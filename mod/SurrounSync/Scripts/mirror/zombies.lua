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
-- n > 0 while a host's zombie hit is applied to me. Shared by every copy of this module (one per other player): with
-- 3 players the other copy's damage hook took that hit for a copy's own and set it to 0 (live 2026-10-30: all 80)
local copy_damage = require("mirror.peers").shared_table("copy_damage")
local dmg_stats = { sent = 0, applied = 0, dodged = 0, spared = 0 }
local install_hit_hooks = function() end
local hit_hooks_done = false

local LOOK_KEYS, look_of, health_of

local TRADER = "/Game/AI/Humans/Trader/BP_MasterTrader.BP_MasterTrader_C"
-- the damage of a guest's "my copy of it died here first" message: the host's zombie is finished with it
-- (module fields, not locals: this file's main chunk is at Lua's 200-local limit)
zombies.FINISH_DAMAGE = 100000
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
    local c = util.cached(fam_cls, path)
    if c then return c end
    if (fam_retry[path] or 0) > os.clock() then return nil end
    c = StaticFindObject(path)
    if util.valid(c) then fam_cls[path] = c; return c end
    fam_retry[path] = os.clock() + 10
    return nil
end
local applying_hit = false
-- (cached per class address in fam_cls: up to 7 IsA per call otherwise; forgotten with the world)
local function family_of(o)
    if not util.valid(o) then return nil end
    local ca
    pcall(function() ca = o:GetClass():GetAddress() end)
    local known = ca and fam_cls[ca]
    if known ~= nil then return known or nil end
    local all = true
    for _, f in ipairs(FAMILIES) do
        local c = fam_class(f[2])
        if c then
            local ok, r = pcall(function() return o:IsA(c) end)
            if ok and r == true then
                if ca then fam_cls[ca] = f[1] end
                return f[1]
            end
        else all = false end
    end
    if ca and all then fam_cls[ca] = false end
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

local ZLIST_FULL_EVERY = 120.0
local zlist, zlist_at, zlist_pruned = {}, -100, -100
local zlist_new, zlist_set, zlist_addr = {}, {}, {}
-- (one table: the main chunk is at Lua's 200-local limit - a new top-level local stops this file loading)
-- prune_every: s between prunes of ended/invalid entries
-- new_at: address of each queued new zombie: true, false once it ended before it was listed
-- ended: a listed zombie ended since the last prune: the next read prunes, whatever the time
-- remade[id]: a guest's copy the game removes again and again: { n, first, last, holds, hold_until } (see drive)
local zq = { prune_every = 0.0, new_at = {}, ended = false, remade = {} }
local notify_on = false
-- zlist_set[a]: true = listed, false = EndPlay'd (still in zlist until the next prune), nil = not listed
local function zlist_add(z)
    local a = util.addr(z)
    if not a or zlist_set[a] then return end
    -- an ended entry at this address is this object now (UE reuses the slot): just mark it live again
    if zlist_set[a] == nil then zlist[#zlist + 1] = z; zlist_addr[#zlist] = a end
    zlist_set[a] = true
end
-- An ended zombie leaves at the next read of the list, before it can be freed (a freed one's wrapper still passes
-- IsValid). The next read can come after a garbage collection: keepalive and ghost read the list before
-- zombies.tick in a frame, and a pause (the settings menu) stops our ticks but not the collector - an ended zombie
-- read after that crashed the host in UE4SS (DBG-20261030-010). So the read right after an end always prunes.
util.on_end(function(a)
    if zlist_set[a] then zlist_set[a], zq.ended = false, true end
    if zq.new_at[a] then zq.new_at[a] = false end
end)
local begin_fn = function(self)
    local o; pcall(function() o = self:get() end)
    local a = o and util.addr(o)
    if a then zlist_new[#zlist_new + 1] = { o, a }; zq.new_at[a] = true end
end
-- New zombies come from the master class's BeginPlay (game thread). NotifyOnNewObject was used before: it runs
-- on whichever thread constructs the object - the loading thread during a level load, where its Lua callback
-- waits for the Lua lock the game thread holds while our Lua waits for that load (DBG-20261027-006 H1).
local function watch_new_zombies()
    local was = notify_on
    notify_on = util.ensure_hook(MASTER .. ":ReceiveBeginPlay", begin_fn) == true
    if notify_on ~= was then
        log.info("zombies: watching for new zombies " .. (notify_on and "(BeginPlay - no periodic scan needed)" or "lost the BeginPlay hook - scanning instead"))
    end
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
local begin_in = 0.0
local function watch_begin(dt)
    begin_in = begin_in - dt
    if begin_in > 0 then return end
    begin_in = 2.0
    watch_new_zombies()
    for _, c in ipairs(BEGIN_CLASSES) do util.ensure_hook(c .. ":ReceiveBeginPlay", begin_fn) end
end
local function zombies_cached(t)
    if t - zlist_at >= (notify_on and ZLIST_FULL_EVERY or 2.0) then
        perf.run("z.list", function()
            zlist, zlist_set, zlist_new, zlist_addr, zq.new_at = {}, {}, {}, {}, {}
            for _, z in ipairs(all_zombies()) do zlist_add(z) end
        end)
        zlist_at, zlist_pruned, zq.ended = t, t, false
    else
        if #zlist_new > 0 then
            for _, e in ipairs(zlist_new) do
                -- one that ended while queued is not touched (it may be freed by now; util.addr would touch it)
                local z = e[1]
                if zq.new_at[e[2]] and util.valid(z) then
                    local cdo = false
                    pcall(function() cdo = z:GetFullName():find("Default__", 1, true) ~= nil end)
                    if not cdo then zlist_add(z) end
                end
            end
            zlist_new, zq.new_at = {}, {}
        end
        if zq.ended or t - zlist_pruned > zq.prune_every then
            zlist_pruned, zq.ended = t, false
            local j, n = 0, #zlist
            for i = 1, n do
                local z, a = zlist[i], zlist_addr[i]
                if zlist_set[a] and util.valid(z) then
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
    local o = util.cached(cache, p)
    if o then return o end
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
for _, n in ipairs(LOOT_TABLES) do LOOT_TABLES[n] = true end   -- (name set: which loaded tables count)
local loot_obj = {}
-- Never LoadAsset (or spawn something that loads assets) from our Lua: a synchronous load there
-- hangs the game. Copies wait until the game has loaded the zombie data itself.
-- A StaticFindObject of a table costs ~15 ms, found or not: the 16 in the first pass after a join were a 224-269 ms
-- frame (kit 2026-10-31, "perf: z.pass took 280 ms"). One walk of the tables' class (~8 ms, 46 objects) finds every
-- loaded one at once. While some are missing, a probe that found nothing waits 2 s doubling up to 8 s - a load is
-- seen at most 8 s late (live 2026-10-30 02:34, as a guest: 16/16 missing for 3.5 min, then all 16 there at once).
-- (loot_obj._at/_wait: this file has no room for more locals)
local function loot_ready()
    local t = os.clock()
    local missing = 0
    for _, n in ipairs(LOOT_TABLES) do
        if not util.valid(loot_obj[n]) then loot_obj[n] = nil; missing = missing + 1 end
    end
    if missing == 0 or t < (loot_obj._at or 0) then return missing == 0, missing end
    local hit = false
    for _, o in ipairs(FindAllOf("ContainerItems_DataAsset_C") or {}) do
        local n = (util.fname(o) or ""):match("^DA_LootTable_(.+)$")
        -- (the class holds the containers' tables too: only the AI folder's count)
        local ai = false
        if n and loot_obj[n] == nil and LOOT_TABLES[n] then
            pcall(function() ai = o:GetFullName():find("/Game/AI/AILootTables/", 1, true) ~= nil end)
        end
        if ai then loot_obj[n] = o; missing = missing - 1; hit = true end
    end
    if missing > 0 then
        loot_obj._wait = hit and 2.0 or math.min((loot_obj._wait or 1.0) * 2, 8.0)
        loot_obj._at = t + loot_obj._wait
    end
    return missing == 0, missing
end

-- For our own spawns where no ordinary AI is near (the forest giant): the game then has none of the tables loaded.
-- The engine's latent LoadAsset only queues an async load and returns, and the game loads them itself the way it
-- streams a level (kit 2026-11-02: 15 queued in 0.0 ms, none there yet, all 15 there 0.25 s later) - unlike
-- LoadAsset or GetAsset from Lua, which wait for the load (L-014). Nothing holds them: they go again at a garbage
-- collection once nothing uses them. Returns how many were asked for (0: all there, asked under 20 s ago, no world).
function zombies.load_loot_tables()
    local t = os.clock()
    if loot_ready() or t < (loot_obj._asked or -100) + 20 then return 0 end
    local K, w = util.cdo("/Script/Engine.Default__KismetSystemLibrary"), game.world()
    if not (K and w) then return 0 end
    loot_obj._asked = t
    local n = 0
    for i, name in ipairs(LOOT_TABLES) do
        if not loot_obj[name] then
            local path = "/Game/AI/AILootTables/DA_LootTable_" .. name .. ".DA_LootTable_" .. name
            if pcall(function()
                K:LoadAsset(w, K:Conv_SoftObjPathToSoftObjRef(K:MakeSoftObjectPath(path)), {},
                    { Linkage = 0, UUID = 771100 + i, ExecutionFunction = FName("None"), CallbackTarget = w })
            end) then n = n + 1 end
        end
    end
    loot_obj._at, loot_obj._wait = t + 0.5, 1.0   -- (looked for again soon, not after the up-to-8 s wait)
    log.info("zombies: asked the game to load " .. n .. " AI loot table(s)")
    return n
end

-- Our own zombie spawns must never make the game load anything (DBG-20261027-016): the zombie BP's BeginPlay
-- (Event_SetMeshAndMaterial) LoadAsset's a random Meshes_Soft / Materials_Soft entry of the class defaults. One
-- whose package is still streaming in makes the engine flush async loading inside our SpawnActor, and the loading
-- thread then waits in UE4SS's object-construction hook for the Lua lock this call holds: a permanent freeze.
-- So during our spawn every entry points at a look that is loaded already (the wanted one, else the class's own
-- template mesh). Returns the restore function, or nil when there is no loaded look (then don't spawn).
-- Only a pin that reads back counts (DBG-20261027-016 came back 2026-10-29 on a hand-back after a teleport):
-- for the master zombie's family a list that can't be read is a failure, never "empty", and every entry must
-- resolve to the loaded look afterwards (Conv_SoftObjectReferenceToObject never loads).
local MZ = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"
local BEGIN_EVENT = "/Game/Animations/Notifies/AnimNotify_BeginEvent.AnimNotify_BeginEvent_C:Received_NotifyBegin"
local function pin_soft_looks(cdo, mesh, mat)
    if not cdo then return function() end end
    local K = util.cdo("/Script/Engine.Default__KismetSystemLibrary")
    local mzc, must = find(MZ), false
    if mzc then pcall(function() must = cdo:IsA(mzc) == true end) end
    local saved = {}
    local function restore()
        for _, s in ipairs(saved) do pcall(function() for i, v in ipairs(s.old) do s.a[i] = v end end) end
    end
    local function why_not(name, why)
        local k = "pin " .. name .. " " .. tostring(util.fname(cdo))
        if not warned_class[k] then
            warned_class[k] = true
            log.warn("zombies: " .. name .. " of " .. tostring(util.fname(cdo)) .. " " .. why .. " - not spawned (it could load a look and freeze)")
        end
        return false
    end
    local function pin(name, obj)
        local a, n
        local read = pcall(function() a = cdo[name]; n = a:GetArrayNum() end)
        if not read or type(n) ~= "number" then return not must or why_not(name, "can't be read") end
        if n == 0 then return true end
        local sp
        -- (a soft pointer made by the engine: UE4SS crashes writing a plain object into a soft array)
        if util.valid(obj) then pcall(function() sp = K:Conv_ObjectToSoftObjectReference(obj) end) end
        if not sp then return false end
        local s = { a = a, old = {} }
        saved[#saved + 1] = s
        if not pcall(function() for i = 1, n do s.old[i] = a[i]; a[i] = sp end end) then return why_not(name, "couldn't be pinned") end
        local ok, held = pcall(function()
            for i = 1, n do
                if not util.same(K:Conv_SoftObjectReferenceToObject(a[i]), obj) then return false end
            end
            return true
        end)
        return (ok and held) or why_not(name, "didn't keep the pinned look")
    end
    local tmpl_mesh, tmpl_mat
    pcall(function() tmpl_mesh = cdo.Mesh:GetSkinnedAsset() end)
    pcall(function() tmpl_mat = cdo.Mesh:GetMaterial(0) end)
    if pin("Meshes_Soft", mesh or tmpl_mesh) and pin("Materials_Soft", mat or tmpl_mat) then return restore end
    restore()
    return nil
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

-- Zombie archetypes: BP_MasterZombie rolls one in SelectArchetype 1.0-1.25 s after BeginPlay, so each game
-- rolls its own. The host sends its archetype, hidden bones and whether the eyes glow (EyesColour's dynamic
-- material); copies match. Since game build 26467602 a crawler is no class of its own (BP_Zombie_Crawler is
-- gone): SelectArchetype's Archetype_Crawler gives any zombie the crawl blend space, a 40 cm capsule, missing
-- legs, and sometimes ToughenedCrawler inside it. Crawler is the last number: the numbers are on the wire.
-- (MZ: the master zombie class, above pin_soft_looks)
local ARCH = { "Sprinter", "UltraRadiated", "Acidic", "Screamer", "Grenadier", "ToughenedCrawler", "Crawler" }
local ARCH_CHANCES = { "SprinterArchetypeChance", "UltraRadiatedArchetypeChance", "AcidicArchetypeChance",
    "ScreamerArchetypeChance", "GrenadierArchetypeChance", "CrawlerArchetypeChance" }
local BONES = { "Jaw", "lowerarm_r", "lowerarm_l", "calf_l", "Foot_R", "calf_r", "Foot_L" }
local BIT = { 1, 2, 4, 8, 16, 32, 64 }
local bone_fnames = {}
local arch_seen, arch_seen_n = {}, 0
-- .ready[i] = when this game itself last ran archetype i (its mesh/effects are loaded then); .calling = our
-- own call is running. Calling an Archetype_ function from Lua loads what it needs synchronously when it
-- isn't loaded yet - a guest froze in "z.look.arch" right after its first copies (report 20261024-203718).
local arch_hooks = { ready = {}, calling = false, moon = { seen = {}, n = 0 } }
local ARCH_READY_S = 120
for i, a in ipairs(ARCH) do
    arch_hooks[i] = function(self)
        if not arch_hooks.calling then arch_hooks.ready[i] = os.clock() end
        local n
        pcall(function() n = util.fname(self:get()) end)
        if not n then return end
        -- (Archetype_Crawler calls ToughenedCrawler: the crawler is what the copy has to run)
        if a == "ToughenedCrawler" and ARCH[arch_seen[n] or 0] == "Crawler" then return end
        if arch_seen_n > 4000 then arch_seen, arch_seen_n = {}, 0 end
        if not arch_seen[n] then arch_seen_n = arch_seen_n + 1 end
        arch_seen[n] = i
    end
end
-- Blood moon: zombies alive when it rises get red eyes (+ speed); later ones don't. moon_seen[name] = had it.
arch_hooks.moon.hook = function(self, start)
    local n, on
    pcall(function() n = util.fname(self:get()); on = start:get() == true end)
    if not n then return end
    if arch_hooks.moon.n > 4000 then arch_hooks.moon.seen, arch_hooks.moon.n = {}, 0 end
    if arch_hooks.moon.seen[n] == nil then arch_hooks.moon.n = arch_hooks.moon.n + 1 end
    arch_hooks.moon.seen[n] = on
end
local function hook_archetypes()
    for i, a in ipairs(ARCH) do util.ensure_hook(MZ .. ":Archetype_" .. a, arch_hooks[i]) end
    util.ensure_hook(MZ .. ":Event_BloodMoon", arch_hooks.moon.hook)
    util.ensure_hook(BEGIN_EVENT, function(self, mc) return arch_hooks.notify(self, mc) end)
end
-- Archetype_Crawler loads nothing (the blend space and Toughened's meshes are the class's own references):
-- a copy runs it whether or not this game rolled a crawler lately. -> when this game is known to have it loaded
local function arch_ready(i)
    if ARCH[i] == "Crawler" then return os.clock() end
    return arch_hooks.ready[i]
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
        elseif z.CapsuleComponent:GetUnscaledCapsuleHalfHeight() < 60 then a = 7 end   -- (Archetype_Crawler: 40 cm)
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

-- Engine calls that wait for an animation task (a zombie's death - a copy's Death(), a hit that kills - a mesh swap
-- or archetype, K2_DestroyActor) run only once animation is on the game thread (animgate.lua): a guest froze inside a
-- copy's Death() and, 3 s after dying, while the copies the host no longer sent were removed (reports 2026-10-30
-- 15:36 and 16:11). Until then a death waits in zg.dying, a removed copy is hidden in zg.doomed, a hit that kills
-- waits in zg.hits / zg.dmg / zg.host_hits; the gate opens again zg.linger s after the last need.
-- (one table: the file is at Lua's 200-locals limit; wall clock, not `now`: zombies.tick can pause while the hold
-- must still end; the key names this copy in the log)
local zg = { gate = require("mirror.animgate"), linger = 1.0, need = -100, doomed = {}, dying = {}, hits = {}, dmg = {},
             host_hits = {} }
zg.key = "zombies" .. tostring(zg):gsub("^table: ", " ")
function zg.ready()
    zg.need = os.clock()
    local ok = zg.gate.ready()
    if ok and not zg.gate.held(zg.key) then return true end   -- (the gate is open, or someone else holds it)
    zg.gate.hold(zg.key)   -- (renewed while in use: a hold not renewed lapses)
    return ok
end

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
    -- (a hit that kills runs the zombie's death inside our call: only with animation on the game thread)
    local hn = health_of(z, fam)
    if (not hn or (tonumber(amt) or 0) >= hn) and not zg.ready() then zg.host_hits[#zg.host_hits + 1] = payload; return end
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
    -- (100000: not a hit but the guest's copy that died there first, finished here - read as a trainer hit 2026-10-30)
    local finish = tonumber(amt) == zombies.FINISH_DAMAGE
    log.every("zguesthit", 1.0, string.format("zombies: guest %s zombie %s%s%s%s - health %s -> %s, IsDead? %s",
        finish and "finished" or "hit", id, finish and " (its copy died there first)" or string.format(" for %.1f", tonumber(amt) or 0),
        kind == "F" and " (fire)" or "", tname, h0, h1, dead))
    if dead == "true" and cfg.diagnostics then watch_dead = { z = z, id = id, t = 1.0 } end
end

local statics = {}
local STATICS_EVERY = 3.0

local guest_center = function() return ghost.location() end
-- P8 load split (mirror/split.lua): while split the guest's game runs the AI around the guest, so the
-- host sends no zombies; near_ai = how close the nearest host AI (alive or dead) was to the guest.
local p8 = { on = false, near = { d = math.huge, at = -100 }, stopped = {}, drain = {}, fighting = false }
-- p8.stopped: guest, addr -> spawner this mod stopped (only these are handed back on a split)
-- p8.drain: guest, addr -> { till, dead } own AI kept for a while after a merge (no pop mid-fight)
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
    if p8.on then return end
    send_in = send_in - dt
    if send_in > 0 then return end
    send_in = 1.0 / cfg.zombies.send_hz
    local gl = guest_center()
    if not gl then
        -- no guest (left, or its ghost is gone): the zombies sent to it are despawned around its old spot soon; the
        -- ids only get pruned below, so drop them now - a reader of by_id (corpses scan) touched freed zombies 7 s
        -- after a guest left (host crash 2026-10-27 17:07, AV in UE4SS)
        if next(by_id) then ids, by_id, statics, p8.bound = {}, {}, {}, {} end
        return
    end

    local dict, dict_n, lines = {}, 0, {}
    local function idx(p)
        if not p then return 0 end
        local i = dict[p]
        if not i then dict_n = dict_n + 1; i = dict_n; dict[p] = i end
        return i
    end
    local alive = {}
    local radius = cfg.zombies.radius * zombies.perf_share()
    local nearest = math.huge
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
                if d < nearest then nearest = d end
                local a = znames[z]
                if not a then
                    pcall(function() a = util.fname(z) end)
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
                    else
                        st.arch, st.bones, st.eyes = arch_of(z, a), bones_of(z), eyes_of(z)
                        if st.eyes == 1 and arch_hooks.moon.seen[a] then st.eyes = 2 end
                    end
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
                    local beh, h, gun = -1, nil, nil
                    if cs then beh, h = cs.beh, cs.h
                    else
                        if st.fam == "human" then
                            pcall(function() beh = smart_ai(z)["AI Current Behaviour"] or -1 end)
                            -- the weapon in its hand (its own actor, made by the AI's start-up a copy never runs)
                            local held
                            pcall(function() held = smart_ai(z)["Holdable Actor"] end)
                            gun = util.class_path(held)
                        end
                        h = health_of(z, st.fam)
                    end
                    lines[#lines + 1] = string.format("L %d %s %.1f %d %d", id, table.concat(parts, " "), h or -1, beh, idx(gun))
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
    p8.near.d, p8.near.at = nearest, now
    for a, id in pairs(ids) do
        local held = p8.bound[a] and now < p8.bound[a] and util.valid(by_id[id])
        if not alive[a] and not held then
            ids[a] = nil; by_id[id] = nil; statics[id] = nil; p8.bound[a] = nil
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
local secondary = false
local active_at = 0.0
local stats = { spawned = 0, removed_native = 0, spawners = 0, swings_cut = 0 }
local loot_ok = false
local loot_wait_logged = 0
local spawn_budget = 0
local spawned_class = {}

-- 4 players: every copy of this module (one per other player, peers.lua) keeps its own copies; a copy made
-- by any of them is a copy here too (never swept as "own AI", never a damage source)
local ANY_COPIES = require("mirror.peers").shared_table("zombie_copies")
ANY_COPIES[zombies] = copy_addr
-- a guest's copy of the host's zombie <id> (nil when there is none right now)
function zombies.copy_actor(id)
    local c = copies[id]
    return c and util.valid(c.z) and c.z or nil
end

function zombies.is_copy(obj)
    local a = util.addr(obj) or 0
    if copy_addr[a] ~= nil then return true end
    for _, t in pairs(ANY_COPIES) do if t[a] ~= nil then return true end end
    return false
end

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
end

-- A copy's own swing must not hit anyone here: the host's zombie does the hitting and sends it. The attack
-- montages' AnimNotify_BeginEvent starts a looping timer by name on whatever plays them (AttackTrace, BiteTrace,
-- LeftArmTrace, RightArmTrace), and its hit runs Event_OnHit. Copies play the host's montages. Up to game build
-- 26303910 the traces skipped every class in the zombie's ClassesToIgnore, where the player class went; since
-- 26467602 that list is gone and they skip only actors tagged Zombie (kit 2026-11-07: a copy's RightArmTrace
-- ran its Event_OnHit on the guest). The hook runs after the notify set the timer, so the copy's is cleared
-- before it first fires.
arch_hooks.notify = function(self, mc)
    local m, n, owner, ev
    pcall(function() m = mc:get(); n = self:get() end)
    if not (util.valid(m) and util.valid(n)) then return end
    pcall(function() owner = m:GetOwner() end)
    if not (util.valid(owner) and zombies.is_copy(owner)) then return end
    pcall(function() ev = n.EventName:ToString() end)
    if type(ev) ~= "string" or not ev:find("Trace$") then return end
    pcall(function() util.cdo("/Script/Engine.Default__KismetSystemLibrary"):K2_ClearTimer(owner, ev) end)
    stats.swings_cut = stats.swings_cut + 1
    if stats.swings_cut <= 3 then log.info("zombies: a copy's " .. ev .. " stopped (the host's zombie hits)") end
end

-- (zg: the animation gate's state and zg.ready, defined above apply_hit)
function zg.destroy_actor(z)
    copy_addr[util.addr(z) or 0] = nil
    pcall(function() z:K2_DestroyActor() end)
end

-- any zombie of ours (a copy or one this game runs) or its weapon: destroyed now if safe, else hidden until zg.tick
function zg.kill(z)
    if zg.ready() then zg.destroy_actor(z); return end
    pcall(function() z:SetActorHiddenInGame(true) end)
    pcall(function() z:SetActorEnableCollision(false) end)
    zg.doomed[#zg.doomed + 1] = z
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
        if util.valid(h) then zg.kill(h) end
    end
end

-- A human copy holds what the host's holds: the game's own Equip Holdable spawns the weapon and puts it in the
-- hand socket (BP_SmartAIComponent, decompiled - the start-up that arms a raider needs its AI controller, which a
-- copy doesn't get). Only a class loaded here: loading one from Lua can stall the game (L-014). "-": empty hands.
function zombies.arm_copy(c, path)
    c.weapon = path
    local ai = smart_ai(c.z)
    if not ai then return end
    local cur
    pcall(function() cur = ai["Holdable Actor"] end)
    if util.valid(cur) and util.class_path(cur) == path then return end
    destroy_holdables(c.z)
    pcall(function() ai["Attached Holdables"]:Empty() end)
    pcall(function() ai["Holdable Actor"] = nil end)
    if path == "-" then return end
    local cls = util.find(path)
    if not util.valid(cls) then
        log.every("zombies.gun." .. path, 120, "zombies: a human copy's weapon " .. path:match("([%w_]+)$") .. " isn't loaded here - shown empty-handed")
        return
    end
    local ok, err = pcall(function() ai["Equip Holdable"](ai, cls) end)
    stats.armed = (stats.armed or 0) + (ok and 1 or 0)
    if not ok then log.every("zombies.arm", 60, "zombies: arming a human copy failed: " .. tostring(err)) end
end

local function destroy_copy(id, why)
    local c = copies[id]
    if not c then return end
    if util.valid(c.z) then
        destroyed[util.addr(c.z) or 0] = now
        destroy_holdables(c.z)
        zg.kill(c.z)
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
    local unpin = pin_soft_looks(cdo, mesh, mat)
    local ok = unpin and pcall(function()
        z = w:SpawnActor(cls, { X = e.loc.X, Y = e.loc.Y, Z = e.loc.Z + 10 }, { Pitch = 0, Yaw = e.yaw, Roll = 0 })
    end)
    if unpin then unpin() elseif not warned_class["pin " .. e.cls] then
        warned_class["pin " .. e.cls] = true
        log.warn("zombies: no loaded look for " .. tostring(e.cls) .. " - not spawned (a spawn would load one and could freeze)")
    end
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
-- the sweep's state (one table: this file is at Lua's 200-locals limit); volumes = spawn volumes stopped here
-- (BUDGET: a slice also ends after this many seconds - 150 spawners stopped in one frame took 161 ms, live 2026-10-30)
local sweep = { q = nil, SLICE = 150, DESTROYS = 4, BUDGET = 0.004, volumes = {} }
local native_in = 0.0

function p8.body_loc(z)
    local l
    pcall(function() l = z:K2_GetActorLocation() end)
    if l and math.abs(l.X) < 1 and math.abs(l.Y) < 1 and math.abs(l.Z) < 1 then
        l = nil
        pcall(function() l = z.Mesh:K2_GetComponentLocation() end)
    end
    return l
end

function p8.my_location()
    local l
    pcall(function() l = game.player():K2_GetActorLocation() end)
    return l
end

-- An own zombie still kept after a merge: until its time is up, the host comes near it, or (alive) it is
-- far from me.
function p8.drained(z, a)
    local k = p8.drain[a]
    if not k then return false end
    local sp = cfg.zombies.split
    local l, me, host = p8.body_loc(z), p8.my_location(), ghost.location()
    local keep = l ~= nil and now < k.till
        and not (host and util.dist(host, l) < sp.host_near)
        and not (not k.dead and me and util.dist(me, l) > 2 * sp.drain_radius)
    if not keep and l ~= nil and p8.rendered(z) then return true end   -- (until I look away)
    if not keep then p8.drain[a] = nil end
    return keep
end

-- The sweep's work goes in a queue that runs a slice per frame: walking all ~1100 spawners (and destroying a
-- batch of own zombies) in one frame was a 110 ms hitch every 2 s for the first ~15 s after joining. Each
-- object is still checked when its turn comes (valid, not a copy, not drained); a split stops the queue.
function sweep.step()
    local q = sweep.q
    if not q then return end
    if p8.on then sweep.q = nil; return end
    local budget, destroys, t0 = sweep.SLICE, 0, os.clock()
    while budget > 0 and destroys < sweep.DESTROYS and q.i < #q.items and (budget == sweep.SLICE or os.clock() - t0 < sweep.BUDGET) do
        q.i = q.i + 1
        budget = budget - 1
        local it = q.items[q.i]
        local o = it.o
        -- (queued some frames ago: still that object - a freed one's address can come back as another)
        if not (util.valid(o) and util.addr(o) == it.a and (not it.c or util.class_name(o) == it.c)) then
            -- gone since: nothing to do
        elseif it.k == "s" then
            if util.valid(o) then
                local stopped = false
                pcall(function() stopped = o.IsSpawningStopped == true end)
                if not stopped then
                    pcall(function() o:SetIsSpawningStopped(true) end); q.n_sp = q.n_sp + 1
                    p8.stopped[util.addr(o) or 0] = o
                end
            end
        elseif it.k == "v" then
            local a = util.addr(o) or 0
            if util.valid(o) and not sweep.volumes[a] then
                sweep.volumes[a] = o
                pcall(function() local f = o["Stop Spawning"]; f(o) end)
                q.n_sp = q.n_sp + 1
            end
        else
            local a = util.addr(o) or 0
            -- (one on my screen stays until I look away: the next pass gets it - nothing vanishes in front of me)
            if util.valid(o) and not zombies.is_copy(o) and not (destroyed[a] and now - destroyed[a] < 120) and not p8.drained(o, a)
                    and not p8.rendered(o) then
                if not zg.ready() then q.i = q.i - 1; return end   -- (destroying it waits for its animation task)
                destroyed[a] = now
                pcall(function()
                    local c = o.Controller
                    destroy_holdables(o)
                    o:K2_DestroyActor()
                    if util.valid(c) then c:K2_DestroyActor() end
                end)
                q.n_z = q.n_z + 1
                destroys = destroys + 1
            end
        end
    end
    if q.i < #q.items then return end
    sweep.q = nil
    if q.n_sp > 0 or q.n_z > 0 then
        stats.spawners = stats.spawners + q.n_sp
        stats.removed_native = stats.removed_native + q.n_z
        log.info(string.format("zombies: stopped %d spawner(s), removed %d own zombie(s)", q.n_sp, q.n_z))
    end
end

local function suppress_natives()
    for a, t in pairs(destroyed) do if now - t > 120 then destroyed[a] = nil end end
    -- (the last sweep still running: let it finish first)
    if sweep.q then return end
    local q = { items = {}, i = 0, n_sp = 0, n_z = 0 }
    -- (zombies come and go: their class is checked again too; spawners stay with the level, a reset drops the queue)
    local function add(k, o)
        local a = util.addr(o)
        if a then q.items[#q.items + 1] = { k = k, o = o, a = a, c = k == "z" and util.class_name(o) or nil } end
    end
    spawner_in = spawner_in - 2.0
    local spawners_scanned = spawner_in <= 0
    if spawners_scanned then
        spawner_in = 10.0
        for _, cls in ipairs({ SPAWNER, "BP_AISpawner_Animals_C" }) do
            for _, s in ipairs(util.instances(cls, "/Game/AI/AISpawners/BP_AISpawner_Master.BP_AISpawner_Master_C")) do
                add("s", s)
            end
        end
        for _, cls in ipairs({ "BP_AISpawningVolume_Prefab_C", "BP_AISpawningVolume_RandomChanceToSpawn_C" }) do
            for _, v in ipairs(util.instances(cls, "/Game/AI/Humans/" .. cls:gsub("_C$", "") .. "." .. cls)) do
                add("v", v)
            end
        end
    end
    native_in = native_in - 2.0
    local natives = native_in <= 0 and not spawners_scanned
    if natives then native_in = 2.0 end
    for _, z in ipairs(natives and zombies_cached(now) or {}) do if util.valid(z) then add("z", z) end end
    if #q.items > 0 then sweep.q = q; sweep.step() end
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
        if not util.same(cur, mesh) then
            if not zg.ready() then c.look_at = 0; return end   -- (the swap waits for its animation task: next snapshot)
            perf.run("z.look.mesh", function() pcall(function() z.Mesh:SetSkinnedAssetAndUpdate(mesh, false) end) end); fixed = true
        end
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
        pcall(function() mine = arch_of(z, util.fname(z)) end)
        local seen = arch_ready(x.arch)
        if mine ~= x.arch and seen and os.clock() - seen < ARCH_READY_S then
            if not zg.ready() then c.look_at = 0; return end   -- (it can swap meshes: next snapshot)
            local ok, err
            arch_hooks.calling = true
            perf.run("z.look.arch", function() ok, err = pcall(function() local f = z["Archetype_" .. ARCH[x.arch]]; f(z) end) end)
            arch_hooks.calling = false
            if not ok then log.warn("zombies: copy " .. id .. " archetype " .. ARCH[x.arch] .. ": " .. tostring(err))
            -- (a Crawler hides a random leg pair: the bones pass below may unhide again, to the host's pair)
            else c.arch_ran, c.bones_done = true, nil end
        elseif mine ~= x.arch then
            -- not run here: the archetype's looks only (zfx.lua)
            util.safe(zombies.fx.looks, "zombies.fx_looks", c, x.arch)
            arch_mismatch = arch_mismatch + 1
            if arch_mismatch <= 5 then log.info("zombies: copy " .. id .. " is a " .. ARCH[x.arch] .. " on the host - not loaded here, the copy keeps its own look") end
        end
        c.arch = x.arch
    elseif x and x.arch == 0 and not c.arch then
        c.arch = 0
        local mine
        pcall(function() mine = arch_of(z, util.fname(z)) end)
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
    local had = arch_hooks.moon.seen[util.fname(z) or ""]
    local red = x.eyes == 2
    if red ~= (had == true) and (red or had ~= nil) then
        perf.run("z.look.moon", function() pcall(function() z:Event_BloodMoon(red) end) end)
    end
    local glow = eyes_of(z)
    if x.eyes >= 1 and glow == 0 then
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
zombies._look = { arch_hooks = arch_hooks, moon_hook = arch_hooks.moon.hook, arch_of = function(z, n) return arch_of(z, n) end, bones_of = function(z) return bones_of(z) end,
                  sync = function(id, c, e, x) xlooks[id] = x; sync_look(id, c, e) end, pin = pin_soft_looks }
zombies._host = { tick = function(c, dt) cfg = cfg or c; now = now + dt; host_tick(dt) end }
zombies._test = { setup = function(c, r) cfg, role = c, r end,
    -- a whole sweep (all its frames); start/step: one frame's slice at a time
    sweep = function(dt) now = now + (dt or 0); suppress_natives(); while sweep.q do sweep.step() end end,
    start = function(dt) now = now + (dt or 0); suppress_natives() end,
    step = function() sweep.step(); return sweep.q ~= nil end,
    pending = function() return sweep.q and (#sweep.q.items - sweep.q.i) or 0 end,
    -- the animation gate: a guest's copy deaths (snapshot) and removals, then the frames that run them
    copy = function(id, z)
        copies[id] = { z = z, track = track.new(2.0), seen = now, born = now, fam = "zombie" }
        copy_addr[util.addr(z)] = id
    end,
    copies = function() return copies end,
    remove = function(id) destroy_copy(id, "test") end }

function zg.die_now(id, c)
    local ok, err = xp.without(function() c.z:Death(game.player(), false) end)
    util.safe(function()
        log.info("zombies: copy " .. id .. " died - its loot: " .. invdiag.summary(c.z.BP_JigMultiplayer.MainJigContainers))
    end, "zombies.loot_log")
    if not ok then
        log.warn("zombies: copy Death() failed, ragdolling instead: " .. tostring(err))
        ragdoll(c.z)
    end
end

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
        local g = tonumber(f[#LOOK_KEYS + 3] or "")
        lk.gun = g and (g > 0 and dict[g] or "-") or nil   -- (nil: an older host that doesn't say)
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
            -- a zombie of mine the host took over in a merge: it becomes this copy where it stands
            if not c and p8.pending[id] then c = p8.demote(id); copies[id] = c end
            if not c and not e.dead and not p8.handed[id] and not (zq.remade[id] and now < (zq.remade[id].hold_until or 0))
                    and (not spawn_gate or spawn_gate(id)) then
                local wait
                perf.run("z.recycle", function() c, wait = p8.recycle(id, e) end)
                -- (out of this frame's reuse time: next frame, rather than a spawn now)
                if not c and wait ~= "later" then perf.run("z.spawn", function() c = spawn_copy(id, e) end) end
                copies[id] = c
                if c and on_spawned then util.safe(on_spawned, "zombies.on_spawned", id, c.z) end
            end
            if c then
                c.seen, c.seen_snap = now, snap_count
                c.track:push(snap_t, { loc = e.loc, yaw = e.yaw, vel = e.vel, crouch = nil })
                if e.dead and not c.dead_at and c.fam and c.fam ~= "zombie" then
                    c.dead_at, c.die_at = now, now + DEATH_WAIT
                elseif e.dead and not c.dead_at then
                    c.dead_at = now
                    zg.dying[id] = c   -- (Death() waits for its animation task: zg.tick runs it)
                    zg.ready()
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
        if c.die_at and util.valid(c.z) and (c.guest_kill or now >= c.die_at) and zg.ready() then
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
            local gun = looks[id] and looks[id].gun
            if c.fam == "human" and gun and gun ~= c.weapon then util.safe(zombies.arm_copy, "zombies.arm_copy", c, gun) end
        end
        if not util.valid(c.z) then
            copies[id] = nil
        elseif snap_count - (c.seen_snap or snap_count) > cfg.zombies.despawn_after * cfg.zombies.send_hz then
            destroy_copy(id, "gone")
        elseif not c.dead_at and checks_due(c) and copy_died(c.z) then
            c.dead_at = now
            hits:send(string.format("D %d %.3f 0 %s", id, zombies.FINISH_DAMAGE, "/Game/Blueprints/Other/Damage/Damage_Body.Default__Damage_Body_C"))
            log.info("zombies: copy " .. id .. " died here before the host said so - kept as a corpse, the host's one finished")
        elseif not c.dead_at and c.check_now and copy_broken(c.z) then
            local a = util.addr(c.z) or 0
            copy_addr[a] = nil
            destroyed[a] = now
            copies[id] = nil
            stats.respawned = (stats.respawned or 0) + 1
            -- DBG-20261030-008: one copy the game removed right after every spawn was made 1829 times in 4 min.
            -- 3 removals in 10 s hold it back 15 s, then 30, 60 ... at most 5 min (5 quiet minutes start over).
            local r = zq.remade[id]
            if not r then
                -- (every id the game ever removed gets one: past 256, drop the quiet ones - same as their start over)
                zq.remade_n = (zq.remade_n or 0) + 1
                if zq.remade_n > 256 then
                    local n = 0
                    for k, v in pairs(zq.remade) do
                        if now - (v.last or 0) > 300 and now >= (v.hold_until or 0) then zq.remade[k] = nil else n = n + 1 end
                    end
                    zq.remade_n = n + 1
                end
                r = { n = 0, first = now, holds = 0 }
                zq.remade[id] = r
            end
            if now - (r.last or now) > 300 then r.holds = 0 end
            if now - r.first > 10 then r.n, r.first = 0, now end
            r.n, r.last = r.n + 1, now
            if r.n >= 3 then
                local secs = math.min(300, 15 * 2 ^ r.holds)
                r.n, r.holds, r.hold_until = 0, r.holds + 1, now + secs
                local p = c.track:newest()
                log.info(string.format("zombies: copy %d was removed by the game 3 times in 10 s (the host has it at %s) - not made again for %d s",
                    id, p and p.loc and string.format("%.0f %.0f %.0f", p.loc.X, p.loc.Y, p.loc.Z) or "?", secs))
            else
                log.info("zombies: copy " .. id .. " was removed by the game - making a new one")
            end
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
                                if not stats.anim_tick0 then
                                    stats.anim_tick0 = true
                                    local uro
                                    pcall(function() uro = m.bEnableUpdateRateOptimizations end)
                                    log.info("zombies: copies' own anim tick option is " .. tostring(c.anim_tick0)
                                        .. ", update rate optimizations " .. tostring(uro))
                                end
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

-- Guest, while split: is one of my own AI alive within quiet_radius of me (I'm fighting)? The host then
-- waits with the merge until the players are close (force_radius).
function p8.note_busy()
    local me, q = p8.my_location(), cfg.zombies.split.quiet_radius
    local found = false
    for _, z in ipairs(me and zombies_cached(now) or {}) do
        if not zombies.is_copy(z) then
            local l = p8.body_loc(z)
            if l and util.dist(me, l) < q and not dead_of(z) then found = true; break end
        end
    end
    p8.fighting = found
end

-- (a destroyed actor stays IsValid until the next garbage collection, ~1 min, and IsActorBeingDestroyed reads false
-- again once its destroy is done: the sweep's removals - destroyed[], kept 120 s - don't count. "own AI 54" 20 s after
-- a merge whose sweep had removed 49, live 2026-10-30)
function p8.count_own()
    local n = 0
    for _, z in ipairs(zombies_cached(now)) do
        local a = util.addr(z) or 0
        if not zombies.is_copy(z) and not destroyed[a] and util.valid(z) then n = n + 1 end
    end
    return n
end

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
    p8.recycle_budget, p8.recycle_spent = 4, 0
    local joined = session.in_world() and util.valid(game.player())
    if joined ~= active then
        active, active_at = joined, now
        if not active then destroy_all_copies("left the host's world")
        else log.info("zombies: in the host's world - showing the host's zombies") end
        p8.on, p8.fighting, p8.drain, p8.stopped = false, false, {}, {}
        p8.handed, p8.handing, p8.offer, p8.pending, p8.reenable, p8.brainless = {}, nil, nil, {}, nil, {}
        p8.held = {}
        spawner_in = 0.0
        sweep.volumes = {}
        native_in = 0.0
        pass_in = 0.0
        sweep.q = nil
        loot_ok, loot_wait_logged = false, -100
    end
    if not active then return end
    local busy = now - active_at < 20 or require("mirror.save_guard").busy()
    if not secondary then util.safe(loader.tick, "zombies.loader", dt, busy) end
    if sweep.q and not secondary then perf.run("z.pass", function() util.safe(sweep.step, "zombies.sweep") end) end
    pass_in = pass_in - dt
    if pass_in <= 0 and not secondary then perf.run("z.pass", function()
        pass_in = 2.0
        local ok, missing = loot_ready()
        loot_ok = ok
        if ok and p8.on then
            p8.note_busy()
        elseif ok then
            util.job("zombies.sweep", suppress_natives)
        elseif now - loot_wait_logged > 10 then
            loot_wait_logged = now
            log.info(string.format("zombies: waiting for the game to load its zombie data (%d/%d loot tables missing) - "
                .. "your own spawners stay on until then", missing, #LOOT_TABLES))
        end
        install_hit_hooks()
        hook_archetypes()
    end) end
    if not (p8.on or p8.follow or p8.keep) then perf.run("z.read", read_snapshot) end
    if p8.handing then perf.run("z.handover", p8.step_handover) end
    if p8.brainless[1] then perf.run("z.brainless", p8.brainless_tick) end
    if p8.reenable then p8.step_reenable(100) end
    if p8.offer then perf.run("z.offer", p8.offer_tick, dt) end
    if (next(p8.pending) or p8.pend_stats) and not p8.on then perf.run("z.pending", p8.pending_tick) end
    perf.run("z.drive", drive, dt)
end

-- P8 load split, switched by mirror/split.lua (the host decides; the guest follows and answers).
-- Host on: no zombie snapshot, its ids forgotten (a late guest hit finds nothing to apply).
-- Guest on: the host's copies go, the spawners this mod stopped run again and own AI isn't removed.
-- Guest off: own AI near me (or bodies) are kept a while (drain), the rest go on the next sweep.
function zombies.set_split(on)
    on = on == true
    if on == p8.on then return end
    p8.on = on
    if role == "host" then
        ids, by_id, statics = {}, {}, {}
        p8.near.d, p8.near.at = math.huge, -100
        return
    end
    if on then
        p8.handing = nil
        destroy_all_copies("load split - your game runs the AI around you (not handed over)")
        -- the spawners this mod stopped go back on 100 a frame (all ~1000 at once was one long frame)
        local list, vols = {}, {}
        for _, sp in pairs(p8.stopped) do list[#list + 1] = sp end
        -- (and the people's spawn volumes the sweep stopped: their "Restart Spawning" arms the radius check again)
        for _, v in pairs(sweep.volumes) do vols[#vols + 1] = v end
        p8.reenable = { list = list, vols = vols, i = 0 }
        p8.stopped, p8.drain, p8.fighting, sweep.volumes = {}, {}, false, {}
        log.info(string.format("zombies: split - %d spawner(s) and %d spawn volume(s) going back on, my own AI stays", #list, #vols))
        return
    end
    p8.reenable = nil
    local sp, me, kept = cfg.zombies.split, p8.my_location(), 0
    p8.drain = {}
    for _, z in ipairs(me and zombies_cached(now) or {}) do
        if not zombies.is_copy(z) and util.valid(z) then
            local l = p8.body_loc(z)
            local dead = dead_of(z) == true
            if l and util.dist(me, l) <= (dead and sp.corpse_radius or sp.drain_radius) then
                p8.drain[util.addr(z) or 0] = { till = now + (dead and sp.corpse_s or sp.drain_s), dead = dead }
                kept = kept + 1
            end
        end
    end
    p8.fighting = false
    spawner_in, native_in, pass_in = 0.0, 0.0, 0.0
    log.info(string.format("zombies: merged - the host runs the AI here again (%d of my own kept until they're done)", kept))
end

function zombies.is_split() return p8.on end

-- Split hand-over (guest): before the guest answers a split, each of the host's copies becomes this game's own AI
-- where it stands - the same actor with its look, pose and target area, no spawn and nothing removed: contain_copy
-- undone, then the class's own AI controller. A few per frame (time budget), dead copies simply stay as bodies.
-- Handed ids are never spawned again from a late snapshot, and the host's hits from them are ignored (the zombie
-- here hits on its own now).
p8.handed, p8.handing = {}, nil
function p8.release(z)
    local cdo
    pcall(function() cdo = z:GetClass():GetCDO() end)
    if not cdo then return false end
    pcall(function() z.AIOSubject:SetCanBeUpdatedBySubsystem(true) end)
    pcall(function()
        local cm, d = z.CharacterMovement, cdo.CharacterMovement
        cm.bRunPhysicsWithNoController = d.bRunPhysicsWithNoController
        cm.BrakingDecelerationWalking = d.BrakingDecelerationWalking
        cm.GroundFriction = d.GroundFriction
        cm.BrakingFrictionFactor = d.BrakingFrictionFactor
    end)
    pcall(function() z.DamageComponent["CanHeadshot1Shot?"] = cdo.DamageComponent["CanHeadshot1Shot?"] end)
    -- (contain_copy added the player class: a copy doesn't see me; this one hunts me now)
    pcall(function()
        local a, d = z.ClassesToIgnore, cdo.ClassesToIgnore
        a:Empty()
        for i = 1, d:GetArrayNum() do a[i] = d[i] end
    end)
    pcall(function() z:SpawnDefaultController() end)
    local ok = false
    pcall(function() ok = util.valid(z.Controller) end)
    return ok
end
function p8.promote(id)
    local c = copies[id]
    copies[id], xlooks[id], p8.handed[id] = nil, nil, true
    if not (c and util.valid(c.z)) then return "gone" end
    copy_addr[util.addr(c.z) or 0] = nil
    if p8.handing then p8.handing.mine[#p8.handing.mine + 1] = c.z end
    if c.dead_at or dead_of(c.z, c.fam) then return "body" end
    if p8.release(c.z) then return "ai" end
    p8.brainless[#p8.brainless + 1] = { z = c.z, tries = 0 }
    return "no brain"
end
-- a taken-over zombie the engine gave no controller would stand frozen: tried again a few frames, then removed
-- the moment it is off my screen
p8.brainless = {}
function p8.brainless_tick()
    local keep = {}
    for _, b in ipairs(p8.brainless) do
        if util.valid(b.z) and not dead_of(b.z) then
            b.tries = b.tries + 1
            local ok = false
            if b.tries <= 5 then pcall(function() b.z:SpawnDefaultController() end) end
            pcall(function() ok = util.valid(b.z.Controller) end)
            if ok then
                log.info("zombies: a taken-over zombie got its brain on try " .. b.tries)
            elseif b.tries > 5 and not p8.rendered(b.z) and zg.ready() then
                destroy_holdables(b.z)
                pcall(function() b.z:K2_DestroyActor() end)
                log.info("zombies: a taken-over zombie without a brain removed out of sight")
            else
                keep[#keep + 1] = b
            end
        end
    end
    p8.brainless = keep
end
-- the host called the split off mid hand-over: what is already mine stays until done, like after a merge
function zombies.cancel_handover()
    local h = p8.handing
    if not h then return end
    p8.handing = nil
    local sp, n = cfg.zombies.split, 0
    for _, z in ipairs(h.mine) do
        if util.valid(z) then
            local dead = dead_of(z) == true
            p8.drain[util.addr(z) or 0] = { till = now + (dead and sp.corpse_s or sp.drain_s), dead = dead }
            n = n + 1
        end
    end
    log.info(string.format("zombies: split hand-over called off - %d taken over so far stay until they're done", n))
end
function zombies.begin_handover()
    local ids_ = {}
    for id in pairs(copies) do ids_[#ids_ + 1] = id end
    p8.handing = { ids = ids_, i = 0, n = { ai = 0, body = 0, gone = 0, ["no brain"] = 0 }, t0 = os.clock(), worst = 0.0, mine = {} }
    log.info(string.format("zombies: split hand-over - taking over %d of the host's zombies where they stand", #ids_))
end
-- one frame's share (~3 ms); true once every copy is this game's own
function p8.step_handover()
    local h = p8.handing
    if not h then return true end
    local t0 = os.clock()
    repeat
        if h.i >= #h.ids then
            -- copies that arrived meanwhile go too
            local more = false
            for id in pairs(copies) do h.ids[#h.ids + 1] = id; more = true end
            if not more then break end
        end
        h.i = h.i + 1
        local t1 = os.clock()
        local r = p8.promote(h.ids[h.i])
        h.n[r] = (h.n[r] or 0) + 1
        h.worst = math.max(h.worst, os.clock() - t1)
    until os.clock() - t0 > 0.003
    if h.i < #h.ids or next(copies) then return false end
    log.info(string.format("zombies: split hand-over done in %.2f s - %d now mine, %d bodies, %d gone, %d without a brain (slowest %.1f ms)",
        os.clock() - h.t0, h.n.ai, h.n.body, h.n.gone, h.n["no brain"], h.worst * 1000))
    p8.handing = nil
    return true
end
-- A spawner (or spawn volume) a split or a Realm takeover hands back while I stand inside its SpawnRadius stays
-- off until I'm out of it: here it never spawned (stopped since I joined), so on it fills at once the area the
-- host had cleared (K3YBOARD32 2026-10-31: a takeover turned 1007 spawners and 111 volumes on, the zombies came
-- back). Out of range it goes on and spawns when I come back, like the game's own respawn. The game spawns while
-- the closest invoker is within SpawnRadius (decompiled BP_AISpawner_Master / BP_AISpawningVolume_Prefab).
p8.held, p8.held_in = {}, 0.0
p8.HOLD_MARGIN = 2000   -- (fields, not locals: this file is at Lua's 200-local limit)
function p8.hold(o, vol)
    local me, l, r = p8.my_location(), nil, nil
    pcall(function() l = util.vec(o:K2_GetActorLocation()) end)
    pcall(function() r = tonumber(o.SpawnRadius) end)
    if not (me and l and r) or util.dist(me, l) > r + p8.HOLD_MARGIN then return false end
    p8.held[#p8.held + 1] = { o = o, a = util.addr(o), vol = vol, l = l, r = r }
    return true
end
function p8.spawning_on(o, vol)
    if vol then pcall(function() local f = o["Restart Spawning"]; f(o) end)
    else pcall(function() o:SetIsSpawningStopped(false) end) end
end
-- every second, guest while split or host (after a takeover): a held one I'm out of range of goes on
function p8.held_tick(dt)
    if not p8.held[1] then return end
    p8.held_in = p8.held_in - dt
    if p8.held_in > 0 then return end
    p8.held_in = 1.0
    if role ~= "host" and not p8.on and not p8.keep then
        -- (a guest merged again, or a takeover called off: still off - the lists of what the mod stopped take them)
        for _, h in ipairs(p8.held) do
            if util.valid(h.o) and util.addr(h.o) == h.a then
                if h.vol then sweep.volumes[h.a or 0] = h.o else p8.stopped[h.a or 0] = h.o end
            end
        end
        p8.held = {}
        return
    end
    local me, kept, n = p8.my_location(), {}, 0
    for _, h in ipairs(p8.held) do
        if util.valid(h.o) and util.addr(h.o) == h.a then
            if me and util.dist(me, h.l) > h.r + p8.HOLD_MARGIN then p8.spawning_on(h.o, h.vol); n = n + 1
            else kept[#kept + 1] = h end
        end
    end
    p8.held = kept
    if n > 0 then log.info(string.format("zombies: %d held spawner(s) on again - I'm out of their range (%d still held)", n, #kept)) end
end
-- the spawners a split hands back, n a frame (the ones around me are held)
function p8.step_reenable(n)
    local r = p8.reenable
    for _ = 1, n do
        r.i = r.i + 1
        local sp = r.list[r.i]
        if not sp then
            for _, v in ipairs(r.vols or {}) do
                if util.valid(v) and not p8.hold(v, true) then p8.spawning_on(v, true) end
            end
            p8.reenable = nil
            if p8.held[1] then
                log.info(string.format("zombies: %d spawner(s) around me stay off until I'm out of their range "
                    .. "(the host's world had cleared them)", #p8.held))
            end
            return
        end
        if util.valid(sp) and not p8.hold(sp, false) then p8.spawning_on(sp, false) end
    end
end
zombies._test.handover = function() local f = 0; while p8.handing do p8.step_handover(); f = f + 1 end; return f end
zombies._test.reenable = function(n)
    local frames = 0
    while p8.reenable do p8.step_reenable(n or 100); frames = frames + 1 end
    return frames
end
zombies._test.held = function() p8.held_in = 0.0; p8.held_tick(1.0); return #p8.held end
function zombies.handing() return p8.handing ~= nil end
function zombies.handover_done() return p8.handing == nil end

-- Realm takeover in place (realmplay.promote): this game becomes the Realm's host without a load. The host's
-- copies become my own AI where they stand (the split hand-over), the old host's last snapshots make no new ones,
-- then the spawners this mod stopped go back on (set_split). split.lua keeps out of it meanwhile.
function zombies.begin_takeover()
    p8.keep = true
    if not p8.on and not p8.handing then zombies.begin_handover() end
end
function zombies.taking_over() return p8.keep == true end
-- true once every copy is mine and the stopped spawners run again
function zombies.takeover_ready()
    if p8.handing then return false end
    if not p8.on then zombies.set_split(true) end
    return p8.reenable == nil
end
-- after the switch to host (the same frame as phase1.init "host"), or when the takeover is called off: none of the
-- guest's split state is left for the host's code
function zombies.end_takeover()
    p8.keep, p8.on, p8.handing, p8.reenable, p8.offer = nil, false, nil, nil, nil
    p8.stopped, p8.drain, p8.fighting, p8.pending = {}, {}, false, {}
end

-- Merge hand-back (the way back). The host asks ("M"); the guest offers its own zombies near it in blob "p8h",
-- refreshed every 0.2 s: "A key cls mesh mat x y z yaw arch bones eyes health dead". The host spawns its own zombie
-- for each key where the guest's stands - out of the host's sight (the players are still far apart), one at a time,
-- and keeps it on the guest's latest spot - then merges with "H key id" lines. The guest turns each offered zombie
-- into the copy of that id when the first snapshot with the id arrives: the same actor, nothing pops on either side.
-- Other families and anything not taken stay until done (drain), as before.
p8.offer, p8.pending, p8.taken, p8.bound = nil, {}, nil, {}
-- on my screen just now (a zombie removed then would vanish in front of me)
function p8.rendered(z)
    local r = false
    pcall(function() r = z:WasRecentlyRendered(0.5) == true end)
    return r
end
function zombies.begin_handback(epoch)
    p8.offer = { epoch = epoch, by_key = {}, key_of = {}, n = 0, every = 0.0, t0 = os.clock() }
    log.info("zombies: merge hand-back - offering my zombies near me to the host")
end
function p8.offer_tick(dt)
    local o = p8.offer
    o.every = o.every - dt
    if o.every > 0 then return end
    o.every = 0.2
    local me = p8.my_location()
    if not me then return end
    -- only what I'd notice: on screen or within 40 m, nearest first, at most 24, inside the host's snapshot radius
    -- (the rest is removed out of sight - sweep), so the host spawns few and the merge is quick
    -- (the host sends copies within radius x MY performance setting - "gperf" here would be the host's, never set)
    local ms = require("mirror.mysettings")
    local r, fresh = cfg.zombies.radius * (ms.PERF_SHARE[ms.value("perf") or "full"] or 1.0) * 0.9, {}
    for _, z in ipairs(zombies_cached(now)) do
        if util.valid(z) and not zombies.is_copy(z) and not o.key_of[util.addr(z) or 0] and family_of(z) == "zombie" and not dead_of(z) then
            local l = p8.body_loc(z)
            local d = l and util.dist(me, l)
            if d and d <= r and (d <= 4000 or p8.rendered(z)) then fresh[#fresh + 1] = { z = z, d = d } end
        end
    end
    table.sort(fresh, function(x, y) return x.d < y.d end)
    for _, f in ipairs(fresh) do
        if o.n >= 24 then break end
        o.n = o.n + 1
        o.key_of[util.addr(f.z) or 0], o.by_key[o.n] = o.n, f.z
    end
    local out = { tostring(o.epoch) }
    for key, z in pairs(o.by_key) do
        if util.valid(z) then
            local dead = dead_of(z) == true
            local l = p8.body_loc(z)
            if l then
                local yaw, mesh, mat = 0, nil, nil
                pcall(function() yaw = z:K2_GetActorRotation().Yaw end)
                pcall(function() mesh = z.Mesh:GetSkinnedAsset() end)
                pcall(function() mat = material_asset(z.Mesh:GetMaterial(0)) end)
                out[#out + 1] = string.format("A %d %s %s %s %.1f %.1f %.1f %.1f %d %d %d %.1f %d", key,
                    path_of(z:GetClass()) or "-", path_of(mesh) or "-", path_of(mat) or "-", l.X, l.Y, l.Z, yaw,
                    arch_of(z, util.fname(z)) or 0, bones_of(z) or 0, eyes_of(z) or 0, health_of(z, "zombie") or -1, dead and 1 or 0)
            end
        end
    end
    link.put_blob("p8h", table.concat(out, "\n"))
end
-- the host merged: "H key id" -> that zombie waits for the id's first snapshot; the rest stay until done
function zombies.finish_handback(body)
    local o = p8.offer
    p8.offer = nil
    if not o then return 0 end
    local n = 0
    for key, id in (body or ""):gmatch("\nH (%d+) (%d+)") do
        local z = o.by_key[tonumber(key)]
        if util.valid(z) and not dead_of(z) then p8.pending[tonumber(id)] = { z = z, at = now }; n = n + 1 end
    end
    link.put_blob("p8h", "-")
    p8.pend_stats = n > 0 and { demoted = 0, expired = 0 } or nil
    log.info(string.format("zombies: merge hand-back - the host took %d of my %d zombies over (%.1f s)", n, o.n, os.clock() - o.t0))
    return n
end
function zombies.cancel_handback() if p8.offer then p8.offer = nil; link.put_blob("p8h", "-") end end
-- a taken zombie the host's snapshot never named within 10 s: it simply stays mine until done
function p8.pending_tick()
    local ps = p8.pend_stats
    for id, p in pairs(p8.pending) do
        if now - p.at > 10.0 then p8.pending[id] = nil; if ps then ps.expired = ps.expired + 1 end end
    end
    if ps and not next(p8.pending) then
        log.info(string.format("zombies: merge hand-back - %d of my zombies became the host's copies where they stand, %d never showed up in a snapshot (stay mine until done)",
            ps.demoted, ps.expired))
        p8.pend_stats = nil
    end
end
-- the first snapshot with a taken id: my zombie becomes its copy where it stands
function p8.demote(id)
    local p = p8.pending[id]
    p8.pending[id] = nil
    local z = p.z
    if not util.valid(z) or dead_of(z) then return nil end
    contain_copy(z)
    local a = util.addr(z) or 0
    copy_addr[a] = id
    p8.drain[a] = nil
    if p8.pend_stats then p8.pend_stats.demoted = p8.pend_stats.demoted + 1 end
    return { z = z, track = track.new(2.0), seen = now, born = now, fam = family_of(z), look_at = now }
end

-- Guest: a copy can be one of my own zombies instead of a new spawn - alive, same class, off my screen: contained
-- and moved to the host's zombie's spot out of sight (a SpawnActor is 4-40 ms a copy: the hitch after a merge or a
-- join, while the sweep was removing my own zombies anyway). It shows up where the host's zombie is; sync_look
-- settles its look like any copy's.
function p8.recycle(id, e)
    -- (a few a frame within ~4 ms; the rest go on the next frames' snapshots)
    if not e.cls then return nil end
    if p8.recycle_budget <= 0 or (p8.recycle_spent or 0) > 0.004 then return nil, "later" end
    local held = {}
    for _, p in pairs(p8.pending) do held[util.addr(p.z) or 0] = true end
    -- (only near me: far ones are what my game is despawning - one picked mid-despawn was gone a frame later)
    local me = p8.my_location()
    if not me then return nil end
    for _, z in ipairs(zombies_cached(now)) do
        local a = util.addr(z) or 0
        local l = util.valid(z) and p8.body_loc(z)
        if l and util.dist(me, l) <= cfg.zombies.radius and not copy_addr[a] and not held[a] and not p8.drain[a] and not destroyed[a]
                and not zombies.is_copy(z) and family_of(z) == "zombie" and not dead_of(z)
                and path_of(z:GetClass()) == e.cls and not p8.rendered(z) then
            -- (one the game already removed stays "valid" at 0,0,0 until garbage collection: never reused)
            local gone = copy_broken(z)
            if not gone then pcall(function() gone = z:IsActorBeingDestroyed() == true end) end
            if gone then destroyed[a] = now end
            if not gone then
                if not zg.ready() then return nil, "later" end   -- (its mesh swap waits for its animation task)
                p8.recycle_budget = p8.recycle_budget - 1
                local t0 = os.clock()
                contain_copy(z)
                local t1 = os.clock()
                pcall(function() z:K2_SetActorLocationAndRotation({ X = e.loc.X, Y = e.loc.Y, Z = e.loc.Z + 10 },
                    { Pitch = 0, Yaw = e.yaw, Roll = 0 }, false, {}, true) end)
                local t2 = os.clock()
                local mesh, mat = e.mesh and find(e.mesh), e.mat and find(e.mat)
                pcall(function() if mesh and not util.same(z.Mesh:GetSkinnedAsset(), mesh) then z.Mesh:SetSkinnedAssetAndUpdate(mesh, false) end end)
                pcall(function() if mat then z.Mesh:SetMaterial(0, mat) end end)
                local t3 = os.clock()
                copy_addr[a] = id
                stats.recycled = (stats.recycled or 0) + 1
                p8.recycle_spent = (p8.recycle_spent or 0) + (t3 - t0)
                if stats.recycled <= 6 then
                    log.info(string.format("zombies: reused my zombie as copy %d in %.1f ms (contain %.1f, move %.1f, look %.1f)",
                        id, (t3 - t0) * 1000, (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000))
                end
                return { z = z, track = track.new(2.0), seen = now, born = now, fam = "zombie" }
            end
        end
    end
    return nil
end
p8.recycle_budget = 0

-- Host side of the hand-back.
function zombies.begin_taking() p8.taken = { keys = {}, queue = {}, n = 0, failed = 0, worst = 0.0, t0 = os.clock(), next_at = 0.0 } end
function zombies.take_offer(body)
    local t = p8.taken
    if not t or not body then return end
    for k, cls, mesh, mat, x, y, z, yaw, arch, bones, eyes, h, dead in body:gmatch(
            "\nA (%d+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%d+) (%d+) (%d+) (%S+) (%d)") do
        local key = tonumber(k)
        local e = t.keys[key]
        local loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
        if not e then
            if dead ~= "1" then
                e = { cls = cls, mesh = mesh ~= "-" and mesh or nil, mat = mat ~= "-" and mat or nil, arch = tonumber(arch),
                      bones = tonumber(bones), eyes = tonumber(eyes), h = tonumber(h) }
                t.keys[key] = e
                t.queue[#t.queue + 1] = key
            end
        end
        if e then
            e.loc, e.yaw, e.dead = loc, tonumber(yaw), dead == "1"
            -- (spawned already: kept on the guest's zombie's spot until the merge, so the copy doesn't jump)
            if e.z and util.valid(e.z) and not e.dead then
                pcall(function() e.z:K2_SetActorLocation({ X = loc.X, Y = loc.Y, Z = loc.Z + 10 }, false, {}, true) end)
            elseif e.z and util.valid(e.z) and e.dead then
                zg.kill(e.z)
                e.z = nil
            end
        end
    end
end
function p8.spawn_original(e)
    -- (the same rule as copies: a zombie whose loot table isn't loaded would load it inside our SpawnActor)
    if not loot_ok then return nil end
    local cls = copy_class(e.cls)
    if not util.valid(cls) then return nil end
    if not warned_class["hand-back " .. e.cls] then
        warned_class["hand-back " .. e.cls] = true
        log.info("zombies: hand-back - first " .. tostring(e.cls):match("[^%.]+$") .. " spawning here")
    end
    local cdo
    pcall(function() cdo = cls:GetCDO() end)
    local mesh, mat = e.mesh and find(e.mesh), e.mat and find(e.mat)
    local old_meshes, old_mats = {}, {}
    if cdo then
        pcall(function() local a = cdo.Meshes; for i = 1, a:GetArrayNum() do old_meshes[i] = a[i]; if mesh then a[i] = mesh end end end)
        pcall(function() local a = cdo.Materials; for i = 1, a:GetArrayNum() do old_mats[i] = a[i]; if mat then a[i] = mat end end end)
    end
    local z
    local unpin = pin_soft_looks(cdo, mesh, mat)
    if unpin then
        pcall(function()
            z = game.world():SpawnActor(cls, { X = e.loc.X, Y = e.loc.Y, Z = e.loc.Z + 10 }, { Pitch = 0, Yaw = e.yaw, Roll = 0 })
        end)
    end
    local function restore()
        if unpin then unpin() end
        if cdo then
            pcall(function() local a = cdo.Meshes; for i, m in ipairs(old_meshes) do a[i] = m end end)
            pcall(function() local a = cdo.Materials; for i, m in ipairs(old_mats) do a[i] = m end end)
        end
    end
    if not util.valid(z) then restore(); return nil end
    -- the class's lists go back only after every BP call on the new zombie (none of them may re-roll a look
    -- unpinned), and always (an error here must not leave every later zombie of this class with one look)
    local ok, err = pcall(function()
        -- the guest's zombie's archetype, never a new roll
        for _, k in ipairs(ARCH_CHANCES) do pcall(function() z[k] = 0 end) end
        pcall(function() if mesh and not util.same(z.Mesh:GetSkinnedAsset(), mesh) then z.Mesh:SetSkinnedAssetAndUpdate(mesh, false) end end)
        pcall(function() if mat then z.Mesh:SetMaterial(0, mat) end end)
        local seen = e.arch > 0 and arch_ready(e.arch)
        local ran = false
        if seen and os.clock() - seen < ARCH_READY_S then
            arch_hooks.calling = true
            ran = pcall(function() local f = z["Archetype_" .. ARCH[e.arch]]; f(z) end)
            arch_hooks.calling = false
        end
        -- (a Crawler hides a random leg pair of its own: the other pair is shown again)
        for i = 1, #BONES do
            if (e.bones // BIT[i]) % 2 == 1 then pcall(function() z.Mesh:HideBoneByName(bone_fname(i), 0) end)
            elseif ran then pcall(function() z.Mesh:UnHideBoneByName(bone_fname(i)) end) end
        end
        if e.eyes == 2 then pcall(function() z:Event_BloodMoon(true) end) end
        if e.h and e.h > 0 then pcall(function() z.DamageComponent.CurrentHealth = e.h end) end
    end)
    restore()
    if not ok then error(err, 0) end
    return z
end
-- one of our own zombies of a loaded class, under the hand-back's no-load rules (DBG-20261027-016: a plain
-- SpawnActor of a boss froze the kit host 2026-11-01); nil when it can't be spawned safely. The loot tables are
-- checked here: loot_ok is only kept up to date in a guest's tick (a host's spawn_safe saw it false 2026-11-01).
-- A refusal returns nil plus why.
function zombies.spawn_safe(cls_path, loc, yaw)
    local ready, missing = loot_ready()
    if not ready then return nil, tostring(missing) .. " AI loot table(s) not loaded yet" end
    local saved = loot_ok
    loot_ok = true
    local ok, z = pcall(p8.spawn_original, { cls = cls_path, loc = loc, yaw = yaw or 0, arch = 0, bones = 0 })
    loot_ok = saved
    if not ok then error(z, 0) end
    if not z then return nil, "class not loaded, or no loaded look to pin" end
    return z
end
-- one spawn every 0.25 s at most (a spawn is 4-40 ms of engine work); true once every offered zombie has one
function p8.take_tick()
    local t = p8.taken
    if not t then return true end
    if #t.queue == 0 then return true end
    if os.clock() < t.next_at then return false end
    t.next_at = os.clock() + 0.25
    local key = table.remove(t.queue, 1)
    local e = t.keys[key]
    if e and not e.dead then
        local t0 = os.clock()
        local ok, z = pcall(p8.spawn_original, e)
        t.worst = math.max(t.worst, os.clock() - t0)
        if ok and z then e.z = z; t.n = t.n + 1 else t.failed = t.failed + 1 end
    end
    return #t.queue == 0
end
function zombies.taking_done() return p8.take_tick() end
-- after the host's merge (ids reset): ids for the spawned zombies, as "H key id" lines for the guest
function zombies.bind_taken()
    local t = p8.taken
    p8.taken = nil
    if not t then return "" end
    local out = {}
    for key, e in pairs(t.keys) do
        if e.z and util.valid(e.z) and not e.dead then
            local a = util.fname(e.z) or tostring(util.addr(e.z))
            znames[e.z] = a
            next_id = next_id + 1
            ids[a], by_id[next_id] = next_id, e.z
            p8.bound[a] = now + 10.0   -- (kept while outside the snapshot radius, so the guest's id still matches)
            out[#out + 1] = string.format("H %d %d", key, next_id)
        end
    end
    log.info(string.format("zombies: merge hand-back - spawned %d of the guest's zombies here, %d failed (slowest spawn %.0f ms, %.1f s)",
        t.n, t.failed, t.worst * 1000, os.clock() - t.t0))
    return table.concat(out, "\n")
end
function zombies.cancel_taking()
    local t = p8.taken
    p8.taken = nil
    if not t then return end
    for _, e in pairs(t.keys) do if e.z and util.valid(e.z) then zg.kill(e.z) end end
end

-- 4 players, group split (split.lua / group.lua): this guest follows another guest who runs the AI around both;
-- the host sends no zombies here, its copies go, own AI is still removed (the leader's copies come instead).
function zombies.set_follow(on)
    on = on == true
    if on == (p8.follow == true) then return end
    p8.follow = on
    if on and role ~= "host" then destroy_all_copies("your group's leader runs the AI here") end
end
function zombies.is_follow() return p8.follow == true end

-- A copy of this module for another player (group.lua): only runs while the group is on.
local gate = true
function zombies.set_gate(on)
    on = on == true
    if on == gate then return end
    gate = on
    if not on and role ~= "host" then destroy_all_copies("group split ended") end
    if not on and role == "host" then ids, by_id, statics = {}, {}, {} end
end
function zombies.guest_busy() return p8.fighting end
-- Host: distance from the guest to the nearest host AI the last snapshot found (math.huge = none in range), and its age.
function zombies.near_guest() return p8.near.d, now - p8.near.at end
-- Guest: AI this game runs itself (not copies).
function zombies.own_count() return p8.count_own() end

local selftest_in, selftest_copy = 0.0, nil
local function selftest_file() return require("mirror.localdir").get() .. "\\mirror_selftest_" .. role .. ".txt" end

local want_steamtest = false
function zombies.key_status() want_steamtest = true end   -- (also /status, chatcmd.lua)

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
    -- the command file is a dev tool: test installs only (was a file open every second on every player's game)
    if not cfg.devtest then return end
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
    pcall(function() a = util.fname(z) end)
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
-- archetype looks + death blasts on copies (a field: this file is at Lua's 200-locals limit)
zombies.fx = require("mirror.zfx")

-- Every frame: the deaths and removals that waited for the animation gate, then the gate opens again once
-- nothing here has needed it for zg.linger s.
function zg.tick()
    if (zg.doomed[1] or next(zg.dying) or zg.hits[1] or zg.dmg[1] or zg.host_hits[1]) and zg.ready() then
        local hits, dmg, host_hits = zg.hits, zg.dmg, zg.host_hits
        zg.hits, zg.dmg, zg.host_hits = {}, {}, {}
        for _, p in ipairs(host_hits) do util.safe(apply_hit, "zombies.apply_hit", p) end
        for _, p in ipairs(hits) do util.safe(apply_zhit, "zombies.apply_zhit", p) end
        for _, p in ipairs(dmg) do util.safe(apply_dmg, "zombies.apply_dmg", p) end
        local list = zg.doomed
        zg.doomed = {}
        for _, z in ipairs(list) do if util.valid(z) then zg.destroy_actor(z) end end
        for id, c in pairs(zg.dying) do
            zg.dying[id] = nil
            if copies[id] == c and util.valid(c.z) then zg.die_now(id, c) end
        end
    end
    if zg.gate.held(zg.key) and os.clock() - zg.need > zg.linger then zg.gate.release(zg.key) end
end

zombies._test.gate_tick = function(dt) now = now + dt; zg.tick() end
zombies._test.zlist_begin = begin_fn
zombies._test.drive = function(dt) now = now + dt; frame_dt = dt; drive(dt) end
zombies._test.remade_count = function() local n = 0; for _ in pairs(zq.remade) do n = n + 1 end; return n end
zombies._test.read = read_snapshot
zombies._test.zhit = function(p) return apply_zhit(p) end
zombies._test.dmg = function(p) return apply_dmg(p) end
zombies._test.loot_ready = function() return loot_ready() end
zombies.loot_ready = function() return loot_ready() end   -- (giant.lua: the AI loot tables are loaded)

function zombies.tick(dt)
    if not (cfg and cfg.zombies.enabled) then return end
    -- (also while paused: removals and deaths waiting for the gate still finish, its hold still ends)
    util.safe(zg.tick, "zombies.gate")
    if not gate then return end
    if role ~= "host" then util.safe(rad.watch, "zombies.watch_rad", dt) end
    now = now + dt
    util.safe(selftest_tick, "zombies.selftest", dt)
    util.safe(pin_loot, "zombies.pin_loot", dt)
    util.safe(xp.tick, "zombies.xp")
    util.safe(watch_begin, "zombies.watch_begin", dt)
    if role == "host" then perf.run("z.host", host_tick, dt) else guest_tick(dt) end
    util.safe(p8.held_tick, "zombies.held", dt)
    util.safe(zombies.fx.tick, "zombies.fx", dt)
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
    elseif c.fam == "boss" then pcall(function() c.z.DamageComponent.CurrentHealth = c.z.DamageComponent.CurrentHealth + amount + 1 end)
    else
        -- a hit that kills runs the copy's Death inside ApplyDamage, which waits for its animation task: only with
        -- animation on the game thread (zg) - the kit's host kills killed 15 copies this way; other hits at once
        local h = health_of(c.z, c.fam)
        if (not h or amount >= h) and not zg.ready() then zg.hits[#zg.hits + 1] = payload; return end
    end
    replaying = true
    local ok, err = xp.without(function()
        util.cdo("/Script/Engine.Default__GameplayStatics"):ApplyDamage(c.z, tonumber(amt) or 1, nil,
            util.valid(causer) and causer or nil, dtc)
    end)
    replaying = false
    zhit_stats.played = zhit_stats.played + 1
    if not ok then log.warn("zombies: replaying a host hit failed: " .. tostring(err))
    else log.every("zreplay", 1.0, string.format("zombies: host hit on zombie %s replayed on its copy (%s)", id, amt)) end
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
    if p8.handed[tonumber(id)] then return end   -- taken over in a split hand-over: it hits me on its own now
    if os.clock() < (require("mirror.peers").shared_table("arrival").safe_until or 0) then
        -- (just teleported next to the other player: teleport.lua)
        dmg_stats.spared = dmg_stats.spared + 1
        log.every("zombies.spared", 1.0, string.format("zombies: a hit for %.1f from zombie %s let off - just teleported here", amt, id))
        return
    end
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
    -- a hit that kills me runs my death inside ApplyDamage (ragdoll, death screen), which waits for my animation
    -- task: only with animation on the game thread (zg); other hits at once
    local hp
    pcall(function() hp = tonumber(p.MedicalComponent.Health) end)
    if (not hp or amt >= hp) and not zg.ready() then zg.dmg[#zg.dmg + 1] = payload; return end
    local dtc = (cls ~= "-") and find(cls) or nil
    copy_damage.n = (copy_damage.n or 0) + 1
    local ok, err = pcall(function()
        util.cdo("/Script/Engine.Default__GameplayStatics"):ApplyDamage(p, amt, nil, causer, dtc)
    end)
    copy_damage.n = copy_damage.n - 1
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
    return string.format("%d copies (%d dead; spawned %d, reused %d, replaced %d; off from host avg %.1f m, max %.1f m) own zombies removed %d, spawners stopped %d | hits taken %d, dodged %d, host hits replayed %d, speed from track %d",
        n, dead, stats.spawned, stats.recycled or 0, stats.respawned or 0, off_n > 0 and off_sum / off_n or 0, off_max, stats.removed_native, stats.spawners,
        dmg_stats.applied, dmg_stats.dodged, zhit_stats.played, stats.vel_from_track or 0)
end

local SAI = "/Game/SmartAI/Blueprints/AI/Components/BP_SmartAIComponent.BP_SmartAIComponent_C"
local function fx_id(comp_param)
    local comp, owner, id = util.obj(comp_param), nil, nil
    if not comp then return nil end
    pcall(function() owner = comp:GetOwner() end)
    if not util.valid(owner) then return nil end
    pcall(function() id = ids[util.fname(owner)] end)
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
    zq.new_at, zq.ended, zq.remade, zq.remade_n = {}, false, {}, 0
    copies, copy_addr, destroyed, sweep.volumes, xlooks = {}, {}, {}, {}, {}
    zg.doomed, zg.dying, zg.hits, zg.dmg, zg.host_hits = {}, {}, {}, {}, {}   -- (the old world's actors went with it)
    zg.gate.release(zg.key)
    sweep.q = nil
    ANY_COPIES[zombies] = copy_addr
    p8.on, p8.fighting, p8.drain, p8.stopped, p8.follow = false, false, {}, {}, false
    p8.handed, p8.handing, p8.offer, p8.pending, p8.reenable, p8.taken, p8.brainless, p8.bound = {}, nil, nil, {}, nil, nil, {}, {}
    arch_seen, arch_seen_n = {}, 0
    rad.comp, rad.seen, rad.retry = nil, nil, 0
    cache, missed, appeared, loot_obj, fam_cls, fam_retry = {}, {}, {}, {}, {}, {}
end

-- opts.secondary: a copy for another player (group.lua) - the main copy does the sweeps, spawners and loading
function zombies.init(c, r, s, opts)
    cfg, role, session = c, r, s
    -- (built again below for this role: wrapping the last start's grew by one layer per co-op start on a guest)
    install_host_hooks = function() end
    secondary = opts and opts.secondary or false
    zombies.fx.init(zombies, r)
    game.on_world_reset(forget_world)
    util.safe(watch_new_zombies, "zombies.watch")
    game.keybind("F12", { ModifierKey.CONTROL }, zombies.key_status)
    if not cfg.zombies.enabled then return end
    game.player_hook("ReceiveAnyDamage", function(self, Damage, DamageType, InstigatedBy, DamageCauser)
        local causer = util.obj(DamageCauser)
        local ai = (role == "host") and causer and ai_of(causer) or nil
        if role == "host" and ai and ghost.is(self:get()) then
            local amt, cls, id, l = 0, "-", -1, { X = 0, Y = 0, Z = 0 }
            pcall(function() amt = Damage:get() end)
            cls = util.class_path(util.obj(DamageType)) or "-"
            pcall(function() id = ids[util.fname(ai)] or -1 end)
            pcall(function() l = ai:K2_GetActorLocation() end)
            local fam = family_of(ai)
            local ranged = (fam == "human" or fam == "boss") and 1 or 0
            if amt > 0 then
                dmgs:send(string.format("%d %.3f %s %.1f %.1f %.1f %d", id, amt, cls, l.X, l.Y, l.Z, ranged))
                dmg_stats.sent = dmg_stats.sent + 1
            end
            return
        end
        if (copy_damage.n or 0) > 0 then return end
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
            log.every("zombies.blocked", 30, "zombies: blocked damage from a zombie copy (the host decides its hits)")
        end
    end)
    local function zero(...) for _, v in ipairs({ ... }) do pcall(function() v:set(0) end) end end
    if role == "host" then
        local DC = "/Game/Blueprints/Components/DamageComponent.DamageComponent_C"
        local function on_host_damage(self, DmgAmount, DmgType, DmgCauser)
            if role ~= "host" then return end
            local owner, causer
            pcall(function() owner = self:get():GetOwner() end)
            if not (owner and is_zombie(owner)) then return end
            local id
            pcall(function() id = ids[util.fname(owner)] end)
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
                log.every("zmyhit", 1.0, string.format("zombies: my hit on zombie %d (%.0f, %s) -> guest", id, amt, cls:match("([%w_]+)$") or cls))
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
                pcall(function() id = ids[util.fname(best)] or -1 end)
                pcall(function() l = best.Mesh:K2_GetComponentLocation() end)
            end
            return string.format("%d %.1f %.1f %.1f", id, l.X, l.Y, l.Z)
        end
        local function g(v) local r; pcall(function() r = v:get() end); return r end
        -- (sent to the ghost's player, whose own game applies it; the ghost here kept it as well - bleeding, infection
        -- and radiation on a character nobody plays - so its chances are set to 0 once sent, as a guest does for a copy)
        game.on_ready(function()
            util.hook(GFL .. ":ApplyMedicalEffect", function(self, Actor, Effects, CB, CHB, CBB, CI, Ctx)
                local who = zinfo(Actor, Ctx)
                if not who then return end
                local names = {}
                pcall(function() util.each(Effects:get(), function(_, e) names[#names + 1] = (e:get():ToString():gsub(" ", "_")) end) end)
                meds:send(string.format("M %s %.3f %.3f %.3f %.3f %s", who, g(CB) or 0, g(CHB) or 0, g(CBB) or 0, g(CI) or 0,
                    #names > 0 and table.concat(names, ",") or "-"))
                zero(CB, CHB, CBB, CI)
            end)
            util.hook(GFL .. ":ApplyRadiationDamage", function(self, Actor, Chance, Rad, Mask, Ctx)
                local who = zinfo(Actor, Ctx)
                if not who then return end
                meds:send(string.format("R %s %.3f %.3f %d", who, g(Chance) or 0, g(Rad) or 0, g(Mask) and 1 or 0))
                zero(Chance, Rad)
            end)
            util.hook(GFL .. ":ApplyBiteInfection", function(self, Actor, Chance, Crawler, Ctx)
                local who = zinfo(Actor, Ctx)
                if not who then return end
                meds:send(string.format("B %s %.3f %d", who, g(Chance) or 0, g(Crawler) and 1 or 0))
                zero(Chance)
            end)
        end)
    else
        local function from_copy(actor_param, ctx_param)
            local target, ctx = util.obj(actor_param), util.obj(ctx_param)
            if not (target and ctx and zombies.is_copy(ctx)) then return false end
            local p = game.player()
            return p ~= nil and util.addr(target) == util.addr(p)
        end
        -- (the host's character here: a copy that reaches it hurts nobody - the host's own zombie does that in theirs)
        local function on_ghost(actor_param)
            local target = util.obj(actor_param)
            return target ~= nil and ghost.is(target)
        end
        local function g(v) local r; pcall(function() r = v:get() end); return r end
        game.on_ready(function()
            util.hook(GFL .. ":ApplyMedicalEffect", function(self, Actor, Effects, CB, CHB, CBB, CI, Ctx)
                if from_copy(Actor, Ctx) then zero(CB, CHB, CBB, CI); log.info("zombies: blocked a copy's medical effect")
                elseif on_ghost(Actor) then zero(CB, CHB, CBB, CI) end
            end)
            util.hook(GFL .. ":ApplyRadiationDamage", function(self, Actor, Chance, Rad, Mask, Ctx)
                if from_copy(Actor, Ctx) then
                    local amount = g(Rad)
                    zero(Chance, Rad)
                    rad.take_back(amount)
                    log.info("zombies: blocked a copy's radiation")
                elseif on_ghost(Actor) then
                    zero(Chance, Rad)
                end
            end)
            util.hook(GFL .. ":ApplyBiteInfection", function(self, Actor, Chance, Crawler, Ctx)
                if from_copy(Actor, Ctx) then zero(Chance); log.info("zombies: blocked a copy's bite infection")
                elseif on_ghost(Actor) then zero(Chance) end
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
            pcall(function() id = ids[util.fname(z)] end)
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

-- GUEST PERFORMANCE (the guest's own setting, sent as a blob): the share of the copy range it wants.
-- (a module field, not a local: this file is at Lua's local-variable limit)
function zombies.perf_share()
    local b = link.get_blob("gperf")
    if b then zombies.gperf = b end
    return require("mirror.mysettings").PERF_SHARE[zombies.gperf or "full"] or 1.0
end

return zombies
