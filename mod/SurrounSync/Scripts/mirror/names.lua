-- Custom backpack names: hover one of your backpacks and press F2 -> rename box; hovering any backpack shows its name.
-- (A RENAME row next to the game's right-click menu crashed the game on paint through three fixes - removed 2026-10-24.)
-- Names are kept per item (its UniqueServerID) in mirror_item_names.txt next to the game, and travel with the item
-- wherever the mod copies it to the other game (jig.encode/decode carry them), so both players see the same name.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local notify = require("mirror.notify")

local names = {}

local FILE = "mirror_item_names.txt"
local MAX_LEN, MAX_NAMES = 32, 500
local UMG = "/Script/UMG."
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"
local SHELL = "/Game/JigSInventory/Jigsaw/Widgets/BP_StatTextW.BP_StatTextW_C"
local TOOLTIP = "/Game/JigSInventory/Jigsaw/Widgets/HoverDrag/Hover/OnHoverTooltipWidget.OnHoverTooltipWidget_C:Update"
local JIG_COMP = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"
local BACKPACKS = "/Equipment/Backpacks/"
local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local BLACK = { R = 0, G = 0, B = 0, A = 1 }

local store, count, loaded = {}, 0, false
local popup = nil     -- { w, box, save, clear, cancel, uid }
local clicks = {}
local where = {}      -- named item uid -> { holder, slot, cell, da }: where it last sat (see names.moved)
local last_move = -100.0  -- os.clock() of the last inventory move (the tooltip hook stays out of the frames after it)

local function clean(s)
    s = tostring(s or ""):gsub("[%c|;,%%]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return util.utf8_cut(s, MAX_LEN)
end

local function load_file()
    loaded = true
    local f = io.open(FILE, "r")
    -- a crash between save_file's remove and rename leaves only the finished .tmp
    if not f and os.rename(FILE .. ".tmp", FILE) then f = io.open(FILE, "r") end
    if not f then return end
    for line in f:lines() do
        local uid, name = line:match("^(%-?%d+_%-?%d+_%-?%d+_%-?%d+)\t(.+)$")
        if uid and count < MAX_NAMES then store[uid] = name; count = count + 1 end
    end
    f:close()
end

local function save_file()
    local f = io.open(FILE .. ".tmp", "w")
    if not f then log.warn("names: can't write " .. FILE); return end
    for uid, name in pairs(store) do f:write(uid, "\t", name, "\n") end
    f:close()
    os.remove(FILE)
    os.rename(FILE .. ".tmp", FILE)
end

function names.get(uid)
    if not loaded then load_file() end
    return uid and store[uid] or nil
end

-- name nil/"" clears it. Returns true when something changed.
function names.set(uid, name, quiet)
    if not uid then return false end
    if not loaded then load_file() end
    name = name and clean(name) or ""
    if name == "" then name = nil end
    if store[uid] == name then return false end
    if name and not store[uid] then
        if count >= MAX_NAMES then log.warn("names: " .. MAX_NAMES .. " names kept - not adding more"); return false end
        count = count + 1
    elseif not name then count = count - 1 end
    store[uid] = name
    if not name then where[uid] = nil end
    save_file()
    if not quiet then log.info("names: " .. uid .. " -> " .. tostring(name)) end
    return true
end

-- The game gives an item - and everything inside it - brand-new UIDs whenever it comes out of a container
-- (BP_JigComponent RemoveGetInfo: every drop and every move to another inventory/container), so a name kept
-- under the old UID would be lost. where[uid] (top of the file) remembers where each named item last sat (the
-- UID of the item holding it, its compartment and cell) so names inside a moved backpack can follow too.

-- note where the named items in comp sit (cheap when nothing is named)
function names.note(comp)
    if not loaded then load_file() end
    if count == 0 or not util.valid(comp) then return end
    for _, h in ipairs(require("mirror.jig").contents_of(comp)) do
        if store[h.uid] then where[h.uid] = { holder = h.holder, slot = h.slot, cell = h.cell, da = h.da } end
    end
end

-- old -> new: an item got new UIDs; comp holds its contents now (the dropped pickup, or the inventory it went to)
function names.moved(old, new, comp)
    if not loaded then load_file() end
    if count == 0 or not old or not new or old == new then return end
    local list = nil
    local changed = false
    local function carry(o, n, depth)
        if store[o] and not store[n] then
            store[n], store[o] = store[o], nil
            where[n], where[o] = where[o], nil
            changed = true
            log.info("names: " .. o .. " got a new UID " .. n .. " - name \"" .. store[n] .. "\" kept")
        end
        if depth > 6 then return end
        local kids = {}
        for uid, w in pairs(where) do if w.holder == o then kids[#kids + 1] = uid end end
        if #kids == 0 then return end
        list = list or (util.valid(comp) and require("mirror.jig").contents_of(comp)) or {}
        for _, k in ipairs(kids) do
            local w, hit, same_da, n_da = where[k], nil, nil, 0
            for _, h in ipairs(list) do
                if h.holder == n and h.da == w.da then
                    n_da = n_da + 1
                    same_da = h
                    if h.slot == w.slot and h.cell == w.cell then hit = h end
                end
            end
            hit = hit or (n_da == 1 and same_da) or nil
            if hit then
                w.holder = n
                carry(k, hit.uid, depth + 1)
            end
        end
    end
    carry(old, new, 0)
    if changed then save_file() end
end

-- Handle Comp to Comp Move ran (UE4SS calls this after it): the item now sits in To at ToContainer/ToIndex
local function on_comp_move(From, To, ItemUID, ToIndex, ToContainer)
    last_move = os.clock()
    if count == 0 then return end
    local old, dest, cell
    pcall(function() old = string.format("%d_%d_%d_%d", ItemUID.A, ItemUID.B, ItemUID.C, ItemUID.D) end)
    local kids = false
    for _, w in pairs(where) do if w.holder == old then kids = true; break end end
    if not (old and (store[old] or kids)) then return end
    pcall(function() dest = string.format("%d_%d_%d_%d", ToContainer.A, ToContainer.B, ToContainer.C, ToContainer.D) end)
    pcall(function() cell = ToIndex end)
    if not (old and dest and util.valid(To)) then return end
    for _, h in ipairs(require("mirror.jig").contents_of(To)) do
        if h.mother == dest and h.cell == cell then
            if h.uid ~= old then names.moved(old, h.uid, To) end
            if store[h.uid] then where[h.uid] = { holder = h.holder, slot = h.slot, cell = h.cell, da = h.da } end
            return
        end
    end
end

-- For item lists and event lines: a name as one field without , ; | or spaces
function names.encode(name) return (name:gsub("[%%,;| ]", function(c) return string.format("%%%02X", c:byte()) end)) end
function names.decode(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

-- JSI_Slot:GetUniqueID just returns self.ItemUniqueID: read the property, no out-param call
-- Every widget is checked before a call: a NULL wrapper (a tooltip torn down, a text or slot not built yet) is a native crash
-- (crash report 2026-10-25: two runs died in the tooltip hook, AV reading 0x34, while the player hovered items)
local function child(w, key)
    local c
    pcall(function() c = w[key] end)
    return util.valid(c) and c or nil
end

local function uid_of(item)
    local ok, s = pcall(function()
        local g = item.ItemUniqueID
        return string.format("%d_%d_%d_%d", g.A, g.B, g.C, g.D)
    end)
    return ok and s or nil
end

local function is_backpack(item)
    -- (an item without a data asset holds a wrapper around NULL: GetFullName on it is a native crash pcall can't catch)
    local da, p
    pcall(function() da = item.JigDataAsset end)
    if not util.valid(da) then return false end
    pcall(function() p = da:GetFullName() end)
    return type(p) == "string" and p:find(BACKPACKS, 1, true) ~= nil
end

local function new(cls, outer)
    local o
    pcall(function() o = StaticConstructObject(StaticFindObject(UMG .. cls), outer) end)
    if not util.valid(o) then error("couldn't create " .. cls) end
    return o
end

local function label(outer, s, font, size)
    local t = new("TextBlock", outer)
    pcall(function() t:SetText(FText(s)) end)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = WHITE, ColorUseRule = 0 }) end)
    -- Start from the new TextBlock's own complete font and change fields in it (as nametag/journal_tab do).
    -- A partly filled table leaves the rest of FSlateFontInfo (its CompositeFont pointer) as junk: the menu
    -- crashed on its next paint, right after the right-click.
    if font or size then
        pcall(function()
            local f = t.Font
            if font and font.FontObject then f.FontObject = font.FontObject end
            if font and font.TypefaceFontName then f.TypefaceFontName = font.TypefaceFontName end
            f.Size = size or (font and font.Size) or f.Size
            t:SetFont(f)
        end)
    end
    return t
end

local function clicked(b)
    local pressed, hov = false, false
    pcall(function() pressed = b:IsPressed() end)
    pcall(function() hov = b:IsHovered() end)
    local was = clicks[b]
    clicks[b] = pressed
    return was and not pressed and hov
end

local function close_popup()
    if popup then
        pcall(function() popup.w:RemoveFromParent() end)
        if popup.cursor then
            local pc = game.controller()
            pcall(function() util.cdo(WBL):SetInputMode_GameOnly(pc, false) end)
            pcall(function() pc.bShowMouseCursor = false end)
        end
    end
    popup = nil
end

-- The rename box. o = { title, text, hint, font, cursor (true outside menus: give the mouse to the box), done(name),
-- multiline (raw text, Enter makes a new line), ok = button label (default SAVE), clear = label or false (no button),
-- message (text instead of an input box), cancel = false (no CANCEL: it stays until the ok button) }
local function open_box(o)
    close_popup()
    local wbl, pc, shell = util.cdo(WBL), game.controller(), StaticFindObject(SHELL)
    if not (wbl and util.valid(pc) and util.valid(shell)) then notify.show("Renaming isn't ready yet - try again.", "warn"); return end
    local w
    pcall(function() w = wbl:Create(pc, shell, pc) end)
    if not util.valid(w) then notify.show("Couldn't open the rename box.", "warn"); return end
    local tree = w.WidgetTree
    local canvas = new("CanvasPanel", tree)
    tree.RootWidget = canvas
    local border = new("Border", tree)
    pcall(function() border:SetBrushColor({ R = 0.03, G = 0.03, B = 0.03, A = 0.92 }) end)
    pcall(function() border:SetPadding({ Left = 18, Top = 14, Right = 18, Bottom = 14 }) end)
    local slot
    pcall(function() slot = canvas:AddChildToCanvas(border) end)
    pcall(function()
        slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.4 }, Maximum = { X = 0.5, Y = 0.4 } })
        slot:SetAlignment({ X = 0.5, Y = 0.5 })
        slot:SetAutoSize(true)
    end)
    local vb = new("VerticalBox", tree)
    pcall(function() border:SetContent(vb) end)
    local font = o.font
    vb:AddChildToVerticalBox(label(tree, o.title, font, 20))
    local box = o.message and label(tree, o.message, font, 16)
        or new(o.multiline and "MultiLineEditableTextBox" or "EditableTextBox", tree)
    -- black text on the light box, typing or not (the default focused/unfocused colours are a pale grey),
    -- like the handbook's own input boxes; set before the box is first drawn
    local ink = { SpecifiedColor = BLACK, ColorUseRule = 0 }
    pcall(function() box.WidgetStyle.ForegroundColor = ink end)
    pcall(function() box.WidgetStyle.FocusedForegroundColor = ink end)
    pcall(function() box.WidgetStyle.TextStyle.ColorAndOpacity = ink end)
    pcall(function() box:SetForegroundColor(BLACK) end)
    pcall(function() box:SetText(FText(o.text or "")) end)
    pcall(function() box:SetHintText(FText(o.hint or "")) end)
    if o.message then pcall(function() box:SetAutoWrapText(true) end); pcall(function() box.WrapTextAt = 560 end) end
    pcall(function() box.MinimumDesiredWidth = o.multiline and 520 or 320 end)
    local bs
    pcall(function() bs = vb:AddChildToVerticalBox(box) end)
    pcall(function() bs:SetPadding({ Left = 0, Top = 10, Right = 0, Bottom = 10 }) end)
    local row = new("HorizontalBox", tree)
    vb:AddChildToVerticalBox(row)
    local function btn(s)
        local b = new("Button", tree)
        pcall(function() b:SetBackgroundColor({ R = 0.25, G = 0.25, B = 0.25, A = 1 }) end)
        pcall(function() b:SetContent(label(tree, s, font, 16)) end)
        local hs
        pcall(function() hs = row:AddChildToHorizontalBox(b) end)
        pcall(function() hs:SetPadding({ Left = 0, Top = 0, Right = 10, Bottom = 0 }) end)
        return b
    end
    local save = btn(o.ok or "SAVE")
    local clear = o.clear ~= false and btn(o.clear or "CLEAR NAME") or nil
    popup = { w = w, box = box, done = o.done, cursor = o.cursor, raw = o.multiline == true or o.message ~= nil,
              save = save, clear = clear, cancel = o.cancel ~= false and btn("CANCEL") or nil }
    pcall(function() w:AddToViewport(50) end)
    if o.cursor then
        pcall(function() wbl:SetInputMode_UIOnlyEx(pc, box, 0, false) end)
        pcall(function() pc.bShowMouseCursor = true end)
    end
    if not o.message then pcall(function() box:SetKeyboardFocus() end) end
    return true
end
names.ask = open_box
function names.asking() return popup ~= nil end

local function open_popup(uid, font)
    if not open_box({ title = "NAME THIS BACKPACK", text = names.get(uid), hint = "e.g. Med kit bag", font = font,
                      done = function(name)
                          names.set(uid, name)
                          local comp
                          pcall(function() comp = game.player().BP_JigComponent end)
                          util.safe(names.note, "names.note", comp)
                          name = names.get(uid)
                          notify.show(name and ("Backpack named \"" .. name .. "\".") or "Backpack name cleared.", "good")
                      end }) then return end
    log.info("names: rename box open for " .. uid)
end

local function commit(name)
    if not popup then return end
    local done, popup_raw = popup.done, popup.raw
    if name == nil then
        pcall(function() name = popup.box:GetText():ToString() end)
    end
    close_popup()
    util.safe(done, "names.done", popup_raw and tostring(name or "") or clean(name))
end
names.clean = clean

local noted_at = -100.0
local hovered = nil   -- { uid, at }: the backpack under the mouse and when its tooltip last updated (F2 renames it)
-- the hint goes at the end of the small description text, not next to the name
local HINT = "Rename (F2)"
local COLLAPSED, SHOWN = 1, 4   -- ESlateVisibility Collapsed / SelfHitTestInvisible
-- The tooltip's Update runs every frame while an item is hovered, also in the frames where the game is moving
-- items around. Crash reports (DBG-20261026-001) all died inside this hook while it walked a big inventory: the
-- cause was UE4SS's ForEach letting Lua collect a temporary array mid-loop (fixed for the whole mod: util.each).
-- The hook stays cheap anyway: a frame only compares the tooltip and item addresses; the item is looked at once
-- per newly hovered item and never in the moment after a move.
-- Update(ItemRef) is hooked before it runs: the widget's own ItemRef then still holds the item it showed last,
-- which a move may have destroyed already - reading it was the native crash 0.13.3 still had (property lookup on
-- freed memory, IsValid can't tell). Only the item the game passes in now is read.
local QUIET_AFTER_MOVE = 0.4
local seen = { tip = nil, item = nil, info = nil }   -- info = { uid, bag } of the hovered item
local function forget_hover() seen.tip, seen.item, seen.info, hovered = nil, nil, nil, nil end
local function on_tooltip(self, ref)
    if os.clock() - last_move < QUIET_AFTER_MOVE then forget_hover(); return end
    local tip = util.addr(self)
    if not tip or not ref then return end
    local item
    pcall(function() item = ref:get() end)
    local at = item and util.addr(item) or nil
    if tip ~= seen.tip or at ~= seen.item then
        seen.tip, seen.item, seen.info, hovered = tip, at, nil, nil
        local uid = at and uid_of(item)
        -- (no "is it mine" inventory walk here: it read every container from inside the game's tooltip Update,
        -- and opening a backpack while hovering it crashed there every time - any hovered backpack gets the hint)
        if uid then seen.info = { uid = uid, bag = is_backpack(item) } end
    end
    local info = seen.info
    if not info then return end
    -- (the game's Update writes the item's own name and description again every frame; the name is a plain
    -- table lookup, so a rename shows at once)
    local name = names.get(info.uid)
    if name then
        local title = child(self, "NameText")
        if title then pcall(function() title:SetText(FText(name)) end) end
    end
    if info.bag then
        -- (the game passes the inventory slot as ItemRef: F2 later asks that slot whether it's still hovered)
        hovered = hovered or { uid = info.uid, slot = item, slot_at = at, slot_cls = util.class_name(item) }
        hovered.at = os.clock()
        local descr = child(self, "descr")
        local vis
        if descr then pcall(function() vis = descr:GetVisibility() end) end
        if descr and vis == COLLAPSED then
            -- no description (every backpack): the game collapses the text and its divider and leaves stale
            -- text in it, so the hint becomes the whole text and both are shown
            pcall(function() descr:SetText(FText(HINT)) end)
            pcall(function() descr:SetVisibility(SHOWN) end)
            local divider = child(self, "Divider")
            if divider then pcall(function() divider:SetVisibility(SHOWN) end) end
        elseif descr then pcall(function()
            local d = descr:GetText():ToString() or ""
            if not d:find(HINT, 1, true) then descr:SetText(FText(d == "" and HINT or (d .. "\n" .. HINT))) end
        end) end
    end
end
local function my_comp()
    local p, comp = game.player(), nil
    if not util.valid(p) then return nil end
    pcall(function() comp = p.BP_JigComponent end)
    return util.valid(comp) and comp or nil
end
-- The slot's tooltip binding runs Update only when Slate asks for the tooltip (when it opens, after a click),
-- not every frame: F2 while just hovering found the last Update too old and did nothing - it only worked
-- right after clicking the bag (player report 2026-10-27). So a stale Update still counts while the same slot
-- (same address, class and name check: a freed one's address can come back as another) says it's hovered.
local function still_hovered(h)
    if os.clock() - (h.at or 0) <= 0.3 then return true end
    local s = h.slot
    if not (util.valid(s) and util.addr(s) == h.slot_at and h.slot_cls and util.class_name(s) == h.slot_cls) then return false end
    local yes = false
    pcall(function() yes = s:IsHovered() == true end)
    return yes
end
local function rename_hovered()
    local h = hovered
    if not h or not still_hovered(h) then hovered = nil; return end
    open_popup(h.uid, nil)
end

-- The inventory's backpack list (top right button): the game creates one 2_ContainerListTitle row per bag with
-- the bag's UID set, and the row's Construct writes the asset's name into ItemName. UE4SS runs a Blueprint
-- hook after the function body, so a named bag gets its own name written over that.
local LIST_ROW = "/Game/Inventory/Widgets/ContainerViewer/2_ContainerListTitle.2_ContainerListTitle_C:Construct"
local function on_list_row(row)
    if not loaded then load_file() end
    if count == 0 then return end
    local uid
    pcall(function()
        local g = row.UID
        uid = string.format("%d_%d_%d_%d", g.A, g.B, g.C, g.D)
    end)
    local name = uid and store[uid]
    if not name then return end
    local text = child(row, "ItemName")
    if text then pcall(function() text:SetText(FText(name)) end) end
end
local list_row_fn = function(self) util.safe(on_list_row, "names.list_row", self:get()) end

-- the inventory widgets load the first time the inventory opens: keep asking until the hooks took
local hook_in = 0.0
local tooltip_fn = function(self, ItemRef) util.safe(on_tooltip, "names.tooltip", self:get(), ItemRef) end
local move_fn = function(self, From, To, ItemUID, FinalRotation, ToIndex, ToContainer)
    util.safe(function() on_comp_move(From:get(), To:get(), ItemUID:get(), ToIndex:get(), ToContainer:get()) end, "names.move")
end
local COMP_MOVE = JIG_COMP .. ":Handle Comp to Comp Move"

local enabled = true
function names.init(c)
    enabled = not (c and c.backpack_names == false)
    if not enabled then log.info("names: backpack names off (mirror_settings.txt) - no inventory hooks"); return end
    game.keybind("RETURN", nil, function() if popup and not popup.raw then commit(nil) end end, function() return popup ~= nil end)
    game.keybind("F2", nil, function() if not popup then util.safe(rename_hovered, "names.f2") end end,
        function() return hovered ~= nil end)
end

function names.tick(dt)
    if not enabled then return end
    hook_in = hook_in - (dt or 0)
    if hook_in <= 0 then
        hook_in = 1.0
        util.ensure_hook(TOOLTIP, tooltip_fn)
        util.ensure_hook(COMP_MOVE, move_fn)
        util.ensure_hook(LIST_ROW, list_row_fn)
    end
    -- where my named items sit (names.moved needs it), refreshed while I'm handling my backpacks - from the tick,
    -- not from inside the tooltip's Update
    if count > 0 and hovered and os.clock() - (hovered.at or 0) < 1.0 and os.clock() - noted_at > 2.0
            and os.clock() - last_move >= QUIET_AFTER_MOVE then
        noted_at = os.clock()
        names.note(my_comp())
    end
    if popup then
        if clicked(popup.save) then commit(nil)
        elseif popup and popup.clear and clicked(popup.clear) then commit("")
        elseif popup and popup.cancel and clicked(popup.cancel) then close_popup() end
    end
end

names._open = function(uid) open_popup(uid) end  -- devtest
function names.forget() clicks, where = {}, {}; forget_hover(); close_popup() end
game.on_world_reset(names.forget)

return names
