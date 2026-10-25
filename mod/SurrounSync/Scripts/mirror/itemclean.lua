-- Item cleanup (a host setting, off by default): items dropped on the ground vanish after 20 minutes so
-- a long playthrough doesn't pile up thousands of saved pickups. Only dropped items count - things the
-- level placed (zero item IDs), death bags, carried/attached items and anything near a player are left alone.
-- The guest's copies go through the drop sync (drops.cleanup_remove).

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local hostrules = require("mirror.hostrules")

local itemclean = {}

local PICKUP_COMP = "BP_JigPickupComponent_C"
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"
local INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local ITEM_ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local UID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local SKIP_CLASS = { Container_DeadPlayerLoot_C = true }
local AGE = 20 * 60
local SCAN_EVERY = 30.0
local NEAR = 500
local MAX_PER_SCAN = 25

local role_fn = function() return nil end
local clock, scan_in = 0.0, 5.0
local first = {}          -- key -> clock when first seen lying there
local marked = {}         -- pickups this game saw being dropped (some drops carry a zero item ID)
local stats = { removed = 0, watching = 0 }

local function active()
    return role_fn() ~= "guest" and hostrules.mine("itemclean")
end

-- drops.lua calls this for every drop it sees (own drops, container drops, part stacks).
function itemclean.mark(pickup)
    if util.valid(pickup) then marked[#marked + 1] = { a = pickup, at = clock } end
end

local function is_marked(a)
    for _, m in ipairs(marked) do if util.same(m.a, a) then return true end end
    return false
end

local jig_cls
local function info_of(a)
    if not util.valid(jig_cls) then jig_cls = StaticFindObject(JIG) end
    local da, uid
    pcall(function()
        local c = a:GetComponentByClass(jig_cls)
        local info = c.PickupInfo
        local id = info[INFO][ITEM_ID]
        pcall(function() da = util.fname(id) end)
        local g = info[UID]
        uid = string.format("%d_%d_%d_%d", g.A, g.B, g.C, g.D)
    end)
    return da, uid
end

local function lying(a)
    if not util.valid(a) then return false end
    local ok = true
    pcall(function() if util.valid(a:GetAttachParentActor()) then ok = false end end)
    pcall(function() if a.bHidden == true or a:IsActorBeingDestroyed() then ok = false end end)
    return ok
end

local function near_player(l)
    local who = require("mirror.peers").ghost_list()
    who[#who + 1] = game.player()
    for _, p in ipairs(who) do
        local pl
        if p then pcall(function() pl = util.vec(p:K2_GetActorLocation()) end) end
        if pl and util.dist(pl, l) < NEAR then return true end
    end
    return false
end

local function scan()
    local keep, seen, removed = {}, 0, 0
    local live = {}
    for _, m in ipairs(marked) do if util.valid(m.a) then live[#live + 1] = m end end
    marked = live
    local drops = require("mirror.drops")
    for _, comp in ipairs(util.instances(PICKUP_COMP, "/Game/JigSInventory/Jigsaw/Pickup/BP_JigPickupComponent.BP_JigPickupComponent_C")) do
        local a
        pcall(function() a = comp:GetOwner() end)
        if lying(a) and not SKIP_CLASS[util.class_name(a) or ""] then
            local da, uid = info_of(a)
            if da and ((uid and uid ~= "0_0_0_0") or is_marked(a)) then
                local l
                pcall(function() l = util.vec(a:K2_GetActorLocation()) end)
                if l then
                    local key = string.format("%s:%s:%d:%d:%d", tostring(util.addr(a)), da,
                        math.floor(l.X / 50), math.floor(l.Y / 50), math.floor(l.Z / 50))
                    keep[key] = first[key] or clock
                    seen = seen + 1
                    if clock - keep[key] >= AGE and removed < MAX_PER_SCAN and not near_player(l) then
                        if drops.cleanup_remove(a) then
                            removed = removed + 1
                            keep[key] = nil
                        end
                    end
                end
            end
        end
    end
    first = keep
    stats.watching = seen
    if removed > 0 then
        stats.removed = stats.removed + removed
        log.info(string.format("itemclean: removed %d dropped item(s) older than 20 minutes (%d still on the ground)", removed, seen - removed))
    end
end

local function tick(dt)
    clock = clock + dt
    scan_in = scan_in - dt
    if scan_in > 0 then return end
    scan_in = SCAN_EVERY
    if not (active() and util.valid(game.player())) then first = {}; return end
    util.job("itemclean.scan", util.safe, scan, "itemclean.scan")
end

-- Dev tests: shorter age and scan interval (seconds).
function itemclean.dev_age(age, every) AGE, SCAN_EVERY, scan_in = age or AGE, every or SCAN_EVERY, 0 end

function itemclean.status()
    return string.format("item cleanup %s: watching %d, removed %d", active() and "on" or "off", stats.watching, stats.removed)
end

local function forget_world() first, marked = {}, {} end

function itemclean.init(role_getter)
    role_fn = role_getter or role_fn
    game.on_world_reset(forget_world)
    game.on_tick(function(dt) util.safe(tick, "itemclean.tick", dt) end)
end

return itemclean
