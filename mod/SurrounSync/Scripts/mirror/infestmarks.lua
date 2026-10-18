-- Puts the host's infestation markers on the guest's map. Off by default.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")

local infestmarks = {}

local session = nil
local due = {}
local clock = 0.0
local was_in = false

local done = {}

local F = {
    title = "MarkerTitle_47_5E7A698C4B5AC497BBB438A55515B853",
    tex = "MarkerTexture_10_217A4B4A49F28BE075685196E3EC66CD",
    tsize = "TextureSize_30_0FC614D34939DCCA4077899925344EDF",
    txsize = "TextSize_33_ADA10B73491C7DD1835FD69801CC42F1",
    color = "MarkerColor_52_AB92BD2E4886BEC45F39A59226A8B872",
    border = "TooltipBorderColor_55_45E57FFE40453BB296F6D7A44B06A8D2",
    compass = "CompassMarker?_45_173EEC314B156D67370A86A9FF973EA4",
}

local function minimap()
    for _, ms in ipairs(FindAllOf("BPC_MinimapSystem_C") or {}) do
        local ok = false
        pcall(function()
            ok = not ms:GetFullName():find("Default__", 1, true)
                and (util.same(ms:GetOwner(), game.player()) or util.same(ms:GetOwner(), game.controller()))
        end)
        if ok then return ms end
    end
end

local function col(c) return { R = c.R, G = c.G, B = c.B, A = c.A } end

local function pass()
    local ms = minimap()
    local widget_ok = false
    pcall(function() widget_ok = util.valid(ms.MapWidget) end)
    if not widget_ok then log.info("infestmarks: the map isn't built yet - next pass"); return end
    local world = game.world()
    local added, seen, failed = 0, 0, 0
    local by_place = {}
    for _, m in ipairs(FindAllOf("BP_Marker_C") or {}) do
        pcall(function()
            local l = m:K2_GetActorLocation()
            by_place[string.format("%d,%d", math.floor(l.X / 100), math.floor(l.Y / 100))] = m
        end)
    end
    for _, m in pairs(by_place) do
        pcall(function()
            if m:GetFullName():find("Default__", 1, true) then return end
            if not util.same(m:GetWorld(), world) then return end
            local title = ""
            pcall(function() title = m.MarkerTitle:ToString() end)
            if title ~= "Primary Infestation" then return end
            seen = seen + 1
            local a = util.addr(m)
            if not a or done[a] then return end
            local desc = ""
            pcall(function() desc = m.MarkerDescription:ToString() end)
            local ts = m["Texture Size"]
            local data = {
                [F.title] = FText(title), [F.tex] = m.MarkerTexture, [F.tsize] = { X = ts.X, Y = ts.Y },
                [F.txsize] = { X = 1.0, Y = 1.0 }, [F.color] = col(m.Color), [F.border] = col(m.TooltipBorderColor),
                [F.compass] = m["AddMarkerToCompass?"] == true,
            }
            local ok = pcall(function() ms["Add World Marker"](ms, data, m, FText(desc), {}) end)
            if ok then done[a] = true; added = added + 1 else failed = failed + 1 end
        end)
    end
    log.info(string.format("infestmarks: %d infestation marker(s) put on the map (%d in this world%s)", added, seen,
        failed > 0 and (", " .. failed .. " failed") or ""))
end

function infestmarks.tick(dt)
    clock = clock + dt
    local inside = session and session.in_world and session.in_world() or false
    if inside and not was_in then due = { clock + 15.0, clock + 45.0 } end
    was_in = inside
    if due[1] and clock >= due[1] then table.remove(due, 1); util.safe(pass, "infestmarks.pass") end
end

function infestmarks.init(s, role, cfg)
    if role ~= "guest" or not (cfg and cfg.infest_markers == true) then return end
    session = s
    game.on_new_player(function() if was_in then due = { clock + 15.0, clock + 45.0 } end end)
end

return infestmarks
