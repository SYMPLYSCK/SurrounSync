-- Infestations (nests) run on the host only. The guest's hits go to the host's nest, the host's
-- waves reach the guest as normal zombie copies, and a destroyed nest shows on both screens.
--
-- Health stays REAL on both games (the health bar prints the numbers). How a nest works (BP_Infestation /
-- DamageComponent): every hit lowers DamageComponent.CurrentHealth; a hit that leaves it under MaxHealth / 1.5
-- starts the waves (once - a DoOnce in the nest's graph); at 0 the nest is destroyed. CurrentHealth,
-- StandardHealthValue (the bar's 100%) and MaxHealth are all saved with the nest.
--
--  * Host: its own hits stay the game's (waves, death, XP, loot as in single player). A guest hit is applied
--    here by lowering CurrentHealth. Waves started by a guest hit go from an engine timer (a nest that spawns
--    its wave inside one of our calls freezes the game - UE4SS), and the nest's own 2/3 check is then closed
--    by setting MaxHealth to 0 (it is only used for that check) so a later hit can't start a second wave chain.
--    A lethal guest hit runs the nest's own death branch (health just above 0, then a 1-point hit).
--  * Guest: the copies show the host's exact numbers, MaxHealth 0 so they never start waves of their own; the
--    guest's hits lower the copy at once and go to the host, which answers with its numbers. (Health only goes
--    down and the host applies the same hits, so a copy can't reach 0 before the host's nest does.)
--  * Saves always get the real values (ActorPreSave puts MaxHealth back, ActorSaved closes it again).
--  * Up to 0.11.0 nests were pinned to a 1,000,000+ scale during co-op, and saves written then kept it (a nest
--    with millions of health, or one that could never die). Such nests get their real health back from the
--    game's own defaults (the class's DamageComponent x Difficulty.InfestationsHealth), keeping the same %.

local log = require("mirror.log")
local util = require("mirror.util")
local link = require("mirror.link")
local events = require("mirror.events")
local ghost = require("mirror.ghost")
local game = require("mirror.game")
local notify = require("mirror.notify")

local infest = {}

local PATH = "/Game/Infestation/BP_Infestation.BP_Infestation_C"
-- the five kinds are direct children of BP_Infestation (game files): one walk finds all six lists
local GROUP = "BP_Infestation_C"
util.instance_group(GROUP, { "BP_Infestation_Ceiling_C", "BP_Infestation_Corner_C", "BP_Infestation_Floor_C",
                             "BP_Infestation_Wall_C", "BP_PrimaryInfestation_C" }, true)
local SAI = "/Game/AI/SD_AIComponent.SD_AIComponent_C"
local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local CLASSES = { "BP_Infestation_C", "BP_Infestation_Ceiling_C", "BP_Infestation_Corner_C", "BP_Infestation_Floor_C",
                  "BP_Infestation_Wall_C", "BP_PrimaryInfestation_C" }
local RESCAN, STATE_EVERY = 30.0, 1.0
local WAVE_RADIUS = 3000
local NEAR_FX = 20000
local PINNED = 1e6   -- no real nest has this much: a value left over from the old pin

local cfg, role, session
local killing = false
local same_world = function() return false end
local hits = events.new("nesthits", 32, 15)
local nests, by_addr = {}, {}
local now, scan_in, state_in = 0.0, 0.0, 0.0
local guest_hit_at = -1e9
local active = false
local warm = 0
local last_nests = nil -- guest: the host's last "nests" blob
local sent_state = nil
local shown_dead = {}
local retargeting = false
local guarded = {}   -- key -> the nest's real MaxHealth while its own 2/3 check is closed (MaxHealth = 0)
local stats = { sent = 0, applied = 0, blocked = 0, destroyed = 0, retargeted = 0, missing = 0, repaired = 0 }

local function key_of(o, cls)
    local l = o:K2_GetActorLocation()
    return string.format("%s@%d,%d,%d", cls, math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5), math.floor(l.Z / 10 + 0.5)), util.vec(l)
end

local function read(n)
    local dead, cur, std, max = false, 0, 0, 0
    pcall(function()
        dead = n.obj["IsDestroyed?"] == true
        local dc = n.obj.DamageComponent
        cur, std, max = dc.CurrentHealth, dc.StandardHealthValue, dc.MaxHealth
    end)
    return dead, tonumber(cur) or 0, tonumber(std) or 0, tonumber(max) or 0
end

-- The class's own DamageComponent defaults (StaticFindObject: no walk) and the difficulty's health factor.
local function defaults(o)
    local cp = util.class_path(o)
    if not cp then return nil end
    local t = StaticFindObject(cp .. ":DamageComponent_GEN_VARIABLE")
    if not util.valid(t) then return nil end
    local std, max
    pcall(function() std, max = tonumber(t.StandardHealthValue), tonumber(t.MaxHealth) end)
    local mult = 1.0
    local ksl = util.cdo(KSL)
    if ksl then pcall(function() mult = tonumber(ksl:GetConsoleVariableFloatValue("Difficulty.InfestationsHealth")) or 1.0 end) end
    if not mult or mult <= 0 then mult = 1.0 end
    return std and std * mult, max
end

-- A nest saved while the old pin was on: real health back, same percentage.
local function repair(n)
    local dead, cur, std, max = read(n)
    if dead then return end
    local bad_std, bad_max = std >= PINNED, max >= PINNED or (max <= 0 and not guarded[n.key])
    if not (bad_std or bad_max) then return end
    local real_std, real_max = defaults(n.obj)
    if not real_std or real_std <= 0 then return end
    pcall(function()
        local dc = n.obj.DamageComponent
        if bad_std then
            local ratio = std > 0 and math.min(math.max(cur / std, 0), 1) or 1
            dc.StandardHealthValue = real_std
            dc.CurrentHealth = math.max(real_std * ratio, 1)
        end
        if bad_max and real_max and real_max > 0 then dc.MaxHealth = real_max end
    end)
    stats.repaired = stats.repaired + 1
    log.info(string.format("infest: %s had a leftover pinned health (%.0f / %.0f) - real health back (%.0f)", n.key, cur, std, real_std))
end

-- Close / reopen the nest's own "under 2/3 -> start the waves" check.
local function guard(n)
    if guarded[n.key] then return end
    local _, _, _, max = read(n)
    if max <= 0 then return end
    guarded[n.key] = max
    pcall(function() n.obj.DamageComponent.MaxHealth = 0 end)
end
local function unguard(n)
    local max = guarded[n.key]
    if not max then return end
    pcall(function() n.obj.DamageComponent.MaxHealth = max end)
end

-- One class per call (util.instances keeps the lists without walking every object in the game).
local scan_idx = 0
local function rescan_class(cls)
    local objs, walked = util.instances(cls, PATH, GROUP)
    if not walked then return false end
    for k, n in pairs(nests) do
        if n.cls == cls then nests[k] = nil; by_addr[n.addr] = nil end
    end
    pcall(function()
        for _, o in ipairs(objs) do
            local a = util.valid(o) and util.addr(o)
            if a and not by_addr[a] then
                local ok, k, l = pcall(key_of, o, cls)
                if ok then
                    local n = { obj = o, key = k, loc = l, addr = a, cls = cls }
                    nests[k], by_addr[a] = n, n
                end
            end
        end
    end)
    return true
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

local function show_destroyed(n)
    if shown_dead[n.key] then return end
    shown_dead[n.key] = true
    local p, near = game.player(), false
    if util.valid(p) then
        pcall(function() near = util.dist(util.vec(p:K2_GetActorLocation()), n.loc) < NEAR_FX end)
    end
    if read(n) then return end
    local ok, err = pcall(function() n.obj:Event_OnDestroyed(nil, not near) end)
    stats.destroyed = stats.destroyed + 1
    log.info("infest: " .. n.key .. " destroyed on the host" .. (ok and "" or (" - FAILED: " .. tostring(err))))
end

local function primary_locked(n)
    local primary, can = false, true
    pcall(function() primary = n.obj["PrimaryInfestation?"] == true; can = n.obj["CanDamagePrimary?"] == true end)
    return primary and not can
end

-- Guest: the game opens a primary (CanDamagePrimary?) when a secondary's InfestationDestroyed broadcast reaches
-- it; a nest the host destroyed is shown here with Event_OnDestroyed, which doesn't broadcast - the guest's
-- primary stayed shut for the session ("destroy the others first" on every hit, player report 2026-10-27).
-- Same check as the game's AreSecondariesDestroyed? (IsDestroyed? flips 0.2 s after Event_OnDestroyed).
local function open_primaries()
    for _, n in pairs(nests) do
        if util.valid(n.obj) and primary_locked(n) and not read(n) then
            local all = true
            local ok = pcall(function()
                util.each(n.obj.SecondaryInfestations, function(_, e)
                    local s = e:get()
                    if not (util.valid(s) and s["IsDestroyed?"] == true) then all = false end
                end)
            end)
            if ok and all then
                pcall(function() n.obj["CanDamagePrimary?"] = true end)
                log.info("infest: " .. n.key .. " - its smaller nests are all destroyed, it can be damaged now")
            end
        end
    end
end

-- Host: the guest's hit on its copy of a nest.
local function apply_hit(payload)
    local k, amt = payload:match("^(%S+) (%S+)$")
    amt = tonumber(amt)
    if not (k and amt and amt > 0) then return end
    local n = find(k)
    if not n then stats.missing = stats.missing + 1; log.warn("infest: the guest hit a nest that isn't here: " .. k); return end
    guest_hit_at = now
    local dead, cur, std, max = read(n)
    if dead then return end
    if primary_locked(n) then
        stats.blocked = stats.blocked + 1
        hits:send("B " .. n.key)
        return
    end
    stats.applied = stats.applied + 1
    max = guarded[n.key] or max
    local left = cur - amt
    if left <= 0 then
        -- Only the death branch runs from here: no wave can start inside this call.
        guard(n)
        pcall(function() n.obj.DamageComponent.CurrentHealth = 0.5 end)
        killing = true
        local ok, err = pcall(function() n.obj:Damage_Object(1.0, ghost.get(), nil) end)
        killing = false
        stats.destroyed = stats.destroyed + 1
        log.info("infest: " .. n.key .. " destroyed by the other player" .. (ok and "" or (" - FAILED: " .. tostring(err))))
        return
    end
    pcall(function() n.obj.DamageComponent.CurrentHealth = left end)
    -- Health never goes up: the game's own check (and its DoOnce) can only have fired if the health was already
    -- under 2/3 - so the waves start here exactly when this hit is the one that crosses the line.
    if max > 0 and cur >= max / 1.5 and left < max / 1.5 then
        guard(n)
        local ksl = util.cdo(KSL)
        local ok = ksl and pcall(function() ksl:K2_SetTimer(n.obj, "SpawnWave", 0.05, false, false, 0.0, 0.0) end)
        log.info("infest: " .. n.key .. " below 2/3 from the other player's hits - waves start" .. (ok and "" or " (timer FAILED)"))
    end
end

local function on_guest_message(payload)
    local kind, k = payload:match("^(%a) (%S+)$")
    local n = k and find(k)
    -- (the copy here shut too: the game has said so itself)
    if kind == "B" and not (n and primary_locked(n)) then
        notify.show("Destroy the smaller infestations around it first.", "info", "infest_primary")
    end
end

-- A nest the 30 s scan hasn't reached yet (streamed in since): known from its first hit on.
local function adopt(o)
    local a = util.addr(o)
    local cls = util.class_name(o)
    if not (a and cls) then return nil end
    local ok, k, l = pcall(key_of, o, cls)
    if not ok then return nil end
    local n = { obj = o, key = k, loc = l, addr = a, cls = cls }
    nests[k], by_addr[a] = n, n
    repair(n)
    if role == "guest" and not read(n) then guard(n) end
    return n
end

-- Damage_Object has run (UE4SS calls this after it). The host's own hits are the game's: nothing to do.
local function on_damage(self, Damage)
    if not active or killing or role == "host" then return end
    local o = util.obj(self)
    if not o then return end
    local n = by_addr[util.addr(o) or 0] or adopt(o)
    if not n then return end
    local amt = 0
    pcall(function() amt = Damage:get() end)
    amt = tonumber(amt) or 0
    -- a primary that is still shut here goes to the host too: the host's own nest decides (it answers "B")
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
            if require("mirror.peers").ghost_nearest(ghost, gl, pl, n.loc) then
                retargeting = true
                pcall(function() comp:SetBB_LockOnTarget(gl) end)
                retargeting = false
                stats.retargeted = stats.retargeted + 1
            end
            return
        end
    end
end

-- Host -> guest: "key dead current standard" for every nest that isn't untouched.
local function put_state()
    local lines = {}
    for k, n in pairs(nests) do
        if util.valid(n.obj) then
            local dead, cur, std = read(n)
            if dead or (std > 0 and cur < std) then
                lines[#lines + 1] = string.format("%s %d %.1f %.1f", k, dead and 1 or 0, dead and 0 or cur, std)
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
    for line in text:gmatch("[^\n]+") do
        local k, d, cur, std = line:match("^(%S+) (%d) (%S+) (%S+)$")
        local n = k and find(k)
        if n and util.valid(n.obj) then
            if d == "1" then show_destroyed(n)
            else
                cur, std = tonumber(cur), tonumber(std)
                if cur and std and std > 0 and not read(n) then
                    pcall(function()
                        local dc = n.obj.DamageComponent
                        if math.abs((tonumber(dc.StandardHealthValue) or 0) - std) > 0.05 then dc.StandardHealthValue = std end
                        if math.abs((tonumber(dc.CurrentHealth) or 0) - cur) > 0.05 then dc.CurrentHealth = math.max(cur, 0.5) end
                    end)
                end
            end
        end
    end
end

-- Saves get the real values whatever the session is doing.
local function on_pre_save(self)
    local o = util.obj(self)
    local n = o and by_addr[util.addr(o) or 0]
    if n then unguard(n) end
end
local function on_saved(self)
    local o = util.obj(self)
    local n = o and by_addr[util.addr(o) or 0]
    if n and guarded[n.key] then pcall(function() n.obj.DamageComponent.MaxHealth = 0 end) end
end

local function set_active(on)
    if on == active then return end
    active = on
    shown_dead, sent_state = {}, nil
    if on then
        nests, by_addr, warm, guarded = {}, {}, #CLASSES, {}
        scan_in = RESCAN
        log.info("infest: syncing nests")
    else
        for k, n in pairs(nests) do
            if guarded[k] and util.valid(n.obj) then unguard(n) end
        end
        nests, by_addr, guarded = {}, {}, {}
        log.info("infest: stopped")
    end
end

local function warmed()
    local c = 0
    for _, n in pairs(nests) do
        c = c + 1
        repair(n)
        if role == "guest" and not read(n) then guard(n) end
    end
    log.info(string.format("infest: %d nests here", c))
    if role == "guest" then
        -- get_blob hands out only a changed state: a rescan re-applies the last one or nests look untouched
        local b = link.get_blob("nests") or last_nests
        if b then last_nests = b; take_state(b) end
    end
end

local pre_save_fn = function(self) util.safe(on_pre_save, "infest.pre_save", self) end
local saved_fn = function(self) util.safe(on_saved, "infest.saved", self) end
local damage_fn = function(self, Damage) util.safe(on_damage, "infest.damage", self, Damage) end
local lock_fn = function(self) util.safe(on_lock_target, "infest.lock", self) end

function infest.tick(dt)
    if role ~= "host" and role ~= "guest" then return end
    now = now + dt
    set_active(same_world())
    if not active then return end
    util.ensure_hook(PATH .. ":Damage_Object", damage_fn)
    util.ensure_hook(PATH .. ":ActorPreSave", pre_save_fn)
    util.ensure_hook(PATH .. ":ActorSaved", saved_fn)
    if role == "host" then util.ensure_hook(SAI .. ":SetBB_LockOnTarget", lock_fn) end

    if warm > 0 then
        if rescan_class(CLASSES[warm]) then warm = warm - 1 end
        if warm == 0 then warmed() end
        return
    end
    scan_in = scan_in - dt
    if scan_in <= 0 then
        scan_in = RESCAN
        rescan_step()
        for _, n in pairs(nests) do
            if n.cls == CLASSES[scan_idx] then
                repair(n)
                if role == "guest" and not read(n) then guard(n) end
            end
        end
    end

    if role == "host" then
        hits:pump(apply_hit)
        state_in = state_in - dt
        if state_in <= 0 then state_in = STATE_EVERY; put_state() end
    else
        hits:pump(on_guest_message)
        local b = link.get_blob("nests")
        if b then last_nests = b; take_state(b) end
        state_in = state_in - dt
        if state_in <= 0 then state_in = STATE_EVERY; open_primaries() end
    end
end

-- Host: seconds since the guest last hit a nest (the P8 load split keeps infestation fights on the host).
function infest.guest_hit_age() return now - guest_hit_at end

function infest.status()
    if not active then return "nests: idle" end
    return string.format("nests: hits sent %d, applied %d, blocked %d, destroyed %d, waves retargeted %d, missing %d, repaired %d",
        stats.sent, stats.applied, stats.blocked, stats.destroyed, stats.retargeted, stats.missing, stats.repaired)
end

-- Single player too: a nest saved with the old pin gets its real health back, once per loaded world.
-- All classes in one frame: one group walk fills every class's list, and a list used a frame later can hold an
-- old-world nest the GC freed in between (guest crash 5 s after going home, DBG-20261027-008).
local solo = { left = nil, idx = 0, wait = 0.0 }
local function solo_tick(dt)
    if active then return end
    if solo.left == nil then solo.wait = solo.wait + (dt or 0); if solo.wait < 5.0 then return end; solo.left = #CLASSES end
    while solo.left > 0 do
        local cls = CLASSES[solo.left]
        local objs, walked = util.instances(cls, PATH, GROUP)
        if not walked then return end
        solo.left = solo.left - 1
        for _, o in ipairs(objs or {}) do
            if util.valid(o) then
                local ok, k, l = pcall(key_of, o, cls)
                if ok then repair({ obj = o, key = k, loc = l, cls = cls }) end
            end
        end
    end
end
function infest.watch()
    game.on_tick(function(dt) util.safe(solo_tick, "infest.solo", dt) end)
end

-- Respawn/reload: the old world's objects are freed - drop them without touching them.
local function forget_world()
    nests, by_addr, scan_in, guarded = {}, {}, 0.0, {}
    solo.left, solo.wait = nil, 0.0
    if active then warm = #CLASSES end
end
function infest.init(c, r, s, shared)
    game.on_world_reset(forget_world)
    cfg, role, session = c, r, s
    same_world = shared or same_world
    if cfg.infest_sync == false then role = "off" end
    log.info("infest: " .. (role == "off" and "off" or "ready"))
end

return infest
