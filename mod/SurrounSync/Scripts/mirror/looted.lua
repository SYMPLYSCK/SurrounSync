-- Searched loot containers looted for everyone (user 2026-11-01: "making containers looted for all after 1 loots them
-- and shows them looted for others"). A loot container's ContainerLooted (decompiled BP_LootContainer,
-- BP_MASTER_PicklockContainer, BP_MASTER_ToolRequiredContainer) turns true when it is first opened (OpenContainer,
-- after the hold-to-search). While it is true the container opens at once (no search again, no tool for a tool
-- container), its magnifier goes (the game's DistanceOutline timer, every 0.5 s) and the interact prompt shows it
-- looted (ShowLootContainerWidget reads the flag). Only the game where the player searched ever set it.
-- Here: a container opened here whose flag is true within a few seconds (a tool container sets it after OpenContainer)
-- is sent by its id (class@place, as loot.lua: the same map piece in both games), and the other game sets the flag on
-- its copy. A lock-pick container's IsLocked? goes false with it: the game ties the two (at load IsLocked? = not
-- ContainerLooted), so the other player doesn't pick a lock already picked. The game saves the flag itself.
-- Contents are loot.lua's; this is only the searched state. More than two players: the host passes a guest's on to
-- the other guests (peers.relay). A refill (Difficulty.Refill: the game that opened it runs the container's
-- Bind_Refill when its timer ends, which clears ContainerLooted and puts the magnifier back - decompiled; nothing
-- re-locks) goes the same way as "R <id>": the other game runs Bind_Refill on its copy, so it is searchable there
-- too and its next search is sent again.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local events = require("mirror.events")
local peers = require("mirror.peers")

local looted = {}

local CLASSES = {
    "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C",
    "/Game/Inventory/Containers/ToolRequiredContainer/BP_MASTER_ToolRequiredContainer.BP_MASTER_ToolRequiredContainer_C",
    "/Game/Inventory/Containers/PicklockContainer/BP_MASTER_PicklockContainer.BP_MASTER_PicklockContainer_C",
}
local NEAR = 100          -- cm: the other game's copy of the container is at the same place (as loot.lua)
local WATCH_S = 3.0       -- s an opened container is watched for its flag
local RETRY_S = 15.0      -- s between tries for containers not loaded here yet (each try can walk a class: 30-40 ms)
local KEEP_S, KEEP_MAX = 600, 200

-- (reliable: a lost one leaves a searched container unsearched on the other screen for good)
local channel = events.reliable("looted", 64)
local role, session
local hook_in, retry_in, now = 0.0, 0.0, 0.0
local known = {}          -- id -> true: sent, or the other game's (never sent back)
local watch = {}          -- addr -> { a = actor, t = until }
local refills = {}        -- addr -> { a = actor, t = until }: Bind_Refill ran here, sent once the flag is clear
local applying = false    -- running Bind_Refill on the other game's say-so (its hook here is not a refill of mine)
local later = {}          -- id -> time it came (its container not found here yet)
local n_later = 0
local held = {}           -- payloads that came while I'm not in their world (loading in): applied once I am
local stats = { sent = 0, set = 0, later = 0, gave_up = 0, refills_sent = 0, refilled = 0 }

local function shared() return role == "host" or (session ~= nil and session.in_world()) end

local function id_of(a)
    local l = a:K2_GetActorLocation()
    return string.format("%s@%d,%d,%d", util.class_name(a), math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5),
        math.floor(l.Z / 10 + 0.5))
end

local function is_looted(a)
    local v
    pcall(function() v = a.ContainerLooted end)
    return v == true
end

local function on_open(self)
    local a
    pcall(function() a = self:get() end)
    local k = util.valid(a) and util.addr(a)
    if k then watch[k] = { a = a, t = now + WATCH_S } end
end
local open_fn = function(self) util.safe(on_open, "looted.open", self) end

local function on_refill(self)
    if applying then return end
    local a
    pcall(function() a = self:get() end)
    local k = util.valid(a) and util.addr(a)
    if k then refills[k] = { a = a, t = now + WATCH_S } end
end
local refill_fn = function(self) util.safe(on_refill, "looted.refill", self) end

local function tell(id)
    if known[id] then return end
    known[id] = true
    channel:send("S " .. id)
    stats.sent = stats.sent + 1
    log.debug("looted: searched " .. id .. " - sent")
end

-- the other game's searched container: ours searched too (false: not here yet)
local function set_on(id)
    local a = util.find_by_id(id, NEAR)
    if not util.valid(a) then return false end
    if is_looted(a) then return true end
    local ok = pcall(function() a.ContainerLooted = true end)
    pcall(function() if a["IsLocked?"] == true then a["IsLocked?"] = false end end)
    stats.set = stats.set + 1
    log.info("looted: " .. id .. " searched by the other player - searched here" .. (ok and "" or " - FAILED"))
    return true
end

local function keep(id)
    if later[id] then return end
    if n_later >= KEEP_MAX then
        log.every("looted.full", 30, "looted: too many searched containers not loaded here - dropped " .. id)
        return
    end
    later[id], n_later = now, n_later + 1
    stats.later = stats.later + 1
end

-- the other game's container refilled: ours searchable again, by the game's own Bind_Refill (it keeps a storage
-- container as it is, like there); one not loaded here keeps the state its save gives it
local function refill_on(id)
    if later[id] then later[id], n_later = nil, n_later - 1 end
    local a = util.find_by_id(id, NEAR)
    if not util.valid(a) or not is_looted(a) then return end
    applying = true
    local ok = pcall(function() a:Bind_Refill() end)
    applying = false
    if not ok then pcall(function() a.ContainerLooted = false end) end
    stats.refilled = stats.refilled + 1
    log.info("looted: " .. id .. " refilled on the other player's game - searchable here" .. (ok and "" or " (flag only)"))
end

local function apply(p)
    local kind, id = p:match("^([SR]) (%S+)$")
    if not id then return end
    if kind == "R" then
        known[id] = nil
        refill_on(id)
    else
        known[id] = true
        if not set_on(id) then keep(id) end
    end
    -- (the host set it with a plain write no hook sees: the other guests hear it from here)
    peers.relay("mirror.looted", looted, function(m) m.relay_send(p) end)
end

function looted.relay_send(p)
    local kind, id = p:match("^([SR]) (%S+)$")
    if not id then return end
    if kind == "R" then known[id] = nil; channel:send(p); return end
    if known[id] then return end
    known[id] = true
    channel:send(p)
end

local function retry()
    for id, t in pairs(later) do
        if set_on(id) then
            later[id], n_later = nil, n_later - 1
        elseif now - t > KEEP_S then
            later[id], n_later = nil, n_later - 1
            stats.gave_up = stats.gave_up + 1
            log.info("looted: " .. id .. " never showed up here in " .. KEEP_S .. " s - dropped")
        end
    end
end

function looted.tick(dt)
    now = now + dt
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 2.0
        for _, c in ipairs(CLASSES) do
            util.ensure_hook(c .. ":OpenContainer", open_fn)
            util.ensure_hook(c .. ":Bind_Refill", refill_fn)
        end
    end
    local on = shared()
    for k, w in pairs(refills) do
        if not util.valid(w.a) then
            refills[k] = nil
        elseif not is_looted(w.a) then
            refills[k] = nil
            local ok, id = pcall(id_of, w.a)
            if ok and id then
                known[id] = nil
                if on then
                    channel:send("R " .. id)
                    stats.refills_sent = stats.refills_sent + 1
                    log.debug("looted: refilled " .. id .. " - sent")
                end
            end
        elseif now > w.t then
            refills[k] = nil
        end
    end
    for k, w in pairs(watch) do
        if not util.valid(w.a) then
            watch[k] = nil
        elseif is_looted(w.a) then
            watch[k] = nil
            if on then
                local ok, id = pcall(id_of, w.a)
                if ok and id then tell(id) end
            end
        elseif now > w.t then
            watch[k] = nil
        end
    end
    -- (the channel is pumped either way: it also sends mine. What comes meanwhile waits; it used to be dropped, and
    -- the host's searches while I loaded in stayed unsearched here for good)
    if on and #held > 0 then
        local q = held
        held = {}
        for _, p in ipairs(q) do util.safe(apply, "looted.apply", p) end
    end
    channel:pump(function(p)
        if on then util.safe(apply, "looted.apply", p) elseif #held < KEEP_MAX then held[#held + 1] = p end
    end)
    if n_later > 0 then
        retry_in = retry_in - dt
        if retry_in <= 0 then retry_in = RETRY_S; retry() end
    end
end

function looted.status()
    return string.format("looted: sent %d, set %d%s", stats.sent, stats.set,
        n_later > 0 and (", waiting " .. n_later) or "")
end

-- a world load: the old world's containers are gone, and its ids name places in a world that isn't loaded any more
function looted.forget()
    known, watch, refills, later, n_later = {}, {}, {}, {}, 0
end

function looted.init(c, r, s)
    role, session = r, s
    -- (a new session or another player on this link: peers.lua reuses the link's copy and runs init again. What the
    -- last player's game was told stayed "known", and the new one never heard of containers searched before it came;
    -- audit 2026-11-03)
    looted.forget()
    held = {}
    if c and c.looted_sync == false then role, session = "off", nil end
    game.on_world_reset(looted.forget)
    log.info("looted: " .. (role == "off" and "off" or "ready"))
end

looted._test = { known = function() return known end, later = function() return later end,
    held = function() return held end }

return looted
