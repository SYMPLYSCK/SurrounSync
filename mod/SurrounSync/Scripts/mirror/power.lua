-- Generators, fuel and light switches, on both screens.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local link = require("mirror.link")
local events = require("mirror.events")

local power = {}

local CLASSES = {
    g = { "Buildable_SmallGenerator_C", "Buildable_LargeGenerator_C", "Buildable_IndustrialGenerator_C" },
    -- the lab's generator works like the world one (decompiled: TurnedOn? + Event_TurnOn, which flips it and powers
    -- its Actors: lights, lab doors' warning state) - player report 2026-11-01: "the generator inside needs to be
    -- switched on by both players"
    w = { "BP_PowerGenerator_C", "BP_LaboratoryGenerator_C" },
    l = { "Buildable_Lamp_C", "Buildable_CampingLamp_C", "Buildable_CeilingLight_C", "Buildable_CeilingLight2_C",
          "Buildable_ConstructionLight_C", "Buildable_WallLight_C" },
    -- auto turrets: switched on and off through Buildable_MASTER's power (PoweredOn?), each game its own copy -
    -- one switched off still shot on the other games (player report 2026-10-31: "Turret needs to be disabled by
    -- all players, doesn't sync")
    t = { "Buildable_Turret_C", "Buildable_SmallTurret_C" },
}
local SCAN = {}
for kind, list in pairs(CLASSES) do for _, c in ipairs(list) do SCAN[#SCAN + 1] = { kind, c } end end
-- Whose ReceiveBeginPlay tells util.instances about new ones (BP_PowerGenerator has none).
local GEN_MASTER = "/Game/Blueprints/BuildingSystem/Actors/Generator/Buildable_GeneratorMaster.Buildable_GeneratorMaster_C"
-- the three generators are direct children of it (game files): one walk finds all three
local GEN_GROUP = "Buildable_GeneratorMaster_C"
util.instance_group(GEN_GROUP, CLASSES.g)
-- the two turrets are the only children of their master (game files 26303910): one walk, both BeginPlays
local TURRET_GROUP = "Buildable_TurretMASTER_C"
util.instance_group(TURRET_GROUP, CLASSES.t)
local TURRET_HOOKS = {}
for _, c in ipairs(CLASSES.t) do
    local n = c:gsub("_C$", "")
    TURRET_HOOKS[#TURRET_HOOKS + 1] = "/Game/Blueprints/BuildingSystem/Actors/Turret/" .. n .. "." .. c
end
local GROUP = { g = GEN_GROUP, t = TURRET_GROUP }
local function hooks_of(kind, cls)
    if kind == "g" then return GEN_MASTER end
    if kind == "t" then return TURRET_HOOKS end
    if kind == "l" then local n = cls:gsub("_C$", ""); return "/Game/Blueprints/BuildingSystem/Actors/Lights/" .. n .. "." .. cls end
    return nil
end

local cfg, role, session
local channel = events.reliable("power")
local known = {}
local by_class = {}
local scan_at, scan_retry, scan_in, poll_in, blob_in = 0, 0, 0.0, 0.0, 0.0
local mine_at = {}
local applied_at = {}
local missing = {}
local last_blob = nil
-- guest: the host's last list by id. get_blob hands out only a changed list, so an object that loads (or is
-- recreated) after it arrived gets its line from here
local host_lines = {}
local reapply = {}
local stats = { sent = 0, applied = 0 }

local function shared() return role == "host" or (session and session.in_world()) end

local function id_of(a)
    local l = a:K2_GetActorLocation()
    return string.format("%s@%d,%d,%d", util.class_name(a), math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5),
        math.floor(l.Z / 10 + 0.5))
end

local function read(a, kind)
    local on, fuel = false, nil
    pcall(function()
        if kind == "l" then on = a.LightOn == true
        elseif kind == "t" then on = a["PoweredOn?"] == true
        else on = a["TurnedOn?"] == true end
        if kind == "g" then fuel = tonumber(a.CurrentFuel) end
    end)
    return on, fuel
end

local function scan_step()
    scan_at = scan_at % #SCAN + 1
    local kind, cls = SCAN[scan_at][1], SCAN[scan_at][2]
    local objs, walked = util.instances(cls, hooks_of(kind, cls), GROUP[kind])
    -- not walked yet (its hook lookups took this frame): the same class again next second, not 12 s later
    if not walked then
        if scan_retry < 3 then scan_retry, scan_at = scan_retry + 1, scan_at - 1 else scan_retry = 0 end
        return
    end
    scan_retry = 0
    local seen = {}
    for _, a in ipairs(objs) do
        -- (a group walk's list can be a few frames old: an actor freed since then must not be read)
        local ok, id = false, nil
        if util.valid(a) then ok, id = pcall(id_of, a) end
        if ok then
            seen[id] = true
            local k = known[id]
            if not k or not util.same(k.a, a) then
                local on, fuel = read(a, kind)
                known[id] = { a = a, kind = kind, on = on, fuel = fuel }
                if host_lines[id] then reapply[#reapply + 1] = host_lines[id] end
            end
        end
    end
    for id in pairs(by_class[cls] or {}) do
        if not seen[id] then known[id] = nil end
    end
    by_class[cls] = seen
end

local function line(id, k)
    return string.format("%s %s %d %.1f", id, k.kind, k.on and 1 or 0, k.fuel or -1)
end

local function poll()
    for id, k in pairs(known) do
        if not util.valid(k.a) then known[id] = nil
        else
            local on, fuel = read(k.a, k.kind)
            local refuel = fuel and k.fuel and fuel > k.fuel + 0.5
            if os.clock() - (applied_at[id] or -100) < 2.0 then
                k.on, k.fuel = on, fuel
            elseif on ~= k.on or refuel then
                k.on, k.fuel = on, fuel
                mine_at[id] = os.clock()
                channel:send("S " .. line(id, k))
                stats.sent = stats.sent + 1
                log.info("power: " .. id:match("^[^@]+") .. (on and " on" or " off") .. (refuel and " (refuelled)" or "") .. " - telling the other game")
            elseif fuel then
                k.fuel = fuel
            end
        end
    end
end

local function find(id, kind)
    local k = known[id]
    if k and util.valid(k.a) then return k.a, k end
    if os.clock() < (missing[id] or 0) then return nil end
    local a = util.find_by_id(id, 100)
    if not a then missing[id] = os.clock() + 10; return nil end
    local on, fuel = read(a, kind)
    k = { a = a, kind = kind, on = on, fuel = fuel }
    known[id] = k
    return a, k
end

local function apply(id, kind, on, fuel, why)
    local a, k = find(id, kind)
    if not a then return end
    local cur_on, cur_fuel = read(a, kind)
    local changed = false
    if kind == "g" then
        if fuel and fuel >= 0 and (not cur_fuel or math.abs(cur_fuel - fuel) > 1.0) then
            pcall(function() a.CurrentFuel = fuel end)
            changed = true
        end
        if on ~= cur_on then
            pcall(function() a["TurnedOn?"] = on end)
            pcall(function() a["OnRep_TurnedOn?"](a) end)
            if not on then pcall(function() a:GetObjects() end) end
            changed = true
        end
    elseif kind == "w" then
        if on ~= cur_on then
            pcall(function() a["GasAdded?"] = true; a["ItemUsed?"] = true end)
            -- (the lab's Event_TurnOn also pops the "generator on/off" notice and completes the PowerOnGenerator
            -- quest task on this game, for a switch the other player pulled; its TestTurnOnOff is the same flip and
            -- Actors power without either, decompiled - its hum is Event_TurnOn's own Audio step, done here)
            local quiet = id:find("^BP_LaboratoryGenerator_C@") and pcall(function() a:TestTurnOnOff() end)
            if quiet then
                pcall(function() if on then a.Audio:Activate(false) else a.Audio:Deactivate() end end)
            else
                pcall(function() a:Event_TurnOn(game.player()) end)
            end
            changed = true
        end
    elseif kind == "l" then
        if on ~= cur_on then
            pcall(function() a:MC_OnInteractBuildable(game.player()) end)
            changed = true
        end
    elseif kind == "t" then
        -- (Buildable_MASTER's own switch: sets PoweredOn?, whose OnRep fires the turret's On/Off)
        if on ~= cur_on then
            pcall(function() a[on and "Power On" or "Power Off"](a, game.player()) end)
            changed = true
        end
    end
    k.on, k.fuel = read(a, kind)
    if changed then
        applied_at[id] = os.clock()
        stats.applied = stats.applied + 1
        log.info(string.format("power: %s %s here (%s)", id:match("^[^@]+"), on and "on" or "off", why))
    end
end

local function apply_line(s, why)
    local id, kind, on, fuel = s:match("^(%S+) (%a) (%d) (%S+)$")
    if not id then return end
    if why == "host's list" and os.clock() - (mine_at[id] or -100) < 4.0 then return end
    apply(id, kind, on == "1", tonumber(fuel), why)
end

function power.tick(dt)
    if role == "off" then return end
    poll_in, blob_in = poll_in - dt, blob_in - dt
    scan_in = scan_in - dt
    if scan_in <= 0 then scan_in = 1.0; util.safe(scan_step, "power.scan") end
    if poll_in <= 0 then
        poll_in = 0.5
        if shared() then util.safe(poll, "power.poll") end
    end
    channel:pump(function(p)
        if shared() and p:sub(1, 2) == "S " then util.safe(apply_line, "power.apply", p:sub(3), "the other player") end
    end)
    if role == "host" and blob_in <= 0 then
        blob_in = 3.0
        local out = {}
        for id, k in pairs(known) do out[#out + 1] = line(id, { kind = k.kind, on = k.on, fuel = k.fuel and math.floor(k.fuel) }) end
        table.sort(out)
        local s = table.concat(out, "\n")
        if s ~= last_blob then last_blob = s; link.put_blob("power", s) end
    elseif role ~= "host" and shared() then
        local b = link.get_blob("power")
        if b then
            host_lines = {}
            for s in b:gmatch("[^\n]+") do
                local id = s:match("^(%S+)")
                if id then host_lines[id] = s end
                util.safe(apply_line, "power.list", s, "host's list")
            end
        end
        local q = reapply
        reapply = {}
        for _, s in ipairs(q) do util.safe(apply_line, "power.list", s, "host's list") end
    end
    if (role == "host" or not shared()) and (reapply[1] or next(host_lines)) then host_lines, reapply = {}, {} end
end

local function nearest(kinds)
    local me, best, bd = nil, nil, math.huge
    pcall(function() me = util.vec(game.player():K2_GetActorLocation()) end)
    if not me then return nil end
    for id, k in pairs(known) do
        if kinds:find(k.kind, 1, true) and util.valid(k.a) then
            local l
            pcall(function() l = util.vec(k.a:K2_GetActorLocation()) end)
            local d = l and util.dist(me, l) or math.huge
            if d < bd then best, bd = id, d end
        end
    end
    return best, bd
end
function power.dev_list()
    local n = 0
    for id, k in pairs(known) do
        n = n + 1
        if n <= 20 then log.info(string.format("devtest: power %s %s on=%s fuel=%s", k.kind, id, tostring(k.on), tostring(k.fuel))) end
    end
    log.info("devtest: power known " .. n)
end
function power.dev_toggle(kinds)
    local id, d = nearest(kinds or "gwl")
    if not id then log.info("devtest: power toggle - nothing known nearby"); return end
    local k = known[id]
    local on = read(k.a, k.kind)
    if k.kind == "g" then
        pcall(function() if (k.a.CurrentFuel or 0) <= 0 then k.a.CurrentFuel = k.a.MaxFuel end end)
        pcall(function() k.a["TurnedOn?"] = not on end)
        pcall(function() k.a["OnRep_TurnedOn?"](k.a) end)
        if on then pcall(function() k.a:GetObjects() end) end
    elseif k.kind == "w" then
        pcall(function() k.a["GasAdded?"] = true; k.a["ItemUsed?"] = true end)
        pcall(function() k.a:Event_TurnOn(game.player()) end)
    elseif k.kind == "t" then
        pcall(function() k.a[on and "Power Off" or "Power On"](k.a, game.player()) end)
    else
        pcall(function() k.a:MC_OnInteractBuildable(game.player()) end)
    end
    log.info(string.format("devtest: power toggle %s (%.0f m) -> %s", id, d / 100, tostring(read(k.a, k.kind))))
end

function power.status()
    return string.format("power: %d known, changes sent %d, applied %d", (function() local n = 0; for _ in pairs(known) do n = n + 1 end; return n end)(),
        stats.sent, stats.applied)
end

-- Respawn/reload: the old world's objects are freed - drop them without touching them.
local function forget_world() known, by_class, scan_at, scan_retry, scan_in = {}, {}, 0, 0, 0.0 end
function power.init(c, r, s)
    game.on_world_reset(forget_world)
    cfg, role, session = c, r, s
    if cfg.power_sync == false then role = "off" end
    log.info("power: " .. (role == "off" and "off" or "generators, lights and turrets are shared"))
end

return power
