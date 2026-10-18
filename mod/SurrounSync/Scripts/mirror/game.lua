-- Finds the local player, controller and world, and hands out per-frame ticks and hooks.

local log = require("mirror.log")
local util = require("mirror.util")
local ghost = require("mirror.ghost")

local game = {}

local P = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
game.PLAYER_CLASS = P

local controller, player, world = nil, nil, nil
local tick_handlers, ready_handlers = {}, {}
local pending_hooks = {}
local installed, ready_done = false, false

function game.player() return player end
function game.world() return world end
function game.controller() return controller end

local tick_slot, ready_slot = {}, {}
function game.on_tick(fn)
    local site = util.callsite(2)
    local i = site and tick_slot[site]
    if i then tick_handlers[i] = fn; return end
    tick_handlers[#tick_handlers + 1] = fn
    if site then tick_slot[site] = #tick_handlers end
end
function game.on_ready(fn)
    local site = util.callsite(2)
    local i = site and ready_slot[site]
    if i then ready_handlers[i] = fn
    else
        ready_handlers[#ready_handlers + 1] = fn
        if site then ready_slot[site] = #ready_handlers end
    end
    if ready_done then util.safe(fn, "game.on_ready") end
end
local phook_slot = {}
function game.player_hook(fn_name, cb)
    local site = util.callsite(2)
    local key = site and (fn_name .. "@" .. site)
    local slot = key and phook_slot[key]
    if slot then slot.cb = cb; return end
    slot = { cb = cb }
    if key then phook_slot[key] = slot end
    local tramp = function(...) return slot.cb(...) end
    pending_hooks[#pending_hooks + 1] = { fn = fn_name, cb = tramp }
    if installed then util.hook(P .. ":" .. fn_name, tramp, nil, true) end
end

local new_player_handlers, new_player_slot = {}, {}
function game.on_new_player(fn)
    local site = util.callsite(2)
    local i = site and new_player_slot[site]
    if i then new_player_handlers[i] = fn; return end
    new_player_handlers[#new_player_handlers + 1] = fn
    if site then new_player_slot[site] = #new_player_handlers end
end

local function adopt(pawn, pc)
    local old = player
    player, controller, world = pawn, pc, nil
    pcall(function() world = player:GetWorld() end)
    util.recheck_hooks()
    log.info((old and "new real player (respawn/reload): " or "real player is ") .. player:GetFullName())
    for _, fn in ipairs(new_player_handlers) do util.safe(fn, "game.on_new_player") end
end

local function refresh_player(ctx)
    if util.same(ctx, player) then return true end
    local pc
    pcall(function() pc = ctx.Controller end)
    if util.valid(pc) and util.class_name(pc) == "BP_PlayerController_C" then adopt(ctx, pc); return true end
    if util.valid(player) then return true end
    player, world = nil, nil
    pc = FindFirstOf("BP_PlayerController_C")
    local pawn
    pcall(function() pawn = pc.Pawn end)
    if util.valid(pawn) and not ghost.is(pawn) then adopt(pawn, pc); return true end
    return false
end

local pending_keys = {}
local focus_works = false
local probe_in = 0.0
local PROBE_KEYS = { "W", "A", "S", "D", "LeftMouseButton", "RightMouseButton", "SpaceBar", "LeftShift" }

local function key_down(name)
    local r
    local ok = pcall(function() r = controller:IsInputKeyDown({ KeyName = FName(name) }) end)
    if not ok then return nil end
    return r == true
end

local function key_seen(name)
    local d = key_down(name)
    if d ~= false then return d end
    local r = false
    pcall(function()
        local k = { KeyName = FName(name) }
        r = controller:WasInputKeyJustPressed(k) == true or controller:WasInputKeyJustReleased(k) == true
    end)
    return r
end

local key_slot = {}
-- UE4SS key binds fire in every game running on the PC, so check the key is down in ours.
function game.keybind(name, mods, fn, always)
    local site = util.callsite(2)
    local ks = site and (name .. "@" .. site)
    if ks and key_slot[ks] then key_slot[ks].fn, key_slot[ks].always = fn, always; return end
    local slot = { fn = fn, always = always }
    if ks then key_slot[ks] = slot end
    fn = function() return slot.fn() end
    always = always and function() return slot.always and slot.always() end or nil
    local key = Key[name:upper()] or Key[name]
    if not key then log.warn("game.keybind: unknown key " .. name); return end
    local fkey = ({ ESCAPE = "Escape", ONE = "One", TWO = "Two", THREE = "Three" })[name:upper()] or name
    local cb = function() pending_keys[#pending_keys + 1] = { name = fkey, fn = fn, at = os.clock(), always = always } end
    if mods then RegisterKeyBind(key, mods, cb) else RegisterKeyBind(key, cb) end
end

local function process_keys(dt)
    if not focus_works then
        probe_in = probe_in - dt
        if probe_in <= 0 then
            probe_in = 0.5
            for _, k in ipairs(PROBE_KEYS) do
                if key_down(k) then
                    focus_works = true
                    log.info("game: this window's own key input is readable - hotkeys now only act in the focused game")
                    break
                end
            end
        end
    end
    if #pending_keys == 0 then return end
    local keep, t = {}, os.clock()
    for _, k in ipairs(pending_keys) do
        local down = key_seen(k.name)
        if t - k.at > 2.0 then
            log.info("game: ignored a " .. k.name .. " press from " .. string.format("%.0f", t - k.at) .. " s ago")
        elseif not focus_works or down == nil or down or (k.always and k.always()) then
            util.safe(k.fn, "game.key " .. k.name)
        elseif t - k.at < 0.3 then
            keep[#keep + 1] = k
        end
    end
    pending_keys = keep
end

local last_clock, slow_t, slow_logged = nil, 0.0, nil
local function real_dt(game_dt)
    local c = os.clock()
    local dt = last_clock and math.min(math.max(c - last_clock, 0.0), 0.25) or game_dt
    last_clock = c
    local ratio = dt > 0.001 and game_dt / dt or 1.0
    if ratio < 0.5 or ratio > 2.0 then slow_t = slow_t + dt else slow_t = 0.0 end
    local slow = slow_t > 2.0
    if slow ~= (slow_logged or false) and (slow or slow_logged ~= nil) then
        slow_logged = slow
        log.info(slow and string.format("game: the player's game time runs at %.2fx real time", ratio)
            or "game: the player's game time is back to real time")
    end
    return dt
end

local function on_tick(self, DeltaSeconds)
    local ctx = self:get()
    if ghost.is(ctx) then return end
    if not refresh_player(ctx) then return end
    if not util.same(ctx, player) then return end
    local dt = real_dt(DeltaSeconds:get() or 0)
    util.new_frame()
    if not ready_done then
        ready_done = true
        for _, fn in ipairs(ready_handlers) do util.safe(fn, "game.on_ready") end
    end
    util.safe(process_keys, "game.keys", dt)
    for i = 1, #tick_handlers do util.safe(tick_handlers[i], "game.on_tick", dt) end
end

local function install()
    if installed then return end
    installed = true
    util.hook(P .. ":ReceiveTick", function(self, DeltaSeconds) util.safe(on_tick, "game.tick", self, DeltaSeconds) end)
    for _, h in ipairs(pending_hooks) do util.hook(P .. ":" .. h.fn, h.cb, nil, true) end
end

function game.init()
    if util.valid(StaticFindObject(P)) then install() end
    NotifyOnNewObject(P, function() util.safe(install, "game.install") end)
end

return game
