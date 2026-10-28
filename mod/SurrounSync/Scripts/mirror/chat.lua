-- Text chat between the two players (CO-OP tab).

local log = require("mirror.log")
local util = require("mirror.util")
local events = require("mirror.events")
local link = require("mirror.link")
local notify = require("mirror.notify")

local chat = {}

local MAX_LEN, KEEP = 200, 30
local SEND_GAP = 1.0
local IN_BURST, IN_WINDOW = 5, 5.0

local channel = events.new("chat", 16, 30)
-- one history for every player's link (more than two players: peers.lua gives each link its own copy)
local peers = require("mirror.peers")
local history = peers.shared("chat_history")
local sends = peers.shared("chat_send", { last = -100 })
local incoming = {}

local function clean(s)
    s = tostring(s or ""):gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return util.utf8_cut(s, MAX_LEN)
end

local function add(who, text, mine)
    history[#history + 1] = { who = who, text = text, mine = mine }
    while #history > KEEP do table.remove(history, 1) end
end

function chat.send(text)
    text = clean(text)
    if text == "" then return false, "empty" end
    if text:sub(1, 1) == "/" then require("mirror.teleport").command(text); return true end
    local t = os.clock()
    if t - sends.last < SEND_GAP then
        notify.show("Slow down a little - one message a second.", "info")
        return false, "too fast"
    end
    sends.last = t
    channel:send(text)
    peers.each("mirror.chat", function(c, inst) if inst then c.relay(text) end end)
    add("You", text, true)
    log.info("chat: me: " .. text)
    return true
end

function chat.tick()
    channel:pump(function(p)
        local t = os.clock()
        for i = #incoming, 1, -1 do if t - incoming[i] > IN_WINDOW then table.remove(incoming, i) end end
        if #incoming >= IN_BURST then log.warn("chat: dropped a line (more than " .. IN_BURST .. " in " .. IN_WINDOW .. " s)"); return end
        incoming[#incoming + 1] = t
        local text = clean(p)
        if text == "" then return end
        local who = link.peer_name()
        add(who, text, false)
        log.info("chat: " .. who .. ": " .. text)
        if require("mirror.mysettings").on("chat") then notify.show(who .. ": " .. text, "info", nil, true) end
    end)
end

-- (the same line to this copy's player)
function chat.relay(text) channel:send(text) end

function chat.recent(n)
    local out = {}
    for i = math.max(1, #history - n + 1), #history do out[#out + 1] = history[i] end
    return out
end

return chat
