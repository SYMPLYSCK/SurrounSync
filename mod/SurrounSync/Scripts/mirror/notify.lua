-- On-screen messages: SurrounSync's own stack of message cards at the top right.
--
-- Up to MAX_CARDS show at once, the moment they happen (the game's one-at-a-time pop-up made a burst arrive seconds
-- late). A card has a coloured edge for its kind (info / good / warn / bad), a heading for where it applies (the
-- Realm's name, CO-OP, SURROUNSYNC) and the text. A message with a key is one live card: showing that key again
-- changes the card in place (a countdown, "still waiting"), notify.clear(key) takes it away. The same text again
-- while its card is up counts ("x3") instead of making a second card. Problems never wait behind info: an info card
-- makes room. Every message, shown or not, goes into the history (Ctrl+F9, or /messages in the chat).
-- If the cards can't be built here, the game's own pop-up shows them one at a time, as before.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")

local notify = {}

local MAX_CARDS, MAX_WAIT, REPEAT_S, HISTORY = 4, 8, 20.0, 50
local KINDS = {
    info = { strip = { R = 0.70, G = 0.72, B = 0.75, A = 1 }, secs = 5.0 },
    good = { strip = { R = 0.30, G = 0.85, B = 0.38, A = 1 }, secs = 5.0 },
    warn = { strip = { R = 1.00, G = 0.70, B = 0.18, A = 1 }, secs = 7.0 },
    bad  = { strip = { R = 1.00, G = 0.30, B = 0.24, A = 1 }, secs = 9.0 },
}
local PER_CHAR, LONGEST, STICKY_MAX = 0.045, 15.0, 120.0   -- s per character past 60, the longest card, a sticky one
local FADE_IN, FADE_OUT = 0.2, 0.5

local enabled = true
local clock = 0.0
local cards = {}       -- on screen, oldest first: { text, kind, key, title, count, progress, shown, till, sticky }
local waiting = {}     -- not on screen yet (all cards busy)
local recent = {}      -- text -> clock its card went away (the same text again within REPEAT_S isn't shown again)
local history = {}     -- { at = os.date, text, kind, shown }
local dirty = true
local last_click = -100.0

function notify.configure(cfg) enabled = cfg.notify ~= false end

local PING_SOUNDS = {
    "/Game/Audio/Other/Whistle_Cue.Whistle_Cue",
    "/Game/Audio/SurvivalSoundPack/Cues/UI_click_sound_Cue.UI_click_sound_Cue",
}
local function play2d(paths, times)
    local s
    for _, p in ipairs(paths) do
        local o = util.find(p)
        if o then s = o; break end
    end
    local w = game.world()
    if not s or not w then return false end
    local gs = util.cdo("/Script/Engine.Default__GameplayStatics")
    for _ = 1, times or 1 do
        pcall(function() gs:PlaySound2D(w, s, 1.0, 1.0, 0.0, nil, nil, true) end)
    end
    return true
end
function notify.ping(times) return play2d(PING_SOUNDS, times) end

-- where a message applies: the Realm played in, a co-op session, or the mod itself
local function heading()
    local ok, t = pcall(function()
        local rp = package.loaded["mirror.realmplay"]
        local s = package.loaded["mirror.session"]
        local rid = s and s.realm_joined and s.realm_joined()
        local name = rp and rp.hosting and rp.hosting()
        if not name and rid then
            local r = require("mirror.realm").find(rid)
            name = r and r.name or require("mirror.realm").code(rid)
        end
        if name then return name:upper() end
        local p1 = package.loaded["mirror.phase1"]
        if p1 and p1.started and p1.started() and (p1.connected and p1.connected()) then return "CO-OP" end
        return "SURROUNSYNC"
    end)
    return ok and t or "SURROUNSYNC"
end

local function duration(c)
    if c.sticky then return STICKY_MAX end
    return math.min(LONGEST, KINDS[c.kind].secs + math.max(0, #c.text - 60) * PER_CHAR)
end

-- a live card's updates are one entry (its newest state): a countdown isn't 30 lines of history
local function remember(text, kind, shown, key)
    if key then
        for i = #history, 1, -1 do
            if history[i].key == key then table.remove(history, i); break end
        end
    end
    history[#history + 1] = { at = os.date("%H:%M"), text = text, kind = kind, shown = shown, key = key }
    while #history > HISTORY do table.remove(history, 1) end
end

local function put_on_screen(c)
    c.shown, c.count = clock, c.count or 1
    c.till = clock + duration(c)
    cards[#cards + 1] = c
    dirty = true
    if c.kind == "bad" and clock - last_click > 3.0 then
        last_click = clock
        pcall(play2d, { PING_SOUNDS[2] }, 1)   -- (a message never fails its caller)
    end
end

-- the oldest card a problem may push off (never another problem or warning)
local function evictable()
    for i, c in ipairs(cards) do
        if c.kind == "info" or c.kind == "good" then return i end
    end
    return nil
end

-- text: the message. kind: "info" (default), "good", "warn", "bad". key: one live card for this key.
-- always: shown whatever MY SETTINGS' messages setting says (chat lines have their own).
-- opts: { title = heading, progress = 0..1 (a bar), sticky = stays until shown again or cleared }
function notify.show(text, kind, key, always, opts)
    kind = KINDS[kind] and kind or "info"
    text = tostring(text):gsub("^%l", string.upper)
    opts = opts or {}
    if kind == "bad" or kind == "warn" then log.warn("notify: " .. text) else log.info("notify: " .. text) end
    local shown = enabled
    if shown and not always then
        local ok, level = pcall(function() return require("mirror.mysettings").value("messages") end)
        level = ok and level or "all"
        if level == "off" or (level == "important" and (kind == "info" or kind == "good")) then shown = false end
    end
    remember(text, kind, shown, key)
    if not shown then return end
    local title = opts.title or heading()
    -- the live card for this key: changed in place (it stays where it is on screen)
    if key then
        for _, c in ipairs(cards) do
            if c.key == key then
                if c.text ~= text or c.kind ~= kind or c.progress ~= opts.progress or c.title ~= title then dirty = true end
                c.text, c.kind, c.title, c.progress, c.sticky = text, kind, title, opts.progress, opts.sticky
                c.till = clock + duration(c)
                return
            end
        end
        for _, c in ipairs(waiting) do
            if c.key == key then
                c.text, c.kind, c.title, c.progress, c.sticky = text, kind, title, opts.progress, opts.sticky
                return
            end
        end
    end
    -- the same text while its card is up: counted on that card
    for _, c in ipairs(cards) do
        if c.text == text and not c.key then
            c.count = c.count + 1
            c.till = clock + duration(c)
            dirty = true
            return
        end
    end
    for _, c in ipairs(waiting) do
        if c.text == text and not c.key then c.count = (c.count or 1) + 1; return end
    end
    if not key and recent[text] and clock - recent[text] < REPEAT_S then return end
    local c = { text = text, kind = kind, key = key, title = title, progress = opts.progress, sticky = opts.sticky }
    if #cards >= MAX_CARDS and kind == "bad" then
        local i = evictable()
        if i then table.remove(cards, i); dirty = true end
    end
    if #cards < MAX_CARDS then put_on_screen(c); return end
    waiting[#waiting + 1] = c
    while #waiting > MAX_WAIT do
        local drop = 1
        for i, w in ipairs(waiting) do if w.kind == "info" or w.kind == "good" then drop = i; break end end
        table.remove(waiting, drop)
    end
end

-- the live card for key goes (the countdown ended, the request went away); only_sticky: only while it still waits
-- for something (a sticky card), not once it shows how that ended
function notify.clear(key, only_sticky)
    if not key then return end
    for i = #cards, 1, -1 do
        local c = cards[i]
        if c.key == key and (c.sticky or not only_sticky) then table.remove(cards, i); dirty = true end
    end
    for i = #waiting, 1, -1 do
        local c = waiting[i]
        if c.key == key and (c.sticky or not only_sticky) then table.remove(waiting, i) end
    end
end

function notify.history() return history end

-- ---- the view: one widget with MAX_CARDS card slots, built once per world and only filled in afterwards ----
-- (UMG from Lua: every widget starts from its class's complete defaults and only fields of them are changed - a half
-- filled struct crashed the game's next paint once, names.lua)

local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"
local SHELL = "/Game/JigSInventory/Jigsaw/Widgets/BP_StatTextW.BP_StatTextW_C"
local UMG = "/Script/UMG."
local CARD_W, TOP, RIGHT, GAP = 380, 96, 28, 5
local BG = { R = 0.02, G = 0.02, B = 0.025, A = 0.86 }
local WHITE = { R = 0.96, G = 0.96, B = 0.96, A = 1 }
local COLLAPSED, HIT_INVISIBLE = 1, 3

local view = { w = nil, slots = {}, broken = false, built_for = nil, legacy_next = 0.0 }

local function new(cls, outer)
    local o
    pcall(function() o = StaticConstructObject(StaticFindObject(UMG .. cls), outer) end)
    if not util.valid(o) then error("couldn't create " .. cls) end
    return o
end

local function label(tree, size, bold, wrap)
    local t = new("TextBlock", tree)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = WHITE, ColorUseRule = 0 }) end)
    pcall(function()
        local f = t.Font
        f.Size = size
        f.TypefaceFontName = FName(bold and "Bold" or "Regular")
        t:SetFont(f)
    end)
    if wrap then
        pcall(function() t:SetAutoWrapText(true) end)
        pcall(function() t:SetWrapTextAt(wrap) end)
    end
    return t
end

function view.build()
    local wbl, pc, shell = util.cdo(WBL), game.controller(), StaticFindObject(SHELL)
    if not (wbl and util.valid(pc) and util.valid(shell)) then return false end
    local w
    pcall(function() w = wbl:Create(pc, shell, pc) end)
    if not util.valid(w) then return false end
    local tree = w.WidgetTree
    local canvas = new("CanvasPanel", tree)
    tree.RootWidget = canvas
    local stack = new("VerticalBox", tree)
    local cs = canvas:AddChildToCanvas(stack)
    pcall(function()
        cs:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
        cs:SetAlignment({ X = 1, Y = 0 })
        cs:SetPosition({ X = -RIGHT, Y = TOP })
        cs:SetAutoSize(true)
    end)
    local slots = {}
    for i = 1, MAX_CARDS do
        local card = new("Border", tree)
        pcall(function() card:SetBrushColor(BG) end)
        pcall(function() card:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 }) end)
        local size = new("SizeBox", tree)
        pcall(function() size:SetWidthOverride(CARD_W) end)
        pcall(function() size:SetContent(card) end)
        local row = new("HorizontalBox", tree)
        pcall(function() card:SetContent(row) end)
        local strip = new("Border", tree)
        local sw = new("SizeBox", tree)
        pcall(function() sw:SetWidthOverride(5) end)
        pcall(function() strip:SetContent(sw) end)
        local ss = row:AddChildToHorizontalBox(strip)
        pcall(function() ss:SetVerticalAlignment(0) end)   -- (fill: the edge runs the card's whole height)
        local col = new("VerticalBox", tree)
        local cols = row:AddChildToHorizontalBox(col)
        pcall(function()
            cols:SetPadding({ Left = 11, Top = 7, Right = 12, Bottom = 8 })
            cols:SetSize({ Value = 1.0, SizeRule = 1 })
        end)
        local title = label(tree, 11, true)
        col:AddChildToVerticalBox(title)
        local body = label(tree, 14, false, CARD_W - 36)
        local bs = col:AddChildToVerticalBox(body)
        pcall(function() bs:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 0 }) end)
        local bar = new("ProgressBar", tree)
        local ps = col:AddChildToVerticalBox(bar)
        pcall(function() ps:SetPadding({ Left = 0, Top = 6, Right = 0, Bottom = 1 }) end)
        local vs = stack:AddChildToVerticalBox(size)
        pcall(function() vs:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = GAP }) end)
        pcall(function() size:SetVisibility(COLLAPSED) end)
        slots[i] = { size = size, card = card, strip = strip, title = title, body = body, bar = bar, shows = nil }
    end
    pcall(function() canvas:SetVisibility(HIT_INVISIBLE) end)   -- (never in the way of a click)
    pcall(function() w:AddToViewport(40) end)
    view.w, view.slots, view.built_for = w, slots, util.addr(pc)
    return true
end

local function fill(s, c)
    local k = KINDS[c.kind]
    pcall(function() s.strip:SetBrushColor(k.strip) end)
    pcall(function() s.title:SetColorAndOpacity({ SpecifiedColor = k.strip, ColorUseRule = 0 }) end)
    pcall(function() s.title:SetText(FText(c.title or "")) end)
    pcall(function() s.body:SetText(FText(c.count > 1 and (c.text .. "  x" .. c.count) or c.text)) end)
    if c.progress then
        pcall(function() s.bar:SetPercent(math.max(0, math.min(1, c.progress))) end)
        pcall(function() s.bar:SetFillColorAndOpacity(k.strip) end)
        pcall(function() s.bar:SetVisibility(HIT_INVISIBLE) end)
    else
        pcall(function() s.bar:SetVisibility(COLLAPSED) end)
    end
    -- a live card whose text grew kept its old height and ran over the next card (kit 2026-10-28: "Asked to join"
    -- -> the 3-line "Joined ...'s world"): measured again now, not with the old text
    pcall(function() s.body:InvalidateLayoutAndVolatility() end)
    pcall(function() s.size:InvalidateLayoutAndVolatility() end)
end

function view.render()
    local filled = false
    for i, s in ipairs(view.slots) do
        local c = cards[i]
        if not c then
            if s.shows then pcall(function() s.size:SetVisibility(COLLAPSED) end); s.shows, s.alpha = nil, nil end
        else
            if dirty or s.shows ~= c then
                fill(s, c)
                filled = true
                if not s.shows then pcall(function() s.size:SetVisibility(HIT_INVISIBLE) end) end
                s.shows = c
            end
            local a = math.max(0, math.min(1, (clock - c.shown) / FADE_IN, (c.till - clock) / FADE_OUT))
            if a ~= s.alpha then s.alpha = a; pcall(function() s.size:SetRenderOpacity(a) end) end
        end
    end
    -- (the stack lays its cards out again with their new heights this frame)
    if filled and util.valid(view.w) then pcall(function() view.w:ForceLayoutPrepass() end) end
    dirty = false
end

-- the game's pop-up, one at a time (no cards here)
function view.legacy()
    if clock < view.legacy_next then return end
    local c
    for _, x in ipairs(cards) do if not x.legacy_done then c = x; break end end
    if not c then return end
    c.legacy_done = true
    view.legacy_next = clock + 1.5
    local p = game.player()
    local col = KINDS[c.kind].strip
    local ok, err = pcall(function() p:CreateNotificationUI(FText((c.title or "SurrounSync") .. ": " .. c.text), nil, col, duration(c)) end)
    if not ok then
        enabled = false
        log.warn("notify: the game's notification pop-up failed too (" .. tostring(err) .. ") - messages go to the log only")
    end
end

local function view_ok()
    if view.broken then return false end
    local pc
    pcall(function() pc = game.controller() end)
    if not util.valid(pc) then return false end
    if util.valid(view.w) and view.built_for == util.addr(pc) then return true end
    view.w, view.slots, dirty = nil, {}, true
    local ok, built = pcall(view.build)
    if not ok then
        view.broken = true
        log.warn("notify: couldn't build the message cards (" .. tostring(built) .. ") - using the game's pop-up")
        return false
    end
    return built == true
end

function notify.tick(dt)
    clock = clock + (dt or 1 / 30)
    for i = #cards, 1, -1 do
        if clock >= cards[i].till then
            local c = table.remove(cards, i)
            if not c.key then recent[c.text] = clock end
            dirty = true
        end
    end
    for t, at in pairs(recent) do if clock - at >= REPEAT_S then recent[t] = nil end end
    while #cards < MAX_CARDS and #waiting > 0 do put_on_screen(table.remove(waiting, 1)) end
    if not util.valid(game.player()) then return end
    if #cards == 0 and not util.valid(view.w) then return end   -- (nothing to show: no widget needed yet)
    if view_ok() then util.safe(view.render, "notify.render")
    elseif view.broken then view.legacy() end
end

-- the message history in a box (names.lua's): newest last
function notify.open_history()
    local lines = {}
    for i = math.max(1, #history - 14), #history do
        local h = history[i]
        lines[#lines + 1] = h.at .. "  " .. h.text
    end
    local ok = pcall(function()
        require("mirror.names").ask({ title = "MESSAGES (last " .. #lines .. ")", message = #lines > 0 and table.concat(lines, "\n")
            or "No messages yet.", ok = "CLOSE", clear = false, cancel = false, cursor = true, done = function() end })
    end)
    if not ok then log.info("notify: the message history couldn't open") end
end

function notify.init()
    game.keybind("F9", { ModifierKey.CONTROL }, function() util.safe(notify.open_history, "notify.history") end)
    -- (a load removes the old world's widgets: the next message builds the cards again)
    game.on_world_reset(function() view.w, view.slots, view.built_for, dirty = nil, {}, nil, true end)
end

-- tests: the logic without the engine
notify._test = { cards = function() return cards end, waiting = function() return waiting end, view = view,
                 reset = function() cards, waiting, recent, history, clock, dirty = {}, {}, {}, {}, 0.0, true end }

return notify
