-- The minimap (user 2026-11-01): a round map in the top right corner with the player's arrow in the middle. North is
-- always up: the map and N / E / S / W on its edge stay put and the arrow turns in its spot to the way the player
-- faces (user 2026-11-01: the turning map spun the marker "in a circle not in its spot", "and the nwse rotate with
-- it"). M twice quickly switches it on or
-- off (remembered on this PC). It shows only while a GPS is worn (the game's IsGPSEquipped?), never over the big map
-- or while the mouse cursor is up (inventory, menus).
--
-- The picture is the big map's own texture (BP_MapData's Map Texture), placed the way the game's MapWidget puts
-- markers on it (Calculate Actor Position: a world point sits (y - middle y, -(x - middle x)) * side / World Size
-- from the map's centre, so the map's up is world +X). The game ships the minimap material but no minimap widget, so
-- the round shape comes from that material: the map is drawn into a RetainerBox whose effect material is M_Map_Base
-- with Middle 0 and Zoom 1 (the retainer's picture 1:1, unshifted) and BP_MapData's circle mask.
-- The arrow's turn is a render angle (+yaw, clockwise from north) around its own centre; the map never turns.
--
-- With the game's compass up (a compass worn: its Compass widget visible), the compass's markers show on the minimap
-- too: every BP_CompassMarker actor (pings, quests, places - the compass's own NavPoints list) with its Icon and
-- IconColor, at its spot when it's on the map, else on the rim in its direction. While the minimap shows, the compass
-- at the top is hidden (render opacity 0, set again each frame: its fade animations change the opacity) and comes
-- back when the minimap goes.
--
-- The other players (user 2026-11-01): every co-op player's character here (each player's ghost, peers.each) is a
-- coloured dot, one colour per player for as long as that character stands. On the minimap it sits at its spot, or on
-- the rim in its direction when farther out. On the big map it is one of the game's own W_StandardMarker widgets in
-- the MapWidget's StandardMarkerOverlay (shown with the other markers: only with a GPS worn), placed each frame while
-- the map is open by the MapWidget's own Calculate Actor Position. It is not added to the widget's Standard Marker
-- References, so the game's own loop never moves it; its Icon becomes a round dot (no texture: the marker's
-- Construct collapses the icon and shows an empty title, both undone here).

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")

local minimap = {}

local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"
local SHELL = "/Game/JigSInventory/Jigsaw/Widgets/BP_StatTextW.BP_StatTextW_C"
local UMG = "/Script/UMG."
local MML = "/Script/Engine.Default__KismetMaterialLibrary"
local MAP_MAT = "/Game/Blueprints/MinimapSystem/Material/M_Map_Base.M_Map_Base"
local CIRCLE = "/Game/Blueprints/MinimapSystem/Texture/T_Mask_Circle.T_Mask_Circle"
local ARROW_TEX = "/Game/Blueprints/MinimapSystem/Texture/T_Player.T_Player"
local MAP_COMP = "/Game/Blueprints/MinimapSystem/Blueprints/BPC_MinimapSystem.BPC_MinimapSystem_C"
local MAP_MARKER = "/Game/Blueprints/MinimapSystem/Blueprints/Widget/Markers/W_StandardMarker.W_StandardMarker_C"
local COMPASS_CLS, MARKER_CLS = "Compass_C", "BP_CompassMarker_C"
local FILE = "\\mirror_minimap.txt"

minimap.SIZE, minimap.TOP, minimap.RIGHT = 232, 24, 28   -- px: the disc, its gap to the screen's top and right edges
local SIZE, RIM = minimap.SIZE, 4
local MAP_D = SIZE - 2 * RIM   -- the map's circle inside the rim
local VIEW = 30000.0           -- world units across the map (300 m)
local ARROW, DOT = 26, 12      -- the arrow (T_Player); the dot drawn in its place if the texture isn't loaded
local LETTER_IN = 17           -- px from the disc's edge to a compass letter's centre
local MARK, MAX_MARKS = 20, 24 -- a marker icon's size (px); the most markers drawn
local EDGE_R = SIZE / 2 - MARK / 2 - 1   -- px from the centre: markers farther out ride the rim here
local DOUBLE_S = 0.45          -- s between the two M presses
local MATE_D, MAX_MATES = 12, 3 -- another player's dot (px); the most players drawn (4-player co-op)
local BIG_DOT = 0.6            -- the big map's dot: the marker's 24 px icon at this scale
local BIG_TRIES = 3            -- big-map markers that couldn't be made before giving up for the session
local GPS_EVERY, DATA_EVERY, MARKS_EVERY, COMPASS_EVERY, MATES_EVERY = 0.5, 2.0, 0.5, 1.0, 0.5
-- a FindAllOf walks every object, 6-10 ms a time: the top line of the live perf log, 2026-11-03 (0.3 ms/frame, worst
-- 8-10 ms). No compass widget: looked for less and less often, up to COMPASS_MAX s apart. Markers: swept when the
-- compass's own widget list changes size, else every SWEEP_EVERY s; those found are read every MARKS_EVERY s.
local SWEEP_EVERY, COMPASS_MAX = 5.0, 10.0
local MAP_EVERY = 0.1          -- s between looks at the big map's state while the minimap isn't there to hide
local NUDGE_PX, NUDGE_DEG = 0.25, 0.25   -- smaller moves aren't drawn: each one redraws the retainer's whole disc
local COLLAPSED, HIDDEN, HIT_INVISIBLE = 1, 2, 3
local CLEAR = { R = 0, G = 0, B = 0, A = 0 }
local DISC = { R = 0.015, G = 0.017, B = 0.02, A = 0.85 }
local RIM_C = { R = 0.80, G = 0.82, B = 0.84, A = 0.92 }
local NORTH_C = { R = 1.00, G = 0.36, B = 0.28, A = 1 }
local LETTER_C = { R = 0.88, G = 0.90, B = 0.92, A = 0.92 }
local WHITE = { R = 1, G = 1, B = 1, A = 1 }
-- letter, bearing (degrees from north, clockwise), colour, font size
local LETTERS = { { "N", 0, NORTH_C, 17 }, { "E", 90, LETTER_C, 13 }, { "S", 180, LETTER_C, 13 }, { "W", 270, LETTER_C, 13 } }
-- the other players' colours (not the north red, not the arrow's white)
local MATE_C = {
    { R = 0.20, G = 0.85, B = 1.00, A = 1 },
    { R = 1.00, G = 0.78, B = 0.15, A = 1 },
    { R = 0.72, G = 0.45, B = 1.00, A = 1 },
}

local on, loaded = false, false
local clock, last_m = 0.0, -100.0
local gps, gps_in = false, 0.0
local data, data_in, data_said = nil, 0.0, false   -- { tex, mask, ws, mx, my } from the world's BP_MapData
local comp_cls, comp, comp_for = nil, nil, nil
local marks, marks_in = {}, 0.0                    -- { x, y, tex, tex_id, color } of the compass markers
local mark_actors, sweep_at, mark_n = {}, 0.0, nil -- the markers the last sweep found; the next sweep; the list's size
local map_open, map_in = false, 0.0                -- the big map's state as last read
local cmp ={ w = nil, for_pc = nil, find_at = 0.0, hidden = nil }   -- the game's compass widget; the one we hid
local view = { w = nil, built_for = nil, broken = false, shown = false }
local mates, mates_in = {}, 0.0                    -- { a = actor, key = addr, color } of the other players here
local big = { mw = nil, by = {}, open = false, fails = 0, said = false }   -- the big map's dots: addr -> widget

-- the map image's top-left corner in the map canvas and its side (px), for the player at world (x, y) on a map
-- of World Size ws around world (mx, my): the player's point lands on the canvas's centre
function minimap.place(x, y, mx, my, ws)
    local side = ws * MAP_D / VIEW
    local u = 0.5 + (y - my) / ws
    local v = 0.5 - (x - mx) / ws
    return MAP_D / 2 - u * side, MAP_D / 2 - v * side, side
end

-- where a compass letter's centre goes on the disc for a bearing (degrees from north; north is up)
function minimap.letter_at(deg)
    local a = math.rad(deg)
    local r = SIZE / 2 - LETTER_IN
    return SIZE / 2 + r * math.sin(a), SIZE / 2 - r * math.cos(a)
end

-- where a marker at world (x, y) goes on the disc for the player at (px, py), north up: its spot on the map, or on
-- the rim in its direction when it's farther out (edge = true)
function minimap.mark_at(px, py, x, y)
    local dx, dy = x - px, y - py
    local r = math.sqrt(dx * dx + dy * dy) * MAP_D / VIEW
    local edge = r > EDGE_R
    if edge then r = EDGE_R end
    local a = math.atan(dy, dx)
    return SIZE / 2 + r * math.sin(a), SIZE / 2 - r * math.cos(a), edge
end

local function file_path()
    local ok, d = pcall(function() return require("mirror.link").dir() end)
    return ok and d and (d .. FILE) or nil
end

local function load()
    loaded = true
    local p = file_path()
    local f = p and io.open(p, "rb")
    if not f then return end
    on = (f:read("*a") or ""):match("^%s*(%a+)") == "on"
    f:close()
end

local function save()
    local p = file_path()
    local f = p and io.open(p, "wb")
    if not f then return end
    f:write(on and "on" or "off", "\n")
    f:close()
end

local function worn()
    local out = {}
    local ok = pcall(function() game.player()["IsGPSEquipped?"](game.player(), out) end)
    return ok and out["GPS?"] == true
end

local function big_map_open()
    local p = game.player()
    if not util.valid(p) then return false end
    if not util.same(comp_for, p) or not util.valid(comp) then
        comp, comp_for = nil, p
        if not util.valid(comp_cls) then comp_cls = StaticFindObject(MAP_COMP) end
        if util.valid(comp_cls) then pcall(function() comp = p:GetComponentByClass(comp_cls) end) end
        if not util.valid(comp) then comp = nil end
    end
    local open = false
    if comp then pcall(function() open = comp.MapToggled == true end) end
    return open
end

local function cursor_up()
    local up = false
    pcall(function() up = game.controller().bShowMouseCursor == true end)
    return up
end

local function read_data()
    local md
    pcall(function() md = FindFirstOf("BP_MapData_C") end)
    if not util.valid(md) then return nil end
    local d = {}
    pcall(function()
        d.tex, d.mask, d.ws = md["Map Texture"], md["Minimap Mask Texture"], md["World Size"]
        local m = md["World Middle Coordinations"]
        d.mx, d.my = m.X, m.Y
    end)
    if not (util.valid(d.tex) and type(d.ws) == "number" and d.ws > 0 and type(d.mx) == "number"
            and type(d.my) == "number") then
        return nil
    end
    if not util.valid(d.mask) then d.mask = StaticFindObject(CIRCLE) end
    return d
end

-- the game's compass widget on this controller's screen (Compass_C, the one the HUD made: not the class default)
local function compass()
    local pc = game.controller()
    if util.valid(cmp.w) and cmp.for_pc == util.addr(pc) then return cmp.w end
    cmp.w = nil
    if clock < cmp.find_at then return nil end
    cmp.find_gap = math.min((cmp.find_gap or COMPASS_EVERY / 2) * 2, COMPASS_MAX)
    cmp.find_at = clock + cmp.find_gap
    local all
    pcall(function() all = FindAllOf(COMPASS_CLS) end)
    for _, w in ipairs(all or {}) do
        local owner
        if util.valid(w) then pcall(function() owner = w:GetOwningPlayer() end) end
        if util.same(owner, pc) then cmp.w, cmp.for_pc, cmp.find_gap = w, util.addr(pc), nil; break end
    end
    return cmp.w
end

-- the compass is up: a compass worn (the game shows the widget then)
local function compass_up(w)
    local v
    pcall(function() v = w:GetVisibility() end)
    return v ~= nil and v ~= COLLAPSED and v ~= HIDDEN
end

-- the compass at the top out of sight while the minimap shows (render opacity: the game's own show/hide is its
-- visibility), and back afterwards
local function hide_compass(yes)
    if yes then
        local w = compass()
        if not w then return end
        local o
        pcall(function() o = w:GetRenderOpacity() end)
        if o ~= 0 then pcall(function() w:SetRenderOpacity(0) end) end
        cmp.hidden = w
    elseif cmp.hidden then
        local w = cmp.hidden
        cmp.hidden = nil
        if util.valid(w) then pcall(function() w:SetRenderOpacity(1) end) end
    end
end

-- the compass adds a widget per marker to this list and takes it off again (Compass_C: NavPoints, RemoveFromCompass):
-- free to read, nil if it can't be
local function compass_list_size(w)
    local n
    pcall(function() n = w.UsedObjectWidgets:GetArrayNum() end)
    return type(n) == "number" and n or nil
end

local function scan_marks(w)
    local n = compass_list_size(w)
    if clock >= sweep_at or n ~= mark_n then
        sweep_at, mark_n = clock + SWEEP_EVERY, n
        local all
        pcall(function() all = FindAllOf(MARKER_CLS) end)
        mark_actors = all or {}
    end
    local list = {}
    for _, m in ipairs(mark_actors) do
        if #list >= MAX_MARKS then break end
        if util.valid(m) then
            local e = {}
            local ok = pcall(function()
                local l = m:K2_GetActorLocation()
                e.x, e.y = l.X, l.Y
                e.tex = m.Icon
                local c = m.IconColor
                e.color = { R = c.R, G = c.G, B = c.B, A = c.A }
            end)
            if ok and util.valid(e.tex) then e.tex_id = util.addr(e.tex); list[#list + 1] = e end
        end
    end
    marks = list
end

-- the other players' characters here; a player keeps the colour it was first given while its character stands
local function scan_mates()
    local old, list, taken = {}, {}, {}
    for _, m in ipairs(mates) do old[m.key] = m.color end
    local ok, peers = pcall(require, "mirror.peers")
    if ok and type(peers) == "table" and peers.each then
        pcall(peers.each, "mirror.ghost", function(g)
            local a = #list < MAX_MATES and g.get and g.get()
            local key = a and util.addr(a)
            if key then
                list[#list + 1] = { a = a, key = key, color = old[key] }
                if old[key] then taken[old[key]] = true end
            end
        end)
    end
    for _, m in ipairs(list) do
        if not m.color then
            for _, c in ipairs(MATE_C) do if not taken[c] then m.color, taken[c] = c, true; break end end
        end
    end
    mates = list
end

local function mates_due(dt, now)
    mates_in = mates_in - dt
    if now or mates_in <= 0 then mates_in = MATES_EVERY; scan_mates() end
end

local function mate_at(m)
    local l
    if util.valid(m.a) then pcall(function() l = m.a:K2_GetActorLocation() end) end
    return l
end

-- (UMG from Lua as notify.lua builds it: every widget starts from its class's defaults, only fields change)
local function new(cls, outer)
    local o
    pcall(function() o = StaticConstructObject(StaticFindObject(UMG .. cls), outer) end)
    if not util.valid(o) then error("couldn't create " .. cls) end
    return o
end

-- child on a canvas at (x, y): its top-left corner, or its centre when centred; w nil = its own size
local function put(canvas, child, x, y, w, h, centred)
    local s = canvas:AddChildToCanvas(child)
    pcall(function()
        if centred then s:SetAlignment({ X = 0.5, Y = 0.5 }) end
        s:SetPosition({ X = x, Y = y })
        if w then s:SetSize({ X = w, Y = h }) else s:SetAutoSize(true) end
    end)
    return s
end

-- an Image drawn as a circle (Slate's rounded box with half-height corners): fill colour, edge line colour + width
local function circle(img, fill, line, width)
    pcall(function()
        local b = img.Brush
        b.DrawAs = 4                         -- ESlateBrushDrawType::RoundedBox
        b.TintColor = { SpecifiedColor = fill, ColorUseRule = 0 }
        b.OutlineSettings.RoundingType = 1   -- HalfHeightRadius: a square box becomes a circle
        b.OutlineSettings.Width = width
        b.OutlineSettings.Color = { SpecifiedColor = line, ColorUseRule = 0 }
        img:SetBrush(b)
    end)
end

-- the retainer draws its content through the map material: round, the texture otherwise as it is
local function round_mask(ret)
    local lib, parent, p = util.cdo(MML), StaticFindObject(MAP_MAT), game.player()
    if not (lib and util.valid(parent) and util.valid(p)) then return false end
    local mid
    pcall(function() mid = lib:CreateDynamicMaterialInstance(p, parent, FName("None"), 0) end)
    if not util.valid(mid) then return false end
    local ok = pcall(function()
        mid:SetTextureParameterValue(FName("MaskTexture"), data.mask)
        mid:SetScalarParameterValue(FName("LevelSize"), data.ws)
        -- Middle 0: the material shifts its sample by Middle / LevelSize (World Middle here left grey strips about
        -- 0.17 of the disc wide on two sides, user 2026-11-01), and the retainer's content must be drawn 1:1
        mid:SetScalarParameterValue(FName("Minimap Middle X"), 0.0)
        mid:SetScalarParameterValue(FName("Minimap Middle Y"), 0.0)
        mid:SetScalarParameterValue(FName("Zoom"), 1.0)
        ret:SetTextureParameter(FName("MapTexture"))
        ret:SetEffectMaterial(mid)
    end)
    return ok
end

local function letter(tree, l)
    local t = new("TextBlock", tree)
    pcall(function() t:SetText(FText(l[1])) end)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = l[3], ColorUseRule = 0 }) end)
    pcall(function()
        local f = t.Font
        f.Size = l[4]
        f.TypefaceFontName = FName("Bold")
        t:SetFont(f)
    end)
    pcall(function()
        t:SetShadowOffset({ X = 1, Y = 1 })
        t:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 })
    end)
    return t
end

-- what the map is drawn from, in the log once per build (a grey part of the minimap: the texture's own edge or not)
local function describe()
    local name, w, h = "?", "?", "?"
    pcall(function() name = data.tex:GetFullName() end)
    pcall(function() w, h = data.tex:Blueprint_GetSizeX(), data.tex:Blueprint_GetSizeY() end)
    log.info(string.format("minimap: built - map %s (%sx%s), World Size %.0f, middle (%.0f, %.0f)", tostring(name),
        tostring(w), tostring(h), data.ws, data.mx, data.my))
end

local function build()
    local wbl, pc, shell = util.cdo(WBL), game.controller(), StaticFindObject(SHELL)
    if not (wbl and util.valid(pc) and util.valid(shell)) then return false end
    local w
    pcall(function() w = wbl:Create(pc, shell, pc) end)
    if not util.valid(w) then return false end
    local tree = w.WidgetTree
    local root = new("CanvasPanel", tree)
    tree.RootWidget = root
    local frame = new("CanvasPanel", tree)
    local fs = root:AddChildToCanvas(frame)
    pcall(function()
        fs:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
        fs:SetAlignment({ X = 1, Y = 0 })
        fs:SetPosition({ X = -minimap.RIGHT, Y = minimap.TOP })
        fs:SetSize({ X = SIZE, Y = SIZE })
    end)
    local disc = new("Image", tree)
    put(frame, disc, 0, 0, SIZE, SIZE)
    circle(disc, DISC, CLEAR, 0)
    local ret = new("RetainerBox", tree)
    put(frame, ret, RIM, RIM, MAP_D, MAP_D)
    local turn = new("CanvasPanel", tree)
    pcall(function() ret:SetContent(turn) end)
    pcall(function() turn:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
    local map = new("Image", tree)
    pcall(function() map:SetBrushFromTexture(data.tex, false) end)
    local x, y, side = minimap.place(data.mx, data.my, data.mx, data.my, data.ws)
    local ms = put(turn, map, x, y, side, side)
    if not round_mask(ret) then log.warn("minimap: the round mask couldn't be set up - the map shows square") end
    -- the rim on top of the map's edge
    local ring = new("Image", tree)
    put(frame, ring, 0, 0, SIZE, SIZE)
    circle(ring, CLEAR, RIM_C, RIM)
    -- the compass markers (under the letters, so N stays readable)
    local mslots = {}
    for i = 1, MAX_MARKS do
        local img = new("Image", tree)
        pcall(function() img:SetVisibility(COLLAPSED) end)
        mslots[i] = { img = img, slot = put(frame, img, SIZE / 2, SIZE / 2, MARK, MARK, true) }
    end
    -- the other players (over the compass markers, under the letters)
    local dots = {}
    for i = 1, MAX_MATES do
        local img = new("Image", tree)
        pcall(function() img:SetVisibility(COLLAPSED) end)
        dots[i] = { img = img, slot = put(frame, img, SIZE / 2, SIZE / 2, MATE_D, MATE_D, true) }
    end
    local letters = {}
    for i, l in ipairs(LETTERS) do
        local lx, ly = minimap.letter_at(l[2])
        letters[i] = { deg = l[2], slot = put(frame, letter(tree, l), lx, ly, nil, nil, true) }
    end
    local arrow, tex = new("Image", tree), StaticFindObject(ARROW_TEX)
    if util.valid(tex) then
        pcall(function() arrow:SetBrushFromTexture(tex, false) end)
        pcall(function() arrow:SetColorAndOpacity(WHITE) end)
        put(frame, arrow, SIZE / 2, SIZE / 2, ARROW, ARROW, true)
    else
        circle(arrow, NORTH_C, WHITE, 2)
        put(frame, arrow, SIZE / 2, SIZE / 2, DOT, DOT, true)
    end
    pcall(function() arrow:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
    pcall(function() root:SetVisibility(COLLAPSED) end)
    pcall(function() w:AddToViewport(39) end)
    view.w, view.built_for, view.root, view.turn, view.map_slot = w, util.addr(pc), root, turn, ms
    view.arrow = arrow
    view.letters, view.marks, view.dots, view.told = letters, mslots, dots, false
    view.x, view.y, view.yaw, view.shown = nil, nil, nil, false
    describe()
    return true
end

local function drop_view()
    hide_compass(false)
    local old = view.w
    view.w, view.built_for, view.root, view.turn, view.map_slot, view.letters, view.marks, view.dots, view.shown =
        nil, nil, nil, nil, nil, nil, nil, nil, false
    view.arrow = nil
    if util.valid(old) then pcall(function() old:RemoveFromParent() end) end
end

local function view_ok()
    if view.broken then return false end
    local pc = game.controller()
    if not util.valid(pc) then return false end
    if util.valid(view.w) and view.built_for == util.addr(pc) then return true end
    drop_view()
    local ok, built = pcall(build)
    if not ok then
        view.broken = true
        log.warn("minimap: couldn't build the minimap (" .. tostring(built) .. ")")
        return false
    end
    return built == true
end

local function show(yes)
    if view.shown == yes or not util.valid(view.root) then return end
    view.shown = yes
    pcall(function() view.root:SetVisibility(yes and HIT_INVISIBLE or COLLAPSED) end)
    if not yes then hide_compass(false) end
end

local function same_color(a, b) return b and a.R == b.R and a.G == b.G and a.B == b.B and a.A == b.A end

local function place_marks(px, py, up)
    for i, s in ipairs(view.marks) do
        local m = up and marks[i]
        if not m then
            if s.on then s.on = false; pcall(function() s.img:SetVisibility(COLLAPSED) end) end
        else
            if s.tex_id ~= m.tex_id then s.tex_id = m.tex_id; pcall(function() s.img:SetBrushFromTexture(m.tex, false) end) end
            if not same_color(m.color, s.color) then
                s.color = m.color
                pcall(function() s.img:SetColorAndOpacity(m.color) end)
            end
            local x, y = minimap.mark_at(px, py, m.x, m.y)
            if not s.x or math.abs(x - s.x) + math.abs(y - s.y) > NUDGE_PX then
                s.x, s.y = x, y
                pcall(function() s.slot:SetPosition({ X = x, Y = y }) end)
            end
            if not s.on then s.on = true; pcall(function() s.img:SetVisibility(HIT_INVISIBLE) end) end
        end
    end
end

local function place_dots(px, py)
    for i, s in ipairs(view.dots) do
        local m = mates[i]
        local l = m and m.color and mate_at(m)
        if not l then
            if s.on then s.on = false; pcall(function() s.img:SetVisibility(COLLAPSED) end) end
        else
            if s.color ~= m.color then s.color = m.color; circle(s.img, m.color, WHITE, 2) end
            local x, y = minimap.mark_at(px, py, l.X, l.Y)
            if not s.x or math.abs(x - s.x) + math.abs(y - s.y) > NUDGE_PX then
                s.x, s.y = x, y
                pcall(function() s.slot:SetPosition({ X = x, Y = y }) end)
            end
            if not s.on then s.on = true; pcall(function() s.img:SetVisibility(HIT_INVISIBLE) end) end
        end
    end
end

local function update(dt)
    local l, r
    pcall(function() l = game.player():K2_GetActorLocation() end)
    pcall(function() r = game.controller():GetControlRotation() end)
    if not (l and r) then return end
    local x, y = minimap.place(l.X, l.Y, data.mx, data.my, data.ws)
    if not view.told then
        view.told = true
        log.info(string.format("minimap: the player is at (%.3f, %.3f) of the map texture",
            0.5 + (l.Y - data.my) / data.ws, 0.5 - (l.X - data.mx) / data.ws))
    end
    if not view.x or math.abs(x - view.x) + math.abs(y - view.y) > NUDGE_PX then
        view.x, view.y = x, y
        pcall(function() view.map_slot:SetPosition({ X = x, Y = y }) end)
    end
    -- north-up: only the arrow turns (the letters were placed for yaw 0 at build)
    local yaw = r.Yaw or 0
    if not view.yaw or math.abs(yaw - view.yaw) > NUDGE_DEG then
        view.yaw = yaw
        pcall(function() view.arrow:SetRenderTransformAngle(yaw) end)
    end
    hide_compass(true)
    local up = cmp.w ~= nil and compass_up(cmp.w)
    if up then
        marks_in = marks_in - dt
        if marks_in <= 0 then marks_in = MARKS_EVERY; scan_marks(cmp.w) end
    else
        marks_in, sweep_at = 0.0, 0.0   -- (worn again: looked for at once)
    end
    place_marks(l.X, l.Y, up)
    mates_due(dt)
    place_dots(l.X, l.Y)
end

-- the big map's dot for another player: the game's marker widget in the map's marker overlay, its icon a round dot
-- and its (empty) title hidden. Set again each time the map opens: a rebuilt marker runs its Construct again.
local function style_big(w, color)
    pcall(function() w.Text:SetVisibility(COLLAPSED) end)
    local icon
    pcall(function() icon = w.Icon end)
    if not util.valid(icon) then return end
    circle(icon, color, WHITE, 2)
    pcall(function() icon:SetRenderScale({ X = BIG_DOT, Y = BIG_DOT }) end)
    pcall(function() icon:SetVisibility(HIT_INVISIBLE) end)
end

local function make_big(mw, color)
    local wbl, cls = util.cdo(WBL), StaticFindObject(MAP_MARKER)
    if not (wbl and util.valid(cls)) then return nil end
    local w, s
    pcall(function() w = wbl:Create(mw, cls, game.controller()) end)
    if not util.valid(w) then return nil end
    pcall(function() s = mw.StandardMarkerOverlay:AddChildToOverlay(w) end)
    if not s then return nil end
    pcall(function()
        s:SetHorizontalAlignment(2)   -- centred, as MapWidget's Add Standard Marker sets them
        s:SetVerticalAlignment(2)
    end)
    style_big(w, color)
    return w
end

-- every tick while the minimap must hide at once or the map is up, else a few times a second
local function map_state(dt)
    map_in = map_in - dt
    if map_open or view.shown or map_in <= 0 then
        map_in = MAP_EVERY
        map_open = big_map_open()
    end
    return map_open
end

local function update_big(dt, open)
    if not open then big.open = false; return end
    local mw
    pcall(function() mw = comp.MapWidget end)
    if not util.valid(mw) then return end
    -- another map widget (a new character): the old one's dots went with it
    if not util.same(big.mw, mw) then big.by, big.mw = {}, mw end
    local opened = not big.open
    big.open = true
    mates_due(dt, opened)
    local seen = {}
    for _, m in ipairs(mates) do
        if m.color and util.valid(m.a) then
            seen[m.key] = true
            local w = big.by[m.key]
            if w and not util.valid(w) then w = nil end
            if not w and big.fails < BIG_TRIES then
                w = make_big(mw, m.color)
                big.by[m.key] = w
                if not w then
                    big.fails = big.fails + 1
                    if big.fails >= BIG_TRIES then log.warn("minimap: couldn't put the other players on the big map") end
                end
            elseif w and opened then
                style_big(w, m.color)
            end
            if w then
                local out = {}
                local ok = pcall(function() mw["Calculate Actor Position"](mw, m.a, out) end)
                local p = ok and out.Location
                if p then
                    pcall(function() w:SetRenderTranslation({ X = p.X, Y = p.Y }) end)
                elseif not big.said then
                    big.said = true
                    log.warn("minimap: the big map couldn't place another player's dot")
                end
            end
        end
    end
    for k, w in pairs(big.by) do
        if not seen[k] then
            if util.valid(w) then pcall(function() w:RemoveFromParent() end) end
            big.by[k] = nil
        end
    end
end

function minimap.tick(dt)
    dt = dt or 1 / 30
    clock = clock + dt
    if not loaded then load() end
    local alive = util.valid(game.player())
    local open = alive and map_state(dt)
    if alive then util.safe(update_big, "minimap.update_big", dt, open) end
    local want = on and alive
    if want then
        gps_in = gps_in - dt
        if gps_in <= 0 then gps_in = GPS_EVERY; gps = worn() end
        want = gps and not open and not cursor_up()
    end
    if want and not data then
        data_in = data_in - dt
        if data_in <= 0 then
            data_in = DATA_EVERY
            data = read_data()
            if not data and not data_said then data_said = true; log.info("minimap: this world has no map data (yet)") end
        end
        want = data ~= nil
    end
    if not want then show(false); return end
    if not view_ok() then return end
    show(true)
    util.safe(update, "minimap.update", dt)
end

-- true while the minimap is on the screen; bottom(): the first free y under it (notify's cards go there), or nil
function minimap.shown() return view.shown and util.valid(view.w) end
function minimap.bottom() if minimap.shown() then return minimap.TOP + SIZE + 12 end end
function minimap.on() if not loaded then load() end; return on end

function minimap.set(v)
    if not loaded then load() end
    on = v == true
    save()
    log.info("minimap: " .. (on and "on" or "off"))
    local text = not on and "Minimap off. M twice turns it on again."
        or worn() and "Minimap on. M twice turns it off."
        or "Minimap on: it shows while you wear a GPS."
    pcall(function() require("mirror.notify").show(text, "info", "minimap") end)
end

-- M is a letter while typing: in the quick chat, or in a text box with the cursor up (the journal's chat, a rename).
-- With the big map open the cursor is up too, and that M counts (the game's M opens and closes the map).
local function typing()
    local busy = false
    pcall(function() busy = require("mirror.quickchat").is_open() == true end)
    return busy or (cursor_up() and not big_map_open())
end

local function on_m()
    if typing() then last_m = -100.0; return end
    if clock - last_m <= DOUBLE_S then
        last_m = -100.0
        minimap.set(not minimap.on())
    else
        last_m = clock
    end
end

local function forget_world()
    drop_view()
    data, data_in, data_said, gps, gps_in = nil, 0.0, false, false, 0.0
    comp, comp_for, marks, marks_in = nil, nil, {}, 0.0
    mark_actors, sweep_at, mark_n, map_open, map_in = {}, 0.0, nil, false, 0.0
    mates, mates_in = {}, 0.0
    big.by, big.mw, big.open = {}, nil, false   -- the old world's widgets are freed: dropped without touching them
    cmp.w, cmp.for_pc, cmp.find_at, cmp.find_gap, cmp.hidden = nil, nil, 0.0, nil, nil
    view.broken = false   -- (a build that failed is tried again in the next world, not given up on until a restart)
end

function minimap.init()
    load()
    game.keybind("M", nil, on_m)
    game.on_tick(minimap.tick)
    game.on_world_reset(forget_world)
    -- a death takes every widget off the screen with the same controller (notify.lua): build it again
    game.on_widgets_cleared(drop_view)
    log.info("minimap: " .. (on and "on" or "off") .. " (M twice switches it)")
end

-- tests: the logic without the engine
minimap._test = { view = view, press = on_m, compass = cmp, marks = function() return marks end, big = big,
    mates = function() return mates end, reset = function()
    on, loaded, clock, last_m = false, false, 0.0, -100.0
    forget_world()
    view.broken = false
end }

return minimap
