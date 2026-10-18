-- Grenades and other thrown items, and launcher projectiles, seen on both screens.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local events = require("mirror.events")

local throwables = {}

local DIR = "/Game/Blueprints/Throwables/"
local PDIR = "/Game/Inventory/Items/Other/ItemProjectiles/"
local KINDS = {
    BP_Throwable_Frag = "boom", BP_Throwable_PipeBomb = "boom", BP_Throwable_Molotov = "fire",
    BP_Throwable_NoiseMaker = "noise",
    BP_ProjectileGrenade = "boom", BP_ProjectileRocket = "boom", BP_FlareRoundProjectile = "fly", BP_ProjectileArrow = "fly",
}
local function class_path(cls)
    local d = cls:find("^BP_Throwable") and DIR or PDIR
    return d .. cls .. "." .. cls .. "_C"
end
local GS = "/Script/Engine.Default__GameplayStatics"
local HEARING = "/Script/AIModule.Default__AISense_Hearing"
local FX = {
    explosion = "/Game/PolygonFiles/PolygonMilitary/FX/FX_Explosion_New.FX_Explosion_New",
    boom_cue = "/Game/Audio/WARFARE_SOUNDS/Explosion_Fire_Gas/Cues/explosion_large_06_Cue.explosion_large_06_Cue",
    burn = "/Game/Blueprints/Other/ExplosiveBarrel/M_Burn.M_Burn",
    molotov = "/Game/PolygonFiles/PolygonApocalypse/ParticleFX/Other/ParticleFX/FX_MolotovEffect.FX_MolotovEffect",
    fire_cue = "/Game/Audio/WARFARE_SOUNDS/Explosion_Fire_Gas/Cues/MolotovFire.MolotovFire",
    firecracker = "/Game/Audio/firecracker_Cue.firecracker_Cue",
}
local SEND_EVERY = 1 / 15
local FIRE_TIME = 10.0

local cfg
local channel = events.new("throws", 32, 4)
local mine = {}
local counter = 0
local copies = {}
local made = {}
local fires = {}
local now, send_in = 0.0, 0.0
local diag_left = 5

local function short_of(a) return ((util.class_name(a) or ""):gsub("_C$", "")) end
local function loc_of(a)
    local l
    pcall(function() l = a:K2_GetActorLocation() end)
    if l and l.X == 0 and l.Y == 0 and l.Z == 0 then return nil end
    return l
end
local function fmt(l) return string.format("%.0f %.0f %.0f", l.X, l.Y, l.Z) end

local function on_begin(a)
    if not util.valid(a) or made[util.addr(a) or 0] then return end
    local kind = KINDS[short_of(a)]
    if not kind then return end
    local owner, parent, owner2, wo, inst
    local p = game.player()
    pcall(function() owner = a:GetOwner() end)
    pcall(function() owner2 = owner:GetOwner() end)
    pcall(function() parent = a:GetAttachParentActor() end)
    pcall(function() wo = a.WeaponOwner end)
    pcall(function() inst = a:GetInstigator() end)
    if not (util.same(owner, p) or util.same(parent, p) or util.same(owner2, p) or util.same(wo, p) or util.same(inst, p)) then
        if diag_left > 0 then
            diag_left = diag_left - 1
            log.info(string.format("throwables: a %s began - not ours? owner %s, attached to %s", short_of(a),
                tostring(util.class_name(owner)), tostring(util.class_name(parent))))
        end
        return
    end
    local delay = 0
    pcall(function() delay = tonumber(a.ExplosionDelay) or 0 end)
    mine[util.addr(a) or 0] = { actor = a, cls = short_of(a), kind = kind, delay = delay }
end

local function send_tick(dt)
    send_in = send_in - dt
    local send_pos = send_in <= 0
    if send_pos then send_in = SEND_EVERY end
    for k, m in pairs(mine) do
        local a = m.actor
        local alive = util.valid(a)
        if alive then pcall(function() alive = not a:IsActorBeingDestroyed() end) end
        if not m.thrown then
            if not alive then mine[k] = nil
            else
                local parent
                pcall(function() parent = a:GetAttachParentActor() end)
                if not util.valid(parent) then
                    local l = loc_of(a)
                    if l then
                        counter = counter + 1
                        m.n, m.thrown, m.at, m.last = counter, true, 0.0, l
                        channel:send(string.format("S %d %s %s", m.n, m.cls, fmt(l)))
                        log.info("throwables: threw a " .. m.cls .. " - telling the other game")
                    end
                end
            end
        else
            m.at = m.at + dt
            if alive then
                local l = loc_of(a)
                if l then m.last = l end
            end
            if not m.gone_off then
                local off = not alive
                if m.kind == "fire" then
                    local mesh
                    pcall(function() mesh = a.StaticMesh end)
                    off = off or not util.valid(mesh)
                elseif m.kind == "fly" then off = false
                elseif m.delay > 0 and m.at >= m.delay then off = true end
                if off then
                    m.gone_off = true
                    channel:send(string.format("X %d %s", m.n, fmt(m.last)))
                elseif send_pos and alive then
                    channel:send(string.format("P %d %s", m.n, fmt(m.last)))
                end
            end
            if not alive then
                channel:send(string.format("E %d", m.n))
                mine[k] = nil
            end
        end
    end
end

local function noise(loc, range)
    local h = util.cdo(HEARING)
    local by = ghost.get() or game.player()
    if h and by then pcall(function() h:ReportNoiseEvent(by, loc, 1.0, by, range, FName("Noise")) end) end
end

local function go_off(cls, loc)
    local gs = util.cdo(GS)
    local ctx = game.player()
    if not (gs and ctx) then return end
    local kind = KINDS[cls]
    local rot = { Pitch = 0, Yaw = math.random() * 360, Roll = 0 }
    local down = { Pitch = -90, Yaw = math.random() * 360, Roll = 0 }
    local zero = { Pitch = 0, Yaw = 0, Roll = 0 }
    local function find(k) local o = StaticFindObject(FX[k]); return util.valid(o) and o or nil end
    if kind == "boom" then
        local s = 1.0 + math.random() * 0.25
        local fx, cue, burn = find("explosion"), find("boom_cue"), find("burn")
        if fx then pcall(function() gs:SpawnEmitterAtLocation(ctx, fx, loc, rot, { X = s, Y = s, Z = s }, true, 0, true) end) end
        if cue then pcall(function() gs:PlaySoundAtLocation(ctx, cue, loc, zero, 1.0, 1.0, 0.0, nil, nil, nil, nil) end) end
        if burn then pcall(function() gs:SpawnDecalAtLocation(ctx, burn, { X = 400, Y = 800, Z = 800 }, loc, down, 30.0) end) end
        noise(loc, 7500)
    elseif kind == "fire" then
        local fx, cue, burn = find("molotov"), find("fire_cue"), find("burn")
        local f = { ["until"] = now + FIRE_TIME }
        if fx then pcall(function() f.emitter = gs:SpawnEmitterAtLocation(ctx, fx, loc, rot, { X = 1, Y = 1, Z = 1 }, true, 0, true) end) end
        if cue then
            pcall(function() f.sound = gs:SpawnSoundAtLocation(ctx, cue, loc, zero, 1.0, 1.0, 0.0, nil, nil, true) end)
        end
        if burn then pcall(function() gs:SpawnDecalAtLocation(ctx, burn, { X = 400, Y = 1000, Z = 1000 }, loc, down, 30.0) end) end
        fires[#fires + 1] = f
        noise(loc, 1000)
    elseif kind == "noise" then
        local s = 0.1 + math.random() * 0.1
        local fx, cue = find("explosion"), find("firecracker")
        if fx then pcall(function() gs:SpawnEmitterAtLocation(ctx, fx, loc, rot, { X = s, Y = s, Z = s }, true, 0, true) end) end
        if cue then pcall(function() gs:PlaySoundAtLocation(ctx, cue, loc, zero, 1.0, 1.0, 0.0, nil, nil, nil, nil) end) end
        noise(loc, 15000)
    end
    log.info("throwables: the other player's " .. cls .. " went off")
end

local function remove_copy(n)
    local c = copies[n]
    copies[n] = nil
    if c and util.valid(c.actor) then
        made[util.addr(c.actor) or 0] = nil
        pcall(function() c.actor:K2_DestroyActor() end)
    end
end

local function make_copy(n, cls, loc)
    local uc = StaticFindObject(class_path(cls))
    if not util.valid(uc) then log.info("throwables: the other player threw a " .. cls .. " - not loaded here, not shown"); return end
    local a
    local ok, err = pcall(function() a = game.world():SpawnActor(uc, loc, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if not (ok and util.valid(a)) then log.warn("throwables: couldn't show the other player's " .. cls .. ": " .. tostring(err)); return end
    made[util.addr(a) or 0] = true
    pcall(function() a.Capsule:SetSimulatePhysics(false) end)
    pcall(function() a.Capsule:SetCollisionEnabled(0) end)
    pcall(function() a.StaticMesh:SetCollisionEnabled(0) end)
    pcall(function() a.ProjectileMovement:StopMovementImmediately() end)
    pcall(function() a.ProjectileMovement:Deactivate() end)
    pcall(function() a:SetActorEnableCollision(false) end)
    copies[n] = { actor = a, cls = cls, to = loc }
end

local function apply(p)
    local k = p:sub(1, 1)
    if k == "S" then
        local n, cls, x, y, z = p:match("^S (%d+) (%S+) (%S+) (%S+) (%S+)$")
        if n and KINDS[cls] then
            remove_copy(n)
            make_copy(n, cls, { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) })
        end
    elseif k == "P" then
        local n, x, y, z = p:match("^P (%d+) (%S+) (%S+) (%S+)$")
        local c = n and copies[n]
        if c then c.to = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } end
    elseif k == "X" then
        local n, x, y, z = p:match("^X (%d+) (%S+) (%S+) (%S+)$")
        local c = n and copies[n]
        if c then
            local loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
            if loc.X == 0 and loc.Y == 0 and loc.Z == 0 then loc = loc_of(c.actor) or c.to end
            go_off(c.cls, loc)
            remove_copy(n)
        end
    elseif k == "E" then
        local n = p:match("^E (%d+)$")
        if n then remove_copy(n) end
    end
end

local function follow(dt)
    local f = math.min(1.0, dt * 20)
    for n, c in pairs(copies) do
        if not util.valid(c.actor) then copies[n] = nil
        else
            local l = loc_of(c.actor)
            if l and c.to then
                local t = { X = l.X + (c.to.X - l.X) * f, Y = l.Y + (c.to.Y - l.Y) * f, Z = l.Z + (c.to.Z - l.Z) * f }
                pcall(function() util.move(c.actor, t, 0) end)
            end
        end
    end
    for i = #fires, 1, -1 do
        local fi = fires[i]
        if now >= fi["until"] then
            pcall(function() fi.emitter:Deactivate() end)
            pcall(function() fi.sound:Deactivate() end)
            table.remove(fires, i)
        end
    end
end

local hook_in = 0.0
local begin_fn = function(self) util.safe(function() on_begin(self:get()) end, "throwables.begin") end

function throwables.tick(dt)
    if not (cfg and cfg.mirror_throwables) then return end
    now = now + dt
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 1.0
        for cls in pairs(KINDS) do util.ensure_hook(class_path(cls) .. ":ReceiveBeginPlay", begin_fn) end
    end
    util.safe(send_tick, "throwables.send", dt)
    channel:pump(function(p) util.safe(apply, "throwables.apply", p) end)
    util.safe(follow, "throwables.follow", dt)
end

function throwables.status()
    local m, c = 0, 0
    for _ in pairs(mine) do m = m + 1 end
    for _ in pairs(copies) do c = c + 1 end
    return string.format("throwables: thrown %d, mine now %d | the other player's flying %d, fires %d", counter, m, c, #fires)
end

function throwables.init(c) cfg = c end

return throwables
