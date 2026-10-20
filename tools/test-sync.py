"""Unit checks for sync helpers that run outside the game (Lua 5.4 via lupa).

    pip install --target <dir> lupa, set PYTHONPATH=<dir>, then: python tools/test-sync.py
"""
import os, random, sys

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


for t in (posepack_recovers_lost_packets, clockmap_quiet_places_without_stats, util_null_objects_are_invalid,
          jig_stats_copy_the_asset_defaults):
    try:
        t()
    except Exception as e:
        failed += 1
        print("  FAIL %s raised %s" % (t.__name__, e))
print()
print("ALL PASSED" if failed == 0 else "%d FAILED" % failed)
sys.exit(1 if failed else 0)
