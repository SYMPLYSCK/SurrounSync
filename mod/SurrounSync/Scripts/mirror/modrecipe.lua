-- Crafting recipes for SurrounSync's own items (the Hang Glider, the Double Drum Magazine): the game has no recipe for
-- them, so one is added to a row of DT_CraftingTableTypes in memory: a copy of a recipe with as many ingredients
-- (kit 2026-11-02: arr[n + 1] = arr[i] appends a deep copy, the source stays as it was, and a fresh row read shows
-- it), its output and ingredients set to the item's. A reloaded table loses it and gets it again on the next check.
-- The item is kept in the game instance's ReferencedObjects too, so the GC never drops it while a save may name it.
-- An item not in memory is loaded from its pak here, with what `also` names (its model): BPModLoaderMod's ModActor
-- loading it was the only way in, and a player whose BPModLoaderMod was off, missing or late had no glider and no
-- recipe (user 2026-11-12: "make sure the glider loads immediatly for everyone").
--
-- local r = modrecipe.new({ item = path, needs = { { path, count }, ... }, label = "Hang Glider", tag = "glideritem",
--                           also = { path, ... } })
-- r.tick(dt) every frame (does its work every CHECK_S); r.stats.added counts recipes put in, r.stats.asked loads asked.

local log = require("mirror.log")
local util = require("mirror.util")
local jig = require("mirror.jig")
local game = require("mirror.game")

local modrecipe = {}

local DT = "/Game/Inventory/Crafting/DT_CraftingTableTypes.DT_CraftingTableTypes"
local RECIPES = "ItemsToCraft_4_BD8109364B29C67733A91FB124A74183"
local OUT = "ItemToCraft_4_D2CE3CA74FD5DD913A8E86BB23414908"
local NEED = "ItemsNeeded_8_03B3B6B348EE04631090FFB588341C30"
local ID, CNT = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848", "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local CHECK_S = 10.0
local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local LOAD_S, LOAD_MAX_S = 5.0, 120.0   -- asked again while it isn't there: 5 s, doubling up to 2 min (no pak at all)
local ARRIVE_S = 2.5                     -- looked for again this soon after asking (util.find asks again 2 s after a miss)
local uuid = 772200                      -- (each latent load its own UUID: one with a UUID already queued is dropped)

modrecipe.DT, modrecipe.CHECK_S, modrecipe.LOAD_S, modrecipe.ARRIVE_S = DT, CHECK_S, LOAD_S, ARRIVE_S

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
    local r = { stats = { added = 0, asked = 0 } }
    local bench = spec.bench or "CraftingWorkbench"
    local needs, tag = spec.needs, spec.tag
    local paths = { spec.item }
    for _, p in ipairs(spec.also or {}) do paths[#paths + 1] = p end
    local check_in, pinned_gi, pinned, said = 0, nil, {}, {}
    local load_at, load_wait = -100, LOAD_S

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

    local function pin(o, path)
        -- (first, before the walk over every object: the game instance lives as long as the game)
        if util.valid(pinned_gi) and pinned[path] then return end
        local gi = util.valid(pinned_gi) and pinned_gi or FindFirstOf("SD_GameInstance_C")
        if not util.valid(gi) then return end
        if not util.same(gi, pinned_gi) then pinned = {} end
        if pcall(function() local arr = gi.ReferencedObjects; arr[arr:GetArrayNum() + 1] = o end) then
            pinned_gi, pinned[path] = gi, true
        end
    end

    -- the engine's latent LoadAsset: it only queues an async load and returns, the game loads it the way it streams a
    -- level (zombies.load_loot_tables, kit 2026-11-02); LoadAsset or GetAsset from our Lua wait for it and can hang
    -- the game (L-014). True when a load was asked for now.
    local function ask_load()
        local t = os.clock()
        if t < load_at + load_wait then return false end
        local K, w = util.cdo(KSL), game.world()
        if not (K and w) then return false end
        if load_at > 0 then load_wait = math.min(load_wait * 2, LOAD_MAX_S) end
        load_at = t
        local n = 0
        for _, p in ipairs(paths) do
            if not util.find(p) then
                uuid = uuid + 1
                if pcall(function()
                    K:LoadAsset(w, K:Conv_SoftObjPathToSoftObjRef(K:MakeSoftObjectPath(p)), {},
                        { Linkage = 0, UUID = uuid, ExecutionFunction = FName("None"), CallbackTarget = w })
                end) then n = n + 1 end
            end
        end
        if n == 0 then return false end
        r.stats.asked = r.stats.asked + 1
        once("asked", string.format("%s: %s not in memory - asked the game to load it from its pak (%d file(s))",
            tag, spec.label, n))
        return true
    end

    function r.tick(dt)
        check_in = check_in - dt
        if check_in > 0 then return end
        check_in = CHECK_S
        local item = util.find(spec.item)
        if not item then
            -- (its pak is not installed, or nothing loaded it yet: looked for again soon after asking)
            if ask_load() then check_in = ARRIVE_S end
            return
        end
        if r.stats.asked > 0 then once("arrived", tag .. ": " .. spec.label .. " loaded") end
        pin(item, spec.item)
        for i = 2, #paths do
            local o = util.find(paths[i])
            if o then pin(o, paths[i]) elseif ask_load() then check_in = ARRIVE_S end
        end
        -- (looked at again every check, ~16 recipes in one row: a table the game reloaded has lost it)
        local dt_obj = util.find(DT)
        if dt_obj then add_recipe(dt_obj, item) end
    end

    function r.reset()
        check_in, pinned_gi, pinned, said, load_at, load_wait = 0, nil, {}, {}, -100, LOAD_S
        r.stats.added, r.stats.asked = 0, 0
    end

    return r
end

return modrecipe
