"""Unit checks for sync helpers that run outside the game (Lua 5.4 via lupa).

    pip install --target <dir> lupa, set PYTHONPATH=<dir>, then: python tools/test-sync.py
"""
import os, random, shutil, sys, tempfile

try:
    from lupa.lua54 import LuaRuntime   # the game's Lua (plain `lupa` is the newest, 5.5 - other semantics)
except ImportError:
    print("needs lupa (Lua 5.4 for Python): pip install --target <dir> lupa, then set PYTHONPATH=<dir>")
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "mod", "SurrounSync", "Scripts")
failed = 0


def check(cond, what):
    global failed
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        failed += 1


def lua():
    L = LuaRuntime(unpack_returned_tuples=True)
    L.execute('package.path = ... .. "/?.lua;" .. package.path', SCRIPTS.replace("\\", "/"))
    L.execute('package.loaded["mirror.log"] = setmetatable({}, { __index = function() return function() end end })')
    L.execute('function evmock(t) t.reliable = t.reliable or t.new; return t end')
    return L


def posepack_recovers_lost_packets():
    print("posepack_recovers_lost_packets")
    L = lua()
    L.execute('pp = require("mirror.posepack"); out = pp.new(2)')
    packets = [L.eval('out:pack(...)', s, "pose%d" % s) for s in range(1, 21)]
    check(packets[0] == "pose1", "first packet is just the pose (%r)" % packets[0])
    check(packets[4] == "pose5\t4 pose4\t3 pose3", "packet carries the two previous poses (%r)" % packets[4])
    random.seed(7)
    got, after, arrived = [], None, set()
    for s in range(1, 21):
        if s % 3 == 0 or random.random() < 0.2:
            continue  # lost, or overwritten before the reader looked
        arrived.add(s)
        for e in L.eval('pp.unpack(...)', s, packets[s - 1], after).values():
            got.append(e["seq"])
            after = e["seq"]
    missing = [s for s in range(1, 21) if s not in got]
    # pose s travels in packets s, s+1 and s+2; it's only gone if all three were lost (or the stream ended)
    expect = [s for s in range(1, 21) if not ({s, s + 1, s + 2} & arrived)]
    check(got == sorted(got) and len(set(got)) == len(got), "poses come out in order, once each (%s)" % got)
    check(missing == expect, "every pose with one of its 3 packets delivered is recovered (missing %s, expected %s, %d of 20 packets lost)"
          % (missing, expect, 20 - len(arrived)))
    stale = L.eval('pp.unpack(...)', 10, packets[9], 15).values()
    check(len(list(stale)) == 0, "a late packet older than what was seen yields nothing")
    first = list(L.eval('pp.unpack(...)', 1, "pose1", None).values())
    check(len(first) == 1 and first[0]["live"] and first[0]["line"] == "pose1", "a packet without history still works")


def link_blob_comes_back_after_reset():
    """The link hands out a blob once; an unchanged one stays hidden even after link.open again (what phase1 does
    on stop + host again) - only reset_blob shows it again. phase1's reset_link_state resets hello + look: without
    that the other game's unchanged hello never came back -> false "it runs an OLDER SurrounSync" (in-game)."""
    print("link_blob_comes_back_after_reset")
    L = lua()
    d = tempfile.mkdtemp()
    try:
        L.execute('local d = ...; package.loaded["mirror.localdir"] = { get = function() return d end }', d)
        with open(os.path.join(d, "mirror_hello_guest.txt"), "wb") as f:
            f.write(b"SurrounSync protocol 54 role guest\nEND\n")
        L.execute('lf = require("mirror.link_file"); lf.configure({}); lf.open("host")')
        check(L.eval('lf.get_blob("hello")') == "SurrounSync protocol 54 role guest", "first read hands out the hello")
        L.execute('lf.open("host")')
        check(L.eval('lf.get_blob("hello")') is None, "unchanged hello after a new open: hidden (the false alarm's cause)")
        L.execute('lf.reset_blob("hello")')
        check(L.eval('lf.get_blob("hello")') == "SurrounSync protocol 54 role guest", "after reset_blob: handed out again")
        src = open(os.path.join(SCRIPTS, "mirror", "phase1.lua"), encoding="utf-8").read()
        body = src[src.index("local function reset_link_state"):]
        body = body[:body.index("\nend\n")]
        check('link.reset_blob("hello")' in body and 'link.reset_blob("look")' in body,
              "phase1 reset_link_state resets the hello + look blobs")
        # audit N43: compat.reset forgets the friend's mod list - its unchanged "mods" blob must come back too
        check('link.reset_blob("mods")' in body and 'link.reset_blob("light")' in body,
              "phase1 reset_link_state resets the mods + light blobs")
        # T10: a copy stopped for 20 s of silence restarts with peer_where nil; the unchanged "joined" must come back
        check(all('link.reset_blob("%s")' % b in body for b in ("where", "life", "death")),
              "phase1 reset_link_state resets the where + life + death blobs (state it clears)")
        # audit N42: a rejoin's unchanged host bed came back nil -> random start respawn
        ses = open(os.path.join(SCRIPTS, "mirror", "session.lua"), encoding="utf-8").read()
        j = ses.index('link.reset_blob("joincut")')
        check('link.reset_blob("hostbed")' in ses[j:j + 200], "a join resets the hostbed blob with world/joincut")
        bye = src[src.index('local bye = link.get_blob("bye")'):]
        bye = bye[:bye.index('" stopped hosting."')]
        check(bye.index('session.state() == "joined"') < bye.index("said < opened_at"),
              "an old goodbye only skips the 'stopped hosting' note - a joined guest still goes home first")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def a_player_in_the_game_menu_is_not_a_frozen_game():
    """Player review 2026-10-31: the host opened the pause/settings menu and 10 s later the guest read "Host's game
    isn't responding (paused, loading or frozen)" (a file link went "gone" at 45 s: countdown home). The menu stops
    the game's tick; away.lua puts "away menu <n>" from the LoopAsync watch and the other game reads paused/gone
    as "menu" while it keeps coming."""
    print("a_player_in_the_game_menu_is_not_a_frozen_game")
    L = lua()
    L.execute('''
        CLOCK = 0; os.clock = function() return CLOCK end
        PUT, IN, RESET, GAME_GONE = {}, nil, 0, false
        package.loaded["mirror.link"] = {
            put_blob = function(n, t) PUT[#PUT + 1] = n .. "=" .. t end,
            get_blob = function(n) if n ~= "away" then return nil end local b = IN; IN = nil; return b end,
            reset_blob = function(n) if n == "away" then RESET = RESET + 1 end end,
            peer_game_gone = function() return GAME_GONE end,
        }
        away = require("mirror.away")
        function at(t) CLOCK = t end
        function puts() local s = table.concat(PUT, ","); PUT = {}; return s end
    ''')
    # sender: ticks run, then the menu opens at t=10 (no tick after it)
    L.execute('at(0); away.tick(); at(1); away.idle(true); at(10); away.tick()')
    check(L.eval('puts()') == "", "ticking: nothing is sent")
    L.execute('at(11.5); away.idle(true)')
    check(L.eval('puts()') == "", "1.5 s without a tick: nothing yet")
    L.execute('at(12.5); away.idle(false)')
    check(L.eval('puts()') == "", "no tick but no player (a load) or a load/leave under way: nothing")
    L.execute('at(12.5); away.idle(true); at(13.5); away.idle(true); at(16); away.idle(true)')
    check(L.eval('puts()') == "away=menu 1", "over 2 s without a tick: 'menu 1' once, not again within 5 s")
    L.execute('at(17.6); away.idle(true)')
    check(L.eval('puts()') == "away=menu 2", "bumped 5 s later, so the other game sees it change")
    L.execute('at(30); away.tick(); away.tick()')
    check(L.eval('puts()') == "away=-", "the next tick puts 'away -' once")
    L.execute('at(30.5); away.idle(true)')
    check(L.eval('puts()') == "", "ticking again: nothing")
    # receiver
    check(L.eval('away.wrap("paused")') == "paused", "no menu heard: paused stays paused")
    L.execute('IN = "menu 3"; at(100); away.tick()')
    check(L.eval('away.wrap("paused")') == "menu" and L.eval('away.wrap("gone")') == "menu",
          "a menu bump: paused and gone read as menu")
    check(L.eval('away.wrap("ok")') == "ok" and L.eval('away.wrap("unknown")') == "unknown", "ok/unknown are left alone")
    L.execute('GAME_GONE = true')
    check(L.eval('away.wrap("gone")') == "gone", "the bridge says their game closed: gone, whatever the blob said")
    L.execute('GAME_GONE = false; at(118); away.tick()')
    check(L.eval('away.wrap("paused")') == "menu", "18 s after the last bump: still menu")
    L.execute('IN = "menu 4"; at(118.5); away.tick(); at(135); away.tick()')
    check(L.eval('away.wrap("paused")') == "menu", "each bump keeps it fresh")
    L.execute('at(139); away.tick()')
    check(L.eval('away.wrap("paused")') == "paused", "no bump for 20 s (a game frozen in its menu): paused again")
    # (kit 2026-10-31: "isn't responding" flashed as the host closed its menu - "away -" came before its poses)
    L.execute('IN = "menu 5"; at(140); away.tick(); IN = "-"; at(141); away.tick()')
    check(L.eval('away.wrap("paused")') == "menu", "'away -': still menu for a moment, until their poses come")
    L.execute('at(143.9); away.tick()')
    check(L.eval('away.wrap("paused")') == "menu", "...2.9 s after it")
    L.execute('at(144.1); away.tick()')
    check(L.eval('away.wrap("gone")') == "gone", "...and over 3 s after 'away -' it is over")
    L.execute('IN = "-"; at(146); away.tick()')
    check(L.eval('away.wrap("paused")') == "paused", "another 'away -' doesn't bring it back")
    # reset: forgets the other game's state, and mine doesn't keep saying "menu" to a later link
    L.execute('IN = "menu 6"; at(150); away.tick(); at(160); away.idle(true); puts(); away.reset()')
    check(L.eval('away.wrap("paused")') == "paused" and L.eval('RESET') == 1, "reset forgets their menu and resets the blob")
    check(L.eval('puts()') == "away=-", "reset while marked away puts 'away -'")
    L.execute('at(170); away.idle(true)')
    check(L.eval('puts()') == "", "after a reset nothing is sent before a tick was seen")
    src = open(os.path.join(SCRIPTS, "mirror", "phase1.lua"), encoding="utf-8").read()
    check('session.set_peer_state(function() return away.wrap(link.peer_state(now - last_rx)) end)' in src,
          "phase1 gives the session the wrapped peer state")
    check('local ps = away.wrap(link.peer_state(now - last_rx))' in src and 'ps == "ok" or ps == "menu"' in src,
          "the host's guest-gone check reads it wrapped too (a guest in its menu isn't forgotten)")
    reset = src[src.index("local function reset_link_state"):]
    check("away.reset()" in reset[:reset.index("\nend\n")], "reset_link_state resets it")
    tick = src[src.index("local function on_tick"):]
    check("away.tick()" in tick[:tick.index("\nend\n")], "every phase1 tick calls away.tick")
    peers_src = open(os.path.join(SCRIPTS, "mirror", "peers.lua"), encoding="utf-8").read()
    pres = peers_src[peers_src.index("local PRESENCE"):]
    check("away = true" in pres[:pres.index("}")], "every guest's copy has its own (peers PRESENCE)")
    # kit 2026-10-31: 30 s into the host's menu the guest also said "Lost connection to Test-host." and its name tag
    # read "no signal" - both went by the pose age alone. User: the tag says what is happening, no pop-up cards.
    lost = src[src.index('elseif connected and now - last_rx > 30'):]
    check("away.in_menu()" in lost[:lost.index("\n")], "no lost link while the other game says it's in its menu")
    check('notify.show("Lost connection' not in src and 'notify.show("Reconnected' not in src,
          "lost / reconnected: no pop-up card (the name tag says it)")
    check('log.warn("phase1: Lost connection to " .. link.peer_name() .. ".")' in src,
          "...still logged in the wording tools/sessionwatch.py reads")
    why = src[src.index("netq.set_why(function()"):]
    why = why[:why.index("\n    end)")]
    check('if busy_where(peer_where) then return "loading" end' in why
          and "return away.wrap(link.peer_state(now - last_rx))" in why, "phase1 tells the tag why: a load, else the wrapped state")
    check(src.index("netq.set_why(") < src.index("    if mate then\n        anim.init"), "...in every copy (a mate's tag too)")
    L.execute('''
        package.loaded["mirror.events"] = { new = function() return { send = function() end, pump = function() end } end }
        package.loaded["mirror.link"].status = function() return "" end
        netq = require("mirror.netq")
        netq.tick(0.1, 12)
    ''')
    check(L.eval('(netq.tag("Host"))') == "Host · No signal", "no poses, nothing known: 'No signal'")
    for state, text in (("menu", "Paused"), ("loading", "Loading"), ("paused", "Not responding"),
                        ("gone", "Disconnected"), ("ok", "No signal")):
        L.execute('netq.set_why(function() return "%s" end)' % state)
        check(L.eval('(netq.tag("Host"))') == "Host · " + text, "name tag for '%s': '%s'" % (state, text))
    L.execute('netq.tick(0.1, 0.2)')
    check(L.eval('(netq.tag("Host"))') == "Host", "poses coming: no state on the tag")


def link_restart_puts_the_games_blobs_again():
    """A bridge starting idle clears the "_host" files: the hosting game's own one-shot hello went with them after a
    bridge restart and every guest then said "it runs an OLDER SurrounSync" (player report 2026-10-28)."""
    print("link_restart_puts_the_games_blobs_again")
    L = lua()
    d = tempfile.mkdtemp()
    try:
        L.execute('local d = ...; package.loaded["mirror.localdir"] = { get = function() return d end }', d)
        L.execute('link = require("mirror.link"); link.configure({ transport = "steam" }); link.start_lobby()')
        L.execute('link.open("host"); link.put_blob("hello", "SurrounSync protocol 54 role host")')
        hello = os.path.join(d, "mirror_hello_host.txt")
        os.remove(hello)   # the restarted bridge's start-up clear
        L.execute('link.restart_bridge()')
        L.execute('link.idle_tick(0.1)')
        check(not os.path.exists(hello), "nothing is put again while the new bridge isn't up (its clear may still come)")
        with open(os.path.join(d, "mirror_lobby.txt"), "wb") as f:
            f.write(("me 1 2 x\ntime %d\nEND\n" % int(__import__("time").time())).encode())
        L.execute('link.idle_tick(0.1)')
        body = open(hello, "rb").read().decode() if os.path.exists(hello) else None
        check(body == "SurrounSync protocol 54 role host\nEND\n", "once the bridge is up the hello is there again (%r)" % body)
        L.execute('link.open("guest")')
        check(not os.path.exists(hello), "switching to guest removes my host hello at once")
        L.execute('link.restart_bridge(); link.idle_tick(0.1)')
        check(not os.path.exists(hello), "after a new role only that role's blobs come back (no old host hello)")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def link_keeps_putting_the_hello():
    """Player report 2026-10-29 17:57: the host switched in a 3-player Realm, the guest's link came back on the same
    Steam session and the host's bridge sent everything again but the hello (its one-shot file was missing or older
    than its bridge) - 30 s later "WarFare has an older SurrounSync". A kept blob is put again every 10 s; the bridge
    sends it only when its text changed for that player, so on a working link that costs nothing."""
    print("link_keeps_putting_the_hello")
    L = lua()
    d = tempfile.mkdtemp()
    try:
        L.execute('local d = ...; package.loaded["mirror.localdir"] = { get = function() return d end }', d)
        L.execute('link = require("mirror.link"); link.configure({ transport = "steam" }); link.start_lobby()')
        L.execute('link.open("host"); link.put_blob("hello", "SurrounSync protocol 54 role host", true)')
        hello = os.path.join(d, "mirror_hello_host.txt")
        os.remove(hello)   # lost: the other side's bridge never gets it again
        L.execute('for _ = 1, 50 do link.tick(0.1) end')
        check(not os.path.exists(hello), "not put again within 5 s")
        L.execute('for _ = 1, 51 do link.tick(0.1) end')
        body = open(hello, "rb").read().decode() if os.path.exists(hello) else None
        check(body == "SurrounSync protocol 54 role host\nEND\n", "put again within 10 s (%r)" % body)
        L.execute('link.put_blob("look", "a"); link.open("guest")')
        os.remove(os.path.join(d, "mirror_look_host.txt")) if os.path.exists(os.path.join(d, "mirror_look_host.txt")) else None
        L.execute('for _ = 1, 110 do link.tick(0.1) end')
        check(not os.path.exists(hello), "after a role switch the old role's hello isn't put again")
        check(not os.path.exists(os.path.join(d, "mirror_look_host.txt")), "...and a blob put without keep never is")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def clockmap_quiet_places_without_stats():
    print("clockmap_quiet_places_without_stats")
    L = lua()
    L.execute('cm = require("mirror.clockmap").new(0.05, 0.25, 0.15)')
    t1 = L.eval('cm:place(...)', 10.0, 100.0)
    check(t1 is not None, "first update placed")
    L.eval('cm:report()')
    t2 = L.eval('cm:place(...)', 10.1, 100.4, True)
    late, _ = L.eval('cm:report()')
    check(t2 is not None and t2 > t1, "a recovered older update is placed in order (%s > %s)" % (t2, t1))
    check(late == 0, "it doesn't count as lateness (%s)" % late)
    t3 = L.eval('cm:place(...)', 10.05, 100.5, True)
    check(t3 is None, "an update older than one already placed is dropped")


def util_null_objects_are_invalid():
    print("util_null_objects_are_invalid")
    L = lua()
    L.execute('util = require("mirror.util")')
    L.execute('''
        good = { IsValid = function() return true end, GetClass = function() return { GetFullName = function() return "Class /Game/A.A_C" end,
                 GetFName = function() return { ToString = function() return "A_C" end } end, IsValid = function() return true end } end }
        null = { IsValid = function() return false end, GetClass = function() error("would read through a null pointer") end }
        param = function(o) return { get = function() return o end } end
    ''')
    check(L.eval('util.valid(good)') is True, "a live object is valid")
    check(L.eval('util.valid(null)') is False, "a null wrapper is not")
    check(L.eval('util.valid(nil)') is False and L.eval('util.valid(5)') is False and L.eval('util.valid({})') is False,
          "nil, numbers and plain tables are not")
    check(L.eval('util.obj(param(good)) == good') is True, "util.obj passes a live hook param through")
    check(L.eval('util.obj(param(null))') is None, "util.obj turns a null param into nil")
    check(L.eval('util.class_path(null)') is None, "class_path never touches a null object")
    check(L.eval('util.class_path(good)') == "/Game/A.A_C", "class_path of a live object")
    check(L.eval('util.class_name(good)') == "A_C", "class_name of a live object")
    # crash reports 2026-10-20..24: a collected material's address and index went to a new object,
    # IsValid passed and a zombie copy got that object as its material
    L.execute('''
        named = function(n) return { IsValid = function() return true end,
                                     GetFName = function() return { ToString = function() return n end } end } end
        C = { ["/Game/M/Mat_A.Mat_A"] = named("Mat_A"), ["/Game/M/Mat_B.Mat_B"] = named("SomethingElse"),
              ["/Game/M/Mat_C.Mat_C"] = null, ["/Game/X.Y:Sub"] = named("Sub") }
    ''')
    check(L.eval('util.cached(C, "/Game/M/Mat_A.Mat_A") == C["/Game/M/Mat_A.Mat_A"]') is True, "a cached asset that still is itself is returned")
    check(L.eval('util.cached(C, "/Game/X.Y:Sub") ~= nil') is True, "a subobject path matches its own name")
    check(L.eval('util.cached(C, "/Game/M/Mat_B.Mat_B")') is None and L.eval('C["/Game/M/Mat_B.Mat_B"]') is None,
          "a valid object with another name in the cached slot is dropped, not returned")
    check(L.eval('util.cached(C, "/Game/M/Mat_C.Mat_C")') is None and L.eval('util.cached(C, "/none")') is None,
          "a dead or missing entry is nil")


def jig_stats_copy_the_asset_defaults():
    print("jig_stats_copy_the_asset_defaults")
    L = lua()
    L.execute('''
        FName = function(s) return { name = s, ToString = function() return s end } end
        local function nm(s) return { ToString = function() return s end } end
        local stat = { STAT_NAME_13_8D9D8D5D48A145FB1BAD6E98C69D0A10 = { TagName = nm("Stat.Hunger") },
                       Prefix_16_994B3BFF49FB68BE6A485DB9498EB954 = nm("+"),
                       MinValue_6_4B4822A7420F784740B6A58155973EE6 = 20, MaxValue_8_04A5809A498E900862BCCA9A6E412BD7 = 25,
                       Txt_12_F1BE8023414240AC50F4B09BF1B79D58 = nm("Food") }
        ASSET = { IsValid = function() return true end, GetAddress = function() return 42 end,
                  ItemStats = { ForEach = function(self, fn) fn(1, { get = function() return stat end }) end } }
        local function arr()
            local a = { n = 0 }
            function a:GetArrayNum() return self.n end
            return setmetatable(a, { __newindex = function(t, k, v) rawset(t, k, v); if type(k) == "number" and k > t.n then t.n = k end end })
        end
        EMPTY, FULL = { Stats_26_C770972746930CB80CC49AB7A6D19359 = arr() }, { Stats_26_C770972746930CB80CC49AB7A6D19359 = arr() }
        FULL.Stats_26_C770972746930CB80CC49AB7A6D19359[1] = "own"
        jig = require("mirror.jig")
    ''')
    s = L.eval('jig.base_stats(ASSET)')
    check(len(s) == 1, "one stat from the asset")
    first = s[1]
    check(first["MinValue_6_4B4822A7420F784740B6A58155973EE6"] == 20 and first["MaxValue_8_04A5809A498E900862BCCA9A6E412BD7"] == 25,
          "min/max copied")
    check(first["STAT_NAME_13_8D9D8D5D48A145FB1BAD6E98C69D0A10"]["TagName"]["name"] == "Stat.Hunger", "tag rebuilt as a fresh FName")
    check(L.eval('jig.base_stats(ASSET)[1] ~= jig.base_stats(ASSET)[1]'), "fresh tables every call (never reused structs)")
    check(L.eval('jig.write_stats(EMPTY, ASSET)') == 1 and L.eval('EMPTY.Stats_26_C770972746930CB80CC49AB7A6D19359:GetArrayNum()') == 1,
          "an item without stats gets the asset's")
    check(L.eval('jig.write_stats(FULL, ASSET)') == -1 and L.eval('FULL.Stats_26_C770972746930CB80CC49AB7A6D19359[1]') == "own",
          "an item that has stats keeps them")
    check(L.eval('#jig.base_stats(nil)') == 0, "no asset, no stats")
    # A weapon: no ItemStats, its damage is rolled from RandomStats like the game's GenerateRandomStats.
    L.execute('''
        local function nm(s) return { ToString = function() return s end } end
        local function rs(tag, mn, mx, chance, force, both)
            return { STAT_NAME_23_8D9D8D5D48A145FB1BAD6E98C69D0A10 = { TagName = nm(tag) }, Txt_22_E0F5EFD44434F58678FE088E508B5B53 = nm("x"),
                     RandomMinValue_9_4B4822A7420F784740B6A58155973EE6 = mn, RandomMaxValue_10_04A5809A498E900862BCCA9A6E412BD7 = mx,
                     Chance_15_AF3D90B44051B6E1B6D8F194C1F20BD4 = chance, ["ForceToMinValue?_27_531AA2464812E07068161A898359479B"] = force,
                     ["Rounded?_28_44A60F2C4A467758D866B5BCE56695AE"] = true, ["RollForBothMinMax?_19_FEE7FBE94044DC3E7E09DCA48626158A"] = both }
        end
        local rows = { rs("Jig.Stat.FirearmDamage", 30, 40, 100, false, true), rs("Jig.Stat.FirearmRPM", 600, 600, 100, true, false),
                       rs("Jig.Stat.Never", 1, 2, 0, false, false) }
        GUN = { IsValid = function() return true end, GetAddress = function() return 43 end,
                ItemStats = { ForEach = function() end },
                RandomStats = { MaxStats_7_971BC4334FEFC6C1B39175A3D0721033 = 0,
                                Stats_8_78B6E3C14C0578F96B7C9FBBA7820A46 = { ForEach = function(self, fn)
                                    for i, r in ipairs(rows) do fn(i, { get = function() return r end }) end end } } }
        G = jig.base_stats(GUN)
    ''')
    check(L.eval('#G') == 2, "a weapon gets its rolled stats (a 0% stat is skipped)")
    check(L.eval('G[1].STAT_NAME_13_8D9D8D5D48A145FB1BAD6E98C69D0A10.TagName.name') == "Jig.Stat.FirearmDamage"
          and 30 <= L.eval('G[1].MinValue_6_4B4822A7420F784740B6A58155973EE6') <= L.eval('G[1].MaxValue_8_04A5809A498E900862BCCA9A6E412BD7') <= 40,
          "firearm damage rolled inside the asset's range")
    check(L.eval('G[2].MinValue_6_4B4822A7420F784740B6A58155973EE6') == 600, "a forced stat keeps the asset's value")


def weapon_slots_get_their_stats():
    # 1 damage on 0.14.2: an item the mod adds was shown in an open window (HandleNewItemAdded) without its Stats, and
    # the slot keeps its own copy (JSI_Slot.ItemStats) that a weapon's damage is read from (FindStat, 1 when missing)
    print("weapon_slots_get_their_stats")
    L = lua()
    L.execute('''
        FName = function(s) return { s = s, ToString = function() return s end } end
        util = require("mirror.util")
        jig = require("mirror.jig")
        local F = require("mirror.fields")
        local function nm(s) return { ToString = function() return s end } end
        function tarr()   -- a TArray of structs: arr[i] = s writes, ForEach reads
            local list = {}
            return setmetatable({ list = list }, { __index = {
                GetArrayNum = function() return #list end,
                ForEach = function(_, fn) for i, s in ipairs(list) do fn(i, { get = function() return s end }) end end },
                __newindex = function(_, k, v) list[k] = v end })
        end
        DMG = { STAT_NAME_13_8D9D8D5D48A145FB1BAD6E98C69D0A10 = { TagName = nm("Jig.Stat.FirearmDamage") },
                Prefix_16_994B3BFF49FB68BE6A485DB9498EB954 = nm("None"), MinValue_6_4B4822A7420F784740B6A58155973EE6 = 34,
                MaxValue_8_04A5809A498E900862BCCA9A6E412BD7 = 38, Txt_12_F1BE8023414240AC50F4B09BF1B79D58 = nm("Damage") }
        GUN = { IsValid = function() return true end, GetAddress = function() return 77 end, SlotDimensions = { X = 3, Y = 1 },
                Weight = 3, Price = 100, GetFullName = function() return "DataAsset /Game/I.DA_Gun" end,
                ItemStats = { ForEach = function(_, fn) fn(1, { get = function() return DMG end }) end } }
        StaticFindObject = function(p) if p == "/Game/I.DA_Gun" then return GUN end end
        local items, n = {}, 0
        local cont = { ReplicationUID_23_EB27D09649B6E02591DCA98708B06332 = { A = 9, B = 9, C = 9, D = 9 },
                       Columns_4_1D84448048078D988999ABA138CE1809 = 5, Rows_6_78B4BC5B449017D63758E79844375AE9 = 4,
                       ContainerIndex_22_9A211B86466A9D1C57E1FC839A5B0896 = 0,
                       InContainerUID_24_D1504ED7438699C73EA046AD734E79BF = { A = 0, B = 0, C = 0, D = 0 } }
        cont[F.ITEMS] = { ForEach = function(_, fn) for i, it in ipairs(items) do fn(i, { get = function() return it end }) end end }
        COMP = { IsValid = function() return true end, MainJigContainers = { GetArrayNum = function() return 1 end, ForEach = function(_, fn) fn(1, { get = function() return cont end }) end } }
        function COMP:AddNewItemToSlot(info, to, idx, a, b, out, c)
            -- like the game: the stored info has an (empty) Stats array of its own
            local stored = {}
            for k, v in pairs(info[F.INFO]) do stored[k] = v end
            stored[jig.STATS] = tarr()
            n = n + 1
            items[#items + 1] = { [F.INFO] = stored, [F.UID] = { A = n, B = 0, C = 0, D = 0 }, [F.SLOT_INDEX] = idx,
                                  [F.ROTATED] = false, [F.MOTHER] = { A = 9, B = 9, C = 9, D = 9 } }
            out.Added = true
        end
        SHOWN, UPDATED, REJECT_STATS, SLOT_THERE = {}, {}, false, true
        function COMP:HandleNewItemAdded(info, uid, target, idx, rot, subs)
            if REJECT_STATS and info[jig.STATS] then error("struct not taken") end
            SHOWN[#SHOWN + 1] = info
        end
        SLOT = { IsValid = function() return true end, GetAddress = function() return 88 end }
        function SLOT:UpdateStats(st) UPDATED[#UPDATED + 1] = st end
        function COMP:FindItemByUID(g, out) if SLOT_THERE then out.Found = SLOT end end
        function STAT(st, i, key) return st[i][key] end
        function ITEMS() return items end
    ''')
    L.execute('U = jig.add_item(COMP, "/Game/I.DA_Gun", 1, 0, 0); jig.flush_ui()')
    check(L.eval('#SHOWN') == 1 and L.eval('SHOWN[1][jig.STATS] ~= nil'), "the open window is told about the gun with its stats")
    check(L.eval('#SHOWN[1][jig.STATS]') == 1
          and L.eval('SHOWN[1][jig.STATS][1].STAT_NAME_13_8D9D8D5D48A145FB1BAD6E98C69D0A10.TagName.s') == "Jig.Stat.FirearmDamage"
          and L.eval('SHOWN[1][jig.STATS][1].MinValue_6_4B4822A7420F784740B6A58155973EE6') == 34,
          "the stats shown are the item's own (firearm damage 34)")
    check(L.eval('SHOWN[1][jig.STATS][1] ~= DMG'), "fresh tables, not the game's struct")
    check(L.eval('#UPDATED') == 1 and L.eval('#UPDATED[1]') == 1
          and L.eval('UPDATED[1][1].MaxValue_8_04A5809A498E900862BCCA9A6E412BD7') == 38,
          "and the slot in the window gets them through its UpdateStats")
    # the game won't take the stats struct in HandleNewItemAdded: shown plain, the slot still gets them after
    L.execute('SHOWN, UPDATED, REJECT_STATS = {}, {}, true; jig.add_item(COMP, "/Game/I.DA_Gun", 1, 0, 0); jig.flush_ui()')
    check(L.eval('#SHOWN') == 1 and L.eval('SHOWN[1][jig.STATS]') is None and L.eval('#UPDATED') == 1
          and L.eval('#UPDATED[1]') == 1, "stats refused by the add: shown without, then UpdateStats on the slot")
    # an old stat-less gun in the player's inventory: the repair fills the data and the slot made without them
    L.execute('''SHOWN, UPDATED, REJECT_STATS = {}, {}, false
        local F = require("mirror.fields")
        for _, it in ipairs(ITEMS()) do it[F.INFO][jig.STATS] = tarr() end
        FIXED = jig.repair_stats(COMP)''')
    check(L.eval('FIXED') == 2 and L.eval('#UPDATED') == 2 and L.eval('#UPDATED[1]') == 1,
          "the repair of 2 stat-less guns updates both their slots")
    L.execute('SLOT_THERE = false; UPDATED = {}; jig.add_item(COMP, "/Game/I.DA_Gun", 1, 0, 0); OK = pcall(jig.flush_ui)')
    check(L.eval('OK') is True and L.eval('#UPDATED') == 0, "no slot for the item (no window): nothing to update, no error")


FAKES = r"""
    local next_addr = 100
    function obj(t)
        next_addr = next_addr + 1
        local a = next_addr
        if t.IsValid == nil then t.IsValid = function() return true end end
        t.GetAddress = function() return a end
        return t
    end
    function cls(name) return obj({ GetFName = function() return { ToString = function() return name end } end,
                                     GetFullName = function() return "Class /Game/X." .. name end }) end
    package.loaded["mirror.notify"] = { show = function() end, clear = function() end }
    blobs_out, blobs_in = {}, {}
    package.loaded["mirror.link"] = { put_blob = function(n, b) blobs_out[n] = b end,
                                      get_blob = function(n) local b = blobs_in[n]; blobs_in[n] = nil; return b end }
    FName = function(s) return s end
"""


def instances_walk_once_then_follow_beginplay():
    print("instances_walk_once_then_follow_beginplay")
    L = lua()
    L.execute(FAKES + r"""
        NOW = 0; os.clock = function() return NOW end
        util = require("mirror.util")
        HOOKS = {}
        util.hook = function(p, fn) HOOKS[p] = fn; return true end
        local found = {}
        StaticFindObject = function(p)
            if not p:find("^/Game/D%.") then return nil end
            found[p] = found[p] or obj({})
            return found[p]
        end
        function actor(name)
            local a = obj({ GetFullName = function() return name .. " /Game/L.L:P." .. name .. "_1" end })
            a.GetClass = function() return cls(a.cls or name) end
            return a
        end
        WORLD = { Door_C = { actor("Door_C"), actor("Door_C") }, Lamp_C = { actor("Lamp_C") } }
        WORLD.Door_C[3] = obj({ GetFullName = function() return "Door_C /Game/D.Default__Door_C" end })
        WALKS = 0
        FindAllOf = function(c) WALKS = WALKS + 1; return WORLD[c] end
        function frame(secs) NOW = NOW + (secs or 0.016); util.new_frame() end
        frame()
        local a, wa = util.instances("Door_C", "/Game/D.Door_C")
        local b, wb = util.instances("Lamp_C")
        R1 = { WALKS, #a, wa, #b, wb }
    """)
    r = L.eval('R1')
    check(r[1] == 1 and r[2] == 2 and r[3] and r[4] == 0 and not r[5], "one walk per frame, the default object left out")
    L.execute('frame(); R2 = #util.instances("Lamp_C")')
    check(L.eval('WALKS') == 2 and L.eval('R2') == 1, "the next class is walked the frame after")
    L.execute('NEW = actor("Door_C"); HOOKS["/Game/D.Door_C:ReceiveBeginPlay"]({ get = function() return NEW end }); '
              'R3 = #util.instances("Door_C")')
    check(L.eval('R3') == 3 and L.eval('WALKS') == 2, "a new one arrives through BeginPlay, no walk")
    L.execute('ENDED = nil; util.on_end(function(a) ENDED = a end); '
              'HOOKS["/Script/Engine.Actor:ReceiveEndPlay"]({ get = function() return NEW end }); '
              'R8 = #util.instances("Door_C"); NEW_A = NEW:GetAddress()')
    check(L.eval('R8') == 2 and L.eval('ENDED') == L.eval('NEW_A'), "an ended one leaves the list at once (EndPlay)")
    L.execute('HOOKS["/Game/D.Door_C:ReceiveBeginPlay"]({ get = function() return NEW end })')
    L.execute('for i = 1, 400 do frame(1.0); util.instances("Door_C", "/Game/D.Door_C"); util.instances("Lamp_C") end')
    check(L.eval('WALKS') == 3, "400 s later: the hooked class not re-walked, the one without a BeginPlay once")
    L.execute('W0 = WALKS; for i = 1, 50 do frame(1.0); R7 = select(2, util.instances("Bunker_C", "/Game/B.Bunker_C")) end')
    check(L.eval('WALKS') == L.eval('W0') and L.eval('R7'), "a class that isn't loaded is never walked")
    L.execute('NEW.IsValid = function() return false end; WORLD.Door_C[1].cls = "Bullet_C"; frame(2.0); R4 = #util.instances("Door_C")')
    check(L.eval('R4') == 1, "destroyed objects and reused addresses drop out")
    L.execute('TOUCHED = 0; for _, o in ipairs(util.instances("Door_C")) do o.IsValid = function() TOUCHED = TOUCHED + 1; return false end end; '
              'WORLD.Door_C = { actor("Door_C"), actor("Door_C") }; util.instances_reset(); W0 = WALKS; frame(); '
              'local l, w = util.instances("Door_C"); R5, R6 = #l, w')
    check(L.eval('TOUCHED') == 0, "a world reset drops the old objects without touching them")
    check(L.eval('WALKS') == L.eval('W0') + 1 and L.eval('R5') == 2 and L.eval('R6'), "and walks the class again in the new world")


def grouped_classes_share_one_walk():
    # join lag: ~50 class walks (30-110 ms each) in a row after a load; 19 car types are one walk now
    print("grouped_classes_share_one_walk")
    L = lua()
    L.execute(FAKES + r"""
        NOW = 0; os.clock = function() return NOW end
        util = require("mirror.util")
        HOOKS = {}
        util.hook = function(p, fn) HOOKS[p] = fn; return true end
        StaticFindObject = function(p) return obj({ GetFName = function() return { ToString = function() return p:match("([^:]+)$") end } end }) end
        local function thing(c) local o = obj({ GetFullName = function() return c .. " /Game/L.L:P." .. c .. "_1" end }); o.GetClass = function() return cls(c) end; return o end
        WORLD = { thing("Car_A_C"), thing("Car_A_C"), thing("Car_B_C") }
        CDO = obj({ GetFullName = function() return "Car_A_C /Game/A.Default__Car_A_C" end }); CDO.GetClass = function() return cls("Car_A_C") end
        CALLS = {}
        -- like the engine: the parent's FindAllOf returns its children's objects; a child's only its own
        FindAllOf = function(c)
            CALLS[#CALLS + 1] = c
            local out = {}
            for _, o in ipairs(WORLD) do if c == "Car_C" or util.class_name(o) == c then out[#out + 1] = o end end
            if c == "Car_C" or c == "Car_A_C" then out[#out + 1] = CDO end
            return out
        end
        util.instance_group("Car_C", { "Car_A_C", "Car_B_C", "Car_D_C" }, true)
        function frame() NOW = NOW + 0.016; util.new_frame() end
        local M = "/Game/V.Car_C"
        frame()
        local a, wa = util.instances("Car_A_C", M, "Car_C")
        frame()
        local b, wb = util.instances("Car_B_C", M, "Car_C")
        local d, wd = util.instances("Car_D_C", M, "Car_C")
        local p = util.instances("Car_C", M, "Car_C")
        R1 = { #CALLS, #a, wa, #b, wb, #d, wd, #p }
        for i = 1, 100 do frame(); NOW = NOW + 1; util.instances("Car_A_C", M, "Car_C"); util.instances("Car_B_C", M, "Car_C") end
        R2 = #CALLS
        -- a new one after the walk: BeginPlay (the parent's hook) adds it to its own class's list, also for a class no one asked for yet
        NEW = thing("Car_D_C"); HOOKS[M .. ":ReceiveBeginPlay"]({ get = function() return NEW end })
        R3 = #util.instances("Car_D_C", M, "Car_C")
        -- a world reset with a class outside the group (say a game update added Car_E as a child of Car_A): one by one
        WORLD[#WORLD + 1] = thing("Car_E_C")
        util.instances_reset()
        local n0 = #CALLS
        for i = 1, 6 do frame(); A2 = util.instances("Car_A_C", M, "Car_C"); B2 = util.instances("Car_B_C", M, "Car_C") end
        SOLO = {}
        for i = n0 + 1, #CALLS do SOLO[#SOLO + 1] = CALLS[i] end
    """)
    r = L.eval("R1")
    check(r[1] == 1 and r[2] == 2 and r[3] and r[4] == 1 and r[5] and r[6] == 0 and r[7],
          "one walk fills every type of the group (A 2 without the default object, B 1, D 0) - walks %d" % r[1])
    check(r[8] == 3, "the parent's own list is all of them, from the same walk (FindAllOf(parent))")
    check(L.eval("R2") == 1, "no walk again while BeginPlay keeps the lists (%d walks)" % L.eval("R2"))
    check(L.eval("R3") == 1, "a type no one had asked for still gets its new ones through BeginPlay")
    solo = list(L.eval("SOLO").values())
    check(solo[:1] == ["Car_C"] and "Car_A_C" in solo and "Car_B_C" in solo, "an unknown child class: the types are walked one by one (%s)" % solo)
    check(L.eval("#A2") == 2 and L.eval("#B2") == 1, "...with the same lists as before")


def walk_skip_is_measured_after_a_load():
    # measurement only: after a load, did BeginPlay (since the teardown burst) already find what the walk finds?
    print("walk_skip_is_measured_after_a_load")
    L = lua()
    L.execute(FAKES + r"""
        LOGS = {}
        package.loaded["mirror.log"].info = function(s) LOGS[#LOGS + 1] = s end
        NOW = 0; os.clock = function() return NOW end
        util = require("mirror.util")
        HOOKS = {}
        util.hook = function(p, fn) HOOKS[p] = fn; return true end
        StaticFindObject = function(p) return obj({ GetFName = function() return { ToString = function() return p:match("([^:]+)$") end } end }) end
        local function thing(c) local o = obj({ GetFullName = function() return c .. " /Game/L.L:P." .. c .. "_1" end }); o.GetClass = function() return cls(c) end; return o end
        WORLD = { thing("Door_C"), thing("Door_C") }
        WALKS = 0
        FindAllOf = function(c) WALKS = WALKS + 1; return WORLD end
        function frame() NOW = NOW + 0.016; util.new_frame() end
        frame(); util.instances("Door_C", "/Game/D.Door_C")
        -- the old world ends (a burst of EndPlays), the new world's doors begin play (one is missed), then the reset
        NOW = NOW + 10
        for i = 1, 600 do HOOKS["/Script/Engine.Actor:ReceiveEndPlay"]({ get = function() return obj({}) end }) end
        NOW = NOW + 1
        WORLD = { thing("Door_C"), thing("Door_C"), thing("Door_C") }
        HOOKS["/Game/D.Door_C:ReceiveBeginPlay"]({ get = function() return WORLD[1] end })
        HOOKS["/Game/D.Door_C:ReceiveBeginPlay"]({ get = function() return WORLD[2] end })
        util.instances_reset()
        local w0 = WALKS
        frame(); L1, W1 = util.instances("Door_C", "/Game/D.Door_C")
        WALKED = WALKS - w0
        LINE = nil
        for _, s in ipairs(LOGS) do if s:find("after the load BeginPlay had found", 1, true) then LINE = s end end
    """)
    check(L.eval("WALKED") == 1 and L.eval("#L1") == 3 and L.eval("W1"), "the walk after a load still runs and finds all 3")
    line = L.eval("LINE")
    check(line is not None and "found 2 of 3" in line and "Door_C 2/3" in line, "and the log says BeginPlay alone had 2 of 3 (%s)" % line)


def unloaded_tracked_classes_cost_few_lookups():
    # "perf: power/doors took 30-45 ms": a tracked class nobody built (no lamp of that type) was looked up
    # twice every 2 s, ~15 ms per miss
    print("unloaded_tracked_classes_cost_few_lookups")
    L = lua()
    L.execute(FAKES + r"""
        NOW = 0; os.clock = function() return NOW end
        util = require("mirror.util")
        HOOKS = {}
        util.hook = function(p, fn) HOOKS[p] = fn; return true end
        MISSES, HITS = 0, 0
        LOADED = {}
        StaticFindObject = function(p)
            local c = p:match("^(.-):") or p
            if not LOADED[c] then MISSES = MISSES + 1; NOW = NOW + 0.015; return nil end
            HITS = HITS + 1
            return obj({ GetFName = function() return { ToString = function() return p:match("([^:]+)$") end } end })
        end
        WALKS = 0
        FindAllOf = function(c) WALKS = WALKS + 1; return { obj({ GetFullName = function() return c .. " /Game/L.L:P." .. c .. "_1" end }) } end
        function frame(secs) NOW = NOW + (secs or 0.016); util.new_frame() end
        for i = 1, 120 do frame(1.0); util.instances("Lamp_C", "/Game/L.Lamp_C") end
        M120 = MISSES
        LOADED["/Game/L.Lamp_C"] = true
        for i = 1, 31 do frame(1.0); L1, W1 = util.instances("Lamp_C", "/Game/L.Lamp_C") end
        H0 = HITS
        for i = 1, 120 do frame(1.0); util.instances("Lamp_C", "/Game/L.Lamp_C") end
        H120 = HITS - H0
    """)
    check(L.eval("M120") <= 9, "an unloaded class: few misses in 2 minutes (%d, was 120)" % L.eval("M120"))
    check(L.eval("#L1") == 1 and L.eval("W1") and L.eval('HOOKS["/Game/L.Lamp_C:ReceiveBeginPlay"] ~= nil'),
          "once it loads (within 30 s) it's hooked and walked")
    check(L.eval("H120") == 0, "a standing hook needs no lookups (%d)" % L.eval("H120"))


def hook_lookups_share_one_budget():
    print("hook_lookups_share_one_budget")
    L = lua()
    L.execute(FAKES + r"""
        NOW = 0; os.clock = function() return NOW end
        util = require("mirror.util")
        HOOKED = {}
        util.hook = function(p) HOOKED[#HOOKED + 1] = p; return true end
        LOOKS = {}
        LOADED = { ["/Game/A.A_C"] = true }
        StaticFindObject = function(p)
            LOOKS[#LOOKS + 1] = p
            NOW = NOW + 0.0017   -- a hit ~1.7 ms, a miss ~15 ms
            local c = p:match("^(.-):") or p
            if not LOADED[c] then NOW = NOW + 0.013; return nil end
            return obj({ GetFName = function() return { ToString = function() return p:match("([^:]+)$") end } end })
        end
        function frame() NOW = NOW + 0.016; util.new_frame() end
        F = {}
        for i = 1, 10 do F[i] = function() end end
        function all()
            for i = 1, 5 do util.ensure_hook("/Game/A.A_C:F" .. i, F[i]) end
            for i = 6, 10 do util.ensure_hook("/Game/B.B_C:F" .. i, F[i]) end
        end
        frame(); all(); R1 = #LOOKS
    """)
    check(L.eval('R1') == 2, "first lookups are budgeted too (2 hits in one frame, not 10)")
    L.execute('for i = 1, 20 do frame(); all() end; R2, R3 = #HOOKED, #LOOKS')
    check(L.eval('R2') == 5, "the loaded class gets all its hooks over the next frames")
    check(L.eval('R3') == 6, "the unloaded class costs one miss for all its functions")
    L.execute('LOOKS = {}; util.ensure_hook("/Game/B.B_C:Urgent", function() end, nil, true); R4 = #LOOKS')
    check(L.eval('R4') == 1, "an urgent hook skips the budget and the class miss")
    L.execute('LOOKS = {}; LOADED["/Game/B.B_C"] = true; for i = 1, 400 do frame(); NOW = NOW + 0.25; all() end; R5 = #HOOKED')
    check(L.eval('R5') == 10, "a class that loads later gets hooked")
    # in-game 2026-10-27: a module late in the tick order asked each second in the frame where the earlier ones had
    # spent the budget - its hooks never went in (host map pings off after 3 min)
    L.execute(r"""
        HOOKED, N = {}, 0
        function second() frame()
            for i = 1, 2 do N = N + 1; util.ensure_hook("/Game/A.A_C:Hog" .. N, function() end) end
            util.ensure_hook("/Game/A.A_C:Late", F[1]); NOW = NOW + 1.0 end
        function late() local n = 0; for _, p in ipairs(HOOKED) do if p:find("Late") then n = n + 1 end end; return n end
        second(); S1 = late()
        frame(); S2 = late()
    """)
    check(L.eval('S1') == 0 and L.eval('S2') == 1, "a hook that finds the budget spent is looked up in the next frame, not never")
    L.execute(r"""
        for i = 1, 20 do frame() end
        LATE2 = {}; for i = 1, 6 do LATE2[i] = function() end end
        frame(); for i = 1, 2 do N = N + 1; util.ensure_hook("/Game/A.A_C:Hog" .. N, function() end) end
        for i = 1, 6 do util.ensure_hook("/Game/A.A_C:Many" .. i, LATE2[i]) end
        function many() local n = 0; for _, p in ipairs(HOOKED) do if p:find("Many") then n = n + 1 end end; return n end
        M0 = many(); frame(); M1 = many()
        for i = 1, 5 do frame() end; M6 = many()
    """)
    check(L.eval('M0') == 0 and L.eval('M1') == 1 and L.eval('M6') == 6,
          "waiting hooks go one per frame, not all at once (after a load ~200 at once = 300-600 ms) (%s, %s, %s)" % (L.eval('M0'), L.eval('M1'), L.eval('M6')))


def find_remembers_misses():
    print("find_remembers_misses")
    L = lua()
    L.execute(FAKES + r"""
        NOW = 0; os.clock = function() return NOW end
        util = require("mirror.util")
        N = 0; HAVE = false
        StaticFindObject = function(p) N = N + 1; if HAVE then return obj({ GetFName = function() return { ToString = function() return "X" end } end }) end return nil end
        for i = 1, 10 do util.find("/Game/X.X") end
        R1 = N
        NOW = 2.5; util.find("/Game/X.X"); R2 = N
        HAVE = true; NOW = 3; R3 = util.find("/Game/X.X") ~= nil
        util.find_reset(); R4 = util.find("/Game/X.X") ~= nil; R5 = N
        R6 = util.find("/Game/X.X") ~= nil and N == R5
    """)
    check(L.eval('R1') == 1, "ten asks for a missing path cost one lookup")
    check(L.eval('R2') == 2, "asked again after 2 s")
    check(not L.eval('R3'), "the next ask waits for the doubled backoff")
    check(L.eval('R4') and L.eval('R6'), "a world reset forgets misses; a hit is cached")


def tactical_reads_only_lights_the_class_has():
    print("tactical_reads_only_lights_the_class_has")
    L = lua()
    L.execute(FAKES + r"""
        PLAYER = obj({})
        GHOST = obj({})
        package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end }
        package.loaded["mirror.ghost"] = { get = function() return GHOST_ON and GHOST or nil end, generation = function() return 1 end,
                                           on_destroy = function() end }
        package.loaded["mirror.look"] = { components = function() return {} end }
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        local weapon = obj({ GetAttachParentActor = function() return PLAYER end })
        -- A light the class doesn't have reads as a placeholder that can't be compared with a number.
        local placeholder = setmetatable({}, { __lt = function() error("attempt to compare TrivialObject with number") end,
                                               __le = function() error("attempt to compare TrivialObject with number") end })
        local function missing() return { Intensity = placeholder, IsValid = function() return false end } end
        local function att(name, spot, point)
            local a = obj({ GetAttachParentActor = function() return weapon end, GetClass = function() return cls(name .. "_C") end,
                            StaticMesh = { StaticMesh = obj({ GetFullName = function() return "StaticMesh /Game/M." .. name end }) },
                            LaserEndPoint = function(self, out) out.X, out.Y, out.Z = 1, 2, 3 end })
            a.SpotLight = spot and obj({ Intensity = spot }) or missing()
            a.PointLight = point and obj({ Intensity = point }) or missing()
            return a
        end
        ATT = { BP_SmallTacticalLaserSightLocalAttachment_C = { att("BP_SmallTacticalLaserSightLocalAttachment", nil, 5) },
                BP_TacticalLaserLightComboLocalAttachment_C = { att("BP_TacticalLaserLightComboLocalAttachment", 900, 5) },
                BP_SmallTacticalLightLocalAttachment_C = { att("BP_SmallTacticalLightLocalAttachment", 700, nil) },
                BP_TacticalLightLocalAttachment_C = { att("BP_TacticalLightLocalAttachment", 0, nil) } }
        SCANS = 0
        FindAllOf = function(c) SCANS = SCANS + 1; return ATT[c] end
        local found = {}
        StaticFindObject = function(p)
            if not p:find("LocalAttachments", 1, true) then return nil end
            found[p] = found[p] or obj({})
            return found[p]
        end
        tactical = require("mirror.tactical")
        local tick = tactical.tick
        tactical.tick = function(dt) util.new_frame(); tick(dt) end   -- one game frame each, like game.lua
        tactical.init({ mirror_tactical = true })
        errors_before = util.error_count()
    """)
    L.execute('GHOST_ON = false; for i = 1, 200 do tactical.tick(0.1) end')
    check(L.eval('SCANS') == 0 and L.eval('blobs_out.tactical') is None, "no peer: no scans, nothing sent")
    L.execute('GHOST_ON = true; for i = 1, 400 do tactical.tick(0.1) end')
    blob = L.eval('blobs_out.tactical') or ""
    check(L.eval('util.error_count() - errors_before') == 0, "no errors from missing light components")
    check("BP_SmallTacticalLaserSightLocalAttachment" in blob and " 0 5 1 2 3" in blob, "laser sight sent with its beam end")
    check("BP_TacticalLaserLightComboLocalAttachment" in blob and " 900 5" in blob, "combo sends both lights")
    check("BP_SmallTacticalLightLocalAttachment" in blob and " 700 0" in blob, "small light sent")
    check("BP_TacticalLightLocalAttachment " not in blob, "a light switched off is not sent")
    L.execute('ATT.BP_TacticalLaserLightComboLocalAttachment_C[1].dead = true; '
              'ATT.BP_TacticalLaserLightComboLocalAttachment_C[1].IsValid = function() return false end; '
              'for i = 1, 20 do tactical.tick(0.1) end')
    check("Combo" not in (L.eval('blobs_out.tactical') or ""), "a removed attachment stops being sent")


def group_split_leader_and_follower_agree():
    print("group_split_leader_and_follower_agree")
    G = r'''
        local my_slot, peer_slot = ...
        OUT, IN, LOG = {}, {}, {}
        SPLIT, INWORLD, KIND = false, true, nil
        package.loaded["mirror.log"] = { info = function(m) LOG[#LOG + 1] = m end }
        package.loaded["mirror.link"] = { put_blob = function(n, b) OUT[n] = b end,
            get_blob = function(n) local b = IN[n]; IN[n] = nil; return b end,
            tags = function() return { out = "to" .. peer_slot } end, peer_name = function() return "P" .. peer_slot end }
        Z = { gate = nil, role = nil }
        function Z.init(c, r, s, o) Z.role, Z.secondary = r, o and o.secondary end
        function Z.set_gate(v) Z.gate = v end
        function Z.set_guest_center() end
        function Z.is_split() return SPLIT end
        package.loaded["mirror.zombies"] = Z
        package.loaded["mirror.ghost"] = { location = function() return nil end }
        package.loaded["mirror.phase1"] = { set_ghost_kind = function(k) KIND = k end }
        package.loaded["mirror.corpses"] = { init = function(c, r, z) CORPSES = { role = r, z = z } end }
        package.loaded["mirror.peers"] = { my_slot = function() return my_slot end, slot_of = function() return peer_slot end,
                                           main = function() return Z end }
        group = require("mirror.group")
        group.init({}, { in_world = function() return INWORLD end })
    '''
    A, B = lua(), lua()
    A.execute(G, 2, 3)      # leader: slot 2, its copy for slot 3
    B.execute(G, 3, 2)      # follower: slot 3, its copy for slot 2
    check(A.eval("CORPSES.role") == "host" and B.eval("CORPSES.role") == "guest" and A.eval("CORPSES.z == Z"),
          "the pair's corpse loot: the leader's copy rolls it (host role), the follower's shows it, on the pair's zombies")

    def run(n=3):
        for _ in range(n):
            A.execute('group.tick(0.3)'); B.execute('group.tick(0.3)')
            for src, dst in ((A, B), (B, A)):
                out = src.eval('OUT')
                for k in list(out.keys()):
                    dst.eval('IN')[k] = out[k]
                src.execute('OUT = {}')

    check(A.eval('Z.role') == "host" and B.eval('Z.role') == "guest" and A.eval('Z.secondary') and A.eval('Z.gate') is False,
          "lower slot's copy sends (host role), the other shows (guest role); both off at first")
    A.execute('SPLIT = true')
    B.execute('group.follow(true, 7)')
    run()
    check(A.eval('Z.gate') is True and A.eval('KIND') == "host", "leader (split) takes the follower on: its AI goes for their ghost")
    check(B.eval('Z.gate') is True and B.eval('group.follow_acked(7)'), "follower shows the leader's AI once confirmed")
    A.execute('SPLIT = false')
    run()
    check(A.eval('Z.gate') is False and A.eval('KIND') == "guest" and B.eval('Z.gate') is False and not B.eval('group.follow_acked(7)'),
          "leader merged: both sides stop")
    A.execute('SPLIT = true'); B.execute('group.follow(true, 8)'); run()
    B.execute('group.follow(false, 9)'); run()
    check(A.eval('Z.gate') is False and B.eval('Z.gate') is False, "follower told to stop by the host: both sides stop")
    A2 = lua(); A2.execute(G, 2, 3); A2.execute('SPLIT = false; IN.p8f = "f 4"; group.tick(0.3)')
    check(A2.eval('Z.gate') is False and A2.eval('OUT.p8l') is None, "a guest that isn't split never leads")


def vehicles_seat_four_players_by_slot():
    print("vehicles_seat_four_players_by_slot")

    def setup(role, my_slot, peer_slot):
        L = lua()
        L.execute(FAKES + r"""
            local role, MY, PS = ...
            CAR_PARENT = nil
            PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
                           GetAttachParentActor = function() return CAR_PARENT end,
                           K2_SetActorLocation = function(self, l) PLAYER_AT = l end })
            GHOST_AT = nil
            GHOST = obj({ K2_SetActorLocationAndRotation = function(self, l) GHOST_AT = l end, PlayAnimMontage = function() end,
                          CharacterMovement = { SetMovementMode = function() end } })
            package.loaded["mirror.game"] = { player = function() return PLAYER end, world = function() return nil end,
                                              on_world_reset = function() end }
            package.loaded["mirror.ghost"] = { get = function() return GHOST end, set_seated = function() end, generation = function() return 1 end }
            package.loaded["mirror.link"].tags = function() return nil end
            package.loaded["mirror.link"].peer_name = function() return "Peer" end
            StaticFindObject = function() return obj({}) end
            util = require("mirror.util")
            util.ensure_hook = function() return true end
            local ksl = obj({})
            ksl.IsValid = function(self, a) if a == nil then return true end return a.dead ~= true end
            util.cdo = function() return ksl end
            OTHERS = {}
            package.loaded["mirror.peers"] = {
                my_slot = function() return MY end,
                slot_of = function(out) return PS end,
                each = function(name, fn) fn(require(name)); for _, m in ipairs(OTHERS) do fn(m) end end,
                main = function(name) return MAIN or require(name) end,
            }
            -- driver seat at (0, 100, 0) of a car at the origin facing +X: passenger (0, -100), rear seats 95 behind
            A = obj({ VehicleColor = 0, Colors = {}, Mesh = { SetMaterial = function() end, SetPhysicsLinearVelocity = function() end,
                                                             SetPhysicsAngularVelocityInDegrees = function() end },
                      FuelComponent = { CurrentFuel = 50, MaxFuel = 100 }, VehicleHealthComponent = { CurrentHealth = 100, MaxHealth = 100 },
                      PlayerLocation = { K2_GetComponentToWorld = function() return { Translation = { X = 0, Y = 100, Z = 0 } } end },
                      GetActorRightVector = function() return { X = 0, Y = 1, Z = 0 } end,
                      GetActorForwardVector = function() return { X = 1, Y = 0, Z = 0 } end,
                      K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
                      K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
                      K2_SetActorLocationAndRotation = function() end, K2_TeleportTo = function() return true end,
                      VehicleEngineFX = function() end, IsActorBeingDestroyed = function() return false end,
                      IsA = function() return true end, GetVelocity = function() return { X = 0, Y = 0, Z = 0 } end,
                      VehicleMovementComponent = { SetHandbrakeInput = function() end, SetBrakeInput = function() end,
                                                   SetThrottleInput = function() end, SetSteeringInput = function() end },
                      GetFullName = function() return "Vehicle_Van_C /Game/L.L:P.Vehicle_Van_C_1" end,
                      GetFName = function() return { ToString = function() return "Vehicle_Van_C_1" end } end })
            FindAllOf = function(c) if c == "Vehicle_Van_C" then return { A } end return {} end
            util.instances = function(c) if c == "Vehicle_Van_C" then return { A }, true end return {}, true end
            vehicles = require("mirror.vehicles")
            vehicles.init({ mirror_vehicles = true }, role, { guest_in_world = function() return true end, in_world = function() return true end })
            local tick = vehicles.tick
            vehicles.tick = function(dt) util.new_frame(); tick(dt) end
            for i = 1, 30 do vehicles.tick(0.1) end
        """, role, my_slot, peer_slot)
        return L

    # this game's copy shows the player in slot 3; slot 1 rides the same car (another copy): 3 gets the second passenger seat
    L = setup("guest", 2, 3)
    L.execute('OTHERS = { { rides_in = function() return "Vehicle_Van_C_1" end, player_slot = function() return 1 end } }')
    L.execute('blobs_in.ride = "R Vehicle_Van_C_1"; vehicles.tick(0.1)')
    at = L.eval('GHOST_AT')
    check(at is not None and abs(at.X + 95) < 1e-6 and abs(at.Y - 100) < 1e-6,
          "riders take the passenger seats in slot order (slot 3 behind the driver, after slot 1)")
    L.execute('OTHERS = {}; vehicles.tick(0.1); vehicles.tick(0.1)')
    at = L.eval('GHOST_AT')
    check(abs(at.X) < 1e-6 and abs(at.Y + 100) < 1e-6, "the other rider gets out: it moves up to the front passenger seat")

    # the guest's own screen, a bot's copy: the local player (slot 1) sits in the front passenger seat - the bot
    # (slot 2) used to be put there too (the copy didn't count the local rider: bot in the guest's lap)
    L = setup("guest", 1, 2)
    L.execute('MAIN = { my_ride = function() return "Vehicle_Van_C_1", 1 end }; blobs_in.ride = "R Vehicle_Van_C_1"; vehicles.tick(0.1)')
    at = L.eval('GHOST_AT')
    check(at is not None and abs(at.X + 95) < 1e-6 and abs(at.Y - 100) < 1e-6, "a rider never gets the local player's seat")
    # first come keeps its seat: a rider that announced the rear-left seat stays there when the front one empties
    L = setup("guest", 2, 3)
    L.execute('OTHERS = { { rides_in = function() return "Vehicle_Van_C_1" end, player_slot = function() return 1 end, '
              'peer_seat = function() return 1 end } }; blobs_in.ride = "R Vehicle_Van_C_1 3"; vehicles.tick(0.1)')
    at = L.eval('GHOST_AT')
    check(at is not None and abs(at.X + 95) < 1e-6 and abs(at.Y + 100) < 1e-6, "an announced seat is used (seat 3, behind the passenger)")
    L.execute('OTHERS = {}; vehicles.tick(0.1); vehicles.tick(0.1)')
    at = L.eval('GHOST_AT')
    check(abs(at.X + 95) < 1e-6 and abs(at.Y + 100) < 1e-6, "and kept when the front passenger gets out")
    # two claim the same seat: the lower slot keeps it, the other takes the next free one
    L = setup("guest", 2, 3)
    L.execute('OTHERS = { { rides_in = function() return "Vehicle_Van_C_1" end, player_slot = function() return 1 end, '
              'peer_seat = function() return 1 end } }; blobs_in.ride = "R Vehicle_Van_C_1 1"; vehicles.tick(0.1)')
    at = L.eval('GHOST_AT')
    check(at is not None and abs(at.X + 95) < 1e-6 and abs(at.Y - 100) < 1e-6, "a contested seat goes to the lower slot, the other moves to a free one")

    # both get into the same car: the lower slot drives
    L = setup("guest", 1, 0)
    L.execute('CAR_PARENT = A; for i = 1, 3 do vehicles.tick(0.1) end')
    check(L.eval('vehicles.status():find("driving Vehicle_Van_C_1") ~= nil'), "guest drives the car")
    L.execute('vehicles.drive_sample("D Vehicle_Van_C_1 0 0 0 0 0 0 0 0 0 1 0 1.000"); for i = 1, 3 do vehicles.tick(0.1) end')
    check(L.eval('vehicles.status():find("driving %-") ~= nil') and (L.eval('blobs_out.ride') or "").startswith("R Vehicle_Van_C_1"),
          "the host (slot 0) got in too: the guest rides along instead")
    L = setup("host", 0, 1)
    L.execute('CAR_PARENT = A; for i = 1, 3 do vehicles.tick(0.1) end')
    L.execute('vehicles.drive_sample("D Vehicle_Van_C_1 0 0 0 0 0 0 0 0 0 1 0 1.000"); for i = 1, 3 do vehicles.tick(0.1) end')
    check(L.eval('vehicles.status():find("driving Vehicle_Van_C_1") ~= nil'), "and the host keeps driving")

    # the driver hops out and back in while the passenger stays (player review 2026-10-31: the car was sometimes thrown
    # airborne). The passenger, whom its own game seats in the driver's seat, took the car over: the driver came back
    # as a passenger of a car following the other game (kit 2026-10-31: "driving ... - the other game follows" on the
    # guest, "riding along" on the host) while its own throttle fought the follow.
    L = setup("guest", 1, 0)
    L.execute(r'''
        A.VehicleMovementComponent.SetHandbrakeInput = function(self, v) HB = v end
        CAR_PARENT = A
        vehicles.drive_sample("D Vehicle_Van_C_1 0 0 0 0 0 0 0 0 0 1 0 1.000"); for i = 1, 3 do vehicles.tick(0.1) end
        RIDE0 = blobs_out.ride
        blobs_out.drive = nil
        blobs_in.drive = "P Vehicle_Van_C_1 0 0 0 0 0 0 0 50.0 100.0 2.000 0.00 0.00"
        for i = 1, 20 do vehicles.tick(0.1) end
    ''')
    check((L.eval('RIDE0') or "").startswith("R Vehicle_Van_C_1"), "(setup) the guest rides along in the host's car")
    check(L.eval('vehicles.status():find("driving %-") ~= nil') and L.eval('blobs_out.drive') is None,
          "the driver got out: the passenger still in it doesn't take the car over (%s, %s)"
          % (L.eval('vehicles.status()')[:60], L.eval('blobs_out.drive')))
    check((L.eval('blobs_out.ride') or "").startswith("R Vehicle_Van_C_1") and L.eval('HB') is True,
          "...it stays a passenger, the car standing with its handbrake on (ride %s, handbrake %s)"
          % (L.eval('blobs_out.ride'), L.eval('HB')))
    L.execute('vehicles.drive_sample("D Vehicle_Van_C_1 0 0 0 0 0 0 0 0 0 1 0 3.000"); for i = 1, 3 do vehicles.tick(0.1) end')
    check(L.eval('vehicles.status():find("the other player\'s car Vehicle_Van_C_1") ~= nil') and L.eval('blobs_out.drive') is None,
          "the driver gets back in: they drive again and the passenger rides on")
    L.execute('CAR_PARENT = nil; for i = 1, 3 do vehicles.tick(0.1) end')
    check(L.eval('blobs_out.ride') == "R -", "the passenger gets out: the other game hears it")

    # the car's HitBox (runs zombies over) is off while the other player drives it here; the game turns it back on only
    # when the car comes back into its optimization range, so it stayed off: user 2026-10-31 "after a while the zombies
    # become brick walls to vehicles"
    L = setup("guest", 1, 0)
    L.execute(r'''
        A.HitBoxCollision = { SetGenerateOverlapEvents = function(self, v) HITBOX = v end }
        HITBOX = true
        vehicles.drive_sample("D Vehicle_Van_C_1 0 0 0 0 0 0 0 0 0 1 0 1.000")
        vehicles.drive_sample("D Vehicle_Van_C_1 50 0 0 0 0 0 500 0 0 1 0 1.100")
        for i = 1, 5 do vehicles.tick(0.1) end
        WHILE_THEY_DRIVE = HITBOX
        blobs_in.drive = "P Vehicle_Van_C_1 0 0 0 0 0 0 0 50.0 100.0 2.000 0.00 0.00"
        for i = 1, 3 do vehicles.tick(0.1) end
        PARKED = HITBOX
        vehicles.drive_sample("D Vehicle_Van_C_1 0 0 0 0 0 0 0 0 0 1 0 3.000")
        vehicles.drive_sample("D Vehicle_Van_C_1 50 0 0 0 0 0 500 0 0 1 0 3.100")
        for i = 1, 5 do vehicles.tick(0.1) end
        AGAIN = HITBOX
        blobs_in.ride = "R Vehicle_Van_C_1"; vehicles.tick(0.1)
        RIDES = HITBOX
        HITBOX = false
        blobs_in.ride = "R -"; CAR_PARENT = A
        for i = 1, 3 do vehicles.tick(0.1) end
        I_DRIVE = HITBOX
    ''')
    check(L.eval('WHILE_THEY_DRIVE') is False and L.eval('AGAIN') is False,
          "(setup) the HitBox is off while the other player drives the car here")
    check(L.eval('PARKED') is True, "the other player parks it: the HitBox is back on (%s)" % L.eval('PARKED'))
    check(L.eval('RIDES') is True, "the driver becomes a rider: the HitBox is back on (%s)" % L.eval('RIDES'))
    check(L.eval('I_DRIVE') is True and L.eval('vehicles.status():find("driving Vehicle_Van_C_1") ~= nil'),
          "I drive a car whose HitBox was left off: it is on (%s, %s)" % (L.eval('I_DRIVE'), L.eval('vehicles.status()')[:60]))

    # lights go the game's own way (TurnOnOffLights: intensity), never hidden - the driver's own switch lit hidden
    # lights (user 2026-10-29: the other player saw them, the driver didn't)
    L = setup("guest", 1, 0)
    L.execute(r'''
        A["LightsOn?"], TOGGLES, VIS = false, 0, nil
        A.TurnOnOffLights = function(self) self["LightsOn?"] = not self["LightsOn?"]; TOGGLES = TOGGLES + 1 end
        A.LightLeft = { SetVisibility = function(_, v) VIS = v end }
        vehicles.drive_sample("D Vehicle_Van_C_1 0 0 0 0 0 0 0 0 0 1 1 1.000"); vehicles.tick(0.1)
        vehicles.drive_sample("D Vehicle_Van_C_1 0 0 0 0 0 0 0 0 0 1 1 2.000"); vehicles.tick(0.1)
    ''')
    check(L.eval('A["LightsOn?"]') is True and L.eval('TOGGLES') == 1, "the driver's lights on: the game's own switch, once")
    check(L.eval('VIS') is True, "the lights are never hidden")
    L.execute('vehicles.drive_sample("D Vehicle_Van_C_1 0 0 0 0 0 0 0 0 0 1 0 3.000"); vehicles.tick(0.1)')
    check(L.eval('A["LightsOn?"]') is False and L.eval('TOGGLES') == 2 and L.eval('VIS') is True,
          "lights off the same way (still not hidden: the game's own switch must keep working here)")

    # the guest drives a car the host's world doesn't have: the host makes one to show it, but it never goes into the
    # host's saves and is gone when the guest leaves (report 2026-10-29: cars in the host's save it never had)
    L = setup("host", 0, 1)
    L.execute(r'''
        HERE = true
        util.ensure_hook = function(p, fn) if p:find("ReceiveBeginPlay", 1, true) then BEGIN = fn end; return true end
        vehicles.init({ mirror_vehicles = true }, "host", { guest_in_world = function() return HERE end, in_world = function() return true end })
        for i = 1, 3 do vehicles.tick(0.1) end
        SKIPSAVE, MADE = nil, nil
        util.cdo().SetActorSaveProperties = function(self, a, skip) if a == MADE then SKIPSAVE = skip end end
        local made = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
                           K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
                           K2_SetActorLocationAndRotation = function() end, K2_TeleportTo = function() return true end,
                           IsActorBeingDestroyed = function() return false end, GetVelocity = function() return { X = 0, Y = 0, Z = 0 } end,
                           Mesh = A.Mesh, VehicleMovementComponent = A.VehicleMovementComponent, IsA = function() return true end,
                           K2_DestroyActor = function(self) self.dead = true; DESTROYED = true end,
                           GetFName = function() return { ToString = function() return "Vehicle_Truck_C_77" end } end,
                           GetFullName = function() return "Vehicle_Truck_C /Game/L.L:P.Vehicle_Truck_C_77" end,
                           -- (a class like a real car's: host_list leaves out a car whose class it can't name)
                           GetClass = function() return obj({ GetFullName = function() return "BlueprintGeneratedClass /Game/Vehicles/Truck.Vehicle_Truck_C" end }) end })
        MADE = made
        -- as in the game: the new car's BeginPlay (hooked) runs inside SpawnActor
        package.loaded["mirror.game"].world = function() return { SpawnActor = function()
            if BEGIN then BEGIN({ get = function() return made end }) end
            return made end } end
        for i = 1, 30 do vehicles.tick(0.1) end   -- (the car BeginPlay hook stands before the drive comes in)
        BEGIN_BEFORE = BEGIN ~= nil
        local lg = require("mirror.log")
        local info = lg.info
        ANNOUNCED = false
        lg.info = function(m) if tostring(m):find("a new car here (Vehicle_Truck_C_77)", 1, true) then ANNOUNCED = true end; return info(m) end
        vehicles.drive_sample("D Vehicle_Truck_C_9 0 0 0 0 0 0 0 0 0 1 0 1.000 /Game/Vehicles/Truck.Vehicle_Truck_C")
        for i = 1, 3 do vehicles.tick(0.1) end
        lg.info = info
        -- a car of the host's own world turns up next (its BeginPlay outside any copy): the list goes to the guest
        -- 2 s later - with the world's cars in it and not the copy (classes as a real car's: unnamed ones are left out)
        local function cls(p) return function() return obj({ GetFullName = function() return "BlueprintGeneratedClass " .. p end }) end end
        A.GetClass = cls("/Game/Vehicles/Van.Vehicle_Van_C")
        local b = obj({ K2_GetActorLocation = function() return { X = 500, Y = 0, Z = 0 } end,
                        K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
                        IsActorBeingDestroyed = function() return false end, IsA = function() return true end,
                        GetClass = cls("/Game/Vehicles/Pickup.Vehicle_Pickup_C"),
                        GetFName = function() return { ToString = function() return "Vehicle_Pickup_C_5" end } end,
                        GetFullName = function() return "Vehicle_Pickup_C /Game/L.L:P.Vehicle_Pickup_C_5" end })
        blobs_out.cars = nil
        BEGIN({ get = function() return b end })
        for i = 1, 25 do vehicles.tick(0.1) end
        LISTED = blobs_out.cars or ""
    ''')
    listed = L.eval('LISTED')
    check("Vehicle_Pickup_C_5 " in listed and "Vehicle_Van_C_1 " in listed,
          "(setup) a new car of the host's world sends the car list, with the world's cars in it: %r" % listed)
    check("Vehicle_Truck_C_77" not in listed, "...and never the copy of the guest's car (live: the guest made a 2nd car of it)")
    check(L.eval('vehicles.status():find("added 1") ~= nil'), "the host made the guest's car (%s)" % L.eval('vehicles.status()'))
    check(L.eval('SKIPSAVE') is True, "...kept out of the host's saves")
    # report 2026-10-30 (Realm): the copy was announced as 'a new car here' and listed to the guest, who made a second
    # car of it - players then sat in a car the other game had released
    check(L.eval('BEGIN_BEFORE') is True, "(setup) the car BeginPlay hook stood before the copy was made")
    check(L.eval('ANNOUNCED') is False, "...and never announced to the guest as 'a new car here' (live: the guest made a 2nd car of it)")
    L.execute('HERE = false; for i = 1, 3 do vehicles.tick(0.1) end; NOW_GONE = DESTROYED == true')
    # (a car has an anim graph: its K2_DestroyActor waits until animation runs on the game thread - animgate.lua)
    L.execute('for i = 1, 3 do util.new_frame(); require("mirror.animgate").tick() end')
    check(L.eval('NOW_GONE') is False and L.eval('DESTROYED') is True,
          "...and removed when the guest leaves, 2 frames after animation went to the game thread")

    # wheels: the driver's steering / throttle / brake travel with the car, the follower's wheels use them
    L = setup("host", 0, 1)
    L.execute('A.VehicleMovementComponent.RawSteeringInput = 0.3; A.VehicleMovementComponent.RawThrottleInput = 1.0;'
              ' A.VehicleMovementComponent.RawBrakeInput = 0.0; CAR_PARENT = A; for i = 1, 3 do vehicles.tick(0.1) end')
    check(" I 0.30 1.00 0.00" in (L.eval('vehicles.drive_line()') or ""), "the driver sends its inputs (%s)" % L.eval('vehicles.drive_line()'))
    L = setup("guest", 1, 0)
    L.execute(r'''
        local m = A.VehicleMovementComponent
        m.IdleBrakeInput = 0.4
        m.SetSteeringInput = function(self, v) STEER = v end
        m.SetThrottleInput = function(self, v) THROTTLE = v end
        vehicles.drive_sample("D Vehicle_Van_C_1 0 0 0 0 0 0 500 0 0 1 0 1.000 I -0.60 0.80 0.00")
        vehicles.drive_sample("D Vehicle_Van_C_1 50 0 0 0 0 0 500 0 0 1 0 1.100 I -0.60 0.80 0.00")
        for i = 1, 5 do vehicles.tick(0.1) end
    ''')
    check(L.eval("STEER") == -0.6 and L.eval("THROTTLE") == 0.8, "the other player's car steers and drives its wheels (%s, %s)"
          % (L.eval("STEER"), L.eval("THROTTLE")))
    check(L.eval("A.VehicleMovementComponent.IdleBrakeInput") == 0.0, "and its idle brake is off while it follows")

    # Vehicle_Humvee2_C (game update 26303910) is a car too: left out of the types it was never in the host's car list
    # (a guest driving one made the host spawn a second one), and it split the one car walk into one per type after
    # every join (kit 2026-10-31: "BP_VehicleMaster_C has a child class outside its group (Vehicle_Humvee2_C)")
    L = setup("host", 0, 1)
    L.execute(r'''
        local function cls(p) return function() return obj({ GetFullName = function() return "BlueprintGeneratedClass " .. p end }) end end
        A.GetClass = cls("/Game/Vehicles/Van.Vehicle_Van_C")
        local h = obj({ K2_GetActorLocation = function() return { X = 900, Y = 0, Z = 0 } end,
                        K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
                        IsActorBeingDestroyed = function() return false end, IsA = function() return true end,
                        GetClass = cls("/Game/Blueprints/Vehicles/Types/Humvee2/Vehicle_Humvee2.Vehicle_Humvee2_C"),
                        GetFName = function() return { ToString = function() return "Vehicle_Humvee2_C_3" end } end,
                        GetFullName = function() return "Vehicle_Humvee2_C /Game/L.L:P.Vehicle_Humvee2_C_3" end })
        util.instances = function(c)
            if c == "Vehicle_Van_C" then return { A }, true end
            if c == "Vehicle_Humvee2_C" then return { h }, true end
            return {}, true
        end
        -- (the guest leaves and comes back: the host sends its list anew)
        HERE = false
        vehicles.init({ mirror_vehicles = true }, "host", { guest_in_world = function() return HERE end, in_world = function() return true end })
        for i = 1, 3 do vehicles.tick(0.1) end
        blobs_out.cars, HERE = nil, true
        for i = 1, 30 do vehicles.tick(0.1) end
        LISTED = blobs_out.cars or ""
    ''')
    listed = L.eval('LISTED')
    check("Vehicle_Van_C_1 " in listed and "Vehicle_Humvee2_C_3 " in listed,
          "the host's car list has its Humvee2 (game update 26303910) as well: %r" % listed)


def vehicles_keep_this_worlds_fuel():
    print("vehicles_keep_this_worlds_fuel")
    L = lua()
    L.execute(FAKES + r"""
        PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end })
        GHOST = obj({})
        package.loaded["mirror.game"] = { player = function() return PLAYER end, world = function() return nil end,
                                          on_world_reset = function() end }
        package.loaded["mirror.ghost"] = { get = function() return GHOST end, set_seated = function() end, generation = function() return 1 end }
        StaticFindObject = function() return obj({}) end
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        local ksl = obj({})
        ksl.IsValid = function(self, a) if a == nil then return true end return a.dead ~= true end
        util.cdo = function() return ksl end
        function car(name, fuel, health)
            return obj({ VehicleColor = 0, Colors = {}, Mesh = { SetMaterial = function() end }, ["EngineOn?"] = health > 0,
                         FuelComponent = { CurrentFuel = fuel, MaxFuel = 100, Empty = fuel <= 0 },
                         VehicleHealthComponent = { CurrentHealth = health, MaxHealth = 100 },
                         FuelWidget = { GetUserWidgetObject = function() return { UpdateFuel = function(_, f) SHOWN_FUEL = f end } end },
                         RepairWidget = { GetUserWidgetObject = function() return { UpdateHealth = function(_, h) SHOWN_HEALTH = h end } end },
                         Svr_UpdateFuel = function(_, f) HUD_FUEL = f end, Svr_UpdateEngine = function(_, h) HUD_HEALTH = h end,
                         K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end,
                         K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
                         K2_SetActorLocationAndRotation = function() end, VehicleEngineFX = function() end,
                         IsActorBeingDestroyed = function() return false end,
                         IsA = function() return true end,
                         GetClass = function() return cls("Vehicle_Van_C") end,
                         GetFullName = function() return "Vehicle_Van_C /Game/L.L:P." .. name end,
                         GetFName = function() return { ToString = function() return name end } end })
        end
        A = car("Vehicle_Van_C_1", 60, 100)
        B = car("Vehicle_Van_C_2", 0, 0)
        -- (like the engine: FindAllOf of the parent class returns its children's objects too)
        FindAllOf = function(c) if c == "Vehicle_Van_C" or c == "BP_VehicleMaster_C" then return { A, B } end return {} end
        vehicles = require("mirror.vehicles")
        vehicles.init({ mirror_vehicles = true }, "host", { guest_in_world = function() return true end })
        local tick = vehicles.tick
        vehicles.tick = function(dt) util.new_frame(); tick(dt) end   -- one game frame each, like game.lua
        for i = 1, 30 do vehicles.tick(0.1) end   -- every car type walked once, one per frame
    """)
    L.execute('vehicles.drive_sample("P Vehicle_Van_C_1 100 0 0 0 0 0 0 0.0 100.0 5.000 0.00 0.00")')
    check(L.eval('A.FuelComponent.CurrentFuel') == 60, "a park after a drive that used nothing keeps this world's fuel (stale copy said 0)")
    L.execute('vehicles.drive_sample("P Vehicle_Van_C_1 100 0 0 0 0 0 0 0.0 100.0 6.000 12.50 20.00")')
    check(abs(L.eval('A.FuelComponent.CurrentFuel') - 47.5) < 1e-6 and abs(L.eval('A.VehicleHealthComponent.CurrentHealth') - 80) < 1e-6,
          "a park applies the fuel used and damage taken")
    L.execute('blobs_in.carstate = "Vehicle_Van_C_2 0 50.0 50.0"; vehicles.tick(0.1)')
    check(L.eval('B.FuelComponent.CurrentFuel') == 50 and L.eval('B.FuelComponent.Empty') is False,
          "a refuel from the other game clears the empty flag")
    check(L.eval('B.VehicleHealthComponent.CurrentHealth') == 50 and L.eval('B["EngineOn?"]') is True,
          "a repair from the other game turns a wreck's engine back on")
    check(L.eval('SHOWN_FUEL') == 50 and L.eval('SHOWN_HEALTH') == 50,
          "the car's own fuel and repair widgets show the other player's refuel/repair at once")
    check(L.eval('HUD_FUEL') == 50 and L.eval('HUD_HEALTH') == 50, "the HUD stats of the car next to me are refreshed too")
    L.execute('blobs_out.carstate = nil; for i = 1, 30 do vehicles.tick(0.1) end')
    check(L.eval('blobs_out.carstate') is None, "applied state is not echoed back")
    L.execute('A.FuelComponent.CurrentFuel = 97.5; for i = 1, 30 do vehicles.tick(0.1) end')
    check("Vehicle_Van_C_1 0 97.5" in (L.eval('blobs_out.carstate') or ""), "a refuel here is told to the other game")
    # T10 audit 2026-10-31: the other player's refuel came while the car was driven (they refuelled, the driver got in
    # first): it was marked applied and dropped, and the driver's state after the drive undid it on both screens
    L.execute(r"""
        DRIVEN = false
        local pd = vehicles.peer_drives
        vehicles.peer_drives = function(c) return (DRIVEN and c == A) or pd(c) end
        DRIVEN = true
        blobs_in.carstate = "Vehicle_Van_C_1 0 100.0 80.0"; vehicles.tick(0.1)
        DURING = A.FuelComponent.CurrentFuel
        A.FuelComponent.CurrentFuel = 90.0   -- the drive used 7.5
        for i = 1, 5 do vehicles.tick(0.1) end
        DRIVEN = false
        blobs_out.carstate = nil
        for i = 1, 30 do vehicles.tick(0.1) end
    """)
    check(L.eval('DURING') == 97.5, "a change from the other game waits while the car is driven (%s)" % L.eval('DURING'))
    check(abs(L.eval('A.FuelComponent.CurrentFuel') - 92.5) < 1e-6,
          "after the drive their refuel of 2.5 is added to what the drive left (%s)" % L.eval('A.FuelComponent.CurrentFuel'))
    check("Vehicle_Van_C_1 0 92.5" in (L.eval('blobs_out.carstate') or ""),
          "and the result goes back to them (%r)" % L.eval('blobs_out.carstate'))


def car_horn_reaches_the_other_game():
    print("car_horn_reaches_the_other_game")
    for role in ("host", "guest"):
        L = lua()
        L.execute(FAKES + r"""
            package.loaded["mirror.link"].peer_age = function() return 0 end
            PARENT = nil
            PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
                           GetAttachParentActor = function() return PARENT end })
            GHOST = obj({})
            package.loaded["mirror.game"] = { player = function() return PLAYER end, world = function() return nil end,
                                              on_world_reset = function() end }
            package.loaded["mirror.ghost"] = { get = function() return GHOST end, set_seated = function() end, generation = function() return 1 end }
            StaticFindObject = function() return obj({}) end
            util = require("mirror.util")
            HOOKS = {}
            util.ensure_hook = function(path, fn) HOOKS[path:match("([%w_]+:[%w_]+)$")] = fn; return true end
            HORNS, NOISES = {}, {}
            local ksl = obj({})
            ksl.IsValid = function(self, a) if a == nil then return true end return a.dead ~= true end
            ksl.PlaySoundAtLocation = function(self, ctx, cue, loc) HORNS[#HORNS + 1] = loc end
            ksl.ReportNoiseEvent = function(self, by, loc, loud, inst, range, tag) NOISES[#NOISES + 1] = { by = by, range = range } end
            util.cdo = function() return ksl end
            function car(name, x)
                return obj({ VehicleColor = 0, Colors = {}, Mesh = { SetMaterial = function() end }, ["EngineOn?"] = true,
                             FuelComponent = { CurrentFuel = 50, MaxFuel = 100, Empty = false },
                             VehicleHealthComponent = { CurrentHealth = 100, MaxHealth = 100 },
                             K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end,
                             K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
                             K2_SetActorLocationAndRotation = function() end, VehicleEngineFX = function() end,
                             IsActorBeingDestroyed = function() return false end,
                             IsA = function() return true end,
                             GetClass = function() return cls("Vehicle_Van_C") end,
                             GetFullName = function() return "Vehicle_Van_C /Game/L.L:P." .. name end,
                             GetFName = function() return { ToString = function() return name end } end })
            end
            A = car("Vehicle_Van_C_1", 100)
            B = car("Vehicle_Van_C_2", 900)
            FindAllOf = function(c) if c == "Vehicle_Van_C" or c == "BP_VehicleMaster_C" then return { A, B } end return {} end
            vehicles = require("mirror.vehicles")
            vehicles.init({ mirror_vehicles = true }, ROLE, { guest_in_world = function() return true end, in_world = function() return true end })
            local tick = vehicles.tick
            -- (each tick is 0.1 s of game time: an event channel writes at most every 0.05 s)
            local real = os.clock; SKEW = 0; os.clock = function() return real() + SKEW end
            vehicles.tick = function(dt) util.new_frame(); SKEW = SKEW + dt; tick(dt) end
            for i = 1, 30 do vehicles.tick(0.1) end
            function P(v) return { get = function() return v end } end
        """.replace("ROLE", '"%s"' % role))
        check(L.eval('HOOKS["BP_VehicleMaster_C:Horn"] ~= nil'), "%s: the game's Horn is hooked" % role)
        L.execute('blobs_out.horn = nil; HOOKS["BP_VehicleMaster_C:Horn"](P(B)); vehicles.tick(0.1)')
        check(L.eval('blobs_out.horn') is None, "%s: a horn of a car I'm not driving is not sent" % role)
        L.execute('PARENT = A; for i = 1, 3 do vehicles.tick(0.1) end; HOOKS["BP_VehicleMaster_C:Horn"](P(A)); vehicles.tick(0.1)')
        check(" 100 0 0" in (L.eval('blobs_out.horn') or ""), "%s: my honk is sent with my car's place" % role)
        L.execute('blobs_in.horn = "x 1 %d 500 0 0"; vehicles.tick(0.1)' % (L.eval('os.time()')))
        check(L.eval('#HORNS') == 1 and L.eval('HORNS[1].X') == 500, "%s: the other player's honk is played where their car is" % role)
        if role == "host":
            check(L.eval('#NOISES') == 1 and L.eval('NOISES[1].by == GHOST') and L.eval('NOISES[1].range') == 8500,
                  "host: the guest's honk is a noise for my zombies (8500, like the game's own horn)")
        else:
            check(L.eval('#NOISES') == 0, "guest: no noise here (my zombies are the host's copies)")
        check("horns sent 1, played 1" in L.eval('vehicles.status()'), "%s: horns counted in the status" % role)
        # SyncFX wreck horns: the guest passes a fresh one on, the host's zombies hear it (at most the game horn's 8500)
        old = os.getcwd()
        d = tempfile.mkdtemp()
        try:
            os.makedirs(os.path.join(d, "ue4ss", "Mods", "SyncFX"))
            os.chdir(d)
            noise = os.path.join("ue4ss", "Mods", "SyncFX", "noise.txt")
            with open(noise, "w") as f:
                f.write("%d 3 10 20 30 6000\n" % (L.eval('os.time()') - 60))
            L.execute('blobs_out.horn = nil; for i = 1, 7 do vehicles.tick(0.1) end')
            check(L.eval('blobs_out.horn') is None, "%s: an old wreck honk is not sent" % role)
            with open(noise, "w") as f:
                f.write("%d 4 10 20 30 6000\n" % L.eval('os.time()'))
            L.execute('for i = 1, 7 do vehicles.tick(0.1) end')
            sent = L.eval('blobs_out.horn') or ""
            if role == "guest":
                check("N 10 20 30 6000" in sent, "guest: a fresh SyncFX wreck honk goes to the host")
                L.execute('blobs_out.horn = nil; for i = 1, 7 do vehicles.tick(0.1) end')
                check(L.eval('blobs_out.horn') is None, "guest: ...once")
            else:
                check("N " not in sent, "host: its own wreck honks stay here (SyncFX made the noise already)")
        finally:
            os.chdir(old)
            shutil.rmtree(d, ignore_errors=True)
        L.execute('NOISES = {}; HORNS = {}; blobs_in.horn = "y 1 %d N 10 20 30 99999"; vehicles.tick(0.1)' % L.eval('os.time()'))
        if role == "host":
            check(L.eval('#NOISES') == 1 and L.eval('NOISES[1].range') == 8500 and L.eval('#HORNS') == 0,
                  "host: the guest's wreck honk is a noise here (capped at 8500), no second horn sound")
        else:
            check(L.eval('#NOISES') == 0, "guest: a wreck honk from the host makes no noise here")


def raiders_can_hit_the_guests_ghost():
    # DBG-20261028-003: raider shots trace "Weapons" (23); a no-PvP ghost answered Visibility only -> they never hit
    print("raiders_can_hit_the_guests_ghost")
    L = lua()
    L.execute(FAKES + r"""
        PVP = false
        package.loaded["mirror.hostrules"] = { get = function(k) if k == "pvp" then return PVP end end }
        RESTORED = 0
        local function mesh(blocks)
            local m = obj({ resp = {} })
            for _, ch in ipairs(blocks) do m.resp[ch] = 2 end
            m.SetCollisionEnabled = function() end
            m.SetCollisionResponseToChannel = function(self, ch, r) m.resp[ch] = r end
            m.GetCollisionResponseToChannel = function(self, ch) return m.resp[ch] or 0 end
            m.SetPhysMaterialOverride = function() FLESH = true end
            return m
        end
        PLAYER = obj({ Mesh = mesh({ 3, 9, 10, 23, 25 }) })
        GHOST = obj({ Mesh = mesh({ 3 }) })
        package.loaded["mirror.game"] = { player = function() return PLAYER end, controller = function() return nil end,
                                          player_hook = function() end, on_world_reset = function() end }
        package.loaded["mirror.ghost"] = { get = function() return GHOST end, is = function(a) return a == GHOST end,
            generation = function() return 1 end,
            restore_mesh = function() RESTORED = RESTORED + 1; GHOST.Mesh.resp = { [3] = 2 } end }
        util = require("mirror.util")
        HOOKS = {}
        util.ensure_hook = function(path, fn) HOOKS[path:match(":(.+)$")] = fn; return true end
        pvp = require("mirror.pvp")
        pvp.init("host", function() return true end)
        pvp.tick(0.1)
        RAIDER = obj({ Dead = false })
        function P(v) return { get = function() return v end } end
        function tick(n) for i = 1, n or 3 do pvp.tick(0.1) end end
    """)
    check(L.eval('HOOKS["Set BB Attack Target"] ~= nil'), "host hooks the raiders' Set BB Attack Target")
    L.execute('RAIDER["Attack Target"] = PLAYER; HOOKS["Set BB Attack Target"](P(RAIDER)); tick()')
    check(L.eval('GHOST.Mesh.resp[23]') is None, "a raider after me (not the ghost) changes nothing")
    L.execute('RAIDER["Attack Target"] = GHOST; HOOKS["Set BB Attack Target"](P(RAIDER)); tick()')
    check(L.eval('GHOST.Mesh.resp[23]') == 2 and L.eval('GHOST.Mesh.resp[9]') == 2,
          "a raider after the guest: the ghost blocks the weapon traces the real player blocks")
    check(L.eval('FLESH') is None, "...without the flesh surface (my own stray bullets hurt nobody)")
    check("raiders after the other player 1, cover on" in L.eval('pvp.status()'), "counted in the status")
    L.execute('RAIDER["Attack Target"] = PLAYER; tick()')
    check(L.eval('RESTORED') == 1 and L.eval('GHOST.Mesh.resp[23]') is None, "the raider turns away: ghost back to no-PvP collision")
    L.execute('RAIDER["Attack Target"] = GHOST; HOOKS["Set BB Attack Target"](P(RAIDER)); RAIDER.Dead = true; tick()')
    check(L.eval('GHOST.Mesh.resp[23]') is None, "a dead raider is no reason")
    L.execute('RAIDER.Dead = false; PVP = true; RESTORED = 0; HOOKS["Set BB Attack Target"](P(RAIDER)); tick(); PVP = false')
    check(L.eval('RESTORED') == 0, "with PvP on the PvP setup owns the mesh (nothing restored under it)")


def harvest_uses_up_nodes_once():
    print("harvest_uses_up_nodes_once")
    sides = {}
    for role in ("host", "guest"):
        L = lua()
        L.execute(FAKES + r"""
            package.loaded["mirror.link"].peer_age = function() return 0 end
            package.loaded["mirror.game"] = { on_world_reset = function(fn) RESET = fn end }
            util = require("mirror.util")
            HOOKS = {}
            util.ensure_hook = function(path, fn) HOOKS[path:match(":(.+)$")] = fn; return true end
            local function node(c, x, hits)
                local n = obj({ MaxHits = hits, ["Salvaged?"] = false, destroyed = false,
                                GetClass = function() return cls(c) end,
                                K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end,
                                ParticleSystem = { SetActive = function(self, on) PS_ON = on end } })
                n.K2_DestroyActor = function() n.destroyed = true end
                return n
            end
            ROCK = node("BP_HarvestableObject_Rocks_C", 100, ...)
            ROCK2 = node("BP_HarvestableObject_Rocks_C", 500, 7)
            SCRAP = node("BP_HarvestableObject_ScrapMetal_C", 300, 0)
            FindAllOf = function(c)
                if c == "BP_HarvestableObject_Rocks_C" then return { ROCK, ROCK2 } end
                if c == "BP_HarvestableObject_ScrapMetal_C" then return { SCRAP } end
                return {}
            end
            function param(v) return { get = function() return v end } end
            harvest = require("mirror.harvest")
            harvest.init({ harvest_sync = true }, ...)
            harvest.tick(0.1)
        """.replace("...", "7" if role == "host" else "6", 1).replace("...", '"%s", function() return TOGETHER end' % role))
        L.execute("TOGETHER = true")
        sides[role] = L
    H, G = sides["host"], sides["guest"]

    def carry(a, b):
        out = a.eval("blobs_out")
        inn = b.eval("blobs_in")
        for k in list(out.keys()):
            inn[k] = out[k]
        b.execute("harvest.tick(0.1)")

    # guest hits its rock (6 hits) 5 times: the host's copy (7) must stay standing with hits left
    for _ in range(5):
        G.execute("ROCK.MaxHits = ROCK.MaxHits - 1; HOOKS.HitHarvestableObject(param(ROCK), param({}), param(1))")
        G.execute("harvest.tick(0.1)")
        carry(G, H)
    check(H.eval("ROCK.MaxHits") == 1 and not H.eval("ROCK.destroyed"), "the other player's hits wear the node down to their hits left")
    G.execute("ROCK.MaxHits = 0; HOOKS.HitHarvestableObject(param(ROCK), param({}), param(1)); harvest.tick(0.1)")
    carry(G, H)
    check(H.eval("ROCK.destroyed"), "the last hit in one game removes the node in the other")
    # host's own hits never finish the guest's copy early (different MaxHits rolls)
    for _ in range(6):
        H.execute("ROCK2.MaxHits = ROCK2.MaxHits - 1; HOOKS.HitHarvestableObject(param(ROCK2), param({}), param(1)); harvest.tick(0.1)")
        carry(H, G)
    check(G.eval("ROCK2.MaxHits") == 1 and not G.eval("ROCK2.destroyed"), "remote hits leave at least one hit")
    G.execute('SCRAP["Salvaged?"] = true; HOOKS.Event_HoldTimer(param(SCRAP)); harvest.tick(0.1)')
    carry(G, H)
    check(H.eval('SCRAP["Salvaged?"]') is True and H.eval("PS_ON") is False, "salvaged scrap is salvaged in both games")
    blob = H.eval("blobs_out.harvested") or ""
    check("Rocks_C@10,0,0" in blob and "ScrapMetal_C@30,0,0" in blob, "the host keeps a list of used-up nodes")
    # a late joiner (fresh guest world) removes the nodes the host already used up
    G.execute('RESET(); ROCK.destroyed = false; SCRAP["Salvaged?"] = false; blobs_in.harvested = ' + repr(blob) + '; harvest.tick(0.1)')
    check(G.eval("ROCK.destroyed") and G.eval('SCRAP["Salvaged?"]') is True, "a late joiner gets the used-up nodes removed")

    # Rocks are foliage until their first hit, which (in the hitting game only) spawns the node actor at the
    # instance and removes the instance. The other game had no actor -> every hit was "not found".
    for L in (H, G):
        L.execute(r"""
            CPATH = "/Game/Levels/L.L:PersistentLevel.InstancedFoliageActor_0.FoliageInstancedStaticMeshComponent_3"
            REMOVED = {}
            INST = { [4] = { X = 900, Y = 0, Z = 0 }, [5] = { X = 2000, Y = 0, Z = 0 }, [9] = { X = 2004, Y = 0, Z = 0 } }
            FOL = obj({ GetFullName = function() return "FoliageInstancedStaticMeshComponent " .. CPATH end })
            FOL.GetInstancesOverlappingSphere = function(self, at, r)
                local out = {}
                for i, l in pairs(INST) do if math.abs(l.X - at.X) < r + 50 then out[#out + 1] = param(i) end end
                return out
            end
            FOL.GetInstanceTransform = function(self, i, t) t.Translation = INST[i]; t.Scale3D = { X = 1, Y = 1, Z = 1 } end
            FOL.RemoveInstance = function(self, i) REMOVED[#REMOVED + 1] = i; INST[i] = nil end
            StaticFindObject = function(p) if p == CPATH then return FOL end end
            function convert(x, hits)
                local n = obj({ MaxHits = hits, destroyed = false, GetClass = function() return cls("BP_HarvestableObject_Rocks_C") end,
                                K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end })
                n.K2_DestroyActor = function() n.destroyed = true end
                for i, l in pairs(INST) do if l.X == x then INST[i] = nil end end
                local fa = FindAllOf
                FindAllOf = function(c) local t = fa(c); if c == "BP_HarvestableObject_Rocks_C" then t[#t + 1] = n end; return t end
                HOOKS.SetMaxHits(param(n))
                HOOKS.HitFoliageRock(param({}), param({}), param({}), param(FOL), param(0), param(1))
                return n
            end
        """)
    H.execute("NEW = convert(2000, 7)")
    H.execute("harvest.tick(0.1)"); carry(H, G)
    for _ in range(3):
        H.execute("NEW.MaxHits = NEW.MaxHits - 1; HOOKS.HitHarvestableObject(param(NEW), param({}), param(1)); harvest.tick(0.1)")
        carry(H, G)
    check(G.eval("#REMOVED") == 0, "hits on a node that is still foliage here leave the foliage standing")
    G.execute("GNEW = convert(2000, 8); harvest.tick(0.1)")
    check(G.eval("GNEW.MaxHits") == 4, "its first hit here converts it with the hits the host has left (%s)" % G.eval("GNEW.MaxHits"))
    H.execute("NEW.MaxHits = 0; HOOKS.HitHarvestableObject(param(NEW), param({}), param(1)); harvest.tick(0.1)")
    carry(H, G)
    check(G.eval("GNEW.destroyed"), "used up in the host's game: the converted node goes here too")
    # a node the guest never touched: used up on the host -> the guest's foliage instance (not its neighbour) goes
    H.execute("N2 = convert(900, 7); harvest.tick(0.1)"); carry(H, G)
    H.execute("N2.MaxHits = 0; HOOKS.HitHarvestableObject(param(N2), param({}), param(1)); harvest.tick(0.1)")
    carry(H, G)
    check(list(G.eval("REMOVED").values()) == [4], "used up there, still foliage here: that foliage instance is removed (%s)"
          % list(G.eval("REMOVED").values()))
    blob = H.eval("blobs_out.harvested") or ""
    check(("Rocks_C@90,0,0 " + "/Game/Levels/L.L:PersistentLevel.InstancedFoliageActor_0.FoliageInstancedStaticMeshComponent_3") in blob,
          "the used-up list names the foliage component for late joiners")
    G.execute('RESET(); REMOVED = {}; INST[4] = { X = 900, Y = 0, Z = 0 }; blobs_in.harvested = ' + repr(blob) + '; harvest.tick(0.1)')
    check(list(G.eval("REMOVED").values()) == [4], "a late joiner's foliage instance of a used-up node is removed")
    # the "F" (which foliage component) was lost - e.g. sent while the link reconnected: found by searching
    G.execute('REMOVED = {}; INST[7] = { X = 3000, Y = 0, Z = 0 }; INST[8] = { X = 3100, Y = 0, Z = 0 }'
              '; FindAllOf_was = FindAllOf; FindAllOf = function(c) if c == "FoliageInstancedStaticMeshComponent" then return { FOL } end; return FindAllOf_was(c) end')
    H.execute("N3 = convert(3000, 7); harvest.tick(0.1)")
    H.execute("N3.MaxHits = 0; HOOKS.HitHarvestableObject(param(N3), param({}), param(1)); harvest.tick(0.1)")
    G.execute('StaticFindObject = function() return nil end')   # the named component can't be used
    carry(H, G)
    got = list(G.eval("REMOVED").values())
    check(7 in got and 8 not in got, "without the component name the right foliage instance is still removed (%s)" % got)


def zombie_spawn_pins_hold_or_refuse():
    # DBG-20261027-016 came back on a hand-back (2026-10-29): a pin that didn't take, or a list that couldn't be
    # read, let the zombie BP load a random soft look inside our SpawnActor. Only a pin that reads back may spawn.
    print("zombie_spawn_pins_hold_or_refuse")
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.game"] = { player = function() return nil end, world = function() return nil end,
                                          on_world_reset = function() end, keybind = function() end }
        package.loaded["mirror.ghost"] = { get = function() return nil end, is = function() return false end }
        package.loaded["mirror.loader"] = { want = function() end }
        ASSETS = {}
        StaticFindObject = function(p) return ASSETS[p] end
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        DROP = false
        util.cdo = function() return {
            Conv_ObjectToSoftObjectReference = function(self, o) return { soft = o } end,
            Conv_SoftObjectReferenceToObject = function(self, s) return type(s) == "table" and s.soft or nil end } end
        zombies = require("mirror.zombies")
        MZC = cls("BP_MasterZombie_C")
        ASSETS["/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"] = MZC
        MESH, MAT = obj({}), obj({})
        function arr(t)
            local a = { GetArrayNum = function() return #t end }
            return setmetatable(a, { __index = function(_, i) return t[i] end,
                                     __newindex = function(_, i, v) if not DROP then t[i] = v end end }), t
        end
        function cdo(zombie_family, lists)
            local c = obj({ IsA = function(self, k) return zombie_family and k == MZC end,
                            GetFName = function() return { ToString = function() return "Default__BP_Z_C" end } end,
                            Mesh = { GetSkinnedAsset = function() return MESH end, GetMaterial = function() return MAT end } })
            for k, v in pairs(lists) do c[k] = v end
            return c
        end
    """)
    # a pin that holds: every entry points at the loaded look while spawning, the lists come back afterwards
    L.execute('M, MT = arr({ "softA", "softB" }); T, TT = arr({ "softC" }); '
              'C = cdo(true, { Meshes_Soft = M, Materials_Soft = T }); UNPIN = zombies._look.pin(C, MESH, MAT)')
    check(L.eval('UNPIN ~= nil and MT[1].soft == MESH and MT[2].soft == MESH and TT[1].soft == MAT'),
          "a pin that reads back lets the zombie spawn, every soft entry on the loaded look")
    L.execute('UNPIN()')
    check(L.eval('MT[1] == "softA" and MT[2] == "softB" and TT[1] == "softC"'), "and the class's own lists come back")
    # UE4SS dropped the write: the random (maybe still streaming) look would load inside our SpawnActor
    L.execute('DROP = true; M, MT = arr({ "softA" }); C = cdo(true, { Meshes_Soft = M, Materials_Soft = arr({}) }); '
              'R = zombies._look.pin(C, MESH, MAT); DROP = false')
    check(L.eval('R') is None, "a pin that didn't take refuses the spawn")
    # a zombie whose list can't be read: refused, never taken for "no list"
    L.execute('C = cdo(true, {}); C.Meshes_Soft = setmetatable({}, { __index = function() error("no read") end }); '
              'R = zombies._look.pin(C, MESH, MAT)')
    check(L.eval('R') is None, "a zombie's unreadable soft list refuses the spawn")
    # not the master zombie's family (no soft looks to roll): spawns as before
    L.execute('C = cdo(false, {}); R = zombies._look.pin(C, MESH, MAT)')
    check(L.eval('type(R)') == "function", "a class outside the zombie family without soft lists still spawns")
    L.execute('C = cdo(true, { Meshes_Soft = arr({}), Materials_Soft = arr({}) }); R = zombies._look.pin(C, MESH, MAT)')
    check(L.eval('type(R)') == "function", "empty soft lists need no pin")


def hounds_bark_when_they_come_for_you():
    """User 2026-10-28: zombie dogs bark while they chase you, stop the moment they die, and bark once when they
    first get near (the game has no bark sound; SurrounSyncSounds.pak brings them)."""
    print("hounds_bark_when_they_come_for_you")
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.zombies"] = { dead_of = function(z) return z.dead == true end }
        TICKS = {}
        PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end })
        package.loaded["mirror.game"] = { player = function() return PLAYER end, world = function() return {} end,
            on_tick = function(f) TICKS[#TICKS + 1] = f end, on_world_reset = function() end }
        LOADED = true
        -- (UE 5.6 has no SoundBase.Duration to read: the mod can't see a sound's length; each plays for its WAV's length)
        LEN = { DogBark1 = 0.51, DogBark2 = 0.76, DogGrowl = 1.71, DogBarking = 2.9 }
        StaticFindObject = function(p) if p:find("SurrounSyncSounds") and not LOADED then return nil end return obj({ p = p }) end
        T = 0
        function hound(x) local d = obj({ x = x, dead = false, speed = 0 })
            d.K2_GetActorLocation = function() return { X = d.x, Y = 0, Z = 0 } end
            d.K2_GetRootComponent = function() return obj({}) end; d.IsActorBeingDestroyed = function() return false end; return d end
        H = hound(3000)
        IN = { H }
        PLAYS = {}
        local k = obj({})
        k.SphereOverlapActors = function(self, w, loc, r, t, cls, ign, out)
            for _, d in ipairs(IN) do if math.abs(d.x - loc.X) <= r then out[#out + 1] = d end end end
        local gs = obj({})
        -- (a sound plays for its length at its pitch, then the component destroys itself: IsPlaying/Stop on it
        -- afterwards are calls on a dead object - counted as LATE)
        LATE = 0
        gs.SpawnSoundAttached = function(self, snd, root, _, _, _, _, _, _, pitch)
            local c = obj({ on = true, p = snd.p, t_end = T + LEN[snd.p:match("([%w_]+)$")] / pitch })
            c.IsPlaying = function() if T >= c.t_end then LATE = LATE + 1 end return c.on end
            c.Stop = function() if T >= c.t_end then LATE = LATE + 1 end c.on = false; c.stopped = true end
            PLAYS[#PLAYS + 1] = c
            return c
        end
        util = require("mirror.util")
        util.cdo = function(p) return p:find("GameplayStatics") and gs or k end
        dg = require("mirror.dogs")
        dg.init({})
        function run(s, step) for i = 1, math.floor(s * 10) do T = T + 0.1; H.x = H.x + (step or 0); for _, f in ipairs(TICKS) do f(0.1) end
            for _, c in ipairs(PLAYS) do if c.on and T >= c.t_end then c.on = false end end end end
    """)
    L.execute('run(10)')
    check(L.eval('#PLAYS') == 0, "a hound standing 30 m off: quiet")
    L.execute('run(45, -5)')   # walking up at 0.5 m/s (not a chase) from 30 m to 7.5 m
    check(L.eval('#PLAYS') >= 1 and "DogBark" in L.eval('PLAYS[1].p'), "it comes within 10 m: one bark")
    L.execute('N0 = #PLAYS; run(1.5, -20); H.x = 400; run(6.5)')   # 2 m/s at the player, then right on them
    n = L.eval('#PLAYS - N0')
    check(3 <= n <= 30, "chasing me: bark after bark (%d)" % n)
    check(all(not (L.eval('PLAYS[%d].on' % i) and L.eval('PLAYS[%d].on' % (i + 1))) for i in range(1, L.eval('#PLAYS'))),
          "...one at a time")
    L.execute('N3 = #PLAYS; for i = 1, 40 do if #PLAYS > N3 then break end run(0.1) end; LAST = PLAYS[#PLAYS]; '
              'H.dead = true; IN = {}; run(0.3)')
    check(L.eval('#PLAYS > N3') and L.eval('LAST.stopped') is True,
          "it dies mid-bark: the bark stops at once (dead hounds drop out of the query too)")
    check(L.eval('LATE') == 0, "never a call on a bark whose sound already ended (its component is gone then)")
    L.execute('N1 = #PLAYS; run(5)')
    check(L.eval('#PLAYS') == L.eval('N1'), "...and it never barks again")
    check("1 near bark(s)" in L.eval('dg.status()'), "counted in the status (%s)" % L.eval('dg.status()'))
    check("1 seen" in L.eval('dg.status()'), "the hound itself is counted as seen (%s)" % L.eval('dg.status()'))
    # a short near bark (0.5-0.8 s) has ended and freed its component; the hound dies 0.3 s later
    L.execute('H = hound(1500); IN = { H }; N4 = #PLAYS; for i = 1, 200 do if #PLAYS > N4 then break end run(0.1, -5) end; '
              'B = PLAYS[#PLAYS]; for i = 1, 30 do if not B.on then break end run(0.1) end; run(0.3); '
              'H.dead = true; IN = {}; run(0.3)')
    check(L.eval('#PLAYS > N4') and L.eval('B.on') is False and L.eval('LATE') == 0,
          "a hound dying after its short bark ended: no call on the freed component (%s calls)" % L.eval('LATE'))
    # user 2026-10-30: other players cannot hear dog barks - a hound chasing the friend 20 m from me barks on my
    # game too (judged by my own player alone it was "not closing in" and quiet)
    L.execute('GHOST_AT = { X = 2000, Y = 0, Z = 0 }; '
              'package.loaded["mirror.peers"] = { each = function(name, fn) if name == "mirror.ghost" then '
              'fn({ location = function() return GHOST_AT end }) end end }; '
              'H = hound(1200); IN = { H }; run(1.5); N5 = #PLAYS; '
              # (running from 12 m off me towards the other player: away from me, so only they can be its target)
              'for i = 1, 30 do T = T + 0.1; H.x = math.min(1900, H.x + 30); for _, f in ipairs(TICKS) do f(0.1) end '
              'for _, c in ipairs(PLAYS) do if c.on and T >= c.t_end then c.on = false end end end')
    n = L.eval('#PLAYS - N5')
    # (one at least: a random 2.9 s "fit" can fill the whole run; judged by my player alone it is 0)
    check(n >= 1, "a hound chasing the other player near me barks on my game (%d)" % n)
    L.execute('LOADED = false; util.find = function(p) return StaticFindObject(p) end; H = hound(500); IN = { H }; N2 = #PLAYS; run(5, -20)')
    check(L.eval('#PLAYS') == L.eval('N2'), "no pak: quiet, nothing loaded from Lua")


def human_copies_hold_the_hosts_weapon():
    """User 2026-10-28: raiders' weapons are invisible on the guest - the AI start-up that arms them needs the AI
    controller a copy never gets. The copy is armed with the host's weapon class through the game's Equip Holdable."""
    print("human_copies_hold_the_hosts_weapon")
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.game"] = { player = function() return nil end, world = function() return nil end,
                                          on_world_reset = function() end, keybind = function() end }
        package.loaded["mirror.ghost"] = { get = function() return nil end, is = function() return false end }
        package.loaded["mirror.loader"] = { want = function() end }
        GUN = obj({ GetFullName = function() return "BlueprintGeneratedClass /Game/AI/W/BP_AIWeapon_M4.BP_AIWeapon_M4_C" end })
        StaticFindObject = function(p) if p == "/Game/AI/W/BP_AIWeapon_M4.BP_AIWeapon_M4_C" then return GUN end end
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        zombies = require("mirror.zombies")
        EQUIPS, KILLED = {}, 0
        local held = obj({ K2_DestroyActor = function() KILLED = KILLED + 1 end, GetClass = function() return
            obj({ GetFullName = function() return "BlueprintGeneratedClass /Game/AI/W/BP_AIWeapon_Axe.BP_AIWeapon_Axe_C" end }) end })
        AI = obj({ ["Holdable Actor"] = held, ["Attached Holdables"] = { GetArrayNum = function() return 0 end, Empty = function() EMPTIED = true end } })
        AI["Equip Holdable"] = function(self, c) EQUIPS[#EQUIPS + 1] = c end
        Z = obj({ BP_AIComponent = AI })
        C = { z = Z, fam = "human" }
    """)
    L.execute('zombies.arm_copy(C, "/Game/AI/W/BP_AIWeapon_M4.BP_AIWeapon_M4_C")')
    check(L.eval('#EQUIPS') == 1 and L.eval('EQUIPS[1] == GUN'), "the copy equips the host's weapon class (the game's Equip Holdable)")
    check(L.eval('KILLED') == 1 and L.eval('EMPTIED') is True, "...after its old one is taken away")
    L.execute('EQUIPS = {}; zombies.arm_copy(C, "/Game/AI/W/BP_AIWeapon_Nope.BP_AIWeapon_Nope_C")')
    check(L.eval('#EQUIPS') == 0, "a weapon class not loaded here is never loaded from Lua (empty hands)")
    L.execute('EQUIPS = {}; zombies.arm_copy(C, "-")')
    check(L.eval('#EQUIPS') == 0 and L.eval('C.weapon') == "-", "the host's empty hands: nothing in the copy's")


def zombie_copies_take_the_hosts_look():
    print("zombie_copies_take_the_hosts_look")
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.game"] = { player = function() return nil end, world = function() return nil end,
                                          on_world_reset = function() end, keybind = function() end }
        package.loaded["mirror.ghost"] = { get = function() return nil end, is = function() return false end }
        package.loaded["mirror.loader"] = { want = function() end }
        ASSETS = {}
        StaticFindObject = function(p) return ASSETS[p] end
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        util.cdo = function() return { GetConsoleVariableBoolValue = function() return false end } end
        zombies = require("mirror.zombies")
        local function asset(kind, p) local a = obj({ GetFullName = function() return kind .. " " .. p end,
                                                      GetClass = function() return cls(kind) end }); ASSETS[p] = a; return a end
        MESH, MAT, OTHER_MAT = asset("SkeletalMesh", "/Game/Z/SK_A.SK_A"), asset("Material", "/Game/Z/M_A.M_A"),
                               asset("Material", "/Game/Z/M_B.M_B")
        function zombie(cname)
            local z
            local mesh = { hidden = {}, asset = MESH, mat = OTHER_MAT }
            mesh.IsBoneHiddenByName = function(self, b) return mesh.hidden[b] == true end
            mesh.HideBoneByName = function(self, b) mesh.hidden[b] = true end
            mesh.UnHideBoneByName = function(self, b) mesh.hidden[b] = nil end
            mesh.GetSkinnedAsset = function() return mesh.asset end
            mesh.SetSkinnedAssetAndUpdate = function(self, m) mesh.asset = m end
            mesh.GetMaterial = function() return mesh.mat end
            mesh.SetMaterial = function(self, i, m) mesh.mat = m end
            z = obj({ Mesh = mesh, DamageComponent = {}, called = {},
                      GetFName = function() return { ToString = function() return "Z_" .. tostring(z) end } end,
                      GetClass = function() return cls(cname or "BP_Zombie_Roamer_C") end,
                      Event_EyesCallback = function(self, off)
                          local parent = mesh.mat
                          mesh.mat = obj({ Parent = parent, GetClass = function() return cls("MaterialInstanceDynamic") end })
                      end })
            for _, a in ipairs({ "Sprinter", "UltraRadiated", "Acidic", "Screamer", "Grenadier", "ToughenedCrawler" }) do
                z["Archetype_" .. a] = function(self) self.called[#self.called + 1] = a end
            end
            return z
        end
        E = { mesh = "/Game/Z/SK_A.SK_A", mat = "/Game/Z/M_A.M_A" }
    """)
    # Host side: a screamer's hidden jaw and arms and its glowing eyes are read.
    L.execute('H = zombie(); H.Mesh.hidden = { Jaw = true, lowerarm_r = true, lowerarm_l = true }; '
              'H.Mesh.mat = obj({ Parent = MAT, GetClass = function() return cls("MaterialInstanceDynamic") end })')
    check(L.eval('zombies._look.arch_of(H, "nohook")') == 4, "a screamer is recognised without the hook")
    check(L.eval('zombies._look.bones_of(H)') == 7, "hidden jaw and forearms read as a bone mask")
    # Guest side: the copy rolled its own crawler legs, a plain material and no archetype.
    # This game never ran a Screamer itself: calling it would load its assets from our Lua (guest freeze).
    L.execute('N = zombie(); NCOPY = { z = N, fam = "zombie" }; zombies._look.sync(2, NCOPY, E, { arch = 4, bones = 0, eyes = 0 })')
    check(L.eval('#N.called') == 0, "an archetype this game hasn't run itself is not called on a copy")
    L.execute('local G = zombie(); zombies._look.arch_hooks[4]({ get = function() return G end })')
    L.execute('C = zombie(); C.Mesh.hidden = { calf_l = true, Foot_R = true }; COPY = { z = C, fam = "zombie" }; '
              'zombies._look.sync(1, COPY, E, { arch = 4, bones = 7, eyes = 1 })')
    check(L.eval('C.called[1]') == "Screamer" and L.eval('#C.called') == 1, "once the game ran it itself, the copy runs the host's archetype once")
    check(L.eval('zombies._look.arch_hooks.calling') is False, "and our own call doesn't count as the game's")
    check(L.eval('zombies._look.bones_of(C)') == 7, "the copy's bones match the host's")
    check(L.eval('C.Mesh.mat.Parent == MAT'), "the host's material is put back, with the eye glow on top")
    L.execute('zombies._look.sync(1, COPY, E, { arch = 4, bones = 7, eyes = 1 })')
    check(L.eval('#C.called') == 1, "the archetype is not applied twice")
    L.execute('zombies._look.sync(1, COPY, E, { arch = 4, bones = 7, eyes = 0 })')
    check(L.eval('C.Mesh.mat == MAT'), "eyes the host's doesn't show are turned off")
    # Blood moon: a copy made after it rose (no red eyes of its own) takes the host zombie's red eyes, once.
    L.execute('MOONS = {}; M = zombie(); M.Event_BloodMoon = function(self, on) MOONS[#MOONS + 1] = on; '
              'zombies._look.moon_hook({ get = function() return self end }, { get = function() return on end }) end; '
              'MCOPY = { z = M, fam = "zombie" }; zombies._look.sync(3, MCOPY, E, { arch = 0, bones = 0, eyes = 2 }); '
              'zombies._look.sync(3, MCOPY, E, { arch = 0, bones = 0, eyes = 2 })')
    check(L.eval('#MOONS') == 1 and L.eval('MOONS[1]') is True, "a host zombie's blood moon eyes reach a later copy, once")
    L.execute('zombies._look.sync(3, MCOPY, E, { arch = 0, bones = 0, eyes = 1 })')
    check(L.eval('#MOONS') == 2 and L.eval('MOONS[2]') is False, "and end on it when the host's end")
    L.execute('zombies._look.sync(3, MCOPY, E, { arch = 0, bones = 0, eyes = 1 }); '
              'P = zombie(); P.Event_BloodMoon = M.Event_BloodMoon; zombies._look.sync(4, { z = P, fam = "zombie" }, E, { arch = 0, bones = 0, eyes = 1 })')
    check(L.eval('#MOONS') == 2, "no blood moon call on copies that never had one")


def copy_deaths_and_removals_wait_for_the_animation_gate():
    # Guest froze inside a copy's Death() called from our Lua (report 2026-10-30 15:36) and 3 s after dying, while
    # the copies the host stopped sending were removed (16:11): both wait for the mesh's animation task, whose worker
    # waited for our Lua lock. They now run 2 frames after animation went to the game thread, never in the call.
    print("copy_deaths_and_removals_wait_for_the_animation_gate")
    L = lua()
    L.execute(FAKES + r"""
        WORLD = obj({})
        package.loaded["mirror.game"] = { player = function() return nil end, world = function() return WORLD end,
                                          controller = function() return nil end,
                                          on_world_reset = function() end, keybind = function() end }
        package.loaded["mirror.ghost"] = { get = function() return nil end, is = function() return false end }
        package.loaded["mirror.loader"] = { want = function() end }
        package.loaded["mirror.invdiag"] = { summary = function() return "-" end }
        CV = { ["a.ParallelAnimUpdate"] = 1, ["a.ParallelAnimEvaluation"] = 1 }
        KSL = obj({ GetConsoleVariableIntValue = function(self, n) return CV[n] end,
                    ExecuteConsoleCommand = function(self, w, cmd)
                        local n, v = cmd:match("^(%S+) (%S+)$"); CV[n] = tonumber(v) end })
        StaticFindObject = function() return nil end
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        util.cdo = function(p) if p:find("KismetSystemLibrary", 1, true) then return KSL end
                               return { GetConsoleVariableBoolValue = function() return false end } end
        zombies = require("mirror.zombies")
        animgate = require("mirror.animgate")
        zombies._test.setup({ zombies = { enabled = true, send_hz = 15, despawn_after = 3.0 } }, "guest")
        function zombie()
            local z = obj({ DEATHS = 0, DESTROYED = 0, Mesh = {}, BP_JigMultiplayer = {} })
            z.Death = function(self) self.DEATHS = self.DEATHS + 1 end
            z.K2_DestroyActor = function(self) self.DESTROYED = self.DESTROYED + 1 end
            z.SetActorHiddenInGame = function(self, h) self.HIDDEN = h end
            z.SetActorEnableCollision = function() end
            return z
        end
        T = 0; os.clock = function() return T end
        function frame(n) for i = 1, n or 1 do T = T + 0.016; util.new_frame(); zombies._test.gate_tick(0.016) end end
        A = zombie(); zombies._test.copy(7, A)
        blobs_in.zombies = "H\nT 1.0\nZ 7 0 0 0 100 0 0 0 0 0 0 0 0 1\n"
        zombies._test.read()
        R1 = { A.DEATHS, CV["a.ParallelAnimUpdate"], CV["a.ParallelAnimEvaluation"] }
        frame(1); R2 = A.DEATHS
        frame(1); R3 = A.DEATHS
        frame(1); R4 = A.DEATHS
        frame(80); R5 = { CV["a.ParallelAnimUpdate"], CV["a.ParallelAnimEvaluation"], animgate.held("load") }
    """)
    r1 = L.eval('R1')
    check(r1[1] == 0 and r1[2] == 0 and r1[3] == 0,
          "a copy the host says died isn't killed inside the snapshot call; animation goes to the game thread (%s)" % list(r1.values()))
    check(L.eval('R2') == 0, "not yet the next frame (a task started before the switch may still run)")
    check(L.eval('R3') == 1 and L.eval('R4') == 1, "its Death() runs 2 frames later, once")
    r5 = L.eval('R5')
    check(r5[1] == 1 and r5[2] == 1, "the engine's own values come back a second after the last need (%s)" % list(r5.values()))
    # removing a copy (gone from the host's snapshots): hidden at once, destroyed once the gate is ready
    L.execute('''
        B = zombie(); zombies._test.copy(8, B)
        zombies._test.remove(8)
        R6 = { B.DESTROYED, B.HIDDEN == true, zombies._test.copies()[8] == nil, zombies.is_copy(B) }
        frame(1); R7 = B.DESTROYED
        frame(2); R8 = B.DESTROYED
        frame(80); R9 = CV["a.ParallelAnimUpdate"]
    ''')
    r6 = L.eval('R6')
    check(r6[1] == 0 and r6[2] and r6[3], "a removed copy is hidden and dropped at once, not destroyed in the call")
    check(r6[4], "and still counts as a copy until it's destroyed (not swept as my own zombie)")
    check(L.eval('R7') == 0 and L.eval('R8') == 1, "it's destroyed once animation has run on the game thread for 2 frames")
    check(L.eval('R9') == 1, "the cvars come back afterwards")
    # a load holding the gate keeps animation on the game thread when the zombies let go
    L.execute('''
        animgate.hold("load")
        C = zombie(); zombies._test.copy(9, C); zombies._test.remove(9); frame(3); frame(80)
        R10 = { C.DESTROYED, CV["a.ParallelAnimUpdate"] }
        animgate.release("load"); R11 = CV["a.ParallelAnimUpdate"]
    ''')
    r10 = L.eval('R10')
    check(r10[1] == 1 and r10[2] == 0, "while a load holds the gate the zombies letting go doesn't switch animation back")
    check(L.eval('R11') == 1, "the load's release does")
    # a host hit that kills a copy runs its Death inside ApplyDamage: it waits for the gate; one that doesn't kill doesn't
    # (kit 2026-10-29: the host's kills killed 15 copies through these replays)
    L.execute('''
        frame(80)
        HITS = {}
        GS = { ApplyDamage = function(self, z, amt) HITS[#HITS + 1] = amt end }
        local cdo = util.cdo
        util.cdo = function(p) if p:find("GameplayStatics", 1, true) then return GS end return cdo(p) end
        H = zombie(); H.DamageComponent = { CurrentHealth = 30 }; zombies._test.copy(11, H)
        zombies._test.zhit("11 10 -"); R13 = #HITS
        zombies._test.zhit("11 40 -"); R14 = #HITS
        frame(1); R15 = #HITS
        frame(2); R16 = #HITS
    ''')
    check(L.eval('R13') == 1, "a host hit that doesn't kill is replayed at once")
    check(L.eval('R14') == 1 and L.eval('R15') == 1 and L.eval('R16') == 2,
          "one that kills waits until animation has run on the game thread for 2 frames")
    # no world: the gate can't close - calls run at once as before (and nothing waits forever)
    L.execute('WORLD = nil; D = zombie(); zombies._test.copy(10, D); zombies._test.remove(10); R12 = D.DESTROYED')
    check(L.eval('R12') == 1, "without a world the removal runs at once, as before the gate")


def animgate_runs_waiting_calls_once_animation_is_on_the_game_thread():
    # the shared gate for the ghost, stray bodies, cars and the Realm's main-menu exit (animgate.lua)
    print("animgate_runs_waiting_calls_once_animation_is_on_the_game_thread")
    L = lua()
    L.execute(FAKES + r"""
        WORLD = obj({}); TICK, RESET = nil, nil
        package.loaded["mirror.game"] = { world = function() return WORLD end,
                                          on_tick = function(f) TICK = f end, on_world_reset = function(f) RESET = f end }
        CV = { ["a.ParallelAnimUpdate"] = 1, ["a.ParallelAnimEvaluation"] = 1 }
        KSL = obj({ GetConsoleVariableIntValue = function(self, n) return CV[n] end,
                    ExecuteConsoleCommand = function(self, w, cmd) local n, v = cmd:match("^(%S+) (%S+)$"); CV[n] = tonumber(v) end })
        util = require("mirror.util")
        util.cdo = function() return KSL end
        T = 0; os.clock = function() return T end
        gate = require("mirror.animgate")
        gate.init()
        function frame(n) for i = 1, n or 1 do T = T + 0.016; util.new_frame(); TICK(0.016) end end
        function actor() local a = obj({ gone = 0 }); a.K2_DestroyActor = function(self) self.gone = self.gone + 1 end
                         a.SetActorHiddenInGame = function(self, h) self.hidden = h end
                         a.SetActorEnableCollision = function(self, on) self.collides = on end; return a end
        RAN = 0
        R1 = gate.later(function() RAN = RAN + 1 end, "test")
        A = actor(); gate.destroy(A, "test")
        R2 = { RAN, A.gone, A.hidden == true, A.collides == false, gate.pending(A), CV["a.ParallelAnimUpdate"] }
        frame(1); R3 = { RAN, A.gone }
        frame(1); R4 = { RAN, A.gone, gate.pending(A) }
        R5 = gate.safe_now()
        B = actor(); gate.destroy(B); R6 = B.gone
        frame(70); R7 = { CV["a.ParallelAnimUpdate"], CV["a.ParallelAnimEvaluation"] }
        R8 = gate.safe_now(); frame(1); R9 = gate.safe_now(); frame(1); R10 = gate.safe_now()
        C = actor(); gate.destroy(C); frame(70)
        D = actor(); frame(70); gate.destroy(D); RESET(); frame(3)
        R11 = { C.gone, D.gone, gate.pending(D), CV["a.ParallelAnimUpdate"] }
    """)
    check(L.eval('R1') is False, "a call that waits for animation isn't run while animation tasks may be running")
    r2 = L.eval('R2')
    check(r2[1] == 0 and r2[2] == 0 and r2[3] and r2[4] and r2[5] and r2[6] == 0,
          "an actor to destroy is hidden, without collision, pending; animation goes to the game thread")
    check(list(L.eval('R3').values()) == [0, 0], "not yet the next frame")
    r4 = L.eval('R4')
    check(r4[1] == 1 and r4[2] == 1 and not r4[3], "2 frames later both ran once and nothing is pending")
    check(L.eval('R5') is True and L.eval('R6') == 1, "while the gate is open such calls run at once")
    check(list(L.eval('R7').values()) == [1, 1], "a second after the last need the engine's values come back")
    check(L.eval('R8') is False and L.eval('R9') is False and L.eval('R10') is True,
          "a caller that asks every frame gets its go 2 frames after the first ask")
    r11 = L.eval('R11')
    check(r11[1] == 1, "a destroy started earlier finishes")
    check(r11[2] == 0 and not r11[3] and r11[4] == 1,
          "a world reset drops the old world's waiting calls (never touched again) and gives animation back")
    # hardening: a hold nobody renews lapses; a restore without a world comes later; a save flushes waiting destroys
    L.execute('''
        gate.hold("someone"); frame(2); R12 = { CV["a.ParallelAnimUpdate"], gate.held("someone") }
        frame(400); R13 = { CV["a.ParallelAnimUpdate"], gate.held("someone") }
        gate.hold("load"); frame(400); R14 = { CV["a.ParallelAnimUpdate"], gate.held("load") }
        local W = WORLD; WORLD = nil; gate.release("load"); R15 = CV["a.ParallelAnimUpdate"]
        WORLD = W; frame(1); R16 = CV["a.ParallelAnimUpdate"]
        E = actor(); gate.destroy(E); R17 = gate.flush(); R18 = { E.gone, gate.pending(E) }; frame(80); R19 = E.gone
    ''')
    check(list(L.eval('R12').values()) == [0, True], "a hold closes the gate")
    check(list(L.eval('R13').values()) == [1, False], "one not renewed for 5 s lapses: animation back on its threads")
    check(list(L.eval('R14').values()) == [0, True], "a load's hold lasts a whole load (6 s here)")
    check(L.eval('R15') == 0 and L.eval('R16') == 1, "released without a world: the engine's values come back once there is one")
    check(L.eval('R17') == 1 and list(L.eval('R18').values()) == [1, False] and L.eval('R19') == 1,
          "a save flushes a waiting destroy at once, and it isn't destroyed twice")


def zombie_archetype_effects_reach_copies():
    print("zombie_archetype_effects_reach_copies")
    def side(role):
        L = lua()
        L.execute(FAKES + r"""
            NOW = 0; os.clock = function() return NOW end
            SENT, INBOX = {}, {}
            package.loaded["mirror.events"] = evmock { new = function(name)
                return { send = function(self, p) SENT[#SENT + 1] = p end,
                         pump = function(self, fn) local q = INBOX; INBOX = {}; for _, p in ipairs(q) do fn(p) end end } end }
            PLAYER = obj({})
            package.loaded["mirror.game"] = { player = function() return PLAYER end }
            util = require("mirror.util")
            HOOKS = {}
            util.ensure_hook = function(p, fn) HOOKS[p:match(":(.+)$")] = fn; return true end
            LOADED = {}
            StaticFindObject = function(p) return LOADED[p] end
            CALLS = {}
            local function rec(name) return function(self, ...) CALLS[#CALLS + 1] = { name, ... }; return obj({}) end end
            CDO = { SpawnSystemAttached = rec("spit"), SpawnEmitterAttached = rec("mist"), SpawnEmitterAtLocation = rec("emitter"),
                    PlaySoundAtLocation = rec("sound"), SpawnDecalAtLocation = rec("decal") }
            util.cdo = function() return CDO end
            zfx = require("mirror.zfx")
            for k, p in pairs(zfx.A) do LOADED[p] = obj({ name = k }) end
            function zombie(x) return obj({ Mesh = { K2_GetComponentLocation = function() return { X = x, Y = 0, Z = 0 } end },
                                            K2_GetRootComponent = function() return obj({}) end, SD_AIComponent = {} }) end
            HOST_Z = zombie(500); ARCH = 2
            COPIES = {}
            ZOMBIES = { host_id_of = function(z) return 7 end, copy = function(id) return COPIES[id] end,
                        _look = { arch_of = function() return ARCH end } }
            zfx.init(ZOMBIES, ROLE_)
        """.replace("ROLE_", '"%s"' % role))
        return L
    H, G = side("host"), side("guest")
    # copy looks: acidic drool at the mouth, radiated mist, sprinter run - once each, no archetype call
    G.execute('C3 = { z = zombie(0) }; zfx.looks(C3, 3); zfx.looks(C3, 3); C2 = { z = zombie(0) }; zfx.looks(C2, 2); '
              'C1 = { z = zombie(0) }; zfx.looks(C1, 1)')
    kinds = [G.eval('CALLS[%d][1]' % i) for i in range(1, G.eval('#CALLS') + 1)]
    check(kinds == ["spit", "mist"], "an acidic copy drools and a radiated one gets the mist, once (%s)" % kinds)
    check(G.eval('C3.z.BloodSpitFX ~= nil') and G.eval('C2.z.ZombieMist ~= nil'), "kept where the game keeps them")
    check(G.eval('C1.z.SD_AIComponent.MovementBlendspace.name') == "run", "a sprinter copy runs like one")
    # death blasts: the host's radiated zombie (not a headshot) and grenadier are sent; a headshot isn't
    H.execute('zfx.tick(2.1); HOOKS.Event_SpecialDeath({ get = function() return HOST_Z end }, { get = function() return true end })')
    check(H.eval('#SENT') == 0, "no radiated blast after a headshot")
    H.execute('HOOKS.Event_SpecialDeath({ get = function() return HOST_Z end }, { get = function() return false end }); '
              'ARCH = 0; HOOKS.Event_SpecialDeath({ get = function() return HOST_Z end }, { get = function() return false end }); '
              'HOOKS.GrenadierDeath({ get = function() return HOST_Z end })')
    sent = [H.eval('SENT[%d]' % i) for i in range(1, H.eval('#SENT') + 1)]
    check(sent == ["R 7 500 0 0", "G 7 500 0 0"], "radiated and grenadier blasts are sent (%s)" % sent)
    G.execute('CALLS = {}; COPIES[7] = { z = zombie(510) }; INBOX = { "G 7 500 0 0", "R 7 500 0 0" }; zfx.tick(0.1); NOW = 0.2; zfx.tick(0.1)')
    kinds = [G.eval('CALLS[%d][1]' % i) for i in range(1, G.eval('#CALLS') + 1)]
    check(kinds == ["emitter", "sound", "decal"], "the grenadier blast plays on the copy at once (%s)" % kinds)
    check(G.eval('CALLS[1][4].X') == 510, "at the copy's own spot")
    G.execute('NOW = 1.6; zfx.tick(0.1)')
    check(G.eval('#CALLS') == 4 and G.eval('CALLS[4][1]') == "emitter", "the radiated blast follows after the game's delay")
    G.execute('CALLS = {}; COPIES[7].arch_ran = true; INBOX = { "G 7 500 0 0" }; NOW = 3; zfx.tick(0.1); NOW = 4; zfx.tick(0.1)')
    check(G.eval('#CALLS') == 0, "a copy that ran the archetype itself blasts on its own - not twice")


def nests_keep_real_health():
    print("nests_keep_real_health")
    def setup(role):
        L = lua()
        L.execute(FAKES + r"""
            local role = ...
            NOW = 0
            HOOKS, TIMERS, KILLS = {}, {}, {}
            SENT, INBOX = {}, {}
            package.loaded["mirror.events"] = evmock { new = function(name)
                return { send = function(self, p) SENT[#SENT + 1] = p end,
                         pump = function(self, fn) local q = INBOX; INBOX = {}; for _, p in ipairs(q) do fn(p) end end } end }
            GHOST = obj({})
            package.loaded["mirror.ghost"] = { get = function() return GHOST end, location = function() return nil end }
            PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end })
            package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end,
                                              on_tick = function() end }
            TEMPLATE = { StandardHealthValue = 2000, MaxHealth = 3000 }
            StaticFindObject = function(p) if p:find(":DamageComponent_GEN_VARIABLE", 1, true) then return obj(TEMPLATE) end return obj({}) end
            util = require("mirror.util")
            util.ensure_hook = function(p, fn) HOOKS[p:match(":(.+)$")] = fn; return true end
            local ksl = obj({ K2_SetTimer = function(self, o, fname) TIMERS[#TIMERS + 1] = fname end,
                              GetConsoleVariableFloatValue = function(self, n) if n == "Difficulty.InfestationsHealth" then return 1.5 end return 0 end,
                              IsValid = function() return true end })
            util.cdo = function() return ksl end
            function nest(x, std, cur, max)
                local n = obj({ ["IsDestroyed?"] = false, ["PrimaryInfestation?"] = false, ["CanDamagePrimary?"] = true,
                                DamageComponent = obj({ StandardHealthValue = std, CurrentHealth = cur, MaxHealth = max }),
                                K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end })
                n.GetClass = function() return obj({ GetFullName = function() return "BlueprintGeneratedClass /Game/Infestation/BP_Infestation.BP_Infestation_C" end }) end
                n.Damage_Object = function(self, amt) KILLS[#KILLS + 1] = amt
                    self.DamageComponent.CurrentHealth = self.DamageComponent.CurrentHealth - amt
                    if self.DamageComponent.CurrentHealth <= 0 then self["IsDestroyed?"] = true end end
                n.Event_OnDestroyed = function(self) self["IsDestroyed?"] = true end
                return n
            end
            A = nest(0, 3000, 3000, 3000)
            BAD = nest(5000, 1500000, 750000, 3000)
            -- a pinned nest whose DamageComponent is already gone (a load still running): never written
            STALE = nest(9000, 1500000, 750000, 3000)
            STALE.DamageComponent.IsValid = function() return false end
            util.instances = function(cls) if cls == "BP_Infestation_C" then return { A, BAD, STALE }, true end return {}, true end
            infest = require("mirror.infest")
            infest.init({}, role, {}, function() return true end)
            for i = 1, 10 do infest.tick(0.1) end
            function dc(n) return n.DamageComponent end
            function hook(name, self, ...) local args = { ... }
                local w = {}; for i, v in ipairs(args) do w[i] = { get = function() return v end } end
                HOOKS[name]({ get = function() return self end }, table.unpack(w)) end
        """, role)
        return L
    L = setup("host")
    check(L.eval("dc(A).StandardHealthValue") == 3000 and L.eval("dc(A).CurrentHealth") == 3000,
          "host: nests keep their real health (no million-point pin)")
    check(L.eval("dc(BAD).StandardHealthValue") == 3000 and L.eval("dc(BAD).CurrentHealth") == 1500,
          "a nest saved with a pinned million-point health gets its real health back (game defaults x difficulty, same %)")
    check(L.eval("dc(STALE).StandardHealthValue") == 1500000 and L.eval("dc(STALE).MaxHealth") == 3000,
          "a nest whose DamageComponent is no longer valid is neither read nor written")
    L.execute('INBOX = { "' + "BP_Infestation_C@0,0,0" + ' 500" }; infest.tick(0.1)')
    check(L.eval("dc(A).CurrentHealth") == 2500 and L.eval("#TIMERS") == 0 and L.eval("#KILLS") == 0,
          "host: a guest hit lowers the real health, no waves above 2/3")
    L.execute('INBOX = { "BP_Infestation_C@0,0,0 600" }; infest.tick(0.1)')
    check(L.eval("dc(A).CurrentHealth") == 1900 and L.eval("#TIMERS") == 1 and L.eval("TIMERS[1]") == "SpawnWave",
          "host: a guest hit below 2/3 starts the waves once, from a timer")
    check(L.eval("dc(A).MaxHealth") == 0, "host: the nest's own 2/3 check is closed so a later hit can't start a second wave chain")
    L.execute('hook("ActorPreSave", A)')
    check(L.eval("dc(A).MaxHealth") == 3000 and L.eval("dc(A).StandardHealthValue") == 3000, "saving writes the real values")
    L.execute('hook("ActorSaved", A)')
    check(L.eval("dc(A).MaxHealth") == 0, "after the save the wave guard is back")
    L.execute('INBOX = { "BP_Infestation_C@0,0,0 300" }; infest.tick(0.1)')
    check(L.eval("#TIMERS") == 1, "no second wave chain")
    L.execute("NOW = 2; infest.tick(1.1)")
    st = L.eval("blobs_out.nests") or ""
    check("BP_Infestation_C@0,0,0 0 1600.0 3000.0" in st, "host state carries the real health numbers")
    L.execute('INBOX = { "BP_Infestation_C@0,0,0 5000" }; infest.tick(0.1)')
    check(L.eval("A['IsDestroyed?']") is True and L.eval("KILLS[1]") == 1.0, "host: a lethal guest hit runs the nest's own death")
    L.execute('hook("Damage_Object", BAD, 100.0, PLAYER, nil)')
    check(L.eval("dc(BAD).CurrentHealth") == 1500, "host: the host's own hits stay the game's (nothing re-applied)")

    H = setup("host")
    H.execute('dc(A).CurrentHealth = 1800; INBOX = { "BP_Infestation_C@0,0,0 100" }; infest.tick(0.1)')
    check(H.eval("#TIMERS") == 0 and H.eval("dc(A).CurrentHealth") == 1700,
          "host: a nest already under 2/3 (its waves already ran or wait for the game's own check) gets no second chain")
    H.execute(r"""
        LATE = nest(9000, 3000, 3000, 3000)
        LATE.GetClass = function() return obj({ GetFullName = function() return "BlueprintGeneratedClass /Game/Infestation/BP_Infestation_Wall.BP_Infestation_Wall_C" end,
                                                GetFName = function() return { ToString = function() return "BP_Infestation_Wall_C" end } end }) end
    """)
    G2 = setup("guest")
    G2.execute(r"""
        LATE = nest(9000, 3000, 3000, 3000)
        LATE.GetClass = function() return obj({ GetFullName = function() return "BlueprintGeneratedClass /Game/Infestation/BP_Infestation_Wall.BP_Infestation_Wall_C" end,
                                                GetFName = function() return { ToString = function() return "BP_Infestation_Wall_C" end } end }) end
        hook("Damage_Object", LATE, 50.0, PLAYER, nil)
    """)
    check(G2.eval("SENT[#SENT]") == "BP_Infestation_Wall_C@900,0,0 50.000" and G2.eval("dc(LATE).MaxHealth") == 0,
          "guest: a hit on a nest the scan hasn't reached yet still goes to the host (and the copy can't start waves)")

    G = setup("guest")
    check(G.eval("dc(A).StandardHealthValue") == 3000 and G.eval("dc(A).MaxHealth") == 0,
          "guest: copies show real health and can't start waves of their own")
    G.execute('blobs_in.nests = "BP_Infestation_C@0,0,0 0 1234.0 3000.0"; infest.tick(0.1)')
    check(G.eval("dc(A).CurrentHealth") == 1234 and G.eval("dc(A).StandardHealthValue") == 3000,
          "guest: the copy shows the host's exact health")
    G.execute('dc(A).CurrentHealth = 1134; hook("Damage_Object", A, 100.0, PLAYER, nil)')
    check(G.eval("SENT[#SENT]") == "BP_Infestation_C@0,0,0 100.000", "guest: its hit goes to the host")
    G.execute('blobs_in.nests = "BP_Infestation_C@0,0,0 1 0.0 3000.0"; infest.tick(0.1)')
    check(G.eval("A['IsDestroyed?']") is True, "guest: a nest destroyed on the host is destroyed here")

    # player report 2026-10-27: after destroying the smaller nests the guest's primary kept saying "destroy the
    # others first" - nests the host destroyed are shown with Event_OnDestroyed, which doesn't tell the primary
    G3 = setup("guest")
    G3.execute(r"""
        P = nest(20000, 3000, 3000, 3000)
        P["PrimaryInfestation?"], P["CanDamagePrimary?"] = true, false
        P.GetClass = function() return obj({ GetFullName = function() return "BlueprintGeneratedClass /Game/Infestation/BP_PrimaryInfestation.BP_PrimaryInfestation_C" end,
                                             GetFName = function() return { ToString = function() return "BP_PrimaryInfestation_C" end } end }) end
        P.SecondaryInfestations = { items = { A, BAD }, ForEach = function(self, fn)
            for i, v in ipairs(self.items) do fn(i, { get = function() return v end }) end end }
        hook("Damage_Object", P, 50.0, PLAYER, nil)
    """)
    check(G3.eval("SENT[#SENT]") == "BP_PrimaryInfestation_C@2000,0,0 50.000",
          "guest: a hit on a primary still shut here goes to the host (the host's nest decides)")
    G3.execute('blobs_in.nests = "BP_Infestation_C@0,0,0 1 0.0 3000.0"; infest.tick(1.1)')
    check(G3.eval("P['CanDamagePrimary?']") is False, "guest: the primary stays shut while one smaller nest is left")
    G3.execute('blobs_in.nests = "BP_Infestation_C@0,0,0 1 0.0 3000.0\\nBP_Infestation_C@500,0,0 1 0.0 3000.0"; infest.tick(1.1)')
    check(G3.eval("P['CanDamagePrimary?']") is True, "guest: once the host's kills of all its smaller nests show here, the primary opens")


def horde_beacon_runs_only_on_the_host():
    print("horde_beacon_runs_only_on_the_host")
    def setup(role):
        L = lua()
        L.execute(FAKES + r"""
            local role = ...
            HOOKS, SENT, INBOX, DISH, NOTES = {}, {}, {}, {}, {}
            package.loaded["mirror.events"] = evmock { new = function(name)
                return { send = function(self, p) SENT[#SENT + 1] = p end,
                         pump = function(self, fn) local q = INBOX; INBOX = {}; for _, p in ipairs(q) do fn(p) end end } end }
            package.loaded["mirror.ghost"] = { get = function() return nil end, location = function() return nil end }
            PLAYER = obj({ CreateNotificationUI = function(self, t) NOTES[#NOTES + 1] = t end })
            package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end }
            FText = function(s) return s end
            util = require("mirror.util")
            util.ensure_hook = function(p, fn) HOOKS[p:match(":(.+)$")] = fn; return true end
            B = obj({ ["HordeStarted?"] = false, ["CanStopHorde?"] = false, STARTS = 0, STOPS = 0,
                      K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end })
            B.GetClass = function() return cls("Buildable_HordeBeacon_C") end
            B.Event_StartHorde = function(self) self.STARTS = self.STARTS + 1; self["HordeStarted?"] = true; self["CanStopHorde?"] = true end
            B.Event_StopHorde = function(self) self.STOPS = self.STOPS + 1; self["HordeStarted?"] = false end
            B.Event_DishMovement = function(self, on) DISH[#DISH + 1] = on end
            util.find_by_id = function(id) if id == "Buildable_HordeBeacon_C@10,0,0" then return B end end
            horde = require("mirror.horde")
            horde.init({}, role, { in_world = function() return true end }, function() return true end)
            horde.tick(0.1)
            function hook(name, self, ...) local w, n = {}, select("#", ...)
                for i = 1, n do local v = select(i, ...); w[i] = { get = function() return v end } end
                HOOKS[name]({ get = function() return self end }, table.unpack(w, 1, n)) end
        """, role)
        return L
    ID = "Buildable_HordeBeacon_C@10,0,0"
    H = setup("host")
    H.execute('INBOX = { "I %s start" }; horde.tick(0.1); horde.tick(1.1)' % ID)
    check(H.eval("B.STARTS") == 1, "host: a guest press starts the host's beacon")
    check(H.eval("blobs_out.hordes") == ID + " 1", "host: its horde state goes to the guest")
    H.execute('INBOX = { "I %s start" }; horde.tick(0.1)' % ID)
    check(H.eval("B.STARTS") == 1, "host: a second start while it runs is ignored (no double horde)")
    H.execute('B["CanStopHorde?"] = false; INBOX = { "I %s stop" }; horde.tick(0.1)' % ID)
    check(H.eval("B.STOPS") == 0, "host: a stop after the countdown is ignored, like the game's own press")
    H.execute('B["CanStopHorde?"] = true; INBOX = { "I %s stop" }; horde.tick(0.1); horde.tick(1.1)' % ID)
    check(H.eval("B.STOPS") == 1 and H.eval("blobs_out.hordes") == "", "host: a stop in the countdown stops it, the guest is told")
    H.execute('hook("CreateNotificationUI", {}, { ToString = function() return "Wave: 1 Begin!" end }, nil, nil, 2.0, false, B)')
    H.execute('hook("CreateNotificationUI", {}, { ToString = function() return "picked up" end }, nil, nil, 2.0, false, PLAYER)')
    check(H.eval("SENT[#SENT]") == "T %s Wave: 1 Begin!" % ID and H.eval("#SENT") == 1,
          "host: only the beacon's own messages go to the guest")

    G = setup("guest")
    G.execute('B.Event_StartHorde(B); hook("Event_StartHorde", B)')
    check(G.eval('B["HordeStarted?"]') is False and G.eval("SENT[1]") == "I %s start" % ID,
          "guest: a press doesn't run the copy's horde, it asks the host")
    G.execute('INBOX = { "T %s Horde incoming" }; horde.tick(0.1)' % ID)
    check(G.eval("#NOTES") == 0, "guest: the host's repeat of the press's own message isn't shown twice")
    G.execute('blobs_in.hordes = "%s 1"; for i = 1, 40 do horde.tick(0.1) end' % ID)
    check(G.eval('B["HordeStarted?"]') is False, "guest: the copy's own countdown is left to die first")
    G.execute('for i = 1, 160 do horde.tick(0.1) end')
    check(G.eval('B["HordeStarted?"]') is True and G.eval('B["CanStopHorde?"]') is True,
          "guest: then the copy shows the host's horde (a press now means stop)")
    G.execute('INBOX = { "T %s Wave: 1 Begin!" }; horde.tick(0.1)' % ID)
    check(G.eval("NOTES[1]") == "Wave: 1 Begin!", "guest: the host's wave messages are shown")
    G.execute('blobs_in.hordes = ""; horde.tick(0.1)')
    check(G.eval('B["HordeStarted?"]') is False and G.eval("DISH[#DISH]") is False, "guest: the host's horde ended - the dish stops here")
    G2 = setup("guest")
    G2.execute('B.Event_StartHorde(B); hook("Event_StartHorde", B); for i = 1, 50 do horde.tick(0.1) end')
    check(G2.eval("DISH[#DISH]") is False, "guest: a press the host turned down doesn't leave the dish turning")


def copy_radiation_is_taken_back():
    print("copy_radiation_is_taken_back")
    L = lua()
    L.execute(FAKES + r"""
        RC = obj({ CurrentRadiation = 80, refreshed = 0 })
        RC.DecreaseRadiation = function(self, n) self.refreshed = self.refreshed + 1; self.CurrentRadiation = self.CurrentRadiation - n end
        PLAYER = obj({ GetComponentByClass = function() return RC end })
        package.loaded["mirror.game"] = { player = function() return PLAYER end, world = function() return nil end,
                                          on_world_reset = function() end, keybind = function() end }
        package.loaded["mirror.ghost"] = { get = function() return nil end, is = function() return false end }
        package.loaded["mirror.loader"] = { want = function() end }
        StaticFindObject = function() return obj({}) end
        util = require("mirror.util")
        zombies = require("mirror.zombies")
        zombies._rad.watch(0.1)
    """)
    L.execute("RC.CurrentRadiation = 60; zombies._rad.take_back(20)")
    check(L.eval("RC.CurrentRadiation") == 80 and L.eval("RC.refreshed") == 1, "a copy's blast that already landed is undone")
    L.execute("zombies._rad.watch(0.1); zombies._rad.take_back(20)")
    check(L.eval("RC.CurrentRadiation") == 80 and L.eval("RC.refreshed") == 1, "nothing is given back when the block worked")
    L.execute("RC.CurrentRadiation = 50; zombies._rad.take_back(5)")
    check(L.eval("RC.CurrentRadiation") == 55, "never more than the copy's own amount is given back")


def goto_and_bring_move_only_your_own_player():
    print("goto_and_bring_move_only_your_own_player")
    def side(swim=False):
        L = lua()
        L.execute(FAKES + r"""
            NOTES = {}
            package.loaded["mirror.notify"] = { show = function(t) NOTES[#NOTES + 1] = t end, clear = function() end }
            SENT, INBOX = {}, {}
            package.loaded["mirror.events"] = evmock { new = function() return {
                send = function(self, m) SENT[#SENT + 1] = m end,
                pump = function(self, fn) local q = INBOX; INBOX = {}; for _, m in ipairs(q) do fn(m) end end } end }
            package.loaded["mirror.link"].peer_name = function() return "Friend" end
            BUSY = nil
            package.loaded["mirror.vehicles"] = { busy = function() return BUSY end }
            P = obj({ at = { X = 0, Y = 0, Z = 90 }, SwimmingComponent = {}, CharacterMovement = { SetMovementMode = function() end } })
            P.K2_GetActorLocation = function(self) return self.at end
            P.K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end
            P.K2_TeleportTo = function(self, to) self.at = to; return true end
            G = obj({ SwimmingComponent = {} })
            G.K2_GetActorLocation = function() return { X = 10000, Y = 0, Z = 590 } end
            package.loaded["mirror.game"] = { player = function() return P end, on_world_reset = function() end }
            package.loaded["mirror.ghost"] = { get = function() return G end,
                                               location = function() return G:K2_GetActorLocation() end }
            KSL = { LineTraceSingle = function(self, ctx, from, to, ch, cx, ign, dbg, out)
                out.ImpactPoint = { X = from.X, Y = from.Y, Z = 500 }; return true end }
            util = require("mirror.util")
            util.cdo = function() return KSL end
            tp = require("mirror.teleport")
        """)
        return L
    A = side()
    A.execute('tp.command("/goto Nobody")')
    check(A.eval("P.at.X") == 0 and "No player called" in A.eval("NOTES[#NOTES]"), "a wrong name is refused with the right one")
    A.execute('BUSY = "you are in a vehicle - get out first"; tp.command("/goto Friend")')
    check(A.eval("P.at.X") == 0 and "vehicle" in A.eval("NOTES[#NOTES]"), "no teleport out of a car")
    A.execute('BUSY = nil; os.clock = (function(c) return function() return c() + 100 end end)(os.clock); tp.command("/goto fri")')
    check(A.eval("P.at.X") == 0 and A.eval("SENT[#SENT]") == "Q G", "/goto only asks - nothing moves before the answer")
    A.execute('INBOX = { "A" }; tp.tick(0.1)')
    d = A.eval("math.sqrt((P.at.X - 10000)^2 + P.at.Y^2)")
    check(140 <= d <= 160 and A.eval("P.at.Z") == 600, "accepted: lands on the ground beside the other player (%.0f cm)" % d)
    check(A.eval("SENT[#SENT]") == "G", "the other player is told")
    A.execute('INBOX = { "A" }; tp.tick(0.1)')
    check(A.eval("SENT[#SENT]") == "G" and A.eval("#SENT") == 2, "a stray accept without a request moves nothing")
    B = side()
    B.execute('INBOX = { "Q B" }; tp.tick(0.1)')
    check(B.eval("tp.pending().kind") == "bring" and B.eval("P.at.X") == 0, "a bring request waits for the answer")
    B.execute('tp.command("/deny")')
    check(B.eval("P.at.X") == 0 and B.eval("SENT[1]") == "D" and B.eval("tp.pending()") is None, "denied: nothing moves, the asker is told")
    B.execute('P.SwimmingComponent["IsSwimming?"] = true; INBOX = { "Q B" }; tp.tick(0.1); tp.command("/accept")')
    check(B.eval("P.at.X") == 0 and B.eval("SENT[2]").startswith("N they are swimming"), "accepted while swimming: not moved, the asker is told why")
    B.execute('P.SwimmingComponent["IsSwimming?"] = false; INBOX = { "Q B" }; tp.tick(0.1); tp.accept()')
    check(B.eval("P.at.X") > 9000 and B.eval("SENT[3]") == "Y", "accepted: the asked game moves its own player")
    B.execute('INBOX = { "Q G" }; tp.tick(0.1); tp.tick(31)')
    check(B.eval("tp.pending()") is None and B.eval("SENT[4]") == "X", "an unanswered request times out")


def backpack_tooltip_reads_the_item_once():
    # DBG-20261026-001: the per-frame tooltip hook read the item, its data asset and walked the inventory every
    # frame - all four crash runs died there while items moved. Now: once per hovered item, nothing right after a move.
    print("backpack_tooltip_reads_the_item_once")
    import tempfile
    d = tempfile.mkdtemp()
    L = lua()
    L.execute(FAKES + r"""
        NOW = 0; os.clock = function() return NOW end
        FText = function(s) return s end
        KEYS, HOOKS, WALKS, FULLNAMES, REFREADS = {}, {}, 0, 0, 0
        COMP = obj({})
        PLAYER = obj({ BP_JigComponent = COMP })
        package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end,
                                          keybind = function(k, _, fn) KEYS[k] = fn end, on_ready = function() end }
        package.loaded["mirror.jig"] = { contents_of = function(c) WALKS = WALKS + 1; return { { uid = "1_2_3_4" } } end }
        util = require("mirror.util")
        util.ensure_hook = function(path, fn) HOOKS[path:match(":(.+)$")] = fn; return true end
        ITEM = obj({ ItemUniqueID = { A = 1, B = 2, C = 3, D = 4 },
                     JigDataAsset = obj({ GetFullName = function() FULLNAMES = FULLNAMES + 1
                                          return "JigDataAsset /Game/Equipment/Backpacks/DA_Bag.DA_Bag" end }) })
        DESCR, SHOWN = "Holds things", nil
        TIP = setmetatable(obj({ NameText = obj({ SetText = function(_, t) SHOWN = t end }),
                                 descr = obj({ GetText = function() return { ToString = function() return DESCR end } end,
                                               SetText = function(_, t) DESCR = t end }) }),
                           { __index = function(_, k) if k == "ItemRef" then STALE = true; return ITEM end end })
        P = function(v) return { get = function() return v end } end
        -- Update(ItemRef) is hooked before it runs: TIP.ItemRef is the item shown last (maybe freed), the param is live
        REF = { get = function() REFREADS = REFREADS + 1; return ITEM end }
        function frames(n) for _ = 1, n do NOW = NOW + 0.016; HOOKS.Update(P(TIP), REF) end end
    """)
    L.execute('local d = ...; local io_open = io.open; io.open = function(p, m) return io_open(d .. "/" .. p, m) end; '
              'local rn, rm = os.rename, os.remove; os.rename = function(a, b) return rn(d .. "/" .. a, d .. "/" .. b) end; '
              'os.remove = function(a) return rm(d .. "/" .. a) end', d.replace("\\", "/"))
    L.execute('names = require("mirror.names"); names.init({}); names.tick(1); names.set("1_2_3_4", "Med bag")')
    check(L.eval("HOOKS.Update ~= nil and HOOKS['Handle Comp to Comp Move'] ~= nil"), "tooltip and move hooks registered")
    L.execute("frames(60)")
    check(L.eval("WALKS") == 0 and L.eval("FULLNAMES") == 1, "60 frames on one backpack: item read once, inventory never walked (%s walks, %s names)"
          % (L.eval("WALKS"), L.eval("FULLNAMES")))
    check(L.eval("SHOWN") == "Med bag" and "Rename (F2)" in L.eval("DESCR"), "its name and the F2 hint still show")
    # backpacks have no description: the game's Update collapses descr + Divider and leaves stale text in descr
    L.execute('DESCR = "Designer placeholder"; DVIS = 1; DIVVIS = 1; '
              'TIP.descr.GetVisibility = function() return DVIS end; TIP.descr.SetVisibility = function(_, v) DVIS = v end; '
              'TIP.Divider = obj({ SetVisibility = function(_, v) DIVVIS = v end }); frames(1)')
    check(L.eval("DESCR") == "Rename (F2)" and L.eval("DVIS") == 4 and L.eval("DIVVIS") == 4,
          "a bag without a description: the collapsed text is shown with just the hint (%s, vis %s/%s)"
          % (L.eval("DESCR"), L.eval("DVIS"), L.eval("DIVVIS")))
    L.execute('DESCR = "Holds things"; DVIS = 0')
    L.execute('ROWTXT = {}; function row(a) local t = obj({ SetText = function(_, s) ROWTXT[a] = s end }) '
              'return obj({ UID = { A = a, B = 2, C = 3, D = 4 }, ItemName = t }) end; '
              'HOOKS.Construct(P(row(1))); HOOKS.Construct(P(row(7)))')
    check(L.eval("ROWTXT[1]") == "Med bag" and L.eval("ROWTXT[7]") is None,
          "backpack list (top right): a named bag's row shows its name, other rows keep the game's")
    check(L.eval("STALE") is None, "the tooltip's previous item (self.ItemRef, maybe freed) is never read")
    L.execute("names.set('1_2_3_4', 'Ammo bag'); frames(1)")
    check(L.eval("SHOWN") == "Ammo bag" and L.eval("WALKS") == 0, "a rename shows at once without a new walk")
    L.execute("R0 = REFREADS; HOOKS['Handle Comp to Comp Move'](P(COMP), P(COMP), P(COMP), P({ A = 9, B = 9, C = 9, D = 9 }), P(0), P(0), P({}))")
    L.execute("frames(20)")  # 0.32 s
    check(L.eval("REFREADS") == L.eval("R0"), "right after a move the tooltip hook doesn't touch the item")
    L.execute("frames(10)")
    check(L.eval("REFREADS") > L.eval("R0") and L.eval("WALKS") == 0, "after the pause it looks at the item once more, still no walk")
    L.execute("NOW = NOW + 1.0; KEYS.F2()")
    check(L.eval("names.asking()") is False, "F2 on a tooltip that stopped updating opens nothing (no widget kept)")
    # the slot's tooltip binding only runs Update when the tooltip opens: F2 while the slot is still hovered works
    # (player report: F2 only worked right after clicking the bag)
    # (the box itself needs real widgets: count the rename box asking for the bag's current name instead)
    L.execute("ITEM.GetClass = function() return cls('JSI_Slot_C') end; HOOKS.Update(P(obj({})), REF); "
              "local get = names.get; OPENS = 0; names.get = function(u) if NOW > 0 and IN_F2 then OPENS = OPENS + 1 end return get(u) end; "
              "local function f2() IN_F2 = true; KEYS.F2(); IN_F2 = false; return OPENS > 0 end; "
              "frames(1); NOW = NOW + 2.0; HOV = false; ITEM.IsHovered = function() return HOV end; A1 = f2(); "
              "frames(1); NOW = NOW + 2.0; HOV = true; A2 = f2(); names.get = get")
    check(L.eval("A1") is False and L.eval("A2") is True,
          "F2 seconds after the last tooltip Update: opens while the bag's slot is hovered, not after the mouse left (%s/%s)"
          % (L.eval("A1"), L.eval("A2")))
    L.execute('package.loaded["mirror.names"] = nil; HOOKS = {}; names = require("mirror.names"); '
              'names.init({ backpack_names = false }); names.tick(1)')
    check(L.eval("next(HOOKS) == nil"), "backpack_names = off: no inventory hooks at all")


def foreach_keeps_temporary_arrays_alive():
    # DBG-20261026-001: UE4SS's ForEach takes the array off the Lua stack before it loops, so a temporary
    # (comp.MainJigContainers:ForEach) can be collected by Lua mid-loop -> freed memory read -> native crash (big bags).
    print("foreach_keeps_temporary_arrays_alive")
    L = lua()
    L.execute(FAKES + r"""
        util = require("mirror.util")
        jig = require("mirror.jig")
        FREED = 0
        -- a fresh array object per property read, like UE4SS; its ForEach lets go of it the way UE4SS does
        function arr(elems)
            return { ForEach = function(self, fn)
                local w = setmetatable({ self }, { __mode = "v" })
                self = nil
                for i, e in ipairs(elems) do
                    collectgarbage("collect")
                    if w[1] == nil then FREED = FREED + 1 end
                    fn(i, { get = function() return e end })
                end
            end }
        end
        local function item(n)
            return { UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = { A = n, B = 0, C = 0, D = 0 },
                     ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = {
                         ItemID_28_01CA27D84AF7D1014D9E2E83894C1848 = obj({ GetFullName = function() return "X /Game/I.I" end }),
                         Count_8_DD79AF2A46126A338C8DCCB4616D91CD = 1,
                         Durability_22_A3557C454274D193D47AB9B71FB0C0CA = { X = 1, Y = 1 } } }
        end
        local function cont(first, n)
            local items = {}
            for i = 1, n do items[i] = item(first + i) end
            return setmetatable({ InContainerUID_24_D1504ED7438699C73EA046AD734E79BF = { A = 0, B = 0, C = 0, D = 0 },
                                  ContainerIndex_22_9A211B86466A9D1C57E1FC839A5B0896 = 0 },
                { __index = function(_, k) if k == "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B" then return arr(items) end end })
        end
        CONTS = { cont(0, 40), cont(100, 40), cont(200, 40) }
        COMP = setmetatable(obj({}), { __index = function(_, k) if k == "MainJigContainers" then return arr(CONTS) end end })
    """)
    L.execute("COMP.MainJigContainers:ForEach(function() end)")
    check(L.eval("FREED") > 0, "the fake reproduces it: a temporary array is collected mid-ForEach")
    L.execute("FREED = 0; N = #jig.contents_of(COMP)")
    check(L.eval("FREED") == 0 and L.eval("N") == 120,
          "jig.contents_of keeps every array alive for its whole loop (%d freed, %d items)" % (L.eval("FREED"), L.eval("N")))
    import re
    bad = []
    for base, _, files in os.walk(SCRIPTS):
        for f in files:
            if f.endswith(".lua"):
                for i, line in enumerate(open(os.path.join(base, f), encoding="utf-8"), 1):
                    code = line.split("--", 1)[0]
                    if re.search(r"(\.\w+|\]|\))\s*:ForEach\(", code):
                        bad.append("%s:%d" % (f, i))
    check(not bad, "no :ForEach on a temporary anywhere in the mod %s" % (bad or ""))


def backpack_names_travel_with_the_item():
    print("backpack_names_travel_with_the_item")
    import tempfile
    d = tempfile.mkdtemp()
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.game"] = { player = function() return nil end, on_world_reset = function() end,
                                          keybind = function() end, on_ready = function() end }
        util = require("mirror.util")
        names = require("mirror.names")
        jig = require("mirror.jig")
    """)
    L.execute('local d = ...; local io_open = io.open; io.open = function(p, m) return io_open(d .. "/" .. p, m) end; '
              'local rn, rm = os.rename, os.remove; os.rename = function(a, b) return rn(d .. "/" .. a, d .. "/" .. b) end; '
              'os.remove = function(a) return rm(d .. "/" .. a) end', d.replace("\\", "/"))
    L.execute('names.set("1_2_3_4", "Med bag; 50%, Bob|x")')
    n = L.eval('names.get("1_2_3_4")')
    check(n.startswith("Med bag") and not any(c in n for c in ";,|%"), "names are cleaned of separators")
    L.execute("names.set('1_2_3_4', \"Bob's med bag\")")
    enc = L.eval('jig.encode({ { uid = "1_2_3_4", da = "/Game/B.DA_B", count = 1 }, { uid = "5_6_7_8", da = "/Game/X.DA_X", count = 2, parent = 1, slot = 0 } })')
    check("|" in enc and " " not in enc, "the name rides along in the item list")
    L.execute('LIST = jig.decode(...)', enc)
    check(L.eval("LIST[1].name") == "Bob's med bag" and L.eval("LIST[2].name") is None and L.eval("LIST[2].parent") == 1,
          "decoded with the name, nesting intact")
    L.execute('package.loaded["mirror.names"] = nil; names = require("mirror.names")')
    check(L.eval('names.get("1_2_3_4")') == "Bob's med bag", "names survive a restart (file)")
    L.execute('names.set("1_2_3_4", "")')
    check(L.eval('names.get("1_2_3_4")') is None, "an empty name clears it")
    # the game re-rolls UIDs when an item leaves a container (RemoveGetInfo): names follow, nested ones too
    L.execute(r"""
        names.set("10_0_0_1", "Outer"); names.set("20_0_0_2", "Inner")
        local real = jig.contents_of
        jig.contents_of = function(c) return c.list end
        local real_valid = util.valid
        util.valid = function(o) return o ~= nil end
        -- before: Outer in my inventory, Inner in Outer's compartment 1, cell 7
        names.note({ list = { { uid = "10_0_0_1", da = "/G/BP.Big", holder = "INV", slot = 0, cell = 3 },
                              { uid = "20_0_0_2", da = "/G/BP.Small", holder = "10_0_0_1", slot = 1, cell = 7 },
                              { uid = "30_0_0_3", da = "/G/BP.Small", holder = "10_0_0_1", slot = 0, cell = 7 } } })
        -- dropped: new UIDs everywhere, the pickup holds the contents
        names.moved("10_0_0_1", "11_0_0_1", { list = { { uid = "31_0_0_3", da = "/G/BP.Small", holder = "11_0_0_1", slot = 0, cell = 7 },
                                                      { uid = "21_0_0_2", da = "/G/BP.Small", holder = "11_0_0_1", slot = 1, cell = 7 } } })
        jig.contents_of = real
        util.valid = real_valid
    """)
    check(L.eval('names.get("11_0_0_1")') == "Outer" and L.eval('names.get("10_0_0_1")') is None, "a dropped backpack keeps its name")
    check(L.eval('names.get("21_0_0_2")') == "Inner" and L.eval('names.get("31_0_0_3")') is None,
          "a named backpack inside it keeps its name (matched by compartment + cell)")
    L.execute('names.moved("99_0_0_9", "98_0_0_9", nil)')
    check(L.eval('names.get("98_0_0_9")') is None, "unnamed items stay unnamed")


def container_items_keep_their_cell_and_rotation():
    print("container_items_keep_their_cell_and_rotation")
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.names"] = { get = function() end, set = function() end, encode = function(s) return s end, decode = function(s) return s end }
        local ITEMS, INFO = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B", "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
        local ITEM_ID, COUNT = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848", "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
        local VEC, UID = "ItemVec_13_4DB12E4E4F80730BD25ACFA6FA51AD0A", "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
        local CELL, ROT = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD", "Rotated_9_3CFE5D9342A81FB1FF17DEB7B491CE56"
        ASSETS = {}
        local function asset(name, x, y)
            ASSETS["/Game/I." .. name] = obj({ SlotDimensions = { X = x, Y = y }, Weight = 1, Price = 1,
                GetFullName = function() return "DataAsset /Game/I." .. name end,
                ItemStats = { ForEach = function() end } })
        end
        asset("DA_Gun", 3, 1); asset("DA_Can", 1, 1)
        StaticFindObject = function(p) return ASSETS[p] end
        local uid_n = 0
        function grid(cols, rows)
            local items = {}
            local cont = { ReplicationUID_23_EB27D09649B6E02591DCA98708B06332 = { A = 9, B = 9, C = 9, D = 9 },
                           Columns_4_1D84448048078D988999ABA138CE1809 = cols, Rows_6_78B4BC5B449017D63758E79844375AE9 = rows,
                           ContainerIndex_22_9A211B86466A9D1C57E1FC839A5B0896 = 0,
                           InContainerUID_24_D1504ED7438699C73EA046AD734E79BF = { A = 0, B = 0, C = 0, D = 0 } }
            cont[ITEMS] = { ForEach = function(self, fn) for i, it in ipairs(items) do fn(i, { get = function() return it end }) end end }
            local function cells(it)
                local v, out = it[INFO][VEC], {}
                local w, h = v.X, v.Y
                if it[ROT] then w, h = h, w end
                local c0, r0 = it[CELL] % cols, it[CELL] // cols
                if c0 + w > cols or r0 + h > rows then return nil end
                for r = r0, r0 + h - 1 do for c = c0, c0 + w - 1 do out[#out + 1] = r * cols + c end end
                return out
            end
            local comp = { items = items }
            comp.MainJigContainers = { GetArrayNum = function() return 1 end,
                                       ForEach = function(self, fn) fn(1, { get = function() return cont end }) end }
            function comp:AddNewItemToSlot(info, to, idx, a, b, out, c)
                local it = { [INFO] = info[INFO], [CELL] = idx, [ROT] = info[ROT] == true }
                local mine = cells(it)
                if not mine then out.Added = false; return end
                local busy = {}
                for _, o in ipairs(items) do for _, k in ipairs(cells(o)) do busy[k] = true end end
                for _, k in ipairs(mine) do if busy[k] then out.Added = false; return end end
                uid_n = uid_n + 1
                it[UID] = { A = uid_n, B = 0, C = 0, D = 0 }
                items[#items + 1] = it
                out.Added = true
            end
            function comp:HandleSameContainerMoveToIndex(g, to, idx, rot, by, n)
                MOVES = (MOVES or 0) + 1
                for _, o in ipairs(items) do
                    if o[UID].A == g.A then
                        local old_c, old_r = o[CELL], o[ROT]
                        o[CELL], o[ROT] = idx, rot == true
                        local mine, ok = cells(o), true
                        if not mine then ok = false else
                            local busy = {}
                            for _, x in ipairs(items) do if x ~= o then for _, k in ipairs(cells(x)) do busy[k] = true end end end
                            for _, k in ipairs(mine) do if busy[k] then ok = false end end
                        end
                        if not ok then o[CELL], o[ROT] = old_c, old_r end
                        return
                    end
                end
            end
            function comp:HandleLocalRequestConsumeItem(g)
                for i, o in ipairs(items) do if o[UID].A == g.A then table.remove(items, i); return end end
            end
            return comp
        end
        util = require("mirror.util")
        jig = require("mirror.jig")
        A, B = grid(5, 4), grid(5, 4)
    """)
    L.execute('U1 = jig.add_item(A, "/Game/I.DA_Gun", 1, 0, 0, nil, { cell = 6, rot = true })')
    L.execute('U2 = jig.add_item(A, "/Game/I.DA_Can", 4, 0, 0, nil, { cell = 2 })')
    L.execute('H = jig.contents_of(A)')
    check(L.eval('H[1].cell') == 6 and L.eval('H[1].rot') is True, "an item goes to the exact cell, rotated as sent")
    check(L.eval('H[2].cell') == 2 and L.eval('H[2].rot') is False, "an unrotated item keeps its cell too")
    L.execute('U3 = jig.add_item(A, "/Game/I.DA_Can", 1, 0, 0, nil, { cell = 11 })')
    check(L.eval('U3') is not None and L.eval('jig.contents_of(A)[3].cell') not in (6, 11, 16, 2),
          "a taken cell falls back to the first free spot, no overlap")
    enc = L.eval('jig.encode(jig.contents_of(A), true)')
    L.execute('LIST = jig.decode(...)', enc)
    check(L.eval('LIST[1].cell') == 6 and L.eval('LIST[1].rot') is True and L.eval('LIST[2].rot') is False,
          "the item list carries cell + rotation (%s)" % enc)
    check(L.eval('LIST[2].count') == 4 and L.eval('LIST[1].dy') == 0, "count/durability still decode")
    check(L.eval('jig.decode("/Game/I.DA_Can,2,0.000,0.000")[1].cell') is None, "a list without placement still decodes")
    L.execute('jig.apply_contents(B, LIST); HB = jig.contents_of(B)')
    same = all(L.eval('HB[%d].cell' % i) == L.eval('jig.contents_of(A)[%d].cell' % i)
               and L.eval('HB[%d].rot' % i) == L.eval('jig.contents_of(A)[%d].rot' % i) for i in (1, 2, 3))
    check(same and L.eval('#HB') == 3, "the other game rebuilds the same layout from the list")
    L.execute('C = grid(5, 4); jig.add_item(C, "/Game/I.DA_Can", 1, 0, 0, nil, { cell = 0 }); '
              'jig.add_item(C, "/Game/I.DA_Can", 5, 0, 0, nil, { cell = 9 }); '
              'jig.apply_contents(C, { { da = "/Game/I.DA_Can", count = 5, dx = 0, dy = 0, cell = 9 } }); HC = jig.contents_of(C)')
    check(L.eval('#HC') == 1 and L.eval('HC[1].cell') == 9 and L.eval('HC[1].count') == 5,
          "matching keeps the item standing in the wanted cell")
    # rearranging: A moves its gun and a can around; B follows by moving, never adding/removing
    L.execute('local h = jig.contents_of(A); jig.apply_layout(A, { { uid = h[1].uid, da = h[1].da, cell = 15, rot = false }, '
              '{ uid = h[2].uid, da = h[2].da, cell = 6, rot = false } }, nil)')
    check(L.eval('jig.contents_of(A)[1].cell') == 15 and L.eval('jig.contents_of(A)[2].cell') == 6, "items move to the wanted cells (chained)")
    L.execute('LAY = jig.decode(jig.encode(jig.contents_of(A), true)); MOVES = 0; MV, FL = jig.apply_layout(B, LAY, function() return nil end)')
    same = all(L.eval('jig.contents_of(B)[%d].cell' % i) == L.eval('jig.contents_of(A)[%d].cell' % i) for i in (1, 2, 3))
    check(same and L.eval('FL') == 0 and L.eval('#jig.contents_of(B)') == 3 and L.eval('jig.contents_of(B)[2].count') == 4,
          "the other game copies the rearranged layout by moves only (%s moved)" % L.eval('MV'))
    L.execute('MOVES = 0; jig.apply_layout(B, LAY, function() return nil end)')
    check(L.eval('MOVES') == 0, "an identical layout moves nothing")
    L.execute('''
        local R_INDEX, R_ROT = "Index_37_B46F3993454026F67AFD6D936119D0F6", "PreferRotated?_39_71AEF07C444B177A20CAF4A74260B9CD"
        local st = { n = 0 }
        function st:GetArrayNum() return self.n end
        S = setmetatable(st, { __newindex = function(t, k, v) rawset(t, k, v); if type(k) == "number" and k > t.n then t.n = k end end })
        D = { ContainersSettings = { { StartingItems_10_C6DB208442353E0AA9B5DB892266821A = S } } }
        jig.set_starting(D, LIST)
        SI, SR = S[1][R_INDEX], S[1][R_ROT]
        SI2 = S[2][R_INDEX]
    ''')
    check(L.eval('SI') == 6 and L.eval('SR') is True and L.eval('SI2') == 2, "a not-yet-opened container starts with the same layout")


def loot_skips_containers_gone_since_listed():
    print("loot_skips_containers_gone_since_listed")
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.crumb"] = { at = function() end }
        package.loaded["mirror.ghost"] = { get = function() return GH end, location = function() return { X = 0, Y = 0, Z = 0 } end }
        package.loaded["mirror.game"] = { player = function() return ME end, on_world_reset = function() end }
        GEN, READ = {}, {}
        package.loaded["mirror.jig"] = {
            generate = function(c) GEN[#GEN + 1] = c.name end,
            contents_of = function(c) READ[#READ + 1] = c.name; return {} end,
            encode = function() return "" end, uid_str = function(x) return x end, full_path = function(x) return x end,
            guid = function(x) return x end, flush_ui = function() end,
        }
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        GH, ME = obj({}), obj({})
        local CL = cls("BP_LootContainer_C")
        StaticFindObject = function() return CL end
        function box(name, x)
            local a = obj({ loc = { X = x, Y = 0, Z = 0 }, dying = false })
            a.K2_GetActorLocation = function() return a.loc end
            a.GetClass = function() return CL end
            a.IsA = function() return true end
            a.IsActorBeingDestroyed = function() return a.dying end
            local c = obj({ name = name, GetOwner = function() return a end })
            return c, a
        end
        LIVE = box("live", 500)
        DYING, DA = box("dying", 700)
        MOVED, MA = box("moved", 900)
        local comps = { LIVE, DYING, MOVED }
        util.instances = function() return comps, true end
        loot = require("mirror.loot")
        loot.init({}, "host", { in_world = function() return true end })
        for i = 1, 5 do loot.tick(0.2) end
        DA.dying = true
        loot.guest_arriving()
        -- a car being driven: never where it was when listed (the list is redone on arrival)
        for i = 1, 30 do MA.loc = { X = 900 + i * 100, Y = 0, Z = 0 }; loot.tick(0.2) end
    """)
    check(L.eval("#GEN") == 1 and L.eval("GEN[1]") == "live", "ahead-loading skips a listed container being destroyed or moved away since")
    check(L.eval("#READ") == 1 and L.eval("READ[1]") == "live", "and only that one's contents are read and sent")


def loot_guest(near=False):
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.crumb"] = { at = function() end }
        package.loaded["mirror.ghost"] = { get = function() return nil end, location = function() return nil end }
        package.loaded["mirror.game"] = { player = function() return ME end, on_world_reset = function() end }
        SENT, INBOX = {}, {}
        package.loaded["mirror.events"] = { send = function(self, p) SENT[#SENT + 1] = p end, reliable = function(name)
            return { send = function(self, p) SENT[#SENT + 1] = p end,
                     pump = function(self, fn) local q = INBOX[name] or {}; INBOX[name] = {}; for _, p in ipairs(q) do fn(p) end end }
        end }
        APPLIED = 0
        package.loaded["mirror.jig"] = {
            generate = function() end, contents_of = function() return {} end, flush_ui = function() end,
            encode = function() return "" end, decode = function(s) return { s } end, is_empty = function() return false end,
            uid_str = function(x) return x end, full_path = function(x) return x end, guid = function(x) return x end,
            apply_contents = function(c, list) APPLIED = APPLIED + 1; LAST = list[1]; return 1, (list[1] == "two" and 1 or 0), 0, 0, {} end,
            apply_layout = function() return 0, 0 end,
        }
        util = require("mirror.util")
        HOOKS = {}
        util.ensure_hook = function(name, fn) HOOKS[name] = fn; return true end
        local CL = cls("Container_FuelLoot_GasPump_C")
        StaticFindObject = function() return CL end
        PUMP = obj({ loc = { X = 100, Y = 0, Z = 0 } })
        PUMP.K2_GetActorLocation = function() return PUMP.loc end
        PUMP.GetClass = function() return CL end
        PUMP.IsA = function() return true end
        PUMP.IsActorBeingDestroyed = function() return false end
        COMP = obj({ GetOwner = function() return PUMP end })
        REFRESHED = 0
        ME = obj({ RequestServerData = function() REFRESHED = REFRESHED + 1 end })
        util.instances = function() return { COMP }, true end
        util.find_by_id = function() return PUMP end
        loot = require("mirror.loot")
        loot.init({}, "guest", { in_world = function() return true end })
        loot.tick(0.1)
        REQ = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_RequestData"
        function open() HOOKS[REQ](nil, { get = function() return COMP end }) end
        function qs() local n = 0; for _, p in ipairs(SENT) do if p:sub(1, 2) == "Q " then n = n + 1 end end; return n end
    """)
    return L


def loot_asks_the_host_again_on_every_reopen():
    print("loot_asks_the_host_again_on_every_reopen")
    L = loot_guest()
    L.execute(r"""
        open()
        ID = SENT[1] and SENT[1]:match("^Q (%S+)$")
        INBOX.lootc = { "C " .. tostring(ID) .. " 0 one" }
        loot.tick(0.1)
        for i = 1, 30 do loot.tick(0.1) end
        open()
        loot.tick(0.1)
        INBOX.lootc = { "C " .. tostring(ID) .. " 0 two" }
        loot.tick(0.1)
    """)
    check(L.eval("ID ~= nil"), "first open asks the host for the contents")
    check(L.eval("qs()") == 2, "opening it again later asks again (%d asks)" % L.eval("qs()"))
    check(L.eval("REFRESHED") == 1, "and redraws it when the host's copy changed meanwhile (%d)" % L.eval("REFRESHED"))
    L.execute("open(); loot.tick(0.1)")
    check(L.eval("qs()") == 2, "an open right after (the redraw itself) doesn't ask again")


def loot_first_open_never_undoes_a_take_the_host_has_not_acked(take=True):
    # an older host list (host lagging / gone a while) was taken over 0.3 s after the first open even when the
    # guest had taken something in between: the list still held it, so it came back - the item existed twice
    print("loot_first_open_never_undoes_a_take_the_host_has_not_acked" + ("" if take else " (control: no take)"))
    L = loot_guest()
    L.execute(r"""
        open()
        ID = SENT[1] and SENT[1]:match("^Q (%S+)$")
        package.loaded["mirror.loot"] = nil
        loot = require("mirror.loot")
        loot.init({}, "guest", { in_world = function() return true end })
        loot.tick(0.1)
        SENT = {}
        INBOX.lootc = { "C " .. tostring(ID) .. " 0 stale" }
        loot.tick(0.1)
        for i = 1, 40 do loot.tick(0.1) end
        BEFORE = APPLIED
        open()
        PUMP.BP_JigMultiplayer = COMP
    """)
    if take:
        L.execute(r"""
            HOOKS["/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:JigMP_OnItemRemoved"](
                { get = function() return PUMP end }, { get = function() return "G1" end })
        """)
    L.execute(r"""
        for i = 1, 5 do loot.tick(0.1) end
        STALE = APPLIED - BEFORE
        TAKES = 0
        for _, p in ipairs(SENT) do if p:match("^%S+ G1 0 %d+") then TAKES = TAKES + 1 end end
        INBOX.lootc = { "C " .. tostring(ID) .. " 9 acked" }
        loot.tick(0.1)
    """)
    if not take:
        check(L.eval("STALE") == 1, "control: with no take, the host's list is taken over 0.3 s after the first open")
        return
    check(L.eval("TAKES") == 1, "the take was sent (%d)" % L.eval("TAKES"))
    check(L.eval("STALE") == 0, "the older host list (no ack for the take yet) is NOT taken over after the first open "
          "- it would bring the taken item back (%d)" % L.eval("STALE"))
    check(L.eval("LAST") == "acked", "the host's next list, which has the take, is taken over (%s)" % L.eval("LAST"))


def loot_first_open_takes_over_an_older_list_without_takes():
    loot_first_open_never_undoes_a_take_the_host_has_not_acked(take=False)


def loot_take_without_a_uid_pairing_finds_the_item():
    print("loot_take_without_a_uid_pairing_finds_the_item")
    L = loot_guest()
    L.execute(r"""
        open()
        ID = SENT[1] and SENT[1]:match("^Q (%S+)$")
        TAKEN = {}
        PUMP.BP_JigMultiplayer = COMP
        package.loaded["mirror.jig"].contents_of = function()
            return { { uid = "G1", da = "/Game/X.DA_Bandage", count = 3 }, { uid = "G2", da = "/Game/X.DA_Pills", count = 1 } }
        end
        package.loaded["mirror.jig"].take = function(comp, uid, n) TAKEN[#TAKEN + 1] = uid .. ":" .. n; return true end
        INBOX.loot = { tostring(ID) .. " H9 1 5" }
        loot.tick(0.1)
        NO_DA = #TAKEN
        INBOX.loot = { tostring(ID) .. " H9 1 6 /Game/X.DA_Bandage" }
        loot.tick(0.1)
    """)
    check(L.eval("NO_DA") == 0, "an unknown uid without the item kind takes nothing (as before)")
    check(L.eval("TAKEN[1]") == "G1:2", "with the item kind the same item is taken (%s) - it can't come back with the next list"
          % L.eval("TAKEN[1]"))


def loot_take_for_a_container_the_host_lacks_is_kept():
    # a dropped take left the item in the host's container AND the guest's bag (car trunks, containers not loaded)
    print("loot_take_for_a_container_the_host_lacks_is_kept")
    L = loot_guest()
    L.execute(r"""
        package.loaded["mirror.loot"] = nil
        loot = require("mirror.loot")
        loot.init({}, "host", { in_world = function() return true end })
        FOUND = false
        util.find_by_id = function() return FOUND and PUMP or nil end
        PUMP.BP_JigMultiplayer = COMP
        TAKEN = {}
        package.loaded["mirror.jig"].contents_of = function() return { { uid = "G1", da = "/Game/X.DA_Bandage", count = 3 } } end
        package.loaded["mirror.jig"].take = function(comp, uid, n) TAKEN[#TAKEN + 1] = uid .. ":" .. n; return true end
        ID = "Container_FuelLoot_GasPump_C@10,0,0"
        INBOX.loot = { ID .. " G1 0 5 /Game/X.DA_Bandage" }
        loot.tick(0.1)
        for i = 1, 30 do loot.tick(0.1) end
        BEFORE = #TAKEN
        FOUND = true
        for i = 1, 12 do loot.tick(0.1) end
        AFTER = TAKEN[1]
        for i = 1, 30 do loot.tick(0.1) end
        ONCE = #TAKEN
        -- a put-in for a container that never shows up: given up after 10 min, the guest told (R) so it keeps it
        FOUND = false
        SENT = {}
        INBOX.loot = { "A " .. ID .. " G7 /Game/X.DA_Pills 1 0 0 6 -1:0:-1" }
        loot.tick(0.1)
        R0 = #SENT
        for i = 1, 6100 do loot.tick(0.1) end
        R1 = SENT[1]
        -- audit N14: a take has no refund - after 10 min it still waits and is applied when the container comes
        TAKEN = {}
        INBOX.loot = { ID .. " G1 0 6 /Game/X.DA_Bandage" }
        loot.tick(0.1)
        for i = 1, 6100 do loot.tick(0.1) end
        FOUND = true
        for i = 1, 12 do loot.tick(0.1) end
        LATE = TAKEN[1]
    """)
    check(L.eval("LATE") == "G1:3", "a take whose container comes after 10 min is still applied (%s)" % L.eval("LATE"))
    check(L.eval("BEFORE") == 0, "container not here: the take isn't lost, just waits")
    check(L.eval("AFTER") == "G1:3", "the container shows up: the take is applied (%s)" % L.eval("AFTER"))
    check(L.eval("ONCE") == 1, "and only once (%d)" % L.eval("ONCE"))
    check(L.eval("R0") == 0 and (L.eval("R1") or "").startswith("R " + "Container_FuelLoot_GasPump_C@10,0,0 G7"),
          "a put-in for a container that never comes is handed back after 10 min (%r)" % L.eval("R1"))
    check((L.eval("R1") or "").endswith(" 6"), "the refusal names the put-in's action number (%r)" % L.eval("R1"))


def same_moment_container_takes_keep_one_copy():
    # host and guest take the same item at once: both had it. The host's world decides, the guest gives it back.
    print("same_moment_container_takes_keep_one_copy")
    L = loot_guest()
    L.execute(r"""
        PUMP.BP_JigMultiplayer = COMP
        INV = {}
        package.loaded["mirror.jig"].contents_of = function(c) if c == COMP then return CONT end return INV end
        CONT = { { uid = "G1", da = "/Game/X.DA_Bandage", count = 3 } }
        open(); loot.tick(0.1)
        ID = SENT[1] and SENT[1]:match("^Q (%S+)$")
        INBOX.lootc = { "C " .. tostring(ID) .. " 0 one" }
        loot.tick(0.1)
        CONT = {}
        INV = { { uid = "P5", da = "/Game/X.DA_Bandage", count = 3 } }
        HOOKS["/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:JigMP_OnItemRemoved"]({ get = function() return PUMP end }, { get = function() return "G1" end })
        loot.tick(0.01)   -- (removals go out the next frame: audit N44, uiremove)
        TAKE = nil
        for _, p in ipairs(SENT) do if p:find("^" .. ID:gsub("%p", "%%%0") .. " G1 0") then TAKE = p end end
        GAVE = {}
        package.loaded["mirror.jig"].take = function(c, uid, n, total) GAVE[#GAVE + 1] = uid .. ":" .. n; return true end
        ME.BP_JigMultiplayer = obj({})
        INBOX.loot = { "L " .. ID .. " G1" }
        loot.tick(0.1)
    """)
    check(L.eval("TAKE") is not None, "the guest's take went out (%r)" % L.eval("TAKE"))
    check(L.eval("GAVE[1]") == "P5:3", "host had none of it: the guest gives the 3 bandages back (%s)" % L.eval("GAVE[1]"))
    L.execute('GAVE = {}; INBOX.loot = { "L " .. ID .. " G1" }; loot.tick(0.1)')
    check(L.eval("#GAVE") == 0, "...only once")
    H = loot_guest()
    H.execute(r"""
        package.loaded["mirror.loot"] = nil
        loot = require("mirror.loot")
        loot.init({}, "host", { in_world = function() return true end })
        PUMP.BP_JigMultiplayer = COMP
        package.loaded["mirror.jig"].contents_of = function() return {} end
        SENT = {}
        INBOX.loot = { "Container_FuelLoot_GasPump_C@10,0,0 G1 0 5 /Game/X.DA_Bandage" }
        loot.tick(0.1)
    """)
    check(any(m == "L Container_FuelLoot_GasPump_C@10,0,0 G1" for m in H.eval("SENT").values()),
          "host: a take of an item it has none of is answered with L")


def same_moment_partial_takes_keep_the_total():
    # T10 audit 2026-10-31: a stack of 10, the host takes 3 and the guest 4 within one round trip. Takes said only
    # how many were left: the guest's "left 6" made the host remove 1, the host's "left 7" nothing on the guest -
    # 13 items from 10. A take now carries how many it moved; the host gives back only what it didn't have.
    print("same_moment_partial_takes_keep_the_total")
    L = loot_guest()
    L.execute(r"""
        PUMP.BP_JigMultiplayer = COMP
        package.loaded["mirror.jig"].contents_of = function(c) if c == COMP then return CONT end return {} end
        CONT = { { uid = "G1", da = "/Game/X.DA_Bandage", count = 10 } }
        open(); loot.tick(0.1)
        ID = SENT[1] and SENT[1]:match("^Q (%S+)$")
        INBOX.lootc = { "C " .. tostring(ID) .. " 0 one" }
        loot.tick(0.1)
        COUNT = 6
        COMP.MainJigContainers = { GetArrayNum = function() return 1 end, ForEach = function(self, f)
            f(1, { get = function() return { ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B = { ForEach = function(_, g)
                if COUNT > 0 then g(1, { get = function() return { UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = "G1",
                    ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = { Count_8_DD79AF2A46126A338C8DCCB4616D91CD = COUNT } } end }) end
            end } } end }) end }
        SENT = {}
        HOOKS["/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:JigMP_OnItemRemoved"]({ get = function() return PUMP end }, { get = function() return "G1" end })
        loot.tick(0.01)
        TAKE = nil
        for _, p in ipairs(SENT) do if p:find("^" .. ID:gsub("%p", "%%%0") .. " G1 6") then TAKE = p end end
        -- the host's own take of 3 (sent "left 7, moved 3") reaches the guest, which has 6 left
        TOOK = {}
        package.loaded["mirror.jig"].take = function(c, uid, n, total) TOOK[#TOOK + 1] = uid .. ":" .. n; COUNT = COUNT - n; return true end
        INBOX.loot = { ID .. " G1 7 9 /Game/X.DA_Bandage 3" }
        loot.tick(0.1)
        GUEST_LEFT = COUNT
    """)
    check((L.eval("TAKE") or "").endswith("/Game/X.DA_Bandage 4"), "the guest's take says it moved 4 (%r)" % L.eval("TAKE"))
    check(L.eval("TOOK[1]") == "G1:3" and L.eval("GUEST_LEFT") == 3,
          "guest: the host's take of 3 removes 3 of its 6 (%s, %d left)" % (L.eval("TOOK[1]"), L.eval("GUEST_LEFT")))
    H = loot_guest()
    H.execute(r"""
        package.loaded["mirror.loot"] = nil
        loot = require("mirror.loot")
        loot.init({}, "host", { in_world = function() return true end })
        PUMP.BP_JigMultiplayer = COMP
        package.loaded["mirror.jig"].contents_of = function() return {} end
        COUNT = 7
        COMP.MainJigContainers = { GetArrayNum = function() return 1 end, ForEach = function(self, f)
            f(1, { get = function() return { ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B = { ForEach = function(_, g)
                if COUNT > 0 then g(1, { get = function() return { UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = "G1",
                    ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = { Count_8_DD79AF2A46126A338C8DCCB4616D91CD = COUNT } } end }) end
            end } } end }) end }
        TOOK = {}
        package.loaded["mirror.jig"].take = function(c, uid, n, total) TOOK[#TOOK + 1] = uid .. ":" .. n; COUNT = COUNT - n; return true end
        SENT = {}
        ID = "Container_FuelLoot_GasPump_C@10,0,0"
        INBOX.loot = { ID .. " G1 6 5 /Game/X.DA_Bandage 4" }
        loot.tick(0.1)
        HOST_LEFT, L1 = COUNT, #SENT
        -- the guest took 4 more but only 2 are still here: the host takes 2, the guest gives 2 back
        COUNT = 2
        INBOX.loot = { ID .. " G1 2 6 /Game/X.DA_Bandage 4" }
        loot.tick(0.1)
        TOOK2, GIVE = TOOK[2], SENT[#SENT]
        -- an older message without the moved count: down to "left" as before
        COUNT = 7
        INBOX.loot = { ID .. " G1 6 7 /Game/X.DA_Bandage" }
        loot.tick(0.1)
        TOOK3 = TOOK[3]
    """)
    check(H.eval("TOOK[1]") == "G1:4" and H.eval("HOST_LEFT") == 3 and H.eval("L1") == 0,
          "host: the guest's take of 4 removes 4 of its 7, nothing given back (%s, %d left, %d sent)"
          % (H.eval("TOOK[1]"), H.eval("HOST_LEFT"), H.eval("L1")))
    check(H.eval("TOOK2") == "G1:2" and H.eval("GIVE") == "L Container_FuelLoot_GasPump_C@10,0,0 G1 2",
          "host: 4 taken, 2 here: removes 2 and asks 2 back (%s, %r)" % (H.eval("TOOK2"), H.eval("GIVE")))
    check(H.eval("TOOK3") == "G1:1", "host: a take without the count still goes down to left (%s)" % H.eval("TOOK3"))
    L.execute(r"""
        GAVE = {}
        package.loaded["mirror.jig"].take = function(c, uid, n, total) GAVE[#GAVE + 1] = uid .. ":" .. n; return true end
        ME.BP_JigMultiplayer = obj({})
        package.loaded["mirror.jig"].contents_of = function(c) if c == COMP then return {} end return { { uid = "P5", da = "/Game/X.DA_Bandage", count = 4 } } end
        INBOX.loot = { "L " .. ID .. " G1 2" }
        loot.tick(0.1)
    """)
    check(L.eval("GAVE[1]") == "P5:2", "guest: an L for 2 gives back 2 of the 4 it took (%s)" % L.eval("GAVE[1]"))


def refused_put_in_taken_back_tells_the_host_nothing():
    # T10 audit 2026-10-31: the host had no room for a guest's put-in (R) - it is only in the guest's copy. Taking it
    # back out was sent as a take: the host matched it by kind and removed its OWN same item, or found none and had
    # the guest give it back (lost). And R never acked the put-in, so the host's lists stayed un-taken-over.
    print("refused_put_in_taken_back_tells_the_host_nothing")
    L = loot_guest()
    L.execute(r"""
        PUMP.BP_JigMultiplayer = COMP
        package.loaded["mirror.jig"].contents_of = function(c) if c == COMP then return CONT end return {} end
        CONT = { { uid = "G1", da = "/Game/X.DA_Bandage", count = 2 }, { uid = "G7", da = "/Game/X.DA_Pills", count = 1 } }
        open(); loot.tick(0.1)
        ID = SENT[1] and SENT[1]:match("^Q (%S+)$")
        INBOX.lootc = { "C " .. tostring(ID) .. " 0 one" }
        loot.tick(0.1)
        COUNT = 1
        COMP.MainJigContainers = { GetArrayNum = function() return 1 end, ForEach = function(self, f)
            f(1, { get = function() return { ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B = { ForEach = function(_, g)
                if COUNT > 0 then g(1, { get = function() return { UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = "G1",
                    ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = { Count_8_DD79AF2A46126A338C8DCCB4616D91CD = COUNT } } end }) end
            end } } end }) end }
        -- my last action there (a take of 1 bandage) waits for the host's ack
        SENT = {}
        HOOKS["/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:JigMP_OnItemRemoved"]({ get = function() return PUMP end }, { get = function() return "G1" end })
        loot.tick(0.01)
        S = nil
        for _, p in ipairs(SENT) do S = S or p:match("^" .. ID:gsub("%p", "%%%0") .. " G1 1 (%d+)") end
        -- the host had no room for my pills, refused as that last action
        INBOX.loot = { "R " .. ID .. " G7 /Game/X.DA_Pills " .. tostring(S) }
        loot.tick(0.1)
        -- I take the pills back out: only in my copy
        SENT = {}
        NOW = (NOW or 0) + 1
        HOOKS["/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:JigMP_OnItemRemoved"]({ get = function() return PUMP end }, { get = function() return "G7" end })
        loot.tick(0.01)
        TOLD = 0
        for _, p in ipairs(SENT) do if p:find(" G7 ", 1, true) then TOLD = TOLD + 1 end end
        -- the host's next list (its ack is older than the refused action) is taken over: nothing of mine waits
        APPLIED = 0
        INBOX.lootc = { "C " .. ID .. " 0 two" }
        loot.tick(0.1)
        TAKEN_OVER = APPLIED
    """)
    check(L.eval("S") is not None, "the guest's take went out with its action number (%r)" % L.eval("S"))
    check(L.eval("TOLD") == 0, "taking a refused item back out sends nothing to the host (%d sent)" % L.eval("TOLD"))
    check(L.eval("TAKEN_OVER") == 1, "a refused last action no longer blocks the host's lists (%d taken over)" % L.eval("TAKEN_OVER"))


def stacking_moves_reach_the_other_game():
    # 2026-10-25: nails taken onto the bag's nails stack fired no removed event - the host kept them and
    # every try copied 12 nails; a stack put onto a container's stack never reached the host
    print("stacking_moves_reach_the_other_game")
    L = loot_guest()
    L.execute(r"""
        PUMP.BP_JigMultiplayer = COMP
        COMP.GetOwner = function() return PUMP end
        BAG = obj({ GetOwner = function() return ME end })
        package.loaded["mirror.jig"].contents_of = function(c) if c == COMP then return CONT end return {} end
        CONT = { { uid = "G1", da = "/Game/X.DA_Nails", count = 12 } }
        COUNT = 12
        COMP.MainJigContainers = { GetArrayNum = function() return 1 end, ForEach = function(self, f)
            f(1, { get = function() return { ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B = { ForEach = function(_, g)
                if COUNT > 0 then g(1, { get = function() return { UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = "G1",
                    ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = { Count_8_DD79AF2A46126A338C8DCCB4616D91CD = COUNT } } end }) end
            end } } end }) end }
        open(); loot.tick(0.1)
        ID = SENT[1]:match("^Q (%S+)$")
        INBOX.lootc = { "C " .. ID .. " 0 one" }
        loot.tick(0.1)
        local S = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_RequestStackItem"
        function w(x) return { get = function() return x end } end
        -- nails out of the container onto the bag's stack: all 12 gone from the container
        COUNT = 0
        HOOKS[S](nil, w(COMP), w(BAG), w("G1"), w("P7"), w(99))
        loot.tick(0.1)
        TAKE = nil
        for _, p in ipairs(SENT) do if p:find(" G1 0 ", 1, true) then TAKE = p end end
        -- back onto the container's stack: 12 -> 20
        COUNT = 12
        package.loaded["mirror.loot"].prefetch(PUMP)
        CONT = { { uid = "G1", da = "/Game/X.DA_Nails", count = 12 } }
        open(); loot.tick(3.0)
        COUNT = 20
        HOOKS[S](nil, w(BAG), w(COMP), w("P7"), w("G1"), w(99))
        loot.tick(0.1)
        N = nil
        for _, p in ipairs(SENT) do if p:sub(1, 2) == "N " then N = p end end
    """)
    L.execute(r"""
        -- the host takes 7 of the 20 (applied here), then this guest stacks 4 more onto the 13: N must say 4
        local S = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_RequestStackItem"
        package.loaded["mirror.jig"].take = function(c, uid, n) COUNT = COUNT - n; return true end
        SENT = {}
        INBOX.loot = { ID .. " G1 13 99 /Game/X.DA_Nails" }
        loot.tick(0.1)
        COUNT = 17
        HOOKS[S](nil, w(BAG), w(COMP), w("P8"), w("G1"), w(99))
        loot.tick(0.1)
        N2 = nil
        for _, p in ipairs(SENT) do if p:sub(1, 2) == "N " then N2 = p end end
    """)
    check(" G1 4 " in (L.eval("N2") or ""), "after the other player's take the stacked amount is still right (%r)" % L.eval("N2"))
    L.execute(r"""
        -- split 5 of the 17 into the bag: the old stack's new count (12) goes to the host as a take
        SENT = {}
        COUNT = 12
        HOOKS["/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_RequestSplitItem"](
            nil, w(COMP), w(BAG), w("G1"), w("C0"), w(0), w(5), w(false))
        loot.tick(0.1)
        SPLIT = nil
        for _, p in ipairs(SENT) do if p:find(" G1 12 ", 1, true) then SPLIT = p end end
    """)
    check(L.eval("SPLIT") is not None, "a split out of the container tells the host what's left (%r)" % L.eval("SPLIT"))
    check(L.eval("TAKE") is not None, "taken onto a stack in the bag: the take goes to the host (%r)" % L.eval("TAKE"))
    check((L.eval("N") or "").startswith("N ") and " G1 8 " in (L.eval("N") or ""),
          "stacked onto the container's stack: the 8 added go out as N (%r)" % L.eval("N"))
    H = loot_guest()
    H.execute(r"""
        package.loaded["mirror.loot"] = nil
        loot = require("mirror.loot")
        loot.init({}, "host", { in_world = function() return true end })
        PUMP.BP_JigMultiplayer = COMP
        SET = nil
        COMP.ServerUpdateCountByUID = function(self, g, n) SET = n end
        COMP.ClientUpdateCount = function() end
        COMP.MainJigContainers = { GetArrayNum = function() return 1 end, ForEach = function(self, f)
            f(1, { get = function() return { ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B = { ForEach = function(_, g)
                g(1, { get = function() return { UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = "1_2_3_4",
                    ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = { Count_8_DD79AF2A46126A338C8DCCB4616D91CD = 12 } } end })
            end } } end }) end }
        package.loaded["mirror.jig"].guid = function(u) return u end
        INBOX.loot = { "N Container_FuelLoot_GasPump_C@10,0,0 1_2_3_4 8 5 /Game/X.DA_Nails" }
        loot.tick(0.1)
    """)
    check(H.eval("SET") == 20, "host: N raises its stack by the count stacked (%r)" % H.eval("SET"))


def one_take_fires_both_removed_hooks_and_is_sent_once():
    # 2026-10-25 reports: the game fires JigMP_OnItemRemoved and JigMP_OnMainContainerItemRemoved for one take;
    # the echo reached the host as a second take of an item already gone and it answered L - every take refunded
    print("one_take_fires_both_removed_hooks_and_is_sent_once")
    L = loot_guest()
    L.execute(r"""
        PUMP.BP_JigMultiplayer = COMP
        package.loaded["mirror.jig"].contents_of = function(c) return CONT end
        CONT = { { uid = "G1", da = "/Game/X.DA_Bandage", count = 1 } }
        open(); loot.tick(0.1)
        ID = SENT[1]:match("^Q (%S+)$")
        INBOX.lootc = { "C " .. ID .. " 0 one" }
        loot.tick(0.1)
        CONT = {}
        local C = "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C"
        local a, u = { get = function() return PUMP end }, { get = function() return "G1" end }
        HOOKS[C .. ":JigMP_OnItemRemoved"](a, u)
        HOOKS[C .. ":JigMP_OnMainContainerItemRemoved"](a, nil, u)
        function takes() local n = 0; for _, p in ipairs(SENT) do if p:find(" G1 0 ", 1, true) then n = n + 1 end end; return n end
        loot.tick(0.01)   -- (removals go out the next frame: audit N44, uiremove)
        ONCE = takes()
        loot.tick(1.0)
        HOOKS[C .. ":JigMP_OnItemRemoved"](a, u)
        loot.tick(0.01)
        LATER = takes()
    """)
    check(L.eval("ONCE") == 1, "both hooks for one take send it once (%d)" % L.eval("ONCE"))
    check(L.eval("LATER") == 2, "a real take of it later (put back, taken again) still goes out")
    H = loot_guest()
    H.execute(r"""
        package.loaded["mirror.loot"] = nil
        loot = require("mirror.loot")
        loot.init({}, "host", { in_world = function() return true end })
        PUMP.BP_JigMultiplayer = COMP
        HAVE = { { uid = "G1", da = "/Game/X.DA_Bandage", count = 1 } }
        package.loaded["mirror.jig"].contents_of = function() return HAVE end
        package.loaded["mirror.jig"].take = function() HAVE = {}; return true end
        COMP.MainJigContainers = { GetArrayNum = function() return 1 end, ForEach = function(self, f)
            f(1, { get = function() return { ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B = { ForEach = function(_, g)
                for _, it in ipairs(HAVE) do g(1, { get = function() return {
                    UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = it.uid,
                    ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = { Count_8_DD79AF2A46126A338C8DCCB4616D91CD = it.count } } end }) end
            end } } end }) end }
        SENT = {}
        INBOX.loot = { "Container_FuelLoot_GasPump_C@10,0,0 G1 0 5 /Game/X.DA_Bandage",
                       "Container_FuelLoot_GasPump_C@10,0,0 G1 0 6 /Game/X.DA_Bandage" }
        loot.tick(0.1)
    """)
    check(not any(m.startswith("L ") for m in H.eval("SENT").values()),
          "host: a repeat of a take it just applied isn't answered with L")


def item_used_out_of_a_container_is_a_take():
    # report 20261027-171134: ripping clothes in a shared trash bag fires only JigMP_OnItemConsumed - the host
    # kept the clothes and its next list put them back on the guest's copy (rags + clothes, every rip)
    print("item_used_out_of_a_container_is_a_take")
    L = loot_guest()
    L.execute(r"""
        PUMP.BP_JigMultiplayer = COMP
        package.loaded["mirror.jig"].contents_of = function(c) return CONT end
        CONT = { { uid = "G1", da = "/Game/X.DA_BlackShirt", count = 1 } }
        open(); loot.tick(0.1)
        ID = SENT[1]:match("^Q (%S+)$")
        INBOX.lootc = { "C " .. ID .. " 0 one" }
        loot.tick(0.1)
        CONT = {}
        local C = "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C"
        function takes() local n = 0; for _, p in ipairs(SENT) do if p:find(" G1 0 ", 1, true) then n = n + 1 end end; return n end
        HOOKS[C .. ":JigMP_OnItemConsumed"]({ get = function() return PUMP end },
            { get = function() return { UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = "G1" } end })
        SAME_FRAME = takes()
        loot.tick(0.1)
        AFTER = takes()
    """)
    check(L.eval("SAME_FRAME") == 0, "a consume is looked at the next frame (the pre-hook runs before the count changes)")
    check(L.eval("AFTER") == 1, "an item used up inside a shared container is sent as a take (%d)" % L.eval("AFTER"))
    # a guest disassembling at a crafted bench: the bench consumes the input via SERVER_RequestConsumeItem and
    # Buildable_DisassemblyWorkbench inherits Buildable_MASTER's JigMP_OnItemConsumed (output + input kept on 0.13.2)
    check(L.eval('HOOKS["/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C:JigMP_OnItemConsumed"] ~= nil'),
          "a disassembly bench's consumed input is hooked (Buildable_MASTER)")


def player_rip_in_a_container_is_a_take():
    # report 20261027-205518 (0.13.7): a guest's rips/reads in a shared bin came back 6x - a player's consume fires
    # JigMP_OnItemConsumed on the PLAYER (HandleLocalRequestConsumeItem calls it on the asking comp's owner), never on
    # the container; only the container comp's HandleLocalRequestConsumeItem says which container
    print("player_rip_in_a_container_is_a_take")
    L = loot_guest()
    L.execute(r"""
        PUMP.BP_JigMultiplayer = COMP
        package.loaded["mirror.jig"].contents_of = function(c) return CONT end
        CONT = { { uid = "G1", da = "/Game/X.DA_BlackShirt", count = 1 }, { uid = "G2", da = "/Game/X.DA_Book", count = 1 } }
        open(); loot.tick(0.1)
        ID = SENT[1]:match("^Q (%S+)$")
        INBOX.lootc = { "C " .. ID .. " 0 one" }
        loot.tick(0.1)
        CONT = { { uid = "G2", da = "/Game/X.DA_Book", count = 1 } }
        function takes(u) local n = 0; for _, p in ipairs(SENT) do if p:find(" " .. u .. " 0 ", 1, true) then n = n + 1 end end; return n end
        local H = HOOKS["/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:HandleLocalRequestConsumeItem"]
        HOOKED = H ~= nil
        H({ get = function() return COMP end }, { get = function() return "G1" end })
        loot.tick(0.1)
        AFTER = takes("G1")
        -- one consume seen by the container's own event too (a bench consuming its own input): one take
        CONT = {}
        HOOKS["/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:JigMP_OnItemConsumed"]({ get = function() return PUMP end },
            { get = function() return { UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = "G2" } end })
        H({ get = function() return COMP end }, { get = function() return "G2" end })
        loot.tick(0.1)
        BOTH = takes("G2")
    """)
    check(L.eval("HOOKED") is True, "the container component's HandleLocalRequestConsumeItem is hooked")
    check(L.eval("AFTER") == 1, "a player's rip inside a shared container is sent as a take (%d)" % L.eval("AFTER"))
    check(L.eval("BOTH") == 1, "the container's own event and the component hook for one consume send one take (%d)" % L.eval("BOTH"))


def bench_output_made_on_a_guest_reaches_the_host():
    # user 2026-10-31: a guest's decrafted items appear in the bench's lower grid, then despawn. The bench UI adds them
    # with JigTryAddItemSomewhere (AddNewItemToSlot / CLIENT_UpdateCount: no added event), so the host never got them
    # and its list after the input's consume took them away
    print("bench_output_made_on_a_guest_reaches_the_host")
    L = loot_guest()
    L.execute(r"""
        PUMP.BP_JigMultiplayer = COMP
        local J = package.loaded["mirror.jig"]
        J.contents_of = function(c) return CONT end
        J.subtree = function(c, uid) return { { uid = uid } } end
        J.worth_sending = function() return false end
        CONT = { { uid = "G1", da = "/Game/X.DA_Rifle", count = 1 }, { uid = "G5", da = "/Game/X.DA_Screws", count = 4 } }
        open(); loot.tick(0.1)
        ID = SENT[1]:match("^Q (%S+)$")
        INBOX.lootc = { "C " .. ID .. " 0 one" }
        loot.tick(0.1)
        SENT = {}
        local H = HOOKS["/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:JigTryAddItemSomewhere"]
        HOOKED = H ~= nil
        local function made(da) if H then H({ get = function() return COMP end }, { get = function() return COMP end }, { get = function() return da end }) end end
        -- the bench makes 3 scrap (a new item) and 2 screws (onto the stack there), then consumes the rifle
        CONT = { { uid = "G1", da = "/Game/X.DA_Rifle", count = 1 }, { uid = "G5", da = "/Game/X.DA_Screws", count = 6 },
                 { uid = "G9", da = "/Game/X.DA_Scrap", count = 3 } }
        made("/Game/X.DA_Scrap"); made("/Game/X.DA_Screws")
        SAME_FRAME = #SENT
        loot.tick(0.1)
        function sent(pat) local n = 0; for _, p in ipairs(SENT) do if p:find(pat) then n = n + 1 end end; return n end
        PUTS = sent("^A %S+ G9 /Game/X%.DA_Scrap 3 ")
        STACKED = sent("^N %S+ G5 2 ")
        RIFLE = sent("G1")
        -- the same kind made again later: only the new one goes, the scrap already sent doesn't go twice
        CONT[#CONT + 1] = { uid = "G10", da = "/Game/X.DA_Scrap", count = 1 }
        made("/Game/X.DA_Scrap")
        loot.tick(0.1)
        AGAIN = sent("^A %S+ G9 ")
        NEW = sent("^A %S+ G10 ")
    """)
    check(L.eval("HOOKED") is True, "JigTryAddItemSomewhere is hooked")
    check(L.eval("SAME_FRAME") == 0, "an item a bench makes is looked at the next frame (%d sent at once)" % L.eval("SAME_FRAME"))
    check(L.eval("PUTS") == 1, "a guest's bench output is sent to the host as a put-in (%d)" % L.eval("PUTS"))
    check(L.eval("STACKED") == 1, "bench output added onto a stack there is sent as N 2 (%d)" % L.eval("STACKED"))
    check(L.eval("RIFLE") == 0, "items the bench didn't make aren't sent (%d)" % L.eval("RIFLE"))
    check(L.eval("AGAIN") == 1 and L.eval("NEW") == 1,
          "made again: only the new item is sent (old %d, new %d)" % (L.eval("AGAIN"), L.eval("NEW")))


def lights_come_back_on_a_respawned_ghost():
    # audit N37: get_blob hands out the light blob only when it changes - every save respawns the ghost, which stayed dark
    print("lights_come_back_on_a_respawned_ghost")
    L = lua()
    L.execute(r"""
        package.loaded["mirror.log"] = setmetatable({}, { __index = function() return function() end end })
        package.loaded["mirror.util"] = { valid = function(o) return type(o) == "table" end,
            safe = function(fn, _, ...) return fn(...) end, cdo = function() return nil end, rot = function() return {} end }
        StaticFindObject = function() return nil end
        function light()
            local fl = { Intensity = 0, AttenuationRadius = 0 }
            function fl:SetIntensity(v) self.Intensity = v end
            function fl:SetAttenuationRadius(v) self.AttenuationRadius = v end
            function fl:SetLightFunctionMaterial() end
            function fl:K2_SetWorldRotation() end
            return fl
        end
        ME = { Flashlight = light() }
        package.loaded["mirror.game"] = { player = function() return ME end }
        GEN, GHOST = 1, { Flashlight = light(), K2_GetActorLocation = function() return {} end }
        package.loaded["mirror.ghost"] = { get = function() return GHOST end, generation = function() return GEN end }
        PENDING = "800.0 1500 -"
        package.loaded["mirror.link"] = { put_blob = function() end,
            get_blob = function(n) if n == "light" then local b = PENDING; PENDING = nil; return b end end }
        package.loaded["mirror.audio"] = { attenuation_for = function() return nil end }
        lights = require("mirror.lights")
        lights.tick(0.3, nil)
        FIRST = GHOST.Flashlight.Intensity
        GEN, GHOST = 2, { Flashlight = light(), K2_GetActorLocation = function() return {} end }
        for _ = 1, 5 do lights.tick(0.3, nil) end
        AFTER = GHOST.Flashlight.Intensity
    """)
    check(L.eval("FIRST") == 800, "the other player's light is on on the first ghost (%s)" % L.eval("FIRST"))
    check(L.eval("AFTER") == 800, "after a ghost respawn with an unchanged blob the light is still on (%s)" % L.eval("AFTER"))


def perf_run_puts_the_outer_step_back():
    # audit N30: after fire.tick's sub-timers the crash step stayed "f.hurts" for the rest of fire.tick
    print("perf_run_puts_the_outer_step_back")
    L = lua()
    L.execute(r"""
        package.loaded["mirror.log"] = setmetatable({}, { __index = function() return function() end end })
        CUR = nil
        package.loaded["mirror.crumb"] = { at = function(s) CUR = s end, current = function() return CUR end }
        perf = require("mirror.perf")
        perf.frame_begin()
        perf.run("fire", function() perf.run("f.hurts", function() end); IN = CUR end)
        AFTER = CUR
        perf.run("pose", function() end)
        TOP = CUR
    """)
    check(L.eval("IN") == "fire", "after a nested run the outer step is back (%s)" % L.eval("IN"))
    check(L.eval("TOP") == "pose", "a top-level run leaves its own step (%s)" % L.eval("TOP"))
    # spikes of the same size in unrelated parts (live 2026-10-30): a slow part says when a Lua GC ran inside it
    L.execute(r"""
        LINES = {}
        package.loaded["mirror.log"] = setmetatable({ info = function(s) LINES[#LINES + 1] = s end },
            { __index = function() return function() end end })
        package.loaded["mirror.perf"] = nil
        perf = require("mirror.perf")
        local function busy() local t = os.clock(); while os.clock() - t < 0.035 do end end
        JUNK = {}; for i = 1, 40000 do JUNK[i] = { i, tostring(i) } end
        perf.frame_begin()
        perf.run("plain", busy)
        perf.run("fire", function() JUNK = nil; collectgarbage("collect"); busy() end)
        perf.frame_end(31)
    """)
    lines = list(L.eval("LINES").values())
    plain = [s for s in lines if s.startswith("perf: plain took")]
    fire = [s for s in lines if s.startswith("perf: fire took")]
    check(plain and "GC" not in plain[0], "a slow part without a collection says only its time (%s)" % plain)
    check(fire and "a Lua GC ran inside it" in fire[0], "a slow part with a collection inside says so (%s)" % fire)
    check(any("inside 1 slow part(s)" in s for s in lines), "the 30 s report counts them")
    # live 2026-10-31: the 8 listed parts were about half of "mod 2.09 ms/frame" - the rest and the time outside
    # any part are given, sub-parts not counted twice
    L.execute(r"""
        LINES = {}
        package.loaded["mirror.perf"] = nil
        perf = require("mirror.perf")
        local function busy(ms) local t = os.clock(); while os.clock() - t < ms / 1000 do end end
        perf.frame_begin()
        for i = 1, 9 do perf.run("p" .. i, function() busy(12 - i); if i == 1 then perf.run("sub", busy, 6.5) elseif i == 2 then perf.run("sub2", busy, 1) end end) end
        local s = perf.start(); busy(4.5); perf.stop("span", s)
        busy(20)
        perf.frame_end(31)
    """)
    import re
    rep = [s for s in L.eval("LINES").values() if s.startswith("perf: mod")]
    m = re.search(r"(\d+) more parts ([\d.]+), outside any part (-?[\d.]+)", rep[0]) if rep else None
    # (no marks: the 20 ms outside the parts is "glue start". Listed: glue start, p1-p5, sub, p6; left out: p7 5 ms,
    # a caller-timed span 4.5 ms, p8 4 ms, p9 3 ms - and sub2 inside p2)
    check(m is not None and m.group(1) == "4", "the report counts the top-level parts it left out, not sub-parts (%s)" % (m and m.group(0)))
    check(m is not None and 15.0 <= float(m.group(2)) <= 18.5, "with their time (%s)" % (m and m.group(2)))
    g = re.search(r"glue start ([\d.]+) \(max", rep[0]) if rep else None
    check(g is not None and 17.0 <= float(g.group(1)) <= 23.0, "the time outside the parts is glue (%s)" % (g and g.group(1)))
    check(m is not None and abs(float(m.group(3))) <= 0.6, "and nothing is left outside, nor counted twice (%s)" % (m and m.group(3)))
    # kit 2026-10-31: still 0.66 ms/frame outside every part on both games - phase1's step marks time the code
    # between them, without the parts run inside
    L.execute(r"""
        LINES = {}
        package.loaded["mirror.perf"] = nil
        perf = require("mirror.perf")
        local function busy(ms) local t = os.clock(); while os.clock() - t < ms / 1000 do end end
        perf.frame_begin()
        busy(2); perf.glue("a")
        perf.run("x", busy, 5); busy(3); perf.glue("b")
        busy(4)
        perf.frame_end(31)
    """)
    rep = [s for s in L.eval("LINES").values() if s.startswith("perf: mod")]
    def part(n):
        g = re.search(re.escape(n) + r" ([\d.]+) \(max", rep[0]) if rep else None
        return float(g.group(1)) if g else None
    o = re.search(r"outside any part (-?[\d.]+)", rep[0]) if rep else None
    check(part("glue start") is not None and 1.5 <= part("glue start") <= 3.0, "the code before the first mark is its own glue (%s)" % part("glue start"))
    check(part("glue a") is not None and 2.5 <= part("glue a") <= 4.0, "glue leaves out the parts run inside it (%s)" % part("glue a"))
    check(part("glue b") is not None and 3.5 <= part("glue b") <= 5.0, "the last mark runs to the frame's end (%s)" % part("glue b"))
    check(o is not None and abs(float(o.group(1))) <= 0.6, "and nothing is left outside (%s)" % (o and o.group(1)))


def fs_write_is_whole_or_old():
    # audit N45: fs.write was truncate + write - a crash mid-write emptied beds / bag owners / Realm sidecars
    print("fs_write_is_whole_or_old")
    d = tempfile.mkdtemp()
    try:
        L = lua()
        p = os.path.join(d, "beds.txt").replace("\\", "/")
        L.execute('fs = require("mirror.fs"); P = ...', p)
        check(L.eval('fs.write(P, "one\\n")') is True and L.eval("fs.read(P)") == "one\n", "a write returns true and reads back")
        check(L.eval('fs.write(P, "two\\n")') is True and L.eval("fs.read(P)") == "two\n" and not os.path.exists(p + ".new"),
              "a rewrite replaces the file and leaves no .new")
        os.remove(p)
        with open(p + ".new", "wb") as f: f.write(b"three\n")
        check(L.eval("fs.read(P)") == "three\n" and os.path.exists(p), "a crash after remove (only .new left) is recovered on read")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def host_rules_and_mod_list_survive_a_full_disk():
    """Save audit 2026-10-30: hostrules (a Realm's rules travel with its world) and modlist (UE4SS starts SurrounSync
    from mods.txt) wrote their files in place - a write that failed half-way (a full disk) left them empty."""
    print("host_rules_and_mod_list_survive_a_full_disk")
    d = tempfile.mkdtemp()
    try:
        L = lua()
        rules = os.path.join(d, "rules.txt").replace("\\", "/")
        with open(rules, "wb") as f: f.write(b"pvp on\n")
        L.execute(r'''
            package.loaded["mirror.notify"] = { show = function() end }
            hr = require("mirror.hostrules")
            hr.init(function() return "host" end)
            hr.use_file(...)
            REAL_OPEN = io.open
            -- a full disk: files open for writing, nothing written reaches them
            function FULL_DISK()
                io.open = function(p, m)
                    local f, e = REAL_OPEN(p, m)
                    if not f or not tostring(m):find("w") then return f, e end
                    return { write = function() return nil, "No space left on device" end, close = function() f:close(); return true end }
                end
            end
        ''', rules)
        before = L.eval('hr.my_value("pvp")')
        L.execute('FULL_DISK(); hr.toggle("pvp"); io.open = REAL_OPEN')
        with open(rules, "rb") as f: kept = f.read()
        check(before == "on" and b"pvp on" in kept, "host rules: a failed save keeps the old file (%r)" % kept)
        w64 = os.path.join(d, "SurrounDead", "Binaries", "Win64")
        mods = os.path.join(w64, "ue4ss", "Mods")
        for m in ("SurrounSync", "AimRun"):
            os.makedirs(os.path.join(mods, m))
        os.makedirs(os.path.join(d, "SurrounDead", "Content", "Paks"))
        with open(os.path.join(mods, "mods.txt"), "wb") as f: f.write(b"SurrounSync : 1\r\nAimRun : 1\r\n")
        g = L.globals()
        g.pydirs = lambda p: L.table_from(sorted(x for x in os.listdir(p) if os.path.isdir(os.path.join(p, x)))) if os.path.isdir(p) else None
        g.pyfiles = lambda p: L.table_from(sorted(x for x in os.listdir(p) if not os.path.isdir(os.path.join(p, x)))) if os.path.isdir(p) else None
        g.W64, g.PAKS = w64, os.path.join(d, "SurrounDead", "Content", "Paks")
        L.execute('ml = require("mirror.modlist"); ml.configure{ io_root = W64 .. "\\\\", list_win64 = W64, list_paks = PAKS, reset = true,'
                  ' lister = { dirs = function(p) return pydirs(p) end, files = function(p) return pyfiles(p) end } }; ml.init()')
        L.execute('FULL_DISK(); SET = ml.set("AimRun", false); io.open = REAL_OPEN')
        with open(os.path.join(mods, "mods.txt"), "rb") as f: kept = f.read()
        check(b"SurrounSync : 1" in kept, "mods.txt: a failed write keeps SurrounSync in it (%r)" % kept)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def utf8_cut_never_splits_a_character():
    # audit: chat cut a long Cyrillic/emoji line mid-character (200 bytes)
    print("utf8_cut_never_splits_a_character")
    L = lua()
    L.execute(r"""
        util = require("mirror.util")
        local s = string.rep("\208\191\209\128", 120) .. "\240\159\152\128"   -- 2-byte letters + a 4-byte emoji
        local c = util.utf8_cut(s, 201)
        ODD, VALID = #c, utf8.len(c) ~= nil
        SHORT = util.utf8_cut("abc", 200) == "abc"
        EMOJI = util.utf8_cut("ab\240\159\152\128", 4) == "ab"
    """)
    check(L.eval("ODD") == 200 and L.eval("VALID"), "a cut at an odd byte drops the half letter (%d bytes)" % L.eval("ODD"))
    check(L.eval("SHORT"), "a short text is kept")
    check(L.eval("EMOJI"), "a cut inside an emoji drops the whole emoji")


def ui_no_room_removal_is_not_a_take():
    # audit N44: when the container UI can't place an item, the game removes it via comp.SERVER_RequestRemoveItem(comp, ..)
    # -> HandleLocalRequestConsumeItem + the container's JigMP_OnItemConsumed - a take sent for it deleted the host's item
    print("ui_no_room_removal_is_not_a_take")
    L = loot_guest()
    L.execute(r"""
        PUMP.BP_JigMultiplayer = COMP
        package.loaded["mirror.jig"].contents_of = function(c) return CONT end
        CONT = { { uid = "G1", da = "/Game/X.DA_BlackShirt", count = 1 }, { uid = "G2", da = "/Game/X.DA_Book", count = 1 } }
        open(); loot.tick(0.1)
        ID = SENT[1]:match("^Q (%S+)$")
        INBOX.lootc = { "C " .. ID .. " 0 one" }
        loot.tick(0.1)
        function takes(u) local n = 0; for _, p in ipairs(SENT) do if p:find(" " .. u .. " 0 ", 1, true) then n = n + 1 end end; return n end
        local P = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:"
        local R, H = HOOKS[P .. "SERVER_RequestRemoveItem"], HOOKS[P .. "HandleLocalRequestConsumeItem"]
        local E = HOOKS["/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:JigMP_OnItemConsumed"]
        HOOKED = R ~= nil
        local comp = { get = function() return COMP end }
        CONT = { { uid = "G2", da = "/Game/X.DA_Book", count = 1 } }
        -- the order seen in-game (kit 2026-10-27): UE4SS runs a Blueprint "pre" hook after the body, so the inner
        -- consume / removed hooks fire first and the SERVER_RequestRemoveItem marker last
        H(comp, { get = function() return "G1" end })
        E({ get = function() return PUMP end }, { get = function() return { UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = "G1" } end })
        HOOKS["/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:JigMP_OnItemRemoved"]({ get = function() return PUMP end }, { get = function() return "G1" end })
        R(comp, comp, { get = function() return "G1" end })
        loot.tick(0.1)
        UI = takes("G1")
        -- a remove request from ANOTHER component is not the UI path: the rip after it is still a take
        local other = obj({})
        CONT = {}
        R(comp, { get = function() return other end }, { get = function() return "G2" end })
        H(comp, { get = function() return "G2" end })
        loot.tick(0.1)
        RIP = takes("G2")
    """)
    check(L.eval("HOOKED") is True, "SERVER_RequestRemoveItem is hooked")
    check(L.eval("UI") == 0, "the UI's no-room removal sends no take (%d)" % L.eval("UI"))
    check(L.eval("RIP") == 1, "a rip after another comp's remove request is still a take (%d)" % L.eval("RIP"))


def crumb_keeps_the_last_64_steps():
    # 2026-10-27: one crash step alone didn't explain a guest's freezes - mirror_steps.txt keeps the last 64, in order
    print("crumb_keeps_the_last_64_steps")
    d, old = tempfile.mkdtemp(), os.getcwd()
    os.chdir(d)
    try:
        L = lua()
        L.execute(r"""
            package.loaded["mirror.crumb"] = nil
            local crumb = require("mirror.crumb")
            crumb.start()
            for i = 1, 70 do crumb.at("step " .. i) end
            crumb.at("step 70")
        """)
        raw = open("mirror_steps.txt", "rb").read()
        rows = [r for r in raw.split(b"\n") if r.strip()]
        seqs = sorted(int(r.split()[0]) for r in rows)
        check(len(raw) == 64 * 100, "64 fixed-width slots (%d bytes)" % len(raw))
        check(seqs == list(range(7, 71)), "the newest 64 steps are kept (%s..%s)" % (seqs[0], seqs[-1]))
        newest = [r for r in rows if r.split()[0] == b"70"][0]
        check(newest.rstrip().endswith(b"step 70"), "each line ends in its step (%r)" % newest[:60])
        check(open("mirror_step.txt").read().rstrip().endswith("step 70"), "mirror_step.txt still holds the current step")
        L.execute(r"""
            -- (a new game run: the last run's files are closed - Windows can't rename an open file)
            package.loaded["mirror.crumb"] = nil
            collectgarbage(); collectgarbage()
            local crumb = require("mirror.crumb")
            PREV = crumb.start()
            crumb.at("next run")
        """)
        check(os.path.exists("mirror_steps.1.txt") and len(open("mirror_steps.1.txt", "rb").read()) == 64 * 100,
              "the last run's steps are kept as mirror_steps.1.txt")
        check(str(L.eval("PREV")).rstrip().endswith("step 70"), "the last run's final step is still reported at start")
        # player report 2026-10-31: crash 23:14, three more runs, report 01:05 - the crash run's steps were gone
        for i in range(3):
            L.execute(r"""
                package.loaded["mirror.crumb"] = nil
                collectgarbage(); collectgarbage()
                local crumb = require("mirror.crumb")
                crumb.start()
                crumb.at("run %d")
            """ % (i + 3))
        kept = {n: open(n).read().strip() for n in ("mirror_step.1.txt", "mirror_step.2.txt", "mirror_step.3.txt")}
        check(kept["mirror_step.1.txt"].endswith("run 4") and kept["mirror_step.2.txt"].endswith("run 3")
              and kept["mirror_step.3.txt"].endswith("next run"),
              "the last three runs' steps are kept, newest first (%r)" % kept)
        check(not os.path.exists("mirror_step.4.txt") and os.path.exists("mirror_steps.3.txt"),
              "...no more than three, for the step ring too")
    finally:
        os.chdir(old)
        shutil.rmtree(d, ignore_errors=True)


def coop_tab_in_a_realm_has_nothing_of_it():
    # user 2026-10-30: co-op and Realms are fully separate - in a Realm the CO-OP tab said "In K3YBOARD32's world"
    # with LEAVE CO-OP; now it shows no session and no controls (the REALMS tab has all of it)
    print("coop_tab_in_a_realm_has_nothing_of_it")
    L = lua()
    L.execute(r"""
        local any = { __index = function() return function() end end }
        local function stub(t) return setmetatable(t or {}, any) end
        for _, n in ipairs({ "util", "game", "notify", "menu_backups", "instance", "hostrules", "mysettings",
                             "modlist", "itemclean", "names", "voice", "chat", "teleport", "compat", "version" }) do
            package.loaded["mirror." .. n] = stub()
        end
        ROLE, STATE, REALM_ID, HOSTING = "guest", "joined", nil, nil
        package.loaded["mirror.link"] = stub({ kind = function() return "steam" end, peer_name = function() return "K3YBOARD32" end,
            lobby = function() return { players = {} } end, bridge_cmd = function() return true end })
        package.loaded["mirror.session"] = stub({ state = function() return STATE end, realm_joined = function() return REALM_ID end })
        package.loaded["mirror.phase1"] = stub({ started = function() return ROLE end, connected = function() return true end })
        package.loaded["mirror.realmplay"] = stub({ hosting = function() return HOSTING end })
        package.loaded["mirror.realm"] = stub({ find = function(id) return id == "7K2M9P4Q1Z" and { name = "Camp Test" } or nil end,
            code = function(id) return "R-" .. id end })
        package.loaded["mirror.journal_tab"] = stub({ configure = function(t) TAB = t end })
        ModifierKey = { CONTROL = 1 }
        menu = require("mirror.menu")
        menu.init({})
        M = TAB.model()
    """)
    check(L.eval("M.headline") == "IN K3YBOARD32'S WORLD" and L.eval("M.show_leave") is True,
          "plain co-op: the host's world and LEAVE CO-OP, as before")
    def inert(who):
        check(L.eval("M.headline") == "NOT IN CO-OP" and L.eval("M.realm_session") is True
              and "K3YBOARD32" not in L.eval("M.detail") and "K3YBOARD32" not in L.eval("M.status"),
              "%s: the CO-OP tab shows no session (%s / %s)" % (who, L.eval("M.headline"), L.eval("M.detail")))
        check(not any(L.eval("M." + k) for k in ("show_leave", "show_stop", "show_host", "show_join_local", "show_chat"))
              and L.eval("#M.requests") == 0 and L.eval("M.allowed") == 0, "%s: and no co-op controls" % who)
    L.execute('REALM_ID = "7K2M9P4Q1Z"; M = TAB.model()')
    inert("a Realm guest")
    L.execute('ROLE, REALM_ID, HOSTING = "host", nil, "Camp Test"; M = TAB.model()')
    inert("a Realm host")
    L.execute('HOSTING = nil; M = TAB.model()')
    check(L.eval("M.headline") == "HOSTING" and L.eval("M.show_stop") is True, "plain hosting unchanged")


def unanswered_join_keeps_the_friends_list():
    # player report: asking to join someone who never accepts switched the CO-OP tab to just the chat - the
    # friends list and code box were gone (role was "guest" from the moment of asking)
    print("unanswered_join_keeps_the_friends_list")
    L = lua()
    L.execute(r"""
        local any = { __index = function() return function() end end }
        local function stub(t) return setmetatable(t or {}, any) end
        for _, n in ipairs({ "util", "game", "notify", "menu_backups", "instance", "hostrules", "mysettings",
                             "modlist", "itemclean", "names", "voice", "chat", "teleport", "compat", "version" }) do
            package.loaded["mirror." .. n] = stub()
        end
        CMDS = {}
        ROLE, CONNECTED, STATE = nil, false, "idle"
        package.loaded["mirror.link"] = stub({ kind = function() return "steam" end, peer_name = function() return "Bob" end,
            lobby = function() return { hosts = { { id = "765", name = "Bob" } } } end,
            bridge_cmd = function(c) CMDS[#CMDS + 1] = c; return true end })
        package.loaded["mirror.session"] = stub({ state = function() return STATE end })
        package.loaded["mirror.phase1"] = stub({ started = function() return ROLE end, connected = function() return CONNECTED end,
            init = function(c, r) ROLE = r end })
        package.loaded["mirror.journal_tab"] = stub({ configure = function(t) TAB = t end })
        ModifierKey = { CONTROL = 1 }
        menu = require("mirror.menu")
        menu.init({})
        TAB.act.join("765", "Bob")
        M1 = TAB.model()
        CONNECTED = true
        M2 = TAB.model()
        CONNECTED = false
        TAB.act.join("765", "Bob")
    """)
    check(L.eval("ROLE") == "guest", "asking to join makes this game a guest")
    check(L.eval("M1.in_coop") is False and L.eval("M1.show_chat") is False,
          "while the host hasn't accepted, the tab keeps the friends list and hides the chat")
    check(L.eval("M2.in_coop") is True and L.eval("M2.show_chat") is True, "once connected it shows the co-op rows")
    check(L.eval("CMDS[#CMDS]") == "join 765", "asking the same host again re-sends the request (%s)" % L.eval("CMDS[#CMDS]"))
    # a request nobody answers stops by itself after 2 minutes (one still waiting after 13 min was accepted into a Realm)
    L = lua()
    L.execute(r"""
        local any = { __index = function() return function() end end }
        local function stub(t) return setmetatable(t or {}, any) end
        for _, n in ipairs({ "notify", "menu_backups", "instance", "hostrules", "mysettings",
                             "modlist", "itemclean", "names", "voice", "chat", "teleport", "compat", "version" }) do
            package.loaded["mirror." .. n] = stub()
        end
        SAID, STOPPED, ERRS = {}, 0, {}
        package.loaded["mirror.notify"] = stub({ show = function(m) SAID[#SAID + 1] = m end, clear = function() end })
        package.loaded["mirror.util"] = stub({ safe = function(f, n, ...) local ok, e = pcall(f, ...); if not ok then ERRS[#ERRS + 1] = tostring(n) .. ": " .. tostring(e) end; return ok, e end })
        package.loaded["mirror.game"] = stub({ on_tick = function(f) TICK = f end })
        ROLE, CONNECTED = nil, false
        package.loaded["mirror.link"] = stub({ kind = function() return "steam" end, peer_name = function() return "Bob" end,
            lobby = function() return { hosts = { { id = "765", name = "Bob" } } } end, bridge_cmd = function() return true end })
        package.loaded["mirror.session"] = stub({ state = function() return "idle" end })
        package.loaded["mirror.phase1"] = stub({ started = function() return ROLE end, connected = function() return CONNECTED end,
            init = function(c, r) ROLE = r end, stop = function() STOPPED = STOPPED + 1 end })
        package.loaded["mirror.journal_tab"] = stub({ configure = function(t) TAB = t end })
        ModifierKey = { CONTROL = 1 }
        CLOCK = 1000
        os.clock = function() return CLOCK end
        menu = require("mirror.menu")
        menu.init({})
        TAB.act.join("765", "Bob")
        CLOCK = 1100; TICK(0.1)
    """)
    check(L.eval("STOPPED") == 0, "after 100 s the request is still waiting")
    L.execute("CLOCK = 1121; TICK(0.1)")
    said = list(L.eval("SAID").values())
    check(L.eval("STOPPED") == 1 and any("didn't answer within 2 minutes" in s for s in said),
          "after 2 minutes without an answer it stops asking and says so (%s)" % said[-1:])
    L.execute("CLOCK = 1500; TICK(0.1)")
    check(L.eval("STOPPED") == 1, "...once")
    # home after a leave: the link to the host ends too, once the host confirmed everything this game sent
    # (2026-10-29: the CO-OP tab still said "connected to" the host after leaving)
    print("home_after_a_leave_disconnects_once_confirmed")
    L = lua()
    L.execute(r"""
        local any = { __index = function() return function() end end }
        local function stub(t) return setmetatable(t or {}, any) end
        for _, n in ipairs({ "notify", "menu_backups", "instance", "hostrules", "mysettings",
                             "modlist", "itemclean", "names", "voice", "chat", "teleport", "compat", "version" }) do
            package.loaded["mirror." .. n] = stub()
        end
        STOPPED, ERRS, HOME, UNCONF, STATE = 0, {}, nil, 2, "idle"
        package.loaded["mirror.hostrules"] = stub({ my_value = function() return "4" end })
        package.loaded["mirror.util"] = stub({ error_count = function() return 0 end,
            safe = function(f, n, ...) local ok, e = pcall(f, ...); if not ok then ERRS[#ERRS + 1] = tostring(n) .. ": " .. tostring(e) end; return ok, e end })
        package.loaded["mirror.game"] = stub({ on_tick = function(f) TICK = f end })
        ROLE, CONNECTED = "guest", true
        package.loaded["mirror.link"] = stub({ kind = function() return "steam" end, peer_name = function() return "Bob" end,
            lobby = function() return { hosts = {} } end, bridge_cmd = function() return true end })
        package.loaded["mirror.session"] = stub({ state = function() return STATE end,
            home_since = function() return STATE == "idle" and HOME or nil end, forget_home = function() HOME = nil end })
        package.loaded["mirror.events"] = stub({ unconfirmed = function() return UNCONF end })
        LOCKS = 0
        package.loaded["mirror.doorlock"] = stub({ unconfirmed = function() return LOCKS end })
        package.loaded["mirror.phase1"] = stub({ started = function() return ROLE end, connected = function() return CONNECTED end,
            init = function(c, r) ROLE = r end, stop = function() STOPPED = STOPPED + 1; ROLE = nil end })
        package.loaded["mirror.journal_tab"] = stub({ configure = function(t) TAB = t end })
        ModifierKey = { CONTROL = 1 }
        CLOCK = 1000
        os.clock = function() return CLOCK end
        menu = require("mirror.menu")
        menu.init({})
        HOME = 1000
        CLOCK = 1001; TICK(0.1)
    """)
    check(L.eval("STOPPED") == 0, "just home: the link stays a moment")
    L.execute("CLOCK = 1010; TICK(0.1)")
    check(L.eval("STOPPED") == 0, "two messages the host hasn't confirmed yet: the link stays")
    L.execute("UNCONF = 0; LOCKS = 1; CLOCK = 1011; TICK(0.1)")
    check(L.eval("STOPPED") == 0, "a door code change the host hasn't taken yet: the link stays")
    L.execute("LOCKS = 0; CLOCK = 1012; TICK(0.1)")
    check(L.eval("STOPPED") == 1 and L.eval("HOME") is None, "all confirmed: disconnected (NOT IN CO-OP), once")
    L.execute("ROLE = 'guest'; HOME = 2000; UNCONF = 5; CLOCK = 2059; TICK(0.1)")
    check(L.eval("STOPPED") == 1, "a host that never confirms: still waiting at 59 s")
    L.execute("CLOCK = 2061; TICK(0.1)")
    check(L.eval("STOPPED") == 2, "...and disconnected after 60 s anyway")
    L.execute("ROLE = 'guest'; HOME = 3000; UNCONF = 0; STATE = 'joining'; CLOCK = 3010; TICK(0.1)")
    check(L.eval("STOPPED") == 2, "joining again before it ended: the link stays")
    check(L.eval("#ERRS") == 0, "no errors (%s)" % list(L.eval("ERRS").values()))


def refused_realm_join_disarms_the_realm():
    # hardening 2026-10-30: a declined Realm join kept the Realm armed, so the next Ctrl+F10 join of the same host
    # went out as a Realm join with the Realm character (and was refused as the wrong kind)
    print("refused_realm_join_disarms_the_realm")
    L = lua()
    L.execute(r"""
        local any = { __index = function() return function() end end }
        local function stub(t) return setmetatable(t or {}, any) end
        for _, n in ipairs({ "notify", "menu_backups", "instance", "hostrules", "mysettings",
                             "modlist", "itemclean", "names", "voice", "chat", "teleport", "compat", "version" }) do
            package.loaded["mirror." .. n] = stub()
        end
        ERRS, LOBBY, ARMED = {}, { hosts = {} }, "unset"
        package.loaded["mirror.hostrules"] = stub({ my_value = function() return "4" end })
        package.loaded["mirror.util"] = stub({ error_count = function() return 0 end,
            safe = function(f, n, ...) local ok, e = pcall(f, ...); if not ok then ERRS[#ERRS + 1] = tostring(n) .. ": " .. tostring(e) end; return ok, e end })
        package.loaded["mirror.game"] = stub({ on_tick = function(f) TICK = f end })
        ROLE = nil
        package.loaded["mirror.link"] = stub({ kind = function() return "steam" end, peer_name = function() return "Bob" end,
            lobby = function() return LOBBY end, bridge_cmd = function() return true end })
        package.loaded["mirror.session"] = stub({ state = function() return "idle" end, realm_guest = function(id) ARMED = id end })
        package.loaded["mirror.phase1"] = stub({ started = function() return ROLE end, connected = function() return false end,
            init = function(c, r) ROLE = r end, stop = function() ROLE = nil end })
        package.loaded["mirror.journal_tab"] = stub({ configure = function(t) TAB = t end })
        ModifierKey = { CONTROL = 1 }
        os.clock = function() return 1000 end
        menu = require("mirror.menu")
        menu.init({})
        menu.realm_join("7656", "Bob", "Camp")
        package.loaded["mirror.session"].realm_guest("R1")   -- (realmplay.start arms it right after)
        TICK(0.1)
        A1 = ARMED
        LOBBY = { hosts = {}, joinerror = "declined" }
        TICK(1.0)   -- (the lobby is read once a second)
    """)
    check(L.eval("A1") == "R1", "asking to join the Realm keeps it armed")
    check(L.eval("ARMED") is None, "the host declined: the Realm is no longer armed")
    check(L.eval("#ERRS") == 0, "no errors (%s)" % list(L.eval("ERRS").values()))


def bag_put_back_after_a_take_reaches_the_host():
    # report 20261027-095623 (0.13.2): guest put a duffle bag in a cupboard, took it out (sent by the host's uid,
    # learned from the host's list), filled it, put it back: the host still had "G1 already added" and only acked
    # it, its next list lacked the bag and the guest's copy removed it with its 15 items ("0 added, 16 removed")
    print("bag_put_back_after_a_take_reaches_the_host")
    H = loot_guest()
    H.execute(r"""
        package.loaded["mirror.loot"] = nil
        loot = require("mirror.loot")
        loot.init({}, "host", { in_world = function() return true end })
        PUMP.BP_JigMultiplayer = COMP
        HCONT, ADDS = {}, 0
        local J = package.loaded["mirror.jig"]
        J.contents_of = function() return HCONT end
        J.add_item = function(c, da, n) ADDS = ADDS + 1; local u = "H" .. ADDS; HCONT[#HCONT + 1] = { uid = u, da = da, count = n }; return u end
        J.take = function(c, uid) for i, it in ipairs(HCONT) do if it.uid == uid then table.remove(HCONT, i); break end end; return true end
        J.fill = function() return 0, 0 end
        COMP.MainJigContainers = { GetArrayNum = function() return 1 end, ForEach = function(self, f)
            f(1, { get = function() return { ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B = { ForEach = function(_, g)
                for i, it in ipairs(HCONT) do g(i, { get = function() return { UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = it.uid,
                    ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = { Count_8_DD79AF2A46126A338C8DCCB4616D91CD = it.count } } end }) end
            end } } end }) end }
        ID = "Container_FuelLoot_GasPump_C@10,0,0"
        local function put(seq) INBOX.loot = { "A " .. ID .. " G1 /Game/X.DA_DuffleBag 1 0 0 " .. seq .. " -1:0:-1" }; loot.tick(0.1) end
        put(1)
        A1 = ADDS
        put(1)                       -- the same message again (replayed): still one bag
        A_REPLAY = ADDS
        INBOX.loot = { ID .. " H1 0 2 /Game/X.DA_DuffleBag" }; loot.tick(0.1)
        LEFT = #HCONT
        put(3)                       -- the same bag put back
        A2, N2 = ADDS, #HCONT
        put(1)                       -- an old message replayed after all that: no extra bag
        A3 = ADDS
    """)
    check(H.eval("A1") == 1 and H.eval("A_REPLAY") == 1, "a put is added once, a replay of it is ignored")
    check(H.eval("LEFT") == 0, "the guest's take (by the host's uid) removed it")
    check(H.eval("A2") == 2 and H.eval("N2") == 1, "the same bag put back is added again (adds %s, here %s)" % (H.eval("A2"), H.eval("N2")))
    check(H.eval("A3") == 2, "an old put replayed later adds nothing")


def container_class_checks_are_cached():
    # "perf: loot took 30-90 ms": with some MAIN classes not loaded (tents, stations...) "not a container" was
    # never kept, so every inventory component redid up to 12 IsA, and the missing classes were looked up
    # again (~15 ms per miss) every 10 s
    print("container_class_checks_are_cached")
    L = loot_guest()
    L.execute(r"""
        NOW = 100; os.clock = function() return NOW end
        local B = "/Game/Blueprints/BuildingSystem/Actors/"
        CRATE = "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C"
        TENT = B .. "Tents/BuildableMaster_Tent.BuildableMaster_Tent_C"
        LOADED = { [CRATE] = true, [B .. "Buildable_MASTER.Buildable_MASTER_C"] = true }
        ROOT = {}
        MISSES, ISA = 0, 0
        StaticFindObject = function(p)
            -- (only container-class misses count: the vehicle class is is_car's, other paths other modules')
            local main = (p:find("/Containers/", 1, true) or p:find("/BuildingSystem/", 1, true) or p:find("Station", 1, true))
                and not p:find(":", 1, true)
            if not LOADED[p] then if main then MISSES = MISSES + 1 end; return nil end
            ROOT[p] = ROOT[p] or cls(p:match("[^.]+$"))
            return ROOT[p]
        end
        local function actor(name, parent)
            local c = cls(name)
            local a = obj({ GetClass = function() return c end })
            a.IsA = function(_, r) ISA = ISA + 1; return parent ~= nil and ROOT[parent] == r end
            return a
        end
        -- a fresh loot module: the harness's own ticks already found every class (its fake finds anything)
        package.loaded["mirror.loot"] = nil
        loot = require("mirror.loot")
        loot.init({}, "guest", { in_world = function() return true end })
        local zombies = {}
        for i = 1, 30 do zombies[i] = actor("Zombie" .. (i % 6) .. "_C") end
        local crate = actor("Crate_C", CRATE)
        -- after a load the first round runs from the tick, one class a frame (it was one 433 ms freeze at join)
        PER_FRAME = 0
        for f = 1, 2 do local m = MISSES; NOW = NOW + 0.016; loot.tick(0.016); PER_FRAME = math.max(PER_FRAME, MISSES - m) end
        -- asked in the middle of it (a take in the first frames): the rest is looked up then, the answer is right
        MID_CRATE = loot.is_shared(crate)
        package.loaded["mirror.loot"] = nil
        loot = require("mirror.loot")
        loot.init({}, "guest", { in_world = function() return true end })
        for f = 1, 12 do local m = MISSES; NOW = NOW + 0.016; loot.tick(0.016); PER_FRAME = math.max(PER_FRAME, MISSES - m) end
        local m0 = MISSES
        loot.is_shared(zombies[1])
        AFTER_ROUND = MISSES - m0
        local m0 = MISSES
        for f = 1, 600 do
            NOW = NOW + 0.1
            loot.tick(0.1)
            for _, z in ipairs(zombies) do loot.is_shared(z) end
        end
        MISSES_60S, ISA0 = MISSES - m0, ISA
        for f = 1, 10 do for _, z in ipairs(zombies) do loot.is_shared(z) end end
        ISA_CACHED = ISA - ISA0
        CRATE_OK = loot.is_shared(crate)
        LOADED[TENT] = true
        local tent = actor("MyTent_C", TENT)
        TENT_NOW = loot.is_shared(tent)
        for f = 1, 12 do NOW = NOW + 0.016; loot.tick(0.016) end
        TENT_LATER = loot.is_shared(tent)
    """)
    check(L.eval("MISSES_60S") <= 6, "6 missing container classes: one lookup round in a minute, not one every 10 s (%d misses)" % L.eval("MISSES_60S"))
    check(L.eval("ISA_CACHED") == 0, "a known class needs no IsA (%d)" % L.eval("ISA_CACHED"))
    check(L.eval("PER_FRAME") <= 1 and L.eval("AFTER_ROUND") == 0,
          "after a load: the classes are looked up one a frame, none left when the first question comes (%d/frame, %d after)"
          % (L.eval("PER_FRAME"), L.eval("AFTER_ROUND")))
    check(L.eval("MID_CRATE") is True, "a container asked about mid-round is still known as one")
    check(L.eval("CRATE_OK") is True, "a loot crate is a container")
    check(L.eval("TENT_NOW") is False and L.eval("TENT_LATER") is True, "a tent whose class loads later is a container within a few frames")


def car_trunks_go_by_the_cars_name():
    print("car_trunks_go_by_the_cars_name")
    L = loot_guest()
    L.execute(r"""
        CAR = obj({ name = "Vehicle_Jeep_C_3" })
        package.loaded["mirror.vehicles"] = { peer_name_of = function(a) return a == CAR and "Vehicle_Jeep_C_7" or nil end,
                                               car_named = function(n) return n == "Vehicle_Jeep_C_7" and CAR or nil end }
    """)
    check(L.eval('package.loaded["mirror.vehicles"].car_named("Vehicle_Jeep_C_7") == CAR'), "fake car paired")
    src = open(os.path.join(SCRIPTS, "mirror", "loot.lua"), encoding="utf-8").read()
    check('"car:" .. n' in src and 'id:sub(1, 4) == "car:"' in src, "loot ids a car trunk by the host's car name and finds it by name")


def loot_open_shows_the_hosts_items_at_once():
    print("loot_open_shows_the_hosts_items_at_once")
    L = loot_guest()
    L.execute(r"""
        ME.K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end
        for i = 1, 12 do loot.tick(0.1) end
        NEAR_QS = qs()
        ID = SENT[1] and SENT[1]:match("^Q (%S+)$")
        INBOX.lootc = { "C " .. tostring(ID) .. " 0 one" }
        loot.tick(0.1)
        A0 = APPLIED
        INIT = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:InitializeJigComponent"
        HOOKS[INIT]({ get = function() return COMP end })
        A1 = APPLIED
        LISTED = LAST
        open(); loot.tick(0.1)
    """)
    check(L.eval("NEAR_QS") == 1, "standing next to a container asks the host about it before any open (%d)" % L.eval("NEAR_QS"))
    check(L.eval("A0") == 0 and L.eval("A1") == 1 and L.eval("LISTED") == "one", "the open itself takes the host's items, inside the open (before the UI reads them)")
    check(L.eval("REFRESHED") == 0 and L.eval("qs()") == 1, "no redraw afterwards and no second ask")
    L.execute("for i = 1, 25 do loot.tick(0.1) end")
    check(L.eval("qs()") == 2, "while the player stays near, it is asked again every 2 s (%d)" % L.eval("qs()"))


def bags_are_never_consumed_and_twin_grids_are_counted():
    print("bags_are_never_consumed_and_twin_grids_are_counted")
    L = lua()
    L.execute(FAKES + r"""
        local ITEMS, INFO = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B", "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
        local ITEM_ID, UID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848", "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
        local C_IN, C_INDEX = "InContainerUID_24_D1504ED7438699C73EA046AD734E79BF", "ContainerIndex_22_9A211B86466A9D1C57E1FC839A5B0896"
        local function arr(t) return { ForEach = function(self, fn) for i, v in ipairs(t) do fn(i, { get = function() return v end }) end end } end
        local function g(a) return { A = a, B = 0, C = 0, D = 0 } end
        local function item(u, da) return { [UID] = g(u), [INFO] = { [ITEM_ID] = { GetFullName = function() return "DA " .. da end }, Count_8_DD79AF2A46126A338C8DCCB4616D91CD = 1,
            Durability_22_A3557C454274D193D47AB9B71FB0C0CA = { X = 0, Y = 0 } } } end
        GRIDS = {
            { [C_IN] = g(0), [C_INDEX] = 0, [ITEMS] = arr({ item(1, "/Game/I.DA_Backpack"), item(2, "/Game/I.DA_Can") }) },
            { [C_IN] = g(0), [C_INDEX] = 0, [ITEMS] = arr({}) },
            { [C_IN] = g(1), [C_INDEX] = 0, [ITEMS] = arr({}) },
            { [C_IN] = g(1), [C_INDEX] = 1, [ITEMS] = arr({}) },
            { [C_IN] = g(1), [C_INDEX] = 0, [ITEMS] = arr({ item(3, "/Game/I.DA_Bag") }) },
        }
        CONSUMED, REMOVE_OK = {}, false
        COMP = obj({ MainJigContainers = arr(GRIDS),
            RemoveGetInfo = function() if not REMOVE_OK then error("no") end end, MC_ItemRemoved = function() end,
            HandleLocalRequestConsumeItem = function(self, guid) CONSUMED[#CONSUMED + 1] = guid.A end })
        jig = require("mirror.jig")
        TWINS = jig.twin_grids(COMP)
        OK1, ERR1 = jig.take(COMP, "1_0_0_0", 1, 1)
        REMOVE_OK = true
        OK2 = jig.take(COMP, "1_0_0_0", 1, 1)
        OK3 = jig.take(COMP, "2_0_0_0", 1, 1)
    """)
    check(L.eval("TWINS") == 1, "a bag compartment that exists twice is counted once; main containers aren't")
    check(L.eval("OK1") is False and L.eval("ERR1") is not None, "a bag that can't be removed whole is reported, not taken")
    check(L.eval("OK2") is True, "a bag removed whole is taken")
    check(L.eval("#CONSUMED") == 1 and L.eval("CONSUMED[1]") == 2, "only the plain item was ever consumed")


def twin_compartments_are_merged_into_one():
    # old saves: a bag compartment that exists twice (left by bags consumed in older versions) - items in the
    # one the UI doesn't show were invisible. Its items move into the other, the empty twin is detached.
    print("twin_compartments_are_merged_into_one")
    L = lua()
    L.execute(FAKES + r"""
        local ITEMS, INFO = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B", "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
        local ITEM_ID, UID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848", "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
        C_IN, C_INDEX = "InContainerUID_24_D1504ED7438699C73EA046AD734E79BF", "ContainerIndex_22_9A211B86466A9D1C57E1FC839A5B0896"
        REP, COLS, ROWS = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332", "Columns_4_1D84448048078D988999ABA138CE1809", "Rows_6_78B4BC5B449017D63758E79844375AE9"
        function arr(t) return { t = t, GetArrayNum = function(self) return #self.t end,
            ForEach = function(self, fn) for i, v in ipairs(self.t) do fn(i, { get = function() return v end }) end end } end
        local function g(a) return { A = a, B = 0, C = 0, D = 0 } end
        function item(u, da) return { [UID] = g(u), [INFO] = { [ITEM_ID] = { GetFullName = function() return "DA " .. da end },
            Count_8_DD79AF2A46126A338C8DCCB4616D91CD = 1, Durability_22_A3557C454274D193D47AB9B71FB0C0CA = { X = 0, Y = 0 } } } end
        function grid(rep, holder, idx, cols, rows, items)
            return { [REP] = g(rep), [C_IN] = g(holder), [C_INDEX] = idx, [COLS] = cols, [ROWS] = rows, [ITEMS] = arr(items) }
        end
        function setup(cap)
            GRIDS = {
                grid(100, 0, 0, 4, 4, { item(1, "/Game/I.DA_Backpack") }),          -- main: the bag
                grid(101, 1, 0, 2, 2, { item(2, "/Game/I.DA_Can") }),               -- shown compartment
                grid(102, 1, 1, 2, 2, {}),                                          -- its other slot (no twin)
                grid(103, 1, 0, 2, 2, { item(3, "/Game/I.DA_Pills"), item(4, "/Game/I.DA_Nails") }), -- twin
            }
            COMP = obj({ MainJigContainers = arr(GRIDS) })
            COMP.HandleSameContainerMoveToIndex = function(self, guid, to, idx, rot, by, z)
                local dst
                for _, ct in ipairs(GRIDS) do if ct[REP].A == to.A then dst = ct end end
                if #dst[ITEMS].t >= (cap or dst[COLS] * dst[ROWS]) then return end
                for _, ct in ipairs(GRIDS) do
                    for i, it in ipairs(ct[ITEMS].t) do
                        if it[UID].A == guid.A then table.remove(ct[ITEMS].t, i); table.insert(dst[ITEMS].t, it); return end
                    end
                end
            end
        end
        jig = require("mirror.jig")
        setup()
        M, D, LEFT = jig.merge_twins(COMP)
        TWINS = jig.twin_grids(COMP)
        function holders() local o = {} for _, ct in ipairs(GRIDS) do o[#o + 1] = ct[C_IN].A .. "/" .. #ct[ITEMS].t .. "/" .. ct[COLS] end return table.concat(o, " ") end
        H1, N1 = holders(), #jig.contents_of(COMP)
        setup(2)   -- the twin holding the most is kept, but the shown one has room for only 2: one item stays
        M2, D2, LEFT2 = jig.merge_twins(COMP)
        H2, N2 = holders(), #jig.contents_of(COMP)
    """)
    check(L.eval("M") == 1 and L.eval("D") == 1 and L.eval("LEFT") == 0,
          "the smaller twin's item moves into the twin holding the most, the empty one is detached (%s %s %s)" % (L.eval("M"), L.eval("D"), L.eval("LEFT")))
    check(L.eval("TWINS") == 0, "no compartment exists twice afterwards")
    check(L.eval("H1") == "0/1/4 1/0/0 1/0/2 1/3/2".replace("1/0/0", "1397639507/0/0"),
          "the bag keeps one compartment per slot with all 3 items, the old twin is empty, 0x0 and belongs to no item (%s)" % L.eval("H1"))
    check(L.eval("N1") == 4, "no item lost or added (%d)" % L.eval("N1"))
    check(L.eval("M2") == 0 and L.eval("D2") == 0 and L.eval("LEFT2") == 1 and L.eval("N2") == 4,
          "no room: the item stays where it was and its twin is kept, nothing lost (%s %s %s, %s)" % (L.eval("M2"), L.eval("D2"), L.eval("LEFT2"), L.eval("H2")))


def beds_get_a_rename_row_and_shared_names():
    print("beds_get_a_rename_row_and_shared_names")
    import tempfile
    d = tempfile.mkdtemp().replace("\\", "/")
    L = lua()
    L.execute(FAKES + r"""
        local function text() return { t = "", SetText = function(self, v) self.t = v end } end
        function opt(name) return obj({ sel = false, SetSelected = function(self, v) self.sel = v end, OptionName = name }) end
        function arr(items) return { items = items, GetArrayNum = function(self) return #self.items end,
            ForEach = function(self, fn) for i, e in ipairs(self.items) do fn(i, { get = function() return e end }) end end } end
        OPTS = { opt("Sleep"), opt("Spawn"), opt("Move"), opt("Pick up") }
        VB = obj({ kids = {} })
        for _, o in ipairs(OPTS) do VB.kids[#VB.kids + 1] = o end
        VB.GetChildrenCount = function(self) return #self.kids end
        VB.GetChildAt = function(self, i) return self.kids[i + 1] end
        VB.AddChildToVerticalBox = function(self, w) self.kids[#self.kids + 1] = w; return { SetPadding = function() end } end
        W = obj({ InteractOptions = VB, Options = arr(OPTS), ObjectName = text() })
        BED = obj({ GetClass = function() return cls("Buildable_SleepingBag_C") end,
                    K2_GetActorLocation = function() return { X = 1000, Y = 2000, Z = 30 } end })
        HELPER = obj({ CurrentTracActor = BED, CurrentInteractOptionIndex = 0 })
        PC = obj({ MyHUD = { InteractWidget = W } })
        package.loaded["mirror.game"] = { player = function() return { BP_JigHelperComp = HELPER } end, controller = function() return PC end,
                                          on_world_reset = function() end, keybind = function() end }
        util = require("mirror.util")
        HOOKS = {}
        util.ensure_hook = function(p, fn) HOOKS[p:match(":(%w+)$")] = fn; return true end
        util.cdo = function() return { Create = function() return opt(nil) end } end
        StaticFindObject = function() return obj({}) end
        FText = function(s) return s end
        ASKED = nil
        names = require("mirror.names")
        names.ask = function(o) ASKED = o; return true end
        bt = require("mirror.bedtags")
        SENT = {}
        bt.init({ data_file = function(n) return DIR .. "/" .. n end }, function(p) SENT[#SENT + 1] = p end, function() return true end)
    """.replace("DIR", '"' + d + '"'))
    L.execute("bt.tick(0.2)")
    check(L.eval("#VB.kids") == 5 and L.eval("VB.kids[5].OptionName") == "Rename", "a Rename row is added after the bed's own options")
    L.execute("bt.tick(0.02); bt.tick(0.02)")
    check(L.eval("#VB.kids") == 5, "the row is added once")
    L.execute("HELPER.CurrentInteractOptionIndex = 3; bt.tick(0.02)")
    L.execute("HELPER.CurrentInteractOptionIndex = 0; HOOKS.CycleOptions(nil, { get = function() return false end }); bt.tick(0.02)")
    check(L.eval("HELPER.CurrentInteractOptionIndex") == 4 and L.eval("VB.kids[5].sel") and not L.eval("OPTS[4].sel"),
          "scrolling down past the last option selects Rename (no bed option at that index)")
    L.execute("HOOKS.TryInteract(); bt.tick(0.02); bt.tick(0.02)")
    check(L.eval("ASKED ~= nil") and L.eval("ASKED.title") == "NAME THIS SLEEPING BAG", "interacting on Rename opens the rename box")
    L.execute('ASKED.done("Base camp"); bt.tick(0.02)')
    check(L.eval("SENT[1]") == "N 1000 2000 30 Base%20camp" and L.eval("W.ObjectName.t") == "Base camp",
          "the name is sent and replaces the hover title")
    L.execute("HELPER.CurrentInteractOptionIndex = 0; HOOKS.CycleOptions(nil, { get = function() return false end }); bt.tick(0.02)")
    check(L.eval("HELPER.CurrentInteractOptionIndex") == 0 and not L.eval("VB.kids[5].sel"), "scrolling on wraps to the first option")
    L.execute('bt.apply("N 1001 2001 30 Tent%20two")')
    check(L.eval('bt.name_at({ X = 1000, Y = 2000, Z = 30 })') == "Tent two", "the other player's rename is applied")
    L.execute('bt.apply("N 1000 2000 30 -")')
    check(L.eval('bt.name_at({ X = 1000, Y = 2000, Z = 30 })') is None, "and a cleared name clears it")
    L.execute('bt.apply("N 5 5 5 Shed"); bt.gone({ X = 5, Y = 5, Z = 5 })')
    check(L.eval('bt.name_at({ X = 5, Y = 5, Z = 5 })') is None, "a removed bed loses its name")


def ghost_swims_without_its_own_water_detection():
    print("ghost_swims_without_its_own_water_detection")
    L = lua()
    L.execute(FAKES + r"""
        util = require("mirror.util")
        CLEARED = {}
        util.cdo = function() return { K2_ClearTimer = function(self, o, fn) CLEARED[#CLEARED + 1] = fn end } end
        ghost = require("mirror.ghost")
        G = obj({ SwimmingComponent = { ["IsSwimming?"] = false, ["UnderWater?"] = false } })
        tr = require("mirror.track").new(2.0)
        tr:push(1.0, { loc = { X = 0, Y = 0, Z = 0 }, yaw = 0, vel = { X = 0, Y = 0, Z = 0 }, swim = true, underwater = false })
        tr:push(1.1, { loc = { X = 1, Y = 0, Z = 0 }, yaw = 0, vel = { X = 0, Y = 0, Z = 0 }, swim = true, underwater = true })
    """)
    L.execute('P = tr:at(1.05, util); ghost.apply_swim(G, P)')
    check(L.eval('CLEARED[1]') == "WaterDetection", "the ghost's water detection timer is stopped")
    check(L.eval('G.SwimmingComponent["IsSwimming?"] and G.SwimmingComponent["UnderWater?"]') is True,
          "the peer's swimming and diving reach the ghost through the track")
    L.execute('ghost.apply_swim(G, { swim = false, underwater = false })')
    check(L.eval('#CLEARED') == 1, "the timer is stopped once per ghost")
    check(L.eval('G.SwimmingComponent["IsSwimming?"]') is False, "leaving the water ends the ghost's swimming")


def a_player_sitting_down_sits_on_the_other_screen():
    # User 2026-10-30: "also sitting down isnt synced". The game's sit (BP_PlayerCharacter IA_SitDown) plays
    # Chr_SittingFloor_Montage straight on the character and sets Sitting? - not through MC_Montage, which is all
    # anim.lua mirrors - so the other player saw them stand. The montage's one section loops on itself.
    print("a_player_sitting_down_sits_on_the_other_screen")
    L = lua()
    L.execute(FAKES + r"""
        util = require("mirror.util")
        SIT = obj({})
        StaticFindObject = function(p) if p:find("Chr_SittingFloor_Montage", 1, true) then return SIT end end
        p1 = require("mirror.poseline")
        ghost = require("mirror.ghost")
        ghost.configure({ ghost = { snap_distance = 500 } })
        PLAYS, STOPS = {}, {}
        NOW = 100; os.clock = function() return NOW end
        PLAYLEN, CURM, TP_OK = 1.5, nil, true
        G = obj({ CharacterMovement = { MovementMode = 1 }, SwimmingComponent = {}, StaminaComponent = {},
                  K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
                  K2_TeleportTo = function() return TP_OK end,
                  K2_SetActorLocationAndRotation = function(_, l) SET = l end,
                  GetCurrentMontage = function() return CURM end,
                  PlayAnimMontage = function(_, m) PLAYS[#PLAYS + 1] = m; return PLAYLEN end,
                  StopAnimMontage = function(_, m) STOPS[#STOPS + 1] = m end })
        ghost._set_for_test(G)
        ME = obj({ ["Sitting?"] = true, bIsCrouched = false, CharacterMovement = { IsFalling = function() return false end } })
        tr = require("mirror.track").new(2.0)
    """)
    check(L.eval('p1.flags(ME)') == 32, "a sitting player sends the sit flag (%s)" % L.eval('p1.flags(ME)'))
    L.execute('P = p1.parse("1 2 3 90 0 0 0 32"); tr:push(1.0, P); tr:push(1.1, p1.parse("1 2 3 90 0 0 0 32"))')
    check(L.eval('P.sit') is True and L.eval('P.crouch') is False, "the other side reads it as sitting, not crouching")
    L.execute('ghost.apply(tr:at(1.05, util), false); ghost.apply(tr:at(1.2, util), false)')
    check(L.eval('#PLAYS') == 1 and L.eval('PLAYS[1] == SIT'), "the ghost sits once through the track (%s plays)" % L.eval('#PLAYS'))
    L.execute('ghost.apply(p1.parse("1 2 3 90 0 0 0 0"), false)')
    check(L.eval('#STOPS') == 1 and L.eval('STOPS[1] == SIT'), "standing up stops only the sit montage on the ghost")
    L.execute('ghost.apply(p1.parse("1 2 3 90 0 0 0 1"), false)')
    check(L.eval('#STOPS') == 1 and L.eval('#PLAYS') == 1, "crouching is not sitting")
    check(L.eval('p1.parse("1 2 3 90 0 0 0 16").sit') is False, "an old build's flags never read as sitting")
    check(L.eval('p1.parse("1 2 3 90 0 0 0 31").crouch and p1.parse("1 2 3 90 0 0 0 31").underwater') is True,
          "the other flags read as before")
    # audit 2026-10-31: a stop-all (anim.lua "-", vehicles.lua seat exit) cut the sit and nothing sat the ghost again
    L.execute('PLAYS = {}; SITP = p1.parse("1 2 3 90 0 0 0 32"); ghost.apply(SITP, false); CURM = SIT'
              '; NOW = NOW + 2; ghost.apply(SITP, false)')
    check(L.eval('#PLAYS') == 1, "a sit that still plays isn't started again (%s plays)" % L.eval('#PLAYS'))
    L.execute('CURM = nil; NOW = NOW + 0.5; ghost.apply(SITP, false)')
    check(L.eval('#PLAYS') == 1, "a cut sit isn't replayed every pose")
    L.execute('NOW = NOW + 0.6; ghost.apply(SITP, false)')
    check(L.eval('#PLAYS') == 2, "a sit cut by a stop-all is sat again within a second (%s plays)" % L.eval('#PLAYS'))
    L.execute('CURM = obj({}); NOW = NOW + 2; ghost.apply(SITP, false)')
    check(L.eval('#PLAYS') == 2, "nor over another montage that plays (a use, a reload)")
    L.execute('ghost.apply(p1.parse("1 2 3 90 0 0 0 0"), false); PLAYLEN = 0; CURM = nil; ghost.apply(SITP, false)'
              '; NOW = NOW + 0.5; ghost.apply(SITP, false)')
    check(L.eval('#PLAYS') == 3, "a sit that didn't play (0) waits a second before trying again (%s)" % L.eval('#PLAYS'))
    L.execute('PLAYLEN = 1.5; NOW = NOW + 0.6; ghost.apply(SITP, false); CURM = SIT; NOW = NOW + 0.6; ghost.apply(SITP, false)')
    check(L.eval('#PLAYS') == 4, "and then sits (%s plays)" % L.eval('#PLAYS'))
    # audit 2026-10-31: K2_TeleportTo refuses spots that overlap a car (the capsule blocks cars since 4e98473)
    L.execute('SET = nil; TP_OK = false; ghost.apply(p1.parse("40 0 3 90 0 0 0 0"), false)')
    check(L.eval('SET ~= nil and SET.X == 40'), "a move refused beside a car still puts the ghost where its player is")
    L.execute('SET = nil; TP_OK = true; ghost.apply(p1.parse("60 0 3 90 0 0 0 0"), false)')
    check(L.eval('SET == nil'), "a move that works isn't set twice")


def door_code_locks_keep_other_players_out_until_they_type_it():
    # User 2026-10-30: "it ads a selection in the door menu for lock and then a keypad UI pops up where u set a
    # password and then it saves for all doors you have placed, no other players can use the door unless they enter
    # the password correctly and they have access too the players doors". Host + guest, each its own Lua, with the
    # real doors.lua carrying the locks between them (door_sync off: locks don't depend on it).
    print("door_code_locks_keep_other_players_out_until_they_type_it")
    import tempfile
    def side(role, sid, name):
        d = tempfile.mkdtemp().replace("\\", "/")
        L = lua()
        L.execute(FAKES + r"""
            DIR, ROLE = "D", "R"
            package.loaded["mirror.link"].lobby = function() return { id = "SID", name = "NAME" } end
            CARDS = {}
            package.loaded["mirror.notify"] = { show = function(t) CARDS[#CARDS + 1] = t end, clear = function() end }
            function opt(n) return obj({ sel = false, SetSelected = function(self, v) self.sel = v end, OptionName = n,
                                        UpdateText = function(self, v) self.OptionName = v end,
                                        RemoveFromParent = function(self) for i, k in ipairs(VB.kids) do if k == self then table.remove(VB.kids, i) end end end }) end
            function arr(items) return { items = items, GetArrayNum = function(self) return #self.items end,
                ForEach = function(self, fn) for i, e in ipairs(self.items) do fn(i, { get = function() return e end }) end end } end
            OPTS = { opt("Open"), opt("Pick up"), opt("Move") }
            VB = obj({ kids = {} })
            for _, o in ipairs(OPTS) do VB.kids[#VB.kids + 1] = o end
            VB.GetChildrenCount = function(self) return #self.kids end
            VB.GetChildAt = function(self, i) return self.kids[i + 1] end
            VB.AddChildToVerticalBox = function(self, w) self.kids[#self.kids + 1] = w; return { SetPadding = function() end } end
            W = obj({ InteractOptions = VB, Options = arr(OPTS), ObjectName = { t = "Wooden Door", SetText = function(self, v) self.t = v end,
                                                                          GetText = function(self) local t = self.t; return { ToString = function() return t end } end } })
            function door(x, y) return obj({ GetClass = function() return cls("Buildable_WoodenDoor_C") end,
                                             K2_GetActorLocation = function() return { X = x, Y = y, Z = 50 } end }) end
            DOOR1, DOOR2, DOOR3 = door(1000, 2000), door(1400, 2000), door(5000, 5000)
            -- (TraceToWorld: the game's camera trace; TRACE = what it hits now, nil = leave it as it is)
            HELPER = obj({ CurrentTracActor = nil, CurrentInteractOptionIndex = 0,
                           TraceToWorld = function(self) if TRACE ~= nil then self.CurrentTracActor = TRACE end end })
            -- the helper's own option map (tag -> text, in key order), as TryInteract picks from it
            function opts(list) return { ForEach = function(self, fn) for _, s in ipairs(list) do
                fn({}, { get = function() return { ToString = function() return s end } end }) end end } end
            HELPER.CurrentInteractOptions = opts({ "Open", "Pick up", "Move" })
            -- the game's TryInteract in its real order: its camera trace (TRACE, else what the hover has), the option
            -- at the index on a hit that is CurrentTracActor, Option1 on anything else - and only then the hook
            -- (UE4SS runs it after the function). Returns the text of the option that ran, nil for none.
            function real_press()
                local hit, labels = TRACE or HELPER.CurrentTracActor, {}
                HELPER.CurrentInteractOptions:ForEach(function(_, v) labels[#labels + 1] = v:get():ToString() end)
                if hit == HELPER.CurrentTracActor then RAN = labels[HELPER.CurrentInteractOptionIndex + 1] else RAN = labels[1] end
                HOOKS.TryInteract({ get = function() return HELPER end })
                return RAN
            end
            PAD = nil
            PC = obj({ MyHUD = { InteractWidget = W }, bShowMouseCursor = false,
                       Pawn = { DisableInput = function() end, EnableInput = function() end } })
            -- (ME_AT: where this player stands; nil = no spot to read)
            package.loaded["mirror.game"] = { player = function() return { BP_JigHelperComp = HELPER,
                                                  K2_GetActorLocation = ME_AT and function() return ME_AT end } end,
                                              controller = function() return PC end, on_world_reset = function() end }
            util = require("mirror.util")
            HOOKS = {}
            util.ensure_hook = function(p, fn) HOOKS[p:match(":(%w+)$")] = fn; return true end
            util.cdo = function() return {
                Create = function(_, pc, c)
                    if c.path:find("KeypadUI", 1, true) then
                        local code = ""
                        PAD = obj({ AcceptedCode = 0, shown = false, CurrentCode = { ToString = function() return code end },
                                    AddToViewport = function(self) self.shown = true end,
                                    IsInViewport = function(self) return self.shown end,
                                    RemoveFromParent = function(self) self.shown = false end })
                        PAD.type = function(s) code = s end
                        return PAD
                    end
                    return opt(nil)
                end,
                SetInputMode_GameAndUIEx = function() end, SetInputMode_GameOnly = function() end } end
            StaticFindObject = function(p) return obj({ path = p }) end
            FText = function(s) return s end
            lock = require("mirror.doorlock")
            SESSION = { in_world = function() return true end, data_file = function(n) return DIR .. "/" .. n end }
            lock.init(SESSION, function() return DIR .. "/id.txt" end)
            doors = require("mirror.doors")
            LIVE = true
            doors.init({ door_sync = false }, ROLE, SESSION, function() return LIVE end)
            function tick(n) for i = 1, (n or 1) do util.new_frame(); doors.tick(0.05); lock.tick(0.2) end end
            function look(d) HELPER.CurrentTracActor = d; tick(2) end
            function press() HOOKS.TryInteract({ get = function() return HELPER end }); tick(2) end
            -- scroll from the door's last option down onto ours (the menu wraps to 0 and our row takes that step)
            function pick() HELPER.CurrentInteractOptionIndex = 2; tick(); HELPER.CurrentInteractOptionIndex = 0
                            HOOKS.CycleOptions(nil, { get = function() return false end }); tick() end
            function at(d) local l = d:K2_GetActorLocation(); return (lock.state_at(l)) end
            function row() return VB.kids[4] and VB.kids[4].OptionName end
        """.replace('"D"', '"%s"' % d).replace('"R"', '"%s"' % role).replace("SID", sid).replace("NAME", name))
        return L, d
    H, hd = side("host", "7656001", "Hosty")
    G, gd = side("guest", "7656002", "Guesty")
    last = {}
    def pump():
        for src, dst, name in ((H, G, "locks"), (G, H, "lock_g")):
            b = src.eval('blobs_out["%s"]' % name)
            if b is not None and last.get(name) != b:
                last[name] = b
                dst.execute('blobs_in["%s"] = ...' % name, b)
        H.execute("tick(2)"); G.execute("tick(2)")

    # the host builds a door while joined: it is the host's, open to all until the host sets a code
    H.execute('lock.placed("Buildable_WoodenDoor_C", { X = 1003, Y = 1998, Z = 50 })')
    pump(); pump()
    check(H.eval('at(DOOR1)') == "unset" and G.eval('at(DOOR1)') == "open", "a placed door is its builder's, open while no code is set")
    G.execute('look(DOOR1)')
    check(G.eval('#VB.kids') == 3, "an open door of someone else gets no lock row")
    # the host sets a code: Lock row -> keypad -> 4 digits
    H.execute('look(DOOR1)')
    check(H.eval('row()') == "Set door code", "the builder's door menu gets a code row (%s)" % H.eval('row()'))
    H.execute('pick()')
    check(H.eval('HELPER.CurrentInteractOptionIndex') == 3 and H.eval('VB.kids[4].sel') is True, "scrolling down past the last option selects it")
    H.execute('press()')
    check(H.eval('PAD ~= nil and PAD.shown') is True and H.eval('PAD.AcceptedCode') == 2147483647,
          "picking it opens the game's keypad, its own code check parked out of reach")
    H.execute('PAD.type("0472"); tick()')
    check(H.eval('PAD.shown') is False and H.eval('at(DOOR1)') == "mine", "4 digits close the keypad and set the code")
    saved = open(hd + "/mirror_coop_door_locks.txt").read()
    check("0472" not in saved and ("C 7656001 " + H.eval('lock.hash("7656001", "0472")')) in saved
          and "D 1003 1998 50 7656001" in saved, "the world's lock file keeps the door and a hash, never the code")
    pump(); pump()
    # the guest is locked out
    G.execute('look(DOOR1)')
    check(G.eval('at(DOOR1)') == "locked" and G.eval('row()') == "Enter code" and G.eval('HELPER.CurrentInteractOptionIndex') == 3,
          "the guest sees the door locked: only an Enter code row, picked")
    check(G.eval('W.ObjectName.t') == "Hosty's door - locked", "the hover title names the owner (%s)" % G.eval('W.ObjectName.t'))
    G.execute('HELPER.CurrentInteractOptionIndex = 0; HOOKS.TryInteract({ get = function() return HELPER end })')
    check(G.eval('HELPER.CurrentInteractOptionIndex') == 64, "pressing interact on the door's own option runs nothing (index far past the end)")
    G.execute('tick(2)')
    check(G.eval('PAD ~= nil and PAD.shown') is True, "...and opens the keypad to enter the code")
    G.execute('PAD.type("1111"); tick()')
    check(G.eval('at(DOOR1)') == "locked" and G.eval('CARDS[#CARDS]') == "Wrong code.", "a wrong code keeps it locked")
    # E pressed just after turning to the door: the game's own trace hits it before its 0.4 s hover caught up
    # (TryInteract runs Option1 = open on a hit that isn't CurrentTracActor)
    G.execute('HELPER.CurrentTracActor = nil; HELPER.CurrentInteractOptionIndex = 0; TRACE = DOOR1; '
              'HOOKS.TryInteract({ get = function() return HELPER end }); TRACE = nil')
    check(G.eval('HELPER.CurrentTracActor == DOOR1') is True and G.eval('HELPER.CurrentInteractOptionIndex') == 64,
          "a locked door the hover hasn't caught up with yet still runs nothing")
    G.execute('HELPER.CurrentTracActor = DOOR3; HELPER.CurrentInteractOptionIndex = 0; TRACE = DOOR1; '
              'HOOKS.TryInteract({ get = function() return HELPER end }); TRACE = nil')
    check(G.eval('HELPER.CurrentTracActor == DOOR1') is True and G.eval('HELPER.CurrentInteractOptionIndex') == 64,
          "...nor when the hover still has another thing")
    G.execute('tick(2); if PAD and PAD.shown then PAD.shown = false end; tick(2)')
    # the same in the game's real order, where the hook comes after the option ran (Sentinel R5 2026-10-31)
    G.execute('look(DOOR1); HELPER.CurrentInteractOptionIndex = 0; tick()')
    check(G.eval('real_press()') is None, "pressing interact on a locked door runs none of its options, the hook after it")
    G.execute('tick(2); if PAD and PAD.shown then PAD.shown = false end; tick(2)')
    G.execute('HELPER.CurrentTracActor = DOOR3; HELPER.CurrentInteractOptionIndex = 0; TRACE = DOOR1; tick()')
    check(G.eval('real_press()') is None, "turned to a locked door a frame before pressing: nothing runs (%s)" % G.eval('RAN'))
    G.execute('TRACE = nil; tick(2); if PAD and PAD.shown then PAD.shown = false end; tick(2)')
    G.execute('PC.MyHUD.InteractWidget = nil; HELPER.CurrentTracActor = DOOR1; HELPER.CurrentInteractOptionIndex = 0; tick()')
    check(G.eval('real_press()') is None, "before the game's hover menu is up a locked door still runs nothing (%s)" % G.eval('RAN'))
    G.execute('PC.MyHUD.InteractWidget = W; W.ObjectName.t = "Wooden Door"; tick(2); if PAD and PAD.shown then PAD.shown = false end; tick(2)')
    G.execute('press(); PAD.type("0472"); tick()')
    check(G.eval('at(DOOR1)') == "access", "the right code opens it on the guest at once")
    G.execute('tick(2)')
    check(G.eval('W.ObjectName.t') == "Wooden Door", "the hover title loses its lock mark once the guest may open it (%s)"
          % G.eval('W.ObjectName.t'))
    check(" grant 7656001 7656002 " in G.eval('lock.ops_text()'), "the guest tells the host (%r)" % G.eval('lock.ops_text()'))
    pump(); pump()
    saved = open(hd + "/mirror_coop_door_locks.txt").read()
    check("A 7656001 7656002" in saved, "the host keeps the guest's access in the world's file")
    pump()   # (the guest sends on the tick after the keypad, so the host's answer is one round later)
    check(G.eval('lock.ops_text()').count("\n") == 0, "once the host took it the guest stops sending it (%r, host sends %r)"
          % (G.eval('lock.ops_text()'), (H.eval('blobs_out["locks"]') or "")[:12]))
    G.execute('tick(2)')
    check(G.eval('#VB.kids') == 3 and G.eval('at(DOOR1)') == "access", "the lock row goes; the door's own options are back")
    # all of the owner's doors
    H.execute('lock.placed("Buildable_WoodenDoor_C", { X = 1400, Y = 2000, Z = 50 })')
    pump(); pump()
    check(G.eval('at(DOOR2)') == "access", "the code covers the owner's other doors, built later too")
    # replays and forged changes do nothing
    gen0 = H.eval('lock.gen()')
    blob = G.eval('blobs_out["lock_g"]')
    H.execute('blobs_in["lock_g"] = ...', blob); H.execute('tick(2)')
    check(H.eval('lock.gen()') == gen0, "the guest's changes sent again change nothing")
    H.execute('seen2 = {}; lock.take_ops("run x\\n1 grant 7656001 9999 00000000\\n2 code 7656001 ffffffff\\n'
              '3 grant 7656001 7656002 ffffffff", seen2)')
    saved = open(hd + "/mirror_coop_door_locks.txt").read()
    check(H.eval('lock.gen()') == gen0 and "A 7656001 9999" not in saved and H.eval('lock.hash("7656001", "0472")') in saved,
          "a grant with the wrong hash and a code change in the host's name are refused")
    # one connection is one player, whatever run it names; the next connection (seen starts over) is its own player
    H.execute('seen3 = {}; lock.take_ops("run a\\n1 code 111 aaaaaaaa", seen3); lock.take_ops("run b\\n1 code 222 bbbbbbbb", seen3)')
    saved = open(hd + "/mirror_coop_door_locks.txt").read()
    check("C 111 aaaaaaaa" in saved and "C 222" not in saved, "a guest can't become another player by naming a new run")
    H.execute('seen4 = {}; lock.take_ops("run b\\n1 code 222 bbbbbbbb\\n2 code 333 cccccccc", seen4)')
    saved = open(hd + "/mirror_coop_door_locks.txt").read()
    check("C 222 bbbbbbbb" in saved and "C 333" not in saved, "the next connection is its own player, and stays one")
    # a guest can't build its way into someone else's door, nor fill the list until real owners' doors drop off
    H.execute('seen5 = {}; lock.take_ops("run q\\n1 place 7656002 1400 2000 50\\n2 claim 7656002 1003 1998 50", seen5)')
    check(H.eval('at(DOOR2)') == "mine" and H.eval('at(DOOR1)') == "mine", "a guest's build over the host's door leaves it the host's")
    H.execute('local t = { "run z" }; for i = 1, 600 do t[#t + 1] = i .. " place 999 " .. (20000 + i * 100) .. " 0 0" end; '
              'seen6 = {}; lock.take_ops(table.concat(t, "\\n"), seen6)')
    saved = open(hd + "/mirror_coop_door_locks.txt").read()
    check(saved.count(" 999\n") + saved.endswith(" 999") <= 500 and H.eval('at(DOOR1)') == "mine",
          "one guest owns at most a quarter of the list (%d)" % saved.count(" 999\n"))
    H.execute('S = { codes = {}, doors = {}, access = {}, names = {} }; '
              'for i = 1, 2001 do lock._apply_op(S, "place", "o" .. i, tostring(i * 100), "0", "0") end')
    check(H.eval('#S.doors') == 2000 and H.eval('S.doors[1].owner') == "o1", "a full list takes no new door rather than drop the oldest")
    # an ack the host meant for another guest game doesn't drop this game's unsent changes
    G.execute('lock.placed("Buildable_WoodenDoor_C", { X = 9000, Y = 9000, Z = 50 })')
    q = G.eval('lock.ops_text()')
    run = q.split("\n")[0].split(" ")[1]
    body = H.eval('blobs_out["locks"]').split("\n", 1)[1]
    G.execute('lock.take(...)', "ack 999 other\n" + body)
    check(G.eval('lock.ops_text()') == q, "an ack for another guest game drops nothing (%r)" % G.eval('lock.ops_text()'))
    G.execute('lock.take(...)', "ack 999 %s\n" % run + body)
    check(G.eval('lock.ops_text()').count("\n") == 0, "an ack for this game drops what it covers (%r)" % G.eval('lock.ops_text()'))
    G.execute('lock.take(nil)')
    # the host's ack names the guest game and starts over when the guest goes
    pump()
    check((H.eval('blobs_out["locks"]') or "").startswith("ack ") and run in H.eval('blobs_out["locks"]').split("\n")[0],
          "the host's locks name the guest game their ack is for (%r)" % H.eval('blobs_out["locks"]').split("\n")[0])
    H.execute('LIVE = false; tick(); LIVE = true; tick()')
    check(H.eval('blobs_out["locks"]').split("\n")[0] == "ack 0", "after the guest left the host's ack starts over (%r)"
          % H.eval('blobs_out["locks"]').split("\n")[0])
    pump(); pump()
    # the guest's own door
    G.execute('lock.placed("Buildable_WoodenGate_C", { X = 5000, Y = 5000, Z = 50 })')
    check(G.eval('at(DOOR3)') == "unset", "the guest's own build is the guest's straight away")
    pump(); pump()
    check(H.eval('at(DOOR3)') == "open", "and the host sees it as the guest's")
    G.execute('look(DOOR3); pick(); press(); PAD.type("8080"); tick()')
    pump(); pump()
    H.execute('look(DOOR3)')
    check(H.eval('at(DOOR3)') == "locked" and H.eval('row()') == "Enter code", "the guest's code locks the host out of the guest's doors")
    H.execute('look(DOOR1)')
    check(H.eval('at(DOOR1)') == "mine" and H.eval('row()') == "Change door code", "the host's own doors stay the host's")
    # a restart: the file brings it all back
    H.execute('lock.forget()')
    check(H.eval('at(DOOR1)') == "mine" and H.eval('at(DOOR3)') == "locked", "after a world reload the locks come back from the file")
    # the guest goes home in the frame it built a door: the door is still the guest's in the host's world, and the
    # guest counts it unconfirmed (the leave keeps the link for it) until the host took it
    G.execute('lock.placed("Buildable_WoodenDoor_C", { X = 6000, Y = 6000, Z = 50 }); SESSION.in_world = function() return false end')
    check(G.eval('lock.unconfirmed()') > 0, "a change the host hasn't taken counts as unconfirmed (%r)" % G.eval('lock.ops_text()'))
    pump(); pump(); pump()
    saved = open(hd + "/mirror_coop_door_locks.txt").read()
    check("D 6000 6000 50 7656002" in saved, "a door built just before going home still lands in the host's file as the guest's")
    check(G.eval('lock.unconfirmed()') == 0 and G.eval('at(DOOR1)') == "free",
          "...the host's ack read at home clears it, the guest going by its own locks (%s)" % G.eval('lock.unconfirmed()'))
    G.execute('SESSION.in_world = function() return true end'); pump(); pump()
    # the guest leaves: back to its own world's locks
    G.execute('lock.placed("Buildable_WoodenDoor_C", { X = 7000, Y = 7000, Z = 50 })')
    check(G.eval('lock.ops_text()').count("\n") > 0, "(a change the host hasn't taken yet)")
    G.execute('LIVE = false; tick()')
    check(G.eval('at(DOOR1)') == "free", "a guest back alone goes by its own world's locks")
    check(G.eval('lock.ops_text()').count("\n") == 0, "what the host never took isn't sent to the next host")
    # moved and removed doors
    H.execute('lock.moved({ X = 1003, Y = 1998, Z = 50 }, { X = 1200, Y = 2600, Z = 50 })')
    check(H.eval('(lock.state_at({ X = 1200, Y = 2600, Z = 50 }))') == "mine" and H.eval('at(DOOR1)') == "free",
          "a moved door keeps its lock")
    H.execute('lock.gone({ X = 1200, Y = 2600, Z = 50 })')
    check(H.eval('lock.state_at({ X = 1200, Y = 2600, Z = 50 })') == "free", "a removed door leaves the file")
    check(G.eval('lock.loc_of_id("Buildable_WoodenDoor_C@100,200,5").X') == 1000, "a builds id reads back as its place")
    # an id kept from a start without Steam stays: the doors and code filed under it are still this player's
    K, kd = side("host", "7656009", "Kay")
    with open(kd + "/id.txt", "w") as f:
        f.write("p12345678\n")
    check(K.eval('lock.me()') == "p12345678" and open(kd + "/id.txt").read().strip() == "p12345678",
          "a kept id beats a Steam id read later (%s)" % K.eval('lock.me()'))

    # User 2026-10-31: "add a remove permissions button that removes peoples access too the door so for when changing
    # the code etc you can remove there access then change the code"; "other players cannot move or pickup others
    # buildables unless they have key door access and removing access removes building/ pickup perms near there
    # buildables"; "add the same lock feature too containers". A fresh host + guest pair.
    print("door_locks_remove_access_guard_the_base_and_cover_containers")
    H, hd = side("host", "7656001", "Hosty")
    G, gd = side("guest", "7656002", "Guesty")
    last.clear()
    for L in (H, G):
        L.execute(r"""
            function thing(cname, x, y, extra)
                local t = { GetClass = function() return cls(cname) end,
                            K2_GetActorLocation = function() return { X = x, Y = y, Z = 50 } end }
                for k, v in pairs(extra or {}) do t[k] = v end
                return obj(t)
            end
            BC_CLS = { ["Buildable_MASTER_C"] = true }
            CRATE = thing("Buildable_StorageCrate_C", 1600, 2000)
            WALL = thing("Base_wood_wall_C", 1800, 2300, { IsA = function(self, c) return c.path:find("Buildable_MASTER", 1, true) ~= nil end })
            FAR_WALL = thing("Base_wood_wall_C", 90000, 90000, { IsA = function(self, c) return c.path:find("Buildable_MASTER", 1, true) ~= nil end })
            -- looking at a with these options, idx picked, a frame, then E: the text of the option that ran, or nil
            function try_on(a, list, idx)
                HELPER.CurrentTracActor = a; HELPER.CurrentInteractOptions = opts(list); HELPER.CurrentInteractOptionIndex = idx
                TRACE = nil; tick(); return real_press()
            end
            -- the building component after the game's BuildCycle made the ghost green
            COMP = obj({ ["BuildModeOn?"] = true, CanBuild = true, BuildTransform = { Translation = { X = 0, Y = 0, Z = 50 } },
                         GiveBuildColour = function(self, g) self.CanBuild = g end })
            function ghost_at(x, y)
                COMP.CanBuild = true; COMP.BuildTransform.Translation = { X = x, Y = y, Z = 50 }
                HOOKS.BuildCycle({ get = function() return COMP end }); return COMP.CanBuild
            end
        """)
    H.execute('lock.placed("Buildable_WoodenDoor_C", { X = 1003, Y = 1998, Z = 50 })')
    H.execute('look(DOOR1); pick(); press(); PAD.type("0472"); tick()')
    pump(); pump()
    # containers lock like doors
    H.execute('lock.placed("Buildable_StorageCrate_C", { X = 1600, Y = 2000, Z = 50 })')
    pump(); pump()
    check(H.eval('at(CRATE)') == "mine" and G.eval('at(CRATE)') == "locked", "a container its builder placed is locked by the same code")
    G.execute('look(CRATE)')
    check(G.eval('row()') == "Enter code" and G.eval('W.ObjectName.t') == "Hosty's container - locked",
          "the guest's container menu has only Enter code, titled as a container (%s)" % G.eval('W.ObjectName.t'))
    check(G.eval('try_on(CRATE, {"Open", "Pick up", "Move"}, 0)') is None, "opening a locked container runs nothing")
    G.execute('tick(2); if PAD and PAD.shown then PAD.shown = false end; look(nil); tick(2)')
    # the base is guarded: no pick-up, move or building near the owner's locks
    check(G.eval('try_on(WALL, {"Pickup", "Move"}, 0)') is None and G.eval('try_on(WALL, {"Pickup", "Move"}, 1)') is None,
          "the owner's base pieces don't pick up or move for a player without the code (%s)" % G.eval('RAN'))
    check(G.eval('try_on(WALL, {"Open", "Pickup"}, 0)') == "Open", "other options of a base piece still run")
    check(G.eval('try_on(WALL, {"Pick up", "Move", "Rotate"}, 0)') == "Rotate",
          "a guarded option is stepped over to the next one the player may use (%s)" % G.eval('RAN'))
    G.execute('HOOKS.CycleOptions(nil, { get = function() return true end })')
    check(G.eval('try_on(WALL, {"Rotate", "Pick up", "Move", "Open"}, 2)') == "Rotate",
          "...upwards when the player scrolls up (%s)" % G.eval('RAN'))
    G.execute('HOOKS.CycleOptions(nil, { get = function() return false end })')
    check(G.eval('try_on(FAR_WALL, {"Pickup", "Move"}, 0)') == "Pickup", "far from any lock pieces pick up as before")
    # away from the host's base the guard doesn't run at all: no camera trace every frame (perf, user 2026-10-31)
    G.execute('TRACES = 0; HELPER.TraceToWorld = function(self) TRACES = TRACES + 1; if TRACE ~= nil then self.CurrentTracActor = TRACE end end')
    G.execute('ME_AT = { X = 90000, Y = 90000, Z = 50 }; HELPER.CurrentTracActor = FAR_WALL; tick(3); TRACES = 0; tick(10)')
    check(G.eval('TRACES') == 0, "away from other players' bases the guard runs no trace (%s)" % G.eval('TRACES'))
    G.execute('ME_AT = { X = 1700, Y = 2100, Z = 50 }; tick(2); TRACES = 0; tick(10)')
    check(G.eval('TRACES') == 10, "walking into reach of the base the guard runs every frame again (%s)" % G.eval('TRACES'))
    check(G.eval('try_on(WALL, {"Pickup", "Move"}, 0)') is None, "...and still stops Pick up there")
    G.execute('ME_AT = nil; HELPER.TraceToWorld = function(self) if TRACE ~= nil then self.CurrentTracActor = TRACE end end; tick(2)')
    check(G.eval('ghost_at(1500, 2500)') is False and G.eval('ghost_at(90000, 90000)') is True,
          "the build ghost turns red in the owner's base, and only there")
    G.execute('COMP["ReplacingObject?"] = true; COMP.ReplacingActor = WALL')
    check(G.eval('ghost_at(90000, 90000)') is False, "a piece moved out of the owner's base stays red outside it too")
    G.execute('COMP["ReplacingObject?"] = false; COMP.ReplacingActor = nil')
    check(H.eval('ghost_at(1500, 2500)') is True and H.eval('try_on(WALL, {"Pickup", "Move"}, 0)') == "Pickup",
          "the owner builds and picks up in their own base")
    check(G.eval('lock._build_op("Pick Up")') and G.eval('lock._build_op("Move")') and not G.eval('lock._build_op("Open")'),
          "pick up and move are the guarded options, open isn't")
    # a base of the guest's own next to the host's stays the guest's to build in
    G.execute('lock.placed("Buildable_WoodenDoor_C", { X = 4700, Y = 2000, Z = 50 })')
    check(G.eval('ghost_at(4300, 2000)') is True, "next to its own lock the guest builds even inside the owner's zone")
    # ...but a lock set down inside the owner's base doesn't carry the next build further in
    G.execute('lock.placed("Buildable_WoodenDoor_C", { X = 3800, Y = 2000, Z = 50 })')
    check(G.eval('ghost_at(3000, 2000)') is False, "a lock placed inside someone's base doesn't make the spots past it the guest's")
    # the class of a just-placed door or container comes from the actor standing there
    G.execute('FindAllOf = function(c) if c == "Buildable_StorageCrate_C" then return { CRATE } end return {} end')
    check(G.eval('lock.class_at({ X = 1610, Y = 2000, Z = 50 }, "/Game/Inventory/Items/DataAssets/Buildable/Storage/DA_StorageCrate1.DA_StorageCrate1")')
          == "Buildable_StorageCrate_C" and G.eval('lock.class_at({ X = 1610, Y = 2000, Z = 50 }, "/Game/X/DoorsAndGates/DA_WoodenDoor1.DA_WoodenDoor1")') is None
          and G.eval('lock.class_at({ X = 1610, Y = 2000, Z = 50 }, "/Game/X/Walls/DA_Wall.DA_Wall")') is None,
          "a placed container's class is read off the actor at its spot")
    # the guest types the code: all of it opens up
    G.execute('look(DOOR1); press(); PAD.type("0472"); tick(); look(nil); tick(2)')
    pump(); pump(); pump()
    check(G.eval('at(CRATE)') == "access" and G.eval('try_on(WALL, {"Pickup", "Move"}, 0)') == "Pickup" and G.eval('ghost_at(1500, 2500)') is True,
          "with the code the guest opens the container, picks up and builds in the base")
    # the owner's door now shows Remove access
    H.execute('look(DOOR1)')
    check(H.eval('VB.kids[4] and VB.kids[4].OptionName') == "Change door code" and H.eval('VB.kids[5] and VB.kids[5].OptionName') == "Remove access (1)",
          "the owner's door shows Remove access with the count (%s / %s)" % (H.eval('VB.kids[4] and VB.kids[4].OptionName'),
                                                                                H.eval('VB.kids[5] and VB.kids[5].OptionName')))
    # scrolling: last game option -> our first row -> our second row; and back up
    H.execute('HELPER.CurrentInteractOptionIndex = 2; tick(); HELPER.CurrentInteractOptionIndex = 0; '
              'HOOKS.CycleOptions(nil, { get = function() return false end }); tick()')
    check(H.eval('HELPER.CurrentInteractOptionIndex') == 3, "scrolling down past the game's options lands on the first row")
    H.execute('HELPER.CurrentInteractOptionIndex = 0; HOOKS.CycleOptions(nil, { get = function() return false end }); tick()')
    check(H.eval('HELPER.CurrentInteractOptionIndex') == 4 and H.eval('VB.kids[5].sel') is True and H.eval('VB.kids[4].sel') is False,
          "one more step lands on Remove access, the only row selected")
    H.execute('HELPER.CurrentInteractOptionIndex = 0; HOOKS.CycleOptions(nil, { get = function() return true end }); tick()')
    check(H.eval('HELPER.CurrentInteractOptionIndex') == 3, "scrolling up from Remove access goes back to the code row")
    H.execute('HOOKS.CycleOptions(nil, { get = function() return false end }); HELPER.CurrentInteractOptionIndex = 0; tick()')
    H.execute('HELPER.CurrentInteractOptionIndex = 4; tick(); press(); tick(2)')
    check(H.eval('at(DOOR1)') == "mine" and H.eval('PAD == nil or not PAD.shown') is True
          and "A 7656001 7656002" not in open(hd + "/mirror_coop_door_locks.txt").read(),
          "picking Remove access takes the guest's access off the world's file, no keypad")
    check(H.eval('#VB.kids') == 4, "with nobody left to remove the row goes (%d rows)" % H.eval('#VB.kids'))
    pump(); pump()
    check(G.eval('at(DOOR1)') == "locked" and G.eval('at(CRATE)') == "locked" and G.eval('try_on(WALL, {"Pickup"}, 0)') is None
          and G.eval('ghost_at(1500, 2500)') is False, "the guest is locked out of the doors, the container and the base again")
    # a guest owner removes access too: its revoke goes through the host
    H.execute('seen9 = {}; lock.take_ops("run g\\n1 code 7656002 " .. lock.hash("7656002", "1234") .. "\\n2 place 7656002 9000 9000 50", seen9)')
    H.execute('seen10 = {}; lock.take_ops("run h\\n1 grant 7656002 777 " .. lock.hash("7656002", "1234"), seen10)')
    check("A 7656002 777" in open(hd + "/mirror_coop_door_locks.txt").read(), "(a third player has the guest's code)")
    H.execute('lock.take_ops("run g\\n3 revoke 7656002", seen9)')
    check("A 7656002 777" not in open(hd + "/mirror_coop_door_locks.txt").read(), "a guest's Remove access reaches the host's file")
    H.execute('S2 ={ codes = {}, doors = {}, access = { o = { p = true } }, names = {} }')
    check(H.eval('lock._apply_op(S2, "revoke", "o")') is True and H.eval('lock._apply_op(S2, "revoke", "o")') is False,
          "a revoke applied twice changes nothing the second time")
    H.execute('lock.take_ops("run x\\n1 grant 7656001 7656003 " .. lock.hash("7656001", "0472"), {})')
    before = open(hd + "/mirror_coop_door_locks.txt").read()
    H.execute('lock.take_ops("run y\\n1 revoke 7656001", {})')
    check("A 7656001 7656003" in open(hd + "/mirror_coop_door_locks.txt").read() and "A 7656001 7656003" in before,
          "a guest can't remove access in the host's name")


def all_players_must_sleep_before_the_night_is_skipped():
    # User 2026-10-30: "sleeping bags sync for everyone when 1 person sleeps" -> "Feature: all must sleep".
    # The game's sleep (SleepingUI_C) runs the sky's Transition Time of Day(650, 2.0, 7, 2.0, false); joined, one
    # sleeping host skipped the night for all. Blueprint hooks run before the function: the hook changes its target.
    print("all_players_must_sleep_before_the_night_is_skipped")
    def side(role):
        L = lua()
        L.execute(FAKES + r"""
            NOW = 0; os.clock = function() return NOW end
            util = require("mirror.util")
            HOOK = nil
            util.ensure_hook = function(p, fn) if p:find(":Transition Time of Day", 1, true) then HOOK = fn end; return true end
            CARDS = {}
            package.loaded["mirror.notify"] = { show = function(t) CARDS[#CARDS + 1] = t end, clear = function() end }
            AT = { X = 0, Y = 0, Z = 0 }
            PLAYER = obj({ K2_GetActorLocation = function() return AT end })
            package.loaded["mirror.game"] = { player = function() return PLAYER end }
            function P(v) local box = { v = v }; return { get = function() return box.v end, set = function(_, x) box.v = x end } end
            MOVES = {}
            SKY = obj({ ["Time of Day"] = 2300.0, GetFullName = function() return "Ultra_Dynamic_Sky_C /Game/M.M:P.Ultra_Dynamic_Sky_2" end })
            -- kit 2026-10-31: the hook runs AFTER the function, which has already stored its target in Transition Time B
            -- (the clock went 54 -> 655 with only the argument changed): what the sky eases to is that stored target
            local function run(self, t, d)
                local np = P(t)
                self["Transition Time B"], self["Transitioning Time"] = t, true
                if HOOK then HOOK({ get = function() return self end }, np, P(d)) end
                return self["Transition Time B"]
            end
            SKY["Transition Time of Day"] = function(self, t, d) MOVES[#MOVES + 1] = run(self, t, d) end
            FindAllOf = function(c) if c == "Ultra_Dynamic_Sky_C" then return { SKY } end return {} end
            -- the game's sleep button: where the sky is told to go
            function GAME_SLEEP() return run(SKY, 650.0, 2.0) end
            function OTHER_TRANSITION() return run(SKY, 1200.0, 5.0) end
            -- (like the real link: a blob stays, and is handed out only when its text changed - until reset_blob)
            SEEN = {}
            package.loaded["mirror.link"].get_blob = function(n)
                local b = blobs_in[n]
                if b == nil or b == SEEN[n] then return nil end
                SEEN[n] = b
                return b
            end
            package.loaded["mirror.link"].reset_blob = function(n) SEEN[n] = nil end
            LIVE = true
            sleep = require("mirror.sleep")
            sleep.init("ROLE", function() return LIVE end)
            function tick(s) NOW = NOW + (s or 0.6); sleep.tick(s or 0.6) end
            tick()
        """.replace("ROLE", role))
        return L
    H, G = side("host"), side("guest")
    def pump():
        for n in ("slp_h",):
            v = H.eval('blobs_out["%s"]' % n)
            if v is not None: G.execute('blobs_in["%s"] = %r' % (n, v)); H.execute('blobs_out["%s"] = nil' % n)
        v = G.eval('blobs_out["slp_g"]')
        if v is not None: H.execute('blobs_in["slp_g"] = %r' % v); G.execute('blobs_out["slp_g"] = nil')
    def turn():
        pump(); H.execute("tick()"); G.execute("tick()"); pump(); H.execute("tick()"); G.execute("tick()")
    turn()
    H.execute("LIVE = false; tick()")
    check(H.eval("GAME_SLEEP()") == 650.0, "alone, the game's sleep skips the night as before")
    H.execute("LIVE = true; tick()")
    check(abs(H.eval("GAME_SLEEP()") - 2300.01) < 0.001, "joined, the host's sleep is held: the sky stays at its time")
    check(H.eval("OTHER_TRANSITION()") == 1200.0, "a time change that isn't the sleep is left alone")
    turn()
    check(H.eval("#MOVES") == 0, "one of two asleep: no morning on the host")
    check(any("1 of 2 players asleep" in (G.eval("CARDS[%d]" % i) or "") for i in range(1, G.eval("#CARDS") + 1)),
          "the guest is told 1 of 2 players are asleep")
    H.execute("AT = { X = 500, Y = 0, Z = 0 }"); turn()
    check(H.eval("sleep._shared.me") is None, "walking away from the bed wakes the host")
    H.execute("AT = { X = 0, Y = 0, Z = 0 }"); H.execute("GAME_SLEEP()")
    check(abs(G.eval("GAME_SLEEP()") - 2300.01) < 0.001, "the guest's sleep is held too")
    turn(); turn()
    check(H.eval("#MOVES") == 1 and H.eval("MOVES[1]") == 650.0, "both asleep: the host's sky goes to morning once (%s)" % H.eval("#MOVES"))
    check(G.eval("#MOVES") == 1 and G.eval("MOVES[1]") == 650.0, "and the guest's sky goes the same way (%s)" % G.eval("#MOVES"))
    check(H.eval("sleep._shared.me") is None and G.eval("sleep._shared.me") is None, "everyone is awake after the night")
    turn(); turn(); turn()
    check(H.eval("#MOVES") == 1 and G.eval("#MOVES") == 1, "the night is skipped only once")
    G.execute("GAME_SLEEP()"); turn(); turn()
    check(H.eval("#MOVES") == 1, "the next night the guest's \"asleep\" alone skips nothing")
    # the host's link stalls (15 s without a word) and comes back; the guest never noticed and sends nothing new
    H.execute("LIVE = false; tick(); LIVE = true"); turn()
    H.execute("GAME_SLEEP()"); turn(); turn()
    check(H.eval("#MOVES") == 2, "after a stall the guest still counts as asleep: the host's sleep brings morning (%s)" % H.eval("#MOVES"))
    # the other player leaves while I sleep: woken, told so
    turn(); H.execute("GAME_SLEEP()"); turn()
    check(H.eval("sleep._shared.me") is not None, "(the host asleep, the guest awake)")
    H.execute("LIVE = false; tick()")
    check(H.eval("sleep._shared.me") is None and "left - you're awake" in H.eval("CARDS[#CARDS]"),
          "the other player leaves while I sleep: I'm awake and told so (%s)" % H.eval("CARDS[#CARDS]"))
    # a guest that never says (an older build): after 10 s it doesn't hold the night
    H.execute("blobs_in.slp_g = nil; LIVE = true; tick(); GAME_SLEEP(); tick(); M0 = #MOVES")
    check(H.eval("#MOVES") == H.eval("M0"), "a guest that hasn't said yet counts as awake at first")
    H.execute("for i = 1, 20 do tick() end")
    check(H.eval("#MOVES") == H.eval("M0") + 1, "a guest silent for 10 s doesn't hold the night (%s)" % (H.eval("#MOVES") - H.eval("M0")))
    H.execute("tick(); GAME_SLEEP(); for i = 1, 3 do tick() end")
    check(H.eval("#MOVES") == H.eval("M0") + 2, "...nor the next night (%s)" % (H.eval("#MOVES") - H.eval("M0")))
    # the hook's change didn't take: not marked asleep (the later morning would be a whole day on)
    H.execute("tick(); BAD = setmetatable({}, { __index = { ['Time of Day'] = 2300.0, ['Transitioning Time'] = true, ['Transition Time B'] = 650.0 },"
              " __newindex = function() error('read only') end })"
              "; HOOK({ get = function() return BAD end }, { get = function() return 650.0 end, set = function() end }, P(2.0))")
    check(H.eval("sleep._shared.me") is None, "a hold that didn't take marks nobody asleep")

    # three players: the host has a copy of sleep.lua per guest link; they count together through peers.shared
    L = lua()
    L.execute(FAKES + r"""
        NOW = 0; os.clock = function() return NOW end
        util = require("mirror.util")
        util.ensure_hook = function(p, fn) HOOK = HOOK or fn; return true end
        package.loaded["mirror.game"] = { player = function() return obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end }) end }
        function P(v) local box = { v = v }; return { get = function() return box.v end, set = function(_, x) box.v = x end } end
        MOVES = {}
        SKY = obj({ ["Time of Day"] = 100.0, GetFullName = function() return "Ultra_Dynamic_Sky_C /Game/M.M:P.S" end })
        local function run(self, t, d)
            local np = P(t)
            self["Transition Time B"], self["Transitioning Time"] = t, true   -- (the hook runs after the function: kit 2026-10-31)
            if HOOK then HOOK({ get = function() return self end }, np, P(d)) end
            return self["Transition Time B"]
        end
        SKY["Transition Time of Day"] = function(self, t, d) MOVES[#MOVES + 1] = run(self, t, d) end
        FindAllOf = function(c) if c == "Ultra_Dynamic_Sky_C" then return { SKY } end return {} end
        function GAME_SLEEP() return run(SKY, 650.0, 2.0) end
        LINKS, COPIES = {}, {}
        for i = 1, 2 do
            local l = { out = {}, inn = {} }
            l.put_blob = function(n, b) l.out[n] = b end
            l.get_blob = function(n) local b = l.inn[n]; l.inn[n] = nil; return b end
            LINKS[i] = l
            package.loaded["mirror.link"] = l
            package.loaded["mirror.sleep"] = nil
            COPIES[i] = require("mirror.sleep")
            COPIES[i].init("host", function() return true end)
        end
        function tick() NOW = NOW + 0.6; for i = 1, 2 do COPIES[i].tick(0.6) end end
        tick()
    """)
    L.execute('GAME_SLEEP(); LINKS[1].inn.slp_g = "1"; tick(); tick()')
    check(L.eval("#MOVES") == 0 and L.eval('LINKS[2].out.slp_h') == "2 3 0",
          "three players, two asleep: no morning, and the third is told 2 of 3 (%s)" % L.eval('LINKS[2].out.slp_h'))
    L.execute('LINKS[2].inn.slp_g = "1"; tick(); tick()')
    check(L.eval("#MOVES") == 1 and L.eval("MOVES[1]") == 650.0, "the third goes to sleep: one morning (%s)" % L.eval("#MOVES"))
    check(str(L.eval('LINKS[1].out.slp_h')).endswith(" 1") and str(L.eval('LINKS[2].out.slp_h')).endswith(" 1"),
          "both guests are told the night is over (%s, %s)" % (L.eval('LINKS[1].out.slp_h'), L.eval('LINKS[2].out.slp_h')))


def sleeping_screen_stays_until_everyone_sleeps():
    # User 2026-10-31: "when player sleeps make it so the sleeping screen stays on untill the other players sleep too,
    # add some text that says Move too cancel sleep". SleepingUI_C's sleep button shows SleepingText and calls Exit
    # (screen off, input back) 2.5 s later: while the night is held the screen is put back up.
    print("sleeping_screen_stays_until_everyone_sleeps")
    L = lua()
    L.execute(FAKES + r"""
        NOW = 0; os.clock = function() return NOW end
        util = require("mirror.util")
        util.ensure_hook = function(p, fn) HOOK = fn; return true end
        package.loaded["mirror.notify"] = { show = function() end, clear = function() end }
        AT = { X = 0, Y = 0, Z = 0 }
        package.loaded["mirror.game"] = { player = function() return obj({ K2_GetActorLocation = function() return AT end }) end }
        function P(v) local box = { v = v }; return { get = function() return box.v end, set = function(_, x) box.v = x end } end
        MOVES = {}
        SKY = obj({ ["Time of Day"] = 2300.0, GetFullName = function() return "Ultra_Dynamic_Sky_C /Game/M.M:P.S" end })
        local function run(self, t, d)
            self["Transition Time B"], self["Transitioning Time"] = t, true
            if HOOK then HOOK({ get = function() return self end }, P(t), P(d)) end
            return self["Transition Time B"]
        end
        SKY["Transition Time of Day"] = function(self, t, d) MOVES[#MOVES + 1] = run(self, t, d) end
        FText = function(s) return { s = s } end
        ADDS = 0
        TEXT = obj({ SetText = function(_, t) SHOWN_TEXT = t.s end, SetVisibility = function(_, v) TEXT_VIS = v end })
        CHOICES = obj({ SetVisibility = function(_, v) CHOICES_VIS = v end })
        UI = obj({ inview = true, SleepingText = TEXT, Choices = CHOICES, BlurAnim = {},
                   IsInViewport = function(self) return self.inview end,
                   AddToViewport = function(self) self.inview = true; ADDS = ADDS + 1 end,
                   RemoveFromParent = function(self) self.inview = false end,
                   PlayAnimationForward = function() BLUR = true end })
        FindAllOf = function(c)
            if c == "Ultra_Dynamic_Sky_C" then return { SKY } end
            if c == "SleepingUI_C" then return { UI } end
            return {}
        end
        function GAME_SLEEP() UI.inview = true; return run(SKY, 650.0, 2.0) end
        sleep = require("mirror.sleep")
        sleep.init("host", function() return true end)
        blobs_in.slp_g = "0"
        function tick(s) NOW = NOW + (s or 0.6); sleep.tick(s or 0.6) end
        tick()
    """)
    L.execute("GAME_SLEEP(); tick()")
    check(L.eval("MOVES[1]") != 650.0 and "Move to cancel sleep" in (L.eval("SHOWN_TEXT") or ""),
          "held: the game's sleeping screen says Move to cancel sleep (%r)" % L.eval("SHOWN_TEXT"))
    check("Waiting for 1 more player to sleep" in L.eval("SHOWN_TEXT"), "and how many are still awake")
    # the game's own Exit 2.5 s after the button
    L.execute("tick(1.0); tick(1.0); UI.inview = false; tick(0.016)")
    check(L.eval("UI.inview") is True and L.eval("ADDS") == 1 and L.eval("CHOICES_VIS") == 2 and L.eval("TEXT_VIS") == 4,
          "the game takes its screen down: put straight back up, choices hidden, the text shown")
    check("Move to cancel sleep" in L.eval("SHOWN_TEXT"), "with the text again")
    L.execute("for i = 1, 10 do tick() end")
    check(L.eval("UI.inview") is True and L.eval("sleep._shared.me") is not None, "it stays while the other player is awake")
    # a step cancels: awake, screen off at once
    L.execute("AT = { X = 80, Y = 0, Z = 0 }; tick()")
    check(L.eval("sleep._shared.me") is None and L.eval("UI.inview") is False, "a step (80 cm): awake and the screen goes")
    L.execute("for i = 1, 3 do tick() end")
    check(L.eval("ADDS") == 1, "and it isn't put back")
    # asleep again, then everyone is: morning, the screen stays while the sky moves, then goes
    L.execute("AT = { X = 0, Y = 0, Z = 0 }; GAME_SLEEP(); tick(); tick(1.0); tick(1.0); UI.inview = false; tick(0.016)")
    check(L.eval("ADDS") == 2, "asleep again: put back after the game's Exit again")
    L.execute('blobs_in.slp_g = "1"; tick(0.6)')
    check(L.eval("#MOVES") >= 1 and L.eval("MOVES[#MOVES]") == 650.0 and L.eval("UI.inview") is True,
          "everyone asleep: morning, and the screen is still up as the sky moves")
    L.execute("tick(1.0); tick(1.0); tick(1.0)")
    check(L.eval("UI.inview") is False and L.eval("sleep._shared.scr") is None, "2.5 s later the screen goes")
    # taken down again later (the pause key: its Tick calls Exit): stays down, still asleep
    L.execute('blobs_in.slp_g = "0"; tick(); GAME_SLEEP(); tick(); tick(1.0); tick(1.0); UI.inview = false; tick(0.016); ADDS0 = ADDS')
    L.execute("tick(3.0); UI.inview = false; tick(0.016); tick()")
    check(L.eval("UI.inview") is False and L.eval("ADDS") == L.eval("ADDS0") and L.eval("sleep._shared.me") is not None,
          "taken down again later (Escape): it stays down and the player stays asleep")
    # no sleeping screen found: the hold works as before
    L.execute("AT = { X = 200, Y = 0, Z = 0 }; tick(); AT = { X = 0, Y = 0, Z = 0 }; UI.dead = true"
              "; UI.IsValid = function() return false end; GAME_SLEEP(); tick()")
    check(L.eval("sleep._shared.me") is not None and L.eval("sleep._shared.scr") is None, "no screen: still held, nothing to keep up")


def ghost_stands_on_cars_but_never_pushes_them():
    # 2026-10-24: a ghost capsule with a physics body, teleported into a car's body, flung parked cars - so it ignored
    # cars. User 2026-10-30: "when player is ontop of car they are floating for the other": with cars ignored the
    # ghost had no floor on a roof. Now: cars blocked for queries (floor sweeps), no physics body, no physics push.
    print("ghost_stands_on_cars_but_never_pushes_them")
    L = lua()
    L.execute(FAKES + r"""
        util = require("mirror.util")
        util.cdo = function() return obj({ SetActorSaveProperties = function() end }) end
        StaticFindObject = function() return obj({}) end
        FindFirstOf = function() return nil end
        ghost = require("mirror.ghost")
        ghost.configure({ ghost = { class = "/Game/X.Ghost_C", target_tag = "t", view_controller = false } })
        BLOCKS = {}
        local function body()
            local cap = { SetCollisionEnabled = function(_, m) CAP_MODE = m end, SetCollisionResponseToAllChannels = function() end,
                          SetCollisionResponseToChannel = function(_, ch, r) if r == 2 then BLOCKS[ch] = true end end }
            LAST = obj({ CapsuleComponent = cap, Mesh = { SetCollisionEnabled = function() end,
                         SetCollisionResponseToAllChannels = function() end, SetCollisionResponseToChannel = function() end },
                         MedicalComponent = {}, CharacterMovement = {}, Tags = { Empty = function() end },
                         AIOInvoker = {}, ActorHasTag = function() return false end,
                         GetFullName = function() return "BP_Ghost /Game/X.Ghost" end })
            return LAST
        end
        WORLD = { SpawnActor = function() return body() end }
    """)
    for kind in ("guest", "host"):
        L.execute('BLOCKS = {}; CAP_MODE = nil; ghost.forget(); ghost.spawn(WORLD, { X = 0, Y = 0, Z = 0 }, 0, "%s")' % kind)
        check(L.eval('BLOCKS[6]') is True, "the %s ghost's capsule blocks cars, so it stands on a car roof" % kind)
        check(L.eval('CAP_MODE') == 1, "the %s ghost's capsule is queries only: no physics body to shove a car (%s)" % (kind, L.eval('CAP_MODE')))
        check(L.eval('LAST.CharacterMovement.bEnablePhysicsInteraction') is False,
              "the %s ghost's steps don't push cars or other simulated things" % kind)
        check(L.eval('BLOCKS[0] and BLOCKS[1] and BLOCKS[2]') is True, "the %s ghost still blocks the world and players" % kind)


def a_host_zombie_hit_reaches_a_guest_with_three_players():
    # live 2026-10-30, 3 players: every hit the host sent ("took 20.0 damage from zombie 38") was set to 0 inside
    # ApplyDamage by the other player's copy of zombies.lua ("[to2] blocked damage from a zombie copy", 85 times)
    print("a_host_zombie_hit_reaches_a_guest_with_three_players")
    L = lua()
    L.execute(FAKES + r"""
        PLAYER = obj({ MedicalComponent = { Health = 100 } })
        PLAYER.K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end
        HURT = {}
        package.loaded["mirror.game"] = { player = function() return PLAYER end, world = function() return obj({}) end,
            controller = function() return nil end, on_world_reset = function() end, keybind = function() end,
            on_ready = function() end, on_tick = function() end,
            player_hook = function(name, fn) if name == "ReceiveAnyDamage" then HURT[#HURT + 1] = fn end end }
        package.loaded["mirror.ghost"] = { get = function() return nil end, is = function() return false end }
        package.loaded["mirror.loader"] = { want = function() end }
        package.loaded["mirror.invdiag"] = { summary = function() return "-" end }
        StaticFindObject = function() return nil end
        ModifierKey = ModifierKey or { CONTROL = 1 }
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        GOT = {}
        util.cdo = function(p)
            if p:find("GameplayStatics", 1, true) then
                return { ApplyDamage = function(self, who, amt, inst, causer)
                    local d = { v = amt }
                    local Damage = { get = function() return d.v end, set = function(_, v) d.v = v end }
                    for _, fn in ipairs(HURT) do fn({ get = function() return who end }, Damage, nil, nil, { get = function() return causer end }) end
                    GOT[#GOT + 1] = d.v
                end }
            end
            return { GetConsoleVariableBoolValue = function() return false end, GetConsoleVariableIntValue = function() return 0 end }
        end
        CFG = { zombies = { enabled = true, send_hz = 15, despawn_after = 3.0, dmg_reach = 400 } }
        local function instance()
            package.loaded["mirror.zombies"] = nil
            local z = require("mirror.zombies")
            local ok, e = pcall(z.init, CFG, "guest", { in_world = function() return true end })
            if not ok then INIT_ERR = tostring(e) end
            z._test.setup(CFG, "guest")
            return z
        end
        MAIN, MATE = instance(), instance()
        Z = obj({ Mesh = {} }); Z.K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end
        MAIN._test.copy(7, Z)
        MAIN._test.dmg("7 20.0 - 100 0 0 0")
    """)
    check(L.eval('#HURT') == 2, "both copies of the module watch my damage (%s hooks, %s)" % (L.eval('#HURT'), L.eval('INIT_ERR')))
    check(L.eval('GOT[1]') == 20.0, "the host's hit is applied in full, not set to 0 by the other copy (%s)" % L.eval('GOT[1]'))
    L.execute('local d = { v = 15 }; for _, fn in ipairs(HURT) do fn({ get = function() return PLAYER end }, '
              '{ get = function() return d.v end, set = function(_, v) d.v = v end }, nil, nil, { get = function() return Z end }) end; OWN = d.v')
    check(L.eval('OWN') == 0, "a copy's own hit (not the host's) is still blocked")
    # live 2026-10-30 02:28:59: teleported into a fight, dead 4 s later
    L.execute('ARR = require("mirror.peers").shared_table("arrival"); ARR.safe_until = os.clock() + 3; N0 = #GOT; '
              'MAIN._test.dmg("7 20.0 - 100 0 0 0"); SPARED = #GOT - N0; '
              'ARR.safe_until = os.clock() - 0.01; MAIN._test.dmg("7 20.0 - 100 0 0 0"); AFTER = #GOT - N0')
    check(L.eval('SPARED') == 0, "a host zombie's hit just after a teleport landed is let off")
    check(L.eval('AFTER') == 1 and L.eval('GOT[#GOT]') == 20.0, "...and hits land again once the 3 s are over")


def zombie_loot_tables_are_all_looked_up_and_misses_stay_few():
    # live 2026-10-30 02:34 as a guest: only Bandit and BanditBoss were ever asked (every 2 s, 32-59 ms of misses),
    # "16/16 missing" for 3.5 min - and the host's zombies wait for those tables
    print("zombie_loot_tables_are_all_looked_up_and_misses_stay_few")
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.game"] = { player = function() return nil end, world = function() return obj({}) end,
            controller = function() return nil end, on_world_reset = function() end, keybind = function() end }
        package.loaded["mirror.ghost"] = { get = function() return nil end, is = function() return false end }
        package.loaded["mirror.loader"] = { want = function() end }
        package.loaded["mirror.invdiag"] = { summary = function() return "-" end }
        LOADED, MISSES, WALKS = {}, 0, 0
        StaticFindObject = function(p)
            if p:find("DA_LootTable_", 1, true) then MISSES = MISSES + 1 end
            return nil
        end
        -- the tables' class: every loaded table (and other container data) in one walk
        FindAllOf = function(c)
            if c ~= "ContainerItems_DataAsset_C" then return nil end
            WALKS = WALKS + 1
            local out = { cls("DA_Container_Fridge"), cls("DA_LootTable_Bandit") }   -- (a container table: not the AI one)
            for p in pairs(LOADED) do
                local o = cls(p:match("%.(DA_LootTable_.+)$"))
                o.GetFullName = function() return "ContainerItems_DataAsset_C " .. p end
                out[#out + 1] = o
            end
            return out
        end
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        zombies = require("mirror.zombies")
        zombies._test.setup({ zombies = { enabled = true } }, "guest")
        T = 0; os.clock = function() return T end
        function table_path(n) return "/Game/AI/AILootTables/DA_LootTable_" .. n .. ".DA_LootTable_" .. n end
        -- every table but the first two is in memory
        for _, n in ipairs({ "BanditSniper", "Bear", "Deer", "MilitaryBoss", "MilitaryRifleman", "Rabbit", "Scavenger", "Wolf",
                             "Zombie", "ZombieBoss", "ZombieBossSmall", "ZombieHound", "ZombieInfected", "ZombieRadiated" }) do
            LOADED[table_path(n)] = true
        end
        for i = 1, 40 do T = T + 2; R_OK, R_MISSING = zombies._test.loot_ready() end
        M40, W40 = MISSES, WALKS
        LOADED[table_path("Bandit")], LOADED[table_path("BanditBoss")] = true, true
        for i = 1, 10 do T = T + 2; R2_OK = zombies._test.loot_ready() end
        W50 = WALKS
        for i = 1, 10 do T = T + 2; zombies._test.loot_ready() end
    """)
    check(L.eval('R_MISSING') == 2, "every table is looked up, not only the first two missing ones (%s missing)" % L.eval('R_MISSING'))
    # (kit 2026-10-31: a StaticFindObject per table was ~15 ms, found or not - 224-269 ms for the 16 in one frame)
    check(L.eval('M40') == 0, "no table is looked up by name: %s lookups (was 16 in the first probe)" % L.eval('M40'))
    check(L.eval('W40') <= 14, "one class walk a probe, probes backing off: %s walks in 80 s" % L.eval('W40'))
    check(L.eval('R2_OK') is True, "once they're there it is seen within a few probes")
    check(L.eval('WALKS') == L.eval('W50'), "all there: no more walks (%s after)" % (L.eval('WALKS') - L.eval('W50')))


def zombies_go_after_the_ghost_again_after_a_save():
    # live 2026-10-30: every save let the zombies chasing the ghost go ("8 zombie(s) stopped chasing it")
    print("zombies_go_after_the_ghost_again_after_a_save")
    L = lua()
    L.execute(FAKES + r"""
        util = require("mirror.util")
        util.cdo = function() return obj({ SetActorSaveProperties = function() end }) end
        StaticFindObject = function() return obj({}) end
        FindFirstOf = function() return nil end
        ME = obj({ GetFullName = function() return "BP_PlayerCharacter_C /Game/L.L:P.Me" end, Controller = obj({}) })
        package.loaded["mirror.game"] = { player = function() return ME end, on_world_reset = function() end }
        package.loaded["mirror.animgate"] = { destroy = function() end, flush = function() return 0 end }
        function zombie()
            local bb = { v = {} }
            bb.GetValueAsObject = function(self, k) return self.v[tostring(k)] end
            bb.SetValueAsObject = function(self, k, o) self.v[tostring(k)] = o end
            bb.SetValueAsBool = function(self, k, b) self.v[tostring(k)] = b end
            bb.SetValueAsVector = function(self, k, x) self.v[tostring(k)] = x end
            bb.ClearValue = function(self, k) self.v[tostring(k)] = nil end
            return obj({ Controller = obj({ Blackboard = bb, Combat = true }) })
        end
        CHASER, OTHER = zombie(), zombie()
        PAWNS = { CHASER, OTHER }
        package.loaded["mirror.zombies"] = { all_cached = function() return PAWNS end }
        ghost = require("mirror.ghost")
        ghost.configure({ ghost = { class = "/Game/X.Ghost_C", target_tag = "t", view_controller = false } })
        local function body()
            local cap = { SetCollisionEnabled = function() end, SetCollisionResponseToAllChannels = function() end,
                          SetCollisionResponseToChannel = function() end }
            local b = obj({ CapsuleComponent = cap, Mesh = { SetCollisionEnabled = function() end,
                         SetCollisionResponseToAllChannels = function() end, SetCollisionResponseToChannel = function() end },
                         MedicalComponent = {}, CharacterMovement = {}, Tags = { Empty = function() end, Add = function() end },
                         AIOInvoker = {}, ActorHasTag = function() return false end })
            b.GetFullName = function() return "BP_PlayerCharacter_C /Game/L.L:P.Ghost" end
            b.K2_GetActorLocation = function() return { X = 1, Y = 2, Z = 3 } end
            b.K2_DestroyActor = function() end
            return b
        end
        WORLD = { SpawnActor = function() return body() end }
        CLOCK = 100; os.clock = function() return CLOCK end
        G1 = ghost.spawn(WORLD, { X = 0, Y = 0, Z = 0 }, 0, "host")
        CHASER.Controller.Blackboard.v.AttackTarget = G1
        ghost.destroy("save", true)
        RELEASED = CHASER.Controller.Blackboard.v.AttackTarget == nil and CHASER.Controller.Combat == false
        CLOCK = CLOCK + 1.5
        G2 = ghost.spawn(WORLD, { X = 0, Y = 0, Z = 0 }, 0, "host")
        BACK = CHASER.Controller.Blackboard.v.AttackTarget == G2 and CHASER.Controller.Combat == true
            and CHASER.Controller.Blackboard.v["CanSeePlayer?"] == true
        LEFT = OTHER.Controller.Blackboard.v.AttackTarget == nil
        -- the other player died: their ghost goes for good, nothing comes back for the next one
        CHASER.Controller.Blackboard.v.AttackTarget = G2
        ghost.destroy("peer dead", true)
        CLOCK = CLOCK + 1
        G3 = ghost.spawn(WORLD, { X = 0, Y = 0, Z = 0 }, 0, "host")
        DEAD_LEFT = CHASER.Controller.Blackboard.v.AttackTarget == nil
    """)
    check(L.eval('RELEASED') is True, "a save lets the zombies after the ghost go, as before")
    check(L.eval('BACK') is True, "the ghost back after the save: the zombies that were after it go after it again")
    check(L.eval('LEFT') is True, "...not the ones that weren't")
    check(L.eval('DEAD_LEFT') is True, "a ghost gone for another reason (death): nobody is sent after the next one")


def a_ghost_the_game_removed_is_let_go_and_made_again():
    # report 2026-10-30 (Realm): after the guest's bed respawn the host stayed invisible to them and /goto went to 0,0,0
    print("a_ghost_the_game_removed_is_let_go_and_made_again")
    L = lua()
    L.execute(FAKES + r"""
        util = require("mirror.util")
        util.cdo = function() return obj({ SetActorSaveProperties = function() end }) end
        StaticFindObject = function() return obj({}) end
        FindFirstOf = function() return nil end
        ME = obj({ GetFullName = function() return "BP_PlayerCharacter_C /Game/L.L:P.Me" end, Controller = obj({}) })
        package.loaded["mirror.game"] = { player = function() return ME end, on_world_reset = function() end }
        GATED = 0
        package.loaded["mirror.animgate"] = { destroy = function() GATED = GATED + 1 end, flush = function() return 0 end }
        local bb = { v = {} }
        bb.GetValueAsObject = function(self, k) return self.v[tostring(k)] end
        bb.SetValueAsObject = function(self, k, o) self.v[tostring(k)] = o end
        bb.SetValueAsBool = function(self, k, b) self.v[tostring(k)] = b end
        bb.SetValueAsVector = function(self, k, x) self.v[tostring(k)] = x end
        bb.ClearValue = function(self, k) self.v[tostring(k)] = nil end
        CHASER = obj({ Controller = obj({ Blackboard = bb, Combat = true }) })
        package.loaded["mirror.zombies"] = { all_cached = function() return { CHASER } end }
        ghost = require("mirror.ghost")
        ghost.configure({ ghost = { class = "/Game/X.Ghost_C", target_tag = "t", view_controller = false } })
        KILLS = 0
        local function body()
            local cap = { SetCollisionEnabled = function() end, SetCollisionResponseToAllChannels = function() end,
                          SetCollisionResponseToChannel = function() end }
            local b = obj({ CapsuleComponent = cap, Mesh = { SetCollisionEnabled = function() end,
                         SetCollisionResponseToAllChannels = function() end, SetCollisionResponseToChannel = function() end },
                         MedicalComponent = {}, CharacterMovement = {}, Tags = { Empty = function() end, Add = function() end },
                         AIOInvoker = {}, ActorHasTag = function() return false end })
            b.at, b.root = { X = 5000, Y = 6000, Z = 300 }, obj({})
            b.GetFullName = function() return "BP_PlayerCharacter_C /Game/L.L:P.Ghost" end
            b.K2_GetActorLocation = function(self) return self.at end
            b.K2_GetRootComponent = function(self) return self.root end
            b.K2_DestroyActor = function() KILLS = KILLS + 1 end
            return b
        end
        WORLD = { SpawnActor = function() return body() end }
        CLOCK = 100; os.clock = function() return CLOCK end
        G1 = ghost.spawn(WORLD, { X = 5000, Y = 6000, Z = 300 }, 0, "host")
        KEPT = ghost.check and (ghost.check(1) == false) and ghost.exists()
        LOC = ghost.location()
        LIVE_AT = LOC and LOC.X == 5000
        CHASER.Controller.Blackboard.v.AttackTarget = G1
        -- the game destroys it (the guest's respawn): still IsValid, root gone, reads 0,0,0
        G1.at, G1.root = { X = 0, Y = 0, Z = 0 }, obj({ IsValid = function() return false end })
        TO = ghost.location()
        GONE = TO == nil and not ghost.exists() and ghost.was(G1)
        UNTOUCHED = KILLS == 0 and GATED == 0
        NO_ORIGIN = CHASER.Controller.Blackboard.v.LastHeardLocation == nil
        CLOCK = CLOCK + 1
        G2 = ghost.spawn(WORLD, { X = 5000, Y = 6000, Z = 300 }, 0, "host")
        BACK = CHASER.Controller.Blackboard.v.AttackTarget == G2
        -- the tick's own check: root gone while the location still reads right
        G2.root = obj({ IsValid = function() return false end })
        EARLY = ghost.check and ghost.check(0.1)
        LATE = ghost.check and ghost.check(0.5)
        TICK_GONE = not ghost.exists()
    """)
    check(L.eval('KEPT') is True and L.eval('LIVE_AT') is True, "a live ghost is kept and read where it stands")
    check(L.eval('GONE') is True, "one the game destroyed (0,0,0, no root) is let go: no teleport to the world's origin")
    check(L.eval('UNTOUCHED') is True, "...without destroying it again (%d K2_DestroyActor, %d gated)" % (L.eval('KILLS'), L.eval('GATED')))
    check(L.eval('NO_ORIGIN') is True, "its zombies aren't sent to 0,0,0")
    check(L.eval('BACK') is True, "the zombies after it go after the new ghost")
    check(L.eval('EARLY') is False and L.eval('LATE') is True and L.eval('TICK_GONE') is True,
          "the tick checks every 0.5 s and lets go of a ghost without a root")


def a_ghost_destroyed_for_a_save_is_never_touched_again():
    print("a_ghost_destroyed_for_a_save_is_never_touched_again")
    L = lua()
    L.execute(FAKES + r"""
        util = require("mirror.util")
        util.cdo = function() return obj({ SetActorSaveProperties = function() end }) end
        StaticFindObject = function() return obj({}) end
        FindFirstOf = function() return nil end
        ME = obj({ GetFullName = function() return "BP_PlayerCharacter_C /Game/L.L:P.Me" end, Controller = obj({}) })
        package.loaded["mirror.game"] = { player = function() return ME end, on_world_reset = function() end }
        ghost = require("mirror.ghost")
        ghost.configure({ ghost = { class = "/Game/X.Ghost_C", target_tag = "t", view_controller = false } })
        TOUCHED, DESTROYS = 0, 0
        local function body()
            local cap = { SetCollisionEnabled = function() end, SetCollisionResponseToAllChannels = function() end,
                          SetCollisionResponseToChannel = function() end }
            local b = obj({ CapsuleComponent = cap, Mesh = { SetCollisionEnabled = function() end,
                         SetCollisionResponseToAllChannels = function() end, SetCollisionResponseToChannel = function() end },
                         MedicalComponent = {}, CharacterMovement = {}, Tags = { Empty = function() end },
                         AIOInvoker = {}, ActorHasTag = function() return false end })
            -- (like the game: still valid once destroyed, and IsActorBeingDestroyed is false again)
            b.GetFullName = function() TOUCHED = TOUCHED + 1; return "BP_PlayerCharacter_C /Game/L.L:P.Ghost" end
            b.IsActorBeingDestroyed = function() return false end
            b.K2_DestroyActor = function() DESTROYS = DESTROYS + 1 end
            return b
        end
        WORLD = { SpawnActor = function() GHOST = body(); return GHOST end }
        ghost.spawn(WORLD, { X = 0, Y = 0, Z = 0 }, 0, "guest")
        HOOKED = {}
        util.hook = function(path, fn) HOOKED[path] = fn end
        package.loaded["mirror.animgate"] = { flush = function() return 0 end }
        save_guard = require("mirror.save_guard")
        save_guard.configure({ save = { destroy_ghost_on_save = true } }, function() end)
        save_guard.install()
        CLOCK = 100; os.clock = function() return CLOCK end
        ghost.destroy("save", true)
        -- (my own autosave came 5 s after the other player died, live 2026-10-30 02:28:37: well inside the window)
        CLOCK = CLOCK + 30
        TOUCHED, DESTROYS = 0, 0
        STRAY = obj({ GetFullName = function() return "BP_PlayerCharacter_C /Game/L.L:P.Left" end,
                      IsActorBeingDestroyed = function() return false end })
        STRAY.K2_DestroyActor = function() STRAY_GONE = true end
        FindAllOf = function() return { ME, GHOST, STRAY } end
        -- another player's copy runs its save check right after mine destroyed my ghost
        HOOKED["/Script/EasyMultiSave.EMSAsyncSaveGame:AsyncSaveActors"]()
    """)
    check(L.eval('DESTROYS') == 0 and L.eval('TOUCHED') == 0,
          "a ghost just destroyed for a save isn't taken for a stray body and touched again (%s destroys, %s reads)"
          % (L.eval('DESTROYS'), L.eval('TOUCHED')))
    check(L.eval('STRAY_GONE') is True, "a real stray body is still removed")
    L.execute('CLOCK = CLOCK + 100; R_LATE = ghost.was(GHOST)')
    check(L.eval('R_LATE') is False, "a ghost destroyed long ago (garbage-collected since) is forgotten")


def audio_spatializes_and_shares_without_echo():
    print("audio_spatializes_and_shares_without_echo")
    L = lua()
    L.execute(FAKES + r"""
        PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end })
        package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end }
        package.loaded["mirror.ghost"] = { is = function() return false end }
        SENT, PLAYED = {}, {}
        package.loaded["mirror.events"] = evmock { new = function() return {
            send = function(self, m) SENT[#SENT + 1] = m end,
            pump = function(self, fn) local q = INBOX; INBOX = {}; for _, m in ipairs(q or {}) do fn(m) end end } end }
        INBOX = {}
        ATTS = {}
        local function att(n) local a = obj({ name = n }); ATTS["/Game/Audio/Attenuation/" .. n .. "." .. n] = a; return a end
        RIFLE, DOOR = att("GunshotsRifle"), att("DoorOpeningClosing")
        function cue(name, own) return obj({ AttenuationSettings = own and obj({}) or obj({ IsValid = function() return false end }),
            GetFName = function() return { ToString = function() return name end } end,
            GetFullName = function() return "SoundCue /Game/Audio/" .. name .. "." .. name end }) end
        CUES = { ["/Game/Audio/Shotgun_Insert_Cue.Shotgun_Insert_Cue"] = cue("Shotgun_Insert_Cue"),
                 ["/Game/Audio/AR_Single_Shot_Cue.AR_Single_Shot_Cue"] = cue("AR_Single_Shot_Cue", true) }
        StaticFindObject = function(p) return ATTS[p] or CUES[p] end
        util = require("mirror.util")
        util.cdo = function() return { PlaySoundAtLocation = function(self, ctx, s, l, r, v, pi, st, att)
            PLAYED[#PLAYED + 1] = { s = s, att = att } end } end
        HOOKS = {}
        RegisterHook = function(n, fn) HOOKS[n:match(":(.+)$")] = fn end
        audio = require("mirror.audio")
        audio.init({}, "host", nil, { family_of = function() return nil end, is_copy = function() return false end,
                                      host_id_of = function() return nil end, copy = function() return nil end }, { last_shot = -100 })
        audio.tick(0.1)
        function P(v) return { get = function() return v end } end
        -- a shared sound as the other game sends it, stamped `ago_ms` before now on the sender's clock (shifted by `off`)
        function MSG(x, ago_ms, off) return string.format("/Game/Audio/Shotgun_Insert_Cue.Shotgun_Insert_Cue %d 0 0 1.00 1.00 %d",
            x, math.floor(os.clock() * 1000) + (off or 0) - ago_ms) end
    """)
    check(L.eval('audio.attenuation_for(CUES["/Game/Audio/Shotgun_Insert_Cue.Shotgun_Insert_Cue"], "/Game/Audio/Shotgun_Insert_Cue.Shotgun_Insert_Cue") == DOOR'),
          "a 2D reload cue gets a short-range attenuation")
    check(L.eval('audio.attenuation_for(CUES["/Game/Audio/AR_Single_Shot_Cue.AR_Single_Shot_Cue"], "/Game/Audio/AR_Single_Shot_Cue.AR_Single_Shot_Cue") == nil'),
          "a cue with its own attenuation keeps it")
    check(L.eval('audio.attenuation_for(cue("explosion_large_06_Cue")) == RIFLE'),
          "a cue passed without its path is still named (an explosion gets the long range)")
    L.execute('INBOX = { MSG(5000, 0) }; audio.tick(0.1)')
    check(L.eval('#PLAYED == 1 and PLAYED[1].att == DOOR'), "a replayed 2D cue plays with the attenuation")
    # This game played the same cue at the same spot itself: the replay is a duplicate.
    L.execute('HOOKS.PlaySoundAtLocation(nil, P(obj({})), P(CUES["/Game/Audio/Shotgun_Insert_Cue.Shotgun_Insert_Cue"]), P({ X = 9000, Y = 0, Z = 0 }), nil, P(1), P(1)); '
              'INBOX = { MSG(9100, 0) }; audio.tick(0.1)')
    check(L.eval('#PLAYED') == 1, "a sound both games played is not doubled")
    # Late sounds (user 2026-10-31: the other player's game sounds were glitchy over Steam at 229 ms). The sender's
    # clock is 7 minutes off from this one: only the delay relative to the smallest one seen counts.
    OFF = 420000
    L.execute('audio.late_reset(); PLAYED = {}; INBOX = { MSG(20000, 229, %d) }; audio.tick(0.1); '
              'INBOX = { MSG(21000, 229, %d), MSG(22000, 260, %d) }; audio.tick(0.1)' % (OFF, OFF, OFF))
    check(L.eval('#PLAYED') == 3, "a steady 229 ms link with a different clock: every sound plays (%s)" % L.eval('#PLAYED'))
    # a 2 s stall: the backlog arrives at once - only what is still within half a second of now plays
    L.execute('PLAYED = {}; INBOX = { MSG(30000, 2229, %d), MSG(31000, 1729, %d), MSG(32000, 1229, %d), MSG(33000, 600, %d), '
              'MSG(34000, 229, %d) }; audio.tick(0.1)' % (OFF, OFF, OFF, OFF, OFF))
    check(L.eval('#PLAYED') == 2, "after a 2 s stall only the sounds under 0.5 s late play, not the backlog (%s)" % L.eval('#PLAYED'))
    # the first batch after joining is a backlog too: judged against its own newest sound
    L.execute('audio.late_reset(); PLAYED = {}; INBOX = { MSG(40000, 3000, %d), MSG(41000, 1500, %d), MSG(42000, 0, %d) }; '
              'audio.tick(0.1)' % (OFF, OFF, OFF))
    check(L.eval('#PLAYED') == 1, "the first batch: only its newest sound plays (%s)" % L.eval('#PLAYED'))
    # the other game restarted (its clock began again, far behind): sounds play again at once, not dropped as late
    L.execute('PLAYED = {}; INBOX = { MSG(50000, 0, %d) }; audio.tick(0.1); INBOX = { MSG(51000, 0, %d) }; audio.tick(0.1)'
              % (OFF - 400000, OFF - 400000))
    check(L.eval('#PLAYED') == 2, "the other game restarted: its sounds play (%s)" % L.eval('#PLAYED'))
    # an old-version message (no clock): dropped, not an error
    L.execute('PLAYED = {}; INBOX = { "/Game/Audio/Shotgun_Insert_Cue.Shotgun_Insert_Cue 60000 0 0 1.00 1.00" }; audio.tick(0.1)')
    check(L.eval('#PLAYED') == 0 and "format=1" in L.eval('audio.status()'), "an old-format sound is dropped and counted")
    # A crate the player opens, 2 m away: its one-shot sound is shared.
    L.execute('CRATE = obj({ GetOwner = function() return nil end }); '
              'HOOKS.PlaySoundAtLocation(nil, P(CRATE), P(CUES["/Game/Audio/Shotgun_Insert_Cue.Shotgun_Insert_Cue"]), P({ X = 200, Y = 0, Z = 0 }), nil, P(1), P(1)); '
              'local t0 = os.clock(); while os.clock() - t0 < 0.12 do end; audio.tick(0.1)')
    check(L.eval('#SENT') == 1, "a sound of something the player uses nearby is shared")


def keycard_doors_open_on_both_games():
    # player report: one area's keycard doors took a keycard on each game (BP_KeycardDoor / secure lab doors
    # weren't synced at all)
    print("keycard_doors_open_on_both_games")
    L = lua()
    L.execute(FAKES + r"""
        GHOST = obj({})
        package.loaded["mirror.ghost"] = { get = function() return GHOST end }
        BLOB = nil
        package.loaded["mirror.link"].get_blob = function(n) if n ~= "doors" then return nil end local b = BLOB; BLOB = nil; return b end
        PUT = nil
        package.loaded["mirror.link"].put_blob = function(n, s) if n == "doors" then PUT = s end end
        util = require("mirror.util")
        function door(c, props)
            local d = obj(props)
            d.GetClass = function() return cls(c) end
            d.K2_GetActorLocation = function() return { X = 100, Y = 200, Z = 0 } end
            d.GetFullName = function() return c .. " /Game/L.L:P." .. c .. "_1" end
            return d
        end
        CARD = door("BP_KeycardDoor_C", { ["Open?"] = false })
        CARD.MC_OpenDoor = function(self, by) OPENED_BY = by; self["Open?"] = true end
        SECURE = door("BP_LaboratorySecureDoors_C", { Unlocked = false })
        util.instances = function(c)
            if c == "BP_KeycardDoor_C" then return { CARD }, true elseif c == "BP_LaboratorySecureDoors_C" then return { SECURE }, true end
            return {}, true
        end
        doors = require("mirror.doors")
        doors.init({}, "guest", { in_world = function() return true end })
        for i = 1, 40 do doors.tick(0.3) end
        BLOB = "BP_KeycardDoor_C@10,20,0 1 1 -1 0\nBP_LaboratorySecureDoors_C@10,20,0 1 -1 1 0"
        doors.tick(0.3)
        OPEN1, UNLOCKED1 = CARD["Open?"], SECURE.Unlocked
        for i = 1, 3 do doors.tick(0.3) end
        ECHO = PUT
        -- it closed on their side first (each closes on its own timer): this one isn't shut from here
        CARD.MC_OpenDoor = function() CALLED_AGAIN = true end
        BLOB = "BP_KeycardDoor_C@10,20,0 2 0 -1 0"
        doors.tick(0.3)
        -- and the other way: closed here by its timer, then opened here with my keycard -> told to the other game
        CARD["Open?"] = false; for i = 1, 25 do doors.tick(0.3) end
        PUT = nil
        CARD["Open?"] = true; for i = 1, 3 do doors.tick(0.3) end
        MINE_SENT = PUT
    """)
    sent = L.eval("MINE_SENT") or ""
    check("BP_KeycardDoor_C@10,20,0" in sent and " 1 -1 " in sent, "a keycard door opened here is told to the other game (%r)" % sent)
    check(L.eval("OPEN1") is True and L.eval("OPENED_BY == GHOST"), "the other player's keycard door opens here too, facing them, no keycard")
    check(L.eval("UNLOCKED1") is True, "a secure lab door they unlocked is unlocked here")
    echo = L.eval("ECHO")
    check(not echo or "BP_KeycardDoor_C" not in echo, "opening it here is not sent back as my own (%r)" % echo)
    check(L.eval("CALLED_AGAIN") is None, "their door closing doesn't shut (or reopen) this one")


def doors_of_one_master_are_found_in_one_walk():
    # kit 2026-10-31: each door class was its own 30-60 ms walk, one a frame, right after a join ("perf: doors took 63 ms");
    # the keycard/keypad/container/barrier doors are all children of BP_MasterDoor_C (live class chains)
    print("doors_of_one_master_are_found_in_one_walk")
    L = lua()
    L.execute(FAKES + r"""
        NOW = 0; os.clock = function() return NOW end
        package.loaded["mirror.ghost"] = { get = function() return nil end }
        package.loaded["mirror.link"].get_blob = function() return nil end
        package.loaded["mirror.link"].put_blob = function() end
        util = require("mirror.util")
        StaticFindObject = function() return nil end
        local function door(c, x)
            local d = obj({ ["Open?"] = false })
            d.GetClass = function() return cls(c) end
            d.K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end
            d.GetFullName = function() return c .. " /Game/L.L:P." .. c .. "_" .. x end
            return d
        end
        WORLD = { door("BP_ContainerDoors_C", 100), door("BP_KeycardDoor_C", 200), door("BP_KeycardDoor_Child_C", 300),
                  door("BP_BarrierGate_C", 400), door("BP_KeypadDoor_C", 500),
                  door("BP_HangarDoor_C", 600),    -- (a child of the master the mod doesn't sync, live 2026-10-31)
                  door("BP_WarehouseDoors_C", 700) }
        -- (the game has the warehouse door's class and its BeginPlay loaded)
        StaticFindObject = function(p) if p:find("BP_WarehouseDoors", 1, true) then return obj({ GetFName = function()
            return { ToString = function() return p:match("ReceiveBeginPlay$") and "ReceiveBeginPlay" or "BP_WarehouseDoors_C" end } end }) end end
        local PARENT = { BP_KeycardDoor_Child_C = "BP_KeycardDoor_C" }
        CALLS = {}
        -- like the engine: a class's FindAllOf returns its children's objects too
        FindAllOf = function(c)
            CALLS[c] = (CALLS[c] or 0) + 1
            local out = {}
            for _, o in ipairs(WORLD) do
                local k = util.class_name(o)
                if c == "BP_MasterDoor_C" or k == c or PARENT[k] == c then out[#out + 1] = o end
            end
            return out
        end
        doors = require("mirror.doors")
        doors.init({}, "guest", { in_world = function() return true end })
        for i = 1, 200 do NOW = NOW + 0.3; util.new_frame(); doors.tick(0.3) end
        STATUS, M1 = doors.status(), CALLS.BP_MasterDoor_C
        OWN1 = {}
        for _, o in ipairs(WORLD) do local c = util.class_name(o); if CALLS[c] then OWN1[#OWN1 + 1] = c end end
        -- a door that comes later (an event site's): the group's 5 min re-walk finds it, for every member alike
        WORLD[#WORLD + 1] = door("BP_KeypadDoor_C", 800)
        for i = 1, 1100 do NOW = NOW + 0.3; util.new_frame(); doors.tick(0.3) end
        STATUS2 = doors.status()
    """)
    own = L.eval("table.concat(OWN1, ',')")
    check(L.eval("M1") == 1 and own == "",
          "one walk of BP_MasterDoor_C finds its door classes in the first minute (master %s, own walks %r)" % (L.eval("M1"), own))
    check(L.eval("STATUS").startswith("doors: 6 here"), "...and all 6 doors are synced, the keycard child under its own class (%s)"
          % L.eval("STATUS"))
    check(L.eval("STATUS2").startswith("doors: 7 here") and L.eval("CALLS.BP_MasterDoor_C") == 2,
          "a keypad door that comes later is found by the group's re-walk within 5 min (%s, %s master walks)"
          % (L.eval("STATUS2"), L.eval("CALLS.BP_MasterDoor_C")))


def doors_forget_the_old_world_at_a_load():
    # hardening 2026-10-30: the host stays active through its own loads, so set_active never cleared the doors - the
    # old world's door objects were read after the load and its unlocks were sent on to the next world's guest
    print("doors_forget_the_old_world_at_a_load")
    L = lua()
    L.execute(FAKES + r"""
        PUT = nil
        package.loaded["mirror.link"].put_blob = function(n, s) if n == "doors" then PUT = s end end
        util = require("mirror.util")
        function door(name)
            local d = obj({ Unlocked = false })
            d.GetClass = function() return cls("BP_LaboratorySecureDoors_C") end
            d.K2_GetActorLocation = function() return { X = 100, Y = 200, Z = 0 } end
            d.GetFullName = function() return "BP_LaboratorySecureDoors_C /Game/L.L:P." .. name end
            return d
        end
        OLD = door("Old")
        HERE = { OLD }
        util.instances = function(c)
            if c == "BP_LaboratorySecureDoors_C" then return HERE, true end
            return {}, true
        end
        doors = require("mirror.doors")
        doors.init({}, "host", { in_world = function() return true end })
        for i = 1, 40 do doors.tick(0.3) end
        OLD.Unlocked = true
        for i = 1, 3 do doors.tick(0.3) end
        SENT_A = PUT
        -- the host loads another save: the old door is freed, the new world's one is locked
        READ_OLD = false
        OLD.IsValid = function() READ_OLD = true; return true end
        HERE = {}
        require("mirror.game").reset_world()
        doors.tick(0.3)
        SENT_B = PUT
        HERE = { door("New") }
        for i = 1, 40 do doors.tick(0.3) end
    """)
    check("BP_LaboratorySecureDoors_C" in (L.eval("SENT_A") or ""), "the unlock is sent in the first world (%r)" % L.eval("SENT_A"))
    check("BP_LaboratorySecureDoors_C" not in (L.eval("SENT_B") or ""), "after the load it isn't sent any more (%r)" % L.eval("SENT_B"))
    check(L.eval("READ_OLD") is False, "the old world's door is never read after the load")


def throws_and_mines_reach_the_other_game():
    print("throws_and_mines_reach_the_other_game")
    L = lua()
    L.execute(FAKES + r"""
        PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end })
        package.loaded["mirror.game"] = { player = function() return PLAYER end, world = function() return nil end,
                                          on_world_reset = function() end }
        package.loaded["mirror.ghost"] = { get = function() return nil end, is = function() return false end }
        package.loaded["mirror.bedtags"] = { gone = function() end, tick = function() end, init = function() end }
        package.loaded["mirror.audio"] = { attenuation_for = function() return nil end }
        SENT = {}
        INBOX = {}
        package.loaded["mirror.events"] = evmock { new = function(name) return {
            send = function(self, m) SENT[#SENT + 1] = name .. ":" .. m end,
            pump = function(self, fn) local q = INBOX[name] or {}; INBOX[name] = {}; for _, m in ipairs(q) do fn(m) end end } end,
            send = function(self, m) SENT[#SENT + 1] = "builds:" .. m end }
        StaticFindObject = function() return obj({}) end
        util = require("mirror.util")
        HOOKS = {}
        util.ensure_hook = function(path, fn) HOOKS[path:match("([%w_]+:[%w_]+)$")] = fn; return true end
        BOOMS = 0
        util.cdo = function() return { SpawnEmitterAtLocation = function() BOOMS = BOOMS + 1 end, PlaySoundAtLocation = function() end } end
        function actor(cname, x)
            local a = obj({ dead = false })
            a.GetClass = function() return cls(cname) end
            a.K2_GetActorLocation = function() return a.dead and { X = 0, Y = 0, Z = 0 } or { X = x, Y = 0, Z = 0 } end
            a.IsActorBeingDestroyed = function() return a.dead end
            a.K2_DestroyActor = function() a.dead = true end
            a.GetFullName = function() return cname .. " /Game/L.L:P." .. cname .. "_1" end
            return a
        end
        throwables = require("mirror.throwables")
        throwables.init({ mirror_throwables = true })
        throwables.tick(0.1)
        function P(v) return { get = function() return v end } end
    """)
    L.execute('NEAR = actor("BP_Throwable_Molotov_C", 120); HOOKS["BP_Throwable_Molotov_C:ReceiveBeginPlay"](P(NEAR)); throwables.tick(0.1)')
    check(any(m.startswith("throws:S ") and "BP_Throwable_Molotov" in m for m in L.eval('SENT').values()),
          "a hotbar molotov (no owner) thrown by the player is sent")
    L.execute('SENT = {}; FAR = actor("BP_Throwable_Frag_C", 5000); HOOKS["BP_Throwable_Frag_C:ReceiveBeginPlay"](P(FAR)); throwables.tick(0.1)')
    check(not any("Frag" in m for m in L.eval('SENT').values()), "an unowned throwable far from the player is not ours")
    # player report: one throw showed as 2-8 grenades. The copy's BeginPlay runs inside SpawnActor (like the
    # engine here), standing next to the thrower it looked like our own throw and went back
    L.execute(r"""
        SENT = {}
        WORLD = { SpawnActor = function(self, cls, loc) local a = actor("BP_Throwable_Frag_C", loc.X)
            HOOKS["BP_Throwable_Frag_C:ReceiveBeginPlay"](P(a)); return a end }
        package.loaded["mirror.game"].world = function() return WORLD end
        INBOX.throws = { "S 7 BP_Throwable_Frag 100 0 0" }
        for i = 1, 3 do throwables.tick(0.1) end
    """)
    check(not any(m.startswith("throws:S ") for m in L.eval('SENT').values()),
          "the other player's grenade shown next to me is not sent back as mine (%s)" % list(L.eval('SENT').values()))
    check("flying 1" in L.eval('throwables.status()'), "...and it is shown once")
    # experimental 2026-10-29: the noise maker calls the AI every 2 s until the game destroys it ("E")
    L.execute(r"""
        NOISES = 0
        local base = util.cdo
        util.cdo = function(p) if p:find("AISense_Hearing") then return { ReportNoiseEvent = function() NOISES = NOISES + 1 end } end return base(p) end
        INBOX.throws = { "S 8 BP_Throwable_NoiseMaker 300 0 0" }; throwables.tick(0.1)
        INBOX.throws = { "X 8 300 0 0" }; throwables.tick(0.1)
        N_OFF = NOISES
        for i = 1, 50 do throwables.tick(0.1) end
        N_5S = NOISES
        INBOX.throws = { "E 8" }; throwables.tick(0.1)
        for i = 1, 100 do throwables.tick(0.1) end
        N_AFTER_E = NOISES
        INBOX.throws = { "S 9 BP_Throwable_NoiseMaker 300 0 0" }; throwables.tick(0.1)
        INBOX.throws = { "X 9 300 0 0" }; throwables.tick(0.1)
        N9 = NOISES
        for i = 1, 400 do throwables.tick(0.1) end
        N9_END = NOISES - N9
        util.cdo = base; BOOMS = 0
    """)
    check(L.eval('N_OFF') == 1 and L.eval('N_5S') == 3,
          "the other player's noise maker keeps calling the AI here every 2 s (%d, then %d after 5 s)" % (L.eval('N_OFF'), L.eval('N_5S')))
    check(L.eval('N_AFTER_E') == L.eval('N_5S'), "...and stops when theirs is gone")
    check(L.eval('N9_END') == 9, "...and on its own after 20 s, as long as the game's own calls (%d calls)" % L.eval('N9_END'))
    # Land mines: one placed in each game; ours goes off -> the other game shows it and loses its copy.
    L.execute(r"""
        builds = require("mirror.builds")
        builds.init({}, "host", nil)
        builds.tick(1.1)
        MINE = actor("Buildable_LandMine_C", 3000)
        HOOKS["Buildable_LandMine_C:ReceiveBeginPlay"](P(MINE))
        MINE.dead = true
        SENT = {}
        HOOKS["Buildable_LandMine_C:Event_Explode"](P(MINE))
    """)
    sent = list(L.eval('SENT').values())
    check(any(m.startswith("builds:X Buildable_LandMine_C@300,0,0") for m in sent), "an exploded mine is sent with its place")
    L.execute(r"""
        COPY = actor("Buildable_LandMine_C", 3001)
        util.all_of = function() return { COPY }, 0 end
        INBOX.builds = { "X Buildable_LandMine_C@300,0,0" }
        builds.tick(0.1)
    """)
    check(L.eval('COPY.dead') and L.eval('BOOMS') == 1, "the other game's mine shows the explosion and is removed")
    # Turret pick-up: OnInteractBuildable's hook runs after the turret destroyed itself (place reads 0,0,0) - without
    # the place from its BeginPlay nothing was sent and the other game kept its copy (placed again near it: two
    # turrets stacked there, DBG-20261027-004)
    L.execute(r"""
        TUR = actor("Buildable_Turret_C", 5000)
        HOOKS["Buildable_Turret_C:ReceiveBeginPlay"](P(TUR))
        TUR.dead = true
        SENT = {}
        HOOKS["Buildable_Turret_C:OnInteractBuildable"](P(TUR))
    """)
    sent = list(L.eval('SENT').values())
    check(any(m == "builds:R Buildable_Turret_C@500,0,0" for m in sent),
          "a picked-up turret is sent with its place even when the hook only runs after it is gone (%s)" % sent)
    # A place sent again (a join's save already holds the piece) a few mm across a 10 cm grid line: the exact id
    # missed it and built it twice. A fence's neighbour 2 m on is a new piece (rejoin live 2026-10-30).
    L.execute(r"""
        FENCE, BUILT = actor("Buildable_MetalFence_C", 1004.9), {}
        local fcls = cls("Buildable_MetalFence_C")
        StaticFindObject = function() return obj({ BuildActorClass = fcls }) end
        util.all_of = function() local l = { FENCE }; for _, b in ipairs(BUILT) do l[#l + 1] = b end; return l, 0 end
        WORLD = { SpawnActor = function(self, c, loc) local a = actor("Buildable_MetalFence_C", loc.X); BUILT[#BUILT + 1] = a; return a end }
        package.loaded["mirror.game"].world = function() return WORLD end
        INBOX.builds = { "P /Game/B/DA_MetalFence.DA_MetalFence 1005.10 0 0 0 0 0 1 1 1" }
        builds.tick(0.1)
        N1 = #BUILT
        INBOX.builds = { "P /Game/B/DA_MetalFence.DA_MetalFence 1215.00 0 0 0 0 0 1 1 1" }
        builds.tick(0.1)
        N2 = #BUILT
    """)
    check(L.eval('N1') == 0, "a fence sent again 2 mm off, across a grid line: not built twice (%s)" % L.eval('N1'))
    check(L.eval('N2') == 1, "its neighbour 2.1 m on is built")


def map_pings_reach_the_other_game():
    print("map_pings_reach_the_other_game")
    L = lua()
    L.execute(FAKES + r"""
        TEX = "MarkerTexture_10_217A4B4A49F28BE075685196E3EC66CD"
        COL = "MarkerColor_52_AB92BD2E4886BEC45F39A59226A8B872"
        SIZE = "TextureSize_30_0FC614D34939DCCA4077899925344EDF"
        CMP = "CompassMarker?_45_173EEC314B156D67370A86A9FF973EA4"
        function texture(p) return obj({ GetFullName = function() return "Texture2D " .. p end }) end
        SKULL, POINT = texture("/Game/T/T_Skull.T_Skull"), texture("/Game/T/T_Point.T_Point")
        function data(t, r) return { [TEX] = t, [COL] = { R = r, G = 0, B = 0, A = 1 }, [SIZE] = { X = 32, Y = 32 }, [CMP] = true } end
        HOOKS = {}
        function P(v) return { get = function() return v end } end
        MARKERS, COMPASSES, QMARKS = {}, {}, {}
        -- BP_CompassMarker: one compass icon each (the ping spawns it at its own place when CompassMarker? is set)
        function compass(x)
            local c = obj({ gone = false })
            c.IsValid = function() return not c.gone end
            c.K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end
            c.K2_DestroyActor = function() c.gone = true end
            COMPASSES[#COMPASSES + 1] = c
            return c
        end
        function marker(x, d)
            local m = obj({ ["Marker Data"] = d, gone = false })
            m.IsValid = function() return not m.gone end
            m.K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end
            if d and d[CMP] then m.CompassMarker = compass(x) end
            MARKERS[#MARKERS + 1] = m
            return m
        end
        -- the game: placing runs Event_AddMarker with the picker's data; removing runs ReceiveDestroyed inside
        COMP = obj({ DefaultPlayerMarkerData = data(POINT, 1) })
        ADD, DESTROYED, REMOVE = "BP_PlayerMarker_C:Event_AddMarker", "BP_PlayerMarker_C:ReceiveDestroyed", "BPC_MinimapSystem_C:Remove Player Marker"
        COMP.Svr_SpawnPlayerMarker = function(self, l, ok)
            local d = self.DefaultPlayerMarkerData
            SPAWNED = marker(l.X, { [TEX] = d[TEX], [COL] = { R = d[COL].R }, [SIZE] = d[SIZE], [CMP] = d[CMP] })
            HOOKS[ADD](P(SPAWNED))
        end
        COMP["Remove Player Marker"] = function(self, m)
            if m.CompassMarker then m.CompassMarker.gone = true end   -- (its ReceiveDestroyed: only the one it holds)
            HOOKS[DESTROYED](P(m)); m.gone = true; HOOKS[REMOVE](P(self), P(m))
        end
        -- laptop scans: quest marker class + defaults, the crate class, a world that spawns
        QM_CDO = { IsValid = function() return true end, ["Marker Texture"] = POINT, Color = { R = 1, G = 1, B = 1, A = 1 },
                   Text = { ToString = function() return "Default" end }, ["Underground?"] = false }
        QM_CLS, CRATE_CLS = obj({}), obj({ GetFName = function() return { ToString = function() return "BP_GuaranteedSpawner_Classified_C" end } end,
            GetFullName = function() return "BlueprintGeneratedClass /Game/Inv/BP_GuaranteedSpawner_Classified.BP_GuaranteedSpawner_Classified_C" end })
        OBJS = { ["/Game/T/T_Skull.T_Skull"] = SKULL, ["/Game/Quests/Blueprints/Objects/BP_QuestMarker.BP_QuestMarker_C"] = QM_CLS,
                 ["/Game/Quests/Blueprints/Objects/BP_QuestMarker.Default__BP_QuestMarker_C"] = QM_CDO,
                 ["/Game/Inv/BP_GuaranteedSpawner_Classified.BP_GuaranteedSpawner_Classified_C"] = CRATE_CLS }
        CRATES, WORLD_SPAWNED = {}, {}
        WORLD = { SpawnActor = function(self, c, l, r)
            local a = obj({ gone = false, cls = c, rot = r })
            a.IsValid = function() return not a.gone end
            a.K2_GetActorLocation = function() return l end
            a.K2_DestroyActor = function() a.gone = true end
            if c == QM_CLS then a.tex, a.color, a.text, a.ug = QM_CDO["Marker Texture"], QM_CDO.Color.R, QM_CDO.Text, QM_CDO["Underground?"] end
            if c == CRATE_CLS then
                a.GetClass = function() return CRATE_CLS end
                a.MC_CrateOpen = function() a.lid = true end
                CRATES[#CRATES + 1] = a
            end
            WORLD_SPAWNED[#WORLD_SPAWNED + 1] = a
            return a
        end }
        HAS_COMP = true
        PLAYER = obj({ GetComponentByClass = function() return HAS_COMP and COMP or nil end })
        package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end,
                                          world = function() return WORLD end }
        SHARE = true
        package.loaded["mirror.mysettings"] = { on = function(k) return k == "pings" and SHARE end }
        RELAYED = 0
        package.loaded["mirror.peers"] = { shared = function(n, init) return init end,
                                           relay = function(n, self, fn) RELAYED = RELAYED + 1 end }
        SENT, INBOX = {}, {}
        package.loaded["mirror.events"] = evmock { new = function(name) return {
            send = function(self, m) SENT[#SENT + 1] = m end,
            pump = function(self, fn) local q = INBOX[name] or {}; INBOX[name] = {}; for _, m in ipairs(q) do fn(m) end end } end }
        StaticFindObject = function(p) return OBJS[p] or obj({}) end
        FindAllOf = function(c)
            if c == "BP_GuaranteedSpawner_Classified_C" then return CRATES end
            if c == "BP_CompassMarker_C" then return COMPASSES end
            if c == "BP_QuestMarker_C" then return QMARKS end
            return MARKERS
        end
        util = require("mirror.util")
        util.ensure_hook = function(path, fn) HOOKS[path:match("([%w_]+:[^:]+)$")] = fn; return true end
        IN_WORLD = true
        pings = require("mirror.pings")
        pings.init({}, "guest", { in_world = function() return IN_WORLD end })
        pings.tick(1.1)
        function place(x, d) local m = marker(x, d); HOOKS[ADD](P(m)); return m end
    """)
    L.execute('MINE = place(500, data(SKULL, 1))')
    check(list(L.eval('SENT').values()) == ["A 500 0 0 /Game/T/T_Skull.T_Skull 1.000 0.000 0.000 1.000 32.0 32.0 1"],
          "a ping I place is sent with its place and look (%s)" % list(L.eval('SENT').values()))
    L.execute('SENT = {}; INBOX.pings = { "A 2000 0 0 /Game/T/T_Skull.T_Skull 0.500 0.000 0.000 1.000 32.0 32.0 0" }; pings.tick(0.1)')
    check(L.eval('SPAWNED and SPAWNED["Marker Data"]["%s"] == SKULL and SPAWNED["Marker Data"]["%s"].R == 0.5' % (
        "MarkerTexture_10_217A4B4A49F28BE075685196E3EC66CD", "MarkerColor_52_AB92BD2E4886BEC45F39A59226A8B872")),
        "the other player's ping is placed here with its own look")
    check(L.eval('COMP.DefaultPlayerMarkerData[TEX] == POINT and COMP.DefaultPlayerMarkerData[COL].R == 1 and COMP.DefaultPlayerMarkerData[CMP] == true'),
          "...and my marker picker keeps my own choice")
    check(L.eval('#SENT') == 0, "...and it is not sent back")
    check(L.eval('RELAYED') == 1, "...and the host passes it on to the other guests")
    L.execute('INBOX.pings = { "A 2000 0 0 - 1 1 1 1 0 0 0" }; N = #MARKERS; pings.tick(0.1)')
    check(L.eval('#MARKERS == N'), "a ping already there isn't placed twice")
    L.execute('THEIRS = SPAWNED; INBOX.pings = { "R 2010 0 0" }; pings.tick(0.1)')
    check(L.eval('THEIRS.gone') and L.eval('#SENT') == 0, "the other player's removal removes it here, without echo")
    L.execute('COMP["Remove Player Marker"](COMP, MINE)')
    check(list(L.eval('SENT').values()) == ["R 500 0 0"], "removing my ping is sent (%s)" % list(L.eval('SENT').values()))
    # a ping that came with the world (loaded before the hooks stood) is still found for a removal
    L.execute('SENT = {}; OLD = marker(9000, data(POINT, 1)); INBOX.pings = { "R 9000 0 0" }; pings.tick(0.1)')
    check(L.eval('OLD.gone'), "a removal finds a ping loaded with the world")
    L.execute('SHARE = false; place(700, data(SKULL, 1))')
    check(L.eval('#SENT') == 0, "SHARE MAP PINGS off: my pings stay mine")
    L.execute('SHARE = true; IN_WORLD = false; place(800, data(SKULL, 1))')
    check(L.eval('#SENT') == 0, "a guest at home doesn't send its own world's pings")
    L.execute('IN_WORLD = true; HAS_COMP = false; N = #MARKERS; INBOX.pings = { "A 4000 0 0 - 1 1 1 1 0 0 0" }; pings.tick(0.1)')
    check(L.eval('#MARKERS == N') and "waiting 1" in L.eval('pings.status()'), "no map yet (respawning): the ping waits")
    L.execute('HAS_COMP = true; pings.tick(2.1)')
    check(L.eval('#MARKERS == N + 1') and "waiting" not in L.eval('pings.status()'), "...and is placed once the map is back")
    # a respawn (SD_GameInstance Survival_Respawn) runs RespawnMarker on every ping: it spawns a new compass marker over
    # the one the ping holds and never destroys the old one, so a removed ping left a compass icon behind
    L.execute(r"""
        function respawn()
            for _, m in ipairs(MARKERS) do
                if not m.gone and m["Marker Data"][CMP] then m.CompassMarker = compass(m.K2_GetActorLocation().X) end
            end
        end
        function icons_at(x)
            local n = 0
            for _, c in ipairs(COMPASSES) do if not c.gone and math.abs(c.K2_GetActorLocation().X - x) < 100 then n = n + 1 end end
            return n
        end
        INBOX.pings = { "A 3000 0 0 - 1 1 1 1 0 0 1" }; pings.tick(0.1)
        THEIRS2 = SPAWNED
        MINE2 = place(3500, data(SKULL, 1))
        KEEP = place(6000, data(SKULL, 1))
        QUEST = obj({ CompassMarker = compass(3000) }); QMARKS[1] = QUEST
        respawn()
        A0, B0 = icons_at(3000), icons_at(3500)
        INBOX.pings = { "R 3000 0 0" }; pings.tick(0.1); pings.tick(0.1)
        COMP["Remove Player Marker"](COMP, MINE2); pings.tick(0.1)
    """)
    check(L.eval('A0 == 3 and B0 == 2'), "a respawn leaves a second compass marker per ping (%s at 3000, %s at 3500)" % (L.eval('A0'), L.eval('B0')))
    check(L.eval('THEIRS2.gone') and L.eval('icons_at(3000)') == 1 and not L.eval('QUEST.CompassMarker.gone'),
          "the other player's removal after a respawn takes all its compass icons here, a quest marker's on the spot stays (%s left)" % L.eval('icons_at(3000)'))
    check(L.eval('icons_at(3500)') == 0, "removing my own ping after a respawn takes all its compass icons (%s left)" % L.eval('icons_at(3500)'))
    check(not L.eval('KEEP.CompassMarker.gone'), "a ping still there keeps its compass icon")
    # military laptop scans: the bounty quest's map icon and its crate reach the other game
    L.execute(r"""
        SENT = {}
        function event(path, tag) return obj({ GetFullName = function() return "Quest_Event_SpawnMarker_C " .. path end,
            Location = { X = 100, Y = 200, Z = 300 }, ["Marker Texture"] = SKULL, Color = { R = 0.25, G = 0.5, B = 0, A = 1 },
            ["Underground?"] = true, ActorTag = { ToString = function() return tag end }, Text = "Classified container" }) end
        BOUNTY = event("/Game/Quests/Quests/Bounties/FindClassifiedContainer/Quest_Bounty_ClassifiedContainer001.Default__Quest_Bounty_ClassifiedContainer001_C:QuestTemplate.Event_SpawnMarker_C_0", "Bounty01")
        STORY = event("/Game/Quests/Quests/Main/Quest_Main_FindRadio.Default__Quest_Main_FindRadio_C:QuestTemplate.Event_SpawnMarker_C_0", "Radio")
        HOOKS["Quest_Event_SpawnMarker_C:ExecuteEvent"](P(BOUNTY))
        HOOKS["Quest_Event_SpawnMarker_C:ExecuteEvent"](P(STORY))
    """)
    check(list(L.eval('SENT').values()) == ["Q 100 200 300 /Game/T/T_Skull.T_Skull 0.250 0.500 0.000 1.000 1 Bounty01 Classified container"],
          "a laptop scan's map icon is sent, a story quest's isn't (%s)" % list(L.eval('SENT').values()))
    L.execute('SENT = {}; INBOX.pings = { "Q 100 200 300 /Game/T/T_Skull.T_Skull 0.250 0.500 0.000 1.000 1 Bounty01 Classified container" }; pings.tick(0.1)')
    check(L.eval('#WORLD_SPAWNED == 1 and WORLD_SPAWNED[1].cls == QM_CLS and WORLD_SPAWNED[1].tex == SKULL and WORLD_SPAWNED[1].color == 0.25 '
                 'and WORLD_SPAWNED[1].text == "Classified container" and WORLD_SPAWNED[1].ug == true'),
          "the other player's scan icon is shown here with its look")
    check(L.eval('QM_CDO["Marker Texture"] == POINT and QM_CDO.Color.R == 1 and QM_CDO.Text == "Default" and QM_CDO["Underground?"] == false'),
          "...and the quest marker class keeps its own defaults")
    L.execute('INBOX.pings = { "Q 100 200 300 - 1 1 1 1 0 Bounty01 x" }; pings.tick(0.1)')
    check(L.eval('#WORLD_SPAWNED') == 1, "...shown once")
    L.execute('HOOKS["Quest_Event_RemoveMarker_C:ExecuteEvent"](P(BOUNTY))')
    check(list(L.eval('SENT').values()) == ["X Bounty01"], "the scan's icon going away is sent")
    L.execute('SENT = {}; INBOX.pings = { "X Bounty01" }; pings.tick(0.1)')
    check(L.eval('WORLD_SPAWNED[1].gone'), "...and the copy goes away here")
    L.execute(r"""
        function spawner(cls, tag) return obj({ ObjectToSpawn = cls, QuestTag = { ToString = function() return tag end },
            K2_GetActorLocation = function() return { X = 5000, Y = 0, Z = 10 } end,
            K2_GetActorRotation = function() return { Pitch = 0, Yaw = 90, Roll = 0 } end }) end
        HOOKS["BP_Quest_Spawner_Object_C:Quest_Spawn"](P(spawner(CRATE_CLS, "Quest_Main_Radio")))
        HOOKS["BP_Quest_Spawner_Object_C:Quest_Spawn"](P(spawner(CRATE_CLS, "Quest_Bounty_ClassifiedContainer004")))
    """)
    check(list(L.eval('SENT').values()) == ["C /Game/Inv/BP_GuaranteedSpawner_Classified.BP_GuaranteedSpawner_Classified_C 5000.0 0.0 10.0 0.00 90.00 0.00"],
          "a bounty quest's crate is sent, a story quest's spawn isn't (%s)" % list(L.eval('SENT').values()))
    L.execute('SENT = {}; INBOX.pings = { "C /Game/Inv/BP_GuaranteedSpawner_Classified.BP_GuaranteedSpawner_Classified_C 5000.0 0.0 10.0 0.00 90.00 0.00" }; pings.tick(0.1)')
    check(L.eval('#CRATES == 1 and CRATES[1].rot.Yaw == 90 and CRATES[1].K2_GetActorLocation().X == 5000'),
          "the other player's laptop crate is placed here at the same spot")
    L.execute('INBOX.pings = { "C /Game/Inv/BP_GuaranteedSpawner_Classified.BP_GuaranteedSpawner_Classified_C 5000.0 0.0 10.0 0.00 90.00 0.00" }; pings.tick(0.1)')
    check(L.eval('#CRATES') == 1 and L.eval('#SENT') == 0, "...once, and nothing goes back")
    check(L.eval('CRATES[1].Opened') is True, "...already searched here: the item and the quest stay the scanner's")
    # a crate class not loaded here is never loaded from our Lua (a LoadAsset there can deadlock, L-014): it waits
    L.execute(r"""
        LOADS = 0; LoadAsset = function() LOADS = LOADS + 1 end
        local fa = FindAllOf; FindAllOf = function(c) if c == "BP_Other_C" then return {} end return fa(c) end
        P2 = "/Game/Inv/BP_Other.BP_Other_C"
        OBJS[P2] = { IsValid = function() return false end }
        N0 = #WORLD_SPAWNED
        INBOX.pings = { "C " .. P2 .. " 7000.0 0.0 10.0 0.00 0.00 0.00" }; pings.tick(0.1)
        N1 = #WORLD_SPAWNED
        OBJS[P2] = obj({}); pings.tick(2.1)
        N2 = #WORLD_SPAWNED
    """)
    check(L.eval('LOADS') == 0 and L.eval('N1 == N0'), "a crate whose class isn't loaded here isn't loaded from Lua - it waits")
    check(L.eval('N2 == N0 + 1'), "...and is placed once the game has the class")
    L.execute('HOOKS["BP_GuaranteedSpawner_C:Svr_CrateOpen"](P(CRATES[1]))')
    check(L.eval('#SENT') == 0, "searching the copy sends nothing")
    L.execute(r"""
        MINE_CRATE = obj({ GetClass = function() return CRATE_CLS end, K2_GetActorLocation = function() return { X = 9000, Y = 0, Z = 0 } end })
        HOOKS["BP_GuaranteedSpawner_C:Svr_CrateOpen"](P(MINE_CRATE))
    """)
    check(list(L.eval('SENT').values()) == ["O BP_GuaranteedSpawner_Classified_C 9000.0 0.0 0.0"], "searching my own scan's crate is sent (%s)" % list(L.eval('SENT').values()))
    L.execute('SENT = {}; INBOX.pings = { "O BP_GuaranteedSpawner_Classified_C 5000.0 0.0 10.0" }; pings.tick(0.1)')
    check(L.eval('CRATES[1].lid') is True and L.eval('#SENT') == 0, "the scanner searching theirs opens the copy's lid here, no echo")


def drops_pickup_reaches_every_guest():
    # T10 audit 2026-10-31: drops.lua set channel.send twice; the later one (checkpoint on D/T) replaced the relay
    # send, so with 3-4 players a pickup on the host reached only the guest who dropped the item.
    print("drops_pickup_reaches_every_guest")
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.game"] = { player = function() return nil end, world = function() return nil end,
                                          on_world_reset = function() end }
        package.loaded["mirror.bedtags"] = { gone = function() end, tick = function() end, init = function() end }
        SENT, RELAYED, CHECKPOINTS = {}, {}, 0
        package.loaded["mirror.events"] = evmock { new = function(name) return {
            send = function(self, m) SENT[#SENT + 1] = name .. ":" .. m end, pump = function() end } end,
            send = function(self, m) SENT[#SENT + 1] = "drops:" .. m end }
        package.loaded["mirror.peers"] = { relaying = function() return false end, my_slot = function() return 0 end,
            each = function() end, relay = function(name, self, fn) RELAYED[#RELAYED + 1] = name end }
        StaticFindObject = function() return obj({}) end
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        util.cdo = function() return nil end
        drops = require("mirror.drops")
        drops.init({ mirror_drops = true }, "host", { in_world = function() return true end,
            checkpoint = function() CHECKPOINTS = CHECKPOINTS + 1 end })
        drops.relay_take("T U1 0")
    """)
    check(L.eval("#SENT") == 1 and L.eval("SENT[1]") == "drops:T U1 0", "the pickup goes out (%r)" % L.eval("SENT[1]"))
    check(L.eval("RELAYED[1]") == "mirror.drops", "and is offered to the other guests' copies (%r)" % L.eval("RELAYED[1]"))
    check(L.eval("CHECKPOINTS") == 1, "and still checkpoints the trade (%d)" % L.eval("CHECKPOINTS"))


DROPS_PAIR_FAKES = FAKES + r"""
    package.loaded["mirror.game"] = { player = function() return nil end, world = function() return nil end,
                                      on_world_reset = function() end }
    package.loaded["mirror.bedtags"] = { gone = function() end, tick = function() end, init = function() end }
    SENT, INBOX = {}, {}
    package.loaded["mirror.events"] = evmock { new = function(name) return {
        send = function(self, m) SENT[#SENT + 1] = name .. ":" .. m end,
        pump = function(self, fn) local q = INBOX[name] or {}; INBOX[name] = {}; for _, p in ipairs(q) do fn(p) end end } end,
        send = function(self, m) SENT[#SENT + 1] = "drops:" .. m end }
    package.loaded["mirror.peers"] = { relaying = function() return false end, my_slot = function() return 0 end,
        relay = function() end, each = function(name, fn) fn(require(name)) end }
    StaticFindObject = function() return obj({}) end
    util = require("mirror.util")
    util.ensure_hook = function() return true end
    util.cdo = function() return nil end
    util.class_name = function(a) return a.cls end
    WORLD = {}
    FindAllOf = function() return WORLD end
    function pickup(x, name)
        local asset = obj({ GetFullName = function() return "DA /Game/Items/" .. name .. "." .. name end })
        local a
        a = obj({ cls = "BP_Pickup_C", K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end,
                  IsActorBeingDestroyed = function() return a.gone == true end, GetAttachParentActor = function() return a.parent end,
                  K2_DestroyActor = function() a.gone = true end })
        local comp = obj({ ItemDataAsset = asset, GetOwner = function() return a end, MainJigContainers = { ForEach = function() end } })
        a.GetComponentByClass = function() return comp end
        WORLD[#WORLD + 1] = a
        return a
    end
    drops = require("mirror.drops")
"""


def drops_rejoin_pairs_the_saved_pickups():
    # T10 audit 2026-10-31: after a join or rejoin the guest's dropped items are plain saved pickups and a guest at
    # home forgets which were drops; the host still tracked them. The guest's pickup went out as a world item (W) the
    # host skipped, the host's as a uid the guest didn't know: both kept the item. The host now tells the joining
    # guest its drops (P) and the guest pairs them with the saved pickups.
    print("drops_rejoin_pairs_the_saved_pickups")
    H = lua()
    H.execute(DROPS_PAIR_FAKES + r"""
        drops.init({ mirror_drops = true }, "host", { in_world = function() return true end, checkpoint = function() end })
        RIFLE, AMMO = pickup(100, "DA_Rifle"), pickup(140, "DA_Ammo")
        -- (tracked the way a guest's pairing does it: the host's own tracking of these is not what is tested)
        INBOX.drops = { "P U1 BP_Pickup_C 100.0 0.0 0.0 " .. "/Game/Items/DA_Rifle.DA_Rifle",
                        "P U2 BP_Pickup_C 140.0 0.0 0.0 " .. "/Game/Items/DA_Ammo.DA_Ammo" }
        drops.tick(0.6)
        SENT = {}
        if drops.join_started then drops.join_started() end
    """)
    lines = sorted(m[len("drops:"):] for m in H.eval("SENT").values())
    want = ["P U1 BP_Pickup_C 100.0 0.0 0.0 /Game/Items/DA_Rifle.DA_Rifle", "P U2 BP_Pickup_C 140.0 0.0 0.0 /Game/Items/DA_Ammo.DA_Ammo"]
    check(lines == want, "host: a join's save start sends its 2 tracked drops (%r)" % lines)
    lines = want
    G = lua()
    G.execute(DROPS_PAIR_FAKES + r"""
        drops.init({ mirror_drops = true }, "guest", { in_world = function() return true end, checkpoint = function() end })
        -- the join save's pickups: the two drops, and a level-placed rifle 2 m off
        R, A, OTHER = pickup(101, "DA_Rifle"), pickup(139, "DA_Ammo"), pickup(300, "DA_Rifle")
        INBOX.drops = LINES
    """.replace("LINES", "{ " + ", ".join('"%s"' % l for l in lines) + " }"))
    G.execute("drops.tick(0.6)")
    G.execute('SENT = {}; INBOX.drops = { "T U1 0" }; drops.tick(0.1)')
    check(G.eval("R.gone") is True and not G.eval("OTHER.gone"),
          "guest: the host's pickup of its drop removes the saved rifle here, not the other one")
    G.execute("A.parent = obj({}); drops.tick(0.6)")   # picked up: in the player's hands
    sent = [m for m in G.eval("SENT").values()]
    check(any(m.startswith("drops:T U2 ") for m in sent) and not any(m.startswith("drops:W ") for m in sent),
          "guest: its pickup of the saved ammo goes out as the host's drop U2 (%r)" % sent)


def drops_pile_pickups_take_only_their_own_item():
    # T10 audit 2026-10-31: three cans lying in a pile. The guest picks up one, the host the one next to it within
    # 15 s: the host's W matched the guest's own pickup as a same-moment race, so the guest took its can back out AND
    # removed the host's here - two cans became one. A real race (both took the same can) removed the neighbour too.
    print("drops_pile_pickups_take_only_their_own_item")
    def side(role, slot, xs, pick_x, w_x, w_slot):
        G = lua()
        G.execute(DROPS_PAIR_FAKES.replace('drops = require("mirror.drops")', "") + r"""
            PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end })
            PLAYER.BP_JigMultiplayer = obj({})
            package.loaded["mirror.game"].player = function() return PLAYER end
            package.loaded["mirror.peers"].my_slot = function() return @MYSLOT end
            TAKEN = {}
            require("mirror.jig")
            package.loaded["mirror.jig"].contents_of = function(c)
                if c == PLAYER.BP_JigMultiplayer then return { { uid = "I1", da = "/Game/Items/DA_Can.DA_Can", count = 1 } } end
                return {}
            end
            package.loaded["mirror.jig"].take = function(c, uid, n) TAKEN[#TAKEN + 1] = uid; return true end
            HOOKS = {}
            util.ensure_hook = function(path, fn) HOOKS[path:match(":(.+)$")] = fn; return true end
            drops = require("mirror.drops")
            drops.init({ mirror_drops = true }, @ROLE, { in_world = function() return true end, checkpoint = function() end })
            drops.tick(0.6)
            CANS = {}
            for i, x in ipairs(@XS) do CANS[i] = pickup(x, "DA_Can") end
            C1, C2, C3 = CANS[1], CANS[2], CANS[3]
            for _, c in ipairs(CANS) do if c.K2_GetActorLocation().X == @PICK_X then MINE = c end end
            HOOKS["JigMP_OnPickupEquipped"]({ get = function() return PLAYER end }, { get = function() return MINE end }, nil, { get = function() return "I1" end })
            MINE.parent = obj({})
            W = nil
            for _, m in ipairs(SENT) do W = W or m:match("^drops:(W .*)$") end
            INBOX.drops = { "W BP_Pickup_C " .. @W_X .. ".0 0.0 0.0 /Game/Items/DA_Can.DA_Can " .. @W_SLOT }
            drops.tick(0.1)
            HELD = 1 - #TAKEN
            LYING = 0
            for _, c in ipairs(CANS) do if c ~= MINE and not c.gone then LYING = LYING + 1 end end
        """.replace("@ROLE", '"%s"' % role).replace("@MYSLOT", str(slot)).replace("@XS", "{ %s }" % ", ".join(map(str, xs)))
           .replace("@PICK_X", str(pick_x)).replace("@W_X", str(w_x)).replace("@W_SLOT", str(w_slot)))
        return G
    def guest(pick_x):   # the host (slot 0) picked up the can at 130
        return side("guest", 1, (100, 130, 160), pick_x, 130, 0)
    G = guest(100)
    check((G.eval("W") or "").startswith("W BP_Pickup_C 100.0"), "guest: its pickup goes out as a world item (%r)" % G.eval("W"))
    check(G.eval("#TAKEN") == 0, "neighbour picked up by the host: the guest keeps its own can (%d taken back)" % G.eval("#TAKEN"))
    check(G.eval("C2.gone") is True and not G.eval("C3.gone"), "and the host's can is removed here, not the third one")
    G = guest(130)
    check(G.eval("#TAKEN") == 1, "both took the same can: the guest (higher slot) gives it back (%d)" % G.eval("#TAKEN"))
    check(not G.eval("C1.gone") and not G.eval("C3.gone"), "and no neighbouring can is removed")
    # Sentinel R4: cans 5 cm apart, the host's world has them 20 cm off. Both take the same can; each game decided
    # from its own lying cans and the two came out different (host: race, guest: neighbour) - a can more than there was.
    # In each world the cans held by both players plus those lying there must still be 3.
    H = side("host", 0, (120, 125, 130), 120, 100, 1)
    G = side("guest", 1, (100, 105, 110), 100, 120, 0)
    held = H.eval("HELD") + G.eval("HELD")
    check(held + H.eval("LYING") == 3 and held + G.eval("LYING") == 3,
          "worlds 20 cm apart, both took the same can: still 3 cans in each world (held %d, lying host %d, guest %d)"
          % (held, H.eval("LYING"), G.eval("LYING")))
    # the other way: neighbours 10 cm apart in the same spots, the guest took one, the host the next (a race to both)
    H = side("host", 0, (100, 110, 120), 110, 100, 1)
    G = side("guest", 1, (100, 110, 120), 100, 110, 0)
    held = H.eval("HELD") + G.eval("HELD")
    check(held + H.eval("LYING") == 3 and held + G.eval("LYING") == 3,
          "neighbours 10 cm apart taken at once: still 3 cans in each world (held %d, lying host %d, guest %d)"
          % (held, H.eval("LYING"), G.eval("LYING")))


def horde_rewards_reach_the_other_game():
    print("horde_rewards_reach_the_other_game")
    L = lua()
    L.execute(FAKES + r"""
        PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end })
        package.loaded["mirror.game"] = { player = function() return PLAYER end, world = function() return nil end,
                                          on_world_reset = function() end }
        package.loaded["mirror.bedtags"] = { gone = function() end, tick = function() end, init = function() end }
        SENT = {}
        package.loaded["mirror.events"] = evmock { new = function(name) return {
            send = function(self, m) SENT[#SENT + 1] = name .. ":" .. m end,
            pump = function() end } end,
            send = function(self, m) SENT[#SENT + 1] = "drops:" .. m end }
        StaticFindObject = function() return obj({}) end
        util = require("mirror.util")
        HOOKS = {}
        util.ensure_hook = function(path, fn) HOOKS[path:match("([%w_]+:[%w_ ]+)$")] = fn; return true end
        util.cdo = function() return nil end
        I = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
        function pickup(x, name)
            local asset = obj({ GetFullName = function() return "DA /Game/Items/" .. name .. "." .. name end })
            local info = { [I] = { ItemID_28_01CA27D84AF7D1014D9E2E83894C1848 = asset, Count_8_DD79AF2A46126A338C8DCCB4616D91CD = 3,
                Durability_22_A3557C454274D193D47AB9B71FB0C0CA = { X = 1, Y = 1 }, ItemVec_13_4DB12E4E4F80730BD25ACFA6FA51AD0A = { X = 1, Y = 1 } },
                UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = { A = 0, B = 0, C = 0, D = 0 } }
            local a = obj({ K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end,
                            K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
                            IsActorBeingDestroyed = function() return false end, GetAttachParentActor = function() return nil end })
            local comp = obj({ PickupInfo = info, GetOwner = function() return a end, MainJigContainers = { ForEach = function() end } })
            a.GetComponentByClass = function() return comp end
            return a, comp
        end
        function P(v) return { get = function() return v end } end
        drops = require("mirror.drops")
        drops.init({ mirror_drops = true }, "host", nil)
        drops.tick(0.6)
        OLD, OLDC = pickup(500, "DA_Old")
        HOOKS["BP_JigPickupComponent_C:ReceiveBeginPlay"](P(OLDC))
        drops.tick(0.6)
        R1, R1C = pickup(10, "DA_Ammo")
        R2, R2C = pickup(20, "DA_Rifle")
        HOOKS["BP_JigPickupComponent_C:ReceiveBeginPlay"](P(R1C))
        HOOKS["BP_JigPickupComponent_C:ReceiveBeginPlay"](P(R2C))
        HOOKS["Buildable_HordeBeacon_C:SpawnRewards"](P(obj({})))
        drops.tick(0.3)
        EARLY = #SENT
        drops.tick(0.3)
    """)
    sent = [m for m in L.eval('SENT').values() if m.startswith("drops:D ")]
    check(L.eval('EARLY') == 0, "rewards are sent only once their info is filled in")
    check(len(sent) == 2 and any("DA_Ammo" in m for m in sent) and any("DA_Rifle" in m for m in sent)
          and not any("DA_Old" in m for m in sent), "the final-wave rewards (and only they) are sent as drops")
    uids = [m.split(" ")[1] for m in sent]
    check(len(set(uids)) == 2 and "0_0_0_0" not in uids, "each reward without a UID gets its own")
    L.execute('SENT = {}; drops.tick(0.6)')
    check(len([m for m in L.eval('SENT').values() if m.startswith("drops:D ")]) == 0, "rewards are sent once")


def loose_magazine_rounds_reach_the_picker():
    print("loose_magazine_rounds_reach_the_picker")
    L = lua()
    L.execute(FAKES + r"""
        PC = obj({})
        PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end, BP_JigMultiplayer = PC })
        COMP = obj({ PickupInfo = { ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = {},
                                    UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = { A = 7, B = 7, C = 7, D = 7 } } })
        COPY = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
                     IsActorBeingDestroyed = function() return false end, GetAttachParentActor = function() return nil end,
                     GetComponentByClass = function() return COMP end, K2_DestroyActor = function() end })
        package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end,
            world = function() return { SpawnActor = function() return COPY end } end }
        SENT, IN = {}, {}
        package.loaded["mirror.events"] = evmock { new = function(name) return {
            send = function(self, m) SENT[#SENT + 1] = m end,
            pump = function(self, fn) local q = IN; IN = {}; for _, p in ipairs(q) do fn(p) end end } end,
            send = function(self, m) SENT[#SENT + 1] = m end }
        CLIP = "/Game/Items/DA_AR45Clip.DA_AR45Clip"
        StaticFindObject = function(p)
            if p == CLIP then return obj({ PickupClass = obj({}), ["IsContainer?"] = true }) end
            return obj({})
        end
        INV, FILLED = {}, nil
        package.loaded["mirror.jig"] = {
            full_path = function() return CLIP end, guid = function() return {} end,
            uid_str = function(g) return string.format("%d_%d_%d_%d", g.A, g.B, g.C, g.D) end,
            contents_of = function(c) if c == PC then return INV end return {} end,
            apply_contents = function(c, want) return 0, 0, 0, #want end,   -- the copy has no container
            fill = function(c, uid, list) FILLED = { comp = c, uid = uid, list = list }; return #list - 1, 0 end }
        package.loaded["mirror.names"] = { set = function() end, decode = function(s) return s end, moved = function() end }
        util = require("mirror.util")
        HOOKS = {}
        util.ensure_hook = function(path, pre, post) HOOKS[path:match("([%w_]+:[%w_ ]+)$")] = { pre, post }; return true end
        util.cdo = function() return nil end
        function P(v) return { get = function() return v end } end
        drops = require("mirror.drops")
        drops.init({ mirror_drops = true }, "host", nil)
        IN = { "D 1_2_3_4 " .. CLIP .. " 1 0 0 0 0 0 0 0 0 1 2 0.2 10",
               "I 1_2_3_4 /Game/Items/DA_45ACPAmmo.DA_45ACPAmmo 25 0.000 0.000 0 0" }
        drops.tick(0.1)
        drops.tick(0.6)
        REP = COMP.RepCapacity
        INV = { { uid = "1_1_1_1", da = "/Game/Items/DA_Knife.DA_Knife" } }
        HOOKS["BP_JigComponent_C:ServerFunc_HandleRequestAddActorToContainer"][1](obj({}), P(COPY))
        INV[2] = { uid = "9_9_9_9", da = CLIP }
        HOOKS["BP_PlayerCharacter_C:JigMP_OnPickupAdded"][1](P(PLAYER), P({}), P({ A = 9, B = 9, C = 9, D = 9 }))
        HOOKS["BP_JigComponent_C:ServerFunc_HandleRequestAddActorToContainer"][2]()
        EARLY = FILLED
        drops.tick(0.4)
    """)
    check(L.eval('REP') == 25, "the copy on the ground shows the mag's 25 rounds")
    check(L.eval('EARLY') is None, "the rounds go in only after the pickup has finished")
    check(L.eval('FILLED and FILLED.uid') == "9_9_9_9" and L.eval('FILLED.comp == PC'),
          "the rounds go into the picked-up magazine in the picker's inventory")
    check(L.eval('FILLED and FILLED.list[2].da') == "/Game/Items/DA_45ACPAmmo.DA_45ACPAmmo"
          and L.eval('FILLED.list[2].count') == 25 and L.eval('FILLED.list[2].parent') == 1, "all 25 rounds, inside the mag")
    check(any(m.split(" ")[:2] == ["T", "1_2_3_4"] for m in L.eval('SENT').values()), "the other game is told it was taken (the original goes)")
    L.execute('FILLED = nil; drops.tick(1.0)')
    check(L.eval('FILLED') is None, "the rounds are put in once")
    # the same mag picked up at the same moment by a player with a lower slot: they keep it, this copy goes
    L.execute(r"""
        TAKEN = {}
        package.loaded["mirror.jig"].take = function(c, uid, n, total) TAKEN[#TAKEN + 1] = uid; return c == PC end
        package.loaded["mirror.peers"].my_slot = function() return 2 end
        IN = { "T 1_2_3_4 1" }
        drops.tick(0.1)
    """)
    check(L.eval('TAKEN[1]') == "9_9_9_9", "picked up at the same moment by a lower slot: taken back out here (%s)" % L.eval('TAKEN[1]'))
    L.execute('TAKEN = {}; IN = { "T 1_2_3_4 1" }; drops.tick(0.1)')
    check(L.eval('#TAKEN') == 0, "...only once")


def a_picked_up_items_address_can_come_back_as_a_new_drop():
    """Audit 2026-10-30: a pickup destroyed here is marked ended (it stays valid until garbage collection), and the mark
    was its address, kept for the whole world. After the collection a new pickup can get that address: the other
    player's pickup of it no longer removed it here, so the item was in both games."""
    print("a_picked_up_items_address_can_come_back_as_a_new_drop")
    L = lua()
    L.execute(FAKES + r"""
        PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end, BP_JigMultiplayer = obj({}) })
        local k = 0
        function pickup(x)
            k = k + 1
            local comp = obj({ PickupInfo = { ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = {} } })
            local a = obj({ name = "BP_Pickup_C /Game/Map.Map:PersistentLevel.BP_Pickup_C_" .. k,
                            K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end,
                            IsActorBeingDestroyed = function() return false end, GetAttachParentActor = function() return nil end,
                            GetComponentByClass = function() return comp end })
            a.GetFullName = function(self) return self.name end
            a.K2_DestroyActor = function(self) self.destroyed = (self.destroyed or 0) + 1 end
            if REUSE then local r = REUSE; a.GetAddress = function() return r end end
            return a
        end
        package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end,
            world = function() return { SpawnActor = function(_, c, l) COPY = pickup(l.X); return COPY end } end }
        IN = {}
        package.loaded["mirror.events"] = evmock { new = function(name) return {
            send = function() end, pump = function(self, fn) local q = IN; IN = {}; for _, p in ipairs(q) do fn(p) end end } end,
            send = function() end }
        KNIFE = "/Game/Items/DA_Knife.DA_Knife"
        StaticFindObject = function(p) return obj({ PickupClass = obj({}) }) end
        package.loaded["mirror.jig"] = { full_path = function() return KNIFE end, guid = function() return {} end,
            uid_str = function(g) return "0_0_0_0" end, contents_of = function() return {} end, write_stats = function() return 0 end }
        package.loaded["mirror.names"] = { set = function() end, decode = function(s) return s end, moved = function() end }
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        util.cdo = function() return nil end
        drops = require("mirror.drops")
        drops.init({ mirror_drops = true }, "host", nil)
    """)
    # an item lying here is cleaned up: destroyed and marked, still listed until garbage collection
    L.execute('OLD = pickup(500); CLEANED = drops.cleanup_remove(OLD)')
    check(L.eval('CLEANED') is True and L.eval('drops.cleanup_remove(OLD)') is False,
          "a cleaned-up item counts as gone while it is still listed")
    # collected; the other player drops a knife here and its copy gets the old item's address
    L.execute('REUSE = OLD:GetAddress(); IN = { "D 5_5_5_5 " .. KNIFE .. " 1 0 0 100 0 0 0 0 0 1 1 0.5 10" }; drops.tick(0.1)')
    check(L.eval('COPY ~= nil and COPY:GetAddress() == REUSE'), "the copy has the old item's address")
    L.execute('IN = { "T 5_5_5_5 1" }; drops.tick(0.1)')
    check(L.eval('COPY.destroyed') == 1, "the other player picks it up: the copy here is removed (%s)" % L.eval('COPY.destroyed'))


def loose_magazine_picked_up_without_hooks_still_gets_its_rounds():
    # in-game 2026-10-24: the game's pickup of a mag copy ran none of the pickup hooks - it was only seen as "gone"
    print("loose_magazine_picked_up_without_hooks_still_gets_its_rounds")
    L = lua()
    L.execute(FAKES + r"""
        PC = obj({})
        PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end, BP_JigMultiplayer = PC })
        COMP = obj({ PickupInfo = { ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = {},
                                    UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = { A = 7, B = 7, C = 7, D = 7 } } })
        GONE = false
        COPY = obj({ K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end,
                     IsActorBeingDestroyed = function() return GONE end, GetAttachParentActor = function() return nil end,
                     GetComponentByClass = function() return COMP end, K2_DestroyActor = function() end })
        package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end,
            world = function() return { SpawnActor = function() return COPY end } end }
        SENT, IN = {}, {}
        package.loaded["mirror.events"] = evmock { new = function(name) return {
            send = function(self, m) SENT[#SENT + 1] = m end,
            pump = function(self, fn) local q = IN; IN = {}; for _, p in ipairs(q) do fn(p) end end } end,
            send = function(self, m) SENT[#SENT + 1] = m end }
        CLIP = "/Game/Items/DA_AR45Clip.DA_AR45Clip"
        StaticFindObject = function(p)
            if p == CLIP then return obj({ PickupClass = obj({}), ["IsContainer?"] = true }) end
            return obj({})
        end
        -- the player already carries an empty mag of the same kind: that one must not get the rounds
        INV, FILLED = { { uid = "5_5_5_5", da = CLIP } }, nil
        package.loaded["mirror.jig"] = {
            full_path = function() return CLIP end, guid = function() return {} end,
            uid_str = function(g) return string.format("%d_%d_%d_%d", g.A, g.B, g.C, g.D) end,
            contents_of = function(c) if c == PC then return INV end return {} end,
            apply_contents = function(c, want) return 0, 0, 0, #want end,
            fill = function(c, uid, list) FILLED = { comp = c, uid = uid, list = list }; return #list - 1, 0 end }
        package.loaded["mirror.names"] = { set = function() end, decode = function(s) return s end, moved = function() end }
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        util.cdo = function() return { IsValid = function() return not GONE end } end
        drops = require("mirror.drops")
        drops.init({ mirror_drops = true }, "host", nil)
        IN = { "D 1_2_3_4 " .. CLIP .. " 1 0 0 0 0 0 0 0 0 1 2 0.2 10",
               "I 1_2_3_4 /Game/Items/DA_45ACPAmmo.DA_45ACPAmmo 25 0.000 0.000 0 0" }
        drops.tick(0.1)
        drops.tick(0.6)
        drops.tick(0.6)
        GONE = true
        INV[2] = { uid = "9_9_9_9", da = CLIP }
        drops.tick(0.6)
        drops.tick(0.4)
    """)
    check(any(m.split(" ")[:2] == ["T", "1_2_3_4"] for m in L.eval('SENT').values()), "the other game is told it was taken")
    check(L.eval('FILLED and FILLED.uid') == "9_9_9_9", "the rounds go into the new mag, not the one carried before")
    check(L.eval('FILLED and FILLED.list[2].count') == 25, "all 25 rounds")
    L.execute('FILLED = nil; drops.tick(1.0); drops.tick(1.0)')
    check(L.eval('FILLED') is None, "the rounds are put in once")


def loose_magazine_picked_up_by_both_at_once_is_kept_once():
    # T10 audit 2026-10-31: a mag copy's pickup here is only seen at the next ground check (0.5 s). The host's "T" for
    # the same mag in between forgot the copy and the check never told mine: both kept the mag.
    print("loose_magazine_picked_up_by_both_at_once_is_kept_once")
    L = lua()
    L.execute(FAKES + r"""
        PC = obj({})
        PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end, BP_JigMultiplayer = PC })
        COMP = obj({ PickupInfo = { ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = {},
                                    UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = { A = 7, B = 7, C = 7, D = 7 } } })
        GONE = false
        COPY = obj({ K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end,
                     IsActorBeingDestroyed = function() return GONE end, GetAttachParentActor = function() return nil end,
                     GetComponentByClass = function() return COMP end, K2_DestroyActor = function() end })
        package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end,
            world = function() return { SpawnActor = function() return COPY end } end }
        package.loaded["mirror.notify"] = { show = function() end }
        SENT, IN = {}, {}
        package.loaded["mirror.events"] = evmock { new = function(name) return {
            send = function(self, m) SENT[#SENT + 1] = m end,
            pump = function(self, fn) local q = IN; IN = {}; for _, p in ipairs(q) do fn(p) end end } end,
            send = function(self, m) SENT[#SENT + 1] = m end }
        CLIP = "/Game/Items/DA_AR45Clip.DA_AR45Clip"
        StaticFindObject = function(p)
            if p == CLIP then return obj({ PickupClass = obj({}), ["IsContainer?"] = true }) end
            return obj({})
        end
        INV, TAKEN = { { uid = "5_5_5_5", da = CLIP } }, {}
        package.loaded["mirror.jig"] = {
            full_path = function() return CLIP end, guid = function() return {} end,
            uid_str = function(g) return string.format("%d_%d_%d_%d", g.A, g.B, g.C, g.D) end,
            contents_of = function(c) if c == PC then return INV end return {} end,
            apply_contents = function(c, want) return 0, 0, 0, #want end,
            fill = function(c, uid, list) return #list - 1, 0 end,
            take = function(c, uid, n) TAKEN[#TAKEN + 1] = uid; return true end }
        package.loaded["mirror.names"] = { set = function() end, decode = function(s) return s end, moved = function() end }
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        util.cdo = function() return { IsValid = function() return not GONE end } end
        drops = require("mirror.drops")
        drops.init({ mirror_drops = true }, "guest", { in_world = function() return true end, checkpoint = function() end })
        package.loaded["mirror.peers"].my_slot = function() return 1 end
        IN = { "D 1_2_3_4 " .. CLIP .. " 1 0 0 0 0 0 0 0 0 1 2 0.2 10",
               "I 1_2_3_4 /Game/Items/DA_45ACPAmmo.DA_45ACPAmmo 25 0.000 0.000 0 0" }
        drops.tick(0.1)
        drops.tick(0.6)
        drops.tick(0.6)
        -- I pick it up; the host (slot 0) picked it up too, its T lands before my next ground check
        GONE = true
        INV[2] = { uid = "9_9_9_9", da = CLIP }
        SENT = {}
        IN = { "T 1_2_3_4 0" }
        drops.tick(0.05)
    """)
    sent = list(L.eval('SENT').values())
    check("T 1_2_3_4 1" in sent, "my pickup is told after all, so the host settles it too (%r)" % sent)
    check(L.eval('TAKEN[1]') == "9_9_9_9", "the higher slot gives back the mag it just picked up, not the one it carried (%s)"
          % L.eval('TAKEN[1]'))
    L.execute('SENT = {}; TAKEN = {}; for i = 1, 4 do drops.tick(0.6) end')
    check(L.eval('#TAKEN') == 0 and not any(m.startswith("T 1_2_3_4") for m in L.eval('SENT').values()),
          "...once: the forgotten copy isn't told again")


def ground_weapon_attachments_reach_the_other_game():
    print("ground_weapon_attachments_reach_the_other_game")
    L = lua()
    L.execute(FAKES + r"""
        PC = obj({})
        PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end, BP_JigMultiplayer = PC })
        COMP = obj({ PickupInfo = { ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = {},
                                    UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = { A = 7, B = 7, C = 7, D = 7 } } })
        COPY = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
                     IsActorBeingDestroyed = function() return false end, GetAttachParentActor = function() return nil end,
                     GetComponentByClass = function() return COMP end, K2_DestroyActor = function() end })
        COMP.GetOwner = function() return COPY end
        PC.GetOwner = function() return PLAYER end
        package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end,
            world = function() return { SpawnActor = function() return COPY end } end }
        SENT, IN = {}, {}
        package.loaded["mirror.events"] = evmock { new = function(name) return {
            send = function(self, m) SENT[#SENT + 1] = m end,
            pump = function(self, fn) local q = IN; IN = {}; for _, p in ipairs(q) do fn(p) end end } end,
            send = function(self, m) SENT[#SENT + 1] = m end }
        RIFLE = "/Game/Items/DA_Rifle.DA_Rifle"
        StaticFindObject = function(p)
            if p == RIFLE then return obj({ PickupClass = obj({}), ["IsContainer?"] = false }) end
            return obj({})
        end
        HAVE, APPLIED = {}, nil
        package.loaded["mirror.jig"] = {
            full_path = function() return RIFLE end, guid = function() return {} end,
            uid_str = function(g) return string.format("%d_%d_%d_%d", g.A, g.B, g.C, g.D) end,
            write_stats = function() return 0 end,
            contents_of = function(c) if c == COMP then return HAVE end return {} end,
            encode = function(list) local t = {}; for _, h in ipairs(list) do t[#t + 1] = h.da end; return table.concat(t, ";") end,
            decode = function(s) local t = {}; for d in s:gmatch("[^;]+") do t[#t + 1] = { da = d } end; return t end,
            apply_contents = function(c, want) APPLIED = { comp = c, want = want }; return 0, #want, 0, 0 end }
        package.loaded["mirror.names"] = { set = function() end, get = function() end, decode = function(s) return s end,
                                           moved = function() end }
        util = require("mirror.util")
        HOOKS = {}
        util.ensure_hook = function(path, pre, post) HOOKS[path:match("([%w_]+:[%w_ ]+)$")] = { pre, post }; return true end
        util.cdo = function() return nil end
        function P(v) return { get = function() return v end } end
        function MOVE(from, to) HOOKS["BP_JigComponent_C:Handle Comp to Comp Move"][1](P(PC), P(from), P(to), P({ A = 1, B = 1, C = 1, D = 1 }),
            P({}), P(0), P({ A = 0, B = 0, C = 0, D = 0 })) end
        drops = require("mirror.drops")
        drops.init({ mirror_drops = true }, "host", nil)
        IN = { "D 1_2_3_4 " .. RIFLE .. " 1 0 0 0 0 0 0 0 0 4 2 3 100" }
        drops.tick(0.6)
        SENT = {}
        HAVE = { { uid = "5_5_5_5", da = "/Game/Items/DA_Scope.DA_Scope", parent = nil } }
        MOVE(PC, COMP)
        EARLY = #SENT
        drops.tick(0.4)
        FIRST = SENT
        SENT = {}
        MOVE(PC, COMP)
        drops.tick(0.4)
        SAME = #SENT
        HAVE = {}
        MOVE(COMP, PC)
        drops.tick(0.4)
        TAKEN = SENT
        SENT = {}
        MOVE(PC, obj({ GetOwner = function() return obj({}) end }))
        drops.tick(0.4)
        OTHER = #SENT
        IN = { "C 1_2_3_4 - /Game/Items/DA_Scope.DA_Scope;/Game/Items/DA_Grip.DA_Grip" }
        drops.tick(0.1)
        drops.tick(0.4)
        drops.tick(0.6)
        ECHO = #SENT
        -- in the real game the move hook never fires: the change is still found by looking
        SENT = {}
        HAVE = { { uid = "6_6_6_6", da = "/Game/Items/DA_Laser.DA_Laser" } }
        drops.tick(0.6)
        drops.tick(0.6)
        POLLED = SENT
        SENT = {}
        drops.tick(0.6)
        drops.tick(0.6)
        POLLED_AGAIN = #SENT
        COPY.K2_GetActorLocation = function() return { X = 1000, Y = 0, Z = 0 } end
        HAVE = {}
        drops.tick(0.6)
        drops.tick(0.6)
        FAR = #SENT
        -- a fresh copy spawns with the item's default parts; the other game's real parts land 0.5 s later
        -- (seen in-game: the guest sent the host's own parts back) - that landing isn't a change made here
        CRIFLE = "/Game/Items/DA_CRifle.DA_CRifle"
        StaticFindObject = function(p)
            if p == CRIFLE then return obj({ PickupClass = obj({}), ["IsContainer?"] = true }) end
            return obj({})
        end
        package.loaded["mirror.jig"].apply_contents = function(c, want) HAVE = want; return 0, #want, 0, 0 end
        COPY.K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end
        HAVE = { { uid = "8_8_8_8", da = "/Game/Items/DA_DefaultMag.DA_DefaultMag" } }
        IN = { "D 9_9_9_9 " .. CRIFLE .. " 1 0 0 0 0 0 0 0 0 4 2 3 100",
               "I 9_9_9_9 /Game/Items/DA_Scope.DA_Scope 1 0 0" }
        drops.tick(0.1)
        SENT = {}
        -- the 0.5 s check looks at the copy before its parts land (frame ticks, as in the game)
        drops.tick(0.45)
        LOOKED_EARLY = #HAVE == 1 and HAVE[1].uid == "8_8_8_8"
        drops.tick(0.6)
        drops.tick(0.6)
        drops.tick(0.6)
        LANDED = {}
        for _, m in ipairs(SENT) do if m:find("^C 9_9_9_9") then LANDED[#LANDED + 1] = m end end
        LANDED_N, LANDED_HAVE = #LANDED, #HAVE
    """)
    first = list(L.eval('FIRST').values())
    check(L.eval('EARLY') == 0, "the change is sent once the move has settled")
    check(first == ["C 1_2_3_4 * /Game/Items/DA_Scope.DA_Scope"],
          "an attachment put on a dropped weapon is sent with its uid; no list known before: '*', taken whole (%r)" % first)
    check(L.eval('SAME') == 0, "an unchanged weapon isn't sent again")
    check(list(L.eval('TAKEN').values()) == ["C 1_2_3_4 /Game/Items/DA_Scope.DA_Scope -"], "taking the attachment off is sent too")
    check(L.eval('OTHER') == 0, "moves between untracked containers send nothing")
    check(L.eval('APPLIED and APPLIED.comp == COMP') and L.eval('#APPLIED.want') == 2,
          "the other game's change goes onto this game's copy")
    check(L.eval('ECHO') == 0, "applying the other game's change isn't echoed back")
    check(list(L.eval('POLLED').values()) == ["C 1_2_3_4 - /Game/Items/DA_Laser.DA_Laser"],
          "a part put on without any hook is found by looking and sent")
    check(L.eval('POLLED_AGAIN') == 0, "and sent once")
    check(L.eval('FAR') == 0, "an item 10 m away isn't looked at")
    check(L.eval('LOOKED_EARLY') == True, "(the check saw the copy's default parts first)")
    check(L.eval('LANDED_HAVE') == 1, "the copy got the other game's parts")
    check(L.eval('LANDED_N') == 0, "the other game's parts landing on a fresh copy aren't sent back")


def ground_weapon_parts_changed_by_both_at_once_keep_both_changes():
    # T10 item-sync audit 2026-10-31: a parts change on a dropped weapon went over as its whole parts list. The host
    # takes the scope off while the guest takes the mag off: each list put back the part the other had just taken
    # (the host kept a scope in its bag and one on the weapon). Each game must end with both changes and stay quiet.
    print("ground_weapon_parts_changed_by_both_at_once_keep_both_changes")
    def side(role):
        S = lua()
        S.execute(FAKES + r"""
            PC = obj({})
            PLAYER = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end, BP_JigMultiplayer = PC })
            COMP = obj({ PickupInfo = { ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = {},
                                        UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = { A = 7, B = 7, C = 7, D = 7 } } })
            COPY = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
                         IsActorBeingDestroyed = function() return false end, GetAttachParentActor = function() return nil end,
                         GetComponentByClass = function() return COMP end, K2_DestroyActor = function() end })
            COMP.GetOwner = function() return COPY end
            PC.GetOwner = function() return PLAYER end
            package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end,
                world = function() return { SpawnActor = function() return COPY end } end }
            SENT, IN = {}, {}
            package.loaded["mirror.events"] = evmock { new = function(name) return {
                send = function(self, m) SENT[#SENT + 1] = m end,
                pump = function(self, fn) local q = IN; IN = {}; for _, p in ipairs(q) do fn(p) end end } end,
                send = function(self, m) SENT[#SENT + 1] = m end }
            RIFLE = "/Game/Items/DA_Rifle.DA_Rifle"
            StaticFindObject = function(p)
                if p == RIFLE then return obj({ PickupClass = obj({}), ["IsContainer?"] = false }) end
                return obj({})
            end
            package.loaded["mirror.names"] = { set = function() end, get = function() end, decode = function(s) return s end,
                                               encode = function(s) return s end, moved = function() end }
            local real = require("mirror.jig")
            package.loaded["mirror.jig"] = {
                full_path = function() return RIFLE end, guid = function() return {} end,
                uid_str = function(g) return string.format("%d_%d_%d_%d", g.A, g.B, g.C, g.D) end,
                write_stats = function() return 0 end,
                contents_of = function(c) if c == COMP then return HAVE end return {} end,
                encode = real.encode, decode = real.decode,
                apply_contents = function(c, want)
                    HAVE = {}
                    for i, w in ipairs(want) do
                        HAVE[i] = { da = w.da, count = w.count, dx = w.dx, dy = w.dy, parent = w.parent, slot = w.slot }
                    end
                    return #want, 0, 0, 0
                end }
            util = require("mirror.util")
            util.ensure_hook = function() return true end
            util.cdo = function() return nil end
            drops = require("mirror.drops")
            drops.init({ mirror_drops = true }, "@ROLE", { in_world = function() return true end, checkpoint = function() end })
            function PART(name, slot, count) return { da = "/Game/Items/DA_" .. name .. ".DA_" .. name, count = count, parent = 1, slot = slot } end
            HAVE = { { da = RIFLE }, PART("Scope", 1), PART("Mag", 2, 30) }
            IN = { "D 1_2_3_4 " .. RIFLE .. " 1 0 0 0 0 0 0 0 0 4 2 3 100" }
            drops.tick(0.6)
            drops.tick(0.6)
            SENT = {}
            function OFF(name) for i = #HAVE, 1, -1 do if HAVE[i].da:find("DA_" .. name, 1, true) then table.remove(HAVE, i) end end end
            function KINDS()
                local t = {}
                for _, h in ipairs(HAVE) do t[#t + 1] = h.da:match("DA_(%w+)$") .. ((h.count or 1) ~= 1 and ("x" .. h.count) or "") end
                table.sort(t)
                return table.concat(t, ",")
            end
        """.replace("@ROLE", role))
        return S
    def settle(H, G):
        for S in (H, G):
            S.execute("drops.tick(0.6); drops.tick(0.6)")
        rounds = 0
        while rounds < 6:
            h, g = list(H.eval("SENT").values()), list(G.eval("SENT").values())
            if not h and not g:
                return rounds
            rounds += 1
            for S, inbox in ((H, g), (G, h)):
                S.execute("SENT = {}; IN = { %s }; drops.tick(0.6); drops.tick(0.6)"
                          % ", ".join("[==[%s]==]" % m for m in inbox))
        return rounds
    H, G = side("host"), side("guest")
    check(H.eval("KINDS()") == "Magx30,Rifle,Scope" and H.eval("#SENT") == 0, "(both games start with a rifle, scope and mag)")
    H.execute('OFF("Scope")')
    G.execute('OFF("Mag")')
    rounds = settle(H, G)
    check(H.eval("KINDS()") == "Rifle" and G.eval("KINDS()") == "Rifle",
          "scope off on the host, mag off on the guest at once: both are off in both games (host %s, guest %s)"
          % (H.eval("KINDS()"), G.eval("KINDS()")))
    check(rounds < 6, "and the games go quiet (%d exchanges)" % rounds)
    H, G = side("host"), side("guest")
    H.execute('OFF("Scope")')
    G.execute('OFF("Scope")')
    rounds = settle(H, G)
    check(H.eval("KINDS()") == "Magx30,Rifle" and G.eval("KINDS()") == "Magx30,Rifle" and rounds < 6,
          "both take the scope off at once: it stays off, nothing else changes (host %s, guest %s, %d exchanges)"
          % (H.eval("KINDS()"), G.eval("KINDS()"), rounds))
    H, G = side("host"), side("guest")
    H.execute('HAVE[#HAVE + 1] = PART("Grip", 3)')
    G.execute('OFF("Mag")')
    rounds = settle(H, G)
    check(H.eval("KINDS()") == "Grip,Rifle,Scope" and G.eval("KINDS()") == "Grip,Rifle,Scope" and rounds < 6,
          "a grip put on here while the mag comes off there: both kept (host %s, guest %s, %d exchanges)"
          % (H.eval("KINDS()"), G.eval("KINDS()"), rounds))
    H, G = side("host"), side("guest")
    G.execute("HAVE[3].count = 12")
    rounds = settle(H, G)
    check(H.eval("KINDS()") == "Magx12,Rifle,Scope" and rounds < 6,
          "a lone change still goes over whole (host %s, %d exchanges)" % (H.eval("KINDS()"), rounds))
    # Sentinel R5: both games answered a same-moment change with their merge; the answers crossed and each applied
    # the other's count change a second time (30 -> 12 beside a scope taken off: the mag went on both sides)
    def both(host_do, guest_do, want, what):
        H, G = side("host"), side("guest")
        H.execute(host_do)
        G.execute(guest_do)
        rounds = settle(H, G)
        check(H.eval("KINDS()") == want and G.eval("KINDS()") == want and rounds < 6,
              "%s: %s on both (host %s, guest %s, %d exchanges)" % (what, want, H.eval("KINDS()"), G.eval("KINDS()"), rounds))
    both("HAVE[3].count = 12", 'OFF("Scope")', "Magx12,Rifle", "rounds taken out of the mag here, the scope off there")
    both("HAVE[3].count = 20", 'HAVE[#HAVE + 1] = PART("Grip", 3)', "Grip,Magx20,Rifle,Scope",
         "rounds taken out here, a grip put on there")
    both("HAVE[3].count = 20", "HAVE[3].count = 25", "Magx15,Rifle,Scope", "10 rounds taken here, 5 there")
    # a change here the 0.5 s check hasn't seen yet when theirs lands: it goes over on top of theirs
    def unsent(host_do, guest_do, want, what):
        H, G = side("host"), side("guest")
        G.execute(guest_do + "; drops.tick(0.6); drops.tick(0.6)")
        g = list(G.eval("SENT").values())
        G.execute("SENT = {}")
        H.execute("%s; IN = { %s }; drops.tick(0.1)" % (host_do, ", ".join("[==[%s]==]" % m for m in g)))
        rounds = settle(H, G)
        check(H.eval("KINDS()") == want and G.eval("KINDS()") == want and rounds < 6,
              "%s: %s on both (host %s, guest %s, %d exchanges)" % (what, want, H.eval("KINDS()"), G.eval("KINDS()"), rounds))
    unsent('OFF("Scope")', 'OFF("Mag")', "Rifle", "scope off here not sent yet when the mag-off lands")
    unsent("HAVE[3].count = 12", 'OFF("Scope")', "Magx12,Rifle", "rounds taken out here not sent yet when the scope-off lands")


def ghost_gun_in_hand_is_known():
    print("ghost_gun_in_hand_is_known")
    L = lua()
    L.execute(FAKES + r"""
        StaticFindObject = function() return obj({}) end
        G = obj({ Mesh = obj({}), AddComponentByClass = function() return obj({}) end })
        look = require("mirror.look")
        local A = function(id, parent, sock) return table.concat({ "A", id, parent, "S", sock, "-", "", "0,0,0", "0,0,0", "1,1,1", 0 }, "\t") end
        look.apply(G, table.concat({ A(1, 0, "PrimaryWeaponBackpack"), A(2, 1, "None"), A(3, 0, "Rifle_Hand"), A(4, 3, "None") }, "\n"))
        R = { look.in_hand(1), look.in_hand(2), look.in_hand(3), look.in_hand(4) }
        look.forget()
        GONE = look.in_hand(3)
    """)
    r = list(L.eval('R').values())
    check(r == [False, False, True, True], "pieces under a hand socket are the held gun, the holstered one isn't")
    check(L.eval('GONE') is False, "forgetting the gear forgets the hand pieces")


def ghost_wears_its_players_face_beard_and_tattoos():
    # User 2026-10-31: "character beards and facial stuff tattoos etc sync those if not already". The character
    # creator (CharacterCreatorMenu / BP_PlayerCharacter SetSexMesh, build 26303910) keeps every choice as an asset on
    # a named part: BeardMesh/HairMesh/EyebrowsMesh/Mouth static meshes, tattoos, scars, freckles and war paint as
    # Accessory1-3 static meshes, skin and hair colour as material instances. The ghost starts with OUR save's look
    # (its construction script runs SetSexMesh from this PC's save): the other player's parts must replace all of it.
    print("ghost_wears_its_players_face_beard_and_tattoos")
    L = lua()
    L.execute(FAKES + r"""
        ASSETS = {}
        function asset(p, c) local o = obj({ GetFullName = function() return (c or "StaticMesh") .. " " .. p end }); ASSETS[p] = o; return o end
        StaticFindObject = function(p) return ASSETS[p] end
        local P = "/Game/PlayerModel/"
        for _, p in ipairs({ "Hair/Beard/Chr_Beard2.Chr_Beard2", "Hair/Beard/Chr_Moustache1.Chr_Moustache1",
                             "Hair/HairMesh/Chr_MaleHair3.Chr_MaleHair3", "Hair/Eyebrows/Chr_Eyebrows2.Chr_Eyebrows2",
                             "BodyParts/Head/Features/Male/Male_Tattoo2.Male_Tattoo2", "BodyParts/Head/Features/Male/Male_Scar1.Male_Scar1",
                             "BodyParts/Head/Features/Male/Male_Freckles.Male_Freckles", "BodyParts/Head/Features/Male/Male_Mouth2.Male_Mouth2" }) do
            asset(P .. p)
        end
        asset(P .. "BodyParts/Male/SK_Chr_Male_Head.SK_Chr_Male_Head", "SkeletalMesh")
        for _, p in ipairs({ "Hair/Material/Other/MI_CharacterHair_Ginger.MI_CharacterHair_Ginger",
                             "Hair/Material/Brown/MI_CharacterHair_Brown.MI_CharacterHair_Brown" }) do asset(P .. p, "MaterialInstanceConstant") end
        for _, n in ipairs({ "1A", "1C" }) do asset("/Game/Character/M_Chr_Texture_" .. n .. ".M_Chr_Texture_" .. n, "MaterialInstanceConstant") end
        function A(p) return ASSETS[p:find("^/Game/Character") and p or (P .. p)] end
        function sm(mesh, mat) return obj({ StaticMesh = mesh, mats = { mat }, vis = true,
            GetNumMaterials = function(self) return self.StaticMesh and #self.mats or 0 end,
            GetMaterial = function(self, i) return self.mats[i + 1] end, IsVisible = function(self) return self.vis end,
            SetStaticMesh = function(self, m) self.StaticMesh = m end, SetMaterial = function(self, i, m) self.mats[i + 1] = m end,
            SetVisibility = function(self, v) self.vis = v end, SetCastShadow = function() end }) end
        function sk(mesh, mat) local c = sm(nil, mat); c.SK = mesh
            c.GetSkinnedAsset = function(self) return self.SK end
            c.SetSkinnedAssetAndUpdate = function(self, m) self.SK = m end
            c.GetNumMaterials = function(self) return #self.mats end
            return c end
        local skin = function(n) return A("/Game/Character/M_Chr_Texture_" .. n .. ".M_Chr_Texture_" .. n) end
        local ginger, brown = A("Hair/Material/Other/MI_CharacterHair_Ginger.MI_CharacterHair_Ginger"), A("Hair/Material/Brown/MI_CharacterHair_Brown.MI_CharacterHair_Brown")
        local head = A("BodyParts/Male/SK_Chr_Male_Head.SK_Chr_Male_Head")
        PEER = obj({ Head = sk(head, skin("1C")), Torso = sk(nil, skin("1C")),
                     BeardMesh = sm(A("Hair/Beard/Chr_Beard2.Chr_Beard2"), ginger), HairMesh = sm(nil, ginger),
                     EyebrowsMesh = sm(A("Hair/Eyebrows/Chr_Eyebrows2.Chr_Eyebrows2"), ginger),
                     Mouth = sm(A("BodyParts/Head/Features/Male/Male_Mouth2.Male_Mouth2")),
                     Accessory1 = sm(A("BodyParts/Head/Features/Male/Male_Tattoo2.Male_Tattoo2")),
                     Accessory2 = sm(nil), Accessory3 = sm(A("BodyParts/Head/Features/Male/Male_Scar1.Male_Scar1")) })
        G = obj({ Head = sk(head, skin("1A")), Torso = sk(nil, skin("1A")),
                  BeardMesh = sm(A("Hair/Beard/Chr_Moustache1.Chr_Moustache1"), brown),
                  HairMesh = sm(A("Hair/HairMesh/Chr_MaleHair3.Chr_MaleHair3"), brown), EyebrowsMesh = sm(nil, brown),
                  Mouth = sm(nil), Accessory1 = sm(nil), Accessory2 = sm(A("BodyParts/Head/Features/Male/Male_Freckles.Male_Freckles")),
                  Accessory3 = sm(nil), Mesh = obj({ SetCastShadow = function() end }) })
        look = require("mirror.look")
        BLOB = look.capture(PEER)
        look.apply(G, BLOB)
        function name(o) return o and o:GetFullName():match("[^%.]+$") or "none" end
    """)
    got = lambda e: L.eval('name(%s)' % e)
    check(got('G.BeardMesh.StaticMesh') == "Chr_Beard2" and got('G.BeardMesh.mats[1]') == "MI_CharacterHair_Ginger",
          "the ghost's beard is its player's, in their colour (%s, %s)" % (got('G.BeardMesh.StaticMesh'), got('G.BeardMesh.mats[1]')))
    check(got('G.HairMesh.StaticMesh') == "none", "a bald player's ghost loses our save's hair (%s)" % got('G.HairMesh.StaticMesh'))
    check(got('G.EyebrowsMesh.StaticMesh') == "Chr_Eyebrows2" and got('G.Mouth.StaticMesh') == "Male_Mouth2", "eyebrows and mouth")
    check(got('G.Accessory1.StaticMesh') == "Male_Tattoo2", "the face tattoo (%s)" % got('G.Accessory1.StaticMesh'))
    check(got('G.Accessory2.StaticMesh') == "none", "our save's freckles come off (%s)" % got('G.Accessory2.StaticMesh'))
    check(got('G.Accessory3.StaticMesh') == "Male_Scar1", "the scar (%s)" % got('G.Accessory3.StaticMesh'))
    check(got('G.Head.mats[1]') == "M_Chr_Texture_1C" and got('G.Torso.mats[1]') == "M_Chr_Texture_1C",
          "the skin colour on head and body (%s)" % got('G.Head.mats[1]'))


def ghost_look_is_applied_over_frames():
    # a 46-line look took 153 ms in one frame at a join (live 2026-10-30 02:34:29)
    print("ghost_look_is_applied_over_frames")
    L = lua()
    L.execute(FAKES + r"""
        StaticFindObject = function() return obj({}) end
        G = obj({ Mesh = obj({}), AddComponentByClass = function() return obj({}) end })
        look = require("mirror.look")
        local A = function(id, parent, sock) return table.concat({ "A", id, parent, "S", sock, "-", "", "0,0,0", "0,0,0", "1,1,1", 0 }, "\t") end
        BLOB = table.concat({ A(1, 0, "PrimaryWeaponBackpack"), A(2, 1, "None"), A(3, 0, "Rifle_Hand"), A(4, 3, "None") }, "\n")
        local T = 0
        os.clock = function() T = T + 0.004; return T end
        R1 = look.apply(G, BLOB, 0.006); N1 = #look.components(); BUSY1 = look.applying()
        R2 = look.apply(G, BLOB, 0.006); N2 = #look.components(); BUSY2 = look.applying()
        HAND = { look.in_hand(1), look.in_hand(2), look.in_hand(3), look.in_hand(4) }
        -- a new look while one is half on starts over
        look.apply(G, BLOB, 0.006)
        R3 = look.apply(G, A(1, 0, "Rifle_Hand"), 0.006); N3 = #look.components()
        -- without a budget: all at once, as before
        look.forget()
        R4 = look.apply(G, BLOB); N4 = #look.components()
    """)
    check(L.eval('R1') is None and L.eval('N1') == 2 and L.eval('BUSY1') is True,
          "a look over budget stops part way (%s parts, %s)" % (L.eval('N1'), L.eval('R1')))
    check(L.eval('R2') == 0 and L.eval('N2') == 4 and L.eval('BUSY2') is False, "...and is finished at the next call")
    check(list(L.eval('HAND').values()) == [False, False, True, True], "...with the same pieces as in one go")
    check(L.eval('R3') == 0 and L.eval('N3') == 1, "a changed look starts over (%s parts)" % L.eval('N3'))
    check(L.eval('R4') == 0 and L.eval('N4') == 4, "no budget: the whole look in one call")


def missing_zombie_looks_get_loaded():
    print("missing_zombie_looks_get_loaded")
    import tempfile
    d = tempfile.mkdtemp()
    L = lua()
    L.execute(FAKES + r"""
        local d = ...
        os.getenv = function() return d end
        LOADED, CALLS = {}, 0
        StaticFindObject = function(p)
            if LOADED[p] then return obj({}) end
            return { IsValid = function() return false end }
        end
        LoadAsset = function(p) CALLS = CALLS + 1; LOADED[p] = true end
        NOW = 0; os.clock = function() return NOW end
        loader = require("mirror.loader")
        loader.configure({ asset_loader = true })
        loader.want("/Game/Zombies/SK_Zombie_Punk_Male_01.SK_Zombie_Punk_Male_01")
        NOW = 10; loader.tick(0.1, false)
        R1 = CALLS
        loader.want("/Game/Zombies/SK_Zombie_Punk_Male_01.SK_Zombie_Punk_Male_01")
        NOW = 20; loader.tick(0.1, false)
        R2 = CALLS
    """, d)
    check(L.eval("R1") == 1, "a missing look (NULL wrapper from StaticFindObject) is loaded")
    check(L.eval("R2") == 1, "a loaded look is not loaded again")


def random_and_debug_weather_is_shared():
    print("random_and_debug_weather_is_shared")
    def side(role):
        L = lua()
        L.execute(FAKES + r"""
            util = require("mirror.util")
            local FIELDS = { "Cloud Coverage", "Rain", "Snow", "Thunder/Lightning", "Wind Intensity", "Fog", "Dust",
                             "Material Wetness", "Material Snow Coverage", "Material Dust Coverage" }
            function settings(name, full, rain)
                local o = obj({ GetFName = function() return { ToString = function() return name end } end,
                                GetFullName = function() return full end, ["User Friendly Name"] = "" })
                for _, f in ipairs(FIELDS) do o[f] = 0 end
                o.Rain = rain or 0
                return o
            end
            MADE = {}
            StaticConstructObject = function(cls, outer, name) local o = settings("made", "UDS_Weather_Settings_C /Engine/Transient.x"); MADE[#MADE + 1] = o; return o end
            CHANGES = 0
            W = obj({ GetFullName = function() return "Ultra_Dynamic_Weather_C /Game/L.L:P.UDW" end })
            W["Random Weather Variation"] = 1
            W.Weather = settings("Clear_Skies", "UDS_Weather_Settings_C /Game/UDS/Clear_Skies.Clear_Skies")
            W["Change Weather"] = function(self, ws, t) self.Weather = ws; CHANGES = CHANGES + 1 end
            SKY = obj({ GetFullName = function() return "Ultra_Dynamic_Sky_C /Game/L.L:P.UDS" end, ["Time of Day"] = 1000,
                        ["Animate Time of Day"] = true })
            FindAllOf = function(c) if c == "Ultra_Dynamic_Sky_C" then return { SKY } elseif c == "Ultra_Dynamic_Weather_C" then return { W } end return {} end
            StaticFindObject = function(p) if p:find("^/Engine/Transient%.") then return nil end return obj({}) end
            FindFirstOf = function() return obj({}) end
            world = require("mirror.world")
            world.init({}, ROLE, { in_world = function() return true end }, function() return true end)
        """.replace("ROLE", '"' + role + '"'))
        return L
    H, G = side("host"), side("guest")
    def pass_blobs(a, b):
        for k, v in dict(a.eval('blobs_out')).items():
            b.execute('blobs_in[%r] = %r' % (k, v))
        a.execute('blobs_out = {}')
    # The host's weather turns random (a runtime settings object): its values reach the guest.
    H.execute('W.Weather = settings("UDS_Weather_Settings_C_7", "UDS_Weather_Settings_C /Engine/Transient.UDS_Weather_Settings_C_7", 0.8); world.tick(2.1)')
    pass_blobs(H, G)
    G.execute('world.tick(2.1)')
    check(G.eval('W.Weather.Rain') == 0.8 and G.eval('#MADE') == 1, "the host's random weather is copied by value")
    G.execute('world.tick(2.1)')
    check(G.eval('CHANGES') == 1, "copied once, not every tick")
    # The guest changes the weather with the debug menu: the host takes it over, no ping-pong.
    G.execute('W.Weather = settings("Snow", "UDS_Weather_Settings_C /Game/UDS/Snow.Snow"); world.tick(2.1)')
    pass_blobs(G, H)
    H.execute('Snow = settings("Snow", "UDS_Weather_Settings_C /Game/UDS/Snow.Snow"); '
              'local fa = FindAllOf; FindAllOf = function(c) if c == "UDS_Weather_Settings_C" then return { Snow } end return fa(c) end; '
              'world.tick(2.1)')
    check(H.eval('W.Weather') is not None and H.eval('W.Weather:GetFName():ToString()') == "Snow", "the guest's debug weather becomes the host's")
    pass_blobs(H, G)
    G.execute('local fa = FindAllOf; FindAllOf = function(c) if c == "UDS_Weather_Settings_C" then return { W.Weather } end return fa(c) end; '
              'for i = 1, 4 do world.tick(2.1) end')
    check(G.eval('W.Weather:GetFName():ToString()') == "Snow" and G.eval('blobs_out.sky_req') is None,
          "the guest keeps it and asks nothing more")
    check(G.eval('W["Random Weather Variation"]') == 0 and H.eval('W["Random Weather Variation"]') == 1,
          "the guest's own random weather is off while joined (the host's keeps running)")
    # The host's clock stands still (same value, so the blob isn't delivered again): the guest's stops too.
    H.execute('world.tick(2.1)'); pass_blobs(H, G)
    G.execute('for i = 1, 4 do world.tick(2.1) end')
    check(G.eval('SKY["Animate Time of Day"]') is False, "a frozen host clock stops the guest's")
    H.execute('SKY["Time of Day"] = 1010; world.tick(2.1)'); pass_blobs(H, G)
    G.execute('world.tick(2.1)')
    check(G.eval('SKY["Animate Time of Day"]') is True, "and it runs again when the host's does")
    G.execute('world.init({}, "off", { in_world = function() return true end }, function() return true end)')
    check(G.eval('W["Random Weather Variation"]') == 1, "leaving gives the guest its own random weather back")
    # What the host SEES is its live state (random weather), not the preset it names: the guest copies that.
    # (The host named a storm preset under a clear sky; the guest copied the preset -> rain + snow on one screen.)
    H2, G2 = side("host"), side("guest")
    for L in (H2, G2):
        L.execute('GWS = settings("UDS_Weather_Settings_C_12", "UDS_Weather_Settings_C /Engine/Transient.G", 0); '
                  'W["Global Weather State"] = GWS; W["Change Weather"] = function(self, ws, t) self.Weather = ws; '
                  'CHANGES = CHANGES + 1; for k, v in pairs({ "Cloud Coverage", "Rain", "Snow" }) do GWS[v] = ws[v] end end')
    H2.execute('W.Weather = settings("Rain_Thunderstorm", "UDS_Weather_Settings_C /Game/UDS/R.Rain_Thunderstorm", 9); world.tick(2.1)')
    pass_blobs(H2, G2)
    G2.execute('Storm = settings("Rain_Thunderstorm", "UDS_Weather_Settings_C /Game/UDS/R.Rain_Thunderstorm", 9); '
               'local fa = FindAllOf; FindAllOf = function(c) if c == "UDS_Weather_Settings_C" then return { Storm } end return fa(c) end; '
               'GWS.Rain = 7; world.tick(2.1)')
    check(G2.eval('GWS.Rain') == 0 and G2.eval('W.Weather:GetFName():ToString()') != "Rain_Thunderstorm",
          "the guest takes the host's live weather (clear), not the storm preset it names")
    G2.execute('world.tick(2.1); world.tick(2.1)')
    check(G2.eval('CHANGES') == 1, "matched live weather isn't set again")
    H2.execute('GWS.Rain = 6; GWS.Snow = 3; world.tick(2.1)')
    pass_blobs(H2, G2)
    G2.execute('world.tick(2.1)')
    check(G2.eval('GWS.Rain') == 0, "a sudden jump of the host's weather waits for a second look")
    G2.execute('world.tick(2.1)')
    check(G2.eval('GWS.Rain') == 6 and G2.eval('GWS.Snow') == 3, "the host's live weather changing reaches the guest")
    # the host read zeros for a moment (it stalled, live 2026-10-30): back the next look - the guest's never moves
    H2.execute('GWS.Rain = 0; GWS.Snow = 0; world.tick(2.1)'); pass_blobs(H2, G2); G2.execute('world.tick(2.1)')
    H2.execute('GWS.Rain = 6; GWS.Snow = 3; world.tick(2.1)'); pass_blobs(H2, G2); G2.execute('world.tick(2.1); world.tick(2.1)')
    check(G2.eval('GWS.Rain') == 6 and G2.eval('CHANGES') == 2, "a one-look glitch of the host's weather never reaches the guest (%s sets)" % G2.eval('CHANGES'))
    # Blood moon: each game rolled its own at sunset; the host's is shared and the guest doesn't roll while joined.
    H3, G3 = side("host"), side("guest")
    for L in (H3, G3):
        L.execute('HOOKS = {}; util.ensure_hook = function(p, fn) HOOKS[p:match(":(.+)$")] = fn; return true end; '
                  'SETS = {}; EM = obj({ GetFullName = function() return "BP_EventManager_C /Game/L.L:P.EM" end, BloodMoonChance = 25 }); '
                  'EM.SetBloodMoon = function(self, on) SETS[#SETS + 1] = on; HOOKS.SetBloodMoon(nil, { get = function() return on end }) end; '
                  'local fa = FindAllOf; FindAllOf = function(c) if c == "BP_EventManager_C" then return { EM } end return fa(c) end')
    H3.execute('world.tick(2.1)'); pass_blobs(H3, G3)
    G3.execute('world.tick(2.1)')
    check(G3.eval('EM.BloodMoonChance') == 0 and H3.eval('EM.BloodMoonChance') == 25 and G3.eval('#SETS') == 0,
          "the guest's own blood moon roll is off while joined; nothing set while both have none")
    H3.execute('EM:SetBloodMoon(true); world.tick(2.1)'); pass_blobs(H3, G3)
    G3.execute('world.tick(2.1); world.tick(2.1)')
    check(G3.eval('#SETS') == 1 and G3.eval('SETS[1]') is True, "the host's blood moon rises on the guest, once")
    H3.execute('EM:SetBloodMoon(false); world.tick(2.1)'); pass_blobs(H3, G3)
    G3.execute('world.tick(2.1)')
    check(G3.eval('#SETS') == 2 and G3.eval('SETS[2]') is False, "and ends there when the host's ends")
    G3.execute('world.init({}, "off", { in_world = function() return true end }, function() return true end)')
    check(G3.eval('EM.BloodMoonChance') == 25, "leaving gives the guest its own blood moon chance back")


def an_ended_zombie_is_never_read_from_the_zombie_list():
    """DBG-20261030-010: the host crashed in UE4SS on leaving the settings menu, mod step keepalive (it reads the
    zombie list before zombies.tick). An ended zombie stayed listed until a prune at a later time, and a pause lets
    the garbage collector free it first; the next read touched freed memory."""
    print("an_ended_zombie_is_never_read_from_the_zombie_list")
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.game"] = { player = function() return nil end, world = function() return nil end,
                                          on_world_reset = function() end, keybind = function() end }
        package.loaded["mirror.ghost"] = { get = function() return nil end, is = function() return false end }
        package.loaded["mirror.loader"] = { want = function() end }
        StaticFindObject = function() return nil end
        FindAllOf = function() return {} end
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        HOOKS = {}
        util.hook = function(p, fn) HOOKS[p] = fn; return true end
        util.instances("Door_C")   -- puts the EndPlay hook in
        zombies = require("mirror.zombies")
        TOUCH = 0
        function zombie(n) return obj({ name = n, GetFullName = function() return "BP_Z_C /Game/L.L:P.Z_" .. n end }) end
        -- the engine frees it: any use of the old handle is a touch
        function free(z)
            for k in pairs(z) do z[k] = nil end
            setmetatable(z, { __index = function() TOUCH = TOUCH + 1; error("freed") end })
        end
        function ended(z) HOOKS["/Script/Engine.Actor:ReceiveEndPlay"]({ get = function() return z end }) end
        function has(z) for _, x in ipairs(zombies.all_cached()) do if rawequal(x, z) then return true end end return false end
        zombies.all_cached()       -- the full walk (none), then new ones arrive through BeginPlay
        A, B, C = zombie(1), zombie(2), zombie(3)
        zombies._test.zlist_begin({ get = function() return A end })
        zombies._test.zlist_begin({ get = function() return B end })
    """)
    check(L.eval('has(A) and has(B)'), "zombies that began play are listed")
    # A ends; the settings menu pauses our ticks (same module time) and the collector frees it
    L.execute('ended(A); free(A); R1 = has(A); R2 = has(B)')
    check(not L.eval('R1'), "a zombie that ended is gone from the very next read, at the same time")
    check(L.eval('R2'), "the others stay listed")
    check(L.eval('TOUCH') == 0, "the ended, freed zombie is never touched")
    # C begins and ends before any read; freed before the list takes the queued ones in
    L.execute('TOUCH = 0; zombies._test.zlist_begin({ get = function() return C end }); ended(C); free(C); R3 = has(C)')
    check(not L.eval('R3') and L.eval('TOUCH') == 0, "a queued zombie that ended is dropped untouched")
    L.execute('D = zombie(4); zombies._test.zlist_begin({ get = function() return D end }); R4 = has(D)')
    check(L.eval('R4') and L.eval('has(B)'), "a new zombie after that is listed as before")


def a_copy_the_game_keeps_removing_is_held_back():
    """DBG-20261030-008 (live 2026-10-30, guest of K3YBOARD32): 'copy 42 was removed by the game - making a new one'
    1829 times in 4 min: every new copy was gone (0,0,0) at its first check and the next snapshot made another."""
    print("a_copy_the_game_keeps_removing_is_held_back")
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.game"] = { player = function() return nil end, world = function() return obj({}) end,
                                          controller = function() return nil end,
                                          on_world_reset = function() end, keybind = function() end }
        package.loaded["mirror.ghost"] = { get = function() return nil end, is = function() return false end }
        package.loaded["mirror.loader"] = { want = function() end }
        package.loaded["mirror.invdiag"] = { summary = function() return "-" end }
        StaticFindObject = function() return nil end
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        util.cdo = function() return { GetConsoleVariableBoolValue = function() return false end,
                                       GetConsoleVariableIntValue = function() return 1 end,
                                       ExecuteConsoleCommand = function() end } end
        zombies = require("mirror.zombies")
        zombies._test.setup({ zombies = { enabled = true, send_hz = 15, despawn_after = 3.0 } }, "guest")
        ASKED = 0
        zombies.set_copy_hooks(function(id) ASKED = ASKED + 1; return false end, nil)
        -- a copy the game removed: no root component, reads 0,0,0
        function gone_copy() zombies._test.copy(42, obj({ K2_GetRootComponent = function() return nil end })) end
        function snapshot() blobs_in.zombies = "H\nT 1.0\nZ 42 0 0 0 100 0 0 0 0 0 0 0 0 0\n"; zombies._test.read() end
        function removed() return zombies._test.copies()[42] == nil end
    """)
    L.execute('gone_copy(); zombies._test.drive(0.3); R1 = removed(); snapshot(); R2 = ASKED')
    check(L.eval('R1') and L.eval('R2') == 1, "a copy the game removed once is made again at the next snapshot")
    L.execute('ASKED = 0; for i = 1, 2 do gone_copy(); zombies._test.drive(0.3) end; R3 = removed(); snapshot(); R4 = ASKED')
    check(L.eval('R3') and L.eval('R4') == 0, "removed 3 times in 10 s: not made again (asked %s)" % L.eval('R4'))
    L.execute('for i = 1, 40 do zombies._test.drive(0.3); snapshot() end; R5 = ASKED')
    check(L.eval('R5') == 0, "still held 12 s later")
    L.execute('zombies._test.drive(3.5); snapshot(); R6 = ASKED')
    check(L.eval('R6') == 1, "after 15 s it is made again")
    # it keeps going: the next hold is longer
    L.execute('ASKED = 0; for i = 1, 3 do gone_copy(); zombies._test.drive(0.3) end; '
              'zombies._test.drive(20); snapshot(); R7 = ASKED; zombies._test.drive(11); snapshot(); R8 = ASKED')
    check(L.eval('R7') == 0 and L.eval('R8') == 1, "the second hold is 30 s (%s %s)" % (L.eval('R7'), L.eval('R8')))
    # another copy removed once in a while is never held
    L.execute('ASKED = 0; for i = 1, 4 do zombies._test.copy(43, obj({ K2_GetRootComponent = function() return nil end })); '
              'zombies._test.drive(11) end; '
              'blobs_in.zombies = "H\\nT 1.0\\nZ 43 0 0 0 100 0 0 0 0 0 0 0 0 0\\n"; zombies._test.read(); R9 = ASKED')
    check(L.eval('R9') == 1, "a copy removed once every 11 s is made again each time")
    # a long session: a copy the game removed once doesn't leave its record behind forever
    L.execute('zombies._test.drive(400); for i = 1, 300 do zombies._test.copy(1000 + i, obj({ K2_GetRootComponent = function() return nil end })); '
              'zombies._test.drive(0.01) end; zombies._test.drive(400); '
              'for i = 1, 300 do zombies._test.copy(2000 + i, obj({ K2_GetRootComponent = function() return nil end })); zombies._test.drive(0.01) end; '
              'R10 = zombies._test.remade_count()')
    # (600 removed in two batches 400 s apart: about the second batch is kept, not both)
    check(L.eval('R10') <= 320, "copies removed long ago are forgotten (%s kept)" % L.eval('R10'))


def a_new_ghost_leaves_no_name_tag_behind():
    """user 2026-10-30 (live, guest of K3YBOARD32): 'my name is stuck somewhere else as well as above me on his screen'.
    A ghost waiting for its destroy is only hidden, and its screen-space tag still drew where it was left."""
    print("a_new_ghost_leaves_no_name_tag_behind")
    L = lua()
    L.execute('''
        CALLS = {}; ONDESTROY = {}; G, GEN = nil, 0; TAGS = {}
        local function comp(n)
            return setmetatable({ valid = true, n = n, visible = true }, { __index = function(o, k)
                return function(_, ...)
                    CALLS[#CALLS + 1] = "tag" .. o.n .. ":" .. k
                    if k == "SetVisibility" then o.visible = (...) end
                end
            end })
        end
        package.loaded["mirror.util"] = { valid = function(o) return o ~= nil and o.valid ~= false end,
            dist = function() return 100 end, vec = function(v) return v end }
        package.loaded["mirror.game"] = { on_world_reset = function() end,
            player = function() return { K2_GetActorLocation = function() return {} end } end }
        package.loaded["mirror.ghost"] = { get = function() return G end, generation = function() return G and GEN or nil end,
            on_destroy = function(fn) ONDESTROY[#ONDESTROY + 1] = fn end }
        package.loaded["mirror.link"] = { peer_name = function() return "Bob" end }
        package.loaded["mirror.netq"] = { tag = function(n) return n, "white" end }
        package.loaded["mirror.voice"] = { talking = function() return 0, false end }
        package.loaded["mirror.mysettings"] = { on = function() return true end }
        FText = function(s) return s end
        nametag = require("mirror.nametag")
        nametag.attach = function(actor, text)
            local c = comp(#TAGS + 1); TAGS[#TAGS + 1] = c
            return { comp = c, text = { SetText = function() end, SetColorAndOpacity = function() end }, name = text, shown = true }
        end
        nametag.init({}); nametag.init({})   -- (phase1 calls it from two places)
        function spawn() G = { valid = true }; GEN = GEN + 1 end
        function destroy(by_game) for _, fn in ipairs(ONDESTROY) do fn() end; if not by_game then G.valid = false end; G = nil end
        function shown() local n = 0; for _, c in ipairs(TAGS) do if c.visible then n = n + 1 end end; return n end
    ''')
    L.execute('spawn(); nametag.tick(1.0)')
    check(L.eval('#TAGS') == 1 and L.eval('shown()') == 1, "a ghost gets one tag")
    check(L.eval('#ONDESTROY') == 1, "the tag follows the ghost's destroy, registered once for two inits")
    # a destroy that only hides the ghost (animgate waits): the old actor and its tag stay in the world
    L.execute('local old = G; for _, fn in ipairs(ONDESTROY) do fn() end; G = nil; spawn(); nametag.tick(1.0)')
    check(L.eval('#TAGS') == 2 and L.eval('TAGS[1].visible') is False,
          "a ghost waiting for its destroy: its tag is hidden (was: stayed on screen where the ghost was left)")
    check(L.eval('shown()') == 1 and L.eval('TAGS[2].visible') is True, "...and only the new ghost's tag shows")
    L.execute('destroy(true); spawn(); nametag.tick(1.0)')
    check(L.eval('shown()') == 1 and L.eval('#TAGS') == 3, "the game removed it: one tag, on the new ghost")
    L.execute('CALLS = {}; G = nil; for _, fn in ipairs(ONDESTROY) do fn() end')
    check(L.eval('#CALLS') == 0, "no ghost left (a world reset freed it): the old tag isn't touched")


def the_message_of_the_day_shows_once_in_a_world_and_on_the_main_menu():
    """user 2026-10-30 'a message of the day that I can send whenever': the bridge's mirror_motd.txt shows once per
    message as a card in a world (not again after a restart) and as a banner at the main menu while the menu is up."""
    print("the_message_of_the_day_shows_once_in_a_world_and_on_the_main_menu")
    d = tempfile.mkdtemp()
    try:
        def new_lua():
            L = lua()
            L.execute('''
                local d = ...
                NOTES = {}; CALLS = {}; MENUS = {}; HOOKS = 0
                function called(s) for _, c in ipairs(CALLS) do if c == s then return true end end return false end
                function mock(name)
                    local o = { valid = true, name = name }
                    return setmetatable(o, { __index = function(_, k)
                        if k == "WidgetTree" then local t = mock("tree"); rawset(o, k, t); return t end
                        if k == "Font" then return {} end
                        return function(_, ...)
                            CALLS[#CALLS + 1] = name .. ":" .. k
                            if k == "IsInViewport" then return o.on end
                            if k:find("^AddChild") then return mock("slot") end
                            if k == "GetOwningPlayer" then return mock("pc") end
                            if k == "Create" then return mock("banner") end
                        end
                    end })
                end
                StaticFindObject = function(p) return mock("found") end
                StaticConstructObject = function(cls) return mock("w") end
                FindAllOf = function() return MENUS end
                FText = function(s) return s end
                FName = function(s) return s end
                LOOPS = {}
                LoopAsync = function(ms, fn) LOOPS[#LOOPS + 1] = fn end
                ExecuteInGameThread = function(fn) fn() end
                package.loaded["mirror.notify"] = { show = function(text, kind, key, always, opts)
                    NOTES[#NOTES + 1] = { text = text, key = key, always = always, title = opts and opts.title, sticky = opts and opts.sticky, secs = opts and opts.secs } end }
                package.loaded["mirror.link"] = { dir = function() return d end }
                package.loaded["mirror.util"] = { valid = function(o) return o ~= nil and o.valid ~= false end,
                    safe = function(fn, _, ...) return pcall(fn, ...) end, cdo = function() return mock("wbl") end,
                    ensure_hook = function() HOOKS = HOOKS + 1; return true end }
                TICK, RESET = nil, nil
                LOGS = {}
                function logged(s) for _, l in ipairs(LOGS) do if l:find(s, 1, true) then return true end end return false end
                function nlogged(s) local n = 0; for _, l in ipairs(LOGS) do if l:find(s, 1, true) then n = n + 1 end end return n end
                package.loaded["mirror.log"] = setmetatable({}, { __index = function(_, k)
                    return function(s) LOGS[#LOGS + 1] = k .. " " .. tostring(s) end end })
                package.loaded["mirror.game"] = { on_tick = function(fn) TICK = fn end, on_world_reset = function(fn) RESET = fn end }
                motd = require("mirror.motd")
                function put(s) local f = io.open(d .. "/mirror_motd.txt", "wb"); f:write(s); f:close() end
                function seenfile() local f = io.open(d .. "/mirror_motd_seen.txt", "rb"); local s = f and f:read("*a"); if f then f:close() end; return s end
            ''', d.replace("\\", "/"))
            return L

        L = new_lua()
        # the file's shape
        check(L.eval('motd.parse("motd ABCDEFGH 0 Hello there\\nEND\\n").text') == "Hello there"
              and L.eval('motd.parse("motd ABCDEFGH 0 Hello there\\nEND\\n").id') == "ABCDEFGH", "a message line is read")
        check(L.eval('motd.parse("motd none\\nEND\\n")') is None and L.eval('motd.parse("motd ABCDEFGH 0 Half")') is None
              and L.eval('motd.parse("motd ABC 0 short id\\nEND\\n")') is None and L.eval('motd.parse(nil)') is None,
              "'motd none', a half written file, a bad id and no file are no message")
        check(L.eval('motd.parse("motd ABCDEFGH 100 Old\\nEND\\n", 100)') is None
              and L.eval('motd.parse("motd ABCDEFGH 200 Soon\\nEND\\n", 100).text') == "Soon", "an expired one is no message, one expiring later is")

        # in a world: once per message, as a 25 s card shown whatever the messages setting says
        L.execute('motd.init(); put("motd ABCDEFGH 0 Servers down tonight\\nEND\\n")')
        L.execute('TICK(1.0)')
        check(L.eval('#NOTES') == 0, "nothing in the first seconds of a world (the load settles first)")
        L.execute('for _ = 1, 10 do TICK(1.0) end')
        check(L.eval('#NOTES') == 1 and L.eval('NOTES[1].text') == "Servers down tonight" and L.eval('NOTES[1].always') is True
              and L.eval('NOTES[1].title') == "MESSAGE FROM SYMPLYSCK" and L.eval('NOTES[1].secs') == 25 and not L.eval('NOTES[1].sticky'),
              "a new message shows once as a card: %s" % L.eval('NOTES[1] and NOTES[1].text'))
        check((L.eval('seenfile()') or "").startswith("ABCDEFGH"), "...and is noted as seen on this PC")
        L.execute('for _ = 1, 20 do TICK(1.0) end; RESET(); for _ = 1, 20 do TICK(1.0) end')
        check(L.eval('#NOTES') == 1, "the same message isn't shown again (next reads, a new world)")
        L2 = new_lua()
        L2.execute('motd.init(); for _ = 1, 20 do TICK(1.0) end')
        check(L2.eval('#NOTES') == 0, "...nor after the game restarts")
        L2.execute('put("motd JKMNPQRS 0 Weekend event\\nEND\\n"); for _ = 1, 6 do TICK(1.0) end')
        check(L2.eval('#NOTES') == 1 and L2.eval('NOTES[1].text') == "Weekend event", "a newer message shows")
        L2.execute('put("motd none\\nEND\\n"); for _ = 1, 6 do TICK(1.0) end')
        check(L2.eval('#NOTES') == 1, "'motd none' shows nothing")

        # at the main menu: a banner while the menu is up, polled from LoopAsync, gone once a world ticks
        L3 = new_lua()
        L3.execute('put("motd ABCDEFGH 0 Servers down tonight\\nEND\\n"); motd.init()')
        check(L3.eval('#LOOPS') == 1, "the main menu poll starts with the game")
        L3.execute('LOOPS[1](); LOOPS[1]()')
        check(L3.eval('motd._test.banner()') is None, "no banner while the main menu isn't on screen")
        L3.execute('MENUS = { mock("menu") }; MENUS[1].on = true; for _ = 1, 3 do LOOPS[1]() end')
        check(L3.eval('motd._test.banner() ~= nil') and L3.eval('motd._test.banner().id') == "ABCDEFGH"
              and L3.eval('called("banner:AddToViewport")'), "the menu up 2 s: the banner shows the message")
        check(L3.eval('#NOTES') == 0, "...and the world's once-only card isn't used up by it")
        L3.execute('MENUS[1].on = false; LOOPS[1]()')
        check(L3.eval('called("banner:SetVisibility")') and L3.eval('motd._test.banner().shown') is False,
              "the menu off the screen (New Game, Load): the banner hides")
        L3.execute('MENUS[1].on = true; LOOPS[1](); put("motd none\\nEND\\n"); LOOPS[1]()')
        check(L3.eval('motd._test.banner()') is None and L3.eval('called("banner:RemoveFromParent")'), "the message cleared: the banner goes")
        L3.execute('put("motd JKMNPQRS 0 Weekend event\\nEND\\n"); LOOPS[1]()')
        check(L3.eval('motd._test.banner() and motd._test.banner().id') == "JKMNPQRS", "a new message at the menu: its banner shows")
        L3.execute('CALLS = {}; TICK(0.1)')
        check(L3.eval('motd._test.banner()') is None and L3.eval('called("banner:RemoveFromParent")'), "a world's first tick takes the banner away")
        L3.execute('TICK(0.1)')
        check(L3.eval('LOOPS[1]()') is True, "...and the main menu poll stops once the world ticks")
        L3.execute('CALLS = {}; HOOKS = 0; for _ = 1, 10 do TICK(1.0) end')
        check(L3.eval('HOOKS') > 0, "in a world the main menu hook is kept in place")

        # user 2026-10-31 'make it stay while the main menu is up' (was 15 s, then gone)
        L4 = new_lua()
        L4.execute('put("motd ABCDEFGH 0 Servers down tonight\\nEND\\n"); motd.init(); LOOPS[1]()')
        check(L4.eval('logged("motd: main menu off screen")'), "the menu not up yet: logged as off the screen")
        L4.execute('MENUS = { mock("menu") }; MENUS[1].on = true; for _ = 1, 3 do LOOPS[1]() end')
        check(L4.eval('motd._test.banner() and motd._test.banner().id') == "ABCDEFGH" and L4.eval('logged("motd: main menu on screen")'),
              "the menu up: logged, and the banner shows")
        L4.execute('CALLS = {}; for _ = 1, 2000 do LOOPS[1]() end')
        check(L4.eval('motd._test.banner() and motd._test.banner().shown') is True and not L4.eval('called("banner:RemoveFromParent")'),
              "...still there after 2000 s of the menu up (no time limit, no giving up)")
        check(L4.eval('LOOPS[1]()') is False, "...and the main menu poll keeps going")
        check(L4.eval('nlogged("motd: main menu on screen")') == 1, "...the menu logged once while it stays up")
        L4.execute('MENUS[1].on = false; for _ = 1, 30 do LOOPS[1]() end')
        check(L4.eval('motd._test.banner().shown') is False and L4.eval('nlogged("motd: main menu off screen")') == 2,
              "the menu off the screen (New Game, Load): hidden, logged once")
        L4.execute('CALLS = {}; MENUS[1].on = true; LOOPS[1]()')
        check(L4.eval('motd._test.banner().shown') is True and L4.eval('called("banner:SetVisibility")')
              and not L4.eval('called("banner:AddToViewport")'), "back at the menu: the same banner shows again")
        L4.execute('put("motd JKMNPQRS 0 Weekend event\\nEND\\n"); LOOPS[1](); LOOPS[1]()')
        check(L4.eval('motd._test.banner() and motd._test.banner().id') == "JKMNPQRS", "a new message: its banner replaces the old one")
        # a banner that can't be built isn't retried every second, and the poll keeps going for the next message
        L4.execute('motd._test.reset(); LOOPS = {}; put("motd ABCDEFGH 0 Servers down tonight\\nEND\\n"); motd.init()')
        L4.execute('local c = package.loaded["mirror.util"].cdo; package.loaded["mirror.util"].cdo = function() return nil end; '
                   'for _ = 1, 10 do LOOPS[1]() end; package.loaded["mirror.util"].cdo = c')
        check(L4.eval('motd._test.banner()') is None and L4.eval('nlogged("main menu banner for message ABCDEFGH -> false")') == 1,
              "a failed build: logged once, not retried for that message")
        L4.execute('put("motd JKMNPQRS 0 Weekend event\\nEND\\n"); LOOPS[1]()')
        check(L4.eval('motd._test.banner() and motd._test.banner().id') == "JKMNPQRS", "...the next message still gets its banner")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def the_host_can_switch_the_debug_menu_off_for_everyone():
    """user 2026-10-30: host rule DEBUG MENU - off, an opened menu closes at once (the game's CloseDebugMenu); on, the
    others hear who opened it; everyone hears the rule change."""
    print("the_host_can_switch_the_debug_menu_off_for_everyone")

    def side(role):
        L = lua()
        L.execute(FAKES + r"""
            ROLE = ...
            package.loaded["mirror.link"].peer_age = function() return 0 end
            package.loaded["mirror.link"].peer_name = function() return ROLE == "host" and "Gus" or "Hal" end
            package.loaded["mirror.link"].dir = nil   -- (no settings file in the test)
            package.loaded["mirror.peers"] = { each = function(m, fn) fn(package.loaded["mirror.link"], nil) end }
            NOTES = {}
            package.loaded["mirror.notify"] = { show = function(m) NOTES[#NOTES + 1] = m end, clear = function() end }
            util = require("mirror.util")
            HOOKS = {}
            util.ensure_hook = function(path, fn) HOOKS[path] = fn; return true end
            CLOSED = 0
            PLAYER = obj({ CloseDebugMenu = function() CLOSED = CLOSED + 1 end })
            package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end }
            hostrules = require("mirror.hostrules")
            hostrules.init(function() return ROLE end)
            dm = require("mirror.debugmenu")
            dm.init()
            function OPEN() HOOKS["/Game/UI/Widgets/Debug/DebugMenu.DebugMenu_C:Construct"]() end
            function note_has(s) for _, m in ipairs(NOTES) do if m:find(s, 1, true) then return true end end return false end
            dm.tick(2.1)
        """, role)
        return L
    H, G = side("host"), side("guest")

    def carry(a, b):
        out, inn = a.eval("blobs_out"), b.eval("blobs_in")
        for k in list(out.keys()):
            inn[k] = out[k]

    H.execute("hostrules.tick()"); carry(H, G); G.execute("dm.tick(0.1)")
    G.execute("OPEN(); dm.tick(0.1)"); carry(G, H); H.execute("dm.tick(0.1)")
    check(H.eval('note_has("Gus opened the debug menu.")') and G.eval("CLOSED") == 0, "rule on: the host hears the guest opened it")
    H.execute('hostrules.toggle("debugmenu"); hostrules.tick(); dm.tick(0.1)'); carry(H, G); G.execute("dm.tick(0.1)")
    check(H.eval('note_has("debug menu OFF for everyone")') and G.eval('note_has("debug menu OFF for everyone")'),
          "the switch to off is announced on both screens")
    G.execute("OPEN(); dm.tick(0.1)")
    check(G.eval("CLOSED") == 1 and G.eval('note_has("switched the debug menu off")'), "rule off: the guest's menu closes at once")
    H.execute("OPEN(); dm.tick(0.1)")
    check(H.eval("CLOSED") == 1, "...and the host's own too")
    # audit 2026-10-30: a guest joining a host whose rule is already off ran on the defaults (on) until the rules
    # arrived, and their arrival read as a switch - "turned OFF for everyone" on a join where nobody switched anything
    G2 = side("guest")
    G2.execute("dm.tick(0.1)")
    H.execute("hostrules.tick()"); carry(H, G2); G2.execute("dm.tick(0.1); dm.tick(0.1)")
    check(not G2.eval('note_has("for everyone")'), "joining a host with the rule off: no switch notice")
    G2.execute("OPEN(); dm.tick(0.1)")
    check(G2.eval("CLOSED") == 1, "...and the host's off rule still holds for the joiner")
    H.execute('hostrules.toggle("debugmenu"); hostrules.tick(); dm.tick(0.1)'); carry(H, G2); G2.execute("dm.tick(0.1)")
    check(G2.eval('note_has("debug menu ON for everyone")'), "...while a real switch afterwards is still announced")
    # ...and leaving forgets that host's rules: the next host (rule off) is read fresh, not through the old one's
    G2.execute('RESETS = 0; package.loaded["mirror.link"].reset_blob = function(n) if n == "rules" then RESETS = RESETS + 1 end end')
    G2.execute('ROLE = "solo"; dm.tick(0.1); NOTES = {}')
    check(G2.eval("RESETS") == 1, "leaving: the rules blob is reset so the next host's arrive again")
    H2 = side("host")
    H2.execute('hostrules.toggle("debugmenu"); hostrules.tick()')
    G2.execute('ROLE = "guest"; dm.tick(0.1)')
    check(G2.eval('hostrules.source()') is None, "joining the next host: no rules in hand yet (the old host's are gone)")
    carry(H2, G2); G2.execute("dm.tick(0.1)")
    check(G2.eval('hostrules.get("debugmenu")') is False and not G2.eval('note_has("for everyone")'),
          "...its off rule arrives and applies without a switch notice")


def the_nuke_goes_off_on_both_screens():
    """user 2026-10-30 'sync nuke': the easter-egg bomb's MC_Explode in one game sets off the other game's bomb at the
    same spot, once, without echoing back."""
    print("the_nuke_goes_off_on_both_screens")
    sides = {}
    for role in ("host", "guest"):
        L = lua()
        L.execute(FAKES + r"""
            package.loaded["mirror.link"].peer_age = function() return 0 end
            util = require("mirror.util")
            HOOKS = {}
            util.ensure_hook = function(path, fn) HOOKS[path] = fn; return true end
            FN = "/Game/Blueprints/Other/EasterEggs/BP_EasterEgg_Nuke.BP_EasterEgg_Nuke_C:MC_Explode"
            CALLS = 0
            -- the game runs the hook around its own MC_Explode: as UE4SS calls a pre hook, with the actor wrapped
            BOMB = obj({ K2_GetActorLocation = function() return { X = 1000, Y = 2000, Z = 300 } end })
            BOMB.MC_Explode = function(self) CALLS = CALLS + 1; if HOOKS[FN] then HOOKS[FN]({ get = function() return BOMB end }) end end
            FAR = obj({ K2_GetActorLocation = function() return { X = 90000, Y = 0, Z = 0 } end, MC_Explode = function() FAR_CALLS = (FAR_CALLS or 0) + 1 end })
            FindAllOf = function(c) if c == "BP_EasterEgg_Nuke_C" then return { FAR, BOMB } end return {} end
            nuke = require("mirror.nuke")
            nuke.init()
            nuke.tick(2.1)
        """)
        sides[role] = L
    H, G = sides["host"], sides["guest"]

    def carry(a, b):
        out, inn = a.eval("blobs_out"), b.eval("blobs_in")
        for k in list(out.keys()):
            inn[k] = out[k]

    check(H.eval("HOOKS[FN] ~= nil"), "(setup) MC_Explode is hooked")
    H.execute("BOMB:MC_Explode(); nuke.tick(0.1)")          # shot on the host's screen
    carry(H, G)
    G.execute("nuke.tick(0.1)")
    check(G.eval("CALLS") == 1 and G.eval("FAR_CALLS") is None, "the guest's bomb at that spot goes off (not one far away)")
    G.execute("nuke.tick(0.1)")
    sent_back = G.eval("blobs_out.nuke")
    check(sent_back is None or "E " not in sent_back, "...without sending it back")
    carry(H, G)
    G.execute("nuke.tick(0.1)")
    check(G.eval("CALLS") == 1, "the same news again doesn't set it off twice")


def human_corpses_get_their_inventory_made_first():
    """live 2026-10-30: every item failed on all 8 human corpses ('0 matched, 0 added' - no containers), 0 failures on
    153 zombies. The guest makes a human copy's inventory once before putting the host's loot in; zombies untouched."""
    print("human_corpses_get_their_inventory_made_first")
    out = {}
    for fam in ("human", "zombie"):
        L = lua()
        L.execute(FAKES + r"""
            FAM = ...
            package.loaded["mirror.link"].peer_age = function() return 0 end
            util = require("mirror.util")
            util.job = function(name, fn, ...) fn(...); return true end
            HOOKS = {}
            util.ensure_hook = function(p, fn) HOOKS[p] = fn; return true end
            package.loaded["mirror.ghost"] = { exists = function() return true end }
            T = 0
            Z = obj({ BP_JigMultiplayer = obj({}) })
            BOXES = FAM == "human" and 0 or 1
            GEN, ADDED, MISSING, PUTS = 0, 0, 0, 0
            ROLLED = {}
            local info = package.loaded["mirror.log"].info
            package.loaded["mirror.log"].info = function(m, ...)
                if m:find("telling the other game", 1, true) then PUTS = PUTS + 1 end
                return info(m, ...)
            end
            package.loaded["mirror.jig"] = {
                -- the roll puts the body's own items in: if the game fires its item-added event for them, it must
                -- not reach the host as items the guest put in (they'd join the host's loot)
                generate = function()
                    GEN = GEN + 1; BOXES = 1
                    ROLLED = { { uid = "r1", da = "/Game/Items/Bandage.DA_Bandage", count = 1, dx = 0, dy = 0 } }
                    for p, f in pairs(HOOKS) do
                        if p:find("JigMP_OnItemAdded", 1, true) then f({ get = function() return Z end }, { get = function() return "r1" end }) end
                    end
                end,
                container_count = function() return BOXES end,
                contents_of = function() return ROLLED end,
                subtree = function() return {} end, worth_sending = function() return false end,
                count_of_item = function() return 1 end,
                encode = function(l) return "" end,
                decode = function(s) return { { da = "/Game/Items/Rags.DA_Rags", count = 1 }, { da = "/Game/Items/Knife.DA_Knife", count = 1 } } end,
                apply_contents = function(comp, items)
                    if BOXES == 0 then MISSING = MISSING + #items; return 0, 0, 0, #items end
                    ADDED = ADDED + #items; return 0, #items, 0, 0
                end,
                set_starting = function() return 0, 0 end,
                full_path = function(x) return x end, uid_str = function(x) return x end,
            }
            COPY = { z = Z, born = 0, fam = FAM, dead_at = 0.1 }
            package.loaded["mirror.zombies"] = {
                now = function() return T end, host_zombies = function() return {} end,
                copies = function() return { [9] = COPY } end, copy = function(id) return id == 9 and COPY or nil end,
                is_trader = function() return false end, dead_of = function() return true end,
                host_id_of = function() return nil end, copy_id_of = function(z) return z == Z and 9 or nil end,
                set_copy_hooks = function() end,
            }
            corpses = require("mirror.corpses")
            corpses.init({}, "guest", package.loaded["mirror.zombies"], { in_world = function() return true end, guest_in_world = function() return true end })
        """, fam)
        # the host's list for body 9 arrives (as its blob would), then the guest's checks at 1 s and 4 s after death
        ep = "1"
        L.execute('blobs_in.zloot = %r' % ("%s 1 1 L 9 x" % ep))
        for _ in range(20):
            L.execute("T = T + 0.3; corpses.tick(0.3)")
        out[fam] = (L.eval("GEN"), L.eval("ADDED"), L.eval("MISSING"), L.eval("PUTS"))
    check(out["human"][0] == 1 and out["human"][1] > 0 and out["human"][2] == 0,
          "a human corpse's inventory is made once, then the host's loot goes in: %s" % (out["human"],))
    check(out["human"][3] == 0, "the body's own roll is not sent to the host as items put in (%d sent)" % out["human"][3])
    check(out["zombie"][0] == 0 and out["zombie"][1] > 0, "a zombie corpse (containers already there) is not re-made: %s" % (out["zombie"],))


def trader_stock_is_the_hosts():
    print("trader_stock_is_the_hosts")
    sides = {}
    for role in ("host", "guest"):
        L = lua()
        L.execute(FAKES + r"""
            ROLE = ...
            package.loaded["mirror.link"].peer_age = function() return 0 end
            util = require("mirror.util")
            util.job = function(name, fn, ...) fn(...); return true end
            HOOKS = {}
            util.ensure_hook = function(path, fn) HOOKS[path] = fn; return true end
            package.loaded["mirror.ghost"] = { exists = function() return true end }
            T, DEAD = 0, false
            TR = obj({ BP_JigMultiplayer = obj({}) })
            STOCK = { { da = "/Game/Items/Ammo.Ammo", count = 3 }, { da = "/Game/Items/Gun.Gun", count = 1 } }
            GEN, APPLIED, TAKEN = 0, {}, {}
            package.loaded["mirror.jig"] = {
                generate = function() GEN = GEN + 1 end,
                contents_of = function() return STOCK end,
                encode = function(l) local o = {} for _, w in ipairs(l) do o[#o + 1] = w.da .. "=" .. w.count end return table.concat(o, ";") end,
                decode = function(s) local o = {} for da, n in s:gmatch("([^=;]+)=(%d+)") do o[#o + 1] = { da = da, count = tonumber(n) } end return o end,
                apply_contents = function(comp, items) APPLIED[#APPLIED + 1] = #items; return #items, 0, 0, 0 end,
                set_starting = function() return 0, 0 end,
                count_of_item = function(comp, da) for _, w in ipairs(STOCK) do if w.da == da then return w.count end end return 0 end,
                reduce_item = function(comp, da, left) TAKEN[#TAKEN + 1] = da .. ">" .. left; return 1 end,
                full_path = function(x) return x end, uid_str = function(x) return x end,
            }
            COPY = { z = TR, born = 0 }
            package.loaded["mirror.zombies"] = {
                now = function() return T end, host_zombies = function() return { [7] = TR } end,
                copies = function() return { [7] = COPY } end, copy = function(id) return id == 7 and COPY or nil end,
                is_trader = function(z) return z == TR end, dead_of = function() return DEAD end,
                host_id_of = function(z) return z == TR and 7 or nil end, copy_id_of = function(z) return z == TR and 7 or nil end,
                set_copy_hooks = function() end,
            }
            corpses = require("mirror.corpses")
            corpses.init({}, ROLE, package.loaded["mirror.zombies"], { in_world = function() return true end, guest_in_world = function() return true end })
            function tick() T = T + 0.3; if DEAD and COPY then COPY.dead_at = COPY.dead_at or T end; corpses.tick(0.3) end
        """, role)
        sides[role] = L
    H, G = sides["host"], sides["guest"]

    def carry(a, b):
        out, inn = a.eval("blobs_out"), b.eval("blobs_in")
        for k in list(out.keys()):
            inn[k] = out[k]

    for _ in range(4):
        H.execute("tick()"); carry(H, G); G.execute("tick()")
    for _ in range(4):
        G.execute("tick()")
    check(G.eval("APPLIED[1]") == 2 and G.eval("GEN") == 1, "the guest's living trader copy gets the host's stock (made once first)")
    check(G.eval("#APPLIED") == 1, "applied once while alive")
    # host buys 2 ammo: the guest's copy loses them too
    H.execute('STOCK[1].count = 1; HOOKS["/Game/AI/Humans/Trader/BP_MasterTrader.BP_MasterTrader_C:JigMP_OnMainContainerItemRemoved"]'
              '({ get = function() return TR end }, nil, nil, nil, { get = function() return { '
              'ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = { ItemID_28_01CA27D84AF7D1014D9E2E83894C1848 = "/Game/Items/Ammo.Ammo" } } end }); tick()')
    carry(H, G); G.execute("tick()")
    check(G.eval("TAKEN[1]") == "/Game/Items/Ammo.Ammo>1", "a purchase from the host's trader is taken from the guest's copy")
    # the trader dies: the host sends what the body holds, the guest applies it again once its copy is dead
    H.execute('DEAD = true; STOCK = { { da = "/Game/Items/Money.Money", count = 700 } }')
    for _ in range(5):
        H.execute("tick()")
    carry(H, G)
    G.execute("DEAD = true")
    for _ in range(5):
        G.execute("tick()")
    check(G.eval("#APPLIED") == 2 and G.eval("APPLIED[2]") == 1, "the dead trader's body holds the host's loot")
    for _ in range(15):
        G.execute("tick()")
    n_applied = G.eval("#APPLIED")
    # the host sends that same list once more (live 2026-10-30: each corpse was set 3-4 times): not set again
    last = H.eval("blobs_out.zloot").split("\n")[-1]
    ep, _, stamp, payload = last.split(" ", 3)
    G.execute('blobs_in.zloot = %r' % ("%s 99 %s %s" % (ep, stamp, payload)))
    for _ in range(20):
        G.execute("tick()")
    check(G.eval("#APPLIED") == n_applied, "the same list again doesn't set the corpse again (%s -> %s)" % (n_applied, G.eval("#APPLIED")))
    G.execute('blobs_in.zloot = %r' % ("%s 100 %s L 7 -" % (ep, stamp)))
    for _ in range(20):
        G.execute("tick()")
    check(G.eval("#APPLIED") > n_applied, "a changed list does")


CORPSE_FAKES = FAKES + r"""
    ROLE, GID = ...
    package.loaded["mirror.link"].peer_age = function() return 0 end
    T, DEAD = 0, false
    AMMO, GUN = "/Game/Items/Ammo.Ammo", "/Game/Items/Gun.Gun"
    MASTER = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"
    util = require("mirror.util")
    HOOKS = {}
    util.ensure_hook = function(path, fn) HOOKS[path] = HOOKS[path] or {}; HOOKS[path][fn] = true; return true end
    function fire_removed(z, da, n)
        for fn in pairs(HOOKS[MASTER .. ":JigMP_OnMainContainerItemRemoved"] or {}) do
            fn({ get = function() return z end }, nil, nil, nil, { get = function() return {
                ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = { ItemID_28_01CA27D84AF7D1014D9E2E83894C1848 = da,
                                                                  Count_8_DD79AF2A46126A338C8DCCB4616D91CD = n } } end })
        end
    end
    package.loaded["mirror.ghost"] = { exists = function() return true end }
    SH, ALL = {}, {}
    package.loaded["mirror.peers"] = {
        shared = function(n, init) SH[n] = SH[n] or init or {}; return SH[n] end,
        role = function() return ROLE end, main = function(n) return require(n) end,
        relay = function(name, self_mod, fn)
            if ROLE ~= "host" or RELAYING then return end
            RELAYING = true
            for _, m in ipairs(ALL) do if m ~= self_mod then fn(m) end end
            RELAYING = false
        end }
    TR = obj({ BP_JigMultiplayer = obj({}) })
    UIDS = 0
    function count(da) local n = 0 for _, w in ipairs(STOCK) do if w.da == da then n = n + w.count end end return n end
    TAKEN, APPLIED = {}, 0
    package.loaded["mirror.jig"] = {
        generate = function() end,
        contents_of = function() return STOCK end,
        encode = function(l) local o = {} for _, w in ipairs(l) do o[#o + 1] = w.da .. "=" .. w.count end return table.concat(o, ";") end,
        decode = function(s) local o = {} for da, n in s:gmatch("([^=;]+)=(%d+)") do o[#o + 1] = { da = da, count = tonumber(n) } end return o end,
        apply_contents = function(comp, items)
            APPLIED = APPLIED + 1
            STOCK = {}
            for _, w in ipairs(items) do UIDS = UIDS + 1; STOCK[#STOCK + 1] = { uid = "g" .. UIDS, da = w.da, count = w.count } end
            return #items, 0, 0, 0
        end,
        set_starting = function() return 0, 0 end,
        count_of_item = function(comp, da) return count(da) end,
        reduce_item = function(comp, da, left)
            local take, n = count(da) - left, 0
            for _, w in ipairs(STOCK) do
                if take > 0 and w.da == da then local k = math.min(take, w.count); w.count = w.count - k; take = take - k; n = n + k end
            end
            if n > 0 then TAKEN[#TAKEN + 1] = da .. ">" .. left; fire_removed(TR, da) end
            return n
        end,
        full_path = function(x) return x end, uid_str = function(x) return x end,
        subtree = function() return nil end, worth_sending = function() return false end,
    }
    SESSION = { in_world = function() return true end, guest_in_world = function() return true end }
    function zfake(id)
        local copy = { z = TR, born = 0 }
        return {
            now = function() return T end, host_zombies = function() return { [id] = TR } end,
            copies = function() return { [id] = copy } end, copy = function(i) return i == id and copy or nil end,
            is_trader = function() return false end, dead_of = function() return DEAD end,
            host_id_of = function(z) return z == TR and id or nil end, copy_id_of = function(z) return z == TR and id or nil end,
            set_copy_hooks = function() end, _copy = copy,
        }
    end
    -- another player's copy of corpses (and its own events/link), like peers.lua loads it
    function load_copy(zf)
        local out, inn, loaded = {}, {}, {}
        local lk = { put_blob = function(n, b) out[n] = b end, get_blob = function(n) local b = inn[n]; inn[n] = nil; return b end,
                     peer_age = function() return 0 end }
        local function ireq(name)
            if name == "mirror.link" then return lk end
            if name == "mirror.events" or name == "mirror.corpses" then
                if not loaded[name] then
                    local path = package.searchpath(name, package.path)
                    loaded[name] = assert(loadfile(path, "t", setmetatable({ require = ireq }, { __index = _G })))(name)
                end
                return loaded[name]
            end
            return require(name)
        end
        local m = ireq("mirror.corpses")
        m.init({}, ROLE, zf, SESSION)
        return m, out, inn
    end
"""


def corpse_loot_reaches_every_player():
    print("corpse_loot_reaches_every_player")
    H = lua()
    H.execute(CORPSE_FAKES + r"""
        STOCK = { { uid = "h1", da = AMMO, count = 3 }, { uid = "h2", da = GUN, count = 1 } }
        main = require("mirror.corpses")
        main.init({}, ROLE, zfake(7), SESSION)
        c2, out2, in2 = load_copy(zfake(3))
        ALL = { main, c2 }
        function tick() T = T + 0.3; main.tick(0.3); c2.tick(0.3) end
    """, "host")
    guests = []
    for gid in (7, 3):
        G = lua()
        G.execute(CORPSE_FAKES + r"""
            STOCK = { { uid = "x1", da = AMMO, count = 5 } }
            ZF = zfake(GID)
            corpses = require("mirror.corpses")
            corpses.init({}, "guest", ZF, SESSION)
            function tick() T = T + 0.3; if DEAD then ZF._copy.dead_at = ZF._copy.dead_at or T end; corpses.tick(0.3) end
        """, "guest", gid)
        guests.append(G)
    G1, G2 = guests

    def carry(src_out, dst_in):
        for k in list(src_out.keys()):
            dst_in[k] = src_out[k]

    def step(n=1):
        for _ in range(n):
            H.execute("tick()")
            carry(H.eval("blobs_out"), G1.eval("blobs_in")); carry(H.eval("out2"), G2.eval("blobs_in"))
            G1.execute("tick()"); G2.execute("tick()")
            carry(G1.eval("blobs_out"), H.eval("blobs_in")); carry(G2.eval("blobs_out"), H.eval("in2"))

    step(4)
    H.execute("DEAD = true"); G1.execute("DEAD = true"); G2.execute("DEAD = true")
    step(6)
    check(G1.eval("count(AMMO)") == 3 and G2.eval("count(AMMO)") == 3 and G2.eval("count(GUN)") == 1,
          "both guests' corpses hold the host's loot (each under its own zombie id)")
    # guest 1 loots 2 ammo: the host takes them, guest 2's corpse loses them too, nothing comes back to guest 1
    G1.execute("STOCK[1].count = 1; fire_removed(TR, AMMO)")
    step(2)
    check(H.eval("count(AMMO)") == 1, "the host's body loses what guest 1 took (%d)" % H.eval("count(AMMO)"))
    check(G2.eval("count(AMMO)") == 1, "guest 2's corpse loses it too (%d)" % G2.eval("count(AMMO)"))
    check(G1.eval("#TAKEN") == 0, "no echo back to guest 1")
    # the 4 s re-check of the death list must not bring the looted ammo back
    step(16)
    check(G1.eval("count(AMMO)") == 1 and G2.eval("count(AMMO)") == 1,
          "re-applying the host's list after a take brings nothing back (g1 %d, g2 %d)" % (G1.eval("count(AMMO)"), G2.eval("count(AMMO)")))
    # the host loots the last one: hooks fire in both host copies, each guest hears it once
    H.execute("STOCK[1].count = 0; fire_removed(TR, AMMO)")
    step(2)
    check(G1.eval("count(AMMO)") == 0 and G2.eval("count(AMMO)") == 0, "the host's own take reaches both guests")
    check(G2.eval("#TAKEN") == 2, "guest 2 applied each take once (%d)" % G2.eval("#TAKEN"))
    # guest 2 takes the gun
    G2.execute("STOCK[2].count = 0; fire_removed(TR, GUN)")
    step(3)
    check(H.eval("count(GUN)") == 0 and G1.eval("count(GUN)") == 0, "guest 2's take reaches the host and guest 1")
    step(16)
    check(G2.eval("count(GUN)") == 0 and G1.eval("count(GUN)") == 0, "and stays taken")


def corpse_looted_at_the_same_moment_keeps_one_copy():
    print("corpse_looted_at_the_same_moment_keeps_one_copy")
    H = lua()
    H.execute(CORPSE_FAKES + r"""
        STOCK = { { uid = "h1", da = AMMO, count = 3 } }
        main = require("mirror.corpses")
        main.init({}, ROLE, zfake(7), SESSION)
        ALL = { main }
        function tick() T = T + 0.3; main.tick(0.3) end
    """, "host")
    G = lua()
    G.execute(CORPSE_FAKES + r"""
        STOCK = {}
        ZF = zfake(7)
        PCI = obj({})
        INV = {}
        package.loaded["mirror.game"] = { player = function() return obj({ BP_JigMultiplayer = PCI }) end, on_world_reset = function() end }
        corpses = require("mirror.corpses")
        corpses.init({}, "guest", ZF, SESSION)
        local jg = package.loaded["mirror.jig"]
        local inner = jg.contents_of
        jg.contents_of = function(c) if c == PCI then return INV end return inner(c) end
        GAVE = {}
        jg.take = function(c, uid, n, total) GAVE[#GAVE + 1] = uid .. ":" .. n; return c == PCI end
        function tick() T = T + 0.3; if DEAD then ZF._copy.dead_at = ZF._copy.dead_at or T end; corpses.tick(0.3) end
    """, "guest", 7)

    def step(n=1):
        for _ in range(n):
            H.execute("tick()")
            for k in list(H.eval("blobs_out").keys()):
                G.eval("blobs_in")[k] = H.eval("blobs_out")[k]
            G.execute("tick()")
            for k in list(G.eval("blobs_out").keys()):
                H.eval("blobs_in")[k] = G.eval("blobs_out")[k]

    step(4)
    H.execute("DEAD = true"); G.execute("DEAD = true")
    step(6)
    check(G.eval("count(AMMO)") == 3, "the guest's corpse holds the host's 3 ammo")
    # both loot all 3 before hearing of the other's take
    H.execute("STOCK[1].count = 0; fire_removed(TR, AMMO, 3)")
    G.execute('STOCK[1].count = 0; INV = { { uid = "p9", da = AMMO, count = 3 } }; fire_removed(TR, AMMO, 3)')
    step(4)
    check(G.eval("GAVE[1]") == "p9:3", "the host had none left: the guest gives its 3 back (%s)" % G.eval("GAVE[1]"))
    check(G.eval("#GAVE") == 1, "...once")


def corpse_partial_takes_at_the_same_moment_keep_the_total():
    # T10 audit 2026-10-31: body of 5, the host takes 1 and the guest 2 before hearing of the other. The host went
    # down to the guest's "left 3", keeping its own take on the body too: 3 left of 5 - 1 - 2, one copied.
    print("corpse_partial_takes_at_the_same_moment_keep_the_total")
    H = lua()
    H.execute(CORPSE_FAKES + r"""
        STOCK = { { uid = "h1", da = AMMO, count = 5 } }
        main = require("mirror.corpses")
        main.init({}, ROLE, zfake(7), SESSION)
        ALL = { main }
        function tick() T = T + 0.3; main.tick(0.3) end
    """, "host")
    G = lua()
    G.execute(CORPSE_FAKES + r"""
        STOCK = {}
        ZF = zfake(7)
        PCI = obj({})
        INV = {}
        package.loaded["mirror.game"] = { player = function() return obj({ BP_JigMultiplayer = PCI }) end, on_world_reset = function() end }
        corpses = require("mirror.corpses")
        corpses.init({}, "guest", ZF, SESSION)
        local jg = package.loaded["mirror.jig"]
        local inner = jg.contents_of
        jg.contents_of = function(c) if c == PCI then return INV end return inner(c) end
        GAVE = {}
        jg.take = function(c, uid, n, total) GAVE[#GAVE + 1] = uid .. ":" .. n; return c == PCI end
        function tick() T = T + 0.3; if DEAD then ZF._copy.dead_at = ZF._copy.dead_at or T end; corpses.tick(0.3) end
    """, "guest", 7)

    def step(n=1):
        for _ in range(n):
            H.execute("tick()")
            for k in list(H.eval("blobs_out").keys()):
                G.eval("blobs_in")[k] = H.eval("blobs_out")[k]
            G.execute("tick()")
            for k in list(G.eval("blobs_out").keys()):
                H.eval("blobs_in")[k] = G.eval("blobs_out")[k]

    step(4)
    H.execute("DEAD = true"); G.execute("DEAD = true")
    step(6)
    check(G.eval("count(AMMO)") == 5, "the guest's corpse holds the host's 5 ammo (%d)" % G.eval("count(AMMO)"))
    H.execute("STOCK[1].count = 4; fire_removed(TR, AMMO, 1)")
    G.execute('STOCK[1].count = 3; INV = { { uid = "p9", da = AMMO, count = 2 } }; fire_removed(TR, AMMO, 2)')
    step(4)
    check(H.eval("count(AMMO)") == 2, "host: 5 - 1 - 2 leaves 2 on the body (%d)" % H.eval("count(AMMO)"))
    check(G.eval("#GAVE") == 0, "the host had enough: the guest gives nothing back (%d)" % G.eval("#GAVE"))


def link_reads_only_blobs_the_index_says_changed():
    print("link_reads_only_blobs_the_index_says_changed")
    import tempfile
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "SurrounDead"))

    def put(name, *lines):
        with open(os.path.join(d, "SurrounDead", "mirror_%s_host.txt" % name), "wb") as f:
            f.write("".join(l + "\r\n" for l in lines).encode())
    L = lua()
    L.execute('local d = ...; T = 0; os.clock = function() return T end; os.getenv = function() return d end', d)
    L.execute('lf = require("mirror.link_file"); lf.configure({}); lf.open("guest")'
              '; OPENS = 0; local o = io.open; io.open = function(p, m) if p:find("zombies") then OPENS = OPENS + 1 end; return o(p, m) end'
              '; function get(n) T = T + 0.01; return lf.get_blob(n) end')
    put("zombies", "A", "END")
    check(L.eval('get("zombies")') == "A", "without an index (older bridge) blobs are polled as before")
    put("index", "v1 5", "zombies 1", "END")
    L.execute('OPENS = 0')
    check(L.eval('get("zombies")') is None and L.eval('OPENS') == 1, "first indexed read re-checks once, same text gives nothing")
    L.execute('T = T + 1; OPENS = 0; for i = 1, 20 do get("zombies") end')
    check(L.eval('OPENS') == 1, "an unchanged counter never opens the blob again (opened %s times in 20 frames)" % L.eval('OPENS'))
    L.execute('T = T + 1; OPENS = 0; for i = 1, 20 do get("zombies") end')
    check(L.eval('OPENS') == 0, "...once settled, zero opens per frame")
    put("zombies", "B", "END"); put("index", "v1 5", "zombies 2", "END")
    check(L.eval('get("zombies")') == "B", "a bumped counter delivers the new blob on the next frame")
    put("index", "v1 5", "zombies 3", "END")
    check(L.eval('get("zombies")') is None, "counter ahead of a not-yet-written file: nothing yet")
    put("zombies", "C", "END")
    check(L.eval('get("zombies")') == "C", "...and the blob arrives once it's on disk")
    L.execute('lf.reset_blob("zombies")')
    check(L.eval('get("zombies")') == "C", "reset_blob delivers the current blob again")
    put("zombies", "D", "END"); put("index", "v1 9", "zombies 1", "END")
    check(L.eval('get("zombies")') == "D", "a restarted bridge (new run id, counters from 1) is followed")
    shutil.rmtree(d, ignore_errors=True)


def host_settled_corpses_cost_almost_nothing():
    print("host_settled_corpses_cost_almost_nothing")
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.game"] = { player = function() return nil end, world = function() return nil end,
                                          on_world_reset = function() end, keybind = function() end }
        package.loaded["mirror.ghost"] = { get = function() return nil end, is = function() return false end,
                                           location = function() return { X = 0, Y = 0, Z = 0 } end }
        package.loaded["mirror.loader"] = { want = function() end }
        package.loaded["mirror.invdiag"] = { summary = function() return "-" end }
        CALLS = 0
        local function counted(t)
            for k, v in pairs(t) do
                if type(v) == "function" then t[k] = function(...) CALLS = CALLS + 1; return v(...) end end
            end
            return t
        end
        local MZ = cls("BP_MasterZombie_C")
        StaticFindObject = function(p) if p:find("BP_MasterZombie", 1, true) then return MZ end end
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        LIST = {}
        FindAllOf = function(c) if c == "Character" then return LIST end end
        zombies = require("mirror.zombies")
        function zombie(name, x)
            local z
            local mesh = counted({ IsBoneHiddenByName = function() return false end,
                                   GetSkinnedAsset = function() return nil end, GetMaterial = function() return nil end,
                                   K2_GetComponentLocation = function() return { X = x, Y = 0, Z = 0 } end,
                                   GetAnimInstance = function() return nil end })
            z = obj(counted({ Mesh = mesh, DamageComponent = {}, bHidden = false,
                      IsA = function(self, c) return c == MZ end,
                      GetFName = function() return { ToString = function() return name end } end,
                      GetClass = function() return cls("BP_Zombie_Roamer_C") end,
                      K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end,
                      K2_GetActorRotation = function() return { Yaw = 90 } end,
                      GetVelocity = function() return { X = 0, Y = 0, Z = 0 } end,
                      GetCurrentMontage = function() return nil end,
                      IsActorBeingDestroyed = function() return false end }))
            return z
        end
        CFG = { zombies = { enabled = true, radius = 15000, send_hz = 15 } }
        function send() zombies._host.tick(CFG, 0.1); return blobs_out.zombies end
    """)
    L.execute('A, D = zombie("Alive", 100), zombie("Dead", 200); LIST = { A, D }')
    L.execute('send(); CALLS = 0; send()')
    both = L.eval('CALLS')
    L.execute('D["IsDead?"] = true; send(); for i = 1, 40 do send() end; CALLS = 0; snap = send()')
    with_corpse = L.eval('CALLS')
    snap = L.eval('snap')
    check(with_corpse <= both * 0.75, "a settled corpse skips most game calls (%d calls with 2 alive, %d with 1 alive + 1 corpse)" % (both, with_corpse))
    zl = [l for l in snap.split("\n") if l.startswith("Z ")]
    check(len(zl) == 2 and any(l.endswith(" 1") and " 200.0 " in l for l in zl),
          "the corpse is still in the snapshot, dead, at its place (%s)" % zl)
    L.execute('D.bHidden = true; snap = send()')
    check(len([l for l in L.eval('snap').split("\n") if l.startswith("Z ")]) == 1, "a corpse the game hides drops out at once")


def standing_hooks_skip_the_lookup():
    # StaticFindObject costs ~1.7 ms in-game: a hook whose function is still alive must not be looked up again
    print("standing_hooks_skip_the_lookup")
    L = lua()
    L.execute(FAKES + r"""
        NOW = 0; os.clock = function() return NOW end
        util = require("mirror.util")
        util.hook = function() return true end
        LOOKS = 0
        local fns = {}
        StaticFindObject = function(p)
            LOOKS = LOOKS + 1
            if p:find("Gone", 1, true) then return nil end
            fns[p] = fns[p] or obj({ GetFName = function() return { ToString = function() return p:match("([^:]+)$") end } end })
            return fns[p]
        end
        function frame(secs) NOW = NOW + (secs or 0.016); util.new_frame() end
        local P = "/Game/A.A_C:Fire"
        frame(); R1 = util.ensure_hook(P, print)
        local first = LOOKS
        for i = 1, 10 do frame(20) ; util.ensure_hook(P, print) end
        R2 = LOOKS - first
        fns[P].IsValid = function() return false end   -- class reloaded: the old function is gone
        fns[P] = nil
        frame(20); R3 = util.ensure_hook(P, print)
        R4 = LOOKS - first
    """)
    check(L.eval("R1") is True, "hooks the first time")
    check(L.eval("R2") == 0, "a standing hook is not looked up again (looked up %s times)" % L.eval("R2"))
    check(L.eval("R3") is True and L.eval("R4") == 1, "a gone function is looked up and hooked again")


SPLIT_FAKES = r"""
    local role = ...
    package.loaded["mirror.link"].reset_blob = function(n) RESET = n end
    SPLIT, FIGHT, NEAR, SETTING, GUEST, INWORLD, SAVING, NEST, HORDE = false, false, 1e9, true, true, true, false, 1e9, false
    GHOST, INV, AI = true, 0, 40
    GL, HL = { X = 0, Y = 0, Z = 0 }, { X = 0, Y = 0, Z = 0 }
    package.loaded["mirror.zombies"] = { set_split = function(on) SPLIT = on end, is_split = function() return SPLIT end, is_follow = function() return FOLLOW == true end, set_follow = function(on) FOLLOW = on end,
        guest_busy = function() return FIGHT end, near_guest = function() return NEAR, 0.5 end, own_count = function() return 7 end,
        -- hand-over: HANDOVER_TICKS guest ticks until every copy is taken over (0 = none to take)
        begin_handover = function() HANDED = (HANDED or 0) + 1; HANDING = HANDOVER_TICKS or 0 end,
        handing = function() return (HANDING or 0) > 0 end,
        handover_done = function() if (HANDING or 0) > 0 then HANDING = HANDING - 1 end; return (HANDING or 0) == 0 end,
        cancel_handover = function() CANCELLED = (CANCELLED or 0) + 1; HANDING = 0 end,
        taking_over = function() return TAKEOVER == true end,
        -- hand-back: the host spawns what the guest offers (TAKE_TICKS evaluations), then merges with "H key id"
        begin_taking = function() TAKING = TAKE_TICKS or 0; TAKES = (TAKES or 0) + 1 end,
        take_offer = function(body) OFFERS_SEEN = (OFFERS_SEEN or 0) + 1 end,
        taking_done = function() if (TAKING or 0) > 0 then TAKING = TAKING - 1 end; return (TAKING or 0) == 0 end,
        bind_taken = function() local m = BIND or ""; BIND = nil; return m end,
        cancel_taking = function() TAKE_CANCELLED = (TAKE_CANCELLED or 0) + 1 end,
        begin_handback = function(e) OFFERING = e end,
        finish_handback = function(body) FINISHED = body end,
        cancel_handback = function() OFFERING = nil end }
    package.loaded["mirror.ghost"] = { exists = function() return GHOST end, location = function() return GHOST and GL or nil end,
        set_invoker = function(on) INV = on and 0 or -1; return INV end, invoker_index = function() return INV end,
        ai_count = function() return AI end }
    package.loaded["mirror.game"] = { player = function() return { K2_GetActorLocation = function() return HL end } end,
                                      on_world_reset = function() end }
    package.loaded["mirror.hostrules"] = { mine = function() return SETTING end }
    package.loaded["mirror.save_guard"] = { busy = function() return SAVING end }
    package.loaded["mirror.infest"] = { guest_hit_age = function() return NEST end }
    package.loaded["mirror.horde"] = { active_near = function() return HORDE end }
    util = require("mirror.util")
    split = require("mirror.split")
    CFG = { zombies = { split = { split_radius = 40000, split_after = 10.0, merge_radius = 30000, merge_after = 3.0, force_radius = 20000,
        quiet_radius = 6000, ack_timeout = 10.0, retry_after = 30.0, horde_radius = 25000, nest_hit_s = 90.0 } } }
    REVIVED, TP_OPEN = math.huge, false
    split.init(CFG, role, { guest_in_world = function() return GUEST end, in_world = function() return INWORLD end },
        function() return REVIVED end, function() return TP_OPEN end)
    function run(secs) for i = 1, math.floor(secs * 10 + 0.5) do split.tick(0.1) end end
"""


def group_split_host_decides_follow_and_ignores_followers():
    print("group_split_host_decides_follow_and_ignores_followers")
    PEERS = r"""
        local _, me = ...
        OTHERS = {}
        package.loaded["mirror.peers"] = { slot_of = function() return me end, my_slot = function() return 0 end,
            each = function(name, fn) fn(require(name)); for _, m in ipairs(OTHERS) do fn(m, { slot = m.slot() }) end end }
        function other(slot, st, loc, lead)
            return { slot = function() return slot end, host_state = function() return st[1] end,
                     ghost_loc = function() return loc end, lead_slot = function() return lead end }
        end
    """
    # host copy for the guest in slot 3, 500 m from the host, 20 m from the split guest in slot 2
    H = lua()
    H.execute(FAKES + PEERS + SPLIT_FAKES, "host", 3)
    H.execute('LST = { "split" }; OTHERS = { other(2, LST, { X = 52000, Y = 0, Z = 0 }) }; GL = { X = 50000, Y = 0, Z = 0 }; run(1.1)')
    check(H.eval('split.host_state()') == "asking" and H.eval('blobs_out.p8') == "f 1 2",
          "far from the host, next to a split guest with a lower slot: asks to follow it")
    check(H.eval('INV') == 0, "the host keeps the AI there until the guest confirms")
    H.execute('blobs_in.p8g = "f 1 0"; run(0.3)')
    check(H.eval('split.host_state()') == "following" and H.eval('INV') == -1 and H.eval('SPLIT') is True,
          "confirmed: ghost out of the optimizer, no snapshots")
    H.execute('run(5)')
    check(H.eval('split.host_state()') == "following", "the leader next to it doesn't merge it")
    H.execute('LST[1] = "merged"; run(1.1)')
    check(H.eval('split.host_state()') == "merged" and H.eval('INV') == 0 and H.eval('blobs_out.p8') == "m 2",
          "the leader merged: the follower goes back to the host's AI")
    # the leader's copy (slot 2): its follower next to it doesn't count as "another player near"
    A = lua()
    A.execute(FAKES + PEERS + SPLIT_FAKES, "host", 2)
    A.execute('GL = { X = 50000, Y = 0, Z = 0 }; run(12); blobs_in.p8g = "s 1 0"; run(0.5)')
    check(A.eval('split.host_state()') == "split", "leader split on its own")
    A.execute('OTHERS = { other(3, { "following" }, { X = 50500, Y = 0, Z = 0 }, 2) }; run(3)')
    check(A.eval('split.host_state()') == "split", "its follower 5 m away: still split")
    A.execute('OTHERS = { other(3, { "merged" }, { X = 50500, Y = 0, Z = 0 }, nil) }; run(3)')
    check(A.eval('split.host_state()') == "split", "a higher slot next to it, far from the host, not following yet: still split (it follows next)")
    A.execute('OTHERS = { other(1, { "merged" }, { X = 50500, Y = 0, Z = 0 }, nil) }; run(1.1)')
    ep = (A.eval('blobs_out.p8') or "").split(" ")[-1]
    check(A.eval('split.host_state()') == "merging", "a lower slot next to it that isn't following: merge (hand-back asked first)")
    A.execute('blobs_in.p8h = "%s\\nA 1 x"; run(0.3)' % ep)
    check(A.eval('split.host_state()') == "merged", "... merged once the zombies are handed back")
    # two guests together far from the host (live 2026-10-30: slots 1 and 2 at 6-70 m, host 700+ m: never split)
    B = lua()
    B.execute(FAKES + PEERS + SPLIT_FAKES, "host", 1)
    B.execute('OTHERS = { other(2, { "merged" }, { X = 50500, Y = 0, Z = 0 }, nil) }; GL = { X = 50000, Y = 0, Z = 0 }; run(12)')
    check(B.eval('split.host_state()') == "splitting", "the lower slot of two guests together far from the host splits (the other follows it)")
    B.execute('OTHERS = { other(2, { "merged" }, { X = 20000, Y = 0, Z = 0 }, nil) }; blobs_in.p8g = "s 1 0"; run(0.5)')
    check(B.eval('split.host_state()') == "merged", "... but not for one near the host: that one counts (merge)")
    # the other guest never follows (blocked, no answer): after a while it counts again - both share the host's AI
    C = lua()
    C.execute(FAKES + PEERS + SPLIT_FAKES, "host", 1)
    C.execute('OTHERS = { other(2, { "merged" }, { X = 50500, Y = 0, Z = 0 }, nil) }; GL = { X = 50000, Y = 0, Z = 0 }; run(12); '
              'blobs_in.p8g = "s 1 0"; run(0.5)')
    check(C.eval('split.host_state()') == "split", "split, the other guest asked to follow it")
    C.execute('run(45)')
    ep = (C.eval('blobs_out.p8') or "").split(" ")[-1]
    check(C.eval('split.host_state()') == "merging", "it never followed: merge after a while, not each with its own zombies (%s)" % C.eval('split.host_state()'))


POWER_FAKES = r"""
    OUT, INBOX = {}, {}
    package.loaded["mirror.events"] = { reliable = function() return {
        send = function(self, m) OUT[#OUT + 1] = m end,
        pump = function(self, fn) local q = INBOX; INBOX = {}; for _, m in ipairs(q) do fn(m) end end } end }
    PLAYER = obj({}); PLAYER.K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end
    package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end }
    function turret(x)
        local t = obj({ ["PoweredOn?"] = true, cls = "Buildable_Turret_C", calls = 0 })
        t.K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end
        t["Power On"] = function(self, who) self["PoweredOn?"] = true; self.calls = self.calls + 1 end
        t["Power Off"] = function(self, who) self["PoweredOn?"] = false; self.calls = self.calls + 1 end
        return t
    end
    util = require("mirror.util")
    LIST = {}
    util.instances = function(cls, hooks, group) HOOKS_SEEN = HOOKS_SEEN or {}; HOOKS_SEEN[cls] = { hooks = hooks, group = group }
        return LIST[cls] or {}, true end
    util.class_name = function(o) return o.cls end
    power = require("mirror.power")
    -- (the echo window is real time: os.clock goes with the ticks here)
    CLOCK = 0; os.clock = function() return CLOCK end
    function run(s) for i = 1, math.floor(s * 10) do CLOCK = CLOCK + 0.1; power.tick(0.1) end end
"""


def a_turret_switched_off_is_off_for_everyone():
    # player report 2026-10-31: "Turret needs to be disabled by all players, dosent sync"
    print("a_turret_switched_off_is_off_for_everyone")
    H, G = lua(), lua()
    for L, role in ((H, "host"), (G, "guest")):
        L.execute(FAKES + POWER_FAKES)
        L.execute('T = turret(1000); LIST["Buildable_Turret_C"] = { T }; '
                  'power.init({}, %r, { in_world = function() return true end }); run(14)' % role)
    check(H.eval('HOOKS_SEEN["Buildable_Turret_C"].group') == "Buildable_TurretMASTER_C"
          and H.eval('HOOKS_SEEN["Buildable_SmallTurret_C"].group') == "Buildable_TurretMASTER_C",
          "both turret classes are found in one walk of their master")
    check(H.eval('#OUT') == 0, "a turret left as it is sends nothing")
    H.execute('T["PoweredOn?"] = false; run(1)')
    sent = list(H.eval('OUT').values())
    check(len(sent) == 1 and sent[0].startswith("S Buildable_Turret_C@100,0,0 t 0"), "switched off on one game: sent (%r)" % sent)
    G.execute('INBOX = { %r }; run(0.2)' % sent[0])
    check(G.eval('T["PoweredOn?"]') is False and G.eval('T.calls') == 1, "...and switched off on the other's copy")
    G.execute('run(3)')
    check(G.eval('#OUT') == 0, "...without being sent back")
    G.execute('T["PoweredOn?"] = true; run(1)')
    back = list(G.eval('OUT').values())
    check(len(back) == 1 and " t 1 " in back[0], "the guest switching it on again is sent to the host (%r)" % back)
    H.execute('INBOX = { %r }; run(0.2)' % back[0])
    check(H.eval('T["PoweredOn?"]') is True, "...and the host's turret is on again")


def a_teleport_landing_lets_off_the_first_hits():
    # live 2026-10-30 02:28:59: teleported into a fight, dead 4 s later (zombies.lua lets the hits off, see
    # a_host_zombie_hit_reaches_a_guest_with_three_players)
    print("a_teleport_landing_lets_off_the_first_hits")
    L = lua()
    L.execute(FAKES + r"""
        INBOX, SENT = {}, {}
        package.loaded["mirror.events"] = { new = function() return {
            send = function(self, m) SENT[#SENT + 1] = m end,
            pump = function(self, fn) local q = INBOX; INBOX = {}; for _, m in ipairs(q) do fn(m) end end } end }
        package.loaded["mirror.notify"] = { show = function() end }
        package.loaded["mirror.hostrules"] = { get = function() return true end }
        package.loaded["mirror.vehicles"] = { busy = function() return nil end }
        package.loaded["mirror.link"].peer_name = function() return "Friend" end
        PLAYER = obj({ at = { X = 0, Y = 0, Z = 0 } })
        PLAYER.K2_GetActorLocation = function() return PLAYER.at end
        PLAYER.K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end
        PLAYER.K2_TeleportTo = function(self, to) PLAYER.at = to; return true end
        GHOST = obj({}); GHOST.K2_GetActorLocation = function() return { X = 50000, Y = 0, Z = 0 } end
        package.loaded["mirror.ghost"] = { get = function() return GHOST end,
            location = function() return { X = 50000, Y = 0, Z = 0 } end }
        package.loaded["mirror.game"] = { player = function() return PLAYER end, on_world_reset = function() end }
        util = require("mirror.util")
        util.cdo = function() return { LineTraceSingle = function(self, p, a, b, _, _, _, _, out)
            out.OutHit = { ImpactPoint = { X = a.X, Y = a.Y, Z = 0 } }; return true end } end
        tp = require("mirror.teleport")
        ARR = require("mirror.peers").shared_table("arrival")
        BEFORE = ARR.safe_until
        tp.command("/goto")
        INBOX = { "A" }; tp.tick(0.1)
        LEFT = (ARR.safe_until or 0) - os.clock()
    """)
    check(L.eval('PLAYER.at.X') > 49000, "the player landed next to the other one (%s)" % L.eval('PLAYER.at.X'))
    # (a clock difference: 3.0000000000000004 failed it once)
    check(L.eval('BEFORE') is None and 2.5 < L.eval('LEFT') <= 3.0 + 1e-9,
          "...and the host's zombies' hits are let off for the next 3 s (%s)" % L.eval('LEFT'))


def load_split_waits_after_a_respawn_and_for_a_teleport():
    # live 2026-10-30: respawn 02:28:40, split 02:28:51, teleport asked 02:28:53, merged 02:29:00
    print("load_split_waits_after_a_respawn_and_for_a_teleport")
    H = lua()
    H.execute(FAKES + SPLIT_FAKES, "host")
    H.execute('SETTING = true; GL = { X = 50000, Y = 0, Z = 0 }; REVIVED = 0; run(12)')
    check(H.eval('split.state()') == "merged", "a guest that just respawned far away isn't split")
    H.execute('REVIVED = 15; run(4)')
    check(H.eval('split.state()') == "merged", "...still within 20 s of the respawn")
    H.execute('REVIVED = math.huge; TP_OPEN = true; run(15)')
    check(H.eval('split.state()') == "merged", "a teleport open between them: no split")
    H.execute('TP_OPEN = false; run(9)')
    check(H.eval('split.state()') == "merged", "after it: split_after counts from there")
    H.execute('run(3)')
    check(H.eval('split.state()') == "splitting", "...then the split is asked as usual")
    H.execute('blobs_in.p8g = "s 1 0"; run(0.3)')
    check(H.eval('split.state()') == "split", "split")
    H.execute('REVIVED = 0; TP_OPEN = true; run(5)')
    check(H.eval('split.state()') == "split", "a split already on isn't ended by either")


def load_split_switches_only_when_both_agree():
    print("load_split_switches_only_when_both_agree")
    H, G = lua(), lua()
    H.execute(FAKES + SPLIT_FAKES, "host")
    G.execute(FAKES + SPLIT_FAKES, "guest")
    def to_guest():
        b = H.eval('blobs_out.p8')
        if b is not None: G.execute('blobs_in.p8 = %r' % b)
    def to_host():
        b = G.eval('blobs_out.p8g')
        if b is not None: H.execute('blobs_in.p8g = %r' % b)
    def handshake():
        to_guest(); G.execute('run(0.6)'); to_host(); H.execute('run(0.3)')
    H.execute('SETTING = false; GL = { X = 50000, Y = 0, Z = 0 }; run(60)')
    check(H.eval('split.state()') == "merged" and H.eval('INV') == 0, "setting off: the host keeps running everything (no split)")
    H.execute('SETTING = true; run(9)')
    check(H.eval('split.state()') == "merged", "on, far apart: no split before split_after seconds")
    H.execute('run(3)')
    check(H.eval('split.state()') == "splitting" and H.eval('blobs_out.p8') == "s 1" and H.eval('INV') == 0,
          "then the host asks the guest first - its ghost still keeps the AI there")
    H.execute('run(11)')
    check(H.eval('split.state()') == "merged" and H.eval('INV') == 0 and H.eval('blobs_out.p8') == "m 2",
          "a guest that never answers (older version) -> stays merged")
    H.execute('run(20)')
    check(H.eval('split.state()') == "merged", "no new attempt before retry_after")
    H.execute('run(11)')
    check(H.eval('split.state()') == "splitting" and H.eval('blobs_out.p8') == "s 3", "retried later")
    to_guest(); G.execute('HANDOVER_TICKS = 2; run(0.6)')
    check(G.eval('HANDED') == 1 and G.eval('SPLIT') is False and G.eval('blobs_out.p8g') != "s 3 0",
          "guest: takes the host's zombies over first - no answer while that runs")
    G.execute('run(0.6)')
    check(G.eval('SPLIT') is True and G.eval('blobs_out.p8g') == "s 3 0" and G.eval('HANDED') == 1,
          "guest: then splits and answers with the epoch (one hand-over per epoch)")
    G.execute('HANDOVER_TICKS = 0')
    H.execute('blobs_in.p8g = "s 2 0"; run(0.3)')
    check(H.eval('split.state()') == "splitting", "host: an answer to an old epoch doesn't count")
    to_host(); H.execute('run(0.3)')
    check(H.eval('split.state()') == "split" and H.eval('INV') == -1 and H.eval('SPLIT') is True,
          "host: only on that answer the ghost leaves the optimizer and snapshots stop")
    H.execute('INV = 0; run(1.1)')
    check(H.eval('INV') == -1, "a ghost respawned after a save is taken out again")
    H.execute('SAVING = true; GHOST = false; run(3); SAVING = false; run(3)')
    check(H.eval('split.state()') == "split", "a save (ghost gone for a moment) doesn't merge")
    H.execute('GHOST = true; GL = { X = 35000, Y = 0, Z = 0 }; blobs_in.p8g = "s 3 1"; run(2)')
    check(H.eval('split.state()') == "split", "between merge_radius and split_radius: still split")
    H.execute('GL = { X = 25000, Y = 0, Z = 0 }; run(1.1); GL = { X = 35000, Y = 0, Z = 0 }; run(2); GL = { X = 25000, Y = 0, Z = 0 }; run(2.2)')
    check(H.eval('split.state()') == "split", "within merge_radius only briefly (a player driving by): still split")
    H.execute('run(2.2)')
    check(H.eval('split.state()') == "merging" and H.eval('INV') == -1 and H.eval('SPLIT') is True and H.eval('blobs_out.p8') == "M 4",
          "within merge_radius, even mid-fight: the host first asks for the guest's zombies (ghost still out)")
    to_guest(); G.execute('run(0.6)')
    check(G.eval('OFFERING') == 4 and G.eval('SPLIT') is True, "guest: offers its zombies and keeps running them meanwhile")
    H.execute('blobs_in.p8h = "3\\nA 1 old"; run(0.3)')
    check(H.eval('split.state()') == "merging" and H.eval('OFFERS_SEEN') is None, "host: an offer for another epoch doesn't count")
    H.execute('blobs_in.p8h = "4\\nA 1 x"; BIND = "H 1 77"; run(0.3)')
    check(H.eval('split.state()') == "merged" and H.eval('INV') == 0 and H.eval('SPLIT') is False
          and H.eval('blobs_out.p8') == "m 5\nH 1 77",
          "host: spawns the offered zombies, then merges with their ids - ghost back in the optimizer")
    to_guest(); G.execute('run(0.6)')
    check(G.eval('SPLIT') is False and G.eval('blobs_out.p8g') == "m 5 0" and G.eval('FINISHED') == "m 5\nH 1 77",
          "guest: follows the merge and gets the ids for its zombies")
    H.execute('GL = { X = 50000, Y = 0, Z = 0 }; run(12)'); handshake()
    H.execute('GL = { X = 25000, Y = 0, Z = 0 }; blobs_in.p8g = "s 6 0"; run(4.4)')
    check(H.eval('split.state()') == "merging", "closer again: hand-back asked")
    H.execute('GL = { X = 50000, Y = 0, Z = 0 }; run(0.3)')
    check(H.eval('split.state()') == "split" and H.eval('TAKE_CANCELLED') == 1 and H.eval('INV') == -1,
          "apart again before the hand-back finished: stays split, the spawned zombies go")
    H.execute('GL = { X = 15000, Y = 0, Z = 0 }; run(30)')
    check(H.eval('split.state()') == "merged", "a guest that never offers (older version): merged after the time-out")
    to_guest(); G.execute('run(0.6)')
    H.execute('GL = { X = 50000, Y = 0, Z = 0 }; run(12)'); handshake()
    check(H.eval('split.state()') == "split", "split again")
    H.execute('NEST = 0.2; split.tick(0.016)')
    check(H.eval('split.state()') == "merged" and H.eval('INV') == 0, "a guest hit on an infestation merges in the same frame")
    H.execute('NEST = 1e9; run(13)')
    check(H.eval('split.state()') == "splitting", "after the fight, splitting again")
    H.execute('HORDE = true; run(0.3)')
    check(H.eval('split.state()') == "merged", "a horde near the guest cancels the split")
    H.execute('HORDE = false; NEAR = 3000')
    for _ in range(80):          # (the link carries the blobs both ways all the time)
        H.execute('run(1)'); handshake()
        if H.eval('split.state()') == "split":
            break
    check(H.eval('split.state()') == "split" and G.eval('HANDED') >= 2,
          "zombies near the guest don't block a split: the guest takes them over first, then answers (%s, %s hand-overs)"
          % (H.eval('split.state()'), G.eval('HANDED')))
    H.execute('SETTING = false; run(0.2)')
    check(H.eval('split.state()') == "merged" and H.eval('INV') == 0, "setting turned off mid-split: merged at once")
    H.execute('SETTING = true; run(11)'); handshake()
    H.execute('GUEST = false; run(0.2)')
    check(H.eval('split.state()') == "merged" and H.eval('INV') == 0, "the guest leaves: merged at once")
    G.execute('INWORLD = false; run(0.2)')
    check(G.eval('RESET') == "p8", "guest out of the world: the host's state is read fresh on the next join")
    G.execute('SPLIT = false; INWORLD = true; blobs_in.p8 = "m 9"; run(0.6)')
    check(G.eval('blobs_out.p8g') == "m 9 0" and G.eval('SPLIT') is False, "guest: answers the host's epoch after a rejoin")
    # a Realm takeover in place runs its own hand-over: the old host's last "merged" must not call it off or merge
    G.execute('SPLIT = true; TAKEOVER = true; HANDING = 3; CANCELLED = 0; blobs_in.p8 = "m 10"; run(0.6)')
    check(G.eval('CANCELLED') == 0 and G.eval('SPLIT') is True and G.eval('HANDING') == 3,
          "guest taking a Realm over: split leaves the hand-over and the split alone")


def load_split_hands_the_ai_to_the_guest():
    print("load_split_hands_the_ai_to_the_guest")
    L = lua()
    L.execute(FAKES + r"""
        ME, HOST = { X = 0, Y = 0, Z = 0 }, { X = 90000, Y = 0, Z = 0 }
        package.loaded["mirror.game"] = { player = function() return { K2_GetActorLocation = function() return ME end } end,
            world = function() return nil end, on_world_reset = function() end, keybind = function() end }
        package.loaded["mirror.ghost"] = { get = function() return nil end, is = function() return false end,
                                           location = function() return HOST end }
        package.loaded["mirror.loader"] = { want = function() end }
        package.loaded["mirror.invdiag"] = { summary = function() return "-" end }
        local MZ = cls("BP_MasterZombie_C")
        StaticFindObject = function(p) if p:find("BP_MasterZombie", 1, true) then return MZ end end
        util = require("mirror.util")
        util.ensure_hook = function() return true end
        LIST, SPAWNERS = {}, {}
        FindAllOf = function(c) if c == "Character" then return LIST elseif c == "BP_AISpawner_Master_C" then return SPAWNERS end end
        util.instances = function(c) return c == "BP_AISpawner_Master_C" and SPAWNERS or {} end
        zombies = require("mirror.zombies")
        function zombie(name, x, dead)
            local z
            z = obj({ Mesh = { K2_GetComponentLocation = function() return { X = x, Y = 0, Z = 0 } end }, DamageComponent = {},
                      bHidden = false, ["IsDead?"] = dead or false, gone = false,
                      IsA = function(self, c) return c == MZ end,
                      GetFName = function() return { ToString = function() return name end } end,
                      GetClass = function() return cls("BP_Zombie_Roamer_C") end,
                      K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end,
                      K2_GetActorRotation = function() return { Yaw = 90 } end,
                      GetVelocity = function() return { X = 0, Y = 0, Z = 0 } end,
                      GetCurrentMontage = function() return nil end,
                      IsActorBeingDestroyed = function() return false end,
                      K2_DestroyActor = function(self) self.gone = true end })
            return z
        end
        function spawner() local s = obj({ IsSpawningStopped = false })
            s.SetIsSpawningStopped = function(self, v) self.IsSpawningStopped = v end; return s end
        CFG = { zombies = { enabled = true, radius = 15000, send_hz = 15, split = { drain_radius = 6000, drain_s = 90.0,
                corpse_radius = 15000, corpse_s = 300.0, host_near = 12000, quiet_radius = 6000 } } }
    """)
    # Host: the merged snapshot is unchanged (same Z/X lines as without the feature), and stops only while split.
    L.execute('HOST = ME; LIST = { zombie("Near", 4000), zombie("Far", 9000) }; snap0 = zombies._host.tick(CFG, 0.1); snap0 = blobs_out.zombies; '
              'd = zombies.near_guest()')
    check(abs(L.eval('d') - 4000) < 1, "host: the nearest AI to the guest is known from the snapshot scan")
    check(len([l for l in L.eval('snap0').split("\n") if l.startswith("Z ")]) == 2 and
          len([l for l in L.eval('snap0').split("\n") if l.startswith("X ")]) == 2,
          "host merged: zombies and their looks (X lines) are sent as before")
    L.execute('zombies._test.setup(CFG, "host"); zombies.set_split(true); blobs_out.zombies = nil; '
              'for i = 1, 20 do zombies._host.tick(CFG, 0.1) end')
    check(L.eval('blobs_out.zombies') is None, "host: no zombie snapshots while split")
    L.execute('zombies.set_split(false); for i = 1, 2 do zombies._host.tick(CFG, 0.1) end')
    check(L.eval('blobs_out.zombies') is not None, "host: snapshots resume on the merge")
    # Guest
    L.execute('HOST = { X = 90000, Y = 0, Z = 0 }; zombies._test.setup(CFG, "guest"); S1, S2 = spawner(), spawner(); S2.IsSpawningStopped = true; SPAWNERS = { S1, S2 }; '
              'LIST = {}; zombies._test.sweep(10)')
    check(L.eval('S1.IsSpawningStopped') is True, "guest merged: its spawners are stopped (as before)")
    L.execute('zombies.set_split(true); zombies._test.reenable()')
    check(L.eval('S1.IsSpawningStopped') is False and L.eval('S2.IsSpawningStopped') is True,
          "guest split: only the spawners the mod stopped run again")
    L.execute('A, B, C, D = zombie("Fighting", 3000), zombie("Away", 50000), zombie("Body", 10000, true), zombie("NearHost", 85000); '
              'LIST = { A, B, C, D }')
    check(L.eval('zombies.own_count()') == 4, "guest split: its own AI are counted")
    # (while split guest_tick runs no sweep at all - only the busy check)
    L.execute('zombies.set_split(false); zombies._test.sweep(10); zombies._test.sweep(10)')
    check(L.eval('A.gone') is False and L.eval('C.gone') is False, "guest merge: the zombie near me and the body stay (drain)")
    check(L.eval('B.gone') is True and L.eval('D.gone') is True, "guest merge: the others are removed")
    check(L.eval('S1.IsSpawningStopped') is True, "guest merge: spawners stopped again")
    L.execute('HOST = { X = 3500, Y = 0, Z = 0 }; zombies._test.sweep(10)')
    check(L.eval('A.gone') is True and L.eval('C.gone') is True, "guest: the host coming near ends the drain")
    L.execute('HOST = { X = 90000, Y = 0, Z = 0 }; zombies.set_split(true); E = zombie("Late", 2000); LIST = { E }; '
              'zombies.set_split(false); zombies._test.sweep(10); zombies._test.sweep(95)')
    check(L.eval('E.gone') is True, "guest: a kept zombie goes after drain_s")
    # join lag: ~1100 spawners and a batch of own zombies were one 110 ms frame every 2 s - now a slice per frame
    L.execute(r"""
        zombies.set_split(false); zombies._test.sweep(10)
        -- (spawner passes come every 10 s, native passes in between: start passes until one queues something)
        local function until_queued() for i = 1, 8 do zombies._test.start(10); if zombies._test.pending() > 0 then return end end end
        LIST = {}
        SPAWNERS = {}; for i = 1, 1100 do SPAWNERS[i] = spawner() end
        until_queued()
        FRAMES, MAXDONE, prev = 1, 0, 0
        local function stopped() local n = 0; for _, s in ipairs(SPAWNERS) do if s.IsSpawningStopped then n = n + 1 end end; return n end
        MAXDONE = stopped(); prev = MAXDONE
        while zombies._test.step() do FRAMES = FRAMES + 1; local n = stopped(); MAXDONE = math.max(MAXDONE, n - prev); prev = n end
        SP_ALL = stopped()
        SPAWNERS = {}
        LIST = {}; for i = 1, 10 do LIST[i] = zombie("Own" .. i, 100000) end
        until_queued()
        local gone = 0; for _, z in ipairs(LIST) do if z.gone then gone = gone + 1 end end
        FIRST_GONE = gone
        while zombies._test.step() do end
        ALL_GONE = 0; for _, z in ipairs(LIST) do if z.gone then ALL_GONE = ALL_GONE + 1 end end
        -- a split in the middle of a queue stops it: the spawners it didn't reach keep running
        LIST = {}
        SPAWNERS = {}; for i = 1, 600 do SPAWNERS[i] = spawner() end
        until_queued()
        QUEUED = zombies._test.pending()
        zombies.set_split(true); zombies._test.step()
        REENABLE_FRAMES = zombies._test.reenable(100)
        LEFT_ON = 0; for _, s in ipairs(SPAWNERS) do if not s.IsSpawningStopped then LEFT_ON = LEFT_ON + 1 end end
        AFTER_SPLIT = zombies._test.pending()
        zombies.set_split(false)
    """)
    check(L.eval('SP_ALL') == 1100 and L.eval('FRAMES') >= 7 and L.eval('MAXDONE') <= 150,
          "1100 spawners: all stopped over %d frames, at most 150 a frame (%d)" % (L.eval('FRAMES'), L.eval('MAXDONE')))
    check(L.eval('FIRST_GONE') <= 4 and L.eval('ALL_GONE') == 10,
          "own zombies: at most 4 removed a frame (%d), all 10 in the end" % L.eval('FIRST_GONE'))
    # (the split itself turns back on the 150 the first slice stopped)
    check(L.eval('QUEUED') == 450 and L.eval('AFTER_SPLIT') == 0 and L.eval('LEFT_ON') == 600,
          "a split mid-sweep drops the rest of it (%d queued, %d left after, %d of 600 on)"
          % (L.eval('QUEUED'), L.eval('AFTER_SPLIT'), L.eval('LEFT_ON')))
    check(L.eval('REENABLE_FRAMES') >= 2, "the split turns its spawners back on over frames (100 a frame, %d frames)"
          % L.eval('REENABLE_FRAMES'))
    # Realm takeover in place: hand-over first, then the stopped spawners and people's spawn volumes run again
    L.execute(r"""
        zombies.set_split(false); zombies._test.sweep(10)
        S3 = spawner(); RESTARTED = 0
        V1 = obj({ ["Stop Spawning"] = function(self) self.stopped = true end,
                   ["Restart Spawning"] = function(self) self.stopped = false; RESTARTED = RESTARTED + 1 end })
        SPAWNERS = { S3 }
        util.instances = function(c) if c == "BP_AISpawner_Master_C" then return SPAWNERS end
                                     if c == "BP_AISpawningVolume_Prefab_C" then return { V1 } end return {} end
        LIST = {}
        for i = 1, 6 do zombies._test.sweep(10) end   -- (spawners and volumes: every 5th pass)
        STOPPED_BEFORE = S3.IsSpawningStopped and V1.stopped
        zombies.begin_takeover()
        READY_FIRST = zombies.takeover_ready()
        zombies._test.handover()
        READY_AFTER_HANDOVER = zombies.takeover_ready()
        zombies._test.reenable(100)
        READY = zombies.takeover_ready()
        KEEP = zombies.taking_over()
        zombies.end_takeover()
    """)
    check(L.eval('STOPPED_BEFORE') is True, "guest merged: the sweep stopped a spawner and a spawn volume")
    check(L.eval('READY_FIRST') is False and L.eval('READY_AFTER_HANDOVER') is False and L.eval('READY') is True,
          "takeover: ready only once the hand-over is done and the spawners are back on")
    check(L.eval('S3.IsSpawningStopped') is False and L.eval('V1.stopped') is False and L.eval('RESTARTED') == 1,
          "takeover: the spawner runs again and the spawn volume restarted once")
    check(L.eval('KEEP') is True and L.eval('zombies.taking_over()') is False and L.eval('zombies.is_split()') is False,
          "takeover ends with no split state left for the host's code")
    # K3YBOARD32 2026-10-31: a takeover turned every stopped spawner on and the area the host had cleared filled
    # again. The ones whose SpawnRadius I stand in stay off until I'm out of their range.
    L.execute(r"""
        ME = { X = 0, Y = 0, Z = 0 }
        function HELD() return zombies._test.held and zombies._test.held() or -1 end   -- (Lua before the hold: no hook)
        zombies._test.setup(CFG, "guest"); zombies.set_split(false); zombies._test.sweep(10)
        function placed(s, x, r) s.SpawnRadius = r; s.K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end; return s end
        SN, SF = placed(spawner(), 1000, 10000), placed(spawner(), 50000, 5000)   -- (held within radius + 2000)
        RESTARTED = 0
        VN = placed(obj({ ["Stop Spawning"] = function(self) self.stopped = true end,
                         ["Restart Spawning"] = function(self) self.stopped = false; RESTARTED = RESTARTED + 1 end }), 3000, 4000)
        SPAWNERS = { SN, SF }
        util.instances = function(c) if c == "BP_AISpawner_Master_C" then return SPAWNERS end
                                     if c == "BP_AISpawningVolume_Prefab_C" then return { VN } end return {} end
        LIST = {}
        for i = 1, 6 do zombies._test.sweep(10) end
        T_STOPPED = SN.IsSpawningStopped and SF.IsSpawningStopped and VN.stopped
        zombies.begin_takeover(); zombies._test.handover(); zombies.takeover_ready(); zombies._test.reenable(100)
        T_READY = zombies.takeover_ready()
        T_NEAR_OFF, T_FAR_ON, T_VOL_OFF = SN.IsSpawningStopped, not SF.IsSpawningStopped, VN.stopped == true
        zombies._test.setup(CFG, "host"); zombies.end_takeover()
        T_HELD_STILL = HELD()          -- host, still in range
        ME = { X = 10000, Y = 0, Z = 0 }              -- 7000 from the volume (out of 4000 + 2000), 9000 from the spawner (in)
        T_HELD_MID = HELD()
        T_VOL_ON = VN.stopped == false and RESTARTED == 1
        ME = { X = 20000, Y = 0, Z = 0 }
        T_HELD_END = HELD()
        T_NEAR_ON = SN.IsSpawningStopped == false
        -- a guest split, then merged again before leaving the range: the held spawner is the mod's to hand back again
        ME = { X = 0, Y = 0, Z = 0 }
        zombies._test.setup(CFG, "guest"); SPAWNERS = { SN }; util.instances = function(c) return c == "BP_AISpawner_Master_C" and SPAWNERS or {} end
        zombies.set_split(false); for i = 1, 6 do zombies._test.sweep(10) end
        S_SWEPT = SN.IsSpawningStopped
        zombies.set_split(true); zombies._test.reenable(100)
        S_SPLIT_OFF = SN.IsSpawningStopped
        zombies.set_split(false)
        S_HELD = HELD()
        for i = 1, 6 do zombies._test.sweep(10) end   -- (it's off already: the sweep doesn't list it)
        zombies.set_split(true); zombies._test.reenable(100)
        ME = { X = 20000, Y = 0, Z = 0 }
        HELD()
        S_ON_AGAIN = SN.IsSpawningStopped == false
        zombies.set_split(false)
    """)
    check(L.eval('T_STOPPED') is True and L.eval('T_READY') is True, "hold: the sweep stopped them and the takeover is ready")
    check(L.eval('T_NEAR_OFF') is True and L.eval('T_VOL_OFF') is True and L.eval('T_FAR_ON') is True,
          "takeover: the spawner and spawn volume around me stay off, the far spawner goes on")
    check(L.eval('T_HELD_STILL') == 2, "takeover: as host, still in range, both stay held (%s)" % L.eval('T_HELD_STILL'))
    check(L.eval('T_HELD_MID') == 1 and L.eval('T_VOL_ON') is True,
          "takeover: out of the volume's range it restarts once, the spawner (still in range) stays held")
    check(L.eval('T_HELD_END') == 0 and L.eval('T_NEAR_ON') is True, "takeover: out of range the spawner goes on")
    check(L.eval('S_SWEPT') is True and L.eval('S_SPLIT_OFF') is True and L.eval('S_HELD') == 0 and L.eval('S_ON_AGAIN') is True,
          "split: a held spawner goes back to the mod's list on a merge and on again at the next split, out of range")

def a_looping_reload_stops_on_the_other_game():
    # user 2026-10-31: "the other players when reloading have a never ending reload animation". The shotgun's and
    # revolver's ReloadB montage loops (its section's next is itself) and the game ends it without MC_StopMontage.
    print("a_looping_reload_stops_on_the_other_game")
    L = lua()
    L.execute(FAKES + r"""
        CLOCK = 0; os.clock = function() return CLOCK end
        HOOKS, PLAYING, GSTOP = {}, {}, {}
        ME = obj({ Mesh = { GetAnimInstance = function() return { Montage_IsPlaying = function(self, m) return PLAYING[m] == true end } end } })
        G = obj({ StopAnimMontage = function(self, m) GSTOP[#GSTOP + 1] = m end })
        package.loaded["mirror.game"] = { player = function() return ME end, player_hook = function(n, fn) HOOKS[n] = fn end }
        package.loaded["mirror.ghost"] = { is = function() return false end, get = function() return G end }
        package.loaded["mirror.link"].peer_age = function() return 0 end
        util = require("mirror.util")
        function sections(list)
            return { ForEach = function(self, fn) for i, s in ipairs(list) do
                fn(i, { get = function() return { SectionName = { ToString = function() return s[1] end },
                                                   NextSectionName = { ToString = function() return s[2] end } } end }) end end }
        end
        function montage(name, len, secs)
            return obj({ GetFullName = function() return "AnimMontage /Game/Character/Anims/" .. name .. "." .. name end,
                         GetPlayLength = function() return len end, CompositeSections = sections(secs) })
        end
        LOOP = montage("Chr_AN_Shotgun_ReloadB_Anim_Montage", 1.0, { { "Default", "Default" } })
        ONCE = montage("Chr_Rifle_Reload_Hip_Montage", 2.0, { { "Default", "None" } })
        util.find = function(p) if p:find("ReloadB", 1, true) then return LOOP end return ONCE end
        anim = require("mirror.anim")
        anim.init({ ghost = { mirror_montages = true } })
        SELF = { get = function() return ME end }
        function play(m) HOOKS.MC_Montage(SELF, { get = function() return m end }, { get = function() return 1.0 end }) end
        function run(secs) local t = 0; while t < secs do CLOCK = CLOCK + 0.05; t = t + 0.05; anim.tick() end end
        function stops() local n = 0; for l in (blobs_out.anim or ""):gmatch("[^\n]+") do if l:find(" stop ", 1, true) then n = n + 1 end end; return n end
        play(LOOP); PLAYING[LOOP] = true; run(3.0)               -- three times round the loop
        LOOPING = stops()
        PLAYING[LOOP] = nil; run(0.2)                            -- the game ends it (no MC_StopMontage)
        LOOP_ENDED = stops()
        play(ONCE); PLAYING[ONCE] = true; run(1.95); PLAYING[ONCE] = nil; run(0.2)
        ONCE_ENDED = stops()                                     -- ran to its end: the other game's ends there too
        play(ONCE); PLAYING[ONCE] = true; run(0.5); PLAYING[ONCE] = nil; run(0.2)
        ONCE_CUT = stops()                                       -- cut short here
        play(LOOP); PLAYING[LOOP] = true; run(0.5)
        HOOKS.MC_StopMontage(SELF, { get = function() return LOOP end }); PLAYING[LOOP] = nil; run(0.5)
        EXPLICIT = stops()                                       -- the game's own stop: one line, not two
        play(ONCE); run(1.5)
        NEVER = stops()                                          -- never played here: nothing to stop
        blobs_in.anim = "9 1 " .. os.time() .. " stop /Game/Character/Anims/Chr_AN_Shotgun_ReloadB_Anim_Montage.Chr_AN_Shotgun_ReloadB_Anim_Montage 1.000"
        anim.tick()
    """)
    check(L.eval('LOOPING') == 0, "a looping reload still playing here sends no stop (%d)" % L.eval('LOOPING'))
    check(L.eval('LOOP_ENDED') == 1, "the looping reload ended by the game: a stop goes out (%d)" % L.eval('LOOP_ENDED'))
    check(L.eval('ONCE_ENDED') == 1, "a reload that ran to its end sends no stop (%d)" % L.eval('ONCE_ENDED'))
    check(L.eval('ONCE_CUT') == 2, "a reload cut short here sends a stop (%d)" % L.eval('ONCE_CUT'))
    check(L.eval('EXPLICIT') == 3, "the game's own stop is sent once (%d)" % L.eval('EXPLICIT'))
    check(L.eval('NEVER') == 3, "a montage that never played here sends no stop (%d)" % L.eval('NEVER'))
    check(L.eval('#GSTOP') == 1 and L.eval('GSTOP[1] == LOOP'), "the other game stops the looping montage on the player's character")

def reliable_events_survive_pauses_and_restarts():
    print("reliable_events_survive_pauses_and_restarts")
    def side(t0):
        L = lua()
        L.execute(FAKES + r"""
            T = ...; os.time = function() return math.floor(T) end
            CLOCK = 0; os.clock = function() return CLOCK end
            package.loaded["mirror.link"].peer_age = function(s) return os.time() - s end
            package.loaded["mirror.link"].same_clock = function() return true end
            events = require("mirror.events")
            ch = events.reliable("drops")
            plain = events.new("hits", 32, 3)
            GOT, GOTP = {}, {}
            function tick(dt)
                T = T + dt; CLOCK = CLOCK + dt
                ch:pump(function(p) GOT[#GOT + 1] = p end)
                plain:pump(function(p) GOTP[#GOTP + 1] = p end)
            end
        """, t0)
        return L
    def ship(a, b):
        out = a.eval('blobs_out')
        inn = b.eval('blobs_in')
        for k in list(out.keys()):
            inn[k] = out[k]
        a.execute('blobs_out = {}')
    A, B = side(1000), side(1000)
    def run(n, dt=0.25):
        for _ in range(n):
            A.execute('tick(%f)' % dt); B.execute('tick(%f)' % dt)
            ship(A, B); ship(B, A)
    A.execute('for i = 1, 40 do ch:send("I item" .. i) end; ch:send("T 1"); plain:send("hit")')
    A.execute('tick(0.25)'); ship(A, B)
    B.execute('T = T + 30')           # B sat in the ESC menu for 30 s
    run(4)
    check(B.eval('#GOT') == 41 and B.eval('GOT[41]') == "T 1", "a reliable message read after a 30 s pause is applied (41 of 41)")
    check(B.eval('#GOTP') == 0, "a plain (combat) message still expires")
    run(8)
    A.execute('ch:send("T 2")'); run(4)
    check(B.eval('GOT[42]') == "T 2" and B.eval('#GOT') == 42, "later messages still arrive once")
    check(A.eval('#ch.recent') <= 1, "acked messages are dropped from the sender's history")
    # (a guest that went home ends its link only when this is 0: a take the host never read would be a dupe)
    check(A.eval('events.unconfirmed()') == 0, "everything A sent is confirmed by B")
    A.execute('ch:send("T 3")')
    check(A.eval('events.unconfirmed()') == 1, "...a new message stays unconfirmed until B reads it")
    run(4)
    check(A.eval('events.unconfirmed()') == 0, "...and is confirmed once B has read it")
    C = side(1200)                     # B restarted: a fresh game must not replay the old session
    A.execute('ch.recent = { "1 7 900 T old" }; ch.ids = { { id = 7, t = 0 } }; ch.dirty = true')
    A.execute('tick(0.25)'); ship(A, C); C.execute('tick(0.25)')
    check(C.eval('#GOT') == 0, "a restarted game skips messages stamped before it started")
    # join: the guest holds the host's messages while loading and skips those before the host's join save
    A2, B2 = side(5000), side(5000)
    B2.execute('JOINING = true; events.set_hold(function() return JOINING end)')
    A2.execute('ch:send("D before"); T = T + 3'); A2.execute('tick(0.25)'); ship(A2, B2)
    A2.execute('events.set_cut(os.time()); CUT = os.time(); T = T + 1; ch:send("D after")')
    A2.execute('tick(0.25)'); ship(A2, B2)
    for _ in range(40):
        B2.execute('tick(0.25)')   # a 10 s load: nothing read yet
    check(B2.eval('#GOT') == 0, "nothing is applied while the guest loads in")
    B2.execute('events.set_cut(%d); JOINING = false; tick(0.25)' % A2.eval('CUT'))
    check(B2.eval('#GOT') == 1 and B2.eval('GOT[1]') == "D after",
          "after the load only the messages since the host's join save are applied")
    # nobody reads: the history shrinks to the small keep after a while instead of growing to 512
    A2.execute('for i = 1, 200 do ch:send("M x") end; CLOCK = CLOCK + 400; ch:send("M y")')
    check(A2.eval('#ch.recent') > 200, "7 min unread (a guest waiting for its host): every take is still kept (%d)" % A2.eval('#ch.recent'))
    A2.execute('CLOCK = CLOCK + 1500; ch:send("M z")')
    check(A2.eval('#ch.recent') == 64, "an unread history shrinks to the small keep after 30 min")
    # T10 audit 2026-10-31 (R2 #2): over Steam (whole seconds, 2 s clock slack) the guest's cut let host messages from
    # ~3 s before it through, and messages sent between the cut and the save's start are in the save too: both were
    # applied twice. The host's ids at the save's start decide instead.
    A3, B3 = side(7000), side(7000)
    for s in (A3, B3):
        s.execute('package.loaded["mirror.link"].peer_age = function(s) return os.time() - s - 2 end')
    B3.execute('JOINING = true; events.set_hold(function() return JOINING end)')
    A3.execute('ch:send("D old"); T = T + 1.5; events.set_cut(os.time()); CUT = os.time(); ch:send("D in save"); '
               'MARKS = events.marks(); T = T + 0.5; ch:send("D after"); tick(0.25)')
    ship(A3, B3)
    B3.execute('tick(0.25)')
    cut = 'os.time() - package.loaded["mirror.link"].peer_age(%d) - 2' % A3.eval('CUT')
    B3.execute('events.set_cut(%s, %s); JOINING = false; tick(0.25)' % (cut, repr(A3.eval('MARKS'))))
    check(B3.eval('#GOT') == 1 and B3.eval('GOT[1]') == "D after",
          "Steam join: only the host's messages after its save's start are applied (%s)"
          % [B3.eval('GOT[%d]' % (i + 1)) for i in range(B3.eval('#GOT'))])
    A3.execute('ch:send("D next"); tick(0.25)'); ship(A3, B3); B3.execute('tick(0.25)')
    check(B3.eval('#GOT') == 2 and B3.eval('GOT[2]') == "D next", "...and later ones still arrive")
    # an older host sends no marks: the time cut alone decides (and clears marks of an earlier join)
    B4 = side(7000)
    B4.execute('package.loaded["mirror.link"].peer_age = function(s) return os.time() - s - 2 end; '
               'events.set_cut(1, "drops 1 99"); events.set_cut(%d)' % A3.eval('CUT'))
    A3.execute('ch.dirty = true; tick(0.25)'); ship(A3, B4); B4.execute('tick(0.25)')
    check(B4.eval('#GOT') == 4 and B4.eval('GOT[1]') == "D old" and B4.eval('GOT[2]') == "D in save",
          "no marks (an older host): the time cut alone decides, an earlier join's marks are gone - and it lets the "
          "two messages already in the save through, the double apply the marks stop (%d)" % B4.eval('#GOT'))
    # T10 audit 2026-10-31: a give-back to the guest's bag ("G"/"L") is in no join save; sent between the join request
    # and the save start it was skipped with the rest, and the guest kept the duplicate. Fresh ones pass the cut.
    A5, B5 = side(9000), side(9000)
    B5.execute('JOINING = true; events.set_hold(function() return JOINING end); '
               'ch.past_cut = function(p) return p:sub(1, 2) == "G " end')
    A5.execute('ch:send("G stale"); T = T + 180; ch:send("G give back"); ch:send("D in save"); '
               'CUT = os.time(); MARKS = events.marks(); T = T + 0.5; ch:send("D after"); tick(0.25)')
    ship(A5, B5)
    B5.execute('T = T + 180.5; tick(0.25); events.set_cut(%d, %s); JOINING = false; tick(0.25)' % (A5.eval('CUT'), repr(A5.eval('MARKS'))))
    got = [B5.eval('GOT[%d]' % (i + 1)) for i in range(B5.eval('#GOT'))]
    check(got == ["G give back", "D after"],
          "join: a fresh give-back sent before the save start still reaches the guest, a 3 min old one and the "
          "save's own messages don't (%s)" % got)


def plain_events_skip_late_lines_and_bound_the_window():
    print("plain_events_skip_late_lines_and_bound_the_window")
    def side():
        L = lua()
        L.execute(FAKES + r"""
            T = 1000; os.time = function() return math.floor(T) end
            CLOCK = 0; os.clock = function() return CLOCK end
            local lk = package.loaded["mirror.link"]
            lk.peer_age = function(s) return os.time() - s - 2 end     -- Steam: whole seconds, 2 s clock slack
            local put = lk.put_blob
            PUTS, MAXL = 0, 0
            lk.put_blob = function(n, b)
                if n == "imp" then PUTS = PUTS + 1; MAXL = math.max(MAXL, select(2, b:gsub("\n", "")) + 1) end
                return put(n, b)
            end
            events = require("mirror.events")
            hits = events.new("hits", 32, 3)
            imp = events.new("imp", 200, 1)
            GOT, GOTI = {}, {}
            function tick(dt)
                T = T + dt; CLOCK = CLOCK + dt
                hits:pump(function(p) GOT[#GOT + 1] = p end)
                imp:pump(function(p) GOTI[#GOTI + 1] = p end)
            end
        """)
        return L
    def ship(a, b):
        out = a.eval('blobs_out')
        inn = b.eval('blobs_in')
        for k in list(out.keys()):
            inn[k] = out[k]
        a.execute('blobs_out = {}')
    A, B = side(), side()
    A.execute('hits:send("on time"); tick(0.1)'); ship(A, B); B.execute('tick(0.1)')
    check(B.eval('#GOT') == 1, "a hit read at once is applied")
    # a 4 s link stall: the line reaches B 4 s after it was sent (the whole-second check alone let it through)
    A.execute('hits:send("stalled"); tick(0.1)'); ship(A, B)
    B.execute('T = T + 4; CLOCK = CLOCK + 4'); A.execute('T = T + 4; CLOCK = CLOCK + 4')
    B.execute('tick(0.1)')
    check(B.eval('#GOT') == 1, "a hit read 4 s late is skipped (max_age 3) (%d applied)" % B.eval('#GOT'))
    A.execute('hits:send("after"); tick(0.1)'); ship(A, B); B.execute('tick(0.1)')
    check(B.eval('#GOT') == 2 and B.eval('GOT[2]') == "after", "the next hit after the stall is applied")
    # 25 messages a second for 10 s at 50 frames a second: the window holds ~1 s, at most 20 writes a second, none lost
    for i in range(500):
        if i % 2 == 0:
            A.execute('imp:send("i%d")' % (i // 2))
        A.execute('tick(0.02)'); ship(A, B); B.execute('tick(0.02)')
    A.execute('tick(0.1)'); ship(A, B); B.execute('tick(0.02)')
    got = B.eval('#GOTI')
    check(got == 250 and B.eval('GOTI[250]') == "i249" and B.eval('GOTI[1]') == "i0",
          "every one of 250 impacts arrives once, in order (%d)" % got)
    check(A.eval('MAXL') <= 28, "the window holds only the last second (max %d lines, was up to 200)" % A.eval('MAXL'))
    check(A.eval('PUTS') <= 205, "at most 20 writes a second (%d in 10 s, was one per message)" % A.eval('PUTS'))


def jig_price_follows_the_traders_table():
    print("jig_price_follows_the_traders_table")
    L = lua()
    L.execute(FAKES + r"""
        jig = require("mirror.jig")
        BOOK, AXE, CAN = obj({ Price = 40 }), obj({ Price = 25 }), obj({ Price = 3 })
        local function row(a, p) return { ItemID_41_8C5E69274AB445604263E4A2B3091BAD = a, PriceOverride_29_306CC4B441051ADD17999E8D00D06A7F = p } end
        local rows = { row(BOOK, 120.0), row(AXE, -1.0) }
        local arr = setmetatable({ GetArrayNum = function() return #rows end }, { __index = function(_, i) return rows[i] end })
        TRADER = { ContainersSettings = { { StartingItems_10_C6DB208442353E0AA9B5DB892266821A = arr } } }
        CRATE = {}
    """)
    check(L.eval('jig.price_in(TRADER, BOOK)') == 120.0, "a trader's table price is used (%s)" % L.eval('jig.price_in(TRADER, BOOK)'))
    check(L.eval('jig.price_in(TRADER, AXE)') == 25, "no override (-1): the item's own price")
    check(L.eval('jig.price_in(TRADER, CAN)') == 3, "an item not in the table: the item's own price")
    check(L.eval('jig.price_in(CRATE, BOOK)') == 40, "an ordinary container: the item's own price")


def jig_probe_names_what_a_patch_removed():
    print("jig_probe_names_what_a_patch_removed")
    SETUP = """
        local function fn(n) return { IsValid = function() return true end,
                                      GetFName = function() return { ToString = function() return n end } end } end
        GONE = {}
        StaticFindObject = function(p) local f = p:match(":(.+)$"); if GONE[f] then return nil end return fn(f) end
        local function arr(list) return { ForEach = function(self, cb) for i, v in ipairs(list) do cb(i, { get = function() return v end }) end end } end
        function inv(item)
            local c = { ReplicationUID_23_EB27D09649B6E02591DCA98708B06332 = {}, InContainerUID_24_D1504ED7438699C73EA046AD734E79BF = {},
                        ContainerIndex_22_9A211B86466A9D1C57E1FC839A5B0896 = 0,
                        ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B = arr(item and { item } or {}) }
            return { MainJigContainers = arr({ c }) }
        end
        function item()
            return { UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68 = {}, SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD = 3,
                     Rotated_9_3CFE5D9342A81FB1FF17DEB7B491CE56 = false,
                     ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7 = { ItemID_28_01CA27D84AF7D1014D9E2E83894C1848 = {},
                         Count_8_DD79AF2A46126A338C8DCCB4616D91CD = 1, Durability_22_A3557C454274D193D47AB9B71FB0C0CA = {} } }
        end
        jig = require("mirror.jig")
    """
    L = lua()
    L.execute(SETUP)
    check(L.eval('#jig.probe(inv(item()))') == 0, "today's layout passes (rotated = false counts as present)")
    check(L.eval('#jig.probe(inv(nil))') == 0, "an empty inventory checks the containers only")
    L.execute('local it = item(); it.ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7.Count_8_DD79AF2A46126A338C8DCCB4616D91CD = nil; M = jig.probe(inv(it))')
    check(L.eval('#M') == 1 and L.eval('M[1]') == "Count_8_DD79AF2A46126A338C8DCCB4616D91CD", "a renamed item member is named")
    L = lua()  # a found function stays cached (right), so the removal runs in a fresh game
    L.execute(SETUP)
    L.execute('GONE.RemoveGetInfo = true; M = jig.probe(inv(item()))')
    check(L.eval('#M') == 1 and L.eval('M[1]') == "RemoveGetInfo", "a removed inventory function is named")
    check(L.eval('#jig.probe({})') >= 1, "no MainJigContainers at all is reported, not an error")


def find_by_id_reuses_the_object_it_found():
    print("find_by_id_reuses_the_object_it_found")
    L = lua()
    L.execute("""
        util = require("mirror.util")
        WALKS = 0
        local function crate(addr, x, y, z)
            local o = { loc = { X = x, Y = y, Z = z }, addr = addr }
            o.IsValid = function() return true end
            o.GetAddress = function() return o.addr end
            o.GetFullName = function() return "Crate_C /Game/Map.Map:Crate_" .. o.addr end
            o.GetFName = function() return { ToString = function() return "Crate_" .. o.addr end } end
            o.GetClass = function() return { GetFName = function() return { ToString = function() return "Crate_C" end } end,
                                             IsValid = function() return true end, GetFullName = function() return "BlueprintGeneratedClass /Game/Crate.Crate_C" end } end
            o.K2_GetActorLocation = function() return o.loc end
            return o
        end
        A, B = crate(101, 1000, 2000, 30), crate(102, 5000, 5000, 0)
        FindAllOf = function() WALKS = WALKS + 1; return { A, B } end
        CLOCK = 0; os.clock = function() return CLOCK end
    """)
    first = L.eval('util.find_by_id("Crate_C@100,200,3") == A')
    w1 = L.eval('WALKS')
    L.execute('CLOCK = 100')  # far past the 5 s list cache: only the id cache can avoid a walk
    again = L.eval('util.find_by_id("Crate_C@100,200,3") == A')
    check(first and again, "the container is found by its id")
    check(w1 == 1 and L.eval('WALKS') == 1, "the second lookup reuses the object, no walk (walks %d)" % L.eval('WALKS'))
    L.execute('A.loc = { X = 9000, Y = 0, Z = 0 }; CLOCK = 200; R = util.find_by_id("Crate_C@100,200,3")')
    check(L.eval('R') is None and L.eval('WALKS') == 2, "an object that moved off the id is not returned; one walk to re-check")
    L.execute('A.loc = { X = 1000, Y = 2000, Z = 30 }; util.find_by_id("Crate_C@100,200,3"); util.find_reset(); CLOCK = 300; util.find_by_id("Crate_C@100,200,3")')
    check(L.eval('WALKS') == 3, "a world reset forgets the cache (walks %d)" % L.eval('WALKS'))


def tooltip_never_calls_into_null_objects():
    print("tooltip_never_calls_into_null_objects")
    L = lua()
    L.execute(FAKES + r"""
        package.loaded["mirror.game"] = { player = function() return nil end, on_world_reset = function() end,
                                          keybind = function() end, on_ready = function() end }
        util = require("mirror.util")
        HOOKS = {}
        util.ensure_hook = function(p, fn) HOOKS[p:match(":(.+)$")] = fn; return true end
        names = require("mirror.names")
        names.tick(2)
        TOUCHED = nil
        -- a UE4SS wrapper around NULL: IsValid says false, anything else is a native crash in the game
        function null(what)
            return setmetatable({ IsValid = function() return false end },
                                { __index = function(_, k) TOUCHED = what .. "." .. k; return function() TOUCHED = what .. ":" .. k end end })
        end
        function hover(tip, item) HOOKS.Update({ get = function() return tip end }, { get = function() return item end }) end
        local uid = { A = 1, B = 2, C = 3, D = 4 }
        ITEM_NO_DA = obj({ ItemUniqueID = uid, JigDataAsset = null("JigDataAsset") })
        TIP = obj({ ItemRef = ITEM_NO_DA, NameText = null("NameText"), descr = null("descr") })
    """)
    check(L.eval('HOOKS.Update ~= nil'), "the tooltip hook is installed")
    L.execute('hover(TIP, ITEM_NO_DA)')
    check(L.eval('TOUCHED') is None, "an item without a data asset is left alone (touched %s)" % L.eval('TOUCHED'))
    L.execute('names.set("1_2_3_4", "Bag"); hover(TIP, ITEM_NO_DA)')
    check(L.eval('TOUCHED') is None, "a named item whose title text isn't built is left alone (touched %s)" % L.eval('TOUCHED'))
    L.execute('hover(null("tooltip"))')
    check(L.eval('TOUCHED') is None, "a torn-down tooltip is left alone (touched %s)" % L.eval('TOUCHED'))
    L.execute('hover(TIP, null("ItemRef"))')
    check(L.eval('TOUCHED') is None, "a tooltip whose item is gone is left alone (touched %s)" % L.eval('TOUCHED'))


def settlement_camps_follow_the_host():
    print("settlement_camps_follow_the_host")
    def side(role):
        L = lua()
        L.execute(FAKES + r"""
            util = require("mirror.util")
            WORLD = {}
            util.instances = function(cls) local l = {} for _, a in ipairs(WORLD[cls] or {}) do if not a.gone then l[#l + 1] = a end end return l end
            function camp(cls, at) local a = obj({ cls = cls }); a.K2_DestroyActor = function() if not at then a.gone = true end end
                               a.K2_GetActorLocation = function() return at or { X = 5000, Y = 7000, Z = 300 } end
                               WORLD[cls] = WORLD[cls] or {}; table.insert(WORLD[cls], a); return a end
            function spawner(cls) local s = obj({ Settlement = { GetFName = function() return { ToString = function() return cls end } end } })
                                  s.SpawnSettlement = function() camp(cls) end
                                  WORLD.BP_SettlementCampSpawner_C = WORLD.BP_SettlementCampSpawner_C or {}
                                  table.insert(WORLD.BP_SettlementCampSpawner_C, s) end
            for i = 1, 4 do spawner("Prefab_Settlement" .. i .. "_C") end
            JOINED = true
            -- (no world: the animation gate lets a camp's destroy run at once)
            package.loaded["mirror.game"] = { on_world_reset = function() end, world = function() return nil end }
            camps = require("mirror.camps")
            camps.init({}, "%s", { in_world = function() return JOINED end }, function() return true end)
            function n(cls) return #util.instances(cls) end
        """ % role)
        return L
    H, G = side("host"), side("guest")
    H.execute('camp("Prefab_Settlement4_C"); camps.tick(5)')
    sent = H.eval('blobs_out.camps')
    check(sent == "Prefab_Settlement4_C=1", "the host sends its camps (%r)" % sent)
    # (the game also keeps an empty Settlement1 at the world origin that can't be destroyed: not a camp)
    G.execute('camp("Prefab_Settlement1_C", { X = 0, Y = 0, Z = 0 }); camp("Prefab_Settlement2_C"); camp("Prefab_Settlement3_C")')
    G.execute('blobs_in.camps = ...; camps.tick(5)', sent)
    check(G.eval('n("Prefab_Settlement2_C") + n("Prefab_Settlement3_C")') == 2, "nothing changes in the first seconds after arriving")
    for _ in range(4):
        G.execute('camps.tick(5)')
    check(G.eval('n("Prefab_Settlement2_C") + n("Prefab_Settlement3_C")') == 0, "the guest's own leftover camps are removed")
    check(G.eval('n("Prefab_Settlement4_C")') == 1, "the host's camp is spawned through its spawner")
    for _ in range(4):
        G.execute('camps.tick(5)')
    check(G.eval('n("Prefab_Settlement4_C")') == 1, "and only once")
    # a spawned camp that isn't seen (no BeginPlay of its own, test 2026-10-25: 6 copies) is still spawned only once
    G.execute('for _, a in ipairs(WORLD.Prefab_Settlement4_C) do a.gone = true end; for i = 1, 6 do camps.tick(5) end')
    check(G.eval('#WORLD.Prefab_Settlement4_C') == 1, "a camp is never spawned twice in one world (%d)" % G.eval('#WORLD.Prefab_Settlement4_C'))
    G.execute('for _, a in ipairs(WORLD.Prefab_Settlement4_C) do a.gone = nil end')
    check(G.eval('n("Prefab_Settlement1_C")') == 1, "the empty template at the origin is not touched")
    G.execute('JOINED = false; camp("Prefab_Settlement2_C"); for i = 1, 6 do camps.tick(5) end')
    check(G.eval('n("Prefab_Settlement2_C")') == 1, "the guest's home world is left alone")
    check(H.eval('n("Prefab_Settlement4_C")') == 1, "the host's world is never changed")


def military_trader_follows_the_host():
    print("military_trader_follows_the_host")
    def side(role, at):
        L = lua()
        L.execute(FAKES + r"""
            util = require("mirror.util")
            WORLD = {}
            util.instances = function(cls) return WORLD[cls] or {} end
            function trader(x, y, z, yaw)
                local a = obj({ loc = { X = x, Y = y, Z = z }, yaw = yaw })
                a.K2_GetActorLocation = function() return a.loc end
                a.K2_GetActorRotation = function() return { Pitch = 0, Yaw = a.yaw, Roll = 0 } end
                a.K2_SetActorLocationAndRotation = function(_, l, r, sweep, hit, tp)
                    a.loc, a.yaw, a.tp = { X = l.X, Y = l.Y, Z = l.Z }, r.Yaw, tp end
                WORLD.BP_MilitaryTrader_C = { a }; return a end
            JOINED = true
            package.loaded["mirror.game"] = { on_world_reset = function() end }
            camps = require("mirror.camps")
            camps.init({}, "%s", { in_world = function() return JOINED end }, function() return true end)
            T = trader(%s)
        """ % (role, at))
        return L
    H, G = side("host", "-1937, 239448, 1737, 90"), side("guest", "215480, -64813, 1622, 0")
    H.execute('camps.tick(5)')
    sent = H.eval('blobs_out.miltrader')
    check(sent == "-1937.00 239448.00 1737.00 90.0", "the host sends where its military trader stands (%r)" % sent)
    # (the host's camps blob always comes along - "-" when it has no camp)
    G.execute('blobs_in.miltrader = ...; blobs_in.camps = "%s"; camps.tick(5)' % H.eval('blobs_out.camps'), sent)
    check(G.eval('T.loc.X') == 215480, "nothing moves in the first seconds after arriving")
    for _ in range(3):
        G.execute('camps.tick(5)')
    check(G.eval('T.loc.X') == -1937 and G.eval('T.loc.Y') == 239448 and G.eval('T.yaw') == 90.0,
          "the guest's trader stands where the host's does (%s, %s)" % (G.eval('T.loc.X'), G.eval('T.loc.Y')))
    check(G.eval('T.tp') is True, "moved as a teleport (no sweep through the world)")
    G.execute('T.loc = { X = 1, Y = 2, Z = 3 }; JOINED = false; for i = 1, 4 do camps.tick(5) end')
    check(G.eval('T.loc.X') == 1, "the guest's own world is left alone")
    H.execute('camps.tick(5)')
    check(H.eval('T.loc.X') == -1937, "the host's trader is never moved")
    H.execute('blobs_out.miltrader = nil; camps.tick(5)')
    check(H.eval('blobs_out.miltrader') is None, "an unchanged spot is not sent again")


PEERS_FAKES = r'''
    LINKDIR = ...
    os.getenv = (function(real) return function(k) if k == "LOCALAPPDATA" then return LINKDIR end return real(k) end end)(os.getenv)
    STARTED = {}
    package.preload["mirror.phase1"] = function(name, tag)
        local p = { tag = tag }
        function p.init(cfg, role, id, tags) STARTED[#STARTED + 1] = { tag = tag, role = role, id = id, out = tags.out, inn = tags.inn }; p.running = true end
        function p.stop() p.running = false; STOPPED = (STOPPED or 0) + 1 end
        return p
    end
    GHOSTS = {}
    package.preload["mirror.ghost"] = function(name, tag)
        local g = { tag = (tag ~= ":preload:" and tag) or "main" }
        function g.is(o) return o ~= nil and o == GHOSTS[g.tag] end
        function g.get() return GHOSTS[g.tag] end
        function g.location() local o = GHOSTS[g.tag]; return o and o.loc or nil end
        return g
    end
    package.preload["mirror.world"] = function() return { main_world = true } end
    peers = require("mirror.peers")
    function roster(lines) local f = io.open(LINKDIR .. "\\SurrounDead\\mirror_roster.txt", "wb"); f:write("v1\n" .. lines .. "END\n"); f:close() end
'''


def airdrops_follow_the_host():
    """User 2026-10-29: airdrops aren't synced - each game's BP_EventManager flies its own plane and drops its own random
    crates. The host sends where its crates came to rest; the guest gets the same crate on that spot (shared loot finds
    a container by class + position) and its own planes are taken away."""
    print("airdrops_follow_the_host")

    def side(role):
        L = lua()
        L.execute(FAKES + r"""
            util = require("mirror.util")
            WORLD = {}
            util.instances = function(cls) local l = {} for _, a in ipairs(WORLD[cls] or {}) do if not a.gone then l[#l + 1] = a end end return l end
            function actor(cls, at)
                local a = obj({ cls = cls, at = { X = at.X, Y = at.Y, Z = at.Z }, physics = true })
                a.K2_GetActorLocation = function(self) return self.at end
                a.K2_GetActorRotation = function() return { Pitch = 0, Yaw = 30, Roll = 0 } end
                a.K2_DestroyActor = function(self) self.gone = true end
                a.K2_SetActorLocationAndRotation = function(self, l) self.at = { X = l.X, Y = l.Y, Z = l.Z } end
                a.K2_GetRootComponent = function(self) return { SetSimulatePhysics = function(_, on) self.physics = on end } end
                WORLD[cls] = WORLD[cls] or {}; table.insert(WORLD[cls], a); return a
            end
            StaticFindObject = function(p) return obj({ path = p }) end
            FindFirstOf = function() return obj({ ReferencedObjects = { GetArrayNum = function() return 0 end } }) end
            -- the container loot tables: all in memory (one walk of their class finds them)
            FindAllOf = function(c)
                if c ~= "ContainerItems_DataAsset_C" then return nil end
                local out = {}
                for _, p in ipairs(require("mirror.loottables")._paths) do
                    out[#out + 1] = obj({ GetFullName = function() return "ContainerItems_DataAsset_C " .. p end })
                end
                return out
            end
            package.loaded["mirror.game"] = { on_world_reset = function() end,
                world = function() return { SpawnActor = function(_, cls, l) return actor(cls.path:match("%%.(.+)$"), l) end } end }
            JOINED = true
            airdrops = require("mirror.airdrops")
            airdrops.init({}, "%s", { in_world = function() return JOINED end }, function() return true end)
        """ % role)
        return L

    H, G = side("host"), side("guest")
    H.execute('C = actor("AirdropContainer_Military_C", { X = 1000, Y = 2000, Z = 5000 }); airdrops.tick(3)')
    check(H.eval('blobs_out.airdrops') in (None, "-"), "a falling crate isn't sent yet (%r)" % H.eval('blobs_out.airdrops'))
    H.execute('C.at = { X = 1000.25, Y = 2000.5, Z = 300.75 }; airdrops.tick(3); airdrops.tick(3)')
    sent = H.eval('blobs_out.airdrops') or ""
    check(sent.startswith("AirdropContainer_Military_C 1000.25 2000.50 300.75"), "a crate at rest is sent with its exact spot (%r)" % sent)
    G.execute('PLANE = actor("AirdropAircraft_C", { X = 0, Y = 0, Z = 50000 }); blobs_in.airdrops = ...', sent)
    G.execute('for i = 1, 5 do airdrops.tick(3) end')
    check(G.eval('PLANE.gone') is True, "the guest's own airdrop plane is taken away")
    check(G.eval('#util.instances("AirdropContainer_Military_C")') == 1, "the host's crate is spawned here")
    check(G.eval('util.instances("AirdropContainer_Military_C")[1].at.Z') > 300.75, "...a little above its spot, so it lands")
    G.execute('local a = util.instances("AirdropContainer_Military_C")[1]; a.at = { X = 1003, Y = 1998, Z = 301 }')
    G.execute('os_clock = os.clock; os.clock = function() return os_clock() + 10 end; for i = 1, 3 do airdrops.tick(3) end; os.clock = os_clock')
    a = G.eval('util.instances("AirdropContainer_Military_C")[1]')
    check(abs(a.at.X - 1000.25) < 1e-6 and abs(a.at.Y - 2000.5) < 1e-6 and abs(a.at.Z - 300.75) < 1e-6 and a.physics is False,
          "once landed it is put on the host's exact spot and held there (the loot ids match)")
    G.execute('for i = 1, 5 do airdrops.tick(3) end')
    check(G.eval('#WORLD.AirdropContainer_Military_C') == 1, "and only spawned once")
    G.execute('blobs_in.airdrops = "-"; airdrops.tick(3)')
    check(G.eval('util.instances("AirdropContainer_Military_C")[1]') is None, "the host's crate gone: the copy goes too")


def event_sites_follow_the_host():
    """User 2026-10-29: plane crashes aren't synced - every BP_PrefabSpawner rolls its own chance in each game and the
    event manager fires dynamic ones on its own timer. The host sends its prefabs; the guest removes its own others and
    spawns the host's at the same spot. Settlements (camps.lua) and quest prefabs are left alone."""
    print("event_sites_follow_the_host")

    def side(role):
        L = lua()
        L.execute(FAKES + r"""
            util = require("mirror.util")
            ALL, SPAWNERS = {}, {}
            util.instances = function(cls)
                local src = cls == "BP_PrefabSpawner_C" and SPAWNERS or ALL
                local l = {} for _, a in ipairs(src) do if not a.gone then l[#l + 1] = a end end return l end
            util.class_name = function(a) return a.cls end
            -- a spawner standing on a site, with its marker (as the game's BP_PrefabSpawner)
            function spawner(x, y, marker)
                local s = obj({ at = { X = x, Y = y, Z = 100 }, DistanceToDiscoverPrefab = 5000, ["Marker?"] = true,
                                ["Marker Texture"] = obj({ GetFullName = function() return "Texture2D /Game/UI/Crash.Crash" end }),
                                ["Marker Title"] = { ToString = function() return "Plane Crash" end },
                                ["Marker Description"] = { ToString = function() return "A military plane went down" end } })
                s.K2_GetActorLocation = function(self) return self.at end
                s.K2_DestroyActor = function(self) self.gone = true end
                s.Marker = marker
                SPAWNERS[#SPAWNERS + 1] = s; return s
            end
            util.class_path = function(a) return "/Game/Prefabs/X/" .. a.cls:gsub("_C$", "") .. "." .. a.cls end
            function prefab(cls, x, y)
                local a = obj({ cls = cls, at = { X = x, Y = y, Z = 100 } })
                a.K2_GetActorLocation = function(self) return self.at end
                a.K2_GetActorRotation = function() return { Pitch = 0, Yaw = 90, Roll = 0 } end
                a.K2_DestroyActor = function(self) self.gone = true end
                ALL[#ALL + 1] = a; return a
            end
            MARKER_CDO = obj({})
            FText = function(s) return "FText:" .. s end
            NOT_LOADED = {}   -- paths the game hasn't loaded (StaticFindObject finds nothing)
            FINDS = {}
            StaticFindObject = function(p)
                FINDS[p] = (FINDS[p] or 0) + 1
                if NOT_LOADED[p] then return nil end
                if p:find("Default__BP_Marker_C", 1, true) then return MARKER_CDO end
                if p:find("Default__GameFunctionLibrary_C", 1, true) then return obj({ XpMultiplierCalc = function() return 50 end }) end
                return obj({ cls = p:match("%%.(.+)$") })
            end
            -- the container loot tables in memory: one walk of their class finds them (not one lookup each)
            WALKS = 0
            FindAllOf = function(c)
                if c ~= "ContainerItems_DataAsset_C" then return nil end
                WALKS = WALKS + 1
                local out = {}
                for _, p in ipairs(require("mirror.loottables")._paths) do
                    if not NOT_LOADED[p] then
                        out[#out + 1] = obj({ GetFullName = function() return "ContainerItems_DataAsset_C " .. p end })
                    end
                end
                return out
            end
            MARKERS, XP = {}, 0
            ME = obj({ K2_GetActorLocation = function() return ME_AT end }); ME_AT = { X = 0, Y = 0, Z = 0 }
            package.loaded["mirror.game"] = { on_world_reset = function() end, player = function() return ME end,
                controller = function() return { LevellingComponent = { AddXP = function(_, n) XP = XP + n end } } end,
                world = function() return { SpawnActor = function(_, c, l)
                    if c.cls == "BP_Marker_C" then
                        local m = obj({ title = MARKER_CDO.MarkerTitle, at = l }); m.K2_DestroyActor = function(self) self.gone = true end
                        MARKERS[#MARKERS + 1] = m; return m
                    end
                    return prefab(c.cls, l.X, l.Y) end } end }
            JOINED = true
            prefabs = require("mirror.prefabs")
            prefabs.init({}, "%s", { in_world = function() return JOINED end }, function() return true end)
            function n(cls) local k = 0 for _, a in ipairs(util.instances()) do if a.cls == cls then k = k + 1 end end return k end
        """ % role)
        return L

    H, G = side("host"), side("guest")
    H.execute('prefab("Prefab_CrashedMilitaryPlane_C", 5000, 6000); spawner(5000, 6000); prefab("Prefab_Settlement2_C", 1, 2000); '
              'prefab("Prefab_Quest_BanditCamp1_C", 3000, 3000); prefab("Prefab_AbandonedConvoy_C", 0, 0); prefabs.tick(5)')
    sent = H.eval('blobs_out.prefabs') or ""
    check(sent.startswith("Prefab_CrashedMilitaryPlane_C /Game/Prefabs/X/Prefab_CrashedMilitaryPlane.Prefab_CrashedMilitaryPlane_C 5000.00 6000.00")
          and "Settlement" not in sent and "Quest" not in sent and "Convoy" not in sent,
          "the host sends its event sites (no settlements, quest prefabs or origin templates) (%r)" % sent)
    check(sent.endswith("\t/Game/UI/Crash.Crash\t5000\t1\tPlane Crash\tA military plane went down"),
          "...with its spawner's map marker (%r)" % sent)
    # (a container's BeginPlay loads the loot tables it walks: one not in memory = a load inside our SpawnActor,
    # the DBG-016 freeze - and a site whose class isn't loaded yet is tried again later, not given up)
    G.execute('GI = obj({ ReferencedObjects = { n = 0, GetArrayNum = function(self) return self.n end } }); '
              'setmetatable(GI.ReferencedObjects, { __newindex = function(t, k, v) rawset(t, k, v); t.n = k end }); '
              'FindFirstOf = function(c) if c == "SD_GameInstance_C" then return GI end end; '
              'TABLE = "/Game/Inventory/Containers/LootTables/DA_LootTable_Bunker.DA_LootTable_Bunker"; '
              'PLANE = "/Game/Prefabs/X/Prefab_CrashedMilitaryPlane.Prefab_CrashedMilitaryPlane_C"; '
              'NOT_LOADED[TABLE] = true; NOT_LOADED[PLANE] = true')
    G.execute('prefab("Prefab_CrashedHelicopter01_C", 9000, 9000); OWN_MARK = obj({}); OWN_MARK.K2_DestroyActor = function(self) self.gone = true end; '
              'OWN_SP = spawner(9000, 9000, OWN_MARK); prefab("Prefab_Settlement3_C", 7, 7000); '
              'prefab("Prefab_Quest_BanditCamp2_C", 4000, 4000); blobs_in.prefabs = ...; prefabs.tick(5)', sent)
    check(G.eval('n("Prefab_CrashedHelicopter01_C")') == 1 and G.eval('n("Prefab_CrashedMilitaryPlane_C")') == 0,
          "nothing changes in the first seconds after arriving")
    G.execute('for i = 1, 6 do prefabs.tick(5) end')
    # (a site can hold animated child actors: destroyed once animation runs on the game thread - animgate.lua)
    check(G.eval('n("Prefab_CrashedHelicopter01_C")') == 1, "the guest's own crash site waits for the animation gate")
    G.execute('for i = 1, 3 do util.new_frame(); require("mirror.animgate").tick() end')
    check(G.eval('n("Prefab_CrashedHelicopter01_C")') == 0, "the guest's own crash site is removed")
    check(G.eval('n("Prefab_CrashedMilitaryPlane_C")') == 0, "the host's site's class isn't loaded here: not spawned")
    # (a miss costs ~15 ms in the game: 42-49 ms every 5 s live 2026-10-30 with ~12 such sites)
    check(G.eval('FINDS[PLANE]') == 1, "...and not looked up again at every check (%s lookups)" % G.eval('FINDS[PLANE]'))
    # (util.find asks a missing path again 2 s later, real time: the ticks here take no time)
    G.execute('NOT_LOADED[PLANE] = nil; util.find_reset(); for i = 1, 6 do prefabs.tick(5) end')
    check(G.eval('n("Prefab_CrashedMilitaryPlane_C")') == 0,
          "class loaded, one container loot table not: still not spawned (no load inside SpawnActor)")
    G.execute('NOT_LOADED[TABLE] = nil; for i = 1, 16 do prefabs.tick(5); '
              'if GI.ReferencedObjects.n == 30 and PIN_N == nil then PIN_N = n("Prefab_CrashedMilitaryPlane_C") end end')
    check(G.eval('GI.ReferencedObjects.n') == 30, "every loot table in memory: all 30 pinned (%s)" % G.eval('GI.ReferencedObjects.n'))
    # (kit 2026-10-31: ~15 ms a lookup, found or not - "perf: prefabs took 139 ms" after a join)
    G.execute('BYNAME = 0; for p, k in pairs(FINDS) do if p:find("/LootTables/", 1, true) then BYNAME = BYNAME + k end end')
    check(G.eval('BYNAME') == 0 and G.eval('WALKS') >= 1,
          "...found by walking their class, none looked up by name (%s lookups, %s walks)" % (G.eval('BYNAME'), G.eval('WALKS')))
    # (pin + spawn in one frame: 468 ms live 2026-10-30 02:34:53)
    check(G.eval('PIN_N') == 0, "...and the site isn't spawned in the check that pinned them (%s)" % G.eval('PIN_N'))
    check(G.eval('OWN_SP.gone') is True and G.eval('OWN_MARK.gone') is True,
          "...with its spawner and map marker (no marker for a site that isn't there)")
    check(G.eval('n("Prefab_CrashedMilitaryPlane_C")') == 1, "the host's crashed plane is spawned at its spot")
    # DBG-20261028-004: a BP_Marker spawned from Lua with the spawner's look written into its class defaults
    # crashed the guest at every join - without a spawner here the site gets no map icon, and nothing is written
    check(G.eval('#MARKERS') == 0, "...without a spawner here: no marker spawned from Lua (it crashed the game)")
    check(G.eval('MARKER_CDO.MarkerTitle') != "FText:Plane Crash", "the marker class's defaults are never written")
    check(G.eval('n("Prefab_Settlement3_C")') == 1 and G.eval('n("Prefab_Quest_BanditCamp2_C")') == 1,
          "settlements and quest prefabs are left alone")
    G.execute('for i = 1, 6 do prefabs.tick(5) end')
    check(G.eval('n("Prefab_CrashedMilitaryPlane_C")') == 1, "and only once")


def a_destroyed_sites_address_can_come_back_as_a_new_site():
    """Audit 2026-10-30: an event site or camp destroyed here stays listed until garbage collection, so it is marked;
    the mark was its address, kept for the whole world. After the collection the address can come back as a new actor:
    a host that took over the Realm in place left that site out of its list and every guest removed it."""
    print("a_destroyed_sites_address_can_come_back_as_a_new_site")
    L = lua()
    L.execute(FAKES + r"""
        util = require("mirror.util")
        ALL = {}
        util.instances = function() local l = {} for _, a in ipairs(ALL) do if not a.gone then l[#l + 1] = a end end return l end
        util.class_name = function(a) return a.cls end
        util.class_path = function(a) return "/Game/Prefabs/X/" .. a.cls:gsub("_C$", "") .. "." .. a.cls end
        local k = 0
        function prefab(cls, x, y)
            k = k + 1
            local a = obj({ cls = cls, at = { X = x, Y = y, Z = 100 }, name = cls .. " /Game/Map.Map:Persistent." .. cls .. "_" .. k })
            a.GetFullName = function(self) return self.name end
            a.K2_GetActorLocation = function(self) return self.at end
            a.K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end
            a.K2_DestroyActor = function(self) self.destroyed = true end   -- still listed until "garbage collection"
            ALL[#ALL + 1] = a; return a
        end
        package.loaded["mirror.game"] = { on_world_reset = function() end, player = function() end,
            world = function() return { SpawnActor = function() end } end }
        JOINED = true
        prefabs = require("mirror.prefabs")
        prefabs.init({}, "guest", { in_world = function() return JOINED end }, function() return true end)
    """)
    L.execute('OLD = prefab("Prefab_CrashedHelicopter01_C", 9000, 9000); blobs_in.prefabs = "-"; '
              'for i = 1, 8 do prefabs.tick(5) end; '
              'for i = 1, 3 do util.new_frame(); require("mirror.animgate").tick() end')
    check(L.eval('OLD.destroyed') is True, "the guest destroys its own site the host doesn't have")
    # in place, no world load: the guest becomes the host (Realm takeover)
    L.execute('prefabs.init({}, "host", { in_world = function() return true end }, function() return true end); prefabs.tick(5)')
    check(L.eval('blobs_out.prefabs') == "-", "the new host leaves out the site it destroyed while still listed (%r)" % L.eval('blobs_out.prefabs'))
    L.execute('OLD.gone = true; NEW = prefab("Prefab_CrashedMilitaryPlane_C", 5000, 6000); '
              'local a = OLD:GetAddress(); NEW.GetAddress = function() return a end; prefabs.tick(5)')
    sent = L.eval('blobs_out.prefabs') or ""
    check(sent.startswith("Prefab_CrashedMilitaryPlane_C "), "a new site at the old one's address is sent (%r)" % sent)


def new_realm_character_gets_the_starting_kit():
    """User 2026-10-29: new Realm characters had no starter gear - the pocket repair always used InitNoStartingItems.
    A character without any inventory file gets the game's own kit; a stored one that arrives empty never does."""
    print("new_realm_character_gets_the_starting_kit")
    for fresh in (True, False):
        L = lua()
        L.execute('''
            CALLS = {}
            local n = 0
            local arr = function(k) return { GetArrayNum = function() return k end } end
            JIG = { ContainersSettings = arr(22), LocalJSIContainers = arr(0), MainContainersIDs = arr(0) }
            JIG.MainJigContainers = setmetatable({}, { __len = function() return n end })
            function JIG:ResetInitComponent() CALLS[#CALLS + 1] = "reset" end
            function JIG:InitNoStartingItems() CALLS[#CALLS + 1] = "nokit"; n = 22 end
            function JIG:InitializeJigComponent() CALLS[#CALLS + 1] = "init"; n = 22 end
            PLAYER = { BP_JigMultiplayer = JIG, SetStartingItems = function() CALLS[#CALLS + 1] = "kit" end }
            package.loaded["mirror.game"] = { player = function() return PLAYER end, keybind = function() end,
                                              on_tick = function() end, player_hook = function() end, on_ready = function() end }
            SAVED = 0
            package.loaded["mirror.session"] = { save_now = function() SAVED = SAVED + 1 end }
            NOTES = {}
            package.loaded["mirror.notify"] = { show = function(m) NOTES[#NOTES + 1] = m end, clear = function() end }
            invdiag = require("mirror.invdiag")
            invdiag.live_containers = function() return #JIG.MainJigContainers end
        ''')
        L.execute('invdiag.ensure_pockets("test", %s)' % ("true" if fresh else "false"))
        calls = list(L.eval('CALLS').values())
        if fresh:
            check(calls == ["reset", "kit", "init"], "fresh: the game's starting kit is set, then the inventory built (%s)" % calls)
            check(L.eval('#NOTES') == 0, "fresh: no 'missing its pockets' note")
        else:
            check(calls == ["reset", "nokit"], "stored character: empty pockets only, no items from nothing (%s)" % calls)
        check(L.eval('SAVED') == 1, "saved after the repair")


def realm_takes_the_creators_difficulty():
    """User 2026-10-28: make the difficulties match - a new Realm plays at the difficulty of the save its creator is in,
    not the New Game page's. The live values are the Difficulty.* / Loot.* cvars (names from UserSettings.ini)."""
    print("realm_takes_the_creators_difficulty")
    d = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(d, "SurrounDead", "Saved", "Config", "Windows"))
        with open(os.path.join(d, "SurrounDead", "Saved", "Config", "Windows", "UserSettings.ini"), "w") as f:
            f.write("[Settings]\nVideo.Gamma=1.2\nDifficulty.Permadeath=false\nDifficulty.XPMultiplier=1.5\n"
                    "Loot.General=1.5\nLoot.Food&Drink=1.5\nDifficulty.ZombieAmount=1.0\n")
        L = lua()
        L.execute(FAKES + r"""
            package.loaded["mirror.game"] = { world = function() return WORLD end }
            WORLD = {}
            LIVE = { ["Difficulty.Permadeath"] = false, ["Difficulty.XPMultiplier"] = 1.5121, ["Loot.General"] = 1.5,
                     ["Loot.Food&Drink"] = 1.5, ["Difficulty.ZombieAmount"] = 1.0, ["Video.Gamma"] = 1.2 }
            CMDS = {}
            local k = obj({})
            k.GetConsoleVariableBoolValue = function(self, n) return LIVE[n] end
            k.GetConsoleVariableFloatValue = function(self, n) return LIVE[n] end
            k.ExecuteConsoleCommand = function(self, w, c) CMDS[#CMDS + 1] = c end
            util = require("mirror.util")
            util.cdo = function() return k end
            ld = require("mirror.localdir")
            ld.configure({ getenv = function() return DIR end })
            dif = require("mirror.difficulty")
        """.replace("DIR", repr(d)))
        names = L.eval('(function() local t = {} for _, e in ipairs(dif.names()) do t[#t + 1] = e.name .. (e.bool and ":b" or "") end return table.concat(t, " ") end)()')
        check(names == "Difficulty.Permadeath:b Difficulty.XPMultiplier Loot.General Loot.Food&Drink Difficulty.ZombieAmount",
              "the difficulty and loot settings come from the game's settings file, video ones don't (%s)" % names)
        L.execute('SNAP = dif.snapshot()')
        check(L.eval('SNAP["Difficulty.XPMultiplier"]') == "1.5121" and L.eval('SNAP["Difficulty.Permadeath"]') == "0",
              "the live values are read (number and on/off)")
        L.execute('SNAP2 = dif.decode(dif.encode(SNAP)); N = dif.apply(SNAP2)')
        cmds = sorted(L.eval('CMDS').values())
        check(L.eval('N') == 5 and "Loot.Food&Drink 1.5" in cmds and "Difficulty.Permadeath 0" in cmds and "Difficulty.ZombieAmount 1" in cmds,
              "kept and set again in the new world, one console line each (%s)" % cmds)
        L.execute('CMDS = {}; dif.apply({ ["Difficulty.X; quit"] = "1", ["Loot.General"] = "1 ; exit" })')
        check(L.eval('#CMDS') == 0, "nothing but a setting name and a number is ever sent to the console")
        check(L.eval('dif.remember_mine("QuickSave1")') is True, "the player's own difficulty is remembered")
        mine, name = L.eval('(dif.mine())'), L.eval('select(2, dif.mine())')
        check(mine is not None and mine["Loot.General"] == "1.5" and name == "QuickSave1", "...with the save it came from")
    finally:
        shutil.rmtree(d, ignore_errors=True)


WORLDSET_LUA = r"""
    package.loaded["mirror.game"] = { world = function() return WORLD end, player = function() return PLAYER end,
        on_tick = function(f) TICKS[#TICKS + 1] = f end }
    WORLD, PLAYER, TICKS = {}, obj({}), {}
    CMDS, NOTES = {}, {}
    local BOOL = { ["Difficulty.Permadeath"] = true }
    local k = obj({})
    k.GetConsoleVariableBoolValue = function(self, n) return LIVE[n] end
    k.GetConsoleVariableFloatValue = function(self, n) return LIVE[n] end
    k.ExecuteConsoleCommand = function(self, w, c)
        TRIES = (TRIES or 0) + 1
        if FAIL and c:find(FAIL, 1, true) then error("console refused") end
        CMDS[#CMDS + 1] = c
        local n, v = c:match("^(%S+) (%S+)$")
        if BOOL[n] then LIVE[n] = v == "1" else LIVE[n] = tonumber(v) end
    end
    util = require("mirror.util")
    util.cdo = function() return k end
    require("mirror.localdir").configure({ getenv = function() return DIR end })
    STATE, SLOT, INW = "idle", nil, false
    OWN = { A = true, B = true }
    package.loaded["mirror.session"] = { state = function() return STATE end, world_save = function() return SLOT end,
        in_world = function() return STATE == "joined" and INW end }
    package.loaded["mirror.slotguard"] = { is_own = function(n) return OWN[n] == true end }
    package.loaded["mirror.notify"] = { show = function(t) NOTES[#NOTES + 1] = t end }
    dif = require("mirror.difficulty")
    ws = require("mirror.worldset")
    function look() ws.tick(5.0) end
    function own(a, b) LIVE = { ["Difficulty.Permadeath"] = false, ["Difficulty.TraderCurrencyAmount"] = a,
        ["Difficulty.XPMultiplier"] = b, ["Loot.General"] = 1.5 } end
    HOST = "Difficulty.Permadeath=1\nDifficulty.TraderCurrencyAmount=5000\nDifficulty.XPMultiplier=2\nLoot.General=1.5\n"
    function cmds() table.sort(CMDS); local s = table.concat(CMDS, ","); CMDS = {}; return s end
    function pend() local p = dif.pending(); return p and (p.slot .. " " .. p.loads) or "none" end
"""


def coop_guest_runs_the_hosts_world_settings():
    """Player review 2026-10-31: 'if the host changes a world setting e.g. trader currency cap, player 2 has to do it
    too'. The guest's game runs the host's Difficulty/Loot values while joined, and gets its own back in its own save
    (Sentinel R1: also after a crash, and never remembering the host's as its own)."""
    print("coop_guest_runs_the_hosts_world_settings")
    d = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(d, "SurrounDead", "Saved", "Config", "Windows"))
        with open(os.path.join(d, "SurrounDead", "Saved", "Config", "Windows", "UserSettings.ini"), "w") as f:
            f.write("[Settings]\nDifficulty.Permadeath=false\nDifficulty.TraderCurrencyAmount=1000\n"
                    "Difficulty.XPMultiplier=1.5\nLoot.General=1.5\n")
        setup = FAKES + WORLDSET_LUA.replace("DIR", repr(d))
        L = lua()
        L.execute(setup.replace(repr(d), repr(os.path.join(d, "missing"))))
        check(L.eval('dif.set_pending("A", "?")') is False and L.eval('pend()') == "A ?",
              "a restore file that can't be written: still owed while the game runs")
        L = lua()
        L.execute(setup)
        check(L.eval('dif.same({ a = "2" }, { a = "2.0" })') is True and L.eval('dif.same({ a = "1.5121" }, { a = "1.51210004" })') is True
              and L.eval('dif.same({ a = "2" }, { a = "2.1" })') is False and L.eval('dif.same({}, { a = "1" })') is False,
              "values compare as numbers (the game keeps floats), a missing one differs")
        L.execute('own(1000, 1.5); SLOT = "A"; look()')
        mine, name = L.eval('(dif.mine())'), L.eval('select(2, dif.mine())')
        check(name == "A" and mine is not None and mine["Difficulty.TraderCurrencyAmount"] == "1000",
              "solo in my own save: my world settings are kept (%s)" % name)
        L.execute('own(1200, 1.5); look()')
        check(L.eval('(dif.mine())')["Difficulty.TraderCurrencyAmount"] == "1200", "...and a change there is kept too")
        L.execute('STATE = "requested"; ws.tick(0.1)')
        check(L.eval('pend()') == "A ?", "asking to join: a restore is owed to save A (%s)" % L.eval('pend()'))
        check(os.path.exists(os.path.join(d, "SurrounDead", "mirror_difficulty_restore.txt")),
              "...written to a file (a crash keeps it)")
        # the join's load didn't change the values (the case the guest reported): the host's are set
        L.execute('STATE, SLOT, INW = "joined", "Coop1", false; ws.follow(HOST, "Hosty")')
        check(L.eval('cmds()') == "", "still loading into the host's world: nothing set yet")
        L.execute('INW = true; ws.follow(HOST, "Hosty")')
        c = L.eval('cmds()')
        check(c == "Difficulty.Permadeath 1,Difficulty.TraderCurrencyAmount 5000,Difficulty.XPMultiplier 2",
              "in the host's world: the host's values are set, only the ones that differ (%s)" % c)
        check(L.eval('pend()') == "A no", "...and the join showed a world load doesn't set them (%s)" % L.eval('pend()'))
        L.execute('ws.follow(HOST, "Hosty")')
        check(L.eval('cmds()') == "" and L.eval('#NOTES') == 0, "matching: nothing more is set, no message")
        L.execute('LIVE["Difficulty.TraderCurrencyAmount"] = 99; ws.follow(HOST, "Hosty")')
        check(L.eval('cmds()') == "Difficulty.TraderCurrencyAmount 5000", "the guest changed one: the host's comes back")
        check(L.eval('#NOTES') == 1 and "Hosty" in L.eval('NOTES[1]'), "...with one message saying why")
        L.execute('LIVE["Difficulty.TraderCurrencyAmount"] = 98; ws.follow(HOST, "Hosty")')
        check(L.eval('cmds()') == "Difficulty.TraderCurrencyAmount 5000" and L.eval('#NOTES') == 1, "...only one message")
        L.execute('HOST = HOST:gsub("XPMultiplier=2", "XPMultiplier=3"); ws.follow(HOST, "Hosty")')
        check(L.eval('cmds()') == "Difficulty.XPMultiplier 3" and L.eval('#NOTES') == 1,
              "the host changes a setting: it reaches the guest (no message, the guest changed nothing)")
        check(L.eval('dif.remember_mine("A")') is False, "the host's values are never remembered as mine meanwhile")
        # home again, the save path asks first
        L.execute('STATE, SLOT = "idle", nil')
        check(L.eval('ws.restore_now()') is False and L.eval('cmds()') == "", "home world still loading: nothing set yet")
        L.execute('SLOT = "A"')
        check(L.eval('ws.restore_now()') is True, "back in save A: the restore runs before the save")
        c = L.eval('cmds()')
        check(c == "Difficulty.Permadeath 0,Difficulty.TraderCurrencyAmount 1200,Difficulty.XPMultiplier 1.5",
              "...my own values are set again (%s)" % c)
        check(L.eval('pend()') == "none" and not os.path.exists(os.path.join(d, "SurrounDead", "mirror_difficulty_restore.txt")),
              "...and nothing is owed any more")
        L.execute('look()')
        check(L.eval('(dif.mine())')["Difficulty.TraderCurrencyAmount"] == "1200", "my own values stay mine")

        # a crash while joined, then another own save: a load that doesn't set them leaves the host's -> set mine
        L.execute('STATE, SLOT = "requested", "A"; ws.tick(0.1); STATE, SLOT, INW = "joined", "Coop1", true; ws.follow(HOST, "Hosty"); cmds()')
        check(L.eval('pend()') == "A no", "joined again (%s)" % L.eval('pend()'))
        L.execute('ws.tick(0.1); ws.follow(HOST, "Hosty"); ws.tick(0.1); LIVE["Difficulty.TraderCurrencyAmount"] = 99; ws.follow(HOST, "Hosty"); ws.tick(0.1); '
                  'LIVE["Difficulty.TraderCurrencyAmount"] = 98; ws.follow(HOST, "Hosty"); cmds()')
        check(L.eval('#NOTES') == 2, "a new join: a change there gets its message again, once (%d)" % L.eval('#NOTES'))
        L = lua()
        L.execute(setup)
        L.execute('own(5000, 3); LIVE["Difficulty.Permadeath"] = true; SLOT, PLAYER = "B", nil; look()')
        check(L.eval('cmds()') == "" and L.eval('pend()') == "A no", "after a crash, no player in the world yet: nothing set")
        L.execute('PLAYER, FAIL = obj({}), "Difficulty.XPMultiplier"')
        check(L.eval('ws.restore_now()') is False and L.eval('pend()') == "A no",
              "one setting wouldn't set: the restore stays owed")
        L.execute('N1 = TRIES; ws.tick(0.01)')
        check(L.eval('TRIES') == L.eval('N1') + 1, "...the next frame tries once more (no 5 s wait while owed)")
        L.execute('N1 = TRIES; ws.tick(0.01); ws.tick(0.01)')
        check(L.eval('TRIES') == L.eval('N1'), "...then a second later, not every frame")
        L.execute('local clock = os.clock; os.clock = function() return clock() + 2 end; FAIL = nil; ws.tick(0.01); os.clock = clock')
        c = L.eval('cmds()')
        check(c == "Difficulty.Permadeath 0,Difficulty.TraderCurrencyAmount 1200,Difficulty.XPMultiplier 1.5",
              "after a crash, in another own save still running the host's values: mine are set (%s)" % c)
        L.execute('look()')
        mine, name = L.eval('(dif.mine())'), L.eval('select(2, dif.mine())')
        check(name == "B" and mine["Difficulty.TraderCurrencyAmount"] == "1200" and L.eval('pend()') == "none",
              "...then kept as save B's (%s %s)" % (name, mine["Difficulty.TraderCurrencyAmount"]))

        # a load that sets them from the save: another own save keeps its own, and the host's are never mine
        L.execute('STATE = "requested"; ws.tick(0.1)')
        L.execute('own(5000, 2); LIVE["Difficulty.Permadeath"] = true; STATE, SLOT, INW = "joined", "Coop1", true; ws.follow(HOST, "Hosty")')
        check(L.eval('cmds()') == "" and L.eval('pend()') == "B yes", "the join's load set the host's itself (%s)" % L.eval('pend()'))
        L = lua()
        L.execute(setup)
        L.execute('own(700, 1.1); SLOT = "A"; look()')
        check(L.eval('cmds()') == "", "after a crash, save A's load set A's own: nothing is changed")
        L.execute('look()')
        mine, name = L.eval('(dif.mine())'), L.eval('select(2, dif.mine())')
        check(name == "A" and mine["Difficulty.TraderCurrencyAmount"] == "700" and L.eval('pend()') == "none",
              "...and save A's values are kept, not the host's (%s %s)" % (name, mine["Difficulty.TraderCurrencyAmount"]))
        L.execute('SLOT = nil; look(); STATE = "requested"; ws.tick(0.1)')
        check(L.eval('pend()') == "A ?", "a join from the main menu owes the restore to the save I was last in (%s)" % L.eval('pend()'))
        L = lua()
        L.execute(setup)
        L.execute('dif.clear_pending(); STATE = "requested"; ws.tick(0.1)')
        check(L.eval('pend()') == "A ?", "...right after a start too: to the save my own values came from (%s)" % L.eval('pend()'))

        # the wire: the host's world.lua puts "diff" (kept) on change only, the guest's follows it
        L = lua()
        L.execute(setup + r"""
            PUT, BLOB = {}, nil
            package.loaded["mirror.link"] = { put_blob = function(n, t, keep) if n == "diff" then PUT[#PUT + 1] = { t, keep } end end,
                get_blob = function(n) if n == "diff" then local b = BLOB; BLOB = nil; return b end end,
                peer_name = function() return "Hosty" end }
            package.loaded["mirror.sleep"] = { init = function() end, tick = function() end, forget = function() end }
            FindAllOf = function() return {} end
            own(1000, 1.5)
            dif.clear_pending()
            world = require("mirror.world")
            world.init({}, "host", package.loaded["mirror.session"])
            world.tick(2.0)
        """)
        check(L.eval('#PUT') == 1 and L.eval('PUT[1][2]') is True and "TraderCurrencyAmount=1000" in L.eval('PUT[1][1]'),
              "host: the world settings go over at once, kept for a link that comes back")
        L.execute('world.tick(2.0)')
        check(L.eval('#PUT') == 1, "...once while nothing changes")
        L.execute('local clock = os.clock; os.clock = function() return clock() + 4 end; own(4000, 1.5); for i = 1, 3 do world.tick(2.0) end')
        check(L.eval('#PUT') == 2 and "TraderCurrencyAmount=4000" in L.eval('PUT[2][1]'), "...and again when one changes")
        L.execute('world.init({}, "guest", package.loaded["mirror.session"]); STATE, SLOT, INW = "joined", "Coop1", true; '
                  'BLOB = HOST; world.tick(2.0); world.tick(2.0)')
        check("Difficulty.TraderCurrencyAmount 5000" in L.eval('cmds()'), "guest: the host's are set from the blob")
        check(L.eval('pend()') == "A ?", "...a join the mod didn't see start still owes my own save the restore (%s)" % L.eval('pend()'))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def zombies_stop_at_arms_length():
    """User 2026-10-28: zombies clip inside the player (the game's zombie capsule ignores pawns, 15 cm wide)."""
    print("zombies_stop_at_arms_length")
    L = lua()
    L.execute(FAKES + r"""
        ROLE = nil
        package.loaded["mirror.phase1"] = { started = function() return ROLE end }
        TICKS = {}
        function at(x) return { X = x, Y = 0, Z = 0 } end
        PLAYER = obj({ K2_GetActorLocation = function() return at(0) end })
        GHOST = obj({ K2_GetActorLocation = function() return at(5000) end })
        package.loaded["mirror.game"] = { player = function() return PLAYER end, world = function() return {} end,
            on_tick = function(f) TICKS[#TICKS + 1] = f end, on_world_reset = function(f) RESET = f end }
        package.loaded["mirror.peers"] = { each = function(n, fn) fn({ get = function() return GHOST end }) end }
        function zombie(x)
            local cap = obj({ resp = 0, r = 15 })
            cap.GetCollisionResponseToChannel = function(self, ch) return ch == 2 and cap.resp or 2 end
            cap.SetCollisionResponseToChannel = function(self, ch, v) if ch == 2 then cap.resp = v end end
            cap.GetUnscaledCapsuleRadius = function() return cap.r end
            cap.SetCapsuleRadius = function(self, r) cap.r = r end
            local z = obj({ CapsuleComponent = cap, x = x })
            z.K2_GetActorLocation = function() return at(z.x) end
            return z
        end
        Z1, Z2 = zombie(150), zombie(5100)
        ZOMBIES = { Z1, Z2 }
        local k = obj({})
        k.SphereOverlapActors = function(self, w, loc, r, types, cls, ignore, out)
            for _, z in ipairs(ZOMBIES) do if math.abs(z.x - loc.X) <= r then out[#out + 1] = z end end
            return true
        end
        StaticFindObject = function() return obj({}) end
        util = require("mirror.util")
        util.cdo = function() return k end
        ps = require("mirror.personalspace")
        ps.init({})
        function step(n) for i = 1, n or 3 do for _, f in ipairs(TICKS) do f(0.1) end end end
        step()
    """)
    check(L.eval('Z1.CapsuleComponent.resp') == 2 and L.eval('Z1.CapsuleComponent.r') == 28,
          "single player: a zombie next to me blocks pawns, with a fuller capsule")
    check(L.eval('Z2.CapsuleComponent.resp') == 0, "...one next to nobody keeps the game's collision")
    L.execute('Z1.x = 400; step()')
    check(L.eval('Z1.CapsuleComponent.resp') == 2, "between near and far it stays (no flicker)")
    L.execute('Z1.x = 600; step()')
    check(L.eval('Z1.CapsuleComponent.resp') == 0 and L.eval('Z1.CapsuleComponent.r') == 15, "far again: back as the game made it")
    L.execute('ROLE = "host"; Z1.x = 100; step()')
    check(L.eval('Z2.CapsuleComponent.resp') == 2 and L.eval('Z1.CapsuleComponent.resp') == 2,
          "host: zombies at the guest's ghost are kept off it too")
    L.execute('ROLE = "guest"; step()')
    check(L.eval('Z1.CapsuleComponent.resp') == 0 and L.eval('Z2.CapsuleComponent.resp') == 0,
          "guest: its zombies are the host's copies - nothing changed here")
    check("most at once 2" in L.eval('ps.status()'), "counted in the status")
    L.execute('package.loaded["mirror.zombies"] = { is_split = function() return true end }; step()')
    check(L.eval('Z1.CapsuleComponent.resp') == 2, "guest running its own AI (load split): its zombies keep their distance")
    # the player's spot unreadable for a moment: the ghost's zombies still count as near it (a gap ended the list)
    L.execute('package.loaded["mirror.zombies"] = nil; ROLE = "host"; Z1.x = 100; step(); '
              'PLAYER.K2_GetActorLocation = function() error("not ready") end; step()')
    check(L.eval('Z2.CapsuleComponent.resp') == 2, "host: with the player's spot unreadable, the ghost's zombie stays held")


def role_switch_reads_nothing_of_its_own_old_role():
    """Player report 2026-10-29 11:57: a guest took a Realm over as host; for a moment the bridge was still the guest.
    The new host read its own guest pose file as the guest's, and the bridge's guest roster (the old host in slot 0)
    as a third player whose copy wrote mirror_link_guest.txt - "SYMPLYSCK connected" with nobody there, then 30 s
    later "it runs an OLDER SurrounSync"."""
    print("role_switch_reads_nothing_of_its_own_old_role")
    d = tempfile.mkdtemp(prefix="mirror_switch_")
    os.makedirs(os.path.join(d, "SurrounDead"))
    sd = os.path.join(d, "SurrounDead")
    try:
        L = lua()
        L.execute(PEERS_FAKES, d)
        L.execute('''
            link = require("mirror.link")
            link.configure({ transport = "steam" }); link.start_lobby()
            link.open("guest", 1002); link.send(5, "pose as guest"); link.put_blob("hello", "SurrounSync protocol 54 role guest")
            link.open("host")
        ''')
        check(not os.path.exists(os.path.join(sd, "mirror_link_guest.txt")), "guest -> host: my own guest pose file is gone")
        check(not os.path.exists(os.path.join(sd, "mirror_hello_guest.txt")), "...and my own guest blobs")
        check(L.eval('link.poll()') is None, "the new host reads no pose of its own as the guest's")
        L.execute('''
            peers.start({}, "host")
            roster("me 1 1001 guest\\npeer guest host 0 1002 connected SYMPLYSCK\\n")
            peers.tick(1.1)
        ''')
        check(L.eval('#STARTED') == 0, "a roster the bridge wrote as a guest starts no copy on the new host (%d)" % L.eval('#STARTED'))
        L.execute('roster("me 0 1001 host\\npeer host guest 1 1002 connected Ann\\npeer to2 from2 2 1003 connected Bob\\n"); peers.tick(1.1)')
        check(L.eval('#STARTED') == 1 and L.eval('STARTED[1].out') == "to2", "the bridge's host roster is used once it's there")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def peers_give_every_player_their_own_copy():
    print("peers_give_every_player_their_own_copy")
    d = tempfile.mkdtemp(prefix="mirror_peers_")
    os.makedirs(os.path.join(d, "SurrounDead"))
    try:
        L = lua()
        L.execute(PEERS_FAKES, d)
        L.execute('''
            inst = peers._new_instance("to2", "host")
            main_link, copy_link = require("mirror.link"), inst.require("mirror.link")
            main_link.configure({ transport = "file" }); copy_link.configure({ transport = "file" })
            main_link.open("host"); copy_link.open("host", "1003", { out = "to2", inn = "from2" })
            main_link.put_blob("look", "main"); copy_link.put_blob("look", "copy")
        ''')
        check(L.eval('main_link ~= copy_link and copy_link.tags().out == "to2"'), "a copy gets its own link module")
        read = lambda n: open(os.path.join(d, "SurrounDead", n), encoding="utf-8").read() if os.path.exists(os.path.join(d, "SurrounDead", n)) else None
        check((read("mirror_look_host.txt") or "").startswith("main") and (read("mirror_look_to2.txt") or "").startswith("copy"),
              "the copy writes to<slot> files, the main link keeps the two-player names")
        check(L.eval('inst.require("mirror.util") == require("mirror.util")'), "shared helpers (util) are the same module")
        # player report 2026-10-29: a Realm took its creator + one friend, then every further join got "isn't hosting
        # that Realm right now" - the copy's own realmplay was never started and said it hosted nothing
        check(L.eval('inst.require("mirror.realmplay") == require("mirror.realmplay")'),
              "a copy asks the game's own realmplay which Realm it hosts")
        check(L.eval('inst.require("mirror.events") ~= require("mirror.events")'), "per-player state (events) is a copy")
        check(L.eval('debug.getinfo(inst.require("mirror.events").new, "S").short_src:sub(-4) == "#to2"'),
              "a copy's chunk name ends with its tag, so call-site keyed hook/tick slots stay apart")
        check(L.eval('copy_link.bridge_cmd("stop") == false'), "only the main link may command the bridge")
        L.execute('mate = peers._new_instance("to1", "mate")')
        check(L.eval('mate.require("mirror.world") == require("mirror.world")'), "a mate copy uses the host link's world modules")
        check(L.eval('mate.require("mirror.link") ~= require("mirror.link") and mate.require("mirror.link") ~= copy_link'),
              "but has its own link")
        check(L.eval('inst.require("mirror.log") ~= require("mirror.log")'), "a copy's log lines carry its tag")

        # the bridge's player list starts the copies
        L.execute('''
            peers.start({}, "host")
            roster("me 0 1001 host\\npeer host guest 1 1002 connected Ann\\npeer to2 from2 2 1003 connected Bob\\npeer to3 from3 3 1004 connecting Cid\\n")
            peers.tick(1.1)
        ''')
        check(L.eval('#STARTED') == 2, "host: two copies started for guests 2 and 3, guest 1 uses the normal modules (%d)" % L.eval('#STARTED'))
        check(L.eval('STARTED[1].out == "to2" and STARTED[1].inn == "from2" and STARTED[1].role == "host" and STARTED[1].id == "1003"'),
              "copy for slot 2: host role, its tags and id")
        L.execute('peers.tick(1.1); peers.tick(1.1)')
        check(L.eval('#STARTED') == 2, "an unchanged list starts nothing again")
        L.execute('roster("me 0 1001 host\\npeer host guest 1 1002 connected Ann\\npeer to2 from2 2 1009 connected Dan\\npeer to3 from3 3 1004 connecting Cid\\n"); peers.tick(1.1)')
        check(L.eval('#STARTED') == 3 and L.eval('STARTED[3].id') == "1009", "a new player in slot 2 restarts that copy for them")
        L.execute('STOPPED = 0; roster("me 0 1001 host\\npeer host guest 1 1002 connected Ann\\npeer to2 from2 2 1009 silent Dan\\n"); peers.tick(1.1)')
        check(L.eval('STOPPED') == 2, "players who left or went silent: their copies stop (%s)" % L.eval('STOPPED'))
        L.execute('roster("me 0 1001 host\\npeer host guest 1 1002 connected Ann\\npeer to2 from2 2 1009 connected Dan\\npeer to3 from3 3 1004 connecting Cid\\n"); peers.tick(1.1)')
        check(L.eval('#STARTED') == 5 and L.eval('STARTED[4].id') == "1009", "and start again when they're back")
        L.execute('STOPPED = 0')
        L.execute('peers.stop(); STARTED = {}; peers.start({}, "guest"); roster("me 2 1003 guest\\npeer guest host 0 1001 connected Host\\npeer to1 from1 1 1002 connected Ann\\n"); peers.tick(1.1)')
        check(L.eval('STOPPED') == 2, "stop stops every copy")
        check(L.eval('#STARTED') == 1 and L.eval('STARTED[1].role') == "mate" and L.eval('STARTED[1].out') == "to1",
              "guest: a mate copy for the other guest, none for the host link")
        # a Realm host leaves: only the guest in the lowest slot takes it over (report 2026-10-29 22:28: both did)
        L.execute('FIRST, NEXT = peers.first_guest()')
        check(L.eval('FIRST') is False and L.eval('NEXT') == "Ann", "guest in slot 2 with a guest in slot 1: Ann takes the Realm over")
        L.execute('peers.stop(); STARTED = {}; peers.start({}, "guest"); '
                  'roster("me 1 1002 guest\\npeer guest host 0 1001 connected Host\\npeer to2 from2 2 1003 connected Bob\\n"); peers.tick(1.1); '
                  'FIRST = peers.first_guest()')
        check(L.eval('FIRST') is True, "the guest in slot 1 takes it over")
        L.execute('peers.stop(); STARTED = {}; peers.start({}, "guest"); roster("me 1 1002 guest\\npeer guest host 0 1001 connected Host\\n"); '
                  'peers.tick(1.1); FIRST = peers.first_guest()')
        check(L.eval('FIRST') is True, "the only guest takes it over (as before)")

        # ghosts of every copy count
        L.execute('''
            peers.stop(); STARTED = {}; peers.start({}, "host")
            roster("me 0 1001 host\\npeer host guest 1 1002 connected Ann\\npeer to2 from2 2 1003 connected Bob\\n"); peers.tick(1.1)
            local i2 = peers.instances()[1]
            i2.require("mirror.ghost")
            GHOSTS.main = { loc = { X = 0, Y = 0, Z = 0 } }
            GHOSTS.to2 = { loc = { X = 5000, Y = 0, Z = 0 } }
        ''')
        check(L.eval('peers.is_ghost(GHOSTS.main) and peers.is_ghost(GHOSTS.to2) and not peers.is_ghost({})'),
              "is_ghost knows every player's ghost")
        check(L.eval('#peers.ghost_list()') == 2, "ghost_list has both")
        check(L.eval('#peers.ghost_locations(require("mirror.ghost"))') == 1, "ghost_locations leaves out the asking copy's own")
        check(L.eval('peers.ghost_nearest(require("mirror.ghost"), {X=0,Y=0,Z=0}, {X=9000,Y=0,Z=0}, {X=100,Y=0,Z=0})') is True,
              "nearest: my ghost is the nearest player")
        check(L.eval('peers.ghost_nearest(require("mirror.ghost"), {X=0,Y=0,Z=0}, {X=9000,Y=0,Z=0}, {X=4900,Y=0,Z=0})') is False,
              "not when another guest's ghost is nearer")

        # relay: every other copy, never back to the sender, no loops
        L.execute('''
            package.preload["mirror.relaytest"] = function(name, tag)
                local m = { tag = (tag ~= ":preload:" and tag) or "main", got = {} }
                function m.relay_send(p) m.got[#m.got + 1] = p; peers.relay("mirror.relaytest", m, function(o) o.relay_send("again " .. p) end) end
                return m
            end
            package.loaded["mirror.relaytest"] = package.preload["mirror.relaytest"]("mirror.relaytest")
            local i2 = peers.instances()[1]
            r2 = i2.require("mirror.relaytest")
            peers.relay("mirror.relaytest", require("mirror.relaytest"), function(o) o.relay_send("P x") end)
        ''')
        check(L.eval('#r2.got') == 1 and L.eval('r2.got[1]') == "P x" and L.eval('#require("mirror.relaytest").got') == 0,
              "relay reaches the other copies once, not the sender, and doesn't loop")
        L.execute('peers.stop(); peers.start({}, "guest"); r2.got = {}; peers.relay("mirror.relaytest", nil, function(o) o.relay_send("G") end)')
        check(L.eval('#r2.got') == 0, "only the host relays")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def chat_and_voice_reach_every_player():
    print("chat_and_voice_reach_every_player")
    d = tempfile.mkdtemp(prefix="mirror_peers2_")
    os.makedirs(os.path.join(d, "SurrounDead"))
    try:
        L = lua()
        L.execute(PEERS_FAKES, d)
        L.execute('''
            package.loaded["mirror.notify"] = { show = function() end, clear = function() end }
            package.preload["mirror.events"] = function(name, tag)
                local e = {}
                CH = CH or {}
                function e.new(n)
                    local ch = { name = n, out = {}, inb = {}, send = function(self, p) self.out[#self.out + 1] = p end,
                        pump = function(self, fn) for _, p in ipairs(self.inb) do fn(p) end; self.inb = {} end }
                    CH[(tag or "main") .. ":" .. n] = ch
                    return ch
                end
                e.reliable = e.new
                return e
            end
            package.loaded["mirror.events"] = package.preload["mirror.events"]("mirror.events")
            package.loaded["mirror.teleport"] = { command = function() return true end }
            peers.start({}, "host")
            roster("me 0 1001 host\\npeer host guest 1 1002 connected Ann\\npeer to2 from2 2 1003 connected Bob\\n"); peers.tick(1.1)
            i2 = peers.instances()[1]
            c1, c2 = require("mirror.chat"), i2.require("mirror.chat")
            -- the copy's link answers peer_name for its player
            i2.require("mirror.link").peer_name = function() return "Bob" end
        ''')
        L.execute('c1.send("hello all")')
        check(L.eval('#c1.recent(5)') == 1, "my line is in the history once")
        check(L.eval('c1 ~= c2'), "each player's link has its own chat channel")
        check(L.eval('c2.recent(5)[1].text') == "hello all", "and they share one history")
        check(L.eval('CH["main:chat"].out[1]') == "hello all" and L.eval('CH["to2:chat"].out[1]') == "hello all",
              "a line typed once goes to every player's link")
        L.execute('CH["to2:chat"].inb = { "hi from Bob" }; c2.tick()')
        check(L.eval('c1.recent(5)[2].who') == "Bob" and L.eval('c1.recent(5)[2].text') == "hi from Bob",
              "a line from guest 2 shows in the one history with their name")
    finally:
        shutil.rmtree(d, ignore_errors=True)

def settings_pages_cycle_save_and_follow_the_host():
    print("settings_pages_cycle_save_and_follow_the_host")
    d = tempfile.mkdtemp()
    try:
        L = lua()
        L.execute('''
            local d = ...
            ROLE = "host"; BLOBS = {}; SEEN = {}
            package.loaded["mirror.notify"] = { show = function() end, clear = function() end }
            package.loaded["mirror.peers"] = { each = function(_, fn) fn(package.loaded["mirror.link"], nil) end }
            package.loaded["mirror.link"] = { dir = function() return d end,
                put_blob = function(n, s) BLOBS[n] = s end,
                get_blob = function(n) local b = BLOBS[n]; if b ~= SEEN[n] then SEEN[n] = b; return b end end }
            hr = require("mirror.hostrules"); ms = require("mirror.mysettings")
            hr.init(function() return ROLE end); ms.init(function() return ROLE end)
        ''', d.replace("\\", "/"))
        check(L.eval('hr.my_value("itemclean")') == "off" and L.eval('hr.my_value("players")') == "4", "host rules start at their defaults")
        seq = []
        for _ in range(4):
            L.execute('hr.toggle("itemclean")'); seq.append(L.eval('hr.my_value("itemclean")'))
        check(seq == ["10", "20", "40", "off"], "ITEM CLEANUP cycles OFF -> 10 -> 20 -> 40 -> OFF (%s)" % seq)
        L.execute('hr.toggle("joins"); hr.toggle("pvp"); hr.tick()')
        check("joins friends" in (L.eval('BLOBS.rules') or "") and "pvp on" in L.eval('BLOBS.rules'), "the rules blob carries every value")
        L.execute('ROLE = "guest"; package.loaded["mirror.hostrules"] = nil; hr2 = require("mirror.hostrules"); hr2.init(function() return ROLE end)')
        check(L.eval('hr2.value("joins")') == "friends" and L.eval('hr2.get("pvp")') is True,
              "a guest follows the host's blob (and the file kept the host's values)")
        check(L.eval('hr2.can_edit()') is False, "a guest can't edit the host rules")
        L.execute('ms.toggle("messages")')
        check(L.eval('ms.value("messages")') == "important", "CO-OP MESSAGES cycles ALL -> IMPORTANT")
        L.execute('ms.toggle("perf"); ms.toggle("perf"); ms.tick()')
        check(L.eval('BLOBS.gperf') == "low", "a guest sends its GUEST PERFORMANCE to the host (%s)" % L.eval('BLOBS.gperf'))
        L.execute('package.loaded["mirror.mysettings"] = nil; ms2 = require("mirror.mysettings")')
        check(L.eval('ms2.value("messages")') == "important" and L.eval('ms2.value("perf")') == "low", "my settings are saved on this PC")
        check(abs(L.eval('ms2.PERF_SHARE.low') * 15000 - 6000) < 1, "LOW = 60 m zombie copy range")
        with open(os.path.join(d, "mirror_host_settings.txt"), "w") as f:
            f.write("pvp on\nitemclean on\nloadsplit off\n")
        L.execute('ROLE = "host"; package.loaded["mirror.hostrules"] = nil; hr3 = require("mirror.hostrules"); hr3.init(function() return ROLE end)')
        check(L.eval('hr3.my_value("itemclean")') == "20" and L.eval('hr3.my_value("teleport")') == "on",
              "an old on/off settings file still loads (cleanup on = 20 min, new rules at defaults)")
    finally:
        shutil.rmtree(d, ignore_errors=True)

def a_realm_plays_by_its_owners_rules():
    """user 2026-10-30 'owner rules': in a Realm only its owner sets the rules (the server keeps them), whoever hosts;
    the host plays by the server's, a change of the owner's goes to the server and isn't undone by its older copy."""
    print("a_realm_plays_by_its_owners_rules")
    d = tempfile.mkdtemp()
    try:
        L = lua()
        L.execute('''
            local d = ...
            NOW = 0; os.clock = function() return NOW end
            ROLE = "host"; BLOBS = {}; SEEN = {}; NOTES = {}; PUSHES = {}
            package.loaded["mirror.notify"] = { show = function(m) NOTES[#NOTES + 1] = m end, clear = function() end }
            package.loaded["mirror.peers"] = { each = function(_, fn) fn(package.loaded["mirror.link"], nil) end }
            package.loaded["mirror.link"] = { dir = function() return d end, reset_blob = function() end,
                put_blob = function(n, s) BLOBS[n] = s end,
                get_blob = function(n) local b = BLOBS[n]; if b ~= SEEN[n] then SEEN[n] = b; return b end end }
            hr = require("mirror.hostrules")
            hr.init(function() return ROLE end)
            REALM = nil
            hr.set_realm(function() return REALM end,
                function(id, rules, cb) PUSHES[#PUSHES + 1] = { id = id, rules = rules, cb = cb } end)
            function note_has(s) for _, m in ipairs(NOTES) do if m:find(s, 1, true) then return true end end return false end
            function file() local f = io.open(d .. "/mirror_host_settings.txt"); local s = f and f:read("*a") or ""; if f then f:close() end; return s end
        ''', d.replace("\\", "/"))
        # hosting someone else's Realm: the owner's rules from the server, into the Realm's file and out to the guests
        L.execute('REALM = { id = "R1", owner = false, rules = "pvp on players 2 debugmenu off" }; hr.tick()')
        check(L.eval('hr.my_value("pvp")') == "on" and L.eval('hr.my_value("players")') == "2"
              and L.eval('hr.my_value("debugmenu")') == "off" and L.eval('hr.my_value("teleport")') == "on",
              "a host in a Realm plays by the owner's rules (keys they lack keep their value)")
        check("pvp on" in L.eval("file()") and "debugmenu off" in (L.eval("BLOBS.rules") or ""),
              "...saved to the Realm's settings file and sent to the guests")
        check(L.eval("hr.can_edit()") is False and L.eval("hr.note()") == "The Realm's rules - only its owner can change them.",
              "a host who isn't the owner can't edit them, and the page says so")
        L.execute('hr.toggle("debugmenu"); hr.tick()')
        check(L.eval('hr.my_value("debugmenu")') == "off" and L.eval("#PUSHES") == 0
              and L.eval('note_has("Only the Realm\'s owner can change its rules.")'),
              "a non-owner host's toggle changes nothing, sends nothing and tells them why")
        L.execute('REALM.rules = "pvp off players 3 debugmenu off"; hr.tick()')
        check(L.eval('hr.my_value("pvp")') == "off" and L.eval('hr.my_value("players")') == "3",
              "the owner's later change (in the next heartbeat) applies on the host")
        # the owner hosting: a change goes to the server; the server's older copy doesn't undo it meanwhile
        L.execute('REALM.owner = true; hr.tick(); hr.toggle("debugmenu")')
        check(L.eval("#PUSHES") == 1 and L.eval("PUSHES[1].id") == "R1" and "debugmenu on" in L.eval("PUSHES[1].rules")
              and "players 3" in L.eval("PUSHES[1].rules") and L.eval('hr.my_value("debugmenu")') == "on",
              "the owner hosting: their toggle applies and goes to the server with every rule")
        check(L.eval("hr.note()") == "Your Realm's rules. Everyone in it plays by them, whoever hosts.",
              "...and the page tells the owner the rules are theirs")
        L.execute("NOW = 5; hr.tick()")
        check(L.eval('hr.my_value("debugmenu")') == "on", "the server's older rules don't undo the change while it's on its way")
        L.execute('PUSHES[1].cb(true); REALM.rules = PUSHES[1].rules; NOW = 6; hr.tick()')
        check(L.eval('hr.my_value("debugmenu")') == "on" and "debugmenu on" in L.eval("file()"), "...and it holds once the server has it")
        L.execute('hr.toggle("pvp"); NOW = 7; PUSHES[2].cb(false, nil, "owner_only"); hr.tick()')
        check(L.eval('note_has("Couldn\'t save the Realm\'s rules (owner_only).")') and L.eval('hr.my_value("pvp")') == "off",
              "a refused change is reported and the server's rules come back")
        L.execute('hr.toggle("pvp"); NOW = 80; hr.tick()')
        check(L.eval('hr.my_value("pvp")') == "off", "an unanswered change lets the server's rules back in after 60 s")
        # a Realm the server has no rules for (made before): its owner sends theirs, once a minute at most
        L.execute('PUSHES = {}; REALM = { id = "R2", owner = true, rules = nil }; NOW = 100; hr.tick(); hr.tick()')
        check(L.eval("#PUSHES") == 1 and L.eval("PUSHES[1].id") == "R2" and L.eval("PUSHES[1].rules:find('pvp off', 1, true)") is not None,
              "the owner hosting a Realm with no rules on the server sends theirs, once")
        L.execute('PUSHES[1].cb(true); NOW = 120; hr.tick()')
        check(L.eval("#PUSHES") == 1, "...not again within the minute")
        L.execute('PUSHES = {}; REALM = { id = "R3", owner = false, rules = nil }; NOW = 300; hr.tick()')
        check(L.eval("#PUSHES") == 0, "a host who isn't the owner never sends rules for a Realm")
        # the owner visiting as a guest: they edit a copy of the host's rules, sent to the server; their own stay
        L.execute('ROLE = "guest"; REALM = { id = "R1", owner = true, rules = "pvp off" }; '
                  'BLOBS.rules = "pvp off itemclean off loadsplit off players 4 joins ask teleport on weather on debugmenu on"; '
                  'MINE = hr.my_value("pvp"); PUSHES = {}; NOTES = {}; hr.toggle("pvp")')
        rows = {r["key"]: r["text"] for r in L.eval("hr.rows()").values()}
        check(rows.get("pvp") == "ON" and L.eval("#PUSHES") == 1 and "pvp on" in L.eval("PUSHES[1].rules")
              and L.eval('hr.my_value("pvp")') == L.eval("MINE"),
              "the owner visiting: the page shows their change, it goes to the server, their own settings stay (%s)" % rows.get("pvp"))
        L.execute('BLOBS.rules = PUSHES[1].rules')
        rows = {r["key"]: r["text"] for r in L.eval("hr.rows()").values()}
        check(rows.get("pvp") == "ON" and L.eval("hr.value('pvp')") == "on", "...until the host plays by it")
        L.execute('REALM.owner = false; NOTES = {}; PUSHES = {}; hr.toggle("pvp")')
        check(L.eval("#PUSHES") == 0 and L.eval('note_has("Only the Realm\'s owner")'), "a guest who isn't the owner can't change them")
        # outside a Realm nothing changes: the host edits their own, nothing goes to a server
        L.execute('ROLE = "host"; REALM = nil; PUSHES = {}; hr.toggle("weather")')
        check(L.eval("hr.can_edit()") is True and L.eval("#PUSHES") == 0 and L.eval("hr.note()") is None,
              "outside a Realm the host edits their own rules and nothing goes to the server")
        # kit 2026-10-30 20:09:09: a guest taking a Realm over played ~1 s by the Realm file's older rules before the tick
        rf = os.path.join(d, "realm_rules.txt")
        with open(rf, "w") as f:
            f.write("pvp off\ndebugmenu on\nplayers 4\n")
        L.execute('REALM = { id = "R5", owner = false, rules = "pvp on debugmenu off" }; hr.use_file(...)', rf.replace("\\", "/"))
        check(L.eval('hr.my_value("debugmenu")') == "off" and L.eval('hr.my_value("pvp")') == "on"
              and L.eval('hr.my_value("players")') == "4",
              "taking a Realm over: the owner's rules apply the moment its file is loaded, before any tick")
        check("debugmenu off" in open(rf).read(), "...and go into the Realm's file")
        L.execute('REALM = nil; hr.use_file(nil)')
        check(L.eval('hr.my_value("debugmenu") == file():match("debugmenu (%w+)") and hr.my_value("pvp") == file():match("pvp (%w+)")'),
              "...back home my own file's rules again")
        # kit 2026-10-30: the first send of a Realm's rules failing on the server gave a red notice every minute
        L.execute('REALM = { id = "R6", owner = true, rules = nil }; PUSHES = {}; NOTES = {}; NOW = 500; hr.tick()')
        L.execute('PUSHES[1].cb(false, nil, "server_error x"); NOW = 561; hr.tick(); PUSHES[2].cb(false, nil, "server_error x");'
                  ' NOW = 622; hr.tick(); PUSHES[3].cb(false, nil, "server_error x")')
        check(L.eval("#PUSHES") == 3 and L.eval("#NOTES") == 1,
              "the Realm's rules failing to reach the server: retried each minute, told once (%s notices)" % L.eval("#NOTES"))
        L.execute('REALM.rules = PUSHES[3].rules; NOW = 700; hr.tick(); hr.toggle("pvp"); PUSHES[#PUSHES].cb(false, nil, "server_error y")')
        check(L.eval("#NOTES") == 2 and L.eval('note_has("server_error y")'), "...the owner's own change failing is still told")
        # a bridge older than the rules verb (Sentinel R1): one log line, no red notice every minute, nothing more sent
        L.execute('REALM = { id = "R4", owner = true, rules = nil }; PUSHES = {}; NOTES = {}; NOW = 1000; hr.tick()')
        L.execute('PUSHES[1].cb(false, nil, "bad_command unknown Realm command rules"); NOW = 1100; hr.tick(); NOW = 1200; hr.tick()')
        check(L.eval("#PUSHES") == 1 and L.eval("#NOTES") == 0, "an old bridge (bad_command): no notice, no more sends")
    finally:
        shutil.rmtree(d, ignore_errors=True)

def reshade_follows_the_syncfx_switch():
    """User 2026-10-30: ReShade off when SyncFX goes off (GPU crash tests). ReShade's dxgi.dll loads with the game, so
    MY SETTINGS' SyncFX switch moves it for the next start through SyncFX's own syncfx/reshade.lua."""
    print("reshade_follows_the_syncfx_switch")
    src = os.path.join(os.environ["USERPROFILE"], "Desktop", "DreadFX", "mod", "SyncFX", "Scripts", "syncfx", "reshade.lua")
    if not os.path.exists(src):
        check(False, "SyncFX's reshade.lua is at %s" % src)
        return
    d = tempfile.mkdtemp(prefix="reshade-")
    try:
        w64 = os.path.join(d, "Win64")
        fx = os.path.join(w64, "ue4ss", "Mods", "SyncFX")
        os.makedirs(os.path.join(fx, "Scripts", "syncfx"))
        shutil.copy(src, os.path.join(fx, "Scripts", "syncfx", "reshade.lua"))
        dll = b"MZ ... ReShade by crosire ..."
        with open(os.path.join(w64, "dxgi.dll"), "wb") as f:
            f.write(dll)
        open(os.path.join(w64, "ReShade.ini"), "w").close()
        L = lua()
        L.globals().W64 = w64
        L.execute('ml = require("mirror.modlist"); ml.configure{ io_root = W64 .. "\\\\", reset = true }')
        top = lambda: sorted(x for x in os.listdir(w64) if x != "ue4ss")
        check(L.eval('ml.follow_reshade(false)') == "off" and top() == ["ReShade.ini", "dxgi.dll.syncfx-off"],
              "SyncFX switched off: ReShade's dxgi.dll is set aside for the next start (%s)" % top())
        check(L.eval('ml.follow_reshade(true)') is None and top() == ["ReShade.ini", "dxgi.dll.syncfx-off"],
              "SyncFX switched on with its own F8 switch off (nothing saved): ReShade stays off")
        with open(os.path.join(fx, "SyncFX.user.ini"), "w") as f:
            f.write("enabled = on\n")
        check(L.eval('ml.follow_reshade(true)') == "on" and top() == ["ReShade.ini", "dxgi.dll"]
              and open(os.path.join(w64, "dxgi.dll"), "rb").read() == dll,
              "SyncFX switched on with F8 on: the same dxgi.dll comes back")
        with open(os.path.join(w64, "dxgi.dll"), "wb") as f:
            f.write(b"MZ ... another dxgi proxy ...")
        check(L.eval('ml.follow_reshade(false)') is None and top() == ["ReShade.ini", "dxgi.dll"],
              "a dxgi.dll that isn't ReShade is left alone")
        shutil.rmtree(os.path.join(fx, "Scripts"))
        check(L.eval('ml.follow_reshade(false)') is None, "a SyncFX without reshade.lua: nothing happens")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def mods_switch_restart_and_match_the_host():
    print("mods_switch_restart_and_match_the_host")
    d = tempfile.mkdtemp(prefix="mods-")
    try:
        w64 = os.path.join(d, "SurrounDead", "Binaries", "Win64")
        mods = os.path.join(w64, "ue4ss", "Mods")
        paks = os.path.join(d, "SurrounDead", "Content", "Paks")
        for m in ("SurrounSync", "shared", "AimRun", "HeadshotBrains", "Keybinds", "SelfOn", "ConsoleEnablerMod", "SyncFX"):
            os.makedirs(os.path.join(mods, m))
        open(os.path.join(mods, "SelfOn", "enabled.txt"), "w").close()
        with open(os.path.join(mods, "mods.txt"), "w", newline="") as f:
            f.write("SurrounSync : 1\r\nAimRun : 1\r\nHeadshotBrains : 0\r\nConsoleEnablerMod : 0\r\nSyncFX : 0\r\n"
                    "; Built-in keybinds, do not move up!\r\nKeybinds : 1\r\n")
        with open(os.path.join(mods, "mods.json"), "w") as f:
            f.write('[\n    {\n        "mod_name": "AimRun",\n        "mod_enabled": true\n    }\n]\n')
        os.makedirs(os.path.join(paks, "~mods"))
        os.makedirs(os.path.join(paks, "LogicMods"))
        for n in ("Cars_P.pak", "Cars_P.ucas", "Cars_P.utoc", "Old_P.pak.off"):
            open(os.path.join(paks, "~mods", n), "w").close()
        L = lua()
        g = L.globals()

        def listing(p, want_dir):
            if not os.path.isdir(p):
                return None
            return L.table_from(sorted(x for x in os.listdir(p) if os.path.isdir(os.path.join(p, x)) == want_dir))
        g.pydirs = lambda p: listing(p, True)
        g.pyfiles = lambda p: listing(p, False)
        g.W64, g.PAKS = w64, paks
        L.execute('ml = require("mirror.modlist"); ml.configure{ io_root = W64 .. "\\\\", list_win64 = W64, list_paks = PAKS, reset = true,'
                  ' lister = { dirs = function(p) return pydirs(p) end, files = function(p) return pyfiles(p) end } }; ml.init()')
        L.execute('function rows(peer) local m = ml.model(peer); local t = {}; for _, r in ipairs(m.rows) do t[r.id] = r end; return m, t end')
        m, r = L.eval('rows()')
        ids = sorted(list(r.keys()))
        check(ids == sorted(["AimRun", "ConsoleEnablerMod", "HeadshotBrains", "Keybinds", "SelfOn", "pak:Cars_P.pak", "pak:Old_P.pak"]),
              "lists UE4SS and pak mods, not SurrounSync or shared (%s)" % ids)
        check(r["AimRun"]["on"] and not r["HeadshotBrains"]["on"] and r["SelfOn"]["on"] and r["pak:Cars_P.pak"]["on"] and not r["pak:Old_P.pak"]["on"],
              "on/off read from mods.txt, enabled.txt and .pak/.pak.off")
        check(not m["restart"], "nothing changed: no restart")
        loaded = L.eval('ml.loaded_ids()')
        check(loaded["SelfOn"] and loaded["pak:Cars_P.pak"] and not loaded["HeadshotBrains"], "running set includes enabled.txt mods and paks")

        L.execute('ml.toggle("HeadshotBrains"); ml.toggle("SelfOn"); ml.toggle("pak:Cars_P.pak"); ml.toggle("pak:Old_P.pak"); ml.toggle("AimRun")')
        txt = open(os.path.join(mods, "mods.txt"), newline="").read()
        check("HeadshotBrains : 1\r\n" in txt and "AimRun : 0\r\n" in txt and "SelfOn : 0\r\n; Built-in" in txt,
              "mods.txt switched in place, CRLF kept, a new line goes above the keybinds block (%r)" % txt)
        check(os.path.exists(os.path.join(mods, "SelfOn", "enabled.txt.off")) and not os.path.exists(os.path.join(mods, "SelfOn", "enabled.txt")),
              "a self-enabled mod's enabled.txt is set aside")
        check('"mod_enabled": false' in open(os.path.join(mods, "mods.json")).read(), "mods.json follows")
        pk = sorted(os.listdir(os.path.join(paks, "~mods")))
        check(pk == ["Cars_P.pak.off", "Cars_P.ucas.off", "Cars_P.utoc.off", "Old_P.pak"], "pak and its .ucas/.utoc renamed together (%s)" % pk)
        m, r = L.eval('rows()')
        check(m["restart"] and r["HeadshotBrains"]["note"] == "on after a restart" and r["AimRun"]["note"] == "off after a restart",
              "changes wait for a restart and say so")
        check(not L.eval('ml.loaded_ids()')["HeadshotBrains"], "what runs now doesn't change")
        L.execute('ml.toggle("HeadshotBrains"); ml.toggle("AimRun"); ml.toggle("SelfOn"); ml.toggle("pak:Cars_P.pak"); ml.toggle("pak:Old_P.pak")')
        check(not L.eval('ml.model().restart'), "switching back: no restart needed")
        check(os.path.exists(os.path.join(mods, "SelfOn", "enabled.txt")), "enabled.txt comes back")

        # the host runs HeadshotBrains and a pak I don't have, not AimRun; ConsoleEnablerMod is client-only
        L.execute('KIND = { ConsoleEnablerMod = "client" }; peer = { set = { HeadshotBrains = true, ["pak:Cars_P.pak"] = true, ["pak:Map_P.pak"] = true,'
                  ' ConsoleEnablerMod = true, SelfOn = true, Keybinds = true }, who = "Host", host = true,'
                  ' kind = function(id) return KIND[id] or "unknown" end }')
        m, r = L.eval('rows(peer)')
        check(r["AimRun"]["differs"] and r["AimRun"]["note"] == "Host has it OFF" and r["HeadshotBrains"]["note"] == "Host has it ON",
              "rows show the host's choice where it differs")
        check(not r["ConsoleEnablerMod"]["differs"], "a client-only mod never needs to match")
        check(r["pak:Map_P.pak"]["locked"] and r["pak:Map_P.pak"]["text"] == "MISSING", "a mod only the host has shows as MISSING")
        check(m["can_match"] and m["missing"] == 1, "a guest can MATCH HOST")
        n, missing = L.eval('ml.match(peer)')
        check(n == 2 and list(missing.values()) == ["Map_P.pak"], "match switches 2 and names the missing one (%s, %s)" % (n, list(missing.values())))
        m, r = L.eval('rows(peer)')
        check(not r["AimRun"]["differs"] and not r["HeadshotBrains"]["differs"] and not r["ConsoleEnablerMod"]["on"] and m["restart"],
              "after MATCH only the missing one differs, the client mod is left alone, restart asked")
        check(not L.eval('ml.model({ set = {}, who = "G", host = false }).can_match'), "the host doesn't get MATCH")

        # SyncFX: not in the MODS list, never matched; its switch is on top of MY SETTINGS (mods.txt, next start)
        check("SyncFX" not in ids, "SyncFX isn't in the MODS list")
        L.execute('peer2 = { set = { SyncFX = true }, who = "Host", host = true, kind = function() return "unknown" end }')
        m, r = L.eval('rows(peer2)')
        check("SyncFX" not in list(r.keys()) and m["missing"] == 0, "a host's SyncFX is never MISSING for the guest")
        L.execute('ml.match(peer2)')
        check(L.eval('(select(2, ml.state("SyncFX")))') is False, "MATCH HOST leaves SyncFX alone")
        L.execute('package.loaded["mirror.link"] = { dir = function() return W64 end, put_blob = function() end }'
                  '; ms = require("mirror.mysettings")')
        first = L.eval('ms.rows()[1]')
        check(first.key == "syncfx" and first.tag == "Optimizes Performance" and first.tag_color.G > first.tag_color.R
              and first.text == "OFF" and "FPS" not in first.hint and "F6" in first.hint,
              "MY SETTINGS starts with SYNCFX GRAPHICS tagged 'Optimizes Performance' in green, OFF, no FPS warning")
        L.execute('ml.set("SyncFX", true)')
        first = L.eval('ms.rows()[1]')
        check("SyncFX : 1\r\n" in open(os.path.join(mods, "mods.txt"), newline="").read() and first.text == "ON"
              and "next game start" in first.hint, "switching it writes mods.txt and says it starts next time")
        check(L.eval('ms.rows()[2].key') == "nametags", "the other settings follow it")
    finally:
        shutil.rmtree(d, ignore_errors=True)


for t in (drops_pickup_reaches_every_guest, drops_rejoin_pairs_the_saved_pickups, drops_pile_pickups_take_only_their_own_item, loose_magazine_picked_up_by_both_at_once_is_kept_once,corpse_looted_at_the_same_moment_keeps_one_copy,corpse_partial_takes_at_the_same_moment_keep_the_total,same_moment_container_takes_keep_one_copy, same_moment_partial_takes_keep_the_total, refused_put_in_taken_back_tells_the_host_nothing,one_take_fires_both_removed_hooks_and_is_sent_once, item_used_out_of_a_container_is_a_take, player_rip_in_a_container_is_a_take, bench_output_made_on_a_guest_reaches_the_host, ui_no_room_removal_is_not_a_take, lights_come_back_on_a_respawned_ghost, perf_run_puts_the_outer_step_back, fs_write_is_whole_or_old, utf8_cut_never_splits_a_character, crumb_keeps_the_last_64_steps,unanswered_join_keeps_the_friends_list, coop_tab_in_a_realm_has_nothing_of_it, bag_put_back_after_a_take_reaches_the_host, container_class_checks_are_cached, stacking_moves_reach_the_other_game, loot_take_for_a_container_the_host_lacks_is_kept, car_trunks_go_by_the_cars_name, mods_switch_restart_and_match_the_host, loot_take_without_a_uid_pairing_finds_the_item, settings_pages_cycle_save_and_follow_the_host, zombie_archetype_effects_reach_copies, group_split_host_decides_follow_and_ignores_followers, loot_open_shows_the_hosts_items_at_once, group_split_leader_and_follower_agree, vehicles_seat_four_players_by_slot, loot_asks_the_host_again_on_every_reopen, peers_give_every_player_their_own_copy, chat_and_voice_reach_every_player, reliable_events_survive_pauses_and_restarts, plain_events_skip_late_lines_and_bound_the_window, jig_probe_names_what_a_patch_removed, jig_price_follows_the_traders_table, find_by_id_reuses_the_object_it_found, tooltip_never_calls_into_null_objects, settlement_camps_follow_the_host, military_trader_follows_the_host, role_switch_reads_nothing_of_its_own_old_role, new_realm_character_gets_the_starting_kit, realm_takes_the_creators_difficulty, coop_guest_runs_the_hosts_world_settings, zombies_stop_at_arms_length, human_copies_hold_the_hosts_weapon, hounds_bark_when_they_come_for_you, airdrops_follow_the_host, event_sites_follow_the_host, a_destroyed_sites_address_can_come_back_as_a_new_site, posepack_recovers_lost_packets, link_blob_comes_back_after_reset, a_player_in_the_game_menu_is_not_a_frozen_game, link_restart_puts_the_games_blobs_again, link_keeps_putting_the_hello, clockmap_quiet_places_without_stats, util_null_objects_are_invalid,
          jig_stats_copy_the_asset_defaults, weapon_slots_get_their_stats, tactical_reads_only_lights_the_class_has, host_rules_and_mod_list_survive_a_full_disk,
          vehicles_keep_this_worlds_fuel, car_horn_reaches_the_other_game, raiders_can_hit_the_guests_ghost, harvest_uses_up_nodes_once, zombie_spawn_pins_hold_or_refuse,
          zombie_copies_take_the_hosts_look,
          copy_deaths_and_removals_wait_for_the_animation_gate,
          animgate_runs_waiting_calls_once_animation_is_on_the_game_thread,
          copy_radiation_is_taken_back, nests_keep_real_health, horde_beacon_runs_only_on_the_host, goto_and_bring_move_only_your_own_player, backpack_tooltip_reads_the_item_once, foreach_keeps_temporary_arrays_alive, backpack_names_travel_with_the_item, beds_get_a_rename_row_and_shared_names,
          ghost_swims_without_its_own_water_detection, a_player_sitting_down_sits_on_the_other_screen, all_players_must_sleep_before_the_night_is_skipped, sleeping_screen_stays_until_everyone_sleeps, door_code_locks_keep_other_players_out_until_they_type_it, ghost_stands_on_cars_but_never_pushes_them,zombies_go_after_the_ghost_again_after_a_save, a_ghost_the_game_removed_is_let_go_and_made_again, a_ghost_destroyed_for_a_save_is_never_touched_again, zombie_loot_tables_are_all_looked_up_and_misses_stay_few, a_host_zombie_hit_reaches_a_guest_with_three_players, audio_spatializes_and_shares_without_echo,
          throws_and_mines_reach_the_other_game, map_pings_reach_the_other_game, keycard_doors_open_on_both_games, doors_of_one_master_are_found_in_one_walk, doors_forget_the_old_world_at_a_load, refused_realm_join_disarms_the_realm, horde_rewards_reach_the_other_game, loose_magazine_rounds_reach_the_picker, a_picked_up_items_address_can_come_back_as_a_new_drop, loose_magazine_picked_up_without_hooks_still_gets_its_rounds, ground_weapon_attachments_reach_the_other_game, ground_weapon_parts_changed_by_both_at_once_keep_both_changes, ghost_gun_in_hand_is_known, ghost_wears_its_players_face_beard_and_tattoos, ghost_look_is_applied_over_frames, missing_zombie_looks_get_loaded,
          random_and_debug_weather_is_shared,
          trader_stock_is_the_hosts, instances_walk_once_then_follow_beginplay, grouped_classes_share_one_walk, walk_skip_is_measured_after_a_load, unloaded_tracked_classes_cost_few_lookups,
          link_reads_only_blobs_the_index_says_changed, corpse_loot_reaches_every_player, host_settled_corpses_cost_almost_nothing,
          human_corpses_get_their_inventory_made_first, the_nuke_goes_off_on_both_screens,
          the_host_can_switch_the_debug_menu_off_for_everyone, a_realm_plays_by_its_owners_rules,
          the_message_of_the_day_shows_once_in_a_world_and_on_the_main_menu, a_new_ghost_leaves_no_name_tag_behind,
          an_ended_zombie_is_never_read_from_the_zombie_list, a_copy_the_game_keeps_removing_is_held_back,
          reshade_follows_the_syncfx_switch,
          standing_hooks_skip_the_lookup, hook_lookups_share_one_budget, find_remembers_misses, container_items_keep_their_cell_and_rotation, loot_skips_containers_gone_since_listed, bags_are_never_consumed_and_twin_grids_are_counted,
          a_turret_switched_off_is_off_for_everyone, a_teleport_landing_lets_off_the_first_hits, load_split_waits_after_a_respawn_and_for_a_teleport, load_split_switches_only_when_both_agree, load_split_hands_the_ai_to_the_guest, a_looping_reload_stops_on_the_other_game,
          loot_first_open_never_undoes_a_take_the_host_has_not_acked, loot_first_open_takes_over_an_older_list_without_takes,
          twin_compartments_are_merged_into_one):
    try:
        t()
    except Exception as e:
        failed += 1
        print("  FAIL %s raised %s" % (t.__name__, e))
print()
print("ALL PASSED" if failed == 0 else "%d FAILED" % failed)
sys.exit(1 if failed else 0)
