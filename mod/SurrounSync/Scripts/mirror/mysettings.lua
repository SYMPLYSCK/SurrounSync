-- Your own settings (CO-OP tab -> gear -> MY SETTINGS): saved on this PC, only change your own game.

local log = require("mirror.log")
local link = require("mirror.link")
local util = require("mirror.util")

local mysettings = {}

local FILE = "\\mirror_my_settings.txt"
local ONOFF = { { "off", "OFF" }, { "on", "ON" } }

-- key, label, hint (one line under the option), values ({ value, button text }; on/off when left out), default
mysettings.LIST = {
    { key = "nametags", label = "NAME TAGS", hint = "Names over the other players' heads.", default = "on" },
    { key = "messages", label = "CO-OP MESSAGES", hint = "Pop-ups from the mod. IMPORTANT = warnings and joins only.",
      values = { { "all", "ALL" }, { "important", "IMPORTANT" }, { "off", "OFF" } }, default = "all" },
    { key = "chat", label = "CHAT POP-UPS", hint = "Chat lines show on screen (they're always in the CO-OP tab).", default = "on" },
    { key = "sounds", label = "SHARED SOUNDS", hint = "Hear zombies and tools from the other players' games.", default = "on" },
    { key = "joinsound", label = "JOIN ALERT SOUND", hint = "A whistle when someone asks to join you.", default = "on" },
    { key = "autotp", label = "AUTO-ACCEPT TELEPORTS", hint = "Say yes to /goto and /bring without asking.", default = "off" },
    { key = "pings", label = "SHARE MAP PINGS", hint = "Your map pings and laptop scans show for the other players.", default = "on" },
    { key = "dmgnumbers", label = "DAMAGE NUMBERS", hint = "The numbers that pop up when you hit something.", default = "on" },
    { key = "perf", label = "GUEST PERFORMANCE", hint = "As a guest: zombies are copied to you within 150 / 100 / 60 m.",
      values = { { "full", "FULL" }, { "balanced", "BALANCED" }, { "low", "LOW" } }, default = "full" },
}
-- the zombie copy range each GUEST PERFORMANCE value asks the host for (share of config zombies.radius)
mysettings.PERF_SHARE = { full = 1.0, balanced = 100 / 150, low = 60 / 150 }

local by_key = {}
for _, o in ipairs(mysettings.LIST) do o.values = o.values or ONOFF; by_key[o.key] = o end

local mine = {}
local loaded = false
local sent_perf = nil
local role_fn = function() return nil end

local function valid(o, v)
    for _, x in ipairs(o.values) do if x[1] == v then return true end end
    return false
end

local function load()
    loaded = true
    for _, o in ipairs(mysettings.LIST) do mine[o.key] = o.default end
    local f = link.dir and io.open(link.dir() .. FILE, "rb")
    local s = f and f:read("*a") or ""
    if f then f:close() end
    for k, v in s:gmatch("(%w+)%s+(%w+)") do
        if by_key[k] and valid(by_key[k], v) then mine[k] = v end
    end
end

local function save()
    local f = link.dir and io.open(link.dir() .. FILE, "wb")
    if not f then return end
    for _, o in ipairs(mysettings.LIST) do f:write(o.key, " ", mine[o.key], "\n") end
    f:close()
end

function mysettings.value(key)
    if not loaded then load() end
    return mine[key]
end
function mysettings.on(key) local v = mysettings.value(key); return v ~= nil and v ~= "off" end

-- The settings page's button: the next value.
function mysettings.toggle(key)
    local o = by_key[key]
    if not o then return end
    if not loaded then load() end
    local n = 1
    for i, x in ipairs(o.values) do if x[1] == mine[key] then n = i % #o.values + 1 end end
    mine[key] = o.values[n][1]
    save()
    log.info("mysettings: " .. key .. " " .. mine[key])
end

-- SyncFX, the graphics mod: on top of MY SETTINGS when it's installed. Its switch is the mod itself (mods.txt,
-- through modlist), so it takes effect when the game starts next. Loaded, SyncFX itself starts switched off until
-- the player presses F8 (it remembers that).
mysettings.SYNCFX = "SyncFX"
mysettings.SYNCFX_ROW = { key = "syncfx", tag = "Optimizes Performance", tag_color = { R = 0.06, G = 0.30, B = 0.08, A = 1.0 },
    label = "SYNCFX GRAPHICS", hint = "F8 in game turns it on, F6 menu." }   -- one line on the page

local function syncfx_row()
    local ok, installed, on, pending = pcall(function() return require("mirror.modlist").state(mysettings.SYNCFX) end)
    if not ok or not installed then return nil end
    local r = mysettings.SYNCFX_ROW
    return { key = r.key, tag = r.tag, tag_color = r.tag_color, label = r.label, text = on and "ON" or "OFF",
             hint = pending and ((on and "On" or "Off") .. " from your next game start.") or r.hint }
end

function mysettings.rows()
    if not loaded then load() end
    local out = {}
    local fx = syncfx_row()
    if fx then out[1] = fx end
    for _, o in ipairs(mysettings.LIST) do
        local text = mine[o.key]
        for _, x in ipairs(o.values) do if x[1] == mine[o.key] then text = x[2] end end
        out[#out + 1] = { key = o.key, label = o.label, hint = o.hint, text = text }
    end
    return out
end

-- DAMAGE NUMBERS off: every number widget is hidden as it's built (all sources - guns, melee, turrets -
-- create it through GameFunctionLibrary SpawnDamageNumbers). Hidden, not removed: removing a widget while
-- it starts crashed the game once (main menu).
local DMG_UI = "/Game/UI/Widgets/Player/FloatingDamageNumbersUI.FloatingDamageNumbersUI_C:Construct"
local hook_in = 0.0
local function hide_number(self)
    if mysettings.on("dmgnumbers") then return end
    local w = util.obj(self)
    if w then pcall(function() w:SetVisibility(1) end) end
end

-- A guest tells the host how far out it wants zombie copies (GUEST PERFORMANCE).
function mysettings.tick(dt)
    hook_in = hook_in - (dt or 0.1)
    if hook_in <= 0 then
        hook_in = 2.0
        if not mysettings.on("dmgnumbers") then util.ensure_hook(DMG_UI, hide_number) end
    end
    if role_fn() == "guest" then
        local v = mysettings.value("perf")
        if v ~= sent_perf then sent_perf = v; link.put_blob("gperf", v) end
    else
        sent_perf = nil
    end
end

function mysettings.init(role_getter)
    role_fn = role_getter or role_fn
    load()
    local parts = {}
    for _, o in ipairs(mysettings.LIST) do parts[#parts + 1] = o.key .. " " .. mine[o.key] end
    log.info("mysettings: " .. table.concat(parts, " "))
end

return mysettings
