-- Hang glider (user 2026-11-02: "make it so players can use the glider from high places to glide down", "build the
-- player character holding on to the glider and then also make the glider work"). Falling with at least MIN_DROP_CM
-- of air under them, a player who carries a Hang Glider (glideritem.lua, made at the crafting workbench) presses
-- Jump and the glider opens: they hang under it face down (the character mesh
-- turned PRONE_DEG forward, the glider model attached above), sink slowly and fly where the camera looks - looking down
-- dives (faster, sinks more), looking up flares (slower, sinks less). Jump again, landing, water or death closes it.
-- The model is SM_Glider from SurrounSyncGlider.pak (Paks\LogicMods, tools/glider); without it the glide still works,
-- only unseen. Every player can glide, alone too: the glide is the player's own movement (the ghost's comes with
-- the pose), so only "gliding or not" goes to the other players, who show the glider and the pose on its ghost.
-- One copy of this file per other player (peers.lua, mates too): each sends my state on its link and shows its
-- player's glider on its ghost; my own glide (one per game) is in peers.shared("glider") and only main.lua's copy flies.
-- Kit-measured (build 26303910): Mesh relative (0, -90, 0) at Z -82 (= capsule half height), SpringArm 300 cm,
-- GravityScale 1.75; ComposeRotators(mesh, pitch -80) gives (0, -90, 80).

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local events = require("mirror.events")
local ghost = require("mirror.ghost")
local peers = require("mirror.peers")
local glideritem = require("mirror.glideritem")

local glider = {}

local MESH = "/Game/Mods/SurrounSyncGlider/SM_Glider.SM_Glider"
local SMA = "/Script/Engine.StaticMeshActor"
local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local KML = "/Script/Engine.Default__KismetMathLibrary"
local KEYS = { "SpaceBar", "Gamepad_FaceButton_Bottom" }   -- the game's jump
local MIN_DROP_CM = 500       -- air under the feet needed to open it (a jump on flat ground never does)
-- or, on a hill: the ground AHEAD_CM along the run is AHEAD_DROP_CM under the feet (user 2026-11-02: "its impossible
-- to use it on a hill ... you cant get high enough"; a jump on a slope never has 5 m straight down). On flat ground the
-- ground ahead is level, uphill the run is blocked, so neither opens it.
-- (300: a 20 degree hill opens it from 1 m up; a 10 degree one, flatter than the glide, doesn't)
local AHEAD_CM, AHEAD_DROP_CM = 600, 300
local CLOSE_AFTER_S = 0.4     -- a second Jump closes it, not the press that opened it
-- Jump arms it for ARM_S; it opens the moment there is MIN_DROP_CM of air under the feet (or the hill below, above), so
-- a tap at a cliff's edge opens it once over the edge (user 2026-11-02: "a double space click quickly will activate it,
-- i notice its hard to activate sometimes" - a press counted only with the drop already under). The jump itself arms
-- it too (user 2026-11-10: "make it so it's automatic instead of pressing space twice? It will deploy if your on a hill
-- or jump with nothing under you"): a Jump on the ground, carrying one, arms it for the jump it starts (the game lifts
-- off a frame or two later, within LIFTOFF_S); a jump on flat ground stays a jump, landing ends the arming.
local ARM_S = 1.5
local LIFTOFF_S = 0.3
-- A Jump in the air that opens nothing says why (user 2026-11-10: a friend "can't get the glider to open at all"): the
-- glider's files not loaded in this game, no Hang Glider carried, or (after a real drop since the press, so a double tap
-- on flat ground stays quiet) not enough air under. Each reason at most once per TELL_S.
local TOO_LOW_TOLD_CM = 300
local TELL_S = { not_loaded = 60, no_item = 300, too_low = 30 }
-- Flight is speed traded for height: looking down (a dive) gains speed and sinks faster, looking up (a flare) spends
-- the speed - above trim speed that becomes a short climb, below STALL_SPEED the glider sinks harder.
local SPEED = 1100            -- cm/s forward the glider settles at, level
local MIN_SPEED, MAX_SPEED = 450, 2300
local DIVE_ACCEL, FLARE_DECEL = 650, 400                   -- cm/s2 forward gained at a full dive, lost at a full flare
local DRAG = 0.55             -- 1/s: speed drifts back to SPEED (full dive settles near 2300, full flare at MIN_SPEED)
local SINK, DIVE_SINK = 220, 750                           -- cm/s down: level, added at a full dive
-- flaring turns the speed above SPEED into climb, cm/s up per cm/s (offline sim, full dive then full flare: up to
-- 5 m/s up for 1.3 s, about 4 m gained)
local ZOOM = 1.0
local STALL_SPEED, STALL_SINK = 650, 1.2                   -- below it, sink grows STALL_SINK cm/s per cm/s short
local DIVE_DEG = 45           -- camera pitch for a full dive (down) or flare (up)
local TURN_DEG_S, TURN_GAIN, TURN_EASE = 75, 2.0, 4.0      -- turn rate: max, per degree off the camera, 1/s to reach it
local EASE_SINK = 5.0         -- 1/s: how fast the climb or sink reaches its target
local CATCH_CM_S = 1200       -- opening catches a fall down to this at once (kit: 1 s of the game's fall is 33 m/s)
local GRAVITY = 0.2           -- GravityScale while gliding (the game's 1.75 would pull it down between my sets)
local ARM_CM = 650            -- camera distance while gliding (the 5.7 m sail hides a 300 cm camera)
local LAG_SPEED, LAG_MAX_CM = 8, 150                       -- the camera trails a little (the game's: 25, 50)
local FOV_KICK = 8            -- degrees added to the camera's field of view at MAX_SPEED (none at SPEED)
local PRONE_DEG = 80          -- the body turned face down
local PRONE_AT = { X = -85, Y = 0, Z = -20 }               -- the turned mesh's spot: the body under the bar
local OPEN_S = 0.35           -- the body swings face down and the wing unfolds over this long
local GLIDER_AT = { X = 0, Y = 0, Z = -10 }                -- the base bar until the hands are read (kit: hands there)
local HANDS = { "hand_l", "hand_r" }                       -- the game's skeleton (kit: GetSocketLocation on both)
local HAND_FOLLOW = 0.5                                    -- per frame: the bar keeps to the hands without a shake
local BANK_PER_DEG_S, BANK_MAX = 0.35, 25                  -- the glider leans into a turn
local PITCH_MAX = 12          -- the glider's nose goes down this far in a full dive (up in a flare)
-- The hold: the game's ladder grip looped on the montage slot, both hands up at the bar. Without it the game's
-- animation sees a fast fall and plays its run cycle (kit 2026-11-02: falling, PlayerVelocity 1345; user: "playing a
-- walking animation when gliding"). The ghost's too (its animation runs on the pose's velocity).
local HOLD_ANIM = "/Game/Character/Anims/Locomotion/Chr_LadderIdle.Chr_LadderIdle"
local HOLD_SLOT = "DefaultSlot"
local HOLD_BLEND_S = 0.25
local HOLD_CHECK_S = 0.25     -- the slot is looked at this often; an empty one gets the hold again
local RESEND_S = 5.0          -- while gliding, said again (a player who joins meanwhile hears it)
-- The game's wind (user 2026-11-03: "make the gliders use the games natural wind physics", "as natural and realistic
-- as possible"). Ultra Dynamic Weather keeps it (kit 2026-11-03, build 26303910): "Wind Force Vector" points where it
-- blows (it drifts slowly), "Get Wind Speed in Real Units" gives its speed in knots for a chosen speed at intensity 10
-- (the live intensity is in "Global Weather State"; 2.06 gave 0.074 of that), "Current Wind Gust Multiplier" is its
-- gusting, a new target about once a second within +-"Wind Gust Intensity" (0.45). The glider flies through that air:
-- - its ground track is its airspeed plus the wind (a headwind slows it over the ground, a tailwind carries it on,
--   a crosswind drifts it; it still points where it flies through the air)
-- - a gust changes the airspeed, not the ground speed at once: a headwind gust gives speed, which a level or pulled-up
--   glider turns into height (LEVEL_ZOOM), a tailwind gust or a lull takes it
-- - wind up a slope lifts it (ridge lift: the wind times the slope along it), off the far side it sinks (half that),
--   both fading out RIDGE_TOP_CM over the ground
-- - near the ground the wind is weaker (WIND_LOW of it at the ground, all of it from WIND_FULL_CM up)
-- No weather actor, or calm: the flight is as before.
local UDW = "Ultra_Dynamic_Weather_C"
local KNOTS_AT_10 = 60        -- intensity 10 a violent storm; 2 (clear, kit) comes to 4.4 knots, a light breeze
local KNOT_CM_S = 51.44
local WIND_MAX_CM_S = 900     -- a storm's wind counts up to this (the glider's 1100 still makes way into it)
local WIND_LOW, WIND_FULL_CM = 0.6, 3000
local LEVEL_ZOOM = 0.3        -- cm/s up per cm/s over trim speed, level (a flare: up to ZOOM)
local RIDGE_SPAN_CM, RIDGE_TRACE_CM, RIDGE_TOP_CM = 3000, 15000, 8000
local RIDGE_MAX_SLOPE, LEE_SINK = 1.0, 0.5
local AIR_S = 0.5             -- the wind's speed and direction and the ground under me are looked at this often
local UDW_LOOK_S = 5.0        -- no weather actor: looked for again this often

-- my glide (main copy flies it, every copy sends it): on, ep (counts my glides), heading, speed, vz
local sh = peers.shared("glider", { on = false, ep = 0 })
local stats = peers.shared("glider.stats", { opened = 0, landed = 0, closed = 0, water = 0, no_model = 0, no_item = 0,
    not_loaded = 0, too_low = 0 })
local key_was, opened_at, armed_until, armed_at = false, 0.0, 0.0, 0.0
local arm_z = nil             -- my height at the press that armed it (the drop since, for "too low")
local arm_asked = false       -- armed by a press in the air (asked for the glider: "too low" is said); a jump's own arming is quiet
local told = {}               -- reason -> os.clock() it was last said
local mine = nil              -- shown on my player: { actor, glider, mesh_rot, mesh_at, arm, gravity }
local theirs = nil            -- shown on this copy's ghost: { actor, glider, mesh_rot, mesh_at, yaw }
local peer_on = false
local same_world = function() return false end
local channel = nil
local sent, resend_in = nil, 0.0
local model_told = false
local reinstall = "reinstall SurrounSync"   -- (the glider on its own, mod/SurrounSyncGlider, names itself: glider.init)
-- the air my glide flies through (main copy only): w the weather actor (look_at: when to look for it again), next_at
-- when the wind and the ground are looked at again; dx, dy where the wind blows, speed (cm/s, before gusts and
-- height), low (the near-ground share), ridge (cm/s up per cm/s of wind); wx, wy the wind on me last frame
local air = { w = nil, look_at = 0.0, next_at = 0.0, dx = 1, dy = 0, speed = 0, low = 1, ridge = 0, wx = nil, wy = nil }

local function key_pressed()
    local down = false
    for _, k in ipairs(KEYS) do if game.key_down(k) then down = true; break end end
    local edge = down and not key_was
    key_was = down
    return edge
end

local function clamp(x, lo, hi) return x < lo and lo or (x > hi and hi or x) end

-- shortest signed angle a -> b in degrees
local function delta_deg(a, b) return (b - a + 540) % 360 - 180 end

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

-- true when the line a-b hits something (or the trace fails)
local function blocked(ksl, p, a, b)
    local hit = true
    local ok = pcall(function()
        hit = ksl:LineTraceSingle(p, a, b, 0, false, {}, 0, {}, true,
            { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0) == true
    end)
    return not ok or hit
end

-- nothing within MIN_DROP_CM under the capsule's bottom, or a clear run AHEAD_CM on to ground AHEAD_DROP_CM under the
-- feet (along the run; a standing jump: where the body faces)
local function high_enough(p)
    local ksl, l, half = util.cdo(KSL), nil, 90
    pcall(function() l = util.vec(p:K2_GetActorLocation()) end)
    pcall(function() half = p.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    if not (ksl and l) then return false end
    local feet = l.Z - half
    if not blocked(ksl, p, l, { X = l.X, Y = l.Y, Z = feet - MIN_DROP_CM }) then return true end
    local dx, dy = 0, 0
    pcall(function() local v = util.vec(p.CharacterMovement.Velocity); dx, dy = v.X, v.Y end)
    local n = math.sqrt(dx * dx + dy * dy)
    if n < 100 then
        local yaw
        pcall(function() yaw = math.rad(p:K2_GetActorRotation().Yaw) end)
        if not yaw then return false end
        dx, dy, n = math.cos(yaw), math.sin(yaw), 1
    end
    -- (the run is traced first: uphill the spot ahead could be inside the hill, where a trace down hits nothing)
    local ahead = { X = l.X + dx / n * AHEAD_CM, Y = l.Y + dy / n * AHEAD_CM, Z = l.Z }
    return not blocked(ksl, p, l, ahead) and not blocked(ksl, p, ahead, { X = ahead.X, Y = ahead.Y, Z = feet - AHEAD_DROP_CM })
end

local function smooth01(k) k = clamp(k, 0, 1); return k * k * (3 - 2 * k) end

-- The body swung k of the way (0..1) from standing to face down under the bar.
local function lean(a, v, k)
    if not v.mesh_rot then return end
    local rot
    pcall(function() rot = util.cdo(KML):ComposeRotators(v.mesh_rot, { Pitch = -PRONE_DEG * k, Yaw = 0, Roll = 0 }) end)
    rot = rot and { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll }
        or { Pitch = 0, Yaw = v.mesh_rot.Yaw, Roll = PRONE_DEG * k }   -- (what it gives for the game's yaw -90)
    local f, at = v.mesh_at, {}
    for _, c in ipairs({ "X", "Y", "Z" }) do at[c] = f[c] + (PRONE_AT[c] - f[c]) * k end
    pcall(function() a.Mesh:K2_SetRelativeLocationAndRotation(at, rot, false, {}, true) end)
end

-- the hands up at the bar (HOLD_ANIM looped), unless another montage plays (eating, a hit): the hold comes back after
local function hold(a, v, dt)
    v.hold_in = (v.hold_in or 0) - dt
    if v.hold_in > 0 then return end
    v.hold_in = HOLD_CHECK_S
    local cur, seq = nil, util.find(HOLD_ANIM)
    if not seq or not pcall(function() cur = a:GetCurrentMontage() end) or util.valid(cur) then return end
    pcall(function()
        v.hold_m = a.Mesh:GetAnimInstance():PlaySlotAnimationAsDynamicMontage(seq, FName(HOLD_SLOT), HOLD_BLEND_S,
            HOLD_BLEND_S, 1.0, 100000, -1.0, 0.0)
    end)
end

-- The look: the glider model attached above the character (base bar at the hands) and the character turned face down,
-- both eased in over OPEN_S by place(). Kept in `v` so hide() puts back exactly what show() changed.
local function show(a, v)
    local m
    pcall(function() m = a.Mesh end)
    if util.valid(m) and not v.mesh_rot then
        pcall(function()
            local r, l = m.RelativeRotation, m.RelativeLocation
            v.mesh_rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
            v.mesh_at = { X = l.X, Y = l.Y, Z = l.Z }
        end)
        v.t = 0
    end
    if util.valid(v.glider) then return end
    local sm, cls, w = util.find(MESH), util.find(SMA), game.world()
    if not (sm and cls and util.valid(w)) then
        if not model_told then
            model_told = true
            stats.no_model = stats.no_model + 1
            log.info("glider: the glider model isn't loaded (SurrounSyncGlider.pak in Paks\\LogicMods, BPModLoaderMod on) - gliding without it")
        end
        return
    end
    local g
    pcall(function() g = w:SpawnActor(cls, util.vec(a:K2_GetActorLocation()), { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if not util.valid(g) then return end
    local ok = pcall(function()
        local c = g.StaticMeshComponent
        c:SetMobility(2)
        c:SetStaticMesh(sm)
        c:SetCollisionEnabled(0)
        g:K2_AttachToComponent(a.CapsuleComponent, FName("None"), 0, 0, 0, false)
        c:K2_SetRelativeLocationAndRotation(GLIDER_AT, { Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true)
    end)
    if not ok then pcall(function() g:K2_DestroyActor() end); return end
    v.glider = g
end

local function hide(a, v)
    if not v then return end
    if util.valid(v.glider) then pcall(function() v.glider:K2_DestroyActor() end) end
    v.glider, v.at, v.roll, v.pitch, v.unfolded = nil, nil, nil, nil, nil
    if util.valid(a) then
        -- (only the hold: a montage the game plays meanwhile keeps playing)
        if util.valid(v.hold_m) then pcall(function() a.Mesh:GetAnimInstance():Montage_Stop(HOLD_BLEND_S, v.hold_m) end) end
        if v.mesh_rot then
            pcall(function() a.Mesh:K2_SetRelativeLocationAndRotation(v.mesh_at, v.mesh_rot, false, {}, true) end)
        end
    end
    v.mesh_rot, v.mesh_at, v.hold_m, v.hold_in, v.t = nil, nil, nil, nil, nil
end

-- the middle of the two hands in the actor's frame (forward, right, up; the actor stands upright), or nil
local function hands_at(a)
    local l, r, at, yaw
    pcall(function()
        l, r = util.vec(a.Mesh:GetSocketLocation(FName(HANDS[1]))), util.vec(a.Mesh:GetSocketLocation(FName(HANDS[2])))
        at, yaw = util.vec(a:K2_GetActorLocation()), math.rad(a:K2_GetActorRotation().Yaw)
    end)
    if not (l and r and at and yaw) then return nil end
    local dx, dy, dz = (l.X + r.X) / 2 - at.X, (l.Y + r.Y) / 2 - at.Y, (l.Z + r.Z) / 2 - at.Z
    local c, s = math.cos(yaw), math.sin(yaw)
    return { X = dx * c + dy * s, Y = -dx * s + dy * c, Z = dz }
end

-- Every frame: the body swings in (OPEN_S), the hands hold the bar, and the base bar (the model's origin) follows the
-- hands so they stay on it whatever the animation does; the glider leans into a turn and noses down in a dive
-- (dive: -1 full flare .. 1 full dive). The wing unfolds from its keel while the body swings.
local function place(a, v, turn_deg_s, dive, dt)
    if v.t and v.t < OPEN_S + dt then
        v.t = v.t + dt
        lean(a, v, smooth01(v.t / OPEN_S))
    end
    hold(a, v, dt)
    if not util.valid(v.glider) then return end
    local want = hands_at(a) or GLIDER_AT
    if v.at then
        for _, k in ipairs({ "X", "Y", "Z" }) do v.at[k] = v.at[k] + (want[k] - v.at[k]) * HAND_FOLLOW end
    else
        v.at = { X = want.X, Y = want.Y, Z = want.Z }
    end
    local ease = math.min(1, dt * 6)
    local roll = clamp(turn_deg_s * BANK_PER_DEG_S, -BANK_MAX, BANK_MAX)
    v.roll = (v.roll or 0) + (roll - (v.roll or 0)) * ease
    v.pitch = (v.pitch or 0) + (-dive * PITCH_MAX - (v.pitch or 0)) * ease
    local k = smooth01((v.t or OPEN_S) / OPEN_S)
    pcall(function()
        local c = v.glider.StaticMeshComponent
        c:K2_SetRelativeLocationAndRotation(v.at, { Pitch = v.pitch, Yaw = 0, Roll = v.roll }, false, {}, true)
        if k < 1 or not v.unfolded then
            c:SetRelativeScale3D({ X = 0.6 + 0.4 * k, Y = 0.15 + 0.85 * k, Z = 0.6 + 0.4 * k })
            v.unfolded = k >= 1
        end
    end)
end

local function open(p)
    local vel, yaw = { X = 0, Y = 0, Z = 0 }, 0
    pcall(function() vel = util.vec(p.CharacterMovement.Velocity) end)
    pcall(function() yaw = game.controller():GetControlRotation().Yaw end)
    local hs = math.sqrt(vel.X * vel.X + vel.Y * vel.Y)
    sh.on, sh.ep = true, sh.ep + 1
    -- (the forward speed carried in counts, along the heading; a standing drop starts slow and dives to speed)
    sh.heading, sh.speed, sh.vz, sh.turn = yaw, clamp(hs, MIN_SPEED, MAX_SPEED), math.max(vel.Z, -CATCH_CM_S), 0
    opened_at = os.clock()
    air.next_at, air.wx, air.wy = 0, nil, nil
    mine = { actor = p }
    pcall(function() mine.gravity = p.CharacterMovement.GravityScale; p.CharacterMovement.GravityScale = GRAVITY end)
    pcall(function()
        local arm = p.SpringArm
        mine.arm, mine.lag, mine.lag_max = arm.TargetArmLength, arm.CameraLagSpeed, arm.CameraLagMaxDistance
        arm.CameraLagSpeed, arm.CameraLagMaxDistance = LAG_SPEED, LAG_MAX_CM
    end)
    pcall(function() mine.fov = p.Camera.FieldOfView end)
    show(p, mine)
    stats.opened = stats.opened + 1
    log.info(string.format("glider: open (%d cm/s forward, %d cm/s down)", math.floor(hs), math.floor(-vel.Z)))
end

local function close(why)
    if not sh.on then return end
    sh.on = false
    local p = mine and mine.actor
    hide(p, mine)   -- (the glider model goes even when the character already has: hide checks the actor itself)
    if mine and util.valid(p) then
        if mine.gravity then pcall(function() p.CharacterMovement.GravityScale = mine.gravity end) end
        if mine.arm then pcall(function() p.SpringArm.TargetArmLength = mine.arm end) end
        if mine.lag then
            pcall(function() p.SpringArm.CameraLagSpeed, p.SpringArm.CameraLagMaxDistance = mine.lag, mine.lag_max end)
        end
        if mine.fov then pcall(function() p.Camera.FieldOfView = mine.fov end) end
    end
    mine = nil
    log.info("glider: closed (" .. why .. ")")
end

-- One step of the flight (no engine calls): speed, climb/sink, turn rate and heading from the dive (-1 full flare ..
-- 1 full dive) and how far the camera looks off the heading (degrees, signed). The turn eases in and out
-- (critically damped enough not to swing past the camera). lift: cm/s the air itself rises (sinks below 0).
function glider.steer(dive, off_deg, dt, lift)
    local accel = dive > 0 and DIVE_ACCEL * dive or FLARE_DECEL * dive
    sh.speed = clamp(sh.speed + (accel - DRAG * (sh.speed - SPEED)) * dt, MIN_SPEED, MAX_SPEED)
    local want_vz = -(SINK + DIVE_SINK * math.max(dive, 0)) + (lift or 0)
    if dive <= 0 and sh.speed > SPEED then
        want_vz = want_vz + (sh.speed - SPEED) * (LEVEL_ZOOM + (ZOOM - LEVEL_ZOOM) * -dive)
    end
    if sh.speed < STALL_SPEED then want_vz = want_vz - (STALL_SPEED - sh.speed) * STALL_SINK end
    sh.vz = sh.vz + (want_vz - sh.vz) * math.min(1, dt * EASE_SINK)
    local want_turn = clamp(off_deg * TURN_GAIN, -TURN_DEG_S, TURN_DEG_S)
    sh.turn = (sh.turn or 0) + (want_turn - (sh.turn or 0)) * math.min(1, dt * TURN_EASE)
    local step = sh.turn * dt
    if (off_deg > 0 and step > off_deg) or (off_deg < 0 and step < off_deg) then step = off_deg end
    sh.heading = (sh.heading + step + 180) % 360 - 180
end

local function weather_actor(now)
    if util.valid(air.w) then return air.w end
    air.w = nil
    if now < air.look_at then return nil end
    air.look_at = now + UDW_LOOK_S
    pcall(function()
        for _, o in ipairs(FindAllOf(UDW) or {}) do
            if util.valid(o) and not o:GetFullName():find("Default__", 1, true) then air.w = o; break end
        end
    end)
    if air.w and not air.told then air.told = true; log.info("glider: flying in the game's wind") end
    return air.w
end

-- cm from at down to the ground (traced from up cm above it; nil: nothing within RIDGE_TRACE_CM, or unreadable)
local function ground_under(ksl, p, at, up)
    local from, out, hit, d = { X = at.X, Y = at.Y, Z = at.Z + up }, {}, false, nil
    pcall(function()
        hit = ksl:LineTraceSingle(p, from, { X = at.X, Y = at.Y, Z = at.Z - RIDGE_TRACE_CM }, 0, false, {}, 0, out, true,
            { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0) == true
    end)
    if hit then pcall(function() d = (out.OutHit or out).Distance end) end
    return type(d) == "number" and d - up or nil
end

-- the wind's speed and direction, the ground under me and its slope along the wind (engine calls, every AIR_S)
local function look_at_air(p, at, now)
    air.next_at = now + AIR_S
    local w = weather_actor(now)
    local speed, dx, dy = 0, air.dx, air.dy
    if w then
        pcall(function()
            local v = w["Wind Force Vector"](w)
            local n = math.sqrt(v.X * v.X + v.Y * v.Y)
            if n > 1e-6 then dx, dy = v.X / n, v.Y / n end
        end)
        pcall(function()
            local out = {}
            w["Get Wind Speed in Real Units"](w, KNOTS_AT_10, false, out, {}, {})
            speed = clamp((tonumber(out.Knots) or 0) * KNOT_CM_S, 0, WIND_MAX_CM_S)
        end)
    end
    air.speed, air.dx, air.dy, air.low, air.ridge = speed, dx, dy, 1, 0
    if speed <= 0 then return end
    local ksl = util.cdo(KSL)
    if not ksl then return end
    local here = ground_under(ksl, p, at, 0)
    if not here then return end
    air.low = clamp(WIND_LOW + (1 - WIND_LOW) * here / WIND_FULL_CM, WIND_LOW, 1)
    local fade = clamp(1 - here / RIDGE_TOP_CM, 0, 1)
    if fade <= 0 then return end
    -- (from a span up: the ground downwind may stand higher than me)
    local ahead = ground_under(ksl, p, { X = at.X + dx * RIDGE_SPAN_CM, Y = at.Y + dy * RIDGE_SPAN_CM, Z = at.Z }, RIDGE_SPAN_CM)
    if not ahead then return end
    local slope = clamp((here - ahead) / RIDGE_SPAN_CM, -RIDGE_MAX_SLOPE, RIDGE_MAX_SLOPE)   -- (+: it rises downwind)
    air.ridge = (slope > 0 and slope or slope * LEE_SINK) * fade
end

-- The wind on me this frame (cm/s across the ground, x and y) and how fast the air rises; a change in the wind since
-- the last frame changes my airspeed (my ground speed carries on). Calm or no weather: 0, 0, 0.
local function air_step(p, at, now)
    if now >= air.next_at then look_at_air(p, at, now) end
    local s = 0
    if air.speed > 0 then
        local gust = 0
        pcall(function() gust = tonumber(air.w["Current Wind Gust Multiplier"]) or 0 end)
        s = air.speed * air.low * (1 + clamp(gust, -0.9, 1))
    end
    local wx, wy = air.dx * s, air.dy * s
    if air.wx then
        local h = math.rad(sh.heading)
        sh.speed = clamp(sh.speed - ((wx - air.wx) * math.cos(h) + (wy - air.wy) * math.sin(h)), MIN_SPEED, MAX_SPEED)
    end
    air.wx, air.wy = wx, wy
    return wx, wy, s * air.ridge
end

local function fly(p, dt)
    local pitch, yaw = 0, sh.heading
    pcall(function()
        local r = game.controller():GetControlRotation()
        pitch, yaw = r.Pitch, r.Yaw
    end)
    if pitch > 180 then pitch = pitch - 360 end
    local dive = clamp(-pitch / DIVE_DEG, -1, 1)
    local at, wx, wy, lift = nil, 0, 0, 0
    pcall(function() at = util.vec(p:K2_GetActorLocation()) end)
    if at then wx, wy, lift = air_step(p, at, os.clock()) end
    glider.steer(dive, delta_deg(sh.heading, yaw), dt, lift)
    local h = math.rad(sh.heading)
    pcall(function()
        p.CharacterMovement.Velocity = { X = math.cos(h) * sh.speed + wx, Y = math.sin(h) * sh.speed + wy, Z = sh.vz }
    end)
    pcall(function() p:K2_SetActorRotation({ Pitch = 0, Yaw = sh.heading, Roll = 0 }, false) end)
    local e = math.min(1, dt * 3)
    pcall(function()
        local arm = p.SpringArm
        arm.TargetArmLength = arm.TargetArmLength + (ARM_CM - arm.TargetArmLength) * e
    end)
    if mine.fov then
        pcall(function()
            local cam = p.Camera
            local want = mine.fov + FOV_KICK * clamp((sh.speed - SPEED) / (MAX_SPEED - SPEED), 0, 1)
            cam.FieldOfView = cam.FieldOfView + (want - cam.FieldOfView) * e
        end)
    end
    place(p, mine, sh.turn, dive, dt)
end

local function tell(why, text)
    stats[why] = (stats[why] or 0) + 1
    local now = os.clock()
    if told[why] and now - told[why] < TELL_S[why] then return end
    told[why] = now
    log.info("glider: not opened, " .. why .. " (" .. text .. ")")
    pcall(function() require("mirror.notify").show(text, "info", "glider." .. why) end)
end

local function height(p)
    local z
    pcall(function() z = p:K2_GetActorLocation().Z end)
    return z
end

local function arm(p, now, in_air)
    if now >= armed_until then arm_z, arm_asked = height(p), false end   -- (a press while armed keeps the first press's height)
    armed_until, armed_at = now + ARM_S, now
    arm_asked = arm_asked or in_air
end

-- armed, and it ran out or I landed without opening: asked for it in the air and fell a real drop since the press? then
-- say it was too low (a plain jump down a wall, armed by the jump alone, says nothing)
local function disarm(p)
    local z = armed_until > 0 and arm_asked and arm_z and height(p)
    if z and arm_z - z >= TOO_LOW_TOLD_CM then
        tell("too_low", "Hang Glider: not enough air under you to open it (" .. MIN_DROP_CM / 100 .. " m of drop, or a slope going down ahead)")
    end
    armed_until, arm_z, arm_asked = 0, nil, false
end

-- a press in the air without a Hang Glider: none carried, or the glider's item isn't in this game at all
-- why: its pak missing, as the game reads it (the game runs in Binaries\Win64). BPModLoaderMod isn't needed for it:
-- modrecipe loads the item from the pak itself (2026-11-12); a pak there but not loaded was put in after the game
-- started (the engine mounts the Paks folder at start only)
local function missing_files()
    local f = io.open("..\\..\\Content\\Paks\\LogicMods\\SurrounSyncGlider.pak", "rb")
    if not f then return "SurrounSyncGlider.pak isn't in Content\\Paks\\LogicMods" end
    f:close()
    return "SurrounSyncGlider.pak is there but this game started without it - restart the game"
end

local function no_glider()
    if not util.valid(util.find(glideritem.ITEM)) then
        local why = missing_files()
        log.warn("glider: the glider's item isn't loaded - " .. why)
        tell("not_loaded", "Hang Glider: the glider's files aren't loaded in this game (" .. why .. ") - " .. reinstall)
    else
        tell("no_item", "Hang Glider: you don't carry one - make it at the crafting workbench")
    end
end

-- main.lua's copy only (every frame, co-op or not)
local function own_tick(dt)
    local p = game.player()
    local pressed = key_pressed()
    if not util.valid(p) then return end
    if sh.on then
        if not util.same(mine and mine.actor, p) then close("a new character"); return end
        if dead(p) then close("died"); return end
        if swimming(p) then stats.water = stats.water + 1; close("in the water"); return end
        if not falling(p) then stats.landed = stats.landed + 1; close("landed"); return end
        if pressed and os.clock() - opened_at >= CLOSE_AFTER_S then stats.closed = stats.closed + 1; close("let go"); return end
        fly(p, dt)
        if not util.valid(mine.glider) or not mine.mesh_rot then show(p, mine) end
        return
    end
    local now = os.clock()
    local air = falling(p)
    if armed_until > 0 and now >= armed_until then disarm(p) end
    if pressed and now >= armed_until then
        -- (the inventory is walked on a Jump press only, never per frame; a jump without one carried is just a jump)
        if glideritem.carried(p) then arm(p, now, air) elseif air then no_glider() end
    elseif pressed then
        arm(p, now, air)
    end
    if not air then
        -- (on the ground the press is the game's jump: it stays armed while the jump lifts off; landing disarms)
        if armed_until > 0 and now - armed_at >= LIFTOFF_S then disarm(p) end
        return
    end
    if now < armed_until and not swimming(p) and not dead(p) and high_enough(p) then armed_until, arm_z = 0, nil; open(p) end
end

local function apply(msg)
    local kind, ep = msg:match("^(%u) (%d+)$")
    if not tonumber(ep) then return end
    local on = kind == "G"
    if on ~= peer_on then log.info("glider: the other player's glider " .. (on and "opened" or "closed")) end
    peer_on = on
end

-- this copy's player's glider on its ghost (a new ghost - respawned, another world - gets it again)
local function show_peer(dt)
    local g = peer_on and same_world() == true and ghost.get() or nil
    if theirs and not util.same(theirs.actor, g) then
        hide(theirs.actor, theirs)
        theirs = nil
    end
    if not g then return end
    theirs = theirs or { actor = g }
    show(g, theirs)
    -- (their turn and dive read off the ghost's own movement: yaw rate, and sink against the level glide's)
    local yaw, z
    pcall(function() yaw = g:K2_GetActorRotation().Yaw; z = g:K2_GetActorLocation().Z end)
    local ok = dt > 0 and theirs.yaw and yaw and z and theirs.z
    local turn = ok and delta_deg(theirs.yaw, yaw) / dt or 0
    local dive = ok and clamp((-(z - theirs.z) / dt - SINK) / DIVE_SINK, -1, 1) or 0
    place(g, theirs, turn, dive, dt)
    theirs.yaw, theirs.z = yaw, z
end

function glider.tick(dt)
    if not channel then return end
    local here = same_world() == true
    channel:pump(function(m) util.safe(apply, "glider.apply", m) end)
    local st = (sh.on and "G " or "L ") .. sh.ep
    resend_in = resend_in - dt
    if here and (st ~= sent or (sh.on and resend_in <= 0)) then
        resend_in, sent = RESEND_S, st
        if sh.on or sh.ep > 0 then channel:send(st) end
    end
    util.safe(show_peer, "glider.peer", dt)
end

function glider.active() return sh.on == true end

function glider.status()
    return string.format("glider: %s, opened %d, landed %d, let go %d, water %d, no item %d, too low %d, wind %.1f m/s, recipe %s, item %s",
        sh.on and "GLIDING" or (peer_on and "they're gliding" or "closed"),
        stats.opened, stats.landed, stats.closed, stats.water, stats.no_item, stats.too_low, air.speed / 100,
        glideritem.stats.added > 0 and "added" or "not yet",
        util.valid(util.find(glideritem.ITEM)) and "loaded" or "NOT LOADED")
end

-- co-op stops: the other player's glider goes (mine flies on, it's my own movement)
function glider.stop()
    if theirs then hide(theirs.actor, theirs) end
    theirs, peer_on, sent = nil, false, nil
end

local function forget()
    -- (the world went: the actors with it; my character is a new one)
    if sh.on and mine then mine.glider, mine.mesh_rot = nil, nil; close("world reset") end
    theirs, peer_on, sent = nil, false, nil
end

-- main.lua: my own glide, every frame (co-op or not); c: config (glider = false turns it off; reinstall: what the
-- "files aren't loaded" notice tells the player to reinstall)
function glider.init(c)
    if c and c.glider == false then log.info("glider: off"); return end
    if c and c.reinstall then reinstall = c.reinstall end
    game.on_world_reset(forget)
    game.on_tick(function(dt) util.safe(own_tick, "glider.own", dt) end)
    game.on_tick(function(dt) util.safe(glideritem.tick, "glideritem", dt) end)
    log.info("glider: ready (carrying a Hang Glider, a jump with " .. MIN_DROP_CM / 100 .. " m or more under you, or down a hill, opens it)")
end

-- phase1, each link's copy: send my state on it, show its player's
function glider.link_init(same_world_fn)
    same_world = same_world_fn or same_world
    channel = channel or events.reliable("glider", 16)
    game.on_world_reset(forget)
end

glider._shared = sh
glider._air = air
glider._consts = { MIN_DROP_CM = MIN_DROP_CM, AHEAD_CM = AHEAD_CM, AHEAD_DROP_CM = AHEAD_DROP_CM,SPEED = SPEED, SINK = SINK, ARM_CM = ARM_CM, GRAVITY = GRAVITY,
    CLOSE_AFTER_S = CLOSE_AFTER_S, PRONE_DEG = PRONE_DEG, MIN_SPEED = MIN_SPEED, MAX_SPEED = MAX_SPEED,
    DIVE_SINK = DIVE_SINK, STALL_SPEED = STALL_SPEED, TURN_DEG_S = TURN_DEG_S, CATCH_CM_S = CATCH_CM_S,
    HOLD_ANIM = HOLD_ANIM, OPEN_S = OPEN_S }

return glider
