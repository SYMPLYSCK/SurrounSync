-- Container contents stay the same on both screens: taking, putting in, and the first open.

local log = require("mirror.log")
local util = require("mirror.util")
local events = require("mirror.events")

local loot = {}

local MAIN = {
    "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C",
    "/Game/Inventory/Containers/ToolRequiredContainer/BP_MASTER_ToolRequiredContainer.BP_MASTER_ToolRequiredContainer_C",
    "/Game/Inventory/Containers/PicklockContainer/BP_MASTER_PicklockContainer.BP_MASTER_PicklockContainer_C",
    "/Game/Inventory/Containers/Containers/Airdrop/Master_AirdropContainer.Master_AirdropContainer_C",
    "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C",
    "/Game/Blueprints/BuildingSystem/Actors/Containers/BuildableMaster_Container.BuildableMaster_Container_C",
    "/Game/Blueprints/BuildingSystem/Actors/Display/BuildableMaster_Display.BuildableMaster_Display_C",
    "/Game/Blueprints/BuildingSystem/Actors/Tents/BuildableMaster_Tent.BuildableMaster_Tent_C",
    "/Game/Blueprints/BuildingSystem/Actors/Benches/Buildable_BatteryCharger.Buildable_BatteryCharger_C",
    "/Game/Blueprints/Other/BP_CookingStation.BP_CookingStation_C",
    "/Game/Blueprints/Other/BP_CraftingStation.BP_CraftingStation_C",
    "/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C",
}
local ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local ITEM_ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local DURABILITY = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local UID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"

local cfg, role, session
-- Taken/put-in events must not expire: replaying a full contents list over a lost one dupes or loses items.
local channel = events.reliable("loot")
-- Host -> guest full contents ("C <id> <ack> <items>"), kept apart so the event blob stays small.
local cchan = events.reliable("lootc", 64)
local applying = false
local hook_in = 0.0
local stats = { sent = 0, applied = 0, missing = 0, put = 0, added = 0 }
-- The same item has a different id in each game: alias maps theirs to ours, rev ours to theirs.
local alias = {}
local rev = {}
local added_once = {}
-- uid -> item asset of what this game last saw in a shared container: a take carries it, so the other game
-- can still find the item when the uid pairing isn't there yet (a fast take right after opening, before
-- the host's list was taken over, was acked but never removed - the next list brought the item back)
local da_of = {}
local put_sent = {}
local add_q, moved, move_q = {}, {}, {}
local JIG_COMP = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"
local GENERATE = JIG_COMP .. ":InitializeJigComponent"
local REQUEST = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:SERVER_RequestData"
local diag_left = 20
local PREFETCH = {
    "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C",
    "/Game/Inventory/Containers/ToolRequiredContainer/BP_MASTER_ToolRequiredContainer.BP_MASTER_ToolRequiredContainer_C",
    "/Game/Inventory/Containers/PicklockContainer/BP_MASTER_PicklockContainer.BP_MASTER_PicklockContainer_C",
    "/Game/Inventory/Containers/Containers/Airdrop/Master_AirdropContainer.Master_AirdropContainer_C",
}
local jig = require("mirror.jig")
-- uid -> count last seen in a shared container (what a take removed = that minus what's left)
local count_seen = {}
local function note_items(comp)
    for _, it in ipairs(jig.contents_of(comp)) do
        if it.uid and it.da then da_of[it.uid], count_seen[it.uid] = it.da, it.count or 1 end
    end
end
-- Guest: what each take removed ("<id> <uid as sent>" -> { da, n, at }): the host answers "L" when its copy has
-- none of it (the host took it at the same moment, or this game's copy had an item the host's world doesn't) and
-- this game takes it back out of the inventory - else the item existed twice.
local sent_takes = {}
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local crumb = require("mirror.crumb")
local now = 0.0
local opened_at, reopened = {}, {}
-- guest: when the host's list of a container came, and when this game last asked for it
local list_at, asked_at = {}, {}
local FRESH = 3.0
local pushed = {}
local push_q = {}
local host_list = {}
-- Guest: the host's ack in its last list per container, and a re-check 1 s after taking a list over
-- (a player saw an item kept by the take-over gone until the next host push, 8 s later)
local host_ack, recheck = {}, {}
local opened = {}
local asked = {}
local synced = {}
local apply_q = {}
-- Guest: last event number sent per container, and items the host had no room for (kept here only).
local seq, pending, held = 0, {}, {}
-- Host: last guest event number applied per container.
local ack = {}
local function next_seq(id)
    seq = seq + 1
    if role ~= "host" then pending[id] = seq end
    return seq
end
local function mark_dirty(id, comp)
    if role ~= "host" or not util.valid(comp) or not ghost.get() then return end
    local q = push_q[id]
    if q then q.comp = comp else push_q[id] = { comp = comp, at = now + 0.5 } end
end
local function release(id, uid)
    local h = held[id]
    if not h or not h[uid] then return end
    h[uid] = nil
    if next(h) == nil then held[id] = nil end
end

local function list_add(id, uid, da, count, dx, dy, inside, place)
    local list = host_list[id]
    if not list or synced[id] then return end
    for _, w in ipairs(list) do if w.uid == uid then return end end
    local at = #list + 1
    list[at] = { uid = uid, da = da, count = tonumber(count) or 1, dx = tonumber(dx) or 0, dy = tonumber(dy) or 0,
                 cell = place.cell, rot = place.rot, slot = place.slot }
    local sub = (inside and inside ~= "") and jig.decode(inside) or {}
    for i = 2, #sub do
        local w = sub[i]
        if w.parent then w.parent = at + w.parent - 1 end
        list[#list + 1] = w
    end
end
local function list_take(id, uid, left)
    local list = host_list[id]
    if not list or synced[id] then return end
    local at
    for i, w in ipairs(list) do if w.uid == uid then at = i; break end end
    if not at then return end
    if left > 0 then list[at].count = left; return end
    local drop, place, out = { [at] = true }, {}, {}
    for i, w in ipairs(list) do
        if w.parent and drop[w.parent] then drop[i] = true end
        if not drop[i] then
            out[#out + 1] = w
            place[i] = #out
            if w.parent then w.parent = place[w.parent] end
        end
    end
    host_list[id] = out
end

local function shared() return role == "host" or (session and session.in_world()) end
local function traded() if session and session.checkpoint and shared() then session.checkpoint("loot") end end
-- Every take and put-in needs a save soon on both sides: the guest's save keeps what it took, the host's
-- save keeps the container without it. World loot only saved on the guest's side was a dupe: the host
-- quit or crashed, its containers came back full and the guest still had the items.
-- (Q asks, C is a full list, M a rearrange, R a rejection: nothing changed hands.)
local function is_trade(p)
    return p:find("^[QCMR] ") == nil
end
channel.send = function(self, p) if is_trade(p) then traded() end return events.send(self, p) end

local uid_str, guid, full_path = jig.uid_str, jig.guid, jig.full_path

-- A car's trunk is a container that moves: by position the host often didn't find the guest's car (parked a
-- little differently, or driven since) and the take was lost - the item stayed in the host's trunk AND the
-- guest's bag. Cars go by the host's car name (vehicles.lua pairs the names on both games).
local VEHICLE = "/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C"
local veh_cls, veh_miss, car_by_class = nil, 0, {}
local function is_car(actor)
    local cls
    pcall(function() cls = actor:GetClass() end)
    local a = util.addr(cls)
    if a and car_by_class[a] ~= nil then return car_by_class[a] end
    if not util.valid(veh_cls) and os.clock() >= veh_miss then
        veh_cls = StaticFindObject(VEHICLE)
        if not util.valid(veh_cls) then veh_cls, veh_miss = nil, os.clock() + 10 end
    end
    if not util.valid(veh_cls) then return false end
    local yes = false
    pcall(function() yes = actor:IsA(veh_cls) == true end)
    if a then car_by_class[a] = yes end
    return yes
end

local function id_of(actor)
    if is_car(actor) then
        local v = require("mirror.vehicles")
        local n = v.peer_name_of and v.peer_name_of(actor)
        if n and n ~= "" then return "car:" .. n end
    end
    local cls = util.class_name(actor)
    local l = actor:K2_GetActorLocation()
    return string.format("%s@%d,%d,%d", cls, math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5), math.floor(l.Z / 10 + 0.5))
end

local function comp_of(actor)
    local c
    pcall(function() c = actor.BP_JigMultiplayer end)
    return util.valid(c) and c or nil
end

-- A container component kept from an earlier frame (list up to 120 s old, queue, opened), or nil when
-- it's gone. IsValid alone passes a component whose actor is being destroyed (a picked-up buildable, a
-- despawned car), or a new object at a freed one's address - calls on it can walk junk (report 122034:
-- native crash in UE4SS property lookup during loot, the host ahead-loading right after a guest joined).
local function still(id, comp)
    if not util.valid(comp) then return nil end
    local owner, ok = nil, false
    pcall(function()
        owner = comp:GetOwner()
        ok = util.valid(owner) and not owner:IsActorBeingDestroyed()
    end)
    if not ok then return nil end
    local idok, now_id = pcall(id_of, owner)
    return (idok and now_id == id) and comp or nil
end

local function count_of(comp, uid)
    local n = 0
    pcall(function()
        util.each(comp.MainJigContainers, function(_, c)
            util.each(c:get()[ITEMS], function(_, it)
                local item = it:get()
                if uid_str(item[UID]) == uid then n = n + (item[INFO][COUNT] or 0) end
            end)
        end)
    end)
    return n
end

local function forget(mine, theirs)
    if theirs then alias[theirs], added_once[theirs] = nil, nil end
    if mine then rev[mine], added_once[mine], put_sent[mine] = nil, nil, nil end
end

local last_removed = { key = nil, at = -100 }
local function removed(actor, uid)
    local comp = comp_of(actor)
    if not comp then return end
    local ok, id = pcall(id_of, actor)
    if not ok then return end
    local left = count_of(comp, uid)
    -- One removal fires both JigMP_OnItemRemoved and JigMP_OnMainContainerItemRemoved: the echo reached the
    -- host as a second take of an item already gone there, and its "L" took the item back out of the guest's
    -- bag (2026-10-25 reports: every take refunded as "someone else took that at the same moment").
    local key = id .. " " .. uid .. " " .. left
    if last_removed.key == key and now - last_removed.at < 0.25 then return end
    last_removed.key, last_removed.at = key, now
    local da = da_of[uid]
    local sent_uid = rev[uid] or uid
    if role ~= "host" and da then
        local n = (count_seen[uid] or (left + 1)) - left
        if n > 0 then sent_takes[id .. " " .. sent_uid] = { da = da, n = n, at = now } end
    end
    count_seen[uid] = left > 0 and left or nil
    channel:send(string.format("%s %s %d %d", id, sent_uid, left, next_seq(id)) .. (da and (" " .. da) or ""))
    stats.sent = stats.sent + 1
    if left == 0 then release(id, uid) end
    mark_dirty(id, comp)
    if left == 0 then forget(uid, rev[uid]) end
    log.debug(string.format("loot: took %s from %s (%d left there)", uid, id, left))
end
local function on_removed(self, ItemUID)
    if applying or not shared() then return end
    local actor = self:get()
    local uid
    pcall(function() uid = uid_str(ItemUID:get()) end)
    if uid then removed(actor, uid) end
end

-- Dropping an item onto a stack of the same item (SERVER_RequestStackItem) moves the count with no
-- removed/added event: taken onto a stack in the bag, the host never heard of it and its next list put
-- the item back - every try copied the stack (nails, 2026-10-25). Put onto a container's stack, the
-- host never got it. Looked at the next frame (the hook may run before the game did the move):
-- out of a shared container it is a take, onto a stack in one an "N" (count up).
local stacks = {}
local function stack_up(actor, uid)
    local comp = comp_of(actor)
    local ok, id = pcall(id_of, actor)
    if not (comp and ok) then return end
    local have = count_of(comp, uid)
    local was = count_seen[uid]
    if not was and host_list[id] then
        local theirs = rev[uid] or uid
        for _, w in ipairs(host_list[id]) do if w.uid == theirs then was = w.count or 1; break end end
    end
    if not was then
        log.warn("loot: something was stacked onto an item in " .. id .. " whose count wasn't known here - not sent")
        count_seen[uid] = have > 0 and have or nil
        return
    end
    local n = have - was
    if n <= 0 then return end
    count_seen[uid] = have
    local da = da_of[uid] or ""
    channel:send(string.format("N %s %s %d %d %s", id, rev[uid] or uid, n, next_seq(id), da))
    stats.put = stats.put + 1
    mark_dirty(id, comp)
    log.info(string.format("loot: stacked %d %s onto a stack in %s - telling the other game", n, da:match("[%w_]+$") or "item", id))
end
local function flush_stacks()
    if not stacks[1] then return end
    local list = stacks
    stacks = {}
    for _, s in ipairs(list) do
        local from_owner, to_owner
        if util.valid(s.from) then pcall(function() from_owner = s.from:GetOwner() end) end
        if util.valid(s.to) then pcall(function() to_owner = s.to:GetOwner() end) end
        if util.valid(from_owner) and loot.is_shared(from_owner) and not util.same(from_owner, game.player()) then
            removed(from_owner, s.dropped)
        elseif util.valid(from_owner) and not util.same(from_owner, game.player()) then
            -- a zombie body: the item kind is the receiving stack's (a merged one is gone now), or for a split
            -- the part that stayed behind
            local look, want = s.split and s.from or s.to, s.split and s.dropped or s.receiver
            if util.valid(look) then
                for _, it in ipairs(jig.contents_of(look)) do
                    if it.uid == want then require("mirror.corpses").stack_take(from_owner, it.da); break end
                end
            end
        end
        -- (a split's new stack comes through the container's "added" event as a put-in)
        if not s.split and util.valid(to_owner) and loot.is_shared(to_owner) and not util.same(to_owner, game.player()) then
            stack_up(to_owner, s.receiver)
        end
    end
end
local function on_stack(FromCom, ToComp, DroppedUID, ReceiverUID)
    if applying or not shared() then return end
    local s = {}
    pcall(function() s.from, s.to = FromCom:get(), ToComp:get() end)
    pcall(function() s.dropped, s.receiver = uid_str(DroppedUID:get()), uid_str(ReceiverUID:get()) end)
    if s.dropped and s.receiver then stacks[#stacks + 1] = s end
end
-- Splitting a stack (the split slider) lowers the old stack with ServerUpdateCountByUID - no removed event
-- either: split out of a container into the bag, the host kept the whole stack (a copy); split inside a
-- container, the host got the new stack and kept the old one whole. The old stack's new count goes as a take.
local function on_split(FromComp, ToComp, ItemUID)
    if applying or not shared() then return end
    local s = { split = true }
    pcall(function() s.from, s.to = FromComp:get(), ToComp:get() end)
    pcall(function() s.dropped = uid_str(ItemUID:get()) end)
    if s.dropped then stacks[#stacks + 1] = s end
end

local function find(id)
    if id:sub(1, 4) == "car:" then
        local v = require("mirror.vehicles")
        return v.car_named and v.car_named(id:sub(5)) or nil
    end
    return util.find_by_id(id, 100)
end

-- Host: a guest's take / put-in for a container this game can't find right now (not loaded here, a car not
-- paired yet) is kept and tried again - dropped, the item was in the host's container and the guest's bag.
-- Not acked until it's applied, so the guest never takes over a host list that still holds what it took.
local later, later_in = {}, 0.0
local LATER_S = 600
local function keep_for_later(kind, id, payload)
    if role ~= "host" then return false end
    for _, x in ipairs(later) do if x.p == payload then return true end end
    later[#later + 1] = { k = kind, id = id, p = payload, t = now }
    log.info(string.format("loot: %s for %s - container not found here yet, kept to apply when it is", kind == "A" and "put-in" or "take", id))
    return true
end

local function acked(id, s, comp)
    s = tonumber(s)
    if role ~= "host" or not s then return end
    if s > (ack[id] or 0) then ack[id] = s end
    mark_dirty(id, comp)
end

-- host: "<id> <uid>" -> when this guest's take emptied it (a repeat of it is an echo, not a race)
local emptied, emptied_n = {}, 0
local function apply(payload)
    if not shared() then return end
    local id, uid, left, s, da = payload:match("^(%S+) (%S+) (%d+) ?(%d*) ?(%S*)$")
    if not id then return end
    list_take(id, uid, tonumber(left) or 0)
    local actor = find(id)
    local comp = actor and comp_of(actor)
    if not comp then
        stats.missing = stats.missing + 1
        keep_for_later("T", id, payload)
        return
    end
    acked(id, s, comp)
    local theirs = uid
    if role == "host" then
        -- (contents not rolled here yet: roll them first, or every take would look like one of an item not here)
        local slots = 0
        pcall(function() slots = comp.MainJigContainers:GetArrayNum() end)
        if slots == 0 then pcall(jig.generate, comp) end
    end
    local have = count_of(comp, uid)
    if have == 0 and alias[uid] then uid = alias[uid]; have = count_of(comp, uid) end
    if have == 0 and da ~= "" then
        -- no pairing for that uid: the same kind of item in that container (the biggest stack, which can give
        -- what was taken)
        local best
        for _, it in ipairs(jig.contents_of(comp)) do
            if it.da == da and not it.parent and (not best or (it.count or 1) > (best.count or 1)) then best = it end
        end
        if best then
            alias[theirs], rev[best.uid] = best.uid, theirs
            uid, have = best.uid, best.count or 1
            log.info("loot: matched the other player's take in " .. id .. " by item (" .. (da:match("[%w_]+$") or da) .. ")")
        end
    end
    if tonumber(left) == 0 then
        -- the guest's own uid this item was added for (its put): the guest learned the host's uid from a list and
        -- took it by that one - left paired, the same bag put back was "already added" and never arrived
        local orig = rev[uid]
        forget(uid ~= theirs and uid or nil, theirs)
        if orig and orig ~= theirs then forget(uid, orig) end
    end
    -- this same item was just taken out by this guest's own earlier message (an echo): nothing to give back
    if have == 0 and role == "host" and now - (emptied[id .. " " .. theirs] or -100) < 5.0 then return end
    if have == 0 and role == "host" then
        -- none of it here: taken here at the same moment, or the guest's copy had it and this world doesn't.
        -- The host's world decides: the guest gives it back.
        channel:send("L " .. id .. " " .. theirs)
        stats.lost = (stats.lost or 0) + 1
        log.info("loot: the other player took " .. ((da ~= "" and da or "?"):match("[%w_]+$") or "?") .. " from " .. id
            .. " - none of it here (taken here at the same moment?) - they give it back")
        return
    end
    local take = have - (tonumber(left) or 0)
    if take <= 0 then return end
    applying = true
    local ok, err = jig.take(comp, uid, take, have)
    applying = false
    if ok then count_seen[uid] = (have - take) > 0 and (have - take) or nil end
    if ok and tonumber(left) == 0 then
        if emptied_n > 200 then emptied, emptied_n = {}, 0 end
        emptied[id .. " " .. theirs], emptied_n = now, emptied_n + 1
    end
    stats.applied = stats.applied + 1
    log.info(string.format("loot: the other player took %d from %s - removed here%s", take, id,
        ok and "" or (" FAILED: " .. tostring(err))))
end

local function on_added(self, ItemUID, ItemInfo)
    if applying or not shared() then return end
    local actor = self:get()
    local comp = comp_of(actor)
    if not comp then return end
    local uid, da, count, dur
    pcall(function() uid = uid_str(ItemUID:get()) end)
    if not uid or rev[uid] or now - (put_sent[uid] or -10) < 1.0 then return end
    if ItemInfo then
        pcall(function()
            local info = ItemInfo:get()[INFO]
            da = full_path(info[ITEM_ID])
            count = info[COUNT]
            local d = info[DURABILITY]
            dur = { X = d.X, Y = d.Y }
        end)
    else
        for _, it in ipairs(jig.contents_of(comp)) do
            if it.uid == uid then da, count, dur = it.da, it.count, { X = it.dx, Y = it.dy }; break end
        end
    end
    if not da then return end
    da_of[uid], count_seen[uid] = da, tonumber(count) or 1
    put_sent[uid] = now
    local ok, id = pcall(id_of, actor)
    if not ok then return end
    -- Sent next frame: moving an item inside the container fires this "added" event too - the move hook
    -- (on_moved, same frame) cancels it, so a rearrange never adds a copy on the other side.
    add_q[#add_q + 1] = { uid = uid, id = id, comp = comp, da = da, count = count, dur = dur }
end

local function flush_adds()
    local q = add_q
    add_q = {}
    for _, e in ipairs(q) do
        if moved[e.uid] then
            put_sent[e.uid] = nil
        elseif util.valid(e.comp) then
            local id, uid, da, count, dur = e.id, e.uid, e.da, e.count, e.dur
            local inside = jig.subtree(e.comp, uid)
            local me = inside and inside[1] or {}
            -- where it sits in the grid (cell:rotated:container) so the other game puts it in the same spot
            channel:send(string.format("A %s %s %s %d %.3f %.3f %d %d:%d:%d", id, uid, da, count or 1, dur and dur.X or 0, dur and dur.Y or 0, next_seq(id),
                me.cell or -1, me.rot and 1 or 0, me.slot or -1)
                .. (jig.worth_sending(inside) and (" " .. jig.encode(inside)) or ""))
            mark_dirty(id, e.comp)
            stats.put = stats.put + 1
            log.info(string.format("loot: put %s x%d into %s - telling the other game", da:match("[^%.]+$") or da, count or 1, id))
        end
    end
    moved = {}
end

-- is_main asks IsA of these only: Container, Display and BatteryCharger are children of Buildable_MASTER
-- (object dump), their own entries in MAIN are there for their hooks.
local MAIN_ROOTS = {}
for _, p in ipairs(MAIN) do
    if not (p:find("BuildableMaster_Container", 1, true) or p:find("BuildableMaster_Display", 1, true)
            or p:find("Buildable_BatteryCharger", 1, true)) then MAIN_ROOTS[#MAIN_ROOTS + 1] = p end
end
local main_cls = {}
local function is_main_uncached(actor)
    for _, p in ipairs(MAIN_ROOTS) do
        local c = main_cls[p]
        local yes = false
        if util.valid(c) then pcall(function() yes = actor:IsA(c) == true end) end
        if yes then return true end
    end
    return false
end
-- Answer per class (by class address, checked by name: a freed class's address can come back as another).
-- Several MAIN classes are usually not loaded at all (tents, stations, lock/tool containers) and each
-- StaticFindObject miss costs ~15 ms: they were looked up again every 10 s and "not a container" was never
-- kept while one was missing - every pass over the ~3000 inventory components redid up to 12 IsA each and
-- hitched 30-90 ms ("perf: loot took"). Now a class's "no" is final once the missing ones were looked up
-- after that class was first seen (its parents load with it, so a later-loading MAIN class can't be one of
-- them); until then it's "no for now" (as before) and one lookup round runs, one class per frame.
local main_by_class, first_seen = {}, {}
local round_at, round_q, round_due = -1, nil, false
local function main_round_tick()
    if not round_q then
        if not round_due then return end
        round_due = false
        round_q = { at = os.clock(), i = 0 }
    end
    local i = round_q.i + 1
    while MAIN_ROOTS[i] and util.valid(main_cls[MAIN_ROOTS[i]]) do i = i + 1 end
    local p = MAIN_ROOTS[i]
    if not p then round_at, round_q = round_q.at, nil; return end
    round_q.i = i
    local c = StaticFindObject(p)
    if util.valid(c) then main_cls[p] = c end
end
local function is_main(actor)
    if round_at < 0 then
        -- The first round runs one class per frame from the tick after a load (all at once was a 433 ms freeze
        -- right after joining, report 20261027-095623). Asked before it's done (a take/put in the first frames):
        -- the rest is looked up here at once, as it always was - no answer comes from a half-done round.
        local q = round_q or { at = os.clock(), i = 0 }
        for i = q.i + 1, #MAIN_ROOTS do
            local p = MAIN_ROOTS[i]
            if not util.valid(main_cls[p]) then
                local c = StaticFindObject(p)
                if util.valid(c) then main_cls[p] = c end
            end
        end
        round_at, round_q, round_due = q.at, nil, false
    end
    local cls
    pcall(function() cls = actor:GetClass() end)
    local a = util.addr(cls)
    if not a then return is_main_uncached(actor) end
    local name = util.fname(cls)
    local e = main_by_class[a]
    if e and e.name == name then return e.yes end
    if e then main_by_class[a], first_seen[a] = nil, nil end
    local seen = first_seen[a] or os.clock()
    first_seen[a] = seen
    local r = is_main_uncached(actor)
    if r or round_at >= seen then main_by_class[a], first_seen[a] = { name = name, yes = r }, nil
    elseif not round_q then round_due = true end
    return r
end

local function player_jig()
    local c
    pcall(function() c = game.player().BP_JigMultiplayer end)
    return util.valid(c) and c or nil
end
local function local_uid(theirs) return alias[theirs] or theirs end

local function give_back(p)
    local id, uid = p:match("^L (%S+) (%S+)")
    local t = id and sent_takes[id .. " " .. uid]
    if not t or now - t.at > 120 then return end
    sent_takes[id .. " " .. uid] = nil
    local pc = player_jig()
    if not pc then return end
    local best
    for _, it in ipairs(jig.contents_of(pc)) do
        if it.da == t.da and not it.parent and (not best or (it.count or 1) > (best.count or 1)) then best = it end
    end
    local name = (t.da:match("([%w_]+)$") or "item"):gsub("^DA_", "")
    if not best then
        log.warn("loot: the host had no " .. name .. " left in " .. id .. " - couldn't find it here to give back")
        return
    end
    local n = math.min(t.n, best.count or 1)
    applying = true
    local ok, err = jig.take(pc, best.uid, n, best.count or 1)
    applying = false
    log.warn(string.format("loot: the host had no %s left in %s (taken there at the same moment) - gave back %d%s", name, id, n,
        ok and " (no duplicate)" or (" FAILED: " .. tostring(err))))
    if ok then require("mirror.notify").show("Someone else took that " .. name .. " at the same moment - they keep it.", "info") end
end

-- Rearranging inside a shared container: send the whole layout (uids as the other game knows them).
local function on_moved(self, ItemUID)
    if applying or not shared() then return end
    local comp = util.obj(self)
    if not comp then return end
    local owner
    pcall(function() owner = comp:GetOwner() end)
    if not (util.valid(owner) and is_main(owner)) then return end
    local uid
    pcall(function() uid = uid_str(ItemUID:get()) end)
    if not uid then return end
    moved[uid] = true
    local ok, id = pcall(id_of, owner)
    if ok and id then move_q[id] = comp end
end

local function flush_moves()
    for id, comp in pairs(move_q) do
        if still(id, comp) then
            local list = jig.contents_of(comp)
            for _, h in ipairs(list) do h.uid = rev[h.uid] or h.uid end
            channel:send(string.format("M %s %d %s", id, next_seq(id), jig.encode(list, true)))
            mark_dirty(id, comp)
            stats.moved = (stats.moved or 0) + 1
            log.info("loot: rearranged " .. id .. " - telling the other game")
        end
    end
    move_q = {}
end

local function apply_move(payload)
    if not shared() then return end
    local id, s, rest = payload:match("^M (%S+) (%d+) (.*)$")
    if not id then return end
    local actor = find(id)
    local comp = actor and comp_of(actor)
    if not comp then return end
    local n = 0
    pcall(function() n = comp.MainJigContainers:GetArrayNum() end)
    if n == 0 then acked(id, s, comp); return end
    applying = true
    local ok, mv, failed = pcall(jig.apply_layout, comp, jig.decode(rest), local_uid, player_jig())
    applying = false
    acked(id, s, comp)
    if not ok then log.warn("loot: couldn't rearrange " .. id .. ": " .. tostring(mv)); return end
    log.info(string.format("loot: the other player rearranged %s - %d moved here%s", id, mv,
        failed > 0 and (", " .. failed .. " couldn't move") or ""))
end

local function apply_add(payload)
    if not shared() then return end
    local id, uid, da, count, dx, dy, s, cell, rot, slot, inside =
        payload:match("^A (%S+) (%S+) (%S+) (%-?%d+) (%S+) (%S+) (%d+) (%-?%d+):(%d):(%-?%d+) ?(%S*)$")
    if not id then return end
    local place = { cell = tonumber(cell) >= 0 and tonumber(cell) or nil, rot = rot == "1", slot = tonumber(slot) >= 0 and tonumber(slot) or nil }
    local actor = find(id)
    local comp = actor and comp_of(actor)
    if added_once[uid] then
        -- a repeat of a put already done: skip it while that item is still here, or when it's no newer than what
        -- was acked (a replay). A newer put of an item gone from here is the same item put back: add it again.
        local here = comp and (count_of(comp, alias[uid] or uid) > 0 or count_of(comp, uid) > 0)
        if not comp or here or role ~= "host" or (tonumber(s) or 0) <= (ack[id] or 0) then
            if comp then acked(id, s, comp) end
            return
        end
        added_once[uid], alias[uid] = nil, nil
    end
    if not comp then
        stats.missing = stats.missing + 1
        if keep_for_later("A", id, payload) then return end
        log.info("loot: the other player put something into " .. id .. " - not here")
        return
    end
    if count_of(comp, uid) > 0 or (alias[uid] and count_of(comp, alias[uid]) > 0) then added_once[uid] = true; acked(id, s, comp); return end
    local asset = util.find(da)
    if not asset then
        log.info("loot: the other player put " .. (da:match("[^%.]+$") or da) .. " into " .. id .. " - not loaded here")
        if role == "host" then channel:send("R " .. id .. " " .. uid .. " " .. da) end
        return
    end
    local slots = 0
    pcall(function() slots = comp.MainJigContainers:GetArrayNum() end)
    if role ~= "host" then list_add(id, uid, da, count, dx, dy, inside, place) end
    if role ~= "host" and slots == 0 then
        added_once[uid] = true
        log.info(string.format("loot: the other player put %s into %s - not opened here yet, it'll be there when opened",
            da:match("[^%.]+$") or da, id))
        return
    end
    applying = true
    local mine, err = jig.add_item(comp, da, tonumber(count) or 1, tonumber(dx) or 0, tonumber(dy) or 0, nil, place)
    applying = false
    if not mine then
        log.warn("loot: couldn't add the other player's " .. (da:match("[^%.]+$") or da) .. " to " .. id .. ": " .. tostring(err))
        if role == "host" then channel:send("R " .. id .. " " .. uid .. " " .. da) end
        return
    end
    acked(id, s, comp)
    added_once[uid] = true
    alias[uid], rev[mine] = mine, uid
    da_of[mine], count_seen[mine] = da, tonumber(count) or 1
    stats.added = stats.added + 1
    local n, miss = 0, 0
    if inside ~= "" then
        applying = true
        local ok, a, m = pcall(jig.fill, comp, mine, jig.decode(inside))
        applying = false
        if ok then n, miss = a, m else log.warn("loot: couldn't fill the other player's item: " .. tostring(a)) end
    end
    log.info(string.format("loot: the other player put %s x%s into %s - added here%s", da:match("[^%.]+$") or da, count, id,
        (n + miss > 0) and string.format(" (holding %d, %d missing)", n, miss) or ""))
end

-- "N id uid n seq da": the other player stacked n more onto that item in a shared container
local function apply_count(payload)
    if not shared() then return end
    local id, uid, n, s, da = payload:match("^N (%S+) (%S+) (%d+) (%d+) ?(%S*)$")
    n = tonumber(n)
    if not (id and n and n > 0) then return end
    local list = host_list[id]
    if list and not synced[id] then
        for _, w in ipairs(list) do if w.uid == uid then w.count = (w.count or 1) + n end end
    end
    local actor = find(id)
    local comp = actor and comp_of(actor)
    if not comp then
        stats.missing = stats.missing + 1
        keep_for_later("N", id, payload)
        return
    end
    local mine = alias[uid] or uid
    local have = count_of(comp, mine)
    if have == 0 and da ~= "" then
        local best
        for _, it in ipairs(jig.contents_of(comp)) do
            if it.da == da and not it.parent and (not best or (it.count or 1) > (best.count or 1)) then best = it end
        end
        if best then mine, have = best.uid, best.count or 1 end
    end
    if have == 0 then
        -- not opened here yet (the stack comes with the container's list) or the stack is gone here: add it
        local slots = 0
        pcall(function() slots = comp.MainJigContainers:GetArrayNum() end)
        if slots == 0 or da == "" then acked(id, s, comp); return end
        applying = true
        local made, err = jig.add_item(comp, da, n, 0, 0)
        applying = false
        if not made then
            log.warn("loot: couldn't add the other player's stacked " .. (da:match("[%w_]+$") or da) .. " to " .. id .. ": " .. tostring(err))
            if role == "host" then channel:send("R " .. id .. " " .. uid .. " " .. da) end
            return
        end
        acked(id, s, comp)
        log.info(string.format("loot: the other player stacked %d %s in %s - not here, added as a new stack", n, da:match("[%w_]+$") or "item", id))
        return
    end
    applying = true
    local ok, err = pcall(function() comp:ServerUpdateCountByUID(jig.guid(mine), have + n) end)
    applying = false
    if ok then jig.show_count(comp, mine, have + n); count_seen[mine] = have + n end
    acked(id, s, comp)
    stats.added = stats.added + 1
    log.info(string.format("loot: the other player stacked %d more onto a stack in %s - %d now%s", n, id, have + n,
        ok and "" or (" FAILED: " .. tostring(err))))
end

-- quiet = applied inside the open itself (same frame, before the UI shows it): no redraw needed
local function sync_from_host(id, quiet)
    local comp, list = opened[id], host_list[id]
    if not (comp and list) then return end
    if not still(id, comp) then opened[id] = nil; return end
    if held[id] then return end
    local first = not synced[id]
    synced[id] = true
    applying = true
    local ok, set, added, removed, missing, pairs_ = pcall(jig.apply_contents, comp, list)
    applying = false
    if not ok then log.warn("loot: couldn't take over the host's contents of " .. id .. ": " .. tostring(set)); return end
    note_items(comp)
    for _, p in ipairs(pairs_) do
        if p.want.uid then alias[p.want.uid], rev[p.uid] = p.uid, p.want.uid end
    end
    applying = true
    local lok, mv = pcall(jig.apply_layout, comp, list, local_uid, player_jig())
    applying = false
    if lok and mv > 0 then log.info(string.format("loot: %s rearranged to the host's layout (%d moved)", id, mv)) end
    stats.synced = (stats.synced or 0) + 1
    if not first then
        local again = reopened[id]
        reopened[id] = nil
        if added + removed > 0 then
            -- still open on screen after a reopen: redraw it with the host's items
            if again and not quiet and now - (opened_at[id] or -100) < 5.0 then
                pcall(function() game.player():RequestServerData(comp, {}) end)
            end
            stats.fixed = (stats.fixed or 0) + 1
            log.info(string.format("loot: %s corrected to the host's contents (%d added, %d removed%s)", id, added, removed,
                missing > 0 and (", " .. missing .. " not loaded here") or ""))
        end
        return
    end
    if added + removed > 0 and not quiet and now - (opened_at[id] or -100) < 5.0 then
        -- open on screen: redraw it with the host's items (no message - it should just look right)
        local owner
        pcall(function() owner = comp:GetOwner() end)
        if util.valid(owner) then pcall(function() game.player():RequestServerData(comp, {}) end) end
    end
    recheck[id] = now + 1.0
    log.info(string.format("loot: %s now holds the host's items (%d: %d kept, %d added, %d removed%s)", id, #list, set, added,
        removed, missing > 0 and (", " .. missing .. " missing - opened before the host's list came, or not loaded here") or ""))
end

local function on_generated(comp, via)
    if not shared() or not util.valid(comp) then return end
    local owner
    pcall(function() owner = comp:GetOwner() end)
    local main = util.valid(owner) and is_main(owner)
    if diag_left > 0 then
        diag_left = diag_left - 1
        log.info(string.format("loot: open seen (%s): %s, shared container %s", via, util.class_name(owner) or "?", tostring(main)))
    end
    if not main then return end
    local ok, id = pcall(id_of, owner)
    if not ok then return end
    note_items(comp)
    -- A fresh host list (asked while the player came near): take it over right here, inside the open, so the
    -- container never shows this game's copy first. "init" runs before the UI reads it; "request" just after, same frame.
    local fresh = role ~= "host" and host_list[id] and now - (list_at[id] or -100) < FRESH
        and (pending[id] or 0) <= (host_ack[id] or 0)
    if role == "host" then
        -- Every generation, not just the first: some containers (shops) roll new stock after a while.
        pushed[id] = true
        push_q[id] = { comp = comp, at = now + 0.3 }
    elseif opened[id] then
        -- Opened again: the host's copy may have changed since (things the game adds or fills on its own,
        -- like a gas pump's cans, fire no event here). Ask again; its answer corrects this copy.
        if now - (opened_at[id] or -100) < 2.0 then return end
        opened[id], opened_at[id] = comp, now
        reopened[id] = true
        if fresh then reopened[id] = via ~= "init" or nil; sync_from_host(id, via == "init")
        else asked_at[id] = now; channel:send("Q " .. id) end
    elseif fresh then
        opened[id], opened_at[id] = comp, now
        sync_from_host(id, via == "init")
    else
        opened[id], opened_at[id] = comp, now
        if not host_list[id] and not jig.is_empty(comp) then
            -- the host's list isn't here yet: show nothing rather than this game's own roll, its items come in a moment
            applying = true
            pcall(jig.apply_contents, comp, {})
            applying = false
        end
        if host_list[id] and jig.is_empty(comp) then
            local n, miss = jig.set_starting(comp, host_list[id])
            log.info("loot: " .. id .. " preset to the host's items (" .. tostring(n) .. " set"
                .. (n and miss > 0 and (", " .. miss .. " not loaded here") or (n and "" or (" FAILED: " .. tostring(miss)))) .. ")")
        end
        if host_list[id] then apply_q[id] = now + 0.3
        elseif not asked[id] then asked[id] = true; channel:send("Q " .. id) end
    end
end

local function flush_pushes()
    for id, q in pairs(push_q) do
        if now >= q.at then
            push_q[id] = nil
            if still(id, q.comp) then
                cchan:send("C " .. id .. " " .. (ack[id] or 0) .. " " .. jig.encode(jig.contents_of(q.comp), true))
                stats.pushed = (stats.pushed or 0) + 1
            end
        end
    end
end

local LIST_EVERY, SCAN_EVERY, AHEAD_M, AHEAD_STEP = 120.0, 2.0, 35, 0.15
local ahead, ahead_scan_in, ahead_step_in = {}, 0.0, 0.0
local known, list_in = {}, 0.0
-- The container list is rebuilt LIST_SLICE components per frame (it was one 120-160 ms frame every
-- LIST_EVERY s); the old list stays in use until the new one is done. Components come from a
-- tracked list (one walk per world, new ones via BeginPlay) instead of a FindAllOf each time.
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"
local LIST_SLICE = 150
local build
local function list_containers()
    -- (the container classes are still being looked up, one per frame: listing now would force them all at once)
    if round_at < 0 then list_in = 0.1; return end
    local comps, walked = util.instances("BP_JigComponent_C", JIG)
    if not walked then list_in = 1.0; return end
    build = { comps = comps, i = 1, out = {} }
end
local function list_step()
    local g, me = ghost.get(), game.player()
    local comps, out = build.comps, build.out
    local last = math.min(#comps, build.i + LIST_SLICE - 1)
    for i = build.i, last do
        local comp = comps[i]
        local owner
        if util.valid(comp) then pcall(function() owner = comp:GetOwner() end) end
        if util.valid(owner) and not util.same(owner, g) and not util.same(owner, me) and is_main(owner) then
            local ok, id = pcall(id_of, owner)
            local l
            pcall(function() l = util.vec(owner:K2_GetActorLocation()) end)
            if ok and l then out[#out + 1] = { id = id, comp = comp, loc = l } end
        end
    end
    build.i = last + 1
    if build.i > #comps then known, build = out, nil end
end
local function ahead_scan()
    ahead = {}
    local gl = ghost.location()
    if not gl then return end
    for _, k in ipairs(known) do
        if not pushed[k.id] then
            local d = util.dist(gl, k.loc)
            if d < AHEAD_M * 100 then ahead[#ahead + 1] = { id = k.id, comp = k.comp, d = d } end
        end
    end
    table.sort(ahead, function(a, b) return a.d > b.d end)
end
local function list_tick(dt)
    list_in = list_in - dt
    if build then util.safe(list_step, "loot.list")
    elseif list_in <= 0 then list_in = role == "host" and LIST_EVERY or 15.0; util.safe(list_containers, "loot.list") end
end
-- Guest: containers within NEAR_M are asked about every 2 s, so their host list is already here (fresh)
-- when one is opened - the open then shows the host's items at once instead of correcting itself a moment later.
local NEAR_M, NEAR_EVERY, near_in = 3.0, 1.0, 0.0
local function near_ask()
    local l
    pcall(function() l = util.vec(game.player():K2_GetActorLocation()) end)
    if not l then return end
    for _, k in ipairs(known) do
        local id = k.id
        if util.dist(l, k.loc) < NEAR_M * 100 and now - (asked_at[id] or -100) >= 2.0
                and not (host_list[id] and now - (list_at[id] or -100) < 2.0) then
            asked[id], asked_at[id] = true, now
            channel:send("Q " .. id)
        end
    end
end
local function ahead_tick(dt)
    list_tick(dt)
    ahead_scan_in = ahead_scan_in - dt
    if ahead_scan_in <= 0 then ahead_scan_in = SCAN_EVERY; util.safe(ahead_scan, "loot.ahead_scan") end
    ahead_step_in = ahead_step_in - dt
    if ahead_step_in > 0 or #ahead == 0 then return end
    ahead_step_in = AHEAD_STEP
    local e = table.remove(ahead)
    if pushed[e.id] or not still(e.id, e.comp) then return end
    jig.generate(e.comp)
    pushed[e.id] = true
    push_q[e.id] = { comp = e.comp, at = now + 0.3 }
    stats.ahead = (stats.ahead or 0) + 1
end

function loot.guest_arriving()
    pushed, push_q, ahead, ahead_scan_in, list_in = {}, {}, {}, 0.0, 0.0
    alias, rev, added_once, put_sent, ack = {}, {}, {}, {}, {}
    emptied, emptied_n = {}, 0
    log.info("loot: a guest is arriving - container contents will be sent again ahead of time")
end

local function answer(id)
    local actor = find(id)
    local comp = actor and comp_of(actor)
    if not comp then stats.missing = stats.missing + 1; return end
    jig.generate(comp)
    pushed[id] = true
    push_q[id] = { comp = comp, at = now + 0.3 }
end

local function prefetch(actor)
    if role == "host" or not shared() or not util.valid(actor) then return end
    local ok, id = pcall(id_of, actor)
    if not ok then return end
    -- every interaction asks again (the host's copy can change without events), at most every 2 s
    if now - (asked_at[id] or -100) < 2.0 or (host_list[id] and now - (list_at[id] or -100) < FRESH) then return end
    asked[id], asked_at[id] = true, now
    channel:send("Q " .. id)
end
local prefetch_fn = function(self) util.safe(function() prefetch(self:get()) end, "loot.prefetch") end
local generate_fn = function(self) util.safe(function() on_generated(self:get(), "init") end, "loot.generated") end
local request_fn = function(self, JigMpCompRef)
    util.safe(function() on_generated(JigMpCompRef:get(), "request") end, "loot.request")
end
local hook_fn = function(self, ItemUID) util.safe(on_removed, "loot.removed", self, ItemUID) end
-- Using an item straight out of a container (rip clothing, eat, drink, read, open a loot box...) consumes it:
-- the game fires only JigMP_OnItemConsumed, no removed event. The host kept the item and its next list put
-- it back on the guest's copy - every rip left the rags AND the clothes (report 20261027-171134). Sent the
-- next frame like a stack (the pre-hook may run before the count changes).
local eaten = {}
local consumed_fn = function(self, ConsumedItem)
    util.safe(function()
        if applying or not shared() then return end
        local actor, uid = self:get(), nil
        pcall(function() uid = uid_str(ConsumedItem:get()[UID]) end)
        if uid and util.valid(actor) then eaten[#eaten + 1] = { actor = actor, uid = uid } end
    end, "loot.consumed")
end
local function flush_eaten()
    if not eaten[1] then return end
    local list = eaten
    eaten = {}
    for _, e in ipairs(list) do
        if util.valid(e.actor) and is_main(e.actor) then removed(e.actor, e.uid) end
    end
end
-- Dropping an item out of a container (all of it or part of a stack) fires no "removed" event on the
-- container: the drop request on its component is the only sign.
local drop_fn = function(self, ItemUID)
    util.safe(function()
        local comp = util.obj(self)
        if not comp then return end
        local owner
        pcall(function() owner = comp:GetOwner() end)
        if not (util.valid(owner) and is_main(owner)) then return end
        on_removed({ get = function() return owner end }, ItemUID)
    end, "loot.dropped")
end
local main_removed_fn = function(self, FromContainerUID, ItemUID) util.safe(on_removed, "loot.main_removed", self, ItemUID) end
local main_added_fn = function(self, ToContainerUID, ItemUID, ToContainerName, ItemInfo)
    util.safe(on_added, "loot.added", self, ItemUID, ItemInfo)
end
local item_added_fn = function(self, ItemUID) util.safe(on_added, "loot.item_added", self, ItemUID, nil) end
local move_fn = function(self, ItemUID) util.safe(on_moved, "loot.moved", self, ItemUID) end
local stack_fn = function(self, FromCom, ToComp, DroppedUID, ReceiverUID)
    util.safe(on_stack, "loot.stack", FromCom, ToComp, DroppedUID, ReceiverUID)
end
local split_fn = function(self, FromComp, ToComp, ItemUID)
    util.safe(on_split, "loot.split", FromComp, ToComp, ItemUID)
end

-- Once per world, a few seconds in: weapons made without their stats by older versions get them.
local repair_in = 8.0
local JIG_CLASS
local function repair_player_stats()
    local p = game.player()
    if not util.valid(p) then repair_in = 5.0; return end
    local comp
    pcall(function() comp = p.BP_JigComponent end)
    if not util.valid(comp) then
        JIG_CLASS = util.valid(JIG_CLASS) and JIG_CLASS or StaticFindObject(JIG_COMP)
        pcall(function() comp = p:GetComponentByClass(JIG_CLASS) end)
    end
    if not util.valid(comp) then log.info("loot: stat repair skipped - no inventory component"); return end
    local n, names = jig.repair_stats(comp)
    if n > 0 then log.info("loot: gave " .. n .. " item(s) their missing stats: " .. table.concat(names, ", ")) end
    local twins = jig.twin_grids(comp)
    if twins > 0 then log.warn("loot: " .. twins .. " bag compartment(s) in the inventory exist twice - items in them may not show (drop the bag and pick it up)") end
end

local function retry_later()
    local list = later
    later = {}
    for _, x in ipairs(list) do
        local actor = find(x.id)
        if actor and comp_of(actor) then
            log.info("loot: the container for a kept " .. (x.k == "A" and "put-in" or "take") .. " is here now (" .. x.id .. ") - applying it")
            if x.k == "A" then apply_add(x.p) elseif x.k == "N" then apply_count(x.p) else apply(x.p) end
        elseif now - x.t > LATER_S then
            log.warn(string.format("loot: gave up on a kept %s for %s after %d s - that container never showed up here",
                x.k == "A" and "put-in" or "take", x.id, LATER_S))
            if x.k == "A" then
                local id, uid, da = x.p:match("^A (%S+) (%S+) (%S+)")
                if id then channel:send("R " .. id .. " " .. uid .. " " .. da) end
            end
        else
            local dup = false
            for _, y in ipairs(later) do if y.p == x.p then dup = true end end
            if not dup then later[#later + 1] = x end
        end
    end
end

function loot.tick(dt)
    if repair_in then
        repair_in = repair_in - dt
        if repair_in <= 0 then repair_in = nil; util.safe(repair_player_stats, "loot.repair_stats") end
    end
    if role == "off" then return end
    now = now + dt
    if role == "host" and later[1] then
        later_in = later_in - dt
        if later_in <= 0 then later_in = 1.0; crumb.at("loot: kept"); util.safe(retry_later, "loot.later") end
    end
    crumb.at("loot: ui")
    util.safe(jig.flush_ui, "jig.ui")
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 1.0
        crumb.at("loot: hooks")
        -- Blueprint hooks here are pre-hooks only (UE4SS 3.0.1 never runs the post callback).
        util.ensure_hook(GENERATE, generate_fn)
        util.ensure_hook(REQUEST, request_fn)
        for _, c in ipairs(PREFETCH) do
            util.ensure_hook(c .. ":OnBeginInteract", prefetch_fn)
            util.ensure_hook(c .. ":OnExecuteInteract", prefetch_fn)
        end
        util.ensure_hook(JIG_COMP .. ":HandleServerDropRequest", drop_fn)
        util.ensure_hook(JIG_COMP .. ":HandleSameContainerMoveToIndex", move_fn)
        util.ensure_hook(JIG_COMP .. ":SERVER_RequestStackItem", stack_fn)
        util.ensure_hook(JIG_COMP .. ":SERVER_RequestSplitItem", split_fn)
        for _, c in ipairs(MAIN) do
            util.ensure_hook(c .. ":JigMP_OnItemRemoved", hook_fn)
            util.ensure_hook(c .. ":JigMP_OnItemConsumed", consumed_fn)
            util.ensure_hook(c .. ":JigMP_OnItemAdded", item_added_fn)
            util.ensure_hook(c .. ":JigMP_OnMainContainerItemRemoved", main_removed_fn)
            util.ensure_hook(c .. ":JigMP_OnMainContainerItemAdded", main_added_fn)
        end
        if not shared() then
            alias, rev, added_once, put_sent, add_q, moved, move_q = {}, {}, {}, {}, {}, {}, {}
            pushed, push_q, host_list, opened, asked, synced, apply_q = {}, {}, {}, {}, {}, {}, {}
            pending, held, ack, main_by_class, first_seen = {}, {}, {}, {}, {}
            host_ack, recheck, reopened, list_at, asked_at, da_of = {}, {}, {}, {}, {}, {}
        end
    end
    crumb.at("loot: moves/adds")
    if round_at < 0 and not round_q and shared() then round_due = true end
    if round_due or round_q then util.safe(main_round_tick, "loot.main_classes") end
    util.safe(flush_stacks, "loot.stacks")
    util.safe(flush_eaten, "loot.consumed")
    util.safe(flush_moves, "loot.moves")
    util.safe(flush_adds, "loot.adds")
    if role == "host" then
        crumb.at("loot: push")
        util.safe(flush_pushes, "loot.push")
        crumb.at("loot: ahead")
        if ghost.get() then util.safe(ahead_tick, "loot.ahead", dt) end
    else
        crumb.at("loot: near")
        list_tick(dt)
        near_in = near_in - dt
        if near_in <= 0 then near_in = NEAR_EVERY; util.safe(near_ask, "loot.near") end
        crumb.at("loot: sync")
        -- only while the host's list already has all of this player's takes/puts (never undoes one)
        for id, at in pairs(recheck) do
            if now >= at then
                recheck[id] = nil
                if (pending[id] or 0) <= (host_ack[id] or 0) then util.safe(sync_from_host, "loot.recheck", id) end
            end
        end
        for id, at in pairs(apply_q) do
            if now >= at then apply_q[id] = nil; util.safe(sync_from_host, "loot.sync", id) end
        end
    end
    local function take_contents(p)
        if role == "host" or not shared() then return end
        local id, a, rest = p:match("^C (%S+) (%d+) ?(.*)$")
        if not id then return end
        host_list[id], host_ack[id], list_at[id] = jig.decode(rest), tonumber(a), now
        if (pending[id] or 0) <= tonumber(a) then util.safe(sync_from_host, "loot.sync", id) end
    end
    crumb.at("loot: messages")
    cchan:pump(take_contents)
    channel:pump(function(p)
        local k = p:sub(1, 2)
        if is_trade(p) then traded() end
        if k == "A " then util.safe(apply_add, "loot.apply_add", p)
        elseif k == "M " then util.safe(apply_move, "loot.apply_move", p)
        elseif k == "N " then util.safe(apply_count, "loot.apply_count", p)
        elseif k == "C " then take_contents(p)
        elseif k == "R " then
            if role ~= "host" and shared() then
                local id, uid, da = p:match("^R (%S+) (%S+) (%S+)$")
                if id then
                    held[id] = held[id] or {}
                    held[id][uid] = true
                    stats.rejected = (stats.rejected or 0) + 1
                    local name = (da:match("([%w_]+)$") or da):gsub("^DA_", "")
                    log.warn("loot: the host had no room for your " .. name .. " in " .. id .. " - it is only in your copy")
                    require("mirror.notify").show("The host's copy of that container had no room for your " .. name ..
                        ". Take it back out, or it stays only on your screen.", "bad", "loot_rejected")
                end
            end
        elseif k == "L " then
            if role ~= "host" and shared() then util.safe(give_back, "loot.give_back", p) end
        elseif k == "Q " then
            if role == "host" then
                local id = p:match("^Q (%S+)$")
                if id then util.safe(answer, "loot.answer", id) end
            end
        else util.safe(apply, "loot.apply", p) end
    end)
end

function loot.is_shared(actor) return is_main(actor) end
function loot.prefetch(actor) util.safe(prefetch, "loot.prefetch", actor) end

function loot.status()
    return string.format("loot: taken sent %d, applied %d | put in sent %d, added %d | contents sent %d (ahead %d), taken over %d, corrected %d, no room %d%s",
        stats.sent, stats.applied, stats.put, stats.added, stats.pushed or 0, stats.ahead or 0, stats.synced or 0,
        stats.fixed or 0, stats.rejected or 0, stats.missing > 0 and (", container not found " .. stats.missing) or "")
end


-- Respawn/reload: the old world's objects are freed - drop them without touching them.
local function forget_world()
    main_cls, main_by_class, first_seen, known, build, da_of = {}, {}, {}, {}, nil, {}
    round_at, round_q, round_due = -1, nil, false
    repair_in = 8.0
end
function loot.init(c, r, s)
    game.on_world_reset(forget_world)
    cfg, role, session = c, r, s
    if cfg.loot_sync == false then role = "off" end
    log.info("loot: " .. (role == "off" and "off" or "container contents are shared (taken + put in)"))
end

return loot
