-- Message of the day: one message from SurrounSync's makers to every player.
--
-- tools/motd.ps1 sets it on the Realms server; the bridge asks for it every minute and writes mirror_motd.txt
-- ("motd <id> <expires, unix s, 0 = never> <text>" or "motd none", then END). In a world each message shows once as
-- a card (and stays in the message history, Ctrl+F9); at the main menu, where no player ticks, a banner at the top
-- shows the current one for as long as the menu is up (polled on the game thread, util.game_loop, as realmplay
-- presses NEW GAME): hidden while the menu is off the screen (New Game, Load), gone when the message changes or a
-- world loads.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local fs = require("mirror.fs")
local notify = require("mirror.notify")

local motd = {}

local FILE, SEEN = "\\mirror_motd.txt", "\\mirror_motd_seen.txt"
local TITLE = "MESSAGE FROM SYMPLYSCK"   -- (user 2026-10-31; card headings are capitals)
local READ_EVERY, FIRST_READ = 5.0, 8.0     -- s in a world; the first read waits for the load to settle
local CARD_SECS = 25.0                      -- the card in a world (user 2026-10-31: was 120 s, sticky)
local LOAD_LEVEL = "/Game/Blueprints/SD_GameInstance.SD_GameInstance_C:Event_LoadLevel"
local MENU = "MenuWidget_C"
local MENU_POLL_MS, MENU_SETTLE = 1000, 2   -- the menu up 2 polls (s) before the banner goes on
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"
local SHELL = "/Game/JigSInventory/Jigsaw/Widgets/BP_StatTextW.BP_StatTextW_C"
local UMG = "/Script/UMG."
local BANNER_WRAP, BANNER_TOP = 900, 28
local BG = { R = 0.02, G = 0.02, B = 0.025, A = 0.86 }
local WHITE = { R = 0.96, G = 0.96, B = 0.96, A = 1 }
local ACCENT = { R = 0.70, G = 0.72, B = 0.75, A = 1 }
local COLLAPSED, HIT_INVISIBLE = 1, 3

local dir = function() return require("mirror.link").dir() end
local seen_id          -- the newest message shown in a world (nil: not read yet, false: none); kept in SEEN
local read_in = FIRST_READ
local ticks = 0        -- player ticks: the main menu poll stops once a world runs
local polling = false
local banner = nil     -- { w, id, shown } on the main menu

-- the bridge's file -> { id, expires, text }, or nil (no file, half written, "motd none", expired)
function motd.parse(s, t)
    if type(s) ~= "string" or not s:find("\nEND\n", 1, true) then return nil end
    local id, exp, text = (s:match("^([^\n]*)\n") or ""):match("^motd ([0-9A-Z]+) (%d+) (.+)$")
    if not id or #id ~= 8 then return nil end
    exp = tonumber(exp)
    if exp > 0 and exp <= (t or os.time()) then return nil end
    return { id = id, expires = exp, text = text }
end

function motd.current() return motd.parse(fs.read(dir() .. FILE)) end

local function seen()
    if seen_id == nil then
        local s = fs.read(dir() .. SEEN)
        seen_id = s and s:match("^([0-9A-Z]+)") or false
    end
    return seen_id or nil
end

-- ---- in a world: once per message ----

local function in_world()
    local m = motd.current()
    if not m or m.id == seen() then return end
    seen_id = m.id
    if not fs.write(dir() .. SEEN, m.id .. "\n") then log.warn("motd: couldn't note message " .. m.id .. " as seen") end
    notify.show(m.text, "info", "motd", true, { title = TITLE, secs = CARD_SECS })
end

-- ---- at the main menu: a banner while the menu is on screen ----

local function new(cls, outer)
    local o
    pcall(function() o = StaticConstructObject(StaticFindObject(UMG .. cls), outer) end)
    if not util.valid(o) then error("couldn't create " .. cls) end
    return o
end

local function label(tree, s, size, bold, wrap, colour)
    local t = new("TextBlock", tree)
    pcall(function() t:SetText(FText(s)) end)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = colour or WHITE, ColorUseRule = 0 }) end)
    -- (the TextBlock's own complete font with fields changed: a half filled FSlateFontInfo crashed a paint, names.lua)
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

local function drop_banner()
    local b = banner
    banner = nil
    if b and util.valid(b.w) then pcall(function() b.w:RemoveFromParent() end) end
end

local function build_banner(menu_w, m)
    local wbl, shell, pc = util.cdo(WBL), StaticFindObject(SHELL), nil
    pcall(function() pc = menu_w:GetOwningPlayer() end)
    if not (wbl and util.valid(pc) and util.valid(shell)) then return false end
    local w
    pcall(function() w = wbl:Create(pc, shell, pc) end)
    if not util.valid(w) then return false end
    local tree = w.WidgetTree
    local canvas = new("CanvasPanel", tree)
    tree.RootWidget = canvas
    local box = new("Border", tree)
    pcall(function() box:SetBrushColor(BG) end)
    pcall(function() box:SetPadding({ Left = 24, Top = 14, Right = 24, Bottom = 16 }) end)
    local cs = canvas:AddChildToCanvas(box)
    pcall(function()
        cs:SetAnchors({ Minimum = { X = 0.5, Y = 0 }, Maximum = { X = 0.5, Y = 0 } })
        cs:SetAlignment({ X = 0.5, Y = 0 })
        cs:SetPosition({ X = 0, Y = BANNER_TOP })
        cs:SetAutoSize(true)
    end)
    local col = new("VerticalBox", tree)
    pcall(function() box:SetContent(col) end)
    col:AddChildToVerticalBox(label(tree, TITLE, 13, true, nil, ACCENT))
    local bs = col:AddChildToVerticalBox(label(tree, m.text, 20, false, BANNER_WRAP))
    pcall(function() bs:SetPadding({ Left = 0, Top = 5, Right = 0, Bottom = 0 }) end)
    pcall(function() canvas:SetVisibility(HIT_INVISIBLE) end)   -- (never in the way of a click)
    pcall(function() w:AddToViewport(45) end)
    banner = { w = w, id = m.id, shown = true }
    return true
end

local function menu_on_screen()
    for _, w in ipairs(FindAllOf(MENU) or {}) do
        local on = false
        if util.valid(w) then pcall(function() on = w:IsInViewport() end) end
        if on then return w end
    end
    return nil
end

-- one poll on the game thread: the banner follows the menu (shown while it is up) and the current message
local function menu_step(st)
    st.polls = st.polls + 1
    local mw = menu_on_screen()
    if (mw ~= nil) ~= st.on then
        st.on = mw ~= nil
        log.info("motd: main menu " .. (st.on and "on" or "off") .. " screen")
    end
    if mw then st.up_since = st.up_since or st.polls else st.up_since = nil end
    local m = motd.current()
    if banner and (not util.valid(banner.w) or not m or m.id ~= banner.id) then drop_banner() end
    if m and mw and not banner and m.id ~= st.failed and st.up_since and st.polls - st.up_since >= MENU_SETTLE then
        local ok, built = pcall(build_banner, mw, m)
        log.info("motd: main menu banner for message " .. m.id .. " -> " .. tostring(ok and built)
            .. (ok and "" or (" " .. tostring(built))))
        if not (ok and built) then drop_banner(); st.failed = m.id end   -- (that message not tried again this time)
    end
    if banner and banner.shown ~= (mw ~= nil) then
        banner.shown = mw ~= nil
        pcall(function() banner.w:SetVisibility(banner.shown and HIT_INVISIBLE or COLLAPSED) end)
    end
end

local function poll_menu()
    if polling then return end
    polling = true
    local st = { polls = 0, up_since = nil, at_ticks = ticks }
    local stop = util.game_loop(MENU_POLL_MS, function()
        -- (a world's player ticking: stop, the world tick takes the banner away)
        if ticks > st.at_ticks + 1 then polling = false; return true end
        menu_step(st)
    end, "motd.menu")
    if not stop then polling = false end
end

local function on_level(_, LevelName)
    local lv
    pcall(function() lv = LevelName:get():ToString() end)
    if lv == "MainMenu" then poll_menu()
    elseif banner then util.safe(drop_banner, "motd.drop_banner") end   -- (a world loads: not kept past its GC)
end

function motd.init()
    game.on_tick(function(dt)
        ticks = ticks + 1
        if banner then util.safe(drop_banner, "motd.drop_banner") end
        read_in = read_in - (dt or 0)
        if read_in > 0 then return end
        read_in = READ_EVERY
        util.ensure_hook(LOAD_LEVEL, on_level, nil, true)
        in_world()
    end)
    game.on_world_reset(function() read_in = FIRST_READ end)
    -- every widget off the screen: the banner goes too, before the GC can free it under us
    game.on_widgets_cleared(drop_banner)
    util.ensure_hook(LOAD_LEVEL, on_level, nil, true)
    poll_menu()   -- (the game starts at its main menu)
end

-- tests: the logic without the engine
motd._test = {
    in_world = in_world, menu_step = menu_step,
    banner = function() return banner end,
    reset = function() seen_id, banner, read_in, ticks, polling = nil, nil, FIRST_READ, 0, false end,
}

return motd
