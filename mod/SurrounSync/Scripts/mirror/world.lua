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
local mine_set = nil
local hold_until = -1
local HOLD = 6.0
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

-- Blood moon: each game rolls its own at sunset (BP_EventManager BloodMoonChance), so one player had a red sky
-- and red-eyed zombies the other didn't. The host's is shared: the guest doesn't roll while joined.
local EM = "/Game/Blueprints/Events/BP_EventManager.BP_EventManager_C"
local events_mgr
local moon = false
local moon_fn = function(self, on) pcall(function() moon = on:get() == true end) end
local em_next = 0.0
local function event_manager()
    if not util.valid(events_mgr) and now >= em_next then
        events_mgr, em_next = live("BP_EventManager_C"), now + 20
    end
    return util.valid(events_mgr) and events_mgr or nil
end

local function current_weather(w)
    local p, name, label
    pcall(function() p = w.Weather end)
    if not util.valid(p) then return nil end
    pcall(function() name = util.fname(p) end)
    pcall(function() label = str(p["User Friendly Name"]) end)
    return name, label
end

-- Random weather (the game's own, and what the debug menu switches to after a change) is a settings object
-- made at runtime, not a preset either game can look up: share its values instead.
local FIELDS = { "Cloud Coverage", "Rain", "Snow", "Thunder/Lightning", "Wind Intensity", "Fog", "Dust",
                 "Material Wetness", "Material Snow Coverage", "Material Dust Coverage" }
local WS_CLASS = "/Game/UltraDynamicSky/Blueprints/Weather_Effects/System/UDS_Weather_Settings.UDS_Weather_Settings_C"
local function is_asset(p)
    local full
    pcall(function() full = p:GetFullName() end)
    return full ~= nil and full:find(" /Game/", 1, true) ~= nil and not full:find(":", 1, true)
end
local function values_of(p)
    local t = {}
    for i, f in ipairs(FIELDS) do
        local v
        pcall(function() v = p[f] end)
        t[i] = tonumber(v) or 0
    end
    return t
end
local function values_str(t)
    local o = {}
    for i, v in ipairs(t) do o[i] = string.format("%.3f", v) end
    return table.concat(o, ",")
end
local function parse_values(s)
    local t = {}
    for v in (s or ""):gmatch("[^,]+") do t[#t + 1] = tonumber(v) or 0 end
    return #t == #FIELDS and t or nil
end
local function differ(a, b)
    if not (a and b) then return true end
    for i = 1, #FIELDS do if math.abs((a[i] or 0) - (b[i] or 0)) > 0.02 then return true end end
    return false
end
-- Live values move by themselves while weather blends: only a clear difference counts.
local function differ_live(a, b)
    if not (a and b) then return true end
    for i = 1, #FIELDS do if math.abs((a[i] or 0) - (b[i] or 0)) > 0.25 then return true end end
    return false
end
-- The weather the player sees right now (a settings object UDW blends towards its target).
local function global_state(w)
    local g
    pcall(function() g = w["Global Weather State"] end)
    return util.valid(g) and g or nil
end
-- One settings object of our own (transient, kept from garbage collection) to hold copied values.
local own_ws
local function own_settings(tag)
    if util.valid(own_ws) then return own_ws end
    own_ws = nil
    -- (StaticFindObject("/Engine/Transient") raises "Name wasn't long" in UE4SS 3.0.1: this never worked.
    -- The game instance outlives every world and isn't saved.)
    local cls, outer = StaticFindObject(WS_CLASS), FindFirstOf("SD_GameInstance_C")
    if not (util.valid(cls) and util.valid(outer)) then return nil end
    pcall(function() own_ws = StaticConstructObject(cls, outer, FName("SurrounSync_Weather_" .. tag), 0x42) end)
    if not util.valid(own_ws) then own_ws = nil; log.warn("world: couldn't make a weather settings object - random weather can't be copied") end
    return own_ws
end
local function apply_values(w, vals, tag)
    local ws = own_settings(tag)
    if not ws then return false end
    for i, f in ipairs(FIELDS) do pcall(function() ws[f] = vals[i] end) end
    local ok, err = pcall(function() local f = w["Change Weather"]; f(w, ws, BLEND) end)
    if not ok then log.warn("world: copying the weather failed: " .. tostring(err)) end
    return ok, ws
end

local function find_preset(name, label)
    local exact, by_label
    local ok, err = pcall(function()
        for _, o in ipairs(FindAllOf("UDS_Weather_Settings_C") or {}) do
            if util.valid(o) and not o:GetFullName():find("Default__", 1, true) then
                if util.fname(o) == name then exact = o; return end
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
    -- The guest changed the weather on their side (debug menu): it becomes the shared weather.
    local req = peer_live() and link.get_blob("sky_req") or nil
    -- GUEST WEATHER (host rule) off: the host's weather stays, the guest's sync puts it back for them
    if req and not require("mirror.hostrules").mine("weather") then
        log.info("world: the guest changed the weather - ignored (GUEST WEATHER is off)")
        req = nil
    end
    local rn, rl, rv, ra = (req or ""):match("^([^|]*)|([^|]*)|([^|]*)|(%d)$")
    if rn and w then
        local preset = ra == "1" and rn ~= "" and find_preset(rn, rl) or nil
        local vals_t = parse_values(rv)
        if preset then
            pcall(function() local f = w["Change Weather"]; f(w, preset, BLEND) end)
            log.info("world: the guest changed the weather to " .. rn .. " - now shared")
        elseif vals_t then
            apply_values(w, vals_t, "Guest")
            log.info("world: the guest changed the weather (" .. (rl ~= "" and rl or "random") .. ") - now shared")
        end
    end
    local name, label, vals, asset, live_vals = nil, nil, "", 0, ""
    if w then
        name, label = current_weather(w)
        local p
        pcall(function() p = w.Weather end)
        if util.valid(p) then vals, asset = values_str(values_of(p)), is_asset(p) and 1 or 0 end
        local g = global_state(w)
        if g then live_vals = values_str(values_of(g)) end
        -- (evidence for "the host's weather changed, the guest's didn't": every clear change of what the host sees)
        local lv = g and values_of(g) or nil
        if lv and (not world.host_logged or differ_live(world.host_logged, lv)) then
            world.host_logged = lv
            log.info("world: my weather is now " .. tostring(label or name) .. " (live " .. live_vals .. ") - sent to the guest")
        end
    end
    util.ensure_hook(EM .. ":SetBloodMoon", moon_fn)
    link.put_blob("sky", string.format("%.2f|%s|%s|%s|%d|%s|m%d", tod, name or "", label or "", vals, asset, live_vals, moon and 1 or 0))
end

-- Guest-side game settings changed while joined (restored on leaving):
-- its own random weather would roll new weather here, which read as "you changed the weather" and was pushed
-- to the host (both games kept overriding each other); its clock ran on while the host's stood still
-- (a frozen host clock snapped the guest back every ~12 s).
local saved = nil
local host_tod_prev, host_still = nil, 0.0
local function hold_guest_settings(s, w)
    if saved then return end
    saved = {}
    pcall(function() saved.random = w and w["Random Weather Variation"] end)
    pcall(function() saved.animate = s and s["Animate Time of Day"] end)
    -- (a byte enum in this UDS version, 0 = off; older ones used a bool)
    local on = saved.random == true or (type(saved.random) == "number" and saved.random ~= 0)
    if w and on then
        local ok = pcall(function() w["Random Weather Variation"] = type(saved.random) == "number" and 0 or false end)
        log.info("world: your own random weather is off while joined (the host's weather is shared)" .. (ok and "" or " - FAILED"))
    end
end
local function restore_guest_settings()
    if not saved then return end
    local s, w = sky, weather
    if util.valid(w) and saved.random ~= nil then pcall(function() w["Random Weather Variation"] = saved.random end) end
    if util.valid(s) and saved.animate ~= nil then pcall(function() s["Animate Time of Day"] = saved.animate end) end
    if util.valid(events_mgr) and saved.moon_chance ~= nil then pcall(function() events_mgr.BloodMoonChance = saved.moon_chance end) end
    saved, host_tod_prev, host_still = nil, nil, 0
end
world.restore = restore_guest_settings

local function guest_tick()
    local msg = peer_live() and link.get_blob("sky") or nil
    if msg then
        local rest, m = msg:match("^(.*)|m([01])$")
        if rest then msg = rest end
        local t, n, l, v, a, g = msg:match("^([^|]+)|([^|]*)|([^|]*)|([^|]*)|(%d)|?([^|]*)$")
        if not t then t, n, l = msg:match("^([^|]+)|([^|]*)|(.*)$") end
        if t then host = { tod = tonumber(t), name = n, label = l, vals = parse_values(v), asset = a ~= "0", live = parse_values(g), moon = m and m == "1" } end
    end
    if not host or not session.in_world() then matched, mine_set = nil, nil; restore_guest_settings(); return end
    local s, w = actors()
    hold_guest_settings(s, w)
    util.ensure_hook(EM .. ":SetBloodMoon", moon_fn)
    local em = (saved.moon_chance == nil or (host.moon ~= nil and host.moon ~= moon)) and event_manager()
    if em and saved.moon_chance == nil then
        pcall(function() saved.moon_chance = em.BloodMoonChance; em.BloodMoonChance = 0 end)
    end
    if em and host.moon ~= nil and host.moon ~= moon then
        local ok, err = pcall(function() em:SetBloodMoon(host.moon) end)
        if ok then moon = host.moon end
        log.info("world: blood moon " .. (host.moon and "rises" or "ends") .. " - the host's" .. (ok and "" or (" FAILED: " .. tostring(err))))
    end

    -- the host's clock standing still (paused time / a time-freeze mod): stop ours too, run it again when theirs does
    -- (an unchanged blob isn't delivered again: "still" = no new clock value for 5 s while the link is up)
    if host.tod then
        -- (a held clock still creeps by hundredths; a running one moves ~1.3 per second)
        if host_tod_prev == nil or math.abs(host.tod - host_tod_prev) >= 0.5 then host_tod_prev, host_still = host.tod, now end
        if s and saved and saved.animate ~= nil then
            local want_animate = (now - host_still < 5 or not peer_live()) and saved.animate
            pcall(function() if s["Animate Time of Day"] ~= want_animate then s["Animate Time of Day"] = want_animate end end)
        end
    end

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

    -- Our weather changed and not by us (debug menu, after we had matched): ask the host to make it shared.
    if w and matched and mine_set then
        local p
        pcall(function() p = w.Weather end)
        if util.valid(p) and not util.same(p, mine_set) then
            local n, l = current_weather(w)
            link.put_blob("sky_req", string.format("%s|%s|%s|%d", n or "", l or "", values_str(values_of(p)), is_asset(p) and 1 or 0))
            log.info("world: you changed the weather to " .. tostring(l or n) .. " - asking the host to share it")
            matched, mine_set, want, hold_until = nil, p, nil, now + HOLD
            return
        end
    end

    if now < hold_until then return end
    if w and host.live then
        -- What the host sees is its live weather state (clouds, rain, snow right now), not the preset it names:
        -- the same preset name with a different live state showed rain + snow here under the host's clear sky.
        local g = global_state(w)
        local have = g and values_of(g) or nil
        if have and not differ_live(have, host.live) then
            matched = "live"
        elseif not want or differ_live(want.vals, host.live) or now - want.at > RETRY then
            want = { vals = host.live, at = now }
            local ok, ws = apply_values(w, host.live, "Host")
            if ok then
                mine_set, matched = ws, "live"
                stats.weather_sets = stats.weather_sets + 1
                log.info("world: weather -> the host's live weather (" .. values_str(host.live) .. "), was " .. values_str(have or {}))
            end
        end
    elseif w and host.vals and not host.asset then
        local p
        pcall(function() p = w.Weather end)
        local have = util.valid(p) and values_of(p) or nil
        if util.same(p, own_ws) and not differ(have, host.vals) then matched = "random"
        elseif not want or differ(want.vals, host.vals) or now - want.at > RETRY then
            want = { vals = host.vals, at = now }
            local ok, ws = apply_values(w, host.vals, "Host")
            if ok then mine_set, matched = ws, "random"; stats.weather_sets = stats.weather_sets + 1 end
        end
    elseif w and host.name ~= "" then
        local name = current_weather(w)
        if name == host.name then
            pcall(function() mine_set = w.Weather end)
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
    restore_guest_settings()
    cfg, role, session = c, r, s
    peer_live = connected or peer_live
    if cfg.world_sync == false then role = "off" end
    log.info("world: " .. (role == "host" and "sending time + weather" or role == "guest" and "copying the host's time + weather while joined" or "off"))
end

-- the old world's sky/weather actors are freed with it
function world.forget() sky, weather, events_mgr, moon, em_next = nil, nil, nil, false, 0 end

return world
