"""Unit checks for sync helpers that run outside the game (Lua 5.4 via lupa).

    pip install --target <dir> lupa, set PYTHONPATH=<dir>, then: python tools/test-sync.py
"""
import os, random, shutil, sys, tempfile

try:
    from lupa import LuaRuntime
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
        bye = src[src.index('local bye = link.get_blob("bye")'):]
        bye = bye[:bye.index('" stopped hosting."')]
        check(bye.index('session.state() == "joined"') < bye.index("said < opened_at"),
              "an old goodbye only skips the 'stopped hosting' note - a joined guest still goes home first")
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
    package.loaded["mirror.notify"] = { show = function() end }
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
                                DamageComponent = { StandardHealthValue = std, CurrentHealth = cur, MaxHealth = max },
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
            util.instances = function(cls) if cls == "BP_Infestation_C" then return { A, BAD }, true end return {}, true end
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
            package.loaded["mirror.notify"] = { show = function(t) NOTES[#NOTES + 1] = t end }
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
    """)
    check(L.eval("BEFORE") == 0, "container not here: the take isn't lost, just waits")
    check(L.eval("AFTER") == "G1:3", "the container shows up: the take is applied (%s)" % L.eval("AFTER"))
    check(L.eval("ONCE") == 1, "and only once (%d)" % L.eval("ONCE"))
    check(L.eval("R0") == 0 and (L.eval("R1") or "").startswith("R " + "Container_FuelLoot_GasPump_C@10,0,0 G7"),
          "a put-in for a container that never comes is handed back after 10 min (%r)" % L.eval("R1"))


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
        ONCE = takes()
        loot.tick(1.0)
        HOOKS[C .. ":JigMP_OnItemRemoved"](a, u)
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


def ghost_never_blocks_cars():
    print("ghost_never_blocks_cars")
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
            local cap = { SetCollisionEnabled = function() end, SetCollisionResponseToAllChannels = function() end,
                          SetCollisionResponseToChannel = function(_, ch, r) if r == 2 then BLOCKS[ch] = true end end }
            return obj({ CapsuleComponent = cap, Mesh = { SetCollisionEnabled = function() end,
                         SetCollisionResponseToAllChannels = function() end, SetCollisionResponseToChannel = function() end },
                         MedicalComponent = {}, CharacterMovement = {}, Tags = { Empty = function() end },
                         AIOInvoker = {}, ActorHasTag = function() return false end,
                         GetFullName = function() return "BP_Ghost /Game/X.Ghost" end })
        end
        WORLD = { SpawnActor = function() return body() end }
    """)
    for kind in ("guest", "host"):
        L.execute('BLOCKS = {}; ghost.forget(); ghost.spawn(WORLD, { X = 0, Y = 0, Z = 0 }, 0, "%s")' % kind)
        check(L.eval('BLOCKS[6]') is None, "the %s ghost's capsule doesn't block cars (a teleported capsule flings them)" % kind)
        check(L.eval('BLOCKS[0] and BLOCKS[1] and BLOCKS[2]') is True, "the %s ghost still blocks the world and players" % kind)


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
    """)
    check(L.eval('audio.attenuation_for(CUES["/Game/Audio/Shotgun_Insert_Cue.Shotgun_Insert_Cue"], "/Game/Audio/Shotgun_Insert_Cue.Shotgun_Insert_Cue") == DOOR'),
          "a 2D reload cue gets a short-range attenuation")
    check(L.eval('audio.attenuation_for(CUES["/Game/Audio/AR_Single_Shot_Cue.AR_Single_Shot_Cue"], "/Game/Audio/AR_Single_Shot_Cue.AR_Single_Shot_Cue") == nil'),
          "a cue with its own attenuation keeps it")
    check(L.eval('audio.attenuation_for(cue("explosion_large_06_Cue")) == RIFLE'),
          "a cue passed without its path is still named (an explosion gets the long range)")
    L.execute('INBOX = { "/Game/Audio/Shotgun_Insert_Cue.Shotgun_Insert_Cue 5000 0 0 1.00 1.00" }; audio.tick(0.1)')
    check(L.eval('#PLAYED == 1 and PLAYED[1].att == DOOR'), "a replayed 2D cue plays with the attenuation")
    # This game played the same cue at the same spot itself: the replay is a duplicate.
    L.execute('HOOKS.PlaySoundAtLocation(nil, P(obj({})), P(CUES["/Game/Audio/Shotgun_Insert_Cue.Shotgun_Insert_Cue"]), P({ X = 9000, Y = 0, Z = 0 }), nil, P(1), P(1)); '
              'INBOX = { "/Game/Audio/Shotgun_Insert_Cue.Shotgun_Insert_Cue 9100 0 0 1.00 1.00" }; audio.tick(0.1)')
    check(L.eval('#PLAYED') == 1, "a sound both games played is not doubled")
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
        package.loaded["mirror.link"].get_blob = function(n) local b = n == "doors" and BLOB or nil; BLOB = nil; return b end
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
        MARKERS = {}
        function marker(x, d)
            local m = obj({ ["Marker Data"] = d, gone = false })
            m.IsValid = function() return not m.gone end
            m.K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end
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
        FindAllOf = function(c) if c == "BP_GuaranteedSpawner_Classified_C" then return CRATES end return MARKERS end
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
    L.execute('HOOKS["BP_GuaranteedSpawner_C:Svr_CrateOpen"](P(CRATES[1]))')
    check(L.eval('#SENT') == 0, "searching the copy sends nothing")
    L.execute(r"""
        MINE_CRATE = obj({ GetClass = function() return CRATE_CLS end, K2_GetActorLocation = function() return { X = 9000, Y = 0, Z = 0 } end })
        HOOKS["BP_GuaranteedSpawner_C:Svr_CrateOpen"](P(MINE_CRATE))
    """)
    check(list(L.eval('SENT').values()) == ["O BP_GuaranteedSpawner_Classified_C 9000.0 0.0 0.0"], "searching my own scan's crate is sent (%s)" % list(L.eval('SENT').values()))
    L.execute('SENT = {}; INBOX.pings = { "O BP_GuaranteedSpawner_Classified_C 5000.0 0.0 10.0" }; pings.tick(0.1)')
    check(L.eval('CRATES[1].lid') is True and L.eval('#SENT') == 0, "the scanner searching theirs opens the copy's lid here, no echo")


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
        IN = { "C 1_2_3_4 /Game/Items/DA_Scope.DA_Scope;/Game/Items/DA_Grip.DA_Grip" }
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
    check(first == ["C 1_2_3_4 /Game/Items/DA_Scope.DA_Scope"], "an attachment put on a dropped weapon is sent with its uid")
    check(L.eval('SAME') == 0, "an unchanged weapon isn't sent again")
    check(list(L.eval('TAKEN').values()) == ["C 1_2_3_4 "], "taking the attachment off is sent too")
    check(L.eval('OTHER') == 0, "moves between untracked containers send nothing")
    check(L.eval('APPLIED and APPLIED.comp == COMP') and L.eval('#APPLIED.want') == 2,
          "the other game's change goes onto this game's copy")
    check(L.eval('ECHO') == 0, "applying the other game's change isn't echoed back")
    check(list(L.eval('POLLED').values()) == ["C 1_2_3_4 /Game/Items/DA_Laser.DA_Laser"],
          "a part put on without any hook is found by looking and sent")
    check(L.eval('POLLED_AGAIN') == 0, "and sent once")
    check(L.eval('FAR') == 0, "an item 10 m away isn't looked at")
    check(L.eval('LOOKED_EARLY') == True, "(the check saw the copy's default parts first)")
    check(L.eval('LANDED_HAVE') == 1, "the copy got the other game's parts")
    check(L.eval('LANDED_N') == 0, "the other game's parts landing on a fresh copy aren't sent back")


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
    check(G2.eval('GWS.Rain') == 6 and G2.eval('GWS.Snow') == 3, "the host's live weather changing reaches the guest")
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
        guest_busy = function() return FIGHT end, near_guest = function() return NEAR, 0.5 end, own_count = function() return 7 end }
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
    CFG = { zombies = { split = { split_radius = 40000, split_after = 10.0, merge_radius = 30000, force_radius = 20000,
        quiet_radius = 6000, ack_timeout = 10.0, retry_after = 30.0, horde_radius = 25000, nest_hit_s = 90.0 } } }
    split.init(CFG, role, { guest_in_world = function() return GUEST end, in_world = function() return INWORLD end })
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
    A.execute('OTHERS = { other(3, { "merged" }, { X = 50500, Y = 0, Z = 0 }, nil) }; run(1.1)')
    check(A.eval('split.host_state()') == "merged", "a guest next to it that isn't following: merged")


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
    to_guest(); G.execute('run(0.6)')
    check(G.eval('SPLIT') is True and G.eval('blobs_out.p8g') == "s 3 0", "guest: takes over and answers with the epoch")
    H.execute('blobs_in.p8g = "s 2 0"; run(0.3)')
    check(H.eval('split.state()') == "splitting", "host: an answer to an old epoch doesn't count")
    to_host(); H.execute('run(0.3)')
    check(H.eval('split.state()') == "split" and H.eval('INV') == -1 and H.eval('SPLIT') is True,
          "host: only on that answer the ghost leaves the optimizer and snapshots stop")
    H.execute('INV = 0; run(1.1)')
    check(H.eval('INV') == -1, "a ghost respawned after a save is taken out again")
    H.execute('SAVING = true; GHOST = false; run(3); SAVING = false; run(3)')
    check(H.eval('split.state()') == "split", "a save (ghost gone for a moment) doesn't merge")
    H.execute('GHOST = true; GL = { X = 25000, Y = 0, Z = 0 }; blobs_in.p8g = "s 3 1"; run(2)')
    check(H.eval('split.state()') == "split", "closer than merge_radius but the guest is fighting: still split")
    H.execute('GL = { X = 15000, Y = 0, Z = 0 }; run(1.1)')
    check(H.eval('split.state()') == "merged" and H.eval('INV') == 0 and H.eval('SPLIT') is False and H.eval('blobs_out.p8') == "m 4",
          "within force_radius: merged even mid-fight, ghost back in the optimizer")
    to_guest(); G.execute('run(0.6)')
    check(G.eval('SPLIT') is False and G.eval('blobs_out.p8g') == "m 4 0", "guest: follows the merge")
    H.execute('GL = { X = 50000, Y = 0, Z = 0 }; run(12)'); handshake()
    check(H.eval('split.state()') == "split", "split again")
    H.execute('NEST = 0.2; split.tick(0.016)')
    check(H.eval('split.state()') == "merged" and H.eval('INV') == 0, "a guest hit on an infestation merges in the same frame")
    H.execute('NEST = 1e9; run(13)')
    check(H.eval('split.state()') == "splitting", "after the fight, splitting again")
    H.execute('HORDE = true; run(0.3)')
    check(H.eval('split.state()') == "merged", "a horde near the guest cancels the split")
    H.execute('HORDE = false; NEAR = 3000; run(60)')
    check(H.eval('split.state()') == "merged", "a host AI (or body) near the guest blocks the split")
    H.execute('NEAR = 1e9; run(12)'); handshake()
    check(H.eval('split.state()') == "split", "split once nothing is near the guest")
    H.execute('SETTING = false; run(0.2)')
    check(H.eval('split.state()') == "merged" and H.eval('INV') == 0, "setting turned off mid-split: merged at once")
    H.execute('SETTING = true; run(11)'); handshake()
    H.execute('GUEST = false; run(0.2)')
    check(H.eval('split.state()') == "merged" and H.eval('INV') == 0, "the guest leaves: merged at once")
    G.execute('INWORLD = false; run(0.2)')
    check(G.eval('RESET') == "p8", "guest out of the world: the host's state is read fresh on the next join")
    G.execute('SPLIT = false; INWORLD = true; blobs_in.p8 = "m 9"; run(0.6)')
    check(G.eval('blobs_out.p8g') == "m 9 0" and G.eval('SPLIT') is False, "guest: answers the host's epoch after a rejoin")


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
    L.execute('zombies.set_split(true)')
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
            package.loaded["mirror.game"] = { on_world_reset = function() end }
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
            package.loaded["mirror.notify"] = { show = function() end }
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
            package.loaded["mirror.notify"] = { show = function() end }
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

def mods_switch_restart_and_match_the_host():
    print("mods_switch_restart_and_match_the_host")
    d = tempfile.mkdtemp(prefix="mods-")
    try:
        w64 = os.path.join(d, "SurrounDead", "Binaries", "Win64")
        mods = os.path.join(w64, "ue4ss", "Mods")
        paks = os.path.join(d, "SurrounDead", "Content", "Paks")
        for m in ("SurrounSync", "shared", "AimRun", "HeadshotBrains", "Keybinds", "SelfOn", "ConsoleEnablerMod"):
            os.makedirs(os.path.join(mods, m))
        open(os.path.join(mods, "SelfOn", "enabled.txt"), "w").close()
        with open(os.path.join(mods, "mods.txt"), "w", newline="") as f:
            f.write("SurrounSync : 1\r\nAimRun : 1\r\nHeadshotBrains : 0\r\nConsoleEnablerMod : 0\r\n"
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
    finally:
        shutil.rmtree(d, ignore_errors=True)


for t in (corpse_looted_at_the_same_moment_keeps_one_copy, same_moment_container_takes_keep_one_copy, one_take_fires_both_removed_hooks_and_is_sent_once, item_used_out_of_a_container_is_a_take, unanswered_join_keeps_the_friends_list, bag_put_back_after_a_take_reaches_the_host, container_class_checks_are_cached, stacking_moves_reach_the_other_game, loot_take_for_a_container_the_host_lacks_is_kept, car_trunks_go_by_the_cars_name, mods_switch_restart_and_match_the_host, loot_take_without_a_uid_pairing_finds_the_item, settings_pages_cycle_save_and_follow_the_host, zombie_archetype_effects_reach_copies, group_split_host_decides_follow_and_ignores_followers, loot_open_shows_the_hosts_items_at_once, group_split_leader_and_follower_agree, vehicles_seat_four_players_by_slot, loot_asks_the_host_again_on_every_reopen, peers_give_every_player_their_own_copy, chat_and_voice_reach_every_player, reliable_events_survive_pauses_and_restarts, jig_probe_names_what_a_patch_removed, find_by_id_reuses_the_object_it_found, tooltip_never_calls_into_null_objects, settlement_camps_follow_the_host, posepack_recovers_lost_packets, link_blob_comes_back_after_reset, clockmap_quiet_places_without_stats, util_null_objects_are_invalid,
          jig_stats_copy_the_asset_defaults, tactical_reads_only_lights_the_class_has,
          vehicles_keep_this_worlds_fuel, harvest_uses_up_nodes_once, zombie_copies_take_the_hosts_look,
          copy_radiation_is_taken_back, nests_keep_real_health, horde_beacon_runs_only_on_the_host, goto_and_bring_move_only_your_own_player, backpack_tooltip_reads_the_item_once, foreach_keeps_temporary_arrays_alive, backpack_names_travel_with_the_item, beds_get_a_rename_row_and_shared_names,
          ghost_swims_without_its_own_water_detection, ghost_never_blocks_cars, audio_spatializes_and_shares_without_echo,
          throws_and_mines_reach_the_other_game, map_pings_reach_the_other_game, keycard_doors_open_on_both_games, horde_rewards_reach_the_other_game, loose_magazine_rounds_reach_the_picker, loose_magazine_picked_up_without_hooks_still_gets_its_rounds, ground_weapon_attachments_reach_the_other_game, ghost_gun_in_hand_is_known, missing_zombie_looks_get_loaded,
          random_and_debug_weather_is_shared,
          trader_stock_is_the_hosts, instances_walk_once_then_follow_beginplay, grouped_classes_share_one_walk, walk_skip_is_measured_after_a_load, unloaded_tracked_classes_cost_few_lookups,
          link_reads_only_blobs_the_index_says_changed, corpse_loot_reaches_every_player, host_settled_corpses_cost_almost_nothing,
          standing_hooks_skip_the_lookup, hook_lookups_share_one_budget, find_remembers_misses, container_items_keep_their_cell_and_rotation, loot_skips_containers_gone_since_listed, bags_are_never_consumed_and_twin_grids_are_counted,
          load_split_switches_only_when_both_agree, load_split_hands_the_ai_to_the_guest):
    try:
        t()
    except Exception as e:
        failed += 1
        print("  FAIL %s raised %s" % (t.__name__, e))
print()
print("ALL PASSED" if failed == 0 else "%d FAILED" % failed)
sys.exit(1 if failed else 0)
