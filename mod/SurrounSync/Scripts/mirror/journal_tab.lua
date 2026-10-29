-- The CO-OP tab in the J handbook. Built at runtime from the handbook's own widgets.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")

local journal_tab = {}

local UMG = "/Script/UMG."
local CLICK_CUE = "/Game/Audio/SurvivalSoundPack/Cues/UI_click_sound_Cue.UI_click_sound_Cue"
local GS = "/Script/Engine.Default__GameplayStatics"
local BLACK = { R = 0.0, G = 0.0, B = 0.0, A = 1.0 }
local DARK_RED = { R = 0.5, G = 0.0, B = 0.0, A = 1.0 }
local GREY = { R = 0.25, G = 0.25, B = 0.25, A = 1.0 }
local CLEAR = { R = 1.0, G = 1.0, B = 1.0, A = 0.0 }
local MARKERS = { InfoMarker = { -189.0, -540.0 }, SkillsMarker = { -192.0390625, -520.0 }, QuestMarker = { -203.0390625, -498.0 } }
local RIBBON_TINT = { R = 0.45, G = 1.0, B = 0.45, A = 1.0 }
local TILT = { paper = 5.0, ribbon = 6.0, piece = 5.0, list = 3.5, banner = -2.0 }
local RIBBON_STEP = { X = -13.0, Y = 150.0 }
-- The handbook's own tab labels (JournalUI asset): each Button sits in the same Overlay, centred, angle -80,
-- text size 34 (QUESTS), slot padding INFO 156,193 -> SKILLS 130,36 -> QUESTS 112,-125. Ours are set up the
-- same way; their paddings were MEASURED in-game (scratchpad ribbons.py: label middle vs ribbon middle in a
-- screenshot) so they sit on their ribbons like QUESTS does: 4 px below the middle, ~1 px right.
-- (CO-OP at Bottom -287 sat 12 px low; 1 Bottom unit = 0.75 px, 1 Left unit = ~1.15 px at 960 px wide)
local LABEL_PAD = { Left = 98.0, Bottom = -279.0 }
local LIST_WIDTH = 560.0
local GEAR_TEX = "/Game/UI/Textures/over_250_survival_flat_icons/gear.gear"
local CLOSE_TEX = "/Game/UI/Textures/CrossX.CrossX"
local INK = { R = 0.12, G = 0.08, B = 0.06, A = 1.0 }
local GREEN = { R = 0.03, G = 0.40, B = 0.08, A = 1.0 }   -- (dark enough to read on the page's paper)
local SETTING_ROWS = 10   -- MY SETTINGS: SyncFX on top of the 9 others
local TAG_COLOR = { R = 0.6, G = 0.13, B = 0.0, A = 1.0 }   -- burnt orange tag in front of a label (a row's tag_color wins)
local MOD_ROWS = 9
local REALM_ROWS = 3   -- per page on the lined note (more Realms: < PREV / NEXT >)
local PEOPLE_ROWS, PEOPLE_PER_ROW = 2, 4   -- WHO'S IN: one label per member (more: "+N more" in the last one)
-- the MODS tab: one ribbon below CO-OP (label spot found in-game; the ribbon art is yellow, so a tint can only
-- darken it: orange, not blue)
local MODS_TINT = { R = 1.0, G = 0.5, B = 0.35, A = 1.0 }
-- (REALMS at Left 85 / Bottom -423 sat 10 px right and 2 px above where QUESTS sits; MODS uses the same spot)
local MODS_PAD = { Left = 79.0, Bottom = -426.0 }
-- The game fades the handbook in/out over 0.5 s (JournalUI "Fade", after a 0.25 s double-tap wait for
-- the clock); playing that fade 8x faster makes J feel ~0.45 s quicker.
local FADE_SPEED = 8.0

local ctx = nil
local S = nil
local failed_at = -100
local clock = 0.0

local function new(cls_name, outer, name)
    local cls = StaticFindObject(UMG .. cls_name)
    if not util.valid(cls) then error("no class " .. cls_name) end
    local o
    pcall(function() o = StaticConstructObject(cls, outer, FName("SurrounSync_" .. name .. "_" .. math.random(1, 1e9)), 0) end)
    if not util.valid(o) then pcall(function() o = StaticConstructObject(cls, outer) end) end
    if not util.valid(o) then error("couldn't create " .. cls_name) end
    return o
end

local function texture_of(img)
    local t
    pcall(function() t = img.Brush.ResourceObject end)
    return util.valid(t) and t or nil
end

local function image_from(tex, outer, name, natural)
    local img = new("Image", outer, name)
    pcall(function() img:SetBrushFromTexture(tex, natural == true) end)
    pcall(function() img:SetVisibility(4) end)
    return img
end

local function step(what) log.info("journal_tab: " .. what) end

local function vis(w, on) pcall(function() w:SetVisibility(on and 4 or 1) end) end
local function vis_hit(w, on) pcall(function() w:SetVisibility(on and 0 or 1) end) end
local function set(t, s) pcall(function() t:SetText(FText(s)) end) end
local function tilt(w, angle) pcall(function() w:SetRenderTransformAngle(angle) end) end

local function find(tree, name, owner)
    local w
    if owner then pcall(function() w = owner[name] end) end
    if util.valid(w) then return w end
    pcall(function() w = tree:FindWidget(FName(name)) end)
    if util.valid(w) then return w end
    local function walk(p, depth)
        if depth > 8 or not util.valid(p) then return nil end
        local n
        pcall(function() n = util.fname(p) end)
        if n == name then return p end
        local count = 0
        pcall(function() count = p:GetChildrenCount() end)
        for i = 0, (count or 0) - 1 do
            local c
            pcall(function() c = p:GetChildAt(i) end)
            local hit = walk(c, depth + 1)
            if hit then return hit end
        end
        if count == 0 then
            local c
            pcall(function() c = p:GetContent() end)
            if util.valid(c) and not util.same(c, p) then return walk(c, depth + 1) end
        end
        return nil
    end
    local root
    pcall(function() root = tree.RootWidget end)
    return walk(root, 0)
end

local function style_text(t, size, color)
    pcall(function()
        local f = S.font
        f.Size = size
        t:SetFont(f)
    end)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = color or BLACK, ColorUseRule = 0 }) end)
end

local function input(name, hint, size, width)
    local e = new("EditableText", S.tree, name)
    pcall(function() e.WidgetStyle.ColorAndOpacity = { SpecifiedColor = BLACK, ColorUseRule = 0 } end)
    pcall(function() e:SetHintText(FText(hint)) end)
    pcall(function() local f = S.font; f.Size = size; e:SetFont(f) end)
    pcall(function() e:SetMinimumDesiredWidth(width) end)
    return e
end

local function text(s, size, color, wrap)
    local t = new("TextBlock", S.tree, "Text")
    set(t, s)
    style_text(t, size, color)
    if wrap then
        pcall(function() t:SetAutoWrapText(true) end)
        pcall(function() t:SetWrapTextAt(wrap) end)
    end
    return t
end

local function button(label, size, color)
    local b = new("Button", S.tree, "Button")
    pcall(function() b:SetBackgroundColor(CLEAR) end)
    local t = text(label, size or 24, color)
    pcall(function() b:SetContent(t) end)
    S.buttons[#S.buttons + 1] = { b = b, t = t }
    return b, t
end

local function vadd(box, w, pad)
    local s
    pcall(function() s = box:AddChildToVerticalBox(w) end)
    if pad then pcall(function() s:SetPadding({ Left = 0, Top = pad, Right = 0, Bottom = 0 }) end) end
    return s
end

local function hadd(box, w, gap)
    local s
    pcall(function() s = box:AddChildToHorizontalBox(w) end)
    if gap then pcall(function() s:SetPadding({ Left = gap, Top = 0, Right = 0, Bottom = 0 }) end) end
    pcall(function() s:SetVerticalAlignment(2) end)
    return s
end

-- n: how many ribbons below the quests one (1 = CO-OP, 2 = MODS)
local function add_ribbon(page_tree, canvas, owner, outer, n, tint)
    n = n or 1
    local qm = find(page_tree, "QuestMarker", owner)
    if not qm then error("no QuestMarker on a handbook page") end
    local tex = texture_of(qm)
    if not tex then error("no ribbon texture") end
    local img = image_from(tex, outer or page_tree, "Ribbon")
    pcall(function() img:SetColorAndOpacity(tint or RIBBON_TINT) end)
    tilt(img, TILT.ribbon)
    local slot = canvas:AddChildToCanvas(img)
    pcall(function()
        slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.5 }, Maximum = { X = 0.0, Y = 0.5 } })
        slot:SetOffsets({ Left = -203.0390625 + n * RIBBON_STEP.X, Top = -498.0 + n * RIBBON_STEP.Y, Right = 1920.0, Bottom = 1080.0 })
        slot:SetZOrder(-1)
    end)
    return img
end

local function place(canvas, w, x, y, wd, ht, z)
    if S.coop then S.coop[#S.coop + 1] = w end
    local sl = canvas:AddChildToCanvas(w)
    pcall(function() sl:SetZOrder(z or 5) end)
    pcall(function()
        sl:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
        sl:SetPosition({ X = x, Y = y })
        if wd then sl:SetAutoSize(false); sl:SetSize({ X = wd, Y = ht }) else sl:SetAutoSize(true) end
    end)
    return sl
end

local function centered(t) pcall(function() t:SetJustification(1) end) end

local function build_content(page, qtree, qpage)
    local u = S.ui
    S.coop = {}
    local function tex(name) local w = find(qtree, name, qpage); return w and texture_of(w) end

    u.headline = text("", 36, DARK_RED, 635); centered(u.headline); tilt(u.headline, TILT.piece)
    place(page, u.headline, 410.0, 17.0, 635.0, 108.0)
    u.detail = text("", 16, BLACK, 670); centered(u.detail); tilt(u.detail, TILT.piece)
    place(page, u.detail, 395.0, 147.0, 690.0, 95.0)
    u.update, u.update_t = button("UPDATE", 24, DARK_RED); tilt(u.update, TILT.piece)
    place(page, u.update, 560.0, 196.0)

    local note = new("Overlay", S.tree, "Note")
    tilt(note, TILT.piece)
    place(page, note, 246.578, 175.916, 853.0, 480.0, 3)
    local note_tex = tex("Image_225")
    if note_tex then
        local img = image_from(note_tex, S.tree, "NoteImage")
        local ns = note:AddChildToOverlay(img)
        pcall(function() ns:SetHorizontalAlignment(0); ns:SetVerticalAlignment(0) end)
    end
    local banner = text("CO-OP", 58, DARK_RED)
    tilt(banner, TILT.banner)
    local bs = note:AddChildToOverlay(banner)
    pcall(function()
        bs:SetPadding({ Left = 0.0, Top = 0.0, Right = 10.0, Bottom = 132.0 })
        bs:SetHorizontalAlignment(2); bs:SetVerticalAlignment(2)
    end)
    local card = new("VerticalBox", S.tree, "Card")
    tilt(card, TILT.list)
    place(page, card, 433.0, 337.5, 500.0, 200.0)
    u.me = text("", 16, GREY, 480); vadd(card, u.me)
    local row = new("HorizontalBox", S.tree, "CodeRow"); vadd(card, row, 6)
    hadd(row, text("FRIEND CODE:", 22))
    u.code = text("", 22, DARK_RED); hadd(row, u.code, 8)
    u.copy = button("COPY", 20); hadd(row, u.copy, 14)
    local acts = new("HorizontalBox", S.tree, "Actions"); vadd(card, acts, 14)
    u.host = button("HOST A GAME", 26); hadd(acts, u.host)
    u.join_local = button("JOIN", 26); hadd(acts, u.join_local, 20)
    u.leave = button("LEAVE CO-OP", 26); hadd(acts, u.leave, 20)
    u.stop = button("STOP HOSTING", 26); hadd(acts, u.stop, 20)
    u.public, u.public_t = button("PUBLIC: OFF", 22); hadd(acts, u.public, 20)
    u.go_home = button("GO HOME NOW", 24); hadd(acts, u.go_home, 20)
    u.wait = button("WAIT", 24); hadd(acts, u.wait, 20)
    local vr = new("HorizontalBox", S.tree, "VoiceRow"); vadd(card, vr, 10)
    u.voice_btn, u.voice_t = button("VOICE: OFF", 20); hadd(vr, u.voice_btn)
    u.voice_vol, u.voice_vol_t = button("VOL 100%", 20); hadd(vr, u.voice_vol, 20)
    u.report = button("BUG REPORT", 20); hadd(vr, u.report, 20)

    for _, k in ipairs({ { "ActiveQuests", "folder_friends" }, { "CompletedQuests", "folder_backups" } }) do
        local t = tex(k[1])
        if t then
            u[k[2]] = image_from(t, S.tree, k[1])
            tilt(u[k[2]], TILT.piece)
            u[k[2] .. "_slot"] = place(page, u[k[2]], 21.0, 465.0, 1280.0, 720.0, 1)
        end
    end
    u.sec_friends = button("FRIENDS", 20); tilt(u.sec_friends, TILT.piece); place(page, u.sec_friends, 419.0, 584.888)
    u.sec_backups = button("BACKUPS", 20); tilt(u.sec_backups, TILT.piece); place(page, u.sec_backups, 619.0, 600.0)

    u.friends_box = new("VerticalBox", S.tree, "Friends")
    tilt(u.friends_box, TILT.piece)
    place(page, u.friends_box, 372.0, 655.0, 575.0, 370.0)
    u.req_title = text("JOIN REQUESTS", 26, DARK_RED); vadd(u.friends_box, u.req_title)
    u.reqs = {}
    for i = 1, 3 do
        local rr = new("HorizontalBox", S.tree, "Request"); vadd(u.friends_box, rr, 2)
        local name = text("", 22)
        local ba, bl, bd = button("ACCEPT", 20), button("ALWAYS", 20), button("DECLINE", 20)
        hadd(rr, name); hadd(rr, ba, 14); hadd(rr, bl, 10); hadd(rr, bd, 10)
        u.reqs[i] = { row = rr, name = name, accept = ba, allow = bl, decline = bd }
    end
    u.clear_allowed, u.clear_allowed_t = button("", 18); vadd(u.friends_box, u.clear_allowed, 4)
    -- the host's guests, each with KICK (pressed twice: the first press asks "SURE?")
    u.guests_title = text("PLAYERS IN YOUR WORLD", 26, DARK_RED); vadd(u.friends_box, u.guests_title, 6)
    u.guests = {}
    for i = 1, 3 do
        local gr = new("HorizontalBox", S.tree, "Guest"); vadd(u.friends_box, gr, 2)
        local name = text("", 22)
        local b, bt = button("KICK", 20)
        hadd(gr, name); hadd(gr, b, 14)
        u.guests[i] = { row = gr, name = name, btn = b, btn_t = bt }
    end
    local gt = new("HorizontalBox", S.tree, "GamesTitle"); vadd(u.friends_box, gt, 10)
    u.games_title = gt
    hadd(gt, text("GAMES TO JOIN", 26, DARK_RED))
    u.refresh = button("REFRESH", 18); hadd(gt, u.refresh, 18)
    u.none = text("", 16, GREY, LIST_WIDTH); vadd(u.friends_box, u.none, 2)
    u.friends = {}
    for i = 1, 4 do
        local fr = new("HorizontalBox", S.tree, "Friend"); vadd(u.friends_box, fr, 2)
        local name = text("", 22)
        local b = button("JOIN", 22)
        hadd(fr, name); hadd(fr, b, 18)
        u.friends[i] = { row = fr, name = name, btn = b }
    end
    u.code_title = text("JOIN WITH A CODE", 26, DARK_RED); vadd(u.friends_box, u.code_title, 14)
    local jr = new("HorizontalBox", S.tree, "CodeJoin"); vadd(u.friends_box, jr, 2)
    u.code_row = jr
    u.input = input("CodeInput", "type your friend's code", 22, 260)
    hadd(jr, u.input)
    u.join_code = button("JOIN", 22); hadd(jr, u.join_code, 18)
    local pr = new("HorizontalBox", S.tree, "PasswordRow"); vadd(u.friends_box, pr, 4)
    u.pw_row = pr
    u.pw_label = text("PASSWORD:", 20); hadd(pr, u.pw_label)
    u.pw_input = input("PasswordInput", "optional", 20, 180)
    pcall(function() u.pw_input:SetIsPassword(true) end)
    hadd(pr, u.pw_input, 8)
    u.pw_set, u.pw_set_t = button("SET", 20); hadd(pr, u.pw_set, 14)
    local cr = new("HorizontalBox", S.tree, "ChatRow"); vadd(u.friends_box, cr, 12)
    u.chat_title = text("CHAT", 26, DARK_RED); hadd(cr, u.chat_title)
    u.chat_input = input("ChatInput", "say something", 20, 280)
    hadd(cr, u.chat_input, 16)
    u.chat_send = button("SEND", 22); hadd(cr, u.chat_send, 14)
    u.chat_row = cr
    u.chat_lines = {}
    for i = 1, 3 do local t = text("", 16, BLACK, LIST_WIDTH); vadd(u.friends_box, t, 1); u.chat_lines[i] = t end
    -- the request text wraps on its own line (a long name ran past the page), the buttons go under it
    u.tp_row = new("VerticalBox", S.tree, "TeleportRow"); vadd(u.friends_box, u.tp_row, 6)
    u.tp_name = text("", 18, BLACK, LIST_WIDTH); vadd(u.tp_row, u.tp_name)
    local tb = new("HorizontalBox", S.tree, "TeleportButtons"); vadd(u.tp_row, tb, 2)
    u.tp_accept = button("ACCEPT", 20); hadd(tb, u.tp_accept)
    u.tp_decline = button("DECLINE", 20); hadd(tb, u.tp_decline, 10)

    local helpers = {
        new = function(cls, _tree) return new(cls, S.tree, "B" .. cls) end,
        text = function(_tree, s, size, rgb)
            local col = rgb and ((rgb[1] or 0) > 0.8 and DARK_RED or GREY) or BLACK
            return text(s, math.max(15, math.floor((size or 16) * 1.1)), col, LIST_WIDTH)
        end,
        button = function(_tree, label) return button(label:gsub("^%s+", ""):gsub("%s+$", ""):upper(), 20) end,
        vadd = vadd, hadd = hadd, vis = function(w, on) vis_hit(w, on) end, set = set,
        can_restore = ctx.can_restore,
        rows = 3, short = true,
    }
    u.backups_box = ctx.backups.build(S.tree, helpers)
    tilt(u.backups_box, TILT.piece)
    place(page, u.backups_box, 372.0, 640.0, 575.0, 385.0)
    vis_hit(u.backups_box, false)
    u.show_backups = false
    S.coop_list, S.coop = S.coop, nil
end

-- An icon at a fixed size with an empty, see-through button over it (a button's padding shrinks its content).
local function icon_button(page, path, fallback, x, y, size, z)
    local tex = StaticFindObject(path)
    local b = new("Button", S.tree, "IconButton")
    pcall(function() b:SetBackgroundColor(CLEAR) end)
    tilt(b, TILT.piece)
    if not util.valid(tex) then
        local t = text(fallback, 26)
        pcall(function() b:SetContent(t) end)
        S.buttons[#S.buttons + 1] = { b = b, t = t }
        place(page, b, x, y)
        return b, nil
    end
    local img = image_from(tex, S.tree, "Icon")
    pcall(function() img:SetColorAndOpacity(INK) end)
    pcall(function() img:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
    tilt(img, TILT.piece)
    place(page, img, x, y, size, size, z)
    place(page, b, x, y, size, size, z + 1)
    S.buttons[#S.buttons + 1] = { b = b, t = img }
    return b, img
end

-- The gear at the bottom of the CO-OP page swaps the page for the settings; X swaps back.
local function build_settings(page)
    local u = S.ui
    -- bottom right corner of the pink FRIENDS folder
    u.gear, u.gear_img = icon_button(page, GEAR_TEX, "SETTINGS", 827.0, 932.0, 96.0, 6)
    u.set_box = new("VerticalBox", S.tree, "Settings")
    tilt(u.set_box, TILT.list)
    -- (9 rows: from 230 the last one ran off the page, screenshot 2026-10-27; 10 rows from 150 too: 120, tighter rows)
    place(page, u.set_box, 420.0, 120.0, 580.0, 875.0, 6)
    u.set_title = text("SETTINGS", 58, DARK_RED); vadd(u.set_box, u.set_title)
    -- two pages: the host's rules for the shared world, and this PC's own settings
    local tabs = new("HorizontalBox", S.tree, "SettingTabs"); vadd(u.set_box, tabs, 2)
    u.set_tab_host, u.set_tab_host_t = button("HOST RULES", 28, DARK_RED); hadd(tabs, u.set_tab_host)
    u.set_tab_mine, u.set_tab_mine_t = button("MY SETTINGS", 28, GREY); hadd(tabs, u.set_tab_mine, 30)
    -- (with Realms on, the REALMS tab takes the MODS ribbon: the mods list opens from here)
    if S.realms_on then u.set_tab_mods = button("MODS", 28, GREY); hadd(tabs, u.set_tab_mods, 30) end
    u.set_tab = "host"
    u.set_sub = text("", 16, GREY, 560); vadd(u.set_box, u.set_sub, 4)
    u.set_rows = {}
    for i = 1, SETTING_ROWS do
        local row = new("HorizontalBox", S.tree, "SettingRow"); vadd(u.set_box, row, i == 1 and 8 or 2)
        local tag = text("", 26, TAG_COLOR)   -- e.g. SyncFX's "Optimizes Performance": collapsed on rows without one
        local label = text("", 26)
        local b, bt = button("OFF", 26, DARK_RED)
        hadd(row, tag); hadd(row, label); hadd(row, b, 24)
        local hint = text("", 16, GREY, 560); vadd(u.set_box, hint, 2)
        u.set_rows[i] = { row = row, tag = tag, label = label, btn = b, btn_t = bt, hint = hint }
    end
    -- (moved up with the box: at 215 it covered the MODS tab)
    u.set_close, u.set_close_img = icon_button(page, CLOSE_TEX, "X", 930.0, 135.0, 72.0, 7)
    vis_hit(u.set_box, false); vis_hit(u.set_close, false); vis(u.set_close_img, false)
    u.settings_mode = false
end

-- The MODS tab's page (on the CO-OP page's paper, like the settings): this PC's mods with ON/OFF, the other
-- side's choice next to each one in co-op, MATCH HOST for a guest, and a restart note after a change.
local function build_mods(page)
    local u = S.ui
    u.mods_box = new("VerticalBox", S.tree, "Mods")
    tilt(u.mods_box, TILT.list)
    place(page, u.mods_box, 420.0, 230.0, 580.0, 760.0, 6)
    vadd(u.mods_box, text("MODS", 58, DARK_RED))
    u.mods_sub = text("", 16, GREY, 560); vadd(u.mods_box, u.mods_sub, 2)
    u.mods_restart = text("", 20, DARK_RED, 560); vadd(u.mods_box, u.mods_restart, 6)
    u.mods_rows = {}
    for i = 1, MOD_ROWS do
        local row = new("HorizontalBox", S.tree, "ModRow"); vadd(u.mods_box, row, i == 1 and 10 or 6)
        local b, bt = button("OFF", 22, DARK_RED)
        local label = text("", 22)
        local note = text("", 15, GREY)
        hadd(row, b); hadd(row, label, 16); hadd(row, note, 12)
        u.mods_rows[i] = { row = row, btn = b, btn_t = bt, label = label, note = note }
    end
    u.mods_none = text("", 18, GREY, 560); vadd(u.mods_box, u.mods_none, 10)
    local nav = new("HorizontalBox", S.tree, "ModNav"); vadd(u.mods_box, nav, 14)
    u.mods_prev = button("< PREV", 20); hadd(nav, u.mods_prev)
    u.mods_page_t = text("", 18, GREY); hadd(nav, u.mods_page_t, 12)
    u.mods_next = button("NEXT >", 20); hadd(nav, u.mods_next, 12)
    u.mods_match, u.mods_match_t = button("MATCH HOST", 22, DARK_RED); hadd(nav, u.mods_match, 30)
    u.mods_page = 1
    vis_hit(u.mods_box, false)
end

-- The REALMS tab's page (Realms on: it takes the MODS ribbon, MODS moves to a tab of the settings), made of the
-- handbook's own paper pieces so it looks like the rest of the book:
--   the lined note taped to the page (info page "Note")       = MY REALMS, each with OPEN/JOIN/START, INVITE, KEY
--   the survivor's license card with its paperclip ("License") = the Realm I'm in right now (replaces the note)
--   the pink folder (quests page "ActiveQuests")               = START A NEW REALM / GOT AN INVITE?, or this
--                                                                 Realm's member tools while I'm in one
-- Everything sits on one canvas, so the tab shows and hides as one piece. The paper art is 1920x1080 with the
-- piece in the middle: sizes and offsets below put the visible paper where the text goes.
local REALM_NAME_W = 185.0   -- (the handbook's font is all capitals and wide: at 235 KEY ran past the note)
local LIVE_GREEN = { R = 0.06, G = 0.30, B = 0.08, A = 1.0 }
local TAPE_WHITE = { R = 0.93, G = 0.90, B = 0.82, A = 1.0 }
local TAPE_ORANGE = { R = 1.0, G = 0.55, B = 0.12, A = 1.0 }
local function sized(w, width)
    local sb = new("SizeBox", S.tree, "Size")
    pcall(function() sb:SetWidthOverride(width) end)
    pcall(function() sb:SetClipping(1) end)
    pcall(function() sb:SetContent(w) end)
    return sb
end

local function build_realms(page, qtree, qpage, itree, ipage)
    local u = S.ui
    local cv = new("CanvasPanel", S.tree, "RealmsCanvas")
    place(page, cv, 0.0, 0.0, 1400.0, 1100.0, 2)
    u.realms_canvas = cv
    local function art(tree, owner, name, x, y, w, h, z)
        local src = find(tree, name, owner)
        local t = src and texture_of(src)
        if not t then log.warn("journal_tab: no " .. name .. " art for the REALMS page"); return nil end
        local img = image_from(t, S.tree, "Realm" .. name)
        tilt(img, TILT.piece)
        place(cv, img, x, y, w, h, z)
        return img
    end

    -- title over the page, like the handbook's own headings
    local title = text("REALMS", 58, DARK_RED); tilt(title, TILT.banner)
    place(cv, title, 420.0, 18.0)
    -- (one line between the title and the note's tape)
    u.realms_sub = text("Shared worlds that live on, even when you're away.", 16, GREY, 520)
    tilt(u.realms_sub, TILT.piece)
    place(cv, u.realms_sub, 425.0, 108.0, 520.0, 24.0)

    -- MY REALMS on the taped, lined note
    u.realms_note = art(itree, ipage, "Note", 132.0, 103.0, 1054.0, 529.0, 3)
    -- the mod's name written on the note's grey tape: worn white + orange, shadowed, at the tape's slant
    -- (centre measured in-game at about 678,185; the tape slopes ~9 degrees)
    local brand = new("HorizontalBox", S.tree, "RealmBrand")
    tilt(brand, 9.0)
    for _, part in ipairs({ { "SURROUN", TAPE_WHITE }, { "SYNC", TAPE_ORANGE } }) do
        local t = text(part[1], 32, part[2])
        pcall(function() t:SetShadowOffset({ X = 2.0, Y = 2.0 }) end)
        pcall(function() t:SetShadowColorAndOpacity({ R = 0.0, G = 0.0, B = 0.0, A = 0.65 }) end)
        hadd(brand, t)
    end
    place(cv, brand, 572.0, 165.0, nil, nil, 6)
    u.realms_brand = brand
    local list = new("VerticalBox", S.tree, "RealmList")
    tilt(list, TILT.piece)
    place(cv, list, 428.0, 240.0, 465.0, 340.0, 6)   -- (below the tape)
    u.realms_list = list
    local head = new("HorizontalBox", S.tree, "RealmListHead"); vadd(list, head)
    hadd(head, text("MY REALMS", 30, DARK_RED))
    u.realms_refresh = button("REFRESH", 16, GREY); hadd(head, u.realms_refresh, 22)
    u.realms_state = text("", 16, DARK_RED, 460); vadd(list, u.realms_state, 2)
    u.realms_rows = {}
    for i = 1, REALM_ROWS do
        local row = new("HorizontalBox", S.tree, "RealmRow"); vadd(list, row, i == 1 and 8 or 6)
        local name = text("", 22, INK)
        local open, open_t = button("OPEN", 22, DARK_RED)
        local inv = button("INVITE", 16, GREY)
        local key = button("KEY", 16, GREY)
        hadd(row, sized(name, REALM_NAME_W)); hadd(row, open, 10); hadd(row, inv, 14); hadd(row, key, 10)
        local info = text("", 14, GREY, 460); vadd(list, info, 0)
        u.realms_rows[i] = { row = row, name = name, open = open, open_t = open_t, invite = inv, key = key, info = info }
    end
    u.realms_none = text("No Realms yet. Start one in the folder below, or add one with a friend's invite code.", 16, GREY, 440)
    vadd(list, u.realms_none, 14)
    local nav = new("HorizontalBox", S.tree, "RealmNav"); vadd(list, nav, 8)
    u.realms_prev = button("< PREV", 18); hadd(nav, u.realms_prev)
    u.realms_page_t = text("", 16, GREY); hadd(nav, u.realms_page_t, 12)
    u.realms_next = button("NEXT >", 18); hadd(nav, u.realms_next, 12)

    -- the Realm I'm in, on the license card (the paperclip holds it to the page)
    u.realms_card = art(itree, ipage, "License", 294.0, 93.0, 724.0, 408.0, 3)
    local card = new("VerticalBox", S.tree, "RealmCard")
    tilt(card, TILT.piece)
    place(cv, card, 436.0, 225.0, 450.0, 220.0, 6)   -- (below the paperclip)
    u.realms_cardbox = card
    u.realms_cur_kind = text("YOUR REALM", 16, GREY); vadd(card, u.realms_cur_kind)
    u.realms_cur_name = text("", 40, DARK_RED, 450); vadd(card, u.realms_cur_name, 0)
    u.realms_cur_info = text("", 16, INK, 450); vadd(card, u.realms_cur_info, 2)
    u.realms_cur_state = text("", 17, BLACK, 440); vadd(card, u.realms_cur_state, 10)
    -- (below the card: inside it a two-line state pushed them onto the card's bottom edge; measured in-game,
    -- the edge ends near canvas y 470 under these buttons)
    local here = new("HorizontalBox", S.tree, "RealmHere")
    tilt(here, TILT.piece)
    place(cv, here, 440.0, 472.0, nil, nil, 6)
    u.realms_here = here
    u.realms_friends, u.realms_friends_t = button("ADD FRIENDS HERE", 20, DARK_RED); hadd(here, u.realms_friends)
    u.realms_end, u.realms_end_t = button("END REALM", 20, DARK_RED); hadd(here, u.realms_end, 24)
    u.realms_cancel, u.realms_cancel_t = button("CANCEL", 20, DARK_RED); hadd(here, u.realms_cancel, 24)
    -- (two lines: a third ran into the folder's tab; measured in-game it starts under END REALM's bottom)
    u.realms_hint = text("Saved to its server after your saves and at END REALM. Everyone keeps their own Realm "
        .. "character; your own saves stay untouched.", 14, GREY, 500)
    tilt(u.realms_hint, TILT.piece)
    place(cv, u.realms_hint, 440.0, 530.0, 510.0, 50.0, 6)

    -- the folder: start or add a Realm, or this Realm's member tools
    u.realms_folder = art(qtree, qpage, "ActiveQuests", 21.0, 465.0, 1280.0, 720.0, 1)
    u.realms_tab_t = text("NEW REALM", 20, INK); tilt(u.realms_tab_t, TILT.piece)
    place(cv, u.realms_tab_t, 419.0, 586.0, nil, nil, 2)
    local fresh = new("VerticalBox", S.tree, "RealmNew")
    tilt(fresh, TILT.piece)
    place(cv, fresh, 380.0, 652.0, 560.0, 380.0, 6)
    u.realms_new = fresh
    vadd(fresh, text("START A NEW REALM", 26, DARK_RED))
    vadd(fresh, text("A brand-new world from the game's New Game screen, with the settings you pick there. Everyone "
        .. "starts it with a fresh character.", 15, GREY, 540), 2)
    local mk = new("HorizontalBox", S.tree, "RealmCreate"); vadd(fresh, mk, 6)
    u.realms_name = input("RealmName", "name your Realm", 22, 300); hadd(mk, u.realms_name)
    u.realms_create = button("CREATE", 22, DARK_RED); hadd(mk, u.realms_create, 18)
    vadd(fresh, text("GOT AN INVITE?", 26, DARK_RED), 22)
    vadd(fresh, text("Paste a friend's invite code, or your own Realm key from another PC.", 15, GREY, 540), 2)
    local add = new("HorizontalBox", S.tree, "RealmAdd"); vadd(fresh, add, 6)
    u.realms_code = input("RealmCode", "XXXX-XXXX-XXXX-XXXX", 22, 300); hadd(add, u.realms_code)
    u.realms_add = button("ADD REALM", 22, DARK_RED); hadd(add, u.realms_add, 18)
    -- the last INVITE code, selectable (clicking selects it all, then Ctrl+C) - the clipboard copy can fail
    local function code_box(box, pad)
        local col = new("VerticalBox", S.tree, "RealmInviteBox"); vadd(box, col, pad)
        local row = new("HorizontalBox", S.tree, "RealmInviteRow"); vadd(col, row)
        hadd(row, text("INVITE CODE:", 22, DARK_RED))
        local e = input("RealmInviteCode", "", 22, 330)
        -- (set before the box joins the page: Slate builds the widget then)
        pcall(function() e.IsReadOnly = true end)
        pcall(function() e.SelectAllTextWhenFocused = true end)
        hadd(row, e, 14)
        pcall(function() e:SetIsReadOnly(true) end)
        vadd(col, text("Click the code, then Ctrl+C. It works once, for 7 days.", 14, GREY, 540), 2)
        return col, e
    end
    u.realms_inv_new, u.realms_inv_new_t = code_box(fresh, 18)
    local tools = new("VerticalBox", S.tree, "RealmTools")
    tilt(tools, TILT.piece)
    place(cv, tools, 380.0, 652.0, 560.0, 380.0, 6)
    u.realms_tools = tools
    -- a player asking to come in, first thing in the folder with its own ACCEPT / DECLINE (2026-10-29: the host found no
    -- way to let a friend in - the request was a relabelled button off on the card's row)
    local req = new("VerticalBox", S.tree, "RealmRequest"); vadd(tools, req)
    u.realms_req = req
    vadd(req, text("JOIN REQUEST", 26, DARK_RED))
    u.realms_req_t = text("", 18, BLACK, 540); vadd(req, u.realms_req_t, 2)
    local rq = new("HorizontalBox", S.tree, "RealmRequestRow"); vadd(req, rq, 6)
    u.realms_req_accept = button("ACCEPT", 26, GREEN); hadd(rq, u.realms_req_accept)
    u.realms_req_decline = button("DECLINE", 26, DARK_RED); hadd(rq, u.realms_req_decline, 40)
    -- every member, the ones playing first; who's online in green (one label each, two rows at most)
    u.realms_who = text("WHO'S IN", 26, DARK_RED); vadd(tools, u.realms_who, 14)
    u.realms_people = text("", 16, INK, 540); vadd(tools, u.realms_people, 2)
    u.realms_names = {}
    for r = 1, PEOPLE_ROWS do
        local row = new("HorizontalBox", S.tree, "RealmPeopleRow"); vadd(tools, row, r == 1 and 2 or 0)
        for i = 1, PEOPLE_PER_ROW do
            local t = text("", 16, INK); hadd(row, t, i > 1 and 18 or nil)
            u.realms_names[#u.realms_names + 1] = t
        end
    end
    -- (hidden while a request is up: the folder has room for one or the other, and chat must stay on the page)
    local bring = new("VerticalBox", S.tree, "RealmBring"); vadd(tools, bring, 14)
    u.realms_bring = bring
    vadd(bring, text("BRING FRIENDS", 26, DARK_RED))
    local tr = new("HorizontalBox", S.tree, "RealmToolRow"); vadd(bring, tr, 8)
    u.realms_cur_invite = button("INVITE CODE", 22, DARK_RED); hadd(tr, u.realms_cur_invite)
    u.realms_cur_key = button("COPY MY KEY", 22, DARK_RED); hadd(tr, u.realms_cur_key, 30)
    -- the owner, hosting: the Realm takes the difficulty of their own save (collapsed for everyone else)
    u.realms_my_diff = button("MY DIFFICULTY", 22, DARK_RED); hadd(tr, u.realms_my_diff, 30)
    vadd(bring, text("INVITE CODE: a one-time code for a friend who isn't here (7 days). COPY MY KEY: play this Realm "
        .. "from another PC - keep it private.", 15, GREY, 540), 8)
    u.realms_inv_tools, u.realms_inv_tools_t = code_box(bring, 12)
    -- the CO-OP tab's chat here too, while in a Realm session (no switching tabs to talk)
    -- (two lines: a third ran past the folder's bottom edge, measured in-game)
    local rc = new("HorizontalBox", S.tree, "RealmChatRow"); vadd(tools, rc, 2)
    hadd(rc, text("CHAT", 20, DARK_RED))
    u.realms_chat_input = input("RealmChatInput", "say something", 17, 300); hadd(rc, u.realms_chat_input, 12)
    u.realms_chat_send = button("SEND", 20); hadd(rc, u.realms_chat_send, 12)
    u.realms_chat_row = rc
    u.realms_chat_lines = {}
    for i = 1, 2 do local t = text("", 14, BLACK, 540); vadd(tools, t, 0); u.realms_chat_lines[i] = t end

    u.realms_page = 1
    vis_hit(cv, false)
end

-- nil = the CO-OP page, "settings" (gear), "mods" (MODS tab), "realms" (REALMS tab). The others hide the CO-OP
-- widgets; X goes back.
local function set_view(v)
    local u = S.ui
    if u.view == v then return end
    local was = u.view
    u.view, u.settings_mode = v, v == "settings"
    if v and not was then
        S.coop_vis = {}
        for i, w in ipairs(S.coop_list) do
            pcall(function() S.coop_vis[i] = w:GetVisibility() end)
            pcall(function() w:SetVisibility(1) end)
        end
    elseif not v and was then
        for i, w in ipairs(S.coop_list) do
            local x = S.coop_vis and S.coop_vis[i]
            if x ~= nil then pcall(function() w:SetVisibility(x) end) end
        end
    end
    vis_hit(u.gear, not v); vis(u.gear_img, not v)
    vis_hit(u.set_box, v == "settings")
    -- (no X on the REALMS page: its own ribbon tab and CO-OP's switch pages)
    local x = v ~= nil and v ~= "realms"
    vis_hit(u.set_close, x); vis(u.set_close_img, x)
    if u.mods_box then vis_hit(u.mods_box, v == "mods") end
    -- (4 = SelfHitTestInvisible: the canvas itself never takes a click, its buttons do. 3 = HitTestInvisible
    -- took every child out of hit testing too - no REALMS button could be pressed)
    if u.realms_canvas then pcall(function() u.realms_canvas:SetVisibility(v == "realms" and 4 or 1) end) end
end
local function set_mode(on) set_view(on and "settings" or nil) end

local function refresh_mods()
    local u = S.ui
    local m = ctx.mods and ctx.mods() or { rows = {} }
    S.mods_model = m
    local rows = m.rows or {}
    local pages = math.max(1, math.ceil(#rows / MOD_ROWS))
    if u.mods_page > pages then u.mods_page = pages end
    set(u.mods_sub, m.who and (m.host_side and ("Your mods next to " .. m.who .. "'s (the host). MATCH HOST switches yours like theirs.")
            or ("Your mods next to " .. m.who .. "'s."))
        or "Switch mods on or off for this PC. The game loads mods only when it starts.")
    local restart = m.restart and "RESTART THE GAME to load your changes." or ""
    if m.restart and m.in_coop then restart = restart .. " You join again after it." end
    if (m.missing or 0) > 0 then restart = restart .. (restart ~= "" and " " or "") .. "MISSING = install that mod to match." end
    set(u.mods_restart, restart); vis(u.mods_restart, restart ~= "")
    for i, r in ipairs(u.mods_rows) do
        local o = rows[(u.mods_page - 1) * MOD_ROWS + i]
        vis_hit(r.row, o ~= nil)
        if o then
            set(r.label, o.label)
            set(r.btn_t, o.text)
            style_text(r.btn_t, 22, o.locked and GREY or (o.on and DARK_RED or GREY))
            style_text(r.label, 22, o.differs and DARK_RED or BLACK)
            set(r.note, o.note or "")
        end
    end
    vis(u.mods_none, #rows == 0)
    set(u.mods_none, "No other mods are installed. UE4SS mods go in ue4ss\\Mods, pak mods in Content\\Paks\\~mods.")
    vis_hit(u.mods_prev, pages > 1); vis_hit(u.mods_next, pages > 1); vis(u.mods_page_t, pages > 1)
    set(u.mods_page_t, u.mods_page .. " / " .. pages)
    vis_hit(u.mods_match, m.can_match == true)
end

local function refresh_realms()
    local u = S.ui
    local m = ctx.realms and ctx.realms() or { rows = {} }
    S.realms_model = m
    local rows = m.rows or {}
    local pages = math.max(1, math.ceil(#rows / REALM_ROWS))
    if u.realms_page > pages then u.realms_page = pages end
    local cur, on = m.current, m.service == "on"
    -- the license card while I'm in a Realm, else the list note
    vis(u.realms_note, not cur); vis(u.realms_brand, not cur); vis_hit(u.realms_list, not cur)
    vis(u.realms_card, cur ~= nil); vis_hit(u.realms_cardbox, cur ~= nil); vis_hit(u.realms_here, cur ~= nil)
    vis(u.realms_hint, m.hosting == true)
    vis_hit(u.realms_new, not cur); vis_hit(u.realms_tools, cur ~= nil and cur.id ~= nil)
    set(u.realms_tab_t, cur and "MEMBERS" or "NEW REALM")
    -- (the code's text only changes with the code: setting it every refresh would drop the player's selection)
    local inv = m.invite and m.invite.code or nil
    vis_hit(u.realms_inv_new, inv ~= nil and not cur); vis_hit(u.realms_inv_tools, inv ~= nil and cur ~= nil)
    if inv ~= u.realms_inv_shown then
        u.realms_inv_shown = inv
        set(u.realms_inv_new_t, inv or ""); set(u.realms_inv_tools_t, inv or "")
    end
    if cur then
        set(u.realms_cur_kind, m.hosting and "YOU'RE HOSTING" or (m.armed and "NEW REALM")
            or (m.visiting and "YOU'RE VISITING") or (m.joining and "JOINING") or "YOUR REALM")
        -- WHO'S IN: one label per member, online ones in green; the last label says how many more there are
        local list = cur.people_list or {}
        vis(u.realms_people, #list == 0)
        set(u.realms_people, cur.people or "Loading the member list...")
        local slots = #u.realms_names
        for i, t in ipairs(u.realms_names) do
            local p = list[i]
            if p and i == slots and #list > slots then p = { short = "+" .. (#list - slots + 1) .. " more", on = false } end
            vis(t, p ~= nil)
            if p then
                local s = p.short or p.label or ""
                if #s > 16 then s = util.utf8_cut(s, 15) .. "." end   -- (four to a row on the folder)
                set(t, s)
                local on = p.on == true
                if t.syncfx_on ~= on then t.syncfx_on = on; style_text(t, 16, on and GREEN or INK) end
            end
        end
        local talk = m.hosting == true or m.visiting == true
        vis_hit(u.realms_chat_row, talk)
        local lines = talk and require("mirror.chat").recent(2) or {}
        for i, t in ipairs(u.realms_chat_lines) do
            local c = lines[i]
            if i == 1 and talk and u.rl_tip then
                vis(t, true); set(t, u.rl_tip)
            else
                vis(t, c ~= nil)
                if c then set(t, c.who .. ": " .. c.text) end
            end
        end
        set(u.realms_cur_name, cur.name or "")
        set(u.realms_cur_info, (cur.code or "") .. (cur.info and ("   |   " .. cur.info) or ""))
        set(u.realms_cur_state, m.state or "")
        -- a player asking to come in: the JOIN REQUEST box with its own ACCEPT / DECLINE (a Realm's join requests are
        -- answered here, not on the CO-OP tab); BRING FRIENDS makes room for it
        local q = m.hosting and m.request or nil
        vis_hit(u.realms_req, q ~= nil)
        vis_hit(u.realms_bring, q == nil)
        if q then set(u.realms_req_t, (q.name or "Someone") .. " wants to join " .. (cur.name or "your Realm") .. ".") end
        vis_hit(u.realms_friends, m.hosting == true)
        -- (a visiting member leaves here too, like LEAVE CO-OP; one still asking to come in cancels here)
        vis_hit(u.realms_end, m.hosting == true or m.visiting == true or m.joining == true)
        vis_hit(u.realms_cancel, m.armed == true)
        vis_hit(u.realms_my_diff, m.hosting == true and cur.owner == true)
        if u.realms_end_armed and clock > u.realms_end_armed + 4 then u.realms_end_armed = nil end
        set(u.realms_end_t, m.joining and "CANCEL" or m.visiting and "LEAVE REALM"
            or (u.realms_end_armed and "SURE? END IT" or "END REALM"))
        return
    end
    local line = m.state or m.note or ""
    set(u.realms_state, line); vis(u.realms_state, line ~= "")
    for i, r in ipairs(u.realms_rows) do
        local o = rows[(u.realms_page - 1) * REALM_ROWS + i]
        vis_hit(r.row, o ~= nil); vis(r.info, o ~= nil)
        if o then
            local name = o.name or ""
            if #name > 15 then name = name:sub(1, 14) .. "..." end
            set(r.name, (o.here and "> " or "") .. name)
            style_text(r.name, 22, o.here and DARK_RED or INK)
            set(r.info, o.info or "")
            style_text(r.info, 14, o.live and LIVE_GREEN or GREY)
            vis_hit(r.open, o.open ~= nil and m.free == true)
            set(r.open_t, o.open or "OPEN")
        end
    end
    vis(u.realms_none, #rows == 0 and on)
    vis_hit(u.realms_prev, pages > 1); vis_hit(u.realms_next, pages > 1); vis(u.realms_page_t, pages > 1)
    set(u.realms_page_t, u.realms_page .. " / " .. pages)
    vis_hit(u.realms_create, on); vis_hit(u.realms_add, on)
end

local function settings_list(m)
    if S.ui.set_tab == "mine" then return m.my_settings or {} end
    return m.settings or {}
end

local function refresh_settings(m)
    local u = S.ui
    local host = u.set_tab ~= "mine"
    style_text(u.set_tab_host_t, 28, host and DARK_RED or GREY)
    style_text(u.set_tab_mine_t, 28, host and GREY or DARK_RED)
    set(u.set_sub, not host and "Only for your own game - saved on this PC."
        or m.settings_editable and "Your rules. Friends in your world play by them too."
        or "The host's rules - only the host can change them.")
    local list = settings_list(m)
    for i, r in ipairs(u.set_rows) do
        local o = list[i]
        vis_hit(r.row, o ~= nil); vis(r.hint, o ~= nil)
        if o then
            vis(r.tag, o.tag ~= nil)
            set(r.tag, o.tag and (o.tag .. " ") or "")
            if o.tag and o.tag_color ~= r.tag_color then r.tag_color = o.tag_color; style_text(r.tag, 26, o.tag_color or TAG_COLOR) end
            set(r.label, o.label .. ":")
            set(r.btn_t, o.text or "OFF")
            set(r.hint, o.hint)
        end
    end
end

local function inject(jui)
    S = { jui = jui, buttons = {}, ui = {}, ribbons = {}, hovered = {}, clicks = {} }
    S.tree = jui.WidgetTree
    local root = S.tree.RootWidget
    local qb, qt = jui.QuestsButton, jui.QuestsText
    if not (util.valid(root) and util.valid(qb) and util.valid(qt)) then error("handbook parts missing") end
    S.font = qt.Font
    S.pages = { jui.Journal_InfoUI, jui.Journal_SkillsUI, jui.Journal_QuestsUI }
    S.originals = { jui.InfoButton, jui.SkillsButton, jui.QuestsButton }

    step("ribbons")
    for _, p in ipairs(S.pages) do
        local pt = p.WidgetTree
        S.ribbons[#S.ribbons + 1] = add_ribbon(pt, pt.RootWidget, p)
        S.ribbons[#S.ribbons + 1] = add_ribbon(pt, pt.RootWidget, p, nil, 2, MODS_TINT)
    end

    step("page")
    local page = new("CanvasPanel", S.tree, "CoopPage")
    local ps = root:AddChildToCanvas(page)
    local a, o, al = { 0, 0, 0, 0 }, { 0, 0, 1920, 1080 }, { 0, 0 }
    pcall(function()
        local qs = jui.Journal_QuestsUI.Slot
        local an, of, ag = qs:GetAnchors(), qs:GetOffsets(), qs:GetAlignment()
        a = { an.Minimum.X, an.Minimum.Y, an.Maximum.X, an.Maximum.Y }
        o = { of.Left, of.Top, of.Right, of.Bottom }
        al = { ag.X, ag.Y }
    end)
    pcall(function()
        ps:SetAnchors({ Minimum = { X = a[1] + 0.0, Y = a[2] + 0.0 }, Maximum = { X = a[3] + 0.0, Y = a[4] + 0.0 } })
        ps:SetOffsets({ Left = o[1] + 0.0, Top = o[2] + 0.0, Right = o[3] + 0.0, Bottom = o[4] + 0.0 })
        ps:SetAlignment({ X = al[1] + 0.0, Y = al[2] + 0.0 })
    end)
    log.info(string.format("journal_tab: page placed like the originals: anchors %s,%s-%s,%s offsets %s,%s,%s,%s",
        tostring(a[1]), tostring(a[2]), tostring(a[3]), tostring(a[4]), tostring(o[1]), tostring(o[2]), tostring(o[3]), tostring(o[4])))
    S.page, S.page_slot = page, ps
    local qtree = jui.Journal_QuestsUI.WidgetTree
    for _, mname in ipairs({ "SkillsMarker", "QuestMarker", "InfoMarker" }) do
        local src = find(qtree, mname, jui.Journal_QuestsUI)
        local tex = src and texture_of(src)
        if tex then
            local img = image_from(tex, S.tree, mname)
            tilt(img, TILT.ribbon)
            local s = page:AddChildToCanvas(img)
            local at = MARKERS[mname]
            pcall(function()
                s:SetAnchors({ Minimum = { X = 0.0, Y = 0.5 }, Maximum = { X = 0.0, Y = 0.5 } })
                s:SetOffsets({ Left = at[1], Top = at[2], Right = 1920.0, Bottom = 1080.0 })
            end)
        end
    end
    add_ribbon(qtree, page, jui.Journal_QuestsUI, S.tree)
    add_ribbon(qtree, page, jui.Journal_QuestsUI, S.tree, 2, MODS_TINT)
    local paper_src = find(qtree, "Page", jui.Journal_QuestsUI)
    local paper_box = new("Overlay", S.tree, "Paper")
    tilt(paper_box, TILT.paper)
    local pbs = page:AddChildToCanvas(paper_box)
    pcall(function()
        pbs:SetAnchors({ Minimum = { X = 0.0, Y = 0.5 }, Maximum = { X = 0.0, Y = 0.5 } })
        pbs:SetOffsets({ Left = 0.0, Top = 0.0, Right = 2112.0, Bottom = 1188.0 })
        pbs:SetAlignment({ X = 0.15, Y = 0.480263 })
    end)
    local paper_tex = paper_src and texture_of(paper_src)
    if not paper_tex then error("no notebook paper texture") end
    local paper = image_from(paper_tex, S.tree, "PaperImage")
    local pis = paper_box:AddChildToOverlay(paper)
    pcall(function() pis:SetHorizontalAlignment(0); pis:SetVerticalAlignment(0) end)
    step("content")
    build_content(page, qtree, jui.Journal_QuestsUI)
    step("settings")
    S.realms_on = ctx.realms_on ~= nil and ctx.realms_on() == true
    build_settings(page)
    step("mods")
    build_mods(page)
    if S.realms_on then
        step("realms")
        build_realms(page, qtree, jui.Journal_QuestsUI, jui.Journal_InfoUI.WidgetTree, jui.Journal_InfoUI)
    end
    vis_hit(page, false)

    step("tab")
    local overlay = qb:GetParent()
    local function make_tab(name, caption, pad)
        local tab = new("Button", S.tree, name)
        pcall(function() tab:SetBackgroundColor(CLEAR) end)
        local label = new("TextBlock", S.tree, name .. "Text")
        set(label, caption)
        style_text(label, 34, BLACK)
        pcall(function() tab:SetContent(label) end)
        local ts = overlay:AddChildToOverlay(tab)
        pcall(function()
            ts:SetPadding({ Left = pad.Left, Top = 0.0, Right = 0.0, Bottom = pad.Bottom })
            ts:SetHorizontalAlignment(2)   -- (2 = centred in UMG, like INFO / SKILLS / QUESTS)
            ts:SetVerticalAlignment(2)
        end)
        pcall(function() tab:SetRenderTransformAngle(-80.0) end)
        return tab, label
    end
    S.tab, S.tab_text = make_tab("CoopTab", "CO-OP", LABEL_PAD)
    if S.realms_on then
        S.mods_tab, S.mods_tab_text = make_tab("ModsTab", "REALMS", MODS_PAD)
    else
        S.mods_tab, S.mods_tab_text = make_tab("ModsTab", "MODS", MODS_PAD)
    end
    log.info("journal_tab: CO-OP and " .. (S.realms_on and "REALMS" or "MODS") .. " tabs added to the handbook")
end

local function journal()
    local jui
    pcall(function() jui = game.player().InGameUI.JournalUI end)
    return util.valid(jui) and jui or nil
end

local function ensure()
    local jui = journal()
    if not jui then return false end
    if S and util.same(S.jui, jui) and util.valid(S.page) then return true end
    if clock - failed_at < 10 then return false end
    local ok, err = pcall(inject, jui)
    if not ok then
        failed_at, S = clock, nil
        log.warn("journal_tab: couldn't add the CO-OP tab (" .. tostring(err) .. ")")
        return false
    end
    return true
end

local function is_open()
    local open = false
    pcall(function() open = game.player()["JournalOpen?"] == true end)
    return open
end

local function show(on)
    if on and not S.shown then
        S.saved_vis = {}
        for i, p in ipairs(S.pages) do
            pcall(function() S.saved_vis[i] = p:GetVisibility() end)
            pcall(function() p:SetVisibility(1) end)
        end
    elseif not on and S.shown then
        for i, p in ipairs(S.pages) do
            local v = S.saved_vis and S.saved_vis[i]
            if v ~= nil then pcall(function() p:SetVisibility(v) end) end
        end
    end
    S.shown = on
    vis_hit(S.page, on)
    if on then
        set_mode(false)
        pcall(function() S.page_slot:SetZOrder(1) end)
        ctx.refresh_now = true
    end
end

local function click_sound()
    pcall(function() util.cdo(GS):PlaySound2D(game.player(), util.find(CLICK_CUE), 1.0, 1.0, 0.0, nil, nil, true) end)
end

local function clicked(b)
    local now_p, hov = false, false
    pcall(function() now_p = b:IsPressed() end)
    pcall(function() hov = b:IsHovered() end)
    local was = S.clicks[b]
    S.clicks[b] = now_p
    return was and not now_p and hov
end

local function hover(b, t)
    local h = false
    pcall(function() h = b:IsHovered() end)
    if h ~= (S.hovered[b] or false) then
        S.hovered[b] = h
        pcall(function() t:SetRenderScale(h and { X = 1.1, Y = 1.1 } or { X = 1.0, Y = 1.0 }) end)
        if h then click_sound() end
    end
end

local function refresh()
    local m, u = ctx.model(), S.ui
    S.model = m
    if u.view == "settings" then refresh_settings(m); return end
    if u.view == "mods" then refresh_mods(); return end
    if u.view == "realms" then refresh_realms(); return end
    set(u.headline, m.headline or "")
    set(u.detail, m.detail or "")
    set(u.me, m.me or "")
    set(u.code, m.code or "-")
    vis_hit(u.copy, m.code ~= nil)
    vis_hit(u.host, m.show_host)
    vis_hit(u.join_local, m.show_join_local)
    vis_hit(u.leave, m.show_leave)
    vis_hit(u.stop, m.show_stop)
    vis_hit(u.go_home, m.host_gone)
    vis_hit(u.wait, m.host_gone)
    -- in co-op the join section can't be used: hidden, so the players, chat and teleport rows fit the folder
    -- (with players listed, the chat ran past the bottom of the page)
    local coop = m.in_coop == true
    vis_hit(u.games_title, not coop)
    vis(u.code_title, not coop); vis_hit(u.code_row, not coop)
    vis_hit(u.pw_row, not coop or m.show_stop == true)
    for i, f in ipairs(u.friends) do
        local h = not coop and m.hosts[i] or nil
        vis_hit(f.row, h ~= nil)
        if h then set(f.name, h.label or h.name); vis_hit(f.btn, h.joinable ~= false) end
    end
    vis_hit(u.public, m.public_state ~= nil)
    if m.public_state then
        set(u.public_t, "PUBLIC: " .. ((m.public_state == "on" and "ON") or (m.public_state == "creating" and "...")
            or (m.public_state == "failed" and "FAILED") or "OFF"))
    end
    set(u.pw_label, m.password_on and "PASSWORD (ON):" or "PASSWORD:")
    vis(u.chat_title, m.show_chat)
    vis_hit(u.voice_btn, m.show_voice); vis_hit(u.voice_vol, m.show_voice)
    if m.show_voice then set(u.voice_t, m.voice_label or "VOICE: OFF"); set(u.voice_vol_t, m.voice_vol or "VOL 100%") end
    vis_hit(u.report, m.show_report)
    vis_hit(u.update, m.update ~= nil)
    if m.update then set(u.update_t, "UPDATE TO " .. m.update) end
    vis_hit(u.chat_row, m.show_chat)
    vis_hit(u.tp_row, m.tp ~= nil)
    if m.tp then set(u.tp_name, m.tp.who .. (m.tp.kind == "goto" and " wants to teleport to you" or " wants to bring you to them")) end
    for i, t in ipairs(u.chat_lines) do
        local c = (m.chat or {})[i]
        if i == 1 and u.co_tip and m.show_chat then
            vis(t, true); set(t, u.co_tip)
        else
            vis(t, m.show_chat and c ~= nil)
            if c then set(t, c.who .. ": " .. c.text) end
        end
    end
    local reqs = m.requests or {}
    vis(u.req_title, #reqs > 0)
    for i, q in ipairs(u.reqs) do
        local r = reqs[i]
        vis_hit(q.row, r ~= nil)
        if r then set(q.name, r.name) end
    end
    local guests = m.guests or {}
    vis(u.guests_title, #guests > 0)
    for i, g in ipairs(u.guests) do
        local p = guests[i]
        vis_hit(g.row, p ~= nil)
        if p then
            set(g.name, p.name)
            if g.armed and (g.armed.id ~= p.id or clock > g.armed.at + 4) then g.armed = nil end
            set(g.btn_t, g.armed and "SURE?" or "KICK")
        end
    end
    vis_hit(u.clear_allowed, (m.allowed or 0) > 0)
    if (m.allowed or 0) > 0 then set(u.clear_allowed_t, "CLEAR ALWAYS-ALLOWED (" .. m.allowed .. ")") end
    set(u.none, #m.hosts > 0 and "" or (m.steam and "No friends are hosting right now. Your friend chooses HOST A GAME here, or sends you their code."
        or "One-PC test mode: Steam features (codes, friends) are off."))
    vis(u.none, #m.hosts == 0 and not coop)
    vis_hit(u.friends_box, not u.show_backups)
    vis_hit(u.backups_box, u.show_backups)
    pcall(function() u.folder_friends_slot:SetZOrder(u.show_backups and 1 or 2) end)
    pcall(function() u.folder_backups_slot:SetZOrder(u.show_backups and 2 or 1) end)
    if u.show_backups then ctx.backups.refresh(m.playing_slot) end
end

local refresh_in = 0.0
-- Enter in a chat box sends it, like SEND. (The box loses its focus on Enter: the one focused in the last 0.5 s counts.)
local enter_bound = false
local function chat_focused()
    local u = S and S.ui
    return u ~= nil and u.chat_focus ~= nil and clock - (u.chat_focus_at or -9) < 0.5
end
local function chat_enter()
    if not chat_focused() then return end
    local box, txt = S.ui.chat_focus, ""
    pcall(function() txt = box:GetText():ToString() end)
    if txt:find("%S") and ctx.act.chat_send(txt) then pcall(function() box:SetText(FText("")) end) end
    ctx.refresh_now = true
end

function journal_tab.tick(dt)
    clock = clock + dt
    if not enter_bound then
        enter_bound = true
        game.keybind("RETURN", nil, chat_enter, chat_focused)
    end
    if not ensure() then return end
    local open = is_open()
    if open ~= S.was_open then
        S.was_open = open
        pcall(function() S.jui:SetPlaybackSpeed(S.jui.Fade, FADE_SPEED) end)
    end
    if not open then
        if S.shown then show(false) end
        if S.want_show and clock > S.want_show then S.want_show = nil end
        return
    end
    if S.want_show then S.want_show = nil; show(true) end
    hover(S.tab, S.tab_text)
    hover(S.mods_tab, S.mods_tab_text)
    if clicked(S.tab) then click_sound(); show(true) end
    if clicked(S.mods_tab) then
        click_sound(); show(true)
        if S.realms_on then ctx.act.realm_list(true); set_view("realms") else set_view("mods") end
        refresh()
    end
    for _, b in ipairs(S.originals) do
        if clicked(b) and S.shown then show(false) end
    end
    if not S.shown then return end
    for _, x in ipairs(S.buttons) do hover(x.b, x.t) end
    local u, a = S.ui, ctx.act
    -- "/" typed in a chat box: its first chat line shows the commands that fit (teleport.tip), or that it isn't one
    local function typed_tip(box)
        local t = ""
        if box then pcall(function() t = box:GetText():ToString() end) end
        return require("mirror.teleport").tip(t)
    end
    local co_tip = u.view == nil and typed_tip(u.chat_input) or nil
    local rl_tip = u.view == "realms" and typed_tip(u.realms_chat_input) or nil
    if co_tip ~= u.co_tip or rl_tip ~= u.rl_tip then u.co_tip, u.rl_tip, ctx.refresh_now = co_tip, rl_tip, true end
    for _, b in ipairs({ u.chat_input, u.realms_chat_input }) do
        local f = false
        if b then pcall(function() f = b:HasKeyboardFocus() end) end
        if f then u.chat_focus, u.chat_focus_at = b, clock end
    end
    refresh_in = refresh_in - dt
    if u.view == "mods" then
        if clicked(u.set_close) then set_view(nil); ctx.refresh_now = true end
        local mm = S.mods_model or { rows = {} }
        local pages = math.max(1, math.ceil(#(mm.rows or {}) / MOD_ROWS))
        if clicked(u.mods_prev) then u.mods_page = (u.mods_page - 2) % pages + 1; ctx.refresh_now = true end
        if clicked(u.mods_next) then u.mods_page = u.mods_page % pages + 1; ctx.refresh_now = true end
        for i, r in ipairs(u.mods_rows) do
            local o = (mm.rows or {})[(u.mods_page - 1) * MOD_ROWS + i]
            if o and not o.locked and clicked(r.btn) then a.mod_toggle(o.id); ctx.refresh_now = true end
        end
        if mm.can_match and clicked(u.mods_match) then a.mod_match(); ctx.refresh_now = true end
        if refresh_in <= 0 or ctx.refresh_now then refresh_in, ctx.refresh_now = 1.0, false; refresh() end
        return
    end
    if u.view == "realms" then
        if clicked(u.set_close) then set_view(nil); ctx.refresh_now = true; return end
        local rm = S.realms_model or { rows = {} }
        local rows = rm.rows or {}
        local pages = math.max(1, math.ceil(#rows / REALM_ROWS))
        if clicked(u.realms_prev) then u.realms_page = (u.realms_page - 2) % pages + 1; ctx.refresh_now = true end
        if clicked(u.realms_next) then u.realms_page = u.realms_page % pages + 1; ctx.refresh_now = true end
        if clicked(u.realms_refresh) then a.realm_list(true); ctx.refresh_now = true end
        -- (every button is checked every frame: clicked() follows each one's press state)
        for i, r in ipairs(u.realms_rows) do
            local o = rows[(u.realms_page - 1) * REALM_ROWS + i]
            local c_open, c_inv, c_key = clicked(r.open), clicked(r.invite), clicked(r.key)
            if o and c_open and o.open and rm.free then a.realm_open(o.id, o.open); ctx.refresh_now = true end
            if o and c_inv then a.realm_invite(o.id) end
            if o and c_key then a.realm_key(o.id) end
        end
        local cur = rm.current
        local c_fr, c_end, c_cancel = clicked(u.realms_friends), clicked(u.realms_end), clicked(u.realms_cancel)
        local c_inv, c_key = clicked(u.realms_cur_invite), clicked(u.realms_cur_key)
        local q = rm.hosting and rm.request or nil
        local c_yes, c_no = clicked(u.realms_req_accept), clicked(u.realms_req_decline)
        if q and c_yes then a.accept(q.id, q.name); ctx.refresh_now = true end
        if q and c_no then a.decline(q.id, q.name); ctx.refresh_now = true end
        if rm.hosting and c_fr then a.realm_friends() end
        if rm.joining and c_end then a.cancel_join(); ctx.refresh_now = true end
        if rm.hosting and c_end then
            -- END REALM sends everyone home: the first press asks
            if u.realms_end_armed then u.realms_end_armed = nil; a.realm_end() else u.realms_end_armed = clock end
            ctx.refresh_now = true
        end
        if rm.visiting and c_end then a.leave(); ctx.refresh_now = true end
        if (rm.hosting or rm.visiting) and clicked(u.realms_chat_send) then
            local txt = ""
            pcall(function() txt = u.realms_chat_input:GetText():ToString() end)
            if a.chat_send(txt) then pcall(function() u.realms_chat_input:SetText(FText("")) end) end
            ctx.refresh_now = true
        end
        if rm.armed and c_cancel then a.realm_cancel(); ctx.refresh_now = true end
        if cur and cur.id and c_inv then a.realm_invite(cur.id) end
        if cur and cur.id and c_key then a.realm_key(cur.id) end
        if clicked(u.realms_my_diff) and rm.hosting and cur and cur.owner then a.realm_my_difficulty(); ctx.refresh_now = true end
        local function typed(box)
            local txt = ""
            pcall(function() txt = box:GetText():ToString() end)
            return txt
        end
        if clicked(u.realms_create) then
            local name = typed(u.realms_name):gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" then a.realm_create(name); pcall(function() u.realms_name:SetText(FText("")) end) end
            ctx.refresh_now = true
        end
        if clicked(u.realms_add) and a.realm_add(typed(u.realms_code)) then
            pcall(function() u.realms_code:SetText(FText("")) end)
        end
        a.realm_list(false)
        if refresh_in <= 0 or ctx.refresh_now then refresh_in, ctx.refresh_now = 0.5, false; refresh() end
        return
    end
    if u.settings_mode then
        if clicked(u.set_close) then set_mode(false); ctx.refresh_now = true end
        if u.set_tab_mods and clicked(u.set_tab_mods) then set_view("mods"); refresh(); return end
        if clicked(u.set_tab_host) then u.set_tab = "host"; ctx.refresh_now = true end
        if clicked(u.set_tab_mine) then u.set_tab = "mine"; ctx.refresh_now = true end
        local opts = S.model and settings_list(S.model) or {}
        for i, r in ipairs(u.set_rows) do
            if opts[i] and clicked(r.btn) then a.setting(opts[i].key, u.set_tab); ctx.refresh_now = true end
        end
        if refresh_in <= 0 or ctx.refresh_now then refresh_in, ctx.refresh_now = 0.5, false; refresh() end
        return
    end
    if clicked(u.gear) then set_mode(true); refresh(); return end
    if clicked(u.copy) then a.copy() end
    if clicked(u.host) then a.host() end
    if clicked(u.join_local) then a.join_local() end
    if clicked(u.leave) then a.leave() end
    if clicked(u.stop) then a.stop() end
    if clicked(u.public) then a.toggle_public(); ctx.refresh_now = true end
    if clicked(u.refresh) then a.refresh() end
    if clicked(u.voice_btn) then a.voice(); ctx.refresh_now = true end
    if clicked(u.voice_vol) then a.voice_vol(); ctx.refresh_now = true end
    if clicked(u.report) then a.report() end
    if clicked(u.update) then a.update() end
    if clicked(u.go_home) then a.go_home() end
    if clicked(u.wait) then a.wait() end
    if clicked(u.sec_friends) then u.show_backups = false; refresh() end
    if clicked(u.sec_backups) then u.show_backups = true; refresh() end
    if u.show_backups and ctx.backups.handle(clicked) then refresh() end
    local mdl = S.model or ctx.model()
    local hosts = mdl.hosts
    for i, f in ipairs(u.friends) do
        if hosts[i] and hosts[i].joinable ~= false and clicked(f.btn) then a.join(hosts[i].id, hosts[i].name) end
    end
    local reqs = mdl.requests or {}
    for i, q in ipairs(u.reqs) do
        local r = reqs[i]
        if r then
            if clicked(q.accept) then a.accept(r.id, r.name); ctx.refresh_now = true
            elseif clicked(q.allow) then a.allow(r.id, r.name); ctx.refresh_now = true
            elseif clicked(q.decline) then a.decline(r.id, r.name); ctx.refresh_now = true end
        end
    end
    if (mdl.allowed or 0) > 0 and clicked(u.clear_allowed) then a.clear_allowed(); ctx.refresh_now = true end
    for i, g in ipairs(u.guests) do
        local p = (mdl.guests or {})[i]
        if p and clicked(g.btn) then
            if g.armed and g.armed.id == p.id then g.armed = nil; a.kick(p.id, p.name)
            else g.armed = { id = p.id, at = clock } end
            ctx.refresh_now = true
        end
    end
    if clicked(u.pw_set) then
        local pw = ""
        pcall(function() pw = u.pw_input:GetText():ToString() end)
        a.set_password(pw)
        ctx.refresh_now = true
    end
    if mdl.tp and clicked(u.tp_accept) then a.tp_accept(); ctx.refresh_now = true
    elseif mdl.tp and clicked(u.tp_decline) then a.tp_decline(); ctx.refresh_now = true end
    if clicked(u.chat_send) then
        local txt = ""
        pcall(function() txt = u.chat_input:GetText():ToString() end)
        if a.chat_send(txt) then pcall(function() u.chat_input:SetText(FText("")) end) end
        ctx.refresh_now = true
    end
    if clicked(u.join_code) then
        local txt = ""
        pcall(function() txt = u.input:GetText():ToString() end)
        a.join_code(txt)
    end
    if refresh_in <= 0 or ctx.refresh_now then refresh_in, ctx.refresh_now = 0.5, false; refresh() end
end

function journal_tab.open()
    if not ensure() then return false end
    if is_open() then
        show(true)
        refresh()
    else
        pcall(function() game.player():Event_Journal() end)
        S.want_show = clock + 3.0
    end
    return true
end

function journal_tab.dev_section(backups)
    if S and S.ui then S.ui.show_backups = backups == true; ctx.refresh_now = true end
end

function journal_tab.dev_mods(on)
    if S and S.ui and S.ui.mods_box then set_view(on and "mods" or nil); ctx.refresh_now = true end
end

function journal_tab.dev_realms(on)
    if not (S and S.ui and S.ui.realms_canvas) then return false end
    -- (like the REALMS tab click: the mod's page has to be shown first, else the game's own page stays up)
    if on and is_open() then show(true); ctx.act.realm_list(true) end
    set_view(on and "realms" or nil); ctx.refresh_now = true
    return true
end

function journal_tab.dev_settings(on, tab)
    if S and S.ui and S.ui.set_box then
        set_mode(on == true)
        if tab then S.ui.set_tab = tab end
        ctx.refresh_now = true
    end
end

function journal_tab.configure(c) ctx = c end
function journal_tab.act(name, ...) if ctx and ctx.act[name] then return ctx.act[name](...) end end
-- the old world's JournalUI and our widgets are freed with it; a new JournalUI may reuse the address
game.on_world_reset(function() S = nil end)

return journal_tab
