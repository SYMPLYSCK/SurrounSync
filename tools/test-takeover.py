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
    return { safe = function(fn, _, ...) return pcall(fn, ...) end, valid = function(o) return o ~= nil end,
             addr = function() return 1 end, ensure_hook = function() return true end }
end
TICKS = {}
package.preload["mirror.game"] = function()
    return fake("game", { on_tick = function(fn) TICKS[#TICKS + 1] = fn end, player = function() return {} end })
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
    L.execute('n0 = nclaims(); CUR = "MySave"; run(1.0)')
    check(L.eval('nclaims()') == L.eval('n0') + 1 and L.eval('LOGFILE') is None,
          "home again: asks for the Realm once more, to join whoever hosts it")


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


for t in (clean_end_takes_over_in_place, another_member_won_the_realm, no_old_host_known_waits_out_the_lease,
          old_host_known_by_its_lease_id, session_gone_falls_back_home, handover_times_out,
          leaving_saves_once_coop_and_the_first_save_are_over):
    try:
        t()
    except Exception as e:
        check(False, "%s raised %s" % (t.__name__, e))

print()
print("%d FAILED" % len(fails) if fails else "ALL PASSED")
sys.exit(1 if fails else 0)
