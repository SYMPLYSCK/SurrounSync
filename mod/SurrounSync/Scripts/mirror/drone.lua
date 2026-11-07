-- Another player's FPV drone on this screen (user 2026-11-03: "make it ship with SurrounSync but mainly so I can brag
-- and show off"). The quad is flown by the FPVDrone mod (a separate mod, Desktop\FPVDrone): each flown frame its
-- fpv/body.lua sets the UE4SS shared variable FPVDrone.pose to "<seq> <drone id> <x y z> <pitch yaw roll> <4 motors'
-- share>" (the model's origin and turn), "" on foot. drone.line() reads it and phase1 sends it with my pose as a
-- "Q ..." segment (same rate and redundancy as the pose; "D " / "B " are the car's).
-- Each link's copy shows its player's quad: the 5" is SK_FPVDrone on a PoseableMeshComponent, its prop_FL..RR bones
-- turned about the quad's up at the motors' speeds, the whoop is SM_FPVWhoop as it is. The models come in
-- SurrounSyncDrone.pak (Paks\LogicMods, a copy of FPVDrone's FPVDrone_P.pak: the same /Game/Mods/FPVDrone/ assets), so
-- a player without FPVDrone sees it too. Shown DELAY_S behind the newest pose, its turn blended as a quaternion
-- (a flip through straight up or down blends without the rotator's jump), gone GONE_S after the last one.
-- It's heard too (user 2026-11-03: "drone noises ... that change pitch as the drone moves and speeds up"): the sounds
-- are in the same pak, one motor loop per motor following its share of power, the wind following how fast it moves,
-- a knock when it stops dead. The numbers are FPVDrone's fpv/noise.lua (a separate mod, so a copy). Their pose line
-- says nothing of crashes or prop wash: a crash is read from the speed falling away, the wash isn't heard.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local events = require("mirror.events")
local dronegrant = require("mirror.dronegrant")

local drone = {}

drone.SHARED = "FPVDrone.pose"
drone.MODELS = {
    ["5inch"] = { rig = "/Game/Mods/FPVDrone/SK_FPVDrone.SK_FPVDrone", low = 0.4, high = 2.0, volume = 1 },
    whoop = { mesh = "/Game/Mods/FPVDrone/SM_FPVWhoop.SM_FPVWhoop", low = 0.7, high = 2.0, volume = 0.6 },
}
drone.BONES = { "prop_FL", "prop_FR", "prop_RL", "prop_RR" }
drone.SPIN_SIGN = { 1, -1, -1, 1 }   -- FPVDrone's flight.MOTORS: FL and RR clockwise seen from above, FR and RL not
drone.SPIN = 3000       -- deg/s a prop turns at its motor's full power (with the square root of the thrust, as body.lua)
drone.STEP_MAX = 50     -- deg in one frame at most: more and a 3-blade prop seems to stop or turn back
drone.STALE_S = 0.5     -- mine: a pose whose seq hasn't moved this long isn't sent (FPVDrone stopped without clearing it)
drone.GONE_S = 0.5      -- theirs: no pose with a quad this long and it goes
drone.DELAY_S = 0.1     -- theirs: shown this far behind the newest pose (30 a second: three apart)
drone.MAX_SAMPLES = 8
drone.MAX_LINE = 400    -- mine: longest quad segment sent (FPVDrone's is ~150 characters)
drone.LOAD_AGAIN_S = 2
drone.LOAD_TRIES = 5
-- A prop past what a frame can draw (user 2026-11-03, "yes" to a motion-blur disc): above BLUR_ON of its motor's power
-- its blades go (scaled into the hub) and a see-through blurred disc shows where they run; under BLUR_OFF they're
-- back. The disc (FPVDrone_P.pak, tools/model/make_prop_blur.py) is the prop tip's size, put BLUR_UP cm above the
-- prop bone, the middle of the blades' height (drone_spec.json prop_disc_z_cm 2.41..3.28, bone at 2.44).
drone.BLUR_MESH = "/Game/Mods/FPVDrone/SM_FPVPropBlur.SM_FPVPropBlur"
drone.BLUR_ON, drone.BLUR_OFF = 0.2, 0.12
drone.BLUR_UP = 0.41
drone.BLADES_HIDDEN = 0.01   -- the blades' scale while the disc shows
-- Its sound: as FPVDrone's fpv/noise.lua (the engine's pitch limits are 0.4 and 2; the attenuation is on the sounds)
drone.SOUNDS = { motor = "/Game/Mods/FPVDrone/DroneMotor.DroneMotor", wind = "/Game/Mods/FPVDrone/DroneWind.DroneWind",
                 hit = "/Game/Mods/FPVDrone/DroneHit.DroneHit" }
drone.SOUND_ORDER = { "motor", "wind", "hit" }
drone.PITCH_MIN, drone.PITCH_MAX = 0.4, 2.0
drone.DETUNE = { 0.985, 1.012, 0.994, 1.021 }
drone.START = { 0, 0.37, 0.91, 1.43 }
drone.MOTOR_VOL, drone.MOTOR_FLOOR, drone.MOTOR_FADE = 0.3, 0.35, 0.05
drone.WIND_VOL, drone.WIND_FULL = 0.55, 3500
drone.ON_ABOVE, drone.OFF_BELOW = 0.008, 0.004
drone.PITCH_STEP, drone.VOL_STEP = 0.005, 0.003
drone.SOUND_EVERY = 1 / 30
drone.SOUND_LOOK_S = 0.5     -- s between looks for sounds not in memory yet
drone.JUMP = 20000           -- cm/s: faster than any quad flies, so put somewhere else, not flown there
drone.SPEED_TAU = 0.15       -- s, the speed the wind follows
-- A crash, read from the speed: the quick average far under the slow one, and it was going fast enough to be heard
-- (poses that stop coming hold the speed as it was; a stop that hard in the air would knock)
drone.FAST_TAU, drone.SLOW_TAU = 0.06, 0.5
-- (HIT_DROP: FPVDrone's ghost.LAND_SPEED, 400 cm/s, is a landing under and a crash over; the drop reads about 3/5 of the
-- speed it stopped from by the time the quick average is down, so a landing stays under this and a crash from 500 is over)
drone.HIT_DROP, drone.HIT_SHARE, drone.HIT_GAP, drone.HIT_FULL = 300, 0.25, 1.0, 1500
local SMA = "/Script/Engine.StaticMeshActor"
local SMC = "/Script/Engine.StaticMeshComponent"
local POSEABLE = "/Script/Engine.PoseableMeshComponent"
local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local GS = "/Script/Engine.Default__GameplayStatics"
local LOAD_UUID = 771210   -- (+ a number per asset: the engine ignores a second latent load under the same id)
local MOVABLE, NO_COLLISION, COMPONENT_SPACE = 2, 0, 1
local IDENTITY = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 },
                   Scale3D = { X = 1, Y = 1, Z = 1 } }
local LIMIT_CM = 1e7    -- a coordinate past this is a broken line, not a place

local clock = 0
local same_world = function() return false end
local hooked = false
local mine = { seq = nil, at = 0 }
-- theirs: samples { t, at, q, m }, flying, last (clock of the newest), id, actor, comp, rest, angle,
-- noise (nil: not made yet, false: given up on for this quad, else { loops, hit }), was, speed, fast, slow, hit_at
local T = { samples = {}, flying = false, last = -math.huge, angle = { 0, 0, 0, 0 } }
local loads = {}        -- path -> { asked, tries, told, uuid }
local load_ids = 0
local stats = { got = 0, bad = 0, shown = 0, no_model = 0 }

-- FRotator -> FQuat (UE's FRotator::Quaternion)
function drone.quat(pitch, yaw, roll)
    local h = math.pi / 360
    local sp, cp = math.sin(pitch * h), math.cos(pitch * h)
    local sy, cy = math.sin(yaw * h), math.cos(yaw * h)
    local sr, cr = math.sin(roll * h), math.cos(roll * h)
    return { X = cr * sp * sy - sr * cp * cy, Y = -cr * sp * cy - sr * cp * sy,
             Z = cr * cp * sy - sr * sp * cy, W = cr * cp * cy + sr * sp * sy }
end

local function axis(a) return (a + 180) % 360 - 180 end

-- FQuat -> FRotator (UE's FQuat::Rotator, its straight up / down cases too)
function drone.rotator(q)
    local X, Y, Z, W = q.X, q.Y, q.Z, q.W
    local sing = Z * X - W * Y
    local yaw = math.deg(math.atan(2 * (W * Z + X * Y), 1 - 2 * (Y * Y + Z * Z)))
    if sing < -0.4999995 then
        return { Pitch = -90, Yaw = yaw, Roll = axis(-yaw - 2 * math.deg(math.atan(X, W))) }
    elseif sing > 0.4999995 then
        return { Pitch = 90, Yaw = yaw, Roll = axis(yaw - 2 * math.deg(math.atan(X, W))) }
    end
    return { Pitch = math.deg(math.asin(2 * sing)), Yaw = yaw,
             Roll = math.deg(math.atan(-2 * (W * X + Y * Z), 1 - 2 * (X * X + Y * Y))) }
end

-- a to b by k, the short way round, kept a unit quaternion
function drone.nlerp(a, b, k)
    local s = (a.X * b.X + a.Y * b.Y + a.Z * b.Z + a.W * b.W) < 0 and -1 or 1
    local q = { X = a.X + (s * b.X - a.X) * k, Y = a.Y + (s * b.Y - a.Y) * k,
                Z = a.Z + (s * b.Z - a.Z) * k, W = a.W + (s * b.W - a.W) * k }
    local n = math.sqrt(q.X * q.X + q.Y * q.Y + q.Z * q.Z + q.W * q.W)
    if n < 1e-9 then return b end
    return { X = q.X / n, Y = q.Y / n, Z = q.Z / n, W = q.W / n }
end

-- q turned by a degrees about the up axis first: qz(a) * q (as FPVDrone's body.spun)
function drone.spun(q, a)
    local h = math.rad(a) / 2
    local s, c = math.sin(h), math.cos(h)
    return { X = c * q.X - s * q.Y, Y = c * q.Y + s * q.X, Z = c * q.Z + s * q.W, W = c * q.W - s * q.Z }
end

-- each prop's turn this frame: its motor's speed, at most STEP_MAX, its own way round
function drone.spin(angle, motors, dt)
    for k = 1, 4 do
        local m = motors and motors[k] or 0
        local step = math.min(drone.SPIN * math.sqrt(math.max(m, 0)) * dt, drone.STEP_MAX)
        angle[k] = (angle[k] + drone.SPIN_SIGN[k] * step) % 360
    end
    return angle
end

-- My quad's segment for the pose packet, or nil (not flying, no FPVDrone, its pose stopped coming).
function drone.line()
    if ModRef == nil then return nil end
    local ok, v = pcall(function() return ModRef:GetSharedVariable(drone.SHARED) end)
    if not ok or type(v) ~= "string" or v == "" then return nil end
    local seq, rest = v:match("^(%d+) (%S+ .+)$")
    -- (another mod's string: no separator of the pose line or its history, and a sane length - MAX_POSE is 2048 for
    -- the whole pose line, the quad's is ~150)
    if not seq or rest:find("[|\t\r\n]") or #rest > drone.MAX_LINE then return nil end
    if seq ~= mine.seq then mine.seq, mine.at = seq, clock
    elseif clock - mine.at > drone.STALE_S then return nil end
    return "Q " .. rest
end

-- "Q <id> x y z pitch yaw roll m1 m2 m3 m4" -> { id, at, q, m }, or nil
function drone.parse(seg)
    local id, rest = (seg or ""):match("^Q (%S+) (.+)$")
    if not id or not drone.MODELS[id] then return nil end
    local n = {}
    for x in rest:gmatch("%S+") do
        local v = tonumber(x)
        if not v or v ~= v or math.abs(v) > LIMIT_CM then return nil end
        n[#n + 1] = v
    end
    if #n ~= 10 then return nil end
    local m = {}
    for k = 1, 4 do m[k] = math.min(math.max(n[6 + k], 0), 1) end
    return { id = id, at = { X = n[1], Y = n[2], Z = n[3] }, q = drone.quat(n[4], n[5], n[6]), m = m }
end

-- phase1, each live pose from this copy's player: seg is its "Q ..." segment, nil when it had none (on foot)
function drone.sample(seg)
    if seg == nil then T.flying = false; return end
    local s = drone.parse(seg)
    if not s then stats.bad = stats.bad + 1; return end
    stats.got = stats.got + 1
    s.t = clock
    local list = T.samples
    list[#list + 1] = s
    while #list > drone.MAX_SAMPLES do table.remove(list, 1) end
    T.flying, T.last = true, clock
end

-- the pose at time t: between the two samples around it, the oldest before them, the newest after
function drone.at_time(list, t)
    if #list == 0 then return nil end
    if t <= list[1].t then return list[1] end
    for i = 1, #list - 1 do
        local a, b = list[i], list[i + 1]
        if t <= b.t then
            local k = b.t > a.t and (t - a.t) / (b.t - a.t) or 1
            return { id = b.id, m = b.m, q = drone.nlerp(a.q, b.q, k),
                     at = { X = util.lerp(a.at.X, b.at.X, k), Y = util.lerp(a.at.Y, b.at.Y, k), Z = util.lerp(a.at.Z, b.at.Z, k) } }
        end
    end
    return list[#list]
end

local function hide()
    if util.valid(T.actor) then pcall(function() T.actor:K2_DestroyActor() end) end
    T.actor, T.comp, T.rest, T.id, T.discs, T.noise, T.was = nil, nil, nil, nil, nil, nil, nil
end

-- the model in memory, or nil: the engine is asked to load it in the background (its latent LoadAsset: a load that
-- waits can deadlock on UE4SS's Lua lock, L-014), every LOAD_AGAIN_S, LOAD_TRIES times, then said once
-- (what: what goes without it, for that line)
-- Found is not loaded: the background loader's objects are findable before they're read in, and the rig drawn then is
-- the likely cause of FPVDrone's follow take-off crashes (2026-11-03 16:36 and 17:29: write to 0x8 in the engine's GPU
-- skin cache, the mesh's vertex buffers null, 14 ms after its load was asked; FPVDrone fpv/body.lua body.loaded).
-- One with a load step left waits, without spending a try. (EObjectFlags' load bits are the same in UE4 and UE5)
local PENDING = nil
local function loading(m)
    if PENDING == nil then
        PENDING = 0
        pcall(function()
            local F = EObjectFlags
            PENDING = F.RF_NeedInitialization | F.RF_NeedLoad | F.RF_NeedPostLoad | F.RF_NeedPostLoadSubobjects
        end)
    end
    if PENDING == 0 then return false end
    local busy = false
    pcall(function() busy = m:HasAnyFlags(PENDING) == true end)
    return busy
end

local function model(path, what)
    local m = util.find(path)
    if m then
        if loading(m) then return nil end
        return m
    end
    local l = loads[path]
    if not l then
        load_ids = load_ids + 1
        l = { asked = -math.huge, tries = 0, uuid = LOAD_UUID + load_ids }
        loads[path] = l
    end
    if clock - l.asked < drone.LOAD_AGAIN_S then return nil end
    l.asked = clock
    if l.tries >= drone.LOAD_TRIES then
        if not l.told then
            l.told = true
            stats.no_model = stats.no_model + 1
            log.info("drone: the FPV drone model isn't loaded (" .. path:match("[^.]+$")
                .. ", SurrounSyncDrone.pak in Paks\\LogicMods) - " .. (what or "their quad isn't shown"))
        end
        return nil
    end
    l.tries = l.tries + 1
    local K, w = util.cdo(KSL), game.world()
    if not (K and util.valid(w)) then return nil end
    pcall(function()
        K:LoadAsset(w, K:Conv_SoftObjPathToSoftObjRef(K:MakeSoftObjectPath(path)), {},
            { Linkage = 0, UUID = l.uuid, ExecutionFunction = FName("None"), CallbackTarget = w })
    end)
    return nil
end

-- their quad made: an empty static mesh actor carrying the rig on a PoseableMeshComponent, or the static mesh itself
local MAKE_RETRY_S = 2.0   -- after a quad that went wrong (else an actor spawned and destroyed every frame)
local function make(id, s)
    if clock < (T.retry_at or -math.huge) then return false end
    local spec = drone.MODELS[id]
    local m = model(spec.rig or spec.mesh)
    local cls, w = util.find(SMA), game.world()
    if not (m and cls and util.valid(w)) then return false end
    local a
    pcall(function() a = w:SpawnActor(cls, s.at, drone.rotator(s.q)) end)
    if not util.valid(a) then return false end
    local ok, err = pcall(function()
        local root = a.StaticMeshComponent
        root:SetMobility(MOVABLE)
        root:SetCollisionEnabled(NO_COLLISION)
        if spec.rig then
            local c = a:AddComponentByClass(util.find(POSEABLE), false, IDENTITY, false)
            if not pcall(function() c:SetSkinnedAssetAndUpdate(m, true) end) then c:SetSkeletalMesh(m, true) end
            c:SetCollisionEnabled(NO_COLLISION)
            local rest = {}
            for k, name in ipairs(drone.BONES) do
                if c:GetBoneIndex(FName(name)) < 0 then error("the rig has no bone " .. name) end
                local t = c:GetBoneTransformByName(FName(name), COMPONENT_SPACE)
                local q, l, sc = t.Rotation, t.Translation, t.Scale3D
                rest[k] = { Rotation = { X = q.X, Y = q.Y, Z = q.Z, W = q.W },
                            Translation = { X = l.X, Y = l.Y, Z = l.Z }, Scale3D = { X = sc.X, Y = sc.Y, Z = sc.Z } }
            end
            T.comp, T.rest = c, rest
        else
            root:SetStaticMesh(m)
        end
    end)
    if not ok then
        if not (loads[id .. ":make"]) then
            loads[id .. ":make"] = true
            log.warn("drone: their quad's model went wrong: " .. tostring(err))
        end
        pcall(function() a:K2_DestroyActor() end)
        T.comp, T.rest, T.retry_at = nil, nil, clock + MAKE_RETRY_S
        return false
    end
    T.actor, T.id = a, id
    stats.shown = stats.shown + 1
    return true
end

-- a blur disc over each prop of the rigged quad, hidden until its motor runs fast (made once its model is in memory;
-- until then the blades spin as they are). false: tried and failed, not tried again for this quad.
local function make_discs(a)
    local m = model(drone.BLUR_MESH, "their props spin without the blur")
    local cls = util.find(SMC)
    if not m then
        if (loads[drone.BLUR_MESH] or {}).told then return false end   -- (never loaded: spin the blades as they are)
        return nil
    end
    if not cls then return false end
    local discs = {}
    local ok, err = pcall(function()
        for k = 1, #drone.BONES do
            local at = T.rest[k].Translation
            local d = a:AddComponentByClass(cls, false, { Rotation = IDENTITY.Rotation,
                Translation = { X = at.X, Y = at.Y, Z = at.Z + drone.BLUR_UP }, Scale3D = IDENTITY.Scale3D }, false)
            d:SetStaticMesh(m)
            d:SetCollisionEnabled(NO_COLLISION)
            d:SetCastShadow(false)
            d:SetVisibility(false, false)
            discs[k] = { comp = d, on = false }
        end
    end)
    if not ok then
        log.warn("drone: their props' blur discs went wrong: " .. tostring(err))
        for _, d in pairs(discs) do pcall(function() d.comp:K2_DestroyComponent(d.comp) end) end
        return false
    end
    return discs
end

-- each disc on or off by its motor's power (with a gap between, so a motor at the edge doesn't flicker)
function drone.blurred(on, m)
    if on then return m >= drone.BLUR_OFF end
    return m >= drone.BLUR_ON
end

-- every loop's { pitch, volume } for this quad: motors 1..4 (a prop's speed goes with the root of its thrust), then the wind
function drone.noise_mix(id, motors, speed)
    local spec, out = drone.MODELS[id] or {}, {}
    local low, high, volume = spec.low or drone.PITCH_MIN, spec.high or drone.PITCH_MAX, spec.volume or 1
    for k = 1, 4 do
        local m = math.max(motors and motors[k] or 0, 0)
        local pitch = (low + (high - low) * math.sqrt(m)) * drone.DETUNE[k]
        out[k] = { math.min(math.max(pitch, drone.PITCH_MIN), drone.PITCH_MAX), volume * drone.MOTOR_VOL
            * math.min(m / drone.MOTOR_FADE, 1) * (drone.MOTOR_FLOOR + (1 - drone.MOTOR_FLOOR) * m ^ 0.7) }
    end
    local s = math.min(math.max(speed or 0, 0) / drone.WIND_FULL, 1)
    out[5] = { 0.7 + 0.7 * s, drone.WIND_VOL * s ^ 1.3 }
    return out
end

-- did it just stop dead? (fast, slow: its speed averaged over a moment and over longer)
function drone.crashed(fast, slow)
    return slow - fast >= drone.HIT_DROP and fast <= slow * drone.HIT_SHARE
end

-- the sounds on the quad's actor: a component per motor, the wind and a waiting crash, silent and stopped (they go with
-- the actor). nil: not in memory yet; false: never coming, or it went wrong, so this quad is silent.
local function make_noise(a)
    local found, wait = {}, false
    for _, name in ipairs(drone.SOUND_ORDER) do
        local path = drone.SOUNDS[name]
        found[name] = model(path, "their quad is silent")
        if not found[name] then
            if (loads[path] or {}).told then return false end
            wait = true
        end
    end
    if wait then return nil end
    local gs, root = util.cdo(GS), nil
    pcall(function() root = a.StaticMeshComponent end)
    if not (gs and util.valid(found.motor) and root) then return false end
    local function sound_on(snd, start)
        local c = gs:SpawnSoundAttached(snd, root, FName("None"), { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }, 0,
            true, 0, 1, start or 0, nil, nil, false)
        if util.valid(c) then c:Stop(); return c end
        return nil
    end
    local n, loops = nil, {}
    local ok, err = pcall(function()
        for k = 1, 5 do
            local c = sound_on(k <= 4 and found.motor or found.wind, drone.START[k])
            if not c then error("no sound component") end
            loops[k] = { comp = c, on = false, pitch = 1, vol = 0, start = drone.START[k] or 0 }
        end
        n = { loops = loops, hit = sound_on(found.hit), wait = 0 }
    end)
    if not ok then
        if not loads["noise:make"] then
            loads["noise:make"] = true
            log.warn("drone: their quad's sound went wrong: " .. tostring(err))
        end
        return false
    end
    return n
end

local function sound_loop(l, pitch, vol)
    local on = vol >= (l.on and drone.OFF_BELOW or drone.ON_ABOVE)
    if math.abs(pitch - l.pitch) >= drone.PITCH_STEP then
        l.pitch = pitch
        l.comp:SetPitchMultiplier(pitch)
    end
    if math.abs(vol - l.vol) >= drone.VOL_STEP or on ~= l.on then
        l.vol = vol
        l.comp:SetVolumeMultiplier(vol)
    end
    if on ~= l.on then
        l.on = on
        if on then l.comp:Play(l.start) else l.comp:Stop() end
    end
end

-- its speed from where it's shown: nothing from a new quad's past, a teleport is no speed, and while poses have stopped
-- coming (past DELAY_S it stands on the newest one) it isn't a stop
local function track_speed(at, dt)
    local was = T.was
    T.was = at
    if not was then T.speed, T.fast, T.slow = 0, 0, 0; return end
    if dt <= 0 or clock - T.last > drone.DELAY_S then return end
    local v = math.sqrt((at.X - was.X) ^ 2 + (at.Y - was.Y) ^ 2 + (at.Z - was.Z) ^ 2) / dt
    if v > drone.JUMP then T.speed, T.fast, T.slow = 0, 0, 0; return end
    T.speed = T.speed + (v - T.speed) * (1 - math.exp(-dt / drone.SPEED_TAU))
    T.fast = T.fast + (v - T.fast) * (1 - math.exp(-dt / drone.FAST_TAU))
    T.slow = T.slow + (v - T.slow) * (1 - math.exp(-dt / drone.SLOW_TAU))
end

-- each frame their quad shows
local function noise_tick(a, s, dt)
    if T.noise == nil and clock >= (T.noise_at or 0) then
        T.noise_at = clock + drone.SOUND_LOOK_S
        T.noise = make_noise(a)
    end
    track_speed(s.at, dt)
    local n = T.noise
    if not n then return end
    if drone.crashed(T.fast, T.slow) and clock - (T.hit_at or -math.huge) >= drone.HIT_GAP then
        T.hit_at = clock
        if util.valid(n.hit) then
            n.hit:SetVolumeMultiplier(math.min(0.25 + 0.75 * T.slow / drone.HIT_FULL, 1))
            n.hit:Play(0)
        end
        T.slow = T.fast   -- (that stop is heard: a very fast one still falling isn't a second)
    end
    n.wait = n.wait - dt
    if n.wait > 0 then return end
    n.wait = drone.SOUND_EVERY
    local mix = drone.noise_mix(s.id, s.m, T.speed)
    for k, l in ipairs(n.loops) do
        if util.valid(l.comp) then sound_loop(l, mix[k][1], mix[k][2]) end
    end
end

local function show(dt)
    local s = drone.at_time(T.samples, clock - drone.DELAY_S)
    if T.id and s.id ~= T.id then hide() end
    if not util.valid(T.actor) then
        T.actor, T.comp, T.rest, T.discs, T.noise, T.was = nil, nil, nil, nil, nil, nil
        if not make(s.id, s) then return end
    end
    local a = T.actor
    pcall(function() a:K2_SetActorLocationAndRotation(s.at, drone.rotator(s.q), false, {}, true) end)
    local sound_ok, sound_err = pcall(noise_tick, a, s, dt)
    if not sound_ok then
        if not loads["noise:tick"] then
            loads["noise:tick"] = true
            log.warn("drone: their quad's sound went wrong: " .. tostring(sound_err))
        end
        T.noise = false
    end
    if not (T.comp and T.rest) then return end
    if T.discs == nil then T.discs = make_discs(a) end
    drone.spin(T.angle, s.m, dt)
    local c, discs = T.comp, T.discs or nil
    pcall(function()
        for k, name in ipairs(drone.BONES) do
            local r, d = T.rest[k], discs and discs[k]
            if d then
                local on = drone.blurred(d.on, s.m[k] or 0)
                if on ~= d.on then d.on = on; d.comp:SetVisibility(on, false) end
            end
            local h = drone.BLADES_HIDDEN
            c:SetBoneTransformByName(FName(name), { Rotation = drone.spun(r.Rotation, T.angle[k]),
                Translation = r.Translation,
                Scale3D = (d and d.on) and { X = h, Y = h, Z = h } or r.Scale3D }, COMPONENT_SPACE)
        end
    end)
end

-- who may fly the bundled drone (dronegrant.lua): the owner's game sends its list on each link, a game hears it from
-- the link whose player is the owner (peer: that player's SteamID64; the main link's from the roster)
local channel, peer, grant_in, grant_sent = nil, nil, 0, nil
local function grants(dt)
    if not channel then return end
    local now = os.clock()
    channel:pump(function(m) dronegrant.heard(m, peer or require("mirror.peers").main_id(), now) end)
    if dronegrant.owner() then
        local m = dronegrant.message()
        grant_in = grant_in - dt
        if m ~= grant_sent or grant_in <= 0 then
            grant_in, grant_sent = dronegrant.SEND_S, m
            channel:send(m)
        end
    end
    dronegrant.tick(now)
end

-- phase1, every frame of this link's copy
function drone.tick(dt)
    util.safe(grants, "drone.grants", dt)
    clock = clock + dt
    if not (T.flying and clock - T.last <= drone.GONE_S and #T.samples > 0 and same_world() == true) then
        if T.actor then hide() end
        if not T.flying or clock - T.last > drone.GONE_S then T.samples = {} end
        return
    end
    show(dt)
end

function drone.status()
    return string.format("drone: %s, poses %d (%d bad), shown %d, no model %d%s",
        util.valid(T.actor) and "THEIRS FLYING" or (T.flying and "theirs flying, not shown" or "none"),
        stats.got, stats.bad, stats.shown, stats.no_model, T.noise and ", heard" or "")
end

local function forget()
    -- (the world went: the actor with it)
    T.actor, T.comp, T.rest, T.id, T.discs, T.noise, T.was = nil, nil, nil, nil, nil, nil, nil
    T.samples, T.flying, T.last = {}, false, -math.huge
end

-- co-op stops: their quad goes
function drone.stop()
    hide()
    T.samples, T.flying, T.last = {}, false, -math.huge
    mine.seq, grant_sent = nil, nil
end

-- phase1, each link's copy (peer_id: the SteamID64 of this link's player; nil on the main link)
function drone.link_init(same_world_fn, peer_id)
    same_world = same_world_fn or same_world
    peer = peer_id
    channel = channel or events.reliable("dronegrant", 4)
    if not hooked then hooked = true; game.on_world_reset(forget) end
end

drone._theirs = T
return drone
