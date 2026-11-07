-- START WITH GPS (a host rule, off by default; user 2026-11-01): every character gets a GPS when it enters the
-- world (a load, a join, a Realm) and when it spawns again after a death, unless it carries one already - worn in
-- the GPS slot or packed anywhere in its inventory. Each game gives its own player one; a guest goes by the host's
-- rule. The GPS goes into a grid (pockets, backpack), never straight into an equipment slot: the game's add doesn't
-- check the item type, and an item put there isn't worn (the game's equip goes through ServerEquippedItems). Then
-- the game's own Equip (the right-click menu's: Context_TryEquip on the item's slot, as padinv's pad equip) puts it
-- in the GPS slot; if that doesn't take, it stays in the pockets.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local jig = require("mirror.jig")
local hostrules = require("mirror.hostrules")

local startgps = {}

local GPS = "/Game/Inventory/Items/DataAssets/Equipment/Tools/DA_GPS.DA_GPS"
-- s after the character spawns: the saved inventory goes in first (a join reloads an empty one ~5-10 s in,
-- session's inv_fix; a Realm's pockets come at 5 s, realmplay)
local WAIT = 12.0
local RETRY = 1.0
local GIVE_UP = 90.0      -- s after the spawn a grant still waiting (loading, no inventory, no host rules) is dropped
-- s from the add (or the last try) to the next equip step: the item's slot widget is made a frame after the add
-- (jig.flush_ui), and the equip is read back a moment after the game's request
local EQUIP_STEP = 0.5
local EQUIP_TRIES = 3

local session
local due, waited = nil, 0.0   -- s until the next look; s since the spawn
local equipping = nil          -- { uid, tries, at }: the GPS just given, on its way to the GPS slot
local stats = { given = 0, had = 0, failed = 0, worn = 0 }

local function inventory()
    local c
    pcall(function() c = game.player().BP_JigMultiplayer end)
    return util.valid(c) and c or nil
end

-- the grids at the top of the inventory: more than one cell (the 1-cell ones are equipment slots)
local function grids(comp)
    local out = {}
    for _, c in ipairs(jig.top_containers(comp)) do
        local _, cells = jig.container_arg(c.raw)
        if cells > 1 then out[#out + 1] = c end
    end
    return out
end

-- why not now (nil = go): the world or the inventory isn't settled, or a guest has no host rules yet
local function not_yet()
    if session.loading() or session.saving() or session.joining() then return "loading" end
    if hostrules.source() == nil then return "no host rules yet" end
    if not util.valid(game.player()) then return "no player" end
    local comp = inventory()
    if not comp or jig.container_count(comp) == 0 then return "no inventory yet" end
    return nil
end

local function grant()
    local comp = inventory()
    if jig.count_of_item(comp, GPS) > 0 then
        stats.had = stats.had + 1
        log.info("startgps: the character has a GPS already")
        return
    end
    local asset = jig.asset(GPS)
    local dx, dy = 0, 0
    pcall(function() dx = asset.Durability or 0; dy = asset.MaxDurability or 0 end)
    local uid, err = jig.add_item(comp, GPS, 1, dx, dy, grids(comp))
    if uid then
        stats.given = stats.given + 1
        log.info("startgps: gave the character a GPS - equipping it")
        equipping = { uid = uid, tries = 0, at = EQUIP_STEP }
    else
        stats.failed = stats.failed + 1
        log.warn("startgps: couldn't give the character a GPS: " .. tostring(err))
        require("mirror.notify").show("START WITH GPS: no room for your GPS.", "bad")
    end
end

local function worn()
    local out = {}
    local ok = pcall(function() game.player()["IsGPSEquipped?"](game.player(), out) end)
    return ok and out["GPS?"] == true
end

-- the game's Equip on the item's slot: it finds the empty slot that takes the item and moves it there
local function try_equip(comp, uid)
    local out = {}
    if not pcall(function() comp:FindItemByUID(jig.guid(uid), out) end) or not util.valid(out.Found) then
        return "its slot isn't made yet"
    end
    local item, grid, root = out.Found, nil, nil
    pcall(function() grid = item.ContainerMother end)
    if not util.valid(grid) then return "its slot has no grid" end
    local o = {}
    pcall(function() grid:GetRootContainerRef(false, o) end)
    root = util.valid(o.ContainerRef) and o.ContainerRef or grid
    local rc
    pcall(function() rc = root.JigMultiplayerComp end)
    if util.valid(rc) then comp = rc end
    local ok, e = pcall(function() comp:Context_TryEquip(item, root) end)
    if not ok then return "the game's equip failed: " .. tostring(e) end
    return nil
end

local function equip_step(dt)
    local q = equipping
    q.at = q.at - dt
    if q.at > 0 then return end
    local note = require("mirror.notify")
    if q.tries > 0 and worn() then
        equipping = nil
        stats.worn = stats.worn + 1
        log.info("startgps: the GPS is worn")
        note.show("You got a GPS (START WITH GPS is on).", "info")
        return
    end
    local comp = inventory()
    if q.tries >= EQUIP_TRIES or not comp or jig.count_of_item(comp, GPS) == 0 then
        equipping = nil
        log.warn("startgps: the GPS isn't worn after " .. q.tries .. " tr" .. (q.tries == 1 and "y" or "ies")
            .. (q.why and (" (" .. q.why .. ")") or "") .. " - left in the inventory")
        note.show("You got a GPS (START WITH GPS is on) - it's in your inventory, equip it there.", "info")
        return
    end
    q.tries, q.at = q.tries + 1, EQUIP_STEP
    q.why = try_equip(comp, q.uid)
end

function startgps.tick(dt)
    if equipping then equip_step(dt) end
    if not due then return end
    waited = waited + dt
    due = due - dt
    if due > 0 then return end
    local why = not_yet()
    if why then
        if waited >= GIVE_UP then
            due = nil
            log.warn("startgps: no GPS check this time (" .. why .. " for " .. math.floor(GIVE_UP) .. " s)")
        else
            due = RETRY
        end
        return
    end
    due = nil
    if hostrules.get("gps") then grant() end
end

function startgps.status()
    return string.format("start gps: given %d (worn %d), had one %d, failed %d", stats.given, stats.worn, stats.had, stats.failed)
end

-- (a respawn or reload drops a GPS still on its way to the slot: its inventory is gone)
-- the character the last check was for (its address), one for every link's copy of this module (peers.lua)
local function seen() return require("mirror.peers").shared_table("startgps") end
local function spawned()
    equipping = nil
    seen().looked_for = util.addr(game.player())
    if game.in_shooting_range() then due = nil; return end
    due, waited = WAIT, 0.0
end
function startgps.init(s)
    session = s
    game.on_new_player(spawned)
    -- a host who loaded the world before hosting: that character's spawn came before this hook, so it had no check
    -- (once per character: hosting again doesn't hand out another; audit 2026-11-03)
    local p = game.player()
    if util.valid(p) and util.addr(p) ~= seen().looked_for and not due then spawned() end
end

return startgps
