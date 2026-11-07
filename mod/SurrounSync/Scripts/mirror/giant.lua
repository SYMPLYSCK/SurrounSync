-- The forest giant: one fat zombie boss at 10x size and 10x health that guards a spot in the forest - in every world
-- the same one (giant.HOME_SPOT, placed by the creator 2026-11-02) unless the host moves it (Ctrl+G where they
-- stand). The host (or a solo player) runs it; a guest sees the host's giant as the usual zombie copy,
-- made 10x by the "giant" blob ("<copy id> <scale>", "-" when there is none).
-- It comes out when the host is 30-200 m from its spot; the AI loot tables every zombie spawn needs are asked of the
-- game then (zombies.load_loot_tables), so a spot with no other AI around works too.
-- Spawning follows the zombie rules (zombies.spawn_safe: loaded class and looks only, DBG-20261101-012): at 1x
-- first and scaled on a later tick, the way the kit trial (2026-11-01 23:32) showed it keeps its AI controller.
-- One giant per world, kept in mirror_giant.txt next to the saves, one line per world save:
--   <save>|<x> <y> <z>|<days dead>        days dead "-": alive (or not killed yet)
--   <save>|off|-                          removed from that world (devtest giant clear)
-- A world with no line has the giant at HOME_SPOT, alive; its line is written when it dies or is moved.
-- It comes back 15 in-game days after it died: the days are counted from the sky's Time of Day while that world
-- is played (the player controller's DaysSurvived is per player and starts over on their death).

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local fs = require("mirror.fs")

local giant = {}

local CLASSES = {
    "/Game/AI/Zombies/Boss/Types/BP_ZombieBoss_Butcher_Small.BP_ZombieBoss_Butcher_Small_C",
    "/Game/AI/Zombies/Boss/Types/BP_ZombieBoss_Slobber_Small.BP_ZombieBoss_Slobber_Small_C",
}
giant.SCALE = 10.0
giant.HEALTH_X = 10.0
giant.RESPAWN_DAYS = 15
giant.HOME_SPOT = { X = 202905.7, Y = 8343.9, Z = 11280.9 }   -- the forest spot every world starts with
giant.LOOT_TABLE = 8        -- Enum_AILootTables MilitaryBoss (keycards, military laptop, large medkits, rifle ammo)
giant.LOOT_X = 2.0          -- each item's spawn chance doubled (100 at most)
local GFL = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"
local START = "StartingItems_10_C6DB208442353E0AA9B5DB892266821A"   -- (BP struct fields keep their GUID names)
local CHANCE = "SpawnChance_9_0A1811814580181DD09AE78500C25A28"
-- a player 30-200 m from the spot: its ground is loaded, no pop-in at them (fields: the kit test spawns it closer)
giant.SPAWN_FAR, giant.SPAWN_NEAR = 20000.0, 3000.0
local GUARD = 5000.0                             -- nobody within 50 m of the spot: the giant walks home
local HOME = 800.0                               -- close enough to the spot
local LEASH = 12000.0                            -- dragged more than 120 m off: put back on the spot (nobody near it)
local STEP = 1.0                                 -- seconds between checks
local TRY_EVERY = 5.0                            -- seconds between spawn tries
local ADOPT_WAIT = 30.0                          -- seconds between looks for a boss while no spawn can happen
local SKY_LOOK = 10.0                            -- seconds between looks for a sky this world hasn't got yet
local MOVE_EVERY = 5.0

-- (one copy for the whole game, peers.lua SHARED: with more than two players a copy per guest each spawned, grew -
-- health 100x - and mourned the same boss. blobs and copy ids are per guest link, by its tag)
local S = { path = nil, key = nil, spot = nil, dead = nil, z = nil, scaled = false, tod = nil, saved_day = nil,
            step_in = 0.0, move_in = 0.0, spawn_in = 0.0, why = nil, blobs = {}, role_fn = function() return nil end,
            seen = nil, copy_ids = {} }

local function vec(s)
    local x, y, z = (s or ""):match("^(%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+)$")
    if not x then return nil end
    return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
end

-- the file's lines -> { [save] = { spot = vec, dead = days|nil } }
function giant.parse(text)
    local out = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local key, spot, dead = line:match("^([^|]+)|([^|]+)|([^|]+)$")
        local v = spot and vec(spot)
        if v then out[key] = { spot = v, dead = tonumber(dead) } elseif spot == "off" then out[key] = { off = true } end
    end
    return out
end

function giant.format(all)
    local keys = {}
    for k in pairs(all) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        local e = all[k]
        out[#out + 1] = e.off and (k .. "|off|-") or string.format("%s|%.1f %.1f %.1f|%s", k, e.spot.X, e.spot.Y,
            e.spot.Z, e.dead and string.format("%.3f", e.dead) or "-")
    end
    return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
end

-- in-game days between two Time of Day readings (0-2400, wraps at midnight)
function giant.days_between(a, b)
    if type(a) ~= "number" or type(b) ~= "number" then return 0 end
    local d = b - a
    if d < 0 then d = d + 2400 end
    return d / 2400
end

local function load_world(key)
    S.key, S.spot, S.dead, S.z, S.scaled, S.tod, S.why, S.copy_ids, S.off = key, nil, nil, nil, false, nil, nil, {}, nil
    if not S.path then
        local dir
        pcall(function() dir = require("mirror.session").saves_dir() end)
        if type(dir) == "string" and dir ~= "" then S.path = dir:gsub("\\SaveGames$", "") .. "\\mirror_giant.txt" end
    end
    if not key then return end
    local e = S.path and giant.parse(fs.read(S.path))[key]
    if e and e.off then S.off = true
    elseif e then S.spot, S.dead = e.spot, e.dead
    else S.spot = util.vec(giant.HOME_SPOT) end
    S.saved_day = S.dead and math.floor(S.dead) or nil
end

-- The world's line in the file: its save's name. A Realm is played in a co-op slot that the next Realm or session
-- reuses (session.next_coop_slot), so a Realm's giant goes by "Realm <id>"; a co-op slot that isn't my Realm right
-- now (loading into it, or a guest's) has none.
function giant.world_key()
    local key = require("mirror.session").world_save()
    if not key then return nil end
    local coop = false
    pcall(function() coop = require("mirror.slotguard").is_coop(key) end)
    if not coop then return key end
    local id
    pcall(function() id = require("mirror.realmplay").hosting_id() end)
    return id and ("Realm " .. id) or nil
end

local function save_world()
    if not (S.path and S.key) then return end
    local all = giant.parse(fs.read(S.path))
    all[S.key] = S.off and { off = true } or S.spot and { spot = S.spot, dead = S.dead } or nil
    if not fs.write(S.path, giant.format(all)) then log.warn("giant: couldn't write " .. tostring(S.path)) end
end

local function loc_of(a)
    local l
    if util.valid(a) then pcall(function() l = util.vec(a:K2_GetActorLocation()) end) end
    return l
end

local function player_spots()
    local who = {}
    pcall(function() who = require("mirror.peers").ghost_list() end)
    who[#who + 1] = game.player()
    local out = {}
    for _, p in ipairs(who) do
        local l = loc_of(p)
        if l then out[#out + 1] = l end
    end
    return out
end

local function nearest(spots, at)
    local best = math.huge
    for _, l in ipairs(spots) do
        local d = util.dist(l, at)
        if d < best then best = d end
    end
    return best
end

local function dead_of(z)
    if require("mirror.zombies").dead_of(z, "boss") then return true end
    local h
    pcall(function() h = z.DamageComponent.CurrentHealth end)
    return type(h) == "number" and h <= 0
end

local function scale_of(a)
    local s
    pcall(function() s = a:GetActorScale3D().X end)
    return s
end

-- one of ours left in the world (a reload or a mod restart): taken over, never a second one. A boss of the giant's
-- class near its spot, at any size (a game that saved it may bring it back at 1x) - grown again if it is small.
local function adopt()
    for _, p in ipairs(CLASSES) do
        for _, o in ipairs(FindAllOf(p:match("([^%.]+)$")) or {}) do
            local l = loc_of(o)
            if l and util.dist(l, S.spot) <= LEASH and not dead_of(o) then return o end
        end
    end
    return nil
end

-- The boss's health bar shows CurrentHealth capped at StandardHealthValue (its 100%): with only Current/Max at 10x it
-- sat at the boss's own 1951 and never moved (user 2026-11-02). Its 100% follows MaxHealth, the component's own
-- SetCurrent&MaxHealth event tells the bar, and no headshot kills it in one shot (CanHeadshot1Shot?).
local function fit_bar(z)
    pcall(function()
        local d = z.DamageComponent
        if (tonumber(d.StandardHealthValue) or 0) < d.MaxHealth then d.StandardHealthValue = d.MaxHealth end
    end)
    pcall(function() z.DamageComponent["CanHeadshot1Shot?"] = false end)
    pcall(function() local d = z.DamageComponent; d["SetCurrent&MaxHealth_Event"](d, d.CurrentHealth, d.MaxHealth) end)
end

local function grow(z)
    local first = S.health_for ~= z
    pcall(function() z:SetActorScale3D({ X = giant.SCALE, Y = giant.SCALE, Z = giant.SCALE }) end)
    -- (health once per actor: a scale that doesn't read back 10 runs grow again next tick). The base is the bar's
    -- 100% (StandardHealthValue, the boss's rolled health); all three end at 10x of it, a full bar.
    if S.health_for ~= z then
        pcall(function()
            local d = z.DamageComponent
            local base = tonumber(d.StandardHealthValue) or 0
            if base <= 0 then base = (d.MaxHealth or 0) > 0 and d.MaxHealth or d.CurrentHealth end
            d.StandardHealthValue = base * giant.HEALTH_X
            d.MaxHealth = base * giant.HEALTH_X
            d.CurrentHealth = base * giant.HEALTH_X
        end)
        fit_bar(z)
    end
    S.health_for = z
    local s = scale_of(z)
    S.scaled = s ~= nil and math.abs(s - giant.SCALE) < 0.01
    if not first then return end
    local h
    pcall(function() h = z.DamageComponent.CurrentHealth end)
    log.info(string.format("giant: grown to %.0fx, health %s", scale_of(z) or 0, tostring(h)))
end

-- The giant drops the military boss's loot at 2x (user 2026-11-02). The game's own SetLootTable_AI_DA (the one a
-- zombie's construction script runs) puts that table's item list on the boss's jig, a copy per actor; each item's
-- spawn chance is doubled there, then the jig is cleared and filled again the way the game refills a container:
-- ClearContainer(true) opens its init gate once more and InitializeJigComponent rolls the items (BP_JigComponent,
-- decompiled 2026-11-02). Once per actor: a giant already on the table (a mod restart) is not rolled again.
local function richer_loot(z)
    if S.loot_for == z then return end
    local cur
    pcall(function() cur = tonumber(z.LootTable) end)
    if cur == giant.LOOT_TABLE then S.loot_for = z; return end
    -- (SetLootTable_AI_DA loads the AI tables by path: only once the game has them loaded, L-014 - asked for when
    -- a garbage collection took them since the spawn)
    local zombies = require("mirror.zombies")
    if zombies.loot_ready and not zombies.loot_ready() then
        if zombies.load_loot_tables then zombies.load_loot_tables() end
        return
    end
    S.loot_for = z
    local n = 0
    local ok, err = pcall(function()
        local jig = z.BP_JigMultiplayer
        util.cdo(GFL):SetLootTable_AI_DA(giant.LOOT_TABLE, jig, 0, z)
        util.each(jig.ContainersSettings[1][START], function(_, e)
            local it = e:get()
            it[CHANCE] = math.min(100.0, (tonumber(it[CHANCE]) or 0) * giant.LOOT_X)
            n = n + 1
        end)
        jig:ClearContainer(true)
        jig:InitializeJigComponent()
        z.LootTable = giant.LOOT_TABLE   -- (last: the mark that it is done)
    end)
    if ok then
        log.info(string.format("giant: loot table %d (was %s), %d item chances x%.0f, rolled again",
            giant.LOOT_TABLE, tostring(cur), n, giant.LOOT_X))
    else
        log.warn("giant: richer loot failed after " .. n .. " items - " .. tostring(err))
    end
end

local function try_spawn()
    local zombies = require("mirror.zombies")
    local ready, missing = true, nil
    if zombies.loot_ready then ready, missing = zombies.loot_ready() end
    -- adopt walks every object once per boss class, 6-10 ms each: while the loot tables keep any spawn from happening
    -- it waits, and it always runs right before a real spawn (never a second giant)
    S.adopt_in = (S.adopt_in or 0) - TRY_EVERY
    local found
    if ready or S.adopt_in <= 0 then
        S.adopt_in = ADOPT_WAIT
        found = adopt()
    end
    if found then
        -- (already 10x: ours from before a mod restart, health done; smaller: grown on the next tick)
        local s = scale_of(found)
        local big = s ~= nil and math.abs(s - giant.SCALE) < 0.01
        S.z, S.scaled, S.health_for = found, big, big and found or nil
        if big then fit_bar(found) end   -- (one grown before the bar fix keeps its health but gets a moving bar)
        log.info(string.format("giant: found a %.0fx boss at its spot - it is the giant", s or 0))
        return
    end
    -- (a quiet spot has no ordinary AI, so the game hasn't loaded the AI loot tables every zombie spawn needs: the
    -- game is asked to load them, and the try 5 s later finds them - user 2026-11-02: it comes when a player is near)
    if not ready then
        if zombies.load_loot_tables then zombies.load_loot_tables() end
        local wait = tostring(missing or "some") .. " AI loot table(s) not loaded yet"
        if wait ~= S.why then S.why = wait; log.info("giant: waiting to spawn - " .. wait) end
        return
    end
    local why
    for _, p in ipairs(CLASSES) do
        local z, w = zombies.spawn_safe(p, { X = S.spot.X, Y = S.spot.Y, Z = S.spot.Z + 50 }, 0)
        if util.valid(z) then
            S.z, S.scaled, S.why = z, false, nil
            log.info("giant: spawned " .. p:match("([^%.]+)$") .. " at its spot")
            return
        end
        why = why or w
    end
    why = why or "no fat boss class loaded yet"
    if why ~= S.why then S.why = why; log.info("giant: waiting to spawn - " .. why) end
end

local function move_home(z)
    local ctl
    pcall(function() ctl = z.Controller end)
    if not util.valid(ctl) then return false end
    local ok = pcall(function()
        util.cdo("/Script/AIModule.Default__AIBlueprintHelperLibrary"):SimpleMoveToLocation(ctl, S.spot)
    end)
    return ok
end

local function guard(z, spots)
    local at = loc_of(z)
    if not at then return end
    local home = util.dist(at, S.spot)
    if nearest(spots, S.spot) <= GUARD then return end   -- someone at its spot: its own AI fights them
    if home > LEASH and nearest(spots, at) > GUARD then
        pcall(function() z:K2_SetActorLocation({ X = S.spot.X, Y = S.spot.Y, Z = S.spot.Z + 50 }, false, {}, true) end)
        log.info(string.format("giant: %.0f m from its spot with nobody near - put back", home / 100))
    elseif home > HOME then
        S.move_in = S.move_in - STEP
        if S.move_in <= 0 then S.move_in = MOVE_EVERY; move_home(z) end
    end
end

-- every guest's link: the main one, and with more than two players each other guest's copy (peers.lua), with that
-- copy's own zombie sync (its own copy ids)
local function each_link(fn)
    require("mirror.peers").each("mirror.link", function(link, inst)
        local zm
        if inst then zm = inst.loaded["mirror.zombies"] else zm = require("mirror.zombies") end
        fn(link, zm, inst and inst.tag or "main")
    end)
end

-- the copy id a guest's zombie sync gave the giant (only while that guest is near enough to get it)
local function copy_id(z, zm, tag)
    local have = S.copy_ids[tag]
    if have then
        if util.same(zm.host_zombies()[have], z) then return have end
        S.copy_ids[tag] = nil
    end
    for id, c in pairs(zm.host_zombies()) do
        if util.same(c, z) then S.copy_ids[tag] = id; return id end
    end
    return nil
end

-- the "giant" blob to every guest: their copy's id and size, "-" for none (z nil)
local function put_blob(z)
    each_link(function(link, zm, tag)
        local id = z and zm and copy_id(z, zm, tag)
        local v = id and string.format("%d %.1f", id, giant.SCALE) or "-"
        if v == S.blobs[tag] then return end
        S.blobs[tag] = v
        pcall(function() link.put_blob("giant", v) end)
    end)
end

local function sky_tod()
    local tod
    pcall(function()
        local s = S.sky
        if not util.valid(s) then
            s = nil
            S.sky_in = (S.sky_in or 0) - STEP
            if S.sky_in <= 0 then
                S.sky_in = SKY_LOOK
                for _, o in ipairs(FindAllOf("Ultra_Dynamic_Sky_C") or {}) do
                    if util.valid(o) and not o:GetFullName():find("Default__", 1, true) then s = o; break end
                end
            end
            S.sky = s
        end
        tod = s and s["Time of Day"]
    end)
    return type(tod) == "number" and tod or nil
end

local function host_step()
    local key = giant.world_key()
    if not key or not util.valid(game.player()) then return end
    if key ~= S.key then load_world(key) end
    if not S.spot then put_blob(nil); return end
    local tod = sky_tod()
    if S.dead then
        S.dead = S.dead + giant.days_between(S.tod, tod)
        if S.dead >= giant.RESPAWN_DAYS then
            S.dead = nil
            log.info("giant: " .. giant.RESPAWN_DAYS .. " days are up - it comes back")
            save_world()
        elseif math.floor(S.dead) ~= S.saved_day then
            S.saved_day = math.floor(S.dead)
            save_world()
        end
    end
    S.tod = tod
    local z = S.z
    if z and not util.valid(z) then S.z, z = nil, nil end
    if z and dead_of(z) then
        S.z, S.dead, S.saved_day, S.copy_ids = nil, 0, 0, {}
        save_world()
        log.info("giant: killed - back in " .. giant.RESPAWN_DAYS .. " in-game days")
        pcall(function() require("mirror.notify").show("The forest giant is down. It comes back in "
            .. giant.RESPAWN_DAYS .. " days.", "good", "giant") end)
        put_blob(nil)
        return
    end
    local spots = player_spots()
    if z then
        if not S.scaled then grow(z) end
        richer_loot(z)
        guard(z, spots)
        put_blob(z)
        return
    end
    put_blob(nil)
    if S.dead then return end
    local d = nearest({ game.player() and loc_of(game.player()) or nil }, S.spot)
    if d > giant.SPAWN_FAR or d < giant.SPAWN_NEAR then return end
    if require("mirror.save_guard").busy() then return end
    S.spawn_in = S.spawn_in - STEP
    if S.spawn_in > 0 then return end
    S.spawn_in = TRY_EVERY
    try_spawn()
end

-- a guest: the host's giant is a zombie copy; make it as big as the host's
local function guest_step()
    local b = nil
    pcall(function() b = require("mirror.link").get_blob("giant") end)
    if b then S.seen = b end
    local id, scale = (S.seen or ""):match("^(%d+) ([%d%.]+)$")
    if not id then return end
    local z = require("mirror.zombies").copy_actor(tonumber(id))
    if not z then return end
    scale = tonumber(scale)
    local s = scale_of(z)
    if s and math.abs(s - scale) > 0.01 then
        pcall(function() z:SetActorScale3D({ X = scale, Y = scale, Z = scale }) end)
        log.info(string.format("giant: the host's giant (copy %s) made %.0fx", id, scale))
    end
end

local function tick(dt)
    S.step_in = S.step_in - dt
    if S.step_in > 0 then return end
    S.step_in = STEP
    if S.role_fn() == "guest" then guest_step() else host_step() end
end

-- Ctrl+G: the giant guards where I stand (host or solo); one already out walks there from where it is
function giant.place_here()
    if S.role_fn() == "guest" then
        pcall(function() require("mirror.notify").show("Only the host can place the forest giant.", "warn", "giant") end)
        return false
    end
    local key = giant.world_key()
    local at = loc_of(game.player())
    if not (key and at) then return false end
    if key ~= S.key then load_world(key) end
    S.spot, S.off = at, nil
    save_world()
    log.info(string.format("giant: guards %.0f %.0f %.0f now", at.X, at.Y, at.Z))
    pcall(function() require("mirror.notify").show("The forest giant guards this spot now. Walk away and it comes.",
        "info", "giant") end)
    return true
end

function giant.clear_here()
    if S.role_fn() == "guest" or not S.key then return false end
    if util.valid(S.z) then pcall(function() S.z:K2_DestroyActor() end) end
    S.spot, S.dead, S.z, S.off = nil, nil, nil, true   -- (off, not just no line: no line means HOME_SPOT)
    save_world()
    put_blob(nil)
    log.info("giant: removed from this world")
    return true
end

function giant.status()
    if not S.spot then return "giant: none" end
    if S.dead then return string.format("giant: dead, %.1f of %d days", S.dead, giant.RESPAWN_DAYS) end
    if util.valid(S.z) then
        local at = loc_of(S.z)
        return string.format("giant: out, %.0fx, %.0f m from its spot", scale_of(S.z) or 0,
            at and util.dist(at, S.spot) / 100 or -1)
    end
    return "giant: waiting" .. (S.why and (" - " .. S.why) or "")
end

function giant.actor() return S.z end

-- (the link hands a blob out only when it changes: the cached one is forgotten here, so the link must hand the
-- unchanged "giant" out again - else a guest back in the world keeps a 1x copy, as phase1 resets its blobs)
local function forget_world()
    S.key, S.z, S.scaled, S.tod, S.sky, S.copy_ids, S.blobs, S.seen, S.health_for, S.loot_for = nil, nil, false, nil, nil, {}, {}, nil, nil, nil
    S.sky_in, S.adopt_in = nil, nil
    pcall(function() each_link(function(link) link.reset_blob("giant") end) end)
end

-- role_getter: the co-op role ("host" / "guest" / nil outside co-op)
function giant.init(role_getter)
    if S.inited then return end
    S.inited = true
    S.role_fn = role_getter or S.role_fn
    game.on_world_reset(forget_world)
    game.on_tick(function(dt) util.safe(tick, "giant.tick", dt) end)
    game.keybind("G", { ModifierKey.CONTROL }, function() util.safe(giant.place_here, "giant.place_here") end)
end

giant._S = S
return giant
