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
-- Each action's button can be changed (CONTROLLER -> BINDINGS, saved in mirror_pad_binds.txt).

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local link = require("mirror.link")
local padinv = require("mirror.padinv")

local gamepad = {}

local IMC = "/Game/Input/IMC_General.IMC_General"
local BINDS_FILE = "\\mirror_pad_binds.txt"

-- The buttons an action can sit on, in the bindings screen's words.
gamepad.PADS = {
    { "Gamepad_FaceButton_Bottom", "A" }, { "Gamepad_FaceButton_Right", "B" },
    { "Gamepad_FaceButton_Left", "X" }, { "Gamepad_FaceButton_Top", "Y" },
    { "Gamepad_LeftShoulder", "LB" }, { "Gamepad_RightShoulder", "RB" },
    { "Gamepad_LeftTrigger", "LT" }, { "Gamepad_RightTrigger", "RT" },
    { "Gamepad_LeftThumbstick", "L3" }, { "Gamepad_RightThumbstick", "R3" },
    { "Gamepad_DPad_Up", "D-PAD UP" }, { "Gamepad_DPad_Down", "D-PAD DOWN" },
    { "Gamepad_DPad_Left", "D-PAD LEFT" }, { "Gamepad_DPad_Right", "D-PAD RIGHT" },
    { "Gamepad_Special_Left", "VIEW" }, { "Gamepad_Special_Right", "MENU" },
}
local PAD_NAME = {}
for _, p in ipairs(gamepad.PADS) do PAD_NAME[p[1]] = p[2] end
local DPAD = { Gamepad_DPad_Up = true, Gamepad_DPad_Down = true, Gamepad_DPad_Left = true, Gamepad_DPad_Right = true }
-- D-pad up/down while looking at something you can use (a bed, a crate): the mouse wheel's option step. The game
-- has it on plain key events (BP_PlayerCharacter MouseScrollUp/Down -> BP_JigHelperComp.CycleOptions(true = up,
-- false = down)), not on an Enhanced Input action, so no context row can copy it. User 2026-10-31: "when hovering
-- over a bed or a crate you cant use those controlls so make d pad work".
local OPTION_PAD = { Gamepad_DPad_Up = true, Gamepad_DPad_Down = true }
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
    { id = "inventory", label = "INVENTORY", pad = "Gamepad_Special_Left", keys = { "Tab" } },
    { id = "pause", label = "PAUSE MENU", pad = "Gamepad_Special_Right", keys = { "Escape" } },
}
local by_id = {}
for _, a in ipairs(gamepad.ACTIONS) do a.default = a.pad; by_id[a.id] = a end

-- the left stick walks (not rebindable)
local STICK = {
    { "Gamepad_LeftStick_Up", "W" }, { "Gamepad_LeftStick_Down", "S" },
    { "Gamepad_LeftStick_Left", "A" }, { "Gamepad_LeftStick_Right", "D" },
}

-- { pad key, the keyboard/mouse key it copies, skip = { action name = true } }: the stick plus each action's keys
-- on its current button
gamepad.MIRROR = {}
function gamepad.rebuild()
    local m = {}
    for _, p in ipairs(STICK) do m[#m + 1] = p end
    for _, a in ipairs(gamepad.ACTIONS) do
        for _, k in ipairs(a.keys or {}) do m[#m + 1] = { a.pad, k, skip = a.skip } end
    end
    gamepad.MIRROR = m
end
gamepad.rebuild()

-- Saved bindings: "<id> <pad key>" lines; unknown ids/buttons are skipped.
function gamepad.parse_binds(s)
    local out = {}
    for id, pad in tostring(s or ""):gmatch("([%w_]+)%s+([%w_]+)") do
        if by_id[id] and PAD_NAME[pad] then out[id] = pad end
    end
    return out
end
local function binds_path()
    local d = link.dir and link.dir()
    return d and (d .. BINDS_FILE)
end
local function load_binds()
    for _, a in ipairs(gamepad.ACTIONS) do a.pad = a.default end
    local path = binds_path()
    local f = path and io.open(path, "rb")
    if not f then gamepad.rebuild(); return end
    local s = f:read("*a") or ""
    f:close()
    -- saved choices first (the first claim on a button wins), then defaults, then any free button: never one
    -- button on two actions, even from a hand-edited file
    local want, used, left = gamepad.parse_binds(s), {}, {}
    for _, a in ipairs(gamepad.ACTIONS) do
        local p = want[a.id]
        if p and not used[p] then a.pad = p; used[p] = true else left[#left + 1] = a end
    end
    local rest = {}
    for _, a in ipairs(left) do
        if not used[a.default] then a.pad = a.default; used[a.default] = true else rest[#rest + 1] = a end
    end
    for _, a in ipairs(rest) do
        for _, p in ipairs(gamepad.PADS) do
            if not used[p[1]] then a.pad = p[1]; used[p[1]] = true; break end
        end
    end
    gamepad.rebuild()
end
local function save_binds()
    local path = binds_path()
    local f = path and io.open(path, "wb")
    if not f then return false end
    for _, a in ipairs(gamepad.ACTIONS) do f:write(a.id, " ", a.pad, "\n") end
    f:close()
    return true
end

-- Puts an action on a button. The action already there takes this one's old button (a swap), so no button
-- does two things. Returns true when something changed.
function gamepad.assign(id, pad)
    local a = by_id[id]
    if not a or not PAD_NAME[pad] or a.pad == pad then return false end
    for _, o in ipairs(gamepad.ACTIONS) do
        if o ~= a and o.pad == pad then o.pad = a.pad end
    end
    a.pad = pad
    gamepad.rebuild()
    return true
end
function gamepad.reset_binds()
    for _, a in ipairs(gamepad.ACTIONS) do a.pad = a.default end
    gamepad.rebuild()
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
local level = "game"   -- which rows of `added` are in the context: "game" all, "menu" some, "none" none

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
    KEY.lt = { KeyName = FName("Gamepad_LeftTriggerAxis") }
    KEY.pad = {}
    for _, p in ipairs(gamepad.PADS) do KEY.pad[p[1]] = { KeyName = FName(p[1]) } end
    return KEY
end

local function down(pc, pad)
    local d = false
    pcall(function() d = pc:IsInputKeyDown(keys().pad[pad]) end)
    return d == true
end

-- Which pad rows are in the context. "game": all. "menu" (cursor shown): only the left stick and the buttons
-- that close menus (inventory, pause), so A/B/X/Y, the D-pad and the shoulders drive the menu and the inventory
-- without also jumping, crouching or interacting behind it. "look" (in the world, looking at something you can
-- use): all but D-pad up/down, which step its options instead (no throwable behind it). "none" (SET waiting for a
-- button on the bindings screen): no rows, so the press only binds. Rows move only when their state changes; one
-- refresh per change.
local STICK_PAD = {}
for _, p in ipairs(STICK) do STICK_PAD[p[1]] = true end
local function set_level(want)
    level = want
    local imc = StaticFindObject(IMC)
    if not util.valid(imc) then return end
    local keep = {}
    for _, a in ipairs(gamepad.ACTIONS) do
        if a.id == "inventory" or a.id == "pause" then keep[a.pad] = true end
    end
    local n = 0
    for _, p in ipairs(added) do
        local out = want == "none" or (want == "menu" and not keep[p.pad] and not STICK_PAD[p.pad])
            or (want == "look" and OPTION_PAD[p.pad] == true)
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
-- A D-pad press in a menu that reached the game (so no button has focus - Slate's navigation eats it when one
-- has): focus the menu's first button.
local function menu_tick(pc)
    local pressed = false
    for pad in pairs(DPAD) do
        local d = down(pc, pad)
        if d and not menu.held[pad] then pressed = true end
        menu.held[pad] = d
    end
    if not pressed then return end
    local b = menu_buttons()
    local ok = b[1] and pcall(function() b[1]:SetKeyboardFocus() end)
    log.info(string.format("gamepad: menu focus -> %s (%d button(s))", ok and (util.fname(b[1]) or "?") or "none", #b))
end

-- Hotbar step on LB/RB (whatever buttons hotbar_back/next sit on): a fresh press calls Event_WeaponCycle.
local cycle_held = {}
local function hotbar_tick(pc)
    for _, a in ipairs(gamepad.ACTIONS) do
        if a.cycle ~= nil then
            local d = down(pc, a.pad)
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
-- Option step on D-pad up/down: a fresh press while there is a target calls CycleOptions, as one wheel notch does.
local option_held = {}
local function options_tick(pc, helper)
    for pad in pairs(OPTION_PAD) do
        local d = down(pc, pad)
        if d and not option_held[pad] and helper then
            local ok, e = pcall(function() helper:CycleOptions(pad == "Gamepad_DPad_Up") end)
            if not ok then log.every("gamepad.options", 60, "gamepad: option step failed - " .. tostring(e)) end
        end
        option_held[pad] = d
    end
end

-- Bindings screen: SET waits for the next pad press (6 s). Every pad button must be up first, so the A that
-- pressed SET doesn't bind itself. The game viewport takes focus so the press reaches the game, not the menu.
local capture = nil
local CAPTURE_SECS = 6.0
function gamepad.capture(id)
    if not by_id[id] then return false end
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

local function look(dt)
    local pc = game.controller()
    if not util.valid(pc) then return end
    local cursor = false
    pcall(function() cursor = pc.bShowMouseCursor end)
    if cursor then return end   -- a menu is up
    local k, L = keys(), gamepad.LOOK
    local x, y = pc:GetInputAnalogKeyState(k.rx), pc:GetInputAnalogKeyState(k.ry)
    local dx, dy = gamepad.stick(x, y, L.dz, L.expo)
    if dx == 0 and dy == 0 then return end
    local speed = (tonumber(pc:GetInputAnalogKeyState(k.lt)) or 0) > 0.3 and L.aim or 1
    -- the game's own setting: its mouse look multiplies pitch by the player's InvertValue too
    local inv = 1
    pcall(function() local v = tonumber(game.player().InvertValue); if v and v ~= 0 then inv = v end end)
    local ys, ps = gamepad.scales(pc)
    pc:AddYawInput(dx * L.yaw * speed * dt / ys)
    -- stick up looks up (kit 2026-10-31: the mouse path's sign looked down - user: "look up and look down are inverted")
    pc:AddPitchInput(inv * dy * L.pitch * speed * dt / ps)
end

local state = { world = nil, wait = 0, on = nil, check = 0, look_left = 0 }

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
    if not state.on then return end
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
    local pc = game.controller()
    if util.valid(pc) then
        local cursor = false
        pcall(function() cursor = pc.bShowMouseCursor end)
        cursor = cursor == true
        local helper = not capture and not cursor and looked_at() or nil
        if helper then state.look_left = LOOK_HOLD_S else state.look_left = math.max(0, state.look_left - dt) end
        local want = capture and "none" or (cursor and "menu" or (state.look_left > 0 and "look" or "game"))
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
    end
    look(dt)
end

-- Bindings screen: an action onto a button (swap), saved and live at once when bound.
function gamepad.set(id, pad)
    if not gamepad.assign(id, pad) then return false end
    save_binds()
    log.info("gamepad: " .. id .. " -> " .. pad)
    if state.on and #added > 0 then util.safe(function() unbind(); bind() end, "gamepad.rebind") end
    return true
end
function gamepad.reset()
    gamepad.reset_binds()
    save_binds()
    log.info("gamepad: bindings reset")
    if state.on and #added > 0 then util.safe(function() unbind(); bind() end, "gamepad.rebind") end
end
-- rows for the bindings screen: { id, label, button ("..." while SET waits for it) }
function gamepad.binds_model()
    local out = {}
    for _, a in ipairs(gamepad.ACTIONS) do
        out[#out + 1] = { id = a.id, label = a.label, button = capture and capture.id == a.id and "PRESS A BUTTON" or PAD_NAME[a.pad] }
    end
    return out
end

function gamepad.init(cfg)
    local c = cfg and cfg.gamepad
    if type(c) == "table" then
        if c.enabled == false then return end
        for k, v in pairs(c.look or {}) do if gamepad.LOOK[k] ~= nil and type(v) == "number" then gamepad.LOOK[k] = v end end
    end
    util.safe(load_binds, "gamepad.binds")
    game.on_tick(function(dt) util.safe(tick, "gamepad.tick", dt) end)
end

-- dev checks (devtest eval): what's bound, and a fresh bind
function gamepad.status() return string.format("on=%s added=%d world=%s", tostring(state.on), #added, tostring(state.world)) end
gamepad.bind, gamepad.unbind = bind, unbind

return gamepad
