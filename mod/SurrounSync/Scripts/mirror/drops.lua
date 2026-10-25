-- Items dropped on the ground show up for the other player, and picking one up removes it there.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local events = require("mirror.events")
local jig = require("mirror.jig")
local names = require("mirror.names")

local drops = {}

local PLAYER = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"
local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local ITEM_ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local DURABILITY = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local UID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local PICKUP_REF = "PickupRef_20_A3E97763428AC84AF4DBB8A56CFAC657"
local ROTATED = "Rotated_9_3CFE5D9342A81FB1FF17DEB7B491CE56"
local ITEM_VEC = "ItemVec_13_4DB12E4E4F80730BD25ACFA6FA51AD0A"
local WEIGHT = "Weight_16_C6B7568A4E062D2AE81209916A32B4EB"
local PRICE = "Price_19_FEFE0D2A4561BAF04CE37D9BAE1D6EF7"
local PENDING = "Pending?_31_C3AE39044666796C0FA128BA521590CB"
local IS_CONTAINER = "IsContainer_14_0198F62E4F1B93DD8B4D6E92B7E3EA45"
local MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D"
local SLOT_INDEX = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local IN_INDEX = "InContainerIndex_31_A61F5C3A47C8E761BA5CF0ADA1DF9FDE"

local cfg, role, session
local channel = events.reliable("drops")
local peers = require("mirror.peers")
-- More than two players (host): a dropped item lies once in the host's world, held by the copy of this module
-- of whoever dropped it. A "T" (picked up) that this copy sends goes to the other guests as well.
channel.send = function(self, p)
    local r = events.send(self, p)
    if p:sub(1, 2) == "T " and not peers.relaying() then
        peers.relay("mirror.drops", drops, function(m) m.relay_take(p) end)
    end
    return r
end
local tracked = {}
local seen = {}
local copies = {}
local alias = {}
local finish = {}
local contents = {}
local finished = {}
-- A loose magazine's pickup class has no container settings, so its copy here has no grid for the rounds
-- (the game builds the mag's capacity container only when it goes into an inventory). unfilled[uid] = the
-- item list the copy couldn't hold; when it's picked up here the list goes into the new inventory item.
local unfilled = {}
local refill = {}
-- The game's own pickup of a mag copy ran none of the pickup hooks (2026-10-24 in-game): it was only seen
-- as "gone" from the ground. held[uid] = the inventory items of the copy's kind while it lies near the
-- player, so the new one can be told apart when it goes.
local held = {}
local ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local now = 0.0
local check_in = 0.0
local stats = { sent = 0, made = 0, removed = 0, forced = 0 }

local full_path, uid_str, guid = jig.full_path, jig.uid_str, jig.guid

local ended = {}
local PICKUP_COMP = "/Game/JigSInventory/Jigsaw/Pickup/BP_JigPickupComponent.BP_JigPickupComponent_C"
local BEACON = "/Game/Blueprints/HordeSystem/Beacon/Buildable_HordeBeacon.Buildable_HordeBeacon_C"

local function alive(a)
    if not util.valid(a) then return false end
    if ended[util.addr(a) or 0] then return false end
    local ksl = util.cdo(KSL)
    if not ksl then return true end
    local ok, r = pcall(function() return ksl:IsValid(a) end)
    if not ok or r ~= true then return false end
    local dying = false
    pcall(function() dying = a:IsActorBeingDestroyed() == true end)
    return not dying
end

local function on_ground(a)
    if not alive(a) then return false, "gone" end
    local parent, hidden
    pcall(function() parent = a:GetAttachParentActor() end)
    if util.valid(parent) then return false, "attached to " .. (util.class_name(parent) or "?") end
    pcall(function() hidden = a.bHidden == true end)
    if hidden then return false, "hidden" end
    return true
end

local function tracked_uid(actor)
    if not util.valid(actor) then return nil end
    for uid, a in pairs(tracked) do
        if util.same(a, actor) then return uid end
    end
    return nil
end

local world_stats = { sent = 0, removed = 0, missing = 0 }

local resend, sent_list
local function forget(uid)
    local a = tracked[uid]
    if a then ended[util.addr(a) or 0] = nil end
    tracked[uid], copies[uid], seen[uid], resend[uid], sent_list[uid], held[uid] = nil, nil, nil, nil, nil, nil
    unfilled[uid] = nil
end

local function jig_of(actor)
    local cls = util.find(JIG)
    if not cls then return nil end
    local c
    pcall(function() c = actor:GetComponentByClass(cls) end)
    return util.valid(c) and c or nil
end

local function item_of(actor)
    local da
    pcall(function()
        local c = actor:GetComponentByClass(util.find(PICKUP_COMP))
        da = full_path(c.ItemDataAsset)
    end)
    if not da then
        pcall(function() da = full_path(jig_of(actor).PickupInfo[INFO][ITEM_ID]) end)
    end
    return da
end

local contents_of = jig.contents_of
local function describe(list)
    local out = {}
    for _, h in ipairs(list) do
        out[#out + 1] = string.format("%s x%d%s @%s", (h.da or "?"):match("[^%.]+$") or "?", h.count or 1,
            h.parent and (" in " .. h.parent) or "", tostring(h.slot))
    end
    return table.concat(out, ", ")
end
-- What the copy holds after the other game's list went on is the parts check's baseline: a fresh copy
-- spawns with the item's default parts and the check could look before the list lands - that landing
-- isn't a change made here (in-game the guest sent the host's own parts back).
local function apply_contents(uid, comp, want, what)
    local set, added, removed, missing = jig.apply_contents(comp, want)
    local now_in = contents_of(comp)
    log.info(string.format("drops: %s contents - %d set, %d added, %d extra removed, %d missing (of %d) - now [%s]", what,
        set, added, removed, missing, #want, describe(now_in)))
    pcall(function() sent_list[uid] = jig.encode(now_in) end)
    return set + added, missing
end

-- the copy of uid (actor) holds nothing of its list: keep the list for the pickup, show the round count on the ground
local function note_unfilled(uid, actor, placed, missing)
    if not (placed == 0 and missing > 0) then unfilled[uid] = nil; return end
    local list = contents[uid]
    if unfilled[uid] == list then return end
    unfilled[uid] = list
    local n = 0
    for _, w in ipairs(list) do if not w.parent then n = n + (w.count or 1) end end
    pcall(function() actor:GetComponentByClass(util.find(PICKUP_COMP)).RepCapacity = n end)
    log.info(string.format("drops: the copy has no container for its %d item(s) (%d inside) - they go into it when it's picked up here",
        #list, n))
end

local function shared() return role == "host" or (session and session.in_world()) end
local function traded() if session and session.checkpoint and shared() then session.checkpoint("drops") end end
channel.send = function(self, p) if p:find("^[DT] ") then traded() end return events.send(self, p) end

-- " <name>" when the item has a custom name (names.lua), else ""
local function name_field(uid)
    local n = uid and names.get(uid)
    return n and (" " .. names.encode(n)) or ""
end

local function send_drop(pickup, own_uid)
    if util.valid(pickup) then util.safe(require("mirror.itemclean").mark, "drops.clean_mark", pickup) end
    if not shared() or not util.valid(pickup) then return end
    if tracked_uid(pickup) then return end
    local comp = jig_of(pickup)
    if not comp then log.warn("drops: dropped pickup has no Jig component"); return end
    local da, count, dur, uid
    local vec, weight, price = { X = 0, Y = 0 }, 0, 0
    pcall(function()
        local info = comp.PickupInfo
        da = full_path(info[INFO][ITEM_ID])
        count = info[INFO][COUNT]
        local d = info[INFO][DURABILITY]
        dur = { X = d.X, Y = d.Y }
        uid = uid_str(info[UID])
    end)
    pcall(function()
        local info = comp.PickupInfo[INFO]
        local v = info[ITEM_VEC]
        vec = { X = v.X, Y = v.Y }
        weight, price = info[WEIGHT] or 0, info[PRICE] or 0
    end)
    if own_uid and (not uid or uid == "0_0_0_0") then uid = own_uid end
    if not da then da = item_of(pickup) end
    if not (da and uid) then log.warn("drops: couldn't read the dropped item's info"); return end
    if tracked[uid] and alive(tracked[uid]) then return end
    local l, r
    pcall(function() l = pickup:K2_GetActorLocation(); r = pickup:K2_GetActorRotation() end)
    if not l then return end
    tracked[uid] = pickup
    channel:send(string.format("D %s %s %d %.3f %.3f %.1f %.1f %.1f %.1f %.1f %.1f %.0f %.0f %.4f %.2f", uid, da,
        count or 1, dur and dur.X or 0, dur and dur.Y or 0, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll,
        vec.X or 0, vec.Y or 0, weight, price) .. name_field(uid))
    local inside, line, n = contents_of(comp), {}, 0
    for i, h in ipairs(inside) do
        local par = h.parent and line[h.parent]
        if h.da and (par or not h.parent) then
            n = n + 1
            line[i] = n
            channel:send(string.format("I %s %s %d %.3f %.3f %d %d", uid, h.da, h.count, h.dx, h.dy, par or 0, h.slot or 0)
                .. name_field(h.uid))
        end
    end
    stats.sent = stats.sent + 1
    log.info(string.format("drops: dropped %s x%d%s - sent", da:match("[^%.]+$") or da, count or 1,
        #inside > 0 and (" (holding " .. describe(inside) .. ")") or ""))
end

-- Dropping takes the item out with RemoveGetInfo, which gives it (and all it holds) new UIDs: a custom name
-- goes over to the new ones before the drop is sent.
local function carry_name(item_uid, pickup)
    local old, new, comp
    pcall(function() local g = item_uid:get(); old = uid_str(g) end)
    if not old or old == "0_0_0_0" or not util.valid(pickup) then return end
    comp = jig_of(pickup)
    pcall(function() new = uid_str(comp.PickupInfo[UID]) end)
    if new and new ~= old then names.moved(old, new, comp) end
end

local function on_dropped(self, ItemUID, FromContainerUID, ActorRef)
    if not util.same(self:get(), game.player()) then return end
    local pickup = util.obj(ActorRef)
    carry_name(ItemUID, pickup)
    send_drop(pickup)
end

-- Drops from a container or of part of a stack never reach the player's OnItemDropped: the game tells the
-- container instead, or nobody. Every drop path fills the spawned pickup with SetPickupContainerData and then
-- returns from the drop request, so pickups filled during a drop request are this player's drops.
local filled = {}
local function on_filled(self)
    local comp = util.obj(self)
    if not comp then return end
    local owner
    pcall(function() owner = comp:GetOwner() end)
    if util.valid(owner) then filled[#filled + 1] = { actor = owner, at = now } end
end
local function on_drop_request(item_uid)
    local list = filled
    filled = {}
    for _, f in ipairs(list) do
        if f.at == now then
            if item_uid then carry_name(item_uid, f.actor) end
            send_drop(f.actor)
        end
    end
end

-- The horde beacon's final-wave rewards (SpawnRewards) are plain pickups spawned with no owner, so no drop
-- path sees them. Their components begin play inside SpawnRewards: pickups begun in the same frame as the
-- SpawnRewards hook are the rewards. They're sent like drops a moment later (count set, info filled); world
-- pickups can carry a zero UID, so a reward without one gets a made-up one.
local begun, rewards = {}, {}
local function on_pickup_begin(self)
    local comp = util.obj(self)
    if not comp then return end
    local owner
    pcall(function() owner = comp:GetOwner() end)
    if util.valid(owner) then begun[#begun + 1] = { actor = owner, at = now } end
end
local function on_rewards()
    if not shared() then return end
    local n = 0
    for _, b in ipairs(begun) do
        if b.at == now then
            n = n + 1
            rewards[#rewards + 1] = { actor = b.actor, at = now + 0.5 }
        end
    end
    begun = {}
    log.info(string.format("drops: horde beacon rewards spawned here (%d) - sending them", n))
end
local function send_rewards()
    local keep = {}
    for _, r in ipairs(rewards) do
        if now < r.at then keep[#keep + 1] = r
        elseif on_ground(r.actor) then
            send_drop(r.actor, string.format("%d_%d_%d_%d", math.random(1, 2147483646), math.random(1, 2147483646),
                math.random(1, 2147483646), math.random(1, 2147483646)))
        end
    end
    rewards = keep
end

local function make(payload)
    local uid, da, count, dx, dy, x, y, z, pi, ya, ro, vx, vy, wt, pr =
        payload:match("^D (%S+) (%S+) (%-?%d+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)")
    local dname = payload:match("^D" .. string.rep(" %S+", 15) .. " (%S+)$")
    if uid and dname then names.set(uid, names.decode(dname), true) end
    if not uid then return end
    if not shared() then return end
    if tracked[uid] and alive(tracked[uid]) then return end
    local asset = util.find(da)
    if not asset then
        log.info("drops: the other player dropped " .. (da:match("[^%.]+$") or da) .. " - not loaded here, not shown")
        return
    end
    local cls
    pcall(function() cls = asset.PickupClass end)
    if not util.valid(cls) then log.warn("drops: " .. da .. " has no PickupClass"); return end
    local world = game.world()
    local pickup
    log.info("drops: spawning the other player's drop " .. (da:match("[^%.]+$") or da))
    local ok, err = pcall(function()
        pickup = world:SpawnActor(cls, { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) },
            { Pitch = tonumber(pi), Yaw = tonumber(ya), Roll = tonumber(ro) })
    end)
    if not (ok and util.valid(pickup)) then log.warn("drops: spawn failed: " .. tostring(err)); return end
    local is_container = false
    pcall(function() is_container = asset["IsContainer?"] == true end)
    local comp = jig_of(pickup)
    if is_container then
        finish[#finish + 1] = { actor = pickup, uid = uid, count = tonumber(count) or 1, dx = tonumber(dx) or 0,
                                dy = tonumber(dy) or 0, at = now + 0.5 }
    elseif comp then
        local size = { X = tonumber(vx) or 0, Y = tonumber(vy) or 0 }
        local weight, price = tonumber(wt), tonumber(pr)
        if size.X <= 0 or size.Y <= 0 then
            pcall(function() local v = asset.SlotDimensions; size = { X = v.X, Y = v.Y } end)
        end
        if not weight then pcall(function() weight = asset.Weight end) end
        if not price then pcall(function() price = asset.Price end) end
        local okw, errw = pcall(function()
            local info = comp.PickupInfo
            info[INFO][ITEM_ID] = asset
            info[INFO][COUNT] = tonumber(count) or 1
            info[INFO][DURABILITY] = { X = tonumber(dx) or 0, Y = tonumber(dy) or 0 }
            info[INFO][ITEM_VEC] = size
            info[INFO][WEIGHT] = weight or 0
            info[INFO][PRICE] = price or 0
            info[INFO][PENDING] = -1.0
            info[UID] = guid(uid)
            info[IS_CONTAINER] = false
            info[MOTHER] = { A = 0, B = 0, C = 0, D = 0 }
            info[SLOT_INDEX] = 0
            info[IN_INDEX] = 0
            info[PICKUP_REF] = pickup
            info[ROTATED] = false
        end)
        if not okw then log.warn("drops: couldn't write the item info: " .. tostring(errw)) end
        local ns, errs = nil, nil
        pcall(function() ns, errs = jig.write_stats(comp.PickupInfo[INFO], asset) end)
        if ns == nil then log.warn("drops: couldn't give the copy its stats (it may do nothing when used): " .. tostring(errs)) end
        pcall(function()
            local i = comp.PickupInfo[INFO]
            local v = i[ITEM_VEC]
            log.info(string.format("drops: copy info - size %sx%s, weight %s, pending %s, count %s",
                tostring(v.X), tostring(v.Y), tostring(i[WEIGHT]), tostring(i[PENDING]), tostring(i[COUNT])))
        end)
    end
    tracked[uid] = pickup
    copies[uid] = { da = da }
    stats.made = stats.made + 1
end

local function take_content(payload)
    local uid, da, count, dx, dy, rest = payload:match("^I (%S+) (%S+) (%-?%d+) (%S+) (%S+) ?(.*)$")
    if not uid then return end
    local par, slot, nm = (rest or ""):match("^(%d+) (%-?%d+) ?(%S*)$")
    local list = contents[uid] or {}
    list[#list + 1] = { da = da, count = tonumber(count) or 1, dx = tonumber(dx) or 0, dy = tonumber(dy) or 0,
                        parent = par ~= "0" and tonumber(par) or nil, slot = tonumber(slot),
                        name = nm and nm ~= "" and names.decode(nm) or nil }
    contents[uid] = list
    local a = finished[uid]
    if a and alive(a) then
        local comp = jig_of(a)
        if comp then note_unfilled(uid, a, apply_contents(uid, comp, list, da:match("[^%.]+$") or da)) end
    end
end

-- An attachment put on (or taken off) a weapon lying on the ground is a comp-to-comp move into (out of) the
-- pickup's own Jig component: nothing is dropped or picked up, so the other game's copy kept the old parts.
-- After such a move the dropped item's whole contents go over again ("C <uid> <list>").
resend, sent_list = {}, {}
local applying = false
local function on_comp_move(From, To)
    if applying or not shared() then return end
    for _, c in ipairs({ From, To }) do
        local owner
        pcall(function() owner = c:GetOwner() end)
        local uid = tracked_uid(owner)
        if uid then resend[uid] = now + 0.3 end
    end
end
local function send_contents()
    for uid, at in pairs(resend) do
        if now >= at then
            resend[uid] = nil
            local a = tracked[uid]
            local comp = alive(a) and jig_of(a)
            if comp then
                local inside = contents_of(comp)
                local line = jig.encode(inside)
                if line ~= sent_list[uid] then
                    sent_list[uid] = line
                    channel:send("C " .. uid .. " " .. line)
                    log.info(string.format("drops: a dropped item's parts changed here - now [%s], sent", describe(inside)))
                end
            end
        end
    end
end
-- The move hook above never fired in a real game (no "parts changed" in any log), so dropped items near
-- the player are also compared with their last known parts list every check (0.5 s). The first look
-- only records the list; a later difference goes over like a hooked move.
local PARTS_NEAR_CM = 400
local function poll_parts(uid, a, pl)
    local l
    pcall(function() l = util.vec(a:K2_GetActorLocation()) end)
    if not (l and util.dist(l, pl) <= PARTS_NEAR_CM) then return end
    local comp = jig_of(a)
    if not comp then return end
    local line = jig.encode(contents_of(comp))
    if sent_list[uid] == nil then sent_list[uid] = line
    elseif line ~= sent_list[uid] and not resend[uid] then resend[uid] = now end
end
local function take_changed(payload)
    local uid, line = payload:match("^C (%S+) ?(.*)$")
    if not uid then return end
    local list = jig.decode(line)
    contents[uid], sent_list[uid] = list, nil
    local a = finished[uid] or tracked[uid]
    local comp = alive(a) and jig_of(a)
    if not comp then return end
    applying = true
    local ok, placed, missing = pcall(apply_contents, uid, comp, list, "changed parts")
    applying = false
    if ok then note_unfilled(uid, a, placed, missing) end
end

local function remove_world(payload)
    if not shared() then return end
    local cls, x, y, z, da = payload:match("^W (%S+) (%S+) (%S+) (%S+) (%S+)$")
    if not cls then return end
    local at = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    local best, best_d = nil, 60
    for _, o in ipairs(FindAllOf(cls) or {}) do
        if on_ground(o) and not tracked_uid(o) then
            local l
            pcall(function() l = util.vec(o:K2_GetActorLocation()) end)
            local d = l and util.dist(l, at)
            if d and d < best_d and item_of(o) == da then best, best_d = o, d end
        end
    end
    if best then
        pcall(function() best:K2_DestroyActor() end)
        ended[util.addr(best) or 0] = true
        world_stats.removed = world_stats.removed + 1
        log.info(string.format("drops: the other player picked up %s - removed here (%.0f cm off)",
            da:match("[^%.]+$") or da, best_d))
    else
        world_stats.missing = world_stats.missing + 1
        log.info("drops: the other player picked up " .. (da:match("[^%.]+$") or da) .. " - not lying here")
    end
end

local function remove(payload)
    local uid = payload:match("^T (%S+)$")
    local a = uid and tracked[uid]
    if a and on_ground(a) then
        pcall(function() a:K2_DestroyActor() end)
        stats.removed = stats.removed + 1
        log.info("drops: the other player picked up a dropped item - removed here")
    end
    if uid then forget(uid) end
end

local function finish_copies()
    local keep = {}
    for _, f in ipairs(finish) do
        if now < f.at then
            keep[#keep + 1] = f
        elseif alive(f.actor) then
            local comp = jig_of(f.actor)
            local ok, err = comp ~= nil, "no Jig component (gone)"
            if comp then ok, err = pcall(function()
                local info = comp.PickupInfo
                alias[uid_str(info[UID])] = f.uid
                info[INFO][COUNT] = f.count
                info[INFO][DURABILITY] = { X = f.dx, Y = f.dy }
            end) end
            if not ok then log.warn("drops: couldn't finish a container copy: " .. tostring(err)) end
            finished[f.uid] = f.actor
            if comp then note_unfilled(f.uid, f.actor, apply_contents(f.uid, comp, contents[f.uid] or {}, "copy")) end
        end
    end
    finish = keep
end

local picking = nil
function drops.tracks(actor) return tracked_uid(actor) ~= nil end
local function other_tracks(actor)
    local hit = false
    peers.each("mirror.drops", function(m) if m ~= drops and not hit and m.tracks(actor) then hit = true end end)
    return hit
end

-- A copy with unfilled contents was picked up here (uid = its drop uid, item = the new inventory item's uid if known).
local function queue_refill(uid, item, before)
    local list = uid and unfilled[uid]
    if not list then return end
    unfilled[uid] = nil
    refill[#refill + 1] = { uid = uid, item = item, da = copies[uid] and copies[uid].da, list = list, before = before,
                            at = now + 0.3 }
end
local function inventory() local c; pcall(function() c = game.player().BP_JigMultiplayer end); return util.valid(c) and c or nil end
local function do_refill(r)
    local pc = inventory()
    if not pc then return end
    local all, target = contents_of(pc), nil
    local holds = {}
    for _, h in ipairs(all) do if h.parent then holds[h.parent] = true end end
    for i, h in ipairs(all) do
        if h.da == r.da and not holds[i] then
            if h.uid == r.item then target = h; break end
            if not (r.before and r.before[h.uid]) then target = h end
        end
    end
    if not target then log.warn("drops: picked-up copy not found in the inventory - its contents couldn't be put back"); return end
    local fl = { { da = r.da } }
    for _, w in ipairs(r.list) do
        fl[#fl + 1] = { da = w.da, count = w.count, dx = w.dx, dy = w.dy, slot = w.slot, name = w.name,
                        parent = w.parent and (w.parent + 1) or 1 }
    end
    local added, missing = jig.fill(pc, target.uid, fl)
    log.info(string.format("drops: put the picked-up copy's contents into it - %d added, %d missing", added, missing))
end
local NEAR_CM = 600
local function note_held()
    local pc, pl = inventory(), nil
    pcall(function() pl = util.vec(game.player():K2_GetActorLocation()) end)
    if not (pc and pl) then return end
    local all
    for uid in pairs(unfilled) do
        local a, l = tracked[uid], nil
        pcall(function() l = util.vec(a:K2_GetActorLocation()) end)
        local da = copies[uid] and copies[uid].da
        if da and l and util.dist(l, pl) < NEAR_CM then
            all = all or contents_of(pc)
            local set = {}
            for _, h in ipairs(all) do if h.da == da then set[h.uid] = true end end
            held[uid] = set
        else
            held[uid] = nil
        end
    end
end
local function run_refills()
    local keep = {}
    for _, r in ipairs(refill) do
        if now < r.at then keep[#keep + 1] = r else util.safe(do_refill, "drops.refill", r) end
    end
    refill = keep
end
local function send_world(actor, cls, l, da)
    if not (cls and l and da) then return end
    channel:send(string.format("W %s %.1f %.1f %.1f %s", cls, l.X, l.Y, l.Z, da))
    world_stats.sent = world_stats.sent + 1
    log.info("drops: picked up a world item (" .. (da:match("[^%.]+$") or da) .. ") - telling the other game")
end

local function world_info(actor)
    if not util.valid(actor) then return nil end
    local cls, l, da = util.class_name(actor), nil, item_of(actor)
    pcall(function() l = util.vec(actor:K2_GetActorLocation()) end)
    if not (cls and l and da) then return nil end
    return { cls = cls, loc = l, da = da }
end

local function on_add_actor_pre(ActorRef)
    local actor
    pcall(function() actor = ActorRef:get() end)
    local uid = tracked_uid(actor)
    -- another guest's drop (more than two players): the copy that holds it tells everyone
    if not uid and shared() and actor and other_tracks(actor) then picking = nil; return end
    if uid then
        picking = { uid = uid, at = now }
        if unfilled[uid] then
            picking.before = {}
            local pc = inventory()
            for _, h in ipairs(pc and contents_of(pc) or {}) do picking.before[h.uid] = true end
        end
    elseif shared() then picking = { world = world_info(actor), at = now }
    else picking = nil end
end

local function on_add_actor_post()
    local p = picking
    picking = nil
    if not p then return end
    if not p.added then return end
    if not p.uid then
        if p.world then send_world(nil, p.world.cls, p.world.loc, p.world.da) end
        return
    end
    local uid, a = p.uid, tracked[p.uid]
    if a and on_ground(a) then
        pcall(function() a:K2_DestroyActor() end)
        stats.forced = stats.forced + 1
        log.warn("drops: picked-up item still looked present (no EndPlay seen) - destroyed it")
    end
    log.info("drops: a dropped item was picked up here (" .. (copies[uid] and "copy" or "own drop")
        .. ", removed by the game) - telling the other game")
    queue_refill(uid, p.item, p.before)
    forget(uid)
    channel:send("T " .. uid)
end

local function on_picked(self, Info, ItemUID)
    if not util.same(self:get(), game.player()) then return end
    local u, da
    pcall(function() u = uid_str(ItemUID:get()) end)
    if picking then picking.added = true; picking.item = u; return end
    pcall(function() da = full_path(Info:get()[ITEM_ID]) end)
    local key = u and (alias[u] or u)
    if not (key and copies[key]) and da then
        local pl
        pcall(function() pl = util.vec(game.player():K2_GetActorLocation()) end)
        for uid, c in pairs(copies) do
            local a = tracked[uid]
            if c.da == da and pl and on_ground(a) then
                local l
                pcall(function() l = util.vec(a:K2_GetActorLocation()) end)
                if l and util.dist(l, pl) < 400 then key = uid; break end
            end
        end
    end
    if not (key and copies[key]) then return end
    local a = tracked[key]
    if on_ground(a) then
        pcall(function() a:K2_DestroyActor() end)
        stats.forced = stats.forced + 1
        log.warn("drops: picked up a copy that the game didn't remove - removed it (no duplicate)")
    end
    queue_refill(key, u)
    forget(key)
    channel:send("T " .. key)
end

local hook_fn = function(self, ItemUID, FromContainerUID, ActorRef)
    util.safe(on_dropped, "drops.capture", self, ItemUID, FromContainerUID, ActorRef)
end
local picked_fn = function(self, Info, ItemUID) util.safe(on_picked, "drops.picked", self, Info, ItemUID) end
local filled_fn = function(self) util.safe(on_filled, "drops.filled", self) end
local request_fn = function(self, ItemUID) util.safe(on_drop_request, "drops.request", ItemUID) end
local craft_drop_fn = function() util.safe(on_drop_request, "drops.request") end
local add_pre_fn = function(self, ActorRef) util.safe(on_add_actor_pre, "drops.add_pre", ActorRef) end
local add_post_fn = function() util.safe(on_add_actor_post, "drops.add_post") end
local begin_fn = function(self) util.safe(on_pickup_begin, "drops.pickup_begin", self) end
local rewards_fn = function() util.safe(on_rewards, "drops.rewards") end
local comp_move_fn = function(self, From, To)
    util.safe(function() on_comp_move(util.obj(From), util.obj(To)) end, "drops.comp_move")
end
local end_play_fn = function(self)
    util.safe(function()
        local owner
        pcall(function() owner = self:get():GetOwner() end)
        local a = util.addr(owner)
        if a and tracked_uid(owner) then ended[a] = true end
    end, "drops.end_play")
end
local equipped_fn = function(self, ActorRef, ContainerName, ItemUID)
    util.safe(function()
        if not util.same(self:get(), game.player()) then return end
        local actor, item
        pcall(function() actor = ActorRef:get() end)
        if not util.valid(actor) then return end
        pcall(function() item = uid_str(ItemUID:get()) end)
        for uid, a in pairs(tracked) do
            if util.same(a, actor) then
                log.info("drops: a dropped item was picked up here (equipped) - telling the other game")
                queue_refill(uid, item)
                forget(uid)
                channel:send("T " .. uid)
                return
            end
        end
        if shared() then
            local w = world_info(actor)
            if w then send_world(actor, w.cls, w.loc, w.da) end
        end
    end, "drops.equipped")
end

function drops.tick(dt)
    if not (cfg and cfg.mirror_drops) then return end
    now = now + dt
    if #finish > 0 then util.safe(finish_copies, "drops.finish") end
    if #rewards > 0 then util.safe(send_rewards, "drops.send_rewards") end
    if #refill > 0 then run_refills() end
    if next(resend) then util.safe(send_contents, "drops.send_contents") end
    if picking and now - picking.at > 0.2 then util.safe(on_add_actor_post, "drops.add_post_late") end
    check_in = check_in - dt
    if check_in <= 0 then
        check_in = 0.5
        util.ensure_hook(PLAYER .. ":JigMP_OnItemDropped", hook_fn)
        util.ensure_hook(JIG .. ":SetPickupContainerData", filled_fn)
        util.ensure_hook(JIG .. ":HandleServerDropRequest", request_fn)
        util.ensure_hook(JIG .. ":HandleServerFuncRequestCraftDrop", craft_drop_fn)
        if #filled > 0 and filled[#filled].at < now - 1 then filled = {} end
        util.ensure_hook(PLAYER .. ":JigMP_OnPickupAdded", picked_fn)
        util.ensure_hook(PLAYER .. ":JigMP_OnPickupEquipped", equipped_fn)
        util.ensure_hook(JIG .. ":ServerFunc_HandleRequestAddActorToContainer", add_pre_fn, add_post_fn)
        util.ensure_hook(PICKUP_COMP .. ":ReceiveEndPlay", end_play_fn)
        util.ensure_hook(JIG .. ":Handle Comp to Comp Move", comp_move_fn)
        util.ensure_hook(PICKUP_COMP .. ":ReceiveBeginPlay", begin_fn)
        util.ensure_hook(BEACON .. ":SpawnRewards", rewards_fn)
        if #begun > 0 and begun[#begun].at < now then begun = {} end
        if not shared() then
            tracked, copies, alias, finish, ended, contents, finished, unfilled = {}, {}, {}, {}, {}, {}, {}, {}
            resend, sent_list, held = {}, {}, {}
        end
        local pl
        pcall(function() pl = util.vec(game.player():K2_GetActorLocation()) end)
        for uid, a in pairs(tracked) do
            local here, why = on_ground(a)
            if here then
                seen[uid] = true
                if pl then util.safe(poll_parts, "drops.poll_parts", uid, a, pl) end
            end
            if not here and (why ~= "hidden" or seen[uid]) then
                log.info("drops: a dropped item was picked up here (" .. why .. ") - telling the other game")
                if held[uid] then queue_refill(uid, nil, held[uid]) end
                forget(uid)
                channel:send("T " .. uid)
            end
        end
        -- after the check: a snapshot taken once the new mag is already in the inventory would hide it
        if next(unfilled) then util.safe(note_held, "drops.note_held") end
    end
    channel:pump(function(payload)
        local k = payload:sub(1, 1)
        if k == "D" or k == "T" then traded() end
        if k == "D" then util.safe(make, "drops.make", payload)
        elseif k == "W" then util.safe(remove_world, "drops.world", payload)
        elseif k == "I" then util.safe(take_content, "drops.content", payload)
        elseif k == "C" then util.safe(take_changed, "drops.changed", payload)
        else util.safe(remove, "drops.remove", payload) end
        -- host, more than two players: the other guests get it too; a pickup also removes the host's copy,
        -- which the copy of this module of whoever dropped it holds
        if k == "T" then peers.relay("mirror.drops", drops, function(m) m.relay_take(payload) end)
        else peers.relay("mirror.drops", drops, function(m) m.relay_send(payload) end) end
    end)
end

function drops.relay_send(p) channel:send(p) end
function drops.relay_take(p)
    util.safe(remove, "drops.remove", p)
    channel:send(p)
end

function drops.status()
    return string.format("drops sent %d, made %d, removed %d%s | world items taken: sent %d, removed %d, not here %d",
        stats.sent, stats.made, stats.removed, stats.forced > 0 and (", FORCED " .. stats.forced) or "",
        world_stats.sent, world_stats.removed, world_stats.missing)
end

-- Respawn/reload: the old world's objects are freed - drop them without touching them.
-- Item cleanup removes an old dropped item: the other game removes its copy too.
function drops.cleanup_remove(actor)
    if not alive(actor) then return false end
    local uid = tracked_uid(actor)
    local w = not uid and shared() and world_info(actor) or nil
    if not pcall(function() actor:K2_DestroyActor() end) then return false end
    if uid then
        forget(uid)
        channel:send("T " .. uid)
    else
        ended[util.addr(actor) or 0] = true
        if w then channel:send(string.format("W %s %.1f %.1f %.1f %s", w.cls, w.loc.X, w.loc.Y, w.loc.Z, w.da)) end
    end
    return true
end

local function forget_world()
    tracked, finish, finished, ended, filled, picking, begun, rewards, unfilled, refill = {}, {}, {}, {}, {}, nil, {}, {}, {}, {}
    resend, sent_list, held = {}, {}, {}
end
function drops.init(c, r, s)
    game.on_world_reset(forget_world)
    cfg, role, session = c, r, s
    if cfg.mirror_drops then log.info("drops: mirroring dropped items") end
end

return drops
