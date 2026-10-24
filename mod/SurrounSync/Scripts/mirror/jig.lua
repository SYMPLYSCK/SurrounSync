-- Helpers for the game's grid inventory (Jigsaw): reading, adding and matching items.

local util = require("mirror.util")
local log = require("mirror.log")
local stats_logged = 0

local jig = {}

local ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local ITEM_ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
local DURABILITY = "Durability_22_A3557C454274D193D47AB9B71FB0C0CA"
local UID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"
local C_REPUID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
local C_IN = "InContainerUID_24_D1504ED7438699C73EA046AD734E79BF"
local C_INDEX = "ContainerIndex_22_9A211B86466A9D1C57E1FC839A5B0896"
local SLOT_INDEX = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local ROTATED = "Rotated_9_3CFE5D9342A81FB1FF17DEB7B491CE56"

local asset_cache = {}
function jig.asset(path)
    local a = asset_cache[path]
    if util.valid(a) then return a end
    a = StaticFindObject(path)
    if util.valid(a) then asset_cache[path] = a; return a end
    return nil
end

function jig.full_path(obj)
    if not util.valid(obj) then return nil end
    local p
    pcall(function() p = obj:GetFullName():match("^%S+ (.+)$") end)
    return p
end

-- An item's stats (what food/water restores, armour values...) live in the item itself, not the asset:
-- an item made without them looks right but does nothing when used. The game's own default
-- (GetPickupInfoFromDT) is the asset's ItemStats; built as fresh tables, never game structs passed back in.
local STATS = "Stats_26_C770972746930CB80CC49AB7A6D19359"
jig.STATS = STATS
local S_TAG, S_PREFIX = "STAT_NAME_13_8D9D8D5D48A145FB1BAD6E98C69D0A10", "Prefix_16_994B3BFF49FB68BE6A485DB9498EB954"
local S_MIN, S_MAX = "MinValue_6_4B4822A7420F784740B6A58155973EE6", "MaxValue_8_04A5809A498E900862BCCA9A6E412BD7"
local S_TXT = "Txt_12_F1BE8023414240AC50F4B09BF1B79D58"
local stats_cache = {}
local function name_str(n)
    local s
    pcall(function() s = n:ToString() end)
    return s
end
-- Weapons keep their damage etc. in the asset's RandomStats, rolled per item by the game's
-- BP_JigComponent:GenerateRandomStats(RandomStats, ItemStats): the rolls (until MaxStats is reached), then the
-- ItemStats. Without the roll a weapon made by us has no FirearmDamage/MeleeDamage stat and every hit does 1
-- (FindStat's default). Same order as the game's bytecode.
local RS_LIST, RS_MAXN = "Stats_8_78B6E3C14C0578F96B7C9FBBA7820A46", "MaxStats_7_971BC4334FEFC6C1B39175A3D0721033"
local RS_TAG, RS_TXT = "STAT_NAME_23_8D9D8D5D48A145FB1BAD6E98C69D0A10", "Txt_22_E0F5EFD44434F58678FE088E508B5B53"
local RS_MIN, RS_MAX = "RandomMinValue_9_4B4822A7420F784740B6A58155973EE6", "RandomMaxValue_10_04A5809A498E900862BCCA9A6E412BD7"
local RS_CHANCE, RS_FORCE = "Chance_15_AF3D90B44051B6E1B6D8F194C1F20BD4", "ForceToMinValue?_27_531AA2464812E07068161A898359479B"
local RS_ROUND, RS_BOTH = "Rounded?_28_44A60F2C4A467758D866B5BCE56695AE", "RollForBothMinMax?_19_FEE7FBE94044DC3E7E09DCA48626158A"
local function raw_stats(asset)
    local key = util.addr(asset) or 0
    local raw = stats_cache[key]
    if not raw then
        raw = { fixed = {}, random = {}, max = 0 }
        pcall(function()
            asset.ItemStats:ForEach(function(_, e)
                local s = e:get()
                raw.fixed[#raw.fixed + 1] = { tag = name_str(s[S_TAG].TagName), prefix = name_str(s[S_PREFIX]),
                                              min = tonumber(s[S_MIN]) or 0, max = tonumber(s[S_MAX]) or 0, txt = name_str(s[S_TXT]) }
            end)
        end)
        pcall(function()
            local rc = asset.RandomStats
            raw.max = tonumber(rc[RS_MAXN]) or 0
            rc[RS_LIST]:ForEach(function(_, e)
                local s = e:get()
                raw.random[#raw.random + 1] = { tag = name_str(s[RS_TAG].TagName), txt = name_str(s[RS_TXT]),
                    min = tonumber(s[RS_MIN]) or 0, max = tonumber(s[RS_MAX]) or 0, chance = tonumber(s[RS_CHANCE]) or 0,
                    force = s[RS_FORCE] == true, round = s[RS_ROUND] == true, both = s[RS_BOTH] == true }
            end)
        end)
        stats_cache[key] = raw
    end
    return raw
end
function jig.base_stats(asset)
    if not util.valid(asset) then return {} end
    local raw = raw_stats(asset)
    local out = {}
    local function add(tag, prefix, mn, mx, txt)
        out[#out + 1] = { [S_TAG] = { TagName = FName(tag or "None") }, [S_PREFIX] = FName(prefix or "None"),
                          [S_MIN] = mn, [S_MAX] = mx, [S_TXT] = FName(txt or "None") }
    end
    for _, r in ipairs(raw.random) do
        if math.random() * 100 <= r.chance then
            local lo, hi = r.min, r.max
            if not r.force then
                lo = r.min + math.random() * (r.max - r.min)
                hi = lo + math.random() * (r.max - lo)
                if r.round then lo, hi = math.floor(lo + 0.5), math.floor(hi + 0.5) end
                if not r.both then hi = lo end
            end
            add(r.tag, "None", lo, hi, r.txt)
            if #out == raw.max then return out end
        end
    end
    for _, r in ipairs(raw.fixed) do add(r.tag, r.prefix, r.min, r.max, r.txt) end
    return out
end
-- Fills the Stats of an item info already in the game (a dropped copy); returns how many were written.
function jig.write_stats(info, asset)
    local n, list = 0, nil
    local ok, err = pcall(function()
        local arr = info[STATS]
        if arr:GetArrayNum() > 0 then n = -1; return end
        list = jig.base_stats(asset)
        for i, s in ipairs(list) do arr[i] = s; n = i end
    end)
    if not ok then return nil, tostring(err) end
    jig.last_stats = list
    return n
end

-- A game-made item of this asset always has stats (a fixed one or a 100% roll).
function jig.always_has_stats(asset)
    if not util.valid(asset) then return false end
    local raw = raw_stats(asset)
    if #raw.fixed > 0 then return true end
    for _, r in ipairs(raw.random) do if r.chance >= 100 then return true end end
    return false
end

function jig.uid_str(g) return string.format("%d_%d_%d_%d", g.A, g.B, g.C, g.D) end

function jig.guid(uid)
    local a, b, c, d = uid:match("^(%-?%d+)_(%-?%d+)_(%-?%d+)_(%-?%d+)$")
    return { A = tonumber(a), B = tonumber(b), C = tonumber(c), D = tonumber(d) }
end

function jig.contents_of(comp)
    local out, in_of, slot_of = {}, {}, {}
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            local ct = c:get()
            local holder, slot = nil, nil
            pcall(function() holder = jig.uid_str(ct[C_IN]); slot = ct[C_INDEX] end)
            ct[ITEMS]:ForEach(function(_, el)
                pcall(function()
                    local it = el:get()
                    local d = it[INFO][DURABILITY]
                    out[#out + 1] = { uid = jig.uid_str(it[UID]), da = jig.full_path(it[INFO][ITEM_ID]),
                                      count = it[INFO][COUNT] or 1, dx = d.X or 0, dy = d.Y or 0, el = el }
                    pcall(function()
                        local h = out[#out]
                        h.cell, h.rot = it[SLOT_INDEX], it[ROTATED] == true
                        local m = it["ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D"]
                        h.mother = string.format("%d_%d_%d_%d", m.A, m.B, m.C, m.D)
                    end)
                    in_of[#out], slot_of[#out] = holder, slot
                end)
            end)
        end)
    end)
    local index = {}
    for i, h in ipairs(out) do index[h.uid] = i end
    for i, h in ipairs(out) do
        local p = in_of[i] and index[in_of[i]]
        h.slot, h.holder = slot_of[i], in_of[i]
        if p and p ~= i then h.parent = p end
    end
    return out
end

-- Items made by older versions without their rolled stats (weapons doing 1 damage): give them stats.
function jig.repair_stats(comp)
    local fixed, names = 0, {}
    for _, h in ipairs(jig.contents_of(comp)) do
        local asset = jig.asset(h.da)
        if asset and jig.always_has_stats(asset) then
            local n
            pcall(function() n = jig.write_stats(h.el:get()[INFO], asset) end)
            if n and n > 0 then fixed = fixed + 1; names[#names + 1] = h.da:match("[%w_]+$") end
        end
    end
    return fixed, names
end

local function containers_of(comp, holder_uid, items)
    local is_item = {}
    for _, h in ipairs(items or jig.contents_of(comp)) do is_item[h.uid] = true end
    local out = {}
    pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            local ct = c:get()
            local holder, slot = nil, nil
            pcall(function() holder = jig.uid_str(ct[C_IN]); slot = ct[C_INDEX] end)
            local top = not (holder and is_item[holder])
            if (holder_uid == nil and top) or (holder_uid ~= nil and holder == holder_uid) then
                out[#out + 1] = { raw = ct, slot = slot }
            end
        end)
    end)
    return out
end

local names_mod
local function names() names_mod = names_mod or require("mirror.names"); return names_mod end

function jig.encode(list, with_uid)
    local parts, at = {}, {}
    for i, h in ipairs(list) do
        if h.da then
            at[i] = #parts + 1
            local name = h.name or (h.uid and names().get(h.uid))
            parts[#parts + 1] = (with_uid and (h.uid .. ",") or "")
                .. string.format("%s,%d,%.3f,%.3f", h.da, h.count or 1, h.dx or 0, h.dy or 0)
                .. (h.parent and at[h.parent] and string.format(",%d,%d", at[h.parent], h.slot or 0) or "")
                .. (h.cell and h.cell >= 0 and ("@" .. math.floor(h.cell) .. (h.rot and "r" or "")) or "")
                .. (name and ("|" .. names().encode(name)) or "")
        end
    end
    return table.concat(parts, ";")
end

-- A put/drop line needs the item list when the item holds things or has a custom name.
function jig.worth_sending(inside)
    return inside ~= nil and (#inside > 1 or (inside[1] ~= nil and names().get(inside[1].uid) ~= nil))
end

local function name_items(pairs_list)
    for _, p in ipairs(pairs_list) do
        if p.want.name and p.uid then names().set(p.uid, p.want.name, true) end
    end
end

function jig.decode(s)
    local out = {}
    for whole in (s or ""):gmatch("[^;]+") do
        local item, name = whole:match("^([^|]*)|(.*)$")
        local part = item or whole
        local uid, rest = part:match("^(%-?%d+_%-?%d+_%-?%d+_%-?%d+),(.*)$")
        local body = rest or part
        local cell, rot = nil, nil
        local b, c, r = body:match("^(.*)@(%d+)(r?)$")
        if b then body, cell, rot = b, tonumber(c), r == "r" end
        local da, n, dx, dy = body:match("^([^,]+),(%-?%d+),([^,]+),([^,]+)")
        local par, slot = body:match("^[^,]+,%-?%d+,[^,]+,[^,]+,(%d+),(%-?%d+)$")
        if da then
            out[#out + 1] = { uid = uid, da = da, count = tonumber(n) or 1, dx = tonumber(dx) or 0, dy = tonumber(dy) or 0,
                              parent = tonumber(par), slot = tonumber(slot), cell = cell, rot = rot,
                              name = name and name ~= "" and names().decode(name) or nil }
        end
    end
    return out
end

local ITEM_VEC = "ItemVec_13_4DB12E4E4F80730BD25ACFA6FA51AD0A"
local WEIGHT = "Weight_16_C6B7568A4E062D2AE81209916A32B4EB"
local PRICE = "Price_19_FEFE0D2A4561BAF04CE37D9BAE1D6EF7"
local PENDING = "Pending?_31_C3AE39044666796C0FA128BA521590CB"
local IS_CONTAINER = "IsContainer_14_0198F62E4F1B93DD8B4D6E92B7E3EA45"
local MOTHER = "ContainerMotherID_38_33D59C5047C31FF0367835AAF5ABE05D"
local IN_INDEX = "InContainerIndex_31_A61F5C3A47C8E761BA5CF0ADA1DF9FDE"
local COLS = "Columns_4_1D84448048078D988999ABA138CE1809"
local ROWS = "Rows_6_78B4BC5B449017D63758E79844375AE9"
local REPUID = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332"
jig.REPUID = REPUID
local MAX_TRIES = 120
function jig.container_arg(cont)
    local g, c, r = nil, 0, 0
    pcall(function() local u = cont[REPUID]; g = { A = u.A, B = u.B, C = u.C, D = u.D } end)
    pcall(function() c, r = cont[COLS], cont[ROWS] end)
    return { [REPUID] = g or { A = 0, B = 0, C = 0, D = 0 }, [COLS] = c, [ROWS] = r }, c * r
end
-- An open container window only redraws through the game's client-side handlers (what the game itself
-- calls after a server change); items the mod adds/moves/recounts in the data alone showed up only after
-- closing and reopening the container. These do nothing when no window shows that container.
local SUB_MOTHER, SUB_INDEX, SUB_UID = "MotherUID_8_7735C14D45BC033E6B49849FDE3983AD", "Index_4_FD1A1D6C4AEA49616F1968844F3217D2",
    "UniqueID_9_C5CA265F40546A19DEB2539CEC625BC7"
local ui_warned = 0
local ui_q
local function show_added(comp, uid, info, target, idx, rot)
    local subs = {}
    for _, c in ipairs(containers_of(comp, uid)) do
        subs[#subs + 1] = { [SUB_MOTHER] = jig.guid(uid), [SUB_INDEX] = c.slot or 0, [SUB_UID] = (jig.container_arg(c.raw))[REPUID] }
    end
    -- full info first; a struct the game won't take (stats / sub-container list) -> again without it
    local function try(i, sc)
        local t = { A = target.A, B = target.B, C = target.C, D = target.D }
        return pcall(function() comp:HandleNewItemAdded(i, jig.guid(uid), t, idx, rot == true, sc) end)
    end
    local ok, err = try(info, subs)
    if not ok and info[STATS] then
        local plain = {}
        for k, v in pairs(info) do if k ~= STATS then plain[k] = v end end
        info = plain
        ok, err = try(info, subs)
    end
    if not ok and #subs > 0 then ok, err = try(info, {}) end
    if not ok and ui_warned < 5 then ui_warned = ui_warned + 1; log.warn("jig: couldn't show an added item in an open window: " .. tostring(err)) end
end
-- Items added this frame are shown in open windows next frame, read back fresh from the container
-- (the same call made in the same frame as the add drew nothing in-game). jig.flush_ui runs from the loot/corpse ticks.
ui_q = {}
function jig.flush_ui()
    if #ui_q == 0 then return end
    local q = ui_q
    ui_q = {}
    for _, e in ipairs(q) do
        if util.valid(e.comp) then
            for _, h in ipairs(jig.contents_of(e.comp)) do
                if h.uid == e.uid then
                    local mother, info
                    pcall(function()
                        local it = h.el:get()
                        local m = it[MOTHER]
                        mother = { A = m.A, B = m.B, C = m.C, D = m.D }
                        local v = e.asset.SlotDimensions
                        info = { [ITEM_ID] = e.asset, [COUNT] = h.count, [DURABILITY] = { X = h.dx, Y = h.dy },
                                 [ITEM_VEC] = { X = v.X, Y = v.Y }, [WEIGHT] = e.asset.Weight or 0, [PRICE] = e.asset.Price or 0,
                                 [PENDING] = -1.0 }
                    end)
                    if mother and info and h.cell then show_added(e.comp, h.uid, info, mother, h.cell, h.rot) end
                    break
                end
            end
        end
    end
end
function jig.show_moved(comp, uid, target, idx, rot)
    local ok, err = pcall(function() comp:HandleClientMoveItemToIndex(jig.guid(uid), target, idx, rot == true) end)
    if not ok and ui_warned < 5 then ui_warned = ui_warned + 1; log.warn("jig: couldn't show a move in an open window: " .. tostring(err)) end
end
function jig.show_count(comp, uid, count)
    pcall(function() comp:ClientUpdateCount(jig.guid(uid), count, false) end)
end

-- place = { cell, rot }: the grid cell + rotation the item had in the other game; tried first in each
-- container, then the first free cell (unrotated) as before.
function jig.add_item(comp, da, count, dx, dy, conts, place)
    local asset = jig.asset(da)
    if not util.valid(asset) then return nil, "not loaded in this game" end
    local size, weight, price, holds = { X = 1, Y = 1 }, 0, 0, false
    pcall(function() local v = asset.SlotDimensions; size = { X = v.X, Y = v.Y } end)
    pcall(function() holds = asset["IsContainer?"] == true end)
    pcall(function() weight = asset.Weight end)
    pcall(function() price = asset.Price end)
    -- UE4SS writes out-params back into the tables passed in: use fresh ones for every call.
    local function new_info(rot)
        return {
            [INFO] = { [ITEM_ID] = asset, [COUNT] = count or 1, [DURABILITY] = { X = dx or 0, Y = dy or 0 },
                       [ITEM_VEC] = { X = size.X, Y = size.Y }, [WEIGHT] = weight or 0, [PRICE] = price or 0, [PENDING] = -1.0 },
            [UID] = { A = 0, B = 0, C = 0, D = 0 }, [IS_CONTAINER] = holds, [MOTHER] = { A = 0, B = 0, C = 0, D = 0 },
            [SLOT_INDEX] = 0, [IN_INDEX] = 0, [ROTATED] = rot == true,
        }
    end
    local before, items = {}, jig.contents_of(comp)
    for _, h in ipairs(items) do before[h.uid] = true end
    if not conts then
        conts = containers_of(comp, nil, items)
        local slot = place and tonumber(place.slot)
        if slot then
            local same = {}
            for _, c in ipairs(conts) do if c.slot == slot then same[#same + 1] = c end end
            if #same > 0 then conts = same end
        end
    end
    local n, tries, err = #conts, 0, nil
    local function try(raw, idx, rot)
        tries = tries + 1
        local out = {}
        local ok, e = pcall(function() comp:AddNewItemToSlot(new_info(rot), (jig.container_arg(raw))[REPUID], idx, {}, true, out, {}) end)
        if not ok then err = e; return nil, true end
        if out.Added ~= true then return nil end
        for _, h in ipairs(jig.contents_of(comp)) do
            if not before[h.uid] then
                local ns, errs
                jig.last_stats = nil
                pcall(function() ns, errs = jig.write_stats(h.el:get()[INFO], asset) end)
                ui_q[#ui_q + 1] = { comp = comp, uid = h.uid, asset = asset }
                stats_logged = stats_logged + 1
                if stats_logged <= 20 then
                    log.info(string.format("jig: made %s with %s stat(s)%s", tostring(da):match("[%w_]+$") or "?",
                        ns == -1 and "its own" or tostring(ns), errs and (" - " .. errs) or ""))
                end
                return h.uid
            end
        end
    end
    local want = place and tonumber(place.cell)
    for ci = 1, n do
        local raw, cells = conts[ci].raw, 0
        pcall(function() cells = raw[COLS] * raw[ROWS] end)
        if want and want >= 0 and want < cells then
            local uid = try(raw, want, place.rot == true)
            if uid then return uid end
        end
    end
    for ci = 1, n do
        local raw, cells = conts[ci].raw, 0
        pcall(function() cells = raw[COLS] * raw[ROWS] end)
        for idx = 0, cells - 1 do
            if tries > MAX_TRIES then return nil, "no room found in " .. MAX_TRIES .. " tries" end
            local uid, failed = try(raw, idx, false)
            if uid then return uid end
            if failed then break end
        end
    end
    return nil, err and ("AddNewItemToSlot failed: " .. tostring(err))
        or string.format("no room (%d container(s), %d slot(s) tried)", n, tries)
end

-- Taking an item away. A bag (an item with its own compartments) taken whole goes with the game's
-- RemoveGetInfo (what a move between containers uses): plain consuming left the bag's compartments and
-- everything in them behind as loose loot ("everything spilled into the gas pump", 2026-10-24).
function jig.remove_whole(comp, uid)
    -- ItemInfo, RepContainers, VendorNewCount and CountRemoved? are all out params: each needs a table
    local ok, err = pcall(function() comp:RemoveGetInfo(jig.guid(uid), -1, {}, {}, {}, {}) end)
    if ok then pcall(function() comp:MC_ItemRemoved(jig.guid(uid)) end)
    else log.warn("jig: couldn't remove a bag whole: " .. tostring(err)) end
    return ok
end
function jig.take(comp, uid, n, total)
    if (total == nil or n >= total) and #containers_of(comp, uid) > 0 and jig.remove_whole(comp, uid) then return true end
    return pcall(function() comp:HandleLocalRequestConsumeItem(jig.guid(uid), n, comp, "", false) end)
end
local function consume(comp, h) jig.take(comp, h.uid, h.count, h.count) end

function jig.apply_contents(comp, want, no_add)
    local have = jig.contents_of(comp)
    local used, mate, mate_uid = {}, {}, {}
    local added, set, removed, missing, pairs_ = 0, 0, 0, 0, {}
    for wi, w in ipairs(want) do
        local holder = w.parent and mate[w.parent]
        if not w.parent or holder then
            local pick
            for i, h in ipairs(have) do
                if not used[i] and h.da == w.da and h.parent == holder and (w.slot == nil or h.slot == w.slot) then
                    if not pick then pick = i end
                    if w.cell == nil or h.cell == w.cell then pick = i; break end
                end
            end
            for i, h in ipairs(have) do
                if i == pick then
                    used[i], mate[wi], mate_uid[wi] = true, i, h.uid
                    pcall(function()
                        local it = h.el:get()
                        it[INFO][COUNT] = w.count
                        it[INFO][DURABILITY] = { X = w.dx, Y = w.dy }
                    end)
                    if w.count and w.count ~= h.count then jig.show_count(comp, h.uid, w.count) end
                    set = set + 1
                    pairs_[#pairs_ + 1] = { want = w, uid = h.uid }
                    break
                end
            end
        end
    end
    for i = #have, 1, -1 do
        if not used[i] then consume(comp, have[i]); removed = removed + 1 end
    end
    for wi, w in ipairs(want) do
        if not mate_uid[wi] then
            local holder_uid = w.parent and mate_uid[w.parent]
            if no_add or (w.parent and not holder_uid) then
                missing = missing + 1
            else
                local conts = nil
                if holder_uid or w.slot then
                    conts = {}
                    for _, c in ipairs(containers_of(comp, holder_uid)) do
                        if w.slot == nil or c.slot == w.slot then conts[#conts + 1] = c end
                    end
                    if not holder_uid and #conts == 0 then conts = nil end
                end
                local uid = jig.add_item(comp, w.da, w.count, w.dx, w.dy, conts, w)
                if uid then
                    added = added + 1
                    mate_uid[wi] = uid
                    pairs_[#pairs_ + 1] = { want = w, uid = uid }
                    local now, at = jig.contents_of(comp), nil
                    for i, h in ipairs(now) do if h.uid == uid then at = i end end
                    for i = #now, 1, -1 do
                        local p = now[i].parent
                        while p and p ~= at do p = now[p].parent end
                        if at and p == at then consume(comp, now[i]); removed = removed + 1 end
                    end
                else
                    missing = missing + 1
                end
            end
        end
    end
    if added > 0 or removed > 0 then
        -- why items didn't match (nested contents spilled once): wanted vs. what was here, da/parent/slot/cell
        local function d(h, i) return string.format("%d:%s/p%s/s%s/c%s", i, (h.da or "?"):match("[%w_]+$") or "?", tostring(h.parent), tostring(h.slot), tostring(h.cell)) end
        local w_s, h_s = {}, {}
        for i, w in ipairs(want) do w_s[#w_s + 1] = d(w, i) .. (mate_uid[i] and "" or "!") end
        for i, h in ipairs(have) do h_s[#h_s + 1] = d(h, i) .. (used[i] and "" or "!") end
        log.info("jig: apply want [" .. table.concat(w_s, " ") .. "] had [" .. table.concat(h_s, " ") .. "]")
    end
    name_items(pairs_)
    return set, added, removed, missing, pairs_
end

-- Rearranges items to the other game's layout (cell, rotation, which container). Only moves: never adds,
-- removes or changes counts. local_uid(their_uid) -> this game's uid for that item (or nil).
-- Moves use the game's own same-component move (HandleSameContainerMoveToIndex: Rotated? = final rotation).
-- Returns moved, failed.
function jig.apply_layout(comp, want, local_uid, by)
    local have = jig.contents_of(comp)
    local at, used, mate = {}, {}, {}
    for i, h in ipairs(have) do at[h.uid] = i end
    for wi, w in ipairs(want) do
        local u = w.uid and (local_uid and local_uid(w.uid) or w.uid)
        local i = u and at[u]
        if i and not used[i] and have[i].da == w.da then mate[wi], used[i] = i, true end
    end
    for wi, w in ipairs(want) do
        if not mate[wi] then
            local holder = w.parent and mate[w.parent]
            if not w.parent or holder then
                local pick
                for i, h in ipairs(have) do
                    if not used[i] and h.da == w.da and h.parent == holder and (w.slot == nil or h.slot == w.slot) then
                        if not pick then pick = i end
                        if h.cell == w.cell and h.rot == (w.rot == true) then pick = i; break end
                    end
                end
                if pick then mate[wi], used[pick] = pick, true end
            end
        end
    end
    local todo = {}
    for wi, w in ipairs(want) do
        local i = mate[wi]
        local holder = w.parent and mate[w.parent]
        if i and w.cell and (not w.parent or holder) then
            local h = have[i]
            if h.cell ~= w.cell or h.rot ~= (w.rot == true) or h.parent ~= holder or (w.slot ~= nil and h.slot ~= w.slot) then
                todo[#todo + 1] = { uid = h.uid, holder = holder and have[holder].uid, slot = w.slot, cell = w.cell, rot = w.rot == true }
            end
        end
    end
    local moved = 0
    -- a few rounds: an item can only go where another one has already moved away from
    for _ = 1, 3 do
        if #todo == 0 then break end
        local left = {}
        for _, m in ipairs(todo) do
            local target
            for _, c in ipairs(containers_of(comp, m.holder)) do
                if m.slot == nil or c.slot == m.slot then target = c.raw; break end
            end
            local done = false
            if target then
                local to = (jig.container_arg(target))[REPUID]
                pcall(function() comp:HandleSameContainerMoveToIndex(jig.guid(m.uid), to, m.cell, m.rot, by or comp, 0) end)
                for _, h in ipairs(jig.contents_of(comp)) do
                    if h.uid == m.uid then done = h.cell == m.cell and h.rot == m.rot; break end
                end
                if done then jig.show_moved(comp, m.uid, { A = to.A, B = to.B, C = to.C, D = to.D }, m.cell, m.rot) end
            end
            if done then moved = moved + 1 else left[#left + 1] = m end
        end
        if #left == #todo then todo = left; break end
        todo = left
    end
    return moved, #todo
end

function jig.subtree(comp, uid)
    local all = jig.contents_of(comp)
    local at
    for i, h in ipairs(all) do if h.uid == uid then at = i; break end end
    if not at then return nil end
    local out, place = { all[at] }, { [at] = 1 }
    for i = at + 1, #all do
        local h = all[i]
        if h.parent and place[h.parent] then
            out[#out + 1] = { uid = h.uid, da = h.da, count = h.count, dx = h.dx, dy = h.dy, parent = place[h.parent], slot = h.slot,
                              cell = h.cell, rot = h.rot }
            place[i] = #out
        end
    end
    return out
end

function jig.fill(comp, holder_uid, list)
    local uid_of, added, missing = { holder_uid }, 0, 0
    if list[1] and list[1].name and holder_uid then names().set(holder_uid, list[1].name, true) end
    for i = 2, #list do
        local w = list[i]
        local hu = w.parent and uid_of[w.parent]
        local uid = nil
        if hu then
            local conts = {}
            for _, c in ipairs(containers_of(comp, hu)) do
                if w.slot == nil or c.slot == w.slot then conts[#conts + 1] = c end
            end
            uid = jig.add_item(comp, w.da, w.count, w.dx, w.dy, conts, w)
        end
        uid_of[i] = uid
        if uid and w.name then names().set(uid, w.name, true) end
        if uid then added = added + 1 else missing = missing + 1 end
    end
    return added, missing
end

local STARTING = "StartingItems_10_C6DB208442353E0AA9B5DB892266821A"
local R_ITEM = "ItemID_41_8C5E69274AB445604263E4A2B3091BAD"
local R_CHANCE = "SpawnChance_9_0A1811814580181DD09AE78500C25A28"
local R_MIN = "RandomCountMin_17_2CF035DB43DEE23801AD29A29560BDA9"
local R_MAX = "RandomCountMax_18_C37B88104F52B02AA216B5912518580D"
local R_PRICE = "PriceOverride_29_306CC4B441051ADD17999E8D00D06A7F"
local R_INSIDE = "InContainerItem_26_8B73BDAE473217274FE336B3D2EB2407"
local R_INDEX = "Index_37_B46F3993454026F67AFD6D936119D0F6"
local R_ROT = "PreferRotated?_39_71AEF07C444B177A20CAF4A74260B9CD"
function jig.set_starting(comp, want, index)
    local written, missing = 0, 0
    local ok, err = pcall(function()
        local arr = comp.ContainersSettings[index or 1][STARTING]
        local n = arr:GetArrayNum()
        -- keep the price overrides already there (a trader's DT_VendorTable row) for the same item
        local price = {}
        for j = 1, n do
            pcall(function()
                local a = util.addr(arr[j][R_ITEM])
                if a then price[a] = arr[j][R_PRICE] end
            end)
        end
        local i = 0
        for _, w in ipairs(want) do
            local asset = not w.parent and jig.asset(w.da)
            if asset then
                i = i + 1
                arr[i] = { [R_ITEM] = asset, [R_CHANCE] = 100.0, [R_MIN] = w.count or 1, [R_MAX] = w.count or 1,
                           [R_PRICE] = tonumber(price[util.addr(asset) or 0]) or -1.0, [R_INDEX] = w.cell or -1, [R_ROT] = w.rot == true }
                pcall(function() arr[i][R_INSIDE] = {} end)
                written = written + 1
            elseif not w.parent then
                missing = missing + 1
            end
        end
        for j = i + 1, n do arr[j][R_CHANCE] = 0.0 end
    end)
    if not ok then return nil, err end
    return written, missing
end

function jig.is_empty(comp) return #jig.contents_of(comp) == 0 end

function jig.generate(comp)
    return pcall(function() comp:InitializeJigComponent() end)
end

function jig.count_of_item(comp, da)
    local n = 0
    for _, h in ipairs(jig.contents_of(comp)) do if h.da == da then n = n + h.count end end
    return n
end

function jig.reduce_item(comp, da, left)
    local have = jig.count_of_item(comp, da)
    local take, taken = have - left, 0
    if take <= 0 then return 0 end
    for _, h in ipairs(jig.contents_of(comp)) do
        if take <= 0 then break end
        if h.da == da then
            local n = math.min(take, h.count)
            local ok = jig.take(comp, h.uid, n, h.count)
            if ok then take, taken = take - n, taken + n end
        end
    end
    return taken
end

return jig
