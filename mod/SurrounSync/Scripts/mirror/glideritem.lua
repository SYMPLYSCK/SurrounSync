-- The Hang Glider item (user 2026-11-02: "Add the item", made at the crafting workbench). DA_HangGlider comes from
-- SurrounSyncGlider.pak (tools/glider: an instance of the game's item class, loaded with the pak's ModActor). Only a
-- player who carries one (anywhere in the inventory, backpack included) opens the glider (glider.lua). Its recipe and
-- keeping the item loaded: modrecipe.lua.

local util = require("mirror.util")
local jig = require("mirror.jig")
local modrecipe = require("mirror.modrecipe")

local glideritem = {}

local ITEM = "/Game/Mods/SurrounSyncGlider/DA_HangGlider.DA_HangGlider"
local RES = "/Game/Inventory/Items/DataAssets/CraftingMaterials/Resources/"
local NEEDS = {   -- (cloth for the sail, rope for the rigging, rods for the frame)
    { RES .. "DA_Cloth.DA_Cloth", 12 },
    { RES .. "DA_Rope.DA_Rope", 3 },
    { RES .. "DA_MetalRods.DA_MetalRods", 4 },
}

-- (the model glider.lua shows in flight: loaded with the item when nothing else loaded them)
local recipe = modrecipe.new({ item = ITEM, needs = NEEDS, label = "Hang Glider", tag = "glideritem",
                               also = { "/Game/Mods/SurrounSyncGlider/SM_Glider.SM_Glider" } })
glideritem.stats = recipe.stats

-- does this player carry a Hang Glider (any container, the backpack's too)?
function glideritem.carried(p)
    local comp
    pcall(function() comp = p.BP_JigMultiplayer end)
    if not util.valid(comp) then return false end
    return jig.count_of_item(comp, ITEM) > 0
end

-- main.lua's copy (glider.init), every frame; does its work every modrecipe.CHECK_S
glideritem.tick = recipe.tick

glideritem.ITEM = ITEM
glideritem._reset = recipe.reset

return glideritem
