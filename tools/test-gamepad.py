"""Controller support (mirror/gamepad.lua) on stand-in UObjects: the pad-key plan against the real 80-row IMC_General
table, the right-stick curve, the tick lifecycle (bind after 1 s in a world, refresh on a new world, unbind when the
setting goes off, missing context / subsystem), the right-stick look calls, init config, and the MY SETTINGS row.
No game needed.

    PYTHONPATH=tools/testpkg python tools/test-gamepad.py
"""
import math
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
count = 0


def check(cond, what):
    global count
    count += 1
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)


# IMC_General.uasset, read out of the game's files: action -> its keys (80 rows, 64 actions)
IMC_ROWS = {
    "IA_CameraRotation": ["MouseX", "MouseY"], "IA_MoveForward": ["W", "Up"], "IA_MoveBackwards": ["S", "Down"],
    "IA_MoveLeft": ["A", "Left"], "IA_MoveRight": ["D", "Right"], "IA_Jump": ["SpaceBar"], "IA_Crouch": ["LeftControl"],
    "IA_Sprint": ["LeftShift"], "IA_Roll": ["C"], "IA_PrimaryAction": ["LeftMouseButton"],
    "IA_Aim": ["RightMouseButton"], "IA_Reload": ["R"], "IA_Shove": ["V"], "IA_ChangeFireMode": ["X"],
    "IA_Interact": ["F"], "IA_Inventory": ["Tab"], "IA_PauseMenu": ["Escape"], "IA_QuickSearch": ["LeftShift"],
    "IA_EquipPrimary": ["One"], "IA_EquipSecondary": ["Two"], "IA_EquipSidearm": ["Three"], "IA_EquipMelee": ["Four"],
    "IA_Unequip": ["Backslash"], "IA_ScopeZoom": ["MiddleMouseButton"], "IA_RadialMenu": ["Z"],
    "IA_ChangePerspective": ["T"], "IA_Flashlight": ["L"], "IA_VehicleHandbrake": ["SpaceBar"],
    "IA_VehicleHorn": ["H"], "IA_VehicleFlip": ["K"], "IA_Throwable": ["Five"], "IA_Hotbar6": ["Six"],
    "IA_Hotbar7": ["Seven"], "IA_Hotbar8": ["Eight"], "IA_FishingRod": ["Nine"], "IA_Distract": ["O"],
    "IA_NightVision": ["N"], "IA_Binoculars": ["B"], "IA_ZoomCamera": ["MiddleMouseButton"],
    "IA_SwitchCameraLeft": ["Q"], "IA_SwitchCameraRight": ["E"], "IA_HideUI": ["Y"], "IA_SitDown": ["Hyphen"],
    "IA_PhotoMode": ["Semicolon"], "IA_HoldBreath": ["LeftShift"], "IA_Journal": ["J"], "IA_Map": ["M"],
    "IA_FreeLook": ["LeftAlt"], "IA_AutoRun": ["Equals"],
    "IA_CancelAutoRun": ["W", "A", "S", "D", "Up", "Left", "Down", "Right"],
    "IA_ResetCameraPosition": ["Hyphen"], "IA_DebugMenu": ["#"], "IA_VehicleRadio": ["R"],
    "IA_CameraScroll": ["MouseWheelAxis"], "IA_WeaponScroll": ["MouseWheelAxis"], "IA_Screenshot": ["None"],
    "IA_ToggleTactical": ["K"], "IA_QuickSave": ["F5"], "IA_LootAll": ["E"], "IA_FloatUpwards": ["SpaceBar"],
    "IA_VehicleForward": ["W", "Up"], "IA_VehicleBackwards": ["S", "Down"], "IA_VehicleLeft": ["A", "Left"],
    "IA_VehicleRight": ["D", "Right"],
}
ROWS = [(a, k) for a, ks in IMC_ROWS.items() for k in ks]

# The spec, kept apart from gamepad.lua: pad key -> the keyboard/mouse key it stands in for
SPEC = [
    ("Gamepad_LeftStick_Up", "W"), ("Gamepad_LeftStick_Down", "S"), ("Gamepad_LeftStick_Left", "A"),
    ("Gamepad_LeftStick_Right", "D"), ("Gamepad_FaceButton_Bottom", "SpaceBar"),
    ("Gamepad_FaceButton_Right", "LeftControl"), ("Gamepad_FaceButton_Left", "F"),
    # user 2026-10-31: "y is lights/attachments" (L flashlight, K tactical); LB/RB step the hotbar (no key rows)
    ("Gamepad_FaceButton_Top", "L"), ("Gamepad_FaceButton_Top", "K"),
    ("Gamepad_LeftTrigger", "RightMouseButton"), ("Gamepad_RightTrigger", "LeftMouseButton"),
    # user 2026-10-31: L3 while aiming zooms the sight (the middle button's IA_ScopeZoom, which needs IsADS?)
    ("Gamepad_LeftThumbstick", "LeftShift"), ("Gamepad_LeftThumbstick", "MiddleMouseButton"), ("Gamepad_RightThumbstick", "V"),
    ("Gamepad_DPad_Left", "R"), ("Gamepad_DPad_Up", "Five"),
    ("Gamepad_Special_Left", "Tab"), ("Gamepad_Special_Right", "Escape"),
]
EXTRA = [("Gamepad_RightTriggerAxis", "IA_VehicleForward"), ("Gamepad_LeftTriggerAxis", "IA_VehicleBackwards")]
# actions a pad button leaves out although its key has them (Y must not flip the car, D-pad left not change its radio)
SKIP = {"Gamepad_FaceButton_Top": {"IA_VehicleFlip"}, "Gamepad_DPad_Left": {"IA_VehicleRadio"},
        "Gamepad_LeftThumbstick": {"IA_ZoomCamera"}}


def expected(rows=ROWS):
    names = {a for a, _ in rows}
    out = {(a, pad) for pad, kb in SPEC for a, k in rows if k == kb and a not in SKIP.get(pad, ())}
    out |= {(a, pad) for pad, a in EXTRA if a in names}
    return out


EXP = expected()
EXP_STR = {"%s|%s" % e for e in EXP}


def lua_rows(rows):
    return "{ " + ", ".join('{"%s","%s"}' % r for r in rows) + " }"


SETUP = r'''
local scripts = ...
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
LINKDIR = nil   -- a folder for mirror_pad_binds.txt (nil: no app folder, nothing saved)
package.preload["mirror.link"] = function() return { dir = function() return LINKDIR end } end

-- stand-in UObjects: plain tables with IsValid / GetAddress / GetFName; .dead = true makes an invalid wrapper
local OBJ, NAME, nid = {}, {}, 0
OBJ.__index, NAME.__index = OBJ, NAME
function NAME:ToString() return self.s end
function FName(s) return setmetatable({ s = s }, NAME) end
function OBJ:IsValid() return not self.dead end
function OBJ:GetAddress() return self.__id end
function OBJ:GetFName() return FName(self.__name) end
function MKOBJ(name, t)
    nid = nid + 1
    t = t or {}
    t.__name, t.__id = name, nid
    return setmetatable(t, OBJ)
end
local ACTS = {}
function ACT(name) ACTS[name] = ACTS[name] or MKOBJ(name); return ACTS[name] end

ROWS = --ROWS--
PADS = {}

-- the mapping context: Mappings array of { Key = { KeyName = <name> }, Action = <action> }
MAPKEYS, UNMAPS, SUBLOG = {}, {}, {}
IMC_PRESENT, SUB_PRESENT, HAS, PRIO = true, true, true, 3
IMC_PATH = "/Game/Input/IMC_General.IMC_General"
IMC = MKOBJ("IMC_General", { Mappings = {} })
for _, r in ipairs(ROWS) do table.insert(IMC.Mappings, { Key = { KeyName = FName(r[2]) }, Action = ACT(r[1]) }) end
function IMC.MapKey(self, action, key)
    MAPKEYS[#MAPKEYS + 1] = action.__name .. "|" .. key.KeyName.s
    table.insert(self.Mappings, { Key = { KeyName = key.KeyName }, Action = action })
end
function IMC.UnmapKey(self, action, key)
    UNMAPS[#UNMAPS + 1] = action.__name .. "|" .. key.KeyName.s
    for i = #self.Mappings, 1, -1 do
        local m = self.Mappings[i]
        if m.Action == action and m.Key.KeyName.s == key.KeyName.s then table.remove(self.Mappings, i) end
    end
end
VIEWPORT_FOCUS = 0
WBL = MKOBJ("WidgetBlueprintLibrary")
function WBL.SetFocusToGameViewport() VIEWPORT_FOCUS = VIEWPORT_FOCUS + 1 end
BUTTON_CLASS = MKOBJ("Button")
function StaticFindObject(p)
    if IMC_PRESENT and p == IMC_PATH then return IMC end
    if p == "/Script/UMG.Default__WidgetBlueprintLibrary" then return WBL end
    if p == "/Script/UMG.Button" then return BUTTON_CLASS end
    return MKOBJ("none", { dead = true })
end
-- menus on screen: user widgets in the viewport with a tree of children; buttons are .button = true
FOCUSED = {}
function WIDGET(name, t)
    local w = MKOBJ(name, t or {})
    w.kids = w.kids or {}
    function w.IsVisible(self) return not self.hidden end
    function w.IsInViewport(self) return true end
    function w.IsA(self, cls) return cls == BUTTON_CLASS and self.button == true end
    function w.GetChildrenCount(self) return #self.kids end
    function w.GetChildAt(self, i) return self.kids[i + 1] end
    function w.SetKeyboardFocus(self) FOCUSED[#FOCUSED + 1] = self.__name end
    return w
end
MENUS = {}
function FindAllOf(cls) if cls == "UserWidget" then return MENUS end end

SUB = MKOBJ("InputSubsystem")
function SUB.HasMappingContext(self, imc, o)
    SUBLOG[#SUBLOG + 1] = "Has"
    if HAS then o.OutFoundPriority = PRIO end   -- like the engine: the priority is only filled in when found
    return HAS
end
function SUB.RemoveMappingContext(self, imc, o) SUBLOG[#SUBLOG + 1] = "Remove" end
function SUB.AddMappingContext(self, imc, prio, o)
    assert(imc == IMC, "wrong context")
    SUBLOG[#SUBLOG + 1] = "Add:" .. tostring(prio)
end
function FindFirstOf(cls)
    if SUB_PRESENT and cls == "EnhancedInputLocalPlayerSubsystem" then return SUB end
    return MKOBJ("none", { dead = true })
end

-- game: a controllable world / controller / player and the captured tick
WORLD = MKOBJ("World1")
PLAYER = MKOBJ("Player", { InvertValue = 1 })
CYCLES = {}
function PLAYER.Event_WeaponCycle(self, fwd) CYCLES[#CYCLES + 1] = tostring(fwd) end
-- the interaction helper: CurrentTracActor is what the interact prompt is on (a dead one: nothing looked at)
OPTS = {}
NOTHING = MKOBJ("Nothing", { dead = true })
PLAYER.BP_JigHelperComp = MKOBJ("JigHelper", { CurrentTracActor = NOTHING })
function PLAYER.BP_JigHelperComp.CycleOptions(self, up) OPTS[#OPTS + 1] = tostring(up) end
BED = MKOBJ("Bed")
AXES, YAW, PITCH, DOWN = {}, {}, {}, {}
PC = MKOBJ("Controller", { bShowMouseCursor = false })
function PC.GetInputAnalogKeyState(self, key) return AXES[key.KeyName.s] or 0 end
function PC.IsInputKeyDown(self, key) return DOWN[key.KeyName.s] == true end
function PC.AddYawInput(self, v) YAW[#YAW + 1] = v end
function PC.AddPitchInput(self, v) PITCH[#PITCH + 1] = v end
TICKS = {}
package.preload["mirror.game"] = function()
    return {
        world = function() return WORLD end,
        controller = function() return PC end,
        player = function() return PLAYER end,
        on_tick = function(fn) TICKS[#TICKS + 1] = fn end,
    }
end
SETTING = {}
PADSTYLE = "xbox"   -- MY SETTINGS -> CONTROLLER: "xbox" / "playstation"; "boom" makes pad_style() throw
package.preload["mirror.mysettings"] = function()
    return { on = function(k) return SETTING[k] ~= false end,
             pad_style = function() if PADSTYLE == "boom" then error("boom") end; return PADSTYLE end }
end

GP = require("mirror.gamepad")

function MAPS(rows)
    local m = {}
    for _, r in ipairs(rows) do m[#m + 1] = { action = ACT(r[1]), name = r[1], key = r[2] } end
    return m
end
function PAIRSTR(res)
    local t = {}
    for _, p in ipairs(res) do t[#t + 1] = p.name .. "|" .. p.pad end
    table.sort(t)
    return table.concat(t, ";")
end
function PLANSTR(rows) return PAIRSTR(GP.plan(MAPS(rows))) end
function ACTSOK(res)
    for _, p in ipairs(res) do if p.action ~= ACT(p.name) then return false end end
    return #res > 0
end
function MIRRORSTR()
    local t = {}
    for _, p in ipairs(GP.MIRROR) do t[#t + 1] = p[1] .. "=" .. p[2] end
    return table.concat(t, ";")
end
function EXTRASTR()
    local t = {}
    for _, p in ipairs(GP.EXTRA) do t[#t + 1] = p[1] .. "=" .. p[2] end
    return table.concat(t, ";")
end
-- the context already holding the pad keys (the context outlives a world; a reloaded mod finds them)
function PRELOAD_PAD()
    for _, p in ipairs(GP.plan(MAPS(ROWS))) do
        table.insert(IMC.Mappings, { Key = { KeyName = FName(p.pad) }, Action = p.action })
    end
end
function RUN(sec, dt)
    dt = dt or 0.25
    for _ = 1, math.floor(sec / dt + 0.5) do TICKS[1](dt) end
end
function JOIN(t) return table.concat(t, ";") end
function SUM(t) local s = 0; for _, v in ipairs(t) do s = s + v end; return s end
function PADKEYS_IN_IMC()
    local n = 0
    for _, m in ipairs(IMC.Mappings) do if m.Key.KeyName.s:find("^Gamepad_") then n = n + 1 end end
    return n
end
function LOOKTICK(x, y, lt, dt)
    AXES.Gamepad_RightX, AXES.Gamepad_RightY, AXES.Gamepad_LeftTriggerAxis = x, y, lt or 0
    YAW, PITCH = {}, {}
    TICKS[1](dt or 0.1)
end
'''


def make(pre="", init=True, cfg="{}"):
    L = lua54.LuaRuntime()
    L.execute(SETUP.replace("--ROWS--", lua_rows(ROWS)), SCRIPTS)
    if pre:
        L.execute(pre)
    if init:
        L.execute("GP.init(%s)" % cfg)
    return L


def warnings(L):
    return [l for l in L.eval("LOG").values() if l.startswith("WARN") or l.startswith("ERROR")]


def split(s):
    return [x for x in s.split(";") if x]


def booted(pre=""):
    """A world that has been up for a second: bound, idle, no look calls yet."""
    L = make(pre)
    L.execute("RUN(1.0)")
    return L


# ---------------------------------------------------------------------------------------------------------------
def plan():
    print("plan")
    L = make(init=False)
    check(L.eval("MIRRORSTR()") == ";".join("%s=%s" % s for s in SPEC), "MIRROR table is the spec (%d rows)" % len(SPEC))
    check(L.eval("EXTRASTR()") == ";".join("%s=%s" % (p, a) for p, a in EXTRA), "EXTRA table is the two analog triggers")
    check(len(ROWS) == 80 and len(IMC_ROWS) == 64, "test table is the real 80 rows / 64 actions")
    res = split(L.eval("PLANSTR(%s)" % lua_rows(ROWS)))
    check(len(res) == len(set(res)), "no pair twice")
    check(set(res) == EXP_STR, "full table: every pad key on every action of its keyboard key (%d pairs)" % len(res))
    if set(res) != EXP_STR:
        print("       missing %s extra %s" % (sorted(EXP_STR - set(res)), sorted(set(res) - EXP_STR)))
    by_pad = {}
    for r in res:
        a, p = r.split("|")
        by_pad.setdefault(p, set()).add(a)
    check(by_pad.get("Gamepad_LeftThumbstick") == {"IA_Sprint", "IA_QuickSearch", "IA_HoldBreath", "IA_ScopeZoom"},
          "LeftShift + middle button: L3 gives Sprint, QuickSearch, HoldBreath and ScopeZoom, not ZoomCamera")
    check(by_pad.get("Gamepad_LeftStick_Up") == {"IA_MoveForward", "IA_VehicleForward", "IA_CancelAutoRun"},
          "W: stick up gives MoveForward, VehicleForward and CancelAutoRun")
    check(by_pad.get("Gamepad_FaceButton_Top") == {"IA_Flashlight", "IA_ToggleTactical"},
          "L + K: Y gives Flashlight and ToggleTactical, not K's VehicleFlip")
    check(by_pad.get("Gamepad_DPad_Left") == {"IA_Reload"}, "R: D-pad left gives Reload, not R's VehicleRadio")
    check(L.eval('PLANSTR({ {"IA_VehicleFlip","K"}, {"IA_ToggleTactical","K"} })') == "IA_ToggleTactical|Gamepad_FaceButton_Top",
          "skip is per action: K's other action still reaches Y")
    check(by_pad.get("Gamepad_DPad_Up") == {"IA_Throwable"}, "Five: D-pad up gives Throwable")
    check("Gamepad_LeftShoulder" not in by_pad and "Gamepad_RightShoulder" not in by_pad,
          "LB/RB have no key rows (they step the hotbar through Event_WeaponCycle)")
    check("Gamepad_DPad_Right" not in by_pad and "Gamepad_DPad_Down" not in by_pad,
          "D-pad right/down only drive menus")
    check(not any(a.startswith("IA_Equip") for a, _ in (r.split("|") for r in res)), "no hotbar slot keys (One..Four) on the pad")
    check(by_pad.get("Gamepad_FaceButton_Left") == {"IA_Interact"}, "F: X gives Interact (user: interact should be x)")
    check(by_pad.get("Gamepad_FaceButton_Bottom") == {"IA_Jump", "IA_VehicleHandbrake", "IA_FloatUpwards"},
          "SpaceBar: A gives Jump, VehicleHandbrake, FloatUpwards")
    check(by_pad.get("Gamepad_RightTrigger") == {"IA_PrimaryAction"}, "RT is the left mouse button's action only")
    check(by_pad.get("Gamepad_RightTriggerAxis") == {"IA_VehicleForward"}, "analog RT reaches IA_VehicleForward")
    check(by_pad.get("Gamepad_LeftTriggerAxis") == {"IA_VehicleBackwards"}, "analog LT reaches IA_VehicleBackwards")
    check(not any(a in ("IA_CameraRotation", "IA_Journal", "IA_Map") for a, _ in (r.split("|") for r in res)),
          "mouse look, Journal and Map are not touched by the pad")
    check(L.eval("ACTSOK(GP.plan(MAPS(%s)))" % lua_rows(ROWS)) is True, "each pair carries the context's own action object")
    # no duplicates: the context already holds the pad keys
    padrows = ROWS + [tuple(e) for e in sorted(EXP)]
    check(L.eval("PLANSTR(%s)" % lua_rows(padrows)) == "", "a second plan over mappings that include the pad rows returns nothing")
    one_missing = [e for e in sorted(EXP) if e != ("IA_Sprint", "Gamepad_LeftThumbstick")]
    check(L.eval("PLANSTR(%s)" % lua_rows(ROWS + one_missing)) == "IA_Sprint|Gamepad_LeftThumbstick",
          "with one pad row missing, only that one comes back")
    # absent keys
    check(L.eval("PLANSTR({})") == "", "no mappings: nothing planned")
    check(L.eval('PLANSTR({ {"IA_Jump","SpaceBar"} })') == "IA_Jump|Gamepad_FaceButton_Bottom",
          "only SpaceBar present: just Jump on the A button; absent keys skipped")
    check(L.eval('PLANSTR({ {"IA_CameraRotation","MouseX"}, {"IA_Journal","J"} })') == "",
          "only keys the pad doesn't stand in for: nothing planned")
    check(L.eval('PLANSTR({ {"IA_Jump","SpaceBar"} })').count("IA_Vehicle") == 0,
          "EXTRA triggers need their action present: none planned without IA_VehicleForward/Backwards")
    check(L.eval('PLANSTR({ {"IA_VehicleForward","W"} })') ==
          "IA_VehicleForward|Gamepad_LeftStick_Up;IA_VehicleForward|Gamepad_RightTriggerAxis",
          "IA_VehicleForward alone: stick up and analog RT; no brake trigger")


def stick():
    print("stick")
    L = make(init=False)
    L.execute("DZ, EX = GP.LOOK.dz, GP.LOOK.expo")
    st = L.eval("function(x, y) return GP.stick(x, y, DZ, EX) end")
    dz = L.eval("DZ")

    def mag(x, y):
        a, b = st(x, y)
        return math.hypot(a, b)

    check(tuple(st(0.0, 0.0)) == (0, 0), "0,0 gives 0,0")
    check(tuple(st(0.05, -0.05)) == (0, 0), "inside the dead zone gives 0,0")
    check(tuple(st(dz, 0.0)) == (0, 0), "exactly on the dead zone edge gives 0,0")
    check(tuple(st(0.0, -dz * 0.99)) == (0, 0), "just inside on the other axis gives 0,0")
    a, b = st(None, None)
    check((a, b) == (0, 0) and a == a and b == b, "nil, nil gives 0,0 and no NaN")
    a, b = st(0.0, None)
    check((a, b) == (0, 0), "x only, y nil gives 0,0")
    a, b = L.eval("GP.stick(0, 0, 0, 2)")
    check(a == 0 and b == 0 and a == a and b == b, "0,0 with a zero dead zone gives 0,0, no NaN (0/0)")
    for x, y in ((1.0, 0.0), (0.0, -1.0), (-1.0, 0.0), (0.7071, 0.7071), (1.0, 1.0), (2.0, 0.0), (-0.8, 0.8)):
        m = mag(x, y)
        check(abs(m - 1) < 5e-3,
              "full tilt (%s, %s) gives magnitude 1 (got %.4f)" % (x, y, m))
    check(abs(mag(0.56, 0.0) - 0.25) < 1e-6, "mid tilt: (0.56-dz)/(1-dz) squared = 0.25 (got %.4f)" % mag(0.56, 0.0))
    ok = True
    for ang in range(0, 360, 15):
        r = math.radians(ang)
        for m in (0.2, 0.5, 0.9, 1.0):
            a, b = st(m * math.cos(r), m * math.sin(r))
            if math.hypot(a, b) == 0 or abs(math.atan2(b, a) - math.atan2(math.sin(r), math.cos(r))) > 1e-9:
                ok = False
    check(ok, "the direction is kept (24 angles x 4 magnitudes, all quadrants)")
    prev, mono, strict = -1.0, True, True
    for i in range(0, 101):
        m = mag(i / 100.0, 0.0)
        if m < prev - 1e-12:
            mono = False
        if i / 100.0 > dz and m <= prev:
            strict = False
        prev = m
    check(mono, "output magnitude never falls as the stick goes 0 -> 1")
    check(strict, "and rises strictly above the dead zone")
    check(mag(dz + 0.01, 0.0) < 0.01, "no jump at the dead zone edge (%.5f just outside)" % mag(dz + 0.01, 0.0))
    check(all(mag(i / 50.0, 0.0) <= 1.0 + 1e-12 for i in range(0, 101)), "never above 1, even for stick values past 1")
    # diagonal at the same stick magnitude equals the axis value (round dead zone, not square)
    check(abs(mag(0.4243, 0.4243) - mag(0.6, 0.0)) < 1e-3, "round dead zone: a diagonal acts like the same magnitude on an axis")


def lifecycle():
    print("lifecycle")
    n = len(EXP)
    L = make()
    check(L.eval("#TICKS") == 1, "init registers one tick")
    L.execute("RUN(0.75)")
    check(L.eval("#MAPKEYS") == 0 and L.eval("#SUBLOG") == 0, "nothing binds before 1 s in a world (3 ticks of 0.25)")
    L.execute("RUN(0.25)")
    mk = split(L.eval("JOIN(MAPKEYS)"))
    check(len(mk) == n and set(mk) == EXP_STR and len(set(mk)) == len(mk),
          "at 1 s: imc:MapKey once per planned pair (%d), none twice" % len(mk))
    check(L.eval("#IMC.Mappings") == 80 + n, "the context keeps its 80 keyboard rows and gains %d pad rows" % n)
    check(L.eval("JOIN(SUBLOG)") == "Has;Remove;Add:3", "context off and on again at the priority it reported (3)")
    check(any("gamepad: %d pad key(s) added, %d in total" % (n, n) in l for l in L.eval("LOG").values()),
          "the bind logs its count")
    L.execute("RUN(5.0)")
    check(L.eval("#MAPKEYS") == n and L.eval("#SUBLOG") == 3, "the same world doesn't rebind")
    # priority comes from the out table, and a context that isn't on is only added
    L2 = make("PRIO = 7")
    L2.execute("RUN(1.0)")
    check(L2.eval("JOIN(SUBLOG)") == "Has;Remove;Add:7", "priority follows OutFoundPriority (7)")
    L2 = make("HAS = false; PRIO = 9")
    L2.execute("RUN(1.0)")
    check(L2.eval("JOIN(SUBLOG)") == "Has;Add:0", "not on yet: no Remove, added at 0 (the out table isn't trusted)")
    check(L2.eval("#MAPKEYS") == n, "and its keys are still mapped")

    # a second world: refresh, no new MapKey calls
    L.execute("WORLD = MKOBJ('World2'); SUBLOG = {}")
    L.execute("RUN(0.75)")
    check(L.eval("#SUBLOG") == 0, "a new world doesn't refresh before its second is up")
    L.execute("RUN(3.0)")
    check(L.eval("#MAPKEYS") == n, "second world: no new MapKey calls (the context already holds the pad keys)")
    check(L.eval("JOIN(SUBLOG)") == "Has;Remove;Add:3", "second world: the context is refreshed once")
    check(L.eval("#IMC.Mappings") == 80 + n, "second world: no duplicate rows in the context")

    # setting off
    L.execute("SETTING.gamepad = false; UNMAPS = {}; SUBLOG = {}; RUN(1.5)")
    um = split(L.eval("JOIN(UNMAPS)"))
    check(set(um) == EXP_STR and len(um) == n, "off: UnmapKey for each pad mapping (%d)" % len(um))
    check(L.eval("PADKEYS_IN_IMC()") == 0 and L.eval("#IMC.Mappings") == 80, "off: only the 80 keyboard rows are left")
    check(L.eval("JOIN(SUBLOG)") == "Has;Remove;Add:3", "off: the context is refreshed so the pad goes dead")
    check(any("gamepad: off" in l for l in L.eval("LOG").values()) and
          any("gamepad: %d pad key(s) taken out" % n in l for l in L.eval("LOG").values()), "off is logged")
    L.execute("AXES.Gamepad_RightX = 1; YAW = {}; RUN(1.0)")
    check(L.eval("#YAW") == 0 and L.eval("#UNMAPS") == n, "off: no look calls, no repeated unmapping")
    # back on
    L.execute("SETTING.gamepad = true; MAPKEYS = {}; SUBLOG = {}; AXES.Gamepad_RightX = 0; RUN(3.0)")
    check(set(split(L.eval("JOIN(MAPKEYS)"))) == EXP_STR and L.eval("#MAPKEYS") == n, "on again: binds all %d pairs again" % n)
    check(L.eval("JOIN(SUBLOG)") == "Has;Remove;Add:3" and L.eval("PADKEYS_IN_IMC()") == n, "on again: context refreshed")
    check(warnings(L) == [], "no warnings: %s" % warnings(L))

    # pad keys already in the context when the mod loads: bind adds nothing and off still removes them all
    P = make("PRELOAD_PAD()")
    check(P.eval("PADKEYS_IN_IMC()") == n, "(setup) the context starts with %d pad rows" % n)
    P.execute("RUN(1.0)")
    check(P.eval("#MAPKEYS") == 0 and P.eval("JOIN(SUBLOG)") == "Has;Remove;Add:3",
          "pad rows already there: no MapKey, but the context is still refreshed")
    P.execute("SETTING.gamepad = false; RUN(1.5)")
    pm = split(P.eval("JOIN(UNMAPS)"))
    check(set(pm) == EXP_STR and len(pm) == n and P.eval("PADKEYS_IN_IMC()") == 0,
          "off: UnmapKey for the pad rows found already in the context (%d)" % len(pm))
    P.execute("SETTING.gamepad = true; RUN(3.0)")
    check(P.eval("#MAPKEYS") == n, "and on again re-adds them")
    check(warnings(P) == [], "no warnings: %s" % warnings(P))


def missing():
    print("missing pieces")
    n = len(EXP)
    L = make("IMC_PRESENT = false")
    ok = True
    try:
        L.execute("RUN(3.0)")
    except lua54.LuaError as e:
        ok = False
        print("       raised %s" % e)
    check(ok, "no IMC: the tick doesn't throw")
    check(L.eval("#MAPKEYS") == 0 and L.eval("#SUBLOG") == 0, "no IMC: nothing mapped, nothing refreshed")
    check(not [w for w in warnings(L) if "safe() caught" in w], "no IMC: no error caught by safe(): %s" % warnings(L))
    logs = list(L.eval("LOG").values())
    check(any("IMC_General" in l for l in logs), "no IMC: the log says the context is missing (log: %s)" % logs)
    L.execute("SETTING.gamepad = false; RUN(1.5)")
    check(not [w for w in warnings(L) if "safe() caught" in w], "no IMC, then off: no error")

    S = make("SUB_PRESENT = false")
    try:
        S.execute("RUN(3.0)")
        ok = True
    except lua54.LuaError as e:
        ok = False
        print("       raised %s" % e)
    check(ok, "no input subsystem: the tick doesn't throw")
    logs = list(S.eval("LOG").values())
    check(any("no input subsystem" in l for l in logs), "no input subsystem: logged (log: %s)" % logs)
    check(S.eval("#MAPKEYS") == n and S.eval("#SUBLOG") == 0, "no input subsystem: keys still mapped, no refresh")
    check(not [w for w in warnings(S) if "safe() caught" in w], "no input subsystem: no error caught by safe()")
    S.execute("SETTING.gamepad = false; RUN(1.5)")
    check(not [w for w in warnings(S) if "safe() caught" in w] and S.eval("#UNMAPS") == n,
          "no input subsystem, then off: unmaps all, no error")

    D = make("WORLD = MKOBJ('dead', { dead = true })")
    D.execute("RUN(3.0)")
    check(D.eval("#MAPKEYS") == 0 and not warnings(D), "no valid world: nothing binds, no error")


def look():
    print("look")
    L = booted()
    dt = 0.1
    cfg = L.eval("GP.LOOK")
    yaw, pitch, scale, aim = cfg.yaw, cfg.pitch, cfg.scale, cfg.aim
    L.execute("YAW, PITCH = {}, {}")
    full_yaw = yaw * dt / scale
    full_pitch = pitch * dt / scale

    L.execute("LOOKTICK(1, 0, 0)")
    check(L.eval("#YAW") == 1 and abs(L.eval("SUM(YAW)") - full_yaw) < 1e-9,
          "right stick x=1: AddYawInput(LOOK.yaw*dt/LOOK.scale = %.3f), got %.3f" % (full_yaw, L.eval("SUM(YAW)")))
    check(abs(L.eval("SUM(PITCH)")) < 1e-9, "right stick x=1: no pitch")
    L.execute("LOOKTICK(-1, 0, 0)")
    check(abs(L.eval("SUM(YAW)") + full_yaw) < 1e-9, "stick left turns the other way")
    L.execute("LOOKTICK(0, 1, 0)")
    p = L.eval("SUM(PITCH)")
    # kit 2026-10-31: a negative AddPitchInput for stick up looked DOWN in game (user: "inverted"); up is positive
    check(L.eval("#PITCH") == 1 and abs(p - full_pitch) < 1e-9 and abs(L.eval("SUM(YAW)")) < 1e-9,
          "stick up (RightY=+1), InvertValue 1: AddPitchInput positive (%.3f, want %.3f)" % (p, full_pitch))
    L.execute("LOOKTICK(0, -1, 0)")
    check(abs(L.eval("SUM(PITCH)") + full_pitch) < 1e-9, "stick down, InvertValue 1: negative")
    L.execute("PLAYER.InvertValue = -1; LOOKTICK(0, 1, 0)")
    p = L.eval("SUM(PITCH)")
    check(abs(p + full_pitch) < 1e-9, "stick up, InvertValue -1 (the game's invert): AddPitchInput negative (%.3f)" % p)
    L.execute("PLAYER.InvertValue = nil; LOOKTICK(0, 1, 0)")
    check(abs(L.eval("SUM(PITCH)") - full_pitch) < 1e-9, "no InvertValue: acts as 1")
    L.execute("PLAYER.InvertValue = 0; LOOKTICK(0, 1, 0)")
    check(abs(L.eval("SUM(PITCH)") - full_pitch) < 1e-9, "InvertValue 0: acts as 1 (not a frozen camera)")
    L.execute("PLAYER.InvertValue = 1")

    L.execute("LOOKTICK(1, 0, 1)")
    check(abs(L.eval("SUM(YAW)") - full_yaw * aim) < 1e-9 and aim == 0.5,
          "LT held (LeftTriggerAxis 1) halves the speed (%.3f of %.3f)" % (L.eval("SUM(YAW)"), full_yaw))
    L.execute("LOOKTICK(0, 1, 1)")
    check(abs(L.eval("SUM(PITCH)") - full_pitch * aim) < 1e-9, "LT held halves pitch too")
    L.execute("LOOKTICK(1, 0, 0.1)")
    check(abs(L.eval("SUM(YAW)") - full_yaw) < 1e-9, "LT barely touched: full speed")
    L.execute("LOOKTICK(1, 0, 0)")
    y1 = L.eval("SUM(YAW)")
    L.execute("LOOKTICK(0.56, 0, 0)")
    check(abs(L.eval("SUM(YAW)") - 0.25 * y1) < 1e-6, "mid tilt is curved: x=0.56 gives a quarter of full speed")
    L.execute("LOOKTICK(0.6, 0.8, 0)")
    ya, pi = L.eval("SUM(YAW)"), L.eval("SUM(PITCH)")
    check(ya > 0 and pi > 0 and abs(ya / full_yaw / (pi / full_pitch) - 0.6 / 0.8) < 1e-6,
          "a diagonal keeps its direction (yaw:pitch follows x:y)")
    L.execute("LOOKTICK(1, 0, 0, 0.05)")
    check(abs(L.eval("SUM(YAW)") - yaw * 0.05 / scale) < 1e-9, "the turn is per second: half the frame, half the turn")

    L.execute("LOOKTICK(0.05, 0.05, 0)")
    check(L.eval("#YAW") == 0 and L.eval("#PITCH") == 0, "a stick in the dead zone makes no calls")
    L.execute("LOOKTICK(0, 0, 0)")
    check(L.eval("#YAW") == 0 and L.eval("#PITCH") == 0, "stick at rest makes no calls")

    L.execute("PC.bShowMouseCursor = true; LOOKTICK(1, 1, 0)")
    check(L.eval("#YAW") == 0 and L.eval("#PITCH") == 0, "bShowMouseCursor true (a menu is up): no Add*Input calls")
    L.execute("PC.bShowMouseCursor = false; LOOKTICK(1, 0, 0)")
    check(L.eval("#YAW") == 1, "menu closed: the look is back")
    L.execute("PC.dead = true; LOOKTICK(1, 0, 0)")
    check(L.eval("#YAW") == 0, "invalid controller: no calls")
    L.execute("PC.dead = false")
    check(warnings(L) == [], "no warnings: %s" % warnings(L))

    # the game sets the yaw scale to its Input.Sensitivity and the pitch scale to minus that: the pad speed
    # stays the same whatever the mouse sensitivity (the live scales are read once a second)
    L.execute("function PC.GetDeprecatedInputYawScale() return 0.5 end; "
              "function PC.GetDeprecatedInputPitchScale() return -0.5 end; LOOKTICK(1, 0, 0, 1.1)")
    check(abs(L.eval("SUM(YAW)") - yaw * 1.1 / 0.5) < 1e-9,
          "yaw divides by the live yaw scale 0.5 (%.3f)" % L.eval("SUM(YAW)"))
    L.execute("LOOKTICK(0, 1, 0, 1.1)")
    check(abs(L.eval("SUM(PITCH)") - pitch * 1.1 / 0.5) < 1e-9,
          "pitch divides by the live pitch scale's size (stick up stays positive)")
    L.execute("function PC.GetDeprecatedInputYawScale() return 0 end; LOOKTICK(1, 0, 0, 1.1)")
    check(abs(L.eval("SUM(YAW)") - yaw * 1.1 / scale) < 1e-9, "a 0 yaw scale falls back to LOOK.scale")
    L.execute("PC.GetDeprecatedInputYawScale = nil; PC.GetDeprecatedInputPitchScale = nil; LOOKTICK(1, 0, 0, 1.1)")
    check(warnings(L) == [], "scale getters gone again: no warnings")

    # during the 1 s wait after a new world nothing is fed in
    L.execute("WORLD = MKOBJ('World3'); RUN(1.25); LOOKTICK(1, 0, 0)")
    check(L.eval("#YAW") == 0, "while a new world waits to rebind, the look is held back")


def init_cfg():
    print("init")
    L = make(init=False)
    L.execute("GP.init({ gamepad = { enabled = false } })")
    check(L.eval("#TICKS") == 0, "cfg.gamepad.enabled=false registers no tick")
    L = make(init=False)
    L.execute("GP.init({ gamepad = { enabled = false, look = { yaw = 1 } } })")
    check(L.eval("#TICKS") == 0 and L.eval("GP.LOOK.yaw") == 220, "disabled: look overrides aren't applied either")
    for what, cfg in (("no config", "nil"), ("empty config", "{}"), ("gamepad = true", "{ gamepad = true }")):
        L = make(init=False)
        L.execute("GP.init(%s)" % cfg)
        check(L.eval("#TICKS") == 1, "%s: one tick, enabled by default" % what)
    L = make(init=False)
    L.execute('GP.init({ gamepad = { look = { yaw = 100, dz = 0.2, pitch = "fast", bogus = 5, aim = true, expo = 1.5 } } })')
    check(L.eval("GP.LOOK.yaw") == 100 and L.eval("GP.LOOK.dz") == 0.2 and L.eval("GP.LOOK.expo") == 1.5,
          "numeric known keys override (yaw, dz, expo)")
    check(L.eval("GP.LOOK.pitch") == 150 and L.eval("GP.LOOK.aim") == 0.5 and L.eval("GP.LOOK.scale") == 2.5,
          "non-numeric values leave the default (pitch, aim) and untouched keys stay")
    check(L.eval("GP.LOOK.bogus") is None, "unknown keys are not added")
    check(L.eval("#TICKS") == 1, "and the tick is registered")
    L.execute("RUN(1.0); LOOKTICK(1, 0, 0)")
    check(abs(L.eval("SUM(YAW)") - 100 * 0.1 / 2.5) < 1e-9, "the override reaches the look (yaw 100)")


def bindings():
    print("hotbar, menus, bindings")
    import tempfile
    n = len(EXP)
    # LB/RB: one Event_WeaponCycle per fresh press, none while held, none with a menu up
    L = booted()
    L.execute("DOWN.Gamepad_RightShoulder = true; RUN(0.5)")
    check(L.eval("JOIN(CYCLES)") == "true", "RB press: one Event_WeaponCycle(true), not one per frame held")
    L.execute("DOWN.Gamepad_RightShoulder = false; RUN(0.25); DOWN.Gamepad_LeftShoulder = true; RUN(0.25)")
    check(L.eval("JOIN(CYCLES)") == "true;false", "LB press: Event_WeaponCycle(false)")
    L.execute("DOWN.Gamepad_LeftShoulder = false; RUN(0.25); PC.bShowMouseCursor = true; "
              "DOWN.Gamepad_RightShoulder = true; RUN(0.5); DOWN.Gamepad_RightShoulder = false")
    check(L.eval("#CYCLES") == 2, "menu up: LB/RB don't step the hotbar")
    L.execute("PC.bShowMouseCursor = false; RUN(0.25)")

    # menu up: every pad row but the left stick and the menu buttons (VIEW = inventory, MENU = pause) comes out
    kept = ("_LeftStick_", "Gamepad_Special_Left", "Gamepad_Special_Right")
    dpad = sorted(e for e in EXP_STR if not any(k in e for k in kept))
    L.execute("UNMAPS, MAPKEYS, SUBLOG = {}, {}, {}; PC.bShowMouseCursor = true; RUN(0.5)")
    um = sorted(split(L.eval("JOIN(UNMAPS)")))
    check(um == dpad and L.eval("JOIN(SUBLOG)") == "Has;Remove;Add:3",
          "menu opens: A/B/X/Y, D-pad, triggers, sticks' clicks and trigger axes unmapped (%d), one refresh" % len(dpad))
    check(any("IA_Jump|" in e for e in um) and any("IA_Interact|" in e for e in um) and any("IA_Crouch|" in e for e in um),
          "in the inventory A/X/B no longer jump, interact or crouch behind it")
    rows = {(m.Action.__name, m.Key.KeyName.s) for m in L.eval("IMC.Mappings").values()}
    check(("IA_Inventory", "Gamepad_Special_Left") in rows and ("IA_PauseMenu", "Gamepad_Special_Right") in rows and
          ("IA_MoveForward", "Gamepad_LeftStick_Up") in rows, "VIEW still closes the inventory, MENU still pauses, the stick still walks")
    check(L.eval("PADKEYS_IN_IMC()") == n - len(dpad), "the other pad rows stay")
    L.execute("SUBLOG = {}; RUN(1.0)")
    check(L.eval("#SUBLOG") == 0, "menu stays up: no more refreshes")
    # a D-pad press reaching the game (no button focused): the first visible button gets focus
    L.execute("""MENUS = { WIDGET('Hidden', { hidden = true, kids = { WIDGET('HiddenBtn', { button = true }) } }),
                           WIDGET('Journal', { kids = { WIDGET('Box', { kids = { WIDGET('First', { button = true }),
                                                                                  WIDGET('Second', { button = true }) } }) } }) }""")
    L.execute("DOWN.Gamepad_DPad_Down = true; RUN(0.5)")
    check(L.eval("JOIN(FOCUSED)") == "First", "D-pad press in a menu: focus on the first visible button (hidden menus skipped)")
    L.execute("RUN(0.5); DOWN.Gamepad_DPad_Down = false; RUN(0.25)")
    check(L.eval("#FOCUSED") == 1, "held D-pad: focus is set once, not every frame")
    L.execute("MAPKEYS, SUBLOG = {}, {}; PC.bShowMouseCursor = false; RUN(0.5)")
    check(sorted(split(L.eval("JOIN(MAPKEYS)"))) == dpad and L.eval("JOIN(SUBLOG)") == "Has;Remove;Add:3",
          "menu closes: those rows are mapped again, one refresh")
    check(L.eval("PADKEYS_IN_IMC()") == n, "all %d pad rows back" % n)
    check(warnings(L) == [], "no warnings: %s" % warnings(L))

    # D-pad up/down while looking at a bed or crate: the mouse wheel's option step (CycleOptions), no throwable behind it
    updown = sorted(e for e in EXP_STR if e.endswith("|Gamepad_DPad_Up") or e.endswith("|Gamepad_DPad_Down"))
    check(len(updown) > 0, "the default binds put something on D-pad up/down (%s)" % updown)
    L = booted()
    L.execute("DOWN.Gamepad_DPad_Up = true; RUN(0.5); DOWN.Gamepad_DPad_Up = false; RUN(0.25)")
    check(L.eval("#OPTS") == 0 and L.eval("#UNMAPS") == 0, "nothing looked at: no option step, D-pad rows stay")
    L.execute("UNMAPS, MAPKEYS, SUBLOG = {}, {}, {}; PLAYER.BP_JigHelperComp.CurrentTracActor = BED; RUN(0.25)")
    check(sorted(split(L.eval("JOIN(UNMAPS)"))) == updown and L.eval("JOIN(SUBLOG)") == "Has;Remove;Add:3",
          "looking at a bed: the D-pad up/down rows come out (%s), one refresh" % updown)
    check(L.eval("PADKEYS_IN_IMC()") == n - len(updown), "the other pad rows stay while looking at it")
    L.execute("DOWN.Gamepad_DPad_Up = true; RUN(0.5)")
    check(L.eval("JOIN(OPTS)") == "true", "D-pad up: one CycleOptions(true), as a wheel notch up, not one per frame held")
    L.execute("DOWN.Gamepad_DPad_Up = false; RUN(0.25); DOWN.Gamepad_DPad_Down = true; RUN(0.25); "
              "DOWN.Gamepad_DPad_Down = false; RUN(0.25)")
    check(L.eval("JOIN(OPTS)") == "true;false", "D-pad down: CycleOptions(false)")
    L.execute("SUBLOG = {}; RUN(1.0)")
    check(L.eval("#SUBLOG") == 0, "still looking at it: no more refreshes")
    # a flicker of the trace (one tick without a target) keeps the level: no refresh pair per flicker
    L.execute("PLAYER.BP_JigHelperComp.CurrentTracActor = NOTHING; RUN(0.1, 0.1); "
              "PLAYER.BP_JigHelperComp.CurrentTracActor = BED; RUN(0.25)")
    check(L.eval("#SUBLOG") == 0, "a one-tick gap in the target: no refresh")
    # a menu over it (the bed's own window): the menu level, no option step
    L.execute("PC.bShowMouseCursor = true; RUN(0.25); DOWN.Gamepad_DPad_Up = true; RUN(0.25); DOWN.Gamepad_DPad_Up = false")
    check(L.eval("#OPTS") == 2, "menu up: D-pad up doesn't step the options")
    L.execute("PC.bShowMouseCursor = false; RUN(0.25)")
    # looks away: the rows come back once the target has been gone a moment, throwable works again
    L.execute("MAPKEYS, SUBLOG = {}, {}; PLAYER.BP_JigHelperComp.CurrentTracActor = NOTHING; RUN(1.0)")
    check(sorted(split(L.eval("JOIN(MAPKEYS)"))) == updown and L.eval("JOIN(SUBLOG)") == "Has;Remove;Add:3",
          "looks away: the D-pad up/down rows are mapped again, one refresh")
    check(L.eval("PADKEYS_IN_IMC()") == n, "all %d pad rows back" % n)
    L.execute("DOWN.Gamepad_DPad_Up = true; RUN(0.5); DOWN.Gamepad_DPad_Up = false; RUN(0.25)")
    check(L.eval("#OPTS") == 2, "nothing looked at again: D-pad up is the throwable, no option step")
    # no helper on the player (a pawn without it): no step, no error
    L.execute("PLAYER.BP_JigHelperComp.dead = true; DOWN.Gamepad_DPad_Down = true; RUN(0.5); DOWN.Gamepad_DPad_Down = false")
    check(L.eval("#OPTS") == 2, "no helper: nothing happens")
    L.execute("PLAYER.BP_JigHelperComp.dead = nil")
    # CycleOptions throwing: logged once a minute, not raised into the tick
    L.execute("""PLAYER.BP_JigHelperComp.CurrentTracActor = BED; RUN(0.5)
                 PLAYER.BP_JigHelperComp.CycleOptions = function() error('boom') end
                 DOWN.Gamepad_DPad_Up = true; RUN(0.25); DOWN.Gamepad_DPad_Up = false; RUN(0.25)""")
    check(any("option step failed" in l and "boom" in l for l in L.eval("LOG").values()),
          "a failing CycleOptions is logged with its error")
    check(not any("option step failed - nil" in l for l in L.eval("LOG").values()), "a working one is not logged as failed")
    check(warnings(L) == [], "no warnings: %s" % warnings(L))

    # assign: a swap, never one button on two actions
    L = make(init=False)
    check(L.eval('GP.assign("jump", "Gamepad_RightShoulder")') is True, "assign jump to RB")
    pads = {a.id: a.pad for a in L.eval("GP.ACTIONS").values()}
    check(pads["jump"] == "Gamepad_RightShoulder" and pads["hotbar_next"] == "Gamepad_FaceButton_Bottom",
          "the action on RB (hotbar next) takes jump's old button (A)")
    bound = [p for p in pads.values() if p]
    check(len(set(bound)) == len(bound), "no button on two actions")
    check(L.eval('GP.assign("jump", "Gamepad_RightShoulder")') is False, "the same button again: no change")
    check(L.eval('GP.assign("nope", "Gamepad_RightShoulder")') is False and
          L.eval('GP.assign("jump", "Gamepad_LeftStick_Up")') is False, "unknown action or a stick direction: refused")
    check("Gamepad_RightShoulder=SpaceBar" in L.eval("MIRRORSTR()") and
          "Gamepad_FaceButton_Bottom=SpaceBar" not in L.eval("MIRRORSTR()"), "MIRROR follows the new binding")
    L.execute("GP.reset_binds()")
    check(L.eval("MIRRORSTR()") == ";".join("%s=%s" % s for s in SPEC), "reset_binds: back to the defaults")
    # parse: junk lines, unknown ids and buttons are skipped
    t = L.eval('GP.parse_binds("jump Gamepad_RightShoulder\\nbogus Gamepad_DPad_Up\\nshove NotAPad\\n\\n  reload   Gamepad_DPad_Down")')
    check(dict(t.items()) == {"jump": "Gamepad_RightShoulder", "reload": "Gamepad_DPad_Down"},
          "parse_binds keeps only known actions on known buttons")

    # saved and loaded, live rebind when bound
    d = tempfile.mkdtemp(prefix="gp-test-")
    pre = "LINKDIR = [[%s]]" % d
    L = booted(pre)
    L.execute("MAPKEYS, UNMAPS = {}, {}")
    check(L.eval('GP.set("reload", "Gamepad_FaceButton_Right")') is True, "set reload on B (crouch swaps to D-pad left)")
    with open(os.path.join(d, "mirror_pad_binds.txt"), encoding="utf-8") as f:
        saved = f.read()
    check("reload Gamepad_FaceButton_Right" in saved and "crouch Gamepad_DPad_Left" in saved, "saved to mirror_pad_binds.txt")
    um, mk = set(split(L.eval("JOIN(UNMAPS)"))), set(split(L.eval("JOIN(MAPKEYS)")))
    check("IA_Reload|Gamepad_FaceButton_Right" in mk and "IA_Crouch|Gamepad_DPad_Left" in mk,
          "rebound at once: reload on B, crouch on D-pad left")
    rows = [(m.Action.__name, m.Key.KeyName.s) for m in L.eval("IMC.Mappings").values()]
    check(("IA_Reload", "Gamepad_DPad_Left") not in rows and ("IA_Crouch", "Gamepad_FaceButton_Right") not in rows,
          "the old rows are gone from the context")
    check(len([r for r in rows if r[1].startswith("Gamepad_")]) == n, "still %d pad rows, none doubled" % n)
    L2 = make(pre)
    pads = {a.id: a.pad for a in L2.eval("GP.ACTIONS").values()}
    check(pads["reload"] == "Gamepad_FaceButton_Right" and pads["crouch"] == "Gamepad_DPad_Left", "a new start loads them")
    with open(os.path.join(d, "mirror_pad_binds.txt"), "w", encoding="utf-8") as f:
        f.write("jump Gamepad_DPad_Up\nthrowable Gamepad_DPad_Up\n")
    L3 = make(pre)
    pads = {a.id: a.pad for a in L3.eval("GP.ACTIONS").values()}
    bound = [p for p in pads.values() if p]
    check(pads["jump"] == "Gamepad_DPad_Up" and pads["throwable"] not in (None, "Gamepad_DPad_Up") and len(set(bound)) == len(bound),
          "a hand-edited file with one button twice: the first keeps it, the other gets a free button, no doubles")
    L.execute("GP.reset()")
    check(L.eval("MIRRORSTR()") == ";".join("%s=%s" % s for s in SPEC), "RESET: defaults, live")

    # stale pad rows (a reload after a rebind) are taken out by the next bind
    S = make("PRELOAD_PAD(); table.insert(IMC.Mappings, { Key = { KeyName = FName('Gamepad_DPad_Down') }, Action = ACT('IA_EquipMelee') })")
    S.execute("RUN(1.0)")
    check("IA_EquipMelee|Gamepad_DPad_Down" in split(S.eval("JOIN(UNMAPS)")) and S.eval("PADKEYS_IN_IMC()") == n,
          "bind takes out a pad row the bindings no longer want")

    # capture: SET waits for every button up, then the next press
    C = booted()
    C.execute("PC.bShowMouseCursor = true; DOWN.Gamepad_FaceButton_Bottom = true")
    check(C.eval('GP.capture("shove")') is True and C.eval("VIEWPORT_FOCUS") == 1, "capture starts and gives the game viewport focus")
    C.execute("RUN(0.5)")
    check(C.eval("GP.capturing()") == "shove", "the A that pressed SET is still down: not taken")
    check(C.eval("PADKEYS_IN_IMC()") == 0, "while SET waits, no pad row is in the context (the press only binds)")
    C.execute("DOWN.Gamepad_FaceButton_Bottom = false; RUN(0.25); DOWN.Gamepad_FaceButton_Top = true; RUN(0.25)")
    pads = {a.id: a.pad for a in C.eval("GP.ACTIONS").values()}
    check(C.eval("GP.capturing()") is None and pads["shove"] == "Gamepad_FaceButton_Top" and pads["lights"] == "Gamepad_RightThumbstick",
          "the next press binds it (Y), lights swap to R3")
    check(C.eval("#FOCUSED") == 0, "no menu focus grabbed while capturing")
    C.execute("RUN(0.25)")
    rows = {(m.Action.__name, m.Key.KeyName.s) for m in C.eval("IMC.Mappings").values()}
    check(("IA_Inventory", "Gamepad_Special_Left") in rows and ("IA_Shove", "Gamepad_FaceButton_Top") not in rows,
          "after the bind, back to the menu rows (VIEW in, the new Y shove out until the menu closes)")
    C.execute("PC.bShowMouseCursor = false; RUN(0.25)")
    rows = {(m.Action.__name, m.Key.KeyName.s) for m in C.eval("IMC.Mappings").values()}
    check(("IA_Shove", "Gamepad_FaceButton_Top") in rows and C.eval("PADKEYS_IN_IMC()") == n,
          "menu closed: all %d rows in, shove on Y" % n)
    C.execute("PC.bShowMouseCursor = true; RUN(0.25)")
    C.execute("DOWN.Gamepad_FaceButton_Top = false; RUN(0.25)")
    C.execute('GP.capture("jump"); RUN(7.0)')
    check(C.eval("GP.capturing()") is None and any("no button pressed for jump" in l for l in C.eval("LOG").values()),
          "nothing pressed in 6 s: capture ends, binding kept")
    m = {r.id: r.button for r in C.eval("GP.binds_model()").values()}
    check(m["jump"] == "A" and m["hotbar_next"] == "RB" and m["shove"] == "Y", "binds_model names the buttons")
    C.execute('GP.capture("aim")')
    check({r.id: r.button for r in C.eval("GP.binds_model()").values()}["aim"] == "PRESS A BUTTON", "the waiting row says so")
    # audit 2026-11-02: the handbook closed while SET waited - its pad rows stayed out and the next press bound
    C.execute("RUN(0.25); PC.bShowMouseCursor = false; RUN(0.25)")
    check(C.eval("GP.capturing()") is None and C.eval("PADKEYS_IN_IMC()") == n,
          "the menu closed while SET waits: no more waiting, all %d pad rows back (%r)" % (n, C.eval("GP.capturing()")))
    C.execute("DOWN.Gamepad_FaceButton_Top = true; RUN(0.25); DOWN.Gamepad_FaceButton_Top = false; RUN(0.25)")
    m2 = {r.id: r.button for r in C.eval("GP.binds_model()").values()}
    check(m2["aim"] == m["aim"] and m2["shove"] == "Y", "...and the next press binds nothing (aim %r)" % m2["aim"])
    C.execute('GP.capture("jump"); RUN(0.5)')
    check(C.eval("GP.capturing()") == "jump", "a SET with no cursor seen (none to close) still waits")
    C.execute("RUN(7.0)")
    # audit 2026-11-03: the controller off - its tick never counted SET's 6 s down, the row said "..." for good and
    # the first press after switching it back on was bound, wherever that was
    C.execute("SETTING.gamepad = false; RUN(1.5)")
    check(C.eval('GP.capture("jump")') is False and C.eval("GP.capturing()") is None, "the controller off: SET doesn't start")
    C.execute('SETTING.gamepad = true; RUN(3.0); GP.capture("jump"); SETTING.gamepad = false; RUN(1.5)')
    check(C.eval("GP.capturing()") is None, "switched off while SET waits: it ends")
    C.execute("SETTING.gamepad = true; RUN(3.0)")
    check(warnings(C) == [], "no warnings: %s" % warnings(C))


def full_bindings():
    print("full bindings")
    import tempfile
    # every game action a button can sensibly do is on the list; the new ones start on no button
    L = make(init=False)
    acts = {a.id: a for a in L.eval("GP.ACTIONS").values()}
    names = set()
    for a in acts.values():
        if a.ia:
            names |= set(a.ia.values())
    want = {"IA_Roll", "IA_ChangeFireMode", "IA_EquipPrimary", "IA_EquipSecondary", "IA_EquipSidearm", "IA_EquipMelee",
            "IA_Unequip", "IA_Hotbar6", "IA_Hotbar7", "IA_Hotbar8", "IA_FishingRod", "IA_RadialMenu", "IA_LootAll",
            "IA_Flashlight", "IA_ToggleTactical", "IA_NightVision", "IA_Binoculars", "IA_Distract", "IA_HoldBreath",
            "IA_QuickSearch", "IA_ScopeZoom", "IA_ChangePerspective", "IA_SwitchCameraLeft", "IA_SwitchCameraRight",
            "IA_ResetCameraPosition", "IA_FreeLook", "IA_AutoRun", "IA_SitDown", "IA_Journal", "IA_Map",
            "IA_VehicleHorn", "IA_VehicleRadio", "IA_VehicleFlip", "IA_HideUI", "IA_PhotoMode", "IA_QuickSave"}
    check(want <= names and names <= set(IMC_ROWS), "the by-name actions are real IMC_General actions, all %d listed" % len(want))
    check(all(not a.pad for a in acts.values() if a.ia), "the by-name actions start on no button")
    check(L.eval("PLANSTR(ROWS)") == ";".join(sorted(EXP_STR)), "defaults: the plan is the same as before the full list")
    m = {r.id: r.button for r in L.eval("GP.binds_model()").values()}
    check(m["roll"] == "NONE" and m["jump"] == "A", "binds_model: NONE for an unbound action")

    # by name: E's two actions split, the free D-pad right takes loot all only
    check(L.eval('GP.assign("loot_all", "Gamepad_DPad_Right")') is True, "loot all onto D-pad right")
    plan = set(split(L.eval("PLANSTR(ROWS)")))
    check("IA_LootAll|Gamepad_DPad_Right" in plan and "IA_SwitchCameraRight|Gamepad_DPad_Right" not in plan,
          "D-pad right does loot all, not E's shoulder swap")
    # onto a taken button: the action there had none to swap, so it goes to none
    check(L.eval('GP.assign("roll", "Gamepad_FaceButton_Bottom")') is True, "roll onto A")
    pads = {a.id: a.pad for a in L.eval("GP.ACTIONS").values()}
    check(pads["roll"] == "Gamepad_FaceButton_Bottom" and pads["jump"] is None, "jump (on A) goes to none")
    plan = set(split(L.eval("PLANSTR(ROWS)")))
    check("IA_Roll|Gamepad_FaceButton_Bottom" in plan and not any(e.startswith("IA_Jump|") for e in plan),
          "the plan: roll on A, jump on nothing")
    check(L.eval('GP.unassign("roll")') is True and L.eval('GP.unassign("roll")') is False, "unassign: once, then nothing to take")
    check(dict(L.eval('GP.parse_binds("roll none\\njump Gamepad_DPad_Down\\nnope none")').items()) ==
          {"roll": False, "jump": "Gamepad_DPad_Down"}, "parse_binds: none for a known action, unknown ids skipped")

    # saved and loaded: none survives a restart, an old file (no new ids) leaves the new ones on none
    d = tempfile.mkdtemp(prefix="gp-full-")
    pre = "LINKDIR = [[%s]]" % d
    L = booted(pre)
    L.execute("MAPKEYS, UNMAPS = {}, {}")
    check(L.eval('GP.clear("jump")') is True and L.eval('GP.clear("jump")') is False, "CLEAR jump, then nothing to clear")
    with open(os.path.join(d, "mirror_pad_binds.txt"), encoding="utf-8") as f:
        saved = f.read()
    check("jump none" in saved and "roll none" in saved, "saved as none")
    check("IA_Jump|Gamepad_FaceButton_Bottom" in split(L.eval("JOIN(UNMAPS)")), "cleared live: A no longer jumps")
    L.execute('GP.set("map", "Gamepad_FaceButton_Bottom")')
    pads = {a.id: a.pad for a in make(pre).eval("GP.ACTIONS").values()}
    check(pads["jump"] is None and pads["map"] == "Gamepad_FaceButton_Bottom", "a new start keeps jump on none and the map on A")
    # map is a menu action: it stays in the context with a menu up, so it can close the map
    L.execute("PC.bShowMouseCursor = true; RUN(0.5)")
    rows = {(m.Action.__name, m.Key.KeyName.s) for m in L.eval("IMC.Mappings").values()}
    check(("IA_Map", "Gamepad_FaceButton_Bottom") in rows, "menu up: the map's button stays live")
    # a menu action on a menu direction is out with a menu up: one press moved the focus and shut the handbook
    L.execute('PC.bShowMouseCursor = false; RUN(0.5); GP.set("journal", "Gamepad_DPad_Down")')
    L.execute("RUN(0.5)")
    rows = {(m.Action.__name, m.Key.KeyName.s) for m in L.eval("IMC.Mappings").values()}
    check(("IA_Journal", "Gamepad_DPad_Down") in rows, "no menu: the handbook on D-pad down is live")
    L.execute("PC.bShowMouseCursor = true; RUN(0.5)")
    rows = {(m.Action.__name, m.Key.KeyName.s) for m in L.eval("IMC.Mappings").values()}
    check(("IA_Journal", "Gamepad_DPad_Down") not in rows and ("IA_Map", "Gamepad_FaceButton_Bottom") in rows,
          "menu up: the handbook's D-pad down is out (the menu's), the map's A stays")
    with open(os.path.join(d, "mirror_pad_binds.txt"), "w", encoding="utf-8") as f:
        f.write("jump Gamepad_DPad_Down\n")
    pads = {a.id: a.pad for a in make(pre).eval("GP.ACTIONS").values()}
    check(pads["jump"] == "Gamepad_DPad_Down" and pads["roll"] is None and pads["crouch"] == "Gamepad_FaceButton_Right",
          "an old file: its binds, defaults for the rest, the new actions on none (not handed a free button)")
    check(warnings(L) == [], "no warnings: %s" % warnings(L))


PS_NAMES = {
    "Gamepad_FaceButton_Bottom": "CROSS", "Gamepad_FaceButton_Right": "CIRCLE", "Gamepad_FaceButton_Left": "SQUARE",
    "Gamepad_FaceButton_Top": "TRIANGLE", "Gamepad_LeftShoulder": "L1", "Gamepad_RightShoulder": "R1",
    "Gamepad_LeftTrigger": "L2", "Gamepad_RightTrigger": "R2", "Gamepad_LeftThumbstick": "L3",
    "Gamepad_RightThumbstick": "R3", "Gamepad_DPad_Up": "D-PAD UP", "Gamepad_DPad_Down": "D-PAD DOWN",
    "Gamepad_DPad_Left": "D-PAD LEFT", "Gamepad_DPad_Right": "D-PAD RIGHT", "Gamepad_Special_Left": "CREATE",
    "Gamepad_Special_Right": "OPTIONS",
}


def playstation():
    print("playstation")
    import tempfile
    L = make(init=False)
    pads = [(p[1], p[2], p[3]) for p in L.eval("GP.PADS").values()]
    check(len(pads) == 16 and {p[0] for p in pads} == set(PS_NAMES), "16 pad buttons, the same keys as before")
    check(all(PS_NAMES[k] == ps for k, _, ps in pads), "each has its PlayStation name (CROSS, L1, CREATE, OPTIONS...)")
    check(len({ps for _, _, ps in pads}) == 16 and len({x for _, x, _ in pads}) == 16, "no name twice on either pad")
    check(L.eval('GP.pad_name("Gamepad_FaceButton_Bottom", "playstation")') == "CROSS" and
          L.eval('GP.pad_name("Gamepad_FaceButton_Bottom", "xbox")') == "A" and
          L.eval('GP.pad_name("Gamepad_FaceButton_Bottom")') == "A", "pad_name: CROSS / A, xbox when no style given")
    check(L.eval('GP.pad_name(nil, "playstation")') is None and L.eval('GP.pad_name("Gamepad_LeftStick_Up", "playstation")') is None,
          "pad_name: nil for no key or a stick direction")
    plan_x = L.eval("PLANSTR(ROWS)")
    L.execute('PADSTYLE = "playstation"')
    m = {r.id: r.button for r in L.eval("GP.binds_model()").values()}
    check(m["jump"] == "CROSS" and m["crouch"] == "CIRCLE" and m["interact"] == "SQUARE" and m["lights"] == "TRIANGLE",
          "PLAYSTATION: the face buttons are CROSS / CIRCLE / SQUARE / TRIANGLE")
    check(m["hotbar_back"] == "L1" and m["hotbar_next"] == "R1" and m["aim"] == "L2" and m["shoot"] == "R2",
          "PLAYSTATION: shoulders L1 / R1, triggers L2 / R2")
    check(m["inventory"] == "CREATE" and m["pause"] == "OPTIONS" and m["roll"] == "NONE", "CREATE / OPTIONS, NONE for unbound")
    check(L.eval("PLANSTR(ROWS)") == plan_x, "the pad type changes names only: the same keys go into the context")
    L.execute('PADSTYLE = "boom"')
    check({r.id: r.button for r in L.eval("GP.binds_model()").values()}["jump"] == "A", "pad type unreadable: Xbox names, no error")
    # SET on a PS pad: the same key comes back (Cross is Gamepad_FaceButton_Bottom), the row names it CROSS
    C = booted('PADSTYLE = "playstation"')
    C.execute('PC.bShowMouseCursor = true; RUN(0.25); GP.capture("shove"); RUN(0.25); DOWN.Gamepad_FaceButton_Top = true; RUN(0.25)')
    m = {r.id: r.button for r in C.eval("GP.binds_model()").values()}
    check(m["shove"] == "TRIANGLE" and m["lights"] == "R3", "PS pad SET: Triangle binds shove, lights swap to R3")
    check(warnings(C) == [], "no warnings: %s" % warnings(C))

    # each pad button is read once a frame however many parts ask (menu focus + inventory both read the D-pad)
    K = booted()
    K.execute("""KEYREADS = {}
                 local f = PC.IsInputKeyDown
                 PC.IsInputKeyDown = function(self, k) KEYREADS[k.KeyName.s] = (KEYREADS[k.KeyName.s] or 0) + 1; return f(self, k) end""")
    K.execute("KEYREADS = {}; RUN(1.0, 0.25)")
    reads = dict(K.eval("KEYREADS").items())
    check(not reads.get("Gamepad_DPad_Up") and not reads.get("Gamepad_DPad_Down"),
          "in the world with nothing looked at: D-pad up/down are not read (%s)" % reads)
    check(reads.get("Gamepad_RightShoulder") == 4, "the hotbar buttons are read once a tick (4 ticks: %s)" % reads.get("Gamepad_RightShoulder"))
    K.execute("PC.bShowMouseCursor = true; RUN(0.5); KEYREADS = {}; RUN(1.0, 0.25)")
    reads = dict(K.eval("KEYREADS").items())
    check(reads and max(reads.values()) == 4, "menu up: no button read twice in a tick (%s)" % reads)
    K.execute("PC.bShowMouseCursor = false; RUN(0.5); PLAYER.BP_JigHelperComp.CurrentTracActor = BED; RUN(0.25)")
    K.execute("DOWN.Gamepad_DPad_Up = true; RUN(0.25); DOWN.Gamepad_DPad_Up = false; RUN(0.25)")
    check(K.eval("JOIN(OPTS)") == "true", "looking at a bed: D-pad up still steps the options once")
    # a D-pad held while the target comes into view is not a fresh press
    K.execute("PLAYER.BP_JigHelperComp.CurrentTracActor = NOTHING; RUN(1.0); DOWN.Gamepad_DPad_Down = true; RUN(0.25); "
              "PLAYER.BP_JigHelperComp.CurrentTracActor = BED; RUN(0.5)")
    check(K.eval("JOIN(OPTS)") == "true", "D-pad down held as a target appears: no option step")
    K.execute("DOWN.Gamepad_DPad_Down = false; RUN(0.25); DOWN.Gamepad_DPad_Down = true; RUN(0.25); DOWN.Gamepad_DPad_Down = false")
    check(K.eval("JOIN(OPTS)") == "true;false", "released and pressed again: it steps")
    check(warnings(K) == [], "no warnings: %s" % warnings(K))

    # a bindings file that can't be written: said in the log, the binding still live, no error raised
    W = booted("LINKDIR = [[%s]]" % os.path.join(tempfile.mkdtemp(prefix="gp-ro-"), "missing", "dir"))
    W.execute("MAPKEYS = {}")
    check(W.eval('GP.set("reload", "Gamepad_FaceButton_Right")') is True, "SET with no writable folder still binds")
    check("IA_Reload|Gamepad_FaceButton_Right" in split(W.eval("JOIN(MAPKEYS)")), "and it is live at once")
    check(any("bindings not saved" in w for w in warnings(W)) and
          not any("safe() caught" in w for w in warnings(W)), "the failed save is logged as a warning, nothing thrown")
    d = tempfile.mkdtemp(prefix="gp-save-")
    S = booted("LINKDIR = [[%s]]" % d)
    S.execute('GP.set("reload", "Gamepad_FaceButton_Right"); GP.step_sens("look_x", 1)')
    with open(os.path.join(d, "mirror_pad_binds.txt"), encoding="utf-8") as f:
        lines = f.read().splitlines()
    n_act = S.eval("#GP.ACTIONS + #GP.CONTROLS")
    check(len(lines) == n_act + 1 and lines[-1] == "look_x 230" and all(len(l.split()) == 2 for l in lines),
          "saved whole: one line per action and control plus the changed speed (%d lines)" % len(lines))
    # the file opens but the write fails (a full disk): a warning, not a quiet success
    F = booted("LINKDIR = [[%s]]" % d)
    F.execute("""io.open = function() return { write = function() return nil, 'disk full' end,
                                              close = function() return true end } end""")
    F.execute('GP.set("reload", "Gamepad_DPad_Left")')
    check(any("bindings not saved" in w for w in warnings(F)), "a failed write is logged as not saved")

    # IsInputKeyDown throwing (a controller going away): every button counts as up, nothing fires
    T = booted()
    T.execute("PC.IsInputKeyDown = function() error('gone') end; DOWN.Gamepad_RightShoulder = true; RUN(0.5)")
    check(T.eval("#CYCLES") == 0 and not any("safe() caught" in w for w in warnings(T)),
          "a key read that throws: no hotbar step, nothing raised")


CONTROL_DEFAULTS = {
    "menu_up": "Gamepad_DPad_Up", "menu_down": "Gamepad_DPad_Down", "menu_left": "Gamepad_DPad_Left",
    "menu_right": "Gamepad_DPad_Right", "inv_grab": "Gamepad_FaceButton_Bottom", "inv_back": "Gamepad_FaceButton_Right",
    "inv_take": "Gamepad_FaceButton_Left", "inv_tab_left": "Gamepad_LeftShoulder", "inv_tab_right": "Gamepad_RightShoulder",
    "option_up": "Gamepad_DPad_Up", "option_down": "Gamepad_DPad_Down",
}
INV_NAMES = {"menu_up": "up", "menu_down": "down", "menu_left": "left", "menu_right": "right", "inv_grab": "a",
             "inv_back": "b", "inv_take": "x", "inv_tab_left": "lb", "inv_tab_right": "rb"}


def controls():
    print("menu / inventory / option controls, switches")
    import tempfile

    def ctl(L):
        return {a.id: a.pad for a in L.eval("GP.CONTROLS").values()}

    def acts(L):
        return {a.id: a.pad for a in L.eval("GP.ACTIONS").values()}

    def btns(L):
        return dict(L.eval('require("mirror.padinv").BUTTONS').items())

    L = make()
    check(ctl(L) == CONTROL_DEFAULTS, "11 controls on the buttons they had when hard-coded")
    check(btns(L) == {INV_NAMES[k]: v for k, v in CONTROL_DEFAULTS.items() if k in INV_NAMES},
          "padinv's buttons are the bindings")
    check(L.eval("PLANSTR(ROWS)") == ";".join(sorted(EXP_STR)), "the controls add no context rows (same plan)")
    rows = [r.id for r in L.eval("GP.binds_model()").values()]
    check(len(rows) == L.eval("#GP.ACTIONS + #GP.CONTROLS") and len(set(rows)) == len(rows),
          "binds_model: every action and control once (%d rows)" % len(rows))
    check(rows[14] == "menu_up" and rows[24] == "option_down" and rows[25] == "roll" and rows[13] == "pause",
          "the order: the 14 bound actions, the controls, then the unbound actions")
    check(L.eval("math.ceil(#GP.binds_model() / 11)") == 6, "6 pages of 11 on the BUTTONS tab")
    labels = [r.label for r in L.eval("GP.binds_model()").values()]
    check(max(len(x) for x in labels) <= 21, "no label longer than 21 characters (%d)" % max(len(x) for x in labels))

    # swaps stay inside a kind: a control onto a game action's button leaves the action alone
    check(L.eval('GP.assign("inv_grab", "Gamepad_FaceButton_Top")') is True, "INV: GRAB onto Y")
    c, a = ctl(L), acts(L)
    check(c["inv_grab"] == "Gamepad_FaceButton_Top" and a["lights"] == "Gamepad_FaceButton_Top" and
          a["jump"] == "Gamepad_FaceButton_Bottom", "Y grabs in the inventory and still does lights in the world; A still jumps")
    check(btns(L)["a"] == "Gamepad_FaceButton_Top", "padinv grabs on Y")
    check(L.eval('GP.assign("inv_back", "Gamepad_FaceButton_Top")') is True and
          ctl(L)["inv_grab"] == "Gamepad_FaceButton_Right" and btns(L)["a"] == "Gamepad_FaceButton_Right" and
          btns(L)["b"] == "Gamepad_FaceButton_Top", "BACK onto Y: GRAB swaps to BACK's old B")
    check(L.eval('GP.assign("option_up", "Gamepad_DPad_Left")') is True and ctl(L)["menu_left"] == "Gamepad_DPad_Left" and
          ctl(L)["option_down"] == "Gamepad_DPad_Down", "an option step onto D-pad left: the menu's D-pad left untouched")
    check(L.eval('GP.assign("option_up", "Gamepad_DPad_Down")') is True and ctl(L)["option_down"] == "Gamepad_DPad_Left",
          "onto the other option step's button: they swap")
    check(L.eval('GP.unassign("inv_take")') is True and btns(L).get("x") is None, "QUICK TAKE cleared: padinv has no X")
    check(L.eval('GP.assign("jump", "Gamepad_FaceButton_Right")') is True and ctl(L)["inv_grab"] == "Gamepad_FaceButton_Right",
          "and a game action swapping leaves the controls alone")
    L.execute("GP.reset_binds()")
    check(ctl(L) == CONTROL_DEFAULTS and btns(L)["x"] == "Gamepad_FaceButton_Left", "reset_binds: the controls back too")

    # live: the inventory takes a moved button (padinv's own stand-ins)
    P = make()
    P.execute(INV)
    P.execute('GP.set("inv_take", "Gamepad_FaceButton_Top"); PADS.y = "Gamepad_FaceButton_Top"')
    P.execute("P('right'); P('right', 'right', 'right'); CALLS = {}; P('x')")
    check("quick" not in P.eval("JOIN(CALLS)"), "QUICK TAKE moved to Y: X takes nothing")
    P.execute("CALLS = {}; P('y')")
    check("LootComp quick BoxItem" in P.eval("JOIN(CALLS)"), "Y quick-takes the loot box")
    P.execute('GP.clear("menu_right"); PADS.y = nil')
    P.execute("CALLS = {}; local c = CUR(); P('right'); MOVED = CUR() ~= c")
    check(P.eval("MOVED") is False, "MENU RIGHT cleared: D-pad right moves nothing")

    # live: the menu focus and the option step follow theirs
    K = booted()
    K.execute("""MENUS = { WIDGET('Journal', { kids = { WIDGET('First', { button = true }), WIDGET('Second', { button = true }) } }) }""")
    K.execute('GP.set("menu_up", "Gamepad_FaceButton_Top"); PC.bShowMouseCursor = true; RUN(0.5)')
    K.execute("DOWN.Gamepad_DPad_Up = true; RUN(0.25); DOWN.Gamepad_DPad_Up = false; RUN(0.25)")
    check(K.eval("#FOCUSED") == 0, "MENU UP on Y: D-pad up (on nothing in the menu now) focuses nothing")
    K.execute("DOWN.Gamepad_FaceButton_Top = true; RUN(0.25); DOWN.Gamepad_FaceButton_Top = false; RUN(0.25)")
    check(K.eval("JOIN(FOCUSED)") == "First", "Y focuses the menu's first button")
    K.execute("MENUS[1].kids[2].HasKeyboardFocus = function() return true end")
    K.execute("DOWN.Gamepad_FaceButton_Top = true; RUN(0.25); DOWN.Gamepad_FaceButton_Top = false; RUN(0.25)")
    check(K.eval("#FOCUSED") == 1, "a button already focused keeps it (no jump back to the first)")
    K.execute("MENUS = { WIDGET('Small', { kids = { WIDGET('Only', { button = true }) } }) }; FOCUSED = {}")
    K.execute("DOWN.Gamepad_FaceButton_Top = true; RUN(0.25); DOWN.Gamepad_FaceButton_Top = false; RUN(0.25)")
    check(K.eval("JOIN(FOCUSED)") == "Only", "a menu with one button: it gets focus")
    O = booted()
    O.execute('GP.set("option_up", "Gamepad_FaceButton_Top"); RUN(0.25); PLAYER.BP_JigHelperComp.CurrentTracActor = BED; RUN(0.5)')
    rows = {(m.Action.__name, m.Key.KeyName.s) for m in O.eval("IMC.Mappings").values()}
    check(("IA_Throwable", "Gamepad_DPad_Up") in rows and not any(k == "Gamepad_FaceButton_Top" for _, k in rows),
          "looking at a bed with PROMPT OPTION UP on Y: Y's rows out, D-pad up throws again")
    O.execute("OPTS = {}; DOWN.Gamepad_FaceButton_Top = true; RUN(0.25); DOWN.Gamepad_FaceButton_Top = false; RUN(0.25)")
    O.execute("DOWN.Gamepad_DPad_Up = true; RUN(0.25); DOWN.Gamepad_DPad_Up = false; RUN(0.25)")
    check(O.eval("JOIN(OPTS)") == "true", "Y steps the options up once, D-pad up no longer does")
    # SET captures a control like an action
    O.execute('PLAYER.BP_JigHelperComp.CurrentTracActor = NOTHING; PC.bShowMouseCursor = true; RUN(0.5); GP.capture("inv_back"); RUN(0.25)')
    O.execute("DOWN.Gamepad_LeftThumbstick = true; RUN(0.25); DOWN.Gamepad_LeftThumbstick = false; RUN(0.25)")
    check(ctl(O)["inv_back"] == "Gamepad_LeftThumbstick" and acts(O)["sprint"] == "Gamepad_LeftThumbstick",
          "SET on INV: BACK takes L3; sprint keeps L3")
    m = {r.id: r.button for r in O.eval("GP.binds_model()").values()}
    check(m["inv_back"] == "L3" and m["option_up"] == "Y" and m["menu_up"] == "D-PAD UP", "binds_model names them")
    check(warnings(K) == [] and warnings(O) == [] and warnings(P) == [], "no warnings")

    # saved and loaded; an old file leaves the defaults; a hand-edited one never doubles a kind
    d = tempfile.mkdtemp(prefix="gp-ctl-")
    pre = "LINKDIR = [[%s]]" % d
    path = os.path.join(d, "mirror_pad_binds.txt")
    S = booted(pre)
    S.execute('GP.set("inv_back", "Gamepad_FaceButton_Top"); GP.clear("option_down")')
    saved = open(path, encoding="utf-8").read()
    check("inv_back Gamepad_FaceButton_Top" in saved and "option_down none" in saved and "menu_up Gamepad_DPad_Up" in saved,
          "saved: each control's button, none when cleared")
    S2 = make(pre)
    check(ctl(S2)["inv_back"] == "Gamepad_FaceButton_Top" and ctl(S2)["option_down"] is None and
          btns(S2)["b"] == "Gamepad_FaceButton_Top", "a new start loads them, into padinv too")
    with open(path, "w", encoding="utf-8") as f:
        f.write("jump Gamepad_DPad_Down\nreload Gamepad_FaceButton_Right\n")
    S3 = make(pre)
    check(ctl(S3) == CONTROL_DEFAULTS, "a file from before the controls: their defaults")
    with open(path, "w", encoding="utf-8") as f:
        f.write("inv_grab Gamepad_DPad_Up\nmenu_up Gamepad_DPad_Up\noption_up Gamepad_DPad_Up\njump Gamepad_DPad_Up\ninv_take none\n")
    S4 = make(pre)
    c, a = ctl(S4), acts(S4)
    menu = [v for k, v in c.items() if k in INV_NAMES and v]
    check(c["menu_up"] == "Gamepad_DPad_Up" and c["inv_grab"] == "Gamepad_FaceButton_Bottom" and len(set(menu)) == len(menu),
          "one button twice among the menu controls: the first in the list keeps it, the other its default, no doubles")
    check(c["option_up"] == "Gamepad_DPad_Up" and a["jump"] == "Gamepad_DPad_Up" and c["inv_take"] is None,
          "the same button across kinds is kept; none stays none")
    with open(path, "w", encoding="utf-8") as f:
        f.write("menu_up Gamepad_DPad_Down\n")
    check(ctl(make(pre))["menu_down"] == "Gamepad_FaceButton_Top",
          "a control whose default is taken: the first free pad key of its kind (Y; A/B/X are the inventory's)")
    check(warnings(S) == [], "no warnings: %s" % warnings(S))

    # aim's slow look follows AIM's button
    A = booted()
    full = A.eval("GP.LOOK.yaw") * 0.1 / A.eval("GP.LOOK.scale")
    A.execute('GP.set("aim", "Gamepad_LeftShoulder"); RUN(0.25); LOOKTICK(1, 0, 1)')
    check(abs(A.eval("SUM(YAW)") - full) < 1e-9, "AIM on LB: LT pulled is full speed")
    A.execute("DOWN.Gamepad_LeftShoulder = true; LOOKTICK(1, 0, 0); DOWN.Gamepad_LeftShoulder = false")
    check(abs(A.eval("SUM(YAW)") - full * 0.5) < 1e-9, "LB held: half speed")
    A.execute('GP.set("aim", "Gamepad_RightTrigger"); RUN(0.25); AXES.Gamepad_RightTriggerAxis = 1; LOOKTICK(1, 0, 0)')
    check(abs(A.eval("SUM(YAW)") - full * 0.5) < 1e-9, "AIM on RT: the right trigger's axis slows it")
    A.execute("AXES.Gamepad_RightTriggerAxis = 0.2; LOOKTICK(1, 0, 0)")
    check(abs(A.eval("SUM(YAW)") - full) < 1e-9, "RT barely touched: full speed")
    A.execute('AXES.Gamepad_RightTriggerAxis = 0; GP.clear("aim"); RUN(0.25); LOOKTICK(1, 0, 1)')
    check(abs(A.eval("SUM(YAW)") - full) < 1e-9, "AIM on no button: never slowed")

    # switches: INVERT LOOK, SWAP STICKS
    W = booted(pre)
    o = {r.id: r for r in W.eval("GP.opts_model()").values()}
    check(set(o) == {"invert_look", "swap_sticks"} and o["invert_look"].text == "OFF" and o["swap_sticks"].on is False,
          "two switches, both OFF")
    pitch = W.eval("GP.LOOK.pitch") * 0.1 / W.eval("GP.LOOK.scale")
    check(W.eval('GP.toggle_opt("invert_look")') is True, "INVERT LOOK on")
    W.execute("LOOKTICK(0, 1, 0)")
    check(abs(W.eval("SUM(PITCH)") + pitch) < 1e-9, "inverted: stick up looks down")
    W.execute("PLAYER.InvertValue = -1; LOOKTICK(0, 1, 0); PLAYER.InvertValue = 1")
    check(abs(W.eval("SUM(PITCH)") - pitch) < 1e-9, "inverted on top of the game's own invert: up again")
    W.execute("LOOKTICK(1, 0, 0)")
    check(W.eval("SUM(YAW)") > 0, "left / right not inverted")
    W.execute("MAPKEYS, UNMAPS = {}, {}")
    check(W.eval('GP.toggle_opt("swap_sticks")') is True, "SWAP STICKS on")
    mk, um = split(W.eval("JOIN(MAPKEYS)")), split(W.eval("JOIN(UNMAPS)"))
    check("IA_MoveForward|Gamepad_RightStick_Up" in mk and "IA_MoveForward|Gamepad_LeftStick_Up" in um,
          "live: walking moves to the right stick")
    check("Gamepad_RightStick_Up=W" in W.eval("MIRRORSTR()") and "Gamepad_LeftStick_Up" not in W.eval("MIRRORSTR()"),
          "MIRROR: the right stick walks, the left one doesn't")
    W.execute("AXES.Gamepad_RightX = 1; YAW = {}; RUN(0.25)")
    check(W.eval("#YAW") == 0, "swapped: the right stick no longer turns")
    W.execute("AXES.Gamepad_RightX = 0; AXES.Gamepad_LeftX = 1; YAW = {}; RUN(0.25); AXES.Gamepad_LeftX = 0")
    check(W.eval("#YAW") == 1 and W.eval("SUM(YAW)") > 0, "swapped: the left stick turns")
    W.execute("PC.bShowMouseCursor = true; RUN(0.5)")
    rows = {(m.Action.__name, m.Key.KeyName.s) for m in W.eval("IMC.Mappings").values()}
    check(("IA_MoveForward", "Gamepad_RightStick_Up") in rows, "menu up: the walk stick's rows stay, as before")
    W.execute("PC.bShowMouseCursor = false; RUN(0.5)")
    saved = open(path, encoding="utf-8").read()
    check("invert_look on" in saved and "swap_sticks on" in saved, "saved as on")
    W2 = make(pre)
    check(W2.eval("GP.OPT.invert") is True and W2.eval("GP.OPT.swap") is True and
          "Gamepad_RightStick_Up=W" in W2.eval("MIRRORSTR()"), "a new start loads both, the right stick walking")
    W.execute("GP.reset()")
    saved = open(path, encoding="utf-8").read()
    check(W.eval("GP.OPT.invert") is False and W.eval("GP.OPT.swap") is False and "Gamepad_LeftStick_Up=W" in W.eval("MIRRORSTR()")
          and "invert_look" not in saved and "swap_sticks" not in saved, "RESET: both off, the left stick walks, nothing saved")
    check(W.eval('GP.toggle_opt("bogus")') is None, "an unknown switch: nil")
    check(dict(W.eval('GP.parse_opts("look_x 230\\ninvert_look on\\nswap_sticks maybe\\nswap_sticks off extra\\n")').items())
          == {"invert_look": True}, "parse_opts: line by line (not paired with the line before), junk skipped")
    check(dict(W.eval('GP.parse_opts("invert_look off\\r\\n")').items()) == {"invert_look": False}, "off and CRLF read")
    check(warnings(W) == [], "no warnings: %s" % warnings(W))


def sensitivity():
    print("sensitivity")
    import tempfile
    d = tempfile.mkdtemp(prefix="gp-sens-")
    pre = "LINKDIR = [[%s]]" % d
    path = os.path.join(d, "mirror_pad_binds.txt")
    L = booted(pre)
    s = {r.id: r for r in L.eval("GP.sens_model()").values()}
    check(set(s) == {"look_x", "look_y", "aim_look", "dead_zone"}, "four sliders")
    check(s["look_x"].text == "100%" and s["aim_look"].text == "50%" and s["dead_zone"].text == "12%",
          "defaults: speeds at 100%, aim 50%, dead zone 12%")
    check(abs(s["look_x"].value - (220 - 40) / (600 - 40)) < 1e-9, "slider position of the default yaw")
    check(L.eval('GP.set_sens("look_x", 1.0)') is True and L.eval("GP.LOOK.yaw") == 600, "slider full right: yaw 600")
    check(L.eval('GP.set_sens("look_x", 1.0)') is False, "the same place again: no change, no save")
    check(L.eval('GP.set_sens("look_x", 7)') is False and L.eval('GP.set_sens("look_x", "x")') is False and
          L.eval('GP.set_sens("bogus", 0.5)') is False, "out of range clamps (already max), junk and unknown refused")
    L.execute('GP.set_sens("dead_zone", 0.0)')
    check(abs(L.eval("GP.LOOK.dz") - 0.02) < 1e-9, "dead zone slider full left: 0.02")
    check(L.eval('GP.step_sens("aim_look", 1)') is True and abs(L.eval("GP.LOOK.aim") - 0.55) < 1e-9, "+ on aim: 0.55")
    L.execute('GP.step_sens("aim_look", -1); GP.step_sens("aim_look", -1)')
    check(abs(L.eval("GP.LOOK.aim") - 0.45) < 1e-9, "- twice: 0.45")
    with open(path, encoding="utf-8") as f:
        saved = f.read()
    check("look_x 600" in saved and "dead_zone 2" in saved and "aim_look 45" in saved and "look_y" not in saved,
          "saved: the moved ones as whole numbers, the untouched one left out")
    # the look uses it
    L.execute("LOOKTICK(1, 0, 0)")
    check(abs(L.eval("SUM(YAW)") - 600 * 0.1 / 2.5) < 1e-9, "the right stick turns at the new speed")
    # a restart loads them; the bindings in the same file still load
    L.execute('GP.set("reload", "Gamepad_FaceButton_Right")')
    L2 = make(pre)
    check(L2.eval("GP.LOOK.yaw") == 600 and abs(L2.eval("GP.LOOK.aim") - 0.45) < 1e-9 and abs(L2.eval("GP.LOOK.dz") - 0.02) < 1e-9,
          "a new start loads the speeds")
    check({a.id: a.pad for a in L2.eval("GP.ACTIONS").values()}["reload"] == "Gamepad_FaceButton_Right", "and the bindings")
    # a hand-edited value out of range is clamped onto the slider
    with open(path, "w", encoding="utf-8") as f:
        f.write("look_x 99999\ndead_zone 0\njump Gamepad_FaceButton_Bottom\n")
    L3 = make(pre)
    check(L3.eval("GP.LOOK.yaw") == 600 and abs(L3.eval("GP.LOOK.dz") - 0.02) < 1e-9, "out-of-range saved values are clamped")
    # RESET: the default speeds back, nothing about speed left in the file
    L.execute("GP.reset()")
    check(L.eval("GP.LOOK.yaw") == 220 and L.eval("GP.LOOK.aim") == 0.5 and L.eval("GP.LOOK.dz") == 0.12, "RESET: default speeds")
    with open(path, encoding="utf-8") as f:
        saved = f.read()
    check(not any(k in saved for k in ("look_x", "look_y", "aim_look", "dead_zone")), "RESET: no speed lines saved")
    # a config's look speed is the default the slider shows as 100% and RESET returns to
    C = make(pre, cfg="{ gamepad = { look = { yaw = 100 } } }")
    check({r.id: r.text for r in C.eval("GP.sens_model()").values()}["look_x"] == "100%", "a config's yaw shows as 100%")
    C.execute('GP.set_sens("look_x", 1.0); GP.reset()')
    check(C.eval("GP.LOOK.yaw") == 100, "RESET goes back to the config's yaw")
    check(warnings(L) == [] and warnings(C) == [], "no warnings")


# ---------------------------------------------------------------------------------------------------------------
# padinv: stand-in JigSInventory widgets. Grids are JSIContainers with a row-major WSlots array of 50 px cells; items
# cover cells through HostedItem; each grid's root comp records the game calls the pad makes.
INV = r'''
PI = require("mirror.padinv")
CALLS, GRIDS, SCANS, MOUSE, MENUPOS = {}, {}, 0, nil, nil
local function rec(s) CALLS[#CALLS + 1] = s end
function LASTCALL() return CALLS[#CALLS] end
local base_find = FindAllOf
INVS = {}
function FindAllOf(cls)
    if cls == "JSIContainer_C" then SCANS = SCANS + 1; return GRIDS end
    if cls == "BP_Inventory_C" then return INVS end
    return base_find(cls)
end
-- the layout comes from the widget tree: panels with a class name, children with desired sizes, slots with a
-- padding (boxes) or a position (canvas). The viewport is 1920x1080 pixels at DPI scale DPI.
NO_GEO, VPW, VPH, DPI, SIZES, HOVER_OK = false, 1920, 1080, 1, 0, true
WLL = MKOBJ("WidgetLayoutLibrary")
function WLL.GetViewportSize(self, world) return { X = VPW, Y = VPH } end
function WLL.GetViewportScale(self, world) return DPI end
local base_static = StaticFindObject
function StaticFindObject(p)
    if p == "/Script/UMG.Default__WidgetLayoutLibrary" then return WLL end
    return base_static(p)
end
function PC.SetMouseLocation(self, x, y) MOUSE = x .. "," .. y end
function PANEL(name, cls, o)
    o = o or {}
    local w = MKOBJ(name, { kids = {}, w = o.w or 0, h = o.h or 0, collapsed = o.collapsed, Orientation = o.orient,
                           scroll = o.scroll, Slot = { Padding = o.pad and { Left = o.pad[1], Top = o.pad[2], Right = o.pad[3], Bottom = o.pad[4] } } })
    w.GetClass = function() return { GetFName = function() return FName(cls) end } end
    w.GetDesiredSize = function(self) return { X = self.w, Y = self.h } end
    w.GetVisibility = function(self) return self.collapsed and 1 or 0 end
    w.GetChildrenCount = function(self) return #self.kids end
    w.GetChildAt = function(self, i) return self.kids[i + 1] end
    w.GetChildIndex = function(self, ch) for i, k in ipairs(self.kids) do if k == ch then return i - 1 end end return -1 end
    w.GetScrollOffset = function(self) return self.scroll or 0 end
    w.IsVisible = function() return true end
    w.IsInViewport = function() return true end
    return w
end
-- put child into panel (a canvas child at x, y)
function ADD(panel, ch, x, y)
    panel.kids[#panel.kids + 1] = ch
    ch.GetParent = function() return panel end
    if x then ch.Slot = ch.Slot or {}; ch.Slot.GetPosition = function() return { X = x, Y = y } end end
    return ch
end
ROOT = PANEL("Root", "CanvasPanel")

local function border(name)
    local b = MKOBJ(name .. ".border", { BrushColor = { R = 0.1, G = 0.1, B = 0.1, A = 1 } })
    function b.SetBrushColor(self, c) self.cur = c end
    return b
end
function TINT(o) local c = o.SlotBorder.cur; return c and string.format("%.2f,%.2f,%.2f", c.R, c.G, c.B) or "-" end
function COMP(name)
    local c = MKOBJ(name)
    function c.EventOnJigItemMouseButtonDown(self, cont, slot, key)
        rec(name .. " quick " .. slot.__name .. " ctrl=" .. tostring(slot.CTRL_Down) .. " " .. key.KeyName.s .. " from " .. cont.__name)
    end
    function c.EventOnInventoryAction(self, from, to, item, recv, idx, rot)
        rec(string.format("%s move %s %s->%s idx=%d rot=%s recv=%s", name, item.__name, from.__name, to.__name, idx, tostring(rot), recv and recv.__name or "nil"))
    end
    function c.OnItemStackRequest_Event(self, a, b) rec(name .. " stack " .. a.__name .. " on " .. b.__name) end
    function c.Drop_ItemOverItem_Event_0(self, recv, dropped, recv_c, dropped_c)
        rec(name .. " over " .. dropped.__name .. " on " .. recv.__name .. " " .. dropped_c.__name .. "->" .. recv_c.__name)
    end
    function c.Context_TryEquip(self, item, root) rec(name .. " equip " .. item.__name .. " root " .. root.__name) end
    function c.Context_TryUnequip(self, item, root) rec(name .. " unequip " .. item.__name .. " root " .. root.__name) end
    return c
end
-- a grid on panel `parent` (default: ROOT's canvas at x0, y0); its cells are 50x50 and sit in it
function GRID(name, cols, rows, x0, y0, o)
    o = o or {}
    local c = MKOBJ(name, { NumberOfColumns = cols, NumberOfRows = rows, WSlots = {}, ["IsMainContainer?"] = o.main == true,
                           IsActionbar = o.bar == true, equip = o.equip == true, refuse = {} })
    c["IsEquipTo?"] = function(self) return self.equip end
    c.IsVisible = function(self) return not self.hidden end
    c.IsInViewport = function() return true end
    c.GetDesiredSize = function() return { X = cols * 50, Y = rows * 50 } end
    if o.parent then ADD(o.parent, c) else ADD(ROOT, c, x0, y0) end
    if o.pad then c.Slot = { Padding = { Left = o.pad[1], Top = o.pad[2], Right = o.pad[3], Bottom = o.pad[4] } } end
    c.JigMultiplayerComp = COMP(name .. "Comp")
    c.GetRootContainerRef = function(self, b, out) out.ContainerRef = self end
    -- like the game: the first parameter is the item's data asset (an FName id or anything else is not supported)
    c.IsSupportedByThis = function(self, da, ty, out)
        out["Supported?"] = type(da) == "table" and da.is_da == true and type(ty) == "table" and ty.TagName ~= nil
            and ty.TagName.s == "Jig.ItemType.Misc" and not self.refuse[da.id]
    end
    c.CheckRootContainer = function(self, item, out) out["Proceed?"] = not self.inside end
    c.CheckWeightLimit = function(self, w, from, out) out.Result = from == self or w <= (self.maxw or 1e9) end
    c["DifficultyCheckBackpack?"] = function(self, slot, out) out["CarryOn?"] = not (HARD and slot.backpack) end
    function c.HandleContainerOnContainer(self, from, to, item, at, idx, rot, b, out)
        rec(string.format("%s into %s %s from %s at %s idx=%d rot=%s %s", name, to.__name, item.__name, from.__name,
            at and at.__name or "nil", idx, tostring(rot), tostring(b)))
        out["Handled?"] = true
    end
    for r = 0, rows - 1 do
        for col = 0, cols - 1 do
            local cell = MKOBJ(name .. "_" .. col .. "_" .. r)
            cell.SlotBorder = border(cell.__name)
            cell.GetParent = function() return c end
            cell.GetDesiredSize = function() SIZES = SIZES + 1; return NO_GEO and { X = 0, Y = 0 } or { X = 50, Y = 50 } end
            cell.IsHovered = function() return HOVER_OK end
            table.insert(c.WSlots, cell)
        end
    end
    GRIDS[#GRIDS + 1] = c
    return c
end
function ITEM(name, g, col, row, w, h, o)
    o = o or {}
    local it = MKOBJ(name, { SlotIndex = row * g.NumberOfColumns + col, ItemDim = { X = w, Y = h }, ContainerMother = g,
                             id = o.id or name, stack = o.stack == true, opacity = 1 })
    it.SlotBorder = border(name)
    it.da = MKOBJ((o.id or name) .. "DA", { is_da = true, id = o.id or name })
    it.GetItemID = function(self, out) out.ItemId = FName(self.id) end
    it.GetJigDA = function(self, out) out.JigDataAsset = self.da end
    -- like UE4SS (live 2026-10-31): the GameplayTag out-param fills the table itself, no "Type" key
    it.GetType = function(self, out) out.TagName = FName("Jig.ItemType.Misc") end
    it["AbleToStackTo?"] = function(self, other) return self.stack and other.id == self.id end
    it.SetRenderOpacity = function(self, v) self.opacity = v end
    it.GetWeight = function(self) return self.weight or 1 end
    it["IsItemPending?"] = function(self, out) out.IsPending = self.pending == true end
    it["IsContainer?"] = function(self, out) out["IsContainer?"] = self.bag == true end
    it.GetSpecialContainerRef = function(self, out) out.SpecialContainerRef = self.special end
    for r = row, row + h - 1 do
        for c = col, col + w - 1 do g.WSlots[r * g.NumberOfColumns + c + 1].HostedItem = it end
    end
    return it
end
function CELL(g, col, row) return g.WSlots[row * g.NumberOfColumns + col + 1] end
-- an item's own grid (SlotContainer: a magazine's, a bag's): takes what `takes` says, `inside` = the item dropped is
-- its root
function SUBC(name)
    local c = MKOBJ(name, { takes = true })
    c.IsSupportedByThis = function(self, da, ty, out) out["Supported?"] = self.takes and da.is_da == true and ty.TagName ~= nil end
    c.CheckRootContainer = function(self, item, out) out["Proceed?"] = not self.inside end
    return c
end

-- the right-click menu: Use, Repair (property RepairWeaponBtn) and Drop showing, Inspect hidden
CANVAS = MKOBJ("Canvas", { inview = false })
function CANVAS.IsInViewport(self) return self.inview end
function CANVAS.RemoveFromParent(self) self.inview = false; rec("menu closed") end
MENUW = MKOBJ("MenuW")
MENUW.Slot = { SetPosition = function(self, p) MENUPOS = string.format("%g,%g", p.X, p.Y) end }
MW, MH = 200, 150
function MENUW.GetDesiredSize(self) return { X = MW, Y = MH } end
CANVAS.JigContextMenuW = MENUW
BOX = MKOBJ("Box")
function BOX.GetChildIndex(self, b) return b.idx end
local function button(prop, idx, visible)
    local b = MKOBJ(prop, { idx = idx, shown = visible, BackgroundColor = { R = 1, G = 1, B = 1, A = 1 } })
    function b.IsVisible(self) return self.shown end
    function b.GetParent(self) return BOX end
    function b.SetBackgroundColor(self, c) self.bg = c end
    MENUW[prop] = b
    return b
end
-- shuffled on purpose: the order comes from the menu box, not the table
DROPB, USEB, REPB, INSPB = button("DropBtn", 2, true), button("UseBtn", 0, true), button("RepairWeaponBtn", 1, true), button("InspectBtn", 3, false)
for _, h in ipairs({ "BndEvt__JigContextMenuW_UseBtn_K2Node_ComponentBoundEvent_10_OnButtonClickedEvent__DelegateSignature",
                     "BndEvt__JigContextMenuW_RepairBtn_K2Node_ComponentBoundEvent_22_OnButtonClickedEvent__DelegateSignature",
                     "BndEvt__JigContextMenuW_DropBtn_K2Node_ComponentBoundEvent_23_OnButtonClickedEvent__DelegateSignature" }) do
    MENUW[h] = function(self) rec("option " .. h:match("JigContextMenuW_(%a+)_")); CANVAS.inview = false end
end
CTX = MKOBJ("ContextComp")
function CTX.OnJigItemRightClick(self, item, geo, ev)
    rec("menu " .. item.__name)
    if item.no_menu then return end
    self.ContextMRef = CANVAS
    CANVAS.inview = true
end
PC.JigContextMenuComp = CTX

-- the layout: bag 4x3 at (0,0), loot 3x3 at (400,0), equip slot at (0,300), hotbar at (0,500), a hidden grid
BAG = GRID("Bag", 4, 3, 0, 0, { main = true })
LOOT = GRID("Loot", 3, 3, 400, 0)
EQUIP = GRID("Equip", 1, 1, 0, 300, { equip = true })
BAR = GRID("Bar", 5, 1, 0, 500, { bar = true })
HID = GRID("Hidden", 2, 2, 200, 200); HID.hidden = true
RIFLE = ITEM("Rifle", BAG, 1, 0, 2, 1)
CAN = ITEM("Can", BAG, 0, 2, 1, 1, { id = "can", stack = true })
CAN2 = ITEM("Can2", BAG, 3, 2, 1, 1, { id = "can", stack = true })
BOXI = ITEM("BoxItem", LOOT, 0, 0, 1, 1)

PADS = { up = "Gamepad_DPad_Up", down = "Gamepad_DPad_Down", left = "Gamepad_DPad_Left", right = "Gamepad_DPad_Right",
         a = "Gamepad_FaceButton_Bottom", b = "Gamepad_FaceButton_Right", x = "Gamepad_FaceButton_Left",
         lb = "Gamepad_LeftShoulder", rb = "Gamepad_RightShoulder" }
local function is_down(pc, pad) return DOWN[pad] == true end
function T(dt) return PI.tick(PC, dt or 0.05, is_down) end
function P(...)   -- press and release each button in turn; returns the last tick's result
    local r
    for _, n in ipairs({ ... }) do
        DOWN[PADS[n]] = true; r = T(); DOWN[PADS[n]] = false; T()
    end
    return r
end
function CUR() local s = PI.status(); return s:match("cur=(%S+)") end
'''


def padinv():
    print("padinv (controller in the inventory)")
    real = {  # the click handlers in JigContextMenuW (decompiled 2026-10-31)
        "ConsumeBtn_15", "ConsumeCannedBtn_16", "DestroyBtn_24", "DrinkBtn_17", "DropBtn_23", "EquipBtn_12", "FillBtn_18",
        "InspectBtn_8", "OpenBtn_9", "OpenLootBoxBtn_3", "PlaceBtn_11", "PlayMusicBtn_2", "ReadBtn_19", "RepairArmorBtn_1",
        "RepairAttachmentBtn_6", "RepairBtn_22", "RipClothingBtn_20", "ScanLaptopBtn_21", "ShowAttachmentsBtn_0",
        "ShowTacticalAttachmentsBtn_4", "SmokeBtn_5", "UnequipBtn_13", "UnloadBtn_14", "UseBtn_10"}
    real = {"BndEvt__JigContextMenuW_%s_K2Node_ComponentBoundEvent_%s_OnButtonClickedEvent__DelegateSignature" % tuple(r.rsplit("_", 1))
            for r in real}

    def fresh():
        L = make()
        L.execute(INV)
        return L

    L = fresh()
    names = L.eval("(function() local t = {}; for _, o in ipairs(PI.OPTIONS) do t[#t+1] = o[3] or o[1] end; return table.concat(t, ';') end)()")
    L.execute("""HANDLERS = {}; local menu = {}; for _, o in ipairs(PI.OPTIONS) do
        HANDLERS[#HANDLERS+1] = 'BndEvt__JigContextMenuW_' .. (o[3] or o[1]) .. '_K2Node_ComponentBoundEvent_' .. o[2] .. '_OnButtonClickedEvent__DelegateSignature' end""")
    hs = set(L.eval("HANDLERS").values())
    check(hs == real, "the 24 menu options name the game's real click handlers (%d of 24 match)" % len(hs & real))
    check(len(names.split(";")) == 24, "every option of the menu is covered")

    # idle: someone on mouse and keyboard pays nothing
    for _ in range(10):
        r = L.eval("T()")
    check(r is False and L.eval("SCANS") == 0, "no pad press: no scan, the menu focus code keeps the pad (returns false)")
    # first press: the cursor lands on the bag's first cell
    check(L.eval("P('right')") is True, "first D-pad press in the inventory: padinv has the pad")
    check(L.eval("CUR()") == "0,0" and L.eval("TINT(CELL(BAG, 0, 0))") == "1.00,0.75,0.10",
          "the first press puts the cursor on the bag's top-left cell, tinted")
    check(L.eval("MOUSE") == "25,25", "the mouse goes to the cell's center (canvas slot position + half a cell)")
    check(L.eval("SCANS") >= 1 and "grids=4 " in L.eval("PI.status()"),
          "grids scanned on the press: bag, loot, equip, hotbar (the hidden one left out)")
    # onto the rifle (2x1): its menu opens at the cell
    L.execute("P('right')")
    check(L.eval("CUR()") == "1,0" and L.eval("TINT(RIFLE)") == "1.00,0.75,0.10" and L.eval("TINT(CELL(BAG, 0, 0))") == "0.10,0.10,0.10",
          "D-pad right: onto the rifle, the rifle tinted, the old cell's colour back")
    check("menu Rifle" in L.eval("JOIN(CALLS)") and L.eval("MENUPOS") == "95,5",
          "landing on an item opens its right-click menu, placed at the cell (viewport pos + 20,-20)")
    # out of the rifle's footprint
    L.execute("P('right')")
    calls = split(L.eval("JOIN(CALLS)"))
    check(L.eval("CUR()") == "3,0", "D-pad right again skips the rest of the 2-wide rifle (to column 3)")
    check("menu closed" in calls, "moving off closes the item's menu")
    # the bag's edge: the nearest grid that way (loot), not the hotbar or the hidden grid
    L.execute("P('right')")
    check(L.eval("CUR()") == "0,0" and L.eval("TINT(BOXI)") == "1.00,0.75,0.10" and L.eval("LASTCALL()") == "menu BoxItem",
          "at the bag's right edge D-pad right goes to the loot grid beside it")
    # the menu: down/up through the shown options in the menu's order, A uses one
    L.execute("P('down')")
    check(L.eval("USEB.bg ~= nil and REPB.bg == nil") is True, "D-pad down in the menu: the first option (Use, by menu order) lit")
    L.execute("P('down', 'down')")
    check(L.eval("DROPB.bg ~= nil") is True and L.eval("CUR()") == "0,0", "down twice more: Drop lit, the cursor stays")
    L.execute("P('up')")
    check(L.eval("REPB.bg ~= nil and REPB.bg.R == 1 and DROPB.bg.R == 1 and DROPB.bg.G == 1") is True,
          "up: Repair lit, Drop's colour back")
    L.execute("P('a')")
    check(L.eval("LASTCALL()") == "option RepairBtn", "A uses the lit option: Repair's real handler (property RepairWeaponBtn)")
    check(L.eval("CUR()") == "0,0" and L.eval("PI.status()").endswith("menu=-"), "the menu is gone, the cursor stays")
    # B closes, left/right move on, up at the top option leaves the menu upward
    L.execute("P('left', 'right')")
    check(L.eval("LASTCALL()") == "menu BoxItem", "back on the box: its menu again")
    L.execute("P('b')")
    check(L.eval("LASTCALL()") == "menu closed" and L.eval("CUR()") == "0,0", "B closes the menu, the cursor stays")
    L.execute("P('right')")
    check(L.eval("CUR()") == "1,0", "D-pad right with the menu open (or closed) goes to the next slot")
    L.execute("P('left', 'down', 'up', 'up')")
    check(L.eval("CUR()") == "0,0" and L.eval("USEB.bg.R") == 1 and L.eval("USEB.bg.G") == 1,
          "down into the menu, up to its first option, up again leaves it (Use's colour back)")
    # down past the last option: the cursor goes on down
    L.execute("P('down', 'down', 'down', 'down')")
    check(L.eval("CUR()") == "0,1", "down past the last option moves the cursor down a cell")
    # wrap: the right-most grid's edge goes on to the next row
    L.execute("P('right', 'right', 'right')")
    check(L.eval("CUR()") == "0,2", "D-pad right at the last grid's edge wraps to the next row's first cell")

    # X: quick take = the game's Ctrl+click on the item's own inventory component
    L = fresh()
    L.execute("P('right'); P('right', 'right', 'right'); CALLS = {}; P('x')")
    check(L.eval("JOIN(CALLS)") == "menu closed;LootComp quick BoxItem ctrl=true LeftMouseButton from Loot",
          "X on the loot box: EventOnJigItemMouseButtonDown on the loot's comp with CTRL_Down set, left button")
    check(L.eval("BOXI.CTRL_Down") is False, "CTRL_Down is cleared again afterwards")
    L.execute("CALLS = {}; P('left', 'left', 'x')")
    check(L.eval("JOIN(CALLS)").endswith("BagComp quick Rifle ctrl=true LeftMouseButton from Bag"),
          "X on the rifle in the bag: the bag's comp (the game moves it to the open loot)")
    L.execute("CALLS = {}; P('down', 'x')")
    check("quick" not in L.eval("JOIN(CALLS)"), "X on an empty cell does nothing")

    # A: grab, move, turn, put down
    L = fresh()
    L.execute("P('right'); P('right'); CALLS = {}; P('a')")
    check(L.eval("RIFLE.opacity") == 0.5 and L.eval("PI.status()").find("held=true") > 0, "A on the rifle: held, dimmed")
    check(L.eval("JOIN(CALLS)") == "menu closed", "grabbing closes the menu")
    L.execute("CALLS = {}; P('down')")
    check(L.eval("CUR()") == "1,1" and L.eval("TINT(CELL(BAG,1,1))") == "0.20,0.85,0.20" and
          L.eval("TINT(CELL(BAG,2,1))") == "0.20,0.85,0.20", "D-pad down: the rifle's two cells at the new spot show green")
    check(L.eval("JOIN(CALLS)") == "", "no menu opens while holding")
    L.execute("P('rb')")
    check(L.eval("TINT(CELL(BAG,1,2))") == "0.20,0.85,0.20" and L.eval("TINT(CELL(BAG,2,1))") == "0.10,0.10,0.10",
          "RB turns it: one wide, two tall")
    L.execute("P('a')")
    check(L.eval("LASTCALL()") == "BagComp move Rifle Bag->Bag idx=5 rot=true recv=nil",
          "A puts it down: EventOnInventoryAction(from, to, item, nil, index 5, turned) on the bag's comp")
    check(L.eval("RIFLE.opacity") == 1 and L.eval("PI.status()").find("held=false") > 0, "let go: opacity back")
    # doesn't fit: off the grid's edge; taken: another item
    L.execute("P('up', 'a'); CALLS = {}; P('right', 'right', 'a')")
    check(L.eval("CUR()") == "3,0" and L.eval("JOIN(CALLS)") == "" and L.eval("TINT(CELL(BAG,3,0))") == "0.90,0.15,0.10",
          "a spot it doesn't fit: red, A does nothing, still held")
    check(any("doesn't fit" in l for l in L.eval("LOG").values()), "and the log says why")
    L.execute("P('b')")
    check(L.eval("RIFLE.opacity") == 1 and L.eval("PI.status()").find("held=false") > 0 and L.eval("JOIN(CALLS)") == "",
          "B puts it back: no call")
    L.execute("CALLS = {}; P('left', 'left', 'a', 'a')")
    check(L.eval("JOIN(CALLS)").count("move") == 0 and L.eval("PI.status()").find("held=false") > 0,
          "A then A on the same spot: put back, no call")
    # stack: a can onto the other can
    L = fresh()
    L.execute("P('right'); P('left'); P('down', 'down', 'a', 'right', 'right', 'right'); CALLS = {}; P('a')")
    check(L.eval("JOIN(CALLS)") == "BagComp stack Can on Can2", "a can onto a can that stacks: OnItemStackRequest_Event")
    L.execute("P('left', 'left', 'left', 'up', 'up', 'right', 'a'); CALLS = {}; P('down', 'down', 'left', 'a')")
    check(L.eval("CUR()") == "0,2", "(the rifle's corner on the can)")
    # an item onto another it doesn't stack with (ammo onto a magazine; user 2026-10-31 "u cant put ammo into a mag"):
    # the mouse drop's Drop_ItemOverItem, handled by the receiving container's comp
    check(L.eval("JOIN(CALLS)") == "BagComp over Rifle on Can Bag->Bag",
          "the rifle onto a can: Drop_ItemOverItem_Event_0(can, rifle, bag, bag) on the bag's comp (%s)" % L.eval("JOIN(CALLS)"))
    check(L.eval("PI.status()").find("held=false") > 0, "and the rifle is let go")
    # onto a container item (ammo onto a magazine - kit 2026-10-31: magazines are containers, the item-over-item
    # route refused them). The game turns HandleContainerToContainerDrop off, so the mouse's OnDrop sends the
    # unhandled drop: EventOnInventoryAction(from, its grid, item, the item dropped on, -1, turned) on the comp
    # (kit 13:31: the local HandleContainerOnContainer said handled and moved nothing)
    drop_on_can = "P('right'); P('right'); P('a'); CALLS = {}; P('down', 'down', 'left', 'a')"
    L = fresh()
    L.execute("CAN.bag = true; MAG = SUBC('Mag'); CAN.SlotContainer = MAG; " + drop_on_can)
    check(L.eval("JOIN(CALLS)") == "BagComp move Rifle Bag->Mag idx=-1 rot=false recv=Can",
          "the rifle onto a magazine: EventOnInventoryAction into its grid, receiver the magazine (%s)" % L.eval("JOIN(CALLS)"))
    check(L.eval("JOIN(CALLS)").find("into") < 0, "and never the local HandleContainerOnContainer")
    check(L.eval("PI.status()").find("held=false") > 0 and any("padinv: into Can" in l for l in L.eval("LOG").values()),
          "and let go, the log says where")
    L = fresh()
    L.execute("CAN.bag = true; MAG = SUBC('Mag'); MAG.takes = false; CAN.SlotContainer = MAG; " + drop_on_can)
    check(L.eval("JOIN(CALLS)") == "" and any("doesn't take it" in l for l in L.eval("LOG").values()),
          "a container item that doesn't take it: nothing sent, as the mouse (%s)" % L.eval("JOIN(CALLS)"))
    L = fresh()
    L.execute("CAN.bag = true; MAG = SUBC('Mag'); MAG.inside = true; CAN.SlotContainer = MAG; " + drop_on_can)
    check(L.eval("JOIN(CALLS)") == "" and any("inside itself" in l for l in L.eval("LOG").values()),
          "into its own compartment: nothing sent (%s)" % L.eval("JOIN(CALLS)"))
    L = fresh()
    L.execute("CAN.bag = true; " + drop_on_can)
    check(L.eval("JOIN(CALLS)") == "" and any("can't check what that container takes" in l for l in L.eval("LOG").values()),
          "a container item without its grid: nothing sent (%s)" % L.eval("JOIN(CALLS)"))
    L = fresh()
    L.execute("CAN.bag = true; CAN.special = MKOBJ('Spec'); CAN.SlotContainer = SUBC('Mag'); " + drop_on_can)
    check(L.eval("JOIN(CALLS)") == "BagComp over Rifle on Can Bag->Bag",
          "a container item with a special container: item over item, as the mouse (%s)" % L.eval("JOIN(CALLS)"))
    L = fresh()
    L.execute("BAG.SpecialSContainer = MKOBJ('Sp'); " + drop_on_can)
    check(L.eval("JOIN(CALLS)") == "" and any("not on the pad yet" in l for l in L.eval("LOG").values()),
          "a grid with its own special container: refused, never the screen-only HandleContainerOnContainer (%s)"
          % L.eval("JOIN(CALLS)"))
    check(L.eval("PI.status()").find("held=true") > 0, "and the item stays held")
    # the item dropped on still mid-move: nothing sent
    L = fresh()
    L.execute("CAN.pending = true; P('right'); P('right'); P('a'); CALLS = {}; P('down', 'down', 'left', 'a')")
    check(L.eval("JOIN(CALLS)") == "" and any("still being moved" in l for l in L.eval("LOG").values()),
          "onto an item still mid-move: nothing sent (%s)" % L.eval("JOIN(CALLS)"))
    # across grids, unsupported, own compartment
    L = fresh()
    L.execute("P('right'); P('right', 'right', 'right', 'a', 'left'); CALLS = {}; P('a')")
    check(L.eval("JOIN(CALLS)") == "BagComp move BoxItem Loot->Bag idx=3 rot=false recv=nil",
          "loot box into the bag's free cell: the move goes to the bag's comp, from the loot")
    L = fresh()
    L.execute("BAG.refuse.BoxItem = true; P('right'); P('right', 'right', 'right', 'a', 'left'); CALLS = {}; P('a')")
    check(L.eval("JOIN(CALLS)") == "" and any("doesn't take it" in l for l in L.eval("LOG").values()),
          "a container that doesn't take the item (IsSupportedByThis false): nothing sent")
    L = fresh()
    L.execute("BAG.SlotMother = BOXI; P('right'); P('right', 'right', 'right', 'a', 'left'); CALLS = {}; P('a')")
    check(L.eval("JOIN(CALLS)") == "" and any("inside itself" in l for l in L.eval("LOG").values()),
          "never into the item's own compartment (a bag into itself)")
    L = fresh()
    L.execute("BAG.IsSupportedByThis = nil; P('right'); P('right', 'right', 'right', 'a', 'left'); CALLS = {}; P('a')")
    check(L.eval("JOIN(CALLS)") == "" and any("can't check" in l for l in L.eval("LOG").values()),
          "when what the container takes can't be read: nothing sent (no unchecked moves)")
    # the mouse drag's own checks (Sentinel R1: the server only checks fit)
    MOVE_BOX = "P('right'); P('right', 'right', 'right', 'a', 'left'); CALLS = {}; P('a')"
    L = fresh()
    L.execute("BAG.maxw = 0.5; " + MOVE_BOX)
    check(L.eval("JOIN(CALLS)") == "" and any("too heavy" in l for l in L.eval("LOG").values()),
          "over the bag's weight limit (CheckWeightLimit false): nothing sent")
    L = fresh()
    L.execute("BAG.inside = true; " + MOVE_BOX)
    check(L.eval("JOIN(CALLS)") == "" and any("inside itself" in l for l in L.eval("LOG").values()),
          "the game's CheckRootContainer says no: nothing sent")
    L = fresh()
    L.execute("BAG.CheckWeightLimit = nil; " + MOVE_BOX)
    check(L.eval("JOIN(CALLS)") == "" and any("weight limit" in l for l in L.eval("LOG").values()),
          "the weight limit can't be read: nothing sent")
    L = fresh()
    L.execute("P('right'); P('right', 'right', 'right'); BOXI.pending = true; CALLS = {}; P('a')")
    check(L.eval("PI.status()").find("held=false") > 0 and any("still being moved" in l for l in L.eval("LOG").values()),
          "an item still mid-move (IsItemPending?) can't be grabbed")
    L = fresh()
    L.execute("P('right'); P('left'); P('down', 'down', 'a', 'right', 'right', 'right'); CAN2.pending = true; CALLS = {}; P('a')")
    check(L.eval("JOIN(CALLS)") == "", "no stack onto an item still mid-move")
    L = fresh()
    L.execute("CAN.ContainerMother = LOOT; BAG.maxw = 0.5; P('right'); P('left'); P('down', 'down', 'a', 'right', 'right', 'right'); "
              "CALLS = {}; P('a')")
    check(L.eval("JOIN(CALLS)") == "" and any("too heavy" in l for l in L.eval("LOG").values()),
          "a stack from another container over the weight limit: nothing sent")
    # backpack-in-backpack difficulty: a grid owned by a backpack item, beside the loot
    L = fresh()
    L.execute("PACK = GRID('Pack', 2, 2, 600, 0); PACK.SlotMother = RIFLE; RIFLE.backpack = true; BOXI.backpack = true; HARD = true")
    L.execute("P('right'); P('right', 'right', 'right', 'a', 'right', 'right', 'right'); CALLS = {}; P('a')")
    check(L.eval("JOIN(CALLS)") == "" and any("no backpacks in backpacks" in l for l in L.eval("LOG").values()),
          "a backpack into a backpack's grid on that difficulty: nothing sent")
    L.execute("HARD = false; P('a')")
    check(L.eval("LASTCALL()") == "PackComp move BoxItem Loot->Pack idx=0 rot=false recv=nil",
          "the difficulty off: the same move goes through")
    # holding loot when the loot goes
    L = fresh()
    L.execute("P('right'); P('right', 'right', 'right', 'a', 'left'); LOOT.hidden = true; CALLS = {}; T(0.6)")
    check(L.eval("PI.status()").find("held=false") > 0 and L.eval("BOXI.opacity") == 1 and L.eval("JOIN(CALLS)") == ""
          and any("container closed" in l for l in L.eval("LOG").values()),
          "holding a loot item when the loot closes: put back, nothing sent")
    L.execute("CALLS = {}; P('a')")
    check("move" not in L.eval("JOIN(CALLS)"), "and A afterwards doesn't drop the gone item")

    # equip and unequip go through the game's own Context_TryEquip / TryUnequip
    L = fresh()
    L.execute("P('right'); P('right', 'a', 'down', 'down', 'down'); CALLS = {}")
    check(L.eval("CUR()") == "0,0" and L.eval("PI.status()").find("held=true") > 0, "(held rifle down to the equip slot)")
    L.execute("P('a')")
    check(L.eval("JOIN(CALLS)") == "EquipComp equip Rifle root Equip", "onto an equip slot: Context_TryEquip(item, root)")
    L = fresh()
    # (the can gets no menu here, so D-pad down goes straight past it)
    L.execute("CAN.no_menu = true; HELM = ITEM('Helmet', EQUIP, 0, 0, 1, 1); P('right'); P('down', 'down', 'down', 'a', 'up'); CALLS = {}; P('a')")
    check(L.eval("JOIN(CALLS)") == "EquipComp unequip Helmet root Equip", "out of an equip slot: Context_TryUnequip(item, root)")

    # the inventory goes: tints back, menu closed, the pad handed back
    L = fresh()
    L.execute("P('right'); P('right')")
    check(L.eval("TINT(RIFLE)") == "1.00,0.75,0.10" and L.eval("CANVAS.inview") is True, "(cursor on the rifle, menu open)")
    L.execute("for _, g in ipairs(GRIDS) do g.hidden = true end; CALLS = {}")
    r = L.eval("T(0.6)")
    check(r is False and L.eval("RIFLE.SlotBorder.cur.R") == 0.1 and L.eval("CANVAS.inview") is False,
          "inventory closed: tint back, the pad's menu closed, returns false")
    check(any("inventory off the pad" in l for l in L.eval("LOG").values()), "logged")
    L.execute("for _, g in ipairs(GRIDS) do g.hidden = false end; BAR.hidden = false; BAG.hidden = true; LOOT.hidden = true; EQUIP.hidden = true; HID.hidden = true")
    check(L.eval("P('right')") is False, "only the hotbar on screen: not an inventory, the pad goes to the menu code")
    # held D-pad repeats
    L = fresh()
    L.execute("P('right'); CALLS = {}; DOWN[PADS.down] = true; for _ = 1, 12 do T(0.05) end; DOWN[PADS.down] = false; T()")
    check(L.eval("CUR()") == "0,2", "D-pad held 0.6 s: one step, then repeats (0,0 -> 0,2)")
    # no geometry: grids side by side in list order, still usable
    L = fresh()
    L.execute("NO_GEO = true; P('right'); P('right', 'right', 'right')")
    check(L.eval("CUR()") == "0,0" and L.eval("TINT(BOXI)") == "1.00,0.75,0.10" and L.eval("MOUSE") is None,
          "no widget geometry: right still reaches the loot grid (list order), the mouse isn't moved")
    check(any("no layout yet" in l for l in L.eval("LOG").values()), "and the log says the layout is unknown")
    check(warnings(L) == [], "no warnings: %s" % warnings(L))

    # the hotbar is never on the D-pad's way (user 2026-10-31: "i have too click all the way through the hot bar")
    L = fresh()
    L.execute("CAN.no_menu = true; P('right'); P('down', 'down', 'down')")
    check(L.eval("CUR()") == "0,0" and L.eval("TINT(CELL(EQUIP,0,0))") == "1.00,0.75,0.10", "(down from the bag to the equip slot)")
    L.execute("P('down')")
    check(L.eval("TINT(CELL(EQUIP,0,0))") == "1.00,0.75,0.10" and L.eval("TINT(CELL(BAR,0,0))") == "-",
          "down from the equip slot: the hotbar below is skipped, the cursor stays")
    L.execute("P('up')")
    check(L.eval("CUR()") == "0,2" and L.eval("TINT(CAN)") == "1.00,0.75,0.10", "up from the equip slot: back into the bag")

    # the layout from the widget tree: ScaleBox fit, a collapsed sibling, paddings, a scrolled ScrollBox
    L = fresh()
    L.execute("""GRIDS = {}
        local sb = ADD(ROOT, PANEL('Scale', 'ScaleBox'), 0, 0)
        local hb = ADD(sb, PANEL('HB', 'HorizontalBox', { w = 960, h = 540 }))
        ADD(hb, PANEL('A', 'Border', { w = 100, h = 100, collapsed = true }))
        ADD(hb, PANEL('B', 'Border', { w = 200, h = 100, pad = { 10, 0, 0, 0 } }))
        local sc = ADD(hb, PANEL('Scroll', 'ScrollBox', { w = 300, h = 540, pad = { 5, 0, 0, 0 }, orient = 1, scroll = 20 }))
        ADD(sc, PANEL('D', 'Border', { w = 300, h = 40, pad = { 0, 0, 0, 4 } }))
        DEEP = GRID('Deep', 4, 3, 0, 0, { main = true, parent = sc, pad = { 0, 6, 0, 0 } })""")
    L.execute("P('right')")
    # scale 2 (960x540 fit to 1920x1080); x = 2 * (10 + 200 + 5) = 430; y = 2 * (40 + 4 - 20 + 6) = 60; cell 100 px
    check(L.eval("MOUSE") == "480,110" and any("screen layout" in l for l in L.eval("LOG").values()),
          "nested boxes: the cell center from sizes, paddings, the scroll offset and the ScaleBox fit (480,110)")
    # DPI: the mouse takes pixels, the menu viewport units
    L = fresh()
    L.execute("DPI = 2; P('right')")
    check(L.eval("MOUSE") == "50,50", "DPI scale 2: the mouse at the cell center in pixels (2 x 25)")
    L.execute("P('right')")
    check(L.eval("MENUPOS") == "95,5", "and the menu in viewport units (unscaled)")
    # the menu stays on screen: no room right of the cell -> left of it; no room either side -> against the edge
    L = fresh()
    L.execute("VPW = 400; MW = 350; P('right'); P('right')")
    check(L.eval("MENUPOS") == "50,5", "a 350-wide menu on a 400-wide screen, no room either side: kept inside (x 50)")
    L = fresh()
    L.execute("VPW = 140; MW = 50; P('right'); P('right')")
    check(L.eval("MENUPOS") == "5,5", "no room right of the cell: on its left (75 - 20 - 50)")
    L = fresh()
    L.execute("VPH = 100; P('right'); P('right')")
    check(L.eval("MENUPOS") == "95,0", "a 150-tall menu on a 100-tall screen: from the top, never above it")
    L = fresh()
    L.execute("MW = 0; P('right'); P('right')")
    check(L.eval("MENUPOS") == "95,5", "no size yet (first frame): a 300x240 guess, still at the cell")

    # the layout walk is cached until other grids show, or 2 s
    L = fresh()
    L.execute("P('right'); N1 = SIZES; P('right'); N2 = SIZES")
    check(L.eval("N1") > 0 and L.eval("N2") == L.eval("N1"), "a second press with the same grids: no new layout walk")
    L.execute("LOOT.hidden = true; P('left'); N3 = SIZES")
    check(L.eval("N3") > L.eval("N2"), "the loot closes (other grids on screen): laid out again")
    L.execute("T(2.1); N4 = SIZES")
    check(L.eval("N4") > L.eval("N3"), "and again after 2 s")

    # the mouse self-check: moves that don't hover the cell stop the mouse moves (the cursor goes on)
    L = fresh()
    L.execute("HOVER_OK = false; P('right'); P('right', 'right', 'right')")
    check(any("doesn't land" in l for l in L.eval("LOG").values()) and L.eval("MOUSE") == "175,25",
          "three moves the game doesn't see as hovering the cell: logged, the mouse stays at the last spot")
    L.execute("P('left')")
    check(L.eval("CUR()") == "3,0" and L.eval("MOUSE") == "175,25", "the cursor still moves, the mouse doesn't")
    L.execute("MENUPOS = nil; P('left')")
    check(L.eval("CUR()") == "2,0" and "menu Rifle" in L.eval("JOIN(CALLS)") and L.eval("MENUPOS") == "860,465",
          "layout off: an item's menu goes in the middle of the screen (1920x1080, menu 200x150), not the game's spot")
    L = fresh()
    L.execute("P('right'); P('right', 'right', 'right', 'down')")
    check(not any("doesn't land" in l for l in L.eval("LOG").values()), "moves that hover the cell: the mouse keeps following")

    # LB / RB with nothing held: the tabs, through BP_Inventory's own title click handlers
    L = fresh()
    L.execute("""INVW = MKOBJ('Inventory'); INVW.IsVisible = function() return true end; INVW.IsInViewport = function() return true end
        CRAFTW = MKOBJ('Crafting', { on = false }); CRAFTW.IsVisible = function(self) return self.on end
        LOOTW = MKOBJ('LootContent', { on = true }); LOOTW.IsVisible = function(self) return self.on end
        INVW.BP_CraftingWidget, INVW.LootContent = CRAFTW, LOOTW
        for _, fn in ipairs({ 'OnWidgetMouseButtonDown_Event_0', 'OnWidgetMouseButtonDown_Event_1', 'Loot_OnMouseButtonDown',
                              'Vicinity_OnMouseButtonDown' }) do
            INVW[fn] = function(self, key) CALLS[#CALLS + 1] = 'tab ' .. fn .. ' ' .. key.KeyName.s end
        end
        INVS = { INVW }""")
    check(L.eval("P('lb')") is True and L.eval("LASTCALL()") == "tab OnWidgetMouseButtonDown_Event_0 LeftMouseButton",
          "LB with equipment showing: CRAFTING's title click (OnWidgetMouseButtonDown_Event_0, left button)")
    L.execute("CRAFTW.on = true; P('lb')")
    check(L.eval("LASTCALL()") == "tab OnWidgetMouseButtonDown_Event_1 LeftMouseButton", "LB with crafting showing: EQUIPMENT's (_Event_1)")
    L.execute("P('rb')")
    check(L.eval("LASTCALL()") == "tab Vicinity_OnMouseButtonDown LeftMouseButton", "RB with loot showing: VICINITY")
    L.execute("LOOTW.on = false; P('rb')")
    check(L.eval("LASTCALL()") == "tab Loot_OnMouseButtonDown LeftMouseButton", "RB with vicinity showing: LOOT")
    L.execute("P('right'); P('right', 'a'); CALLS = {}; P('rb')")
    check("tab" not in L.eval("JOIN(CALLS)") and L.eval("TINT(CELL(BAG,1,0))") == "0.20,0.85,0.20" and
          L.eval("TINT(CELL(BAG,1,1))") == "0.20,0.85,0.20", "holding an item, RB turns it instead (no tab)")
    L.execute("P('b'); INVS = {}; CALLS = {}; P('lb')")
    check(L.eval("JOIN(CALLS)") == "" and any("no inventory screen" in l for l in L.eval("LOG").values()),
          "no inventory widget found: nothing called, logged")
    check(warnings(L) == [], "no warnings: %s" % warnings(L))

    # B: puts a held item back, else closes the item menu, else leaves the inventory (BP_Inventory's Exit, as Escape)
    L = fresh()
    L.execute("""INVW = MKOBJ('Inventory'); INVW.IsVisible = function() return true end; INVW.IsInViewport = function() return true end
        function INVW.Exit(self) CALLS[#CALLS + 1] = 'exit' end
        INVS = { INVW }""")
    L.execute("P('right'); P('right', 'a'); CALLS = {}; P('b')")
    check("exit" not in L.eval("JOIN(CALLS)") and any("put back" in l for l in L.eval("LOG").values()),
          "B holding an item: put back, the inventory stays")
    L.execute("P('right'); P('left'); CALLS = {}; P('b')")
    calls = L.eval("JOIN(CALLS)")
    check("menu closed" in calls and "exit" not in calls, "B with the item menu open: the menu closes, the inventory stays")
    L.execute("CALLS = {}; P('b')")
    check(L.eval("JOIN(CALLS)") == "exit" and any("inventory closed" in l for l in L.eval("LOG").values()),
          "B with nothing held and no menu: BP_Inventory Exit, the game's own way out")
    L = fresh()
    L.execute("INVS = {}; P('b')")
    check(L.eval("CUR()") is None or L.eval("CUR()") == "-", "B as the first press: no cursor put down for it")

    # through gamepad.lua: with the inventory up the D-pad goes to padinv, not to menu focus
    L = booted()
    L.execute(INV)
    L.execute("PC.bShowMouseCursor = true; RUN(0.5); MENUS = { WIDGET('Inv', { kids = { WIDGET('Btn', { button = true }) } }) }")
    L.execute("DOWN.Gamepad_DPad_Right = true; RUN(0.25); DOWN.Gamepad_DPad_Right = false; RUN(0.25)")
    check(L.eval("#FOCUSED") == 0 and L.eval("CUR()") == "0,0", "gamepad tick: an inventory up takes the D-pad (no menu focus)")
    # in the inventory its buttons only drive the inventory: MAP on A would grab and open the map in one press
    L.execute('GP.set("map", "Gamepad_FaceButton_Bottom"); RUN(0.25)')
    rows = {(m.Action.__name, m.Key.KeyName.s) for m in L.eval("IMC.Mappings").values()}
    check(("IA_Map", "Gamepad_FaceButton_Bottom") not in rows, "inventory up: the map's A is out (padinv's grab)")
    L.execute("PC.bShowMouseCursor = false; RUN(0.25)")
    rows = {(m.Action.__name, m.Key.KeyName.s) for m in L.eval("IMC.Mappings").values()}
    check(("IA_Map", "Gamepad_FaceButton_Bottom") in rows, "inventory closed: the map's A is back")
    check(L.eval("PI.status()").startswith("on=false") and L.eval("TINT(CELL(BAG,0,0))") == "0.10,0.10,0.10",
          "cursor hidden (inventory closed): padinv lets go and restores the tint")
    check(warnings(L) == [], "no warnings: %s" % warnings(L))


MYSET = r'''
local scripts = ...
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
package.preload["mirror.link"] = function() return {} end
MS = require("mirror.mysettings")
function ROWKEYS() local t = {}; for _, r in ipairs(MS.rows()) do t[#t + 1] = r.key end; return table.concat(t, ";") end
'''


def settings():
    print("mysettings")
    L = lua54.LuaRuntime()
    L.execute(MYSET, SCRIPTS)
    row = L.eval('(function() for _, o in ipairs(MS.LIST) do if o.key == "gamepad" then return o end end end)()')
    check(row is not None, "LIST has a gamepad row")
    if row is not None:
        check(row.default == "xbox", "gamepad defaults to XBOX (on, as before)")
        check(row.label == "CONTROLLER", "labelled CONTROLLER")
        vals = [v[1] for v in row["values"].values()]
        check(vals == ["off", "xbox", "playstation"], "values OFF / XBOX / PLAYSTATION")
        check(row.extra == "BINDINGS", "the row has a second button: BINDINGS")
    n = L.eval("#MS.LIST")
    L.execute("MS.init()")

    def hint():
        return L.eval('(function() for _, r in ipairs(MS.rows()) do if r.key == "gamepad" then return r.text .. "|" .. r.hint end end end)()')
    check(L.eval('MS.on("gamepad")') is True and L.eval('MS.value("gamepad")') == "xbox" and L.eval("MS.pad_style()") == "xbox",
          "on by default, Xbox names")
    check(hint().startswith("XBOX|") and "Steam Input off" in hint(), "XBOX: the Steam Input off hint")
    L.execute('MS.toggle("gamepad")')
    check(L.eval('MS.on("gamepad")') is True and L.eval("MS.pad_style()") == "playstation", "toggle: PLAYSTATION, still on")
    check(hint().startswith("PLAYSTATION|") and "Steam Input on" in hint() and "Gamepad" in hint(),
          "PLAYSTATION: the Steam Input on + Gamepad template hint")
    L.execute('MS.toggle("gamepad")')
    check(L.eval('MS.on("gamepad")') is False and L.eval("MS.pad_style()") == "xbox", "toggle: off (Xbox names kept)")
    L.execute('MS.toggle("gamepad")')
    check(L.eval('MS.on("gamepad")') is True and L.eval('MS.value("gamepad")') == "xbox", "and round to XBOX")
    # a settings file from before: "gamepad on" is XBOX, "gamepad off" stays off
    import tempfile
    for saved, want in (("gamepad on\n", "xbox"), ("gamepad off\n", "off"), ("gamepad playstation\n", "playstation"),
                        ("gamepad maybe\n", "xbox")):
        d = tempfile.mkdtemp(prefix="ms-")
        with open(os.path.join(d, "mirror_my_settings.txt"), "w", encoding="utf-8") as f:
            f.write(saved)
        M = lua54.LuaRuntime()
        M.execute(MYSET.replace('return {} end\nMS', 'return { dir = function() return [[%s]] end } end\nMS' % d), SCRIPTS)
        check(M.eval('MS.value("gamepad")') == want, "a saved %r loads as %s" % (saved.strip(), want))
    keys = [k for k in L.eval("ROWKEYS()").split(";") if k not in ("syncfx", "gore")]
    check("gamepad" in keys and len(keys) == n, "the settings page lists the gamepad row (%d rows without SyncFX and GORE)" % len(keys))
    with open(os.path.join(SCRIPTS, "mirror", "journal_tab.lua"), encoding="utf-8") as f:
        m = re.search(r"^local SETTING_ROWS = (\d+)", f.read(), re.M)
    check(m is not None and int(m.group(1)) == n + 2,
          "journal_tab SETTING_ROWS (%s) holds SyncFX, GORE and all %d rows" % (m and m.group(1), n))
    check([w for w in L.eval("LOG").values() if w.startswith("WARN") or w.startswith("ERROR")] == [], "no warnings")


for t in (plan, stick, lifecycle, missing, look, init_cfg, bindings, full_bindings, playstation, controls, sensitivity, padinv,
          settings):
    t()
print()
print("%d checks, %d failure(s)" % (count, len(fails)))
for f in fails:
    print("  FAILED: " + f)
sys.exit(1 if fails else 0)
