"""The minimap (mirror/minimap.lua) on stand-in UMG widgets: the map placement puts the player's point in the middle
with north up whatever the view, the compass letters stay put and only the arrow turns, M twice switches it (remembered on this PC,
typing ignored), and it shows only with a GPS worn, the big map closed and no cursor. No game needed; UMG calls
themselves are pcall-wrapped, so the logic around them is what's tested.

    PYTHONPATH=tools/testpkg python tools/test-minimap.py
"""
import math
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


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)


SETUP = r'''
local scripts, dir = ...
package.path = scripts .. "\\?.lua;" .. scripts .. "\\mirror\\?.lua;" .. package.path
LOG = {}
local function out(lvl) return function(m) LOG[#LOG + 1] = lvl .. " " .. tostring(m) end end
package.preload["mirror.log"] = function()
    return { info = out("INFO"), warn = out("WARN"), error = out("ERROR"), debug = function() end }
end
local noop = setmetatable({}, { __index = function() return function() end end })
package.preload["mirror.crumb"] = function() return noop end
package.preload["mirror.link"] = function() return { dir = function() return dir end } end
SHOWN = {}
package.preload["mirror.notify"] = function() return { show = function(t) SHOWN[#SHOWN + 1] = t end } end
QC_OPEN = false
package.preload["mirror.quickchat"] = function() return { is_open = function() return QC_OPEN end } end

-- stand-in UObjects: any capitalised field is another stand-in (cached); calling one records the call on its owner
local MT, nid = {}, 0
ALL = {}
local function fake(name)
    nid = nid + 1
    local o = setmetatable({ __name = name, __id = nid, props = {}, calls = {} }, MT)
    ALL[#ALL + 1] = o
    return o
end
GPS, LOC, YAW = true, { X = 0, Y = 0, Z = 0 }, 0
ADDRS = {}   -- GetAddress calls by object name: what a comparison costs
local SPECIAL = {
    IsValid = function(o) return not o.dead end,
    GetAddress = function(o) ADDRS[o.__name] = (ADDRS[o.__name] or 0) + 1; return o.__id end,
    ["IsGPSEquipped?"] = function(o, res) res["GPS?"] = GPS end,
    K2_GetActorLocation = function(o) return o.loc or LOC end,
    GetOwningPlayer = function(o) return o.owner end,
    GetVisibility = function(o) return o.vis end,
    GetRenderOpacity = function(o) return o.props.SetRenderOpacity and o.props.SetRenderOpacity[1] or 1 end,
    GetControlRotation = function() return { Pitch = 0, Yaw = YAW, Roll = 0 } end,
    -- MapWidget's own placement: a stand-in scale (world / 100) so the test can tell where it put a marker
    ["Calculate Actor Position"] = function(o, actor, out)
        CALC = (CALC or 0) + 1
        local l = actor.loc or LOC
        out.Location = { X = l.Y / 100, Y = -l.X / 100 }
    end,
}
-- the other players' characters (each player's ghost module, as peers.each hands them over)
GHOSTS = {}
package.preload["mirror.peers"] = function()
    return { each = function(name, fn)
        for _, a in ipairs(GHOSTS) do fn({ get = function() if not a.dead then return a end end }) end
    end }
end
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
        if f.__method == "GetComponentByClass" then return COMP end
    end
    return fake("ret")
end
function StaticFindObject(p) return fake(p) end
function StaticConstructObject(cls, outer) local o = fake(cls.__name); o.cls = cls.__name; return o end
function FText(s) return s end
function FName(s) return s end

MD = fake("MapData")
rawset(MD, "Map Texture", fake("MapTex"))
rawset(MD, "World Size", 800000.0)
rawset(MD, "World Middle Coordinations", { X = 1000.0, Y = -2000.0 })
function FindFirstOf(c) if c == "BP_MapData_C" and MD_ON ~= false then return MD end end
FOUND = {}
function FindAllOf(c) return FOUND[c] end
-- a compass marker actor at world (x, y) with an icon and a colour
function MARKER(x, y, r)
    local m = fake("Marker")
    m.loc = { X = x, Y = y, Z = 0 }
    rawset(m, "Icon", fake("Icon" .. x))
    rawset(m, "IconColor", { R = r or 1, G = 0.5, B = 0, A = 1 })
    return m
end

PLAYER, PC, COMP = fake("Player"), fake("Controller"), fake("MinimapComp")
rawset(COMP, "MapToggled", false)
rawset(PC, "bShowMouseCursor", false)
KEYS, RESETS, CLEARED, TICKS = {}, {}, {}, {}
package.preload["mirror.game"] = function()
    return {
        player = function() return PLAYER end,
        controller = function() return PC end,
        keybind = function(name, mods, fn) KEYS[name] = fn end,
        on_tick = function(fn) TICKS[#TICKS + 1] = fn end,
        on_world_reset = function(fn) RESETS[#RESETS + 1] = fn end,
        on_widgets_cleared = function(fn) CLEARED[#CLEARED + 1] = fn end,
    }
end
mm = require("mirror.minimap")
mm.init()
function TICK(n, dt) for _ = 1, n or 1 do mm.tick(dt or 0.1) end end
function PRESS() KEYS.M() end
function ROOT() return mm._test.view.root end
function ROOT_VIS() local r = ROOT(); return r and r.props.SetVisibility and r.props.SetVisibility[1] end
function OF(cls) local t = {}; for _, o in ipairs(ALL) do if o.cls == "/Script/UMG." .. cls then t[#t + 1] = o end end; return t end
'''


def make():
    d = tempfile.mkdtemp()
    L = lua54.LuaRuntime()
    L.execute(SETUP, SCRIPTS, d)
    return L, d


def screen(L, wx, wy, px, py):
    """Where world point (wx, wy) shows in the map circle with the player at (px, py), as UMG draws it: the map image
    at place()'s corner in the (never turned) map canvas, its point u, v at corner + (u, v) * side."""
    mx, my, ws = 1000.0, -2000.0, 800000.0
    x0, y0, side = L.eval("function(...) return mm.place(...) end")(px, py, mx, my, ws)
    u, v = 0.5 + (wy - my) / ws, 0.5 - (wx - mx) / ws
    return x0 + u * side, y0 + v * side


def near(a, b, eps=0.01):
    return abs(a[0] - b[0]) < eps and abs(a[1] - b[1]) < eps


def maths():
    print("placement (north up)")
    L, _ = make()
    c = 112.0
    for px, py in ((1000.0, -2000.0), (55000.0, 31000.0), (-120000.0, 7000.0)):
        check(near(screen(L, px, py, px, py), (c, c)), "player at (%g, %g) is the disc's centre" % (px, py))
    # 100 m (300 m across 224 px: 74.67 px): north (world +X, the big map's up) straight up, east (+Y) to the right
    for px, py in ((55000.0, 31000.0), (-120000.0, 7000.0)):
        check(near(screen(L, px + 10000, py, px, py), (c, c - 224 / 3)), "100 m north is straight up (%g, %g)" % (px, py))
        check(near(screen(L, px, py + 10000, px, py), (c + 224 / 3, c)), "100 m east is to the right (%g, %g)" % (px, py))
    letter = L.eval("function(d) return mm.letter_at(d) end")
    for deg, want, name in ((0, (116, 17), "N at the top"), (90, (215, 116), "E on the right"),
                            (180, (116, 215), "S at the bottom"), (270, (17, 116), "W on the left")):
        p = letter(deg)
        check(abs(p[0] - want[0]) < 0.01 and abs(p[1] - want[1]) < 0.01, "%s (%s)" % (name, tuple(p)))


def toggling():
    print("M twice")
    L, d = make()
    L.execute("TICK(1); PRESS(); TICK(10)")   # one press, then 1 s later another single one
    L.execute("PRESS(); TICK(10)")
    check(not L.eval("mm.on()"), "two presses 1 s apart don't switch it")
    L.execute("PRESS(); TICK(2); PRESS(); TICK(1)")
    check(L.eval("mm.on()"), "two presses 0.2 s apart switch it on")
    check(open(os.path.join(d, "mirror_minimap.txt")).read().strip() == "on", "remembered on this PC (file says on)")
    check(L.eval("SHOWN[#SHOWN]") == "Minimap on. M twice turns it off.", "says so (%s)" % L.eval("SHOWN[#SHOWN]"))
    L.execute("PRESS(); TICK(2); PRESS(); TICK(2); PRESS(); TICK(1)")
    check(not L.eval("mm.on()"), "a third press right after doesn't count twice (off after the 2nd pair start)")
    L.execute("PRESS(); TICK(1)")
    check(L.eval("mm.on()"), "...and pairs with the next press")
    L.execute("QC_OPEN = true; PRESS(); TICK(1); PRESS(); TICK(1); QC_OPEN = false")
    check(L.eval("mm.on()"), "typing in the quick chat doesn't switch it")
    L.execute("rawset(PC, 'bShowMouseCursor', true); PRESS(); TICK(1); PRESS(); TICK(1)")
    check(L.eval("mm.on()"), "cursor up without the big map (a text box) doesn't switch it")
    L.execute("rawset(COMP, 'MapToggled', true); PRESS(); TICK(1); PRESS(); TICK(1)")
    check(not L.eval("mm.on()"), "cursor up with the big map open (the game's own M) does")
    L.execute("rawset(COMP, 'MapToggled', false); rawset(PC, 'bShowMouseCursor', false)")
    # a new game start reads the file
    L2 = lua54.LuaRuntime()
    with open(os.path.join(d, "mirror_minimap.txt"), "w") as f:
        f.write("on\n")
    L2.execute(SETUP, SCRIPTS, d)
    check(L2.eval("mm.on()"), "on again after a restart (read from the file)")
    with open(os.path.join(d, "mirror_minimap.txt"), "w") as f:
        f.write("off\n")
    L3 = lua54.LuaRuntime()
    L3.execute(SETUP, SCRIPTS, d)
    check(not L3.eval("mm.on()"), "off after a restart when the file says off")


def showing():
    print("when it shows")
    L, _ = make()
    L.execute("TICK(5)")
    check(L.eval("ROOT()") is None, "off: nothing built")
    L.execute("mm.set(true); TICK(2)")
    check(L.eval("ROOT()") is not None and L.eval("ROOT_VIS()") == 3, "on + GPS: built and shown (hit-test invisible)")
    check(L.eval("mm.bottom()") == 24 + 232 + 12, "the message cards go under it")
    check(len(L.eval("OF('RetainerBox')")) == 1, "the map sits in a retainer (the round mask)")
    ret = L.eval("OF('RetainerBox')[1]")
    check(ret.props["SetTextureParameter"] is not None and ret.props["SetTextureParameter"][1] == "MapTexture",
          "the retainer feeds the map material's MapTexture")
    check(not any("WARN" in str(x) for x in L.eval("LOG").values()), "no warnings while building")
    L.execute("YAW = 90; LOC = { X = 11000, Y = -2000, Z = 0 }; TICK(1)")
    turn = L.eval("mm._test.view.turn")
    arrow = L.eval("mm._test.view.arrow")
    check(turn.props["SetRenderTransformAngle"] is None, "the map never turns (north stays up)")
    check(arrow.props["SetRenderTransformAngle"][1] == 90, "the arrow turns in its spot by +yaw (90: pointing east)")
    piv = arrow.props["SetRenderTransformPivot"][1]
    check(piv["X"] == 0.5 and piv["Y"] == 0.5, "...around its own centre")
    n0 = L.eval("mm._test.view.letters[1].slot").props["SetPosition"][1]
    check(abs(n0["X"] - 116) < 0.01 and abs(n0["Y"] - 17) < 0.01, "facing east: N still at the top")
    pos = L.eval("mm._test.view.map_slot").props["SetPosition"][1]
    x0, y0, _ = L.eval("function(...) return mm.place(...) end")(11000, -2000, 1000.0, -2000.0, 800000.0)
    check(abs(pos["X"] - x0) < 0.01 and abs(pos["Y"] - y0) < 0.01, "the map image follows the player")
    n_turn = arrow.calls["SetRenderTransformAngle"]
    L.execute("TICK(3)")
    check(arrow.calls["SetRenderTransformAngle"] == n_turn, "nothing set again while nothing moves")
    L.execute("YAW = -135; TICK(1)")
    check(arrow.props["SetRenderTransformAngle"][1] == -135, "turning: the arrow follows (-135)")
    check(turn.props["SetRenderTransformAngle"] is None, "...and the map still doesn't turn")
    n1 = L.eval("mm._test.view.letters[1].slot").props["SetPosition"][1]
    check(n1["X"] == n0["X"] and n1["Y"] == n0["Y"], "...nor the letters")
    L.execute("GPS = false; TICK(6)")
    check(L.eval("ROOT_VIS()") == 1 and L.eval("mm.bottom()") is None, "GPS taken off: hidden, cards go back up")
    L.execute("GPS = true; TICK(6)")
    check(L.eval("ROOT_VIS()") == 3, "GPS on again: shown")
    L.execute("rawset(COMP, 'MapToggled', true); TICK(1)")
    check(L.eval("ROOT_VIS()") == 1, "big map open: hidden")
    L.execute("rawset(COMP, 'MapToggled', false); rawset(PC, 'bShowMouseCursor', true); TICK(1)")
    check(L.eval("ROOT_VIS()") == 1, "cursor up (inventory, menu): hidden")
    L.execute("rawset(PC, 'bShowMouseCursor', false); TICK(1)")
    check(L.eval("ROOT_VIS()") == 3, "back in play: shown")
    old = L.eval("mm._test.view.w")
    L.execute("for _, f in ipairs(RESETS) do f() end")
    check(old.calls["RemoveFromParent"] == 1, "world reset: the widget leaves the screen")
    L.execute("TICK(1)")
    check(L.eval("ROOT()") is not None and L.eval("mm._test.view.w") != old, "...and is built again in the new world")
    old = L.eval("mm._test.view.w")
    L.execute("for _, f in ipairs(CLEARED) do f() end; TICK(1)")
    check(old.calls["RemoveFromParent"] == 1 and L.eval("mm._test.view.w") != old, "widgets cleared (a death): built again")
    L.execute("PC = setmetatable({}, getmetatable(PLAYER)); rawset(PC, 'bShowMouseCursor', false); TICK(1)")
    check(L.eval("mm._test.view.built_for") == L.eval("PC.__id"), "a new controller: built again for it")
    # no map data in a world: it waits, says it once, no widget
    L2, _ = make()
    L2.execute("MD_ON = false; mm.set(true); TICK(50)")
    check(L2.eval("ROOT()") is None, "no BP_MapData: no widget")
    n = sum(1 for x in L2.eval("LOG").values() if "no map data" in str(x))
    check(n == 1, "logged once (%d)" % n)
    L2.execute("MD_ON = true; TICK(25)")
    check(L2.eval("ROOT_VIS()") == 3, "map data turns up: shown")
    L3, _ = make()
    L3.execute("GPS = false; mm.set(true)")
    check(L3.eval("SHOWN[#SHOWN]") == "Minimap on: it shows while you wear a GPS.", "on without a GPS: says it needs one")


def compass_marks():
    print("compass markers and the compass at the top")
    L, _ = make()
    mark = L.eval("function(...) return mm.mark_at(...) end")
    x, y, edge = mark(0, 0, 7500, 0)   # 75 m north: 56 px up, on the map
    check(abs(x - 116) < 0.01 and abs(y - 60) < 0.01 and not edge, "75 m north: 56 px above the centre")
    x, y, edge = mark(0, 0, 0, 90000)   # 900 m east: on the rim, right
    check(abs(x - (116 + 105)) < 0.01 and abs(y - 116) < 0.01 and edge, "900 m east: on the rim, at the right")
    x, y, edge = mark(0, 0, -90000, 0)   # 900 m south: on the rim, bottom
    check(abs(x - 116) < 0.01 and abs(y - (116 + 105)) < 0.01 and edge, "900 m south: on the rim, at the bottom")
    # the compass widget: ours (owned by our controller) and another one (class default, no owner)
    L.execute("""
        CW = fake and nil
        local mt = getmetatable(PLAYER)
        CW = setmetatable({ __name = 'Compass', __id = 9001, props = {}, calls = {}, owner = PC, vis = 4 }, mt)
        OTHER = setmetatable({ __name = 'CompassCDO', __id = 9002, props = {}, calls = {}, vis = 4 }, mt)
        FOUND['Compass_C'] = { OTHER, CW }
        M1, M2 = MARKER(7500, 0, 1), MARKER(0, 90000, 0.2)
        FOUND['BP_CompassMarker_C'] = { M1, M2 }
        mm.set(true); TICK(3)
    """)
    check(L.eval("ROOT_VIS()") == 3, "minimap shown")
    check(L.eval("CW.props.SetRenderOpacity and CW.props.SetRenderOpacity[1]") == 0, "the compass at the top is hidden")
    check(L.eval("OTHER.props.SetRenderOpacity") is None, "a compass widget not on our screen is left alone")
    slots = L.eval("mm._test.view.marks")
    on = [slots[i] for i in range(1, 25) if slots[i]["on"]]
    check(len(on) == 2, "both markers drawn (%d)" % len(on))
    s1 = slots[1]
    check(L.eval("mm._test.view.marks[1].img.props.SetBrushFromTexture[1] == M1.Icon"), "with the marker's own icon")
    check(s1["img"].props["SetColorAndOpacity"][1]["R"] == 1, "...and colour")
    p1 = s1["slot"].props["SetPosition"][1]
    check(abs(p1["X"] - 116) < 0.01 and abs(p1["Y"] - 60) < 0.01, "the near one at its spot on the map")
    p2 = slots[2]["slot"].props["SetPosition"][1]
    check(abs(p2["X"] - 221) < 0.01 and abs(p2["Y"] - 116) < 0.01, "the far one on the rim in its direction")
    L.execute("YAW = 90; TICK(1)")
    p2 = slots[2]["slot"].props["SetPosition"][1]
    check(abs(p2["X"] - 221) < 0.01 and abs(p2["Y"] - 116) < 0.01, "turning to face it leaves it where it is (north up)")
    # the game's fade animation puts the compass's opacity back: hidden again on the next frame
    L.execute("CW:SetRenderOpacity(0.7); TICK(1)")
    check(L.eval("CW.props.SetRenderOpacity[1]") == 0, "a fade-in on the compass is undone while the minimap shows")
    # compass taken off: its widget collapsed -> no markers on the minimap
    L.execute("CW.vis = 1; TICK(1)")
    check(not any(slots[i]["on"] for i in range(1, 25)), "no compass worn: no markers")
    L.execute("CW.vis = 4; TICK(1)")
    check(sum(1 for i in range(1, 25) if slots[i]["on"]) == 2, "compass worn again: markers back")
    # a marker removed (ping deleted): gone within the rescan time
    L.execute("M1.dead = true; FOUND['BP_CompassMarker_C'] = { M2 }; TICK(6)")
    check(sum(1 for i in range(1, 25) if slots[i]["on"]) == 1, "a removed marker goes")
    # the minimap goes (GPS off): the compass at the top comes back
    L.execute("GPS = false; TICK(6)")
    check(L.eval("ROOT_VIS()") == 1 and L.eval("CW.props.SetRenderOpacity[1]") == 1, "minimap gone: the compass is back")
    L.execute("TICK(5)")
    check(L.eval("CW.props.SetRenderOpacity[1]") == 1, "...and stays back")
    L.execute("GPS = true; TICK(6)")
    check(L.eval("CW.props.SetRenderOpacity[1]") == 0, "minimap back: compass hidden again")
    L.execute("mm.set(false); TICK(1)")
    check(L.eval("CW.props.SetRenderOpacity[1]") == 1, "M twice off: the compass is back")
    L.execute("mm.set(true); TICK(2); for _, f in ipairs(RESETS) do f() end")
    check(L.eval("CW.props.SetRenderOpacity[1]") == 1, "world reset: the compass is given back first")
    check(any("minimap: built - map" in str(x) for x in L.eval("LOG").values()), "the build logs what the map is drawn from")
    check(any("of the map texture" in str(x) for x in L.eval("LOG").values()), "...and where the player is on it")


SWEEPS = """
    SWEPT = {}
    local real = FindAllOf
    function FindAllOf(c) SWEPT[c] = (SWEPT[c] or 0) + 1; return real(c) end
    function swept(c) return SWEPT[c] or 0 end
    function ON() local n = 0; for _, s in ipairs(mm._test.view.marks) do if s.on then n = n + 1 end end; return n end
    function COMPASS()
        local c = setmetatable({ __name = 'Compass', __id = 9001, props = {}, calls = {}, owner = PC, vis = 4 }, getmetatable(PLAYER))
        rawset(c, 'UsedObjectWidgets', { GetArrayNum = function() return NAV end })
        return c
    end
    NAV = 2
"""


def costs():
    # the live log's top line 2026-11-03: minimap.lua 0.29-0.34 ms/frame, worst 8-10 ms: a FindAllOf is 6-10 ms
    print("what it costs: whole-object sweeps and calls per frame")
    L, _ = make()
    L.execute(SWEEPS + "mm.set(true); TICK(600)")
    n = L.eval("swept('Compass_C')")
    check(n <= 10, "no compass widget for 60 s: looked for %d times, not once a second" % n)
    check(L.eval("ROOT_VIS()") == 3, "...and the minimap shows all the same")
    L.execute("""
        CW = COMPASS()
        M1, M2 = MARKER(7500, 0, 1), MARKER(0, 90000, 0.2)
        FOUND['BP_CompassMarker_C'] = { M1, M2 }
        FOUND['Compass_C'] = { CW }
        TICK(110)
    """)
    check(L.eval("CW.props.SetRenderOpacity and CW.props.SetRenderOpacity[1]") == 0, "a compass that turns up later is found within 11 s")
    check(L.eval("ON()") == 2, "...and its markers drawn")
    L.execute("BEFORE = swept('BP_CompassMarker_C'); TICK(100)")
    n = L.eval("swept('BP_CompassMarker_C') - BEFORE")
    check(n <= 2, "10 s with the compass up and nothing new: %d marker sweeps, not 20" % n)
    # (right after a slow sweep, so that only the list growing can find it)
    L.execute("""
        local s = swept('BP_CompassMarker_C')
        while swept('BP_CompassMarker_C') == s do TICK(1) end
        BEFORE = swept('BP_CompassMarker_C'); M3 = MARKER(1000, 0, 0.5); FOUND['BP_CompassMarker_C'] = { M1, M2, M3 }; NAV = 3; TICK(6)
    """)
    check(L.eval("ON()") == 3, "a new marker (the compass's own widget list grew): on the minimap within 0.6 s")
    check(L.eval("swept('BP_CompassMarker_C') - BEFORE") == 1, "...for one sweep")
    L.execute("BEFORE = swept('BP_CompassMarker_C'); M1.dead = true; FOUND['BP_CompassMarker_C'] = { M2, M3 }; TICK(6)")
    check(L.eval("ON()") == 2, "a marker destroyed: off within 0.6 s, its list not counted down yet")
    check(L.eval("swept('BP_CompassMarker_C') - BEFORE") == 0, "...with no sweep")
    L.execute("M2.loc = { X = 7500, Y = 0, Z = 0 }; TICK(6)")
    p = L.eval("mm._test.view.marks[1].slot.props.SetPosition[1]")
    check(abs(p["X"] - 116) < 0.01 and abs(p["Y"] - 60) < 0.01, "a marker that moved is drawn where it is now, with no sweep")
    # the list can't be read: the slow sweep alone still finds what is new
    L.execute("rawset(CW, 'UsedObjectWidgets', nil); TICK(6); M4 = MARKER(2000, 0, 0.5); FOUND['BP_CompassMarker_C'] = { M2, M3, M4 }; TICK(55)")
    check(L.eval("ON()") == 3, "the compass's list unreadable: a new marker still shows within 5.5 s")

    L.execute("B0 = mm._test.view.marks[1].img.calls.SetBrushFromTexture; ADDRS.Icon0 = 0; TICK(20)")
    n = L.eval("ADDRS.Icon0")
    check(n <= 6, "an icon's address is read at each look, not per frame (%d in 20 frames)" % n)
    check(L.eval("mm._test.view.marks[1].img.calls.SetBrushFromTexture == B0"), "...and an unchanged icon isn't set again")

    # moves too small to see don't touch the widgets (0.097 px, 0.1 deg): each SetPosition redraws the retainer
    L, _ = make()
    L.execute("""
        mm.set(true); TICK(3)
        V = mm._test.view
        MOVES, TURNS = V.map_slot.calls.SetPosition, V.arrow.calls.SetRenderTransformAngle
        LOC = { X = 13, Y = 0, Z = 0 }; YAW = 0.1; TICK(1)
    """)
    check(L.eval("V.map_slot.calls.SetPosition == MOVES"), "0.1 px of walking: the map isn't moved")
    check(L.eval("V.arrow.calls.SetRenderTransformAngle == TURNS"), "0.1 degrees: the arrow isn't turned")
    L.execute("LOC = { X = 100, Y = 0, Z = 0 }; YAW = 0.5; TICK(1)")
    check(L.eval("V.map_slot.calls.SetPosition == MOVES + 1"), "0.75 px: it is")
    check(L.eval("V.arrow.calls.SetRenderTransformAngle == TURNS + 1"), "0.5 degrees: it is")

    # the big map's state: read once a frame while the minimap must hide at once, else a few times a second
    L, _ = make()
    L.execute("mm.set(false); ADDRS.Player = 0; TICK(120, 1 / 60)")
    n = L.eval("ADDRS.Player")
    check(n <= 45, "minimap off, 2 s: the big map looked at a few times a second (%d address reads, was 240)" % n)
    L.execute("rawset(COMP, 'MapToggled', true); TICK(7, 1 / 60)")
    check(L.eval("mm._test.big.open") is True, "...and opening it is still seen within 0.12 s")
    L.execute("rawset(COMP, 'MapToggled', false); mm.set(true); TICK(3, 1 / 60); ADDRS.Player = 0; TICK(120, 1 / 60)")
    n = L.eval("ADDRS.Player")
    check(L.eval("ROOT_VIS()") == 3 and n <= 245, "minimap shown, 2 s: looked at once a frame, not twice (%d address reads, was 480)" % n)
    L.execute("rawset(COMP, 'MapToggled', true); TICK(1, 1 / 60)")
    check(L.eval("ROOT_VIS()") == 1, "...so opening the big map hides the minimap on the very next frame")

    # a new world looks for the compass at once, however long the last one went without
    L, _ = make()
    L.execute(SWEEPS + "mm.set(true); TICK(300); for _, f in ipairs(RESETS) do f() end; CW = COMPASS(); FOUND['Compass_C'] = { CW }; TICK(3)")
    check(L.eval("CW.props.SetRenderOpacity and CW.props.SetRenderOpacity[1]") == 0, "a world reset ends the wait for the compass")


def tint(img):
    b = img.props["SetBrush"][1] if img.props["SetBrush"] else None
    return b and b.TintColor["SpecifiedColor"]


def other_players():
    print("other players on the minimap and the big map")
    L, _ = make()
    L.execute("""
        local mt = getmetatable(PLAYER)
        function GHOST(id, x, y) return setmetatable({ __name = 'Ghost', __id = id, props = {}, calls = {},
            loc = { X = x, Y = y, Z = 0 } }, mt) end
        G1, G2 = GHOST(7001, 7500, 0), GHOST(7002, 0, 90000)
        GHOSTS = { G1, G2 }
        mm.set(true); TICK(3)
    """)
    dots = L.eval("mm._test.view.dots")
    check(dots is not None and dots[1]["on"] and dots[2]["on"] and not dots[3]["on"], "two players: two dots")
    p1 = dots[1]["slot"].props["SetPosition"][1]
    check(abs(p1["X"] - 116) < 0.01 and abs(p1["Y"] - 60) < 0.01, "a near player at its spot on the map")
    p2 = dots[2]["slot"].props["SetPosition"][1]
    check(abs(p2["X"] - 221) < 0.01 and abs(p2["Y"] - 116) < 0.01, "a far player on the rim in its direction")
    c1, c2 = tint(dots[1]["img"]), tint(dots[2]["img"])
    check(c1 is not None and c2 is not None and (c1["R"], c1["G"], c1["B"]) != (c2["R"], c2["G"], c2["B"]),
          "each player its own colour")
    L.execute("G1.loc = { X = 0, Y = -7500, Z = 0 }; TICK(1)")
    p1 = dots[1]["slot"].props["SetPosition"][1]
    check(abs(p1["X"] - 60) < 0.01 and abs(p1["Y"] - 116) < 0.01, "a player moving: its dot follows the same frame")
    # the first player leaves: the second keeps its colour
    L.execute("G1.dead = true; TICK(6)")
    check(dots[1]["on"] and not dots[2]["on"], "a player gone: one dot left")
    c = tint(dots[1]["img"])
    check(c is not None and (c["R"], c["G"], c["B"]) == (c2["R"], c2["G"], c2["B"]), "...and the one left keeps its colour")
    # the second leaves instead and a new player joins: it gets a colour nobody here has (not the first one's)
    L.execute("G1.dead = nil; GHOSTS = { G1 }; TICK(6); GHOSTS = { G1, G2 }; TICK(6)")
    ca = tint(dots[1]["img"])
    L.execute("G3 = GHOST(7003, 100, 100); GHOSTS = { G1, G3 }; TICK(6)")
    c1, c3 = tint(dots[1]["img"]), tint(dots[2]["img"])
    check(c1 is not None and c3 is not None and (c1["R"], c1["G"], c1["B"]) == (ca["R"], ca["G"], ca["B"])
          and (c3["R"], c3["G"], c3["B"]) != (c1["R"], c1["G"], c1["B"]), "a newcomer gets a colour nobody here has")
    L.execute("GHOSTS = {}; TICK(6)")
    check(not any(dots[i]["on"] for i in range(1, 4)), "nobody else here: no dots")
    check(L.eval("next(mm._test.big.by)") is None, "big map never opened: no big-map markers made")

    # the big map: the minimap switched off on purpose, the dots there still show
    L, _ = make()
    L.execute("""
        local mt = getmetatable(PLAYER)
        G1 = setmetatable({ __name = 'Ghost', __id = 7001, props = {}, calls = {}, loc = { X = 5000, Y = 300, Z = 0 } }, mt)
        G2 = setmetatable({ __name = 'Ghost', __id = 7002, props = {}, calls = {}, loc = { X = -800, Y = 900, Z = 0 } }, mt)
        GHOSTS = { G1, G2 }
        rawset(COMP, 'MapToggled', true); TICK(1)
        MW = COMP.MapWidget
        OV = MW.StandardMarkerOverlay
    """)
    by = L.eval("mm._test.big.by")
    w1, w2 = by[7001], by[7002]
    check(w1 is not None and w2 is not None and w1 != w2, "map open: a marker for each player")
    check(L.eval("OV.calls.AddChildToOverlay") == 2, "...in the map's marker overlay")
    t = w1.props["SetRenderTranslation"][1]
    check(abs(t["X"] - 3) < 1e-6 and abs(t["Y"] + 50) < 1e-6, "placed by the map's own Calculate Actor Position")
    check(w1.Text.props["SetVisibility"][1] == 1, "the empty title hidden")
    icon = w1.Icon
    check(icon.props["SetVisibility"][1] == 3 and tint(icon) is not None, "the icon a coloured round dot")
    check(icon.props["SetRenderScale"][1]["X"] == 0.6, "...at the dot's size")
    L.execute("G1.loc = { X = 6000, Y = 300, Z = 0 }; TICK(1)")
    t = w1.props["SetRenderTranslation"][1]
    check(abs(t["Y"] + 60) < 1e-6, "a player moving: the marker follows")
    check(L.eval("OV.calls.AddChildToOverlay") == 2, "...without new markers")
    L.execute("G2.dead = true; TICK(1)")
    check(w2.calls["RemoveFromParent"] == 1 and L.eval("mm._test.big.by[7002]") is None, "a player gone: its marker goes")
    n = L.eval("CALC")
    L.execute("rawset(COMP, 'MapToggled', false); TICK(5)")
    check(L.eval("CALC") == n, "map closed: nothing placed")
    L.execute("G1.loc = { X = 7000, Y = 300, Z = 0 }; rawset(COMP, 'MapToggled', true); TICK(1)")
    t = w1.props["SetRenderTranslation"][1]
    check(abs(t["Y"] + 70) < 1e-6 and L.eval("OV.calls.AddChildToOverlay") == 2, "opened again: the same marker, moved")
    check(w1.Text.calls["SetVisibility"] == 2, "...and styled again (a rebuilt marker runs its Construct again)")
    L.execute("for _, f in ipairs(RESETS) do f() end")
    check(L.eval("next(mm._test.big.by)") is None and w1.calls["RemoveFromParent"] is None,
          "world reset: markers forgotten, the freed widgets not touched")
    check(not any("WARN" in str(x) for x in L.eval("LOG").values()), "no warnings")


maths()
toggling()
showing()
compass_marks()
costs()
other_players()
print("%d failure(s)" % len(fails))
sys.exit(1 if fails else 0)
