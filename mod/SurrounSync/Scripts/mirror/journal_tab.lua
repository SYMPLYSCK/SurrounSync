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
local LABEL_PAD = { Left = 98.0, Bottom = -287.0 }
local LIST_WIDTH = 560.0
local GEAR_TEX = "/Game/UI/Textures/over_250_survival_flat_icons/gear.gear"
local CLOSE_TEX = "/Game/UI/Textures/CrossX.CrossX"
local INK = { R = 0.12, G = 0.08, B = 0.06, A = 1.0 }
local SETTING_ROWS = 6

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
        pcall(function() n = p:GetFName():ToString() end)
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

local function add_ribbon(page_tree, canvas, owner, outer)
    local qm = find(page_tree, "QuestMarker", owner)
    if not qm then error("no QuestMarker on a handbook page") end
    local tex = texture_of(qm)
    if not tex then error("no ribbon texture") end
    local img = image_from(tex, outer or page_tree, "Ribbon")
    pcall(function() img:SetColorAndOpacity(RIBBON_TINT) end)
    tilt(img, TILT.ribbon)
    local slot = canvas:AddChildToCanvas(img)
    pcall(function()
        slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.5 }, Maximum = { X = 0.0, Y = 0.5 } })
        slot:SetOffsets({ Left = -203.0390625 + RIBBON_STEP.X, Top = -498.0 + RIBBON_STEP.Y, Right = 1920.0, Bottom = 1080.0 })
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
    local gt = new("HorizontalBox", S.tree, "GamesTitle"); vadd(u.friends_box, gt, 10)
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
    vadd(u.friends_box, text("JOIN WITH A CODE", 26, DARK_RED), 14)
    local jr = new("HorizontalBox", S.tree, "CodeJoin"); vadd(u.friends_box, jr, 2)
    u.input = input("CodeInput", "type your friend's code", 22, 260)
    hadd(jr, u.input)
    u.join_code = button("JOIN", 22); hadd(jr, u.join_code, 18)
    local pr = new("HorizontalBox", S.tree, "PasswordRow"); vadd(u.friends_box, pr, 4)
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
    u.tp_row = new("HorizontalBox", S.tree, "TeleportRow"); vadd(u.friends_box, u.tp_row, 6)
    u.tp_name = text("", 18); hadd(u.tp_row, u.tp_name)
    u.tp_accept = button("ACCEPT", 20); hadd(u.tp_row, u.tp_accept, 14)
    u.tp_decline = button("DECLINE", 20); hadd(u.tp_row, u.tp_decline, 10)

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
    place(page, u.set_box, 420.0, 230.0, 580.0, 760.0, 6)
    u.set_title = text("SETTINGS", 58, DARK_RED); vadd(u.set_box, u.set_title)
    u.set_sub = text("", 16, GREY, 560); vadd(u.set_box, u.set_sub, 4)
    u.set_rows = {}
    for i = 1, SETTING_ROWS do
        local row = new("HorizontalBox", S.tree, "SettingRow"); vadd(u.set_box, row, i == 1 and 26 or 18)
        local label = text("", 26)
        local b, bt = button("OFF", 26, DARK_RED)
        hadd(row, label); hadd(row, b, 24)
        local hint = text("", 16, GREY, 560); vadd(u.set_box, hint, 2)
        u.set_rows[i] = { row = row, label = label, btn = b, btn_t = bt, hint = hint }
    end
    u.set_close, u.set_close_img = icon_button(page, CLOSE_TEX, "X", 930.0, 215.0, 72.0, 7)
    vis_hit(u.set_box, false); vis_hit(u.set_close, false); vis(u.set_close_img, false)
    u.settings_mode = false
end

local function set_mode(on)
    local u = S.ui
    if (u.settings_mode == true) == on then return end
    u.settings_mode = on
    if on then
        S.coop_vis = {}
        for i, w in ipairs(S.coop_list) do
            pcall(function() S.coop_vis[i] = w:GetVisibility() end)
            pcall(function() w:SetVisibility(1) end)
        end
    else
        for i, w in ipairs(S.coop_list) do
            local v = S.coop_vis and S.coop_vis[i]
            if v ~= nil then pcall(function() w:SetVisibility(v) end) end
        end
    end
    vis_hit(u.gear, not on); vis(u.gear_img, not on)
    vis_hit(u.set_box, on); vis_hit(u.set_close, on); vis(u.set_close_img, on)
end

local function refresh_settings(m)
    local u = S.ui
    set(u.set_sub, m.settings_editable
        and "Your settings. While a friend is in your world, their game follows them too."
        or "The host's settings - only the host can change them.")
    for i, r in ipairs(u.set_rows) do
        local o = (m.settings or {})[i]
        vis_hit(r.row, o ~= nil); vis(r.hint, o ~= nil)
        if o then
            set(r.label, o.label .. ":")
            set(r.btn_t, o.on and "ON" or "OFF")
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
    build_settings(page)
    vis_hit(page, false)

    step("tab")
    local overlay = qb:GetParent()
    local tab = new("Button", S.tree, "CoopTab")
    pcall(function() tab:SetBackgroundColor(CLEAR) end)
    local label = new("TextBlock", S.tree, "CoopTabText")
    set(label, "CO-OP")
    style_text(label, 34, BLACK)
    pcall(function() tab:SetContent(label) end)
    local ts = overlay:AddChildToOverlay(tab)
    pcall(function()
        ts:SetPadding({ Left = LABEL_PAD.Left, Top = 0.0, Right = 0.0, Bottom = LABEL_PAD.Bottom })
        ts:SetHorizontalAlignment(2)
        ts:SetVerticalAlignment(2)
    end)
    pcall(function() tab:SetRenderTransformAngle(-80.0) end)
    S.tab, S.tab_text = tab, label
    log.info("journal_tab: CO-OP tab added to the handbook")
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
    pcall(function() util.cdo(GS):PlaySound2D(game.player(), StaticFindObject(CLICK_CUE), 1.0, 1.0, 0.0, nil, nil, true) end)
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
    if u.settings_mode then refresh_settings(m); return end
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
    for i, f in ipairs(u.friends) do
        local h = m.hosts[i]
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
        vis(t, m.show_chat and c ~= nil)
        if c then set(t, c.who .. ": " .. c.text) end
    end
    local reqs = m.requests or {}
    vis(u.req_title, #reqs > 0)
    for i, q in ipairs(u.reqs) do
        local r = reqs[i]
        vis_hit(q.row, r ~= nil)
        if r then set(q.name, r.name) end
    end
    vis_hit(u.clear_allowed, (m.allowed or 0) > 0)
    if (m.allowed or 0) > 0 then set(u.clear_allowed_t, "CLEAR ALWAYS-ALLOWED (" .. m.allowed .. ")") end
    set(u.none, #m.hosts > 0 and "" or (m.steam and "No friends are hosting right now. Your friend chooses HOST A GAME here, or sends you their code."
        or "One-PC test mode: Steam features (codes, friends) are off."))
    vis(u.none, #m.hosts == 0)
    vis_hit(u.friends_box, not u.show_backups)
    vis_hit(u.backups_box, u.show_backups)
    pcall(function() u.folder_friends_slot:SetZOrder(u.show_backups and 1 or 2) end)
    pcall(function() u.folder_backups_slot:SetZOrder(u.show_backups and 2 or 1) end)
    if u.show_backups then ctx.backups.refresh(m.playing_slot) end
end

local refresh_in = 0.0
function journal_tab.tick(dt)
    clock = clock + dt
    if not ensure() then return end
    local open = is_open()
    if not open then
        if S.shown then show(false) end
        if S.want_show and clock > S.want_show then S.want_show = nil end
        return
    end
    if S.want_show then S.want_show = nil; show(true) end
    hover(S.tab, S.tab_text)
    if clicked(S.tab) then click_sound(); show(true) end
    for _, b in ipairs(S.originals) do
        if clicked(b) and S.shown then show(false) end
    end
    if not S.shown then return end
    for _, x in ipairs(S.buttons) do hover(x.b, x.t) end
    local u, a = S.ui, ctx.act
    refresh_in = refresh_in - dt
    if u.settings_mode then
        if clicked(u.set_close) then set_mode(false); ctx.refresh_now = true end
        local opts = (S.model and S.model.settings) or {}
        for i, r in ipairs(u.set_rows) do
            if opts[i] and clicked(r.btn) then a.setting(opts[i].key); ctx.refresh_now = true end
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

function journal_tab.dev_settings(on)
    if S and S.ui and S.ui.set_box then set_mode(on == true); ctx.refresh_now = true end
end

function journal_tab.configure(c) ctx = c end
function journal_tab.act(name, ...) if ctx and ctx.act[name] then return ctx.act[name](...) end end

return journal_tab
