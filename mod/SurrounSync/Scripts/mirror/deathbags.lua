-- The bag a player drops on death, visible and lootable for both players.

local log = require("mirror.log")
local util = require("mirror.util")
local events = require("mirror.events")
local jig = require("mirror.jig")
local uiremove = require("mirror.uiremove")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local link = require("mirror.link")
local fs = require("mirror.fs")

local deathbags = {}

local BAG = "/Game/Inventory/Containers/Container_DeadPlayerLoot.Container_DeadPlayerLoot_C"
local UID = require("mirror.fields").UID
local C_NAME = "ContainerName_13_2E875F304DF2B4B31A44F98C299C3982"
local C_EQUIP = "IsEquipTo?_17_A70EBD1B42E398B0EB14E0B352CCC0A2"
local C_COLS = "Columns_4_A32AA159420F47D951669C9636084F9D"
local C_ROWS = "Rows_6_E1A84D8A441B19CA3C38D0BC029805A1"
local COLS = 10

local MATCH = 150
local FIND_RADIUS = 400
local GIVE_UP = 60.0

local cfg, role, session
local together = function() return false end
local bags = events.new("dbag", 4, 900)
local peers = require("mirror.peers")
-- (reliable: an expired last state left the taken items in the other copy of the bag - a duplicate)
local takes = events.reliable("dbagt", 32)
local clock = 0.0
local owners_path = nil
local relabel_at = nil
local sent_keys = {}
local death = nil
local watch = nil
local copies = {}
local received = {}
local together_at = nil
local spawning = false
local applying = false
local dirty = {}
local hook_in = 0.0
local stats = { sent = 0, made = 0, failed = 0, missing = 0, took = 0, taken = 0 }

local function key_of(a)
    local k
    pcall(function() k = util.fname(a) end)
    return k
end

local function loc_of(a)
    local l
    pcall(function() l = util.vec(a:K2_GetActorLocation()) end)
    return l
end

local function comp_of(a)
    local c
    pcall(function() c = a.BP_JigMultiplayer end)
    return util.valid(c) and c or nil
end

local function all_bags()
    local out = {}
    pcall(function()
        for _, b in ipairs(FindAllOf("Container_DeadPlayerLoot_C") or {}) do
            if util.valid(b) then out[#out + 1] = b end
        end
    end)
    return out
end

local function nearest(loc, within)
    local best, bd = nil, within
    for _, b in ipairs(all_bags()) do
        local l = loc_of(b)
        local d = l and util.dist(l, loc) or math.huge
        if d <= bd then best, bd = b, d end
    end
    return best
end

local function traded() if session and session.checkpoint then session.checkpoint("death bag") end end

local function counts(comp)
    local n = {}
    for _, h in ipairs(jig.contents_of(comp)) do
        if h.da then n[h.da] = (n[h.da] or 0) + (h.count or 1) end
    end
    return n
end

local function loc_str(l) return string.format("%.1f %.1f %.1f", l.X, l.Y, l.Z) end

local MAX_OWNERS = 40

local function read_owners()
    local out = {}
    for line in ((owners_path and fs.read(owners_path())) or ""):gmatch("[^\r\n]+") do
        local x, y, z, text = line:match("^(%S+) (%S+) (%S+)|(.+)$")
        if text then out[#out + 1] = { loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, text = text } end
    end
    return out
end

local function remember_owner(l, text)
    if not (owners_path and l) then return end
    local list = read_owners()
    for i = #list, 1, -1 do if util.dist(list[i].loc, l) < MATCH then table.remove(list, i) end end
    list[#list + 1] = { loc = l, text = text }
    while #list > MAX_OWNERS do table.remove(list, 1) end
    local out = {}
    for _, o in ipairs(list) do out[#out + 1] = string.format("%.0f %.0f %.0f|%s", o.loc.X, o.loc.Y, o.loc.Z, o.text) end
    fs.write(owners_path(), table.concat(out, "\n") .. "\n")
end

local function label(bag, text, remember)
    if not util.valid(bag) then return end
    if remember then remember_owner(loc_of(bag), text) end
end

local function relabel()
    local owners = read_owners()
    if #owners == 0 then return end
    local n = 0
    for _, b in ipairs(all_bags()) do
        local l = loc_of(b)
        for _, o in ipairs(owners) do
            if l and util.dist(l, o.loc) < MATCH then label(b, o.text, false); n = n + 1; break end
        end
    end
    if n > 0 then log.info("deathbags: labelled " .. n .. " bag(s) with their owner again") end
end

local function on_spawn_loot(self)
    local p
    pcall(function() p = self:get() end)
    if not p or require("mirror.peers").is_ghost(p) then return end
    local before = {}
    for k in pairs(sent_keys) do before[k] = true end
    local l = loc_of(p)
    if not l or (math.abs(l.X) < 1 and math.abs(l.Y) < 1) then
        pcall(function() l = util.vec(p.Mesh:K2_GetComponentLocation()) end)
    end
    death = { at = clock, loc = l, before = before, scan_at = 0.0 }
    watch = nil
    log.info("deathbags: I died at " .. (l and loc_str(l) or "?") .. " - watching for my bag")
end

local function watch_tick(dt)
    if not death then return end
    if not watch then
        if clock - death.at < 0.3 or clock < death.scan_at then return end
        -- each scan is a full object walk: fast while the bag normally appears, then backing off (a death with
        -- no bag - the difficulty keeps the items - walked 240 times in the minute before giving up)
        local since = clock - death.at
        death.scan_at = clock + (since < 5 and 0.25 or since < 20 and 1.0 or 3.0)
        local best, bd, seen = nil, FIND_RADIUS, {}
        for _, b in ipairs(death.loc and all_bags() or {}) do
            local k, l = key_of(b), loc_of(b)
            local d = l and util.dist(l, death.loc) or math.huge
            if k and not death.before[k] and not copies[k] then
                seen[#seen + 1] = string.format("%s %.0f m", k, d / 100)
                if d <= bd then best, bd = b, d end
            end
        end
        death.seen = seen
        if best then
            watch = { bag = best, key = key_of(best), loc = loc_of(best), still = 0.0 }
            log.info(string.format("deathbags: my bag is %s, %.0f m from where I died - sending once it lies still", watch.key, bd / 100))
        elseif clock - death.at > GIVE_UP then
            log.info("deathbags: no bag after my death (the difficulty keeps or loses all items); new bags: "
                .. (#(death.seen or {}) > 0 and table.concat(death.seen, ", ") or "none"))
            death = nil
        end
        return
    end
    local l = loc_of(watch.bag)
    if not l then
        log.info("deathbags: lost sight of my bag " .. tostring(watch.key) .. " - looking again")
        watch = nil
        return
    end
    if util.dist(l, watch.loc) > 2 then watch.loc, watch.still = l, 0.0 else watch.still = watch.still + dt end
    if watch.still < 0.6 and clock - death.at < GIVE_UP then return end
    local comp = comp_of(watch.bag)
    local items = comp and jig.contents_of(comp) or {}
    local watch_key, my_bag = watch.key, watch.bag
    death, watch = nil, nil
    if not together() then
        log.info(string.format("deathbags: my bag (%d items) stays in this world - the other player isn't here", #items))
        return
    end
    sent_keys[watch_key or ""] = true
    label(my_bag, "Your bag", true)
    bags:send(string.format("B %d %s %s %s", os.time(), watch_key, loc_str(l), jig.encode(items)))
    stats.sent = stats.sent + 1
    traded()
    log.info(string.format("deathbags: my bag (%d items) -> the other player's world", #items))
end

local function grid_rows(items)
    local cells, tallest = 0, 1
    for _, w in ipairs(items) do
        local x, y = 1, 1
        local a = jig.asset(w.da)
        if a then pcall(function() local v = a.SlotDimensions; x, y = v.X, v.Y end) end
        cells = cells + x * y
        tallest = math.max(tallest, x, y)
    end
    return math.max(6, math.ceil(cells * 1.5 / COLS) + tallest)
end

local function make_copy(from, loc, items)
    if received[from] then return end
    received[from] = true
    local cls = StaticFindObject(BAG)
    if not util.valid(cls) or not game.world() then
        stats.failed = stats.failed + 1
        log.warn("deathbags: can't place the other player's bag (bag class not loaded here)")
        return
    end
    local bag
    spawning = true
    local ok, err = pcall(function() bag = game.world():SpawnActor(cls, loc, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    spawning = false
    if not (ok and util.valid(bag)) then
        stats.failed = stats.failed + 1
        log.warn("deathbags: couldn't place the other player's bag: " .. tostring(err))
        return
    end
    local k = key_of(bag)
    if k then copies[k] = true end
    label(bag, link.peer_name() .. "'s bag", true)
    local comp = comp_of(bag)
    if not comp then
        stats.failed = stats.failed + 1
        log.warn("deathbags: the other player's bag has no inventory here")
        return
    end
    local grid, slot = "?", 1
    local made, why = pcall(function()
        local arr = comp.ContainersSettings
        local n = arr:GetArrayNum()
        if n == 0 then
            arr[1] = { [C_NAME] = FName("DeadPlayerLoot"), [C_EQUIP] = false, [C_COLS] = COLS, [C_ROWS] = grid_rows(items) }
            grid = string.format("own %dx%d", COLS, grid_rows(items))
            return
        end
        local layout = {}
        for i = 1, n do
            local e, nm = arr[i], "?"
            pcall(function() nm = e[C_NAME]:ToString() end)
            layout[#layout + 1] = string.format("%s %sx%s", nm, tostring(e[C_COLS]), tostring(e[C_ROWS]))
        end
        arr[n + 1] = { [C_NAME] = FName("DeadPlayerLoot"), [C_EQUIP] = false, [C_COLS] = COLS, [C_ROWS] = grid_rows(items) }
        slot = n + 1
        grid = string.format("own %dx%d after %d slot(s)", COLS, grid_rows(items), n)
        log.info("deathbags: bag layout " .. table.concat(layout, ", "))
    end)
    local written, missing = nil, nil
    if made then written, missing = jig.set_starting(comp, items, slot) end
    if not written then
        stats.failed = stats.failed + 1
        log.warn("deathbags: couldn't fill the other player's bag: " .. tostring(made and missing or why))
        return
    end
    jig.generate(comp)
    applying = true
    local set, added, removed, absent = jig.apply_contents(comp, items)
    applying = false
    stats.made = stats.made + 1
    stats.missing = stats.missing + absent
    traded()
    log.info(string.format("deathbags: the other player's bag is here (grid %s; %d items: %d placed, %d added, %d removed%s)",
        grid, #items, set, added, removed, absent > 0 and (", " .. absent .. " not loaded in this game / no room") or ""))
    if absent > 0 then
        local lost = {}
        for _, w in ipairs(items) do
            if jig.count_of_item(comp, w.da) < (w.count or 1) then
                lost[#lost + 1] = string.format("%s x%d (%s)", tostring(w.da):match("([^%./]+)$") or tostring(w.da),
                    w.count or 1, jig.asset(w.da) and "loaded, no room?" or "not loaded here")
            end
        end
        log.info("deathbags: not in the copy: " .. table.concat(lost, ", "))
    end
end

-- uid nil = a removal of unknown item (always sent); only removals that are all the UI's no-room ones are skipped
-- (checked at flush: the marker hook runs after these events)
local function on_removed(self, uid)
    if applying or spawning or not together() then return end
    local b = self:get()
    local k = b and key_of(b)
    if not k then return end
    local d = dirty[k] or { b = b, uids = {} }
    dirty[k] = d
    if uid then d.uids[#d.uids + 1] = uid else d.real = true end
end

local function only_ui(d)
    if d.real or not d.uids[1] then return false end
    for _, u in ipairs(d.uids) do if not uiremove.is(u) then return false end end
    return true
end

local function flush_takes()
    for k, d in pairs(dirty) do
        local b = d.b
        local comp = not only_ui(d) and util.valid(b) and comp_of(b)
        local l = comp and loc_of(b)
        if l then
            local list = {}
            for da, n in pairs(counts(comp)) do list[#list + 1] = { da = da, count = n } end
            takes:send(string.format("S %d %s %s", os.time(), loc_str(l), jig.encode(list)))
            stats.took = stats.took + 1
            traded()
        end
        dirty[k] = nil
    end
end

local function apply_state(loc, rest)
    local b = nearest(loc, MATCH)
    local comp = b and comp_of(b)
    if not comp then return end
    local want = {}
    for _, w in ipairs(jig.decode(rest)) do want[w.da] = (want[w.da] or 0) + w.count end
    local n = 0
    applying = true
    for da, have in pairs(counts(comp)) do
        if have > (want[da] or 0) then n = n + jig.reduce_item(comp, da, want[da] or 0) end
    end
    applying = false
    if n > 0 then
        stats.taken = stats.taken + 1
        traded()
        log.info(string.format("deathbags: the other player took %d item(s) from a bag - taken here too", n))
    end
end

local function parse(p)
    local stamp, x, y, z, rest = p:match("^(%d+) (%S+) (%S+) (%S+) ?(.*)$")
    if not stamp or not together_at then return nil end
    if link.peer_age(tonumber(stamp)) > os.time() - together_at + 5 then return nil end
    return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, rest
end

local removed_fn = function(self, FromContainerUID, ItemUID)
    local uid
    pcall(function() uid = jig.uid_str(ItemUID:get()) end)
    util.safe(on_removed, "deathbags.removed", self, uid)
end
-- a player's rip/eat out of the bag fires JigMP_OnItemConsumed on the player, not the bag (see loot.lua
-- consume_req_fn): the bag's component runs HandleLocalRequestConsumeItem
local consumed_fn = function(self, ConsumedItem)
    local uid
    pcall(function() uid = jig.uid_str(ConsumedItem:get()[UID]) end)
    util.safe(on_removed, "deathbags.consumed", self, uid)
end
local consume_req_fn = function(self, ItemUID)
    util.safe(function()
        local comp, b, uid = util.obj(self), nil, nil
        pcall(function() uid = jig.uid_str(ItemUID:get()) end)
        if comp then pcall(function() b = comp:GetOwner() end) end
        if util.valid(b) and util.class_name(b) == "Container_DeadPlayerLoot_C" then on_removed({ get = function() return b end }, uid) end
    end, "deathbags.consume_request")
end

function deathbags.tick(dt)
    if role == "off" then return end
    clock = clock + dt
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 1.0
        util.ensure_hook(BAG .. ":JigMP_OnMainContainerItemRemoved", removed_fn)
        -- used out of the bag (rip, eat...): consumed fires no removed event
        util.ensure_hook(BAG .. ":JigMP_OnItemConsumed", consumed_fn)
        uiremove.ensure_hook()
        util.ensure_hook("/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:HandleLocalRequestConsumeItem", consume_req_fn)
    end
    util.safe(watch_tick, "deathbags.watch", dt)
    if relabel_at and clock >= relabel_at then relabel_at = nil; util.safe(relabel, "deathbags.relabel") end
    util.safe(flush_takes, "deathbags.takes")
    if together() then together_at = together_at or os.time() else together_at = nil end
    bags:pump(function(p)
        local stamp, from, body = p:match("^B (%d+) (%S+) (.*)$")
        if not (stamp and together()) then return end
        local loc, rest = parse(stamp .. " " .. body)
        if loc then util.safe(function() make_copy(from .. "@" .. stamp, loc, jig.decode(rest)) end, "deathbags.copy") end
        -- host, more than two players: the other guests get the bag too (stamped with this clock, theirs is the host's)
        if loc then
            local again = string.format("B %d %s %s", os.time(), from, body)
            peers.relay("mirror.deathbags", deathbags, function(m) m.relay_bag(again) end)
        end
    end)
    takes:pump(function(p)
        local body = p:match("^S (.*)$")
        if not (body and together()) then return end
        local loc, rest = parse(body)
        if loc then util.safe(apply_state, "deathbags.state", loc, rest) end
    end)
end

function deathbags.relay_bag(p) bags:send(p) end

function deathbags.status()
    return string.format("death bags: sent %d, copies %d (failed %d%s) | taken: reported %d, applied %d",
        stats.sent, stats.made, stats.failed, stats.missing > 0 and (", " .. stats.missing .. " items missing") or "",
        stats.took, stats.taken)
end

-- Respawn/reload: the old world's objects are freed - drop them without touching them.
local function forget_world() watch = nil end
function deathbags.init(c, r, s, same_world)
    game.on_world_reset(forget_world)
    cfg, role, session = c, r, s
    together = same_world or together
    if cfg.death_bag_sync ~= true then role = "off" end
    -- (a function: a hosted Realm keeps its own file)
    owners_path = s and s.data_file and function() return s.data_file("mirror_coop_bags.txt") end
    game.on_new_player(function() relabel_at = clock + 5.0 end)
    game.player_hook("SpawnDeadPlayerLoot", function(self) util.safe(on_spawn_loot, "deathbags.died", self) end)
    log.info("deathbags: " .. (role == "off" and "off" or "a player's death bag shows up in both worlds"))
end

return deathbags
