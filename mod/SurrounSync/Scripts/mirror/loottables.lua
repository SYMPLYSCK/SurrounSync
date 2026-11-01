-- The containers' loot tables, in memory before our Lua spawns anything with a container in it.
--
-- A container's BeginPlay (BP_LootContainer -> GameFunctionLibrary SetLootTable_Container_DA, decompiled 2026-10-28)
-- walks every asset in /Game/Inventory/Containers/LootTables and GetAsset's them one by one until it reaches its own
-- table. One that isn't loaded yet is loaded from disk right there - inside our SpawnActor, with the Lua lock held,
-- where the loading thread then waits on UE4SS's object-construction hook for that lock: the freeze of DBG-016
-- (zombies.lua has the same rule for the AI tables). So airdrop crates and event sites are only spawned from Lua once
-- every table is in memory (the game loads them itself as its own containers start), and then they're pinned in
-- the game instance's ReferencedObjects so the GC never drops them again.

local log = require("mirror.log")
local util = require("mirror.util")

local loottables = {}

local DIR = "/Game/Inventory/Containers/LootTables/"
local NAMES = { "AirdropMedical", "AirdropMilitary", "AirdropSupplies", "Ammunition", "AnimalMeat", "AnimalSmallMeat",
    "Axe", "Bunker", "CementMixer", "Clothing", "FirearmsDisplayCase", "GasPump", "Industrial", "Infestation", "Keycards",
    "Laboratory", "LaboratoryMilitary", "Medical", "Military", "MilitaryHighTier", "Nothing", "Police",
    "PrimaryInfestation", "Random", "Residential", "ResidentialFoodDrink", "Safe", "Shop", "ShopFoodDrink" }
local PATHS = {}
for _, n in ipairs(NAMES) do PATHS[#PATHS + 1] = DIR .. "DA_LootTable_" .. n .. ".DA_LootTable_" .. n end
-- (the folder's walk includes its Test subfolder too)
PATHS[#PATHS + 1] = DIR .. "Test/DA_LootTable_Test.DA_LootTable_Test"

local WANTED = {}
for _, p in ipairs(PATHS) do WANTED[p] = true end

local found = {}             -- path -> object
local pinned = false
local missing_n = #PATHS

-- true once every table is in memory (callers ask every few seconds at most; nothing to look up once pinned)
function loottables.ready()
    if pinned then return true end
    local missing = 0
    for _, p in ipairs(PATHS) do
        if not util.valid(found[p]) then found[p] = nil; missing = missing + 1 end
    end
    if missing > 0 then
        -- One walk of the tables' class (~9 ms, kit 2026-10-31: 46 objects, these and the AI ones) finds every loaded
        -- one. A StaticFindObject per table cost ~15 ms, found or not: "perf: prefabs took 139 ms" after a join.
        for _, o in ipairs(FindAllOf("ContainerItems_DataAsset_C") or {}) do
            local p
            pcall(function() p = o:GetFullName():match("^%S+ (.+)$") end)
            if p and WANTED[p] and not found[p] and util.valid(o) then found[p] = o; missing = missing - 1 end
        end
    end
    missing_n = missing
    if missing > 0 then return false end
    -- all here: kept for good (a GC'd table would be one more load later)
    local gi = FindFirstOf("SD_GameInstance_C")
    if not util.valid(gi) then return true end
    local added = 0
    for _, p in ipairs(PATHS) do
        if pcall(function() local arr = gi.ReferencedObjects; arr[arr:GetArrayNum() + 1] = found[p] end) then added = added + 1 end
    end
    pinned = true
    log.info(string.format("loottables: all %d container loot tables in memory - pinned %d", #PATHS, added))
    return true
end

function loottables.missing() return pinned and 0 or missing_n end

-- a load leaves the pinned ones in the game instance (it outlives worlds); the found objects are re-checked by IsValid
function loottables._reset() found, pinned, missing_n = {}, false, #PATHS end
loottables._paths = PATHS

return loottables
