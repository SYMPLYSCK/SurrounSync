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
local channel = events.new("loot", 64, 120)
-- Host -> guest full contents ("C <id> <ack> <items>"), kept apart so the event blob stays small.
local cchan = events.new("lootc", 16, 120)
local applying = false
local hook_in = 0.0
local stats = { sent = 0, applied = 0, missing = 0, put = 0, added = 0 }
-- The same item has a different id in each game: alias maps theirs to ours, rev ours to theirs.
local alias = {}
local rev = {}
local added_once = {}
local put_sent = {}
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
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local now = 0.0
local opened_at = {}
local pushed = {}
local push_q = {}
local host_list = {}
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

local function list_add(id, uid, da, count, dx, dy, inside)
    local list = host_list[id]
    if not list or synced[id] then return end
    for _, w in ipairs(list) do if w.uid == uid then return end end
    local at = #list + 1
    list[at] = { uid = uid, da = da, count = tonumber(count) or 1, dx = tonumber(dx) or 0, dy = tonumber(dy) or 0 }
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
-- Only items moving between players need a save soon: put-ins, and takes from player-built storage.
-- World loot doesn't (a crash just puts it back).
local function is_trade(p)
    if p:find("^A ") then return true end
    return p:find("^Buildable") ~= nil or p:find("^Vehicle") ~= nil
end
channel.send = function(self, p) if is_trade(p) then traded() end return events.send(self, p) end

local uid_str, guid, full_path = jig.uid_str, jig.guid, jig.full_path

local function id_of(actor)
    local cls = util.class_name(actor)
    local l = actor:K2_GetActorLocation()
    return string.format("%s@%d,%d,%d", cls, math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5), math.floor(l.Z / 10 + 0.5))
end

local function comp_of(actor)
    local c
    pcall(function() c = actor.BP_JigMultiplayer end)
    return util.valid(c) and c or nil
end

local function count_of(comp, uid)
    local n = 0
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            c:get()[ITEMS]:ForEach(function(_, it)
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

local function on_removed(self, ItemUID)
    if applying or not shared() then return end
    local actor = self:get()
    local comp = comp_of(actor)
    if not comp then return end
    local uid
    pcall(function() uid = uid_str(ItemUID:get()) end)
    if not uid then return end
    local ok, id = pcall(id_of, actor)
    if not ok then return end
    local left = count_of(comp, uid)
    channel:send(string.format("%s %s %d %d", id, rev[uid] or uid, left, next_seq(id)))
    stats.sent = stats.sent + 1
    if left == 0 then release(id, uid) end
    mark_dirty(id, comp)
    if left == 0 then forget(uid, rev[uid]) end
    log.debug(string.format("loot: took %s from %s (%d left there)", uid, id, left))
end

local function find(id) return util.find_by_id(id, 100) end

local function acked(id, s, comp)
    s = tonumber(s)
    if role ~= "host" or not s then return end
    if s > (ack[id] or 0) then ack[id] = s end
    mark_dirty(id, comp)
end

local function apply(payload)
    if not shared() then return end
    local id, uid, left, s = payload:match("^(%S+) (%S+) (%d+) ?(%d*)$")
    if not id then return end
    list_take(id, uid, tonumber(left) or 0)
    local actor = find(id)
    local comp = actor and comp_of(actor)
    if not comp then stats.missing = stats.missing + 1; return end
    acked(id, s, comp)
    local theirs = uid
    local have = count_of(comp, uid)
    if have == 0 and alias[uid] then uid = alias[uid]; have = count_of(comp, uid) end
    if tonumber(left) == 0 then forget(uid ~= theirs and uid or nil, theirs) end
    local take = have - (tonumber(left) or 0)
    if take <= 0 then return end
    applying = true
    local ok, err = pcall(function() comp:HandleLocalRequestConsumeItem(guid(uid), take, comp, "", false) end)
    applying = false
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
    put_sent[uid] = now
    local ok, id = pcall(id_of, actor)
    if not ok then return end
    local inside = jig.subtree(comp, uid)
    channel:send(string.format("A %s %s %s %d %.3f %.3f %d", id, uid, da, count or 1, dur and dur.X or 0, dur and dur.Y or 0, next_seq(id))
        .. ((inside and #inside > 1) and (" " .. jig.encode(inside)) or ""))
    mark_dirty(id, comp)
    stats.put = stats.put + 1
    log.info(string.format("loot: put %s x%d into %s - telling the other game", da:match("[^%.]+$") or da, count or 1, id))
end

local function apply_add(payload)
    if not shared() then return end
    local id, uid, da, count, dx, dy, s, inside = payload:match("^A (%S+) (%S+) (%S+) (%-?%d+) (%S+) (%S+) (%d+) ?(%S*)$")
    if not id then return end
    local actor = find(id)
    local comp = actor and comp_of(actor)
    if added_once[uid] then if comp then acked(id, s, comp) end return end
    if not comp then
        stats.missing = stats.missing + 1
        log.info("loot: the other player put something into " .. id .. " - not here")
        if role == "host" then channel:send("R " .. id .. " " .. uid .. " " .. da) end
        return
    end
    if count_of(comp, uid) > 0 or (alias[uid] and count_of(comp, alias[uid]) > 0) then added_once[uid] = true; acked(id, s, comp); return end
    local asset = StaticFindObject(da)
    if not util.valid(asset) then
        log.info("loot: the other player put " .. (da:match("[^%.]+$") or da) .. " into " .. id .. " - not loaded here")
        if role == "host" then channel:send("R " .. id .. " " .. uid .. " " .. da) end
        return
    end
    local slots = 0
    pcall(function() slots = comp.MainJigContainers:GetArrayNum() end)
    if role ~= "host" then list_add(id, uid, da, count, dx, dy, inside) end
    if role ~= "host" and slots == 0 then
        added_once[uid] = true
        log.info(string.format("loot: the other player put %s into %s - not opened here yet, it'll be there when opened",
            da:match("[^%.]+$") or da, id))
        return
    end
    applying = true
    local mine, err = jig.add_item(comp, da, tonumber(count) or 1, tonumber(dx) or 0, tonumber(dy) or 0)
    applying = false
    if not mine then
        log.warn("loot: couldn't add the other player's " .. (da:match("[^%.]+$") or da) .. " to " .. id .. ": " .. tostring(err))
        if role == "host" then channel:send("R " .. id .. " " .. uid .. " " .. da) end
        return
    end
    acked(id, s, comp)
    added_once[uid] = true
    alias[uid], rev[mine] = mine, uid
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

local main_cls, main_miss = {}, {}
-- Answer per class (by class address): saves up to 12 IsA calls per actor.
local main_by_class = {}
local function is_main_uncached(actor)
    for _, p in ipairs(MAIN) do
        local c = main_cls[p]
        if not util.valid(c) and os.clock() >= (main_miss[p] or 0) then
            c = StaticFindObject(p)
            if util.valid(c) then main_cls[p] = c else main_cls[p], main_miss[p] = nil, os.clock() + 10 end
        end
        local yes = false
        if util.valid(c) then pcall(function() yes = actor:IsA(c) == true end) end
        if yes then return true end
    end
    return false
end
local function is_main(actor)
    local cls
    pcall(function() cls = actor:GetClass() end)
    local a = util.addr(cls)
    if not a then return is_main_uncached(actor) end
    local r = main_by_class[a]
    if r == nil then
        r = is_main_uncached(actor)
        local all_found = true
        for _, p in ipairs(MAIN) do if not util.valid(main_cls[p]) then all_found = false; break end end
        if r or all_found then main_by_class[a] = r end
    end
    return r
end

local function sync_from_host(id)
    local comp, list = opened[id], host_list[id]
    if not (comp and list) or not util.valid(comp) then return end
    if held[id] then return end
    local first = not synced[id]
    synced[id] = true
    applying = true
    local ok, set, added, removed, missing, pairs_ = pcall(jig.apply_contents, comp, list)
    applying = false
    if not ok then log.warn("loot: couldn't take over the host's contents of " .. id .. ": " .. tostring(set)); return end
    for _, p in ipairs(pairs_) do
        if p.want.uid then alias[p.want.uid], rev[p.uid] = p.uid, p.want.uid end
    end
    stats.synced = (stats.synced or 0) + 1
    if not first then
        if added + removed > 0 then
            stats.fixed = (stats.fixed or 0) + 1
            log.info(string.format("loot: %s corrected to the host's contents (%d added, %d removed%s)", id, added, removed,
                missing > 0 and (", " .. missing .. " not loaded here") or ""))
        end
        return
    end
    if added + removed > 0 and now - (opened_at[id] or -100) < 5.0 then
        local owner
        pcall(function() owner = comp:GetOwner() end)
        if util.valid(owner) then pcall(function() game.player():RequestServerData(comp, {}) end) end
        require("mirror.notify").show("This container was just updated to match the host - close it and open it again.", "info")
    end
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
    if role == "host" then
        -- Every generation, not just the first: some containers (shops) roll new stock after a while.
        pushed[id] = true
        push_q[id] = { comp = comp, at = now + 0.3 }
    elseif not opened[id] then
        opened[id], opened_at[id] = comp, now
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
            if util.valid(q.comp) then
                cchan:send("C " .. id .. " " .. (ack[id] or 0) .. " " .. jig.encode(jig.contents_of(q.comp), true))
                stats.pushed = (stats.pushed or 0) + 1
            end
        end
    end
end

local LIST_EVERY, SCAN_EVERY, AHEAD_M, AHEAD_STEP = 120.0, 2.0, 35, 0.15
local ahead, ahead_scan_in, ahead_step_in = {}, 0.0, 0.0
local known, list_in = {}, 0.0
local function list_containers()
    known, main_by_class = {}, {}
    local g = ghost.get()
    for _, comp in ipairs(FindAllOf("BP_JigComponent_C") or {}) do
        local owner
        pcall(function() owner = comp:GetOwner() end)
        if util.valid(owner) and not util.same(owner, g) and not util.same(owner, game.player()) and is_main(owner) then
            local ok, id = pcall(id_of, owner)
            local l
            pcall(function() l = util.vec(owner:K2_GetActorLocation()) end)
            if ok and l then known[#known + 1] = { id = id, comp = comp, loc = l } end
        end
    end
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
local function ahead_tick(dt)
    list_in = list_in - dt
    if list_in <= 0 then list_in = LIST_EVERY; util.safe(list_containers, "loot.list") end
    ahead_scan_in = ahead_scan_in - dt
    if ahead_scan_in <= 0 then ahead_scan_in = SCAN_EVERY; util.safe(ahead_scan, "loot.ahead_scan") end
    ahead_step_in = ahead_step_in - dt
    if ahead_step_in > 0 or #ahead == 0 then return end
    ahead_step_in = AHEAD_STEP
    local e = table.remove(ahead)
    if pushed[e.id] or not util.valid(e.comp) then return end
    jig.generate(e.comp)
    pushed[e.id] = true
    push_q[e.id] = { comp = e.comp, at = now + 0.3 }
    stats.ahead = (stats.ahead or 0) + 1
end

function loot.guest_arriving()
    pushed, push_q, ahead, ahead_scan_in, list_in = {}, {}, {}, 0.0, 0.0
    alias, rev, added_once, put_sent, ack = {}, {}, {}, {}, {}
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
    if not ok or asked[id] or host_list[id] then return end
    asked[id] = true
    channel:send("Q " .. id)
end
local prefetch_fn = function(self) util.safe(function() prefetch(self:get()) end, "loot.prefetch") end
local generate_fn = function(self) util.safe(function() on_generated(self:get(), "init") end, "loot.generated") end
local request_fn = function(self, JigMpCompRef)
    util.safe(function() on_generated(JigMpCompRef:get(), "request") end, "loot.request")
end
local hook_fn = function(self, ItemUID) util.safe(on_removed, "loot.removed", self, ItemUID) end
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

function loot.tick(dt)
    if role == "off" then return end
    now = now + dt
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 1.0
        -- Blueprint hooks here are pre-hooks only (UE4SS 3.0.1 never runs the post callback).
        util.ensure_hook(GENERATE, generate_fn)
        util.ensure_hook(REQUEST, request_fn)
        for _, c in ipairs(PREFETCH) do
            util.ensure_hook(c .. ":OnBeginInteract", prefetch_fn)
            util.ensure_hook(c .. ":OnExecuteInteract", prefetch_fn)
        end
        util.ensure_hook(JIG_COMP .. ":HandleServerDropRequest", drop_fn)
        for _, c in ipairs(MAIN) do
            util.ensure_hook(c .. ":JigMP_OnItemRemoved", hook_fn)
            util.ensure_hook(c .. ":JigMP_OnItemAdded", item_added_fn)
            util.ensure_hook(c .. ":JigMP_OnMainContainerItemRemoved", main_removed_fn)
            util.ensure_hook(c .. ":JigMP_OnMainContainerItemAdded", main_added_fn)
        end
        if not shared() then
            alias, rev, added_once, put_sent = {}, {}, {}, {}
            pushed, push_q, host_list, opened, asked, synced, apply_q = {}, {}, {}, {}, {}, {}, {}
            pending, held, ack, main_by_class = {}, {}, {}, {}
        end
    end
    if role == "host" then
        util.safe(flush_pushes, "loot.push")
        if ghost.get() then util.safe(ahead_tick, "loot.ahead", dt) end
    else
        for id, at in pairs(apply_q) do
            if now >= at then apply_q[id] = nil; util.safe(sync_from_host, "loot.sync", id) end
        end
    end
    local function take_contents(p)
        if role == "host" or not shared() then return end
        local id, a, rest = p:match("^C (%S+) (%d+) ?(.*)$")
        if not id then return end
        host_list[id] = jig.decode(rest)
        if (pending[id] or 0) <= tonumber(a) then util.safe(sync_from_host, "loot.sync", id) end
    end
    cchan:pump(take_contents)
    channel:pump(function(p)
        local k = p:sub(1, 2)
        if is_trade(p) then traded() end
        if k == "A " then util.safe(apply_add, "loot.apply_add", p)
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

function loot.init(c, r, s)
    cfg, role, session = c, r, s
    if cfg.loot_sync == false then role = "off" end
    log.info("loot: " .. (role == "off" and "off" or "container contents are shared (taken + put in)"))
end

return loot
