"""The J handbook tabs (mirror/journal_tab.lua) built on stand-in UMG widgets: the REALMS page builds, shows and
hides, fills from the model, and its buttons call the right actions. No game needed; catches Lua errors in the
page code (UMG calls themselves are pcall-wrapped, so only the logic around them is tested).

    PYTHONPATH=tools/testpkg python tools/test-journal-ui.py
"""
import os
import sys

try:
    from lupa import lua54
except ImportError:
    print("needs lupa: pip install --target tools/testpkg lupa, then PYTHONPATH=tools/testpkg")
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "mod", "SurrounSync", "Scripts")
fails = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)


SETUP = r'''
local scripts = ...
package.path = scripts .. "\\?.lua;" .. scripts .. "\\mirror\\?.lua;" .. package.path
LOG = {}
local function out(lvl) return function(m) LOG[#LOG + 1] = lvl .. " " .. tostring(m) end end
package.preload["mirror.log"] = function()
    return { info = out("INFO"), warn = out("WARN"), error = out("ERROR"), debug = function() end }
end
local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mirror.crumb"] = function() return noop end

-- stand-in UObjects: any capitalised field is another stand-in (cached); calling one records the call on its owner
local MT, nid = {}, 0
ALL, PRESSED, HOVER = {}, {}, {}
local function fake(name)
    nid = nid + 1
    local o = setmetatable({ __name = name, __id = nid, props = {}, kids = {} }, MT)
    ALL[#ALL + 1] = o
    return o
end
FAKE = fake
local SPECIAL = {
    IsValid = function() return true end,
    GetAddress = function(o) return o.__id end,
    IsPressed = function(o) return PRESSED[o] == true end,
    IsHovered = function(o) return HOVER[o] == true end,
    GetText = function(o) return { ToString = function() return o.typed or "" end } end,
    GetVisibility = function(o) return o.props.SetVisibility and o.props.SetVisibility[1] or 0 end,
    GetChildrenCount = function() return 0 end,
    GetFName = function(o) return { ToString = function() return o.__name end } end,
}
MT.__index = function(o, k)
    if SPECIAL[k] then return SPECIAL[k] end
    if type(k) == "string" and k:match("^[A-Z]") then
        local c = fake(o.__name .. "." .. k)
        c.__method = k
        rawset(o, k, c)
        return c
    end
    return nil
end
MT.__call = function(f, self, ...)
    if type(self) == "table" and getmetatable(self) == MT and f.__method then
        self.props[f.__method] = { ... }
        if f.__method == "SetContent" or f.__method:match("^AddChild") then self.kids[#self.kids + 1] = (...) end
    end
    return fake("ret")
end
function StaticFindObject(p) return fake(p) end
function StaticConstructObject(cls, outer, name) local o = fake(cls.__name); o.cls = cls.__name; o.wname = name; return o end
function FName(s) return s end
function FText(s) return s end
function NotifyOnNewObject() end

PLAYER = fake("Player")
package.preload["mirror.game"] = function()
    return setmetatable({ player = function() return PLAYER end }, { __index = function() return function() end end })
end

ACTS = {}
local function rec(name) return function(...) ACTS[#ACTS + 1] = { name, ... }; return true end end
local act = setmetatable({}, { __index = function(t, k) local f = rec(k); rawset(t, k, f); return f end })
MODEL = { rows = {}, service = "on", free = true }
COOP = { hosts = {}, requests = {}, guests = {}, chat = {} }
jt = require("mirror.journal_tab")
jt.configure{
    model = function() return COOP end, act = act,
    realms_on = function() return REALMS_ON end,
    realms = function() return MODEL end,
    mods = function() return { rows = {} } end,
    backups = { build = function() return fake("Backups") end, refresh = function() end, handle = function() return false end },
    can_restore = function() return false end,
}
function TICK(n) for _ = 1, n or 1 do jt.tick(0.1) end end
-- the label a button shows (its text block's last SetText)
function LABEL(b)
    local t = b.props.SetContent and b.props.SetContent[1]
    return t and t.props.SetText and t.props.SetText[1]
end
function BUTTON(label, nth)
    local n = 0
    for _, o in ipairs(ALL) do
        if o.cls == "/Script/UMG.Button" and LABEL(o) == label then
            n = n + 1
            if n == (nth or 1) then return o end
        end
    end
end
function WIDGET(cls, prop, value)
    for _, o in ipairs(ALL) do
        if o.cls == "/Script/UMG." .. cls and o.props[prop] and o.props[prop][1] == value then return o end
    end
end
function CLICK(b)
    PRESSED[b] = true; TICK(1)
    PRESSED[b] = nil; HOVER[b] = true; TICK(1); HOVER[b] = nil
end
function LAST_ACT(name) for i = #ACTS, 1, -1 do if ACTS[i][1] == name then return ACTS[i] end end end
function COUNT(name, arg)
    local n = 0
    for _, a in ipairs(ACTS) do if a[1] == name and (arg == nil or a[2] == arg) then n = n + 1 end end
    return n
end
function SHOWN(o) local v = o.props.SetVisibility; return v ~= nil and v[1] ~= 1 end
-- the box new() made under this name (journal_tab names them "SurrounSync_<name>_<n>")
function BOX(name)
    for _, o in ipairs(ALL) do
        if o.wname and o.wname:find("SurrounSync_" .. name .. "_", 1, true) == 1 then return o end
    end
end
-- "green" / "ink" / "other": the colour a text was last given
function COLOR_OF(s)
    for i = #ALL, 1, -1 do
        local o = ALL[i]
        if o.cls == "/Script/UMG.TextBlock" and o.props.SetText and o.props.SetText[1] == s then
            local c = o.props.SetColorAndOpacity and o.props.SetColorAndOpacity[1].SpecifiedColor
            if not c then return nil end
            if c.G > 0.3 and c.R < 0.1 then return "green" end
            if c.R == 0.12 and c.G == 0.08 then return "ink" end
            return "other"
        end
    end
end
function TEXT_SHOWN(s)
    for _, o in ipairs(ALL) do
        if o.cls == "/Script/UMG.TextBlock" and o.props.SetText and o.props.SetText[1] == s then return true end
    end
    return false
end
'''


def make(realms_on):
    L = lua54.LuaRuntime()
    L.execute('REALMS_ON = ' + ("true" if realms_on else "false"))
    L.execute(SETUP, SCRIPTS)
    L.execute('TICK(1)')   # injects into the handbook
    L.execute('PLAYER["JournalOpen?"] = true')
    L.execute('TICK(1)')
    return L


def errors(L):
    return [l for l in L.eval('LOG').values() if l.startswith("WARN") or l.startswith("ERROR")]


def realms_off_keeps_mods():
    print("realms_off_keeps_mods")
    L = make(False)
    check(errors(L) == [], "built without warnings: %s" % errors(L))
    check(L.eval('BUTTON("MODS", 2)') is None, "no MODS tab inside the settings (the only MODS is the ribbon)")
    check(L.eval('WIDGET("CanvasPanel", "SetVisibility", 3)') is None, "no REALMS page")
    check(L.eval('TEXT_SHOWN("MODS")') is True, "the ribbon tab says MODS")


def realms_page():
    print("realms_page")
    L = make(True)
    check(errors(L) == [], "built without warnings: %s" % errors(L))
    check(L.eval('TEXT_SHOWN("REALMS")') is True, "the ribbon tab says REALMS")
    check(L.eval('BUTTON("MODS")') is not None, "MODS moved into the settings")
    L.execute('''MODEL = { service = "on", free = true, rows = {
        { id = "4R5BJRNGWF", name = "Our Farm", info = "Nobody's playing", open = "OPEN" },
        { id = "7K2M9P4Q1Z", name = "A very long Realm name that runs on", info = "LIVE: Ann", open = "JOIN", live = true } } }''')
    # the REALMS ribbon tab is the second tab text ("REALMS") - its button holds that text
    L.execute('for _, o in ipairs(ALL) do if o.cls == "/Script/UMG.Button" and LABEL(o) == "REALMS" then TAB = o end end')
    check(L.eval('TAB') is not None, "REALMS tab button found")
    L.execute('CLICK(TAB)')
    check(errors(L) == [], "no errors opening the page: %s" % errors(L))
    check(L.eval('COUNT("realm_list", true)') == 1, "opening asks for a fresh list once")
    # 4 = SelfHitTestInvisible; 3 (HitTestInvisible) took every REALMS button out of hit testing
    check(L.eval('WIDGET("CanvasPanel", "SetVisibility", 4)') is not None, "REALMS canvas shown, its buttons clickable")
    check(L.eval('WIDGET("CanvasPanel", "SetVisibility", 3)') is None, "REALMS canvas never HitTestInvisible")
    L.execute('TICK(6)')
    check(L.eval('TEXT_SHOWN("Our Farm")') is True, "row 1 name")
    check(L.eval('TEXT_SHOWN("A very long Re...")') is True, "long names are cut")
    check(L.eval('BUTTON("JOIN")') is not None, "row 2 says JOIN")
    L.execute('CLICK(BUTTON("OPEN"))')
    a = L.eval('LAST_ACT("realm_open")')
    check(a is not None and a[2] == "4R5BJRNGWF" and a[3] == "OPEN", "OPEN opens that Realm")
    L.execute('CLICK(BUTTON("INVITE", 2))')
    check(L.eval('LAST_ACT("realm_invite")[2]') == "7K2M9P4Q1Z", "INVITE on row 2")
    L.execute('CLICK(BUTTON("KEY", 1))')
    check(L.eval('LAST_ACT("realm_key")[2]') == "4R5BJRNGWF", "KEY on row 1")
    L.execute('WIDGET("EditableText", "SetHintText", "name your Realm").typed = "  My World  "')
    L.execute('CLICK(BUTTON("CREATE"))')
    check(L.eval('LAST_ACT("realm_create")[2]') == "My World", "CREATE with the typed name")
    L.execute('WIDGET("EditableText", "SetHintText", "name your Realm").typed = "   "')
    L.execute('CLICK(BUTTON("CREATE"))')
    check(L.eval('COUNT("realm_create")') == 1, "an empty name does nothing")
    L.execute('WIDGET("EditableText", "SetHintText", "XXXX-XXXX-XXXX-XXXX").typed = "ABCD-EFGH-JKMN-PQRS"')
    L.execute('CLICK(BUTTON("ADD REALM"))')
    check(L.eval('LAST_ACT("realm_add")[2]') == "ABCD-EFGH-JKMN-PQRS", "ADD REALM with the code")
    # in a Realm: the card + member tools, END asks first
    L.execute('''MODEL = { service = "on", free = false, hosting = true, state = "You're hosting.", rows = {},
        current = { id = "4R5BJRNGWF", name = "Our Farm", code = "R-4R5BJ-RNGWF", info = "2 members" } }''')
    L.execute('TICK(6)')
    check(errors(L) == [], "no errors in a Realm: %s" % errors(L))
    check(L.eval('TEXT_SHOWN("YOU\'RE HOSTING")') is True and L.eval('TEXT_SHOWN("MEMBERS")') is True, "card + MEMBERS folder")
    L.execute('CLICK(BUTTON("ADD FRIENDS HERE"))')
    check(L.eval('LAST_ACT("realm_friends")') is not None, "ADD FRIENDS HERE")
    L.execute('CLICK(BUTTON("INVITE CODE"))')
    check(L.eval('LAST_ACT("realm_invite")[2]') == "4R5BJRNGWF", "INVITE CODE for the current Realm")
    L.execute('CLICK(BUTTON("END REALM"))')
    check(L.eval('LAST_ACT("realm_end")') is None, "first END press only asks")
    L.execute('TICK(6)')
    check(L.eval('BUTTON("SURE? END IT")') is not None, "END asks SURE?")
    L.execute('CLICK(BUTTON("SURE? END IT"))')
    check(L.eval('LAST_ACT("realm_end")') is not None, "second press ends the Realm")
    # a non-member asking to come in: its own JOIN REQUEST box in the folder with ACCEPT / DECLINE (members are let
    # in by menu.lua). 2026-10-29: the host found no way to let a friend in when it was a relabelled button
    L.execute('MODEL.request = { id = "1002", name = "Bob" }; TICK(6)')
    # (the CO-OP tab's request rows have ACCEPT / DECLINE buttons too, built first: the Realm folder's are the last ones)
    L.execute('''RACCEPT, RDECLINE = nil, nil
        for _, o in ipairs(ALL) do
            if o.cls == "/Script/UMG.Button" and LABEL(o) == "ACCEPT" then RACCEPT = o end
            if o.cls == "/Script/UMG.Button" and LABEL(o) == "DECLINE" then RDECLINE = o end
        end''')
    check(L.eval('TEXT_SHOWN("JOIN REQUEST")') is True and L.eval('TEXT_SHOWN("Bob wants to join Our Farm.")') is True,
          "a join request: JOIN REQUEST, who and where")
    # (the buttons show with their box: they never get a visibility of their own)
    check(L.eval('RACCEPT ~= nil and RDECLINE ~= nil and RACCEPT.props.SetVisibility == nil') is True,
          "...with its own ACCEPT and DECLINE")
    check(L.eval('SHOWN(BOX("RealmRequest"))') is True and L.eval('SHOWN(BOX("RealmBring"))') is False,
          "...BRING FRIENDS makes room for it (chat stays on the page)")
    check(L.eval('BUTTON("ADD FRIENDS HERE")') is not None, "ADD FRIENDS HERE keeps its own job")
    L.execute('CLICK(RACCEPT)')
    a = L.eval('LAST_ACT("accept")')
    check(a is not None and a[2] == "1002" and a[3] == "Bob", "ACCEPT lets that player in")
    check(L.eval('COUNT("realm_friends")') == 1, "...and doesn't run ADD FRIENDS HERE")
    L.execute('CLICK(RDECLINE)')
    check(L.eval('LAST_ACT("decline")') is not None and L.eval('LAST_ACT("decline")[2]') == "1002", "DECLINE turns them away")
    L.execute('MODEL.request = nil; TICK(6)')
    check(L.eval('SHOWN(BOX("RealmRequest"))') is False and L.eval('SHOWN(BOX("RealmBring"))') is True,
          "no request: the box goes, BRING FRIENDS is back")
    # who's in: one label each, online in green
    L.execute('''MODEL.current.people_list = { { short = "Ann (host)", on = true }, { short = "Bob", on = true },
        { short = "Cy", on = false } }; TICK(6)''')
    check(L.eval('TEXT_SHOWN("Ann (host)")') is True and L.eval('TEXT_SHOWN("Cy")') is True, "members listed one label each")
    check(L.eval('COLOR_OF("Bob")') == "green" and L.eval('COLOR_OF("Cy")') == "ink", "online in green, the others not")
    # a member still waiting for the Realm's host: the card shows it, CANCEL stops asking
    L.execute('''MODEL = { service = "on", free = false, joining = true, state = "Asked Ann to let you in - waiting...", rows = {},
        current = { id = "7K2M9P4Q1Z", name = "Ann's Realm", code = "R-7K2M9-P4Q1Z" } }; TICK(6)''')
    check(L.eval('TEXT_SHOWN("JOINING")') is True, "the card says JOINING")
    L.execute('CLICK(BUTTON("CANCEL"))')
    check(L.eval('LAST_ACT("cancel_join")') is not None, "CANCEL stops asking to join")
    L.execute('MODEL = { service = "on", free = false, armed = true, rows = {}, current = { name = "New" } }; TICK(6)')
    L.execute('CLICK(BUTTON("CANCEL"))')
    check(L.eval('LAST_ACT("realm_cancel")') is not None, "CANCEL while armed")
    check(errors(L) == [], "no errors at the end: %s" % errors(L))


def realms_paging():
    print("realms_paging")
    L = make(True)
    L.execute('''MODEL = { service = "on", free = true, rows = {
        { id = "1AAAAAAAAA", name = "One", info = "i", open = "OPEN" }, { id = "2AAAAAAAAA", name = "Two", info = "i", open = "OPEN" },
        { id = "3AAAAAAAAA", name = "Three", info = "i", open = "OPEN" }, { id = "4AAAAAAAAA", name = "Four", info = "i", open = "OPEN" } } }''')
    L.execute('for _, o in ipairs(ALL) do if o.cls == "/Script/UMG.Button" and LABEL(o) == "REALMS" then TAB = o end end')
    L.execute('CLICK(TAB); TICK(6)')
    check(L.eval('TEXT_SHOWN("1 / 2")') is True, "4 Realms: 2 pages of 3")
    check(L.eval('SHOWN(BUTTON("NEXT >", 2))') is True, "NEXT shown")
    L.execute('CLICK(BUTTON("NEXT >", 2)); TICK(6)')
    check(L.eval('TEXT_SHOWN("2 / 2")') is True and L.eval('TEXT_SHOWN("Four")') is True, "page 2 shows the 4th")
    L.execute('CLICK(BUTTON("OPEN", 1))')
    check(L.eval('LAST_ACT("realm_open")[2]') == "4AAAAAAAAA", "OPEN on page 2 opens the 4th")
    L.execute('MODEL.rows[4] = nil; TICK(6)')
    check(L.eval('TEXT_SHOWN("1 / 1")') is True and L.eval('SHOWN(BUTTON("NEXT >", 2))') is False, "3 Realms: one page, no NEXT")
    check(errors(L) == [], "no errors: %s" % errors(L))


for t in (realms_off_keeps_mods, realms_page, realms_paging):
    t()
print()
print("%d failure(s)" % len(fails))
sys.exit(1 if fails else 0)
