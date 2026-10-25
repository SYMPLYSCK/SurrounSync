-- Cars: the same cars in both worlds, and the other player seen driving or riding along.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local link = require("mirror.link")
local notify = require("mirror.notify")

local vehicles = {}

local MASTER = "/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C"
local TYPES = { "4x4Jeep", "APC", "Ambulance", "BigRig", "Buggy", "Charger", "DamagedSedan", "FlatbedTruck", "GolfCart",
                "Humvee", "ModifiedPickupUtilityTruck", "PickupTruck", "RV", "SUV", "Sheriff", "SwatVan", "Truck",
                "PickupUtilityTruck", "Van" }
local SPAWNERS = { "BP_VehicleSpawner_C", "BP_VehicleUniqueSpawner_C" }
local SIT = "/Game/Character/Anims/Interaction/Chr_SitInCar_Montage.Chr_SitInCar_Montage"
local CLASS_EVERY = 1.0

local cfg, role, session
-- mate: a copy for another guest (peers.lua) - only their driving/riding, the cars list and states come from the host
local mate = false
local cars = {}
local alias, rev = {}, {}
local scan_age = math.huge
local in_world, entered_at = false, 0.0
local now, send_in, wake_in = 0.0, 0.0, 0.0
local driving = nil
local list_sent = nil
local peer = nil
local seated = false
local seated_as = nil
local ghost_collide_at = nil
local resend = false
local out_for = 0.0
local wake_at = {}
local riding = nil
local entered_with = nil
local ride_fix, ride_at, ride_seat = 0, -100.0, nil
local seated_seat = 0
local peer_rides = nil
local LIST_EVERY = 5.0
local list_at, applied_at = -100.0, -100.0
local PASSES = { 3, 10, 18 }
local host_cars, pass = nil, 0
local stats = { moved = 0, added = 0, removed = 0, spawners = 0 }

local apply_ride, seat_point, physics, seat_of, P
local function shared() return role == "host" or (session and session.in_world()) end
local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local function alive(a)
    if not util.valid(a) then return false end
    local ksl, ok, r = util.cdo(KSL), false, false
    if ksl then ok, r = pcall(function() return ksl:IsValid(a) end) end
    if not ok or r ~= true then return false end
    local dying = false
    pcall(function() dying = a:IsActorBeingDestroyed() == true end)
    return not dying
end
local function name_of(a) local n; pcall(function() n = util.fname(a) end); return n end
local new_car, car_hook_in = false, 0.0
local function on_car_begin(self)
    if role ~= "host" or not in_world then return end
    local a
    pcall(function() a = self:get() end)
    if not alive(a) then return end
    local n = name_of(a)
    if n and not alive(cars[n]) then cars[n] = a; new_car = true; log.info("vehicles: a new car here (" .. n .. ") - telling the other game") end
end
local function class_path(a) return util.class_path(a) end
local master_cls = nil
local function is_car(a)
    if not util.valid(a) then return false end
    if not util.valid(master_cls) then master_cls = StaticFindObject(MASTER) end
    local yes = false
    if util.valid(master_cls) then pcall(function() yes = a:IsA(master_cls) == true end) end
    return yes
end

-- False until every car type has been walked once in this world (one type per frame).
local function scan()
    local fresh, ready = {}, true
    for _, t in ipairs(TYPES) do
        local list, walked = util.instances("Vehicle_" .. t .. "_C", MASTER)
        if not walked then ready = false end
        for _, v in ipairs(list) do
            if alive(v) then
                local n = name_of(v)
                if n then fresh[n] = v end
            end
        end
    end
    if not ready then return false end
    cars = fresh
    scan_age = 0.0
    return true
end

local unknown = {}
local function car_named(name)
    local c = alias[name] or cars[name]
    if alive(c) then return c end
    if (unknown[name] or 0) > now then return nil end
    if scan_age > 5 then scan(); c = alias[name] or cars[name] end
    if not alive(c) then unknown[name] = now + 30; return nil end
    return c
end
local function peer_name(car)
    local n = name_of(car)
    return n and (rev[n] or n) or nil
end

local function transform(a)
    local l, r
    pcall(function() l = a:K2_GetActorLocation(); r = a:K2_GetActorRotation() end)
    return l, r
end
local function fmt(l, r) return string.format("%.1f %.1f %.1f %.2f %.2f %.2f", l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll) end
local function place(car, l, r) pcall(function() car:K2_TeleportTo(l, r) end) end
local function place_hard(car, l, r) pcall(function() car:K2_SetActorLocationAndRotation(l, r, false, {}, true) end) end
-- Never switch a car's physics off: once switched back on, the vehicle can't be driven.
local function follow_mode(car, on)
    pcall(function() car.VehicleMovementComponent:SetHandbrakeInput(not on) end)
    pcall(function() car.VehicleMovementComponent:SetBrakeInput(0) end)
    pcall(function() car.VehicleMovementComponent:SetThrottleInput(0) end)
    if not on then
        pcall(function() car.Mesh:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
        pcall(function() car.Mesh:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
    end
end

local function state_of(car)
    local c, f, h = -1, -1, -1
    pcall(function() c = car.VehicleColor end)
    pcall(function() f = car.FuelComponent.CurrentFuel end)
    pcall(function() h = car.VehicleHealthComponent.CurrentHealth end)
    return string.format("%d %.1f %.1f", tonumber(c) or -1, tonumber(f) or -1, tonumber(h) or -1)
end
-- The game's gas can / repair kit also refresh what a player standing at the car sees: the car's own fuel and
-- repair widgets, and the HUD's Fuel/Health stats (Svr_UpdateFuel / Svr_UpdateEngine) - those are otherwise
-- only filled in when someone starts looking at or enters the car. The HUD stats are one panel for whatever
-- the player looks at, so they're refreshed only when this car is the one next to the player.
local NEXT_TO = 600
local function show_state(car, fuel_changed, health_changed)
    if fuel_changed then
        pcall(function()
            local w = car.FuelWidget:GetUserWidgetObject()
            w:UpdateFuel(car.FuelComponent.CurrentFuel, car.FuelComponent.MaxFuel)
        end)
    end
    if health_changed then
        pcall(function()
            local w = car.RepairWidget:GetUserWidgetObject()
            w:UpdateHealth(car.VehicleHealthComponent.CurrentHealth, car.VehicleHealthComponent.MaxHealth)
        end)
    end
    local near = false
    pcall(function()
        local pl, cl = game.player():K2_GetActorLocation(), car:K2_GetActorLocation()
        local d = util.dist(pl, cl)
        if d > NEXT_TO then return end
        near = true
        for _, other in pairs(cars) do
            if not util.same(other, car) and alive(other) and util.dist(pl, other:K2_GetActorLocation()) < d then near = false; return end
        end
    end)
    if not near then return end
    if fuel_changed then pcall(function() car:Svr_UpdateFuel(car.FuelComponent.CurrentFuel) end) end
    if health_changed then pcall(function() car:Svr_UpdateEngine(car.VehicleHealthComponent.CurrentHealth) end) end
end
local function set_state(car, c, f, h)
    c, f, h = tonumber(c), tonumber(f), tonumber(h)
    local fuel_changed, health_changed = false, false
    if c and c >= 0 then
        pcall(function()
            if car.VehicleColor ~= c then
                car.VehicleColor = c
                car.Mesh:SetMaterial(0, car.Colors[c + 1])
            end
        end)
    end
    -- Like the game's gas can: the fuel and the Empty flag together (Empty alone keeps a refuelled car dead).
    if f and f >= 0 then
        local before
        pcall(function() before = car.FuelComponent.CurrentFuel end)
        fuel_changed = math.abs((tonumber(before) or -1) - f) > 0.05
        pcall(function() car.FuelComponent.CurrentFuel = f end)
        pcall(function() car.FuelComponent.Empty = f <= 0 end)
    end
    if h and h >= 0 then
        local before
        pcall(function() before = car.VehicleHealthComponent.CurrentHealth end)
        before = tonumber(before) or 0
        if math.abs(before - h) > 0.05 then
            pcall(function() car.VehicleHealthComponent.CurrentHealth = h end)
            -- Like the repair kit / a wreck: engine back on above 0, off at 0; smoke and fire follow the health.
            if h > 0 and before <= 0 then pcall(function() car["EngineOn?"] = true end)
            elseif h <= 0 and before > 0 then pcall(function() car["EngineOn?"] = false end) end
            pcall(function() car:VehicleEngineFX(true) end)
            health_changed = true
        end
    end
    if fuel_changed or health_changed then show_state(car, fuel_changed, health_changed) end
end
local function fuel_health(car)
    local f, h
    pcall(function() f = car.FuelComponent.CurrentFuel end)
    pcall(function() h = car.VehicleHealthComponent.CurrentHealth end)
    return tonumber(f), tonumber(h)
end

local known_state, told, applied_state = {}, {}, {}
-- Fuel/health/colour changes are watched on the cars near the player 4x a second (a refuel shows live on the
-- other screen); a slow round over all cars (~400) keeps that near set. It used to check 12 cars per 0.5 s
-- over all of them: a change at the car you stood at went out up to ~17 s later.
local STATE_NEAR, STATE_EVERY, SCAN_PER_TICK = 2500, 0.25, 40
local state_in, state_keys, state_idx, near_cars = 0.0, {}, 0, {}
local function remember_state(n, car) known_state[n] = state_of(car) end
local function watch_states(dt, busy)
    state_in = state_in - dt
    if state_in > 0 then return end
    state_in = STATE_EVERY
    local p = game.player()
    local pl = p and (function() local l; pcall(function() l = p:K2_GetActorLocation() end); return l end)()
    if not pl then return end
    if state_idx >= #state_keys then
        state_keys, state_idx = {}, 0
        for n in pairs(cars) do state_keys[#state_keys + 1] = n end
    end
    for _ = 1, SCAN_PER_TICK do
        state_idx = state_idx + 1
        local mine = state_keys[state_idx]
        if not mine then break end
        local car, l = cars[mine], nil
        if alive(car) then pcall(function() l = car:K2_GetActorLocation() end) end
        near_cars[mine] = (l and util.dist(l, pl) < STATE_NEAR) or nil
    end
    local changed = false
    for mine in pairs(near_cars) do
        local car = cars[mine]
        if not alive(car) then near_cars[mine] = nil
        elseif not busy(car) then
            local n = peer_name(car)
            local st = state_of(car)
            if n and known_state[n] and known_state[n] ~= st then told[n], changed = st, true end
            if n then known_state[n] = st end
        end
    end
    if changed then
        local lines = {}
        for n, st in pairs(told) do lines[#lines + 1] = n .. " " .. st end
        table.sort(lines)
        link.put_blob("carstate", table.concat(lines, "\n"))
    end
end
local function apply_states(body, busy, named)
    for line in body:gmatch("[^\n]+") do
        local n, st = line:match("^(%S+) (.+)$")
        if n and applied_state[n] ~= st then
            applied_state[n] = st
            local car = named(n)
            if car and not busy(car) then
                local c, f, h = st:match("^(%S+) (%S+) (%S+)$")
                set_state(car, c, f, h)
                remember_state(n, car)
                log.info("vehicles: the other player changed " .. n .. " (colour/fuel/health " .. st .. ")")
            end
        end
    end
end
physics = function(car, on)
    pcall(function() car.Mesh:SetSimulatePhysics(on) end)
    if on then
        pcall(function() car.Mesh:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
        pcall(function() car.Mesh:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
    end
end

local retired = {}
-- Extra cars are hidden and parked under the map, never destroyed - a half-destroyed car
-- crashed the game.
local function retire(car, n)
    retired[n] = true
    physics(car, false)
    pcall(function() car:SetActorHiddenInGame(true) end)
    pcall(function() car:SetActorEnableCollision(false) end)
    pcall(function() car:SetActorTickEnabled(false) end)
    local l = transform(car)
    if l then place_hard(car, { X = l.X, Y = l.Y, Z = -500000 }, { Pitch = 0, Yaw = 0, Roll = 0 }) end
    retired[n] = true
end

local NEAR_M = 250
local frozen = {}
local function player_loc() local p = game.player(); return p and transform(p) end
local function place_when_near(car, l, r)
    local pl = player_loc()
    if pl and util.dist(pl, l) > NEAR_M * 100 then frozen[util.addr(car) or 0] = { car = car, l = l, r = r }
    else frozen[util.addr(car) or 0] = nil; place_hard(car, l, r) end
end
local pending = {}
local made_for_drive = {}
local parked = {}
local MIN_DELAY, MAX_DELAY = 0.08, 0.35
local function add_car(n, cp, l, r, sc, sf, sh)
    local pl = player_loc()
    if pl and util.dist(pl, l) > NEAR_M * 100 then
        pending[n] = { cp = cp, l = l, r = r, sc = sc, sf = sf, sh = sh }
        return
    end
    pending[n] = nil
    local cls = StaticFindObject(cp)
    if not util.valid(cls) then return end
    local a
    pcall(function() a = game.world():SpawnActor(cls, l, r) end)
    if not util.valid(a) then return end
    set_state(a, sc, sf, sh)
    local mine = name_of(a)
    alias[n], rev[mine or ""] = a, n
    if mine then cars[mine] = a end
    stats.added = stats.added + 1
end

local function wake_near()
    local pl = player_loc()
    if not pl then return end
    for k, w in pairs(frozen) do
        if not alive(w.car) then frozen[k] = nil
        elseif util.dist(pl, w.l) < NEAR_M * 100 then
            frozen[k] = nil
            place_hard(w.car, w.l, w.r)
        end
    end
    for n, c in pairs(pending) do
        if util.dist(pl, c.l) < NEAR_M * 100 then add_car(n, c.cp, c.l, c.r, c.sc, c.sf, c.sh) end
    end
end

local function stop_spawners()
    local n = 0
    for _, cls in ipairs(SPAWNERS) do
        for _, s in ipairs(util.instances(cls, "/Game/Blueprints/Vehicles/Spawner/" .. cls:gsub("_C$", "") .. "." .. cls)) do
            pcall(function() if s["SpawnerUsed?"] ~= true then s["SpawnerUsed?"] = true; n = n + 1 end end)
        end
    end
    stats.spawners = stats.spawners + n
    if n > 0 then log.info("vehicles: stopped " .. n .. " vehicle spawner(s) - the host's cars are the ones here") end
end

local function host_list()
    local lines = {}
    for n, v in pairs(cars) do
        if alive(v) then
            local l, r = transform(v)
            local cp = class_path(v)
            if l and cp then lines[#lines + 1] = n .. " " .. cp .. " " .. fmt(l, r) .. " " .. state_of(v) end
        end
    end
    table.sort(lines)
    return table.concat(lines, "\n")
end

local function apply_list(body)
    if not scan() then return false end
    local want = {}
    for line in body:gmatch("[^\n]+") do
        util.pause()
        local n, cp, x, y, z, pi, ya, ro, sc, sf, sh = line:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) ?(%S*) ?(%S*) ?(%S*)$")
        if n then
            want[n] = true
            local l = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
            local r = { Pitch = tonumber(pi), Yaw = tonumber(ya), Roll = tonumber(ro) }
            local c = alias[n] or cars[n]
            if alive(c) then
                local busy = (peer and util.same(peer.car, c)) or util.same(c, driving) or vehicles.other_drives(c)
                if not busy then set_state(c, sc, sf, sh) end
                local cl = transform(c)
                if cl and util.dist(cl, l) > 100 and not busy then
                    place_when_near(c, l, r); stats.moved = stats.moved + 1
                end
            else
                add_car(n, cp, l, r, sc, sf, sh)
            end
        end
    end
    for n, c in pairs(cars) do
        if not want[n] and not rev[n] and not retired[n] and alive(c) and not util.same(c, driving) then
            retire(c, n)
            stats.removed = stats.removed + 1
        end
    end
    log.info(string.format("vehicles: the host's cars here (moved %d, added %d, removed %d so far)", stats.moved, stats.added, stats.removed))
end

local function send_drive(dt)
    local p = game.player()
    local parent
    pcall(function() parent = p:GetAttachParentActor() end)
    local car = is_car(parent) and parent or nil
    local mine_drives = car and vehicles.peer_drives(car)
    if car and (mine_drives or vehicles.other_drives(car)) then
        local nm = (mine_drives and peer and peer.name) or peer_name(car)
        if not util.same(riding, car) then
            riding, ride_fix, ride_seat = car, 2, nil
            -- got in together with someone who drives it (lower slot): no longer the driver, no "parked"
            if util.same(driving, car) then driving, entered_with, out_for = nil, nil, 0.0 end
            link.put_blob("ride", "R " .. tostring(nm))
            if mine_drives then
                log.info("vehicles: riding along in " .. tostring(nm))
                notify.show("Riding along - your friend is driving.", "info")
            end
        end
        if mine_drives then
            local s = seat_of(nm, P().my_slot())
            if s ~= ride_seat then ride_seat, ride_fix = s, 2 end
            if ride_fix > 0 and now - ride_at > 0.4 then
                ride_fix, ride_at = ride_fix - 1, now
                local pt = seat_point(car, s)
                if pt then pcall(function() p:K2_SetActorLocation(pt, false, {}, true) end) end
            end
        end
        return
    elseif riding then
        riding = nil
        link.put_blob("ride", "R -")
        log.info("vehicles: got out (passenger)")
    end
    if not car and driving then
        out_for = out_for + dt
        if out_for < 1.0 then car = driving end
    else out_for = 0.0 end
    if not util.same(car, driving) and (car or driving) then
        if driving and alive(driving) then
            local l, r = transform(driving)
            local n = peer_name(driving)
            if l and n then
                local f, h = fuel_health(driving)
                local used, lost = 0, 0
                if entered_with and f and h then
                    used = math.max(0, (entered_with.f or f) - f)
                    lost = math.max(0, (entered_with.h or h) - h)
                end
                link.put_blob("drive", "P " .. n .. " " .. fmt(l, r) .. " " .. state_of(driving)
                    .. string.format(" %.3f %.2f %.2f", now, used, lost))
                log.info(string.format("vehicles: parked %s (used %.1f fuel, lost %.1f health)", n, used, lost))
            end
            resend = true
        end
        driving = car
        entered_with = nil
        if car then
            local f, h = fuel_health(car)
            entered_with = { f = f, h = h }
            for i = #wake_at, 1, -1 do if util.same(wake_at[i].car, car) then table.remove(wake_at, i) end end
            frozen[util.addr(car) or 0] = nil

        end
        if car then log.info("vehicles: driving " .. tostring(peer_name(car)) .. " - the other game follows") end
    end
    if not driving then return end
    -- The car's movement rides in the pose packets (vehicles.drive_line); this reliable copy, with the
    -- car's class, is only for a car the other game doesn't have yet.
    send_in = send_in - dt
    if send_in > 0 then return end
    send_in = CLASS_EVERY
    local line = vehicles.drive_line()
    if line then link.put_blob("drive", line .. " " .. (class_path(driving) or "-")) end
end

-- One sample of the car being driven, sent with every pose (unreliable, with the previous two).
function vehicles.drive_line()
    if not (in_world and driving and alive(driving)) then return nil end
    local l, r = transform(driving)
    local n = peer_name(driving)
    if not (l and n) then return nil end
    local v = { X = 0, Y = 0, Z = 0 }
    pcall(function() local vv = driving:GetVelocity(); v = { X = vv.X, Y = vv.Y, Z = vv.Z } end)
    local eng, lit = false, false
    pcall(function() eng = driving["EngineOn?"] == true end)
    pcall(function() lit = driving["LightsOn?"] == true end)
    local line = string.format("D %s %.0f %.0f %.0f %.1f %.1f %.1f %.0f %.0f %.0f %d %d %.3f", n, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll,
        v.X, v.Y, v.Z, eng and 1 or 0, lit and 1 or 0, now)
    local towed
    pcall(function()
        if driving["TowingVehicle?"] == true then towed = driving.PhysicsConstraintComp:GetOwner() end
    end)
    if alive(towed) and not util.same(towed, driving) then
        local tl, tr = transform(towed)
        local tn = peer_name(towed)
        if tl and tn then line = line .. string.format(" T %s %.0f %.0f %.0f %.1f %.1f %.1f", tn, tl.X, tl.Y, tl.Z, tr.Pitch, tr.Yaw, tr.Roll) end
    end
    return line
end

-- Seats: 0 driver (the car's PlayerLocation), 1 front passenger (mirrored across the car), 2 and 3 the
-- seats behind them. The game has only the driver's seat; the others are spots the mod puts people in.
local REAR = 95
seat_point = function(car, seat)
    seat = (seat == true and 1) or tonumber(seat) or 0
    local pt
    pcall(function()
        local t = car.PlayerLocation:K2_GetComponentToWorld()
        pt = { X = t.Translation.X, Y = t.Translation.Y, Z = t.Translation.Z }
        if seat % 2 == 1 then
            local c, rv = car:K2_GetActorLocation(), car:GetActorRightVector()
            local d = (pt.X - c.X) * rv.X + (pt.Y - c.Y) * rv.Y + (pt.Z - c.Z) * rv.Z
            pt = { X = pt.X - 2 * d * rv.X, Y = pt.Y - 2 * d * rv.Y, Z = pt.Z - 2 * d * rv.Z }
        end
        if seat >= 2 then
            local fv = car:GetActorForwardVector()
            pt = { X = pt.X - REAR * fv.X, Y = pt.Y - REAR * fv.Y, Z = pt.Z - REAR * fv.Z }
        end
    end)
    return pt
end

local peers_mod
P = function() peers_mod = peers_mod or require("mirror.peers"); return peers_mod end
-- slot (host 0, guests 1-3) of the player this copy shows
function vehicles.player_slot() local t = link.tags(); return P().slot_of(t and t.out) end
-- name of the car this copy's player rides along in (nil = none)
function vehicles.rides_in() return peer_rides end

-- Passenger seat (1-3) of the player in `slot` riding car n: the riders in slot order, the same on every game.
seat_of = function(n, slot)
    local set, order = {}, {}
    local function add(s) if s and not set[s] then set[s] = true; order[#order + 1] = s end end
    if riding and peer_name(riding) == n then add(P().my_slot()) end
    P().each("mirror.vehicles", function(m)
        if m.rides_in and m.rides_in() == n then add(m.player_slot()) end
    end)
    add(slot)
    table.sort(order)
    for i, s in ipairs(order) do if s == slot then return math.min(i, 3) end end
    return 1
end

local function seat_ghost(car, seat)
    local g = ghost.get()
    if not (g and alive(car)) then return end
    seat = (seat == true and 1) or tonumber(seat) or 0
    -- moving seats: off the old one first
    if seated then pcall(function() g:K2_DetachFromActor(1, 1, 1) end) end
    -- collision off before the move: a body put into the seat with collision on pushes the car away
    pcall(function() g:SetActorEnableCollision(false) end)
    local pt = seat_point(car, seat)
    if pt then pcall(function() g:K2_SetActorLocationAndRotation(pt, car:K2_GetActorRotation(), false, {}, true) end) end
    pcall(function() g.CharacterMovement:SetMovementMode(0, 0) end)
    pcall(function() g:K2_AttachToActor(car, FName("None"), 1, 1, 1, true) end)
    local m = StaticFindObject(SIT)
    if util.valid(m) then pcall(function() g:PlayAnimMontage(m, 1.0, FName("None")) end) end
    ghost.set_seated(true)
    seated, seated_as, seated_seat = true, seat > 0 and "passenger" or "driver", seat
end
local function unseat_ghost()
    if not seated then return end
    seated = false
    ghost.set_seated(false)
    local g = ghost.get()
    if g then
        local car
        pcall(function() car = g:GetAttachParentActor() end)
        pcall(function() g:K2_DetachFromActor(1, 1, 1) end)
        pcall(function() g:StopAnimMontage(nil) end)
        if alive(car) then
            pcall(function()
                local d = car.Mesh:GetSocketLocation(FName(seated_as == "passenger" and "PassengerSide" or "DriverSide"))
                g:K2_SetActorLocation({ X = d.X, Y = d.Y, Z = d.Z + 20 }, false, {}, true)
            end)
        end
        ghost_collide_at = now + 0.5
    end
    seated_as = nil
end

local function car_effects(car, eng, lit)
    pcall(function() if eng then car.EngineSound:Activate(false) else car.EngineSound:Deactivate() end end)
    pcall(function() car.LightLeft:SetVisibility(lit, true) end)
    pcall(function() car.LightRight:SetVisibility(lit, true) end)
end

local function release_peer_car(final_l, final_r)
    if not peer then return end
    local c = peer.car
    if alive(c) then
        if final_l then place_hard(c, final_l, final_r) end
        if util.same(riding, c) then
            pcall(function() c.Mesh:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
            pcall(function() c.HitBoxCollision:SetGenerateOverlapEvents(true) end)
        else
            follow_mode(c, false)
        end
        car_effects(c, false, false)
    end
    if peer.tow and alive(peer.tow.car) then follow_mode(peer.tow.car, false) end
    unseat_ghost()
    peer = nil
end

local function apply_drive(body)
    local k, n, rest = body:match("^(%a) (%S+) (.*)$")
    if not k then return end
    local nums = {}
    for x in rest:gmatch("%S+") do nums[#nums + 1] = tonumber(x) end
    local l = { X = nums[1], Y = nums[2], Z = nums[3] }
    local r = { Pitch = nums[4], Yaw = nums[5], Roll = nums[6] }
    if k == "P" then
        if nums[10] then parked[n] = nums[10] end
        if driving and util.same(car_named(n), driving) then return end
        local pc = car_named(n)
        if pc then
            local f, h = nums[8], nums[9]
            -- Newer games send what the drive used: apply that to this world's numbers, never the
            -- driver's copy of them (a copy that was out of date would empty a refuelled car here).
            if nums[11] and nums[12] then
                local lf, lh = fuel_health(pc)
                if lf then f = math.max(0, lf - nums[11]) end
                if lh then h = math.max(0, lh - nums[12]) end
            end
            set_state(pc, nums[7], f, h)
            remember_state(n, pc)
        end
        if peer and peer.name == n then release_peer_car(l, r) else
            local c = car_named(n)
            if c then place_hard(c, l, r) end
        end
        resend = true
        log.info("vehicles: the other player parked " .. n)
        return
    end
    if k ~= "D" then return end
    local ts0 = nums[12]
    if parked[n] and ts0 and ts0 <= parked[n] then return end
    local mine = driving and car_named(n)
    if mine and util.same(mine, driving) then
        -- we both got into this car: the lower slot drives, the other rides along (send_drive switches)
        if vehicles.player_slot() > P().my_slot() then return end
        log.info("vehicles: " .. link.peer_name() .. " got into " .. n .. " too - they drive, I ride along")
    end
    if peer and peer.name ~= n then release_peer_car() end
    if not peer then
        local c = car_named(n)
        -- a third player's game: two others in this car - the lower slot's copy follows it
        if c and vehicles.other_drives(c, vehicles.player_slot()) then return end
        if not c then
            local cp = rest:match("(/%S+)$")
            if cp and not made_for_drive[n] then
                made_for_drive[n] = true
                pending[n] = nil
                local cls = StaticFindObject(cp)
                local a
                if util.valid(cls) then pcall(function() a = game.world():SpawnActor(cls, l, r) end) end
                if util.valid(a) then
                    local mine = name_of(a)
                    alias[n], rev[mine or ""] = a, n
                    if mine then cars[mine] = a end
                    unknown[n] = nil
                    stats.added = stats.added + 1
                    log.info("vehicles: the other player drives a car this game didn't have (" .. (cp:match("([%w_]+)$") or cp) .. ") - made it")
                    c = a
                else
                    log.warn("vehicles: the other player's car " .. n .. " isn't here and couldn't be made (" .. cp .. ")")
                end
            end
            if not c then return end
        end
        follow_mode(c, true)
        peer = { car = c, name = n }
        frozen[util.addr(c) or 0] = nil
        log.info("vehicles: the other player is driving " .. n)
    end
    peer.to = { loc = l, rot = r, vel = { X = nums[7] or 0, Y = nums[8] or 0, Z = nums[9] or 0 }, at = now }
    local ts = nums[12] or now
    local q = peer.samples or {}
    peer.samples = q
    local tn, tx, ty, tz, tp, tyw, tro = rest:match(" T (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)")
    local tow
    if tn then
        local tc = (peer.tow and peer.tow.name == tn) and peer.tow.car or car_named(tn)
        if tc and not util.same(tc, peer.car) then
            if not (peer.tow and util.same(peer.tow.car, tc)) then
                if peer.tow and alive(peer.tow.car) then follow_mode(peer.tow.car, false) end
                follow_mode(tc, true)
                frozen[util.addr(tc) or 0] = nil
                peer.tow = { car = tc, name = tn }
                log.info("vehicles: the other player tows " .. tn)
            end
            tow = { loc = { X = tonumber(tx), Y = tonumber(ty), Z = tonumber(tz) },
                    rot = { Pitch = tonumber(tp), Yaw = tonumber(tyw), Roll = tonumber(tro) } }
        end
    elseif peer.tow then
        if alive(peer.tow.car) then follow_mode(peer.tow.car, false) end
        log.info("vehicles: the other player unhooked " .. peer.tow.name)
        peer.tow = nil
    end
    if not q[#q] or ts > q[#q].t then
        q[#q + 1] = { t = ts, loc = l, rot = r, vel = peer.to.vel, tow = tow }
        stats.samples = (stats.samples or 0) + 1
        if #q > 40 then table.remove(q, 1) end
        local offs = peer.offs or {}
        peer.offs = offs
        offs[#offs + 1] = now - ts
        if #offs > 45 then table.remove(offs, 1) end
        local m = offs[1]
        for i = 2, #offs do if offs[i] < m then m = offs[i] end end
        peer.off = m
        -- Playback delay: how late samples arrive beyond the fastest one (90th percentile), plus a margin.
        local late = {}
        for i = 1, #offs do late[i] = offs[i] - m end
        table.sort(late)
        peer.delay = math.max(MIN_DELAY, math.min(MAX_DELAY, (late[math.ceil(#late * 0.9)] or 0) + 0.04))
    end
    local eng, lit = (nums[10] or 0) == 1, (nums[11] or 0) == 1
    if eng ~= peer.engine or lit ~= peer.lights then
        peer.engine, peer.lights = eng, lit
        car_effects(peer.car, eng, lit)
    end
    if not seated then seat_ghost(peer.car) end
end

apply_ride = function(body)
    local n = body:match("^R (%S+)$")
    if not n then return end
    if n == "-" then
        if peer_rides then peer_rides = nil; unseat_ghost() end
        log.info("vehicles: the other player got out")
        return
    end
    local c = car_named(n)
    if not c then return end
    if peer and peer.name == n then
        -- they were driving it and now ride along (someone with a lower slot got in): the driver's copy
        -- follows the car from now on - let go of it without parking it
        unseat_ghost(); peer = nil
    end
    peer_rides = n
    seat_ghost(c, seat_of(n, vehicles.player_slot()))
    log.info("vehicles: the other player rides along in " .. n)
end

local lerp, lerp_deg = util.lerp, util.lerp_angle
local function follow(dt)
    if not (peer and peer.samples and peer.off and alive(peer.car)) then return end
    if peer.to and now - peer.to.at > 5.0 then
        log.info("vehicles: no word from the other player's car for 5 s - released where it is")
        release_peer_car()
        return
    end
    local q = peer.samples
    local t = now - peer.off - (peer.delay or 0.15)
    local a, b
    for i = #q, 1, -1 do
        if q[i].t <= t then a, b = q[i], q[i + 1]; break end
    end
    local l, r, v, tl, tr
    if a and b then
        local f = (t - a.t) / math.max(b.t - a.t, 0.001)
        l = { X = lerp(a.loc.X, b.loc.X, f), Y = lerp(a.loc.Y, b.loc.Y, f), Z = lerp(a.loc.Z, b.loc.Z, f) }
        r = { Pitch = lerp_deg(a.rot.Pitch, b.rot.Pitch, f), Yaw = lerp_deg(a.rot.Yaw, b.rot.Yaw, f), Roll = lerp_deg(a.rot.Roll, b.rot.Roll, f) }
        v = { X = lerp(a.vel.X, b.vel.X, f), Y = lerp(a.vel.Y, b.vel.Y, f), Z = lerp(a.vel.Z, b.vel.Z, f) }
        if a.tow and b.tow then
            tl = { X = lerp(a.tow.loc.X, b.tow.loc.X, f), Y = lerp(a.tow.loc.Y, b.tow.loc.Y, f), Z = lerp(a.tow.loc.Z, b.tow.loc.Z, f) }
            tr = { Pitch = lerp_deg(a.tow.rot.Pitch, b.tow.rot.Pitch, f), Yaw = lerp_deg(a.tow.rot.Yaw, b.tow.rot.Yaw, f), Roll = lerp_deg(a.tow.rot.Roll, b.tow.rot.Roll, f) }
        elseif (b or a).tow then tl, tr = (b or a).tow.loc, (b or a).tow.rot end
    else
        local s0 = a or q[1]
        if not s0 then return end
        local ahead = math.max(0, math.min(t - s0.t, 0.3))
        l = { X = s0.loc.X + s0.vel.X * ahead, Y = s0.loc.Y + s0.vel.Y * ahead, Z = s0.loc.Z + s0.vel.Z * ahead }
        r, v = s0.rot, s0.vel
        if s0.tow then
            tl = { X = s0.tow.loc.X + s0.vel.X * ahead, Y = s0.tow.loc.Y + s0.vel.Y * ahead, Z = s0.tow.loc.Z + s0.vel.Z * ahead }
            tr = s0.tow.rot
        end
    end
    local car = peer.car
    -- The car's HitBox runs over AI for the LOCAL player (causer GetPlayerCharacter): only the driver's
    -- game may hit with it, or both games kill the zombie and both pay the XP. Getting in as a
    -- passenger turns it back on, so re-check every second.
    if not peer.hitbox_at or now - peer.hitbox_at > 1.0 then
        peer.hitbox_at = now
        pcall(function() car.HitBoxCollision:SetGenerateOverlapEvents(false) end)
        if peer.tow and alive(peer.tow.car) then pcall(function() peer.tow.car.HitBoxCollision:SetGenerateOverlapEvents(false) end) end
    end
    if riding then
        pcall(function() car.VehicleMovementComponent:SetThrottleInput(0) end)
        pcall(function() car.VehicleMovementComponent:SetBrakeInput(0) end)
        pcall(function() car.VehicleMovementComponent:SetSteeringInput(0) end)
        pcall(function() car.VehicleMovementComponent:SetHandbrakeInput(false) end)
    end
    local ok, moved = pcall(function() return car:K2_TeleportTo(l, r) end)
    if not (ok and moved ~= false) then
        stats.refused = (stats.refused or 0) + 1
        pcall(function() car:SetActorEnableCollision(false) end)
        place(car, l, r)
        pcall(function() car:SetActorEnableCollision(true) end)
    end
    pcall(function() car.Mesh:SetPhysicsLinearVelocity(v, false, FName("None")) end)
    pcall(function() car.Mesh:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
    local tc = peer.tow and peer.tow.car
    if tl and tl.X and alive(tc) then
        local tok, tmoved = pcall(function() return tc:K2_TeleportTo(tl, tr) end)
        if not (tok and tmoved ~= false) then place_hard(tc, tl, tr) end
        pcall(function() tc.Mesh:SetPhysicsLinearVelocity(v, false, FName("None")) end)
        pcall(function() tc.Mesh:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
    end
end

-- A sample of the car the other player drives, from their pose packets.
function vehicles.drive_sample(body)
    if not (cfg and cfg.mirror_vehicles and in_world) then return end
    util.safe(apply_drive, "vehicles.drive", body)
end

function vehicles.tick(dt)
    if not (cfg and cfg.mirror_vehicles) then return end
    now = now + dt
    scan_age = scan_age + dt
    local inside = shared() and role ~= nil
    if inside ~= in_world then
        in_world, entered_at = inside, now
        list_sent, host_cars, pass = nil, nil, 0
        -- A fresh start (or a restart after a crash) isn't riding along: say so, or the other game
        -- keeps seating us from the last ride it heard about.
        if inside then riding = nil; link.put_blob("ride", "R -") end
        if not inside then
            release_peer_car(); peer_rides = nil; unseat_ghost()
            alias, rev, driving, retired, frozen, unknown, wake_at, pending = {}, {}, nil, {}, {}, {}, {}, {}
            made_for_drive, parked = {}, {}
            known_state, told, applied_state = {}, {}, {}
        end
    end
    if not in_world then return end
    if role == "host" then
        local guest_here = session and session.guest_in_world and session.guest_in_world()
        if not guest_here and (peer or peer_rides) then
            release_peer_car(); peer_rides = nil; unseat_ghost()
            log.info("vehicles: the other player left - their car and seat let go")
        end
        if guest_here then
            car_hook_in = car_hook_in - dt
            if car_hook_in <= 0 then car_hook_in = 2.0; util.ensure_hook(MASTER .. ":ReceiveBeginPlay", on_car_begin) end
            if new_car and list_sent ~= nil and now - list_at >= 2.0 then
                new_car, list_at = false, now
                local body = host_list()
                if body ~= list_sent then list_sent = body; link.put_blob("cars", body) end
            end
            if (list_sent == nil or (resend and now - list_at >= LIST_EVERY)) and not util.job_running("vehicles.hostlist") then
                resend, list_at = false, now
                util.job("vehicles.hostlist", function()
                    if not scan() then resend = true; return end
                    local body = host_list()
                    if body ~= list_sent then list_sent = body; link.put_blob("cars", body) end
                end)
            end
        else list_sent = nil end
    else
        local body = link.get_blob("cars")
        if body then host_cars, pass = body, (host_cars and #PASSES - 1 or 0) end
        local due = PASSES[pass + 1]
        if host_cars and due and now - entered_at >= due and now - applied_at >= (pass == 0 and LIST_EVERY or 0)
                and not util.job_running("vehicles.list") then
            applied_at = now
            pass = pass + 1
            local b = host_cars
            util.job("vehicles.list", function()
                util.safe(stop_spawners, "vehicles.spawners")
                local ok, done = util.safe(apply_list, "vehicles.list", b)
                if ok and done == false then pass, applied_at = pass - 1, -100.0 end
            end)
        end
    end
    for i = #wake_at, 1, -1 do
        local w = wake_at[i]
        if now >= w.at then
            table.remove(wake_at, i)
            if alive(w.car) and not (peer and util.same(peer.car, w.car)) then follow_mode(w.car, false) end
        end
    end
    wake_in = wake_in - dt
    if wake_in <= 0 then wake_in = 1.0; util.safe(wake_near, "vehicles.wake") end
    util.safe(send_drive, "vehicles.send", dt)
    local rb = link.get_blob("ride")
    if rb then util.safe(apply_ride, "vehicles.ride", rb) end
    local d = link.get_blob("drive")
    if d then util.safe(apply_drive, "vehicles.drive", d) end
    util.safe(follow, "vehicles.follow", dt)
    if mate then
        util.safe(follow, "vehicles.follow", dt)
        local g = ghost.get()
        if g and seated and peer_rides and not peer then
            -- someone else got in or out: riders keep their slot order
            local c, want = car_named(peer_rides), seat_of(peer_rides, vehicles.player_slot())
            if c and want ~= seated_seat then seat_ghost(c, want) end
        end
        if not g and seated then seated, seated_as = false, nil; ghost.set_seated(false)
        elseif g and not seated then
            if peer and alive(peer.car) then seat_ghost(peer.car, false)
            elseif peer_rides then local c = car_named(peer_rides); if c then seat_ghost(c, seat_of(peer_rides, vehicles.player_slot())) end end
        end
        return
    end
    local function busy(c)
        return util.same(c, driving) or vehicles.peer_drives(c) or vehicles.other_drives(c)
    end
    if ghost.get() then util.safe(watch_states, "vehicles.states", dt, busy) end
    local cs = link.get_blob("carstate")
    if cs then util.safe(apply_states, "vehicles.carstate", cs, busy, car_named) end
    if ghost_collide_at and now >= ghost_collide_at then
        ghost_collide_at = nil
        local g0 = ghost.get()
        if g0 and not seated then
            pcall(function() g0:SetActorEnableCollision(true) end)
            pcall(function() g0.CharacterMovement:SetMovementMode(1, 0) end)
        end
    end
    local g = ghost.get()
    if g and seated and peer_rides and not peer then
        -- someone else got in or out: riders keep their slot order
        local c, want = car_named(peer_rides), seat_of(peer_rides, vehicles.player_slot())
        if c and want ~= seated_seat then seat_ghost(c, want) end
    end
    if not g and seated then seated, seated_as = false, nil; ghost.set_seated(false)
    elseif g and not seated then
        if peer and alive(peer.car) then seat_ghost(peer.car, false)
        elseif peer_rides then local c = car_named(peer_rides); if c then seat_ghost(c, seat_of(peer_rides, vehicles.player_slot())) end end
    end
end

-- Is the player of this copy driving (or towing) car c?
function vehicles.peer_drives(c)
    return (peer and (util.same(c, peer.car) or (peer.tow and util.same(c, peer.tow.car)))) or false
end

-- 4 players: is another player's copy of this module driving car c? (its moves come from them, not the host's list)
-- below_slot: only copies whose player has a lower slot count
function vehicles.other_drives(c, below_slot)
    local hit = false
    P().each("mirror.vehicles", function(m)
        if not hit and m ~= vehicles and m.peer_drives and m.peer_drives(c)
                and (not below_slot or m.player_slot() < below_slot) then hit = true end
    end)
    return hit
end

-- Why a player can't be teleported right now (nil = not in or towing a car).
function vehicles.busy()
    if driving then return "you are in a vehicle - get out first" end
    if riding then return "you are riding in a vehicle - get out first" end
    if peer then return "the other player is driving - wait until they park" end
    if peer_rides then return "the other player is riding in your car" end
    return nil
end

function vehicles.status()
    return string.format("vehicles: car updates received %d | driving %s | the other player's car %s | cars moved %d, added %d, removed %d, spawners stopped %d",
        stats.samples or 0, driving and tostring(peer_name(driving)) or "-", peer and peer.name or "-", stats.moved, stats.added, stats.removed, stats.spawners)
end

-- The old world's cars are gone (respawn/reload): drop them, keep what the other game told us.
local function forget_world()
    cars, alias, rev, retired, frozen, unknown, wake_at, pending = {}, {}, {}, {}, {}, {}, {}, {}
    made_for_drive, parked, known_state, near_cars, state_keys, state_idx = {}, {}, {}, {}, {}, 0
    driving, riding, entered_with, peer, master_cls = nil, nil, nil, nil, nil
    seated, seated_as, ghost_collide_at = false, nil, nil
    scan_age, list_sent, pass, entered_at, applied_at = math.huge, nil, 0, now, -100.0
    state_keys, state_idx = {}, 0
end

function vehicles.init(c, r, s, is_mate)
    cfg, role, session, mate = c, r, s, is_mate == true
    game.on_world_reset(forget_world)
end

return vehicles
