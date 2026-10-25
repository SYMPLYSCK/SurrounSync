-- Rocks, trees and scrap metal: a node one player used up is used up for the other player too.
-- The player who lands the last hit (or finishes salvaging) gets the reward in their own game;
-- the other game only removes the node, so nothing is paid twice.
-- Rocks and trees are foliage instances until their first hit: the melee weapon (HitFoliageRock/Tree) then
-- spawns the harvestable actor at the instance and removes the instance. That happens in the hitting game
-- only, so the conversion is sent ("F key component"): the other game keeps its foliage, remembers the hits
-- left for when its own first hit converts it, and removes the foliage instance when the node is used up.

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
local MELEE = "/Game/Inventory/Items/Pickups/Weapons/Melee/BP_MeleePickup.BP_MeleePickup_C"

local cfg, role
local same_world = function() return false end
local channel = events.reliable("harvest")
local peers = require("mirror.peers")
local done = {}            -- key -> true: used up in this world (the host's list is sent to late joiners)
local comp_of = {}         -- key -> foliage component path (the node was a foliage instance before its first hit)
local left_of = {}         -- key -> hits left in the other game, for a node still foliage here
local converting = nil     -- { key, at }: our weapon is turning a foliage instance into a node right now
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

local function loc_of(key)
    local x, y, z = key:match("@(%-?%d+),(%-?%d+),(%-?%d+)$")
    if not x then return nil end
    return { X = tonumber(x) * 10, Y = tonumber(y) * 10, Z = tonumber(z) * 10 }
end

-- Every foliage component of the level (for a node whose "F" never arrived - e.g. lost while the link
-- reconnected): one FindAllOf, kept a minute.
local foliage_comps, foliage_at = nil, -100
local function all_foliage()
    if not foliage_comps or os.clock() - foliage_at > 60 then
        foliage_comps, foliage_at = {}, os.clock()
        pcall(function()
            for _, c in ipairs(FindAllOf("FoliageInstancedStaticMeshComponent") or {}) do
                if util.valid(c) then foliage_comps[#foliage_comps + 1] = c end
            end
        end)
    end
    return foliage_comps
end

-- The instance nearest to `at` in one component (the node actor stands exactly on its instance: the
-- game spawns it at the instance transform). Returns index, squared distance, unreadable count, candidates.
local function nearest_instance(comp, at)
    local idxs = {}
    -- (UE4SS returns a Lua table of params here, checked in-game)
    pcall(function()
        for _, e in ipairs(comp:GetInstancesOverlappingSphere(at, 100, true) or {}) do
            local i = type(e) == "number" and e or e:get()
            if type(i) == "number" then idxs[#idxs + 1] = i end
        end
    end)
    local best, best_d, unread = nil, 15 * 15, 0
    for _, i in ipairs(idxs) do
        local t = {}
        local ok = pcall(function() comp:GetInstanceTransform(i, t, true) end)
        local l = ok and t.Translation
        if type(l) == "table" and type(l.X) == "number" then
            local d = (l.X - at.X) ^ 2 + (l.Y - at.Y) ^ 2 + (l.Z - at.Z) ^ 2
            if d < best_d then best, best_d = i, d end
        else unread = unread + 1 end
    end
    -- transforms unreadable: only an unambiguous single candidate is removed
    if not best and unread == 1 and #idxs == 1 then best, best_d = idxs[1], 0 end
    return best, best_d, unread, #idxs
end

-- The foliage instance a node was made from (still there in a game that never hit it): remove it.
local function remove_instance(key)
    local at = loc_of(key)
    if not at then return false end
    local comps, why = nil, nil
    local cpath = comp_of[key]
    local named = cpath and StaticFindObject(cpath)
    if util.valid(named) then comps = { named }
    else comps, why = all_foliage(), cpath and ("its component " .. cpath .. " isn't here") or "no component was sent" end
    local best_c, best_i, best_d, seen, unread = nil, nil, math.huge, 0, 0
    for _, c in ipairs(comps) do
        local i, d, u, n = nearest_instance(c, at)
        seen, unread = seen + n, unread + u
        if i and d < best_d then best_c, best_i, best_d = c, i, d end
    end
    if not best_c then
        log.info(string.format("harvest: no foliage instance at %s to remove (%s; %d component(s), %d instance(s) within 1 m, %d unreadable)",
            key, why or "named component", #comps, seen, unread))
        return false
    end
    local ok = pcall(function() best_c:RemoveInstance(best_i) end)
    if why then log.info("harvest: removed " .. key .. " by searching the foliage (" .. why .. ")") end
    return ok
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
    channel:send(string.format("H %s %d %d %d", key, n, gone and 1 or 0, math.max(0, left)))
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

-- A node spawning here (BeginPlay -> SetMaxHits). Ours from a weapon hit on foliage: noted for the
-- HitFoliage hook that follows; hits the other game already landed on it count here too.
local function on_spawned(self)
    if applying then return end
    local o = util.obj(self)
    if not o then return end
    local cls = util.class_name(o)
    local ok, key = pcall(key_of, o, cls)
    if not ok then return end
    -- (a lookup that missed it a moment ago would keep missing it for 10 s)
    if index[cls] then index[cls].by_key[key] = o end
    converting = { key = key, at = os.clock() }
    local left = left_of[key]
    if left then
        left_of[key] = nil
        pcall(function() o.MaxHits = math.max(1, math.min(o.MaxHits, left)) end)
    end
end

local function on_converted(self, _, _, Component)
    local c = converting
    converting = nil
    if not c or os.clock() - c.at > 1.0 or not same_world() then return end
    local comp = util.obj(Component)
    local full
    pcall(function() full = comp:GetFullName() end)
    local cpath = type(full) == "string" and full:match("^%S+ (%S+)$")
    if not cpath then return end
    comp_of[c.key] = cpath
    channel:send("F " .. c.key .. " " .. cpath)
    stats.sent = stats.sent + 1
end

local function apply(payload)
    if payload:sub(1, 2) == "F " then
        local key, cpath = payload:match("^F (%S+) (%S+)$")
        if key then comp_of[key] = cpath end
        return
    end
    local kind, key, n, gone, left = payload:match("^(%a) (%S+)%s*(%d*)%s*(%d*)%s*(%d*)$")
    if not key then return end
    local cls = key:match("^([^@]+)@")
    local o = find(key)
    if kind == "S" or gone == "1" then mark_done(key) end
    if not o then
        -- still foliage here: used up -> its instance goes; else its own first hit starts from the hits left
        if gone == "1" then
            left_of[key] = nil
            if remove_instance(key) then stats.applied = stats.applied + 1; return end
        elseif tonumber(left) then left_of[key] = tonumber(left); stats.applied = stats.applied + 1; return end
        stats.missing = stats.missing + 1
        return
    end
    applying = true
    if kind == "S" or gone == "1" then
        remove(o, cls)
    else
        -- MaxHits is rolled per game (6-8): never let the other player's hits finish my copy.
        pcall(function()
            local m = o.MaxHits - (tonumber(n) or 1)
            if tonumber(left) then m = math.min(m, tonumber(left)) end
            o.MaxHits = math.max(1, m)
        end)
    end
    applying = false
    stats.applied = stats.applied + 1
end

-- Nodes the host's world already lost before I arrived.
local function apply_list(body)
    local n = 0
    for line in body:gmatch("[^\n]+") do
        local key, cpath = line:match("^(%S+) ?(%S*)$")
        if key and not done[key] then
            done[key] = true
            if cpath ~= "" then comp_of[key] = cpath end
            local o = find(key)
            if o then applying = true; remove(o, key:match("^([^@]+)@")); applying = false; n = n + 1
            elseif remove_instance(key) then n = n + 1 end
        end
    end
    if n > 0 then log.info("harvest: removed " .. n .. " node(s) the host's world had used up") end
end

function harvest.tick(dt)
    if not (cfg and cfg.harvest_sync) then return end
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 2.0
        for _, cls in ipairs(HIT) do
            util.ensure_hook(path(cls) .. ":HitHarvestableObject", on_hit)
            util.ensure_hook(path(cls) .. ":SetMaxHits", on_spawned)
        end
        util.ensure_hook(MELEE .. ":HitFoliageRock", on_converted)
        util.ensure_hook(MELEE .. ":HitFoliageTree", on_converted)
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
        for k in pairs(done) do keys[#keys + 1] = comp_of[k] and (k .. " " .. comp_of[k]) or k end
        link.put_blob("harvested", table.concat(keys, "\n"))
    end
    if role == "guest" and together and list_due and peer_body then
        list_due = false
        util.safe(apply_list, "harvest.list", peer_body)
    end
end

-- another guest's hit, already done to the host's node by that guest's copy: only note it and pass it on
function harvest.relay_in(p)
    local kind, key, rest = p:match("^(%a) (%S+)%s*(.*)$")
    if kind == "F" and key then comp_of[key] = rest
    elseif key and (kind == "S" or rest:match("^%d+ 1")) then mark_done(key) end
    channel:send(p)
end

function harvest.status()
    local d = 0
    for _ in pairs(done) do d = d + 1 end
    return string.format("harvest: used up %d, sent %d, applied %d, not found %d", d, stats.sent, stats.applied, stats.missing)
end

-- Respawn/reload: a new world has all its nodes back, and the old objects are freed.
local function forget_world()
    index, foliage_comps = {}, nil
    done, comp_of, left_of, converting = {}, {}, {}, nil
    if role == "host" then dirty = true else list_due = true end
end

function harvest.init(c, r, sw)
    cfg, role = c, r
    same_world = sw or same_world
    game.on_world_reset(forget_world)
end

return harvest
