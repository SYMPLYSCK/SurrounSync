-- Push-to-talk voice chat settings (the audio itself goes through the bridge).

local link = require("mirror.link")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local notify = require("mirror.notify")

local voice = {}

local KEY_VK = 0x56
local VOLUMES = { 100, 60, 30 }
local on, vol_i = false, 1
local write_in = 0.0
local same_world = function() return false end

local function distance_m()
    if not same_world() then return 999 end
    local g, p = ghost.get(), game.player()
    local d = 999
    pcall(function() d = util.dist(util.vec(g:K2_GetActorLocation()), util.vec(p:K2_GetActorLocation())) / 100 end)
    return d
end

function voice.tick(dt)
    write_in = write_in - dt
    if write_in > 0 then return end
    write_in = 0.25
    local f = io.open(link.dir() .. "\\mirror_voice.txt", "wb")
    if not f then return end
    f:write(string.format("on %d key %d volume %d dist %.1f", on and 1 or 0, KEY_VK, VOLUMES[vol_i], distance_m()))
    f:close()
end

function voice.toggle()
    local l = link.lobby()
    if l and l.voice == "unavailable" then
        notify.show("Voice needs Steam - it isn't available in the one-PC test mode.", "bad")
        return
    end
    on = not on
    notify.show(on and "Voice on: hold V to talk. Your microphone is the one set in Steam (Settings > Voice)."
        or "Voice off: you won't hear or send voice.", on and "good" or "info")
    write_in = 0
end

function voice.cycle_volume()
    vol_i = vol_i % #VOLUMES + 1
    notify.show("Voice volume " .. VOLUMES[vol_i] .. "%", "info")
    write_in = 0
end

function voice.label()
    return (on and "VOICE: ON" or "VOICE: OFF"), ("VOL " .. VOLUMES[vol_i] .. "%")
end

function voice.init(same_world_fn) same_world = same_world_fn or same_world end

return voice
