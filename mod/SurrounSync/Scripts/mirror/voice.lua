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
local written = nil -- the text last written (rewritten only when it changes)
local same_world = function() return false end

local function distance_m()
    -- (voice off: a fixed number, so a player walking doesn't replace the bridge's file 4 times a second; the bridge
    -- reads it only to play, and plays nothing with voice off. voice.toggle writes the real one on the next tick)
    if not st.on or not same_world() then return 999 end
    local g, p = ghost.get(), game.player()
    local d = 999
    pcall(function() d = util.dist(util.vec(g:K2_GetActorLocation()), util.vec(p:K2_GetActorLocation())) / 100 end)
    return d
end

function voice.distance() return distance_m() end

-- A handheld radio (the game's buildable Radio, carried anywhere in the inventory) is a walkie-talkie: with one at both
-- ends, voice carries 3x as far and sounds like a radio past earshot (user 2026-11-02; the bridge mixes it, "walkie").
-- Each game looks in its own inventory while voice is on and puts "radio 1|0" on every link; a game without this puts
-- none, so it's never a walkie.
local RADIO = "/Game/Inventory/Items/DataAssets/Buildable/Special/DA_Radio.DA_Radio"
local LOOK_S = 2.0
local WRITE_S = 0.25
local look_in = 0.0
local put_look, peer_radio = nil, false

local function look_for_radio(dt)
    look_in = look_in - dt
    if look_in > 0 then return end
    look_in = LOOK_S
    local have = false
    if st.on and same_world() then
        pcall(function()
            local comp = game.player().BP_JigMultiplayer
            if util.valid(comp) then have = require("mirror.jig").count_of_item(comp, RADIO) > 0 end
        end)
    end
    st.radio = have
    st.looks = (st.looks or 0) + 1
end

-- this link: ours put after every look (a reopened link, a rejoin or a host switch, starts without it; the bridge
-- sends it only when it changed), theirs heard; true when both carry one
function voice.walkie()
    local mine = st.radio == true
    if st.looks ~= put_look then put_look = st.looks; link.put_blob("radio", mine and "1" or "0") end
    local b = link.get_blob("radio")
    if b then peer_radio = b == "1" end
    return mine and peer_radio
end

local function write_file()
    look_for_radio(WRITE_S)
    write_in = WRITE_S
    local more = {}
    require("mirror.peers").each("mirror.voice", function(v, inst)
        if inst then
            more[#more + 1] = string.format(" dist_%s %.1f walkie_%s %d", inst.tag, v.distance(), inst.tag, v.walkie() and 1 or 0)
        end
    end)
    local text = string.format("on %d key %d volume %d dist %.1f walkie %d", st.on and 1 or 0, KEY_VK, VOLUMES[st.vol_i],
        distance_m(), voice.walkie() and 1 or 0) .. table.concat(more)
    if text == written then return end
    -- whole file or none: the bridge read "dist 1" out of a half-written "dist 12.3" (a volume blip)
    local path = link.dir() .. "\\mirror_voice.txt"
    local f = io.open(path .. ".tmp", "wb")
    if not f then return end
    f:write(text)
    f:close()
    os.remove(path)
    if os.rename(path .. ".tmp", path) then written = text end
end

function voice.tick(dt)
    -- one file for the bridge, written by the main link: "dist" = it, "dist_<tag>" = every other player's link
    if (link.tags and link.tags()) then return end
    write_in = write_in - dt
    if write_in <= 0 then write_file() end
    -- phase1 naps until the next write (a toggle or volume change is written at most WRITE_S later)
    return write_in
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
    write_in, look_in = 0, 0
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
