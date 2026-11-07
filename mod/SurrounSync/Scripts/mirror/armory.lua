-- The Colonel's Revenge Double Drum Magazine and the diamond Colonel's Revenge (user 2026-11-02: "design and build a
-- brand new Drum mag double drum mag"; 2026-11-03: "i dont like the gold make it look like the bo2 diamond camo").
-- SurrounSyncArmory.pak (tools/armory) brings DA_CRDoubleDrumMag (the item: a 200-round 5.56 magazine for the
-- CRDrumMag socket, an instance of the game's item class), its model SM_CRDoubleDrumMag and M_ColonelsDiamond. Here:
--  - its recipe at the weapons workbench (modrecipe.lua);
--  - the gun takes it: the Colonel's Revenge widget's MagContainer accepts only the items in OnlySupportTheseItems,
--    so it goes on that list, on the widget class's template (widgets made later copy it) and on the live widgets;
--  - on the gun it is shown by the game's drum attachment actor (the item's Local_ActorClass), and on the ground by
--    the game's drum pickup (PickupClass): both get the twin-drum model when their item is this one;
--  - every Colonel's Revenge (held, on the ground, other players' copies) and the attachments on it are drawn in
--    diamond: M_ColonelsDiamond with Detail = the game's weapon atlas, in place of the atlas material; its inventory icon
--    too (the item's AlternateMaterialToInspect).
-- Looks only: the item's data is the game's own inventory, the same on every game that has the pak (compat.lua).

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local jig = require("mirror.jig")
local modrecipe = require("mirror.modrecipe")

local armory = {}

local MOD = "/Game/Mods/SurrounSyncArmory/"
local DRUM2 = MOD .. "DA_CRDoubleDrumMag.DA_CRDoubleDrumMag"
local DRUM2_MESH = MOD .. "SM_CRDoubleDrumMag.SM_CRDoubleDrumMag"
local DRUM2_MAT = MOD .. "M_CRDoubleDrumMag.M_CRDoubleDrumMag"
local DIAMOND = MOD .. "M_ColonelsDiamond.M_ColonelsDiamond"
local GUN_DA = "/Game/Inventory/Items/DataAssets/Weapons/Firearms/Named/DA_ColonelsRevenge.DA_ColonelsRevenge"
local MAG_LIST = "/Game/Inventory/Widgets/Firearms/Named/SC_ColonelsRevenge.SC_ColonelsRevenge_C:WidgetTree.MagContainer"
local SC = "SC_ColonelsRevenge_C"
-- (neither pickup class has a ReceiveBeginPlay of its own, so util.instances hooks the parent's that runs for it:
-- hooking the class itself found new guns only at the 60 s re-walk, the finish showed up to a minute after a load)
local FIREARM = "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C"
local MESH_PICKUP = "/Game/Inventory/Items/BP_StaticMeshPickup.BP_StaticMeshPickup_C"
local ATLAS_MAT = "ExperimentalWeaponsTexture_Mat"   -- the shared weapon material the gun and its attachments use
local ATLAS = "/Game/Meshes/Textures/ExperimentalWeaponsTexture.ExperimentalWeaponsTexture"
local MML = "/Script/Engine.Default__KismetMaterialLibrary"
local SKEL = "/Script/Engine.SkeletalMeshComponent"
local RES = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Resources/"
local NEEDS = {   -- (high quality metal for the drums, rods for the springs and axles, plastic for the shells)
    { RES .. "DA_HighQualityMetal.DA_HighQualityMetal", 8 },
    { RES .. "DA_MetalRods.DA_MetalRods", 4 },
    { RES .. "DA_Plastic.DA_Plastic", 6 },
}
local LOOK_S = 0.25   -- the finish and model pass (new guns, attachments and drops show right within a quarter second)
local LIST_S = 1.0    -- the allow-list check

local recipe = modrecipe.new({ item = DRUM2, needs = NEEDS, bench = "WeaponsEquipmentWorkbench",
                               label = "Colonel's Revenge Double Drum Magazine", tag = "armory" })
armory.stats = { listed = 0, widgets = 0, finished = 0, swapped = 0, recipe = recipe.stats }

local look_in, list_in = 0, 0
local mid, mid_gi = nil, nil
local said = {}

local function once(key, msg)
    if said[key] then return end
    said[key] = true
    log.info(msg)
end

local function is_drum2(da) return jig.full_path(da) == DRUM2 end

-- the gun's MagContainer list (template or a live widget's): true when it holds the Double Drum (now or already)
local function allow(list, item)
    local arr = list.OnlySupportTheseItems
    local n = arr:GetArrayNum()
    for i = 1, n do
        if util.same(arr[i], item) then return false end
    end
    arr[n + 1] = item
    return true
end

local function patch_list(item)
    local tpl = util.find(MAG_LIST)
    if not tpl then return end
    local ok, added = pcall(allow, tpl, item)
    if not ok then once("listfail", "armory: the Colonel's Revenge mag list could not be read - the Double Drum won't fit"); return end
    if not added then return end
    armory.stats.listed = armory.stats.listed + 1
    -- the widgets made before this copy the old list: (only when the template was just patched: once per load)
    local live = 0
    for _, w in ipairs(FindAllOf(SC) or {}) do
        if util.valid(w) then
            pcall(function()
                local c = w.MagContainer
                if util.valid(c) then allow(c, item); live = live + 1 end
            end)
        end
    end
    armory.stats.widgets = armory.stats.widgets + live
    log.info("armory: the Colonel's Revenge takes the Double Drum Magazine (" .. live .. " live gun widgets)")
end

-- one diamond material for every Colonel's Revenge: kept by the game instance (outer and ReferencedObjects), so it
-- lives across levels and never holds a world
local function diamond()
    -- (the made one first: FindFirstOf walks every object, and this runs four times a second)
    if util.valid(mid) and util.valid(mid_gi) then return mid end
    local gi = FindFirstOf("SD_GameInstance_C")
    if not util.valid(gi) then return nil end
    if util.valid(mid) and util.same(gi, mid_gi) then return mid end
    local parent, lib, atlas = util.find(DIAMOND), util.cdo(MML), util.find(ATLAS)
    if not (parent and lib and atlas) then return nil end
    local m
    pcall(function() m = lib:CreateDynamicMaterialInstance(gi, parent, FName("SurrounSyncColonelsDiamond"), 0) end)
    if not util.valid(m) then once("nomid", "armory: no diamond material - the Colonel's Revenge keeps its look"); return nil end
    pcall(function() m:SetTextureParameterValue(FName("Detail"), atlas) end)
    pcall(function() local arr = gi.ReferencedObjects; arr[arr:GetArrayNum() + 1] = m end)
    pcall(function() util.find(GUN_DA).AlternateMaterialToInspect = m end)   -- the inventory icon
    mid, mid_gi = m, gi
    log.info("armory: diamond Colonel's Revenge ready")
    return m
end

-- the atlas material on a mesh component's slots becomes diamond
local function apply_finish(comp, m)
    if not util.valid(comp) then return end
    local n = 0
    pcall(function() n = comp:GetNumMaterials() end)
    for i = 0, n - 1 do
        local cur
        pcall(function() cur = comp:GetMaterial(i) end)
        if util.valid(cur) and not util.same(cur, m) and cur:GetFName():ToString() == ATLAS_MAT then
            pcall(function() comp:SetMaterial(i, m) end)
            armory.stats.finished = armory.stats.finished + 1
        end
    end
end

-- a static mesh component shows the twin drum (its own material, never the diamond one)
local function show_drum2(comp)
    if not util.valid(comp) then return end
    local sm, mat = util.find(DRUM2_MESH), util.find(DRUM2_MAT)
    if not (sm and mat) then return end
    local cur
    pcall(function() cur = comp.StaticMesh end)
    if not util.same(cur, sm) then
        pcall(function() comp:SetStaticMesh(sm) end)
        armory.stats.swapped = armory.stats.swapped + 1
    end
    local m0
    pcall(function() m0 = comp:GetMaterial(0) end)
    if not util.same(m0, mat) then pcall(function() comp:SetMaterial(0, mat) end) end
end

local function look_gun(gun, m)
    local skel = util.find(SKEL)
    local mesh
    if skel then pcall(function() mesh = gun:GetComponentByClass(skel) end) end
    if m then apply_finish(mesh, m) end
    local out = {}
    pcall(function() gun:GetAttachedActors(out, true, false) end)
    for _, h in ipairs(out) do
        local a
        pcall(function() a = h:get() end)
        if util.valid(a) then
            local comp, info
            pcall(function() comp = a.StaticMesh end)
            pcall(function() info = a["Attachment Info"] end)
            if is_drum2(info) then show_drum2(comp)
            elseif m then apply_finish(comp, m) end
        end
    end
end

local function look()
    local da = util.find(GUN_DA)
    if not da then return end
    local m = diamond()
    local name
    pcall(function() name = da.PickupClass:GetFName():ToString() end)
    if name then
        for _, gun in ipairs(util.instances(name, { FIREARM })) do
            if util.valid(gun) then look_gun(gun, m) end
        end
    end
    -- a Double Drum on the ground: the game's drum pickup, given the twin-drum model (its pickup component has no
    -- PickupInfo in this game: the item is ItemDataAsset)
    for _, p in ipairs(util.instances("BP_ColonelsRevengeDrumMagPickup_C", { MESH_PICKUP })) do
        if util.valid(p) then
            local item
            pcall(function() item = p.BP_JigPickupComponent.ItemDataAsset end)
            if is_drum2(item) then
                local comp
                pcall(function() comp = p.StaticMeshComponent end)
                show_drum2(comp)
            end
        end
    end
end

local function tick(dt)
    recipe.tick(dt)
    local item = util.find(DRUM2)
    if not item then return end   -- (the pak is not installed, or its ModActor has not loaded it yet)
    list_in = list_in - dt
    if list_in <= 0 then
        list_in = LIST_S
        patch_list(item)
    end
    look_in = look_in - dt
    if look_in <= 0 then
        look_in = LOOK_S
        look()
    end
end

local function forget()
    look_in, list_in = 0, 0
end

function armory.init(c)
    if c and c.armory == false then log.info("armory: off"); return end
    game.on_world_reset(forget)
    game.on_tick(function(dt) util.safe(tick, "armory", dt) end)
    log.info("armory: ready (Colonel's Revenge Double Drum Magazine at the weapons workbench, diamond Colonel's Revenge)")
end

armory.DRUM2 = DRUM2
armory._reset = function() look_in, list_in, mid, mid_gi, said = 0, 0, nil, nil, {}; recipe.reset() end

return armory
