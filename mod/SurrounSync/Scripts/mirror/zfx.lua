-- Zombie archetype effects on copies.
-- A copy only runs the host zombie's Archetype_ function when this game ran it itself lately (calling it
-- from Lua could load assets on the spot - a guest froze), and copies never roll archetypes, so most copies
-- showed none of it. Running it would also start the archetype's gameplay timers on the copy (radiation
-- aura, the grenadier's proximity blast) - damage the host's zombie already deals. So copies get the looks
-- only: the acidic drool, the radiated mist, the sprinter's run. The death blasts (grenadier, radiated)
-- happen in the host's game: the host sends them and the guest plays the explosion on the copy.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local events = require("mirror.events")

local zfx = {}

local MZ = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"
local GS = "/Script/Engine.Default__GameplayStatics"
local NIAGARA = "/Script/Niagara.Default__NiagaraFunctionLibrary"
local A = {
    spit = "/Game/FX/Blood/NS_BloodSpit.NS_BloodSpit",
    mist = "/Game/PolygonFiles/PolygonApocalypse/ParticleFX/FX_ZombieRadiationMist.FX_ZombieRadiationMist",
    run = "/Game/AI/Zombies/Infected/ZombieInfectedAILocomotion.ZombieInfectedAILocomotion",
    boom = "/Game/PolygonFiles/PolygonMilitary/FX/FX_Explosion_Grenadier.FX_Explosion_Grenadier",
    boom_cue = "/Game/Audio/WARFARE_SOUNDS/Explosion_Fire_Gas/Cues/explosion_large_06_Cue.explosion_large_06_Cue",
    burn = "/Game/Blueprints/Other/ExplosiveBarrel/M_Burn.M_Burn",
    rad_boom = "/Game/PolygonFiles/PolygonMilitary/FX/FX_Explosion_RadiatedZombie.FX_Explosion_RadiatedZombie",
}
-- archetype numbers as in zombies.lua ARCH
local SPRINTER, RADIATED, ACIDIC, GRENADIER = 1, 2, 3, 5
-- the game's special death waits 1.3-1.6 s before the radiated blast
local RAD_DELAY = 1.45

local role, zombies
local channel = events.reliable("zfx")
local hook_in = 0.0
local later = {}
local stats = { looks = 0, sent = 0, played = 0, missing = 0 }

local function asset(key)
    local o
    pcall(function() o = StaticFindObject(A[key]) end)
    -- only what the game has loaded already: never load from here (see the header)
    if util.valid(o) then return o end
    stats.missing = stats.missing + 1
    return nil
end

-- Looks for a copy whose host zombie has archetype `arch` that the copy itself didn't run. Once per copy.
function zfx.looks(c, arch)
    local z = c and c.z
    if not util.valid(z) or c.fx_arch == arch then return end
    c.fx_arch = arch
    local done = false
    if arch == ACIDIC then
        local ns = asset("spit")
        if ns then pcall(function()
            local fx = util.cdo(NIAGARA):SpawnSystemAttached(ns, z.Mesh, FName("mouth"), { X = 0, Y = 0, Z = 0 },
                { Pitch = 0, Yaw = 0, Roll = 0 }, 0, false, true, 0, true)
            if util.valid(fx) then z.BloodSpitFX = fx; done = true end
        end) end
    elseif arch == RADIATED then
        local ps = asset("mist")
        if ps then pcall(function()
            local fx = util.cdo(GS):SpawnEmitterAttached(ps, z:K2_GetRootComponent(), FName("None"), { X = 0, Y = 0, Z = 0 },
                { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }, 0, false, 0, true)
            if util.valid(fx) then z.ZombieMist = fx; done = true end
        end) end
    elseif arch == SPRINTER then
        local bs = asset("run")
        if bs then done = pcall(function() z.SD_AIComponent.MovementBlendspace = bs end) end
    end
    if done then
        stats.looks = stats.looks + 1
        if stats.looks <= 5 then log.info("zfx: copy shows the host's archetype " .. arch .. " (looks only)") end
    end
end

-- Host: a zombie's death blast.
local function send_blast(kind, z)
    local id = zombies.host_id_of(z)
    if not id then return end
    local l
    pcall(function() l = z.Mesh:K2_GetComponentLocation() end)
    if not l then return end
    channel:send(string.format("%s %d %.0f %.0f %.0f", kind, id, l.X, l.Y, l.Z))
    stats.sent = stats.sent + 1
end
local grenadier_fn = function(self)
    util.safe(function() local z = util.obj(self); if z then send_blast("G", z) end end, "zfx.grenadier")
end
-- bound to every zombie's DeathEvent; only the radiated one blasts, and not after a headshot
local special_fn = function(self, Headshot)
    util.safe(function()
        local z = util.obj(self)
        local hs = false
        pcall(function() hs = Headshot:get() == true end)
        if not z or hs then return end
        if zombies._look.arch_of(z, util.fname(z)) == RADIATED then send_blast("R", z) end
    end, "zfx.special")
end

local function play(kind, loc)
    local gs = util.cdo(GS)
    local ctx = game.player()
    if not (gs and util.valid(ctx)) then return end
    local rot = { Pitch = 0, Yaw = math.random() * 360, Roll = 0 }
    if kind == "G" then
        local fx, cue, burn = asset("boom"), asset("boom_cue"), asset("burn")
        local s = 1 + math.random() * 0.25
        if fx then pcall(function() gs:SpawnEmitterAtLocation(ctx, fx, loc, rot, { X = s, Y = s, Z = s }, true, 0, true) end) end
        if cue then pcall(function() gs:PlaySoundAtLocation(ctx, cue, loc, { Pitch = 0, Yaw = 0, Roll = 0 }, 1.0, 1.0, 0.0, nil, nil, nil, nil) end) end
        if burn then pcall(function()
            gs:SpawnDecalAtLocation(ctx, burn, { X = 400, Y = 800, Z = 800 }, loc, { Pitch = -90, Yaw = rot.Yaw, Roll = 0 }, 0)
        end) end
    else
        -- (its sound, Infected_SpecialCue, already reaches the guest through audio.lua)
        local fx = asset("rad_boom")
        if fx then pcall(function() gs:SpawnEmitterAtLocation(ctx, fx, loc, rot, { X = 1, Y = 1, Z = 1 }, true, 0, true) end) end
    end
    stats.played = stats.played + 1
end

-- Guest: the host's zombie blew up. A copy that ran the archetype itself blows up on its own death.
local function on_blast(p)
    local kind, id, x, y, z = p:match("^([GR]) (%d+) (%-?%d+) (%-?%d+) (%-?%d+)$")
    if not kind then return end
    local c = zombies.copy(tonumber(id))
    if c and c.arch_ran then return end
    local loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    if c and util.valid(c.z) then pcall(function() local l = c.z.Mesh:K2_GetComponentLocation(); loc = { X = l.X, Y = l.Y, Z = l.Z } end) end
    later[#later + 1] = { at = os.clock() + (kind == "R" and RAD_DELAY or 0.1), kind = kind, loc = loc }
end

function zfx.tick(dt)
    if not zombies then return end
    if role == "host" then
        hook_in = hook_in - dt
        if hook_in <= 0 then
            hook_in = 2.0
            util.ensure_hook(MZ .. ":GrenadierDeath", grenadier_fn)
            util.ensure_hook(MZ .. ":Event_SpecialDeath", special_fn)
        end
        channel:pump(function() end)
        return
    end
    channel:pump(function(p) util.safe(on_blast, "zfx.blast", p) end)
    local t = os.clock()
    for i = #later, 1, -1 do
        local b = later[i]
        if t >= b.at then table.remove(later, i); util.safe(play, "zfx.play", b.kind, b.loc) end
    end
end

function zfx.status()
    return string.format("zfx: looks %d, blasts sent %d, played %d, assets not loaded %d", stats.looks, stats.sent, stats.played, stats.missing)
end

function zfx.init(z, r)
    zombies, role = z, r
    later = {}
end

zfx.A = A
return zfx
