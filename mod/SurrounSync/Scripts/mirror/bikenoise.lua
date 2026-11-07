-- The hover bike's sound (user 2026-11-04: "its an electric quad so give it the same audio as tghe drones but make it sounds
-- bigger and heavier and more powerful"): tools/armory/make_bike_sounds.py's in the armory pak, played as drone.lua plays a
-- quad's, one motor loop per motor following its share of power, the wind following its speed. The engine's pitch limits
-- are 0.4 and 2; the attenuation is on the sounds. hoverbike.lua says what the motors do; a bike's d holds the rest:
-- noise (nil: not made yet, false: silent, else { loops, wait }), motors, speed, running.

local log = require("mirror.log")
local util = require("mirror.util")

local noise = {}

local GS = "/Script/Engine.Default__GameplayStatics"
local DIR = "/Game/Mods/SurrounSyncArmory/"
local MOTOR, WIND = DIR .. "BikeMotor.BikeMotor", DIR .. "BikeWind.BikeWind"
local UUID_MOTOR, UUID_WIND = 771305, 771306
local PITCH_LOW, PITCH_HIGH, PITCH_MIN, PITCH_MAX = 0.4, 1.5, 0.4, 2.0
local DETUNE, START = { 0.985, 1.012, 0.994, 1.021 }, { 0, 0.37, 0.91, 1.43 }
local MOTOR_VOL, MOTOR_FLOOR, MOTOR_FADE = 0.5, 0.3, 0.05
local WIND_VOL, WIND_FULL = 0.6, 4000
local ON_ABOVE, OFF_BELOW = 0.008, 0.004
local PITCH_STEP, VOL_STEP = 0.005, 0.003
local EVERY, LOOK_S, LOOKS = 1 / 30, 0.5, 60   -- s; s between looks for sounds not in memory; looks before giving up
local looks, gone, told = 0, false, false

-- another world: what wasn't found may be found there
function noise.reset() looks, gone = 0, false end

-- every loop's { pitch, volume }: motors 1..4 (a prop's speed goes with the root of its thrust), then the wind
function noise.mix(motors, speed)
    local out = {}
    for k = 1, 4 do
        local m = math.max(motors and motors[k] or 0, 0)
        local pitch = (PITCH_LOW + (PITCH_HIGH - PITCH_LOW) * math.sqrt(m)) * DETUNE[k]
        out[k] = { math.min(math.max(pitch, PITCH_MIN), PITCH_MAX),
                   MOTOR_VOL * math.min(m / MOTOR_FADE, 1) * (MOTOR_FLOOR + (1 - MOTOR_FLOOR) * math.min(m, 1) ^ 0.7) }
    end
    local s = math.min(math.max(speed or 0, 0) / WIND_FULL, 1)
    out[5] = { 0.7 + 0.7 * s, WIND_VOL * s ^ 1.3 }
    return out
end

-- The sounds on the bike's model, stopped (they go with the model). nil: not in memory yet; false: never coming, or it
-- went wrong, so this bike is silent. (A pak older than this Lua has no sounds: said once.)
local function make(d, asset)
    if gone then return false end
    local motor, wind = asset(MOTOR, UUID_MOTOR), asset(WIND, UUID_WIND)
    if not (motor and wind) then
        looks = looks + 1
        if looks >= LOOKS then
            gone = true
            log.warn("hoverbike: its sounds aren't there, the bike is silent (an old SurrounSyncArmory.pak?)")
            return false
        end
        return nil
    end
    local gs, root = util.cdo(GS), nil
    pcall(function() root = d.model.StaticMeshComponent end)
    if not (gs and root) then return false end
    local loops = {}
    for k = 1, 5 do
        local c = gs:SpawnSoundAttached(k <= 4 and motor or wind, root, FName("None"), { X = 0, Y = 0, Z = 0 },
            { Pitch = 0, Yaw = 0, Roll = 0 }, 0, true, 0, 1, START[k] or 0, nil, nil, false)
        if not util.valid(c) then error("no sound component") end
        c:Stop()
        loops[k] = { comp = c, on = false, pitch = 1, vol = 0, start = START[k] or 0 }
    end
    log.info("hoverbike: its motors are heard on " .. tostring(util.fname(d.car)))
    return { loops = loops, wait = 0 }
end

local function sound_loop(l, pitch, vol)
    local on = vol >= (l.on and OFF_BELOW or ON_ABOVE)
    if math.abs(pitch - l.pitch) >= PITCH_STEP then
        l.pitch = pitch
        l.comp:SetPitchMultiplier(pitch)
    end
    if math.abs(vol - l.vol) >= VOL_STEP or on ~= l.on then
        l.vol = vol
        l.comp:SetVolumeMultiplier(vol)
    end
    if on ~= l.on then
        l.on = on
        if on then l.comp:Play(l.start) else l.comp:Stop() end
    end
end

local function step(d, dt, asset)
    if d.noise == nil then
        local t = os.clock()
        if t < (d.noise_at or 0) then return end
        d.noise_at = t + LOOK_S
        d.noise = make(d, asset)
    end
    local n = d.noise
    if not n then return end
    n.wait = n.wait - dt
    if n.wait > 0 then return end
    n.wait = EVERY
    local mix = noise.mix(d.motors, d.speed)
    for k, l in ipairs(n.loops) do
        if util.valid(l.comp) then sound_loop(l, mix[k][1], mix[k][2]) end
    end
end

-- d.motors and d.speed as they stand now. Whatever goes wrong takes only the sound.
function noise.hear(d, dt, asset)
    local ok, err = pcall(step, d, dt, asset)
    if not ok then
        d.noise = false
        if not told then
            told = true
            log.warn("hoverbike: its sound went wrong: " .. tostring(err))
        end
    end
end

-- every loop stopped
function noise.quiet(d)
    local n = d.noise
    if not n then return end
    pcall(function()
        for _, l in ipairs(n.loops) do
            if util.valid(l.comp) then sound_loop(l, l.pitch, 0) end
        end
    end)
end

return noise
