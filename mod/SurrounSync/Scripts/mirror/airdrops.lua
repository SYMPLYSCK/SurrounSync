-- Airdrops follow the host.
--
-- Each game runs its own: BP_EventManager rolls a timer + chance, flies an AirdropAircraft over a random region and
-- the plane drops 1-3 crates of random classes at random moments (decompiled 2026-10-29). So the host and the guest
-- got different planes and crates, and a crate's shared loot never matched (user: "airdrops aren't synced").
-- The host sends where its crates came to rest; a joined guest gets the same crate at the same spot (spawned a little
-- above it so it lands like a real drop - parachute off, map marker - then put on the host's exact spot and held
-- there: shared loot finds containers by class + position), and its own planes are taken away while it is joined.

local log = require("mirror.log")
local util = require("mirror.util")
local link = require("mirror.link")
local loottables = require("mirror.loottables")

local airdrops = {}

local CHECK_EVERY = 3.0
local SETTLE = 10.0          -- after arriving: the world's own crates are in first
local DIR = "/Game/Inventory/Containers/Containers/Airdrop/"
local MASTER = DIR .. "Master_AirdropContainer.Master_AirdropContainer_C"
local CLASSES = { "AirdropContainer_Medical_C", "AirdropContainer_Military_C", "AirdropContainer_Supplies_C" }
local PLANE = "AirdropAircraft_C"
local PLANE_PATH = "/Game/Blueprints/Events/Airdrop/AirdropAircraft.AirdropAircraft_C"
local SAME = 300.0           -- cm: a crate of that class this close is the same crate
local EXACT = 2.0            -- cm: closer than this is on the host's spot already
local DROP_FROM = 60.0       -- cm above the host's spot: it lands, which hides the parachute and puts up the marker

local role, session
local peer_live = function() return true end
local tick_in, joined_for = 0.0, 0.0
local last_sent = nil
local seen = {}              -- host: crate address -> { l = last position, still = checks it stayed put }
local made = {}              -- guest: crates spawned here -> { a, key }
local held = {}              -- guest: crate address -> true once on the host's spot and held
local stats = { spawned = 0, placed = 0, removed = 0, planes = 0, sent = 0 }
local function game_world() return require("mirror.game").world() end

local function crates()
    local out = {}
    for _, cn in ipairs(CLASSES) do
        for _, a in ipairs(util.instances(cn, { MASTER })) do
            if util.valid(a) then out[#out + 1] = { a = a, cls = cn } end
        end
    end
    return out
end

local function spot(a)
    local l, r
    pcall(function() l, r = a:K2_GetActorLocation(), a:K2_GetActorRotation() end)
    if not l then return nil end
    return { X = l.X, Y = l.Y, Z = l.Z, P = r and r.Pitch or 0, Y_ = r and r.Yaw or 0, R = r and r.Roll or 0 }
end

-- host: the crates that came to rest (the same spot two checks in a row), one per line
local function host_tick()
    local lines, alive = {}, {}
    for _, c in ipairs(crates()) do
        local key = util.addr(c.a)
        local s = key and spot(c.a)
        if s then
            alive[key] = true
            local e = seen[key]
            if e and util.dist(e.l, s) < 1.0 then e.still = e.still + 1 else seen[key] = { l = s, still = 0 } end
            if seen[key].still >= 1 then
                lines[#lines + 1] = string.format("%s %.2f %.2f %.2f %.2f %.2f %.2f", c.cls, s.X, s.Y, s.Z, s.P, s.Y_, s.R)
            end
        end
    end
    for k in pairs(seen) do if not alive[k] then seen[k] = nil end end
    table.sort(lines)
    local body = #lines > 0 and table.concat(lines, "\n") or "-"
    if body ~= last_sent then
        last_sent, stats.sent = body, #lines
        link.put_blob("airdrops", body)
        log.info("airdrops: the host's landed crates: " .. (#lines > 0 and #lines or "none"))
    end
end

local function parse(body)
    local want = {}
    for line in (body or ""):gmatch("[^\n]+") do
        local cls, x, y, z, p, yw, r = line:match("^(AirdropContainer_%a+_C) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
        if cls then
            want[#want + 1] = { cls = cls, X = tonumber(x), Y = tonumber(y), Z = tonumber(z),
                                P = tonumber(p) or 0, Y_ = tonumber(yw) or 0, R = tonumber(r) or 0, key = line }
        end
    end
    return want
end

-- held on the host's exact spot: no physics (a bump would move it off the spot its loot is found by)
local function hold(a, w)
    pcall(function() a:K2_GetRootComponent():SetSimulatePhysics(false) end)
    local ok = pcall(function()
        a:K2_SetActorLocationAndRotation({ X = w.X, Y = w.Y, Z = w.Z }, util.rot(w.P, w.Y_, w.R), false, {}, true)
    end)
    local now = ok and spot(a)
    return now ~= nil and util.dist(now, w) < EXACT
end

local function guest_tick()
    local body = peer_live() and link.get_blob("airdrops") or nil
    if body then airdrops.want = parse(body) end
    local want = airdrops.want
    -- this game's own planes would drop crates the host doesn't have (only once the host sends its own: an older
    -- host sends none, and then the guest keeps its airdrops)
    if want then
        for _, p in ipairs(util.instances(PLANE, PLANE_PATH)) do
            if util.valid(p) and pcall(function() p:K2_DestroyActor() end) then
                stats.planes = stats.planes + 1
                log.info("airdrops: took this game's own airdrop plane away - the host's airdrops come instead")
            end
        end
    end
    if not want or joined_for < SETTLE then return end
    local here = crates()
    local used, wanted = {}, {}
    for _, w in ipairs(want) do
        wanted[w.key] = true
        local best, bd
        for i, c in ipairs(here) do
            if not used[i] and c.cls == w.cls then
                local s = spot(c.a)
                local d = s and util.dist(s, w)
                if d and d < SAME and (not bd or d < bd) then best, bd = i, d end
            end
        end
        if best then
            used[best] = true
            local a = here[best].a
            local k = util.addr(a)
            if bd >= EXACT or not held[k] then
                -- (one that is still falling: wait until it has landed, so its own landing ran)
                local s = spot(a)
                local m = made[k]
                if not (m and m.at and os.clock() - m.at < 4.0) and s then
                    if hold(a, w) then
                        held[k] = true
                        stats.placed = stats.placed + 1
                        log.info(string.format("airdrops: %s on the host's spot (%.0f cm off)", w.cls, bd))
                    end
                end
            end
        else
            local cls = StaticFindObject(DIR .. w.cls:gsub("_C$", "") .. "." .. w.cls)
            if not util.valid(cls) then
                log.every("airdrops.nocls." .. w.cls, 60, "airdrops: " .. w.cls .. " isn't loaded here - not spawning it")
            elseif not loottables.ready() then
                -- (its BeginPlay would load the missing loot tables inside our SpawnActor: loottables.lua)
                log.every("airdrops.tables", 60, string.format("airdrops: %d container loot table(s) not loaded yet - "
                    .. "the host's crate comes once the game has them", loottables.missing()))
            else
                local a
                pcall(function()
                    a = game_world():SpawnActor(cls, { X = w.X, Y = w.Y, Z = w.Z + DROP_FROM }, util.rot(w.P, w.Y_, w.R))
                end)
                if util.valid(a) then
                    made[util.addr(a) or 0] = { a = a, key = w.key, at = os.clock() }
                    stats.spawned = stats.spawned + 1
                    log.info(string.format("airdrops: the host's %s landed at %.0f, %.0f, %.0f - here too", w.cls, w.X, w.Y, w.Z))
                end
            end
        end
    end
    -- a crate made here whose host crate is gone goes too
    for k, m in pairs(made) do
        if not wanted[m.key] then
            if util.valid(m.a) and pcall(function() m.a:K2_DestroyActor() end) then
                stats.removed = stats.removed + 1
                log.info("airdrops: the host's crate is gone - removed it here")
            end
            made[k], held[k] = nil, nil
        end
    end
end

function airdrops.tick(dt)
    if role == "guest" and session and session.in_world() then joined_for = joined_for + dt
    elseif role == "guest" then joined_for = 0.0 end
    tick_in = tick_in - dt
    if tick_in > 0 then return end
    tick_in = CHECK_EVERY
    if role == "host" then util.safe(host_tick, "airdrops.host")
    elseif role == "guest" and session and session.in_world() then util.safe(guest_tick, "airdrops.guest") end
end

function airdrops.status()
    if role == "host" then return "airdrops: sending " .. stats.sent .. " landed crate(s)" end
    return string.format("airdrops: spawned %d, placed %d, removed %d, own planes taken %d",
        stats.spawned, stats.placed, stats.removed, stats.planes)
end

function airdrops.init(c, r, s, connected)
    role, session = r, s
    peer_live = connected or peer_live
    if c and c.airdrop_sync == false then role = "off" end
    require("mirror.game").on_world_reset(airdrops.forget)
    last_sent, joined_for, airdrops.want = nil, 0.0, nil
end

-- a new world: its objects are new (an old address may come back as another actor)
function airdrops.forget() seen, made, held, last_sent = {}, {}, {}, nil end

return airdrops
