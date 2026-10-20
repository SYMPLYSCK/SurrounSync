-- Infestations (nests) run on the host only. The guest's hits go to the host's nest, the host's
-- waves reach the guest as normal zombie copies, and a destroyed nest shows on both screens.
-- While both players are in the host's world every nest keeps its health on a huge scale, so no hit
-- can start waves or kill it by itself (the bar still shows the real percentage). On the host the real
-- health is kept here: a nest that spawns its wave inside one of our calls freezes the game (UE4SS),
-- so waves start from an engine timer and only the death branch is ever run from here.

local log = require("mirror.log")
local util = require("mirror.util")
local link = require("mirror.link")
local events = require("mirror.events")
local ghost = require("mirror.ghost")
local game = require("mirror.game")
local notify = require("mirror.notify")

local infest = {}

local PATH = "/Game/Infestation/BP_Infestation.BP_Infestation_C"
local SAI = "/Game/AI/SD_AIComponent.SD_AIComponent_C"
local CLASSES = { "BP_Infestation_C", "BP_Infestation_Ceiling_C", "BP_Infestation_Corner_C", "BP_Infestation_Floor_C",
                  "BP_Infestation_Wall_C", "BP_PrimaryInfestation_C" }
local RESCAN, STATE_EVERY, PIN_EVERY = 30.0, 1.0, 2.0
local WAVE_RADIUS = 3000
local NEAR_FX = 20000
local MIN_RATIO = 0.002

local cfg, role, session
local health = {}
local killing = false
local same_world = function() return false end
local hits = events.new("nesthits", 32, 15)
local nests, by_addr = {}, {}
local now, scan_in, state_in, pin_in = 0.0, 0.0, 0.0, 0.0
local active = false
local warm = 0
local sent_state = nil
local host_state = {}
local shown_dead = {}
local retargeting = false
local stats = { sent = 0, applied = 0, blocked = 0, destroyed = 0, retargeted = 0, missing = 0 }

local function key_of(o, cls)
    local l = o:K2_GetActorLocation()
    return string.format("%s@%d,%d,%d", cls, math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5), math.floor(l.Z / 10 + 0.5)), util.vec(l)
end

-- One class per call: FindAllOf walks every object in the game.
local scan_idx = 0
local function rescan_class(cls)
    for k, n in pairs(nests) do
        if n.cls == cls then nests[k] = nil; by_addr[n.addr] = nil end
    end
    pcall(function()
        for _, o in ipairs(FindAllOf(cls) or {}) do
            local a = util.addr(o)
            if a and not by_addr[a] and not o:GetFullName():find("Default__", 1, true) then
                local ok, k, l = pcall(key_of, o, cls)
                if ok then
                    local n = { obj = o, key = k, loc = l, addr = a, cls = cls }
                    nests[k], by_addr[a] = n, n
                end
            end
        end
    end)
end
local function rescan_step()
    scan_idx = scan_idx % #CLASSES + 1
    rescan_class(CLASSES[scan_idx])
end

local function find(k)
    local n = nests[k]
    if n and util.valid(n.obj) then return n end
    local cls, x, y, z = k:match("^([^@]+)@(%-?%d+),(%-?%d+),(%-?%d+)$")
    if not cls then return nil end
    local best, bd = nil, 100.0
    for nk, c in pairs(nests) do
        if nk:sub(1, #cls + 1) == cls .. "@" and util.valid(c.obj) then
            local d = math.sqrt((c.loc.X / 10 - x) ^ 2 + (c.loc.Y / 10 - y) ^ 2 + (c.loc.Z / 10 - z) ^ 2)
            if d < bd then best, bd = c, d end
        end
    end
    return best
end

local function read(n)
    local dead, cur, std = false, 0, 0
    pcall(function()
        dead = n.obj["IsDestroyed?"] == true
        local dc = n.obj.DamageComponent
        cur, std = dc.CurrentHealth, dc.StandardHealthValue
    end)
    return dead, tonumber(cur) or 0, tonumber(std) or 0
end

local function ratio_of(n)
    if role == "host" then
        local h = health[n.key]
        return h and h.std > 0 and math.max(h.hp, 0) / h.std or 1.0
    end
    local hs = host_state[n.key]
    return hs and hs.ratio or 1.0
end

-- Keep the nest far from its wave threshold (MaxHealth / 1.5) and from death.
local function pin(n)
    local ratio = ratio_of(n)
    pcall(function()
        if n.obj["IsDestroyed?"] == true then return end
        local dc = n.obj.DamageComponent
        local scale = math.max(1e6, (tonumber(dc.MaxHealth) or 0) * 1000)
        dc.StandardHealthValue = scale
        dc.CurrentHealth = scale * math.max(ratio, MIN_RATIO)
    end)
end

local function show_destroyed(n)
    if shown_dead[n.key] then return end
    shown_dead[n.key] = true
    local p, near = game.player(), false
    if util.valid(p) then
        pcall(function() near = util.dist(util.vec(p:K2_GetActorLocation()), n.loc) < NEAR_FX end)
    end
    local dead = read(n)
    if dead then return end
    local ok, err = pcall(function() n.obj:Event_OnDestroyed(nil, not near) end)
    stats.destroyed = stats.destroyed + 1
    log.info("infest: " .. n.key .. " destroyed on the host" .. (ok and "" or (" - FAILED: " .. tostring(err))))
end

-- Host: the nest's real health, read before it's pinned (a nest already under 2/3 has its waves going).
local function track(n)
    if role ~= "host" or health[n.key] then return end
    local dead, cur, std = read(n)
    local max = 0
    pcall(function() max = tonumber(n.obj.DamageComponent.MaxHealth) or 0 end)
    if std <= 0 or std >= 1e6 then return end
    health[n.key] = { hp = cur, std = std, max = max, waves = dead or cur < max / 1.5 }
end

local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local function damage(n, amt, causer)
    local h = health[n.key]
    if not h or h.hp < 0 then return end
    h.hp = h.hp - amt
    if not h.waves and h.hp < h.max / 1.5 then
        h.waves = true
        local ksl = util.cdo(KSL)
        local ok = ksl and pcall(function() ksl:K2_SetTimer(n.obj, "SpawnWave", 0.05, false, false, 0.0, 0.0) end)
        log.info("infest: " .. n.key .. " below 2/3 - waves start" .. (ok and "" or " (timer FAILED)"))
    end
    if h.hp < 0 then
        -- Only the death branch runs from here: health just above zero, then a 1-point hit.
        pcall(function()
            local dc = n.obj.DamageComponent
            dc.StandardHealthValue = h.std
            dc.CurrentHealth = 0.5
        end)
        killing = true
        local ok, err = pcall(function() n.obj:Damage_Object(1.0, causer, nil) end)
        killing = false
        stats.destroyed = stats.destroyed + 1
        log.info("infest: " .. n.key .. " destroyed" .. (ok and "" or (" - FAILED: " .. tostring(err))))
        return
    end
    pin(n)
end

local function primary_locked(n)
    local primary, can = false, true
    pcall(function() primary = n.obj["PrimaryInfestation?"] == true; can = n.obj["CanDamagePrimary?"] == true end)
    return primary and not can
end

-- Host: the guest's hit on its copy of a nest.
local function apply_hit(payload)
    local k, amt = payload:match("^(%S+) (%S+)$")
    amt = tonumber(amt)
    if not (k and amt and amt > 0) then return end
    local n = find(k)
    if not n then stats.missing = stats.missing + 1; log.warn("infest: the guest hit a nest that isn't here: " .. k); return end
    if read(n) then return end
    if primary_locked(n) then
        stats.blocked = stats.blocked + 1
        hits:send("B " .. n.key)
        return
    end
    track(n)
    damage(n, amt, ghost.get())
    stats.applied = stats.applied + 1
end

local function on_guest_message(payload)
    local kind, k = payload:match("^(%a) (%S+)$")
    if kind == "B" then
        notify.show("Destroy the smaller infestations around it first.", "info", "infest_primary")
    end
end

local function on_damage(self, Damage, Causer)
    if not active or killing then return end
    local o = util.obj(self)
    local n = o and by_addr[util.addr(o) or 0]
    if not n then return end
    local amt = 0
    pcall(function() amt = Damage:get() end)
    amt = tonumber(amt) or 0
    if role == "host" then
        if amt > 0 and not read(n) and not primary_locked(n) then track(n); damage(n, amt, util.obj(Causer)) else pin(n) end
        return
    end
    pin(n)
    if amt <= 0 or shown_dead[n.key] then return end
    hits:send(string.format("%s %.3f", n.key, amt))
    stats.sent = stats.sent + 1
end

-- Host: a wave started by the guest's fighting should come for the guest, not for the host.
local function on_lock_target(self)
    if role ~= "host" or retargeting or not same_world() then return end
    local g = ghost.get()
    if not g then return end
    local comp = util.obj(self)
    if not comp then return end
    local z, zl, gl, pl
    pcall(function() z = comp:GetOwner() end)
    if not util.valid(z) then return end
    pcall(function() zl = util.vec(z:K2_GetActorLocation()) end)
    gl = ghost.location()
    local p = game.player()
    if util.valid(p) then pcall(function() pl = util.vec(p:K2_GetActorLocation()) end) end
    if not (zl and gl and pl) then return end
    for _, n in pairs(nests) do
        if util.dist(zl, n.loc) < WAVE_RADIUS then
            if util.dist(gl, n.loc) < util.dist(pl, n.loc) then
                retargeting = true
                pcall(function() comp:SetBB_LockOnTarget(gl) end)
                retargeting = false
                stats.retargeted = stats.retargeted + 1
            end
            return
        end
    end
end

local function put_state()
    local lines = {}
    for k, n in pairs(nests) do
        if util.valid(n.obj) then
            local dead = read(n)
            local ratio = ratio_of(n)
            if dead or ratio < 1 then
                lines[#lines + 1] = string.format("%s %d %.4f", k, dead and 1 or 0, ratio)
            end
        end
    end
    table.sort(lines)
    local text = table.concat(lines, "\n")
    if text ~= sent_state then
        sent_state = text
        link.put_blob("nests", text)
    end
end

local function take_state(text)
    host_state = {}
    for line in text:gmatch("[^\n]+") do
        local k, d, r = line:match("^(%S+) (%d) (%S+)$")
        if k then host_state[k] = { dead = d == "1", ratio = tonumber(r) or 1 } end
    end
    for k, hs in pairs(host_state) do
        local n = find(k)
        if n then
            if hs.dead then show_destroyed(n) else pin(n) end
        end
    end
end

local function set_active(on)
    if on == active then return end
    active = on
    shown_dead, sent_state = {}, nil
    if on then
        nests, by_addr, warm = {}, {}, #CLASSES
        scan_in, pin_in = RESCAN, 0
        log.info("infest: syncing nests")
    else
        -- Back to the nests' own health.
        for k, h in pairs(health) do
            local n = nests[k]
            if n and util.valid(n.obj) and h.hp >= 0 and not read(n) then
                pcall(function()
                    local dc = n.obj.DamageComponent
                    dc.StandardHealthValue = h.std
                    dc.CurrentHealth = h.hp
                end)
            end
        end
        nests, by_addr, host_state, health = {}, {}, {}, {}
        log.info("infest: stopped")
    end
end

function infest.tick(dt)
    if role ~= "host" and role ~= "guest" then return end
    now = now + dt
    set_active(same_world())
    if not active then return end
    util.ensure_hook(PATH .. ":Damage_Object", on_damage)
    if role == "host" then util.ensure_hook(SAI .. ":SetBB_LockOnTarget", on_lock_target) end

    if warm > 0 then
        rescan_class(CLASSES[warm])
        warm = warm - 1
        if warm == 0 then
            local c = 0
            for _ in pairs(nests) do c = c + 1 end
            log.info(string.format("infest: %d nests here", c))
            if role == "host" then
                for _, n in pairs(nests) do if not read(n) then track(n); pin(n) end end
            else
                for _, n in pairs(nests) do pin(n) end
                local b = link.get_blob("nests")
                if b then take_state(b) end
            end
        end
        return
    end
    scan_in = scan_in - dt
    if scan_in <= 0 then scan_in = RESCAN; rescan_step() end

    if role == "host" then
        hits:pump(apply_hit)
        state_in = state_in - dt
        if state_in <= 0 then state_in = STATE_EVERY; put_state() end
    else
        hits:pump(on_guest_message)
        local b = link.get_blob("nests")
        if b then take_state(b) end
        pin_in = pin_in - dt
        if pin_in <= 0 then
            pin_in = PIN_EVERY
            for _, n in pairs(nests) do if not shown_dead[n.key] and util.valid(n.obj) then pin(n) end end
        end
    end
end

function infest.status()
    if not active then return "nests: idle" end
    return string.format("nests: hits sent %d, applied %d, blocked %d, destroyed %d, waves retargeted %d, missing %d",
        stats.sent, stats.applied, stats.blocked, stats.destroyed, stats.retargeted, stats.missing)
end

function infest.init(c, r, s, shared)
    cfg, role, session = c, r, s
    same_world = shared or same_world
    if cfg.infest_sync == false then role = "off" end
    log.info("infest: " .. (role == "off" and "off" or "ready"))
end

return infest
