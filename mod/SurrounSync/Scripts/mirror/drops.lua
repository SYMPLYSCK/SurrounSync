-- Items dropped on the ground show up for the other player, and picking one up removes it there.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local events = require("mirror.events")
local jig = require("mirror.jig")

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
local channel = events.new("drops", 32, 5)
local tracked = {}
local seen = {}
local copies = {}
local alias = {}
local finish = {}
local contents = {}
local finished = {}
local ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local now = 0.0
local check_in = 0.0
local stats = { sent = 0, made = 0, removed = 0, forced = 0 }

local full_path, uid_str, guid = jig.full_path, jig.uid_str, jig.guid

local ended = {}
local PICKUP_COMP = "/Game/JigSInventory/Jigsaw/Pickup/BP_JigPickupComponent.BP_JigPickupComponent_C"

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

local function forget(uid)
    local a = tracked[uid]
    if a then ended[util.addr(a) or 0] = nil end
    tracked[uid], copies[uid], seen[uid] = nil, nil, nil
end

local function jig_of(actor)
    local cls = StaticFindObject(JIG)
    if not util.valid(cls) then return nil end
    local c
    pcall(function() c = actor:GetComponentByClass(cls) end)
    return util.valid(c) and c or nil
end

local function item_of(actor)
    local da
    pcall(function()
        local c = actor:GetComponentByClass(StaticFindObject(PICKUP_COMP))
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
local function apply_contents(comp, want, what)
    local set, added, removed, missing = jig.apply_contents(comp, want)
    log.info(string.format("drops: %s contents - %d set, %d added, %d extra removed, %d missing (of %d) - now [%s]", what,
        set, added, removed, missing, #want, describe(contents_of(comp))))
end

local function shared() return role == "host" or (session and session.in_world()) end
local function traded() if session and session.checkpoint and shared() then session.checkpoint("drops") end end
channel.send = function(self, p) if p:find("^[DWT] ") then traded() end return events.send(self, p) end

local function on_dropped(self, ItemUID, FromContainerUID, ActorRef)
    local p = self:get()
    if not util.same(p, game.player()) then return end
    if not shared() then return end
    local pickup
    pcall(function() pickup = ActorRef:get() end)
    if not util.valid(pickup) then return end
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
    if not (da and uid) then log.warn("drops: couldn't read the dropped item's info"); return end
    local l, r
    pcall(function() l = pickup:K2_GetActorLocation(); r = pickup:K2_GetActorRotation() end)
    if not l then return end
    tracked[uid] = pickup
    channel:send(string.format("D %s %s %d %.3f %.3f %.1f %.1f %.1f %.1f %.1f %.1f %.0f %.0f %.4f %.2f", uid, da,
        count or 1, dur and dur.X or 0, dur and dur.Y or 0, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll,
        vec.X or 0, vec.Y or 0, weight, price))
    local inside, line, n = contents_of(comp), {}, 0
    for i, h in ipairs(inside) do
        local par = h.parent and line[h.parent]
        if h.da and (par or not h.parent) then
            n = n + 1
            line[i] = n
            channel:send(string.format("I %s %s %d %.3f %.3f %d %d", uid, h.da, h.count, h.dx, h.dy, par or 0, h.slot or 0))
        end
    end
    stats.sent = stats.sent + 1
    log.info(string.format("drops: dropped %s x%d%s - sent", da:match("[^%.]+$") or da, count or 1,
        #inside > 0 and (" (holding " .. describe(inside) .. ")") or ""))
end

local function make(payload)
    local uid, da, count, dx, dy, x, y, z, pi, ya, ro, vx, vy, wt, pr =
        payload:match("^D (%S+) (%S+) (%-?%d+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
    if not uid then return end
    if not shared() then return end
    if tracked[uid] and alive(tracked[uid]) then return end
    local asset = StaticFindObject(da)
    if not util.valid(asset) then
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
    local par, slot = (rest or ""):match("^(%d+) (%-?%d+)$")
    local list = contents[uid] or {}
    list[#list + 1] = { da = da, count = tonumber(count) or 1, dx = tonumber(dx) or 0, dy = tonumber(dy) or 0,
                        parent = par ~= "0" and tonumber(par) or nil, slot = tonumber(slot) }
    contents[uid] = list
    local a = finished[uid]
    if a and alive(a) then
        local comp = jig_of(a)
        if comp then apply_contents(comp, list, da:match("[^%.]+$") or da) end
    end
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
            if comp then apply_contents(comp, contents[f.uid] or {}, "copy") end
        end
    end
    finish = keep
end

local picking = nil
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
    if uid then picking = { uid = uid, at = now }
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
    forget(uid)
    channel:send("T " .. uid)
end

local function on_picked(self, Info, ItemUID)
    if not util.same(self:get(), game.player()) then return end
    if picking then picking.added = true; return end
    local u, da
    pcall(function() u = uid_str(ItemUID:get()) end)
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
    forget(key)
    channel:send("T " .. key)
end

local hook_fn = function(self, ItemUID, FromContainerUID, ActorRef)
    util.safe(on_dropped, "drops.capture", self, ItemUID, FromContainerUID, ActorRef)
end
local picked_fn = function(self, Info, ItemUID) util.safe(on_picked, "drops.picked", self, Info, ItemUID) end
local add_pre_fn = function(self, ActorRef) util.safe(on_add_actor_pre, "drops.add_pre", ActorRef) end
local add_post_fn = function() util.safe(on_add_actor_post, "drops.add_post") end
local end_play_fn = function(self)
    util.safe(function()
        local owner
        pcall(function() owner = self:get():GetOwner() end)
        local a = util.addr(owner)
        if a and tracked_uid(owner) then ended[a] = true end
    end, "drops.end_play")
end
local equipped_fn = function(self, ActorRef)
    util.safe(function()
        if not util.same(self:get(), game.player()) then return end
        local actor
        pcall(function() actor = ActorRef:get() end)
        if not util.valid(actor) then return end
        for uid, a in pairs(tracked) do
            if util.same(a, actor) then
                log.info("drops: a dropped item was picked up here (equipped) - telling the other game")
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
    if picking and now - picking.at > 0.2 then util.safe(on_add_actor_post, "drops.add_post_late") end
    check_in = check_in - dt
    if check_in <= 0 then
        check_in = 0.5
        util.ensure_hook(PLAYER .. ":JigMP_OnItemDropped", hook_fn)
        util.ensure_hook(PLAYER .. ":JigMP_OnPickupAdded", picked_fn)
        util.ensure_hook(PLAYER .. ":JigMP_OnPickupEquipped", equipped_fn)
        util.ensure_hook(JIG .. ":ServerFunc_HandleRequestAddActorToContainer", add_pre_fn, add_post_fn)
        util.ensure_hook(PICKUP_COMP .. ":ReceiveEndPlay", end_play_fn)
        if not shared() then tracked, copies, alias, finish, ended, contents, finished = {}, {}, {}, {}, {}, {}, {} end
        for uid, a in pairs(tracked) do
            local here, why = on_ground(a)
            if here then seen[uid] = true end
            if not here and (why ~= "hidden" or seen[uid]) then
                log.info("drops: a dropped item was picked up here (" .. why .. ") - telling the other game")
                forget(uid)
                channel:send("T " .. uid)
            end
        end
    end
    channel:pump(function(payload)
        local k = payload:sub(1, 1)
        if k == "D" or k == "W" or k == "T" then traded() end
        if k == "D" then util.safe(make, "drops.make", payload)
        elseif k == "W" then util.safe(remove_world, "drops.world", payload)
        elseif k == "I" then util.safe(take_content, "drops.content", payload)
        else util.safe(remove, "drops.remove", payload) end
    end)
end

function drops.status()
    return string.format("drops sent %d, made %d, removed %d%s | world items taken: sent %d, removed %d, not here %d",
        stats.sent, stats.made, stats.removed, stats.forced > 0 and (", FORCED " .. stats.forced) or "",
        world_stats.sent, world_stats.removed, world_stats.missing)
end

function drops.init(c, r, s)
    cfg, role, session = c, r, s
    if cfg.mirror_drops then log.info("drops: mirroring dropped items") end
end

return drops
