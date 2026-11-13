-- Controller support (MY SETTINGS -> CONTROLLER). The game maps only keyboard and mouse (one mapping context,
-- IMC_General, no Gamepad_ keys). In each world this adds every pad key below to the actions of the keyboard key
-- it stands in for, so the game treats the pad exactly like that key (sprint, quick search and hold breath all
-- on L3, like LeftShift). Then the context is taken off and put back on at its old priority: that makes the new
-- keys live (RequestRebuildControlMappings alone did not, kit 2026-10-31). The right stick turns the camera each
-- frame through the controller's yaw/pitch input, the same calls the game's mouse look makes.
-- LB/RB step the hotbar through the game's own Event_WeaponCycle (the mouse wheel's path, which the game only
-- takes with its Character.WeaponScroll setting on). In a menu (cursor shown) the buttons are for the menu: their
-- rows come out of the context (set_level), the inventory grids go to padinv.lua, and elsewhere a D-pad press with
-- nothing focused puts focus on the menu's first button, so Slate's own navigation moves it and A presses it.
-- Each action's button can be changed, or cleared, and every other game action can be put on a button
-- (CONTROLLER -> BINDINGS), and so can the mod's own menu, inventory and option-step buttons; the look speeds and
-- dead zone have sliders, INVERT LOOK and SWAP STICKS are switches. All saved in mirror_pad_binds.txt.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local link = require("mirror.link")
local padinv = require("mirror.padinv")

local gamepad = {}

local IMC = "/Game/Input/IMC_General.IMC_General"
local BINDS_FILE = "\\mirror_pad_binds.txt"

-- The buttons an action can sit on, in the bindings screen's words: { key, Xbox name, PlayStation name }. A PS5
-- pad is the same buttons in the same places: the game reads XInput only, so a DualSense reaches it as a virtual
-- Xbox pad (Steam Input's Gamepad template, DS4Windows) and Cross is Gamepad_FaceButton_Bottom like A. Words, not
-- the ✕○□△ glyphs, which the game's font may not have. (Touchpad, PS button: no XInput key, so not bindable.)
gamepad.PADS = {
    { "Gamepad_FaceButton_Bottom", "A", "CROSS" }, { "Gamepad_FaceButton_Right", "B", "CIRCLE" },
    { "Gamepad_FaceButton_Left", "X", "SQUARE" }, { "Gamepad_FaceButton_Top", "Y", "TRIANGLE" },
    { "Gamepad_LeftShoulder", "LB", "L1" }, { "Gamepad_RightShoulder", "RB", "R1" },
    { "Gamepad_LeftTrigger", "LT", "L2" }, { "Gamepad_RightTrigger", "RT", "R2" },
    { "Gamepad_LeftThumbstick", "L3", "L3" }, { "Gamepad_RightThumbstick", "R3", "R3" },
    { "Gamepad_DPad_Up", "D-PAD UP", "D-PAD UP" }, { "Gamepad_DPad_Down", "D-PAD DOWN", "D-PAD DOWN" },
    { "Gamepad_DPad_Left", "D-PAD LEFT", "D-PAD LEFT" }, { "Gamepad_DPad_Right", "D-PAD RIGHT", "D-PAD RIGHT" },
    { "Gamepad_Special_Left", "VIEW", "CREATE" }, { "Gamepad_Special_Right", "MENU", "OPTIONS" },
}
local PAD_NAME, PAD_NAME_PS = {}, {}
for _, p in ipairs(gamepad.PADS) do PAD_NAME[p[1]] = p[2]; PAD_NAME_PS[p[1]] = p[3] end
-- a pad key's name for the pad in use (style "playstation" or "xbox"); nil for no key or an unknown one
function gamepad.pad_name(pad, style)
    if pad == nil then return nil end
    return style == "playstation" and PAD_NAME_PS[pad] or PAD_NAME[pad]
end
-- MY SETTINGS -> CONTROLLER: XBOX or PLAYSTATION (xbox when it can't be read)
local function pad_style()
    local ok, s = pcall(function() return require("mirror.mysettings").pad_style() end)
    return ok and s == "playstation" and "playstation" or "xbox"
end
local LOOK_HOLD_S = 0.3   -- the look level stays this long after the target goes (no flapping on a flickering trace)

-- The actions, each on one pad button (pad = the default). keys: the keyboard/mouse keys it copies, so it gets
-- every game action on them, except the ones in skip; cycle: the hotbar step instead (true = forward). User
-- 2026-10-31: "make LB RB switch hotbar, Dpad controlls UI and y is lights/attachments" (L = flashlight, K =
-- tactical attachment). K also flips the car and R also changes its radio: the pad leaves those out.
gamepad.ACTIONS = {
    { id = "jump", label = "JUMP", pad = "Gamepad_FaceButton_Bottom", keys = { "SpaceBar" } },   -- + handbrake
    { id = "crouch", label = "CROUCH", pad = "Gamepad_FaceButton_Right", keys = { "LeftControl" } },
    { id = "interact", label = "INTERACT", pad = "Gamepad_FaceButton_Left", keys = { "F" } },
    { id = "lights", label = "LIGHTS / ATTACHMENTS", pad = "Gamepad_FaceButton_Top", keys = { "L", "K" },
      skip = { IA_VehicleFlip = true } },
    { id = "aim", label = "AIM", pad = "Gamepad_LeftTrigger", keys = { "RightMouseButton" } },
    { id = "shoot", label = "SHOOT", pad = "Gamepad_RightTrigger", keys = { "LeftMouseButton" } },
    { id = "hotbar_back", label = "HOTBAR BACK", pad = "Gamepad_LeftShoulder", cycle = false },
    { id = "hotbar_next", label = "HOTBAR NEXT", pad = "Gamepad_RightShoulder", cycle = true },
    -- + the middle mouse button's IA_ScopeZoom, which the game only acts on while aiming (IsADS?): L3 when aiming
    -- zooms the sight, as the middle button does (user 2026-10-31). Not its IA_ZoomCamera (the unaimed camera zoom).
    { id = "sprint", label = "SPRINT / SCOPE ZOOM", pad = "Gamepad_LeftThumbstick", keys = { "LeftShift", "MiddleMouseButton" },
      skip = { IA_ZoomCamera = true } },
    { id = "shove", label = "SHOVE", pad = "Gamepad_RightThumbstick", keys = { "V" } },
    { id = "reload", label = "RELOAD", pad = "Gamepad_DPad_Left", keys = { "R" }, skip = { IA_VehicleRadio = true } },
    { id = "throwable", label = "THROWABLE", pad = "Gamepad_DPad_Up", keys = { "Five" } },
    { id = "inventory", label = "INVENTORY", pad = "Gamepad_Special_Left", keys = { "Tab" }, menu = true },
    { id = "pause", label = "PAUSE MENU", pad = "Gamepad_Special_Right", keys = { "Escape" }, menu = true },
    -- The rest of the game's actions, on no button until one is picked (16 buttons, the ones above take 14). ia:
    -- the context actions it goes on, by name, so a key with several actions (E: shoulder swap and loot all,
    -- Hyphen: sit and camera reset) can be split. menu: stays live with a menu up, so it can close its own menu.
    { id = "roll", label = "ROLL", ia = { "IA_Roll" } },
    { id = "fire_mode", label = "FIRE MODE", ia = { "IA_ChangeFireMode" } },
    { id = "primary", label = "PRIMARY WEAPON", ia = { "IA_EquipPrimary" } },
    { id = "secondary", label = "SECONDARY WEAPON", ia = { "IA_EquipSecondary" } },
    { id = "sidearm", label = "SIDEARM", ia = { "IA_EquipSidearm" } },
    { id = "melee", label = "MELEE", ia = { "IA_EquipMelee" } },
    { id = "unequip", label = "PUT AWAY", ia = { "IA_Unequip" } },
    { id = "hotbar6", label = "HOTBAR 6", ia = { "IA_Hotbar6" } },
    { id = "hotbar7", label = "HOTBAR 7", ia = { "IA_Hotbar7" } },
    { id = "hotbar8", label = "HOTBAR 8", ia = { "IA_Hotbar8" } },
    { id = "fishing", label = "FISHING ROD", ia = { "IA_FishingRod" } },
    { id = "radial", label = "RADIAL MENU", ia = { "IA_RadialMenu" } },
    { id = "loot_all", label = "LOOT ALL", ia = { "IA_LootAll" } },
    { id = "flashlight", label = "FLASHLIGHT", ia = { "IA_Flashlight" } },
    { id = "tactical", label = "TACTICAL ATTACHMENT", ia = { "IA_ToggleTactical" } },
    { id = "night_vision", label = "NIGHT VISION", ia = { "IA_NightVision" } },
    { id = "binoculars", label = "BINOCULARS", ia = { "IA_Binoculars" } },
    { id = "distract", label = "DISTRACT", ia = { "IA_Distract" } },
    { id = "hold_breath", label = "HOLD BREATH", ia = { "IA_HoldBreath" } },
    { id = "quick_search", label = "QUICK SEARCH", ia = { "IA_QuickSearch" } },
    { id = "scope_zoom", label = "SCOPE ZOOM", ia = { "IA_ScopeZoom" } },
    { id = "perspective", label = "CAMERA VIEW", ia = { "IA_ChangePerspective" } },
    { id = "camera_left", label = "SHOULDER LEFT", ia = { "IA_SwitchCameraLeft" } },
    { id = "camera_right", label = "SHOULDER RIGHT", ia = { "IA_SwitchCameraRight" } },
    { id = "reset_camera", label = "RESET CAMERA", ia = { "IA_ResetCameraPosition" } },
    { id = "free_look", label = "FREE LOOK", ia = { "IA_FreeLook" } },
    { id = "auto_run", label = "AUTO RUN", ia = { "IA_AutoRun" } },
    { id = "sit", label = "SIT DOWN", ia = { "IA_SitDown" } },
    { id = "journal", label = "HANDBOOK", ia = { "IA_Journal" }, menu = true },
    { id = "map", label = "MAP", ia = { "IA_Map" }, menu = true },
    { id = "horn", label = "CAR HORN", ia = { "IA_VehicleHorn" } },
    { id = "car_radio", label = "CAR RADIO", ia = { "IA_VehicleRadio" } },
    { id = "car_flip", label = "FLIP CAR", ia = { "IA_VehicleFlip" } },
    { id = "hide_ui", label = "HIDE HUD", ia = { "IA_HideUI" } },
    { id = "photo", label = "PHOTO MODE", ia = { "IA_PhotoMode" } },
    { id = "quick_save", label = "QUICK SAVE", ia = { "IA_QuickSave" } },
}
local by_id = {}
for _, a in ipairs(gamepad.ACTIONS) do a.default = a.pad; by_id[a.id] = a end

-- The buttons the mod reads itself, each only in its own place, so they swap only with their own kind and can
-- share a button with a game action (A jumps in the world and grabs in the inventory). ctx "menu" (cursor shown):
-- padinv's inventory buttons (inv: its name for one) and the menu cursor (dir: also the menu focus below).
-- ctx "look" (in the world, looking at something you can use, a bed, a crate): the mouse wheel's option step. The
-- game has that on plain key events (BP_PlayerCharacter MouseScrollUp/Down -> BP_JigHelperComp.CycleOptions(up)),
-- not on an Enhanced Input action, so no context row can copy it. User 2026-10-31: "when hovering over a bed or a
-- crate you cant use those controlls so make d pad work".
gamepad.CONTROLS = {
    { id = "menu_up", label = "MENU UP", pad = "Gamepad_DPad_Up", ctx = "menu", inv = "up", dir = true },
    { id = "menu_down", label = "MENU DOWN", pad = "Gamepad_DPad_Down", ctx = "menu", inv = "down", dir = true },
    { id = "menu_left", label = "MENU LEFT", pad = "Gamepad_DPad_Left", ctx = "menu", inv = "left", dir = true },
    { id = "menu_right", label = "MENU RIGHT", pad = "Gamepad_DPad_Right", ctx = "menu", inv = "right", dir = true },
    { id = "inv_grab", label = "INV: GRAB / PUT DOWN", pad = "Gamepad_FaceButton_Bottom", ctx = "menu", inv = "a" },
    { id = "inv_back", label = "INV: BACK / LEAVE", pad = "Gamepad_FaceButton_Right", ctx = "menu", inv = "b" },
    { id = "inv_take", label = "INV: QUICK TAKE", pad = "Gamepad_FaceButton_Left", ctx = "menu", inv = "x" },
    { id = "inv_tab_left", label = "INV: TAB / TURN LEFT", pad = "Gamepad_LeftShoulder", ctx = "menu", inv = "lb" },
    { id = "inv_tab_right", label = "INV: TAB / TURN RIGHT", pad = "Gamepad_RightShoulder", ctx = "menu", inv = "rb" },
    { id = "option_up", label = "PROMPT OPTION UP", pad = "Gamepad_DPad_Up", ctx = "look", up = true },
    { id = "option_down", label = "PROMPT OPTION DOWN", pad = "Gamepad_DPad_Down", ctx = "look", up = false },
}
for _, a in ipairs(gamepad.CONTROLS) do a.default = a.pad; by_id[a.id] = a end
-- the list an action or control swaps buttons within (with its own ctx)
local function kind(a) return a.ctx and gamepad.CONTROLS or gamepad.ACTIONS end

-- On/off switches (BINDINGS -> SENSITIVITY), saved as "<id> on" while on. key: the gamepad.OPT field.
gamepad.OPTIONS = {
    { id = "invert_look", label = "INVERT LOOK", key = "invert" },   -- stick up looks down
    { id = "swap_sticks", label = "SWAP STICKS", key = "swap" },      -- walk on the right stick, look with the left
}
gamepad.OPT = { invert = false, swap = false }
local opt_by_id = {}
for _, o in ipairs(gamepad.OPTIONS) do opt_by_id[o.id] = o end

-- the stick that walks (W/A/S/D): the left one, the right one with SWAP STICKS
local STICKS = {
    left = { { "Gamepad_LeftStick_Up", "W" }, { "Gamepad_LeftStick_Down", "S" },
             { "Gamepad_LeftStick_Left", "A" }, { "Gamepad_LeftStick_Right", "D" } },
    right = { { "Gamepad_RightStick_Up", "W" }, { "Gamepad_RightStick_Down", "S" },
              { "Gamepad_RightStick_Left", "A" }, { "Gamepad_RightStick_Right", "D" } },
}

-- { pad key, the keyboard/mouse key it copies, skip = { action name = true } }: the stick plus each action's keys
-- on its current button. DIRECT: { pad key, action name } for the actions bound by name (ia). The controls go to
-- padinv (its buttons) and option_pads (the rows the option step takes out while looking at something).
gamepad.MIRROR = {}
gamepad.DIRECT = {}
local option_pads = {}
function gamepad.rebuild()
    local m, d, o = {}, {}, {}
    for _, p in ipairs(STICKS[gamepad.OPT.swap and "right" or "left"]) do m[#m + 1] = p end
    for _, a in ipairs(gamepad.ACTIONS) do
        if a.pad then
            for _, k in ipairs(a.keys or {}) do m[#m + 1] = { a.pad, k, skip = a.skip } end
            for _, n in ipairs(a.ia or {}) do d[#d + 1] = { a.pad, n } end
        end
    end
    for _, a in ipairs(gamepad.CONTROLS) do
        if a.inv then padinv.BUTTONS[a.inv] = a.pad end
        if a.ctx == "look" and a.pad then o[a.pad] = true end
    end
    gamepad.MIRROR, gamepad.DIRECT, option_pads = m, d, o
end
gamepad.rebuild()

-- Saved bindings: "<id> <pad key>" lines, "<id> none" for an action taken off its button; unknown ids/buttons
-- are skipped. Returns id -> pad key, or false for none.
function gamepad.parse_binds(s)
    local out = {}
    for id, pad in tostring(s or ""):gmatch("([%w_]+)%s+([%w_]+)") do
        if by_id[id] and PAD_NAME[pad] then out[id] = pad elseif by_id[id] and pad == "none" then out[id] = false end
    end
    return out
end

-- Right stick sensitivity (CONTROLLER -> BINDINGS -> SENSITIVITY sliders), saved in the bindings file as
-- "<id> <whole number>". key: the LOOK field; pct: the file and the screen show it as a percentage (0.5 -> 50);
-- speeds show as a percentage of their default. min/max/step in LOOK units.
gamepad.SENS = {
    { id = "look_x", label = "LOOK SPEED LEFT / RIGHT", key = "yaw", min = 40, max = 600, step = 10 },
    { id = "look_y", label = "LOOK SPEED UP / DOWN", key = "pitch", min = 30, max = 450, step = 10 },
    { id = "aim_look", label = "LOOK SPEED WHILE AIMING", key = "aim", min = 0.1, max = 1.0, step = 0.05, pct = true },
    { id = "dead_zone", label = "STICK DEAD ZONE", key = "dz", min = 0.02, max = 0.4, step = 0.01, pct = true },
}
local sens_by_id = {}
for _, s in ipairs(gamepad.SENS) do sens_by_id[s.id] = s end
local LOOK_DEFAULT = {}   -- the LOOK values before any slider (defaults + cfg), what RESET goes back to

local function snap(s, v)
    v = math.max(s.min, math.min(s.max, v))
    return s.min + math.floor((v - s.min) / s.step + 0.5) * s.step
end
-- "<id> <number>" lines -> id -> LOOK value (clamped, snapped); other lines skipped
function gamepad.parse_sens(str)
    local out = {}
    for id, n in tostring(str or ""):gmatch("([%w_]+)%s+(%d+)") do
        local s = sens_by_id[id]
        if s then out[id] = snap(s, s.pct and tonumber(n) / 100 or tonumber(n)) end
    end
    return out
end
-- "<id> on|off" lines -> id -> true / false; other lines skipped. Line by line: a loose pattern over the whole
-- file pairs one line's number with the next line's name.
function gamepad.parse_opts(str)
    local out = {}
    for line in tostring(str or ""):gmatch("[^\r\n]+") do
        local id, v = line:match("^%s*([%w_]+)%s+(%a+)%s*$")
        if opt_by_id[id] and (v == "on" or v == "off") then out[id] = v == "on" end
    end
    return out
end
local function sens_number(s) local v = gamepad.LOOK[s.key]; return math.floor((s.pct and v * 100 or v) + 0.5) end
local function binds_path()
    local d = link.dir and link.dir()
    return d and (d .. BINDS_FILE)
end
-- Saved choices first (the first claim on a button wins; none stays none), then defaults, then any free button
-- for one that has a default: never one button on two of one kind (list + ctx), even from a hand-edited file.
local function settle(list, want)
    local used, left, rest = {}, {}, {}
    local function free(a, p) return not used[(a.ctx or "game") .. "|" .. p] end
    local function take(a, p) a.pad = p; used[(a.ctx or "game") .. "|" .. p] = true end
    for _, a in ipairs(list) do
        local p = want[a.id]
        if p == false then a.pad = nil
        elseif p and free(a, p) then take(a, p)
        else left[#left + 1] = a end
    end
    for _, a in ipairs(left) do
        if a.default == nil then a.pad = nil
        elseif free(a, a.default) then take(a, a.default)
        else rest[#rest + 1] = a end
    end
    for _, a in ipairs(rest) do
        a.pad = nil
        for _, p in ipairs(gamepad.PADS) do
            if free(a, p[1]) then take(a, p[1]); break end
        end
    end
end
local function load_binds()
    for _, a in ipairs(gamepad.ACTIONS) do a.pad = a.default end
    for _, a in ipairs(gamepad.CONTROLS) do a.pad = a.default end
    local path = binds_path()
    local f = path and io.open(path, "rb")
    if not f then gamepad.rebuild(); return end
    local s = f:read("*a") or ""
    f:close()
    local want = gamepad.parse_binds(s)
    settle(gamepad.ACTIONS, want)
    settle(gamepad.CONTROLS, want)   -- (a file from before the controls were listed: their defaults)
    for id, on in pairs(gamepad.parse_opts(s)) do gamepad.OPT[opt_by_id[id].key] = on end
    gamepad.rebuild()
    for id, v in pairs(gamepad.parse_sens(s)) do gamepad.LOOK[sens_by_id[id].key] = v end
end
local function save_binds()
    local path = binds_path()
    if not path then return false end
    -- the whole file built first, then one write: nothing half-built reaches the disk, and a failed write is said
    local lines = {}
    for _, a in ipairs(gamepad.ACTIONS) do lines[#lines + 1] = a.id .. " " .. (a.pad or "none") .. "\n" end
    for _, a in ipairs(gamepad.CONTROLS) do lines[#lines + 1] = a.id .. " " .. (a.pad or "none") .. "\n" end
    -- (only the ones moved off their default: a later default change still reaches everyone else)
    for _, s in ipairs(gamepad.SENS) do
        local d = LOOK_DEFAULT[s.key]
        if not d or math.abs(gamepad.LOOK[s.key] - d) >= s.step / 2 then lines[#lines + 1] = s.id .. " " .. sens_number(s) .. "\n" end
    end
    for _, o in ipairs(gamepad.OPTIONS) do
        if gamepad.OPT[o.key] then lines[#lines + 1] = o.id .. " on\n" end
    end
    local f, err = io.open(path, "wb")
    local ok = f and f:write(table.concat(lines)) and true
    if f then ok = f:close() and ok end
    if not ok then log.warn("gamepad: bindings not saved - " .. tostring(err or path)) end
    return ok == true
end

-- Puts an action (or control) on a button. The one of its kind already there takes this one's old button (a
-- swap; none when this one had none), so no button does two things at once. Returns true when something changed.
function gamepad.assign(id, pad)
    local a = by_id[id]
    if not a or not PAD_NAME[pad] or a.pad == pad then return false end
    for _, o in ipairs(kind(a)) do
        if o ~= a and o.ctx == a.ctx and o.pad == pad then o.pad = a.pad end
    end
    a.pad = pad
    gamepad.rebuild()
    return true
end
-- Takes an action off its button. Returns true when it had one.
function gamepad.unassign(id)
    local a = by_id[id]
    if not a or not a.pad then return false end
    a.pad = nil
    gamepad.rebuild()
    return true
end
function gamepad.reset_binds()
    for _, a in ipairs(gamepad.ACTIONS) do a.pad = a.default end
    for _, a in ipairs(gamepad.CONTROLS) do a.pad = a.default end
    gamepad.rebuild()
end
function gamepad.reset_sens()
    for _, s in ipairs(gamepad.SENS) do gamepad.LOOK[s.key] = LOOK_DEFAULT[s.key] or gamepad.LOOK[s.key] end
end
-- { pad key, action }: analog throttle and brake in a car (both actions are Axis1D; Backwards negates itself)
gamepad.EXTRA = {
    { "Gamepad_RightTriggerAxis", "IA_VehicleForward" },
    { "Gamepad_LeftTriggerAxis", "IA_VehicleBackwards" },
}

-- Right stick look. yaw/pitch: degrees per second at full tilt; aim: share of the speed while LT is held;
-- scale: degrees one unit of Add*Input turns when the controller can't say. The game sets the controller's yaw
-- scale to its Input.Sensitivity and the pitch scale to minus that (BP_PlayerController), so look() divides by
-- the live scales: the pad turns at these speeds whatever the mouse sensitivity is.
gamepad.LOOK = { yaw = 220, pitch = 150, dz = 0.12, expo = 2.0, aim = 0.5, scale = 2.5 }

-- Stick -> look amount: a round dead zone, the rest stretched back to 0..1 and curved (fine aim near the middle).
function gamepad.stick(x, y, dz, expo)
    x, y = tonumber(x) or 0, tonumber(y) or 0
    local m = math.sqrt(x * x + y * y)
    if m <= dz then return 0, 0 end
    local s = math.min(1, (m - dz) / (1 - dz)) ^ expo / m
    return x * s, y * s
end

-- mappings: { { action = <object>, name = "IA_..", key = "W" }, ... } as read from the context.
-- Returns the { action, pad } pairs to add: each pad key once per action, none the context already has.
function gamepad.plan(mappings)
    local by_key, by_name, have = {}, {}, {}
    for _, m in ipairs(mappings) do
        by_key[m.key] = by_key[m.key] or {}
        table.insert(by_key[m.key], m)
        if m.name and not by_name[m.name] then by_name[m.name] = m end
        have[(m.name or tostring(m.action)) .. "|" .. m.key] = true
    end
    local out = {}
    local function add(m, pad)
        local id = (m.name or tostring(m.action)) .. "|" .. pad
        if have[id] then return end
        have[id] = true
        out[#out + 1] = { action = m.action, name = m.name, pad = pad }
    end
    for _, p in ipairs(gamepad.MIRROR) do
        for _, m in ipairs(by_key[p[2]] or {}) do
            if not (p.skip and m.name and p.skip[m.name]) then add(m, p[1]) end
        end
    end
    for _, p in ipairs(gamepad.DIRECT) do
        if by_name[p[2]] then add(by_name[p[2]], p[1]) end
    end
    for _, p in ipairs(gamepad.EXTRA) do
        if by_name[p[2]] then add(by_name[p[2]], p[1]) end
    end
    return out
end

local function setting_on()
    local ok, on = pcall(function() return require("mirror.mysettings").on("gamepad") end)
    return not ok or on ~= false
end

local function key_name(m)
    local n
    if pcall(function() n = m.Key.KeyName:ToString() end) and n then return n end
    pcall(function() n = m:get().Key.KeyName:ToString() end)
    return n
end
local function action_of(m)
    local a
    if not pcall(function() a = m.Action end) or not util.valid(a) then pcall(function() a = m:get().Action end) end
    return util.valid(a) and a or nil
end

local function read(imc)
    local out = {}
    local maps = imc.Mappings
    for i = 1, #maps do
        local m = maps[i]
        local key, act = key_name(m), action_of(m)
        if key and act then out[#out + 1] = { action = act, name = util.fname(act), key = key } end
    end
    return out
end

local added = {}   -- { action, name, pad, out } this module put in (out: taken out of the context for now)
local level = "game"   -- which rows of `added` are in the context: "game" all, "menu"/"inv" some, "none" none

-- The pad keys go live: the context off and back on at its old priority.
local function refresh(imc)
    local s = FindFirstOf("EnhancedInputLocalPlayerSubsystem")
    if not util.valid(s) then return "no input subsystem" end
    local out = {}
    local has = s:HasMappingContext(imc, out)
    local prio = tonumber(out.OutFoundPriority) or 0
    if has then s:RemoveMappingContext(imc, {}) end
    s:AddMappingContext(imc, prio, {})
    return nil
end

local function bind()
    local imc = StaticFindObject(IMC)
    if not util.valid(imc) then return "no " .. IMC end
    local now = read(imc)
    -- The game maps no pad key, so every Gamepad_ row is ours (the context outlives a world; a reloaded mod or
    -- a changed binding left some): the ones the current bindings still want count as added, the rest go out.
    local kb, pad_rows = {}, {}
    for _, m in ipairs(now) do
        if tostring(m.key):find("^Gamepad_") then pad_rows[#pad_rows + 1] = m else kb[#kb + 1] = m end
    end
    local want = {}
    for _, p in ipairs(gamepad.plan(kb)) do want[(p.name or tostring(p.action)) .. "|" .. p.pad] = true end
    added = {}
    local keep, dropped = {}, 0
    for _, m in ipairs(pad_rows) do
        if want[(m.name or tostring(m.action)) .. "|" .. m.key] then
            added[#added + 1] = { action = m.action, name = m.name, pad = m.key }
            keep[#keep + 1] = m
        else
            dropped = dropped + 1
            pcall(function() imc:UnmapKey(m.action, { KeyName = FName(m.key) }) end)
        end
    end
    if dropped > 0 then log.info("gamepad: " .. dropped .. " old pad key(s) taken out") end
    for _, m in ipairs(keep) do kb[#kb + 1] = m end
    local pairs_ = gamepad.plan(kb)
    for _, p in ipairs(pairs_) do
        local ok, e = pcall(function() imc:MapKey(p.action, { KeyName = FName(p.pad) }) end)
        if ok then added[#added + 1] = p else log.warn("gamepad: " .. tostring(p.name) .. " " .. p.pad .. ": " .. tostring(e)) end
    end
    level = "game"
    local err = refresh(imc)
    log.info(string.format("gamepad: %d pad key(s) added, %d in total%s", #pairs_, #added, err and (" - " .. err) or ""))
    return err
end

local function unbind()
    if #added == 0 then return end   -- off from the start: nothing of ours in the context
    local imc = StaticFindObject(IMC)
    if not util.valid(imc) then added = {}; return end
    for _, p in ipairs(added) do
        if not p.out then
            pcall(function() if util.valid(p.action) then imc:UnmapKey(p.action, { KeyName = FName(p.pad) }) end end)
        end
    end
    log.info("gamepad: " .. #added .. " pad key(s) taken out")
    added = {}
    level = "game"
    refresh(imc)
end

local KEY = {}
local function keys()
    if KEY.rx then return KEY end
    KEY.rx = { KeyName = FName("Gamepad_RightX") }
    KEY.ry = { KeyName = FName("Gamepad_RightY") }
    KEY.lx = { KeyName = FName("Gamepad_LeftX") }
    KEY.ly = { KeyName = FName("Gamepad_LeftY") }
    KEY.lt = { KeyName = FName("Gamepad_LeftTriggerAxis") }
    KEY.rt = { KeyName = FName("Gamepad_RightTriggerAxis") }
    KEY.pad = {}
    for _, p in ipairs(gamepad.PADS) do KEY.pad[p[1]] = { KeyName = FName(p[1]) } end
    return KEY
end

-- Is a pad button down. Read once per tick (padinv, the menu focus and the D-pad all ask; tick() clears it).
local frame_down = {}
local function down(pc, pad)
    local d = frame_down[pad]
    if d ~= nil then return d end
    d = false
    pcall(function() d = pc:IsInputKeyDown(keys().pad[pad]) == true end)
    if pad ~= nil then frame_down[pad] = d end
    return d
end

-- Which pad rows are in the context. "game": all. "menu" (cursor shown): only the walk stick and the buttons
-- that close menus (the menu = true actions: inventory, pause, handbook, map), so A/B/X/Y, the D-pad and the
-- shoulders drive the menu and the inventory
-- without also jumping, crouching or interacting behind it. "look" (in the world, looking at something you can
-- use): all but the option step's buttons (D-pad up/down unless rebound), which step its options instead (no
-- throwable behind it). "none" (SET waiting for a button on the bindings screen): no rows, so the press only binds.
-- Rows move only when their state changes; one refresh per change.
local STICK_PAD = {}
for _, set in pairs(STICKS) do
    for _, p in ipairs(set) do STICK_PAD[p[1]] = true end
end
local function set_level(want)
    level = want
    local imc = StaticFindObject(IMC)
    if not util.valid(imc) then return end
    -- (a menu action on a button the menu itself uses stays out, or one press did both: HANDBOOK on D-pad down
    -- moved the menu's focus and shut the handbook. The MENU directions work in every menu, the INV buttons only in
    -- the inventory ("inv"), so MAP on A still closes the map; audit 2026-11-03)
    local busy, keep = {}, {}
    for _, c in ipairs(gamepad.CONTROLS) do
        if c.ctx == "menu" and c.pad and (c.dir or want == "inv") then busy[c.pad] = true end
    end
    for _, a in ipairs(gamepad.ACTIONS) do
        if a.menu and a.pad and not busy[a.pad] then keep[a.pad] = true end
    end
    local in_menu = want == "menu" or want == "inv"
    local n = 0
    for _, p in ipairs(added) do
        local out = want == "none" or (in_menu and not keep[p.pad] and not STICK_PAD[p.pad])
            or (want == "look" and option_pads[p.pad] == true)
        if out ~= (p.out == true) and util.valid(p.action) then
            n = n + 1
            p.out = out
            pcall(function()
                if out then imc:UnmapKey(p.action, { KeyName = FName(p.pad) }) else imc:MapKey(p.action, { KeyName = FName(p.pad) }) end
            end)
        end
    end
    if n > 0 then refresh(imc) end
end

-- The visible buttons of the menus on screen (UMG Buttons in user widgets in the viewport), in tree order.
local BUTTON
local function menu_buttons()
    BUTTON = BUTTON or StaticFindObject("/Script/UMG.Button")
    local out = {}
    local function shown(w) local v = false; pcall(function() v = w:IsVisible() end); return v end
    local function walk(w, depth)
        if depth > 14 or #out >= 200 or not util.valid(w) or not shown(w) then return end
        local isb = false
        pcall(function() isb = w:IsA(BUTTON) end)
        if isb then out[#out + 1] = w end
        local n = 0
        pcall(function() n = w:GetChildrenCount() end)
        for i = 0, (n or 0) - 1 do
            local c
            pcall(function() c = w:GetChildAt(i) end)
            walk(c, depth + 1)
        end
        local root
        pcall(function() root = w.WidgetTree.RootWidget end)
        if root then walk(root, depth + 1) end
    end
    for _, w in ipairs(FindAllOf("UserWidget") or {}) do
        local inv = false
        pcall(function() inv = w:IsInViewport() end)
        if inv then walk(w, 0) end
    end
    return out
end

local menu = { open = false, buttons = nil, held = {} }
-- A MENU UP/DOWN/LEFT/RIGHT press in a menu that reached the game with no button focused (on the D-pad, Slate's
-- navigation eats it when one has): focus the menu's first button. Slate's own navigation stays on the D-pad and
-- left stick, A pressing: that is the engine's, not the mod's. A button that has focus keeps it (a rebound one
-- reaches the game every press).
local function focused(b)
    for _, w in ipairs(b) do
        local f = false
        pcall(function() f = w:HasKeyboardFocus() end)
        if f == true then return true end
    end
    return false
end
local function menu_tick(pc)
    local pressed = false
    for _, a in ipairs(gamepad.CONTROLS) do
        if a.dir then
            local d = a.pad ~= nil and down(pc, a.pad)
            if d and not menu.held[a.id] then pressed = true end
            menu.held[a.id] = d
        end
    end
    if not pressed then return end
    local b = menu_buttons()
    if focused(b) then return end
    local ok = b[1] and pcall(function() b[1]:SetKeyboardFocus() end)
    log.info(string.format("gamepad: menu focus -> %s (%d button(s))", ok and (util.fname(b[1]) or "?") or "none", #b))
end

-- Hotbar step on LB/RB (whatever buttons hotbar_back/next sit on): a fresh press calls Event_WeaponCycle.
local cycle_held = {}
local function hotbar_tick(pc)
    for _, a in ipairs(gamepad.ACTIONS) do
        if a.cycle ~= nil then
            local d = a.pad ~= nil and down(pc, a.pad)
            if d and not cycle_held[a.id] then
                local p = game.player()
                local ok, e = pcall(function() p:Event_WeaponCycle(a.cycle) end)
                if not ok then log.every("gamepad.cycle", 60, "gamepad: hotbar step failed - " .. tostring(e)) end
            end
            cycle_held[a.id] = d
        end
    end
end

-- The player's interaction helper while it has a target (CurrentTracActor: what the interact prompt is on), else nil.
local function looked_at()
    local h, a
    pcall(function() h = game.player().BP_JigHelperComp end)
    if not util.valid(h) then return nil end
    pcall(function() a = h.CurrentTracActor end)
    return util.valid(a) and h or nil
end
-- Option step (PROMPT OPTION UP/DOWN): a fresh press while there is a target calls CycleOptions, as one wheel
-- notch does.
local option_held = {}
local function options_tick(pc, helper)
    for _, a in ipairs(gamepad.CONTROLS) do
        if a.ctx == "look" and a.pad then
            -- nothing looked at: not read (2 calls a frame saved); counted as held, so a press already down when a
            -- target comes into view isn't taken as a fresh one
            local d = true
            if helper then d = down(pc, a.pad) end
            if d and not option_held[a.id] and helper then
                local ok, e = pcall(function() helper:CycleOptions(a.up) end)
                if not ok then log.every("gamepad.options", 60, "gamepad: option step failed - " .. tostring(e)) end
            end
            option_held[a.id] = d
        end
    end
end

-- Bindings screen: SET waits for the next pad press (6 s). Every pad button must be up first, so the A that
-- pressed SET doesn't bind itself. The game viewport takes focus so the press reaches the game, not the menu.
local capture = nil
local CAPTURE_SECS = 6.0
local ticking = false   -- init ran (gamepad.enabled = false in the config: no tick, so nothing would end a SET)
function gamepad.capture(id)
    -- (the controller off: its tick never counts the 6 s down, SET would wait forever and bind the first press
    -- after it's switched back on, wherever that is)
    if not by_id[id] or not ticking or not setting_on() then return false end
    capture = { id = id, left = CAPTURE_SECS, armed = false }
    pcall(function() StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetFocusToGameViewport() end)
    return true
end
function gamepad.capturing() return capture and capture.id or nil end
local function capture_tick(pc, dt)
    capture.left = capture.left - dt
    if capture.left <= 0 then log.info("gamepad: no button pressed for " .. capture.id); capture = nil; return end
    local hit
    for _, p in ipairs(gamepad.PADS) do
        if down(pc, p[1]) then hit = hit or p[1] end
    end
    if not capture.armed then capture.armed = hit == nil; return end
    if not hit then return end
    local id = capture.id
    capture = nil
    gamepad.set(id, hit)
end

-- The controller's yaw / pitch input scales as sizes (degrees per unit), read once a second; LOOK.scale when
-- unreadable or 0. The pitch scale is negative in this game; the sign stays with the game's own mouse path.
local scale_cache = { at = -1, yaw = nil, pitch = nil }
local clock = 0
local function size(v) v = tonumber(v); return v and v ~= 0 and math.abs(v) or gamepad.LOOK.scale end
function gamepad.scales(pc)
    if clock - scale_cache.at >= 1 or not scale_cache.yaw then
        scale_cache.at = clock
        local y, p
        pcall(function() y = pc:GetDeprecatedInputYawScale() end)
        pcall(function() p = pc:GetDeprecatedInputPitchScale() end)
        scale_cache.yaw, scale_cache.pitch = size(y), size(p)
    end
    return scale_cache.yaw, scale_cache.pitch
end

-- The look slows while AIM's button is held: a trigger past 0.3 of its travel (read as its axis), any other
-- button while down. AIM on no button: never.
local TRIGGER_AXIS = { Gamepad_LeftTrigger = "lt", Gamepad_RightTrigger = "rt" }
local function aiming(pc)
    local pad = by_id.aim.pad
    if pad == nil then return false end
    local axis = TRIGGER_AXIS[pad]
    if axis then return (tonumber(pc:GetInputAnalogKeyState(keys()[axis])) or 0) > 0.3 end
    return down(pc, pad)
end

-- pc: the valid controller, with no menu up (tick checks both)
local function look(pc, dt)
    local k, L, O = keys(), gamepad.LOOK, gamepad.OPT
    local x, y = pc:GetInputAnalogKeyState(O.swap and k.lx or k.rx), pc:GetInputAnalogKeyState(O.swap and k.ly or k.ry)
    local dx, dy = gamepad.stick(x, y, L.dz, L.expo)
    if dx == 0 and dy == 0 then return end
    local speed = aiming(pc) and L.aim or 1
    -- the game's own setting: its mouse look multiplies pitch by the player's InvertValue too; INVERT LOOK on top
    local inv = O.invert and -1 or 1
    pcall(function() local v = tonumber(game.player().InvertValue); if v and v ~= 0 then inv = inv * v end end)
    local ys, ps = gamepad.scales(pc)
    pc:AddYawInput(dx * L.yaw * speed * dt / ys)
    -- stick up looks up (kit 2026-10-31: the mouse path's sign looked down - user: "look up and look down are inverted")
    pc:AddPitchInput(inv * dy * L.pitch * speed * dt / ps)
end

local state = { world = nil, wait = 0, on = nil, check = 0, look_left = 0 }

-- No pad in use: the game's current input type (CommonUI's CommonInputSubsystem on the local player) is mouse and
-- keyboard. The per-frame reads below (cursor, look target, sticks, hotbar: ~7 engine calls a frame, 0.08-0.10 ms,
-- kit 2026-11-11) then wait; the type is asked twice a second instead. Any other answer, or none, keeps them on:
-- a pad must never go dead on a guess. (The game's own rows - walk, jump, buttons - are in its context either way;
-- what waits up to IDLE_ASK s is the camera stick, the hotbar step and the menu focus.)
-- (kit 2026-11-11: GetCurrentInputType answers 0 with keyboard/mouse; InputDeviceSubsystem's
-- GetMostRecentlyUsedHardwareDevice wants its struct as an out parameter through UE4SS and gave nothing back)
local KBM = 0                    -- ECommonInputType::MouseAndKeyboard
local IDLE_ASK, SUB_RETRY, AWAKE_S = 0.5, 30.0, 10.0
local dev = { sub = nil, ask = 0, find_at = 0, idle = false, said = nil, awake_until = 0 }
local function pad_idle(dt)
    dev.ask = dev.ask - dt
    if dev.ask > 0 then return dev.idle end
    dev.ask = IDLE_ASK
    if not util.valid(dev.sub) and clock >= dev.find_at then
        dev.find_at = clock + SUB_RETRY   -- (FindFirstOf walks every object: not again for a while when it isn't there)
        dev.sub = nil
        pcall(function() dev.sub = FindFirstOf("CommonInputSubsystem") end)
        if not util.valid(dev.sub) then dev.sub = nil end
    end
    local kind
    if dev.sub then pcall(function() kind = tonumber(dev.sub:GetCurrentInputType()) end) end
    local idle = kind == KBM
    if idle and clock < dev.awake_until then idle = false end
    if idle then
        -- (and the camera stick at rest: should a pad not count as "used" on this engine, it still wakes them, for
        -- AWAKE_S; down()'s per-frame answers are the tick's, which doesn't run while idle: cleared first)
        frame_down = {}
        local pc, k, sw, x, y = game.controller(), keys(), gamepad.OPT.swap, 0, 0
        if util.valid(pc) then
            pcall(function() x, y = pc:GetInputAnalogKeyState(sw and k.lx or k.rx), pc:GetInputAnalogKeyState(sw and k.ly or k.ry) end)
        end
        idle = math.abs(tonumber(x) or 0) < gamepad.LOOK.dz and math.abs(tonumber(y) or 0) < gamepad.LOOK.dz
        -- (the buttons the reads below drive - hotbar step, menu focus, option step - held: awake too)
        for _, list in ipairs({ gamepad.ACTIONS, gamepad.CONTROLS }) do
            for _, a in ipairs(list) do
                if idle and util.valid(pc) and a.pad and (a.cycle ~= nil or a.dir or a.ctx == "look") and down(pc, a.pad) then idle = false end
            end
        end
        if not idle then dev.awake_until = clock + AWAKE_S end
    end
    if kind ~= dev.said then
        dev.said = kind
        log.info("gamepad: last input device type " .. tostring(kind) .. (idle and " (keyboard/mouse: pad reads paused)" or " (pad reads on)"))
    end
    if idle and not dev.idle then padinv.leave() end
    dev.idle = idle
    return idle
end

local function tick(dt)
    clock = clock + dt
    state.check = state.check - dt
    if state.check <= 0 then
        state.check = 1.0
        local on = setting_on()
        if on ~= state.on then
            if state.on ~= nil then log.info("gamepad: " .. (on and "on" or "off")) end
            state.on = on
            if on then state.world, state.wait = nil, 0 else unbind() end
        end
        -- a new world: bind a second after it starts (the game puts its own context on first)
        local w = util.addr(game.world())
        if on and w and w ~= state.world then state.world, state.wait = w, 1.0 end
    end
    if not state.on then capture = nil; return end   -- (switched off during a SET: it ends)
    if state.wait > 0 then
        state.wait = state.wait - dt
        if state.wait <= 0 then
            -- no context or no input subsystem yet: say so (once a minute) and try again in 5 s
            util.safe(function()
                local err = bind()
                if err then state.wait = 5.0; log.every("gamepad.bind", 60, "gamepad: not bound yet - " .. err) end
            end, "gamepad.bind")
        end
        return
    end
    if not capture and pad_idle(dt) then return end   -- (SET waits for a pad press: never paused)
    frame_down = {}
    local pc = game.controller()
    if util.valid(pc) then
        local cursor = false
        pcall(function() cursor = pc.bShowMouseCursor end)
        cursor = cursor == true
        -- the handbook closed while SET waited: stop waiting (the pad rows stayed out and the next press bound
        -- silently, up to 6 s; audit 2026-11-02). Only once its cursor was seen during this capture.
        if capture then
            if cursor then capture.menu = true
            elseif capture.menu then log.info("gamepad: menu closed - no button set for " .. capture.id); capture = nil end
        end
        local helper = not capture and not cursor and looked_at() or nil
        if helper then state.look_left = LOOK_HOLD_S else state.look_left = math.max(0, state.look_left - dt) end
        local want = capture and "none"
            or (cursor and (padinv.on() and "inv" or "menu") or (state.look_left > 0 and "look" or "game"))
        if want ~= level then set_level(want) end
        if capture then
            padinv.leave()
            capture_tick(pc, dt)
        elseif cursor then
            if not padinv.tick(pc, dt, down) then menu_tick(pc) end
        else
            padinv.leave()
            menu.held = {}
            hotbar_tick(pc)
            options_tick(pc, helper)
        end
        if not cursor then look(pc, dt) end   -- (a menu up: the stick is the menu's)
    end
end

-- the context rows follow a changed binding at once (when bound)
local function rebind_live()
    if state.on and #added > 0 then util.safe(function() unbind(); bind() end, "gamepad.rebind") end
end
-- Bindings screen: an action onto a button (swap), saved and live at once when bound.
function gamepad.set(id, pad)
    if not gamepad.assign(id, pad) then return false end
    save_binds()
    log.info("gamepad: " .. id .. " -> " .. pad)
    rebind_live()
    return true
end
-- Bindings screen CLEAR: the action off its button, saved and live.
function gamepad.clear(id)
    if not gamepad.unassign(id) then return false end
    save_binds()
    log.info("gamepad: " .. id .. " -> none")
    rebind_live()
    return true
end
-- RESET TO DEFAULT: the default buttons, look speeds and switches
function gamepad.reset()
    for _, o in ipairs(gamepad.OPTIONS) do gamepad.OPT[o.key] = false end
    gamepad.reset_binds()
    gamepad.reset_sens()
    save_binds()
    log.info("gamepad: bindings, sensitivity and switches reset")
    rebind_live()
end
-- rows for the bindings screen: { id, label, button ("PRESS A BUTTON" while SET waits for it, "NONE" unbound) },
-- the buttons named for the pad picked in MY SETTINGS (XBOX: A, LB; PLAYSTATION: CROSS, L1). The actions that
-- start on a button, then the menu / inventory / option controls, then the rest of the game's actions.
function gamepad.binds_model()
    local out, style = {}, pad_style()
    local function row(a)
        out[#out + 1] = { id = a.id, label = a.label,
                          button = capture and capture.id == a.id and "PRESS A BUTTON" or gamepad.pad_name(a.pad, style) or "NONE" }
    end
    for _, a in ipairs(gamepad.ACTIONS) do if a.default then row(a) end end
    for _, a in ipairs(gamepad.CONTROLS) do row(a) end
    for _, a in ipairs(gamepad.ACTIONS) do if not a.default then row(a) end end
    return out
end

-- Switches: each as { id, label, on, text ("ON" / "OFF") }
function gamepad.opts_model()
    local out = {}
    for _, o in ipairs(gamepad.OPTIONS) do
        local on = gamepad.OPT[o.key] == true
        out[#out + 1] = { id = o.id, label = o.label, on = on, text = on and "ON" or "OFF" }
    end
    return out
end
-- A switch's button: flipped, saved and live (SWAP STICKS moves the walk rows to the other stick). Returns the
-- new value, nil for an unknown id.
function gamepad.toggle_opt(id)
    local o = opt_by_id[id]
    if not o then return nil end
    gamepad.OPT[o.key] = not gamepad.OPT[o.key]
    gamepad.rebuild()
    save_binds()
    log.info("gamepad: " .. id .. " " .. (gamepad.OPT[o.key] and "on" or "off"))
    if o.key == "swap" then rebind_live() end
    return gamepad.OPT[o.key]
end

-- Sliders: each sensitivity as { id, label, value (0..1 along the slider), text }
function gamepad.sens_model()
    local out = {}
    for _, s in ipairs(gamepad.SENS) do
        local v = gamepad.LOOK[s.key]
        local base = LOOK_DEFAULT[s.key] or v
        local shown = s.pct and math.floor(v * 100 + 0.5) or math.floor(v / base * 100 + 0.5)
        out[#out + 1] = { id = s.id, label = s.label, value = (v - s.min) / (s.max - s.min), text = shown .. "%" }
    end
    return out
end
-- A slider moved to f (0..1): LOOK takes the nearest step; saved when that changed it. Returns true then.
function gamepad.set_sens(id, f)
    local s = sens_by_id[id]
    f = tonumber(f)
    if not s or not f or f ~= f then return false end
    local v = snap(s, s.min + math.max(0, math.min(1, f)) * (s.max - s.min))
    if math.abs(v - gamepad.LOOK[s.key]) < s.step / 2 then return false end
    gamepad.LOOK[s.key] = v
    save_binds()
    return true
end
-- The - / + beside a slider: one step down (dir < 0) or up. Returns true when it moved.
function gamepad.step_sens(id, dir)
    local s = sens_by_id[id]
    if not s then return false end
    local v = snap(s, gamepad.LOOK[s.key] + (dir < 0 and -s.step or s.step))
    if math.abs(v - gamepad.LOOK[s.key]) < s.step / 2 then return false end
    gamepad.LOOK[s.key] = v
    save_binds()
    return true
end

function gamepad.init(cfg)
    local c = cfg and cfg.gamepad
    if type(c) == "table" then
        if c.enabled == false then return end
        for k, v in pairs(c.look or {}) do if gamepad.LOOK[k] ~= nil and type(v) == "number" then gamepad.LOOK[k] = v end end
    end
    for k, v in pairs(gamepad.LOOK) do LOOK_DEFAULT[k] = v end
    util.safe(load_binds, "gamepad.binds")
    game.on_tick(function(dt) util.safe(tick, "gamepad.tick", dt) end)
    ticking = true
end

-- dev checks (devtest eval): what's bound, and a fresh bind
function gamepad.status() return string.format("on=%s added=%d world=%s", tostring(state.on), #added, tostring(state.world)) end
gamepad.bind, gamepad.unbind = bind, unbind

return gamepad
