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
local SEND_EVERY = 0.05

local cfg, role, session
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
local ride_fix, ride_at = 0, -100.0
local peer_rides = nil
local LIST_EVERY = 5.0
local list_at, applied_at = -100.0, -100.0
local PASSES = { 3, 10, 18 }
local host_cars, pass = nil, 0
local stats = { moved = 0, added = 0, removed = 0, spawners = 0 }

local apply_ride, seat_point, physics
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
local function name_of(a) local n; pcall(function() n = a:GetFName():ToString() end); return n end
local new_car, car_hook_in = false, 0.0
local function on_car_begin(self)
    if role ~= "host" or not in_world then return end
    local a
    pcall(function() a = self:get() end)
    if not alive(a) then return end
    local n = name_of(a)
    if n and not alive(cars[n]) then cars[n] = a; new_car = true; log.info("vehicles: a new car here (" .. n .. ") - telling the other game") end
end
local function class_path(a)
    local p
    pcall(function() p = a:GetClass():GetFullName():match("^%S+ (.+)$") end)
    return p
end
local master_cls = nil
local function is_car(a)
    if not util.valid(a) then return false end
    if not util.valid(master_cls) then master_cls = StaticFindObject(MASTER) end
    local yes = false
    if util.valid(master_cls) then pcall(function() yes = a:IsA(master_cls) == true end) end
    return yes
end

local function scan()
    cars = {}
    for _, t in ipairs(TYPES) do
        util.pause()
        for _, v in ipairs(FindAllOf("Vehicle_" .. t .. "_C") or {}) do
            if alive(v) and not v:GetFullName():find("Default__", 1, true) then
                local n = name_of(v)
                if n then cars[n] = v end
            end
        end
    end
    scan_age = 0.0
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
local function set_state(car, c, f, h)
    c, f, h = tonumber(c), tonumber(f), tonumber(h)
    if c and c >= 0 then
        pcall(function()
            if car.VehicleColor ~= c then
                car.VehicleColor = c
                car.Mesh:SetMaterial(0, car.Colors[c + 1])
            end
        end)
    end
    if f and f >= 0 then pcall(function() car.FuelComponent.CurrentFuel = f end) end
    if h and h >= 0 then
        local before
        pcall(function() before = car.VehicleHealthComponent.CurrentHealth end)
        pcall(function() car.VehicleHealthComponent.CurrentHealth = h end)
        if h > 0 and (tonumber(before) or 0) <= 0 then
            pcall(function() car:VehicleEngineFX(false) end)
            pcall(function() car["EngineOn?"] = true end)
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
        util.pause()
        for _, s in ipairs(FindAllOf(cls) or {}) do
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
    scan()
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
                local busy = (peer and util.same(peer.car, c)) or util.same(c, driving)
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
    if car and peer and util.same(car, peer.car) then
        if not util.same(riding, car) then
            riding, ride_fix = car, 2
            link.put_blob("ride", "R " .. tostring(peer.name))
            log.info("vehicles: riding along in " .. tostring(peer.name))
            notify.show("Riding along - your friend is driving.", "info")
        end
        if ride_fix > 0 and now - ride_at > 0.4 then
            ride_fix, ride_at = ride_fix - 1, now
            local pt = seat_point(car, true)
            if pt then pcall(function() p:K2_SetActorLocation(pt, false, {}, true) end) end
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
            if l and n then link.put_blob("drive", "P " .. n .. " " .. fmt(l, r) .. " " .. state_of(driving)); log.info("vehicles: parked " .. n) end
            resend = true
        end
        driving = car
        if car then
            for i = #wake_at, 1, -1 do if util.same(wake_at[i].car, car) then table.remove(wake_at, i) end end
            frozen[util.addr(car) or 0] = nil

        end
        if car then log.info("vehicles: driving " .. tostring(peer_name(car)) .. " - the other game follows") end
    end
    if not driving then return end
    send_in = send_in - dt
    if send_in > 0 then return end
    send_in = SEND_EVERY
    local l, r = transform(driving)
    local n = peer_name(driving)
    if not (l and n) then return end
    local v = { X = 0, Y = 0, Z = 0 }
    pcall(function() local vv = driving:GetVelocity(); v = { X = vv.X, Y = vv.Y, Z = vv.Z } end)
    local eng, lit = false, false
    pcall(function() eng = driving["EngineOn?"] == true end)
    pcall(function() lit = driving["LightsOn?"] == true end)
    link.put_blob("drive", string.format("D %s %s %.0f %.0f %.0f %d %d %.3f %s", n, fmt(l, r), v.X, v.Y, v.Z, eng and 1 or 0,
        lit and 1 or 0, now, class_path(driving) or "-"))
end

seat_point = function(car, passenger)
    local pt
    pcall(function()
        local t = car.PlayerLocation:K2_GetComponentToWorld()
        pt = { X = t.Translation.X, Y = t.Translation.Y, Z = t.Translation.Z }
        if passenger then
            local c, rv = car:K2_GetActorLocation(), car:GetActorRightVector()
            local d = (pt.X - c.X) * rv.X + (pt.Y - c.Y) * rv.Y + (pt.Z - c.Z) * rv.Z
            pt = { X = pt.X - 2 * d * rv.X, Y = pt.Y - 2 * d * rv.Y, Z = pt.Z - 2 * d * rv.Z }
        end
    end)
    return pt
end

local function seat_ghost(car, passenger)
    local g = ghost.get()
    if not (g and alive(car)) then return end
    local pt = seat_point(car, passenger)
    if pt then pcall(function() g:K2_SetActorLocationAndRotation(pt, car:K2_GetActorRotation(), false, {}, true) end) end
    pcall(function() g:SetActorEnableCollision(false) end)
    pcall(function() g.CharacterMovement:SetMovementMode(0, 0) end)
    pcall(function() g:K2_AttachToActor(car, FName("None"), 1, 1, 1, true) end)
    local m = StaticFindObject(SIT)
    if util.valid(m) then pcall(function() g:PlayAnimMontage(m, 1.0, FName("None")) end) end
    ghost.set_seated(true)
    seated, seated_as = true, passenger and "passenger" or "driver"
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
        else
            follow_mode(c, false)
        end
        car_effects(c, false, false)
    end
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
        if driving and util.same(car_named(n), driving) then return end
        local pc = car_named(n)
        if pc then set_state(pc, nums[7], nums[8], nums[9]) end
        if peer and peer.name == n then release_peer_car(l, r) else
            local c = car_named(n)
            if c then place_hard(c, l, r) end
        end
        resend = true
        log.info("vehicles: the other player parked " .. n)
        return
    end
    if k ~= "D" then return end
    local mine = driving and car_named(n)
    if mine and util.same(mine, driving) then return end
    if peer and peer.name ~= n then release_peer_car() end
    if not peer then
        local c = car_named(n)
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
    if not q[#q] or ts > q[#q].t then
        q[#q + 1] = { t = ts, loc = l, rot = r, vel = peer.to.vel }
        stats.samples = (stats.samples or 0) + 1
        if #q > 40 then table.remove(q, 1) end
        local offs = peer.offs or {}
        peer.offs = offs
        offs[#offs + 1] = now - ts
        if #offs > 45 then table.remove(offs, 1) end
        local m = offs[1]
        for i = 2, #offs do if offs[i] < m then m = offs[i] end end
        peer.off = m
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
    peer_rides = n
    seat_ghost(c, true)
    log.info("vehicles: the other player rides along in " .. n)
end

local DELAY = 0.15
local lerp, lerp_deg = util.lerp, util.lerp_angle
local function follow(dt)
    if not (peer and peer.samples and peer.off and alive(peer.car)) then return end
    if peer.to and now - peer.to.at > 5.0 then
        log.info("vehicles: no word from the other player's car for 5 s - released where it is")
        release_peer_car()
        return
    end
    local q = peer.samples
    local t = now - peer.off - DELAY
    local a, b
    for i = #q, 1, -1 do
        if q[i].t <= t then a, b = q[i], q[i + 1]; break end
    end
    local l, r, v
    if a and b then
        local f = (t - a.t) / math.max(b.t - a.t, 0.001)
        l = { X = lerp(a.loc.X, b.loc.X, f), Y = lerp(a.loc.Y, b.loc.Y, f), Z = lerp(a.loc.Z, b.loc.Z, f) }
        r = { Pitch = lerp_deg(a.rot.Pitch, b.rot.Pitch, f), Yaw = lerp_deg(a.rot.Yaw, b.rot.Yaw, f), Roll = lerp_deg(a.rot.Roll, b.rot.Roll, f) }
        v = { X = lerp(a.vel.X, b.vel.X, f), Y = lerp(a.vel.Y, b.vel.Y, f), Z = lerp(a.vel.Z, b.vel.Z, f) }
    else
        local s0 = a or q[1]
        if not s0 then return end
        local ahead = math.max(0, math.min(t - s0.t, 0.3))
        l = { X = s0.loc.X + s0.vel.X * ahead, Y = s0.loc.Y + s0.vel.Y * ahead, Z = s0.loc.Z + s0.vel.Z * ahead }
        r, v = s0.rot, s0.vel
    end
    local car = peer.car
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
end

function vehicles.tick(dt)
    if not (cfg and cfg.mirror_vehicles) then return end
    now = now + dt
    scan_age = scan_age + dt
    local inside = shared() and role ~= nil
    if inside ~= in_world then
        in_world, entered_at = inside, now
        list_sent, host_cars, pass = nil, nil, 0
        if not inside then
            release_peer_car(); peer_rides = nil; unseat_ghost()
            alias, rev, driving, retired, frozen, unknown, wake_at, pending = {}, {}, nil, {}, {}, {}, {}, {}
            made_for_drive = {}
        end
    end
    if not in_world then return end
    if role == "host" then
        if session and session.guest_in_world and session.guest_in_world() then
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
                    scan()
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
                util.safe(apply_list, "vehicles.list", b)
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
    if ghost_collide_at and now >= ghost_collide_at then
        ghost_collide_at = nil
        local g0 = ghost.get()
        if g0 and not seated then
            pcall(function() g0:SetActorEnableCollision(true) end)
            pcall(function() g0.CharacterMovement:SetMovementMode(1, 0) end)
        end
    end
    local g = ghost.get()
    if not g and seated then seated, seated_as = false, nil; ghost.set_seated(false)
    elseif g and not seated then
        if peer and alive(peer.car) then seat_ghost(peer.car, false)
        elseif peer_rides then local c = car_named(peer_rides); if c then seat_ghost(c, true) end end
    end
end

function vehicles.status()
    return string.format("vehicles: car updates received %d | driving %s | the other player's car %s | cars moved %d, added %d, removed %d, spawners stopped %d",
        stats.samples or 0, driving and tostring(peer_name(driving)) or "-", peer and peer.name or "-", stats.moved, stats.added, stats.removed, stats.spawners)
end

function vehicles.init(c, r, s)
    cfg, role, session = c, r, s
end

return vehicles
