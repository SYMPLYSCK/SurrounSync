-- Zombie and AI bodies carry the same loot on both screens; taking from one takes from both.

local log = require("mirror.log")
local util = require("mirror.util")
local events = require("mirror.events")
local jig = require("mirror.jig")
local ghost = require("mirror.ghost")

local corpses = {}

local MASTER = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"
local LOOT_CLASSES = { MASTER,
    "/Game/AI/Zombies/Boss/BP_ZombieBoss.BP_ZombieBoss_C",
    "/Game/AI/Humans/Bandits/BP_MasterBandit.BP_MasterBandit_C",
    "/Game/AI/Humans/CoyoteSoldiers/BP_MasterCoyoteSoldier.BP_MasterCoyoteSoldier_C",
    "/Game/AI/Humans/Scavengers/BP_MasterScavenger.BP_MasterScavenger_C",
    "/Game/AI/Humans/Trader/BP_MasterTrader.BP_MasterTrader_C",
    "/Game/AI/Animals/Deer/BP_AnimalDeer.BP_AnimalDeer_C",
    "/Game/AI/Animals/Wolf/BP_AnimalWolf.BP_AnimalWolf_C",
    "/Game/AI/Animals/Bear/BP_AnimalBear.BP_AnimalBear_C",
    "/Game/AI/Animals/Rabbit/BP_AnimalRabbit.BP_AnimalRabbit_C",
    "/Game/AI/Animals/Dog/BP_AnimalDog.BP_AnimalDog_C" }
local INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local ITEM_ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"

local cfg, role, zombies, session
local channel = events.reliable("zloot")
local first_seen = {}
local sent = {}
local dead_seen, dead_sent = {}, {}
local SEND_AFTER = 0.6
local lists = {}
local gate_since = {}
local GATE_WAIT = 1.5
local checked = {}
local takes = {}
local applying = false
local hook_in, scan_in = 0.0, 0.0
local stats = { sent = 0, preset = 0, unpreset = 0, applied = 0, taken = 0, took = 0, missing = 0 }
local preset_logs = 5

local function comp_of(z)
    local c
    pcall(function() c = z.BP_JigMultiplayer end)
    return util.valid(c) and c or nil
end

local function shared() return role == "host" or (session and session.in_world()) end

-- 4 players: the host has a copy of this module per guest (peers.lua), each with its own zombie ids.
--  * Only the main copy turns the host's own takes/put-ins (hooks) into messages; it hands them to the other
--    copies itself, so every guest hears each change exactly once whether or not the game's hooks fire per copy.
--  * A guest's change is applied by that guest's copy and handed to the other copies the same way.
--  * While any copy applies a change the hooks of all copies stay quiet (shared flag): no echo to the sender.
local peers_mod
local function peers() peers_mod = peers_mod or require("mirror.peers"); return peers_mod end
local busy
local function busy_t()
    if not busy then local p = peers(); busy = p.shared and p.shared("corpses_applying", { on = false }) or { on = false } end
    return busy
end
local function set_applying(v) applying = v; busy_t().on = v end
local function hooks_here()
    if applying or busy_t().on or not shared() then return false end
    local p = peers()
    return not (p.role and p.role() == "host" and p.main and p.main("mirror.corpses") ~= corpses)
end
local function relay(fn)
    if role == "host" and peers().relay then peers().relay("mirror.corpses", corpses, fn) end
end

-- Guest: the host's list for a body follows every take and put-in, so applying it again (1 s / 4 s after
-- death) never brings back a looted item or drops one put in. My own moves of the last few seconds are kept
-- and replayed on a list that was already on its way when I made them.
local own = {}
local OWN_KEEP = 10.0
local function total_of(items, da)
    local n = 0
    for _, it in ipairs(items) do if it.da == da then n = n + (it.count or 1) end end
    return n
end
local function drop_items(items, gone)
    local more = true
    while more do
        more = false
        for i, it in ipairs(items) do
            if not gone[i] and it.parent and gone[it.parent] then gone[i], more = true, true end
        end
    end
    local map, out = {}, {}
    for i, it in ipairs(items) do if not gone[i] then out[#out + 1] = it; map[i] = #out end end
    for _, it in ipairs(out) do if it.parent then it.parent = map[it.parent] end end
    return out
end
local function cap_list(l, da, left)
    local extra = total_of(l.items, da) - left
    if extra <= 0 then return end
    local gone = {}
    for i = #l.items, 1, -1 do
        if extra <= 0 then break end
        local it = l.items[i]
        if it.da == da then
            local n = math.min(extra, it.count or 1)
            extra = extra - n
            if n >= (it.count or 1) then gone[i] = true else it.count = it.count - n end
        end
    end
    l.items = drop_items(l.items, gone)
end
local function grow_list(l, da, count, dx, dy, place, inside)
    local base = #l.items
    local sub = inside and inside ~= "" and jig.decode(inside) or nil
    if sub and sub[1] and sub[1].da == da then
        for i, it in ipairs(sub) do
            if i == 1 then it.parent, it.slot, it.cell, it.rot = nil, place and place.slot, place and place.cell, place and place.rot
            elseif it.parent then it.parent = it.parent + base end
            l.items[#l.items + 1] = it
        end
    else
        l.items[#l.items + 1] = { da = da, count = count, dx = dx, dy = dy,
                                  slot = place and place.slot, cell = place and place.cell, rot = place and place.rot }
    end
end
local function list_took(id, da, left, mine)
    if role == "host" then return end
    if lists[id] then cap_list(lists[id], da, left) end
    if mine then own[id] = own[id] or {}; table.insert(own[id], { at = zombies.now(), da = da, left = left }) end
end
local function list_added(id, da, count, dx, dy, place, inside, have)
    if role == "host" then return end
    if lists[id] then grow_list(lists[id], da, count, dx, dy, place, inside) end
    if have then
        own[id] = own[id] or {}
        table.insert(own[id], { at = zombies.now(), da = da, have = have, add = { count, dx, dy, place, inside } })
    end
end
local function replay_own(id)
    local l, mv = lists[id], own[id]
    if not (l and mv) then return end
    local t, keep = zombies.now(), {}
    for _, m in ipairs(mv) do
        if t - m.at <= OWN_KEEP then
            keep[#keep + 1] = m
            if m.left then cap_list(l, m.da, m.left)
            elseif total_of(l.items, m.da) < m.have then grow_list(l, m.da, m.add[1], m.add[2], m.add[3], m.add[4], m.add[5]) end
        end
    end
    own[id] = #keep > 0 and keep or nil
end
local function traded() if session and session.checkpoint and shared() then session.checkpoint("corpses") end end
channel.send = function(self, p) if p:find("^A ") then traded() end return events.send(self, p) end

local function is_dead(z)
    local d = false
    pcall(function() d = zombies.dead_of(z) end)
    return d
end

local function corpse(id)
    if role == "host" then
        local z = zombies.host_zombies()[id]
        return util.valid(z) and z or nil
    end
    local c = zombies.copy(id)
    -- a living trader's stock is shared too (buying = taking from it)
    return c and util.valid(c.z) and (c.dead_at or c.trader) and c.z or nil
end

-- Rolling a body's loot (InitializeJigComponent) costs ~10-30 ms: a guest joining or a horde arriving
-- made 40 at once = a 0.3-1.3 s freeze. Each scan now stops after SCAN_BUDGET s of that work and runs
-- again next frame until the backlog is gone (40 bodies ~ 1 s, inside the guest's GATE_WAIT).
local SCAN_BUDGET = 0.004
local backlog = false
local function host_scan()
    local t = zombies.now()
    local t0, did = os.clock(), false
    backlog = false
    if not (ghost.exists() or (session and session.guest_in_world())) then
        first_seen, sent, dead_seen, dead_sent = {}, {}, {}, {}
        return
    end
    for id, z in pairs(zombies.host_zombies()) do
        if did and os.clock() - t0 > SCAN_BUDGET then backlog = true; break end
        if not first_seen[id] then first_seen[id] = t end
        if not sent[id] and t - first_seen[id] >= SEND_AFTER and util.valid(z) then
            did = true
            local comp = comp_of(z)
            if comp then
                jig.generate(comp)
                sent[id] = true
                local list = jig.contents_of(comp)
                channel:send("L " .. id .. " " .. jig.encode(list))
                stats.sent = stats.sent + 1
            end
        end
        -- death can change what a body holds (a trader's stock empties and money is added; the game may
        -- roll death loot): send what the body holds once that's done, so the guest's corpse matches
        if sent[id] and not dead_sent[id] and is_dead(z) then
            dead_seen[id] = dead_seen[id] or t
            local comp = t - dead_seen[id] >= 1.0 and comp_of(z)
            if comp then
                did = true
                dead_sent[id] = true
                local list = jig.contents_of(comp)
                channel:send("L " .. id .. " " .. jig.encode(list))
                log.debug(string.format("corpses: zombie %d died holding %d item(s) - sent to the guest", id, #list))
            end
        end
    end
    for id in pairs(first_seen) do
        if not zombies.host_zombies()[id] then
            first_seen[id], sent[id], dead_seen[id], dead_sent[id] = nil, nil, nil, nil
        end
    end
end

local function spawn_gate(id)
    if not shared() or lists[id] then return true end
    local t = zombies.now()
    gate_since[id] = gate_since[id] or t
    return t - gate_since[id] >= GATE_WAIT
end

local function on_spawned(id, z)
    gate_since[id] = nil
    local l = lists[id]
    local comp = comp_of(z)
    if not (l and comp) then stats.unpreset = stats.unpreset + 1; return end
    local n, miss = jig.set_starting(comp, l.items)
    if n then stats.preset = stats.preset + 1 else stats.unpreset = stats.unpreset + 1 end
    if preset_logs > 0 or not n then
        preset_logs = preset_logs - 1
        log.info(string.format("corpses: zombie %d's copy will carry the host's %d item(s)%s", id, #l.items,
            n and (miss > 0 and (" (" .. miss .. " not loaded here)") or "") or (" - FAILED: " .. tostring(miss))))
    end
end

local function guest_check()
    local t = zombies.now()
    for id, c in pairs(zombies.copies()) do
        if c.trader == nil then c.trader = zombies.is_trader(c.z) end
        local since = c.dead_at or (c.trader and c.born)
        -- a trader checked alive is checked again once dead (its own death empties it and adds money);
        -- a corpse is checked 1 s after death and again at 4 s, after anything the game adds on death here
        local st = checked[id]
        local due, wait = not st, 1.0
        if st == "alive" and c.dead_at then due = true elseif st == "first" then due, wait = true, 4.0 end
        if since and due and lists[id] and t - since > wait and util.valid(c.z) then
            checked[id] = (not c.dead_at and "alive") or (st == "first" and true) or "first"
            local comp = comp_of(c.z)
            if comp then
                -- a trader's stock is made on its first init: make it now so applying the host's list doesn't add it twice
                if c.trader and not c.dead_at then jig.generate(comp) end
                set_applying(true)
                local ok, set, added, removed, missing = pcall(jig.apply_contents, comp, lists[id].items)
                set_applying(false)
                if not ok then error(set) end
                stats.applied = stats.applied + 1
                stats.missing = stats.missing + missing
                log.info(string.format("corpses: zombie %d's corpse holds the host's loot (%d items: %d matched, %d added, %d removed%s)",
                    id, #lists[id].items, set, added, removed,
                    missing > 0 and (", " .. missing .. " couldn't be added (not loaded here / no room)") or ""))
            end
        end
    end
    for id, l in pairs(lists) do
        if not zombies.copy(id) and t - l.at > 300 then lists[id], checked[id], own[id] = nil, nil, nil end
    end
end

local function on_removed(self, ItemRemovedInfo)
    if not hooks_here() then return end
    local z = self:get()
    local id = role == "host" and zombies.host_id_of(z) or zombies.copy_id_of(z)
    if not id then return end
    local da, n
    pcall(function() da = jig.full_path(ItemRemovedInfo:get()[INFO][ITEM_ID]) end)
    pcall(function() n = tonumber(ItemRemovedInfo:get()[INFO][COUNT]) end)
    if da then takes[#takes + 1] = { z = z, id = id, da = da, n = n } end
end

local function flush_takes()
    if #takes == 0 then return end
    for _, tk in ipairs(takes) do
        local comp = util.valid(tk.z) and comp_of(tk.z)
        if comp then
            local left = jig.count_of_item(comp, tk.da)
            -- what this take removed: the host's list said how many there were (the hook's count may be the stack's)
            local took = tk.n
            local l = lists[tk.id]
            if role ~= "host" and l then
                local before = 0
                for _, w in ipairs(l.items or {}) do if w.da == tk.da then before = before + (w.count or 1) end end
                took = math.min(took or math.huge, math.max(0, before - left))
                if took == math.huge then took = nil end
            end
            channel:send(string.format("T %d %s %d", tk.id, tk.da, left) .. (took and took > 0 and (" " .. took) or ""))
            stats.took = stats.took + 1
            list_took(tk.id, tk.da, left, true)
            relay(function(m) m.relay_take(tk.z, tk.da) end)
        end
    end
    takes = {}
end

-- Host: the guest took more than this body still has (the host or another guest took it at the same moment):
-- both had it. The host's world decides - the guest gives the surplus back ("G").
local function give_back(da, n)
    local pc
    pcall(function() pc = require("mirror.game").player().BP_JigMultiplayer end)
    if not util.valid(pc) then return end
    local name = (da:match("([%w_]+)$") or "item"):gsub("^DA_", "")
    local done = 0
    for _, h in ipairs(jig.contents_of(pc)) do
        if done >= n then break end
        if h.da == da and not h.parent then
            local k = math.min(n - done, h.count or 1)
            set_applying(true)
            local ok = jig.take(pc, h.uid, k, h.count or 1)
            set_applying(false)
            if ok then done = done + k end
        end
    end
    log.warn(string.format("corpses: took %d %s from a body someone else looted at the same moment - gave back %d (no duplicate)", n, name, done))
    if done > 0 then require("mirror.notify").show("Someone else took that " .. name .. " at the same moment - they keep it.", "info") end
end

local function apply_take(id, da, left, took)
    list_took(id, da, left)
    local z = corpse(id)
    local comp = z and comp_of(z)
    if not comp then return end
    if role == "host" and took and took > 0 then
        local have = jig.count_of_item(comp, da)
        if have < took then
            channel:send(string.format("G %d %s %d", id, da, took - have))
            left = 0
        end
    end
    set_applying(true)
    local ok, n = pcall(jig.reduce_item, comp, da, left)
    set_applying(false)
    if not ok then error(n) end
    relay(function(m) m.relay_take(z, da) end)
    if n > 0 then
        stats.taken = stats.taken + 1
        log.info(string.format("corpses: the other player took %d %s from zombie %d - taken here too", n, da:match("[^%.]+$") or da, id))
    end
end

-- Taken from a body onto a stack in the bag (loot.lua's stack hook): the game fires no removed event for it,
-- and the host's list put the ammo back on the copy - every merge duplicated it (same as the nails, 2026-10-25).
function corpses.stack_take(z, da)
    if not hooks_here() or not util.valid(z) then return false end
    local id = role == "host" and zombies.host_id_of(z) or zombies.copy_id_of(z)
    if not id then return false end
    takes[#takes + 1] = { z = z, id = id, da = da, n = nil }
    return true
end

-- Host, another guest's copy: a body changed (the host or a guest took from it) - tell my guest what's left.
function corpses.relay_take(z, da)
    if role ~= "host" or not shared() then return end
    local id = zombies.host_id_of(z)
    local comp = id and sent[id] and util.valid(z) and comp_of(z)
    if not comp then return end
    channel:send(string.format("T %d %s %d", id, da, jig.count_of_item(comp, da)))
    stats.took = stats.took + 1
end

local removed_fn = function(self, FromContainerUID, ItemUID, ContainerName, ItemRemovedInfo)
    util.safe(on_removed, "corpses.removed", self, ItemRemovedInfo)
end

local item_removed_fn = function(self, ItemUID, FromUID, ToContainer, To)
    util.safe(function()
        if not hooks_here() then return end
        local z = self:get()
        local id = role == "host" and zombies.host_id_of(z) or zombies.copy_id_of(z)
        if not id then return end
        local uid, to
        pcall(function() uid = jig.uid_str(ItemUID:get()) end)
        pcall(function() to = To:get() end)
        if not (uid and util.valid(to)) then return end
        for _, it in ipairs(jig.contents_of(to)) do
            if it.uid == uid then takes[#takes + 1] = { z = z, id = id, da = it.da }; return end
        end
    end, "corpses.item_removed")
end

local added_once = {}
local function add_line(id, uid, it, inside_s)
    return string.format("A %d %s %s %d %.3f %.3f %d:%d:%d", id, uid, it.da, it.count, it.dx, it.dy,
        it.cell or -1, it.rot and 1 or 0, it.slot or -1) .. (inside_s ~= "" and (" " .. inside_s) or "")
end
local function item_of(comp, uid)
    for _, it in ipairs(jig.contents_of(comp)) do
        if it.uid == uid and it.da then
            local inside = jig.subtree(comp, uid)
            return it, jig.worth_sending(inside) and jig.encode(inside) or ""
        end
    end
end
local item_added_fn = function(self, ItemUID)
    util.safe(function()
        if not hooks_here() then return end
        local z = self:get()
        local id = role == "host" and zombies.host_id_of(z) or zombies.copy_id_of(z)
        local comp = z and comp_of(z)
        if not (id and comp) then return end
        local uid
        pcall(function() uid = jig.uid_str(ItemUID:get()) end)
        if not uid or added_once[uid] then return end
        local it, inside_s = item_of(comp, uid)
        if not it then return end
        added_once[uid] = true
        channel:send(add_line(id, uid, it, inside_s))
        list_added(id, it.da, it.count, it.dx, it.dy, { slot = it.slot, cell = it.cell, rot = it.rot }, inside_s,
            jig.count_of_item(comp, it.da))
        relay(function(m) m.relay_add(z, uid) end)
        log.info(string.format("corpses: put %s x%d into zombie %d's corpse - telling the other game",
            it.da:match("[^%.]+$") or it.da, it.count, id))
    end, "corpses.item_added")
end

-- Host, another guest's copy: something was put into a body (by the host or a guest) - tell my guest.
function corpses.relay_add(z, uid)
    if role ~= "host" or not shared() or added_once[uid] then return end
    local id = zombies.host_id_of(z)
    local comp = id and sent[id] and util.valid(z) and comp_of(z)
    if not comp then return end
    local it, inside_s = item_of(comp, uid)
    if not it then return end
    added_once[uid] = true
    channel:send(add_line(id, uid, it, inside_s))
end

local function apply_add(id, uid, da, count, dx, dy, inside, place)
    if added_once[uid] then return end
    added_once[uid] = true
    list_added(id, da, count, dx, dy, place, inside)
    local z = corpse(id)
    local comp = z and comp_of(z)
    if not comp then log.info("corpses: the other player put an item into zombie " .. id .. "'s corpse - no corpse here"); return end
    set_applying(true)
    local ok, mine, err = pcall(jig.add_item, comp, da, count, dx, dy, nil, place)
    if ok and mine and inside ~= "" then pcall(jig.fill, comp, mine, jig.decode(inside)) end
    set_applying(false)
    if not ok then error(mine) end
    if mine then
        added_once[mine] = true
        relay(function(m) m.relay_add(z, mine) end)
    end
    log.info(string.format("corpses: the other player put %s x%d into zombie %d's corpse - %s", da:match("[^%.]+$") or da,
        count, id, mine and "added here" or ("couldn't add: " .. tostring(err))))
end

function corpses.tick(dt)
    if role == "off" or not role then return end
    util.safe(jig.flush_ui, "jig.ui")
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 1.0
        for _, cl in ipairs(LOOT_CLASSES) do
            util.ensure_hook(cl .. ":JigMP_OnMainContainerItemRemoved", removed_fn)
            util.ensure_hook(cl .. ":JigMP_OnItemRemoved", item_removed_fn)
            util.ensure_hook(cl .. ":JigMP_OnItemAdded", item_added_fn)
        end
        if not shared() then lists, gate_since, checked = {}, {}, {} end
    end
    util.safe(flush_takes, "corpses.takes")
    scan_in = scan_in - dt
    if scan_in <= 0 then
        scan_in = backlog and 0 or 0.25
        if role == "host" then util.job("corpses.scan", util.safe, host_scan, "corpses.scan") else util.safe(guest_check, "corpses.check") end
    end
    channel:pump(function(p)
        if not shared() then return end
        local k = p:sub(1, 1)
        if k == "A" then traded() end
        if k == "L" and role ~= "host" then
            local id, rest = p:match("^L (%d+) ?(.*)$")
            if id then
                id = tonumber(id)
                lists[id], checked[id] = { items = jig.decode(rest), at = zombies.now() }, nil
                replay_own(id)
            end
        elseif k == "T" then
            local id, da, left, took = p:match("^T (%d+) (%S+) (%-?%d+) ?(%d*)$")
            if id then util.safe(apply_take, "corpses.take", tonumber(id), da, tonumber(left) or 0, tonumber(took)) end
        elseif k == "G" and role ~= "host" then
            local _, da, n = p:match("^G (%d+) (%S+) (%d+)$")
            if da then util.safe(give_back, "corpses.give_back", da, tonumber(n)) end
        elseif k == "A" then
            local id, uid, da, n, dx, dy, cell, rot, slot, inside =
                p:match("^A (%d+) (%S+) (%S+) (%-?%d+) (%S+) (%S+) (%-?%d+):(%d):(%-?%d+) ?(%S*)$")
            if id then
                local place = { cell = tonumber(cell) >= 0 and tonumber(cell) or nil, rot = rot == "1",
                                slot = tonumber(slot) >= 0 and tonumber(slot) or nil }
                util.safe(apply_add, "corpses.add", tonumber(id), uid, da, tonumber(n) or 1, tonumber(dx) or 0, tonumber(dy) or 0, inside, place)
            end
        end
    end)
end

function corpses.status()
    return string.format("corpse loot: sent %d, copies preset %d (not %d), corpses checked %d%s | taken: reported %d, applied %d",
        stats.sent, stats.preset, stats.unpreset, stats.applied,
        stats.missing > 0 and (" (" .. stats.missing .. " items missing)") or "", stats.took, stats.taken)
end

function corpses.init(c, r, z, s)
    cfg, role, zombies, session = c, r, z, s
    if cfg.corpse_loot_sync == false then role = "off" end
    if role == "guest" then zombies.set_copy_hooks(spawn_gate, on_spawned) else zombies.set_copy_hooks(nil, nil) end
    log.info("corpses: " .. (role == "off" and "off" or "zombie loot is the same for both players"))
end

return corpses
