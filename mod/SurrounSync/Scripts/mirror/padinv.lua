-- Controller in the inventory: gamepad.lua hands the pad over while the cursor shows and an inventory grid is on
-- screen. JigSInventory's own pad support is an empty stub (BP_JigControllerSupport, JSIContainer.OnKeyDown
-- returns Unhandled), so this drives the grids itself. User 2026-10-31: "x will quick take a will allow you too grab
-- and then move with d pad too where you want and then lb rb rotate and when ur hovering over an item and the
-- dropdown menu pops up you can move up and down with d pad too interact with the items and then when u dpad left or
-- right it just moves too the next slot in the inventory".
--   D-pad   the next cell (out of the item under the cursor; at a grid's edge the nearest grid that way, never the
--           hotbar; left/right with nothing that way go on to the next row). The mouse follows, so the game's own
--           hover shows.
--   X       quick take: the game's Ctrl+click (loot -> your bag, your bag -> the open loot)
--   A       grab the item, D-pad to where it goes, A again to put it down; LB/RB turn it; B puts it back
--   LB/RB   (nothing held) the EQUIPMENT/CRAFTING and LOOT/VICINITY tabs
--   B       (nothing held, no menu) leaves the inventory
--   menu    landing on an item opens its right-click menu; D-pad down/up go through the options, A uses one,
--           left/right go on to the next slot, B closes it
-- Moves go through the game's own paths (EventOnInventoryAction: the handler of a mouse drop between containers;
-- OnItemStackRequest_Event; Context_TryEquip / TryUnequip), never straight to the SERVER_ calls.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")

local padinv = {}

local B = {
    up = "Gamepad_DPad_Up", down = "Gamepad_DPad_Down", left = "Gamepad_DPad_Left", right = "Gamepad_DPad_Right",
    a = "Gamepad_FaceButton_Bottom", b = "Gamepad_FaceButton_Right", x = "Gamepad_FaceButton_Left",
    lb = "Gamepad_LeftShoulder", rb = "Gamepad_RightShoulder",
}
local DIRS = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
padinv.REPEAT_FIRST, padinv.REPEAT_EVERY, padinv.SCAN_EVERY, padinv.MENU_PLACE = 0.35, 0.12, 0.5, 0.3
padinv.LAYOUT_EVERY, padinv.HOVER_MISSES = 2.0, 3

-- the slot border tints (the game tints drag targets the same way: SlotBorder SetBrushColor)
local CURSOR = { R = 1.0, G = 0.75, B = 0.1, A = 1.0 }
local FITS = { R = 0.2, G = 0.85, B = 0.2, A = 1.0 }
local NO_FIT = { R = 0.9, G = 0.15, B = 0.1, A = 1.0 }
local OPTION = { R = 1.0, G = 0.75, B = 0.1, A = 1.0 }

-- the right-click menu's buttons (JigContextMenuW properties) and the number in their click handler's name
padinv.OPTIONS = {
    { "InspectBtn", 8 }, { "OpenBtn", 9 }, { "UseBtn", 10 }, { "PlaceBtn", 11 }, { "EquipBtn", 12 },
    { "UnequipBtn", 13 }, { "UnloadBtn", 14 }, { "ConsumeBtn", 15 }, { "ConsumeCannedBtn", 16 }, { "DrinkBtn", 17 },
    { "FillBtn", 18 }, { "ReadBtn", 19 }, { "RipClothingBtn", 20 }, { "ScanLaptopBtn", 21 },
    { "RepairWeaponBtn", 22, "RepairBtn" }, { "DropBtn", 23 }, { "DestroyBtn", 24 }, { "ShowAttachmentsBtn", 0 },
    { "RepairArmorBtn", 1 }, { "PlayMusicBtn", 2 }, { "OpenLootBoxBtn", 3 }, { "ShowTacticalAttachmentsBtn", 4 },
    { "SmokeBtn", 5 }, { "RepairAttachmentBtn", 6 },
}
local function handler(o)
    return "BndEvt__JigContextMenuW_" .. (o[3] or o[1]) .. "_K2Node_ComponentBoundEvent_" .. o[2] ..
        "_OnButtonClickedEvent__DelegateSignature"
end

-- property read / method call that never throws (nil on any failure)
local function get(o, k)
    local v
    if o ~= nil then pcall(function() v = o[k] end) end
    return v
end
local function call(o, fn, ...)
    local args, r = { ... }, nil
    if o ~= nil then pcall(function() r = o[fn](o, table.unpack(args)) end) end
    return r
end
local function count(a)
    local n
    if not pcall(function() n = a:GetArrayNum() end) then n = type(a) == "table" and #a or 0 end
    return tonumber(n) or 0
end
local function num(v) return tonumber(v) or 0 end
local function xy(v)
    local x, y
    pcall(function() x, y = tonumber(v.X), tonumber(v.Y) end)
    return x, y
end

local S = {}
-- held_keys / rep outlive a reset, so a button still down when the inventory goes isn't a fresh press later
local function reset()
    S = { grids = {}, scan = 0, cur = nil, held = nil, menu = nil, tints = {}, on = false, lay_age = 0, lay_sig = nil,
          held_keys = S.held_keys or {}, rep = S.rep or {}, misses = S.misses or 0, no_mouse = S.no_mouse }
end
reset()
local untint   -- drawing, below

-- ---- what's on screen ---------------------------------------------------------------------------------------
-- A widget shows when it and every parent are visible up to a user widget in the viewport (a tree's root widget
-- has no parent: its outer is the WidgetTree, whose outer is the user widget).
local function shown(w)
    for _ = 1, 40 do
        if not util.valid(w) or call(w, "IsVisible") ~= true then return false end
        if call(w, "IsInViewport") == true then return true end
        local p = call(w, "GetParent")
        if not util.valid(p) then
            local tree = call(w, "GetOuter")
            p = util.valid(tree) and call(tree, "GetOuter") or nil
        end
        if not util.valid(p) or util.same(p, w) then return false end
        w = p
    end
    return false
end

-- ---- where things are on screen -------------------------------------------------------------------------------
-- Widget geometry can't be read from Lua: FGeometry has no reflected fields, so GetCachedGeometry comes back as an
-- empty table and every SlateBlueprintLibrary answer is 0,0 (kit 2026-10-31). So the layout is worked out from the
-- widget tree: a Horizontal/Vertical/Scroll box child sits after its shown earlier siblings' desired sizes (and
-- paddings), a canvas child at its slot's position, a ScaleBox scales its content to fit the screen. Units: viewport
-- units (DPI-free), as the menu's SetPosition takes them.
local LIB = {}
local function lib(name)
    if not util.valid(LIB[name]) then LIB[name] = StaticFindObject("/Script/UMG.Default__" .. name) end
    return util.valid(LIB[name]) and LIB[name] or nil
end
local function class_name(o)
    local n
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n
end
-- the parent; at the root of a user widget's tree, the user widget itself (root -> WidgetTree -> user widget)
local function parent_of(w)
    local p = call(w, "GetParent")
    if util.valid(p) then return p end
    local tree = call(w, "GetOuter")
    local uw = util.valid(tree) and call(tree, "GetOuter") or nil
    if util.valid(uw) and util.valid(get(uw, "WidgetTree")) then return uw end
    return nil
end
local function size(w)
    if call(w, "GetVisibility") == 1 then return 0, 0 end   -- Collapsed takes no room
    local x, y = xy(call(w, "GetDesiredSize"))
    return x or 0, y or 0
end
local function margin(w)
    local m = get(get(w, "Slot"), "Padding")
    local l, t, r, b = 0, 0, 0, 0
    pcall(function() l, t, r, b = tonumber(m.Left) or 0, tonumber(m.Top) or 0, tonumber(m.Right) or 0, tonumber(m.Bottom) or 0 end)
    return l, t, r, b
end
local function viewport()
    local wl, world = lib("WidgetLayoutLibrary"), game.world()
    local px, py = xy(call(wl, "GetViewportSize", world))
    local dpi = tonumber(call(wl, "GetViewportScale", world)) or 1
    if not px or px <= 0 or dpi <= 0 then return nil end
    return px / dpi, py / dpi, dpi
end

-- where child w sits inside panel p (p's units), and how much p scales it
local function offset(L, p, w)
    local cls = class_name(p) or ""
    if cls == "CanvasPanel" then
        local x, y = xy(call(get(w, "Slot"), "GetPosition"))
        return x or 0, y or 0, 1
    end
    if cls == "ScaleBox" then
        -- scale to fit, centered, on the assumption the box fills the screen (the mouse check below catches it if not)
        local dw, dh = size(w)
        local vw, vh = viewport()
        if not vw or dw <= 0 or dh <= 0 then return 0, 0, 1 end
        local k = math.min(vw / dw, vh / dh)
        return (vw - dw * k) / 2, (vh - dh * k) / 2, k
    end
    local kind = (cls == "HorizontalBox" and "x") or ((cls == "VerticalBox" or cls == "ScrollBox") and "y") or nil
    if cls == "ScrollBox" and get(p, "Orientation") == 0 then kind = "x" end
    if not kind then local l, t = margin(w); return l, t, 1 end
    local key = util.addr(p) or tostring(p)
    local pre = L.prefix[key]
    if not pre then
        pre = {}
        local along = 0
        for i = 0, (tonumber(call(p, "GetChildrenCount")) or 0) - 1 do
            local ch = call(p, "GetChildAt", i)
            local l, t, r, b = margin(ch)
            local sx, sy = size(ch)
            pre[i] = { along = along, l = l, t = t }
            if sx > 0 or sy > 0 then along = along + (kind == "x" and (l + sx + r) or (t + sy + b)) end
        end
        if cls == "ScrollBox" then pre.scroll = tonumber(call(p, "GetScrollOffset")) or 0 end
        L.prefix[key] = pre
    end
    local e = pre[tonumber(call(p, "GetChildIndex", w)) or -1]
    if not e then return 0, 0, 1 end
    local along = e.along - (pre.scroll or 0)
    if kind == "x" then return along + e.l, e.t, 1 end
    return e.l, along + e.t, 1
end
-- a widget's top-left in viewport units, and the scale its content is drawn at (memoized per layout pass)
local function place(L, w, depth)
    local key = util.addr(w) or tostring(w)
    local hit = L.pos[key]
    if hit then return hit[1], hit[2], hit[3] end
    local x, y, s = 0, 0, 1
    local p = depth < 40 and parent_of(w) or nil
    if p then
        local px, py, ps = place(L, p, depth + 1)
        local ox, oy, k = offset(L, p, w)
        x, y, s = px + ox * ps, py + oy * ps, ps * k
    end
    L.pos[key] = { x, y, s }
    return x, y, s
end

local function grid_of(L, c, i)
    local cols, rows = num(get(c, "NumberOfColumns")), num(get(c, "NumberOfRows"))
    local ws = get(c, "WSlots")
    if cols < 1 or rows < 1 or not ws or count(ws) < cols * rows then return nil end
    local g = { c = c, key = util.addr(c), cols = cols, rows = rows, ws = ws,
                main = get(c, "IsMainContainer?") == true, bar = get(c, "IsActionbar") == true,
                equip = call(c, "IsEquipTo?") == true }
    local cw, chh = size(ws[1])
    if cw > 0 and chh > 0 then
        local x, y, s = place(L, ws[1], 0)
        g.geo, g.dx, g.dy = true, cw * s, chh * s
        g.x0, g.y0 = x + g.dx / 2, y + g.dy / 2
    else
        -- not laid out yet: the grids side by side in list order
        g.geo, g.x0, g.y0, g.dx, g.dy = false, i * 1000, 0, 10, 10
    end
    return g
end

local function scan()
    local found, keys = {}, {}
    for _, c in ipairs(FindAllOf("JSIContainer_C") or {}) do
        if util.valid(c) and shown(c) then found[#found + 1] = c; keys[#keys + 1] = util.addr(c) or tostring(c) end
    end
    -- the layout walk costs a few hundred calls: only again when other grids show (a tab, a bag opened) or every 2 s
    local sig = table.concat(keys, ",")
    local out = S.grids
    if sig ~= S.lay_sig or S.lay_age >= padinv.LAYOUT_EVERY then
        S.lay_sig, S.lay_age, out = sig, 0, {}
        local L = { pos = {}, prefix = {} }
        for _, c in ipairs(found) do
            local g = grid_of(L, c, #out)
            if g then out[#out + 1] = g end
        end
    end
    S.grids = out
    if S.cur then
        local found
        for _, g in ipairs(out) do if g.key == S.cur.g.key then found = g end end
        if found then
            S.cur.g = found
            S.cur.col, S.cur.row = math.min(S.cur.col, found.cols - 1), math.min(S.cur.row, found.rows - 1)
        else
            S.cur = nil   -- its grid went (a closed bag or loot): the next press picks a cell again
            untint()
        end
    end
    local h = S.held
    if h then
        local found
        for _, g in ipairs(out) do if g.key == h.g.key then found = g end end
        if found then
            h.g = found
        else
            -- its container closed under it (loot walked away from): nothing was moved, it just goes back
            S.held = nil
            pcall(function() h.item:SetRenderOpacity(1.0) end)
            log.info("padinv: put back (its container closed)")
        end
    end
end

-- an inventory is up: a grid other than the hotbar is on screen
local function active()
    for _, g in ipairs(S.grids) do if not g.bar then return true end end
    return false
end

local function cell(g, col, row)
    if col < 0 or row < 0 or col >= g.cols or row >= g.rows then return nil end
    return g.ws[row * g.cols + col + 1]
end
local function item_at(g, col, row)
    local h = get(cell(g, col, row), "HostedItem")
    return util.valid(h) and h or nil
end
-- an item's cells: top-left column/row and width/height as it lies now (ItemDim follows its rotation)
local function footprint(g, item)
    local idx = num(get(item, "SlotIndex"))
    local w, h = xy(get(item, "ItemDim"))
    w, h = math.max(1, math.floor((w or 1) + 0.5)), math.max(1, math.floor((h or 1) + 0.5))
    return idx % g.cols, idx // g.cols, w, h
end
local function pos(g, col, row) return g.x0 + col * g.dx, g.y0 + row * g.dy end

-- ---- drawing --------------------------------------------------------------------------------------------------
local function tint(slot, color)
    local b = get(slot, "SlotBorder")
    if not util.valid(b) then return end
    local key = util.addr(b) or tostring(b)
    if not S.tints[key] then
        local c = get(b, "BrushColor")
        local r, gg, bb, a
        pcall(function() r, gg, bb, a = c.R, c.G, c.B, c.A end)
        S.tints[key] = { border = b, color = r and { R = r, G = gg, B = bb, A = a } or nil }
    end
    pcall(function() b:SetBrushColor(color) end)
end
function untint()
    for _, t in pairs(S.tints) do
        if t.color and util.valid(t.border) then pcall(function() t.border:SetBrushColor(t.color) end) end
    end
    S.tints = {}
end

local function fits(g, col, row, w, h, item)
    for r = row, row + h - 1 do
        for c = col, col + w - 1 do
            local s = cell(g, c, r)
            if not s then return false end
            local o = get(s, "HostedItem")
            if util.valid(o) and not util.same(o, item) then return false end
        end
    end
    return true
end

local function redraw()
    untint()
    local cur, held = S.cur, S.held
    if not cur then return end
    if held then
        local ok = cur.g.equip or fits(cur.g, cur.col, cur.row, held.w, held.h, held.item)
        for r = cur.row, cur.row + held.h - 1 do
            for c = cur.col, cur.col + held.w - 1 do
                local s = cell(cur.g, c, r)
                if s then tint(s, ok and FITS or NO_FIT) end
            end
        end
    else
        tint(item_at(cur.g, cur.col, cur.row) or cell(cur.g, cur.col, cur.row), CURSOR)
    end
end

-- The mouse follows the cursor so the game's own hover (tooltip) shows - while the game agrees: a few moves in a
-- row that leave the cell un-hovered mean the worked-out layout is off on this screen, and the mouse stays put.
local function move_mouse()
    local cur = S.cur
    if S.no_mouse or not cur or not cur.g.geo then return end
    local _, _, dpi = viewport()
    local x, y = pos(cur.g, cur.col, cur.row)
    local pc = game.controller()
    if dpi and util.valid(pc) then
        pcall(function() pc:SetMouseLocation(math.floor(x * dpi + 0.5), math.floor(y * dpi + 0.5)) end)
        S.hover = { slot = cell(cur.g, cur.col, cur.row), item = item_at(cur.g, cur.col, cur.row), wait = 2 }
    end
end
-- a couple of ticks after a move: did the mouse land on the cell?
local function hover_check()
    local h = S.hover
    if not h then return end
    h.wait = h.wait - 1
    if h.wait > 0 then return end
    S.hover = nil
    if call(h.slot, "IsHovered") == true or call(h.item, "IsHovered") == true then S.misses = 0; return end
    S.misses = S.misses + 1
    if S.misses >= padinv.HOVER_MISSES then
        S.no_mouse = true
        log.info("padinv: the mouse doesn't land on the cells on this screen - it stays put (the cursor still works)")
    end
end

-- ---- the right-click menu -------------------------------------------------------------------------------------
local function ctx_comp()
    local c = get(game.controller(), "JigContextMenuComp")
    if util.valid(c) then return c end
    c = get(game.player(), "JigContextMenuComp")
    if util.valid(c) then return c end
    c = FindFirstOf("JigContextMenuComp_C")
    return util.valid(c) and c or nil
end
local function menu_widget(m)
    local canvas = get(m.comp, "ContextMRef")
    if not util.valid(canvas) or call(canvas, "IsInViewport") ~= true then return nil end
    local w = get(canvas, "JigContextMenuW")
    return util.valid(w) and w or nil, canvas
end
local function option_paint(m, n)
    local o = m.opts and m.opts[n]
    if not o then return end
    if n == m.sel then
        if o.color == nil then
            local c = get(o.btn, "BackgroundColor")
            local r, g, b, a
            pcall(function() r, g, b, a = c.R, c.G, c.B, c.A end)
            o.color = r and { R = r, G = g, B = b, A = a } or false
        end
        pcall(function() o.btn:SetBackgroundColor(OPTION) end)
    elseif o.color then
        pcall(function() o.btn:SetBackgroundColor(o.color) end)
    end
end
local function options(m)
    local w = menu_widget(m)
    local out = {}
    if not w then return out end
    for i, o in ipairs(padinv.OPTIONS) do
        local b = get(w, o[1])
        if util.valid(b) and call(b, "IsVisible") == true then
            local at = call(call(b, "GetParent"), "GetChildIndex", b)
            out[#out + 1] = { btn = b, fn = handler(o), name = o[1], order = tonumber(at) or (100 + i) }
        end
    end
    table.sort(out, function(p, q) return p.order < q.order end)
    return out
end
local function menu_close(remove)
    local m = S.menu
    if not m then return end
    S.menu = nil
    if m.opts then
        local sel = m.sel
        m.sel = 0
        option_paint(m, sel)
    end
    if remove then
        local _, canvas = menu_widget(m)
        if canvas then pcall(function() canvas:RemoveFromParent() end) end
    end
end
-- The game puts its menu at the click (HandleMenuLocation: the pointer event's screen position); the pad's click
-- has none, so the game's spot is off screen (user 2026-10-31). The pad's menu goes at the cursor cell, or in the
-- middle when the worked-out layout is off on this screen, and always wholly on screen. Again for a moment: the
-- game places a new menu one frame after it is made.
padinv.MENU_W, padinv.MENU_H = 300, 240   -- before the menu has a size of its own
local function menu_place(m)
    local w = menu_widget(m)
    if not w then return end
    local vw, vh = viewport()
    if not vw then return end
    local mw, mh = size(w)
    if mw <= 0 or mh <= 0 then mw, mh = padinv.MENU_W, padinv.MENU_H end
    local cur = S.cur
    local vx, vy
    if cur and cur.g.geo and not S.no_mouse then
        local cx, cy = pos(cur.g, cur.col, cur.row)
        vx, vy = cx + 20, cy - 20
        if vx + mw > vw and cx - 20 - mw >= 0 then vx = cx - 20 - mw end   -- the cell's other side, as the game does
    else
        vx, vy = (vw - mw) / 2, (vh - mh) / 2
    end
    vx, vy = math.max(0, math.min(vx, vw - mw)), math.max(0, math.min(vy, vh - mh))
    pcall(function() w.Slot:SetPosition({ X = vx, Y = vy }) end)
end
local function menu_open(item)
    local comp = ctx_comp()
    if not comp then return end
    local ok, e = pcall(function() comp:OnJigItemRightClick(item, {}, {}) end)
    if not ok then log.every("padinv.menu", 60, "padinv: item menu failed - " .. tostring(e)); return end
    S.menu = { comp = comp, item = item, sel = 0, opts = nil, place = padinv.MENU_PLACE }
    if not menu_widget(S.menu) then S.menu = nil; return end   -- no options for this item: the game made no menu
    menu_place(S.menu)
end
local function menu_select(n)
    local m = S.menu
    local old = m.sel
    m.sel = n
    option_paint(m, old)
    option_paint(m, n)
end
local function menu_use()
    local m = S.menu
    local o = m.opts and m.opts[m.sel]
    if not o then return end
    local w = menu_widget(m)
    local ok, e = false, "menu gone"
    if w then ok, e = pcall(function() w[o.fn](w) end) end
    log.info("padinv: " .. o.name .. (ok and "" or (" failed - " .. tostring(e))))
    menu_close(not ok)
end

-- ---- moving ---------------------------------------------------------------------------------------------------
local function set_cursor(g, col, row)
    menu_close(true)
    S.cur = { g = g, col = col, row = row }
    redraw()
    move_mouse()
    if not S.held then
        local it = item_at(g, col, row)
        if it then menu_open(it) end
    end
end

local function first_cursor()
    local pick
    for _, g in ipairs(S.grids) do
        if not g.bar and not g.equip and g.main and g.cols * g.rows > 1 then pick = g; break end
    end
    if not pick then
        for _, g in ipairs(S.grids) do if not g.bar then pick = pick or g end end
    end
    if pick then set_cursor(pick, 0, 0) end
end

-- the closest cell of another grid in direction (dx, dy) from cell (col, row) of g; off-axis distance counts double.
-- Never the hotbar: it lay between the equipment and everything else (user 2026-10-31: "in order too get too the
-- player ghear i have too click all the way through the hot bar").
local function nearest(g, col, row, dx, dy)
    local px, py = pos(g, col, row)
    local best, bg, bc, br
    for _, o in ipairs(S.grids) do
        if o.key ~= g.key and not o.bar then
            for r = 0, o.rows - 1 do
                for c = 0, o.cols - 1 do
                    local x, y = pos(o, c, r)
                    local along = (x - px) * dx + (y - py) * dy
                    if along > 0.5 then
                        local score = along + 2 * math.abs((x - px) * dy - (y - py) * dx)
                        if not best or score < best then best, bg, bc, br = score, o, c, r end
                    end
                end
            end
        end
    end
    return bg, bc, br
end

local function step(dir)
    local cur = S.cur
    if not cur then return first_cursor() end
    local dx, dy = DIRS[dir][1], DIRS[dir][2]
    local g, col, row = cur.g, cur.col, cur.row
    -- out of the item under the cursor (holding one, the cursor is the drop corner and goes cell by cell)
    local x0, y0, w, h = col, row, 1, 1
    local it = not S.held and item_at(g, col, row)
    if it then x0, y0, w, h = footprint(g, it) end
    local nc, nr = col, row
    if dx > 0 then nc = x0 + w elseif dx < 0 then nc = x0 - 1 end
    if dy > 0 then nr = y0 + h elseif dy < 0 then nr = y0 - 1 end
    if cell(g, nc, nr) then return set_cursor(g, nc, nr) end
    local og, oc, orow = nearest(g, col, row, dx, dy)
    if og then return set_cursor(og, oc, orow) end
    -- left/right with nothing that way: the far end of the next / previous row
    if dx ~= 0 and cell(g, 0, row + dx) then return set_cursor(g, dx > 0 and 0 or g.cols - 1, row + dx) end
end

-- the root container (a bag's grid -> the inventory that holds it) and its JigMultiplayerComp
local function root_comp(c)
    local o = {}
    pcall(function() c:GetRootContainerRef(false, o) end)
    local root = util.valid(o.ContainerRef) and o.ContainerRef or c
    local comp = get(root, "JigMultiplayerComp")
    return util.valid(comp) and comp or nil, root
end

local function quick_take(item)
    local c = get(item, "ContainerMother")
    local comp = util.valid(c) and root_comp(c)
    if not comp then log.info("padinv: quick take - no inventory component"); return end
    -- the game's Ctrl+click: CTRL_Down on the slot (IsCTRLDown reads it), then its own mouse-down handler
    pcall(function() item.CTRL_Down = true end)
    local ok, e = pcall(function() comp:EventOnJigItemMouseButtonDown(c, item, { KeyName = FName("LeftMouseButton") }) end)
    pcall(function() item.CTRL_Down = false end)
    log.info("padinv: quick take" .. (ok and "" or (" failed - " .. tostring(e))))
end

local function set_opacity(item, v)
    pcall(function() item:SetRenderOpacity(v) end)
end
local function grab(g, item)
    local col, row, w, h = footprint(g, item)
    S.held = { item = item, g = g, col = col, row = row, w = w, h = h, turn = false,
               from = get(item, "ContainerMother") }
    set_opacity(item, 0.5)
    S.cur = { g = g, col = col, row = row }
    redraw()
    move_mouse()
end
local function let_go()
    local h = S.held
    S.held = nil
    if h then set_opacity(h.item, 1.0) end
    redraw()
end

-- out-param reads: UE4SS fills the table passed for them (or hands the value back)
local function out_of(o, fn, key, ...)
    local t, args, r = {}, { ... }, nil
    args[#args + 1] = t
    if not pcall(function() r = o[fn](o, table.unpack(args)) end) then return nil end
    if t[key] ~= nil then return t[key] end
    return r
end

-- The checks the game's mouse drag makes (JSIContainer HighlightSlots / Hightlight_DragMove / OnDrop, decompiled
-- 2026-10-31); the server only checks that the item fits, so these are the only guard. Anything that can't be read
-- refuses the move.
local function pending(item) return out_of(item, "IsItemPending?", "IsPending") end   -- a move still on its way
-- the weight limit of the container's root (a move inside one inventory always passes)
local function too_heavy(h, c)
    local w = tonumber(call(h.item, "GetWeight")) or tonumber(get(h.item, "ItemWeight"))
    local ok = w and out_of(c, "CheckWeightLimit", "Result", w, h.from)
    if ok == nil then return "can't check the weight limit" end
    if ok ~= true then return "too heavy for that container" end
    return nil
end

-- why the held item can't go at the cursor (nil: it can)
local function refuse(h, g, col, row)
    local busy = pending(h.item)
    if busy == nil then return "can't check the item" end
    if busy then return "it's still being moved" end
    -- never into its own compartments (a bag into itself); then the game's own check of the same
    local c = g.c
    for _ = 1, 12 do
        local host = get(c, "SlotMother")
        if not util.valid(host) then break end
        if util.same(host, h.item) then return "it can't go inside itself" end
        c = get(host, "ContainerMother")
        if not util.valid(c) then break end
    end
    local go = out_of(g.c, "CheckRootContainer", "Proceed?", h.item)
    if go == nil then return "can't check the container" end
    if not go then return "it can't go inside itself" end
    if not fits(g, col, row, h.w, h.h, h.item) then return "it doesn't fit there" end
    -- the "no backpack in a backpack" difficulty: both the item and the grid's owner are backpacks
    local host = get(g.c, "SlotMother")
    if util.valid(host) then
        local a = out_of(g.c, "DifficultyCheckBackpack?", "CarryOn?", h.item)
        local b = out_of(g.c, "DifficultyCheckBackpack?", "CarryOn?", host)
        if a == nil or b == nil then return "can't check the difficulty rules" end
        if not a and not b then return "no backpacks in backpacks on this difficulty" end
    end
    -- what the container takes (SupportedItemTypes and its lists): IsSupportedByThis(JigDataAsset, Type), as
    -- HighlightSlots calls it (its first parameter is named ItemId but is the item's data asset - kit 2026-10-31)
    -- (GetType's out-param is a GameplayTag struct: UE4SS fills the table passed with its TagName, there is no
    -- "Type" key - live 2026-10-31; a fresh { TagName } goes back in)
    local da = out_of(h.item, "GetJigDA", "JigDataAsset")
    local ty, tt = nil, {}
    if pcall(function() h.item:GetType(tt) end) and tt.TagName ~= nil then ty = { TagName = tt.TagName } end
    local ok
    if da ~= nil and ty ~= nil then ok = out_of(g.c, "IsSupportedByThis", "Supported?", da, ty) end
    if ok == nil then return "can't check what that container takes" end
    if ok ~= true then return "that container doesn't take it" end
    return too_heavy(h, g.c)
end

local function drop()
    local h, cur = S.held, S.cur
    if not h or not cur then return end
    local g, col, row = cur.g, cur.col, cur.row
    if g.key == h.g.key and col == h.col and row == h.row and not h.turn then return let_go() end
    local what, ok, e
    local local_comp, local_root = root_comp(h.from)
    if g.equip then
        -- onto the body: the game picks the right slot for the item and checks it
        local comp, root = root_comp(g.c)
        what = "equip"
        ok, e = pcall(function() comp:Context_TryEquip(h.item, root) end)
    elseif h.g.equip then
        what = "unequip"
        ok, e = pcall(function() local_comp:Context_TryUnequip(h.item, local_root) end)
    else
        local target = item_at(g, col, row)
        if target and not util.same(target, h.item) then
            -- The mouse drop on another item (JSIContainer OnDrop, decompiled 2026-10-31), in its order:
            -- 1. the item dropped on is a container (a magazine, a bag) without a special container, and its own grid
            --    (SlotContainer) takes the item: the unhandled-drop event moves it inside (ammo into a magazine -
            --    user 2026-10-31 "u cant put ammo into a mag"; kit 13:21: magazines are containers);
            --    A container item that doesn't take it: the mouse does nothing;
            -- 2. else the grid has its own special container (SpecialSContainer): into that, with no cell;
            -- 3. it stacks: OnItemStackRequest_Event;
            -- 4. else Drop_ItemOverItem, handled by BP_JigComponent.Drop_ItemOverItem_Event_0 (repair kits, filters,
            --    water: JigItemOverItemComp).
            local a, b = pending(h.item), pending(target)
            local why = (a == nil or b == nil) and "can't check the items" or ((a or b) and "it's still being moved") or nil
            if why then log.info("padinv: drop - " .. why); return end
            local bag = out_of(target, "IsContainer?", "IsContainer?")
            if bag == nil then log.info("padinv: drop - can't check the item"); return end
            local sp = {}
            if bag and not pcall(function() target:GetSpecialContainerRef(sp) end) then
                log.info("padinv: drop - can't check the item"); return
            end
            local special = sp.SpecialContainerRef
            local into, at
            if bag and not util.valid(special) then
                local sc = get(target, "SlotContainer")
                local da = out_of(h.item, "GetJigDA", "JigDataAsset")
                local ty, tt = nil, {}
                if pcall(function() h.item:GetType(tt) end) and tt.TagName ~= nil then ty = { TagName = tt.TagName } end
                local takes, go
                if util.valid(sc) and da ~= nil and ty ~= nil then takes = out_of(sc, "IsSupportedByThis", "Supported?", da, ty) end
                -- never a bag into itself or into one of its own compartments
                if takes == true then go = out_of(sc, "CheckRootContainer", "Proceed?", h.item) end
                if takes == nil or (takes == true and go == nil) then why = "can't check what that container takes"
                elseif not takes then why = "that container doesn't take it"
                elseif not go then why = "it can't go inside itself"
                else into, at = sc, cell(g, col, row) end
            elseif util.valid(get(g.c, "SpecialSContainer")) then
                into = get(g.c, "SpecialSContainer")
            end
            local stacks = false
            if not why and not into then pcall(function() stacks = h.item["AbleToStackTo?"](h.item, target) == true end) end
            if why then
            elseif stacks then why = too_heavy(h, g.c)   -- as the drag checks a stack: the weight limit
            elseif not into then
                local carry = out_of(g.c, "DifficultyCheckBackpack?", "CarryOn?", target)
                why = carry == nil and "can't check the difficulty rules" or (not carry and "no backpacks in backpacks on this difficulty") or nil
            end
            if why then log.info("padinv: drop - " .. why); return end
            if into and at then
                -- into the item's own grid. The game turns HandleContainerToContainerDrop off on every container
                -- (BP_JigComponent SetPermissions), so the mouse's OnDrop skips its local HandleContainerOnContainer
                -- and broadcasts Drop_ContainerOnContainerUnhandled(from, the cell's GetCSlotFromHosted, the item,
                -- the item dropped on, -1, turned), bound to the comp's EventOnInventoryAction -> Jig_UnhandledEvent
                -- (decompiled 2026-10-31; kit 13:31: HandleContainerOnContainer said handled and moved nothing)
                local comp = root_comp(g.c)
                if not comp then log.info("padinv: drop - no inventory component"); return end
                what = "into " .. tostring(util.fname(target) or "container")
                ok, e = pcall(function() comp:EventOnInventoryAction(h.from, into, h.item, target, -1, h.turn) end)
            elseif into then
                -- the grid's own special container: with HandleContainerToContainerDrop off the mouse sends this one
                -- unhandled too, with a slot index it works out (GetEmptySlotTryRotated / slot 0) - not decoded yet.
                -- Never HandleContainerOnContainer from here: it changes only the screen (kit 2026-10-31: a phantom
                -- 75-round stack in a magazine that held nothing, which then refused loads and unloads)
                log.info("padinv: drop - into that container: not on the pad yet (use the mouse)")
                return
            else
                local comp = root_comp(g.c)
                if not comp then log.info("padinv: drop - no inventory component"); return end
                if stacks then
                    what = "stack"
                    ok, e = pcall(function() comp:OnItemStackRequest_Event(h.item, target) end)
                else
                    what = "item over item"
                    ok, e = pcall(function() comp:Drop_ItemOverItem_Event_0(target, h.item, g.c, h.from) end)
                end
            end
        else
            local why = refuse(h, g, col, row)
            if why then log.info("padinv: drop - " .. why); return end
            -- the mouse drop's own handler: it works out the amount and calls Jig_UnhandledEvent (Rotated? flips
            -- the item from how it lies now)
            local comp = root_comp(g.c)
            what = "move"
            ok, e = pcall(function()
                comp:EventOnInventoryAction(h.from, g.c, h.item, nil, row * g.cols + col, h.turn)
            end)
        end
    end
    log.info("padinv: " .. what .. (ok and "" or (" failed - " .. tostring(e))))
    let_go()
    S.scan = 0
end

-- ---- the tick -------------------------------------------------------------------------------------------------
-- presses this frame: fresh ones, plus D-pad repeats while held
local function presses(pc, dt, down)
    local out = {}
    for name, pad in pairs(B) do
        local d = down(pc, pad)
        if d and not S.held_keys[name] then
            out[name] = true
            S.rep[name] = padinv.REPEAT_FIRST
        elseif d and DIRS[name] then
            S.rep[name] = (S.rep[name] or padinv.REPEAT_FIRST) - dt
            if S.rep[name] <= 0 then out[name] = true; S.rep[name] = padinv.REPEAT_EVERY end
        end
        S.held_keys[name] = d
    end
    return out
end

local function on_menu(p)
    local m = S.menu
    m.opts = m.opts or options(m)
    local n = #m.opts
    if p.b then menu_close(true); S.shut = true; return true end
    if p.a and m.sel >= 1 then menu_use(); return true end
    if p.down then
        if m.sel < n then menu_select(m.sel + 1); return true end
        return false   -- past the last option: the cursor goes on down
    end
    if p.up then
        if m.sel >= 1 then menu_select(m.sel - 1); return true end
        return false
    end
    return false
end

-- LB / RB with nothing held: the tabs over the left and middle columns, as clicking their titles does. BP_Inventory
-- binds EquipmentSlotTitle_Crafting -> OnWidgetMouseButtonDown_Event_0, _Equipment -> _Event_1, LootTitle ->
-- Loot_OnMouseButtonDown, VicinityTitle -> Vicinity_OnMouseButtonDown; each wants the left mouse button.
local function inventory_widget()
    for _, w in ipairs(FindAllOf("BP_Inventory_C") or {}) do
        if util.valid(w) and shown(w) then return w end
    end
    return nil
end
local function switch_tab(which)
    local inv = inventory_widget()
    if not inv then log.info("padinv: tabs - no inventory screen"); return end
    local fn, name
    if which == "lb" then
        local crafting = call(get(inv, "BP_CraftingWidget"), "IsVisible") == true
        fn = crafting and "OnWidgetMouseButtonDown_Event_1" or "OnWidgetMouseButtonDown_Event_0"
        name = crafting and "EQUIPMENT" or "CRAFTING"
    else
        local loot = call(get(inv, "LootContent"), "IsVisible") == true
        fn = loot and "Vicinity_OnMouseButtonDown" or "Loot_OnMouseButtonDown"
        name = loot and "VICINITY" or "LOOT"
    end
    menu_close(true)
    local ok, e = pcall(function() inv[fn](inv, { KeyName = FName("LeftMouseButton") }) end)
    log.info("padinv: tab " .. name .. (ok and "" or (" failed - " .. tostring(e))))
    S.scan = 0
end
-- B with nothing held and no menu: out of the inventory the way Escape does it (BP_Inventory's Tick -> Exit ->
-- the jig component's ToggleInventory). User 2026-10-31: "when in an inventory make it so b leaves".
local function close_inventory()
    local inv = inventory_widget()
    if not inv then log.info("padinv: B - no inventory screen"); return end
    local ok, e = pcall(function() inv:Exit() end)
    log.info("padinv: inventory closed" .. (ok and "" or (" - failed: " .. tostring(e))))
    S.scan = 0
end

-- Returns true while it has the pad (an inventory on screen), false to let gamepad.lua's menu focus run. Nothing
-- is looked at until the pad is pressed in a menu: someone on mouse and keyboard pays nothing.
function padinv.tick(pc, dt, down)
    local p = presses(pc, dt, down)
    local pressed = next(p) ~= nil
    if not S.cur and not S.held and not pressed then return false end
    S.scan = S.scan - dt
    S.lay_age = S.lay_age + dt
    if S.scan <= 0 or pressed then S.scan = padinv.SCAN_EVERY; scan() end
    hover_check()
    if not active() then
        padinv.leave()
        return false
    end
    if not S.on then
        S.on = true
        local geo = false
        for _, g in ipairs(S.grids) do geo = geo or g.geo end
        log.info(string.format("padinv: inventory on the pad (%d grid(s), %s)", #S.grids,
            geo and "screen layout" or "no layout yet: grids in list order"))
    end
    if S.menu and not menu_widget(S.menu) then menu_close(false) end
    if S.menu and S.menu.place > 0 then S.menu.place = S.menu.place - dt; menu_place(S.menu) end
    if not S.held and (p.lb or p.rb) then switch_tab(p.lb and "lb" or "rb"); return true end
    if p.b and not S.held and not S.menu then close_inventory(); return true end
    if not S.cur then
        if next(p) then first_cursor() end
        return true
    end
    if S.menu and on_menu(p) then return true end
    if S.held then
        if p.b then let_go(); log.info("padinv: put back")
        elseif p.a then drop()
        elseif p.lb or p.rb then S.held.w, S.held.h, S.held.turn = S.held.h, S.held.w, not S.held.turn; redraw()
        end
    else
        local it = item_at(S.cur.g, S.cur.col, S.cur.row)
        if p.a and it then
            if pending(it) == true then log.info("padinv: that item is still being moved"); return true end
            menu_close(true); grab(S.cur.g, it); return true
        end
        if p.x and it then menu_close(true); quick_take(it); S.scan = 0; return true end
    end
    for dir in pairs(DIRS) do
        if p[dir] then step(dir); break end
    end
    return true
end

-- The inventory closed (or the pad left it): tints, a held item and the pad's menu go back.
function padinv.leave()
    if not S.on and not S.cur and not S.held and not S.menu and next(S.tints) == nil then return end   -- every frame in play
    if S.held then set_opacity(S.held.item, 1.0) end
    menu_close(true)
    untint()
    if S.on then log.info("padinv: inventory off the pad") end
    reset()
end

function padinv.status()
    local c = S.cur
    return string.format("on=%s grids=%d cur=%s held=%s menu=%s", tostring(S.on), #S.grids,
        c and (c.col .. "," .. c.row) or "-", tostring(S.held ~= nil), S.menu and tostring(S.menu.sel) or "-")
end

return padinv
