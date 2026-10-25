-- Push-to-talk voice chat settings (the audio itself goes through the bridge).

local link = require("mirror.link")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local notify = require("mirror.notify")

local voice = {}

local KEY_VK = 0x56
local VOLUMES = { 100, 60, 30 }
-- on/off and volume belong to the player, not to one link (more than two players: every copy sees this)
local st = require("mirror.peers").shared("voice", { on = false, vol_i = 1 })
local write_in = 0.0
local same_world = function() return false end

local function distance_m()
    if not same_world() then return 999 end
    local g, p = ghost.get(), game.player()
    local d = 999
    pcall(function() d = util.dist(util.vec(g:K2_GetActorLocation()), util.vec(p:K2_GetActorLocation())) / 100 end)
    return d
end

function voice.distance() return distance_m() end

function voice.tick(dt)
    -- one file for the bridge, written by the main link: "dist" = it, "dist_<tag>" = every other player's link
    if (link.tags and link.tags()) then return end
    write_in = write_in - dt
    if write_in > 0 then return end
    write_in = 0.25
    local more = {}
    require("mirror.peers").each("mirror.voice", function(v, inst)
        if inst then more[#more + 1] = string.format(" dist_%s %.1f", inst.tag, v.distance()) end
    end)
    local f = io.open(link.dir() .. "\\mirror_voice.txt", "wb")
    if not f then return end
    f:write(string.format("on %d key %d volume %d dist %.1f", st.on and 1 or 0, KEY_VK, VOLUMES[st.vol_i], distance_m()) .. table.concat(more))
    f:close()
end

function voice.toggle()
    local l = link.lobby()
    if l and l.voice == "unavailable" then
        notify.show("Voice needs Steam - it isn't available in the one-PC test mode.", "bad")
        return
    end
    st.on = not st.on
    local on = st.on
    notify.show(on and "Voice on: hold V to talk. Your microphone is the one set in Steam (Settings > Voice)."
        or "Voice off: you won't hear or send voice.", on and "good" or "info")
    write_in = 0
end

function voice.cycle_volume()
    st.vol_i = st.vol_i % #VOLUMES + 1
    notify.show("Voice volume " .. VOLUMES[st.vol_i] .. "%", "info")
    write_in = 0
end

function voice.label()
    return (st.on and "VOICE: ON" or "VOICE: OFF"), ("VOL " .. VOLUMES[st.vol_i] .. "%")
end

-- Who is talking right now: the bridge writes mirror_voice_state.txt ("me 0|1 peer 0|1") only when it changes.
local state_me, state_peer, state_in = false, false, 0.0
function voice.talking(dt)
    state_in = state_in - (dt or 0)
    if state_in <= 0 then
        state_in = 0.2
        local f = io.open(link.dir() .. "\\mirror_voice_state.txt", "rb")
        local s = f and f:read("*a") or ""
        if f then f:close() end
        -- "me 0|1 peer 0|1 <tag> 0|1 ...": the peer flag is the main link's, the others by their file tag
        local t = (link.tags and link.tags())
        state_me = s:find("me 1", 1, true) ~= nil
        if t then state_peer = s:find(" " .. t.out .. " 1", 1, true) ~= nil
        else state_peer = s:find("peer 1", 1, true) ~= nil end
    end
    return state_me, state_peer
end

function voice.init(same_world_fn) same_world = same_world_fn or same_world end

return voice
