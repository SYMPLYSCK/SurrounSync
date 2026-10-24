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
local function make_hittable(g)
    local p = game.player()
    if not util.valid(p) then return false end
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

-- Our own hit landed on the ghost: send it to the other game.
local function on_ghost_damage(self, Damage, DamageType, InstigatedBy, DamageCauser)
    if not ghost.is(self:get()) then return end
    if not (pvp.on() and same_world()) then return end
    local causer, inst = util.obj(DamageCauser), util.obj(InstigatedBy)
    if not (mine_obj(causer) or mine_obj(inst)) then return end
    local amt = 0
    pcall(function() amt = Damage:get() end)
    if not (amt and amt > 0) then return end
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
    local dtc = cls ~= "-" and StaticFindObject(cls) or nil
    if not util.valid(dtc) then dtc = nil end
    local ok, err = pcall(function() util.cdo(GS):ApplyDamage(p, math.min(amt, MAX_HIT), nil, g, dtc) end)
    stats.taken = stats.taken + 1
    if ok then log.info(string.format("pvp: the other player hit me for %.1f", amt))
    else log.warn("pvp: ApplyDamage failed: " .. tostring(err)) end
end

function pvp.tick(dt)
    util.safe(sync_ghost, "pvp.sync")
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
    return string.format("pvp %s | hits sent %d, taken %d, blocked %d", pvp.on() and "on" or "off", stats.sent, stats.taken, stats.blocked)
end

function pvp.init(r, same_world_fn)
    role = r
    same_world = same_world_fn or same_world
    game.player_hook("ReceiveAnyDamage", function(self, Damage, DamageType, InstigatedBy, DamageCauser)
        util.safe(on_ghost_damage, "pvp.capture", self, Damage, DamageType, InstigatedBy, DamageCauser)
    end)
    log.info("pvp: " .. (role == "host" and ("host setting " .. (pvp.on() and "on" or "off")) or "following the host's setting"))
end

return pvp
