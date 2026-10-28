-- When the game's container UI can't place an item in the grid (BuildDataToContainer / SetupNewAddedItem), it
-- removes it with comp.SERVER_RequestRemoveItem(comp, uid, n, true) -> HandleLocalRequestConsumeItem: the same
-- consume a player's rip makes, but nobody took anything. Only those two paths pass the component itself as
-- TargetComp (decompiled BP_JigComponent). Marked here so the consume hooks don't report it as a take.

local util = require("mirror.util")
local jig = require("mirror.jig")

local uiremove = {}

uiremove.PATH = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_RequestRemoveItem"
local KEEP_S = 2.0 -- the consume runs inside the same call; this only bounds the table
local marked = {}

uiremove.hook_fn = function(self, TargetComp, ItemUID)
    util.safe(function()
        if not util.same(util.obj(self), util.obj(TargetComp)) then return end
        local uid
        pcall(function() uid = jig.uid_str(ItemUID:get()) end)
        if uid then marked[uid] = os.clock() end
    end, "uiremove.hook")
end

-- urgent: guards against item loss, and in the kit (2026-10-27) the budgeted lookup never ran for it
function uiremove.ensure_hook() util.ensure_hook(uiremove.PATH, uiremove.hook_fn, nil, true) end

-- true while uid was just removed by the game's UI (not by a player)
function uiremove.is(uid)
    local t = uid and marked[uid]
    if not t then return false end
    if os.clock() - t > KEEP_S then marked[uid] = nil; return false end
    return true
end

return uiremove
