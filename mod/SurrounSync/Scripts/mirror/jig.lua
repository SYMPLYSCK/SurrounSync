-- Helpers for the game's grid inventory (Jigsaw): reading, adding and matching items.

local util = require("mirror.util")

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
                    in_of[#out], slot_of[#out] = holder, slot
                end)
            end)
        end)
    end)
    local index = {}
    for i, h in ipairs(out) do index[h.uid] = i end
    for i, h in ipairs(out) do
        local p = in_of[i] and index[in_of[i]]
        h.slot = slot_of[i]
        if p and p ~= i then h.parent = p end
    end
    return out
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

function jig.encode(list, with_uid)
    local parts, at = {}, {}
    for i, h in ipairs(list) do
        if h.da then
            at[i] = #parts + 1
            parts[#parts + 1] = (with_uid and (h.uid .. ",") or "")
                .. string.format("%s,%d,%.3f,%.3f", h.da, h.count or 1, h.dx or 0, h.dy or 0)
                .. (h.parent and at[h.parent] and string.format(",%d,%d", at[h.parent], h.slot or 0) or "")
        end
    end
    return table.concat(parts, ";")
end

function jig.decode(s)
    local out = {}
    for part in (s or ""):gmatch("[^;]+") do
        local uid, rest = part:match("^(%-?%d+_%-?%d+_%-?%d+_%-?%d+),(.*)$")
        local body = rest or part
        local da, n, dx, dy = body:match("^([^,]+),(%-?%d+),([^,]+),([^,]+)")
        local par, slot = body:match("^[^,]+,%-?%d+,[^,]+,[^,]+,(%d+),(%-?%d+)$")
        if da then
            out[#out + 1] = { uid = uid, da = da, count = tonumber(n) or 1, dx = tonumber(dx) or 0, dy = tonumber(dy) or 0,
                              parent = tonumber(par), slot = tonumber(slot) }
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
local SLOT_INDEX = "SlotIndex_6_8ED1F34A4AF1D565616883B80192E3DD"
local IN_INDEX = "InContainerIndex_31_A61F5C3A47C8E761BA5CF0ADA1DF9FDE"
local ROTATED = "Rotated_9_3CFE5D9342A81FB1FF17DEB7B491CE56"
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
function jig.add_item(comp, da, count, dx, dy, conts)
    local asset = jig.asset(da)
    if not util.valid(asset) then return nil, "not loaded in this game" end
    local size, weight, price, holds = { X = 1, Y = 1 }, 0, 0, false
    pcall(function() local v = asset.SlotDimensions; size = { X = v.X, Y = v.Y } end)
    pcall(function() holds = asset["IsContainer?"] == true end)
    pcall(function() weight = asset.Weight end)
    pcall(function() price = asset.Price end)
    -- UE4SS writes out-params back into the tables passed in: use fresh ones for every call.
    local function new_info()
        return {
            [INFO] = { [ITEM_ID] = asset, [COUNT] = count or 1, [DURABILITY] = { X = dx or 0, Y = dy or 0 },
                       [ITEM_VEC] = { X = size.X, Y = size.Y }, [WEIGHT] = weight or 0, [PRICE] = price or 0, [PENDING] = -1.0 },
            [UID] = { A = 0, B = 0, C = 0, D = 0 }, [IS_CONTAINER] = holds, [MOTHER] = { A = 0, B = 0, C = 0, D = 0 },
            [SLOT_INDEX] = 0, [IN_INDEX] = 0, [ROTATED] = false,
        }
    end
    local before, items = {}, jig.contents_of(comp)
    for _, h in ipairs(items) do before[h.uid] = true end
    conts = conts or containers_of(comp, nil, items)
    local n, tries, err = #conts, 0, nil
    for ci = 1, n do
        local raw, cells = conts[ci].raw, 0
        pcall(function() cells = raw[COLS] * raw[ROWS] end)
        for idx = 0, cells - 1 do
            tries = tries + 1
            if tries > MAX_TRIES then return nil, "no room found in " .. MAX_TRIES .. " tries" end
            local out = {}
            local ok, e = pcall(function() comp:AddNewItemToSlot(new_info(), (jig.container_arg(raw))[REPUID], idx, {}, true, out, {}) end)
            if not ok then err = e; break end
            if out.Added == true then
                for _, h in ipairs(jig.contents_of(comp)) do
                    if not before[h.uid] then return h.uid end
                end
            end
        end
    end
    return nil, err and ("AddNewItemToSlot failed: " .. tostring(err))
        or string.format("no room (%d container(s), %d slot(s) tried)", n, tries)
end

local function consume(comp, h) pcall(function() comp:HandleLocalRequestConsumeItem(jig.guid(h.uid), h.count, comp, "", false) end) end

function jig.apply_contents(comp, want, no_add)
    local have = jig.contents_of(comp)
    local used, mate, mate_uid = {}, {}, {}
    local added, set, removed, missing, pairs_ = 0, 0, 0, 0, {}
    for wi, w in ipairs(want) do
        local holder = w.parent and mate[w.parent]
        if not w.parent or holder then
            for i, h in ipairs(have) do
                if not used[i] and h.da == w.da and h.parent == holder and (w.slot == nil or h.slot == w.slot) then
                    used[i], mate[wi], mate_uid[wi] = true, i, h.uid
                    pcall(function()
                        local it = h.el:get()
                        it[INFO][COUNT] = w.count
                        it[INFO][DURABILITY] = { X = w.dx, Y = w.dy }
                    end)
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
                local uid = jig.add_item(comp, w.da, w.count, w.dx, w.dy, conts)
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
    return set, added, removed, missing, pairs_
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
            out[#out + 1] = { uid = h.uid, da = h.da, count = h.count, dx = h.dx, dy = h.dy, parent = place[h.parent], slot = h.slot }
            place[i] = #out
        end
    end
    return out
end

function jig.fill(comp, holder_uid, list)
    local uid_of, added, missing = { holder_uid }, 0, 0
    for i = 2, #list do
        local w = list[i]
        local hu = w.parent and uid_of[w.parent]
        local uid = nil
        if hu then
            local conts = {}
            for _, c in ipairs(containers_of(comp, hu)) do
                if w.slot == nil or c.slot == w.slot then conts[#conts + 1] = c end
            end
            uid = jig.add_item(comp, w.da, w.count, w.dx, w.dy, conts)
        end
        uid_of[i] = uid
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
        local i = 0
        for _, w in ipairs(want) do
            local asset = not w.parent and jig.asset(w.da)
            if asset then
                i = i + 1
                arr[i] = { [R_ITEM] = asset, [R_CHANCE] = 100.0, [R_MIN] = w.count or 1, [R_MAX] = w.count or 1,
                           [R_PRICE] = -1.0, [R_INDEX] = -1, [R_ROT] = false }
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
            local ok = pcall(function() comp:HandleLocalRequestConsumeItem(jig.guid(h.uid), n, comp, "", false) end)
            if ok then take, taken = take - n, taken + n end
        end
    end
    return taken
end

return jig
