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

function ghost.exists() return ghost.get() ~= nil end

function ghost.generation() return ghost.exists() and generation or nil end

function ghost.is(obj)
    return addr ~= nil and util.addr(obj) == addr
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
    local sub = FindFirstOf("AIOptimizerSubsystem")
    return util.valid(sub) and sub or nil
end

function ghost.invoker_index()
    local g, sub = ghost.get(), ghost.optimizer()
    if not (g and sub) then return -1 end
    local idx = -1
    pcall(function() idx = sub:GetInvokerIndex(g.AIOInvoker) end)
    return idx
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

local ECR_IGNORE, ECR_BLOCK, ECC_PAWN, QUERY_AND_PHYSICS, NO_COLLISION, QUERY_ONLY = 0, 2, 2, 3, 0, 1
local ECC_WORLD_STATIC, ECC_WORLD_DYNAMIC, ECC_PHYSICS_BODY, ECC_VEHICLE = 0, 1, 5, 6
local function capsule_body(g)
    util.safe(function()
        local cap = g.CapsuleComponent
        cap:SetCollisionEnabled(QUERY_AND_PHYSICS)
        cap:SetCollisionResponseToAllChannels(ECR_IGNORE)
        for _, ch in ipairs({ ECC_PAWN, ECC_WORLD_STATIC, ECC_WORLD_DYNAMIC, ECC_PHYSICS_BODY, ECC_VEHICLE }) do
            cap:SetCollisionResponseToChannel(ch, ECR_BLOCK)
        end
    end, "ghost.capsule")
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
    combat_state = nil
    we_registered_invoker = false
    kind = k or "host"
    contain(g)
    log.info(string.format("ghost: spawned %s (%s) at (%.0f, %.0f, %.0f)", g:GetFullName(), kind, loc.X, loc.Y, loc.Z))
    report(g)
    if kind == "guest" then make_cosmetic(g) else make_target_body(g); ensure_invoker() end
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

local function release_zombies(g)
    local n = 0
    local ok, list = pcall(FindAllOf, "BP_ZombieAIController_C")
    if not ok or not list then return 0 end
    local at = util.vec(g:K2_GetActorLocation())
    for _, c in ipairs(list) do
        pcall(function()
            local bb = c.Blackboard
            if not util.same(bb:GetValueAsObject(FName("AttackTarget")), g) then return end
            bb:SetValueAsBool(FName("CanSeePlayer?"), false)
            bb:ClearValue(FName("AttackTarget"))
            c.Combat = false
            bb:SetValueAsBool(FName("IsAlert?"), true)
            if at then bb:SetValueAsVector(FName("LastHeardLocation"), at) end
            n = n + 1
        end)
    end
    return n
end

local on_destroy = {}
function ghost.on_destroy(fn) on_destroy[#on_destroy + 1] = fn end

function ghost.destroy(reason)
    for _, fn in ipairs(on_destroy) do util.safe(fn, "ghost.on_destroy") end
    local g = ghost.get()
    if g then
        if kind ~= "guest" then
            local n = 0
            util.safe(function() n = release_zombies(g) end, "ghost.release_zombies")
            if n > 0 then log.info("ghost: " .. n .. " zombie(s) stopped chasing it") end
        end
        if we_registered_invoker then
            pcall(function() ghost.optimizer():UnregisterInvoker(g.AIOInvoker) end)
            we_registered_invoker = false
        end
        pcall(function() g.Controller = nil end)
        util.safe(function() g:K2_DestroyActor() end, "ghost.destroy")
        log.info("ghost: destroyed (" .. tostring(reason) .. ")")
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
    local cur
    pcall(function() cur = g:K2_GetActorLocation() end)
    local teleport = cur == nil or util.dist(cur, pose.loc) > cfg.ghost.snap_distance
    pcall(function()
        if not util.move(g, pose.loc, pose.yaw) and teleport then g:K2_SetActorLocationAndRotation(pose.loc, util.rot(0, pose.yaw, 0), false, {}, true) end
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

function ghost.location()
    local g = ghost.get(); if not g then return nil end
    local ok, l = pcall(function() return g:K2_GetActorLocation() end)
    return ok and util.vec(l) or nil
end

return ghost
