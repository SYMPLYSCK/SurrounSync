"""The quick chat (mirror/quickchat.lua) on stand-in UMG widgets: "/" with the handbook closed opens it, Enter sends
through the chat (commands included), Esc closes, the last lines and the command tip show; with nobody to talk to only
commands go. And mirror/chatcmd.lua: every hotkey in the mod's source is a command, and runs what the key runs.
No game needed; UMG calls themselves are pcall-wrapped, so the logic around them is what's tested.

    PYTHONPATH=tools/testpkg python tools/test-quickchat.py
"""
import os
import re
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
        on_widgets_cleared = function() end, on_world_reset = function(fn) RESETS[#RESETS + 1] = fn end,
    }
end

ACTIVE, SENT, SEND_OK, HISTORY = false, {}, true, {}
qc = require("mirror.quickchat")
qc.configure{
    active = function() return ACTIVE end,
    send = function(t) SENT[#SENT + 1] = t; if SEND_HOOK then SEND_HOOK() end; return SEND_OK end,
    recent = function(n) local o = {}; for i = math.max(1, #HISTORY - n + 1), #HISTORY do o[#o + 1] = HISTORY[i] end; return o end,
    tip = function(t) return t:sub(1, 1) == "/" and ("tip for " .. t) or nil end,
    say = function(t) SAID[#SAID + 1] = t end,
}
SAID = {}
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


def alone():
    print("alone")
    L = make()
    L.execute('PRESS("OEM_TWO")')
    check(L.eval('qc.is_open()') is True, "not in a session: / opens it too, for the commands")
    L.execute('INPUT().typed = "hello"; PRESS("RETURN")')
    check(L.eval('#SENT') == 0 and L.eval('qc.is_open()') is True and L.eval('#SAID') == 1,
          "a plain line isn't sent: it says why and the line stays")
    L.execute('INPUT().typed = "/fly"; PRESS("RETURN")')
    check(L.eval('SENT[1]') == "/fly" and L.eval('qc.is_open()') is False, "a command goes through the chat")
    L.execute('PRESS("OEM_TWO"); TICK(3)')
    check(L.eval('qc.is_open()') is True, "it stays open though no session runs")
    L.execute('PRESS("ESCAPE")')
    check(L.eval('qc.is_open()') is False, "Esc closes it")
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
    # (/messages opens a window with the mouse: closing the box after it took the keys from that window)
    L.execute('PRESS("OEM_TWO"); INPUT().typed = "/messages"; '
              'local mode = COUNT("SetInputMode_GameOnly"); MODE_AT_SEND = nil; SEND_HOOK = function() MODE_AT_SEND = COUNT("SetInputMode_GameOnly") - mode end; PRESS("RETURN"); SEND_HOOK = nil')
    check(L.eval('MODE_AT_SEND') == 1, "a command runs after the box has given the keys back, so a window it opens keeps them")
    L.execute('table.remove(SENT)')
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


CMD_SETUP = r'''
local scripts = ...
package.path = scripts .. "\\?.lua;" .. scripts .. "\\mirror\\?.lua;" .. package.path
RAN, SAID, LOGS = {}, {}, {}
local function ran(name) return function(...) RAN[#RAN + 1] = name .. (select("#", ...) > 0 and (" " .. tostring((...))) or "") end end
package.preload["mirror.log"] = function() return { info = function(m) LOGS[#LOGS + 1] = m end, warn = function() end } end
package.preload["mirror.util"] = function()
    return { safe = function(fn, _, ...) return fn(...) end }
end
package.preload["mirror.notify"] = function()
    return { show = function(m) SAID[#SAID + 1] = m end, open_history = ran("history") }
end
ROLE, LEAVE = nil, true
package.preload["mirror.phase1"] = function() return { started = function() return ROLE end } end
package.preload["mirror.menu"] = function() return { key_host = ran("host"), key_join = ran("join") } end
package.preload["mirror.session"] = function() return setmetatable({}, { __index = function(_, k) if k == "key_leave" and LEAVE then return ran("leave") end end }) end
package.preload["mirror.zombies"] = function() return { key_status = ran("status") } end
package.preload["mirror.invdiag"] = function() return { key_report = ran("inventory") } end
MINI = false
package.preload["mirror.minimap"] = function() return { on = function() return MINI end, set = function(v) MINI = v; RAN[#RAN + 1] = "minimap " .. tostring(v) end } end
package.preload["mirror.teleport"] = function()
    return { known = function(w) return w == "goto" or w == "accept" end, command = function(t) RAN[#RAN + 1] = "teleport " .. t; return true end,
             tip = function(t)
                 local w = t:match("^/(%S*)")
                 if ("goto"):sub(1, #w) == w then return "/goto <player> - teleport" end
                 return "/" .. w .. " isn't a command. Commands: /goto"
             end }
end
SHARED = {}
ModRef = { GetSharedVariable = function(_, k) return SHARED[k] end, SetSharedVariable = function(_, k, v) SHARED[k] = v end }
cc = require("mirror.chatcmd")
function RUN(t) RAN, SAID = {}, {}; cc.run(t); return RAN[1] end
'''


def lua_str(s):
    return '"%s"' % s.replace("\\", "\\\\")


def commands():
    print("commands")
    L = lua54.LuaRuntime()
    L.execute(CMD_SETUP, SCRIPTS)
    run = lambda t: L.eval('RUN(%r)' % t)
    said = lambda: L.eval('SAID[1]') or ""

    for line, want in (("/host", "host"), ("/join 2", "join 2"), ("/leave", "leave"), ("/inventory", "inventory"),
                       ("/messages", "history"), ("/msgs", "history"), ("/HOST", "host")):
        check(run(line) == want, "%s runs what its key runs (%s)" % (line, L.eval('RAN[1]')))
    check(run("/minimap") == "minimap true" and run("/minimap") == "minimap false", "/minimap switches it each time, as F4 does")
    for bad in ("/join", "/join 4", "/join x", "/join 1.5"):
        check(run(bad) is None and "/join 1" in said(), "%s: nothing runs, it says how: %s" % (bad, said()))
    L.execute('LEAVE = false')
    check(run("/leave") is None and "aren't" in said(), "/leave with no guest's key bound: says so")
    check(run("/status") is None and "No co-op" in said(), "/status out of a session: says so")
    L.execute('ROLE = "host"')
    check(run("/status") == "status" and "log" in said(), "/status in a session writes it to the log, and says so")

    # a command typed with \ or \\ in front, as /
    for line in ("\\host", "\\\\HOST"):
        check(L.eval('RUN(%s)' % lua_str(line)) == "host", "%s: runs /host" % line)
    check("/host" in L.eval('cc.tip("\\\\ho")'), "the \\\\ form gets the tip too")
    check(L.eval('cc.is_command("\\\\host")') is True and L.eval('cc.is_command("hello \\\\")') is False, "the \\\\ form is a command, a \\\\ later on isn't")
    # the commands of the features taken out of SurrounSync (2026-11-10) are gone
    for line in ("/fly", "/bike", "/bikelock", "/lock", "/unlock", "/fpv lock", "/giant", "/bikeview", "/drone fly"):
        check(run(line) is None and "isn't a command" in said(), "%s: not a command any more" % line)

    check(run("/goto Ann") == "teleport /goto Ann" and run("/accept") == "teleport /accept", "teleport commands still go to teleport.lua")
    check(run("/nonsense") is None and "/nonsense isn't a command" in said(), "an unknown command says so")
    check(run("/") is None and said() != "", "a bare / says something")
    check(L.eval('cc.tip("hello")') is None, "a plain line has no tip")
    check("isn't a command" in L.eval('cc.tip("/zz")'), "a tip for what isn't one")
    tip = L.eval('cc.tip("/m")')
    check("/messages" in tip and "/minimap" in tip and "\n" in tip, "/m: every command it could be, a line each: %r" % tip)
    check("\n" not in L.eval('cc.tip("/g", true)') and "\n" not in L.eval('cc.tip("/", true)'), "one line for the handbook's chat")
    check("Ctrl+F10" in L.eval('cc.tip("/le")'), "a tip names the hotkey")

    # the other mod, over its shared variable
    check(run("/syncfx toggle") is None and "isn't a command" in said() and L.eval('SHARED["SyncFX.cmd"]') is None, "/syncfx with no SyncFX listening: not offered")
    L.execute('SHARED["SyncFX.commands"] = true')
    run("/syncfx TOGGLE")
    check(L.eval('SHARED["SyncFX.cmd"]') == "toggle", "/syncfx toggle: the word goes to SyncFX")
    L.execute('SHARED["SyncFX.cmd"] = ""')
    run("/syncfx nonsense")
    check(L.eval('SHARED["SyncFX.cmd"]') == "" and "toggle" in said(), "/syncfx nonsense: not sent, lists the words: %s" % said())
    check("F8" in L.eval('cc.tip("/syncfx t")'), "/syncfx t: the tip narrows to the word, with its key")
    check("/syncfx" in L.eval('cc.tip("/")'), "the list has it while it listens")

    # every hotkey in the source has its command, so a new key can't be forgotten
    src = {}
    mirror = os.path.join(SCRIPTS, "mirror")
    for f in os.listdir(mirror):
        if f.endswith(".lua"):
            with open(os.path.join(mirror, f), encoding="utf-8") as h:
                src[f] = h.read()
    keys = set()
    for f, text in src.items():
        if f == "game.lua" or f == "phase0.lua":    # (game.keybind itself; phase0: a development mode, off in a release)
            continue
        for m in re.finditer(r'game\.keybind\(\s*("?[\w.]+"?|k)\s*,\s*(nil|\{[^}]*\})', text):
            mods = "+".join(re.findall(r"ModifierKey\.(\w+)", m.group(2)))
            keys.add((f, m.group(1).strip('"'), mods))
    command_for = {
        ("invdiag.lua", "F11", "CONTROL"): "/inventory", ("menu.lua", "H", "CONTROL"): "/host", ("menu.lua", "k", "CONTROL"): "/join",
        ("minimap.lua", "F4", ""): "/minimap", ("notify.lua", "F9", "CONTROL"): "/messages", ("session.lua", "F10", "CONTROL"): "/leave",
        ("zombies.lua", "F12", "CONTROL"): "/status",
    }
    # (no command, on purpose: Enter and Esc of a box or menu that is open, "/" itself, and F2, which renames the item
    # under the mouse where no chat box opens)
    left_out = {("journal_tab.lua", "RETURN", ""), ("names.lua", "RETURN", ""), ("names.lua", "F2", ""),
                ("quickchat.lua", "OEM_TWO", ""), ("quickchat.lua", "RETURN", ""), ("quickchat.lua", "ESCAPE", "")}
    unknown = keys - set(command_for) - left_out
    check(not unknown, "every hotkey in the source has a command or is left out on purpose: %s" % sorted(unknown))
    check(len(keys) >= 12, "(the scan found them: %d keys)" % len(keys))
    missing = [c for c in set(command_for.values()) if ("name = \"%s\"" % c[1:]) not in src["chatcmd.lua"]]
    check(not missing, "every one of those commands exists: %s" % missing)


for t in (opening, alone, sending, ending, commands):
    t()
print()
print("%d failure(s)" % len(fails))
sys.exit(1 if fails else 0)
