-- Rocks, trees and scrap metal: a node one player used up is used up for the other player too.
-- The player who lands the last hit (or finishes salvaging) gets the reward in their own game;
-- the other game only removes the node, so nothing is paid twice.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local link = require("mirror.link")
local events = require("mirror.events")

local harvest = {}

local DIR = "/Game/Blueprints/Other/HarvestableObjects/"
-- Rocks and trees lose MaxHits per hit and destroy themselves at 0; scrap metal sets Salvaged?.
local HIT = { "BP_HarvestableObject_Rocks_C", "BP_HarvestableObject_Tree_C" }
local SCRAP = "BP_HarvestableObject_ScrapMetal_C"
local function path(cls) local n = cls:gsub("_C$", ""); return DIR .. n .. "." .. cls end

local cfg, role
local same_world = function() return false end
local channel = events.reliable("harvest")
local peers = require("mirror.peers")
local done = {}            -- key -> true: used up in this world (the host's list is sent to late joiners)
local index = {}           -- cls -> { at, by_key }
local applying = false
local dirty, peer_body, list_due = false, nil, false
local hook_in = 0.0
local stats = { sent = 0, applied = 0, missing = 0 }

local function key_of(obj, cls)
    local l = obj:K2_GetActorLocation()
    return string.format("%s@%d,%d,%d", cls, math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5), math.floor(l.Z / 10 + 0.5))
end

-- One FindAllOf per class, then lookups by key; a miss rebuilds at most every 10 s.
local function find(key)
    local cls = key:match("^([^@]+)@")
    if not cls then return nil end
    local ix = index[cls]
    local o = ix and ix.by_key[key]
    if util.valid(o) then return o end
    if ix and os.clock() - ix.at < 10.0 then return nil end
    ix = { at = os.clock(), by_key = {} }
    index[cls] = ix
    pcall(function()
        for _, a in ipairs(FindAllOf(cls) or {}) do
            if util.valid(a) then
                local ok, k = pcall(key_of, a, cls)
                if ok then ix.by_key[k] = a end
            end
        end
    end)
    o = ix.by_key[key]
    return util.valid(o) and o or nil
end

local function mark_done(key)
    if done[key] then return end
    done[key] = true
    if role == "host" then dirty = true end
end

local function remove(o, cls)
    if cls == SCRAP then
        pcall(function() o["Salvaged?"] = true end)
        pcall(function() o.ParticleSystem:SetActive(false, false) end)
    else
        pcall(function() o:K2_DestroyActor() end)
    end
end

-- My hit / my salvage: tell the other game.
local function on_hit(self, _, Hits)
    if applying or not same_world() then return end
    local o = util.obj(self)
    if not o then return end
    local cls = util.class_name(o)
    local n, left = 1, 1
    pcall(function() n = Hits:get() end)
    pcall(function() left = o.MaxHits end)
    if type(n) ~= "number" or type(left) ~= "number" then return end
    local ok, key = pcall(key_of, o, cls)
    if not ok then return end
    local gone = left <= 0
    if gone then mark_done(key) end
    channel:send(string.format("H %s %d %d", key, n, gone and 1 or 0))
    stats.sent = stats.sent + 1
end

local function on_salvage(self)
    if applying or not same_world() then return end
    local o = util.obj(self)
    if not o then return end
    local salvaged = false
    pcall(function() salvaged = o["Salvaged?"] == true end)
    if not salvaged then return end
    local ok, key = pcall(key_of, o, SCRAP)
    if not ok or done[key] then return end
    mark_done(key)
    channel:send("S " .. key)
    stats.sent = stats.sent + 1
end

local function apply(payload)
    local kind, key, n, gone = payload:match("^(%a) (%S+)%s*(%d*)%s*(%d*)$")
    if not key then return end
    local cls = key:match("^([^@]+)@")
    local o = find(key)
    if kind == "S" or gone == "1" then mark_done(key) end
    if not o then stats.missing = stats.missing + 1; return end
    applying = true
    if kind == "S" or gone == "1" then
        remove(o, cls)
    else
        -- MaxHits is rolled per game (6-8): never let the other player's hits finish my copy.
        pcall(function() o.MaxHits = math.max(1, o.MaxHits - (tonumber(n) or 1)) end)
    end
    applying = false
    stats.applied = stats.applied + 1
end

-- Nodes the host's world already lost before I arrived.
local function apply_list(body)
    local n = 0
    for key in body:gmatch("[^\n]+") do
        if not done[key] then
            done[key] = true
            local o = find(key)
            if o then applying = true; remove(o, key:match("^([^@]+)@")); applying = false; n = n + 1 end
        end
    end
    if n > 0 then log.info("harvest: removed " .. n .. " node(s) the host's world had used up") end
end

function harvest.tick(dt)
    if not (cfg and cfg.harvest_sync) then return end
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 2.0
        for _, cls in ipairs(HIT) do util.ensure_hook(path(cls) .. ":HitHarvestableObject", on_hit) end
        util.ensure_hook(path(SCRAP) .. ":Event_HoldTimer", on_salvage)
    end
    local together = same_world()
    if role == "guest" then
        local body = link.get_blob("harvested")
        if body then peer_body, list_due = body, true end
    end
    channel:pump(function(p)
        if not together then return end
        util.safe(apply, "harvest.apply", p)
        -- host, more than two players: the other guests' copies note it (used-up list) and pass it on
        peers.relay("mirror.harvest", harvest, function(m) m.relay_in(p) end)
    end)
    if role == "host" and dirty then
        dirty = false
        local keys = {}
        for k in pairs(done) do keys[#keys + 1] = k end
        link.put_blob("harvested", table.concat(keys, "\n"))
    end
    if role == "guest" and together and list_due and peer_body then
        list_due = false
        util.safe(apply_list, "harvest.list", peer_body)
    end
end

-- another guest's hit, already done to the host's node by that guest's copy: only note it and pass it on
function harvest.relay_in(p)
    local kind, key, _, gone = p:match("^(%a) (%S+)%s*(%d*)%s*(%d*)$")
    if key and (kind == "S" or gone == "1") then mark_done(key) end
    channel:send(p)
end

function harvest.status()
    local d = 0
    for _ in pairs(done) do d = d + 1 end
    return string.format("harvest: used up %d, sent %d, applied %d, not found %d", d, stats.sent, stats.applied, stats.missing)
end

-- Respawn/reload: a new world has all its nodes back, and the old objects are freed.
local function forget_world()
    index = {}
    done = {}
    if role == "host" then dirty = true else list_due = true end
end

function harvest.init(c, r, sw)
    cfg, role = c, r
    same_world = sw or same_world
    game.on_world_reset(forget_world)
end

return harvest
