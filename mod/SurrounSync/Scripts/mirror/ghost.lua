-- The other player's character in this world (the "ghost"): spawning, moving and keeping it
-- out of saves and AI logic it shouldn't be part of.

local log = require("mirror.log")
local util = require("mirror.util")

local ghost = {}

local cfg
local actor = nil
local addr = nil
local crouched = false
local move_speed, move_crouch, move_sprint = nil, nil, nil
local water_off, swim_shown = nil, nil
local sit_shown, sit_retry = false, 0.0
local generation = 0
local view = nil
local combat_state = nil
local we_registered_invoker = false
local kind = nil

local EMS = "/Script/EasyMultiSave.Default__EMSFunctionLibrary"

function ghost.configure(c) cfg = c end

function ghost.get()
    if actor and util.valid(actor) then return actor end
    actor, addr = nil, nil
    return nil
end

-- The world it stood in is gone: forget it without touching it.
local aio_sub = nil
function ghost.forget()
    actor, addr, view, kind, aio_sub = nil, nil, nil, nil, nil
    generation = generation + 1
end

function ghost.exists() return ghost.get() ~= nil end

function ghost.generation() return ghost.exists() and generation or nil end

function ghost.is(obj)
    return addr ~= nil and util.addr(obj) == addr
end

-- Ghosts destroyed in the last GONE_S (one stays IsValid until the garbage collection ~61 s later, and
-- IsActorBeingDestroyed reads false once the destroy is done): a save check took it for a stray body and destroyed it
-- again - another player's link at nearly every save with 3 players, and my own autosave 5 s after the other player
-- died (live 2026-10-30 02:28:37). Several: a death, a save and a respawn can each destroy one within a minute.
local GONE_S = 90.0
local gone = {}               -- address -> os.clock() of its destroy
local released = nil          -- zombies let go for a save: { addrs = { [address] = true }, at = os.clock() }
local retarget                -- (below, used by ghost.spawn)
function ghost.was(obj)
    local t = gone[util.addr(obj) or 0]
    return t ~= nil and os.clock() - t < GONE_S
end

local function at_origin(l) return math.abs(l.X) < 1 and math.abs(l.Y) < 1 and math.abs(l.Z) < 1 end

-- The game destroyed the ghost itself (no root component, or it reads its location as 0,0,0 - a destroyed actor stays
-- IsValid until the garbage collection ~1 min later). Report 2026-10-30, Realm: after the guest's respawn at a bed the
-- host stayed invisible to them, and both teleports to the host in the next 45 s went to the world's origin.
local function removed(g)
    local root, l
    pcall(function() root = g:K2_GetRootComponent() end)
    if not util.valid(root) then return true end
    pcall(function() l = g:K2_GetActorLocation() end)
    return l ~= nil and at_origin(l)
end

local function load_class()
    local cls = StaticFindObject(cfg.ghost.class)
    if not util.valid(cls) then
        pcall(function() LoadAsset(cfg.ghost.class) end)
        cls = StaticFindObject(cfg.ghost.class)
    end
    return util.valid(cls) and cls or nil
end

-- The ghost is a real player character: never possess it, and keep it out of saves
-- (its ActorPreSave would write its data into our player's save).
local function contain(g)
    util.safe(function() g.MedicalComponent["CanTakeDamage?"] = false end, "ghost.CanTakeDamage")
    util.safe(function() g["ShowStartingQuests?"] = false end, "ghost.ShowStartingQuests")
    util.safe(function() util.cdo(EMS):SetActorSaveProperties(g, true, false, true, 0) end, "ghost.SetActorSaveProperties")
    util.safe(function()
        g.CharacterMovement.bRunPhysicsWithNoController = cfg.ghost.run_physics_no_controller
    end, "ghost.bRunPhysicsWithNoController")
end

function ghost.optimizer()
    if util.valid(aio_sub) then return aio_sub end
    local sub = FindFirstOf("AIOptimizerSubsystem")
    aio_sub = util.valid(sub) and sub or nil
    return aio_sub
end

-- How many AI the AI optimizer has spawned in this game right now (-1 = unknown).
function ghost.ai_count()
    local sub, n = ghost.optimizer(), -1
    if sub then pcall(function() n = sub.SpawnedSubjects:GetArrayNum() end) end
    return n
end

function ghost.invoker_index()
    local g, sub = ghost.get(), ghost.optimizer()
    if not (g and sub) then return -1 end
    local idx = -1
    pcall(function() idx = sub:GetInvokerIndex(g.AIOInvoker) end)
    return idx
end

-- P8 load split (host): out of the optimizer, the ghost no longer keeps AI alive or spawning around the
-- guest (the host's game despawns them as if nobody were there); back in on a merge. Returns the index after.
function ghost.set_invoker(on)
    local g, sub = ghost.get(), ghost.optimizer()
    if not (g and sub) then return -1 end
    local idx = ghost.invoker_index()
    if on and idx < 0 then
        local ok = false
        pcall(function() ok = sub:RegisterInvoker(g.AIOInvoker) end)
        if ok then we_registered_invoker = true end
    elseif not on and idx >= 0 then
        pcall(function() sub:UnregisterInvoker(g.AIOInvoker) end)
        we_registered_invoker = false
    end
    return ghost.invoker_index()
end

local function ensure_invoker()
    local before = ghost.invoker_index()
    if before >= 0 or not cfg.ghost.register_invoker then
        log.info("ghost: AIOInvoker index after spawn = " .. tostring(before) .. (before >= 0 and " (auto-registered)" or " (NOT registered)"))
        return
    end
    local ok = false
    pcall(function() ok = ghost.optimizer():RegisterInvoker(actor.AIOInvoker) end)
    we_registered_invoker = ok == true
    log.info(string.format("ghost: AIOInvoker was NOT registered; RegisterInvoker -> %s, index now %d",
        tostring(ok), ghost.invoker_index()))
end

local function report(g)
    local tag, dead, cantake, physics = "?", "?", "?", "?"
    pcall(function() tag = tostring(g:ActorHasTag(FName(cfg.ghost.target_tag))) end)
    pcall(function() dead = tostring(g["PlayerDead?"]) end)
    pcall(function() cantake = tostring(g.MedicalComponent["CanTakeDamage?"]) end)
    pcall(function() physics = tostring(g.CharacterMovement.bRunPhysicsWithNoController) end)
    local ctrl = "none"
    pcall(function() if util.valid(g.Controller) then ctrl = util.class_name(g.Controller) end end)
    log.info(string.format("ghost: %s=%s PlayerDead?=%s CanTakeDamage?=%s runPhysicsNoController=%s controller=%s",
        cfg.ghost.target_tag, tag, dead, cantake, physics, ctrl))
end

function ghost.kind() return ghost.exists() and kind or nil end

local ECR_IGNORE, ECR_BLOCK, ECC_PAWN, ECC_VEHICLE, NO_COLLISION, QUERY_ONLY = 0, 2, 2, 6, 0, 1
local ECC_WORLD_STATIC, ECC_WORLD_DYNAMIC, ECC_PHYSICS_BODY = 0, 1, 5
local function capsule_body(g)
    util.safe(function()
        local cap = g.CapsuleComponent
        -- queries only, no physics body: the capsule is moved by teleports, and a physics body put into a car's
        -- body (getting in or out, or a little lag next to it) shoved the car out of it - that flung parked cars
        -- (2026-10-24). Its movement's floor and wall sweeps are queries, so it still stands and walks on things.
        cap:SetCollisionEnabled(QUERY_ONLY)
        cap:SetCollisionResponseToAllChannels(ECR_IGNORE)
        -- ECC_VEHICLE too: without it the ghost had no floor on a car roof and floated there in its falling pose
        -- while its player stood on the car (user 2026-10-30)
        for _, ch in ipairs({ ECC_PAWN, ECC_WORLD_STATIC, ECC_WORLD_DYNAMIC, ECC_PHYSICS_BODY, ECC_VEHICLE }) do
            cap:SetCollisionResponseToChannel(ch, ECR_BLOCK)
        end
    end, "ghost.capsule")
    -- nor do its steps push a car (or anything simulated) it walks into or stands on: only in my world, out of sync
    pcall(function() g.CharacterMovement.bEnablePhysicsInteraction = false end)
end
local PARTS = { "Torso", "Arms", "Biceps", "Hands", "Legs", "LowerLegs", "LowerThighs", "Feet", "Head", "Clothing_Torso",
                "Clothing_Legs", "Clothing_Feet", "Clothing_Gloves", "Clothing_Armor", "HairMesh", "BeardMesh",
                "EyebrowsMesh", "Mouth", "Accessory1", "Accessory2", "Accessory3" }
local function parts_off(g)
    for _, n in ipairs(PARTS) do
        pcall(function() local c = g[n]; if util.valid(c) then c:SetCollisionEnabled(NO_COLLISION) end end)
    end
end
local ECC_VISIBILITY = 3
local function make_target_body(g)
    capsule_body(g)
    parts_off(g)
    util.safe(function()
        g.Mesh:SetCollisionEnabled(QUERY_ONLY)
        g.Mesh:SetCollisionResponseToAllChannels(ECR_IGNORE)
        g.Mesh:SetCollisionResponseToChannel(ECC_VISIBILITY, ECR_BLOCK)
    end, "ghost.mesh")
end
local function make_cosmetic(g)
    capsule_body(g)
    parts_off(g)
    util.safe(function() g.Mesh:SetCollisionEnabled(NO_COLLISION) end, "ghost.collision")
    util.safe(function() g.Tags:Empty() end, "ghost.tags")
    local idx = ghost.invoker_index()
    if idx >= 0 then
        pcall(function() ghost.optimizer():UnregisterInvoker(g.AIOInvoker) end)
    end
    local tag = "?"
    pcall(function() tag = tostring(g:ActorHasTag(FName(cfg.ghost.target_tag))) end)
    log.info(string.format("ghost: cosmetic (guest) - blocks players and the world only, %s=%s, invoker index %d -> %d",
        cfg.ghost.target_tag, tag, idx, ghost.invoker_index()))
end

-- Back to the non-PvP mesh setup for this ghost's kind (pvp.lua makes the mesh hittable).
function ghost.restore_mesh()
    local g = ghost.get()
    if not g then return end
    if kind == "guest" then
        util.safe(function() g.Mesh:SetCollisionEnabled(NO_COLLISION) end, "ghost.collision")
    else
        util.safe(function()
            g.Mesh:SetCollisionEnabled(QUERY_ONLY)
            g.Mesh:SetCollisionResponseToAllChannels(ECR_IGNORE)
            g.Mesh:SetCollisionResponseToChannel(ECC_VISIBILITY, ECR_BLOCK)
        end, "ghost.mesh")
    end
end

function ghost.spawn(world, loc, yaw, k)
    if ghost.exists() then return ghost.get() end
    local cls = load_class()
    if not cls then log.error("ghost: class not loadable: " .. cfg.ghost.class); return nil end
    local ok, g = pcall(function()
        return world:SpawnActor(cls, { X = loc.X, Y = loc.Y, Z = loc.Z + 20 }, { Pitch = 0, Yaw = yaw or 0, Roll = 0 })
    end)
    if not (ok and util.valid(g)) then
        log.error("ghost: SpawnActor failed: " .. tostring(g)); return nil
    end
    actor, addr = g, util.addr(g)
    generation = generation + 1
    crouched = false
    move_speed, move_crouch, move_sprint = nil, nil, nil
    water_off, swim_shown = nil, nil
    sit_shown, sit_retry = false, 0.0
    combat_state = nil
    we_registered_invoker = false
    kind = k or "host"
    contain(g)
    log.info(string.format("ghost: spawned %s (%s) at (%.0f, %.0f, %.0f)", g:GetFullName(), kind, loc.X, loc.Y, loc.Z))
    report(g)
    if kind == "guest" then make_cosmetic(g); released = nil else
        make_target_body(g); ensure_invoker()
        local n = 0
        util.safe(function() n = retarget(g) end, "ghost.retarget")
        if n > 0 then log.info("ghost: " .. n .. " zombie(s) after it again (they were before the save)") end
    end
    if cfg.ghost.view_controller then util.safe(function() ghost.attach_view(world, g) end, "ghost.view") end
    return g
end

function ghost.attach_view(world, g)
    local cls = StaticFindObject("/Script/AIModule.AIController")
    if not util.valid(cls) then log.warn("ghost: no AIController class - view rotation not mirrored"); return end
    local ok, c = pcall(function() return world:SpawnActor(cls, g:K2_GetActorLocation(), g:K2_GetActorRotation()) end)
    if not (ok and util.valid(c)) then log.warn("ghost: view controller spawn failed: " .. tostring(c)); return end
    pcall(function() util.cdo(EMS):SetActorSaveProperties(c, true, false, true, 0) end)
    local set = pcall(function() g.Controller = c end)
    view = c
    local local_ctrl = "?"
    pcall(function() local_ctrl = tostring(g:IsLocallyControlled()) end)
    log.info(string.format("ghost: view controller assigned (%s), IsLocallyControlled=%s", tostring(set), local_ctrl))
end

-- kept: addresses of the controllers let go (only numbers - their zombies may be gone by the respawn)
local function release_zombies(g, kept)
    local n = 0
    -- the zombie module's list (no 30-40 ms walk at every save); a walk only if it has none yet
    local ok_z, z = pcall(require, "mirror.zombies")
    local list = {}
    pcall(function()
        for _, p in ipairs(ok_z and z.all_cached() or {}) do
            local c = p.Controller
            if util.valid(c) then list[#list + 1] = c end
        end
    end)
    if #list == 0 then
        local ok, all = pcall(FindAllOf, "BP_ZombieAIController_C")
        if not ok or not all then return 0 end
        list = all
    end
    local at = util.vec(g:K2_GetActorLocation())
    for _, c in ipairs(list) do
        pcall(function()
            local bb = c.Blackboard
            if not util.same(bb:GetValueAsObject(FName("AttackTarget")), g) then return end
            bb:SetValueAsBool(FName("CanSeePlayer?"), false)
            bb:ClearValue(FName("AttackTarget"))
            c.Combat = false
            bb:SetValueAsBool(FName("IsAlert?"), true)
            if at and not at_origin(at) then bb:SetValueAsVector(FName("LastHeardLocation"), at) end
            n = n + 1
            if kept then kept[util.addr(c) or 0] = true end
        end)
    end
    return n
end

-- A save takes the ghost away for a second or two and puts it back where it stood: the zombies that were after it
-- go after the new one (they stood looking at its last spot, live 2026-10-30). Found again in the zombie module's
-- current list by address - no object of before the save is touched.
local RETARGET_S = 10.0
retarget = function(g)
    local r = released
    released = nil
    if not (r and os.clock() - r.at < RETARGET_S and next(r.addrs)) then return 0 end
    local ok_z, z = pcall(require, "mirror.zombies")
    if not ok_z then return 0 end
    local n = 0
    for _, p in ipairs(z.all_cached() or {}) do
        pcall(function()
            local c = p.Controller
            if not (util.valid(c) and r.addrs[util.addr(c) or 0]) then return end
            local bb = c.Blackboard
            bb:SetValueAsObject(FName("AttackTarget"), g)
            bb:SetValueAsBool(FName("CanSeePlayer?"), true)
            c.Combat = true
            n = n + 1
        end)
    end
    return n
end

local on_destroy = {}
function ghost.on_destroy(fn) on_destroy[#on_destroy + 1] = fn end

-- now: destroyed in this call even with animation tasks running (a save: a ghost kept into it takes the player's
-- inventory - mod saves close the animation gate before they start, see session.save_now)
-- by_game: the game destroyed it already (see removed): only let go of it, and its zombies go after the next one
function ghost.destroy(reason, now, by_game)
    for _, fn in ipairs(on_destroy) do util.safe(fn, "ghost.on_destroy") end
    local g = ghost.get()
    if g then
        if kind ~= "guest" then
            local n = 0
            local kept = (reason == "save" or by_game) and {} or nil
            util.safe(function() n = release_zombies(g, kept) end, "ghost.release_zombies")
            if n > 0 then log.info("ghost: " .. n .. " zombie(s) stopped chasing it") end
            released = kept and n > 0 and { addrs = kept, at = os.clock() } or nil
        end
        if we_registered_invoker then
            pcall(function() ghost.optimizer():UnregisterInvoker(g.AIOInvoker) end)
            we_registered_invoker = false
        end
        pcall(function() g.Controller = nil end)
        -- (a character with an anim graph: destroyed once animation is on the game thread - hidden and kept out of
        -- saves until then; animgate.lua, required here: game.lua requires this file)
        if by_game then -- (nothing left to destroy)
        elseif now then util.safe(function() g:K2_DestroyActor() end, "ghost.destroy")
        else util.safe(function() require("mirror.animgate").destroy(g, "ghost.destroy") end, "ghost.destroy") end
        log.info(by_game and ("ghost: " .. tostring(reason)) or ("ghost: destroyed (" .. tostring(reason) .. ")"))
        local t = os.clock()
        for a, at in pairs(gone) do if t - at >= GONE_S then gone[a] = nil end end
        if addr then gone[addr] = t end
    end
    if view and util.valid(view) then pcall(function() view:K2_DestroyActor() end) end
    view = nil
    actor, addr = nil, nil
end

function ghost.report() local g = ghost.get(); if g then report(g) end end

local seated = false
function ghost.set_seated(on) seated = on and true or false end

function ghost.apply(pose, moving)
    local g = ghost.get()
    if not g or not pose or seated then return end
    -- K2_TeleportTo refuses a spot that overlaps something; the capsule blocks cars now (it stands on roofs), so beside
    -- or on a car it was refused and the ghost stood still until the peer was 3 m (snap_distance) away. The peer stands
    -- there in their game: put it there anyway (no physics body, so an overlap shoves nothing).
    pcall(function()
        if not util.move(g, pose.loc, pose.yaw) then g:K2_SetActorLocationAndRotation(pose.loc, util.rot(0, pose.yaw, 0), false, {}, true) end
    end)
    if cfg.ghost.feed_velocity then
        local v = moving and pose.vel or { X = 0, Y = 0, Z = 0 }
        pcall(function() g.CharacterMovement.Velocity = v end)
    end
    local want_mode = pose.falling and 3 or 1
    local mode
    pcall(function() mode = g.CharacterMovement.MovementMode end)
    if mode ~= nil and mode ~= want_mode then
        pcall(function() g.CharacterMovement:SetMovementMode(want_mode, 0) end)
    end
    if cfg.ghost.mirror_crouch and pose.crouch ~= nil and pose.crouch ~= crouched then
        crouched = pose.crouch
        pcall(function() if crouched then g:Crouch(false) else g:UnCrouch(false) end end)
    end
    if cfg.ghost.mirror_aim and pose.aim then ghost.apply_aim(g, pose.aim) end
    ghost.apply_move(g, pose)
    ghost.apply_swim(g, pose)
    ghost.apply_sit(g, pose)
end

-- The floor sit (BP_PlayerCharacter IA_SitDown) plays Chr_SittingFloor_Montage on the character itself, not through
-- MC_Montage, so anim.lua never mirrors it. Its one section loops on itself until standing up stops it: played and
-- stopped here when the peer's Sitting? changes. Only that montage is stopped (a use or reload montage plays on).
local SIT_FLOOR = "/Game/Character/Anims/Interaction/Chr_SittingFloor_Montage.Chr_SittingFloor_Montage"
-- A stop-all (anim.lua when the peer's own montage ends, vehicles.lua getting out of a car) cuts the sit too, and a
-- play can come back 0 (not played): checked every SIT_RETRY_S while sitting, sat again once nothing else plays.
local SIT_RETRY_S = 1.0
function ghost.apply_sit(g, pose)
    local want = pose.sit == true
    local now = os.clock()
    if want == sit_shown then
        if not want or now < sit_retry then return end
        sit_retry = now + SIT_RETRY_S
        local cur
        if not pcall(function() cur = g:GetCurrentMontage() end) or util.valid(cur) then return end
    elseif want and now < sit_retry then return end
    local m = util.find(SIT_FLOOR)
    if not m then return end -- not loaded yet: asked again on a later pose (util.find backs off)
    if want then
        local len
        pcall(function() len = g:PlayAnimMontage(m, 1.0, FName("None")) end)
        sit_retry = now + SIT_RETRY_S
        sit_shown = len ~= 0
    else
        sit_shown, sit_retry = false, 0.0
        pcall(function() g:StopAnimMontage(m) end)
    end
end

function ghost._set_for_test(g) actor, addr = g, util.addr(g) end

-- The ghost's own SwimmingComponent (WaterDetection, every 10 ms) writes bWaterVolume onto its physics volume -
-- outside water volumes that's the world's DefaultPhysicsVolume, shared with the local player, who then swims
-- (floats) on land while the ghost is in water. Stop it and show the peer's swimming from the pose instead
-- (AnimBP_PlayerCharacter reads SwimmingComponent IsSwimming? / UnderWater?).
function ghost.apply_swim(g, pose)
    local a = util.addr(g)
    if water_off ~= a then
        local ok = pcall(function()
            util.cdo("/Script/Engine.Default__KismetSystemLibrary"):K2_ClearTimer(g.SwimmingComponent, "WaterDetection")
        end)
        if ok then water_off = a; log.info("ghost: its own water detection is off") end
    end
    local want = (pose.swim and 1 or 0) + (pose.underwater and 2 or 0)
    if want == swim_shown then return end
    swim_shown = want
    pcall(function()
        local sw = g.SwimmingComponent
        sw["IsSwimming?"] = pose.swim == true
        sw["UnderWater?"] = pose.underwater == true
    end)
end

function ghost.apply_move(g, pose)
    local m = pose.move
    if m and m.walk and m.walk > 0 and m.walk ~= move_speed then
        move_speed = m.walk
        pcall(function() g.CharacterMovement.MaxWalkSpeed = m.walk end)
    end
    if m and m.crouch and m.crouch > 0 and m.crouch ~= move_crouch then
        move_crouch = m.crouch
        pcall(function() g.CharacterMovement.MaxWalkSpeedCrouched = m.crouch end)
    end
    if pose.sprint ~= move_sprint then
        move_sprint = pose.sprint
        pcall(function() g["Sprinting?"] = pose.sprint end)
        pcall(function() g.StaminaComponent.CurrentlySprinting = pose.sprint end)
    end
    if m and m.stamina then
        pcall(function()
            local sc = g.StaminaComponent
            sc.CurrentStamina = sc.MaxStamina * math.max(0, math.min(100, m.stamina)) / 100
        end)
    end
end

function ghost.apply_aim(g, aim)
    pcall(function() g["IsADS?"] = aim.ads end)
    pcall(function() g["HipFire?"] = aim.hip end)
    pcall(function() g["InMeleeStance?"] = aim.melee end)
    if aim.lhand then pcall(function() g.LeftHandLoc = aim.lhand end) end
    if aim.lean then
        pcall(function()
            g.Lean = aim.lean
            g["LeanLeft?"] = aim.lean_side == 1
            g["LeanRight?"] = aim.lean_side == 2
        end)
    end
    if view and util.valid(view) and aim.view_yaw then
        local r = { Pitch = aim.pitch, Yaw = aim.view_yaw, Roll = 0 }
        pcall(function() view:SetControlRotation(r) end)
        pcall(function() view:K2_SetActorRotation(r, false) end)
    elseif aim.head then
        pcall(function()
            g.Mesh:GetAnimInstance().HeadRotation = { Pitch = 0, Yaw = aim.head.Yaw, Roll = aim.head.Roll }
        end)
    end
    pcall(function() g.RemoteViewPitch = math.floor(((aim.pitch % 360) * 255 / 360) + 0.5) % 256 end)
    if aim.combat ~= combat_state then
        combat_state = aim.combat
        local ok, err = pcall(function() g:UpdateCombatState(aim.combat) end)
        if not ok then log.warn("ghost: UpdateCombatState(" .. tostring(aim.combat) .. ") failed: " .. tostring(err)) end
    end
end

-- Lets go of a ghost the game destroyed (phase1 then spawns a new one); checked every CHECK_S. True when it did.
local CHECK_S, check_in = 0.5, 0.0
local function let_go_if_removed(g)
    if not removed(g) then return false end
    ghost.destroy("the game removed it - a new one follows", false, true)
    return true
end
-- The ghost is a real BP_PlayerCharacter with the game's RadiationComponent. A radiated zombie's hit or death blast
-- on it (GameFunctionLibrary.ApplyRadiationDamage -> DecreaseRadiation, decompiled) starts that component's Geiger
-- with SpawnSound2D: heard in this game at full volume at any distance, for radiation its player takes in their own
-- game (player report 2026-11-01: the host hears the guest's radiation; zombies.lua sends that hit to their game).
-- The ghost's radiation means nothing here: its Geiger is stopped and its radiation put back to full the frame it
-- starts (it fades in over 1 s), with the component's timers (the damage tick once at 0). Radiation zones never
-- radiate it (BP_RadiationArea_Sphere only takes GetPlayerCharacter(0)).
local RAD_PATH = "/Game/Blueprints/Components/RadiationComponent.RadiationComponent_C"
local rad = { cls = nil, comp = nil, of = nil, quieted = 0 }
local function quiet_radiation(g)
    if rad.of ~= addr or not util.valid(rad.comp) then
        rad.comp, rad.of = nil, addr
        rad.cls = util.valid(rad.cls) and rad.cls or StaticFindObject(RAD_PATH)
        if not util.valid(rad.cls) then return end
        pcall(function() rad.comp = g:GetComponentByClass(rad.cls) end)
        if not util.valid(rad.comp) then rad.comp = nil; return end
    end
    local c, geiger, cur, max = rad.comp, nil, nil, nil
    pcall(function() geiger = c.Geiger end)
    pcall(function() cur, max = c.CurrentRadiation, c.MaxRadiation end)
    local loud = util.valid(geiger)
    local low = type(cur) == "number" and type(max) == "number" and cur < max
    if not (loud or low) then return end
    if loud then
        pcall(function() geiger:Stop() end)
        pcall(function() geiger:K2_DestroyComponent(c) end)
    end
    if low then pcall(function() c.CurrentRadiation = max end) end
    pcall(function() c:ClearTimers() end)
    rad.quieted = rad.quieted + 1
    log.every("ghost.radiation", 10, string.format("ghost: radiation on the other player's character here (%s/%s%s) - "
        .. "put back, the Geiger is only theirs (%d time(s))", tostring(cur), tostring(max), loud and ", Geiger on" or "",
        rad.quieted))
end
ghost._rad = rad

function ghost.check(dt)
    local cur = ghost.get()
    if cur then util.safe(quiet_radiation, "ghost.radiation", cur) end
    check_in = check_in - (dt or 0)
    if check_in > 0 then return false end
    check_in = CHECK_S
    local g = ghost.get()
    return g ~= nil and let_go_if_removed(g)
end

function ghost.location()
    local g = ghost.get(); if not g then return nil end
    local ok, l = pcall(function() return g:K2_GetActorLocation() end)
    l = ok and util.vec(l) or nil
    if l and at_origin(l) and let_go_if_removed(g) then return nil end
    return l
end

return ghost
