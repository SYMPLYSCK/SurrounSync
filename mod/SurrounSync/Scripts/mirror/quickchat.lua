-- Quick chat: in a co-op or Realm session, "/" with the handbook closed opens a chat box in the bottom left.
-- Enter sends it like the CO-OP tab's SEND ("/goto ..." and the other commands run), Esc closes it. The last chat
-- lines show above the box, and the command tip while a "/" line is typed.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")

local quickchat = {}

local UMG = "/Script/UMG."
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"
local SHELL = "/Game/JigSInventory/Jigsaw/Widgets/BP_StatTextW.BP_StatTextW_C"
local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local GREY = { R = 0.75, G = 0.75, B = 0.75, A = 1 }
local BLACK = { R = 0, G = 0, B = 0, A = 1 }
local LINES = 5
local HINT = "Say something - / for commands - Esc closes"

-- configure{ active() = in a co-op or Realm session, send(text) -> true when sent, recent(n), tip(text) }
local ctx = nil
local box = nil          -- { w, input, lines = { TextBlock }, tip, shown = { text per line }, tip_text }
local want_open, bound = false, false

local function new(cls, outer)
    local o
    pcall(function() o = StaticConstructObject(StaticFindObject(UMG .. cls), outer) end)
    if not util.valid(o) then error("couldn't create " .. cls) end
    return o
end

local function label(outer, size, color)
    local t = new("TextBlock", outer)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = color or WHITE, ColorUseRule = 0 }) end)
    -- (change fields in the TextBlock's own complete font: a partly filled FSlateFontInfo crashed a paint, names.lua)
    pcall(function() local f = t.Font; f.Size = size; t:SetFont(f) end)
    return t
end

local function set(t, s)
    pcall(function() t:SetText(FText(s)) end)
end

local function build(w)
    local tree = w.WidgetTree
    local canvas = new("CanvasPanel", tree)
    tree.RootWidget = canvas
    local border = new("Border", tree)
    pcall(function() border:SetBrushColor({ R = 0.02, G = 0.02, B = 0.02, A = 0.72 }) end)
    pcall(function() border:SetPadding({ Left = 12, Top = 10, Right = 12, Bottom = 10 }) end)
    local slot = canvas:AddChildToCanvas(border)
    pcall(function()
        slot:SetAnchors({ Minimum = { X = 0.0, Y = 1.0 }, Maximum = { X = 0.0, Y = 1.0 } })
        slot:SetAlignment({ X = 0.0, Y = 1.0 })
        slot:SetPosition({ X = 24, Y = -160 })
        slot:SetAutoSize(true)
    end)
    local vb = new("VerticalBox", tree)
    pcall(function() border:SetContent(vb) end)
    local b = { w = w, lines = {}, shown = {} }
    for i = 1, LINES do
        b.lines[i] = label(tree, 16)
        vb:AddChildToVerticalBox(b.lines[i])
    end
    b.tip = label(tree, 14, GREY)
    pcall(function() b.tip:SetVisibility(1) end)
    vb:AddChildToVerticalBox(b.tip)
    local input = new("EditableTextBox", tree)
    -- black text on the light box, typing or not (as the handbook's and the rename box's inputs)
    local ink = { SpecifiedColor = BLACK, ColorUseRule = 0 }
    pcall(function() input.WidgetStyle.ForegroundColor = ink end)
    pcall(function() input.WidgetStyle.FocusedForegroundColor = ink end)
    pcall(function() input.WidgetStyle.TextStyle.ColorAndOpacity = ink end)
    pcall(function() input:SetForegroundColor(BLACK) end)
    pcall(function() input:SetHintText(FText(HINT)) end)
    pcall(function() input.MinimumDesiredWidth = 440 end)
    local is
    pcall(function() is = vb:AddChildToVerticalBox(input) end)
    pcall(function() is:SetPadding({ Left = 0, Top = 6, Right = 0, Bottom = 0 }) end)
    b.input = input
    return b
end

local function typed()
    local s = ""
    if box then pcall(function() s = box.input:GetText():ToString() end) end
    return s
end

local function refresh()
    local rec = ctx.recent(LINES)
    for i = 1, LINES do
        local h = rec[#rec - LINES + i]
        local s = h and ((h.who or "?") .. ": " .. (h.text or "")) or ""
        if box.shown[i] ~= s then box.shown[i] = s; set(box.lines[i], s) end
    end
    local tip = ctx.tip(typed()) or ""
    if tip ~= box.tip_text then
        box.tip_text = tip
        set(box.tip, tip)
        pcall(function() box.tip:SetVisibility(tip ~= "" and 4 or 1) end)
    end
end

local function close()
    if not box then return end
    local b = box
    box = nil
    pcall(function() b.w:RemoveFromParent() end)
    local pc = game.controller()
    pcall(function() util.cdo(WBL):SetInputMode_GameOnly(pc, false) end)
end

-- not over the handbook, the rename box, or anything that shows the mouse (inventory, pause menu, a trader)
local function can_open()
    if box or not (ctx and ctx.active()) then return false end
    local pl, pc = game.player(), game.controller()
    if not (util.valid(pl) and util.valid(pc)) then return false end
    local busy = false
    pcall(function() busy = pl["JournalOpen?"] == true end)
    if busy then return false end
    pcall(function() busy = pc.bShowMouseCursor == true end)
    if busy then return false end
    return not require("mirror.names").asking()
end

local function open()
    local wbl, pc, shell = util.cdo(WBL), game.controller(), StaticFindObject(SHELL)
    if not (wbl and util.valid(pc) and util.valid(shell)) then return end
    local w
    pcall(function() w = wbl:Create(pc, shell, pc) end)
    if not util.valid(w) then log.warn("quickchat: couldn't make the chat box"); return end
    local ok, b = pcall(build, w)
    if not ok then log.warn("quickchat: couldn't build the chat box (" .. tostring(b) .. ")"); return end
    box = b
    refresh()
    pcall(function() w:AddToViewport(45) end)
    -- the keys go to the box (no walking while typing), no mouse
    pcall(function() wbl:SetInputMode_UIOnlyEx(pc, b.input, 0, false) end)
    pcall(function() b.input:SetKeyboardFocus() end)
end

local function enter()
    if not box then return end
    local s = typed()
    if not s:find("%S") then close(); return end
    if ctx.send(s) then close(); return end
    -- (not sent, e.g. "one message a second": the text stays to send again)
    pcall(function() box.input:SetKeyboardFocus() end)
end

function quickchat.configure(c) ctx = c end
function quickchat.is_open() return box ~= nil end

function quickchat.tick(dt)
    if not bound then
        bound = true
        local is_open = function() return box ~= nil end
        game.keybind("OEM_TWO", nil, function() want_open = true end)
        game.keybind("RETURN", nil, enter, is_open)
        game.keybind("ESCAPE", nil, close, is_open)
    end
    if want_open then
        want_open = false
        if can_open() then open() end
    end
    if not box then return end
    if not ctx.active() or not util.valid(box.w) then close(); return end
    refresh()
end

-- a load tears the viewport down: the box went with the old world
game.on_world_reset(function() box = nil; want_open = false end)

return quickchat
