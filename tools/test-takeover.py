"""Realm takeover in place (mirror/realmplay.lua promote): a guest whose Realm host left becomes the host without a
load. Runs the real realmplay.lua with stand-ins for the session, menu, zombies and the Realm store/bridge.

    PYTHONPATH=tools/testpkg python tools/test-takeover.py
"""
import os
import sys

try:
    from lupa import lua54
except ImportError:
    print("needs lupa: pip install --target tools/testpkg lupa, then PYTHONPATH=tools/testpkg")
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "mod", "SurrounSync", "Scripts")
fails = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)


SETUP = r'''
local scripts = ...
package.path = scripts .. "\\?.lua;" .. scripts .. "\\mirror\\?.lua;" .. package.path
CALLS, SAID, SENT, LOGS = {}, {}, {}, {}
local function called(n) CALLS[#CALLS + 1] = n end
function count(n) local c = 0; for _, x in ipairs(CALLS) do if x == n then c = c + 1 end end; return c end
-- a module whose unlisted functions only record that they were called
local function fake(name, t)
    return setmetatable(t or {}, { __index = function(_, k) return function() called(name .. "." .. k) end end })
end
local function out(l) return function(m) LOGS[#LOGS + 1] = l .. " " .. tostring(m) end end
package.preload["mirror.log"] = function() return { info = out("INFO"), warn = out("WARN"), error = out("ERROR"), debug = function() end } end
package.preload["mirror.util"] = function()
    -- (players: { a = address, name = full name }; mark/marked as util.lua's)
    return { safe = function(fn, _, ...) return pcall(fn, ...) end, valid = function(o) return o ~= nil end,
             addr = function(o) return type(o) == "table" and o.a or 1 end, ensure_hook = function() return true end,
             mark = function(t, o) if o then t[o.a or 1] = o.name or true end end,
             marked = function(t, o) local n = o and t[o.a or 1]; return n ~= nil and (n == true or n == o.name) end }
end
TICKS = {}
PLAYER = { a = 1, name = "BP_PlayerCharacter_C_1" }
package.preload["mirror.game"] = function()
    return fake("game", { on_tick = function(fn) TICKS[#TICKS + 1] = fn end, player = function() return PLAYER end })
end
package.preload["mirror.notify"] = function() return { show = function(m, k) SAID[#SAID + 1] = m end, clear = function() end } end
LOGFILE = nil
package.preload["mirror.slotguard"] = function()
    return fake("slotguard", { log_read = function() return nil end, log_write = function(t) LOGFILE = t; return true end,
        log_clear = function() LOGFILE = nil end, log_exists = function() return LOGFILE ~= nil end,
        is_own = function(s) return s == "MySave" end,
        read_realm = function() return { ["Level.sav"] = "w" }, { ["Player.sav"] = "p" } end })
end
RID = "4R5BJRNGWF"
HEAD, PENDING, LIVE_SIDE = 5, nil, nil
package.preload["mirror.realm"] = function()
    return fake("realm", { configure = function() end, enabled = function() return true end,
        valid_id = function(id) return id == RID end, code = function(id) return "R-" .. id end,
        find = function(id) return { id = id, name = "Camp Test", gen = 5, host = LISTHOST } end, head = function() return HEAD end,
        world = function() return { side = { ["mirror_host_settings.txt"] = "old" } } end,
        open_live = function(id, side) LIVE_SIDE = side; return true end, live_dir = function() return "LIVE" end,
        read_live = function() return {} end, service = function() return "on" end, service_at = function() return os.time() + 5 end,
        lease = function() return "held" end, tick = function() end,
        pending = function() return PENDING end, drop_pending = function() PENDING = nil; called("realm.drop_pending") end,
        stage_upload = function() return true end, store_character = function() called("realm.store_character"); return true end,
        accept_download = function(id, gen) HEAD = gen; return gen end,
        send = function(verb, args, cb) SENT[#SENT + 1] = { verb = verb, args = args, cb = cb } end })
end
package.preload["mirror.version"] = function() return { VERSION = "test" } end
package.preload["mirror.fs"] = function() return { read = function() return "mine" end } end
package.preload["mirror.hostrules"] = function() return fake("hostrules", { own_file = function() return "own" end }) end
package.preload["mirror.realmmembers"] = function() return fake("members", { tick = function() end }) end
package.preload["mirror.link"] = function() return fake("link", { lobby = function() return nil end }) end
package.preload["mirror.difficulty"] = function() return fake("difficulty") end
READY, HANDOVER = false, 0
package.preload["mirror.zombies"] = function()
    return { begin_takeover = function() called("zombies.begin_takeover") end,
             takeover_ready = function() return READY end, end_takeover = function() called("zombies.end_takeover") end }
end
package.preload["mirror.vehicles"] = function()
    return { keep_made_cars = function() called("vehicles.keep_made_cars"); return 1 end }
end
PROMOTE = { realm = RID, own = "MySave", own_stamp = "st", coop = "Coop_2" }
SAVING, CUR = false, "Coop_2"
package.preload["mirror.session"] = function()
    return fake("session", { promote_realm = function() called("session.promote_realm"); return PROMOTE end,
        promote_failed = function() called("session.promote_failed") end,
        saving = function() return SAVING end, save_now = function() called("session.save_now") end,
        current_name = function() return CUR end, loading = function() return false end, state = function() return "idle" end,
        set_data_dir = function(fn) DATA_DIR = fn end, set_realm_slot = function(fn) REALM_SLOT = fn end,
        realm_joined = function() return nil end, on_main_menu = function() end })
end
ROLE = "guest"
package.preload["mirror.menu"] = function()
    return fake("menu", { role = function() return ROLE end, realm_host = function() called("menu.realm_host"); ROLE = "host" end,
        realm_stop = function() called("menu.realm_stop") end })
end
NotifyOnNewObject = function() end
realmplay = require("mirror.realmplay")
realmplay.init({ realms = { enabled = true } })
function run(secs, dt)
    dt = dt or 0.1
    for _ = 1, math.floor(secs / dt + 0.5) do for _, fn in ipairs(TICKS) do fn(dt) end end
end
function last(verb) for i = #SENT, 1, -1 do if SENT[i].verb == verb then return SENT[i], i end end end
function answer(verb, ok, words) local s = last(verb); s.answered = true; s.cb(ok, words, table.concat(words, " ")) end
function st() return (realmplay.state()) end
function slot() return (REALM_SLOT()) end
function nclaims() local n = 0; for _, s in ipairs(SENT) do if s.verb == "claim" then n = n + 1 end end; return n end
'''


def fresh():
    L = lua54.LuaRuntime()
    L.execute(SETUP, SCRIPTS)
    return L


def clean_end_takes_over_in_place():
    print("clean_end_takes_over_in_place")
    L = fresh()
    L.execute('STARTED = realmplay.promote(RID, "76561100"); AGAIN = realmplay.promote(RID, "76561100")')
    check(L.eval('STARTED') is True and L.eval('AGAIN') is False, "promote starts once")
    check(L.eval('count("zombies.begin_takeover")') == 1, "the host's zombies start becoming mine")
    L.execute('run(1.0)')
    check(L.eval('count("session.promote_realm")') == 0 and L.eval('st()') == "handover",
          "the session stays joined while the hand-over runs")
    check(L.eval('slot()') is None, "no Realm save claimed yet (the co-op session's firewall still guards it)")
    L.execute('READY = true; run(0.1)')
    check(L.eval('count("session.promote_realm")') == 1 and L.eval('st()') == "switching",
          "hand-over done: the co-op session hands its slots over")
    check(L.eval('count("vehicles.keep_made_cars")') == 1, "the car made for the old host's drive is kept as this world's")
    check(L.eval('LOGFILE.realm') == L.eval('RID') and L.eval('LOGFILE.realm_role') is None
          and L.eval('LOGFILE.coop') == "Coop_2" and L.eval('LOGFILE.own') == "MySave" and L.eval('LOGFILE.gen') == "5",
          "the session log is a Realm host's now (a crash keeps the world pending on generation 5)")
    check(L.eval('slot()') == "Coop_2", "saves go into the co-op save at once")
    check(L.eval('DATA_DIR()') == "LIVE" and L.eval('LIVE_SIDE["mirror_host_settings.txt"]') == "old",
          "the Realm's side files are open (the local copy until the claim)")
    check(L.eval('count("menu.realm_host")') == 0, "not hosting in the same frame (guest modules wind down first)")
    L.execute('run(1.3)')
    check(L.eval('count("menu.realm_host")') == 1 and L.eval('count("zombies.end_takeover")') == 1
          and L.eval('realmplay.hosting()') == "Camp Test", "a second later: hosting the Realm, split state cleared")
    check(L.eval('nclaims()') == 1, "claims the Realm")
    L.execute('answer("claim", true, { "hosted", "76561100", "Old_Host" }); run(4.0)')
    check(L.eval('nclaims()') == 1, "the old host still holds it: no new claim before 5 s")
    L.execute('SAVING = true; run(0.5); SAVING = false; run(1.0)')
    check(L.eval('last("upload")') is None, "a save while the old host holds the Realm uploads nothing")
    L.execute('run(1.0)')
    check(L.eval('nclaims()') == 2, "claims again after 5 s")
    L.execute('PENDING = { base = 3 }; answer("claim", true, { "won", "7" })')
    check(L.eval('LOGFILE.gen') == "7", "won: the log says the old host's final generation")
    check(L.eval('PENDING') is None, "an older pending world is dropped (this world is newer)")
    check(L.eval('last("download")') is not None, "the old host's newest side files are fetched")
    L.execute('answer("download", true, { "7" })')
    check(L.eval('HEAD') == 7, "its world is kept as the local copy of generation 7")
    L.execute('n0 = count("session.save_now"); run(2.1)')
    check(L.eval('count("session.save_now") - n0') == 1, "a save right after winning")
    L.execute('SAVING = true; run(0.3); SAVING = false; run(0.5)')
    up = L.eval('last("upload")')
    check(up is not None and L.eval('last("upload").args') == L.eval('RID') + " 8",
          "that save goes up as generation 8 (my world over the old host's)")


def no_upload_reads_the_realm_save_while_the_game_writes_it():
    """Save audit 2026-10-30: the upload after a save comes once UPLOAD_EVERY has passed, and then read the Realm save
    whatever the game was doing - a file read while the game writes it is cut short, still passes the header check
    and would have become every member's world. An upload waits for the save to end."""
    print("no_upload_reads_the_realm_save_while_the_game_writes_it")
    L = fresh()
    L.execute('realmplay.promote(RID, "76561100"); READY = true; run(1.5); answer("claim", true, { "won", "7" }); '
              'answer("download", true, { "7" }); run(2.1); SAVING = true; run(0.3); SAVING = false; run(0.5)')
    check(L.eval('last("upload").args') == L.eval('RID') + " 8", "hosting: a save goes up as generation 8")
    L.execute('answer("upload", true, {}); SAVING = true; run(0.3); SAVING = false; run(0.5)')
    # the next upload comes due 60 s later - just as the game saves again
    L.execute('n0 = #SENT; SAVING = true; run(61)')
    check(not any(L.eval('SENT[%d].verb' % i) == "upload" for i in range(L.eval('n0') + 1, L.eval('#SENT') + 1)),
          "no upload while the game is saving")
    L.execute('SAVING = false; run(0.2)')
    check(L.eval('last("upload").args') == L.eval('RID') + " 9", "...it goes once the save is over (generation 9)")


def another_member_won_the_realm():
    print("another_member_won_the_realm")
    L = fresh()
    L.execute('LISTHOST = "76561100"; realmplay.promote(RID, "76561100"); READY = true; run(1.5)')
    L.execute('answer("claim", true, { "hosted", "76561999", "Other_Guest" })')
    check(L.eval('count("menu.realm_stop")') == 1 and L.eval('st()') == "stopping",
          "someone else hosts it: leaving (the Realm character is stored on the way)")
    L.execute('ROLE = nil; run(2.0)')
    check(L.eval('last("upload")') is None, "nothing of this world is uploaded")
    check(L.eval('count("realm.store_character")') >= 1, "the Realm character is stored")
    # (the save name is my own a few frames before the load starts: not home yet - a rejoin then ran into the load)
    L.execute('n0 = nclaims(); CUR = "MySave"; run(1.0)')
    check(L.eval('nclaims()') == L.eval('n0') and L.eval('st()') == "going_home",
          "my save's name but the Realm's player still here: not home yet, no rejoin into the load")
    # the load put a new player in my own world - at the old one's address (the load's garbage collection)
    L.execute('PLAYER = { a = 1, name = "BP_PlayerCharacter_C_2" }; run(1.0)')
    check(L.eval('nclaims()') == L.eval('n0') + 1 and L.eval('LOGFILE') is None,
          "home again: asks for the Realm once more, to join whoever hosts it")


def a_host_that_leaves_while_a_member_took_over_is_told_calmly():
    # kit 2026-10-30 11:16: the host left, a member took it over in place, the host's final upload was refused
    # (lease_lost) and it read "Someone else is hosting this Realm now" - for the hand-over working
    print("a_host_that_leaves_while_a_member_took_over_is_told_calmly")
    L = fresh()
    L.execute('realmplay.promote(RID, "76561100"); READY = true; run(1.5); answer("claim", true, { "won", "7" }); '
              'answer("download", true, { "7" }); run(2.1); SAVING = true; run(0.3); SAVING = false; run(0.5)')
    # a lease lost while playing: the alarm stays
    L.execute('SAID = {}; answer("upload", false, { "lease_lost", "you", "are", "not", "hosting" })')
    check(any("Someone else is hosting this Realm now" in str(m) for m in L.eval('SAID').values()),
          "lease lost while playing: the player is warned their game no longer saves to it")
    L = fresh()
    L.execute('realmplay.promote(RID, "76561100"); READY = true; run(1.5); answer("claim", true, { "won", "7" }); '
              'answer("download", true, { "7" }); run(2.1); SAVING = true; run(0.3); SAVING = false; run(0.5); '
              'answer("upload", true, {}); ROLE = nil; realmplay.leave(); run(3.0)')
    up = L.eval('last("upload")')
    check(up is not None and L.eval('last("upload").answered') is None, "leaving: the final upload goes")
    L.execute('SAID = {}; answer("upload", false, { "lease_lost", "you", "are", "not", "hosting" })')
    said = list(L.eval('SAID').values())
    check(not any("Someone else is hosting" in str(m) for m in said) and any("carries on" in str(m) for m in said),
          "leaving, a member hosts it now: told it carries on with them, no alarm (%s)" % said)


def no_old_host_known_waits_out_the_lease():
    print("no_old_host_known_waits_out_the_lease")
    L = fresh()
    L.execute('realmplay.promote(RID, nil); READY = true; run(1.5)')
    L.execute('answer("claim", true, { "hosted", "76561100", "Old" }); run(5.1)')
    check(L.eval('count("menu.realm_stop")') == 0 and L.eval('nclaims()') == 2,
          "old host unknown: whoever holds the Realm is waited for (a crashed host's lease)")


def old_host_known_by_its_lease_id():
    print("old_host_known_by_its_lease_id")
    # kit 2026-10-28 22:52: the link knew the old host as 1001, the server's lease as 76561197960266730 - its
    # "still mine" answer to the first claim was taken for another member's, and the guest left to join it
    L = fresh()
    L.execute('LISTHOST = "76561197960266730"; realmplay.promote(RID, "1001"); READY = true; run(1.5)')
    L.execute('answer("claim", true, { "hosted", "76561197960266730", "Test-host" }); run(5.1)')
    check(L.eval('count("menu.realm_stop")') == 0 and L.eval('nclaims()') == 2 and L.eval('st()') == "playing",
          "the old host's lease id (from the Realm list) is the old host: wait and claim again, never leave")
    L.execute('answer("claim", true, { "won", "3" })')
    check(L.eval('LOGFILE.gen') == "3" and L.eval('count("menu.realm_stop")') == 0, "then wins the Realm")


def session_gone_falls_back_home():
    print("session_gone_falls_back_home")
    L = fresh()
    L.execute('PROMOTE = nil; realmplay.promote(RID, "76561100"); READY = true; run(0.1)')
    check(L.eval('count("session.promote_failed")') == 1 and L.eval('count("zombies.end_takeover")') == 1
          and L.eval('realmplay.active()') is False, "the session can't hand over: back to going home, nothing left armed")


def handover_times_out():
    print("handover_times_out")
    L = fresh()
    L.execute('realmplay.promote(RID, "76561100"); run(10.1)')
    check(L.eval('count("session.promote_realm")') == 1, "a hand-over that never finishes doesn't hold the takeover up")


def leaving_saves_once_coop_and_the_first_save_are_over():
    # player report 2026-10-30 12:23: a host left a solo Realm and the game froze. The leave's second save ran 2 ms
    # after co-op stopped (ghost and copies being destroyed) while the first one still ran: SaveGameToSlot from Lua
    # never returned (UE4SS Lua-lock deadlock family, DBG-20261027-006)
    print("leaving_saves_once_coop_and_the_first_save_are_over")
    L = fresh()
    L.execute('realmplay.promote(RID, "76561100"); run(1.0); READY = true; run(0.1); run(1.3)')
    check(L.eval('realmplay.hosting()') == "Camp Test", "hosting the Realm")
    L.execute('realmplay.leave()')
    check(L.eval('st()') == "stopping", "leaving")
    L.execute('n0 = count("session.save_now"); SAVING = true; ROLE = nil; run(0.1)')
    check(L.eval('count("session.save_now") - n0') == 0, "no save in the moment co-op stops")
    L.execute('run(1.0)')
    check(L.eval('count("session.save_now") - n0') == 0, "no save while the leave's first save still runs")
    L.execute('SAVING = false; run(0.6)')
    check(L.eval('count("session.save_now") - n0') == 1 and L.eval('st()') == "ending_save",
          "saves once both are over (%d)" % L.eval('count("session.save_now") - n0'))
    # a save that never reports done doesn't keep the player in the Realm
    L = fresh()
    L.execute('realmplay.promote(RID, "76561100"); run(1.0); READY = true; run(0.1); run(1.3); realmplay.leave()')
    L.execute('n0 = count("session.save_now"); SAVING = true; ROLE = nil; run(20.5)')
    check(L.eval('st()') == "ending_save" and L.eval('count("session.save_now") - n0') == 0,
          "a save still running after 20 s: on with what it writes, no second save into it")


def a_second_guest_follows_the_one_who_takes_over():
    # player report 2026-10-29 22:28: three in a Realm, the host left, BOTH guests took it over in place; the server
    # gave it to one and the other saved, went home and loaded back in. Now only the lowest slot takes it over; the
    # other goes home and waits - no claim that could win it from under them - then joins them.
    print("a_second_guest_follows_the_one_who_takes_over")
    L = fresh()
    L.execute('ROLE = nil; CUR = "MySave"; LISTHOST = "76561100"; realmplay.takeover(RID, "76561100", true); run(5.0)')
    lists = L.eval('(function() local n = 0; for _, s in ipairs(SENT) do if s.verb == "list" then n = n + 1 end end; return n end)()')
    check(L.eval('nclaims()') == 0 and lists >= 1, "while the old host still holds it: no claim, the list is asked (%d)" % lists)
    L.execute('LISTHOST = "76561999"; run(1.5)')
    check(L.eval('nclaims()') == 1, "the other guest hosts it now: ask for it once, to join them")
    L.execute('answer("claim", true, { "hosted", "76561999", "First_Guest" }); answer("download", true, { "none" })')
    check(L.eval('count("menu.realm_join")') == 1 and L.eval('st()') == "idle", "and join them (never host it here)")


def the_old_host_is_known_from_when_it_left():
    # hardening: once home, the list can already show the next host - the old host's lease id is the one from when
    # it left, else the follower took the next host for the old one and waited out its tries
    print("the_old_host_is_known_from_when_it_left")
    L = fresh()
    L.execute('ROLE = nil; CUR = "MySave"; LISTHOST = "76561999"; realmplay.takeover(RID, "1001", true, "76561100"); run(1.5)')
    check(L.eval('nclaims()') == 1, "the next host already holds it when I get home: join them at once")
    L.execute('answer("claim", true, { "hosted", "76561999", "First_Guest" }); answer("download", true, { "none" })')
    check(L.eval('count("menu.realm_join")') == 1, "joined")


def nobody_takes_it_over_then_open_it_myself():
    print("nobody_takes_it_over_then_open_it_myself")
    L = fresh()
    L.execute('ROLE = nil; CUR = "MySave"; LISTHOST = nil; realmplay.takeover(RID, "76561100", true); run(58.0)')
    check(L.eval('nclaims()') == 0, "nobody hosts it yet: still waiting for the other guest")
    L.execute('run(6.0)')
    check(L.eval('nclaims()') == 1, "a minute without a host: open it myself, so the Realm isn't left without one")


def opening():
    # opening a Realm from my own save: claim won, the world is here already, my save is saved, then the load
    L = fresh()
    L.execute(r'''
        ROLE, CUR, LOADED, POINTED, ANIM = nil, "MySave", nil, nil, nil
        PLAYER, WORLD = { a = 11 }, { a = 21 }
        local U, G = package.loaded["mirror.util"], package.loaded["mirror.game"]
        U.addr = function(o) return o and o.a end
        G.player = function() return PLAYER end
        G.world = function() return WORLD end
        local S, SG = package.loaded["mirror.session"], package.loaded["mirror.slotguard"]
        S.current_slot = function() return "MySave" end
        S.next_coop_slot = function() return "Coop_2" end
        S.load_slot = function(s) LOADED = s; return LOADOK ~= false end
        S.point_at = function(s) POINTED = s; return true end
        S.anim_on_game_thread = function(on) ANIM = on end
        SG.stamp = function() return "st" end
        SG.build_realm = function() return true end
        realmplay.start(RID)
        answer("claim", true, { "won", "5" })
        run(1.6)
    ''')
    return L


def realm_load_that_never_runs_goes_back_home():
    # hardening 2026-10-30: a load call that failed left the session in "loading" for good, the lease held and the
    # game pointing at the Realm's save - my own world's next save would have gone there
    print("realm_load_that_never_runs_goes_back_home")
    L = opening()
    check(L.eval('st()') == "loading" and L.eval('LOADED') == "Coop_2", "the Realm's save is loading")
    L.execute('run(29.0)')
    check(L.eval('st()') == "loading", "still waiting before 30 s")
    L.execute('run(2.0)')
    check(L.eval('realmplay.active()') is False, "the same world and player after 30 s: the Realm is given up")
    check(L.eval('POINTED') == "MySave", "the game points at my own save again")
    check(L.eval('last("release") ~= nil') and L.eval('LOGFILE') is None and L.eval('count("slotguard.purge")') >= 1,
          "the lease is released, the Realm's save emptied, the session record cleared")
    check(L.eval('ANIM') is False, "animation is back on its threads")


def realm_load_that_runs_is_not_given_up():
    print("realm_load_that_runs_is_not_given_up")
    L = opening()
    L.execute('run(10.0); PLAYER, WORLD, CUR = { a = 12 }, { a = 22 }, "Coop_2"; run(25.0)')
    check(L.eval('st()') == "playing" and L.eval('POINTED') is None and L.eval('last("release") == nil'),
          "a new world and player: hosting the Realm, nothing given up")


def load_call_refused_goes_back_home():
    print("load_call_refused_goes_back_home")
    L = fresh()
    L.execute('LOADOK = false')
    L.execute(r'''
        ROLE, CUR = nil, "MySave"
        local S, SG = package.loaded["mirror.session"], package.loaded["mirror.slotguard"]
        S.current_slot = function() return "MySave" end
        S.next_coop_slot = function() return "Coop_2" end
        S.load_slot = function() return false end
        S.point_at = function(s) POINTED = s; return true end
        SG.stamp = function() return "st" end
        SG.build_realm = function() return true end
        realmplay.start(RID); answer("claim", true, { "won", "5" }); run(1.6)
    ''')
    check(L.eval('realmplay.active()') is False and L.eval('POINTED') == "MySave" and L.eval('last("release") ~= nil'),
          "the load can't even start: back on my own save at once, the Realm released")


def coop_started_meanwhile_stops_the_realm():
    print("coop_started_meanwhile_stops_the_realm")
    L = fresh()
    L.execute(r'''
        ROLE, CUR, LOADED = nil, "MySave", nil
        package.loaded["mirror.session"].current_slot = function() return "MySave" end
        package.loaded["mirror.session"].load_slot = function(s) LOADED = s; return true end
        realmplay.start(RID); answer("claim", true, { "won", "5" })
        ROLE = "host"   -- (hosting co-op started while my save was being saved)
        run(1.6)
    ''')
    check(L.eval('realmplay.active()') is False and L.eval('LOADED') is None and L.eval('last("release") ~= nil'),
          "co-op started during the opening: the Realm isn't loaded, its lease released")


for t in (clean_end_takes_over_in_place, no_upload_reads_the_realm_save_while_the_game_writes_it, another_member_won_the_realm,
          a_host_that_leaves_while_a_member_took_over_is_told_calmly, no_old_host_known_waits_out_the_lease,
          old_host_known_by_its_lease_id, session_gone_falls_back_home, handover_times_out,
          leaving_saves_once_coop_and_the_first_save_are_over, a_second_guest_follows_the_one_who_takes_over,
          the_old_host_is_known_from_when_it_left, nobody_takes_it_over_then_open_it_myself,
          realm_load_that_never_runs_goes_back_home, realm_load_that_runs_is_not_given_up,
          load_call_refused_goes_back_home, coop_started_meanwhile_stops_the_realm):
    try:
        t()
    except Exception as e:
        check(False, "%s raised %s" % (t.__name__, e))

print()
print("%d FAILED" % len(fails) if fails else "ALL PASSED")
sys.exit(1 if fails else 0)
