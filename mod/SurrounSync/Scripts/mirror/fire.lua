-- Gunshots, bullet impacts, blood and weapon lights of the other player.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local look = require("mirror.look")
local events = require("mirror.events")

local fire = {}

local FIREARM = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C"
local GS = "/Script/Engine.Default__GameplayStatics"
local HEARING = "/Script/AIModule.Default__AISense_Hearing"

local cfg, role
local shots = events.new("fire", 32, 2)
local hooked = false
local check_in = 0.0
local stats = { sent = 0, played = 0 }
local fix_lasers
local lasers_follow_aim

local function path_of(obj)
    if not util.valid(obj) then return nil end
    local p
    pcall(function() p = obj:GetFullName():match("^%S+ (.+)$") end)
    return p
end

local cache = {}
local function find(p)
    if not p or p == "-" then return nil end
    local o = cache[p]
    if util.valid(o) then return o end
    o = StaticFindObject(p)
    if util.valid(o) then cache[p] = o; return o end
    return nil
end

local function on_weapon_effects(self, EmitterTemplate)
    local w = self:get()
    local p, owner, parent = game.player(), nil, nil
    pcall(function() owner = w:GetOwner() end)
    pcall(function() parent = w:GetAttachParentActor() end)
    if not (util.same(owner, p) or util.same(parent, p)) then return end
    fire.last_shot = os.clock()
    local comp, emitter
    pcall(function() comp = w.BP_WeaponsPickupComponent end)
    pcall(function() emitter = EmitterTemplate:get() end)
    if not util.valid(comp) then return end
    local suppressed = false
    pcall(function() suppressed = util.same(emitter, comp.SuppressedMuzzleFlash) end)
    local sound, radius
    pcall(function() sound = suppressed and comp.FirearmSuppressedSound or comp.FirearmSound end)
    pcall(function() radius = comp.DefaultSoundRadius end)
    radius = (tonumber(radius) or 3000) * (suppressed and 0.5 or 1.0)
    shots:send(string.format("%s %s %.0f", path_of(sound) or "-", path_of(emitter) or "-", radius))
    stats.sent = stats.sent + 1
end

local function capture_hook(self, EmitterTemplate)
    util.safe(on_weapon_effects, "fire.capture", self, EmitterTemplate)
end

local impacts = events.new("impact", 64, 2)
local FX = {
    body = "/Game/PolygonFiles/PolygonMilitary/FX/FX_BloodBodyImpact.FX_BloodBodyImpact",
    head = "/Game/PolygonFiles/PolygonMilitary/FX/FX_BloodHeadshot.FX_BloodHeadshot",
    world = "/Game/PolygonFiles/PolygonMilitary/FX/FX_WorldImpact.FX_WorldImpact",
    flesh_cue = "/Game/Audio/WARFARE_SOUNDS/Weapons/Bullets/Cues/FleshImpact_Cue.FleshImpact_Cue",
    head_cue = "/Game/Audio/Real_Recorded_Guns/Cues/Bullet_Imacts_Flybys/Head_shot/FleshHeadshot_Cue.FleshHeadshot_Cue",
    decal = "/Game/Meshes/Materials/BulletHoleDecal.BulletHoleDecal",
    concurrency = "/Game/Audio/BulletImpactConcurrency.BulletImpactConcurrency",
}
local SURFACE = { [0] = "hole", [1] = "hole", [2] = "hole", [3] = "world", [4] = "hole", [5] = "hole",
    [7] = "head", [8] = "body", [9] = "hole", [10] = "hole", [11] = "world", [12] = "world", [13] = "head",
    [14] = "body", [15] = "world", [16] = "hole", [17] = "hole", [18] = "hole" }
local impact_stats = { sent = 0, played = 0 }
local warned_fx = false

local function on_surface_hit(self, ImpactPoint, HitActor, Rotation, Surface)
    local w = self:get()
    local p, owner, parent = game.player(), nil, nil
    pcall(function() owner = w:GetOwner() end)
    pcall(function() parent = w:GetAttachParentActor() end)
    if not (util.same(owner, p) or util.same(parent, p)) then return end
    fire.last_shot = os.clock()
    local l, r, s
    pcall(function() l = ImpactPoint:get() end)
    pcall(function() r = Rotation:get() end)
    pcall(function() s = Surface:get() end)
    if not (l and r and s) then return end
    impacts:send(string.format("%d %.1f %.1f %.1f %.1f %.1f %.1f", s, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll))
    impact_stats.sent = impact_stats.sent + 1
end

local function surface_hook(self, ImpactPoint, HitActor, Rotation, Surface)
    util.safe(on_surface_hit, "fire.impact_capture", self, ImpactPoint, HitActor, Rotation, Surface)
end

local function play_impact(payload)
    local s, x, y, z, pi, ya, ro = payload:match("^(%d+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
    local kind = SURFACE[tonumber(s or "") or -1]
    if not kind then return end
    local gs, ctx = util.cdo(GS), game.player()
    if not (gs and util.valid(ctx)) then return end
    local loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    local rot = { Pitch = tonumber(pi), Yaw = tonumber(ya), Roll = tonumber(ro) }
    local zero = { Pitch = 0, Yaw = 0, Roll = 0 }
    if kind == "body" or kind == "head" then
        local fx, cue = find(kind == "body" and FX.body or FX.head), find(kind == "body" and FX.flesh_cue or FX.head_cue)
        local sc = kind == "body" and 1.0 or 0.6
        if fx then
            local ok, err = pcall(function() gs:SpawnEmitterAtLocation(ctx, fx, loc, rot, { X = sc, Y = sc, Z = sc }, true, 0, true) end)
            if not ok and not warned_fx then warned_fx = true; log.warn("fire: impact emitter failed: " .. tostring(err)) end
        elseif not warned_fx then
            warned_fx = true
            log.warn("fire: blood impact effect not loaded here: " .. (kind == "body" and FX.body or FX.head))
        end
        if cue then
            pcall(function() gs:PlaySoundAtLocation(ctx, cue, loc, zero, 1.0, 1.0, 0.0, nil, find(FX.concurrency), nil, nil) end)
        end
    else
        local rr = { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = math.random() * 360 }
        if kind == "hole" then
            local decal = find(FX.decal)
            if decal then pcall(function() gs:SpawnDecalAtLocation(ctx, decal, { X = 20, Y = 10, Z = 10 }, loc, rr, 15.0) end) end
        end
        local fx = find(FX.world)
        if fx then pcall(function() gs:SpawnEmitterAtLocation(ctx, fx, loc, rr, { X = 1, Y = 1, Z = 1 }, true, 0, true) end) end
    end
    impact_stats.played = impact_stats.played + 1
end

local function ghost_muzzle()
    for _, c in ipairs(look.components()) do
        local ok = false
        pcall(function() ok = util.valid(c) and c:DoesSocketExist(FName("Muzzle")) and c:IsVisible() end)
        if ok then return c end
    end
    return nil
end

local function play(payload)
    local sp, ep, radius = payload:match("^(%S+) (%S+) (%S+)$")
    local g = ghost.get()
    if not (g and sp) then return end
    local muzzle = ghost_muzzle()
    local loc
    if muzzle then pcall(function() loc = muzzle:GetSocketLocation(FName("Muzzle")) end) end
    if not loc then pcall(function() loc = g:K2_GetActorLocation() end) end
    if not loc then return end
    local gs = util.cdo(GS)
    local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
    local sound, emitter = find(sp), find(ep)
    if sound and gs then
        pcall(function() gs:PlaySoundAtLocation(g, sound, loc, rot, 1.0, 1.0, 0.0, nil, nil, nil, nil) end)
    end
    if emitter and muzzle and gs then
        pcall(function()
            gs:SpawnEmitterAttached(emitter, muzzle, FName("Muzzle"), { X = 0, Y = 0, Z = 0 }, rot,
                { X = 0.75, Y = 0.75, Z = 0.75 }, 0, true, 0, true)
        end)
    end
    if role == "host" then
        local hearing = util.cdo(HEARING)
        if hearing then
            pcall(function() hearing:ReportNoiseEvent(g, loc, 1.0, g, tonumber(radius) or 3000, FName("Noise")) end)
        end
    end
    stats.played = stats.played + 1
end

local hurts = events.new("hurt", 32, 2)
local hurt_stats = { sent = 0, played = 0 }
local hurt_last = -100
local hurt_warned = false

local zombies_mod
local function on_hurt(self, Damage, DamageCauser)
    if not util.same(self:get(), game.player()) then return end
    local amt, causer = 0, nil
    pcall(function() amt = Damage:get() end)
    pcall(function() causer = DamageCauser:get() end)
    zombies_mod = zombies_mod or require("mirror.zombies")
    if causer and zombies_mod.is_copy(causer) then return end
    if not util.valid(causer) or util.same(causer, game.player()) then return end
    local owner
    pcall(function() owner = causer:GetOwner() end)
    if util.same(owner, game.player()) or util.same(owner, game.controller()) then return end
    if not (amt and amt > 0) or os.clock() - hurt_last < 0.25 then return end
    local can = true
    pcall(function() can = game.player().MedicalComponent["CanTakeDamage?"] ~= false end)
    if not can then return end
    hurt_last = os.clock()
    hurts:send(string.format("%.1f", amt))
    hurt_stats.sent = hurt_stats.sent + 1
end

local function play_hurt(payload)
    local g = ghost.get()
    local gs, ctx = util.cdo(GS), game.player()
    if not (util.valid(g) and gs and util.valid(ctx)) then return end
    local loc
    pcall(function() loc = util.vec(g:K2_GetActorLocation()) end)
    if not loc then return end
    loc.Z = loc.Z + 25
    local ok = pcall(function() g:MC_BloodSplatter() end)
    if not ok then
        local fx = find(FX.body)
        local rot = { Pitch = math.random(-30, 30), Yaw = math.random(0, 359), Roll = 0 }
        if fx then pcall(function() gs:SpawnEmitterAtLocation(ctx, fx, loc, rot, { X = 0.8, Y = 0.8, Z = 0.8 }, true, 0, true) end) end
        if not hurt_warned then hurt_warned = true; log.warn("fire: ghost MC_BloodSplatter failed - using the impact effect") end
    end
    local cue = find(FX.flesh_cue)
    if cue then
        pcall(function() gs:PlaySoundAtLocation(ctx, cue, loc, { Pitch = 0, Yaw = 0, Roll = 0 }, 1.0, 1.0, 0.0, nil, find(FX.concurrency), nil, nil) end)
    end
    hurt_stats.played = hurt_stats.played + 1
    log.debug("fire: the other player got hurt (" .. payload .. ") - blood on its ghost")
end

function fire.tick(dt)
    if cfg and cfg.fix_stuck_lasers then util.safe(fix_lasers, "fire.lasers", dt) end
    if cfg and cfg.lasers_follow_aim then util.safe(lasers_follow_aim, "fire.laser_aim", dt) end
    if not (cfg and cfg.ghost.mirror_fire) then return end
    check_in = check_in - dt
    if check_in <= 0 then
        check_in = 2.0
        hooked = util.ensure_hook(FIREARM .. ":Svr_WeaponEffects", capture_hook)
        util.ensure_hook(FIREARM .. ":FireSurfaceHit", surface_hook)
    end
    shots:pump(function(payload) util.safe(play, "fire.play", payload) end)
    impacts:pump(function(payload) util.safe(play_impact, "fire.impact", payload) end)
    hurts:pump(function(payload) util.safe(play_hurt, "fire.hurt", payload) end)
end

local LASERS = { "BP_SmallTacticalLaserSightLocalAttachment_C", "BP_TacticalLaserLightComboLocalAttachment_C" }
local laser_in, laser_fixed = 0.0, 0
local LIST_EVERY = 20.0
local laser_list, list_in, list_idx = {}, 0.0, 0

fix_lasers = function(dt)
    list_in = list_in - dt
    if list_in <= 0 then
        list_in = LIST_EVERY
        list_idx = list_idx % #LASERS + 1
        laser_list[list_idx] = FindAllOf(LASERS[list_idx]) or {}
        return
    end
    laser_in = laser_in - dt
    if laser_in > 0 then return end
    laser_in = 0.5
    local p = game.player()
    if not util.valid(p) then return end
    for i = 1, #LASERS do
        for _, l in ipairs(laser_list[i] or {}) do
            local on = false
            if util.valid(l) then pcall(function() on = l.NS_LaserSight:IsActive() end) end
            if on then
                local weapon, socket
                pcall(function() weapon = l:GetAttachParentActor() end)
                if not util.valid(weapon) then pcall(function() weapon = l:GetOwner() end) end
                local holder
                pcall(function() holder = weapon:GetAttachParentActor() end)
                pcall(function() socket = weapon:K2_GetRootComponent().AttachSocketName:ToString() end)
                if util.same(holder, p) and socket and not socket:lower():find("hand", 1, true) then
                    local ok = pcall(function() l.NS_LaserSight:Deactivate() end)
                    pcall(function() l.PointLight:SetIntensity(0) end)
                    pcall(function()
                        util.cdo("/Script/Engine.Default__KismetSystemLibrary"):K2_ClearAndInvalidateTimerHandle(l, l.LaserTimer)
                    end)
                    laser_fixed = laser_fixed + 1
                    log.info(string.format("fire: switched off a laser left on by a holstered gun (socket %s): %s", socket, tostring(ok)))
                end
            end
        end
    end
end

function fire.status()
    return string.format("shots sent %d, played %d | impacts sent %d, played %d | hurt sent %d, played %d",
        stats.sent, stats.played, impact_stats.sent, impact_stats.played, hurt_stats.sent, hurt_stats.played)
end

function fire.init(c, r)
    cfg, role = c, r
    game.player_hook("ReceiveAnyDamage", function(self, Damage, DamageType, InstigatedBy, DamageCauser)
        util.safe(on_hurt, "fire.hurt_capture", self, Damage, DamageCauser)
    end)
    log.info("fire: mirroring gunshots" .. (role == "host" and " (+ guest gunfire noise for zombies)" or ""))
end

local was_ads, driven = false, {}
local function laser_in_hand(l, p)
    local weapon, holder, socket
    pcall(function() weapon = l:GetAttachParentActor() end)
    if not util.valid(weapon) then pcall(function() weapon = l:GetOwner() end) end
    pcall(function() holder = weapon:GetAttachParentActor() end)
    pcall(function() socket = weapon:K2_GetRootComponent().AttachSocketName:ToString() end)
    return util.same(holder, p) and socket ~= nil and socket:lower():find("hand", 1, true) ~= nil
end
local function laser_off(l)
    pcall(function() l.NS_LaserSight:Deactivate() end)
    pcall(function() l.PointLight:SetIntensity(0) end)
    pcall(function() util.cdo("/Script/Engine.Default__KismetSystemLibrary"):K2_ClearAndInvalidateTimerHandle(l, l.LaserTimer) end)
end
local LASER_REFRESH = 0.5
local in_hand, refresh_in = {}, 0.0
local end_out = {}
local beam_end = nil
lasers_follow_aim = function(dt)
    local p = game.player()
    if not p then return end
    local ads = false
    pcall(function() ads = p["IsADS?"] == true end)
    refresh_in = refresh_in - (dt or 0)
    local changed = ads ~= was_ads
    was_ads = ads
    if not (changed or refresh_in <= 0) then
        if not ads then return end
        for _, l in pairs(driven) do
            if util.valid(l) then
                for k in pairs(end_out) do end_out[k] = nil end
                pcall(function() l:LaserEndPoint(end_out) end)
                local v = end_out.Vector or (end_out.X and end_out)
                if v then
                    beam_end = beam_end or FName("User.Beam End")
                    pcall(function() l.NS_LaserSight:SetVectorParameter(beam_end, v) end)
                end
            end
        end
        return
    end
    refresh_in = LASER_REFRESH
    for i = #in_hand, 1, -1 do in_hand[i] = nil end
    for i = 1, #LASERS do
        for _, l in ipairs(laser_list[i] or {}) do
            if util.valid(l) and laser_in_hand(l, p) then in_hand[#in_hand + 1] = l end
        end
    end
    if ads and changed and #in_hand == 0 then
        for i = 1, #LASERS do laser_list[i] = FindAllOf(LASERS[i]) or {} end
        for i = 1, #LASERS do
            for _, l in ipairs(laser_list[i]) do if util.valid(l) and laser_in_hand(l, p) then in_hand[#in_hand + 1] = l end end
        end
    end
    local keep = {}
    for _, l in ipairs(in_hand) do
        local k = util.addr(l) or 0
        local on = false
        pcall(function() on = l.NS_LaserSight:IsActive() end)
        if ads then
            if not on then
                pcall(function() l.NS_LaserSight:Activate(true) end)
                pcall(function() l.PointLight:SetIntensity(250.0) end)
                driven[k] = l
            end
            if driven[k] then keep[k] = l end
        elseif on then
            laser_off(l)
        end
    end
    for k, l in pairs(driven) do
        if not keep[k] and util.valid(l) then laser_off(l) end
    end
    driven = keep
end

return fire
