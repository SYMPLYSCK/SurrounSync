-- Zombies and AI. The host's are the real ones; the guest sees copies that follow the host's
-- snapshots, and the guest's hits are applied to the host's zombies.

local log = require("mirror.log")
local util = require("mirror.util")
local perf = require("mirror.perf")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local link = require("mirror.link")
local track = require("mirror.track")
local events = require("mirror.events")
local invdiag = require("mirror.invdiag")
local xp = require("mirror.xp")
local loader = require("mirror.loader")

local zombies = {}

local MASTER = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"
local SPAWNER = "BP_AISpawner_Master_C"
local PLAYER = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
local EMS = "/Script/EasyMultiSave.Default__EMSFunctionLibrary"

local cfg, role, session
local now = 0.0
local zclock = require("mirror.clockmap").new(0.06, 0.3, 0.12)
function zombies.net_report()
    local late, shown = zclock:report()
    return string.format("late avg %.0f ms, shown %.0f ms behind (near %.0f)", late, shown, zclock:near_delay() * 1000)
end
local hits = events.new("hits", 64, 3)
local dmgs = events.new("dmg", 32, 3)
local meds = events.new("med", 32, 3)
local zhits = events.new("zhits", 64, 3)
local zkills = events.new("zkill", 64, 3)
local aifx = events.new("aifx", 64, 2)
local replaying = false
local zhit_stats = { sent = 0, played = 0 }
local install_host_hooks = function() end
local GFL = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C"
local GFL_CDO = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"
local allow_copy_damage = false
local dmg_stats = { sent = 0, applied = 0, dodged = 0 }
local install_hit_hooks = function() end
local hit_hooks_done = false
local master_cls = nil

local LOOK_KEYS, look_of, health_of
local function master()
    if util.valid(master_cls) then return master_cls end
    master_cls = StaticFindObject(MASTER)
    return util.valid(master_cls) and master_cls or nil
end

local TRADER = "/Game/AI/Humans/Trader/BP_MasterTrader.BP_MasterTrader_C"
local FAMILIES = {
    { "zombie", MASTER },
    { "boss", "/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C" },
    { "human", "/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C" },
    { "human", "/Game/AI/Humans/CoyoteSoldiers/BP_MasterCoyoteSoldier.BP_MasterCoyoteSoldier_C" },
    { "human", "/Game/AI/Humans/Scavengers/BP_MasterScavenger.BP_MasterScavenger_C" },
    -- the wandering trader: one host-owned trader (own one per game wandered apart and stocked apart)
    { "human", TRADER },
    { "animal", "/Game/AI/Animals/BP_Animal.BP_Animal_C" },
}
local fam_cls, fam_retry = {}, {}
local function fam_class(path)
    local c = fam_cls[path]
    if util.valid(c) then return c end
    if (fam_retry[path] or 0) > os.clock() then return nil end
    c = StaticFindObject(path)
    if util.valid(c) then fam_cls[path] = c; return c end
    fam_retry[path] = os.clock() + 10
    return nil
end
local applying_hit = false
local function family_of(o)
    if not util.valid(o) then return nil end
    for _, f in ipairs(FAMILIES) do
        local c = fam_class(f[2])
        if c then
            local ok, r = pcall(function() return o:IsA(c) end)
            if ok and r == true then return f[1] end
        end
    end
    return nil
end
local function is_zombie(o) return family_of(o) ~= nil end
function zombies.is_trader(o)
    local c = fam_class(TRADER)
    if not (c and util.valid(o)) then return false end
    local ok, r = pcall(function() return o:IsA(c) end)
    return ok and r == true
end
zombies.family_of = family_of
local function ai_of(a)
    if not util.valid(a) then return nil end
    if family_of(a) then return a end
    for _, f in ipairs({ "GetOwner", "GetInstigator" }) do
        local o
        pcall(function() o = a[f](a) end)
        if o and family_of(o) then return o end
    end
    return nil
end

local function smart_ai(z)
    for _, n in ipairs({ "BP_AIComponent", "SmartAIComponent", "BP_SmartAIComponent", "AIComponent" }) do
        local c
        pcall(function() c = z[n] end)
        if util.valid(c) then return c end
    end
    return nil
end
zombies.smart_ai = smart_ai
local destroy_holdables

local function dead_of(z, fam)
    local d = false
    fam = fam or family_of(z)
    if fam == "human" then
        pcall(function() d = smart_ai(z).Dead == true end)
    else
        pcall(function() d = z["IsDead?"] == true or z.Dead == true end)
    end
    return d
end
zombies.dead_of = dead_of

local function all_zombies()
    local out = {}
    for _, c in ipairs(FindAllOf("Character") or {}) do
        if util.valid(c) and is_zombie(c) then out[#out + 1] = c end
    end
    return out
end

local ZLIST_FULL_EVERY, ZLIST_PRUNE_EVERY = 120.0, 0.0
local zlist, zlist_at, zlist_pruned = {}, -100, -100
local zlist_new, zlist_set, zlist_addr = {}, {}, {}
local notify_on = false
local function zlist_add(z)
    local a = util.addr(z)
    if a and not zlist_set[a] then zlist_set[a] = true; zlist[#zlist + 1] = z; zlist_addr[#zlist] = a end
end
local function watch_new_zombies()
    if notify_on then return end
    notify_on = pcall(function()
        NotifyOnNewObject(MASTER, function(obj) zlist_new[#zlist_new + 1] = obj end)
    end)
    log.info("zombies: watching for new zombies " .. (notify_on and "(no periodic scan needed)" or "FAILED - scanning instead"))
end
local BEGIN_CLASSES = {
    "/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C",
    "/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C",
    "/Game/AI/Humans/CoyoteSoldiers/BP_MasterCoyoteSoldier.BP_MasterCoyoteSoldier_C",
    "/Game/AI/Humans/Scavengers/BP_MasterScavenger.BP_MasterScavenger_C",
    TRADER,
    "/Game/AI/Animals/Deer/BP_AnimalDeer.BP_AnimalDeer_C",
    "/Game/AI/Animals/Wolf/BP_AnimalWolf.BP_AnimalWolf_C",
    "/Game/AI/Animals/Bear/BP_AnimalBear.BP_AnimalBear_C",
    "/Game/AI/Animals/Rabbit/BP_AnimalRabbit.BP_AnimalRabbit_C",
    "/Game/AI/Animals/Dog/BP_AnimalDog.BP_AnimalDog_C",
}
local begin_fn = function(self) local o; pcall(function() o = self:get() end); if o then zlist_new[#zlist_new + 1] = o end end
local begin_in = 0.0
local function watch_begin(dt)
    begin_in = begin_in - dt
    if begin_in > 0 then return end
    begin_in = 2.0
    for _, c in ipairs(BEGIN_CLASSES) do util.ensure_hook(c .. ":ReceiveBeginPlay", begin_fn) end
end
local function zombies_cached(t)
    if t - zlist_at >= (notify_on and ZLIST_FULL_EVERY or 2.0) then
        perf.run("z.list", function()
            zlist, zlist_set, zlist_new, zlist_addr = {}, {}, {}, {}
            for _, z in ipairs(all_zombies()) do zlist_add(z) end
        end)
        zlist_at, zlist_pruned = t, t
    else
        if #zlist_new > 0 then
            for _, z in ipairs(zlist_new) do
                if util.valid(z) then
                    local cdo = false
                    pcall(function() cdo = z:GetFullName():find("Default__", 1, true) ~= nil end)
                    if not cdo then zlist_add(z) end
                end
            end
            zlist_new = {}
        end
        if t - zlist_pruned > ZLIST_PRUNE_EVERY then
            zlist_pruned = t
            local j, n = 0, #zlist
            for i = 1, n do
                local z, a = zlist[i], zlist_addr[i]
                if util.valid(z) then
                    j = j + 1; zlist[j], zlist_addr[j] = z, a
                else
                    zlist_set[a] = nil
                end
            end
            for i = j + 1, n do zlist[i], zlist_addr[i] = nil, nil end
        end
    end
    return zlist
end

local function path_of(obj)
    if not util.valid(obj) then return nil end
    local p
    pcall(function() p = obj:GetFullName():match("^%S+ (.+)$") end)
    return p
end

-- Montages are long-lived assets: their paths are cached by address.
local asset_paths, asset_paths_n = {}, 0
local function asset_path(obj)
    local a = util.addr(obj)
    if not a then return nil end
    local p = asset_paths[a]
    if p then return p end
    p = path_of(obj)
    if p then
        if asset_paths_n > 512 then asset_paths, asset_paths_n = {}, 0 end
        asset_paths[a], asset_paths_n = p, asset_paths_n + 1
    end
    return p
end
local far_until = setmetatable({}, { __mode = "k" })
local znames = setmetatable({}, { __mode = "k" })
local CLOSING_SPEED = 4000

local cache = {}
local missed, appeared = {}, {}
local SETTLE = 5.0
local function find(p)
    if not p or p == "-" then return nil end
    local o = cache[p]
    if util.valid(o) then return o end
    -- a miss costs StaticFindObject ~15 ms (measured in-game): ask again for a missing path once for all
    -- copies, 5 s after the first miss, doubling up to 60 s (most never load here - no safe LoadAsset)
    local miss = missed[p]
    if miss and not appeared[p] and os.clock() < miss.at then return nil end
    o = StaticFindObject(p)
    if not util.valid(o) then
        local wait = miss and math.min(miss.wait * 2, 60.0) or SETTLE
        missed[p] = { at = os.clock() + wait, wait = wait }
        return nil
    end
    if missed[p] then
        appeared[p] = appeared[p] or os.clock()
        if os.clock() - appeared[p] < SETTLE then return nil end
    end
    cache[p] = o
    return o
end

local HUMANOID = {
    "/Game/AI/Zombies/Roamer/BP_Zombie_Roamer.BP_Zombie_Roamer_C",
    "/Game/AI/Zombies/Infected/BP_Zombie_Infected.BP_Zombie_Infected_C",
    "/Game/AI/Zombies/Infected/Horde/BP_Zombie_Infected_Horde.BP_Zombie_Infected_Horde_C",
    "/Game/AI/Zombies/Radiated/BP_Zombie_Radiated.BP_Zombie_Radiated_C",
    "/Game/AI/Zombies/BP_Zombie.BP_Zombie_C",
}
local is_humanoid = {}
for _, h in ipairs(HUMANOID) do is_humanoid[h] = true end
local warned_class = {}

local LOOT_TABLES = { "Bandit", "BanditBoss", "BanditSniper", "Bear", "Deer", "MilitaryBoss", "MilitaryRifleman",
    "Rabbit", "Scavenger", "Wolf", "Zombie", "ZombieBoss", "ZombieBossSmall", "ZombieHound", "ZombieInfected",
    "ZombieRadiated" }
local loot_obj = {}
-- Never LoadAsset (or spawn something that loads assets) from our Lua: a synchronous load there
-- hangs the game. Copies wait until the game has loaded the zombie data itself.
local function loot_ready()
    local missing, lookups = 0, 0
    for _, n in ipairs(LOOT_TABLES) do
        local o = loot_obj[n]
        if not util.valid(o) then
            o = nil
            if lookups < 2 then
                lookups = lookups + 1
                o = StaticFindObject("/Game/AI/AILootTables/DA_LootTable_" .. n .. ".DA_LootTable_" .. n)
                if not util.valid(o) then o = nil end
            end
            loot_obj[n] = o
        end
        if not o then missing = missing + 1 end
    end
    return missing == 0, missing
end

local function copy_class(p)
    local c = find(p)
    if c then return c end
    if is_humanoid[p] then
        for _, h in ipairs(HUMANOID) do
            local alt = find(h)
            if alt then
                if not warned_class[p] then
                    warned_class[p] = true
                    log.info("zombies: " .. p:match("[^%.]+$") .. " not loaded here - using " .. h:match("[^%.]+$"))
                end
                return alt
            end
        end
    end
    if not warned_class[p] then
        warned_class[p] = true
        log.warn("zombies: " .. tostring(p) .. " not loaded here and no stand-in - not shown")
    end
    return nil
end

local function material_asset(m)
    if util.valid(m) and util.class_name(m) == "MaterialInstanceDynamic" then
        local parent
        pcall(function() parent = m.Parent end)
        return parent
    end
    return m
end

-- Zombie archetypes: BP_MasterZombie rolls one in SelectArchetype 1.0-1.25 s after BeginPlay and crawlers
-- roll ToughenedCrawler (and which legs are missing) inside BeginPlay, so each game rolls its own. The host
-- sends its archetype, hidden bones and whether the eyes glow (EyesColour's dynamic material); copies match.
local MZ = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"
local ARCH = { "Sprinter", "UltraRadiated", "Acidic", "Screamer", "Grenadier", "ToughenedCrawler" }
local ARCH_CHANCES = { "SprinterArchetypeChance", "UltraRadiatedArchetypeChance", "AcidicArchetypeChance",
    "ScreamerArchetypeChance", "GrenadierArchetypeChance" }
local BONES = { "Jaw", "lowerarm_r", "lowerarm_l", "calf_l", "Foot_R", "calf_r", "Foot_L" }
local BIT = { 1, 2, 4, 8, 16, 32, 64 }
local bone_fnames = {}
local arch_seen, arch_seen_n = {}, 0
local arch_hooks = {}
for i, a in ipairs(ARCH) do
    arch_hooks[i] = function(self)
        local n
        pcall(function() n = self:get():GetFName():ToString() end)
        if not n then return end
        if arch_seen_n > 4000 then arch_seen, arch_seen_n = {}, 0 end
        if not arch_seen[n] then arch_seen_n = arch_seen_n + 1 end
        arch_seen[n] = i
    end
end
local function hook_archetypes()
    for i, a in ipairs(ARCH) do util.ensure_hook(MZ .. ":Archetype_" .. a, arch_hooks[i]) end
end
local function bone_fname(i)
    local f = bone_fnames[i]
    if not f then f = FName(BONES[i]); bone_fnames[i] = f end
    return f
end
local function bones_of(z)
    local m = 0
    for i = 1, #BONES do
        local h = false
        pcall(function() h = z.Mesh:IsBoneHiddenByName(bone_fname(i)) end)
        if h == true then m = m + BIT[i] end
    end
    return m
end
local function eyes_of(z)
    local m
    pcall(function() m = z.Mesh:GetMaterial(0) end)
    return (util.valid(m) and util.class_name(m) == "MaterialInstanceDynamic") and 1 or 0
end
local function arch_of(z, name)
    if name and arch_seen[name] then return arch_seen[name] end
    -- Rolled before the hooks took: the archetypes that leave a trace (a Sprinter leaves none).
    local a = 0
    pcall(function()
        if util.valid(z.ZombieMist) then a = 2
        elseif util.valid(z.BloodSpitFX) then a = 3
        elseif (path_of(z.Mesh:GetSkinnedAsset()) or ""):find("Zombie_grenadier", 1, true) then a = 5
        elseif z.Mesh:IsBoneHiddenByName(bone_fname(1)) then a = 4
        elseif (util.class_name(z) or ""):find("Crawler", 1, true) and z.DamageComponent["CanHeadshot1Shot?"] == false then a = 6 end
    end)
    return a
end

LOOK_KEYS = { "hair", "beard", "backpack", "antlers", "ranged", "melee" }
local LOOK_COMPS = { hair = "HairMesh", beard = "BeardMesh", backpack = "BackpackMesh", antlers = "Antlers" }
health_of = function(z, fam)
    local h
    if fam == "human" then pcall(function() h = smart_ai(z).Health end)
    elseif fam == "animal" then pcall(function() h = z.Health end)
    else pcall(function() h = z.DamageComponent.CurrentHealth end) end
    return tonumber(h)
end
look_of = function(z, fam)
    local t = {}
    for k, comp in pairs(LOOK_COMPS) do
        pcall(function() local c = z[comp]; if util.valid(c) then t[k] = path_of(c.StaticMesh) end end)
    end
    if fam == "human" then
        local ai = smart_ai(z)
        pcall(function() t.ranged = path_of(ai["Start Range Weapon"]) end)
        pcall(function() t.melee = path_of(ai["Start Melee Weapon"]) end)
    end
    return t
end

local ids, next_id = {}, 0
local by_id = {}
local send_in = 0.0
local hit_count = 0
local loot_logged = {}
local watch_dead = nil

local function apply_hit(payload)
    local kind, id, amt, rest = payload:match("^(%a) (%d+) (%S+)%s*(.*)$")
    local z = by_id[tonumber(id or "")]
    if not util.valid(z) then log.debug("zombies: HIT for unknown zombie " .. tostring(id)); return end
    local g = ghost.get()
    local fam = family_of(z)
    local function health()
        local h = "?"
        pcall(function() h = string.format("%.0f", z.DamageComponent.CurrentHealth) end)
        if fam == "human" then pcall(function() h = tostring(smart_ai(z).Health) end) end
        if fam == "animal" then pcall(function() h = string.format("%.0f", z.Health) end) end
        return h, tostring(dead_of(z, fam))
    end
    local h0, d0 = health()
    local was_dead = d0 == "true"
    if was_dead then return end
    local worth = (fam == "zombie") and xp.amount_for(z) or 0
    local ok, err
    local tname = ""
    if fam == "human" or fam == "animal" then
        local _, tp = rest:match("^(%d) (%S+)$")
        local dtc = tp and find((tp:gsub("%.Default__", "."))) or nil
        if dtc and util.class_name(dtc) ~= "BlueprintGeneratedClass" and util.class_name(dtc) ~= "Class" then dtc = nil end
        tname = " type " .. ((tp or "-"):match("([%w_]+)_C$") or tostring(tp))
        applying_hit = true
        ok, err = xp.without(function()
            util.cdo("/Script/Engine.Default__GameplayStatics"):ApplyDamage(z, tonumber(amt) or 1, nil, g, dtc)
        end)
        applying_hit = false
    elseif kind == "D" then
        local _, tp = rest:match("^(%d) (%S+)$")
        local dt = find(tp)
        if not dt and tp then
            local cls = find((tp:gsub("%.Default__", ".")))
            if cls then pcall(function() dt = cls:GetCDO() end) end
        end
        tname = " type " .. ((tp or "-"):match("([%w_]+)_C$") or tostring(tp)) .. (dt and "" or " (NOT FOUND here)")
        applying_hit = true
        ok, err = xp.without(function() z.DamageComponent:DamageTaken(tonumber(amt), dt, g) end)
        applying_hit = false
    else
        applying_hit = true
        ok, err = xp.without(function() z.DamageComponent:FireDamageTaken(tonumber(amt), g) end)
        applying_hit = false
    end
    hit_count = hit_count + 1
    if not ok then log.warn("zombies: applying HIT failed: " .. tostring(err)) end
    local h1, dead = health()
    if dead == "true" and not was_dead then
        zkills:send(string.format("%s %.2f", id, worth or 0))
        if fam ~= "zombie" then xp.hold_for(0.5) end
    end
    log.info(string.format("zombies: guest hit zombie %s for %.1f%s%s - health %s -> %s, IsDead? %s",
        id, tonumber(amt) or 0, kind == "F" and " (fire)" or "", tname, h0, h1, dead))
    if dead == "true" and cfg.diagnostics then watch_dead = { z = z, id = id, t = 1.0 } end
end

local statics = {}
local STATICS_EVERY = 3.0

local guest_center = function() return ghost.location() end
local function host_tick(dt)
    hits:pump(apply_hit)
    if watch_dead then
        watch_dead.t = watch_dead.t - dt
        if watch_dead.t <= 0 then
            local z, sim, cap, ctrl, l = watch_dead.z, "?", "?", "?", nil
            pcall(function() sim = tostring(z.Mesh:IsSimulatingPhysics(FName("None"))) end)
            pcall(function() cap = tostring(util.valid(z.CapsuleComponent)) end)
            pcall(function() ctrl = util.class_name(z.Controller) or "none" end)
            pcall(function() l = z:K2_GetActorLocation() end)
            log.info(string.format("zombies: 1 s after the kill, zombie %s: simulating physics %s, capsule %s, controller %s, at %s",
                watch_dead.id, sim, cap, ctrl, l and string.format("(%.0f, %.0f, %.0f)", l.X, l.Y, l.Z) or "?"))
            watch_dead = nil
        end
    end
    dmgs:pump(function() end)
    meds:pump(function() end)
    zhits:pump(function() end)
    zkills:pump(function() end)
    aifx:pump(function() end)
    install_host_hooks()
    hook_archetypes()
    send_in = send_in - dt
    if send_in > 0 then return end
    send_in = 1.0 / cfg.zombies.send_hz
    local gl = guest_center()
    if not gl then return end

    local dict, dict_n, lines = {}, 0, {}
    local function idx(p)
        if not p then return 0 end
        local i = dict[p]
        if not i then dict_n = dict_n + 1; i = dict_n; dict[p] = i end
        return i
    end
    local alive = {}
    local radius = cfg.zombies.radius
    for _, z in ipairs(zombies_cached(now)) do
        local skip_until = far_until[z]
        local l, is_dead = nil, false
        -- A body dead for STATICS_EVERY s only needs its last values: the guest's copy ragdolls on its
        -- own and ignores a dead one's pose, montage and look. Gone/hidden is still checked below.
        local a0 = znames[z]
        local st0 = a0 and ids[a0] and statics[ids[a0]]
        local cz = st0 and st0.corpse
        if cz and cz.z ~= z then cz, st0.corpse = nil, nil end
        if cz then l, is_dead = cz.l, true
        elseif not (skip_until and now < skip_until) then
            pcall(function() l = z:K2_GetActorLocation() end)
            if l and math.abs(l.X) < 1 and math.abs(l.Y) < 1 and math.abs(l.Z) < 1 then
                is_dead = dead_of(z)
                l = nil
                if is_dead then pcall(function() l = z.Mesh:K2_GetComponentLocation() end) end
            end
        end
        local d = l and util.dist(gl, l)
        if d and d > radius then far_until[z] = now + math.min(2.0, (d - radius) / CLOSING_SPEED) end
        if d and d <= radius then
            local gone = not util.valid(z)
            if not gone then pcall(function() gone = z.bHidden == true end) end
            if not gone then pcall(function() gone = z:IsActorBeingDestroyed() == true end) end
            if not gone then
                local a = znames[z]
                if not a then
                    pcall(function() a = z:GetFName():ToString() end)
                    a = a or tostring(util.addr(z))
                    znames[z] = a
                end
                local id = ids[a]
                if not id then next_id = next_id + 1; id = next_id; ids[a] = id end
                by_id[id] = z
                alive[a] = true
                local st = statics[id]
                if not (st and st.corpse) and (not st or now - st.at > STATICS_EVERY) then perf.run("z.statics", function()
                    local mesh, mat
                    pcall(function() mesh = z.Mesh:GetSkinnedAsset() end)
                    pcall(function() mat = material_asset(z.Mesh:GetMaterial(0)) end)
                    st = { at = now, cls = path_of(z:GetClass()), mesh = path_of(mesh), mat = path_of(mat), dead_at = st and st.dead_at }
                    st.fam = family_of(z)
                    if st.fam ~= "zombie" then st.look = look_of(z, st.fam)
                    else st.arch, st.bones, st.eyes = arch_of(z, a), bones_of(z), eyes_of(z) end
                    statics[id] = st
                end) end
                local yaw, v, mont, mpos, dead = 0, { X = 0, Y = 0, Z = 0 }, nil, 0, false
                local cs = st.corpse
                if cs then
                    yaw, v, mont, mpos, dead = cs.yaw, cs.v, cs.mont, cs.mpos, true
                else
                    pcall(function() yaw = z:K2_GetActorRotation().Yaw end)
                    pcall(function() v = z:GetVelocity() end)
                    pcall(function() mont = z:GetCurrentMontage() end)
                    if util.valid(mont) then
                        pcall(function() mpos = z.Mesh:GetAnimInstance():Montage_GetPosition(mont) end)
                        mont = asset_path(mont)
                    else
                        mont = nil
                    end
                    if is_dead then dead = true else dead = dead_of(z, st.fam) end
                end
                if dead and not loot_logged[id] then
                    loot_logged[id] = true
                    util.safe(function()
                        log.info("zombies: host zombie " .. id .. " died - its loot: " .. invdiag.summary(z.BP_JigMultiplayer.MainJigContainers))
                    end, "zombies.loot_log")
                end
                lines[#lines + 1] = string.format("Z %d %d %d %d %.1f %.1f %.1f %.1f %.1f %.1f %.1f %d %.2f %d",
                    id, idx(st.cls), idx(st.mesh), idx(st.mat),
                    l.X, l.Y, l.Z, yaw, v.X, v.Y, v.Z, idx(mont), mpos or 0, dead and 1 or 0)
                if st.arch then lines[#lines + 1] = string.format("X %d %d %d %d", id, st.arch, st.bones, st.eyes) end
                if st.look then
                    local parts = {}
                    for _, k in ipairs(LOOK_KEYS) do parts[#parts + 1] = tostring(idx(st.look[k])) end
                    local beh, h = -1, nil
                    if cs then beh, h = cs.beh, cs.h
                    else
                        if st.fam == "human" then pcall(function() beh = smart_ai(z)["AI Current Behaviour"] or -1 end) end
                        h = health_of(z, st.fam)
                    end
                    lines[#lines + 1] = string.format("L %d %s %.1f %d", id, table.concat(parts, " "), h or -1, beh)
                    if dead and not cs then st.beh, st.h = beh, h end
                end
                if dead and not cs then
                    st.dead_at = st.dead_at or now
                    if now - st.dead_at >= STATICS_EVERY then
                        st.corpse = { z = z, l = { X = l.X, Y = l.Y, Z = l.Z }, yaw = yaw, v = { X = 0, Y = 0, Z = 0 },
                                      mont = nil, mpos = 0, beh = st.beh or -1, h = st.h }
                    end
                end
            end
        end
    end
    for a, id in pairs(ids) do
        if not alive[a] then
            ids[a] = nil; by_id[id] = nil; statics[id] = nil
        end
    end
    local out = {}
    for p, i in pairs(dict) do out[#out + 1] = "D " .. i .. " " .. p end
    for _, s in ipairs(lines) do out[#out + 1] = s end
    out[#out + 1] = string.format("T %.3f", now)
    link.put_blob("zombies", table.concat(out, "\n"))
end

local copies = {}
local looks, host_health, host_behaviour = {}, {}, {}
local xlooks = {}
local DEATH_WAIT = 0.6
local spawn_gate, on_spawned = nil, nil
local copy_addr = {}
local dress_copy, kill_copy, ragdoll
local destroyed = {}
local pass_in = 0.0
local active = false
local active_at = 0.0
local player_cls = nil
local warned_ignore = false
local stats = { spawned = 0, removed_native = 0, spawners = 0 }
local loot_ok = false
local loot_wait_logged = 0
local spawn_budget = 0
local spawned_class = {}

function zombies.is_copy(obj) return copy_addr[util.addr(obj) or 0] ~= nil end

function zombies.nearest_copy(loc, r)
    local best, bd = nil, r or 150
    for _, c in pairs(copies) do
        if util.valid(c.z) then
            local l
            pcall(function() l = c.z:K2_GetActorLocation() end)
            if l then
                local d = util.dist(loc, l)
                if d < bd then best, bd = c.z, d end
            end
        end
    end
    return best
end

local function contain_copy(z)
    util.safe(function() util.cdo(EMS):SetActorSaveProperties(z, true, false, true, 0) end, "zombies.skipsave")
    pcall(function()
        local c = z.Controller
        if util.valid(c) then z:DetachFromControllerPendingDestroy(); c:K2_DestroyActor() end
    end)
    pcall(function() z.AIOSubject:SetCanBeUpdatedBySubsystem(false) end)
    pcall(function() z.CharacterMovement.bRunPhysicsWithNoController = true end)
    pcall(function()
        local cm = z.CharacterMovement
        cm.BrakingDecelerationWalking = 0.0
        cm.GroundFriction = 0.0
        cm.BrakingFrictionFactor = 0.0
    end)
    pcall(function() z.DamageComponent["CanHeadshot1Shot?"] = false end)
    if not util.valid(player_cls) then player_cls = StaticFindObject(PLAYER) end
    if util.valid(player_cls) then
        if family_of(z) == "zombie" then
            local ok = pcall(function() local a = z.ClassesToIgnore; a[a:GetArrayNum() + 1] = player_cls end)
            if not ok and not warned_ignore then warned_ignore = true; log.warn("zombies: couldn't add the player to a copy's ClassesToIgnore") end
        end
    end
end

-- A human's weapons are their own actors attached to its mesh (the game's body despawn hides
-- them): destroying only the body leaves them floating where it was.
destroy_holdables = function(z)
    local ai = smart_ai(z)
    if not ai then return end
    local held = {}
    pcall(function() held[#held + 1] = ai["Holdable Actor"] end)
    pcall(function()
        local list = ai["Attached Holdables"]
        for i = 1, list:GetArrayNum() do held[#held + 1] = list[i]["Holdable_6_3FE52CBF435F83B34B5404918416EFB4"] end
    end)
    for _, h in ipairs(held) do
        if util.valid(h) then pcall(function() h:K2_DestroyActor() end) end
    end
end

local function destroy_copy(id, why)
    local c = copies[id]
    if not c then return end
    if util.valid(c.z) then
        local a = util.addr(c.z) or 0
        copy_addr[a] = nil
        destroyed[a] = now
        destroy_holdables(c.z)
        pcall(function() c.z:K2_DestroyActor() end)
    end
    copies[id], xlooks[id] = nil, nil
end

local function destroy_all_copies(why)
    local n = 0
    for id in pairs(copies) do destroy_copy(id, why); n = n + 1 end
    if n > 0 then log.info(string.format("zombies: removed %d copies (%s)", n, why)) end
end

dress_copy = function(z, fam, lk)
    local comps = { hair = "HairMesh", beard = "BeardMesh", backpack = "BackpackMesh", antlers = "Antlers" }
    for k, comp in pairs(comps) do
        local want = lk[k]
        if want then
            pcall(function()
                local c = z[comp]
                if not util.valid(c) then return end
                if want == "-" then c:SetStaticMesh(nil)
                else local m = find(want); if m then c:SetStaticMesh(m) end end
            end)
        end
    end
    if fam == "human" then
        local ai = smart_ai(z)
        if ai then
            pcall(function() ai["AI Character"] = z end)
            local ok, err = pcall(function() local f = ai["Server Starting Weapon"]; f(ai) end)
            if not ok then log.warn("zombies: a human copy's weapon: " .. tostring(err)) end
        end
    end
end

local function sync_health(c, h)
    if not h or h < 0 then return end
    local z = c.z
    if c.fam == "human" then pcall(function() smart_ai(z).Health = math.floor(h + 0.5) end)
    elseif c.fam == "animal" then pcall(function() if z.Health ~= h then z.Health = h end end)
    elseif c.fam == "boss" then pcall(function() if z.DamageComponent.CurrentHealth ~= h then z.DamageComponent.CurrentHealth = h end end) end
end

local killing = false
kill_copy = function(c, killer)
    local z = c.z
    if dead_of(z, c.fam) then return true end
    local inst
    if killer and util.same(killer, game.player()) then inst = game.controller() end
    if not inst then xp.hold_for(0.5) end
    killing = true
    local ok, err = pcall(function()
        if c.fam == "human" then
            local ai = smart_ai(z)
            pcall(function() ai["AI Character"] = z end)
            local f = ai["Set AI Dead"]; f(ai)
            z:Death(killer)
        elseif c.fam == "boss" then
            z.DamageComponent.CurrentHealth = 1
            z.DamageComponent:DamageTaken(1000000, nil, killer)
        else
            z.Health = 1
            util.cdo("/Script/Engine.Default__GameplayStatics"):ApplyDamage(z, 1000000, inst, killer, nil)
        end
    end)
    killing = false
    if not ok then log.warn("zombies: a " .. tostring(c.fam) .. " copy's death failed: " .. tostring(err)); ragdoll(z) end
    return ok
end

local function spawn_copy(id, e)
    if spawn_budget <= 0 or not loot_ok then return nil end
    local cls = copy_class(e.cls)
    if not util.valid(cls) then return nil end
    spawn_budget = spawn_budget - 1
    local first = not spawned_class[e.cls]
    local t0 = os.clock()
    local function step(what) if first then log.info("zombies: first copy of " .. tostring(e.cls) .. ": " .. what) end end
    step("class ok, spawning")
    local w = game.world()
    local z
    local cdo, old_possess
    pcall(function() cdo = cls:GetCDO(); old_possess = cdo.AutoPossessAI; cdo.AutoPossessAI = 0 end)
    local mesh, mat = find(e.mesh), find(e.mat)
    for _, m in ipairs({ { e.mesh, mesh }, { e.mat, mat } }) do
        if m[1] and m[1] ~= "-" and not m[2] and not warned_class[m[1]] then
            warned_class[m[1]] = true
            log.info("zombies: look " .. m[1]:match("[^%./]+$") .. " not loaded here - the copy keeps its own")
        end
        if m[1] and m[1] ~= "-" and not m[2] then loader.want(m[1]) end
    end
    local old_meshes, old_mats = {}, {}
    local lk = looks[id] or {}
    local old_w = {}
    if cdo then
        for _, w in ipairs({ { "RangedWeapon", lk.ranged }, { "MeleeWeapon", lk.melee } }) do
            local wc = w[2] and w[2] ~= "-" and find(w[2])
            if wc then
                pcall(function()
                    local a = cdo[w[1]]
                    old_w[w[1]] = {}
                    for i = 1, a:GetArrayNum() do old_w[w[1]][i] = a[i]; a[i] = wc end
                end)
            end
        end
    end
    if cdo then
        pcall(function()
            local a = cdo.Meshes
            for i = 1, a:GetArrayNum() do old_meshes[i] = a[i]; if mesh then a[i] = mesh end end
        end)
        pcall(function()
            local a = cdo.Materials
            for i = 1, a:GetArrayNum() do old_mats[i] = a[i]; if mat then a[i] = mat end end
        end)
    end
    local ok = pcall(function()
        z = w:SpawnActor(cls, { X = e.loc.X, Y = e.loc.Y, Z = e.loc.Z + 10 }, { Pitch = 0, Yaw = e.yaw, Roll = 0 })
    end)
    if old_possess ~= nil then pcall(function() cdo.AutoPossessAI = old_possess end) end
    pcall(function() local a = cdo.Meshes; for i, m in ipairs(old_meshes) do a[i] = m end end)
    pcall(function() local a = cdo.Materials; for i, m in ipairs(old_mats) do a[i] = m end end)
    for f, list in pairs(old_w) do pcall(function() local a = cdo[f]; for i, m in ipairs(list) do a[i] = m end end) end
    local t_spawn = os.clock() - t0
    if not (ok and util.valid(z)) then log.warn("zombies: spawn failed for " .. tostring(e.cls)); return nil end
    copy_addr[util.addr(z)] = id
    destroyed[util.addr(z)] = nil
    -- SelectArchetype runs ~1 s from now: the copy takes the host's archetype instead (sync_look).
    for _, k in ipairs(ARCH_CHANCES) do pcall(function() z[k] = 0 end) end
    step("spawned, containing")
    contain_copy(z)
    local t_contain = os.clock() - t0 - t_spawn
    step("contained, applying look")
    local cur_mesh, cur_mat
    pcall(function() cur_mesh = z.Mesh:GetSkinnedAsset() end)
    pcall(function() cur_mat = z.Mesh:GetMaterial(0) end)
    local swapped = false
    if mesh and not util.same(cur_mesh, mesh) then
        swapped = true
        pcall(function() z.Mesh:SetSkinnedAssetAndUpdate(mesh, false) end)
    end
    if mat and not util.same(cur_mat, mat) then pcall(function() z.Mesh:SetMaterial(0, mat) end) end
    local fam = family_of(z)
    if fam ~= "zombie" then util.safe(dress_copy, "zombies.dress", z, fam, lk) end
    if stats.spawned < 6 then log.info("zombies: copy looks " .. (swapped and "swapped after the spawn" or "picked by the game itself")) end
    stats.spawned = stats.spawned + 1
    if stats.spawned <= 6 then
        log.info(string.format("zombies: copy spawn took %.0f ms (SpawnActor %.0f, contain %.0f, looks %.0f ms)",
            (os.clock() - t0) * 1000, t_spawn * 1000, t_contain * 1000, (os.clock() - t0 - t_spawn - t_contain) * 1000))
    end
    if first then
        spawned_class[e.cls] = true
        log.info(string.format("zombies: first copy spawned in %.0f ms", (os.clock() - t0) * 1000))
    end
    return { z = z, track = track.new(2.0), seen = now, born = now, fam = fam }
end

ragdoll = function(z)
    pcall(function() z:StopAnimMontage(nil) end)
    pcall(function() z.CapsuleComponent:SetCollisionEnabled(0) end)
    pcall(function() z.Mesh:SetCollisionResponseToChannel(3, 2) end)
    pcall(function() z.Mesh:SetCollisionEnabled(3) end)
    pcall(function() z.Mesh:SetSimulatePhysics(true) end)
end

local function play_montage(c, path, pos)
    local m = find(path)
    if not m then return end
    pcall(function() c.z:PlayAnimMontage(m, 1.0, FName("None")) end)
    if pos and pos > 0.05 then
        pcall(function() c.z.Mesh:GetAnimInstance():Montage_SetPosition(m, pos) end)
    end
end

local spawner_in = 0.0
local volumes_stopped = {}
local native_in = 0.0
local function suppress_natives()
    for a, t in pairs(destroyed) do if now - t > 120 then destroyed[a] = nil end end
    local n_sp = 0
    spawner_in = spawner_in - 2.0
    local spawners_scanned = spawner_in <= 0
    if spawners_scanned then
        spawner_in = 10.0
        for _, cls in ipairs({ SPAWNER, "BP_AISpawner_Animals_C" }) do
            for _, s in ipairs(util.instances(cls, "/Game/AI/AISpawners/BP_AISpawner_Master.BP_AISpawner_Master_C")) do
                util.pause()
                if util.valid(s) then
                    local stopped = false
                    pcall(function() stopped = s.IsSpawningStopped == true end)
                    if not stopped then pcall(function() s:SetIsSpawningStopped(true) end); n_sp = n_sp + 1 end
                end
            end
        end
        for _, cls in ipairs({ "BP_AISpawningVolume_Prefab_C", "BP_AISpawningVolume_RandomChanceToSpawn_C" }) do
            for _, v in ipairs(util.instances(cls, "/Game/AI/Humans/" .. cls:gsub("_C$", "") .. "." .. cls)) do
                util.pause()
                local a = util.addr(v) or 0
                if util.valid(v) and not volumes_stopped[a] then
                    volumes_stopped[a] = true
                    pcall(function() local f = v["Stop Spawning"]; f(v) end)
                    n_sp = n_sp + 1
                end
            end
        end
    end
    native_in = native_in - 2.0
    local n_z = 0
    local sweep = native_in <= 0 and not spawners_scanned
    if sweep then native_in = 2.0 end
    for _, z in ipairs(sweep and zombies_cached(now) or {}) do
        util.pause()
        local a = util.addr(z) or 0
        if not zombies.is_copy(z) and not (destroyed[a] and now - destroyed[a] < 120) then
            destroyed[a] = now
            pcall(function()
                local c = z.Controller
                destroy_holdables(z)
                z:K2_DestroyActor()
                if util.valid(c) then c:K2_DestroyActor() end
            end)
            n_z = n_z + 1
        end
    end
    if n_sp > 0 or n_z > 0 then
        stats.spawners = stats.spawners + n_sp
        stats.removed_native = stats.removed_native + n_z
        log.info(string.format("zombies: stopped %d spawner(s), removed %d own zombie(s)", n_sp, n_z))
    end
end

local snap_count = 0

local relooked = 0
local function keep_look(id, c, e)
    local z = c.z
    if c.dead_at or not util.valid(z) then return end
    local mesh, mat = find(e.mesh), find(e.mat)
    if not mesh and e.mesh and e.mesh ~= "-" then loader.want(e.mesh) end
    if not mat and e.mat and e.mat ~= "-" then loader.want(e.mat) end
    local fixed = false
    if mesh then
        local cur
        pcall(function() cur = z.Mesh:GetSkinnedAsset() end)
        if not util.same(cur, mesh) then perf.run("z.look.mesh", function() pcall(function() z.Mesh:SetSkinnedAssetAndUpdate(mesh, false) end) end); fixed = true end
    end
    if mat then
        local cur
        pcall(function() cur = material_asset(z.Mesh:GetMaterial(0)) end)
        if not util.same(cur, mat) then perf.run("z.look.mat", function() pcall(function() z.Mesh:SetMaterial(0, mat) end) end); fixed = true end
    end
    if fixed then
        relooked = relooked + 1
        if relooked <= 5 then log.info("zombies: copy " .. id .. " had changed its look - the host's put back") end
    end
end

-- The copy's own delayed rolls (async mesh/material load, archetype, eye glow) land after the spawn:
-- every few seconds put the host's back.
local LOOK_AFTER, LOOK_EVERY = 2.0, 5.0
local arch_mismatch = 0
local function sync_look(id, c, e)
    local z, x = c.z, xlooks[id]
    if c.dead_at or not util.valid(z) then return end
    if x and x.arch > 0 and c.arch ~= x.arch then
        local mine
        pcall(function() mine = arch_of(z, z:GetFName():ToString()) end)
        if mine ~= x.arch then
            local ok, err
            perf.run("z.look.arch", function() ok, err = pcall(function() local f = z["Archetype_" .. ARCH[x.arch]]; f(z) end) end)
            if not ok then log.warn("zombies: copy " .. id .. " archetype " .. ARCH[x.arch] .. ": " .. tostring(err)) end
        end
        c.arch = x.arch
    elseif x and x.arch == 0 and not c.arch then
        c.arch = 0
        local mine
        pcall(function() mine = arch_of(z, z:GetFName():ToString()) end)
        if mine and mine > 0 then
            arch_mismatch = arch_mismatch + 1
            if arch_mismatch <= 5 then log.info("zombies: copy " .. id .. " rolled " .. ARCH[mine] .. " here, the host's has none (kept)") end
        end
    end
    keep_look(id, c, e)
    if not x then return end
    local have = bones_of(z)
    if have ~= x.bones then perf.run("z.look.bones", function()
        for i = 1, #BONES do
            local want, got = (x.bones // BIT[i]) % 2 == 1, (have // BIT[i]) % 2 == 1
            if want and not got then pcall(function() z.Mesh:HideBoneByName(bone_fname(i), 0) end)
            elseif got and not want and not c.bones_done then pcall(function() z.Mesh:UnHideBoneByName(bone_fname(i)) end) end
        end
    end) end
    c.bones_done = true
    local glow = eyes_of(z)
    if x.eyes == 1 and glow == 0 then
        local off = false
        pcall(function()
            off = util.cdo("/Script/Engine.Default__KismetSystemLibrary"):GetConsoleVariableBoolValue("Game.DisableZombieEyes") == true
        end)
        perf.run("z.look.eyes", function() pcall(function() z:Event_EyesCallback(off) end) end)
    elseif x.eyes == 0 and glow == 1 then
        local mat = find(e.mat)
        if mat then pcall(function() z.Mesh:SetMaterial(0, mat) end) end
    end
end

-- For tools/test-sync.py.
zombies._look = { arch_of = function(z, n) return arch_of(z, n) end, bones_of = function(z) return bones_of(z) end,
                  sync = function(id, c, e, x) xlooks[id] = x; sync_look(id, c, e) end }
zombies._host = { tick = function(c, dt) cfg = cfg or c; now = now + dt; host_tick(dt) end }

local function read_snapshot()
    local body = link.get_blob("zombies")
    if not body then return end
    snap_count = snap_count + 1
    local snap_t = zclock:place(tonumber(body:match("\nT (%S+)")), now) or now
    local dict, seen = {}, {}
    -- at most 6 look checks per snapshot: copies spawned together would otherwise all re-check in one
    -- frame every LOOK_EVERY (~40 ms hitch at 40 copies); the rest go on the next snapshots
    local looks_left = 6
    for line in body:gmatch("[^\n]+") do
        local i, p = line:match("^D (%d+) (.+)$")
        if i then dict[tonumber(i)] = p end
    end
    for lid, rest in body:gmatch("\nL (%d+) ([^\n]+)") do
        local f = {}
        for v in rest:gmatch("%S+") do f[#f + 1] = v end
        local lk = {}
        for k, key in ipairs(LOOK_KEYS) do
            local n = tonumber(f[k] or "0") or 0
            lk[key] = (n > 0) and dict[n] or "-"
        end
        local id = tonumber(lid)
        looks[id] = lk
        host_health[id] = tonumber(f[#LOOK_KEYS + 1] or "")
        host_behaviour[id] = tonumber(f[#LOOK_KEYS + 2] or "")
    end
    for xid, a, b, ey in body:gmatch("\nX (%d+) (%d+) (%d+) (%d+)") do
        xlooks[tonumber(xid)] = { arch = tonumber(a), bones = tonumber(b), eyes = tonumber(ey) }
    end
    for i1, c1, m1, t1, x, y, z, yw, vx, vy, vz, mo, mp, dd in body:gmatch(
            "Z (%d+) (%d+) (%d+) (%d+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%d+) (%S+) (%d)") do
        do
            local id = tonumber(i1)
            local e = {
                cls = dict[tonumber(c1)], mesh = dict[tonumber(m1)], mat = dict[tonumber(t1)],
                loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, yaw = tonumber(yw),
                vel = { X = tonumber(vx), Y = tonumber(vy), Z = tonumber(vz) },
                montage = dict[tonumber(mo)], mpos = tonumber(mp), dead = dd == "1",
            }
            seen[id] = true
            local c = copies[id]
            if not c and not e.dead and (not spawn_gate or spawn_gate(id)) then
                perf.run("z.spawn", function() c = spawn_copy(id, e) end); copies[id] = c
                if c and on_spawned then util.safe(on_spawned, "zombies.on_spawned", id, c.z) end
            end
            if c then
                c.seen, c.seen_snap = now, snap_count
                c.track:push(snap_t, { loc = e.loc, yaw = e.yaw, vel = e.vel, crouch = nil })
                if e.dead and not c.dead_at and c.fam and c.fam ~= "zombie" then
                    c.dead_at, c.die_at = now, now + DEATH_WAIT
                elseif e.dead and not c.dead_at then
                    c.dead_at = now
                    local ok, err = xp.without(function() c.z:Death(game.player(), false) end)
                    util.safe(function()
                        log.info("zombies: copy " .. id .. " died - its loot: " .. invdiag.summary(c.z.BP_JigMultiplayer.MainJigContainers))
                    end, "zombies.loot_log")
                    if not ok then
                        log.warn("zombies: copy Death() failed, ragdolling instead: " .. tostring(err))
                        ragdoll(c.z)
                    end
                elseif not e.dead then
                    if e.montage ~= c.montage or (e.montage and e.mpos + 0.05 < (c.mpos or 0)) then
                        if e.montage then play_montage(c, e.montage, e.mpos)
                        else pcall(function() c.z:StopAnimMontage(nil) end) end
                    end
                    c.montage, c.mpos = e.montage, e.mpos
                    if c.fam == "zombie" and looks_left > 0 and now - (c.look_at or 0) > LOOK_EVERY
                            and now - (c.born or now) > LOOK_AFTER then
                        c.look_at, looks_left = now, looks_left - 1
                        perf.run("z.look", function() util.safe(sync_look, "zombies.look", id, c, e) end)
                    end
                end
            end
        end
    end
end

local function copy_died(z) return dead_of(z) end

-- A destroyed actor stays valid until garbage collection and reads its location as 0,0,0.
local function copy_broken(z)
    local root, l
    pcall(function() root = z:K2_GetRootComponent() end)
    if not util.valid(root) then return true end
    pcall(function() l = z:K2_GetActorLocation() end)
    return l ~= nil and math.abs(l.X) < 1 and math.abs(l.Y) < 1 and math.abs(l.Z) < 1
end

local CHECK_EVERY = 0.2
local frame_dt = 0.0
local function checks_due(c)
    c.check_in = (c.check_in or math.random() * CHECK_EVERY) - frame_dt
    c.check_now = c.check_in <= 0
    if c.check_now then c.check_in = CHECK_EVERY end
    return c.check_now
end

local frame_no, my_loc = 0, nil
local NEAR_M = 12
local function drive(dt)
    local delay = zclock:delay(dt or 0)
    local near_delay = zclock:near_delay()
    frame_no = frame_no + 1
    if frame_no % 6 == 0 or not my_loc then
        pcall(function() local l = game.player():K2_GetActorLocation(); my_loc = { X = l.X, Y = l.Y, Z = l.Z } end)
    end
    for id, c in pairs(copies) do
        if c.die_at and util.valid(c.z) and (c.guest_kill or now >= c.die_at) then
            c.die_at = nil
            local killer = c.guest_kill and game.player() or ghost.get()
            util.safe(kill_copy, "zombies.kill_copy", c, killer)
            log.info(string.format("zombies: %s copy %d died (%s)", tostring(c.fam), id, c.guest_kill and "my kill" or "the host's kill"))
        end
        if not c.dead_at and c.fam and c.fam ~= "zombie" and util.valid(c.z) and c.check_now then
            sync_health(c, host_health[id])
            local b = host_behaviour[id]
            if c.fam == "human" and b and b >= 0 and b ~= c.behaviour then
                c.behaviour = b
                pcall(function() smart_ai(c.z)["AI Current Behaviour"] = b end)
            end
        end
        if not util.valid(c.z) then
            copies[id] = nil
        elseif snap_count - (c.seen_snap or snap_count) > cfg.zombies.despawn_after * cfg.zombies.send_hz then
            destroy_copy(id, "gone")
        elseif not c.dead_at and checks_due(c) and copy_died(c.z) then
            c.dead_at = now
            hits:send(string.format("D %d %.3f 0 %s", id, 100000, "/Game/Blueprints/Other/Damage/Damage_Body.Default__Damage_Body_C"))
            log.info("zombies: copy " .. id .. " died here before the host said so - kept as a corpse, the host's one finished")
        elseif not c.dead_at and c.check_now and copy_broken(c.z) then
            local a = util.addr(c.z) or 0
            copy_addr[a] = nil
            destroyed[a] = now
            copies[id] = nil
            stats.respawned = (stats.respawned or 0) + 1
            log.info("zombies: copy " .. id .. " was removed by the game - making a new one")
        elseif not c.dead_at and (c.lod or 1) > 1 and (frame_no + c.lod_phase) % c.lod ~= 0 then
        elseif not c.dead_at then
            local d_use = delay
            if my_loc then
                local n = c.track:newest()
                if n and util.dist(n.loc, my_loc) < NEAR_M * 100 then d_use = near_delay end
            end
            local p = c.track:at(now - d_use, util, 0.25)
            if p then
                if not util.move(c.z, p.loc, p.yaw) then
                    pcall(function() c.z:K2_SetActorLocationAndRotation(p.loc, util.rot(0, p.yaw, 0), false, {}, true) end)
                end
                local px, py, pz = p.loc.X, p.loc.Y, p.loc.Z
                if c.vel_snap ~= snap_count then
                    c.vel_snap = snap_count
                    local v = c.vel_t or {}
                    c.vel_t = v
                    v.X, v.Y, v.Z = p.vel.X, p.vel.Y, p.vel.Z
                    if (v.X * v.X + v.Y * v.Y) < 400 then
                        local q = c.track:at(now - delay - 0.15, util, 0.25)
                        if q then
                            local dx, dy = (px - q.loc.X) / 0.15, (py - q.loc.Y) / 0.15
                            if dx * dx + dy * dy > 900 then v.X, v.Y, v.Z = dx, dy, 0; stats.vel_from_track = (stats.vel_from_track or 0) + 1 end
                        end
                    end
                    pcall(function() c.z.CharacterMovement.Velocity = v end)
                end
                if c.check_now then
                    pcall(function()
                        if c.z.CharacterMovement.MovementMode ~= 1 then c.z.CharacterMovement:SetMovementMode(1, 0) end
                    end)
                    local d = 0
                    if my_loc then local dx, dy, dz = my_loc.X - px, my_loc.Y - py, my_loc.Z - pz; d = math.sqrt(dx * dx + dy * dy + dz * dz) end
                    c.lod = d > 10000 and 4 or (d > 6000 and 2 or 1)
                    c.lod_phase = c.lod_phase or (id % 4)
                    -- Copies have the game's AI optimizer off, so their anim ran full rate even
                    -- off-screen. Past 40 m the engine now skips the pose only on frames the copy
                    -- isn't drawn (montages still tick); on screen it animates exactly as before.
                    -- (enum: 0 AlwaysTickPoseAndRefreshBones, 1 AlwaysTickPose, 2 OnlyTickMontagesAndRefresh-
                    -- BonesWhenPlayingMontages, 3 OnlyTickMontagesWhenNotRendered, 4 OnlyTickPoseWhenRendered;
                    -- the game's zombie meshes already ship with 4, so this only matters for lower ones)
                    local far = d > 4000 and cfg.zombies.offscreen_anim ~= false
                    if far ~= (c.anim_far or false) then
                        pcall(function()
                            local m = c.z.Mesh
                            if c.anim_tick0 == nil then
                                c.anim_tick0 = m.VisibilityBasedAnimTickOption
                                if not stats.anim_tick0 then stats.anim_tick0 = true; log.info("zombies: copies' own anim tick option is " .. tostring(c.anim_tick0)) end
                            end
                            m.VisibilityBasedAnimTickOption = far and math.max(c.anim_tick0, 3) or c.anim_tick0
                            c.anim_far = far
                        end)
                    end
                end
            end
        end
    end
end

local apply_dmg, apply_med, apply_zhit
local apply_fx
local fx_errors = 0

local function guest_tick(dt)
    frame_dt = dt
    hits:pump(function() end)
    dmgs:pump(function(payload) if active then util.safe(apply_dmg, "zombies.dmg", payload) end end)
    meds:pump(function(payload) if active then util.safe(apply_med, "zombies.med", payload) end end)
    zhits:pump(function(payload) if active then util.safe(apply_zhit, "zombies.zhit", payload) end end)
    aifx:pump(function(payload) if active then util.safe(apply_fx, "zombies.fx", payload) end end)
    zkills:pump(function(payload)
        local id, amount = payload:match("^(%S+)%s*(%S*)$")
        local c = copies[tonumber(id)]
        if c and c.fam and c.fam ~= "zombie" then
            c.guest_kill = true
            return
        end
        util.safe(function() xp.reward_kill(c and util.valid(c.z) and c.z or nil, tonumber(amount)) end, "zombies.zkill")
    end)
    spawn_budget = 1
    local joined = session.in_world() and util.valid(game.player())
    if joined ~= active then
        active, active_at = joined, now
        if not active then destroy_all_copies("left the host's world")
        else log.info("zombies: in the host's world - showing the host's zombies") end
        spawner_in = 0.0
        volumes_stopped = {}
        native_in = 0.0
        pass_in = 0.0
        loot_ok, loot_wait_logged = false, -100
    end
    if not active then return end
    local busy = now - active_at < 20 or require("mirror.save_guard").busy()
    util.safe(loader.tick, "zombies.loader", dt, busy)
    pass_in = pass_in - dt
    if pass_in <= 0 then perf.run("z.pass", function()
        pass_in = 2.0
        local ok, missing = loot_ready()
        loot_ok = ok
        if ok then
            util.job("zombies.sweep", suppress_natives)
        elseif now - loot_wait_logged > 10 then
            loot_wait_logged = now
            log.info(string.format("zombies: waiting for the game to load its zombie data (%d/%d loot tables missing) - "
                .. "your own spawners stay on until then", missing, #LOOT_TABLES))
        end
        install_hit_hooks()
        hook_archetypes()
    end) end
    perf.run("z.read", read_snapshot)
    perf.run("z.drive", drive, dt)
end

local selftest_in, selftest_copy = 0.0, nil
local function selftest_file() return (os.getenv("LOCALAPPDATA") or ".") .. "\\SurrounDead\\mirror_selftest_" .. role .. ".txt" end

local want_steamtest = false

local function bench()
    local c
    for _, cc in pairs(copies) do if not cc.dead_at and util.valid(cc.z) then c = cc; break end end
    if not c then log.info("selftest: bench needs a living zombie copy (join first)"); return end
    local z = c.z
    local loc = z:K2_GetActorLocation()
    local l = { X = loc.X, Y = loc.Y, Z = loc.Z }
    local r = { Pitch = 0, Yaw = z:K2_GetActorRotation().Yaw, Roll = 0 }
    local root = z:K2_GetRootComponent()
    local N = 50
    local tests = {
        { "SetActorLocationAndRotation fresh {}", function() z:K2_SetActorLocationAndRotation(l, r, false, {}, false) end },
        { "SetActorLocationAndRotation fresh {} teleport", function() z:K2_SetActorLocationAndRotation(l, r, false, {}, true) end },
        { "TeleportTo", function() z:K2_TeleportTo(l, r) end },
        { "root SetWorldLocationAndRotation fresh {}", function() root:K2_SetWorldLocationAndRotation(l, r, false, {}, false) end },
        { "SetActorLocation fresh {}", function() z:K2_SetActorLocation(l, false, {}, false) end },
        { "SetActorRotation", function() z:K2_SetActorRotation(r, false) end },
        { "CharacterMovement.Velocity write", function() z.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 } end },
        { "K2_GetActorLocation", function() z:K2_GetActorLocation() end },
    }
    for _, t in ipairs(tests) do
        collectgarbage("collect")
        local m0, t0 = collectgarbage("count"), os.clock()
        local ok, err = true, nil
        for _ = 1, N do
            ok, err = pcall(t[2])
            if not ok then break end
        end
        local dt, dm = os.clock() - t0, collectgarbage("count") - m0
        collectgarbage("collect")
        local kept = collectgarbage("count") - m0
        log.info(string.format("selftest: bench %-45s %8.3f ms/call  %6.2f KB/call allocated  %6.2f KB/call kept after GC%s",
            t[1], dt / N * 1000, dm / N, kept / N, ok and "" or (" FAILED: " .. tostring(err))))
    end
    log.info("selftest: bench done (" .. N .. " calls each)")
end

local function selftest_tick(dt)
    if want_steamtest then
        want_steamtest = false
        log.info("selftest: link status (Ctrl+F12): " .. require("mirror.link").status())
    end
    if selftest_copy then
        selftest_copy.t = selftest_copy.t - dt
        if selftest_copy.t <= 0 then
            pcall(function() selftest_copy.z:K2_DestroyActor() end)
            log.info("selftest: copy removed")
            selftest_copy = nil
        end
    end
    selftest_in = selftest_in - dt
    if selftest_in > 0 then return end
    selftest_in = 1.0
    local f = io.open(selftest_file(), "r")
    if not f then return end
    local cmd = (f:read("*l") or ""):gsub("%s+$", "")
    f:close()
    os.remove(selftest_file())
    log.info("selftest: command '" .. cmd .. "'")
    local ok, missing = loot_ready()
    log.info(string.format("selftest: loot tables in memory: %s (%d/%d missing)", tostring(ok), missing, #LOOT_TABLES))
    if cmd == "spawn" then
        local p = game.player()
        local l, yaw = p:K2_GetActorLocation(), p:K2_GetActorRotation().Yaw
        local r = math.rad(yaw)
        local cls
        for _, h in ipairs(HUMANOID) do
            if not cls and find(h) then cls = h end
        end
        if not cls then log.info("selftest: no humanoid zombie class in memory"); return end
        log.info("selftest: SpawnActor " .. cls .. " ...")
        local t0 = os.clock()
        local saved_ok, saved_budget = loot_ok, spawn_budget
        loot_ok, spawn_budget = true, 1
        local c = spawn_copy(-1, { cls = cls, loc = { X = l.X + math.cos(r) * 500, Y = l.Y + math.sin(r) * 500, Z = l.Z },
                                   yaw = yaw + 180 })
        loot_ok, spawn_budget = saved_ok, saved_budget
        log.info(string.format("selftest: spawn returned %s after %.0f ms", c and "a copy" or "nil", (os.clock() - t0) * 1000))
        if c then selftest_copy = { z = c.z, t = 5.0 } end
    elseif cmd == "bench" then
        bench()
    elseif cmd:match("^load ") then
        local path = cmd:sub(6)
        log.info("selftest: already in memory: " .. tostring(util.valid(StaticFindObject(path))) .. "; LoadAsset " .. path .. " ...")
        local t0 = os.clock()
        local lok, err = pcall(function() LoadAsset(path) end)
        log.info(string.format("selftest: LoadAsset returned (%s) after %.0f ms; in memory now: %s",
            lok and "ok" or tostring(err), (os.clock() - t0) * 1000, tostring(util.valid(StaticFindObject(path)))))
    end
end

local loot_pinned, pin_in, pin_wait = false, 0.0, 2.0
local function pin_loot(dt)
    if loot_pinned or role == "host" then return end
    pin_in = pin_in - dt
    if pin_in > 0 then return end
    pin_in = pin_wait
    if not loot_ready() then pin_wait = math.min(pin_wait * 2, 30); return end
    local gi = FindFirstOf("SD_GameInstance_C")
    if not util.valid(gi) then return end
    local added, ok = 0, true
    for _, n in ipairs(LOOT_TABLES) do
        local t = loot_obj[n]
        local done = pcall(function()
            local arr = gi.ReferencedObjects
            arr[arr:GetArrayNum() + 1] = t
        end)
        if done then added = added + 1 else ok = false end
    end
    local total = -1
    pcall(function() total = gi.ReferencedObjects:GetArrayNum() end)
    loot_pinned = true
    log.info(string.format("zombies: pinned %d/%d loot tables in GameInstance.ReferencedObjects (now %d entries)%s",
        added, #LOOT_TABLES, total, ok and "" or " - some failed"))
end

function zombies.host_zombies() return by_id end
function zombies.dev_guest_kill()
    local p = game.player()
    local pl, best, bd = nil, nil, math.huge
    pcall(function() pl = p:K2_GetActorLocation() end)
    for id, c in pairs(copies) do
        if not c.dead_at and util.valid(c.z) and pl then
            local l
            pcall(function() l = c.z:K2_GetActorLocation() end)
            local d = l and util.dist(pl, l) or math.huge
            if d < bd then best, bd = id, d end
        end
    end
    if not best then log.info("devtest: gkill - no living copy"); return end
    hits:send(string.format("D %d %.3f 0 %s", best, 1000, "/Game/Blueprints/Other/Damage/Damage_Body.Default__Damage_Body_C"))
    log.info(string.format("devtest: gkill - lethal hit sent for copy %d (%.0f m)", best, bd / 100))
end

function zombies.all_cached() return zombies_cached(now) end
function zombies.host_id_of(z)
    local a
    pcall(function() a = z:GetFName():ToString() end)
    return a and ids[a] or nil
end
function zombies.copy(id) return copies[id] end
function zombies.set_copy_hooks(gate, spawned) spawn_gate, on_spawned = gate, spawned end
function zombies.set_guest_center(fn) guest_center = fn end
function zombies.copies() return copies end
function zombies.copy_id_of(z) return copy_addr[util.addr(z) or 0] end
function zombies.now() return now end

-- Guest: the local player's radiation, read every frame. A copy's radiation call (a radiated zombie's death
-- blast) can't be stopped by zeroing its params - the hook may run after the function - so it is taken back
-- to this value instead (the host's real zombie already sends its own).
-- (one table: this file is near Lua's 200-locals limit)
local rad = { path = "/Game/Blueprints/Components/RadiationComponent.RadiationComponent_C", retry = 0 }
function rad.watch(dt)
    if not util.valid(rad.comp) then
        rad.comp, rad.seen = nil, nil
        rad.retry = rad.retry - dt
        if rad.retry > 0 then return end
        rad.retry = 5
        local p = game.player()
        if not util.valid(p) then return end
        rad.cls = util.valid(rad.cls) and rad.cls or StaticFindObject(rad.path)
        if not util.valid(rad.cls) then return end
        pcall(function() rad.comp = p:GetComponentByClass(rad.cls) end)
        if not util.valid(rad.comp) then rad.comp = nil; return end
    end
    local v
    pcall(function() v = rad.comp.CurrentRadiation end)
    rad.seen = type(v) == "number" and v or nil
end

function rad.take_back(amount)
    if not (util.valid(rad.comp) and rad.seen and amount and amount > 0) then return end
    local cur
    pcall(function() cur = rad.comp.CurrentRadiation end)
    if type(cur) ~= "number" or cur >= rad.seen then return end
    local back = math.min(rad.seen - cur, amount)
    pcall(function()
        rad.comp.CurrentRadiation = cur + back
        rad.comp:DecreaseRadiation(0)
    end)
    log.info(string.format("zombies: took back %.2f radiation from a copy", back))
end
zombies._rad = rad

function zombies.tick(dt)
    if not (cfg and cfg.zombies.enabled) then return end
    if role ~= "host" then util.safe(rad.watch, "zombies.watch_rad", dt) end
    now = now + dt
    util.safe(selftest_tick, "zombies.selftest", dt)
    util.safe(pin_loot, "zombies.pin_loot", dt)
    util.safe(xp.tick, "zombies.xp")
    util.safe(watch_begin, "zombies.watch_begin", dt)
    if role == "host" then perf.run("z.host", host_tick, dt) else guest_tick(dt) end
end

local function in_reach(id, x, y, z)
    local p = game.player()
    if not util.valid(p) then return false, 0 end
    local c = copies[tonumber(id)]
    local from = { X = tonumber(x) or 0, Y = tonumber(y) or 0, Z = tonumber(z) or 0 }
    if c and util.valid(c.z) then pcall(function() from = util.vec(c.z.Mesh:K2_GetComponentLocation()) end) end
    local pl
    pcall(function() pl = util.vec(p:K2_GetActorLocation()) end)
    local d = pl and util.dist(from, pl) or 0
    return d <= cfg.zombies.dmg_reach, d
end

local function i_am_dead()
    local d = false
    pcall(function() d = game.player()["PlayerDead?"] == true end)
    return d
end

apply_zhit = function(payload)
    local id, amt, cls = payload:match("^(%d+) (%S+) (%S+)$")
    local c = id and copies[tonumber(id)]
    if not (c and util.valid(c.z)) then log.info("zombies: host hit on zombie " .. tostring(id) .. " - no copy of it here"); return end
    local dtc = cls ~= "-" and find(cls) or nil
    local causer = ghost.get()
    local amount = tonumber(amt) or 1
    if c.fam == "animal" then pcall(function() c.z.Health = c.z.Health + amount + 1 end)
    elseif c.fam == "boss" then pcall(function() c.z.DamageComponent.CurrentHealth = c.z.DamageComponent.CurrentHealth + amount + 1 end) end
    replaying = true
    local ok, err = xp.without(function()
        util.cdo("/Script/Engine.Default__GameplayStatics"):ApplyDamage(c.z, tonumber(amt) or 1, nil,
            util.valid(causer) and causer or nil, dtc)
    end)
    replaying = false
    zhit_stats.played = zhit_stats.played + 1
    if not ok then log.warn("zombies: replaying a host hit failed: " .. tostring(err))
    else log.info(string.format("zombies: host hit on zombie %s replayed on its copy (%s)", id, amt)) end
end

apply_med = function(payload)
    if i_am_dead() then return end
    local kind, id, x, y, z, rest = payload:match("^(%a) (%-?%d+) (%S+) (%S+) (%S+) (.*)$")
    if not kind then return end
    local area = kind == "R" and rest:match("^%S+ %S+ 1") ~= nil
    local ok_reach, d = in_reach(id, x, y, z)
    if not ok_reach and not (area and d <= cfg.zombies.area_reach) then return end
    local p, lib = game.player(), util.cdo(GFL_CDO)
    if not lib then log.warn("zombies: GameFunctionLibrary not found"); return end
    local f = {}
    for v in rest:gmatch("%S+") do f[#f + 1] = v end
    local ok, err
    if kind == "M" then
        local names = {}
        for n in ((f[5] ~= "-" and f[5]) or ""):gmatch("[^,]+") do names[#names + 1] = FName((n:gsub("_", " "))) end
        ok, err = pcall(function()
            lib:ApplyMedicalEffect(p, names, tonumber(f[1]), tonumber(f[2]), tonumber(f[3]), tonumber(f[4]), p)
        end)
    elseif kind == "R" then
        ok, err = pcall(function() lib:ApplyRadiationDamage(p, tonumber(f[1]), tonumber(f[2]), f[3] == "1", p) end)
    elseif kind == "B" then
        ok, err = pcall(function() lib:ApplyBiteInfection(p, tonumber(f[1]), f[2] == "1", p) end)
    end
    if ok then log.info("zombies: zombie " .. id .. " effect " .. kind .. " " .. rest)
    else log.warn("zombies: applying effect " .. kind .. " failed: " .. tostring(err)) end
end

apply_dmg = function(payload)
    if i_am_dead() then return end
    local id, amt, cls, x, y, z, ranged = payload:match("^(%-?%d+) (%S+) (%S+) (%S+) (%S+) (%S+) ?(%d?)$")
    amt = tonumber(amt)
    if not amt or amt <= 0 then return end
    local p = game.player()
    if not util.valid(p) then return end
    local c = copies[tonumber(id)]
    local causer = c and util.valid(c.z) and c.z or nil
    local from = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    if causer then pcall(function() from = util.vec(causer:K2_GetActorLocation()) end) end
    local pl
    pcall(function() pl = util.vec(p:K2_GetActorLocation()) end)
    local d = pl and util.dist(from, pl) or 0
    if ranged ~= "1" and d > cfg.zombies.dmg_reach then
        dmg_stats.dodged = dmg_stats.dodged + 1
        log.info(string.format("zombies: dodged a hit for %.1f (zombie %.1f m away here)", amt, d / 100))
        return
    end
    local dtc = (cls ~= "-") and find(cls) or nil
    allow_copy_damage = true
    local ok, err = pcall(function()
        util.cdo("/Script/Engine.Default__GameplayStatics"):ApplyDamage(p, amt, nil, causer, dtc)
    end)
    allow_copy_damage = false
    dmg_stats.applied = dmg_stats.applied + 1
    if ok then log.info(string.format("zombies: took %.1f damage from zombie %s", amt, id))
    else log.warn("zombies: ApplyDamage failed: " .. tostring(err)) end
end

function zombies.status()
    if role == "host" then
        local n = 0; for _ in pairs(ids) do n = n + 1 end
        return string.format("sending %d zombie(s), %d guest hit(s) applied, %d hit(s) on the guest sent, my hits sent %d", n, hit_count,
            dmg_stats.sent, zhit_stats.sent)
    end
    local n, dead, off_sum, off_max, off_n = 0, 0, 0, 0, 0
    for _, c in pairs(copies) do
        n = n + 1
        if c.dead_at then
            dead = dead + 1
        else
            local want, cur = c.track:newest(), nil
            pcall(function() cur = c.z:K2_GetActorLocation() end)
            if want and cur then
                local d = util.dist(want.loc, cur) / 100
                off_sum, off_n = off_sum + d, off_n + 1
                if d > off_max then off_max = d end
            end
        end
    end
    return string.format("%d copies (%d dead; spawned %d, replaced %d; off from host avg %.1f m, max %.1f m) own zombies removed %d, spawners stopped %d | hits taken %d, dodged %d, host hits replayed %d, speed from track %d",
        n, dead, stats.spawned, stats.respawned or 0, off_n > 0 and off_sum / off_n or 0, off_max, stats.removed_native, stats.spawners,
        dmg_stats.applied, dmg_stats.dodged, zhit_stats.played, stats.vel_from_track or 0)
end

local SAI = "/Game/SmartAI/Blueprints/AI/Components/BP_SmartAIComponent.BP_SmartAIComponent_C"
local function fx_id(comp_param)
    local comp, owner, id = util.obj(comp_param), nil, nil
    if not comp then return nil end
    pcall(function() owner = comp:GetOwner() end)
    if not util.valid(owner) then return nil end
    pcall(function() id = ids[owner:GetFName():ToString()] end)
    return id
end
local function v3(v) return string.format("%.1f %.1f %.1f", v.X, v.Y, v.Z) end
local function getp(p) local r; pcall(function() r = p:get() end); return r end
local fx_hooks = {
    ["Multicast Combat Stance"] = function(self, on)
        local id = fx_id(self); if id then aifx:send(string.format("S %d %d", id, getp(on) and 1 or 0)) end
    end,
    ["Multicast Start Aim Offset"] = function(self, target)
        local id = fx_id(self); if not id then return end
        local t, who = getp(target), "-"
        if t and ghost.is(t) then who = "G" elseif t and util.same(t, game.player()) then who = "P" end
        aifx:send(string.format("A %d %s", id, who))
    end,
    ["Multicast Stop Aim Offset"] = function(self)
        local id = fx_id(self); if id then aifx:send(string.format("a %d", id)) end
    end,
    ["Multicast Range Attack Partical"] = function(self, hit)
        local id = fx_id(self); if not id then return end
        local h = getp(hit); if not h then return end
        local ok, line = pcall(function()
            return string.format("R %d %s %s %s", id, v3(h.TraceStart), v3(h.ImpactPoint), v3(h.ImpactNormal))
        end)
        if ok then aifx:send(line) end
    end,
    ["Multicast Projectile Spawn"] = function(self, loc, vel, cls, speed)
        local id = fx_id(self); if not id then return end
        local ok, line = pcall(function()
            local l = getp(loc); l = l.Translation or l
            return string.format("J %d %s %s %.1f %s", id, v3(l), v3(getp(vel)), getp(speed) or 0, path_of(getp(cls)) or "-")
        end)
        if ok then aifx:send(line) end
    end,
    ["Multicast Sound"] = function(self, sound, vol)
        local id = fx_id(self); if not id then return end
        local sp = path_of(getp(sound)); if sp then aifx:send(string.format("N %d %.2f %s", id, getp(vol) or 1, sp)) end
    end,
    ["Multicast Melee Emitter"] = function(self, hit)
        local id = fx_id(self); if not id then return end
        local h = getp(hit); if not h then return end
        local ok, line = pcall(function() return string.format("M %d %s %s", id, v3(h.ImpactPoint), v3(h.ImpactNormal)) end)
        if ok then aifx:send(line) end
    end,
}
local function install_fx_hooks()
    for fn, cb in pairs(fx_hooks) do util.ensure_hook(SAI .. ":" .. fn, cb) end
end
local function hit_table(start, point, normal)
    return { bBlockingHit = true, TraceStart = start, TraceEnd = point, Location = point, ImpactPoint = point,
             Normal = normal, ImpactNormal = normal, Distance = util.dist(start, point), Time = 1.0 }
end
apply_fx = function(payload)
    local k, id, rest = payload:match("^(%a) (%d+) ?(.*)$")
    local c = id and copies[tonumber(id)]
    if not (c and util.valid(c.z) and not c.dead_at) then return end
    local ai = smart_ai(c.z)
    if not ai then return end
    local n = {}
    for x in rest:gmatch("%S+") do n[#n + 1] = x end
    local function vec(i) return { X = tonumber(n[i]) or 0, Y = tonumber(n[i + 1]) or 0, Z = tonumber(n[i + 2]) or 0 } end
    local function call(fn, ...) local f = ai[fn]; f(ai, ...) end
    local ok, err = pcall(function()
        if k == "S" then call("Multicast Combat Stance", n[1] == "1")
        elseif k == "A" then
            local t = (n[1] == "G") and game.player() or ((n[1] == "P") and ghost.get() or nil)
            if t then call("Multicast Start Aim Offset", t) else call("Multicast Stop Aim Offset") end
        elseif k == "a" then call("Multicast Stop Aim Offset")
        elseif k == "R" then call("Multicast Range Attack Partical", hit_table(vec(1), vec(4), vec(7)))
        elseif k == "M" then call("Multicast Melee Emitter", hit_table(vec(1), vec(1), vec(4)))
        elseif k == "N" then
            local snd = find(n[2]); if snd then call("Multicast Sound", snd, tonumber(n[1]) or 1) end
        elseif k == "J" then
            local cls = find(n[8])
            if cls then
                call("Multicast Projectile Spawn", { Translation = vec(1), Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                    Scale3D = { X = 1, Y = 1, Z = 1 } }, vec(4), cls, tonumber(n[7]) or 0)
            end
        end
    end)
    if not ok then
        fx_errors = fx_errors + 1
        if fx_errors <= 5 then log.warn("zombies: replaying a human's " .. k .. " failed: " .. tostring(err)) end
    end
end

-- The old world is gone: forget its zombies, copies and cached assets without touching them.
local function forget_world()
    ids, by_id, statics, watch_dead = {}, {}, {}, nil
    zlist, zlist_set, zlist_addr, zlist_new, zlist_at, zlist_pruned = {}, {}, {}, {}, -100, -100
    copies, copy_addr, destroyed, volumes_stopped, xlooks = {}, {}, {}, {}, {}
    arch_seen, arch_seen_n = {}, 0
    rad.comp, rad.seen, rad.retry = nil, nil, 0
    cache, missed, appeared, loot_obj, fam_cls, fam_retry, player_cls = {}, {}, {}, {}, {}, {}, nil
end

function zombies.init(c, r, s)
    cfg, role, session = c, r, s
    game.on_world_reset(forget_world)
    util.safe(watch_new_zombies, "zombies.watch")
    game.keybind("F12", { ModifierKey.CONTROL }, function() want_steamtest = true end)
    if not cfg.zombies.enabled then return end
    game.player_hook("ReceiveAnyDamage", function(self, Damage, DamageType, InstigatedBy, DamageCauser)
        local causer = util.obj(DamageCauser)
        local ai = (role == "host") and causer and ai_of(causer) or nil
        if role == "host" and ai and ghost.is(self:get()) then
            local amt, cls, id, l = 0, "-", -1, { X = 0, Y = 0, Z = 0 }
            pcall(function() amt = Damage:get() end)
            cls = util.class_path(util.obj(DamageType)) or "-"
            pcall(function() id = ids[ai:GetFName():ToString()] or -1 end)
            pcall(function() l = ai:K2_GetActorLocation() end)
            local fam = family_of(ai)
            local ranged = (fam == "human" or fam == "boss") and 1 or 0
            if amt > 0 then
                dmgs:send(string.format("%d %.3f %s %.1f %.1f %.1f %d", id, amt, cls, l.X, l.Y, l.Z, ranged))
                dmg_stats.sent = dmg_stats.sent + 1
            end
            return
        end
        if allow_copy_damage then return end
        local from_copy = causer and zombies.is_copy(causer)
        if causer and not from_copy then
            for _, f in ipairs({ "GetOwner", "GetInstigator" }) do
                local o
                pcall(function() o = causer[f](causer) end)
                if zombies.is_copy(o) then from_copy = true end
            end
        end
        if from_copy then
            pcall(function() Damage:set(0) end)
            log.warn("zombies: blocked damage from a zombie copy")
        end
    end)
    if role == "host" then
        local DC = "/Game/Blueprints/Components/DamageComponent.DamageComponent_C"
        local function on_host_damage(self, DmgAmount, DmgType, DmgCauser)
            if role ~= "host" then return end
            local owner, causer
            pcall(function() owner = self:get():GetOwner() end)
            if not (owner and is_zombie(owner)) then return end
            local id
            pcall(function() id = ids[owner:GetFName():ToString()] end)
            if not id or applying_hit then return end
            -- bosses pass junk pointers here; reading them crashes outside pcall
            local boss = family_of(owner) == "boss"
            if not boss then
                causer = util.obj(DmgCauser)
                if causer and ghost.is(causer) then return end
            end
            local amt, cls = 0, "-"
            pcall(function() amt = DmgAmount:get() end)
            if not boss then cls = util.class_path(util.obj(DmgType)) or "-" end
            if amt > 0 then
                zhits:send(string.format("%d %.3f %s", id, amt, cls))
                zhit_stats.sent = zhit_stats.sent + 1
                log.info(string.format("zombies: my hit on zombie %d (%.0f, %s) -> guest", id, amt, cls:match("([%w_]+)$") or cls))
            end
        end
        install_host_hooks = function() util.ensure_hook(DC .. ":DamageTaken", on_host_damage) end
        local function zinfo(actor_param, ctx_param)
            if role ~= "host" then return nil end
            local target = util.obj(actor_param)
            if not (target and ghost.is(target)) then return nil end
            local gl, best, bd = ghost.location(), nil, math.huge
            local ctx = util.obj(ctx_param)
            if ctx and is_zombie(ctx) then best, bd = ctx, 0 end
            for _, zz in ipairs(best and {} or zombies_cached(now)) do
                local l
                pcall(function() l = zz:K2_GetActorLocation() end)
                if l and gl then
                    local d = util.dist(gl, l)
                    if d < bd then best, bd = zz, d end
                end
            end
            local id, l = -1, gl or { X = 0, Y = 0, Z = 0 }
            if best then
                pcall(function() id = ids[best:GetFName():ToString()] or -1 end)
                pcall(function() l = best.Mesh:K2_GetComponentLocation() end)
            end
            return string.format("%d %.1f %.1f %.1f", id, l.X, l.Y, l.Z)
        end
        local function g(v) local r; pcall(function() r = v:get() end); return r end
        game.on_ready(function()
            util.hook(GFL .. ":ApplyMedicalEffect", function(self, Actor, Effects, CB, CHB, CBB, CI, Ctx)
                local who = zinfo(Actor, Ctx)
                if not who then return end
                local names = {}
                pcall(function() Effects:get():ForEach(function(_, e) names[#names + 1] = (e:get():ToString():gsub(" ", "_")) end) end)
                meds:send(string.format("M %s %.3f %.3f %.3f %.3f %s", who, g(CB) or 0, g(CHB) or 0, g(CBB) or 0, g(CI) or 0,
                    #names > 0 and table.concat(names, ",") or "-"))
            end)
            util.hook(GFL .. ":ApplyRadiationDamage", function(self, Actor, Chance, Rad, Mask, Ctx)
                local who = zinfo(Actor, Ctx)
                if not who then return end
                meds:send(string.format("R %s %.3f %.3f %d", who, g(Chance) or 0, g(Rad) or 0, g(Mask) and 1 or 0))
            end)
            util.hook(GFL .. ":ApplyBiteInfection", function(self, Actor, Chance, Crawler, Ctx)
                local who = zinfo(Actor, Ctx)
                if not who then return end
                meds:send(string.format("B %s %.3f %d", who, g(Chance) or 0, g(Crawler) and 1 or 0))
            end)
        end)
    else
        local function from_copy(actor_param, ctx_param)
            local target, ctx = util.obj(actor_param), util.obj(ctx_param)
            if not (target and ctx and zombies.is_copy(ctx)) then return false end
            local p = game.player()
            return p ~= nil and util.addr(target) == util.addr(p)
        end
        local function zero(...) for _, v in ipairs({ ... }) do pcall(function() v:set(0) end) end end
        local function g(v) local r; pcall(function() r = v:get() end); return r end
        game.on_ready(function()
            util.hook(GFL .. ":ApplyMedicalEffect", function(self, Actor, Effects, CB, CHB, CBB, CI, Ctx)
                if from_copy(Actor, Ctx) then zero(CB, CHB, CBB, CI); log.info("zombies: blocked a copy's medical effect") end
            end)
            util.hook(GFL .. ":ApplyRadiationDamage", function(self, Actor, Chance, Rad, Mask, Ctx)
                if from_copy(Actor, Ctx) then
                    local amount = g(Rad)
                    zero(Chance, Rad)
                    rad.take_back(amount)
                    log.info("zombies: blocked a copy's radiation")
                end
            end)
            util.hook(GFL .. ":ApplyBiteInfection", function(self, Actor, Chance, Crawler, Ctx)
                if from_copy(Actor, Ctx) then zero(Chance); log.info("zombies: blocked a copy's bite infection") end
            end)
        end)
    end
    local RAD_CLASSES = {
        "/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C",
        "/Game/AI/Humans/CoyoteSoldiers/BP_MasterCoyoteSoldier.BP_MasterCoyoteSoldier_C",
        "/Game/AI/Humans/Scavengers/BP_MasterScavenger.BP_MasterScavenger_C",
        TRADER,
        "/Game/AI/Animals/Deer/BP_AnimalDeer.BP_AnimalDeer_C",
        "/Game/AI/Animals/Wolf/BP_AnimalWolf.BP_AnimalWolf_C",
        "/Game/AI/Animals/Bear/BP_AnimalBear.BP_AnimalBear_C",
        "/Game/AI/Animals/Rabbit/BP_AnimalRabbit.BP_AnimalRabbit_C",
        "/Game/AI/Animals/Dog/BP_AnimalDog.BP_AnimalDog_C",
    }
    local function on_any_damage(self, Damage, DamageType, InstigatedBy, DamageCauser)
        if killing then return end
        local z, amt = util.obj(self), 0
        if not z then return end
        local causer = util.obj(DamageCauser)
        pcall(function() amt = Damage:get() end)
        local tp = path_of(util.obj(DamageType)) or "-"
        if not (amt and amt > 0) then return end
        if role == "guest" then
            local id = copy_addr[util.addr(z) or 0]
            if not id or replaying then return end
            if causer and zombies.is_copy(causer) then return end
            hits:send(string.format("D %d %.3f 0 %s", id, amt, tp))
        else
            local id
            pcall(function() id = ids[z:GetFName():ToString()] end)
            if not id or (causer and ghost.is(causer)) then return end
            local cls = util.class_path(util.obj(DamageType)) or "-"
            zhits:send(string.format("%d %.3f %s", id, amt, cls))
            zhit_stats.sent = zhit_stats.sent + 1
        end
    end
    local install_rad = function()
        for _, c in ipairs(RAD_CLASSES) do util.ensure_hook(c .. ":ReceiveAnyDamage", on_any_damage) end
    end
    local old_host_hooks = install_host_hooks
    install_host_hooks = function() old_host_hooks(); install_rad(); install_fx_hooks() end
    if role == "guest" then
        local DC = "/Game/Blueprints/Components/DamageComponent.DamageComponent_C"
        local body_cdo
        local function body_type()
            if not util.valid(body_cdo) then
                body_cdo = StaticFindObject("/Game/Blueprints/Other/Damage/Damage_Body.Default__Damage_Body_C")
            end
            return util.valid(body_cdo) and body_cdo or nil
        end
        local function copy_id(self)
            local owner
            pcall(function() owner = self:get():GetOwner() end)
            return owner and copy_addr[util.addr(owner) or 0]
        end
        local function on_damage(self, DmgAmount, DmgType, DmgCauser)
            if role ~= "guest" or killing then return end
            local id = copy_id(self)
            if not id then return end
            if replaying then
                pcall(function() DmgAmount:set(0) end)
                local body = body_type()
                if body then pcall(function() DmgType:set(body) end) end
                return
            end
            local boss = copies[id] and copies[id].fam == "boss"
            if not boss then
                local causer = util.obj(DmgCauser)
                if causer and zombies.is_copy(causer) then pcall(function() DmgAmount:set(0) end); return end
            end
            local amt = 0
            pcall(function() amt = DmgAmount:get() end)
            local tp = not boss and path_of(util.obj(DmgType)) or "-"
            pcall(function() DmgAmount:set(0) end)
            local body = body_type()
            if body then pcall(function() DmgType:set(body) end) end
            if amt > 0 then hits:send(string.format("D %d %.3f 0 %s", id, amt, tp)) end
        end
        local function on_fire_damage(self, DmgAmount)
            if role ~= "guest" then return end
            local id = copy_id(self)
            if not id then return end
            local amt = 0
            pcall(function() amt = DmgAmount:get() end)
            pcall(function() DmgAmount:set(0) end)
            if amt > 0 then hits:send(string.format("F %d %.3f", id, amt)) end
        end
        install_hit_hooks = function()
            install_rad()
            local a = util.ensure_hook(DC .. ":DamageTaken", on_damage)
            local b = util.ensure_hook(DC .. ":FireDamageTaken", on_fire_damage)
            if a and b and not hit_hooks_done then hit_hooks_done = true; log.info("zombies: hit forwarding hooked") end
        end
    end
    log.info("zombies: " .. role .. " side ready")
end

return zombies
