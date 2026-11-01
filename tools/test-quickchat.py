"""The quick chat (mirror/quickchat.lua) on stand-in UMG widgets: "/" with the handbook closed opens it in a co-op or
Realm session only, Enter sends through the chat (commands included), Esc closes, the last lines and the command
tip show. No game needed; UMG calls themselves are pcall-wrapped, so the logic around them is what's tested.

    PYTHONPATH=tools/testpkg python tools/test-quickchat.py
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
package.preload["mirror.names"] = function() return { asking = function() return ASKING == true end } end

-- stand-in UObjects: any capitalised field is another stand-in (cached); calling one records the call on its owner
local MT, nid = {}, 0
ALL = {}
local function fake(name)
    nid = nid + 1
    local o = setmetatable({ __name = name, __id = nid, props = {}, calls = {} }, MT)
    ALL[#ALL + 1] = o
    return o
end
local SPECIAL = {
    IsValid = function(o) return not o.dead end,
    GetAddress = function(o) return o.__id end,
    GetText = function(o) return { ToString = function() return o.typed or "" end } end,
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
        self.calls[f.__method] = (self.calls[f.__method] or 0) + 1
    end
    return fake("ret")
end
function StaticFindObject(p) return fake(p) end
function StaticConstructObject(cls, outer) local o = fake(cls.__name); o.cls = cls.__name; return o end
function FText(s) return s end
function FName(s) return s end

PLAYER, PC = fake("Player"), fake("Controller")
KEYS, RESETS = {}, {}
package.preload["mirror.game"] = function()
    return {
        player = function() return PLAYER end,
        controller = function() return PC end,
        keybind = function(name, mods, fn, always) KEYS[name] = { fn = fn, always = always } end,
        on_world_reset = function(fn) RESETS[#RESETS + 1] = fn end,
    }
end

ACTIVE, SENT, SEND_OK, HISTORY = false, {}, true, {}
qc = require("mirror.quickchat")
qc.configure{
    active = function() return ACTIVE end,
    send = function(t) SENT[#SENT + 1] = t; return SEND_OK end,
    recent = function(n) local o = {}; for i = math.max(1, #HISTORY - n + 1), #HISTORY do o[#o + 1] = HISTORY[i] end; return o end,
    tip = function(t) return t:sub(1, 1) == "/" and ("tip for " .. t) or nil end,
}
function TICK(n) for _ = 1, n or 1 do qc.tick(0.1) end end
function PRESS(k) KEYS[k].fn(); TICK(1) end
-- the input box the quick chat made, and the text blocks in the order made
function INPUT() for i = #ALL, 1, -1 do if ALL[i].cls == "/Script/UMG.EditableTextBox" then return ALL[i] end end end
function TEXTS()
    local t = {}
    for _, o in ipairs(ALL) do if o.cls == "/Script/UMG.TextBlock" then t[#t + 1] = o end end
    return t
end
function SHOWN_TEXT(s)
    for _, o in ipairs(TEXTS()) do if o.props.SetText and o.props.SetText[1] == s then return true end end
    return false
end
function COUNT(method)
    local n = 0
    for _, o in ipairs(ALL) do n = n + (o.calls[method] or 0) end
    return n
end
'''


def make():
    L = lua54.LuaRuntime()
    L.execute(SETUP, SCRIPTS)
    L.execute('TICK(1)')   # binds the keys
    return L


def errors(L):
    return [l for l in L.eval('LOG').values() if l.startswith("WARN") or l.startswith("ERROR")]


def opening():
    print("opening")
    L = make()
    check(L.eval('KEYS.OEM_TWO ~= nil and KEYS.RETURN ~= nil and KEYS.ESCAPE ~= nil') is True, "/, Enter and Esc are bound")
    L.execute('PRESS("OEM_TWO")')
    check(L.eval('qc.is_open()') is False, "not in a session: / does nothing")
    L.execute('ACTIVE = true; PLAYER["JournalOpen?"] = true; PRESS("OEM_TWO")')
    check(L.eval('qc.is_open()') is False, "handbook open: / does nothing (its own chat is there)")
    L.execute('PLAYER["JournalOpen?"] = false; PC.bShowMouseCursor = true; PRESS("OEM_TWO")')
    check(L.eval('qc.is_open()') is False, "inventory / pause menu (mouse shown): / does nothing")
    L.execute('PC.bShowMouseCursor = false; ASKING = true; PRESS("OEM_TWO")')
    check(L.eval('qc.is_open()') is False, "rename box open: / does nothing")
    L.execute('ASKING = false; HISTORY = { { who = "Ann", text = "hi" }, { who = "You", text = "yo" } }; PRESS("OEM_TWO")')
    check(L.eval('qc.is_open()') is True, "in a session, handbook closed: / opens the quick chat")
    check(L.eval('COUNT("AddToViewport")') == 1, "it's on screen")
    check(L.eval('COUNT("SetInputMode_UIOnlyEx")') == 1 and L.eval('COUNT("SetKeyboardFocus")') >= 1,
          "the keys go to its input box")
    check(L.eval('SHOWN_TEXT("Ann: hi")') is True and L.eval('SHOWN_TEXT("You: yo")') is True, "the last chat lines show")
    L.execute('HISTORY[3] = { who = "Ann", text = "new line" }; TICK(1)')
    check(L.eval('SHOWN_TEXT("Ann: new line")') is True, "a line that arrives while it's open shows")
    L.execute('PRESS("OEM_TWO")')
    check(L.eval('COUNT("AddToViewport")') == 1, "/ typed into the open box doesn't open a second one")
    check(errors(L) == [], "no warnings: %s" % errors(L))


def sending():
    print("sending")
    L = make()
    L.execute('ACTIVE = true; PRESS("OEM_TWO"); INPUT().typed = "/go"; TICK(1)')
    check(L.eval('SHOWN_TEXT("tip for /go")') is True, "a / line shows the command tip")
    L.execute('INPUT().typed = "/goto Ann"; PRESS("RETURN")')
    check(L.eval('SENT[1]') == "/goto Ann", "Enter sends the line through the chat (commands run there)")
    check(L.eval('qc.is_open()') is False and L.eval('COUNT("RemoveFromParent")') == 1, "and closes the box")
    check(L.eval('COUNT("SetInputMode_GameOnly")') == 1, "the keys go back to the game")
    L.execute('PRESS("OEM_TWO"); INPUT().typed = "   "; PRESS("RETURN")')
    check(L.eval('#SENT') == 1 and L.eval('qc.is_open()') is False, "Enter on an empty line just closes")
    L.execute('SEND_OK = false; PRESS("OEM_TWO"); INPUT().typed = "too fast"; PRESS("RETURN")')
    check(L.eval('SENT[2]') == "too fast" and L.eval('qc.is_open()') is True, "not sent (one a second): the box stays open")
    L.execute('PRESS("ESCAPE")')
    check(L.eval('qc.is_open()') is False and L.eval('#SENT') == 2, "Esc closes without sending")
    L.execute('PRESS("ESCAPE"); PRESS("RETURN")')
    check(L.eval('#SENT') == 2, "Esc / Enter with the box closed do nothing")
    check(errors(L) == [], "no warnings: %s" % errors(L))


def ending():
    print("ending")
    L = make()
    L.execute('ACTIVE = true; PRESS("OEM_TWO"); ACTIVE = false; TICK(1)')
    check(L.eval('qc.is_open()') is False and L.eval('COUNT("SetInputMode_GameOnly")') == 1,
          "the session ends: the box closes and the keys go back to the game")
    L.execute('ACTIVE = true; PRESS("OEM_TWO"); for _, f in ipairs(RESETS) do f() end; TICK(1)')
    check(L.eval('qc.is_open()') is False, "a load (world reset) forgets the box")
    L.execute('PRESS("OEM_TWO")')
    check(L.eval('qc.is_open()') is True, "and / opens a new one after it")
    check(errors(L) == [], "no warnings: %s" % errors(L))


for t in (opening, sending, ending):
    t()
print()
print("%d failure(s)" % len(fails))
sys.exit(1 if fails else 0)
