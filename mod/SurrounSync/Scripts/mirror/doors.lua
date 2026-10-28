-- Doors, gates and container lids open and close on both screens.

local log = require("mirror.log")
local util = require("mirror.util")
local link = require("mirror.link")

local doors = {}

local KINDS = {
    BP_LockedDoor_C            = { flag = "Closed?", closed_when = true, toggle = "Event_Door", lock = "IsLocked?" },
    BP_WarehouseDoors_C        = { flag = "IsClosed", closed_when = true, toggle = "Event_Door" },
    BP_ContainerDoors_C        = { flag = "Open?", closed_when = false, toggle = "Event_Door" },
    BP_BarrierGate_C           = { flag = "Open?", closed_when = false, toggle = "Event_Door" },
    -- Lab and keycard doors: only the lock state is copied. Their open events use up the keycard.
    BP_LaboratorySlidingDoor_C = { lock = "Locked" },
    Buildable_WoodenDoor_C     = { flag = "IsClosed", closed_when = true, toggle = "Event_OpenDoor", dot = true },
    Buildable_WoodenDoor2_C    = { flag = "IsClosed", closed_when = true, toggle = "Event_OpenDoor", dot = true },
    Buildable_WoodenGate_C     = { flag = "IsClosed", closed_when = true, toggle = "Event_OpenDoor", dot = true },
    Buildable_BunkerDoor_C     = { flag = "IsClosed", closed_when = true, toggle = "Event_OpenDoor", dot = true },
    Buildable_BarricadedMetalDoor_C = { flag = "IsClosed", closed_when = true, toggle = "Event_OpenDoor", dot = true },
    -- Bunker entrances: the keycard scanner calls CallInteractOnObject on its doors (Open? flips when the
    -- door has finished moving). The scanner itself: only whether its keycard was used (the use eats it).
    BP_DoubleBunkerDoor_C          = { flag = "Open?", closed_when = false, toggle = "CallInteractOnObject" },
    BP_LargeBunkerEntrance_C       = { flag = "Open?", closed_when = false, toggle = "CallInteractOnObject" },
    BP_LargeBunkerEntrance_Small_C = { flag = "Open?", closed_when = false, toggle = "CallInteractOnObject" },
    BP_BunkerScanner_C             = { lock = "KeycardRequired?" },
    -- Keycard doors (player report 2026-10-27: one area's doors took a keycard on each game). BP_KeycardDoor uses
    -- up a keycard on every opening and closes itself 30 min later; MC_OpenDoor(actor) only plays the opening
    -- (decompiled): the other game opens its copy with that, facing the other player, and never shuts it (each
    -- closes on its own timer). The keypad door works the same way. The lab's secure doors keep an Unlocked flag
    -- that the keycard sets: copied, the other player opens them for free.
    BP_KeycardDoor_C               = { flag = "Open?", closed_when = false, toggle = "MC_OpenDoor", open_only = true, by_actor = true },
    BP_KeycardDoor_Child_C         = { flag = "Open?", closed_when = false, toggle = "MC_OpenDoor", open_only = true, by_actor = true },
    BP_KeypadDoor_C                = { flag = "Open?", closed_when = false, toggle = "MC_OpenDoor", open_only = true, by_actor = true },
    BP_LaboratorySecureDoors_C     = { unlock = "Unlocked" },
}

local POLL = 0.25
-- One class at a time; util.instances keeps the lists without walking every object in the game.
local RESCAN = 2.0
local EXPECT = 5.0

local cfg, role, session
local peer_live = function() return true end
local list = {}
local last = {}
local expect = {}
local mine, counter = {}, 0
local seen = {}
local pending = {}
local peer_blob = nil
local dirty = false
local active = false
local now, poll_in, scan_in = 0.0, 0.0, 0.0
local stats = { sent = 0, applied = 0, unlocked = 0, missing = 0 }

local function key(obj, cls)
    local l = obj:K2_GetActorLocation()
    return string.format("%s@%d,%d,%d", cls, math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5), math.floor(l.Z / 10 + 0.5))
end

local CLASSES = {}
for cls in pairs(KINDS) do CLASSES[#CLASSES + 1] = cls end
table.sort(CLASSES)
-- Whose ReceiveBeginPlay tells util.instances about new ones (the Master/Lab doors have none).
local function bp(dir, cls) local n = cls:gsub("_C$", ""); return dir .. n .. "." .. cls end
local HOOKS = {
    BP_LockedDoor_C = bp("/Game/Blueprints/Other/Doors/", "BP_LockedDoor_C"),
    BP_WarehouseDoors_C = bp("/Game/Blueprints/Other/Doors/", "BP_WarehouseDoors_C"),
}
for cls in pairs(KINDS) do
    if cls:find("^Buildable_") then HOOKS[cls] = bp("/Game/Blueprints/BuildingSystem/Actors/Doors/", cls) end
end
local scan_idx = 0
local warm = 0

local function rescan_class(cls)
    local objs, walked = util.instances(cls, HOOKS[cls])
    for id, d in pairs(list) do if d.cls == cls then list[id] = nil end end
    local kind = KINDS[cls]
    for _, o in ipairs(objs) do
        -- exact class only: a subclass listed under its parent too (BP_LargeBunkerEntrance_Small) would
        -- get each remote toggle twice - open and straight back shut
        local ok, id = false, nil
        if util.class_name(o) == cls then ok, id = pcall(key, o, cls) end
        if ok then list[id] = { obj = o, kind = kind, cls = cls } end
    end
    return walked
end

local function read(d)
    local open, unlocked
    pcall(function()
        if d.kind.flag then open = (d.obj[d.kind.flag] == true) ~= d.kind.closed_when end
        if d.kind.lock then unlocked = d.obj[d.kind.lock] ~= true end
        if d.kind.unlock then unlocked = d.obj[d.kind.unlock] == true end
    end)
    return open, unlocked
end

local function put()
    local lines = {}
    for id, m in pairs(mine) do
        lines[#lines + 1] = string.format("%s %d %d %d %.3f", id, m.n, m.open == nil and -1 or (m.open and 1 or 0),
            m.unlocked == nil and -1 or (m.unlocked and 1 or 0), m.dot or 0)
    end
    table.sort(lines)
    link.put_blob("doors", table.concat(lines, "\n"))
    dirty = false
end

local function record(id, d, open, unlocked)
    counter = counter + 1
    local dot
    if d.kind.dot then pcall(function() dot = d.obj.DotProduct end) end
    mine[id] = { n = counter, open = open, unlocked = unlocked, dot = type(dot) == "number" and dot or nil }
    dirty = true
    stats.sent = stats.sent + 1
    log.debug(string.format("doors: %s -> %s%s", id, open == nil and "-" or (open and "open" or "closed"),
        unlocked and " (unlocked)" or ""))
end

local function nearest(id)
    local cls, x, y, z = id:match("^([^@]+)@(%-?%d+),(%-?%d+),(%-?%d+)$")
    if not cls then return nil end
    local best, best_d = nil, 10.0
    for oid, d in pairs(list) do
        if d.cls == cls then
            local a, b, c = oid:match("@(%-?%d+),(%-?%d+),(%-?%d+)$")
            local dist = math.sqrt((a - x) ^ 2 + (b - y) ^ 2 + (c - z) ^ 2)
            if dist < best_d then best, best_d = d, dist end
        end
    end
    return best
end
local function apply(id, e)
    local d = list[id] or nearest(id)
    if not d or not util.valid(d.obj) then return false end
    local open, unlocked = read(d)
    local want = { open = open, unlocked = unlocked, ["until"] = now + EXPECT }
    if (d.kind.lock or d.kind.unlock) and e.unlocked == true and unlocked == false then
        local ok = pcall(function()
            if d.kind.lock then d.obj[d.kind.lock] = false else d.obj[d.kind.unlock] = true end
        end)
        want.unlocked = true
        stats.unlocked = stats.unlocked + 1
        log.info("doors: unlocked " .. id .. " (the other player opened it)" .. (ok and "" or " - FAILED"))
    end
    if d.kind.toggle and e.open ~= nil and open ~= nil and e.open ~= open and (e.open or not d.kind.open_only) then
        local ex = expect[id]
        if not (ex and ex.open == e.open and now < ex["until"]) then
            local by = d.kind.by_actor and require("mirror.ghost").get() or nil
            local ok, err = pcall(function() local f = d.obj[d.kind.toggle]; if by then f(d.obj, by) else f(d.obj) end end)
            if ok and e.open and d.kind.dot and e.dot then pcall(function() d.obj.DotProduct = e.dot end) end
            want.open = e.open
            stats.applied = stats.applied + 1
            log.debug("doors: " .. id .. " -> " .. (e.open and "open" or "closed") .. (ok and "" or (" FAILED: " .. tostring(err))))
        end
    end
    expect[id] = want
    return true
end

local function tri(v) if v == "1" then return true elseif v == "0" then return false end return nil end
local function count(t) local c = 0; for _ in pairs(t) do c = c + 1 end; return c end

local function take_peer()
    if not peer_blob then return end
    for line in peer_blob:gmatch("[^\n]+") do
        local id, n, o, u, dot = line:match("^(%S+) (%d+) (%-?%d) (%-?%d) (%S+)$")
        n = tonumber(n)
        if id and n and n > (seen[id] or 0) then
            seen[id] = n
            local e = { open = tri(o), unlocked = tri(u), dot = tonumber(dot) }
            if not apply(id, e) then pending[id] = e end
        end
    end
end

local function set_active(on)
    if on == active then return end
    active = on
    last, expect, seen, pending = {}, {}, {}, {}
    if on then
        list, warm = {}, #CLASSES
        scan_in = RESCAN
        log.info(string.format("doors: syncing (%d doors here)", count(list)))
        take_peer()
    else
        mine = {}
        put()
        log.info("doors: stopped syncing")
    end
end

function doors.tick(dt)
    now = now + dt
    local b = peer_live() and link.get_blob("doors") or nil
    if b then peer_blob = b; if active then take_peer() end end
    set_active(role == "host" or session.in_world())
    if not active then return end

    if warm > 0 then
        if rescan_class(CLASSES[warm]) then warm = warm - 1 end
        return
    end
    scan_in = scan_in - dt
    if scan_in <= 0 then
        scan_in = RESCAN
        scan_idx = scan_idx % #CLASSES + 1
        rescan_class(CLASSES[scan_idx])
        for id, e in pairs(pending) do
            if apply(id, e) then pending[id] = nil end
        end
    end

    poll_in = poll_in - dt
    if poll_in > 0 then return end
    poll_in = POLL
    for id, d in pairs(list) do
        if util.valid(d.obj) then
            local open, unlocked = read(d)
            local was = last[id]
            if not was then
                last[id] = { open = open, unlocked = unlocked }
            elseif open ~= was.open or unlocked ~= was.unlocked then
                last[id] = { open = open, unlocked = unlocked }
                local ex = expect[id]
                if ex and now < ex["until"] and ex.open == open and ex.unlocked == unlocked then
                    expect[id] = nil
                else
                    record(id, d, open, unlocked)
                end
            end
        end
    end
    if dirty then put() end
end

function doors.status()
    if not active then return "doors: idle" end
    local p = count(pending)
    return string.format("doors: %d here, sent %d, applied %d, unlocked %d%s", count(list), stats.sent, stats.applied, stats.unlocked,
        p > 0 and (", waiting " .. p) or "")
end

function doors.init(c, r, s, connected)
    cfg, role, session = c, r, s
    peer_live = connected or peer_live
    if cfg.door_sync == false then role = "off"; session = { in_world = function() return false end } end
    log.info("doors: " .. (role == "off" and "off" or "ready"))
end

return doors
