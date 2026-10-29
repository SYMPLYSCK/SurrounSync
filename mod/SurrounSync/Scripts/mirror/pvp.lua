-- PvP: hits on the other player's ghost hurt their real character. The host turns it on or off
-- for both players (off by default); while it is off bullets pass through the ghost as before.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local events = require("mirror.events")
local hostrules = require("mirror.hostrules")

local pvp = {}

local FIREARM = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C"
local GS = "/Script/Engine.Default__GameplayStatics"
local MAX_HIT = 400

local role
local same_world = function() return false end
local applied_on, applied_gen = nil, nil
local hits = events.new("pvp", 32, 3)
local stats = { sent = 0, taken = 0, blocked = 0 }
local check_in = 0.0
local last_surface = -100
local warned_nodmg = false

-- The host's setting (CO-OP tab -> gear) rules both games; a guest follows the host's.
function pvp.on() return hostrules.get("pvp") end

-- Make the ghost's mesh answer the same trace channels the real player's mesh blocks, so the
-- game's own weapon traces hit it. Movement/camera channels stay ignored (no shoving, no camera pop).
-- Player bodies report surface 0 to bullets, which guns treat as a wall: PlayerImpact (surface 14)
-- makes them take the flesh branch (blood + ApplyDamage on the ghost, which on_ghost_damage forwards).
local FLESH = "/Game/Blueprints/Materials/PlayerImpact.PlayerImpact"
local ECR_BLOCK, QUERY_ONLY = 2, 1
local TRACE_CHANNELS = { 3 }
for ch = 8, 25 do TRACE_CHANNELS[#TRACE_CHANNELS + 1] = ch end
local function block_like_player(g)
    local p = game.player()
    if not util.valid(p) then return nil end
    local copied = {}
    util.safe(function()
        g.Mesh:SetCollisionEnabled(QUERY_ONLY)
        for _, ch in ipairs(TRACE_CHANNELS) do
            local r = 0
            pcall(function() r = p.Mesh:GetCollisionResponseToChannel(ch) end)
            if r == ECR_BLOCK then
                g.Mesh:SetCollisionResponseToChannel(ch, ECR_BLOCK)
                copied[#copied + 1] = tostring(ch)
            end
        end
    end, "pvp.hittable")
    return copied
end
local function make_hittable(g)
    local copied = block_like_player(g)
    if not copied then return false end
    local flesh = StaticFindObject(FLESH)
    local fok = util.valid(flesh) and pcall(function() g.Mesh:SetPhysMaterialOverride(flesh) end)
    log.info("pvp: ghost mesh now blocks trace channels " .. (#copied > 0 and table.concat(copied, ",") or "(none!)")
        .. (fok and ", flesh surface on" or ", flesh surface NOT set (bullets won't hurt)"))
    return true
end

local function sync_ghost()
    local g = ghost.get()
    if not g then applied_on, applied_gen = nil, nil; return end
    local on = pvp.on()
    if on == applied_on and applied_gen == ghost.generation() then return end
    if on then
        if not make_hittable(g) then return end
    elseif applied_on then
        ghost.restore_mesh()
        pcall(function() g.Mesh:SetPhysMaterialOverride(nil) end)
        log.info("pvp: ghost mesh back to no-PvP collision")
    end
    applied_on, applied_gen = on, ghost.generation()
end

local function mine_obj(o)
    local p, pc = game.player(), game.controller()
    if not util.valid(o) then return false end
    if util.same(o, p) or util.same(o, pc) then return true end
    for _, f in ipairs({ "GetOwner", "GetInstigator" }) do
        local x
        pcall(function() x = o[f](o) end)
        if x and (util.same(x, p) or util.same(x, pc)) then return true end
    end
    return false
end

-- A hit my own character deals (stomp, push): the stomp's trace hits whatever stays at the foot again every few ms
-- (meant to finish a downed zombie), so one stomp sent 6 hits, ~200 damage (kit 2026-10-27). One per second goes.
local BODY_HIT_GAP = 1.0
local last_body_hit = -100

-- Our own hit landed on the ghost: send it to the other game.
local function on_ghost_damage(self, Damage, DamageType, InstigatedBy, DamageCauser)
    if not ghost.is(self:get()) then return end
    if not (pvp.on() and same_world()) then return end
    local causer, inst = util.obj(DamageCauser), util.obj(InstigatedBy)
    if not (mine_obj(causer) or mine_obj(inst)) then return end
    local amt = 0
    pcall(function() amt = Damage:get() end)
    if not (amt and amt > 0) then return end
    if util.same(causer, game.player()) then
        if os.clock() - last_body_hit < BODY_HIT_GAP then return end
        last_body_hit = os.clock()
    end
    local cls = util.class_path(util.obj(DamageType)) or "-"
    hits:send(string.format("%.3f %s", math.min(amt, MAX_HIT), cls))
    stats.sent = stats.sent + 1
    last_surface = -100
    log.info(string.format("pvp: my hit on the other player (%.1f, %s)", amt, cls:match("([%w_]+)$") or cls))
end

-- Diagnostics: a bullet of ours struck the ghost. If no damage follows, the game didn't count it.
local function on_surface(self, ImpactPoint, HitActor, Rotation, Surface)
    if not pvp.on() then return end
    local w = self:get()
    local owner
    pcall(function() owner = w:GetOwner() end)
    if not util.same(owner, game.player()) then return end
    local hit = util.obj(HitActor)
    if not (hit and ghost.is(hit)) then return end
    local s = -1
    pcall(function() s = Surface:get() end)
    last_surface = os.clock()
    log.debug("pvp: my bullet hit the other player's ghost (surface " .. tostring(s) .. ")")
end

local function surface_hook(...) util.safe(on_surface, "pvp.surface", ...) end

local function i_am_dead()
    local d = false
    pcall(function() d = game.player()["PlayerDead?"] == true end)
    return d
end

local function apply_hit(payload)
    local amt, cls = payload:match("^(%S+) (%S+)$")
    amt = tonumber(amt)
    if not amt or amt <= 0 then return end
    if not (pvp.on() and same_world()) or i_am_dead() then
        stats.blocked = stats.blocked + 1
        return
    end
    local p, g = game.player(), ghost.get()
    if not util.valid(p) then return end
    -- Damage_Headshot kills outright whatever the amount; the amount already carries the headshot bonus.
    if cls:find("Damage_Headshot", 1, true) then cls = cls:gsub("Damage_Headshot", "Damage_Body") end
    local dtc = util.find(cls)
    local ok, err = pcall(function() util.cdo(GS):ApplyDamage(p, math.min(amt, MAX_HIT), nil, g, dtc) end)
    stats.taken = stats.taken + 1
    if ok then log.info(string.format("pvp: the other player hit me for %.1f", amt))
    else log.warn("pvp: ApplyDamage failed: " .. tostring(err)) end
end

-- Raiders (BP_SmartAIComponent Range Attack / Basic Melee Attack Collision / Active Melee Detect, decompiled) trace
-- their attacks on the "Weapons" channel (DefaultEngine.ini: ECC_GameTraceChannel10 = 23) and take the damage from
-- the bone they hit. Without PvP the guest's ghost answers Visibility only, so their shots went through it and never
-- hurt the guest (DBG-20261028-003). While a raider has the ghost as its attack target, the mesh blocks what the
-- real player's mesh blocks - without the flesh surface, so a bullet of ours stops there like on a wall, no damage.
-- (UE4SS runs a BP function's hook after the function: Set BB Attack Target's hook reads the target it just set,
-- the poll below sees when it changes away)
local SAI = "/Game/SmartAI/Blueprints/AI/Components/BP_SmartAIComponent.BP_SmartAIComponent_C"
local COVER_POLL, MAX_HUNTERS = 0.25, 32
local hunters = {}   -- address -> SmartAI component that set the ghost as its attack target
local cover = { on = false, gen = nil, poll = 0.0, hook_in = 0.0, targeted = 0, times = 0 }

local function targets_ghost(comp, g)
    local t, dead = nil, false
    pcall(function() t = comp["Attack Target"] end)
    pcall(function() dead = comp.Dead == true end)
    return not dead and util.same(t, g)
end

local function on_set_target(self)
    local g, comp = ghost.get(), util.obj(self)
    if not (g and comp and targets_ghost(comp, g)) then return end
    local a = util.addr(comp)
    if not a or hunters[a] then return end
    local n = 0
    for _ in pairs(hunters) do n = n + 1 end
    if n >= MAX_HUNTERS then return end
    hunters[a] = comp
    cover.targeted = cover.targeted + 1
end
local set_target_fn = function(self) util.safe(on_set_target, "pvp.raider_target", self) end

local function cover_poll()
    local g = ghost.get()
    if cover.on and (not g or ghost.generation() ~= cover.gen or pvp.on()) then cover.on = false end   -- (new mesh / PvP's own)
    if not g then hunters = {}; return end
    local engaged = false
    for a, comp in pairs(hunters) do
        if not (util.valid(comp) and util.addr(comp) == a) then hunters[a] = nil
        elseif targets_ghost(comp, g) then engaged = true
        else hunters[a] = nil end
    end
    if pvp.on() then return end
    if engaged and not cover.on then
        local copied = block_like_player(g)
        if copied then
            cover.on, cover.gen, cover.times = true, ghost.generation(), cover.times + 1
            log.info("pvp: a raider is after the other player - their ghost blocks weapon traces " .. table.concat(copied, ",") .. " (no PvP damage)")
        end
    elseif not engaged and cover.on then
        cover.on = false
        ghost.restore_mesh()
        log.info("pvp: no raider after the other player any more - ghost back to no-PvP collision")
    end
end

local function cover_tick(dt)
    if role ~= "host" then return end
    cover.hook_in = cover.hook_in - dt
    if cover.hook_in <= 0 then cover.hook_in = 2.0; util.ensure_hook(SAI .. ":Set BB Attack Target", set_target_fn) end
    cover.poll = cover.poll - dt
    if cover.poll <= 0 then cover.poll = COVER_POLL; cover_poll() end
end

function pvp.tick(dt)
    util.safe(sync_ghost, "pvp.sync")
    util.safe(cover_tick, "pvp.cover", dt)
    check_in = check_in - dt
    if check_in <= 0 then
        check_in = 2.0
        if pvp.on() then util.ensure_hook(FIREARM .. ":FireSurfaceHit", surface_hook) end
    end
    if last_surface > 0 and os.clock() - last_surface > 0.5 then
        last_surface = -100
        if not warned_nodmg then
            warned_nodmg = true
            log.warn("pvp: a bullet hit the ghost but the game dealt it no damage (surface not flesh?)")
        end
    end
    hits:pump(function(payload) util.safe(apply_hit, "pvp.apply", payload) end)
end

function pvp.status()
    return string.format("pvp %s | hits sent %d, taken %d, blocked %d | raiders after the other player %d, cover %s (%d times)",
        pvp.on() and "on" or "off", stats.sent, stats.taken, stats.blocked, cover.targeted, cover.on and "on" or "off", cover.times)
end

function pvp.init(r, same_world_fn)
    role = r
    same_world = same_world_fn or same_world
    game.on_world_reset(function() hunters, cover.on = {}, false end)
    game.player_hook("ReceiveAnyDamage", function(self, Damage, DamageType, InstigatedBy, DamageCauser)
        util.safe(on_ghost_damage, "pvp.capture", self, Damage, DamageType, InstigatedBy, DamageCauser)
    end)
    log.info("pvp: " .. (role == "host" and ("host setting " .. (pvp.on() and "on" or "off")) or "following the host's setting"))
end

return pvp
