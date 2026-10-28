-- The other player's flashlight.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local link = require("mirror.link")
local audio = require("mirror.audio")

local lights = {}

local GS = "/Script/Engine.Default__GameplayStatics"
local CUE_ON = "/Game/Audio/Survival_Sound_Kit_HD_Remake/Cues/Turning_Flashlight_On_Cue.Turning_Flashlight_On_Cue"
local CUE_OFF = "/Game/Audio/Survival_Sound_Kit_HD_Remake/Cues/Turning_Flashlight_Off_3_Cue.Turning_Flashlight_Off_3_Cue"

local poll_in = 0.0
local mine = nil
local applied, applied_gen = nil, nil
local peer_state = nil
local peer_on = false

local function path_of(obj)
    local p
    pcall(function() p = obj:GetFullName():match("^%S+ (.+)$") end)
    return p
end

local function read(p)
    local fl, i, r, m
    pcall(function() fl = p.Flashlight end)
    if not util.valid(fl) then return nil end
    pcall(function() i = fl.Intensity end)
    pcall(function() r = fl.AttenuationRadius end)
    pcall(function() m = fl.LightFunctionMaterial end)
    i, r = tonumber(i) or 0, tonumber(r) or 0
    if i <= 0 or r <= 0 then return "0 0 -" end
    return string.format("%.1f %.0f %s", i, r, util.valid(m) and path_of(m) or "-")
end

local function apply(g, state)
    local i, r, m = state:match("^(%S+) (%S+) (%S+)$")
    i, r = tonumber(i) or 0, tonumber(r) or 0
    local fl
    pcall(function() fl = g.Flashlight end)
    if not util.valid(fl) then return end
    local on = i > 0 and r > 0
    if on and m ~= "-" then
        local mat = StaticFindObject(m)
        if util.valid(mat) then pcall(function() fl:SetLightFunctionMaterial(mat) end) end
    end
    pcall(function() fl:SetIntensity(on and i or 0) end)
    pcall(function() fl:SetAttenuationRadius(on and r or 0) end)
    if on ~= peer_on then
        local cue, gs = StaticFindObject(on and CUE_ON or CUE_OFF), util.cdo(GS)
        if util.valid(cue) and gs then
            pcall(function()
                gs:PlaySoundAtLocation(g, cue, g:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 }, 1.0, 1.0, 0.0,
                    audio.attenuation_for(cue), nil, nil, nil)
            end)
        end
        log.info("lights: the other player's flashlight " .. (on and "on" or "off"))
    end
    peer_on = on
end

local aim_in = 0.0
function lights.tick(dt, pose)
    poll_in = poll_in - dt
    if poll_in <= 0 then
        poll_in = 0.25
        local s = read(game.player())
        if s and s ~= mine then mine = s; link.put_blob("light", s) end
    end
    local g = ghost.get()
    if not g then applied, applied_gen = nil, nil; return end
    -- get_blob hands out a blob only when it changed: keep it, or a respawned ghost (every save) stays dark
    peer_state = link.get_blob("light") or peer_state
    local state = peer_state
    if state and (state ~= applied or applied_gen ~= ghost.generation()) then
        applied, applied_gen = state, ghost.generation()
        util.safe(apply, "lights.apply", g, state)
    end
    aim_in = aim_in - dt
    if peer_on and pose and pose.aim and pose.aim.view_yaw and aim_in <= 0 then
        aim_in = 0.1
        pcall(function()
            g.Flashlight:K2_SetWorldRotation(util.rot(pose.aim.pitch, pose.aim.view_yaw, 0), false, {}, false)
        end)
    end
end

return lights
