"""The handbook's settings page (mirror/journal_tab.lua) on stand-in UMG widgets, with the real gamepad.lua and
mysettings.lua behind it: every setting on one page with tabs HOST RULES (REALM RULES in a Realm) | MY SETTINGS |
BINDINGS | MODS (Realms on), both gears open it and X goes back to where it was opened from, MY SETTINGS' BINDINGS
switches to the BINDINGS tab, every control on that tab reaches the gamepad API (or the MY SETTINGS switch). No
GAMEPAD ribbon. How it looks is not checked (that needs the game). No game needed.

    PYTHONPATH=tools/testpkg python tools/test-journal-gamepad.py
"""
import os
import sys
import tempfile

try:
    from lupa import lua54
except ImportError:
    print("needs lupa: pip install --target tools/testpkg lupa, then PYTHONPATH=tools/testpkg")
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "mod", "SurrounSync", "Scripts")
fails = []
count = 0


def check(cond, what):
    global count
    count += 1
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)


SETUP = r'''
local scripts, linkdir = ...
package.path = scripts .. "\\?.lua;" .. scripts .. "\\mirror\\?.lua;" .. package.path
LOG = {}
local function out(lvl) return function(m) LOG[#LOG + 1] = lvl .. " " .. tostring(m) end end
package.preload["mirror.log"] = function()
    local info = out("INFO")
    return { info = info, warn = out("WARN"), error = out("ERROR"), debug = function() end,
             every = function(_, _, m) info(m) end }
end
local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mirror.crumb"] = function() return noop end
-- (a fresh folder per run: MY SETTINGS and the bindings save there)
package.preload["mirror.link"] = function() return { dir = function() return linkdir end } end
package.preload["mirror.teleport"] = function() return { tip = function() return nil end } end
package.preload["mirror.chat"] = function() return noop end

-- ANY: whatever an unmodelled engine field or call gives back (valid, callable, swallows writes)
ANY = setmetatable({}, { __index = function() return ANY end, __call = function() return ANY end,
                         __newindex = function() end })
rawset(ANY, "IsValid", function() return true end)
rawset(ANY, "GetAddress", function() return 0 end)

function FName(s) return { s = s } end
local TXT = { __index = { ToString = function(self) return self.s end } }
function FText(s) return setmetatable({ s = s }, TXT) end

-- widgets: the parts journal_tab reads back are modelled, the rest is ANY
ALL, PRESSED, HOVER, FOCUS = {}, {}, {}, {}
local nid = 0
local M = {}
local W = { __index = function(t, k) return M[k] or ANY end }
function WIDGET(cls, name, t)
    nid = nid + 1
    t = t or {}
    t.cls, t.name, t.id, t.kids = cls, name, nid, {}
    setmetatable(t, W)
    ALL[#ALL + 1] = t
    return t
end
function M.IsValid() return true end
function M.GetAddress(self) return self.id end
function M.GetFName(self) return FName(self.name) end
function M.SetVisibility(self, v) self.vis = v end
function M.GetVisibility(self) return self.vis or 0 end
function M.SetText(self, t) self.text = t.s end
function M.GetText(self) return FText(self.typed or "") end
function M.IsPressed(self) return PRESSED[self] == true end
function M.IsHovered(self) return HOVER[self] == true end
function M.HasKeyboardFocus(self) return FOCUS[self] == true end
function M.GetValue(self) return self.value end
function M.SetValue(self, v) self.value = v end
function M.SetColorAndOpacity(self, c) self.color = c end
function M.GetParent(self) return self.parent or ANY end
function M.GetChildrenCount(self) return #self.kids end
function M.GetChildAt(self, i) return self.kids[i + 1] end
local function widget(w) return type(w) == "table" and getmetatable(w) == W end
function M.SetContent(self, w) if widget(w) then self.content = w; w.parent = self end end
-- the slot keeps its offsets on the child (the ribbons' place down the page)
local SLOT = { __index = function(_, k)
    if k == "SetOffsets" then return function(s, o) s.child.offsets = o end end
    if k == "SetPosition" then return function(s, p) s.child.pos = p end end
    if k == "SetSize" then return function(s, p) s.child.size = p end end
    return ANY end }
local function add(self, w)
    if not widget(w) then return ANY end
    self.kids[#self.kids + 1] = w; w.parent = self
    return setmetatable({ child = w }, SLOT)
end
M.AddChildToCanvas, M.AddChildToVerticalBox, M.AddChildToHorizontalBox, M.AddChildToOverlay = add, add, add, add

local CLASSES = {}
function StaticFindObject(p)
    local cls = p:match("^/Script/UMG%.(%w+)$")
    if cls then CLASSES[cls] = CLASSES[cls] or { IsValid = function() return true end, cls = cls }; return CLASSES[cls] end
    return ANY   -- textures, sounds, the GameplayStatics CDO
end
function StaticConstructObject(cls, outer, name)
    return WIDGET(cls.cls, name and name.s and name.s:match("^SurrounSync_(.-)_%d+$") or "?")
end

-- the handbook: three game pages, the quests tab button in its overlay, the fade
local function gamepage(n)
    return WIDGET("UserWidget", n, { WidgetTree = WIDGET("WidgetTree", n .. "Tree", { RootWidget = WIDGET("CanvasPanel", n .. "Root") }),
                                     Slot = ANY })
end
local overlay = WIDGET("Overlay", "TabOverlay")
local qb = WIDGET("Button", "QuestsButton", { parent = overlay })
JUI = WIDGET("UserWidget", "JournalUI", {
    WidgetTree = WIDGET("WidgetTree", "Tree", { RootWidget = WIDGET("CanvasPanel", "JRoot") }),
    QuestsButton = qb, QuestsText = WIDGET("TextBlock", "QuestsText", { Font = {} }),
    InfoButton = WIDGET("Button", "InfoButton"), SkillsButton = WIDGET("Button", "SkillsButton"),
    Journal_InfoUI = gamepage("Info"), Journal_SkillsUI = gamepage("Skills"), Journal_QuestsUI = gamepage("Quests"),
    Fade = ANY, SetPlaybackSpeed = function() end })
PLAYER = { InGameUI = { JournalUI = JUI }, ["JournalOpen?"] = true }
package.preload["mirror.game"] = function()
    return { player = function() return PLAYER end, world = function() return ANY end, controller = function() return ANY end,
             on_tick = function() end, keybind = function() end, on_world_reset = function() end }
end

-- the real pad code, every call journal_tab makes into it logged
MS = require("mirror.mysettings")
GP = require("mirror.gamepad")
GP.init({})   -- (as main.lua: a SET only starts once the pad code runs - its tick ends the wait)
CALLS = {}
for _, f in ipairs({ "capture", "clear", "reset", "toggle_opt", "set_sens", "step_sens" }) do
    local real = GP[f]
    GP[f] = function(...) CALLS[#CALLS + 1] = f .. "(" .. table.concat((function(...)
        local t = {}; for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end; return t end)(...), ",") .. ")"
        return real(...) end
end

-- SurrounSync's side: the model and the actions (setting "gamepad" "mine" is MY SETTINGS' toggle)
ACTS = {}
REALMS = false
CTX = {
    model = function()
        return { hosts = {}, requests = {}, guests = {}, chat = {}, settings = {}, my_settings = not NO_MYSET and MS.rows() or nil,
                 headline = "", detail = "", me = "", realm_session = REALM_SESSION }
    end,
    act = setmetatable({}, { __index = function(_, k)
        return function(key, tab)
            ACTS[#ACTS + 1] = k .. (key ~= nil and (":" .. tostring(key) .. ":" .. tostring(tab)) or "")
            if k == "setting" and tab == "mine" then MS.toggle(key) end
        end end }),
    realms_on = function() return REALMS end,
    backups = noop,
    mods = function() return { rows = {} } end,
    realms = function() return REALMM or { rows = {} } end,
}
JT = require("mirror.journal_tab")
JT.configure(CTX)

function TICK(n) for _ = 1, (n or 1) do JT.tick(0.05) end end
-- a click like the engine reports it: pressed for a tick, then released while hovered
function CLICK(b)
    PRESSED[b] = true; TICK()
    PRESSED[b], HOVER[b] = false, true; TICK()
    HOVER[b] = false; TICK()
end
-- pad A on a button Slate's pad navigation focused: pressed and released with focus, never hovered
function PADCLICK(b)
    FOCUS[b] = true; PRESSED[b] = true; TICK()
    PRESSED[b] = false; TICK()
    FOCUS[b] = false; TICK()
end
-- pressed, then let go somewhere else: neither hovered nor focused
function DRAGOFF(b)
    PRESSED[b] = true; TICK()
    PRESSED[b] = false; TICK()
end
function NAMED(n) for _, w in ipairs(ALL) do if w.name == n then return w end end end
function COUNT(f) local c = 0; for _, w in ipairs(ALL) do if f(w) then c = c + 1 end end; return c end
-- on screen: no widget on the way up is collapsed / hidden (1)
function SHOWN(w)
    while w and w ~= ANY do
        if w.vis == 1 then return false end
        w = rawget(w, "parent")
    end
    return true
end
local function under(w, top) while w and w ~= ANY do if w == top then return true end; w = rawget(w, "parent") end; return false end
-- the button whose label reads `label` (under `top` when given; the first shown one wins)
function BTN(label, top)
    local hit
    for _, w in ipairs(ALL) do
        if w.cls == "Button" and w.content and w.content.text == label and (not top or under(w, top)) then
            if SHOWN(w) then return w end
            hit = hit or w
        end
    end
    return hit
end
-- the button `label` on a row with a text reading `row`
function ROWBTN(row, label)
    for _, w in ipairs(ALL) do
        local named, hit = false, nil
        for _, k in ipairs(w.kids) do
            if k.cls == "TextBlock" and k.text == row then named = true end
            if k.cls == "Button" and k.content and k.content.text == label then hit = k end
        end
        if w.cls == "HorizontalBox" and named and hit then return hit end
    end
end
function TEXTS(top)
    local t = {}
    for _, w in ipairs(ALL) do if w.cls == "TextBlock" and w.text and under(w, top) and SHOWN(w) then t[#t + 1] = w.text end end
    return table.concat(t, "|")
end
-- the X: the shown icon button (the gears hide on every other page)
function XBTN() for _, w in ipairs(ALL) do if w.name == "IconButton" and SHOWN(w) then return w end end end
-- the gear on the REALMS page / the CO-OP page's own (the first icon button built, on the page itself)
function RGEAR() for _, w in ipairs(ALL) do if w.name == "IconButton" and under(w, NAMED("RealmsCanvas")) then return w end end end
function CGEAR() for _, w in ipairs(ALL) do if w.name == "IconButton" and rawget(w, "parent") == NAMED("CoopPage") then return w end end end
-- a tab of the settings page
function TAB(label) return BTN(label, NAMED("SettingTabs")) end
-- the settings tabs' labels in order, shown or not (the page is hidden until a gear opens it)
function TABS()
    local t = {}
    for _, b in ipairs(NAMED("SettingTabs").kids) do t[#t + 1] = b.content and b.content.text or "?" end
    return table.concat(t, "|")
end
-- a settings tab's text colour: "red" = the picked one (DARK_RED), "grey" the others
function S_TAB_COLOR(label)
    local c = TAB(label).content.color
    c = c and c.SpecifiedColor
    return not c and "none" or c.R == 0.5 and "red" or c.R == 0.25 and "grey" or "other"
end
'''


def make(realms=False):
    L = lua54.LuaRuntime()
    L.execute(SETUP, SCRIPTS, tempfile.mkdtemp(prefix="jt-"))
    if realms:
        L.execute("REALMS = true")
    L.execute("TICK()")
    return L


def warnings(L):
    return [l for l in L.eval("LOG").values() if l.startswith("WARN") or l.startswith("ERROR")]


def calls(L):
    return list(L.eval("CALLS").values())


# BINDINGS: rows per page (journal_tab BIND_ROWS) and how many pages the real action list takes
BIND_ROWS = 10


def pad_pages(L):
    return -(-L.eval("#GP.binds_model()") // BIND_ROWS)


def build():
    print("build")
    L = make()
    check(warnings(L) == [], "the tab builds without a warning: %s" % warnings(L))
    # the GAMEPAD ribbon hung off the bottom of the screen (user 2026-11-01): gone, the bindings open from the REALMS gear
    check(L.eval('NAMED("GamepadTab")') is None, "no GAMEPAD tab on the handbook")
    check(L.eval('NAMED("CoopTab")') is not None and L.eval('NAMED("ModsTab").content.text') == "MODS",
          "CO-OP and MODS tabs still built")
    ribbons = L.eval('COUNT(function(w) return w.name == "Ribbon" end)')
    check(ribbons == 8, "2 ribbons x 4 pages, no third one (%d)" % ribbons)
    # QuestMarker's spot -498 plus one 150 step per ribbon: CO-OP 1, MODS 2
    tops = L.eval('(function() local t = {}; for _, w in ipairs(ALL) do if w.name == "Ribbon" and w.offsets then '
                  't[#t + 1] = (w.color.G == 0.5 and "mods" or "coop") .. "=" .. w.offsets.Top end end; '
                  'table.sort(t); return table.concat(t, ";") end)()')
    check(tops == ";".join(["coop=-348.0"] * 4 + ["mods=-198.0"] * 4), "CO-OP and MODS ribbons where they were (%s)" % tops)
    check(any("CO-OP and MODS tabs added" in l for l in L.eval("LOG").values()), "the log names the two tabs")
    box = L.eval('NAMED("Bindings")')
    check(box is not None and box.vis == 1, "the bindings are built, hidden until their tab is opened")
    check(L.eval('NAMED("Bindings").parent == NAMED("Settings")') is True, "...inside the settings page, not a page of their own")
    check(L.eval("TABS()") == "HOST RULES|MY SETTINGS|BINDINGS",
          "Realms off: tabs HOST RULES | MY SETTINGS | BINDINGS (%s)" % L.eval("TABS()"))
    check(L.eval('NAMED("Mods").parent ~= NAMED("Settings")') is True, "...MODS stays the ribbon's own page")
    R = make(realms=True)
    check(R.eval("TABS()") == "HOST RULES|MY SETTINGS|BINDINGS|MODS",
          "Realms on: tabs HOST RULES | MY SETTINGS | BINDINGS | MODS (%s)" % R.eval("TABS()"))
    check(R.eval('NAMED("Mods").parent == NAMED("Settings")') is True, "...MODS inside the settings page")
    check(R.eval('NAMED("ModsTab").content.text') == "REALMS" and R.eval('NAMED("GamepadTab")') is None,
          "with Realms on: REALMS there, no GAMEPAD tab")
    check(R.eval("RGEAR()") is not None, "a gear on the REALMS page")
    # the CO-OP gear's spot in the folder's corner: the REALMS canvas sits at 0,0 on the same page, same folder art
    spot = R.eval('(function() local g, c = RGEAR(), CGEAR(); if not (g and c) then return "no gear" end; return string.format("%g,%g,%g %g,%g,%g", '
                  'g.pos.X, g.pos.Y, g.size.X, c.pos.X, c.pos.Y, c.size.X) end)()')
    check(spot == "827,932,96 827,932,96", "the REALMS gear sits where the CO-OP gear does, same size (%s)" % spot)
    check(R.eval('(function() local c = NAMED("RealmsCanvas"); return c.pos.X == 0 and c.pos.Y == 0 end)()') is True,
          "the REALMS canvas is at the page's 0,0 (so the same numbers are the same spot)")
    check(warnings(R) == [], "with Realms on: no warnings: %s" % warnings(R))


def realms_chest():
    # audit 2026-11-02: the chest (character backups, bottom left of the folder) sat over the SERVERS tab's LIST MY
    # REALM rows, which run down into that corner
    print("realms chest")
    L = make(realms=True)
    L.execute('CLICK(NAMED("ModsTab"))')
    L.execute('function CHEST() local n = 0; for _, w in ipairs(ALL) do if w.name == "IconButton" and '
              'rawget(w, "parent") == NAMED("RealmsCanvas") then n = n + 1; if n == 2 then return w end end end end')
    check(L.eval('SHOWN(CHEST())') is True, "the chest shows on the first folder")
    L.execute('CLICK(BTN("SERVERS", NAMED("RealmsCanvas"))); TICK(2)')
    check(L.eval('SHOWN(NAMED("RealmServers"))') is True and L.eval('SHOWN(CHEST())') is False,
          "SERVERS: its box shows and the chest is gone from its corner")
    L.execute('CLICK(BTN("NEW REALM", NAMED("RealmsCanvas"))); TICK(2)')
    check(L.eval('SHOWN(CHEST())') is True, "back on the first folder: the chest again")
    check(warnings(L) == [], "no warnings: %s" % warnings(L))


def switching():
    print("switching")
    L = make(realms=True)
    L.execute('CLICK(NAMED("ModsTab"))')
    check(L.eval('SHOWN(NAMED("RealmsCanvas"))') is True and L.eval('SHOWN(RGEAR())') is True,
          "REALMS ribbon: the REALMS page with its gear")
    check(L.eval('SHOWN(CGEAR())') is False, "the CO-OP page's own gear is hidden there")
    L.execute("CLICK(RGEAR())")
    check(L.eval('SHOWN(NAMED("Settings"))') is True, "REALMS gear: the settings page shows")
    check(L.eval('SHOWN(NAMED("RealmsCanvas"))') is False and L.eval('SHOWN(RGEAR())') is False,
          "the REALMS page (and its gear) is hidden under it")
    check(L.eval('JUI.Journal_QuestsUI.vis') == 1, "the game's own page is hidden under it")
    texts = L.eval("TEXTS(NAMED('Settings'))")
    check("Only for your own game" in texts and "CONTROLLER:" in texts,
          "not in a Realm: it opens on MY SETTINGS (HOST RULES are co-op's) (%s)" % texts[:80])
    check(L.eval('SHOWN(NAMED("Bindings"))') is False and L.eval('SHOWN(NAMED("Mods"))') is False,
          "BINDINGS and MODS tabs hidden until picked")
    # the BINDINGS tab
    L.execute('CLICK(TAB("BINDINGS"))')
    check(L.eval('SHOWN(NAMED("Bindings"))') is True and L.eval('SHOWN(NAMED("SettingList"))') is False,
          "BINDINGS tab: the bindings show, the setting rows go")
    texts = L.eval("TEXTS(NAMED('Bindings'))")
    check(texts.startswith("CONTROLLER:|XBOX|"), "no GAMEPAD title of its own, CONTROLLER: XBOX first (%s)" % texts[:60])
    check("Steam Input off" in texts, "the XBOX setup hint under it")
    pages = pad_pages(L)
    check(("PAGE 1 / %d" % pages) in texts and "SET" in texts, "BUTTONS first: %d pages of %d, SET rows" % (pages, BIND_ROWS))
    check(L.eval('SHOWN(NAMED("BindSens"))') is False, "SENSITIVITY hidden on the BUTTONS tab")
    # the MODS tab
    L.execute('CLICK(TAB("MODS"))')
    check(L.eval('SHOWN(NAMED("Mods"))') is True and L.eval('SHOWN(NAMED("Bindings"))') is False
          and L.eval('SHOWN(NAMED("Settings"))') is True, "MODS tab: the mods list on the same page")
    # X from the REALMS gear: back to the REALMS page
    L.execute("CLICK(XBTN())")
    check(L.eval('SHOWN(NAMED("Settings"))') is False and L.eval('SHOWN(NAMED("RealmsCanvas"))') is True,
          "X (opened by the REALMS gear): back to the REALMS page")
    check(L.eval('SHOWN(RGEAR())') is True and L.eval('SHOWN(CGEAR())') is False, "the REALMS gear is back, CO-OP's still hidden")
    # in a Realm: the REALMS gear opens on the Realm's rules, the tab named REALM RULES
    L.execute('REALMM = { rows = {}, hosting = true, current = { id = "4R5BJRNGWF", name = "Our Farm" } }; REALM_SESSION = true; TICK(12)')
    L.execute("CLICK(RGEAR())")
    check(L.eval("TEXTS(NAMED('SettingTabs'))") == "REALM RULES|MY SETTINGS|BINDINGS|MODS",
          "in a Realm session the first tab is REALM RULES (%s)" % L.eval("TEXTS(NAMED('SettingTabs'))"))
    check(L.eval("S_TAB_COLOR('REALM RULES')") == "red", "...and it is the one picked")
    L.execute("CLICK(XBTN()); REALMM, REALM_SESSION = nil, nil; TICK(12)")
    # the gear again, then CO-OP's ribbon: the CO-OP page, no settings
    L.execute("CLICK(RGEAR())")
    L.execute('CLICK(NAMED("CoopTab"))')
    check(L.eval('SHOWN(NAMED("Settings"))') is False and L.eval('SHOWN(NAMED("RealmsCanvas"))') is False
          and L.eval('SHOWN(CGEAR())') is True, "CO-OP ribbon from the settings: the CO-OP page")
    L.execute("CLICK(JUI.QuestsButton)")
    check(L.eval("NAMED('CoopPage').vis") == 1 and L.eval("JUI.Journal_QuestsUI.vis") != 1,
          "QUESTS: our page goes, the game's comes back")
    # the CO-OP gear opens the same page; HOST RULES there
    L.execute('CLICK(NAMED("CoopTab")); CLICK(CGEAR()); CLICK(TAB("HOST RULES"))')
    check(L.eval('SHOWN(NAMED("Settings"))') is True and L.eval("TEXTS(NAMED('SettingTabs'))") == "HOST RULES|MY SETTINGS|BINDINGS|MODS",
          "CO-OP gear: the same settings page and tabs")
    # MY SETTINGS -> CONTROLLER -> BINDINGS: the BINDINGS tab; X goes back to the CO-OP page
    L.execute('CLICK(TAB("MY SETTINGS"))')
    b = L.eval('ROWBTN("CONTROLLER:", "BINDINGS")')
    check(b is not None, "MY SETTINGS still has CONTROLLER ... BINDINGS")
    L.execute('CLICK(ROWBTN("CONTROLLER:", "BINDINGS"))')
    check(L.eval('SHOWN(NAMED("Bindings"))') is True and L.eval('SHOWN(NAMED("Settings"))') is True
          and L.eval('SHOWN(NAMED("SettingList"))') is False, "BINDINGS switches to the BINDINGS tab")
    check(L.eval("S_TAB_COLOR('BINDINGS')") == "red", "...the BINDINGS tab is the one picked")
    L.execute("CLICK(XBTN())")
    check(L.eval('SHOWN(NAMED("Settings"))') is False and L.eval('SHOWN(CGEAR())') is True,
          "X (opened by the CO-OP gear): back to the CO-OP page")
    check(warnings(L) == [], "no warnings: %s" % warnings(L))


def controls():
    print("controls")
    L = make(realms=True)
    L.execute('CLICK(NAMED("ModsTab")); CLICK(RGEAR()); CLICK(TAB("BINDINGS"))')
    pages = pad_pages(L)
    # CONTROLLER type: MY SETTINGS' switch, value and hint follow
    L.execute('CLICK(BTN("XBOX", NAMED("Bindings")))')
    check("setting:gamepad:mine" in list(L.eval("ACTS").values()), "CONTROLLER button: the MY SETTINGS gamepad switch")
    texts = L.eval("TEXTS(NAMED('Bindings'))")
    check("CONTROLLER:|PLAYSTATION|" in texts and "Steam Input on" in texts, "shows PLAYSTATION and its hint")
    check(L.eval('MS.value("gamepad")') == "playstation", "the setting itself moved to PLAYSTATION")
    L.execute('CLICK(BTN("PLAYSTATION", NAMED("Bindings")))')
    check("CONTROLLER:|OFF|" in L.eval("TEXTS(NAMED('Bindings'))"), "then OFF")
    L.execute('CLICK(BTN("OFF", NAMED("Bindings")))')
    check(L.eval('MS.value("gamepad")') == "xbox", "and round to XBOX")
    # a SurrounSync model without MY SETTINGS rows: the row is read from mysettings itself
    L.execute('MS.toggle("gamepad"); NO_MYSET = true; TICK(10)')
    texts = L.eval("TEXTS(NAMED('Bindings'))")
    check("CONTROLLER:|PLAYSTATION|" in texts and "Steam Input on" in texts, "no my_settings in the model: still PLAYSTATION and its hint")
    L.execute('NO_MYSET = false; MS.toggle("gamepad"); MS.toggle("gamepad"); TICK(10)')
    # BUTTONS: SET / CLEAR on the row's own action, PREV / NEXT
    first = L.eval("GP.binds_model()[1]")
    L.execute('CLICK(ROWBTN(GP.binds_model()[1].label, "SET"))')
    check(calls(L)[-1] == "capture(%s)" % first.id, "SET: gamepad.capture(%s) (%s)" % (first.id, calls(L)[-1:]))
    check(L.eval("GP.capturing()") == first.id and "..." in L.eval("TEXTS(NAMED('Bindings'))"),
          "the row waits (...) for the pad button")
    L.execute('CLICK(ROWBTN(GP.binds_model()[2].label, "CLEAR"))')
    second = L.eval("GP.binds_model()[2].id")
    check(calls(L)[-1] == "clear(%s)" % second, "CLEAR: gamepad.clear(%s) (%s)" % (second, calls(L)[-1:]))
    # pad A on a focused button counts (Slate sets no hover from pad focus; audit 2026-11-03)
    third = L.eval("GP.binds_model()[3].id")
    L.execute('PADCLICK(ROWBTN(GP.binds_model()[3].label, "CLEAR"))')
    check(calls(L)[-1] == "clear(%s)" % third, "pad A on a focused CLEAR: gamepad.clear(%s) (%s)" % (third, calls(L)[-1:]))
    n = len(calls(L))
    L.execute('DRAGOFF(ROWBTN(GP.binds_model()[4].label, "CLEAR"))')
    check(len(calls(L)) == n, "a press let go off the button, unfocused: no click (%s)" % calls(L)[n:])
    L.execute('CLICK(BTN("NEXT >"))')
    check(("PAGE 2 / %d" % pages) in L.eval("TEXTS(NAMED('Bindings'))"), "NEXT: page 2")
    nxt = L.eval("GP.binds_model()[%d]" % (BIND_ROWS + 1))
    L.execute('CLICK(ROWBTN(GP.binds_model()[%d].label, "SET"))' % (BIND_ROWS + 1))
    check(calls(L)[-1] == "capture(%s)" % nxt.id, "page 2's first SET is action %d (%s)" % (BIND_ROWS + 1, nxt.id))
    L.execute('CLICK(BTN("< PREV")); CLICK(BTN("< PREV"))')
    check(("PAGE %d / %d" % (pages, pages)) in L.eval("TEXTS(NAMED('Bindings'))"), "PREV from page 1 wraps to %d" % pages)
    # SENSITIVITY: - / +, the slider, the switches
    L.execute('CLICK(BTN("SENSITIVITY"))')
    check(L.eval('SHOWN(NAMED("BindSens"))') is True and L.eval('SHOWN(NAMED("BindKeys"))') is False, "SENSITIVITY tab shows")
    sid = L.eval("GP.SENS[1].id")
    L.execute('CLICK(BTN("+", NAMED("BindSens")))')
    check(calls(L)[-1] == "step_sens(%s,1)" % sid, "+: gamepad.step_sens(%s, 1) (%s)" % (sid, calls(L)[-1:]))
    L.execute('CLICK(BTN("-", NAMED("BindSens")))')
    check(calls(L)[-1] == "step_sens(%s,-1)" % sid, "-: gamepad.step_sens(%s, -1)" % sid)
    L.execute('local s; for _, w in ipairs(ALL) do if w.cls == "Slider" then s = s or w end end; s.value = 0.9; TICK()')
    check(calls(L)[-1] == "set_sens(%s,0.9)" % sid, "a slider moved by hand: gamepad.set_sens(%s, 0.9) (%s)" % (sid, calls(L)[-1:]))
    L.execute('CLICK(BTN("INVERT LOOK: OFF"))')
    check(calls(L)[-1] == "toggle_opt(invert_look)" and L.eval('BTN("INVERT LOOK: ON")') is not None,
          "INVERT LOOK: gamepad.toggle_opt, the button reads ON")
    L.execute('CLICK(BTN("SWAP STICKS: OFF"))')
    check(calls(L)[-1] == "toggle_opt(swap_sticks)" and L.eval("GP.OPT.swap") is True, "SWAP STICKS: gamepad.toggle_opt")
    L.execute('CLICK(BTN("RESET TO DEFAULT"))')
    check(calls(L)[-1] == "reset()" and L.eval("GP.OPT.swap") is False and L.eval('BTN("INVERT LOOK: OFF")') is not None,
          "RESET TO DEFAULT: gamepad.reset, switches back off")
    check(warnings(L) == [], "no warnings: %s" % warnings(L))


for t in (build, switching, realms_chest, controls):
    t()
print()
print("%d checks, %d failure(s)" % (count, len(fails)))
for f in fails:
    print("  FAILED: " + f)
sys.exit(1 if fails else 0)
