-- A 5-inch FPV quad's flight: a pure step function, no UE calls (tests/test_flight.py flies it offline).
-- Units: cm, seconds, degrees for rates and angles. World axes as UE's: X forward, Y right, Z up. The body is three
-- unit vectors in the world: f (the nose), r (the right arm), u (the top: where the props push).
-- Acro: the sticks command body rotation rates through Betaflight's rate curve and the quad keeps whatever attitude
-- it has; thrust always pushes along u. Angle: the sticks command a tilt and the quad levels itself.
-- The physics: four motors (flight.MOTORS), each spooling up on its own and pushing its own corner with its own
-- inflow (a rolling quad's sinking side bites harder: natural damping), the props' drag torque yawing the frame,
-- and a rigid body with an inertia tensor turning by Euler's equations (the gyroscopic term included). A
-- Betaflight-like flight controller (rate PID with feedforward, airmode mixer that clips at the motors' limits)
-- turns the sticks into motor commands. Not modelled: the motors' own spin-up torque on yaw and the props'
-- gyroscopic precession. Air torques (blade flapping, turbulence, prop wash) are angular accelerations per axis.

local flight = {}

flight.DEFAULTS = {
    twr = 7.0,            -- full-throttle thrust / weight: a 5-inch freestyle quad on 6S
    idle = 0.04,          -- thrust share at zero throttle while armed (motor idle, keeps control while diving)
    thr_expo = 1.6,       -- thrust share = throttle ^ thr_expo above idle: hover near 25 % throttle
    motor_tau = 0.035,    -- s, each motor's thrust follows its command

    -- the airframe for turning (kg, m: the flight path goes by twr alone)
    mass = 0.65,          -- kg, ready to fly on a 6S 1300
    arm = 0.0778,         -- m, each motor's offset forward or back and left or right (220 mm motor to motor across)
    inertia = { 1.8e-3, 2.2e-3, 3.8e-3 },   -- kg m^2 about roll, pitch, yaw (flat: yaw ~ roll + pitch)
    prop_torque = 0.015,  -- m: a prop's drag torque per newton of its thrust (what yaws the frame)
    rot_drag = 0.2,       -- 1/s: the frame's own drag against turning
    windmill = 2.5,       -- 1/s more with the motors off: the props windmilling (a disarmed spin dies away)

    -- the flight controller, per axis: the angular acceleration (deg/s^2) it asks the motors for
    rc_smooth = 0.015,    -- s, the stick setpoint's smoothing (Betaflight's RC smoothing)
    fc_p = 100,           -- 1/s per deg/s of rate error
    fc_d = 2,             -- per deg/s^2 it already turns at (damps the motors' lag)
    fc_ff = 3,            -- per deg/s^2 the setpoint moves at (feedforward: 1 + fc_d follows the sticks exactly)
    stun_grip = 0.1,     -- share of its control it keeps while a hit has it stunned (st.stun, s: props struck,
                          -- the gyro swamped), so a hard hit tumbles it and you fly it back
    -- (drag: 0.5 rho Cd A / mass, per cm. Edge on the frame, pack and blades are ~0.012 m^2 at Cd ~1 (a dive with no
    -- throttle levels near 90 km/h); flat, the four prop discs ~0.05 m^2 at Cd ~1.1 (~40 km/h, idle helping). They were
    -- 3-5 times that: 45 and 17 km/h, user 2026-11-03: "gravity feels too floaty")
    drag_side = 1.2e-4,   -- 1/cm, quadratic drag across the props' plane
    drag_up = 4.5e-4,     -- 1/cm, sinking against the thrust axis: air up through the prop discs, like a plate
    drag_frame = 2.5e-4,  -- 1/cm, moving the way the thrust points: only the frame's own drag
    v_pitch = 5500,       -- cm/s, the props' pitch speed: thrust fades as air already comes through that fast
                          -- (what limits top speed, ~125 km/h flat out)
    drag_lin = 0.05,      -- 1/s, a small linear part so a slow drift dies
    gravity = 980,
    rates = {             -- Betaflight rates per axis: rc rate, super rate, expo (1.0 / 0.7 / 0 = 667 deg/s max)
        roll = { 1.0, 0.7, 0.0 },
        pitch = { 1.0, 0.7, 0.0 },
        yaw = { 1.0, 0.7, 0.0 },
    },
    -- angle mode: it tilts as far as the stick says and levels itself, easing back rather than snapping (user
    -- 2026-11-03: "angle mode is tooo restrictive and it re angles too quickly")
    angle_max = 70,       -- degrees of tilt at full stick in angle mode
    angle_gain = 4,       -- 1/s: angle mode's rotation rate per degree of tilt error ...
    angle_rate = 250,     -- deg/s ... at most
    substep = 1 / 500,    -- s, the longest integration step (a frame is cut into these)

    -- on the ground: a disarmed quad falls onto its belly or its back, whichever it is nearer, and on its back only
    -- turtle mode (the motors run backwards) rolls it over (flight.settle, flight.turtle)
    flop_rate = 360,      -- deg/s it falls flat at
    turtle_thrust = 0.35, -- share of a motor's thrust it makes spun backwards (a prop is poor the wrong way round)
    turtle_edge = 0.10,   -- m from the middle out to the edge it tips over on, lying on its back ...
    turtle_height = 0.035,-- ... and up to the middle from the ground (the battery on top holds it up)
    turtle_damp = 3,      -- 1/s: air and ground against it tipping
    turtle_spin = 300,    -- deg/s full yaw stick spins it where it lies
    turtle_dead = 0.2,    -- the stick deflection turtle mode ignores
    turtle_amps = 25,     -- A the reversed motors draw at full stick

    -- what pushes the quad around (the flight controller fights it: a disturbance knocks the rates off, P and D
    -- catch it and the I term pulls the rest back within a fifth of a second)
    fc_i = 250,           -- 1/s^2 per deg/s of rate error held (the I term)
    fc_i_max = 4000,      -- deg/s^2: the most the I term can push
    flap = 0.45,          -- deg/s^2 per cm/s: blade flapping, air across the props tilts the top away from it
    turb_torque = 5.0,    -- deg/s^2 per cm/s of turbulence: small eddies rock the quad (roll, pitch; yaw less)
    turb_speed = 0.06,    -- ... plus this share of the airspeed: rougher the faster it flies through them
    -- (the three sink speeds are at hover thrust: they go with the props' induced velocity, the square root of their
    -- thrust, so at idle the band is about half as wide)
    wash_sink = 250,      -- cm/s: sinking along the thrust axis faster than this drops into its own prop wash
    wash_full = 500,      -- cm/s more sinking for the full effect (only while slow across: < wash_across)
    wash_out = 1500,      -- cm/s: past about twice the induced velocity the air just blows up through the props
                          -- (the windmill state: smooth again), fading out from wash_sink + wash_full to here.
                          -- Without it a zero-throttle drop sat in the wash for good, airmode lifting the motors
                          -- to fight the shake, and fell at 17 km/h (user 2026-11-03: "gravity feels too floaty")
    wash_across = 700,
    wash_thrust = 0.3,    -- share of thrust lost in full prop wash (the vortex ring)
    wash_torque = 3200,   -- deg/s^2 of shaking in full prop wash at hover thrust (the oscillation pilots fight)
    punch_rise = 8,       -- share of full power per s: the motors spooling up faster than this (a punch) ...
    punch_torque = 600,   -- ... shake it a little, at most this (deg/s^2: still air's only shake, user 2026-11-03) ...
    punch_tau = 0.25,     -- ... dying away over this (s)

    -- the battery: 6S 1300 mAh. Thrust goes with the square of the voltage the motors get, and the voltage sags
    -- under load and falls as the pack empties, so the same throttle lifts less late in the flight. twr is a fresh
    -- pack's punch at full throttle. battery = 0: no sag, twr always.
    battery = 1,
    cells = 6,
    mah = 1300,
    r_pack = 0.025,       -- ohm, the pack and wires
    i_max = 110,          -- A at full thrust
    i_idle = 1.0,         -- A for the flight controller, camera and video transmitter
}

-- resting volts per cell over the charge left (a LiPo's curve: flat in the middle, a knee near empty)
flight.CELL_CURVE = { { 0, 3.0 }, { 0.05, 3.3 }, { 0.1, 3.5 }, { 0.2, 3.65 }, { 0.5, 3.8 }, { 0.9, 4.05 }, { 1, 4.2 } }
flight.CUTOFF = 2.9        -- V a cell under load: below it the pack is flat and the motors stop
flight.LOW_CELL = 3.5      -- V a cell (resting): the OSD's LOW BATTERY ...
flight.LAND_CELL = 3.3     -- ... and LAND NOW

-- a fresh pack in a quad: what flight.new starts with, and what a swap at the character puts back
function flight.fresh_pack(st) st.mah, st.flat, st.volts = 0, false, nil end
function flight.resting_cell(p, st) return flight.cell_volts(1 - (st.mah or 0) / p.mah) end

local sin, cos, rad, deg, sqrt, abs, exp = math.sin, math.cos, math.rad, math.deg, math.sqrt, math.abs, math.exp
local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

-- Betaflight "actual" rate curve: stick -1..1 -> degrees per second
function flight.rate(stick, rc_rate, super, expo)
    local s = clamp(stick, -1, 1)
    if expo and expo ~= 0 then s = s * abs(s) ^ 3 * expo + s * (1 - expo) end
    local r = rc_rate
    if r > 2 then r = r + 14.54 * (r - 2) end
    local d = 200 * r * s
    if super and super ~= 0 then d = d / clamp(1 - abs(s) * super, 0.01, 1) end
    return d
end

function flight.cell_volts(charge)
    local c = flight.CELL_CURVE
    charge = clamp(charge, 0, 1)
    for i = 2, #c do
        if charge <= c[i][1] then
            local a, b = c[i - 1], c[i]
            return a[2] + (b[2] - a[2]) * (charge - a[1]) / (b[1] - a[1])
        end
    end
    return c[#c][2]
end

-- the pack under load: volts at the motors for this many amps with this much used (mAh)
function flight.pack_volts(p, mah_used, amps)
    return p.cells * flight.cell_volts(1 - mah_used / p.mah) - amps * p.r_pack
end
function flight.amps(p, motor) return p.i_idle + p.i_max * clamp(motor, 0, 1) ^ 1.5 end

-- the motors, Betaflight's Quad X "props in": x forward, y right (in arms), spin 1 = clockwise seen from above
flight.MOTORS = {
    { 1, -1, 1 },    -- front left
    { 1, 1, -1 },    -- front right
    { -1, -1, -1 },  -- rear left
    { -1, 1, 1 },    -- rear right
}

-- newtons one motor pushes at full command on a fresh pack in still air
function flight.motor_newtons(p) return p.twr * p.mass * p.gravity / 100 / 4 end

-- the mixer, airmode: per-axis commands (thrust share per motor, + roll right / pitch up / yaw right) on top of
-- the throttle's share, every motor kept within lo..1. Too much asked: the axes are scaled down together; then the
-- throttle gives way (up or down) so the full turn still fits. Returns the four motor commands.
function flight.mix(want, roll, pitch, yaw, lo)
    local d, dmin, dmax = {}, math.huge, -math.huge
    for k, m in ipairs(flight.MOTORS) do
        d[k] = -m[2] * roll + m[1] * pitch - m[3] * yaw
        dmin, dmax = math.min(dmin, d[k]), math.max(dmax, d[k])
    end
    local range = dmax - dmin
    if range > 1 - lo then
        local k = (1 - lo) / range
        for i = 1, 4 do d[i] = d[i] * k end
        dmin, dmax = dmin * k, dmax * k
    end
    local c = clamp(want, lo - dmin, 1 - dmax)
    return { clamp(c + d[1], 0, 1), clamp(c + d[2], 0, 1), clamp(c + d[3], 0, 1), clamp(c + d[4], 0, 1) }
end

-- Euler's equations for the body rates (deg/s: roll, pitch, yaw as FRD's p, q, r) under torques (N m): deg/s^2
function flight.body_accel(p, w, L, M, N)
    local J = p.inertia
    local wp, wq, wr = rad(w[1]), rad(w[2]), rad(w[3])
    return deg((L - (J[3] - J[2]) * wq * wr) / J[1]),
           deg((M - (J[1] - J[3]) * wr * wp) / J[2]),
           deg((N - (J[2] - J[1]) * wp * wq) / J[3])
end

-- thrust share per motor share at these volts (1 = a fresh pack at full throttle)
function flight.volt_scale(p, volts)
    if not p.battery or p.battery == 0 then return 1 end
    local full = flight.pack_volts(p, 0, flight.amps(p, 1))
    return (math.max(volts, 0) / full) ^ 2
end

-- the throttle that holds a hover with these settings (on a fresh pack)
function flight.hover_throttle(p)
    p = p or flight.DEFAULTS
    local motor = 1 / p.twr
    for _ = 1, 4 do motor = 1 / (p.twr * flight.volt_scale(p, flight.pack_volts(p, 0, flight.amps(p, motor)))) end
    return ((motor - p.idle) / (1 - p.idle)) ^ (1 / p.thr_expo)
end

local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function norm(a)
    local l = sqrt(dot(a, a))
    return { a[1] / l, a[2] / l, a[3] / l }
end
-- (UE's axes with the plain cross product: cross(up, forward) = right)
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end

-- body axes from a UE rotator (degrees), as FRotationMatrix builds them
function flight.axes(pitch, yaw, roll)
    local sp, cp, sy, cy, sr, cr = sin(rad(pitch)), cos(rad(pitch)), sin(rad(yaw)), cos(rad(yaw)), sin(rad(roll)), cos(rad(roll))
    return { cp * cy, cp * sy, sp },
           { sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp },
           { -(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp }
end

-- the UE rotator (pitch, yaw, roll in degrees) of body axes f, r, u
function flight.rotator(f, r, u)
    return deg(math.atan(f[3], sqrt(f[1] * f[1] + f[2] * f[2]))), deg(math.atan(f[2], f[1])), deg(math.atan(-r[3], u[3]))
end

function flight.new(x, y, z, yaw, seed)
    local f, r, u = flight.axes(0, yaw or 0, 0)
    return { pos = { x or 0, y or 0, z or 0 }, vel = { 0, 0, 0 }, f = f, r = r, u = u,
             rate = { 0, 0, 0 },   -- deg/s: roll (right side down), pitch (nose up), yaw (nose right)
             thrust = 0,           -- the motors' mean share of full power right now (set it: all four go there)
             motors = nil,         -- each motor's share: front left, front right, rear left, rear right
             alpha = { 0, 0, 0 },  -- deg/s^2 the body turned at last (what the gyro's D term sees)
             sp = { 0, 0, 0 },     -- deg/s the flight controller is steering for (the smoothed sticks)
             iterm = { 0, 0, 0 },  -- deg/s^2 the flight controller's I term pushes back with
             mah = 0, amps = 0, volts = nil,   -- the battery: used, drawn now, at the motors now
             flat = false,         -- the pack ran flat: no thrust until it is swapped (flight.fresh_pack)
             wash = 0,             -- 0..1 how deep in its own prop wash
             punch = 0,            -- 0..1 how hard the last punch of throttle still shakes it
             seed = math.max(1, math.floor(seed or 12345)), wn = { 0, 0, 0 } }
end

-- (prop wash shakes even in still air: its own small noise, seeded like the wind's)
local function wash_noise(st, h)
    local a = exp(-h / 0.05)
    local b = sqrt(1 - a * a)
    for i = 1, 3 do
        st.seed = (st.seed * 48271) % 2147483647
        local u1 = math.max(st.seed / 2147483647, 1e-12)
        st.seed = (st.seed * 48271) % 2147483647
        st.wn[i] = st.wn[i] * a + b * sqrt(-2 * math.log(u1)) * cos(2 * math.pi * st.seed / 2147483647)
    end
    return st.wn
end

-- what the sticks ask for, in deg/s about the body: roll, pitch (nose up), yaw (nose right)
local function targets(st, cmd, p)
    local R, P, Y = p.rates.roll, p.rates.pitch, p.rates.yaw
    local ty = flight.rate(cmd.yaw or 0, Y[1], Y[2], Y[3])
    if cmd.mode ~= "angle" then
        -- pitch stick forward (+1) puts the nose down
        return flight.rate(cmd.roll or 0, R[1], R[2], R[3]), -flight.rate(cmd.pitch or 0, P[1], P[2], P[3]), ty
    end
    -- angle: the top should point where a quad at the stick's tilt (and today's heading) points it
    local yaw = deg(math.atan(st.f[2], st.f[1]))
    local _, _, ud = flight.axes(-(cmd.pitch or 0) * p.angle_max, yaw, (cmd.roll or 0) * p.angle_max)
    local up = dot(ud, st.u)
    local max_r = math.min(flight.rate(1, R[1], R[2], R[3]), p.angle_rate or math.huge)
    local max_p = math.min(flight.rate(1, P[1], P[2], P[3]), p.angle_rate or math.huge)
    -- rolling right swings the top toward r, pitching up swings it toward -f
    return clamp(p.angle_gain * deg(math.atan(dot(ud, st.r), up)), -max_r, max_r),
           clamp(p.angle_gain * deg(math.atan(-dot(ud, st.f), up)), -max_p, max_p), ty
end

local STILL = { 0, 0, 0 }

-- turn the body by small angles (radians: roll right side down, pitch nose up, yaw nose right), then square it up
local function rotate(st, pr, pq, py)
    local f, r, u = st.f, st.r, st.u
    local nf = { f[1] + py * r[1] + pq * u[1], f[2] + py * r[2] + pq * u[2], f[3] + py * r[3] + pq * u[3] }
    local nu = { u[1] - pq * f[1] + pr * r[1], u[2] - pq * f[2] + pr * r[2], u[3] - pq * f[3] + pr * r[3] }
    nf = norm(nf)
    local d = dot(nu, nf)
    nu = norm({ nu[1] - d * nf[1], nu[2] - d * nf[2], nu[3] - d * nf[3] })
    st.f, st.u, st.r = nf, nu, cross(nu, nf)
end

-- one frame: cmd = { thr 0..1, roll, pitch, yaw -1..1, armed, mode = "acro" | "angle" };
-- air = wind.step()'s { vel, shake, sigma } or nil for still air
function flight.step(st, cmd, dt, p, air)
    p = p or flight.DEFAULTS
    if dt <= 0 then return st end
    st.tip = nil   -- (a turtle flip left half done: flying again, it's gone)
    local n = math.max(1, math.ceil(dt / p.substep - 1e-9))
    local h = dt / n
    local g = p.gravity
    local km = 1 - exp(-h / p.motor_tau)
    local ks = 1 - exp(-h / p.rc_smooth)
    local wv = air and air.vel or STILL
    local battery = p.battery and p.battery ~= 0
    local tmax = flight.motor_newtons(p)
    local per = { p.arm, p.arm, p.prop_torque }   -- m: torque per newton of motor difference, per axis
    st.alpha, st.sp = st.alpha or { 0, 0, 0 }, st.sp or { 0, 0, 0 }
    local w, I, al, sp = st.rate, st.iterm, st.alpha, st.sp
    -- (st.thrust set from outside, a new quad or a crash: every motor there)
    local mot = st.motors
    if not mot or st.thrust ~= st.motor_mean then
        mot = { st.thrust, st.thrust, st.thrust, st.thrust }
        st.motors = mot
    end
    for _ = 1, n do
        local grip = 1
        if (st.stun or 0) > 0 then
            st.stun = math.max(st.stun - h, 0)
            grip = p.stun_grip
        end
        local want, tr, tp, ty
        if cmd.armed then
            want = p.idle + (1 - p.idle) * clamp(cmd.thr or 0, 0, 1) ^ p.thr_expo
            tr, tp, ty = targets(st, cmd, p)
        else
            want, tr, tp, ty = 0, 0, 0, 0
        end

        -- the flight controller: per axis an angular acceleration from the rate error (P, I), the turn already
        -- under way (D) and the setpoint's own change (feedforward), made a torque by the inertia and a motor
        -- difference by the arm (yaw: the props' drag)
        local tgt, ax = { tr, tp, ty }, { 0, 0, 0 }
        for i = 1, 3 do
            if cmd.armed then
                local was = sp[i]
                sp[i] = was + (tgt[i] - was) * ks
                local e = sp[i] - w[i]
                if grip == 1 then I[i] = clamp(I[i] + p.fc_i * e * h, -p.fc_i_max, p.fc_i_max) end
                local a = p.fc_p * e + I[i] - p.fc_d * al[i] + p.fc_ff * (sp[i] - was) / h
                ax[i] = rad(a) * p.inertia[i] / (4 * tmax * per[i]) * grip
            else
                sp[i], I[i] = 0, 0
            end
        end
        local c = flight.mix(want, ax[1], ax[2], ax[3], cmd.armed and p.idle or 0)
        local mean0 = st.thrust
        local sum, draw = 0, 0
        for k = 1, 4 do
            mot[k] = mot[k] + (c[k] - mot[k]) * km
            sum, draw = sum + mot[k], draw + mot[k] ^ 1.5
        end
        st.thrust = sum / 4
        st.motor_mean = st.thrust
        local rise = (want - mean0) * km / h
        st.punch = math.max((st.punch or 0) * exp(-h / p.punch_tau),
            cmd.armed and clamp((rise - p.punch_rise) / (3 * p.punch_rise), 0, 1) or 0)

        -- the battery: what the motors draw drains it and sags the volts they get
        local scale = 1
        if battery then
            st.amps = cmd.armed and p.i_idle + p.i_max * draw / 4 or p.i_idle
            st.mah = st.mah + st.amps * h / 3.6
            st.volts = flight.pack_volts(p, st.mah, st.amps)
            scale = flight.volt_scale(p, st.volts)
            -- a flat pack: the ESCs cut out below 3.0 V a cell under load (or nothing left at all)
            if st.mah >= p.mah or st.volts < p.cells * flight.CUTOFF then st.flat = true end
            if st.flat then scale = 0 end
        end

        -- the air as the quad meets it: across the props' plane (s) and through them (vu)
        local v, u = st.vel, st.u
        local va = { v[1] - wv[1], v[2] - wv[2], v[3] - wv[3] }
        local vu = dot(va, u)
        local s = { va[1] - vu * u[1], va[2] - vu * u[2], va[3] - vu * u[3] }
        local sl = sqrt(dot(s, s))
        -- its own prop wash: sinking down the thrust axis while slow across it
        local wash = 0
        if cmd.armed then
            local sink = -vu / sqrt(math.max(st.thrust * p.twr, 0.05))
            local top = p.wash_sink + p.wash_full
            wash = clamp((sink - p.wash_sink) / p.wash_full, 0, 1) * clamp((p.wash_out - sink) / (p.wash_out - top), 0, 1)
                * clamp(1 - sl / p.wash_across, 0, 1)
        end
        st.wash = wash

        -- the air's torques, as angular accelerations: the flight controller has to fight them
        local tq1, tq2, tq3 = 0, 0, 0
        if cmd.armed then
            tq1, tq2 = -p.flap * dot(s, st.r), p.flap * dot(s, st.f)   -- (the top tilts away from the air across it)
            if air and air.shake then
                local amp = p.turb_torque * ((air.sigma or 0) + p.turb_speed * sqrt(dot(va, va)))
                local sh = air.shake
                tq1, tq2, tq3 = tq1 + amp * sh[1], tq2 + amp * sh[2], tq3 + 0.35 * amp * sh[3]
            end
            -- its own prop wash, and a punch of throttle, shake it (even in still air). The wash shakes the thrust
            -- the props make, so it goes with that thrust (wash_torque at hover; little at idle, up to 1.5 times):
            -- the thrust the throttle asks for, not what airmode adds to fight the shake (that fed itself: a
            -- zero-throttle drop shaken up to hover thrust, hanging at 17 km/h)
            local a = p.wash_torque * wash * math.min(want * p.twr, 1.5) + p.punch_torque * st.punch
            if a > 0 then
                local wn = wash_noise(st, h)
                tq1, tq2, tq3 = tq1 + a * wn[1], tq2 + a * wn[2], tq3 + 0.35 * a * wn[3]
            end
        end
        -- each motor's thrust: its share, less of it the faster air already comes through its prop (the quad's
        -- own turn adds to that at each corner), less in its own wash, less on a tired pack. Its push at its corner
        -- rolls and pitches the body, its prop's drag yaws it (FRD: roll = -y T, pitch = x T, yaw = -spin * drag).
        local kt = scale * (1 - p.wash_thrust * wash)
        local wp, wq = rad(w[1]), rad(w[2])
        local push, L, M, N = 0, 0, 0, 0
        for k, m in ipairs(flight.MOTORS) do
            local x, y = m[1] * p.arm, m[2] * p.arm
            local vi = vu + 100 * (wq * x - wp * y)
            local t = mot[k] * kt * clamp(1 - vi / p.v_pitch, 0, 1.15)
            push = push + t
            L, M, N = L - y * t, M + x * t, N - m[3] * p.prop_torque * t
        end
        local a1, a2, a3 = flight.body_accel(p, w, L * tmax, M * tmax, N * tmax)
        local damp = p.rot_drag + (cmd.armed and 0 or p.windmill)
        al[1], al[2], al[3] = a1 + tq1 - damp * w[1], a2 + tq2 - damp * w[2], a3 + tq3 - damp * w[3]
        for i = 1, 3 do w[i] = w[i] + al[i] * h end

        -- forces: the four thrusts along the top, gravity, drag against the air: across the props' plane, and
        -- along the thrust axis a plate when sinking, the bare frame when not
        local a_up = push * p.twr * g / 4
            - (vu < 0 and p.drag_up or p.drag_frame) * abs(vu) * vu
        for i = 1, 3 do
            local a = u[i] * a_up - p.drag_side * sl * s[i] - p.drag_lin * va[i]
            if i == 3 then a = a - g end
            v[i] = v[i] + a * h
            st.pos[i] = st.pos[i] + v[i] * h
        end

        rotate(st, rad(w[1]) * h, rad(w[2]) * h, rad(w[3]) * h)
    end
    return st
end

-- (v turned about the unit axis k by the angle whose cosine and sine are c, s)
local function turn(v, k, c, s)
    local kv, kd = cross(k, v), dot(k, v)
    return { v[1] * c + kv[1] * s + k[1] * kd * (1 - c), v[2] * c + kv[2] * s + k[2] * kd * (1 - c),
             v[3] * c + kv[3] * s + k[3] * kd * (1 - c) }
end

-- on the ground, nothing holding it up: it falls onto its belly or its back, whichever it is nearer, at flop_rate.
-- Returns 1 for its belly, -1 for its back.
function flight.settle(st, dt, p)
    p = p or flight.DEFAULTS
    local u = st.u
    local side = u[3] >= 0 and 1 or -1
    st.rate = { 0, 0, 0 }
    local ang = math.acos(clamp(u[3] * side, -1, 1))
    if ang < 1e-4 then return side end
    local step = math.min(ang, rad(p.flop_rate) * dt)
    local k = norm(cross(u, { 0, 0, side }))
    local c, s = cos(step), sin(step)
    st.f, st.u = norm(turn(st.f, k, c, s)), norm(turn(u, k, c, s))
    st.r = cross(st.u, st.f)
    return side
end

-- turtle mode, on the ground: the motors run backwards. The roll or pitch stick spins the two motors on that side,
-- their props push that side up and the quad levers over the opposite edge, which stays on the ground. Gravity
-- pulls it back until its middle is over that edge; past it, it falls over onto its belly (a little to that side).
-- Too little stick doesn't lift it, a tap lifts it and it drops back, a held stick flips it. Yaw spins it where it
-- lies. It only works on its back or side; throttle does nothing; the pack drains as the motors work.
-- (st.tip: the flip under way: axis 1 roll / 2 pitch, dir, the edge in body axes, its place, angle, rate)
local function tip_offset(st, t)
    return { t.at[1] - (t.b[1] * st.f[1] + t.b[2] * st.r[1] + t.b[3] * st.u[1]),
             t.at[2] - (t.b[1] * st.f[2] + t.b[2] * st.r[2] + t.b[3] * st.u[2]),
             t.at[3] - (t.b[1] * st.f[3] + t.b[2] * st.r[3] + t.b[3] * st.u[3]) }
end
local function tip_turn(st, t, a)
    if t.axis == 1 then rotate(st, t.dir * a, 0, 0) else rotate(st, 0, t.dir * a, 0) end
end

function flight.turtle(st, cmd, dt, p)
    p = p or flight.DEFAULTS
    if dt <= 0 then return st end
    local function push(x)
        local a = abs(x or 0)
        if a <= p.turtle_dead then return 0 end
        return (x > 0 and 1 or -1) * (a - p.turtle_dead) / (1 - p.turtle_dead)
    end
    local pr, pq, py = push(cmd.roll), -push(cmd.pitch), push(cmd.yaw)   -- (pitch stick forward: nose down)
    local scale = 1
    if p.battery and p.battery ~= 0 then
        st.amps = p.i_idle + p.turtle_amps * math.max(abs(pr), abs(pq), abs(py))
        st.mah = st.mah + st.amps * dt / 3.6
        st.volts = flight.pack_volts(p, st.mah, st.amps)
        if st.mah >= p.mah or st.volts < p.cells * flight.CUTOFF then st.flat = true end
        scale = flight.volt_scale(p, st.volts)
    end
    if st.flat then pr, pq, py = 0, 0, 0 end
    st.thrust, st.wash, st.punch, st.vel, st.motors = 0, 0, 0, { 0, 0, 0 }, nil
    local e, c = p.turtle_edge, p.turtle_height
    local mg = p.mass * p.gravity / 100
    local n = math.max(1, math.ceil(dt / 0.005 - 1e-9))
    local h = dt / n
    for _ = 1, n do
        local t = st.tip
        if not t and st.u[3] <= 0 and (pr ~= 0 or pq ~= 0) then
            -- a new flip: the stick's stronger axis; the side it lifts is +r (roll) or the tail (pitch), so the
            -- edge on the ground is the other one, down at the ground (along u, the quad on its back)
            local axis = abs(pr) >= abs(pq) and 1 or 2
            local dir = ((axis == 1 and pr or pq) > 0) and 1 or -1
            local b = axis == 1 and { 0, -e * dir * 100, c * 100 } or { e * dir * 100, 0, c * 100 }
            t = { axis = axis, dir = dir, b = b, angle = 0, w = 0, z0 = st.pos[3] }
            t.at = { st.pos[1] + b[1] * st.f[1] + b[2] * st.r[1] + b[3] * st.u[1],
                     st.pos[2] + b[1] * st.f[2] + b[2] * st.r[2] + b[3] * st.u[2],
                     st.pos[3] + b[1] * st.f[3] + b[2] * st.r[3] + b[3] * st.u[3] }
            st.tip = t
        end
        if t then
            -- the two lifting motors push at the far side (edge to motors: e + arm); the other two push into the
            -- ground and do nothing. Gravity: the middle's height as it tips (-dz/dangle)
            local stick = (t.axis == 1 and pr or pq) * t.dir
            local tq = 2 * p.turtle_thrust * flight.motor_newtons(p) * scale * math.max(stick, 0) * (e + p.arm)
            local z = tip_offset(st, t)[3]
            local probe = { f = st.f, r = st.r, u = st.u }
            tip_turn(probe, t, 1e-4)
            local dz = (tip_offset(probe, t)[3] - z) / 100 / 1e-4
            local ip = p.inertia[t.axis] + p.mass * (e * e + c * c)
            t.w = t.w + ((tq - mg * dz) / ip - p.turtle_damp * t.w) * h
            local a = t.w * h
            if t.angle + a <= 0 then a, t.w = -t.angle, 0 end
            t.angle = t.angle + a
            tip_turn(st, t, a)
            st.pos = tip_offset(st, t)
            if t.angle <= 0 and t.w <= 0 then
                st.tip = nil                                   -- back down on its back
                flight.settle(st, h, p)
                st.pos[3] = t.z0
            elseif st.u[3] > 0.5 then
                st.tip = nil                                   -- over: it lands on its belly
                flight.settle(st, 1, p)
                st.pos[3] = t.z0
            end
        else
            if py ~= 0 then rotate(st, 0, 0, py * rad(p.turtle_spin) * h) end
            flight.settle(st, h, p)
        end
    end
    local t = st.tip
    st.rate = { t and t.axis == 1 and deg(t.w * t.dir) or 0, t and t.axis == 2 and deg(t.w * t.dir) or 0, 0 }
    return st
end

-- the FPV camera's view: the body pitched up by the camera's uptilt (degrees), as a UE rotator
function flight.camera(st, tilt)
    local t = rad(tilt or 0)
    local c, s = cos(t), sin(t)
    local f, u = st.f, st.u
    local cf = { c * f[1] + s * u[1], c * f[2] + s * u[2], c * f[3] + s * u[3] }
    local cu = { c * u[1] - s * f[1], c * u[2] - s * f[2], c * u[3] - s * f[3] }
    return flight.rotator(cf, st.r, cu)
end

function flight.speed(st) return sqrt(dot(st.vel, st.vel)) end

return flight
