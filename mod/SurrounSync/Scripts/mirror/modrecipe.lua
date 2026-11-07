-- Crafting recipes for SurrounSync's own items (the Hang Glider, the Double Drum Magazine): the game has no recipe for
-- them, so one is added to a row of DT_CraftingTableTypes in memory: a copy of a recipe with as many ingredients
-- (kit 2026-11-02: arr[n + 1] = arr[i] appends a deep copy, the source stays as it was, and a fresh row read shows
-- it), its output and ingredients set to the item's. A reloaded table loses it and gets it again on the next check.
-- The item is kept in the game instance's ReferencedObjects too, so the GC never drops it while a save may name it.
--
-- local r = modrecipe.new({ item = path, needs = { { path, count }, ... }, label = "Hang Glider", tag = "glideritem" })
-- r.tick(dt) every frame (does its work every CHECK_S); r.stats.added counts recipes put in.

local log = require("mirror.log")
local util = require("mirror.util")
local jig = require("mirror.jig")

local modrecipe = {}

local DT = "/Game/Inventory/Crafting/DT_CraftingTableTypes.DT_CraftingTableTypes"
local RECIPES = "ItemsToCraft_4_BD8109364B29C67733A91FB124A74183"
local OUT = "ItemToCraft_4_D2CE3CA74FD5DD913A8E86BB23414908"
local NEED = "ItemsNeeded_8_03B3B6B348EE04631090FFB588341C30"
local ID, CNT = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848", "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local CHECK_S = 10.0

modrecipe.DT, modrecipe.CHECK_S = DT, CHECK_S

local function bench_recipes(dt, bench)
    local arr
    dt:ForEachRow(function(name, row)
        if tostring(name) == bench then arr = row[RECIPES] end
    end)
    return arr
end

local function makes(e, path)
    local p
    pcall(function() p = jig.full_path(e[OUT][ID]) end)
    return p == path
end

function modrecipe.new(spec)
    local r = { stats = { added = 0 } }
    local bench = spec.bench or "CraftingWorkbench"
    local needs, tag = spec.needs, spec.tag
    local check_in, pinned_gi, said = 0, nil, {}

    local function once(key, msg)
        if said[key] then return end
        said[key] = true
        log.info(msg)
    end

    -- the bench's recipes hold the item's once; true when it is there (now or already)
    local function add_recipe(dt, item)
        local arr = bench_recipes(dt, bench)
        if not arr then once("norow", tag .. ": no " .. bench .. " row in the crafting table - no recipe"); return false end
        local n = arr:GetArrayNum()
        local template
        for i = 1, n do
            local e = arr[i]
            if makes(e, spec.item) then return true end
            local k = -1
            pcall(function() k = e[NEED]:GetArrayNum() end)
            if not template and k == #needs then template = i end
        end
        local mats = {}
        for i, need in ipairs(needs) do
            mats[i] = util.find(need[1])
            if not mats[i] then return false end   -- (not loaded yet: asked again on a later check)
        end
        if not template then once("notemplate", tag .. ": no " .. #needs .. "-ingredient recipe to copy - no recipe"); return false end
        arr[n + 1] = arr[template]
        if arr:GetArrayNum() ~= n + 1 then once("noappend", tag .. ": the recipe list did not grow - no recipe"); return false end
        local e = arr[n + 1]
        e[OUT][ID] = item
        e[OUT][CNT] = 1
        local slots = e[NEED]
        local made = {}
        for i, need in ipairs(needs) do
            slots[i][ID] = mats[i]
            slots[i][CNT] = need[2]
            made[i] = (need[1]:match("DA_(%w+)%.") or need[1]) .. " x" .. need[2]
        end
        r.stats.added = r.stats.added + 1
        log.info(string.format("%s: %s recipe added to the %s (%d recipes, made from %s)", tag, spec.label, bench, n + 1,
            table.concat(made, ", ")))
        return true
    end

    local function pin(item)
        -- (first, before the walk over every object: the game instance lives as long as the game)
        if util.valid(pinned_gi) then return end
        local gi = FindFirstOf("SD_GameInstance_C")
        if not util.valid(gi) then return end
        if pcall(function() local arr = gi.ReferencedObjects; arr[arr:GetArrayNum() + 1] = item end) then pinned_gi = gi end
    end

    function r.tick(dt)
        check_in = check_in - dt
        if check_in > 0 then return end
        check_in = CHECK_S
        local item = util.find(spec.item)
        if not item then return end   -- (its pak is not installed, or its ModActor has not loaded it yet)
        pin(item)
        -- (looked at again every check, ~16 recipes in one row: a table the game reloaded has lost it)
        local dt_obj = util.find(DT)
        if dt_obj then add_recipe(dt_obj, item) end
    end

    function r.reset() check_in, pinned_gi, said = 0, nil, {}; r.stats.added = 0 end

    return r
end

return modrecipe
