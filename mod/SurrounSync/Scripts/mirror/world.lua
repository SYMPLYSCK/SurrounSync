-- Time of day and weather follow the host.

local log = require("mirror.log")
local util = require("mirror.util")
local link = require("mirror.link")

local world = {}

local SEND_EVERY = 2.0
local TIME_SLACK = 8
local BLEND = 8.0
local RETRY = 15.0

local cfg, role, session
local peer_live = function() return true end
local tick_in = 0.0
local sky, weather
local host = nil
local want = nil
local matched = nil
local now = 0.0
local stats = { time_snaps = 0, weather_sets = 0, drifts = 0, missing = 0 }

local function str(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local s; pcall(function() s = v:ToString() end)
    return type(s) == "string" and s or nil
end

local function live(class)
    local found
    pcall(function()
        for _, o in ipairs(FindAllOf(class) or {}) do
            if util.valid(o) and not o:GetFullName():find("Default__", 1, true) then found = o; break end
        end
    end)
    return found
end

local function actors()
    if not util.valid(sky) then sky = live("Ultra_Dynamic_Sky_C") end
    if not util.valid(weather) then weather = live("Ultra_Dynamic_Weather_C") end
    return sky, weather
end

local function current_weather(w)
    local p, name, label
    pcall(function() p = w.Weather end)
    if not util.valid(p) then return nil end
    pcall(function() name = p:GetFName():ToString() end)
    pcall(function() label = str(p["User Friendly Name"]) end)
    return name, label
end

local function find_preset(name, label)
    local exact, by_label
    local ok, err = pcall(function()
        for _, o in ipairs(FindAllOf("UDS_Weather_Settings_C") or {}) do
            if util.valid(o) and not o:GetFullName():find("Default__", 1, true) then
                if o:GetFName():ToString() == name then exact = o; return end
                if not by_label and label ~= "" and str(o["User Friendly Name"]) == label then by_label = o end
            end
        end
    end)
    if not ok then log.debug("world: preset scan failed: " .. tostring(err)) end
    return exact or by_label
end

local function host_tick()
    local s, w = actors()
    if not s then return end
    local tod
    pcall(function() tod = s["Time of Day"] end)
    if type(tod) ~= "number" then return end
    local name, label = nil, nil
    if w then name, label = current_weather(w) end
    link.put_blob("sky", string.format("%.2f|%s|%s", tod, name or "", label or ""))
end

local function guest_tick()
    local msg = peer_live() and link.get_blob("sky") or nil
    if msg then
        local t, n, l = msg:match("^([^|]+)|([^|]*)|(.*)$")
        if t then host = { tod = tonumber(t), name = n, label = l } end
    end
    if not host or not session.in_world() then matched = nil; return end
    local s, w = actors()

    if s and host.tod then
        local mine
        pcall(function() mine = s["Time of Day"] end)
        if type(mine) == "number" then
            local d = (mine - host.tod + 1200) % 2400 - 1200
            if math.abs(d) > TIME_SLACK then
                local ok = pcall(function() s["Time of Day"] = host.tod end)
                stats.time_snaps = stats.time_snaps + 1
                log.info(string.format("world: clock %.0f -> host's %.0f (%s)", mine, host.tod, ok and "ok" or "write failed"))
            end
        end
    end

    if w and host.name ~= "" then
        local name = current_weather(w)
        if name == host.name then
            matched = host.name
        else
            if matched == host.name then
                stats.drifts = stats.drifts + 1
                matched, want = nil, nil
                log.info("world: weather drifted to " .. tostring(name) .. " (the guest's own random weather?) - back to the host's")
            end
            if not want or want.name ~= host.name or now - want.at > RETRY then
                want = { name = host.name, at = now }
                local preset = find_preset(host.name, host.label)
                if not preset then
                    stats.missing = stats.missing + 1
                    log.warn("world: host weather " .. host.name .. " (" .. host.label .. ") isn't loaded here - can't copy it")
                else
                    local ok, err = pcall(function() local f = w["Change Weather"]; f(w, preset, BLEND) end)
                    stats.weather_sets = stats.weather_sets + 1
                    log.info(string.format("world: weather %s -> host's %s (%s)%s", tostring(name), host.name, host.label,
                        ok and "" or (" FAILED: " .. tostring(err))))
                end
            end
        end
    end
end

function world.tick(dt)
    now = now + dt
    tick_in = tick_in - dt
    if tick_in > 0 then return end
    tick_in = SEND_EVERY
    if role == "host" then host_tick() elseif role == "guest" then guest_tick() end
end

function world.status()
    if role == "host" then return "sky: sending" end
    return string.format("sky: %s, clock snaps %d, weather sets %d, drifts %d%s", matched and "matched" or "not matched",
        stats.time_snaps, stats.weather_sets, stats.drifts, stats.missing > 0 and (", missing " .. stats.missing) or "")
end

function world.init(c, r, s, connected)
    cfg, role, session = c, r, s
    peer_live = connected or peer_live
    if cfg.world_sync == false then role = "off" end
    log.info("world: " .. (role == "host" and "sending time + weather" or role == "guest" and "copying the host's time + weather while joined" or "off"))
end

return world
