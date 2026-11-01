-- The game's debug menu (items, skills, weather) in a co-op or Realm session (user 2026-10-30: "allow disable debug
-- menu for everyone, and announce when debug menu is active or disabled"). The host's DEBUG MENU rule: off, an opened
-- menu closes at once through the game's own CloseDebugMenu (what the menu's close button calls, decompiled); on,
-- the others are told who opened it. Every player is told when the host turns it on or off.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local events = require("mirror.events")
local notify = require("mirror.notify")
local link = require("mirror.link")
local hostrules = require("mirror.hostrules")

local debugmenu = {}

-- Construct runs each time the menu is put on screen (it switches the game to UI input and shows the mouse)
local FN = "/Game/UI/Widgets/Debug/DebugMenu.DebugMenu_C:Construct"
local TELL_EVERY = 30.0   -- s between "X opened the debug menu" notices from one player

local channel = events.new("debugmenu", 8, 20)
local opened, hook_in, told_at, rule_seen, src_seen = false, 0.0, -100.0, nil, nil
local now = 0.0

local function on_construct() opened = true end

local function allowed() return hostrules.get("debugmenu") end

function debugmenu.tick(dt)
    now = now + dt
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 2.0
        util.ensure_hook(FN, on_construct)
    end
    -- the host turned it on or off: everyone hears it (the host from its own toggle, a guest from the host's rules).
    -- Only a change from the same source is a switch: joining, leaving, or a guest's defaults giving way to the
    -- host's rules on arrival is not (a guest joining a host with the rule off heard "turned OFF" otherwise).
    local rule, src = allowed(), hostrules.source()
    if src ~= nil and src == src_seen and rule ~= rule_seen then
        notify.show(rule and "The host turned the debug menu ON for everyone." or "The host turned the debug menu OFF for everyone.", "info")
        log.info("debugmenu: the host's rule is now " .. (rule and "on" or "off"))
    end
    rule_seen, src_seen = rule, src
    if opened then
        opened = false
        if not rule then
            local ok = pcall(function() game.player():CloseDebugMenu() end)
            notify.show("The host has switched the debug menu off.", "info")
            log.info("debugmenu: opened while the host's rule is off - closed (" .. tostring(ok) .. ")")
        elseif now - told_at >= TELL_EVERY then
            told_at = now
            channel:send("open")
            log.info("debugmenu: opened - telling the other players")
        end
    end
    channel:pump(function(p)
        if p == "open" then notify.show(link.peer_name() .. " opened the debug menu.", "info") end
    end)
end

function debugmenu.init() game.on_world_reset(function() opened = false end) end

return debugmenu
