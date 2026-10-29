-- Zombie hounds bark. The game has no bark sound at all (only the hound's growls), so SurrounSyncSounds.pak
-- (Paks\LogicMods) brings four dog sounds; BPModLoader spawns its ModActor at every level load, whose AudioComponents
-- hold them, so the engine has them loaded (never loaded from Lua: L-014).
-- A hound that first comes within NEAR of the player barks once; one chasing the player (closing in, or right on
-- them) barks on and on, one bark after the other; the moment it dies its bark stops. Every game does this for its
-- own player and the hounds it shows (a guest's are the host's copies), so audio.lua doesn't pass these sounds on.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")

local dogs = {}

local DIR = "/Game/Mods/SurrounSyncSounds/"
local SOUNDS = { bark1 = "DogBark1", bark2 = "DogBark2", growl = "DogGrowl", fit = "DogBarking" }
local HOUND = "/Game/AI/Zombies/Dog/BP_Zombie_Dog.BP_Zombie_Dog_C"
local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local GS = "/Script/Engine.Default__GameplayStatics"
local RANGE, NEAR, ON_YOU = 3500, 1000, 600   -- cm
local CLOSING = 150                           -- cm/s towards the player = chasing
local CHASE_HOLD = 1.5                        -- s a chase lasts after it stops closing in
local POLL, FORGET = 0.2, 10.0                -- s
-- EObjectTypeQuery 2 = WorldDynamic, 3 = Pawn (an animal dog's capsule is WorldDynamic - kit: Pawn alone missed it)
local OBJ_TYPES = { 1, 2 }

local hounds = {}                             -- address -> { z, d, near_done, chase_until, next_at, snd, seen, dead }
local clock, poll_in, missing_told = 0.0, 0.0, false
local stats = { near = 0, chase = 0, stopped = 0 }
local cfg

local function sound(k)
    local n = SOUNDS[k]
    return util.find(DIR .. n .. "." .. n)
end

local function dead_of(z)
    local ok, zm = pcall(require, "mirror.zombies")
    if ok and zm.dead_of and zm.dead_of(z, "zombie") then return true end
    local gone = false
    pcall(function() gone = z:IsActorBeingDestroyed() end)
    return gone
end

-- The bark's AudioComponent destroys itself when the sound ends (auto destroy) and can be freed soon after: it is
-- only touched while it surely still plays (until its sound's length, pitch included, has passed). Calls through a
-- freed component's wrapper are the native-crash kind of DBG-20261027-008.
local function playing(h) return h.snd ~= nil and clock < h.snd_until end

local function stop(h)
    local s, on = h.snd, playing(h)
    h.snd = nil
    if on and util.valid(s) and pcall(function() s:Stop() end) then stats.stopped = stats.stopped + 1 end
end

local function play(h, kind)
    local snd, gs, root = sound(kind), util.cdo(GS), nil
    pcall(function() root = h.z:K2_GetRootComponent() end)
    if not (util.valid(snd) and gs and util.valid(root)) then return false end
    local len, pitch = 2.0, 0.92 + math.random() * 0.16
    pcall(function() local d = tonumber(snd.Duration); if d and d > 0 and d < 60 then len = d end end)
    local comp
    pcall(function()
        comp = gs:SpawnSoundAttached(snd, root, FName("None"), { X = 0, Y = 0, Z = 30 }, { Pitch = 0, Yaw = 0, Roll = 0 }, 0,
            true, 1.0, pitch, 0.0, nil, nil, true)
    end)
    if not util.valid(comp) then return false end
    h.snd, h.snd_until = comp, clock + len / pitch
    return true
end

local function chase_kind()
    local r = math.random()
    return r < 0.4 and "fit" or (r < 0.65 and "bark1" or (r < 0.9 and "bark2" or "growl"))
end

local function poll(dt)
    if not util.valid(sound("bark1")) then
        if not missing_told then
            missing_told = true
            log.info("dogs: the dog sounds aren't loaded (SurrounSyncSounds.pak in Paks\\LogicMods, BPModLoaderMod on) - hounds stay quiet")
        end
        return
    end
    local p, k, w = game.player(), util.cdo(KSL), game.world()
    local cls = util.find(HOUND)
    if not (util.valid(p) and k and w) then return end
    local at
    pcall(function() at = util.vec(p:K2_GetActorLocation()) end)
    if not at then return end
    -- every hound already known: a dead one is silenced at once (its capsule may be out of the query by now)
    for a, h in pairs(hounds) do
        if not (util.valid(h.z) and util.addr(h.z) == a) then stop(h); hounds[a] = nil
        elseif not h.dead and dead_of(h.z) then h.dead = true; stop(h)
        elseif clock - h.seen > FORGET then stop(h); hounds[a] = nil end
    end
    if not util.valid(cls) then return end
    local out = {}
    pcall(function() k:SphereOverlapActors(w, at, RANGE, OBJ_TYPES, cls, { p }, out) end)
    for _, o in ipairs(out) do
        local z = o
        pcall(function() local g = o:get(); if util.valid(g) then z = g end end)   -- (an array element wrapper)
        local a = util.valid(z) and util.addr(z)
        local l
        if a then pcall(function() l = util.vec(z:K2_GetActorLocation()) end) end
        if l then
            local h = hounds[a]
            if not h then h = { z = z, near_done = false, chase_until = -1, next_at = 0 }; hounds[a] = h end
            h.seen = clock
            local d = util.dist(at, l)
            local closing = h.d and (h.d - d) / dt or 0
            h.d = d
            if not h.dead then
                if not h.near_done and d <= NEAR then
                    h.near_done = true
                    if not playing(h) and play(h, math.random() < 0.5 and "bark1" or "bark2") then stats.near = stats.near + 1 end
                    h.next_at = clock + 1.0
                end
                if closing >= CLOSING or d <= ON_YOU then h.chase_until = clock + CHASE_HOLD end
                if clock < h.chase_until and clock >= h.next_at and not playing(h) then
                    if play(h, chase_kind()) then stats.chase = stats.chase + 1 end
                    h.next_at = clock + 0.3 + math.random() * 0.7   -- (after this one ends)
                end
            end
        end
    end
end

local function tick(dt)
    if cfg and cfg.dog_barks == false then return end
    clock = clock + dt
    poll_in = poll_in - dt
    if poll_in > 0 then return end
    poll(POLL - poll_in)
    poll_in = POLL
end

function dogs.status()
    return string.format("hounds: %d near bark(s), %d chase bark(s), %d stopped at death", stats.near, stats.chase, stats.stopped)
end

function dogs.init(c)
    cfg = c
    game.on_world_reset(function() hounds = {} end)
    game.on_tick(function(dt) util.safe(tick, "dogs.tick", dt) end)
end

return dogs
