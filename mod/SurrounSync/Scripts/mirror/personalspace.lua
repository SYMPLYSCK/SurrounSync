-- Zombies walk into the player in the game itself: BP_MasterZombie's capsule ignores the Pawn channel (so a horde
-- doesn't jam on itself) and is only 15 cm wide (the player's is 30), so a zombie stands inside you and is hard to
-- shoot. Zombies within NEAR of a player block pawns and get a fuller capsule: they stop at arm's length and crowd
-- around you. Past FAR they are as the game made them again. Single player, host, and a guest running its own AI
-- (load split); otherwise a guest's zombies are the host's copies, and the host keeps its zombies off its ghost of
-- the guest (the ghost's capsule blocks pawns).

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")

local personalspace = {}

local MASTER = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"
local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local NEAR, FAR, POLL = 300, 450, 0.2      -- cm, cm, s
local RADIUS = 28                          -- cm: a zombie's shoulders (game: 15)
local ECC_PAWN, ECR_BLOCK = 2, 2
local OBJ_PAWN = 2                         -- EObjectTypeQuery: ObjectTypeQuery3 = Pawn
local MAX_HELD = 48

local held = {}                            -- address -> { z, resp, radius }
local poll_in, broken, stats = 0.0, false, { held = 0, most = 0 }
local cfg

local function role()
    local ok, p1 = pcall(require, "mirror.phase1")
    return ok and p1.started and p1.started() or nil
end

-- the local player, and on a host every ghost of a guest
local function bodies()
    local out = {}
    local p = game.player()
    if util.valid(p) then out[#out + 1] = p end
    if role() == "host" then
        local ok, peers = pcall(require, "mirror.peers")
        if ok and peers.each then
            peers.each("mirror.ghost", function(m) local g = m.get and m.get(); if util.valid(g) then out[#out + 1] = g end end)
        end
    end
    return out
end

local function loc_of(a)
    local l
    pcall(function() l = util.vec(a:K2_GetActorLocation()) end)
    return l
end

local function release(a, h)
    held[a] = nil
    if not util.valid(h.z) or util.addr(h.z) ~= a then return end
    pcall(function()
        local cap = h.z.CapsuleComponent
        cap:SetCollisionResponseToChannel(ECC_PAWN, h.resp)
        if h.radius then cap:SetCapsuleRadius(h.radius, true) end
    end)
end

local function hold(z)
    local a = util.addr(z)
    if not a or held[a] then return end
    local n = 0
    for _ in pairs(held) do n = n + 1 end
    if n >= MAX_HELD then return end
    local cap
    pcall(function() cap = z.CapsuleComponent end)
    if not util.valid(cap) then return end
    local resp, radius = 0, nil
    pcall(function() resp = cap:GetCollisionResponseToChannel(ECC_PAWN) end)
    if resp == ECR_BLOCK then return end            -- (blocks pawns already: not ours to change)
    pcall(function() radius = cap:GetUnscaledCapsuleRadius() end)
    local ok = pcall(function()
        cap:SetCollisionResponseToChannel(ECC_PAWN, ECR_BLOCK)
        if radius and radius < RADIUS then cap:SetCapsuleRadius(RADIUS, true) end
    end)
    if ok then
        held[a] = { z = z, resp = resp, radius = (radius and radius < RADIUS) and radius or nil }
        stats.held = stats.held + 1
        if n + 1 > stats.most then stats.most = n + 1 end
    end
end

local function near_zombies(k, w, cls, body, at)
    local out = {}
    local ok, err = pcall(function() k:SphereOverlapActors(w, at, NEAR, { OBJ_PAWN }, cls, { body }, out) end)
    if not ok then
        broken = true
        log.warn("personalspace: the overlap query failed (" .. tostring(err) .. ") - zombies keep the game's collision")
        return {}
    end
    return out
end

-- a guest's zombies are the host's copies - except while a load split (or a Realm takeover) has made them its own
local function copies_here()
    if role() ~= "guest" then return false end
    local ok, z = pcall(require, "mirror.zombies")
    return not (ok and z.is_split and z.is_split())
end

local function poll()
    local list = bodies()
    if copies_here() or #list == 0 then
        for a, h in pairs(held) do release(a, h) end
        return
    end
    local k, w, cls = util.cdo(KSL), game.world(), util.find(MASTER)
    if not (k and w and cls) then return end
    local at = {}   -- (only the bodies whose spot was read: a gap would end ipairs early and let close zombies go)
    for _, b in ipairs(list) do
        local l = loc_of(b)
        if l then
            at[#at + 1] = l
            for _, z in ipairs(near_zombies(k, w, cls, b, l)) do
                local o = z
                if not util.valid(o) then pcall(function() o = z:get() end) end   -- (an array element wrapper)
                if util.valid(o) then hold(o) end
            end
            if broken then return end
        end
    end
    for a, h in pairs(held) do
        local l = util.valid(h.z) and util.addr(h.z) == a and loc_of(h.z)
        local close = false
        if l then
            for _, p in ipairs(at) do
                if util.dist(p, l) <= FAR then close = true; break end
            end
        end
        if not close then release(a, h) end
    end
end

local function tick(dt)
    if broken or (cfg and cfg.zombie_personal_space == false) then return end
    poll_in = poll_in - dt
    if poll_in > 0 then return end
    poll_in = POLL
    poll()
end

function personalspace.status()
    local n = 0
    for _ in pairs(held) do n = n + 1 end
    return string.format("personal space: %d zombie(s) kept at arm's length now, %d so far, most at once %d%s", n, stats.held,
        stats.most, broken and " (OFF: overlap query failed)" or "")
end

function personalspace.init(c)
    cfg = c
    -- (an ended zombie's address can be reused: forget it untouched)
    util.on_end(function(a) held[a] = nil end)
    game.on_world_reset(function() held = {} end)
    game.on_tick(function(dt) util.safe(tick, "personalspace.tick", dt) end)
end

return personalspace
