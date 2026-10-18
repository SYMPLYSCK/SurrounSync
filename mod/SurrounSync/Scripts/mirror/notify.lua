-- On-screen messages using the game's own notification pop-up.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")

local notify = {}

local PREFIX, GAP_S, REPEAT_S, MAX_QUEUE = "Co-op: ", 1.5, 20.0, 6
local DURATION = { info = 4.0, good = 5.0, bad = 8.0 }
local COLORS = {
    info = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 },
    good = { R = 0.45, G = 1.0, B = 0.45, A = 1.0 },
    bad  = { R = 1.0, G = 0.45, B = 0.35, A = 1.0 },
}

local enabled = true
local queue = {}
local broken = false
local clock, next_at = 0.0, 0.0
local last_shown = {}

function notify.configure(cfg) enabled = cfg.notify ~= false end

local PING_SOUNDS = {
    "/Game/Audio/Other/Whistle_Cue.Whistle_Cue",
    "/Game/Audio/SurvivalSoundPack/Cues/UI_click_sound_Cue.UI_click_sound_Cue",
}
function notify.ping(times)
    local util, game = require("mirror.util"), require("mirror.game")
    local s
    for _, p in ipairs(PING_SOUNDS) do
        local o = StaticFindObject(p)
        if util.valid(o) then s = o; break end
    end
    local w = game.world()
    if not s or not w then return false end
    local gs = util.cdo("/Script/Engine.Default__GameplayStatics")
    for _ = 1, times or 1 do
        pcall(function() gs:PlaySound2D(w, s, 1.0, 1.0, 0.0, nil, nil, true) end)
    end
    return true
end

function notify.show(text, kind, key)
    kind = COLORS[kind] and kind or "info"
    text = tostring(text):gsub("^%l", string.upper)
    if kind == "bad" then log.warn("notify: " .. text) else log.info("notify: " .. text) end
    if not enabled or broken then return end
    if last_shown[text] and clock - last_shown[text] < REPEAT_S then return end
    for _, m in ipairs(queue) do
        if m.text == text then return end
        if key and m.key == key then m.text, m.kind = text, kind; return end
    end
    queue[#queue + 1] = { text = text, kind = kind, key = key }
    while #queue > MAX_QUEUE do
        local drop = 1
        for i, m in ipairs(queue) do if m.kind ~= "bad" then drop = i; break end end
        table.remove(queue, drop)
    end
end

function notify.tick(dt)
    clock = clock + (dt or 1 / 30)
    if #queue == 0 or clock < next_at then return end
    local p = game.player()
    if not util.valid(p) then return end
    local m = table.remove(queue, 1)
    for t, at in pairs(last_shown) do if clock - at >= REPEAT_S then last_shown[t] = nil end end
    last_shown[m.text] = clock
    next_at = clock + GAP_S
    local ok, err = pcall(function() p:CreateNotificationUI(FText(PREFIX .. m.text), nil, COLORS[m.kind], DURATION[m.kind]) end)
    if not ok then
        broken = true
        queue = {}
        log.warn("notify: the game's notification pop-up failed (" .. tostring(err) .. ") - messages go to the log only")
    end
end

return notify
