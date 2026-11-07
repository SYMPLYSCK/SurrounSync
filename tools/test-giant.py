"""The forest giant (mirror/giant.lua): spot per world, spawn window, 10x size and health, guarding, death and the
15-day respawn, the guest's copy resize. Runs the real Lua with stand-ins for the game.

    PYTHONPATH=tools/testpkg python tools/test-giant.py
"""
import os
import shutil
import sys
import tempfile

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
local scripts, tmp = ...
package.path = scripts .. "\\?.lua;" .. scripts .. "\\mirror\\?.lua;" .. package.path
LOG = {}
local function out(lvl) return function(m) LOG[#LOG + 1] = lvl .. " " .. tostring(m) end end
package.preload["mirror.log"] = function() return { info = out("INFO"), warn = out("WARN"), error = out("ERROR"), debug = function() end } end

-- actors: tables with the UE calls giant.lua makes
START = "StartingItems_10_C6DB208442353E0AA9B5DB892266821A"
CHANCE = "SpawnChance_9_0A1811814580181DD09AE78500C25A28"
function actor(x, y, z, extra)
    local a = { loc = { X = x, Y = y, Z = z }, scale = 1.0, alive = true }
    a.DamageComponent = { CurrentHealth = 2130, MaxHealth = 2130,
        ["SetCurrent&MaxHealth_Event"] = function(self, c, m) self.told = { c, m } end }
    a.Controller = { valid = true }
    a.LootTable = 10   -- ZombieBossSmall
    a.BP_JigMultiplayer = { calls = {}, ContainersSettings = { { [START] = { { [CHANCE] = 5.0 } } } } }
    function a.BP_JigMultiplayer:ClearContainer(reset) self.calls[#self.calls + 1] = "clear " .. tostring(reset) end
    function a.BP_JigMultiplayer:InitializeJigComponent() self.calls[#self.calls + 1] = "init" end
    function a:IsValid() return self.alive end
    function a:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    function a:K2_SetActorLocation(l) self.loc = { X = l.X, Y = l.Y, Z = l.Z }; self.teleports = (self.teleports or 0) + 1 end
    function a:GetActorScale3D() return { X = self.scale, Y = self.scale, Z = self.scale } end
    function a:SetActorScale3D(s) self.scale = s.X end
    function a:K2_DestroyActor() self.alive = false end
    function a:GetFullName() return "BP_ZombieBoss_Butcher_Small_C /Game/Map.Map:Persistent.Boss_1" end
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end
package.preload["mirror.util"] = function()
    local u = {}
    function u.valid(o) return type(o) == "table" and o.alive ~= false and (o.IsValid == nil or o:IsValid()) end
    function u.vec(v) return { X = v.X, Y = v.Y, Z = v.Z } end
    function u.dist(a, b) local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z; return math.sqrt(dx * dx + dy * dy + dz * dz) end
    function u.same(a, b) return a ~= nil and a == b end
    function u.safe(fn, ctx, ...) local ok, err = pcall(fn, ...); if not ok then LOG[#LOG + 1] = "SAFE " .. tostring(err) end end
    function u.cdo(p) return CDO[p] end
    function u.each(arr, fn) for i, v in ipairs(arr) do fn(i, { get = function() return v end }) end return arr end
    return u
end
MOVES = {}
-- SetLootTable_AI_DA: the table's list copied onto the jig (MilitaryBoss: chances 30, 60 and 100)
LOOT_CALLS = {}
CDO = { ["/Script/AIModule.Default__AIBlueprintHelperLibrary"] =
    { SimpleMoveToLocation = function(self, ctl, at) MOVES[#MOVES + 1] = { X = at.X, Y = at.Y, Z = at.Z } end },
    ["/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"] =
    { SetLootTable_AI_DA = function(self, t, jig, c, wc)
        LOOT_CALLS[#LOOT_CALLS + 1] = { t = t, jig = jig, c = c, wc = wc }
        jig.ContainersSettings[c + 1][START] = { { [CHANCE] = 30.0 }, { [CHANCE] = 60.0 }, { [CHANCE] = 100.0 } }
    end } }
PLAYER = actor(0, 0, 100)
TICKS, KEYS, RESETS = {}, {}, {}
package.preload["mirror.game"] = function()
    return { player = function() return PLAYER end, world = function() return {} end,
             on_tick = function(fn) TICKS[#TICKS + 1] = fn end, on_world_reset = function(fn) RESETS[#RESETS + 1] = fn end,
             keybind = function(name, mods, fn) KEYS[name] = fn end }
end
FILES = {}
package.preload["mirror.fs"] = function()
    return { read = function(p) return FILES[p] end, write = function(p, d) FILES[p] = d; return true end }
end
WORLD = "QuickSave1"
package.preload["mirror.session"] = function()
    return { world_save = function() return WORLD end, saves_dir = function() return tmp .. "\\SaveGames" end }
end
HOSTING = nil   -- the Realm id I host right now (realmplay.hosting_id)
package.preload["mirror.slotguard"] = function()
    return { is_coop = function(n) return n:lower():find("^surrounsync_session_") ~= nil end }
end
package.preload["mirror.realmplay"] = function() return { hosting_id = function() return HOSTING end } end
SPAWNS, SPAWN_REFUSE, HOST_Z, COPIES = {}, nil, {}, {}
package.preload["mirror.zombies"] = function()
    return {
        spawn_safe = function(cls, loc, yaw)
            SPAWNS[#SPAWNS + 1] = { cls = cls, loc = loc }
            if SPAWN_REFUSE then return nil, SPAWN_REFUSE end
            if NEED_TABLES and not LOOT_READY then return nil, "16 AI loot table(s) not loaded yet" end
            local a = actor(loc.X, loc.Y, loc.Z)
            LAST = a
            BOSSES[#BOSSES + 1] = a
            return a
        end,
        dead_of = function(z) return z.dead == true end,
        host_zombies = function() return HOST_Z end,
        copy_actor = function(id) return COPIES[id] end,
        loot_ready = function() return LOOT_READY end,
        -- (the game loads them by the next try when TABLES_COME)
        load_loot_tables = function() ASKED = ASKED + 1; if TABLES_COME then LOOT_READY = true end; return 16 end,
    }
end
-- like link_file.lua: a blob is handed out once per change (or again after reset_blob)
BLOBS, GUEST_BLOB, BLOB_SEEN = {}, nil, false
function host_sends(v) GUEST_BLOB, BLOB_SEEN = v, false end
package.preload["mirror.link"] = function()
    return { put_blob = function(n, v) BLOBS[#BLOBS + 1] = n .. "=" .. v end,
             get_blob = function(n) if BLOB_SEEN or not GUEST_BLOB then return nil end BLOB_SEEN = true; return GUEST_BLOB end,
             reset_blob = function(n) if n == "giant" then BLOB_SEEN = false end end }
end
NOTES = {}
package.preload["mirror.notify"] = function() return { show = function(t, k) NOTES[#NOTES + 1] = k .. " " .. t end } end
SAVING = false
package.preload["mirror.save_guard"] = function() return { busy = function() return SAVING end } end
GHOSTS = {}
-- INSTS: the other guests' copies (more than two players), like peers.each: the main module first, then each copy's
INSTS = {}
package.preload["mirror.peers"] = function() return { ghost_list = function() local o = {}; for i, g in ipairs(GHOSTS) do o[i] = g end; return o end,
    each = function(name, fn)
        fn(require(name), nil)
        for _, inst in ipairs(INSTS) do local m = inst.loaded[name]; if m then fn(m, inst) end end
    end } end
function guest_copy(tag)
    local c = { tag = tag, blobs = {}, host_z = {}, resets = 0 }
    c.loaded = { ["mirror.link"] = { put_blob = function(n, v) c.blobs[#c.blobs + 1] = n .. "=" .. v end,
                                     reset_blob = function() c.resets = c.resets + 1 end },
                 ["mirror.zombies"] = { host_zombies = function() return c.host_z end } }
    INSTS[#INSTS + 1] = c
    return c
end
BOSSES = {}
SWEPT = {}
function FindAllOf(name)
    SWEPT[name] = (SWEPT[name] or 0) + 1
    if name == "Ultra_Dynamic_Sky_C" then return SKY_GONE and {} or { SKY } end
    if name == "BP_ZombieBoss_Butcher_Small_C" then return BOSSES end
    return {}
end
SKY = { alive = true, ["Time of Day"] = 900.0 }
function SKY:IsValid() return true end
function SKY:GetFullName() return "Ultra_Dynamic_Sky_C /Game/Map.Map:Persistent.Sky" end
ModifierKey = { CONTROL = 1 }
ROLE = nil
giant = require("mirror.giant")
giant.init(function() return ROLE end)
function TICK(n) for _ = 1, (n or 1) do for _, f in ipairs(TICKS) do f(1.0) end end end
function at(a, x, y, z) a.loc = { X = x, Y = y, Z = z } end
function fresh()
    for k in pairs(giant._S) do if k ~= "role_fn" and k ~= "inited" and k ~= "path" then giant._S[k] = nil end end
    giant._S.step_in, giant._S.move_in, giant._S.spawn_in, giant._S.scaled = 0, 0, 0, false
    giant._S.blobs, giant._S.copy_ids, INSTS = {}, {}, {}
    SPAWNS, BOSSES, MOVES, BLOBS, NOTES, HOST_Z, COPIES, LOG = {}, {}, {}, {}, {}, {}, {}, {}
    SPAWN_REFUSE, SAVING, ROLE, LAST, GHOSTS, GUEST_BLOB, BLOB_SEEN = nil, false, nil, nil, {}, nil, false
    LOOT_CALLS, LOOT_READY, HOSTING = {}, true, nil
    NEED_TABLES, TABLES_COME, ASKED = false, false, 0
    SWEPT, SKY_GONE = {}, false
    PLAYER = actor(0, 0, 100)
    SKY["Time of Day"] = 900.0
end
function path() return giant._S.path end
'''


def make(tmp):
    L = lua54.LuaRuntime()
    L.execute(SETUP, SCRIPTS, tmp)
    return L


def ev(L, expr):
    return L.eval(expr)


def run():
    tmp = tempfile.mkdtemp(prefix="mirror_giant_test_")
    try:
        L = make(tmp)

        print("file format")
        L.execute('T = giant.parse("A|1.0 2.0 3.0|-\\nB|-5.5 6.0 7.0|3.250\\nbroken line\\n")')
        check(ev(L, "T.A.spot.X == 1 and T.A.dead == nil"), "alive world parsed (dead '-' -> nil)")
        check(ev(L, "T.B.spot.X == -5.5 and T.B.dead == 3.25"), "dead world parsed with its days")
        check(ev(L, "T['broken line'] == nil"), "a broken line is skipped")
        check(ev(L, 'giant.format(T) == "A|1.0 2.0 3.0|-\\nB|-5.5 6.0 7.0|3.250\\n"'), "format writes the same lines back, sorted")
        check(ev(L, "math.abs(giant.days_between(2300, 100) - 200 / 2400) < 1e-9"), "days_between wraps at midnight")
        check(ev(L, "giant.days_between(nil, 100) == 0"), "no earlier reading counts 0 days")

        print("home spot (every world)")
        L.execute('fresh(); WORLD = "NewWorld"; H = giant.HOME_SPOT; at(PLAYER, H.X, H.Y + 6000, H.Z); TICK(2)')
        check(ev(L, "giant._S.spot.X == H.X and giant._S.spot.Y == H.Y and giant._S.spot.Z == H.Z"),
              "a world with no line guards the home spot")
        check(ev(L, "#SPAWNS == 1 and SPAWNS[1].loc.X == H.X and SPAWNS[1].loc.Z == H.Z + 50"),
              "and spawns there with nobody pressing anything")
        check(ev(L, 'not (FILES[path()] or ""):find("NewWorld", 1, true)'), "nothing is written for it while it just lives")
        L.execute("LAST.DamageComponent.CurrentHealth = 0; TICK(1)")
        check(ev(L, '(FILES[path()] or ""):find("NewWorld|202905.7 8343.9 11280.9|0.000", 1, true) ~= nil'),
              "its death is saved with the home spot")
        check(ev(L, "H.X == 202905.7 and giant._S.spot ~= H"), "the home spot itself is never changed (a copy is used)")
        L.execute('fresh(); WORLD = "OffWorld"; FILES[path()] = (FILES[path()] or "") .. "OffWorld|off|-\\n"; '
                  'at(PLAYER, H.X, H.Y + 6000, H.Z); TICK(3)')
        check(ev(L, "#SPAWNS == 0 and giant._S.spot == nil"), "a world marked off: nothing spawns")
        check(ev(L, 'BLOBS[#BLOBS] == "giant=-"'), "off: the blob says none")
        L.execute('WORLD = "QuickSave1"')

        print("Realm worlds (a reused co-op slot)")
        L.execute('fresh(); WORLD = "SurrounSync_Session_3"; HOSTING = "realmA"; at(PLAYER, H.X, H.Y + 6000, H.Z); TICK(2)')
        check(ev(L, 'giant._S.key == "Realm realmA" and #SPAWNS == 1'), "a Realm I host goes by its id, not the slot (%s)"
              % ev(L, "giant._S.key"))
        L.execute("LAST.DamageComponent.CurrentHealth = 0; TICK(1)")
        check(ev(L, '(FILES[path()] or ""):find("Realm realmA|", 1, true) ~= nil and '
                    'not (FILES[path()] or ""):find("SurrounSync_Session_3|", 1, true)'), "its death is kept under the Realm")
        L.execute('fresh(); WORLD = "SurrounSync_Session_3"; HOSTING = "realmB"; at(PLAYER, H.X, H.Y + 6000, H.Z); TICK(2)')
        check(ev(L, "giant._S.dead == nil and #SPAWNS == 1"), "another Realm in the same slot has its own, alive giant")
        L.execute('fresh(); WORLD = "SurrounSync_Session_3"; HOSTING = nil; at(PLAYER, H.X, H.Y + 6000, H.Z); TICK(3)')
        check(ev(L, "#SPAWNS == 0 and giant._S.key == nil"), "a co-op slot that is no Realm I host: no giant")
        check(ev(L, "giant.place_here() == false"), "and Ctrl+G there does nothing")
        L.execute('WORLD = "QuickSave1"')
        L.execute("fresh(); C2 = guest_copy('to2'); BLOB_SEEN = true; for _, f in ipairs(RESETS) do f() end")
        check(ev(L, "C2.resets == 1 and BLOB_SEEN == false"), "a world reset asks every guest's link to hand the blob out again")

        print("placing and spawning")
        L.execute("fresh(); at(PLAYER, 1000, 2000, 300); KEYS.G()")
        check(ev(L, "giant._S.spot.X == 1000 and giant._S.spot.Z == 300"), "Ctrl+G sets the spot where I stand")
        check(ev(L, 'FILES[path()]:find("\\nQuickSave1|1000.0 2000.0 300.0|-\\n", 1, true) ~= nil'), "the spot is saved for this world")
        check(ev(L, 'path():find("mirror_giant.txt", 1, true) ~= nil and not path():find("SaveGames", 1, true)'),
              "the file sits next to the saves, not in them")
        L.execute("TICK(3)")
        check(ev(L, "#SPAWNS == 0"), "standing on the spot (under 30 m): no spawn yet")
        L.execute("at(PLAYER, 1000, 2000 + 25000, 300); TICK(3)")
        check(ev(L, "#SPAWNS == 0"), "250 m away: no spawn (its ground may not be loaded)")
        L.execute("at(PLAYER, 1000, 2000 + 6000, 300); SAVING = true; TICK(3)")
        check(ev(L, "#SPAWNS == 0"), "a save in progress: no spawn")
        L.execute("SAVING = false; TICK(1)")
        check(ev(L, "#SPAWNS == 1"), "60 m away, no save: one spawn")
        check(ev(L, 'SPAWNS[1].cls:find("Butcher_Small", 1, true) ~= nil'), "the Butcher is tried first")
        check(ev(L, "SPAWNS[1].loc.X == 1000 and SPAWNS[1].loc.Z == 350"), "spawned on the spot, 50 above it")
        check(ev(L, "LAST.scale == 1.0"), "spawned at 1x (scaled on a later tick)")
        L.execute("TICK(1)")
        check(ev(L, "LAST.scale == 10.0"), "the next tick makes it 10x")
        check(ev(L, "LAST.DamageComponent.MaxHealth == 21300 and LAST.DamageComponent.CurrentHealth == 21300"),
              "health 10x (2130 -> 21300)")
        L.execute("TICK(20)")
        check(ev(L, "#SPAWNS == 1"), "only ever one giant while it lives")
        check(ev(L, "LAST.DamageComponent.MaxHealth == 21300"), "health is not multiplied again")

        print("spawn refused")
        L.execute("fresh(); at(PLAYER, 0, 6000, 100); giant.place_here(); SPAWN_REFUSE = '16 AI loot table(s) not loaded yet'")
        L.execute("at(PLAYER, 0, 6000, 100); giant._S.spot = { X = 0, Y = 0, Z = 100 }; TICK(1)")
        n1 = ev(L, "#SPAWNS")
        L.execute("TICK(4)")
        check(ev(L, "#SPAWNS") == n1, "a refusal waits 5 s before trying again")
        L.execute("TICK(1)")
        check(ev(L, "#SPAWNS") > n1, "then it tries again")
        waits = L.execute('local n = 0 for _, l in ipairs(LOG) do if l:find("waiting to spawn", 1, true) then n = n + 1 end end return n')
        check(waits == 1, "the reason is logged once, not every try (%d)" % waits)

        print("a quiet spot (no ordinary AI: the game has no AI loot table loaded)")
        L.execute("fresh(); at(PLAYER, 0, 25000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }")
        L.execute("NEED_TABLES, TABLES_COME, LOOT_READY = true, true, false; TICK(12)")
        check(ev(L, "ASKED == 0 and #SPAWNS == 0"), "nobody within 200 m: nothing asked of the game, no spawn")
        L.execute("at(PLAYER, 0, 8000, 100); TICK(1)")
        check(ev(L, "ASKED >= 1"), "a player 80 m away: the game is asked for the tables (%s)" % ev(L, "ASKED"))
        L.execute("TICK(5)")
        check(ev(L, "giant.actor() ~= nil and giant.actor() == LAST"),
              "and the giant comes out on the next try (%d tries, %s asks)" % (ev(L, "#SPAWNS"), ev(L, "ASKED")))
        L.execute("TICK(1)")
        check(ev(L, "#LOOT_CALLS == 1"), "with its military boss loot")

        print("adopting a giant already there")
        L.execute("fresh(); giant._S.spot = nil; at(PLAYER, 0, 6000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }")
        L.execute("OLD = actor(100, 0, 900); OLD.scale = 10.0; BOSSES[1] = OLD; TICK(2)")
        check(ev(L, "#SPAWNS == 0"), "a 10x boss already in the world is taken over, no second one")
        check(ev(L, "giant.actor() == OLD"), "the found one is the giant now")
        check(ev(L, "OLD.DamageComponent.MaxHealth == 2130"), "an already-10x one keeps its health (not x10 again)")
        L.execute("fresh(); at(PLAYER, 0, 6000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }")
        L.execute("SMALL = actor(100, 0, 100); BOSSES[1] = SMALL; TICK(3)")
        check(ev(L, "#SPAWNS == 0 and giant.actor() == SMALL"), "a 1x boss of its class at the spot (a save brought it back) is taken over")
        check(ev(L, "SMALL.scale == 10.0 and SMALL.DamageComponent.MaxHealth == 21300"), "and grown to 10x with 10x health")
        L.execute("fresh(); at(PLAYER, 0, 6000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }")
        L.execute("FAR = actor(50000, 0, 100); BOSSES[1] = FAR; TICK(1)")
        check(ev(L, "#SPAWNS == 1 and FAR.scale == 1.0"), "a boss 500 m from the spot is left alone")

        print("health once")
        L.execute("fresh(); at(PLAYER, 0, 6000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }; TICK(1)")
        L.execute("W = LAST; function W:SetActorScale3D(s) self.scale = 9.99 end; TICK(5)")
        check(ev(L, "W.DamageComponent.MaxHealth == 21300"), "a scale that never reads 10 doesn't multiply health again (%s)"
              % ev(L, "W.DamageComponent.MaxHealth"))
        grown = L.execute('local n = 0 for _, l in ipairs(LOG) do if l:find("giant: grown", 1, true) then n = n + 1 end end return n')
        check(grown == 1, "...and doesn't say so again every second (%d)" % grown)

        print("what it costs: whole-object sweeps")
        L.execute("fresh(); at(PLAYER, 0, 6000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }; SKY_GONE = true; TICK(60)")
        n = ev(L, "SWEPT.Ultra_Dynamic_Sky_C or 0")
        check(n <= 7, "no sky in this world for 60 s: looked for %d times, not every second" % n)
        L.execute("SKY_GONE = false; TICK(11)")
        check(ev(L, "giant._S.tod == 900.0"), "a sky that turns up is read within 11 s")
        n = ev(L, "SWEPT.Ultra_Dynamic_Sky_C")
        L.execute("TICK(30)")
        check(ev(L, "SWEPT.Ultra_Dynamic_Sky_C") == n, "and kept: no more looks")

        BUTCHER = "SWEPT.BP_ZombieBoss_Butcher_Small_C or 0"
        L.execute("fresh(); at(PLAYER, 0, 8000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }")
        L.execute("NEED_TABLES, LOOT_READY = true, false; TICK(60)")
        n = ev(L, BUTCHER)
        check(n <= 3 and ev(L, "#SPAWNS == 0"), "the game's loot tables not loaded for 60 s: %d boss sweeps, not one per try (12)" % n)
        check(ev(L, "ASKED >= 1"), "...and the game is asked for them")
        waits = L.execute('local n = 0 for _, l in ipairs(LOG) do if l:find("waiting to spawn", 1, true) then n = n + 1 end end return n')
        check(waits == 1, "...and the wait is said once (%d)" % waits)
        # never a second giant: the moment one could spawn it is looked for first
        L.execute("OLD = actor(100, 0, 900); OLD.scale = 10.0; BOSSES[1] = OLD; LOOT_READY = true; TICK(6)")
        check(ev(L, "#SPAWNS == 0 and giant.actor() == OLD"), "tables in, a boss arrived during the wait: taken over, no second one")
        L.execute("fresh(); at(PLAYER, 0, 8000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }")
        L.execute("NEED_TABLES, LOOT_READY = true, false; OLD = actor(100, 0, 900); OLD.scale = 10.0; BOSSES[1] = OLD; TICK(6)")
        check(ev(L, "#SPAWNS == 0 and giant.actor() == OLD"), "tables not in, a boss left from before: taken over on the first look")
        L.execute("fresh(); at(PLAYER, 0, 8000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }")
        L.execute("NEED_TABLES, LOOT_READY = true, false; TICK(6); OLD = actor(100, 0, 900); OLD.scale = 10.0; BOSSES[1] = OLD; TICK(35)")
        check(ev(L, "#SPAWNS == 0 and giant.actor() == OLD"), "tables still not in, a boss that came later: taken over within 35 s")

        print("health bar")
        # a real boss: bar 100% (StandardHealthValue) 1951, MaxHealth 2000; the bar stuck at 1951 when only Current/Max went 10x
        L.execute("fresh(); at(PLAYER, 0, 6000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }")
        L.execute("REAL = actor(100, 0, 100); REAL.DamageComponent.StandardHealthValue = 1951; REAL.DamageComponent.MaxHealth = 2000;"
                  " REAL.DamageComponent.CurrentHealth = 1951; BOSSES[1] = REAL; TICK(3)")
        d = "REAL.DamageComponent"
        check(ev(L, d + ".StandardHealthValue == 19510 and " + d + ".MaxHealth == 19510 and " + d + ".CurrentHealth == 19510"),
              "bar 100%%, max and current all 10x the rolled 1951 (%s %s %s)"
              % (ev(L, d + ".StandardHealthValue"), ev(L, d + ".MaxHealth"), ev(L, d + ".CurrentHealth")))
        check(ev(L, d + ".told ~= nil and " + d + ".told[1] == 19510 and " + d + ".told[2] == 19510"),
              "the component's SetCurrent&MaxHealth event is told the new health")
        check(ev(L, d + '["CanHeadshot1Shot?"] == false'), "a headshot can't kill it in one shot")
        # one grown before the bar fix (game or mod restart): 10x, Current/Max 20000, bar still 1951
        L.execute("fresh(); at(PLAYER, 0, 6000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }")
        L.execute("OLDBAR = actor(100, 0, 900); OLDBAR.scale = 10.0; OLDBAR.DamageComponent.StandardHealthValue = 1951;"
                  " OLDBAR.DamageComponent.MaxHealth = 20000; OLDBAR.DamageComponent.CurrentHealth = 19800; BOSSES[1] = OLDBAR; TICK(2)")
        d = "OLDBAR.DamageComponent"
        check(ev(L, d + ".StandardHealthValue == 20000 and " + d + ".CurrentHealth == 19800 and " + d + ".MaxHealth == 20000"),
              "an old giant taken over gets its bar at 20000 and keeps the damage it took (%s %s)"
              % (ev(L, d + ".StandardHealthValue"), ev(L, d + ".CurrentHealth")))
        check(ev(L, d + ".told ~= nil and " + d + '["CanHeadshot1Shot?"] == false'), "and the bar is told, headshot one-shot off")

        print("richer loot")
        L.execute("fresh(); at(PLAYER, 0, 6000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }; TICK(2)")
        L.execute("LZ = LAST; J = LZ.BP_JigMultiplayer; IT = J.ContainersSettings[1][START]")
        check(ev(L, "LZ.LootTable == 8"), "the giant is on the MilitaryBoss table (8)")
        check(ev(L, "#LOOT_CALLS == 1 and LOOT_CALLS[1].t == 8 and LOOT_CALLS[1].jig == J and LOOT_CALLS[1].c == 0"
                    " and LOOT_CALLS[1].wc == LZ"), "the game's SetLootTable_AI_DA(8, its jig, 0, itself) puts the table on it")
        check(ev(L, "IT[1][CHANCE] == 60 and IT[2][CHANCE] == 100 and IT[3][CHANCE] == 100"),
              "each item's chance doubled, 100 at most (30 60 100 -> %s %s %s)"
              % (ev(L, "IT[1][CHANCE]"), ev(L, "IT[2][CHANCE]"), ev(L, "IT[3][CHANCE]")))
        check(ev(L, 'table.concat(J.calls, ",") == "clear true,init"'),
              "then cleared with its init reopened and rolled again (%s)" % ev(L, 'table.concat(J.calls, ",")'))
        L.execute("TICK(10)")
        check(ev(L, "#LOOT_CALLS == 1 and #J.calls == 2 and IT[1][CHANCE] == 60"), "only once per giant")
        L.execute("fresh(); at(PLAYER, 0, 6000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }")
        L.execute("RICH = actor(100, 0, 900); RICH.scale = 10.0; RICH.LootTable = 8; BOSSES[1] = RICH; TICK(3)")
        check(ev(L, "giant.actor() == RICH and #LOOT_CALLS == 0 and #RICH.BP_JigMultiplayer.calls == 0"),
              "a giant already on the table (mod restart) is not rolled again")
        L.execute("fresh(); at(PLAYER, 0, 6000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }")
        L.execute("LOOT_READY = false; SM = actor(100, 0, 100); BOSSES[1] = SM; TICK(3)")
        check(ev(L, "#LOOT_CALLS == 0 and SM.LootTable == 10"), "the AI loot tables not loaded: it waits (no sync load)")
        check(ev(L, "ASKED >= 1"), "and asks the game to load them (a garbage collection took them)")
        L.execute("LOOT_READY = true; TICK(1)")
        check(ev(L, "#LOOT_CALLS == 1 and SM.LootTable == 8"), "and does it once they are")
        L.execute("fresh(); at(PLAYER, 0, 6000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }")
        L.execute("BAD = actor(100, 0, 100); BAD.BP_JigMultiplayer = nil; BOSSES[1] = BAD; TICK(3)")
        check(ev(L, "giant.actor() == BAD and BAD.scale == 10.0"), "a boss with no jig still becomes the giant")
        check(L.execute('for _, l in ipairs(LOG) do if l:find("richer loot failed", 1, true) then return true end end return false'),
              "and the loot failure is logged as a warning")
        L.execute("n0 = #LOG; TICK(5)")
        check(L.execute('for i = n0 + 1, #LOG do if LOG[i]:find("richer loot", 1, true) then return false end end return true'),
              "not retried every tick")

        print("guarding")
        L.execute("fresh(); at(PLAYER, 0, 6000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }; TICK(2)")
        L.execute("G = LAST; at(G, 3000, 0, 100); at(PLAYER, 0, 7000, 100); MOVES = {}; TICK(1)")
        check(ev(L, "#MOVES == 1 and MOVES[1].X == 0 and MOVES[1].Y == 0"), "30 m off with nobody at its spot: walks home")
        L.execute("TICK(4)")
        check(ev(L, "#MOVES == 1"), "the walk order is not repeated every second")
        L.execute("TICK(1)")
        check(ev(L, "#MOVES == 2"), "repeated after 5 s while still away")
        L.execute("MOVES = {}; at(PLAYER, 0, 2000, 100); TICK(6)")
        check(ev(L, "#MOVES == 0"), "a player within 50 m of its spot: no walking home, its AI fights")
        L.execute("GHOSTS = { actor(500, 0, 100) }; at(PLAYER, 0, 90000, 100); TICK(6)")
        check(ev(L, "#MOVES == 0"), "a guest's ghost at its spot counts too")
        L.execute("GHOSTS = {}; at(PLAYER, 0, 7000, 100); at(G, 15000, 0, 100); TICK(1)")
        check(ev(L, "G.teleports == 1 and G.loc.X == 0"), "150 m off with nobody near it: put back on its spot")
        L.execute("at(G, 15000, 0, 100); at(PLAYER, 15500, 0, 100); TICK(1)")
        check(ev(L, "G.teleports == 1"), "never put back while a player is next to it")

        print("host blob")
        L.execute("HOST_Z = { [41] = actor(1, 1, 1), [42] = G }; TICK(1)")
        check(ev(L, 'BLOBS[#BLOBS] == "giant=42 10.0"'), "the guest is told the giant's copy id and size")
        L.execute("HOST_Z = {}; TICK(1)")
        check(ev(L, 'BLOBS[#BLOBS] == "giant=-"'), "out of the guest's range: none")
        # audit 2026-11-02: more than two players - one giant for all, each guest told its own copy's id
        L.execute("C2 = guest_copy('to2'); HOST_Z = { [42] = G }; C2.host_z = { [7] = G }; N1 = #BLOBS; TICK(1)")
        check(ev(L, 'BLOBS[#BLOBS] == "giant=42 10.0" and C2.blobs[#C2.blobs] == "giant=7 10.0"'),
              "a second guest's copy is told its own copy id (%s / %s)" % (ev(L, "BLOBS[#BLOBS]"), ev(L, "C2.blobs[#C2.blobs]")))
        L.execute("TICK(1)")
        check(ev(L, "#BLOBS == N1 + 1 and #C2.blobs == 1"), "...each sent once, not every second")
        L.execute("C2.host_z = {}; TICK(1)")
        check(ev(L, 'C2.blobs[#C2.blobs] == "giant=-" and BLOBS[#BLOBS] == "giant=42 10.0"'),
              "the second guest out of range gets none, the first keeps its id")
        L.execute("INSTS = {}; HOST_Z = {}")

        print("death and respawn")
        L.execute("at(PLAYER, 0, 6000, 100); HOST_Z = {}; G.DamageComponent.CurrentHealth = 0; TICK(1)")
        check(ev(L, "giant._S.dead == 0"), "health 0: it counts as dead")
        check(ev(L, 'FILES[path()]:find("|0.000\\n", 1, true) ~= nil'), "its death is saved")
        check(ev(L, 'NOTES[#NOTES]:find("comes back in 15 days", 1, true) ~= nil'), "the player is told when it comes back")
        n_dead = ev(L, "#SPAWNS")
        # 14 days: the clock runs 14 full turns in steps of 600 (4 per day)
        L.execute('for i = 1, 14 * 4 do SKY["Time of Day"] = (SKY["Time of Day"] + 600) % 2400; TICK(1) end')
        check(ev(L, "#SPAWNS") == n_dead, "14 in-game days later: still dead")
        check(ev(L, "math.abs(giant._S.dead - 14) < 0.01"), "14 days counted (%.3f)" % ev(L, "giant._S.dead"))
        check(ev(L, 'FILES[path()]:find("|14.000\\n", 1, true) ~= nil'), "the count is saved as whole days go by")
        L.execute("fresh(); TICK(1)")
        check(ev(L, "math.abs(giant._S.dead - 14) < 0.01"), "a reload reads the 14 days back")
        L.execute('at(PLAYER, 0, 6000, 100); for i = 1, 4 do SKY["Time of Day"] = (SKY["Time of Day"] + 600) % 2400; TICK(1) end; TICK(6)')
        check(ev(L, "giant._S.dead == nil"), "day 15: alive again")
        check(ev(L, "#SPAWNS == 1"), "and it spawns again at its spot")

        print("other worlds")
        L.execute('fresh(); WORLD = "OtherSave"; TICK(2)')
        check(ev(L, "giant._S.spot.X == giant.HOME_SPOT.X and giant._S.spot.X ~= 0"),
              "another world keeps the home spot, not the spot moved in QuickSave1")
        L.execute('WORLD = "QuickSave1"')

        print("guest")
        L.execute("fresh(); ROLE = 'guest'; C = actor(0, 0, 0); COPIES[42] = C; host_sends('42 10.0'); TICK(1)")
        check(ev(L, "C.scale == 10.0"), "the guest makes the host's giant copy 10x")
        L.execute("C.scale = 1.0; TICK(1)")
        check(ev(L, "C.scale == 10.0"), "a respawned copy is made 10x again (the last blob is kept)")
        # the guest leaves and comes back while the host's blob stays '42 10.0' (sent once, never again)
        L.execute("for _, f in ipairs(RESETS) do f() end; C2 = actor(0, 0, 0); COPIES[42] = C2; TICK(2)")
        check(ev(L, "C2.scale == 10.0"), "back in the world with the host's blob unchanged: the copy is 10x again")
        L.execute("host_sends('-'); C.scale = 1.0; COPIES[42] = C; TICK(1)")
        check(ev(L, "C.scale == 1.0"), "'-': nothing resized")
        check(ev(L, "#SPAWNS == 0"), "a guest never spawns a giant")
        L.execute("NOTES = {}; KEYS.G()")
        check(ev(L, 'NOTES[1] ~= nil and NOTES[1]:find("Only the host", 1, true) ~= nil'), "a guest's Ctrl+G is refused")

        print("clear")
        L.execute("fresh(); at(PLAYER, 0, 6000, 100); giant.place_here(); giant._S.spot = { X = 0, Y = 0, Z = 100 }; TICK(2); G = LAST")
        L.execute("giant.clear_here()")
        check(ev(L, "G.alive == false and giant._S.spot == nil"), "clear removes the giant and its spot")
        check(ev(L, 'FILES[path()]:find("QuickSave1|off|-", 1, true) ~= nil'), "and its line says off (no line would mean the home spot)")
        L.execute("fresh(); at(PLAYER, giant.HOME_SPOT.X, giant.HOME_SPOT.Y + 6000, giant.HOME_SPOT.Z); TICK(3)")
        check(ev(L, "giant._S.spot == nil and #SPAWNS == 0"), "a reload keeps it off")
        L.execute("giant.place_here()")
        check(ev(L, 'giant._S.spot ~= nil and not FILES[path()]:find("QuickSave1|off", 1, true)'), "Ctrl+G brings it back there")

        errs = L.execute('local n = 0 for _, l in ipairs(LOG) do if l:find("^SAFE") or l:find("^ERROR") then n = n + 1; print(l) end end return n')
        check(errs == 0, "no Lua errors in any tick (%d)" % errs)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print()
    if fails:
        print("%d FAILED:" % len(fails))
        for f in fails:
            print("  " + f)
        return 1
    print("ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(run())
