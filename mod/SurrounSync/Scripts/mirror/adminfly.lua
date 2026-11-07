-- Admin fly (user 2026-11-03: "keep the flight system for it and then add that too my character as a hotkey for a
-- quick admin fly but no jetpack"). F7 turns it on and off, only in the game whose Steam account is OWNER; there is no
-- item and no model. This is the mod's own Lua on each player's PC, so it keeps honest players out, not someone who
-- edits it.
--
-- Flight (adminfly.step is the whole model, no engine calls, so tools/test-sync.py flies it offline):
-- It flies like GTA V's jetpack (user 2026-11-02: "id prefer if it flew like gtav jetpack"): a craft that hovers on
-- its own, steered by tilting.
--  - F7 on lifts off at once. Landing ends the flight, F7 stays on: a jump held past ENGAGE_S (or a press while falling)
--    takes off again, Jump held on the ground as it lands stays up.
--  - Hands off it holds its height with a slow bob. Jump held climbs at CLIMB, Crouch held sinks at DESCEND.
--  - Move keys / left stick tilt the body toward them (TILT_MAX, eased at TILT_RATE) and the thrust follows the tilt,
--    along the camera's heading: starts lag a moment and build up to CRUISE, a turn swings the drift round. Let go and
--    the body tilts back against the drift and brakes itself to a stop.
--  - Sprint pressed fires a boost: the body tips hard forward and it surges to about BOOST_SPEED for up to BOOST_S
--    on a full charge. The charge refills over RECHARGE_S after a pause; a boost needs at least BOOST_MIN of it.
--  - Retro burn: falling fast with it on (flying or not), the ground within stopping distance brakes the fall to
--    SAFE_VZ by touchdown - no fall damage. F7 off in the air keeps this until the feet are down.
--  - Looks: the body shows the tilt, the camera trails and widens with speed.
-- F7 and not a Ctrl or Shift combination: those are the flight's own Crouch and Sprint.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")

local adminfly = {}

local OWNER = "76561199084190564"   -- SYMPLYSCK's SteamID64
local HOTKEY = "F7"
local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local KML = "/Script/Engine.Default__KismetMathLibrary"

local KEYS = {
    up = { "SpaceBar", "Gamepad_FaceButton_Bottom" },            -- the game's jump
    down = { "LeftControl", "Gamepad_FaceButton_Right" },        -- crouch
    boost = { "LeftShift", "Gamepad_LeftThumbstick" },           -- sprint
    fwd = { "W" }, back = { "S" }, left = { "A" }, right = { "D" },
}

-- the flight model (cm, s)
local CLIMB, DESCEND, VERT_ACCEL = 1000, 1300, 1600   -- Jump / Crouch held; cm/s2 toward the wanted vertical speed
local BOB_CM_S, BOB_HZ = 18, 0.35                     -- the hover's bob
local TILT_MAX = 24           -- degrees at a full move key
local TILT_RATE = 3.5         -- 1/s: the body eases toward the tilt wanted (the lag before the thrust builds)
local TILT_ACCEL = 1380       -- cm/s2 along the ground at TILT_MAX
local DRAG = 0.6              -- 1/s: full tilt settles at TILT_ACCEL / DRAG
local CRUISE = TILT_ACCEL / DRAG                      -- 2300 cm/s
local BRAKE_TILT, BRAKE_V = 12, 1500                  -- hands off: degrees tilted back against a drift this fast
local BOOST_ACCEL, BOOST_SPEED, BOOST_TILT = 2600, 4600, 34
local BOOST_S, RECHARGE_S, RECHARGE_DELAY, BOOST_MIN = 2.5, 6.0, 0.8, 0.3
local SAFE_VZ = 450           -- touchdown speed the retro burn keeps (a normal jump lands about this fast)
local RETRO_ACCEL, RETRO_MARGIN = 4800, 160
local ENGAGE_S = 0.12         -- a jump held this long in the air takes off (a tapped jump stays a jump)
local LIFT_S = 0.4            -- F7 on the ground: it climbs this long by itself, off the floor
-- looks
local LEAN_FWD_MAX, LEAN_BACK_MAX, LEAN_SIDE_MAX, LEAN_EASE = 32, 18, 24, 6.0
local TURN_EASE = 9.0         -- 1/s: the body's yaw follows the camera
local FOV_KICK, FLASH_FOV = 14, 6
local ARM_BOOST_CM, LAG_SPEED = 120, 12
local OWNER_CHECK_S = 5.0

local function clamp(x, lo, hi) return x < lo and lo or (x > hi and hi or x) end
-- full thrust up to TAPER of the cap, none at the cap (speed along the thrust): it settles there without a snap
local TAPER = 0.8
local function taper(along, cap) return clamp((cap - along) / (cap * (1 - TAPER)), 0, 1) end

-- One step of flight (no engine calls). st: { vx, vy, vz, tilt_f, tilt_r, charge, boost_t, recharge_wait, flash, boosts,
-- t }; inp: { up, down, kick (boost pressed this frame), f, r (move keys: forward, right, -1..1), fx, fy (the camera's
-- heading on the ground, unit) }. Returns boosting (true/false).
function adminfly.step(st, inp, dt)
    st.t = (st.t or 0) + dt
    st.charge = st.charge or 1
    -- the boost: a press fires a burst as long as the charge lasts; the charge refills after a pause
    if inp.kick and (st.boost_t or 0) <= 0 and st.charge >= BOOST_MIN then
        st.boost_t, st.flash, st.boosts = st.charge * BOOST_S, 1, (st.boosts or 0) + 1
    end
    local boosting = (st.boost_t or 0) > 0
    if boosting then
        st.boost_t = st.boost_t - dt
        st.charge = math.max(0, st.charge - dt / BOOST_S)
        st.recharge_wait = RECHARGE_DELAY
    else
        st.recharge_wait = (st.recharge_wait or 0) - dt
        if st.recharge_wait <= 0 then st.charge = math.min(1, st.charge + dt / RECHARGE_S) end
    end
    st.flash = math.max(0, (st.flash or 0) - dt * 3)
    local f, r = clamp(inp.f or 0, -1, 1), clamp(inp.r or 0, -1, 1)
    local m = math.sqrt(f * f + r * r)
    if m > 1 then f, r = f / m, r / m end
    local fx, fy = inp.fx or 1, inp.fy or 0
    local rx, ry = -fy, fx
    local fwd_v, side_v = st.vx * fx + st.vy * fy, st.vx * rx + st.vy * ry
    -- the tilt wanted: toward the keys; hands off, back against the drift (it brakes itself); a boost tips it forward
    local want_f = f ~= 0 and f * TILT_MAX or clamp(-fwd_v / BRAKE_V, -1, 1) * BRAKE_TILT
    local want_r = r ~= 0 and r * TILT_MAX or clamp(-side_v / BRAKE_V, -1, 1) * BRAKE_TILT
    if boosting then want_f = BOOST_TILT end
    local e = math.min(1, dt * TILT_RATE)
    st.tilt_f = (st.tilt_f or 0) + (want_f - (st.tilt_f or 0)) * e
    st.tilt_r = (st.tilt_r or 0) + (want_r - (st.tilt_r or 0)) * e
    -- vertical: hold the height (a slow bob), or climb / sink at a steady rate
    local want_vz = inp.up and CLIMB or (inp.down and -DESCEND or BOB_CM_S * math.sin(st.t * BOB_HZ * 2 * math.pi))
    if st.vz < want_vz then st.vz = math.min(st.vz + VERT_ACCEL * dt, want_vz)
    else st.vz = math.max(st.vz - VERT_ACCEL * dt, want_vz) end
    -- along the ground: the thrust follows the tilt, the boost surges along the heading, linear air drag
    local af, ar = TILT_ACCEL * st.tilt_f / TILT_MAX, TILT_ACCEL * st.tilt_r / TILT_MAX
    if boosting then af = af + BOOST_ACCEL * taper(fwd_v, BOOST_SPEED) end
    local keep = math.exp(-DRAG * dt)
    st.vx = (st.vx + (fx * af + rx * ar) * dt) * keep
    st.vy = (st.vy + (fy * af + ry * ar) * dt) * keep
    return boosting
end

-- The retro burn's new vertical speed: vz falling, ground_within(cm) true when ground is that close under the feet,
-- against: the pull it brakes against (cm/s2: the game's gravity not flying; flying, our hover helps and Crouch is cut).
-- The last frames before the ground take it straight to SAFE_VZ, whatever was left.
function adminfly.retro(vz, dt, ground_within, against)
    if vz >= -SAFE_VZ then return vz end
    local net = math.max(RETRO_ACCEL - (against or 0), RETRO_ACCEL * 0.25)
    local stop = (vz * vz - SAFE_VZ * SAFE_VZ) / (2 * net) + RETRO_MARGIN - vz * dt * 2
    if not ground_within(stop) then return vz end
    if ground_within(-vz * dt * 2 + 30) then return -SAFE_VZ end
    return math.min(vz + RETRO_ACCEL * dt, -SAFE_VZ)
end

-- ---------------------------------------------------------------------------------------------------------------
-- who is playing: the bridge's Steam account (mirror_lobby.txt "me"), else the account Steam logged in last

local me, me_from, me_at, as_id = nil, nil, -100, nil

local function vdf_user(path)
    local f = path and io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a") or ""
    f:close()
    for id, body in s:gmatch('"(%d+)"%s*(%b{})') do
        if body:find('"MostRecent"%s*"1"') then return id end
    end
    return nil
end

local function steam_user()
    local ok, link = pcall(require, "mirror.link")
    if ok and type(link) == "table" and link.lobby then
        local l
        pcall(function() l = link.lobby() end)
        if l and l.id and l.id ~= "" then return l.id, "bridge" end
    end
    local roots = { (os.getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)") .. "\\Steam" }
    local src = debug.getinfo(1, "S").source or ""
    local lib = src:match("^@?(.-)[\\/][Ss]team[Aa]pps[\\/]")
    if lib then roots[#roots + 1] = lib end
    for _, r in ipairs(roots) do
        local id = vdf_user(r .. "\\config\\loginusers.vdf")
        if id then return id, "loginusers.vdf" end
    end
    return nil, "unknown"
end

local function owner(now)
    if as_id then return as_id == OWNER end
    if now - me_at >= OWNER_CHECK_S then
        me_at = now
        local id, from = steam_user()
        if id ~= me then
            me, me_from = id, from
            log.info("adminfly: " .. (id == OWNER and "the owner's game" or "not the owner's game") ..
                " (Steam account from " .. tostring(from) .. ")")
        end
    end
    return me == OWNER
end

-- ---------------------------------------------------------------------------------------------------------------
-- my flight (main.lua's copy, every frame)

local st = { on = false, vx = 0, vy = 0, vz = 0 }
local stats = { lit = 0, landed = 0, retro = 0, boosts = 0, toggled = 0 }
local was = {}                 -- key states last frame
local air_held, lift_t = 0, 0
local owner_in = 0
local is_owner, armed, want_toggle, catching = false, false, false, false   -- catching: F7 off in the air, until the feet are down
local saved = nil              -- what flying changed: { actor, gravity, arm, lag, lag_max, fov, mesh_rot, mesh_at }
local look = { lean_f = 0, lean_r = 0, yaw = nil }
local now = 0

local function any(list)
    for _, k in ipairs(list) do if game.key_down(k) then return true end end
    return false
end

local function pressed(name, down)
    local edge = down and not was[name]
    was[name] = down
    return edge
end

local function falling(p)
    local f = false
    pcall(function() f = p.CharacterMovement:IsFalling() == true end)
    return f
end

local function swimming(p)
    local s = false
    pcall(function() s = p.SwimmingComponent["IsSwimming?"] == true end)
    return s
end

local function dead(p)
    local d = false
    pcall(function() d = p["PlayerDead?"] == true end)
    return d
end

local function gliding()
    local ok, glider = pcall(require, "mirror.glider")
    return ok and type(glider) == "table" and glider.active and glider.active() == true
end

local function analog(name)
    local v = 0
    pcall(function() v = game.controller():GetInputAnalogKeyState({ KeyName = FName(name) }) or 0 end)
    return tonumber(v) or 0
end

local function feet_clear(p, cm)
    local ksl, l, half = util.cdo(KSL), nil, 90
    pcall(function() l = util.vec(p:K2_GetActorLocation()) end)
    pcall(function() half = p.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    if not (ksl and l) then return true end
    local hit = false
    pcall(function()
        hit = ksl:LineTraceSingle(p, l, { X = l.X, Y = l.Y, Z = l.Z - half - cm }, 0, false, {}, 0, {}, true,
            { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0) == true
    end)
    return not hit
end

-- the body shows the craft's tilt
local function lean(p, dt)
    if not (saved and saved.mesh_rot) then return end
    local e = math.min(1, dt * LEAN_EASE)
    local want_f = clamp(st.tilt_f or 0, -LEAN_BACK_MAX, LEAN_FWD_MAX)
    local want_r = clamp(st.tilt_r or 0, -LEAN_SIDE_MAX, LEAN_SIDE_MAX)
    look.lean_f = look.lean_f + (want_f - look.lean_f) * e
    look.lean_r = look.lean_r + (want_r - look.lean_r) * e
    local rot
    pcall(function()
        rot = util.cdo(KML):ComposeRotators(saved.mesh_rot, { Pitch = -look.lean_f, Yaw = 0, Roll = look.lean_r })
    end)
    if not rot then return end
    -- tilted about the capsule's middle, not the feet: the feet swing back as the body leans forward
    local h, f, r = -saved.mesh_at.Z, math.rad(look.lean_f), math.rad(look.lean_r)
    local at = { X = saved.mesh_at.X - h * math.sin(f), Y = saved.mesh_at.Y - h * math.sin(r),
                 Z = -h * math.cos(f) * math.cos(r) }
    pcall(function()
        p.Mesh:K2_SetRelativeLocationAndRotation(at, { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll }, false, {}, true)
    end)
end

local function light(p)
    local v = { X = 0, Y = 0, Z = 0 }
    pcall(function() v = util.vec(p.CharacterMovement.Velocity) end)
    st.on, st.vx, st.vy, st.vz = true, v.X, v.Y, v.Z
    st.tilt_f, st.tilt_r, st.boost_t = 0, 0, 0
    saved = { actor = p }
    pcall(function() saved.gravity = p.CharacterMovement.GravityScale; p.CharacterMovement.GravityScale = 0 end)
    pcall(function()
        local arm = p.SpringArm
        saved.arm, saved.lag, saved.lag_max = arm.TargetArmLength, arm.CameraLagSpeed, arm.CameraLagMaxDistance
        arm.CameraLagSpeed = LAG_SPEED
    end)
    pcall(function() saved.fov = p.Camera.FieldOfView end)
    pcall(function()
        local r, l = p.Mesh.RelativeRotation, p.Mesh.RelativeLocation
        saved.mesh_rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
        saved.mesh_at = { X = l.X, Y = l.Y, Z = l.Z }
    end)
    look.lean_f, look.lean_r, look.yaw = 0, 0, nil
    stats.lit = stats.lit + 1
    log.info(string.format("adminfly: flying (%d cm/s up)", math.floor(v.Z)))
end

local function douse(why)
    if not st.on then return end
    st.on, lift_t = false, 0
    local p = saved and saved.actor
    if util.valid(p) then
        if saved.gravity then pcall(function() p.CharacterMovement.GravityScale = saved.gravity end) end
        if saved.arm then
            pcall(function()
                local arm = p.SpringArm
                arm.TargetArmLength, arm.CameraLagSpeed, arm.CameraLagMaxDistance = saved.arm, saved.lag, saved.lag_max
            end)
        end
        if saved.fov then pcall(function() p.Camera.FieldOfView = saved.fov end) end
        if saved.mesh_rot then
            pcall(function() p.Mesh:K2_SetRelativeLocationAndRotation(saved.mesh_at, saved.mesh_rot, false, {}, true) end)
        end
    end
    saved = nil
    log.info("adminfly: out (" .. why .. ")")
end

local function inputs()
    local up, down, boost = any(KEYS.up), any(KEYS.down), any(KEYS.boost)
    local f = (any(KEYS.fwd) and 1 or 0) - (any(KEYS.back) and 1 or 0) + analog("Gamepad_LeftY")
    local r = (any(KEYS.right) and 1 or 0) - (any(KEYS.left) and 1 or 0) + analog("Gamepad_LeftX")
    local yaw = 0
    pcall(function() yaw = game.controller():GetControlRotation().Yaw end)
    local py = math.rad(yaw)
    return { up = up, down = down, kick = pressed("boost", boost), f = f, r = r, yaw = yaw,
             fx = math.cos(py), fy = math.sin(py) }
end

local function fly(p, dt)
    local v
    pcall(function() v = util.vec(p.CharacterMovement.Velocity) end)
    if v then st.vx, st.vy, st.vz = v.X, v.Y, v.Z end   -- (walls and ceilings took their part)
    local inp = inputs()
    if lift_t > 0 then lift_t = lift_t - dt; inp.up = true end
    if st.retro_on then inp.down = false end   -- (the ground is close: the descent thrust gives way to the burn)
    local boosts_before = st.boosts or 0
    local boosting = adminfly.step(st, inp, dt)
    if (st.boosts or 0) > boosts_before then stats.boosts = stats.boosts + 1 end
    st.retro_on = false
    if not inp.up and st.vz < -SAFE_VZ then
        local vz = adminfly.retro(st.vz, dt, function(cm) return not feet_clear(p, cm) end, 0)
        if vz ~= st.vz then st.vz = vz; st.retro_on = true end
    end
    pcall(function() p.CharacterMovement.Velocity = { X = st.vx, Y = st.vy, Z = st.vz } end)
    -- the body faces where the camera looks, tilted as the craft is
    look.yaw = look.yaw or inp.yaw
    look.yaw = look.yaw + ((inp.yaw - look.yaw + 540) % 360 - 180) * math.min(1, dt * TURN_EASE)
    pcall(function() p:K2_SetActorRotation({ Pitch = 0, Yaw = look.yaw, Roll = 0 }, false) end)
    lean(p, dt)
    -- the camera trails and widens with speed
    local e = math.min(1, dt * 4)
    local speed = math.sqrt(st.vx * st.vx + st.vy * st.vy + st.vz * st.vz)
    if saved.fov then
        pcall(function()
            local cam = p.Camera
            local want = saved.fov + FOV_KICK * clamp((speed - CRUISE) / (BOOST_SPEED - CRUISE), 0, 1) + FLASH_FOV * (st.flash or 0)
            cam.FieldOfView = cam.FieldOfView + (want - cam.FieldOfView) * e
        end)
    end
    if saved.arm then
        pcall(function()
            local arm = p.SpringArm
            local want = saved.arm + (boosting and ARM_BOOST_CM or 0)
            arm.TargetArmLength = arm.TargetArmLength + (want - arm.TargetArmLength) * e
        end)
    end
end

-- the retro burn catches a fall even when not flying
local function catch_fall(p, dt)
    local v
    pcall(function() v = util.vec(p.CharacterMovement.Velocity) end)
    if v and v.Z < -SAFE_VZ then
        local g = 1.75
        pcall(function() g = p.CharacterMovement.GravityScale end)
        local vz = adminfly.retro(v.Z, dt, function(cm) return not feet_clear(p, cm) end, 980 * (tonumber(g) or 1.75))
        if vz ~= v.Z then
            if not st.retro_on then stats.retro = stats.retro + 1; st.retro_on = true end
            pcall(function() p.CharacterMovement.Velocity = { X = v.X, Y = v.Y, Z = vz } end)
        end
    else
        st.retro_on = false
    end
end

-- F7: on lifts off at once (unless dead, swimming or under the hang glider); off drops out of the air, the fall caught
local function toggle(p)
    armed = not armed
    stats.toggled = stats.toggled + 1
    log.info("adminfly: " .. (armed and "on" or "off"))
    pcall(function() require("mirror.notify").show(armed and "Admin fly on." or "Admin fly off.", "info") end)
    air_held = 0
    if not armed then
        catching = falling(p)
        douse("off")
        return
    end
    catching = false
    if dead(p) or swimming(p) or gliding() then return end
    light(p)
    if not falling(p) then
        lift_t = LIFT_S
        pcall(function() p.CharacterMovement:SetMovementMode(3, 0) end)
    end
end

local function own_tick(dt)
    now = now + dt
    local p = game.player()
    if not util.valid(p) then return end
    if saved and not util.same(saved.actor, p) then douse("a new character") end
    owner_in = owner_in - dt
    if owner_in <= 0 then owner_in = OWNER_CHECK_S; is_owner = owner(now) end
    if want_toggle then
        want_toggle = false
        if owner(now) then is_owner = true; toggle(p) end
    end
    -- someone else's game: no keys, no flight
    if not is_owner then
        if armed then armed = false; douse("not the owner") end
        return
    end
    local air = falling(p)
    if not armed then
        if catching then
            if air and not gliding() then catch_fall(p, dt) else catching = false end
        end
        return
    end
    local up = any(KEYS.up)
    local up_edge = pressed("up", up)
    if dead(p) then douse("died"); return end
    if swimming(p) then douse("in the water"); return end
    if gliding() then douse("the hang glider opened"); air_held = 0; return end
    if st.on then
        if not air then
            if up or lift_t > 0 then
                pcall(function() p.CharacterMovement:SetMovementMode(3, 0) end)   -- (held on the ground: lift off again)
            else
                stats.landed = stats.landed + 1
                douse("landed"); return
            end
        end
        fly(p, dt)
        return
    end
    -- not flying: a jump held in the air, or a press while falling, takes off
    if air and up then
        air_held = air_held + dt
        if up_edge or air_held >= ENGAGE_S then air_held = 0; light(p); fly(p, dt); return end
    else
        air_held = 0
    end
    if air then catch_fall(p, dt) end
end

local function forget()
    if st.on and saved then saved.mesh_rot = nil; douse("world reset") end
    armed, catching, want_toggle, air_held, lift_t = false, false, false, 0, 0
end

function adminfly.status()
    return string.format("adminfly: %s%s, flights %d, landed %d, retro %d, boosts %d, boost charge %d%%",
        is_owner and "owner" or "not the owner", st.on and ", FLYING" or (armed and ", on" or ""),
        stats.lit, stats.landed, stats.retro, stats.boosts, math.floor((st.charge or 1) * 100))
end

-- glider.lua: no glider while it's flying (it would save the flight's zero gravity as the game's own)
function adminfly.lit() return st.on == true end

function adminfly.key_toggle() want_toggle = true end   -- (also /fly, chatcmd.lua)

function adminfly.init(c)
    if c and c.adminfly == false then log.info("adminfly: off"); return end
    game.on_world_reset(forget)
    game.on_tick(function(dt) util.safe(own_tick, "adminfly", dt) end)
    game.keybind(HOTKEY, nil, adminfly.key_toggle)
    log.info("adminfly: ready")
end

adminfly.OWNER = OWNER
adminfly._state, adminfly._stats = st, stats
-- (dronegrant.lua: the drone's permissions tab; the tick's own clock, as own_tick reads it: os.clock here moved
-- me_at onto another clock and held off own_tick's re-read; audit 2026-11-03)
adminfly.is_owner = function() return owner(now) end
adminfly._as = function(id) as_id = id; owner_in = 0 end   -- (tests and the kit: play as this Steam account)
adminfly._vdf_user = vdf_user
adminfly._consts = { CLIMB = CLIMB, DESCEND = DESCEND, TILT_MAX = TILT_MAX, CRUISE = CRUISE, BOOST_SPEED = BOOST_SPEED,
    BOOST_S = BOOST_S, RECHARGE_S = RECHARGE_S, RECHARGE_DELAY = RECHARGE_DELAY, BOOST_MIN = BOOST_MIN, SAFE_VZ = SAFE_VZ,
    ENGAGE_S = ENGAGE_S, RETRO_ACCEL = RETRO_ACCEL, LIFT_S = LIFT_S }

return adminfly
