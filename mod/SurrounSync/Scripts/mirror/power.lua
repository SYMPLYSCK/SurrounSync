-- Generators, fuel and light switches, on both screens.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local link = require("mirror.link")
local events = require("mirror.events")

local power = {}

local CLASSES = {
    g = { "Buildable_SmallGenerator_C", "Buildable_LargeGenerator_C", "Buildable_IndustrialGenerator_C" },
    w = { "BP_PowerGenerator_C" },
    l = { "Buildable_Lamp_C", "Buildable_CampingLamp_C", "Buildable_CeilingLight_C", "Buildable_CeilingLight2_C",
          "Buildable_ConstructionLight_C", "Buildable_WallLight_C" },
}
local SCAN = {}
for kind, list in pairs(CLASSES) do for _, c in ipairs(list) do SCAN[#SCAN + 1] = { kind, c } end end

local cfg, role, session
local channel = events.new("power", 64, 30)
local known = {}
local by_class = {}
local scan_at, scan_in, poll_in, blob_in = 0, 0.0, 0.0, 0.0
local mine_at = {}
local applied_at = {}
local missing = {}
local last_blob = nil
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
        else on = a["TurnedOn?"] == true end
        if kind == "g" then fuel = tonumber(a.CurrentFuel) end
    end)
    return on, fuel
end

local function scan_step()
    scan_at = scan_at % #SCAN + 1
    local kind, cls = SCAN[scan_at][1], SCAN[scan_at][2]
    local seen = {}
    for _, a in ipairs(FindAllOf(cls) or {}) do
        local cdo = true
        pcall(function() cdo = a:GetFullName():find("Default__", 1, true) ~= nil end)
        if util.valid(a) and not cdo then
            local ok, id = pcall(id_of, a)
            if ok then
                seen[id] = true
                local k = known[id]
                if not k or not util.same(k.a, a) then
                    local on, fuel = read(a, kind)
                    known[id] = { a = a, kind = kind, on = on, fuel = fuel }
                end
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
            pcall(function() a:Event_TurnOn(game.player()) end)
            changed = true
        end
    elseif kind == "l" then
        if on ~= cur_on then
            pcall(function() a:MC_OnInteractBuildable(game.player()) end)
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
    if scan_in <= 0 then scan_in = 2.0; util.safe(scan_step, "power.scan") end
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
        if b then for s in b:gmatch("[^\n]+") do util.safe(apply_line, "power.list", s, "host's list") end end
    end
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
    else
        pcall(function() k.a:MC_OnInteractBuildable(game.player()) end)
    end
    log.info(string.format("devtest: power toggle %s (%.0f m) -> %s", id, d / 100, tostring(read(k.a, k.kind))))
end

function power.status()
    return string.format("power: %d known, changes sent %d, applied %d", (function() local n = 0; for _ in pairs(known) do n = n + 1 end; return n end)(),
        stats.sent, stats.applied)
end

function power.init(c, r, s)
    cfg, role, session = c, r, s
    if cfg.power_sync == false then role = "off" end
    log.info("power: " .. (role == "off" and "off" or "generators and lights are shared"))
end

return power
