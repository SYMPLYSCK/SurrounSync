-- Settlement camps follow the host.
--
-- After every load the game's BP_SettlementManager spawns one camp prefab (a random one the first time, then the
-- saved one), but the camp of the world loaded before is never removed: it isn't a saved actor and the persistent
-- level stays loaded. So each game shows its own set (test 2026-10-25: host Settlement4, guest Settlement2 + 3).
-- The host sends which camps it has; a joined guest removes the others and spawns missing ones through their
-- spawner (BP_SettlementCampSpawner.SpawnSettlement). The host's world is never changed.
--
-- The military trader too: BP_MilitaryTraderSpawner puts it at a random one of its 5 spawn points in each game
-- (kit 2026-10-27: host at -1937,239448, guest 3.7 km away). The host sends where its trader stands; a joined
-- guest moves its own trader there. The ice cream van the same way (BP_ShakesConesSpawner: one of its 5 spawn
-- points at random, BeginPlay; the van never drives).

local log = require("mirror.log")
local util = require("mirror.util")
local link = require("mirror.link")

local camps = {}

local CHECK_EVERY = 5.0
local SETTLE = 10.0          -- after arriving: the game's own manager spawns its camp first
local SPAWNER = "BP_SettlementCampSpawner_C"
local SPAWNER_PATH = "/Game/Blueprints/Settlements/BP_SettlementCampSpawner.BP_SettlementCampSpawner_C"
-- the camps have no BeginPlay of their own: new ones are caught by their parent's (util.instances keeps the class)
local PARENT = "/Game/Prefabs/PrefabMaster.PrefabMaster_C"
local CLASSES = {}
for i = 1, 4 do CLASSES[i] = "Prefab_Settlement" .. i .. "_C" end

local role, session
local peer_live = function() return true end
local tick_in, joined_for = 0.0, 0.0
local last_sent, host_want = nil, nil
local pending = nil          -- the mismatch seen last check (acted on only when it is seen twice)
local stats = { removed = 0, spawned = 0 }

-- traders placed at a random spawn point in each game: its class, its blob, its name in the log
local TRADERS = {
    { cls = "BP_MilitaryTrader_C", blob = "miltrader", name = "military trader" },
    { cls = "BP_ShakesConesTrader_C", blob = "icetrader", name = "ice cream trader" },
}
-- no BeginPlay of their own: new ones are caught by the parent's (looking for its own kept backing off: moved 75 s late)
local MIL_PARENT = "/Game/Inventory/Traders/BP_TraderMaster.BP_TraderMaster_C"
local MIL_NEAR = 100.0       -- cm: closer than this to the host's spot counts as the same place
stats.moved = 0

local destroyed = {}         -- actors already destroyed here, still listed until the engine lets go (util.mark)
local spawned_here = {}      -- class -> true: spawned once in this world (never again, even if it isn't seen)

-- a real camp stands somewhere; an empty one at the world origin (no parts, test 2026-10-25) is a template the
-- game keeps - it can't be destroyed and isn't a camp
local function real(a)
    local a_addr = util.addr(a)
    if not a_addr or util.marked(destroyed, a, a_addr) then return false end
    local l
    pcall(function() l = a:K2_GetActorLocation() end)
    return l ~= nil and (math.abs(l.X) > 100 or math.abs(l.Y) > 100 or math.abs(l.Z) > 100)
end

-- class -> live camp actors of it
local function present()
    local out = {}
    for _, cn in ipairs(CLASSES) do
        local list = {}
        -- only the parent: a camp class has no BeginPlay, and looking one up misses (~15-30 ms each, every 2 s)
        for _, a in ipairs(util.instances(cn, { PARENT })) do
            if real(a) then list[#list + 1] = a end
        end
        out[cn] = list
    end
    return out
end

local function wire(have)
    local parts = {}
    for _, cn in ipairs(CLASSES) do
        local v = have[cn]                               -- a list of actors, or (the host's) a count
        local n = type(v) == "table" and #v or v or 0
        if n > 0 then parts[#parts + 1] = cn .. "=" .. n end
    end
    return table.concat(parts, " ")
end

local function parse(body)
    local want = {}
    for cn, n in body:gmatch("(Prefab_Settlement%d_C)=(%d+)") do want[cn] = tonumber(n) end
    return want
end

local function spawner_for(cn)
    for _, s in ipairs(util.instances(SPAWNER, SPAWNER_PATH)) do
        local c
        pcall(function() c = s.Settlement:GetFName():ToString() end)
        if c == cn and util.valid(s) then return s end
    end
    return nil
end

-- one change per check: remove a camp the host doesn't have (or one too many), else spawn one it has
local function fix(have, want)
    for _, cn in ipairs(CLASSES) do
        local list, n = have[cn] or {}, want[cn] or 0
        if #list > n then
            local a = list[#list]
            util.mark(destroyed, a)
            -- (a camp's child actors can be animated - its people: destroyed once animation is on the game thread)
            if util.valid(a) then
                require("mirror.animgate").destroy(a, "camps.remove")
                stats.removed = stats.removed + 1
                log.info("camps: removed " .. cn .. " - the host's world doesn't have it")
            end
            return
        end
    end
    for _, cn in ipairs(CLASSES) do
        local n = want[cn] or 0
        if #(have[cn] or {}) < n then
            if spawned_here[cn] then
                log.every("camps.again." .. cn, 60, "camps: " .. cn .. " was spawned here already - not spawning it again")
                return
            end
            local s = spawner_for(cn)
            if not s then log.every("camps.nospawner." .. cn, 60, "camps: no spawner for " .. cn .. " here"); return end
            spawned_here[cn] = true
            if pcall(function() s:SpawnSettlement() end) then
                stats.spawned = stats.spawned + 1
                log.info("camps: spawned " .. cn .. " like in the host's world")
            end
            return
        end
    end
end

local function mil_trader(t)
    for _, a in ipairs(util.instances(t.cls, { MIL_PARENT })) do
        if real(a) then return a end
    end
    return nil
end

local function mil_spot(a)
    local l, r
    pcall(function() l, r = a:K2_GetActorLocation(), a:K2_GetActorRotation() end)
    if not l then return nil end
    return { X = l.X, Y = l.Y, Z = l.Z, yaw = r and r.Yaw or 0 }
end

-- host: where its trader stands ("-" = none); sent again only when it is somewhere else
local function mil_host(t)
    local a = mil_trader(t)
    local s = a and mil_spot(a)
    if s and t.sent and util.dist(s, t.sent) < MIL_NEAR then return end
    if not s and t.sent == false then return end
    t.sent = s or false
    -- (exact to the cm: its shared stock is found by position on a 10 cm grid - a rounded spot could land in the next cell)
    link.put_blob(t.blob, s and string.format("%.2f %.2f %.2f %.1f", s.X, s.Y, s.Z, s.yaw) or "-")
    log.info("camps: the host's " .. t.name .. ": " .. (s and string.format("%.0f, %.0f, %.0f", s.X, s.Y, s.Z) or "none"))
end

-- guest: its own trader goes where the host's stands (seen twice, like a camp mismatch)
local function mil_guest(t)
    local body = link.get_blob(t.blob)
    if body then
        local x, y, z, yaw = body:match("^(%S+) (%S+) (%S+) (%S+)$")
        t.want = x and { X = tonumber(x), Y = tonumber(y), Z = tonumber(z), yaw = tonumber(yaw) or 0 } or false
    end
    if not t.want then t.pending = nil; return end
    local a = mil_trader(t)
    local s = a and mil_spot(a)
    if not s or util.dist(s, t.want) < MIL_NEAR then t.pending = nil; return end
    if not t.pending then t.pending = true; return end
    t.pending = nil
    local w = t.want
    local ok = pcall(function()
        a:K2_SetActorLocationAndRotation({ X = w.X, Y = w.Y, Z = w.Z }, util.rot(0, w.yaw, 0), false, {}, true)
    end)
    local now = ok and mil_spot(a)
    ok = now ~= nil and util.dist(now, w) < MIL_NEAR
    if ok then stats.moved = stats.moved + 1 end
    log.info(string.format("camps: %s moved to the host's spot (%.0f, %.0f, %.0f, %.0f m away): %s",
        t.name, w.X, w.Y, w.Z, util.dist(s, w) / 100, ok and "ok" or "FAILED"))
end

local function host_tick()
    local w = wire(present())
    if w ~= last_sent then
        last_sent = w
        link.put_blob("camps", w == "" and "-" or w)
        log.info("camps: the host's settlement camps: " .. (w == "" and "none" or w))
    end
    for _, t in ipairs(TRADERS) do util.safe(mil_host, "camps.mil_host", t) end
end

local function guest_tick()
    local body = peer_live() and link.get_blob("camps") or nil
    if body then host_want = parse(body) end
    if session and session.in_world() and joined_for >= SETTLE and peer_live() then
        for _, t in ipairs(TRADERS) do util.safe(mil_guest, "camps.mil_guest", t) end
    end
    if not (host_want and session and session.in_world()) then joined_for, pending = 0.0, nil; return end
    if joined_for < SETTLE then return end
    local have = present()
    local mine, theirs = wire(have), wire(host_want)
    if mine == theirs then pending = nil; return end
    -- the game's manager may still be spawning: act only on a mismatch that stays, then fix one step per check
    if pending == nil then pending = mine .. "|" .. theirs; return end
    if pending ~= true and pending ~= mine .. "|" .. theirs then pending = mine .. "|" .. theirs; return end
    pending = true
    util.safe(fix, "camps.fix", have, host_want)
end

function camps.tick(dt)
    if role == "guest" and session and session.in_world() then joined_for = joined_for + dt end
    tick_in = tick_in - dt
    if tick_in <= 0 then
        tick_in = CHECK_EVERY
        if role == "host" then host_tick() elseif role == "guest" then guest_tick() end
    end
    -- phase1 naps until the next check; not a guest out of a world (its wake on arrival would count the sleep as
    -- settle time)
    if role ~= "guest" or (session and session.in_world()) then return tick_in end
end

function camps.status()
    if role == "host" then return "camps: sending " .. ((last_sent and last_sent ~= "") and last_sent or "none") end
    return string.format("camps: removed %d, spawned %d, traders moved %d", stats.removed, stats.spawned, stats.moved)
end

function camps.init(c, r, s, connected)
    role, session = r, s
    peer_live = connected or peer_live
    if c and c.camp_sync == false then role = "off" end
    require("mirror.game").on_world_reset(camps.forget)
    last_sent, host_want, pending, joined_for = nil, nil, nil, 0.0
end

-- a new world: its objects are new (an old address may come back as another actor)
function camps.forget()
    destroyed, spawned_here, pending = {}, {}, nil
    for _, t in ipairs(TRADERS) do t.pending = nil end
end

return camps
