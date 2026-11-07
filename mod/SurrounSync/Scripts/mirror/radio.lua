-- Car and buildable radios: songs from a folder, and a button on the radio screen that opens it.
-- The game's RadioComponent plays the files in <game folder>\Radio (GameFunctionLibrary.GetGameDirectory: the
-- packaged project folder "../../../SurrounDead/" minus its last folder, so "../../../" from Binaries\Win64 - the
-- folder with SurrounDead.exe). The game never makes that folder and ships no songs in it, so a radio turned on
-- stays silent (user 2026-11-01: "car radios dont work", "add the ability too add custom mp4 songs"). Any file the
-- game's media players read plays (WmfMedia + Electra are packaged: .mp4, .mp3, .wav).
-- The game reads the folder once, at the radio's BeginPlay (FindFiles into "Found Files"): a radio that is off is
-- made to read it again while its screen is up, so songs added during play are there when it's turned on.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local notify = require("mirror.notify")
local fs = require("mirror.fs")

local radio = {}

radio.DIR = "..\\..\\..\\Radio"
local TOGGLE = "/Game/Blueprints/Components/RadioComponent.RadioComponent_C:ToggleRadioUI"
local UMG = "/Script/UMG."
local LABEL = "SONGS FOLDER"
local RESCAN_S = 2.0

local S = { comp = nil, ui = nil, btn = nil, pressed = false, scan_in = 0.0, told = false }
local hook_in = 0.0
local UI_LOOK_S = 0.2

local function prop(o, k)
    local v
    pcall(function() v = o[k] end)
    return v
end

local function forget()
    S.comp, S.ui, S.btn, S.pressed, S.scan_in, S.told = nil, nil, nil, false, 0.0, false
end

local function new(cls, outer)
    local o
    pcall(function() o = StaticConstructObject(StaticFindObject(UMG .. cls), outer) end)
    return util.valid(o) and o or nil
end

-- The button goes beside the game's own and is dressed like one: its button style, its slot padding and alignment,
-- its label's font and colour. Game build 26467602 made a new radio screen: PAUSE, PLAY, SHUFFLE, PREVIOUS in a row
-- (HorizontalBox_2, each an icon and a label) and no NEXT; ours goes after PREVIOUS. Before that: under NEXT in
-- VerticalBox_0 (power, next, previous, pause), its label the button's own TextBlock.
local ANCHORS = { "PreviousButton", "NextButton" }

-- the TextBlock that labels a game button: the first TextBlock in a content panel (icon + label), else the content
local function label_of(btn)
    local c
    pcall(function() c = btn:GetContent() end)
    if not util.valid(c) then return nil end
    local n = 0
    pcall(function() n = c:GetChildrenCount() end)
    if not n or n <= 0 then return c end
    for i = 0, n - 1 do
        local w
        pcall(function() w = c:GetChildAt(i) end)
        if util.valid(w) and util.class_name(w) == "TextBlock" then return w end
    end
    return nil
end

-- ours already on the panel: forget() after a death (or a world reset) while the game kept its radio screen, and the
-- next look at it put a second SONGS FOLDER button under the first (audit 2026-11-03)
local function on_panel(vb)
    local n = 0
    pcall(function() n = vb:GetChildrenCount() end)
    for i = 0, (n or 0) - 1 do
        local w, c, s
        pcall(function() w = vb:GetChildAt(i) end)
        if util.valid(w) then pcall(function() c = w:GetContent() end) end
        if util.valid(c) then pcall(function() s = c:GetText():ToString() end) end
        if s == LABEL then return w end
    end
    return nil
end

local function add_button(ui)
    local nb
    for _, k in ipairs(ANCHORS) do
        nb = prop(ui, k)
        if util.valid(nb) then break end
    end
    if not util.valid(nb) then return nil, "no " .. table.concat(ANCHORS, " or ") end
    local vb
    pcall(function() vb = nb:GetParent() end)
    if not util.valid(vb) then return nil, "no panel" end
    local row = util.class_name(vb) == "HorizontalBox"
    local had = on_panel(vb)
    if had then return had end
    local tree = prop(ui, "WidgetTree")
    if not util.valid(tree) then return nil, "no widget tree" end
    local b, t = new("Button", tree), new("TextBlock", tree)
    if not (b and t) then return nil, "couldn't create the button" end
    -- (the field, not SetStyle: UE4SS builds a UFunction's parameters in a 0x200-byte stack buffer and copies a struct
    -- in whole, and FButtonStyle - four brushes - is about twice that; SetStyle wrote past it and the game closed on R,
    -- 0xc0000409 in UE4SS, DBG-20261103-004. A field write copies into the button itself. Set before it joins the
    -- panel: its Slate button is built from the field then)
    if not pcall(function() b.WidgetStyle = nb.WidgetStyle end) then
        pcall(function() b:SetBackgroundColor({ R = 0.25, G = 0.25, B = 0.25, A = 1 }) end)
    end
    pcall(function() t:SetText(FText(LABEL)) end)
    local src = label_of(nb)
    if util.valid(src) then
        -- the new TextBlock's own complete font with the fields changed (a partly filled FSlateFontInfo crashed a
        -- menu on paint, names.lua)
        pcall(function()
            local f, g = t.Font, src.Font
            f.FontObject, f.TypefaceFontName, f.Size = g.FontObject, g.TypefaceFontName, g.Size
            t:SetFont(f)
        end)
        pcall(function() t:SetColorAndOpacity(src.ColorAndOpacity) end)
    end
    pcall(function() b:SetContent(t) end)
    local s
    pcall(function() if row then s = vb:AddChildToHorizontalBox(b) else s = vb:AddChildToVerticalBox(b) end end)
    if not s then return nil, "couldn't add the button" end
    pcall(function()
        local ns = nb.Slot
        s:SetPadding(ns.Padding)
        s:SetHorizontalAlignment(ns.HorizontalAlignment)
    end)
    if row then
        -- (explicit numbers, not the game's struct passed back: UE4SS copies a struct parameter whole)
        pcall(function() s:SetVerticalAlignment(nb.Slot.VerticalAlignment) end)
        pcall(function() local z = nb.Slot.Size; s:SetSize({ SizeRule = z.SizeRule, Value = z.Value }) end)
    end
    return b
end

local function count_files()
    local list = fs.list_files(radio.DIR)
    return list and #list or 0
end

-- a radio that is off reads the folder again when it changed (its BeginPlay: FindFiles, then a fresh MediaPlayer;
-- the old one is closed - StopRadio closes it, and one never turned on never opened). Never while it plays: the
-- playing MediaPlayer would be orphaned, still bound to the car's MediaSound.
local function rescan(comp)
    if prop(comp, "TurnedOn?") == true then return false end
    local known
    pcall(function() known = comp["Found Files"]:GetArrayNum() end)
    local n = count_files()
    if known == nil or known == n then return false end
    local ok = pcall(function() comp:ReceiveBeginPlay() end)
    log.info(string.format("radio: %d song(s) in the Radio folder (it knew %d) - read again%s", n, known, ok and "" or " - FAILED"))
    return ok
end

-- (fs.mkdir is UE's MakeDirectory: true when the folder is already there. Not fs.dir_exists: its probe file, left
-- behind once, would be a "song" the radio picks. Not savefs: only the save modules may load it)
function radio.open_folder()
    if not fs.mkdir(radio.DIR) then
        notify.show("Couldn't make the Radio folder next to SurrounDead.exe.", "warn")
        log.warn("radio: couldn't create " .. radio.DIR)
        return false
    end
    -- the bridge opens it, off the game thread: os.execute('start ...') here waits for cmd and Explorer, and froze the
    -- game 5 s at each click (2026-11-03: "hella lag spike when opening radio folder"). No bridge: the old way
    local ok = require("mirror.link").bridge_cmd("openradio")
    if not ok then ok = pcall(function() os.execute('start "" "' .. radio.DIR .. '"') end) end
    notify.show("Put .mp4 or .mp3 songs in the Radio folder that just opened, then turn the radio on.", "info", "radio.folder")
    log.info("radio: opened the Radio folder" .. (ok and "" or " - FAILED"))
    return ok
end

local function clicked(b)
    local pressed, hov = false, false
    pcall(function() pressed = b:IsPressed() == true end)
    pcall(function() hov = b:IsHovered() == true end)
    -- (pad A on the button Slate's pad navigation focused: no hover from focus; journal_tab.lua)
    if not hov and S.pressed and not pressed then pcall(function() hov = b:HasKeyboardFocus() == true end) end
    local was = S.pressed
    S.pressed = pressed
    return was and not pressed and hov
end

local function on_toggle(self)
    local comp
    pcall(function() comp = self:get() end)
    if util.valid(comp) then S.comp, S.ui_in = comp, 0.0 end
end
local toggle_fn = function(self) util.safe(on_toggle, "radio.toggle", self) end

function radio.tick(dt)
    dt = dt or 0
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 1.0
        util.ensure_hook(TOGGLE, toggle_fn)
    end
    local comp = S.comp
    if not comp then return end
    if not util.valid(comp) then forget(); return end
    -- (no screen up: S.comp stays for the rest of the world, not read every frame for it; a toggle looks at once)
    if not S.ui then
        S.ui_in = (S.ui_in or 0.0) - dt
        if S.ui_in > 0 then return end
        S.ui_in = UI_LOOK_S
    end
    local ui = prop(comp, "RadioUI")
    if not util.valid(ui) then
        if S.ui then S.ui, S.btn, S.pressed, S.told = nil, nil, false, false end
        return
    end
    -- (by address: each RadioUI read is a new UE4SS wrapper and two never compare equal - with ~= a button was added
    -- every tick, its click state reset every tick and the folder listed every frame; audit 2026-11-02)
    if not util.same(ui, S.ui) then
        S.ui, S.btn, S.pressed, S.scan_in = ui, nil, false, 0.0
        local b, why = add_button(ui)
        S.btn = b
        if not b then log.warn("radio: no " .. LABEL .. " button on the radio screen (" .. tostring(why) .. ")") end
        if not S.told and count_files() == 0 then
            S.told = true
            notify.show("No songs yet: press " .. LABEL .. " on the radio and put .mp4 or .mp3 files in it.", "info", "radio.empty")
        end
    end
    if S.btn and clicked(S.btn) then radio.open_folder(); S.scan_in = 0.0 end
    S.scan_in = S.scan_in - dt
    if S.scan_in <= 0 then
        S.scan_in = RESCAN_S
        rescan(comp)
    end
end

function radio.init()
    -- made at start, so the folder is there to find before anyone opens a radio
    if not fs.mkdir(radio.DIR) then log.warn("radio: couldn't create " .. radio.DIR) end
    game.on_tick(radio.tick)
    game.on_world_reset(forget)
    -- a death takes every widget off the screen (notify.lua): the radio screen and the button with it
    game.on_widgets_cleared(forget)
end

-- tests: the logic without the engine
radio._test = { toggle = on_toggle, state = S, forget = forget, rescan = rescan }

return radio
