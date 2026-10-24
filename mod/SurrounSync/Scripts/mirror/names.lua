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
local MENU = "/Game/JigSInventory/Jigsaw/Widgets/JContextMenu/JigContextMenuComp.JigContextMenuComp_C:OnJigItemRightClick"
local JIG_COMP = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"
local BACKPACKS = "/Equipment/Backpacks/"
local WHITE = { R = 1, G = 1, B = 1, A = 1 }

local store, count, loaded = {}, 0, false
local menu = nil      -- { uid, canvas, w, btn, bg }: our RENAME row while the game's right-click menu is open
local popup = nil     -- { w, box, save, clear, cancel, uid }
local clicks = {}

local function clean(s)
    s = tostring(s or ""):gsub("[%c|;,%%]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #s > MAX_LEN then s = s:sub(1, MAX_LEN) end
    return s
end

local function load_file()
    loaded = true
    local f = io.open(FILE, "r")
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
    save_file()
    if not quiet then log.info("names: " .. uid .. " -> " .. tostring(name)) end
    return true
end

-- For item lists and event lines: a name as one field without , ; | or spaces
function names.encode(name) return (name:gsub("[%%,;| ]", function(c) return string.format("%%%02X", c:byte()) end)) end
function names.decode(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

-- JSI_Slot:GetUniqueID just returns self.ItemUniqueID: read the property, no out-param call
local function uid_of(item)
    local ok, s = pcall(function()
        local g = item.ItemUniqueID
        return string.format("%d_%d_%d_%d", g.A, g.B, g.C, g.D)
    end)
    return ok and s or nil
end

local function is_backpack(item)
    local p
    pcall(function() p = item.JigDataAsset:GetFullName() end)
    return type(p) == "string" and p:find(BACKPACKS, 1, true) ~= nil
end

local function mine(uid)
    local p = game.player()
    if not util.valid(p) then return false end
    local jig = require("mirror.jig")
    local comp
    pcall(function() comp = p.BP_JigComponent end)
    if not util.valid(comp) then pcall(function() comp = p:GetComponentByClass(StaticFindObject(JIG_COMP)) end) end
    if not util.valid(comp) then return false end
    for _, h in ipairs(jig.contents_of(comp)) do if h.uid == uid then return true end end
    return false
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
-- multiline (raw text, Enter makes a new line), ok = button label (default SAVE), clear = label or false (no button) }
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
    local box = new(o.multiline and "MultiLineEditableTextBox" or "EditableTextBox", tree)
    pcall(function() box:SetText(FText(o.text or "")) end)
    pcall(function() box:SetHintText(FText(o.hint or "")) end)
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
    popup = { w = w, box = box, done = o.done, cursor = o.cursor, raw = o.multiline == true,
              save = save, clear = clear, cancel = btn("CANCEL") }
    pcall(function() w:AddToViewport(50) end)
    if o.cursor then
        pcall(function() wbl:SetInputMode_UIOnlyEx(pc, box, 0, false) end)
        pcall(function() pc.bShowMouseCursor = true end)
    end
    pcall(function() box:SetKeyboardFocus() end)
    return true
end
names.ask = open_box

local function open_popup(uid, font)
    if not open_box({ title = "NAME THIS BACKPACK", text = names.get(uid), hint = "e.g. Med kit bag", font = font,
                      done = function(name)
                          names.set(uid, name)
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

-- The RENAME row: our own widget drawn right under the game's right-click menu, same width, row height and font,
-- shown while that menu is open for one of my backpacks. The game's menu is only READ: adding a button to its
-- OptionsVB crashed both games on the next paint, every time.
local WLL = "/Script/UMG.Default__WidgetLayoutLibrary"
local ROW_BG = { R = 0.02, G = 0.02, B = 0.02, A = 0.86 }
local ROW_HOVER = { R = 0.16, G = 0.16, B = 0.16, A = 0.95 }
local function close_menu()
    if menu then pcall(function() menu.w:RemoveFromParent() end) end
    menu = nil
end

-- Where the game's menu is and how its options look (all reads). nil until it has been laid out.
local function menu_look(canvas)
    local w, pos, size, row, font
    pcall(function() w = canvas.JigContextMenuW end)
    if not util.valid(w) then return nil end
    pcall(function() local p = w.Slot:GetPosition(); pos = { X = p.X, Y = p.Y } end)
    pcall(function() local d = w:GetDesiredSize(); size = { X = d.X, Y = d.Y } end)
    pcall(function()
        local c = w.OptionsVB:GetChildAt(0)
        local d = c:GetDesiredSize()
        row = d.Y > 4 and d.Y or nil
        local t = c:GetContent()
        local f = t.Font
        font = { FontObject = f.FontObject, TypefaceFontName = f.TypefaceFontName, Size = f.Size }
    end)
    if not (pos and size and size.X > 4 and size.Y > 4) then return nil end
    return { pos = pos, size = size, row = row or 34, font = font }
end

local function show_rename(m, look)
    local wbl, pc, shell = util.cdo(WBL), game.controller(), StaticFindObject(SHELL)
    if not (wbl and util.valid(pc) and util.valid(shell)) then return false end
    local w
    pcall(function() w = wbl:Create(pc, shell, pc) end)
    if not util.valid(w) then return false end
    local tree = w.WidgetTree
    local root = new("CanvasPanel", tree)
    tree.RootWidget = root
    local bg = new("Border", tree)
    pcall(function() bg:SetBrushColor(ROW_BG) end)
    pcall(function() bg:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 }) end)
    local btn = new("Button", tree)
    pcall(function() btn:SetBackgroundColor({ R = 1, G = 1, B = 1, A = 0 }) end)
    local font = look and look.font
    pcall(function()
        local cs = btn:SetContent(label(tree, "Rename", font, font and font.Size or 16))
        cs:SetHorizontalAlignment(0)
        cs:SetVerticalAlignment(2)
        cs:SetPadding({ Left = 10, Top = 0, Right = 10, Bottom = 0 })
    end)
    pcall(function() bg:SetContent(btn) end)
    pcall(function() bg:SetHorizontalAlignment(0); bg:SetVerticalAlignment(0) end)
    local slot
    pcall(function() slot = root:AddChildToCanvas(bg) end)
    pcall(function()
        slot:SetAutoSize(false)
        if look then
            slot:SetPosition({ X = look.pos.X + 0.0, Y = look.pos.Y + look.size.Y })
            slot:SetSize({ X = look.size.X + 0.0, Y = look.row + 0.0 })
        else
            local mp = util.cdo(WLL):GetMousePositionOnViewport(pc)
            slot:SetPosition({ X = mp.X + 0.0, Y = mp.Y - 44.0 })
            slot:SetSize({ X = 200.0, Y = 38.0 })
        end
    end)
    pcall(function() w:AddToViewport(60) end)
    m.w, m.btn, m.bg, m.hover = w, btn, bg, false
    return true
end

local function add_rename(self)
    close_menu()
    local item, canvas
    pcall(function() item = self.CurrentItemRef end)
    pcall(function() canvas = self.ContextMRef end)
    if not (util.valid(item) and util.valid(canvas)) then return end
    local uid = uid_of(item)
    if not (uid and is_backpack(item) and mine(uid)) then return end
    -- shown once the game's menu has been laid out (its size is known a frame or two later)
    menu = { uid = uid, canvas = canvas, waited = 0.0 }
end

local function menu_tick(dt)
    local m = menu
    local open = false
    pcall(function() open = util.valid(m.canvas) and m.canvas:IsInViewport() end)
    if not m.w then
        if not open then menu = nil; return end
        m.waited = m.waited + (dt or 0)
        local look = menu_look(m.canvas)
        if look or m.waited > 0.4 then
            if not show_rename(m, look) then menu = nil end
        end
        return
    end
    -- react on press: the game shuts its menu as soon as the mouse goes down outside it
    local pressed, hov = false, false
    pcall(function() pressed = m.btn:IsPressed() end)
    pcall(function() hov = m.btn:IsHovered() end)
    if pressed then
        local uid = m.uid
        close_menu()
        pcall(function() m.canvas:RemoveFromParent() end)
        open_popup(uid, nil)
        return
    end
    if hov ~= m.hover then
        m.hover = hov
        pcall(function() m.bg:SetBrushColor(hov and ROW_HOVER or ROW_BG) end)
    end
    if not open and not hov then close_menu() end
end

local pending_menu = nil   -- the JigContextMenuComp that just got a right-click
local function on_right_click(self) pending_menu = self end

local hovered = nil   -- { tip = the tooltip widget, uid }: my backpack under the mouse (F2 renames it)
-- the hint goes at the end of the small description text, not next to the name
local HINT = "(F2: rename)"
local function on_tooltip(self)
    local item
    pcall(function() item = self.ItemRef end)
    if not util.valid(item) then return end
    local uid = uid_of(item)
    local name = names.get(uid)
    if name then pcall(function() self.NameText:SetText(FText(name)) end) end
    if uid and is_backpack(item) and mine(uid) then
        hovered = { tip = self, uid = uid }
        pcall(function()
            local d = self.descr:GetText():ToString() or ""
            if not d:find(HINT, 1, true) then self.descr:SetText(FText(d == "" and HINT or (d .. "\n" .. HINT))) end
        end)
    end
end
local function rename_hovered()
    local h = hovered
    if not (h and util.valid(h.tip)) then return end
    -- (the tooltip is never "in the viewport" - it lives in the inventory's hover layer)
    local shown = true
    pcall(function() shown = h.tip:IsVisible() end)
    if not shown then log.info("names: F2 - the backpack tooltip is closed"); hovered = nil; return end
    local item
    pcall(function() item = h.tip.ItemRef end)
    if not (util.valid(item) and uid_of(item) == h.uid) then log.info("names: F2 - hovering another item now"); return end
    open_popup(h.uid, nil)
end

-- the inventory widgets load the first time the inventory opens: keep asking until both hooks took
local hook_in = 0.0
local tooltip_fn = function(self) util.safe(on_tooltip, "names.tooltip", self:get()) end
local menu_fn = function(self) util.safe(on_right_click, "names.menu", self:get()) end

function names.init()
    game.keybind("RETURN", nil, function() if popup and not popup.raw then commit(nil) end end, function() return popup ~= nil end)
    game.keybind("F2", nil, function() if not popup then util.safe(rename_hovered, "names.f2") end end,
        function() return hovered ~= nil end)
end

function names.tick(dt)
    hook_in = hook_in - (dt or 0)
    if hook_in <= 0 then
        hook_in = 1.0
        util.ensure_hook(TOOLTIP, tooltip_fn)
    end
    if pending_menu then
        local comp = pending_menu
        pending_menu = nil
        if util.valid(comp) then util.safe(add_rename, "names.menu", comp) end
    end
    if menu then util.safe(menu_tick, "names.menu_tick", dt) end
    if popup then
        if clicked(popup.save) then commit(nil)
        elseif popup and popup.clear and clicked(popup.clear) then commit("")
        elseif popup and clicked(popup.cancel) then close_popup() end
    end
end

names._open = function(uid) open_popup(uid) end  -- devtest
function names.forget() close_menu(); pending_menu, clicks, hovered = nil, {}, nil; close_popup() end
game.on_world_reset(names.forget)

return names
