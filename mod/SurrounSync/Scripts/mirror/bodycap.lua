-- Body limit (a host rule, off by default): "many bodies drop FPS". Once more dead zombies and raiders lie in the
-- world than the limit, the oldest bodies are removed first. Never touched: a body near any player (so one being
-- looted - the other player's ghost counts too), traders, bosses and animals (not in the lists below), death
-- bags and player bodies (other classes). The host decides: it removes the bodies and tells every guest which
-- ones (corpses.body_gone, "X <id>"), so both games lose the same ones. A guest follows the host and removes none
-- itself; outside co-op the player's own setting applies to their own world.
-- One copy of the state for every co-op instance (peers.lua loads this file once per player): all of it in S.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local hostrules = require("mirror.hostrules")

local bodycap = {}

local CLASSES = {
    { "BP_MasterZombie_C", "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C" },
    { "BP_MasterBandit_C", "/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C" },
    { "BP_MasterCoyoteSoldier_C", "/Game/AI/Humans/CoyoteSoldiers/BP_MasterCoyoteSoldier.BP_MasterCoyoteSoldier_C" },
    { "BP_MasterScavenger_C", "/Game/AI/Humans/Scavengers/BP_MasterScavenger.BP_MasterScavenger_C" },
}
local SCAN_EVERY = 5.0
local NEAR = 1500            -- cm: 15 m
local PER_TICK = 2           -- removals per tick (each may wait for the animation gate)

local S = require("mirror.peers").shared("bodycap", {
    clock = 0.0, scan_in = 5.0, n = 0,
    seen = {},               -- address -> { at = clock when first seen dead, n = order, cls }
    queue = {},              -- bodies to remove, oldest first
    removed = 0, bodies = 0,
    role_fn = function() return nil end,
})

local function active()
    return S.role_fn() ~= "guest" and hostrules.mine("bodycap")
end

local function limit_now() return tonumber(hostrules.my_value("bodycap")) end

-- where a body lies (a ragdoll's actor can sit at 0,0,0: its mesh is where it fell)
local function body_pos(z)
    local l
    pcall(function() l = util.vec(z:K2_GetActorLocation()) end)
    if l and math.abs(l.X) < 1 and math.abs(l.Y) < 1 and math.abs(l.Z) < 1 then
        l = nil
        pcall(function() l = util.vec(z.Mesh:K2_GetComponentLocation()) end)
    end
    return l
end

-- me and every other player's ghost (peers.lua: all of them with more than two players)
local function player_spots()
    local who = require("mirror.peers").ghost_list()
    who[#who + 1] = game.player()
    local out = {}
    for _, p in ipairs(who) do
        local l
        if util.valid(p) then pcall(function() l = util.vec(p:K2_GetActorLocation()) end) end
        if l then out[#out + 1] = l end
    end
    return out
end

-- near a player, or nowhere to be read (left alone then)
local function near_player(z, spots)
    local l = body_pos(z)
    if not l then return true end
    for _, p in ipairs(spots) do if util.dist(p, l) < NEAR then return true end end
    return false
end

local function lying(z)
    if not util.valid(z) then return false end
    local ok = true
    pcall(function() if z.bHidden == true or z:IsActorBeingDestroyed() then ok = false end end)
    return ok
end

local function counts(z, zombies)
    local fam = zombies.family_of(z)
    return (fam == "zombie" or fam == "human") and not zombies.is_trader(z) and not zombies.is_copy(z)
        and zombies.dead_of(z) == true
end

local function scan()
    local zombies = require("mirror.zombies")
    local bodies, live = {}, {}
    for _, c in ipairs(CLASSES) do
        for _, z in ipairs(util.instances(c[1], c[2])) do
            local a = lying(z) and util.addr(z)
            if a and not live[a] and counts(z, zombies) then
                live[a] = true
                local cls = util.class_name(z)
                local e = S.seen[a]
                if not e or e.cls ~= cls then   -- (a freed one's address can come back as another body)
                    S.n = S.n + 1
                    e = { at = S.clock, n = S.n, cls = cls }
                    S.seen[a] = e
                end
                bodies[#bodies + 1] = { z = z, at = e.at, n = e.n }
            end
        end
    end
    for a in pairs(S.seen) do if not live[a] then S.seen[a] = nil end end
    S.bodies = #bodies
    S.queue = {}
    local limit = limit_now()
    if not limit or #bodies <= limit then return end
    table.sort(bodies, function(x, y) if x.at ~= y.at then return x.at < y.at end return x.n < y.n end)
    local spots, extra = player_spots(), #bodies - limit
    for _, b in ipairs(bodies) do
        if extra <= 0 then break end
        if not near_player(b.z, spots) then
            S.queue[#S.queue + 1] = b.z
            extra = extra - 1
        end
    end
    if #S.queue > 0 then
        log.info(string.format("bodycap: %d bodies lie around (limit %d) - removing the %d oldest", #bodies, limit, #S.queue))
    end
end

-- what a raider holds in its hands is its own actor: it goes with it (zombies.lua does the same for its copies)
local function destroy_holdables(z, zombies)
    local ai = zombies.smart_ai(z)
    if not ai then return end
    local held = {}
    pcall(function() held[#held + 1] = ai["Holdable Actor"] end)
    pcall(function()
        local list = ai["Attached Holdables"]
        for i = 1, list:GetArrayNum() do held[#held + 1] = list[i]["Holdable_6_3FE52CBF435F83B34B5404918416EFB4"] end
    end)
    for _, h in ipairs(held) do
        if util.valid(h) then require("mirror.animgate").destroy(h, "bodycap.holdable") end
    end
end

local function remove(z)
    local zombies = require("mirror.zombies")
    local ctl
    pcall(function() ctl = z.Controller end)
    -- the guests first (the body's id is read from the body itself), then the body goes
    require("mirror.peers").each("mirror.corpses", function(m)
        if m.body_gone then util.safe(m.body_gone, "bodycap.tell", z) end
    end)
    util.safe(destroy_holdables, "bodycap.holdables", z, zombies)
    require("mirror.animgate").destroy(z, "bodycap")
    if util.valid(ctl) then pcall(function() ctl:K2_DestroyActor() end) end
    S.removed = S.removed + 1
end

-- a few per tick; each is checked again as it goes (it may have been looted or left behind since the scan)
local function drain()
    local zombies = require("mirror.zombies")
    local spots, done = nil, 0
    while done < PER_TICK and S.queue[1] do
        local z = table.remove(S.queue, 1)
        if lying(z) and counts(z, zombies) then
            spots = spots or player_spots()
            if not near_player(z, spots) then remove(z); done = done + 1 end
        end
    end
end

local function tick(dt)
    S.clock = S.clock + dt
    if S.queue[1] then
        if active() then drain() else S.queue = {} end
    end
    S.scan_in = S.scan_in - dt
    if S.scan_in > 0 then return end
    S.scan_in = SCAN_EVERY
    if not (active() and util.valid(game.player())) then S.seen, S.queue = {}, {}; return end
    util.job("bodycap.scan", util.safe, scan, "bodycap.scan")
end

-- Dev tests: a shorter scan interval (seconds).
function bodycap.dev_scan(every) SCAN_EVERY, S.scan_in = every or SCAN_EVERY, 0 end

-- (a guest sees the host's limit; the count of removals is the host's to give)
function bodycap.status()
    if S.role_fn() == "guest" then
        local v = hostrules.value("bodycap")
        return v and v ~= "off" and string.format("body limit %s (the host's)", v) or "body limit off"
    end
    if not active() then return "body limit off" end
    return string.format("body limit %s: %d removed", tostring(hostrules.my_value("bodycap")), S.removed)
end

local function forget_world() S.seen, S.queue, S.bodies = {}, {}, 0 end

-- role_getter: the co-op role ("host" / "guest" / nil outside co-op). Once only, whichever copy asks first.
function bodycap.init(role_getter)
    if S.inited then return end
    S.inited = true
    S.role_fn = role_getter or S.role_fn
    game.on_world_reset(forget_world)
    game.on_tick(function(dt) util.safe(tick, "bodycap.tick", dt) end)
end

return bodycap
