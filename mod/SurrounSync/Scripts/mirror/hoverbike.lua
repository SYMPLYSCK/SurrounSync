-- The hover bike (user 2026-11-03: "i built a hoverbike tho with a custom rider pose and animation", "it will use the same
-- fpvdrone flight engine just tuned", "this is gonna replace the jetpack btw, this is gonna have a 1000slot storage
-- copacity"). A bike is the game's own golf cart marked with VehicleColor MARK, so the game brings the
-- seat, the trunk (BP_JigMultiplayer, synced by loot.lua by the car's host name), saving and the car sync (vehicles.lua
-- sends VehicleColor, and the driver's pose to the other games, which seat the driver's ghost in their copy). Each game
-- dresses its own copy: the cart's mesh hidden, SK_HoverBike (SurrounSyncArmory.pak) on a PoseableMeshComponent attached
-- to it, the props turned bone by bone as FPVDrone's fpv/body.lua does.
-- Flying: mirror/fpvflight.lua is FPVDrone's fpv/flight.lua, unchanged (each UE4SS mod has its own Lua state, so a copy;
-- the suite checks they match), with this machine's numbers (TUNING). While its owner sits on it, it is no physics body:
-- simulation and collision off, the flight model places it every frame and traces keep it out of the world. Getting off
-- gives it back to the game's physics, moving as it was. The rider's Root goes on the model's seat and plays
-- A_Rider_Sit on the ground and A_Rider_Drive in the air.
-- Keys, sat on it: W / S lean forward and back, A / D turn and bank, Space climbs, Left Ctrl sinks, Left Shift leans
-- further for speed. Ctrl+Shift+V (owner): makes the bike, or brings the one in this world to you. Owner only, as the
-- jetpack it replaces was; its storage is anyone's.
-- Who rides it (user 2026-11-04: "nobody can operate the hoverbike BUT me unless I unlock it for everyone"): the owner,
-- and everyone else only after the owner's Ctrl+Shift+P. Anyone else who sits on a locked bike is put off it again, as the
-- cart under it would drive for them.
-- Or FPVDrone's RC remote (user 2026-11-03: "no use the HID remote too control it"): armed, the sticks fly it through its
-- own rc.lua and FPVDrone.ini, the same calibration as the quad, the mode switch picking angle or acro. Not armed, or the
-- remote lost in the air: the keys have it again, and hands off that holds its height and levels it.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local notify = require("mirror.notify")
local flight = require("mirror.fpvflight")
local noise = require("mirror.bikenoise")

local hoverbike = {}

local MASTER = "/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C"
local GROUP = "BP_VehicleMaster_C"
local CART = "/Game/Blueprints/Vehicles/Types/GolfCart/Vehicle_GolfCart.Vehicle_GolfCart_C"
local DIR = "/Game/Mods/SurrounSyncArmory/"
local MESH = DIR .. "SK_HoverBike.SK_HoverBike"
local ANIM_SIT = DIR .. "A_Rider_Sit.A_Rider_Sit"
local ANIM_DRIVE = DIR .. "A_Rider_Drive.A_Rider_Drive"
local SMA = "/Script/Engine.StaticMeshActor"
local POSEABLE = "/Script/Engine.PoseableMeshComponent"
local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local MOVABLE, NO_COLLISION, COMPONENT_SPACE = 2, 0, 1
local IDENTITY = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 },
                   Scale3D = { X = 1, Y = 1, Z = 1 } }
local BONES = { "prop_FL", "prop_FR", "prop_RL", "prop_RR" }   -- in flight.MOTORS' order

local MARK = 78            -- VehicleColor of a bike (the game's Colors list is a few entries)
local OLD_TRAILER = 77     -- VehicleColor of the cargo trailers this mod used to have
local NAME, CART_NAME = "Hover Bike", "Golf Cart"
local CHECK_S, SEAT_S = 1.0, 0.2
local LOAD_AGAIN_S = 5.0
local SPAWN_AHEAD_CM, SPAWN_UP_CM = 450, 60
local MAKE_WAIT_S = 20.0
local UUID_MESH, UUID_SIT, UUID_DRIVE, UUID_CART = 771301, 771302, 771303, 771304

-- 1000 slots (user: "1000slot storage copacity"): the trunk's grid. Field names as deathbags.lua writes them.
local C_NAME = "ContainerName_13_2E875F304DF2B4B31A44F98C299C3982"
local C_EQUIP = "IsEquipTo?_17_A70EBD1B42E398B0EB14E0B352CCC0A2"
local C_COLS = "Columns_4_A32AA159420F47D951669C9636084F9D"
local C_ROWS = "Rows_6_E1A84D8A441B19CA3C38D0BC029805A1"
local COLS, ROWS = 10, 100
-- (the same in a built container: the names the game's struct has there)
local J_COLS = "Columns_4_1D84448048078D988999ABA138CE1809"
local J_ROWS = "Rows_6_78B4BC5B449017D63758E79844375AE9"
local J_ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"

-- The rider: hoverbike_spec.json's seat socket, where the skeleton's Root goes, in the bike's space (cm). The capsule is
-- put so the mesh's Root lands there: the mesh's own offset in the capsule is read at run time.
local SEAT_X, SEAT_Z = -34.95, 36.84
local BLEND_S = 0.25
local ANIM_CHECK_S = 0.25
-- Root on the seat is the plan, the Pelvis where the bike's seat needs it is the result (user 2026-11-03: "the sitting
-- possition is way too low"; what pulls it down isn't known, so it's measured): A_Rider_Sit.fbx has the Pelvis 87.1 cm
-- over Root, the game had it 0.9 cm over (log 2026-11-04 01:12:00). Once the animation has blended in the rider is moved
-- until the bone is at HIP_Z, within HIP_DEAD (Drive's breathing moves it less than that), never more than HIP_MAX from
-- the plan and the tune. HIP_Z is the user's by eye ("+14cm"): 14 over the 107.7 a cap of 70 had stopped it at.
local HIP_BONE, HIP_Z = "Pelvis", 121.7
local HIP_SETTLE_S, HIP_GAIN, HIP_DEAD, HIP_MAX, HIP_LOG = 0.6, 0.5, 2, 100, 3
local TUNE_STEP = 2        -- cm a press of U (higher) or I (lower) moves the rider on top of that, until the game closes

-- The view (user 2026-11-03: "make it so the camera stays looking wher ethe bike is looking, basically giver it a good 3rd
-- person cam, but also a fpv cam too"), G switching: its own camera actor, as FPVDrone's ghost.lua has, so the character's
-- arm and the mouse play no part. Behind the bike: turned to its heading with a little lag, the horizon kept level, and it
-- doesn't follow the nose over in a flip. On it: hoverbike_spec.json's fpv_cam, turned with the bike, the rider hidden
-- (the eyes are inside the head), tilted up as a drone's camera is since flying forward leans it down.
local CAMERA = "/Script/Engine.CameraActor"
local CHASE_BACK, CHASE_UP, CHASE_LOOK = 560, 245, 120   -- cm behind, over the bike's origin; the height it looks at
local CHASE_TURN, CHASE_KEEP, CHASE_LAG = 4, 12, 350     -- 1/s turning to its heading, 1/s following it; cm at most behind
local CHASE_MIN_LEVEL, CHASE_MIN_UP = 0.3, 0.2           -- nose this level, top this far up: its heading can be followed
local CHASE_PAD, CHASE_OUT = 30, 5                       -- cm off a wall; 1/s back out after one
local CHASE_FOV, CHASE_FOV_FAST, FAST = 90, 105, 5000    -- deg; wide at this speed (cm/s)
local EYE_X, EYE_Z, EYE_TILT, EYE_FOV = 6.8, 195, 12, 100

-- The flight engine's numbers for this machine, over flight.DEFAULTS. Estimates, not measurements: a 2.6 m quad of about
-- 220 kg with its rider (the inertia a solid box that size), big props that spool slowly. The flight controller's gains
-- go with that spool (fast gains on slow motors ring). Battery off: it isn't a 6S pack.
hoverbike.TUNING = {
    mass = 220, arm = 0.745, inertia = { 150, 160, 220 }, twr = 2.6, idle = 0.08, thr_expo = 1.0,
    motor_tau = 0.1, prop_torque = 0.25, rot_drag = 0.5, windmill = 1, battery = 0,
    rc_smooth = 0.12, fc_p = 14, fc_d = 0.5, fc_ff = 0.5, fc_i = 20, fc_i_max = 300,
    drag_side = 5e-5, drag_up = 4e-4, drag_frame = 1e-4, drag_lin = 0.05, v_pitch = 12000,
    -- (roll, pitch: only acro on the remote reads these; yaw: 70 deg/s at full stick, the keys too)
    rates = { roll = { 1.0, 0.5, 0 }, pitch = { 1.0, 0.5, 0 }, yaw = { 0.35, 0, 0 } },
    angle_max = 32, angle_gain = 2.2, angle_rate = 70, substep = 1 / 240,
    flap = 0.05, wash_torque = 300, wash_thrust = 0.15, punch_torque = 60, punch_tau = 0.4,
}
local P = {}
for k, v in pairs(flight.DEFAULTS) do P[k] = v end
for k, v in pairs(hoverbike.TUNING) do P[k] = v end
hoverbike.P = P

local TURN_EASE = 1500     -- cm/s at which A / D turn it half as fast
local CRUISE_STICK = 0.65  -- W alone leans this far; Left Shift all the way
local BACK_STICK = 0.5
local BANK_STICK = 0.35    -- A / D lean it into the turn this far ...
local BRAKE, BRAKE_MAX = 5e-4, 0.6   -- stick per cm/s it leans against what the keys don't ask for: W / S off, it stops;
                                     -- it doesn't skid sideways through a turn
local CLIMB, SINK, HOLD_GAIN = 900, 700, 2.5   -- cm/s Space and Left Ctrl ask for; 1/s towards it (hands off: it holds)
local MAX_DT = 0.05
-- what keeps it out of the world (traced each frame, it being no physics body while flown): lines from these points,
-- the bike's body in its own space (cm; forward, right)
local BODY_UP, TOP = 70, 165
local PROBES = { { 0, 0 }, { 110, 0 }, { -110, 0 }, { 0, 110 }, { 0, -110 } }
local PAD = 15
local GROUND_UP = 0.7      -- a surface whose normal points up more than this is ground
local BOUNCE, SCRAPE = 0.2, 0.9
local LAND_LOOK = 40       -- cm under it: sat on where it stands, this near the ground it counts as landed
local SPIN, STEP_MAX = 900, 40   -- deg/s at a motor's full power; deg a frame at most (past 45 a 4-blade prop looks backward)
local PEER_SPIN = 0.4      -- a motor's share on a bike someone else hovers (twr 2.6 hovers at 0.385; their motors aren't sent)
local PEER = { PUSH = 0.4, FULL = 4000,   -- this much more share at this cm/s, or at a full climb
               TAU = 0.3, JUMP = 20000,   -- s, how fast what's seen is followed; cm/s, faster is no flight
               STILL = 50, LOOK_S = 0.25, -- cm/s: under it, is it on the ground? asked this often
               RUN_DOWN_TAU = 0.6, RUN_DOWN_END = 0.002 }   -- s, a motor's share falling with nobody on it; the share where it's done
local RADIO_LIFT = 0.2     -- remote armed: the throttle past this takes it off the ground (it hovers near a third)
local RIGHT_RATE = 360     -- deg/s it rolls back upright, down on its back after a flip
local HOLD, POSE = "FPVDrone.hold", "FPVDrone.pose"
local HOLD_S, RADIO_LOOK_S, QUAD_LOOK_S = 3.0, 1.0, 0.2

local dressed = {}         -- cart address -> { car, model, comp, rest, angle }
local F = nil              -- my flight: { car, st, landed, rider = { actor, at, anim, m, check } }
local them = nil           -- the other player's rider: { actor, car, anim, m, check }
local load_asked = {}      -- asset path -> when last asked
local made_here = {}       -- cart address -> true: made by this game just now, its trunk not built yet
local world_at = nil
local check_in, seat_in = 0, 0
local want_make, make_at = false, nil
local seated_car = nil
local view_eye = false     -- G: on the bike, not behind it (kept from flight to flight)
local want_view = false
local seat_tune, want_tune = 0, 0
local LOCK_BLOB, LOCK_SHARE_S, PUT_OFF_S, DOWN_MAX_S = "bikeopen", 5, 1.0, 60
local COME_DOWN = { down = true }
local open_mine, open_seen, want_lock = false, false, false   -- mine: the owner's choice; seen: what the owner's game says
local want_open = nil      -- /lock, /unlock: what want_lock is to set (nil: the key, the other way round)
local owner_peer = nil     -- (the kit: which player id counts as the owner, its test ids being no Steam accounts)
local share_in, put_off_in = 0, 0
local stats = { dressed = 0, made = 0, brought = 0, flights = 0, landed = 0, grid = 0, no_model = 0, told = 0, views = 0,
                lock_news = 0, put_off = 0 }

local function alive(a)
    if not util.valid(a) then return false end
    local dying = false
    pcall(function() dying = a:IsActorBeingDestroyed() == true end)
    return not dying
end

local function is_bike(car)
    local c
    pcall(function() c = car.VehicleColor end)
    return tonumber(c) == MARK
end
hoverbike.is_bike = is_bike
hoverbike.MARK = MARK

local function is_owner()
    local ok, yes = pcall(function() return require("mirror.adminfly").is_owner() end)
    return ok and yes == true
end

local function is_guest()
    local role = nil
    pcall(function() role = require("mirror.session").role() end)
    return role == "guest"
end

-- ---------------------------------------------------------------------------------------------------------------
-- the lock

-- The owner's game says "open" or "locked" as a blob on each of its links, again every LOCK_SHARE_S (the bridge sends only
-- a change, and a link that came back or a player who just joined gets it that way). Every other game believes it only
-- on the link to the owner's account, and only while that account is among the players: the owner gone, it's locked.
-- Locked is also where each game of the owner's starts.
local function owner_id()
    if owner_peer then return owner_peer end
    local id
    pcall(function() id = require("mirror.adminfly").OWNER end)
    return id
end

local function each_link(fn)
    local peers = package.loaded["mirror.peers"]
    if not peers then return end
    pcall(peers.each, "mirror.link", function(l, inst)
        pcall(fn, l, tostring(inst and inst.id or peers.main_id()))
    end)
end

local function share_lock()
    local text = open_mine and "open" or "locked"
    each_link(function(l) l.put_blob(LOCK_BLOB, text) end)
end

local function owner_here()
    local peers, id = package.loaded["mirror.peers"], owner_id()
    if not (peers and id) then return false end
    local there = false
    pcall(function()
        for _, w in ipairs(peers.players()) do there = there or tostring(w.id) == id end
    end)
    return there
end

local function read_lock()
    local was = open_seen
    if owner_here() then
        local id = owner_id()
        each_link(function(l, from)
            if from == id then
                local body = l.get_blob(LOCK_BLOB)
                if body then open_seen = body == "open" end
            end
        end)
    elseif open_seen then
        open_seen = false
        each_link(function(l) l.reset_blob(LOCK_BLOB) end)   -- (back with the same word, it counts as news)
    end
    if open_seen ~= was then
        stats.lock_news = stats.lock_news + 1
        log.info("hoverbike: " .. (open_seen and "unlocked" or "locked") .. " for everyone by its owner")
        notify.show(open_seen and "The owner unlocked the hover bike for everyone." or "The hover bike is locked: only its owner can ride it.",
            "info", "hoverbike")
    end
end

local function may_ride() return is_owner() or open_seen end

-- The game's way out, the player BP's whole exit as devtest's getout has it (ExitVehicle alone left a stale driving
-- component, and a kit guest crashed 4 cycles on; 2026-10-27). The game may refuse, a wall at the door: the brakes
-- stay on till the next try.
local function put_off(p, car)
    put_off_in = put_off_in - SEAT_S
    local still = car
    if put_off_in <= 0 then
        put_off_in = PUT_OFF_S
        pcall(function() car:ExitVehicle({}) end)
        pcall(function() still = p:GetAttachParentActor() end)
    end
    if util.same(still, car) then
        pcall(function()
            local m = car.VehicleMovementComponent
            m:SetThrottleInput(0)
            m:SetSteeringInput(0)
            m:SetHandbrakeInput(true)
        end)
        return
    end
    pcall(function() p:ResetVehicleCameraArmLength() end)
    pcall(function() p:VehicleInteraction(false, car) end)
    pcall(function() p.VehicleDrivingComponent.Vehicle = nil end)
    stats.put_off = stats.put_off + 1
    log.info("hoverbike: locked, the rider put off it")
end

-- Asks the engine to load an asset in the background (its latent LoadAsset only queues it; a load from our Lua that
-- waits can deadlock on UE4SS's Lua lock, L-014). Again at most every LOAD_AGAIN_S.
local function ask_load(path, uuid)
    local t = os.clock()
    if t < (load_asked[path] or -100) + LOAD_AGAIN_S then return end
    load_asked[path] = t
    local K, w = util.cdo(KSL), game.world()
    if not (K and util.valid(w)) then return end
    local ok = pcall(function()
        K:LoadAsset(w, K:Conv_SoftObjPathToSoftObjRef(K:MakeSoftObjectPath(path)), {},
            { Linkage = 0, UUID = uuid, ExecutionFunction = FName("None"), CallbackTarget = w })
    end)
    log.info("hoverbike: asked the game to load " .. path:match("[^/]+$") .. (ok and "" or " (failed)"))
end

-- A bike never wears out, and the game's engine stays off so its driving input does nothing: BP_VehicleMaster gives a new
-- car 10-40 % health and 0-5 % fuel, smokes at low health, and gates the throttle on EngineOn?.
local FX = { "SmokeFX", "FireFX" }
local WIDGETS = { "FuelWidget", "RepairWidget" }
local function keep(car)
    pcall(function() if car.Name:ToString() ~= NAME then car.Name = NAME end end)
    pcall(function()
        local h = car.VehicleHealthComponent
        if h.CurrentHealth < h.MaxHealth then h.CurrentHealth = h.MaxHealth end
    end)
    pcall(function()
        local f = car.FuelComponent
        if f.CurrentFuel < f.MaxFuel then f.CurrentFuel = f.MaxFuel end
        if f.Empty then f.Empty = false end
    end)
    pcall(function() if car["EngineOn?"] ~= false then car["EngineOn?"] = false end end)
    pcall(function() if car.bCanBeDamaged ~= false then car.bCanBeDamaged = false end end)
    -- (getting in starts the golf cart's engine sound whatever EngineOn? says, if there's fuel, and a bike always has fuel)
    pcall(function() car.EngineSound:SetVolumeMultiplier(0) end)
    for _, n in ipairs(FX) do
        pcall(function() local fx = car[n]; if util.valid(fx) and fx:IsActive() then fx:Deactivate() end end)
    end
    for _, n in ipairs(WIDGETS) do
        pcall(function() local w = car[n]; if util.valid(w) and w.bHiddenInGame ~= true then w:SetHiddenInGame(true, false) end end)
    end
end

-- a cart that lost the mark is a golf cart again
local function unkeep(car)
    pcall(function() car.Name = CART_NAME end)
    pcall(function() car.Mesh:SetHiddenInGame(false, false) end)
    for _, n in ipairs(WIDGETS) do pcall(function() car[n]:SetHiddenInGame(false, false) end) end
    pcall(function() car.bCanBeDamaged = true end)
    pcall(function() car["EngineOn?"] = true end)
    pcall(function() car.EngineSound:SetVolumeMultiplier(1) end)
end

-- Found is not loaded: a mesh drawn with a load step left crashed the engine's GPU skin cache (FPVDrone's body.lua,
-- 2026-11-03), so it isn't used until its load bits are clear.
local PENDING = nil
local function loaded(m)
    if PENDING == nil then
        PENDING = 0
        pcall(function()
            local E = EObjectFlags
            PENDING = E.RF_NeedInitialization | E.RF_NeedLoad | E.RF_NeedPostLoad | E.RF_NeedPostLoadSubobjects
        end)
    end
    if PENDING == 0 then return true end
    local busy = false
    pcall(function() busy = m:HasAnyFlags(PENDING) == true end)
    return not busy
end

local function asset(path, uuid)
    local m = util.find(path)
    if not m then ask_load(path, uuid); return nil end
    if not loaded(m) then return nil end
    return m
end

-- ---------------------------------------------------------------------------------------------------------------
-- the model

local function dress(car)
    local sk = asset(MESH, UUID_MESH)
    if not sk then stats.no_model = stats.no_model + 1; return false end
    local cls, pose, w = util.find(SMA), util.find(POSEABLE), game.world()
    if not (cls and pose and util.valid(w)) then return false end
    local m
    pcall(function() m = w:SpawnActor(cls, util.vec(car:K2_GetActorLocation()), { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if not util.valid(m) then return false end
    local d = { car = car, model = m, angle = { 0, 0, 0, 0 } }
    local ok, err = pcall(function()
        local root = m.StaticMeshComponent
        root:SetMobility(MOVABLE)
        root:SetCollisionEnabled(NO_COLLISION)
        local c = m:AddComponentByClass(pose, false, IDENTITY, false)
        if not pcall(function() c:SetSkinnedAssetAndUpdate(sk, true) end) then c:SetSkeletalMesh(sk, true) end
        c:SetCollisionEnabled(NO_COLLISION)
        d.comp, d.rest = c, {}
        for k, name in ipairs(BONES) do
            if c:GetBoneIndex(FName(name)) < 0 then error("the model has no bone " .. name) end
            local t = c:GetBoneTransformByName(FName(name), COMPONENT_SPACE)
            local q, l, s = t.Rotation, t.Translation, t.Scale3D
            d.rest[k] = { Rotation = { X = q.X, Y = q.Y, Z = q.Z, W = q.W }, Translation = { X = l.X, Y = l.Y, Z = l.Z },
                          Scale3D = { X = s.X, Y = s.Y, Z = s.Z } }
        end
        -- (its origin is on the ground between the motors, +X forward: as a vehicle mesh's)
        m:K2_AttachToComponent(car.Mesh, FName("None"), 0, 0, 0, false)
        root:K2_SetRelativeLocationAndRotation({ X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true)
        car.Mesh:SetHiddenInGame(true, false)
    end)
    if not ok then
        pcall(function() m:K2_DestroyActor() end)
        log.warn("hoverbike: couldn't put the model on " .. tostring(util.fname(car)) .. ": " .. tostring(err))
        return false
    end
    dressed[util.addr(car) or 0] = d
    stats.dressed = stats.dressed + 1
    log.info("hoverbike: dressed " .. tostring(util.fname(car)))
    return true
end

-- the quaternion q turned by a degrees about the up axis first (FPVDrone's body.spun)
local function spun(q, a)
    local h = math.rad(a) / 2
    local s, c = math.sin(h), math.cos(h)
    return { X = c * q.X - s * q.Y, Y = c * q.Y + s * q.X, Z = c * q.Z + s * q.W, W = c * q.W - s * q.Z }
end

local function spin(d, motors, dt)
    local c = d.comp
    if not (util.valid(c) and d.rest) then return end
    pcall(function()
        for k, name in ipairs(BONES) do
            local step = math.min(SPIN * math.sqrt(math.max(motors and motors[k] or PEER_SPIN, 0)) * dt, STEP_MAX)
            d.angle[k] = (d.angle[k] + flight.MOTORS[k][3] * step) % 360
            local r = d.rest[k]
            c:SetBoneTransformByName(FName(name), { Rotation = spun(r.Rotation, d.angle[k]), Translation = r.Translation,
                Scale3D = r.Scale3D }, COMPONENT_SPACE)
        end
    end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- the storage

-- What's in the trunk, read here and not with jig.contents_of (which reads an unreadable trunk as an empty one): how many
-- containers have the bike's size and how many items they all hold, nil if any of it couldn't be read.
local function read_trunk(comp)
    local grids, items, seen, n = 0, 0, 0, nil
    local ok = pcall(function()
        local arr = comp.MainJigContainers
        n = arr:GetArrayNum()
        util.each(arr, function(_, c)
            pcall(function()   -- (one that can't be read isn't counted as seen)
                local ct = c:get()
                if ct[J_COLS] == COLS and ct[J_ROWS] == ROWS then grids = grids + 1 end
                items = items + ct[J_ITEMS]:GetArrayNum()
                seen = seen + 1
            end)
        end)
    end)
    if not ok or seen ~= n then return nil end
    return grids, items
end

-- The grid goes in the trunk's settings on every copy of the bike, every world (they start as the cart's, a save keeps
-- only the containers: BP_VehicleMaster's ActorPreSave copies them to the actor and ActorLoaded puts them back), so
-- whatever builds it next builds 1000 slots. The trunk itself is built again only if it is readable, holds nothing and
-- isn't that size yet, or belongs to a bike just made here (what's in it is whatever the game's start-up gave a new
-- cart). Building adds to the containers there are, so they are cleared first: left there, the old grid stays hidden
-- behind the new one and items added by the mod go into it (Sentinel R2).
local function fit_grid(d)
    local comp
    pcall(function() comp = d.car.BP_JigMultiplayer end)
    if not util.valid(comp) then return end
    local arr, have_c, have_r, name = nil, nil, nil, nil
    pcall(function()
        arr = comp.ContainersSettings
        if arr:GetArrayNum() >= 1 then
            local e = arr[1]
            have_c, have_r, name = e[C_COLS], e[C_ROWS], e[C_NAME]
        end
    end)
    if not arr or (have_c == COLS and have_r == ROWS) then return end
    local ok, err = pcall(function()
        arr[1] = { [C_NAME] = name or FName("Trunk"), [C_EQUIP] = false, [C_COLS] = COLS, [C_ROWS] = ROWS }
    end)
    if not ok then log.warn("hoverbike: couldn't set the storage grid: " .. tostring(err)); return end
    stats.grid = stats.grid + 1
    local grids, items = read_trunk(comp)
    local addr = util.addr(d.car) or 0
    local fresh = made_here[addr] == true
    made_here[addr] = nil
    if not grids or (not fresh and (items > 0 or grids > 0)) then
        log.info(string.format("hoverbike: trunk of %s set to %dx%d, not rebuilt (%s)", tostring(util.fname(d.car)), COLS, ROWS,
            grids and string.format("%d items in it, %d grids that size", items, grids) or "couldn't read it"))
        return
    end
    local built, why = pcall(function()
        comp:ClearContainer(true)        -- (with ResetInitComponent: the game's build is a do-once)
        comp.InventoryWeight:Empty()     -- (ClearContainer leaves it, the build adds a row)
        comp:InitNoStartingItems()
    end)
    log.info(string.format("hoverbike: trunk of %s built %dx%d: %s", tostring(util.fname(d.car)), COLS, ROWS,
        built and "ok" or tostring(why)))
end

-- ---------------------------------------------------------------------------------------------------------------
-- the rider

-- By the world, not relative to the parent: how the game attaches a seated player (which socket) isn't known, and an
-- attached actor put at a world place keeps that place as the parent moves.
local function over_bike(p, l, u)
    return (p.X - l.X) * u.X + (p.Y - l.Y) * u.Y + (p.Z - l.Z) * u.Z
end

-- r.lift towards the Pelvis being at HIP_Z over the bike. The log line is what shows why it was off: the capsule where it
-- was left 0.2 s ago, against where it was put, tells whether something moved it; the mesh offset and the movement mode
-- whether the game changed them; the montage whether the rider's animation is what's playing.
local function fit_hips(r, a, l, u, root_z)
    if not (r.playing and r.since) or os.clock() < r.since + HIP_SETTLE_S then return end
    local hips, was
    if not pcall(function()
        hips = over_bike(a.Mesh:GetSocketLocation(FName(HIP_BONE)), l, u)
        was = over_bike(a:K2_GetActorLocation(), l, u)
    end) then return end
    local miss = HIP_Z + seat_tune - hips
    r.lift = r.lift or 0
    if r.logged == nil or math.abs(r.lift - r.logged) >= HIP_LOG then
        local mode = "?"
        pcall(function() mode = tostring(a.CharacterMovement.MovementMode) end)
        log.info(string.format("hoverbike: the rider's hips %.1f cm over the bike, wanted %.1f: lifted %.1f, tuned %d "
            .. "(capsule %.1f, put at %.1f; mesh z %.1f; movement mode %s; playing %s)", hips, HIP_Z + seat_tune, r.lift,
            seat_tune, was, SEAT_Z - root_z + r.lift, root_z, mode, tostring(r.anim):match("[^.]+$")))
        r.logged = r.lift
    end
    if math.abs(miss) > HIP_DEAD then
        local gain = math.abs(miss) <= 2 * HIP_DEAD and 1 or HIP_GAIN   -- (the last step lands on it, not just inside HIP_DEAD)
        r.lift = math.max(math.min(r.lift + miss * gain, HIP_MAX + seat_tune), seat_tune - HIP_MAX)
    end
end

-- r: the rider's state, what rider_anim keeps. fit: whether the Pelvis can be read (a hidden rider's pose stops being
-- worked out by the game).
local function seat_rider(a, car, r, fit)
    local root_z = -82
    pcall(function() root_z = a.Mesh.RelativeLocation.Z end)
    pcall(function()
        local l, f, u = car:K2_GetActorLocation(), car:GetActorForwardVector(), car:GetActorUpVector()
        if fit then fit_hips(r, a, l, u, root_z) end
        local up = SEAT_Z - root_z + (r.lift or 0)
        a:K2_SetActorLocationAndRotation({ X = l.X + f.X * SEAT_X + u.X * up, Y = l.Y + f.Y * SEAT_X + u.Y * up,
            Z = l.Z + f.Z * SEAT_X + u.Z * up }, car:K2_GetActorRotation(), false, {}, true)
    end)
end

-- r: { actor, anim (the path playing), m (its montage), check }; the slot is looked at now and then and one that holds
-- something else is played again, as glider.lua's hold
local function rider_anim(r, path, uuid, dt)
    r.check = (r.check or 0) - dt
    if r.anim == path and r.check > 0 then return end
    r.check = ANIM_CHECK_S
    local cur
    r.playing = r.anim == path and pcall(function() cur = r.actor:GetCurrentMontage() end) and util.same(cur, r.m)
    if r.playing then return end
    local seq = asset(path, uuid)
    if not seq then return end
    pcall(function()
        r.m = r.actor.Mesh:GetAnimInstance():PlaySlotAnimationAsDynamicMontage(seq, FName("DefaultSlot"), BLEND_S, BLEND_S,
            1.0, 100000, -1.0, 0.0)
    end)
    r.anim = path
    r.since = os.clock()
end

local function rider_off(r)
    if not (r and util.valid(r.actor)) then return end
    if util.valid(r.m) then pcall(function() r.actor.Mesh:GetAnimInstance():Montage_Stop(BLEND_S, r.m) end) end
    -- (seated it leaned with the bike; nothing else stands a character back up)
    pcall(function()
        local yaw = r.actor:K2_GetActorRotation().Yaw
        r.actor:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, true)
    end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- flying

-- The keys as the flight engine's sticks. keys: { fwd, back, left, right, up, down, boost } (true/false). Angle mode: the
-- sticks ask for a tilt and it levels itself. The throttle holds the climb the keys ask for (none: it holds its height).
function hoverbike.command(st, keys, landed)
    local turn = (keys.right and 1 or 0) - (keys.left and 1 or 0)
    local fore = keys.fwd and (keys.boost and 1 or CRUISE_STICK) or 0
    local back = keys.back and BACK_STICK or 0
    if landed and not keys.up then
        return { thr = 0, roll = 0, pitch = 0, yaw = 0, armed = true, mode = "angle" }
    end
    local want = keys.up and CLIMB or (keys.down and -SINK or 0)
    local g = P.gravity
    local up = math.max(st.u[3], 0.5)
    -- thrust along its top that gives the wanted climb, tilted as it is, the props' thrust fading with air through them
    local need = (g + HOLD_GAIN * (want - st.vel[3])) / up
    local vu = st.vel[1] * st.u[1] + st.vel[2] * st.u[2] + st.vel[3] * st.u[3]
    local fade = math.max(1 - vu / P.v_pitch, 0.2)
    local share = need / (P.twr * g * fade)
    local thr = ((math.max(math.min(share, 1), P.idle) - P.idle) / (1 - P.idle)) ^ (1 / P.thr_expo)
    -- how it moves over the ground, along its nose and to its right
    local fx, fy = st.f[1], st.f[2]
    local fl = math.sqrt(fx * fx + fy * fy)
    if fl < 1e-3 then fx, fy, fl = 1, 0, 1 end
    fx, fy = fx / fl, fy / fl
    local along = st.vel[1] * fx + st.vel[2] * fy
    local side = st.vel[2] * fx - st.vel[1] * fy
    local function lean(v) return math.max(math.min(-BRAKE * v, BRAKE_MAX), -BRAKE_MAX) end
    local pitch = (fore - back ~= 0) and (fore - back) or lean(along)
    -- (the faster it goes the wider it turns: at speed a full-rate turn only scrubs the speed off)
    local yaw = turn / (1 + math.abs(along) / TURN_EASE)
    return { thr = thr, roll = turn * BANK_STICK + lean(side), pitch = pitch, yaw = yaw, armed = true, mode = "angle" }
end

local function keys_now()
    local d = game.key_down
    return { fwd = d("W"), back = d("S"), left = d("A"), right = d("D"), up = d("SpaceBar"), down = d("LeftControl"),
             boost = d("LeftShift") }
end

-- ---------------------------------------------------------------------------------------------------------------
-- the remote

-- FPVDrone's folder, next to this mod's: its rc.lua and config.lua are used as they are, so rc.txt's layout (the helper
-- writes it) and the sticks' calibration stay the drone's. No FPVDrone there: no remote, the keys fly it.
local function fpv_dir()
    local src = debug.getinfo(1, "S").source or ""
    local mods = src:gsub("^@", ""):gsub("\\", "/"):match("^(.*/)[^/]+/Scripts/mirror/[^/]*$")
    return (mods or "ue4ss/Mods/") .. "FPVDrone/"
end

-- for one flight: arming starts over, as on the quad. nil: no FPVDrone.
local function radio_open()
    local dir = fpv_dir()
    if not package.path:find(dir, 1, true) then package.path = package.path .. ";" .. dir .. "Scripts/?.lua" end
    local ok, rc = pcall(require, "fpv.rc")
    local ok2, config = pcall(require, "fpv.config")
    if not (ok and ok2) then
        log.info("hoverbike: no remote, FPVDrone's scripts aren't at " .. dir)
        return nil
    end
    local text = nil
    local f = io.open(dir .. "FPVDrone.ini", "r")
    if f then text = f:read("a"); f:close() end
    local cfg = config.parse(text)
    rc.DEADBAND = cfg.deadband
    return { rc = rc, map = cfg.map, st = rc.new(), armed = false, file = dir .. "rc.txt", look_at = 0, hold_at = 0, quad_at = 0 }
end

local function share(k, v) pcall(function() ModRef:SetSharedVariable(k, v) end) end

-- The quad out (Ctrl+Shift+D on the bike): its pose changing. The remote is the quad's then, and has to arm again after.
local function quad_out(R, now)
    if now < R.quad_at then return R.quad end
    R.quad_at = now + QUAD_LOOK_S
    local v = nil
    pcall(function() v = ModRef:GetSharedVariable(POSE) end)
    local out = type(v) == "string" and v ~= "" and v ~= R.pose
    R.pose = v
    if out and not R.quad then
        R.st, R.told, R.armed = R.rc.new(), nil, false
        share(HOLD, "")
    end
    R.quad = out
    return out
end

-- the remote's command while it's armed, otherwise nil (the keys have it)
local function radio_cmd(R, now)
    if not R or quad_out(R, now) then return nil end
    -- (the quad's launch switch may be this mode switch: FPVDrone leaves it alone while this runs)
    if now >= R.hold_at then
        R.hold_at = now + RADIO_LOOK_S
        share(HOLD, string.format("until %.3f", now + HOLD_S))
    end
    if now < R.look_at then return nil end
    local reading, why = nil, "missing"
    local f = io.open(R.file, "rb")
    if f then
        reading, why = R.rc.parse(f:read(R.rc.LINE_LENGTH))
        f:close()
    elseif not R.st.armed then
        R.look_at = now + RADIO_LOOK_S   -- (armed: the helper may have it open for a moment, the failsafe decides)
    end
    local cmd = R.rc.command(R.st, reading, why, now, R.map)
    if cmd.armed ~= R.armed then
        R.armed = cmd.armed
        notify.show(cmd.armed and "Remote armed: the sticks fly it." or "Remote not armed: the keys have it, holding its height.",
            "info", "hoverbike")
    elseif R.st.status == "disarmed" and not R.told then
        notify.show("Remote found: flick arm with the throttle down to fly with it.", "info", "hoverbike")
    end
    if R.st.status == "disarmed" or cmd.armed then R.told = true end
    return cmd.armed and cmd or nil
end

-- ---------------------------------------------------------------------------------------------------------------

local function trace(p, a, b)
    local K = util.cdo(KSL)
    if not K then return false end
    local hit, out, n, at = false, {}, nil, nil
    pcall(function()
        hit = K:LineTraceSingle(p, a, b, 0, false, {}, 0, out, true, { R = 1, G = 0, B = 0, A = 1 },
            { R = 0, G = 1, B = 0, A = 1 }, 0) == true
    end)
    if hit then
        pcall(function()
            local v = (out.OutHit or out).ImpactNormal
            if type(v.X) == "number" then n = { v.X, v.Y, v.Z } end
        end)
        pcall(function()
            local v = (out.OutHit or out).ImpactPoint
            if type(v.X) == "number" then at = { v.X, v.Y, v.Z } end
        end)
    end
    return hit, n, at
end

-- ---------------------------------------------------------------------------------------------------------------
-- the view

-- Where the camera behind the bike is this frame, as if nothing is in the way. v: { yaw, at, reach } kept between frames.
-- Returns the place and the rotation.
function hoverbike.chase(v, st, dt)
    local f, u = st.f, st.u
    local level = math.sqrt(f[1] * f[1] + f[2] * f[2])
    -- (on its back, or its nose straight up, its heading says nothing: a flip doesn't swing the camera round)
    if not v.yaw then v.yaw = math.deg(math.atan(f[2], f[1]))
    elseif level > CHASE_MIN_LEVEL and u[3] > CHASE_MIN_UP then
        local turn = (math.deg(math.atan(f[2], f[1])) - v.yaw + 180) % 360 - 180
        v.yaw = (v.yaw + turn * (1 - math.exp(-CHASE_TURN * dt)) + 180) % 360 - 180
    end
    local at, k = v.at, 1 - math.exp(-CHASE_KEEP * dt)
    if not at then at = { st.pos[1], st.pos[2], st.pos[3] }; v.at = at end
    for i = 1, 3 do at[i] = at[i] + (st.pos[i] - at[i]) * k end
    local dx, dy, dz = at[1] - st.pos[1], at[2] - st.pos[2], at[3] - st.pos[3]
    local behind = math.sqrt(dx * dx + dy * dy + dz * dz)
    if behind > CHASE_LAG then
        local s = CHASE_LAG / behind
        at[1], at[2], at[3] = st.pos[1] + dx * s, st.pos[2] + dy * s, st.pos[3] + dz * s
    end
    local y = math.rad(v.yaw)
    local place = { at[1] - math.cos(y) * CHASE_BACK, at[2] - math.sin(y) * CHASE_BACK, at[3] + CHASE_UP }
    return place, { Pitch = -math.deg(math.atan(CHASE_UP - CHASE_LOOK, CHASE_BACK)), Yaw = v.yaw, Roll = 0 }
end

-- On the bike: the spec's eye point along its own axes, the rotation FPVDrone's camera tilt gives.
function hoverbike.eye(st)
    local f, u, p = st.f, st.u, st.pos
    local place = { p[1] + f[1] * EYE_X + u[1] * EYE_Z, p[2] + f[2] * EYE_X + u[2] * EYE_Z, p[3] + f[3] * EYE_X + u[3] * EYE_Z }
    local pitch, yaw, roll = flight.camera(st, EYE_TILT)
    return place, { Pitch = pitch, Yaw = yaw, Roll = roll }
end

local function view_on(p, f)
    local cls, w, pc = util.find(CAMERA), game.world(), nil
    pcall(function() pc = p.Controller end)
    if not (cls and util.valid(w) and util.valid(pc)) then
        log.warn("hoverbike: no camera of its own (no class, world or controller yet)")
        return
    end
    local cam
    pcall(function()
        cam = w:SpawnActor(cls, { X = f.st.pos[1], Y = f.st.pos[2], Z = f.st.pos[3] }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not util.valid(cam) then log.warn("hoverbike: couldn't make its camera"); return end
    -- (a CameraActor is held to 16:9 by default: black bars in any other window, kit 2026-11-04)
    pcall(function() cam.CameraComponent.bConstrainAspectRatio = false end)
    pcall(function() pc:SetViewTargetWithBlend(cam, 0, 0, 0, false) end)
    f.cam, f.pc, f.view = cam, pc, {}
end

-- What's worn is its own actor on the rider, which hiding the rider leaves showing. With a Ghillie hood and goggles the eye
-- view was black and the screen blurred (kit 2026-11-04); with those two hidden, clear. Why they blur it isn't established.
-- Only what was showing is hidden and put back.
local function worn_hide(p, f)
    local out = {}
    pcall(function() p:GetAttachedActors(out, true, true) end)
    for _, h in ipairs(out) do
        local a, shown = nil, false
        pcall(function() a = h:get() end)
        if util.valid(a) then pcall(function() shown = a.bHidden == false end) end
        if shown then
            pcall(function() a:SetActorHiddenInGame(true) end)
            f.worn = f.worn or {}
            f.worn[#f.worn + 1] = a
        end
    end
end

local function worn_show(f)
    for _, a in ipairs(f.worn or {}) do
        if util.valid(a) then pcall(function() a:SetActorHiddenInGame(false) end) end
    end
    f.worn = nil
end

local function view_off(p, f)
    if not f.cam then return end
    worn_show(f)
    if util.valid(p) then
        pcall(function() p:SetActorHiddenInGame(false) end)
        if util.valid(f.pc) then pcall(function() f.pc:SetViewTargetWithBlend(p, 0, 0, 0, false) end) end
    end
    if util.valid(f.cam) then pcall(function() f.cam:K2_DestroyActor() end) end
    f.cam, f.pc = nil, nil
end

-- Now and then: the game or FPVDrone's quad coming back hands the view to the character, and it's taken back; the quad out
-- has it, and keeps it. The rider is hidden only while this camera, on the bike, is what's looked through.
local function view_keep(p, f)
    if not util.valid(f.cam) or not util.valid(f.pc) then return end
    local on
    pcall(function() on = f.pc:GetViewTarget() end)
    if util.same(on, p) then
        pcall(function() f.pc:SetViewTargetWithBlend(f.cam, 0, 0, 0, false) end)
        on = f.cam
    end
    local hide = view_eye and util.same(on, f.cam)
    if hide ~= f.hidden then
        f.hidden = hide
        pcall(function() p:SetActorHiddenInGame(hide) end)
        if not hide then worn_show(f) end
    end
    if hide then worn_hide(p, f) end   -- (each look: anything put on meanwhile too)
end

local function view_place(p, f, dt)
    local cam, st, v = f.cam, f.st, f.view
    if not util.valid(cam) then return end
    local at, rot, fov
    if view_eye then
        at, rot = hoverbike.eye(st)
        fov = EYE_FOV
    else
        at, rot = hoverbike.chase(v, st, dt)
        -- (from over the bike, back to the camera: a wall in between brings it in at once, and it eases back out)
        local from = { st.pos[1], st.pos[2], st.pos[3] + CHASE_LOOK }
        local dx, dy, dz = at[1] - from[1], at[2] - from[2], at[3] - from[3]
        local long = math.sqrt(dx * dx + dy * dy + dz * dz)
        local reach = math.min((v.reach or 1) + CHASE_OUT * dt, 1)
        local hit, _, point = trace(p, { X = from[1], Y = from[2], Z = from[3] }, { X = at[1], Y = at[2], Z = at[3] })
        if hit and point and long > 1 then
            local hx, hy, hz = point[1] - from[1], point[2] - from[2], point[3] - from[3]
            reach = math.min(reach, math.max(math.sqrt(hx * hx + hy * hy + hz * hz) - CHASE_PAD, 0) / long)
        end
        v.reach = reach
        at = { from[1] + dx * reach, from[2] + dy * reach, from[3] + dz * reach }
        fov = CHASE_FOV + (CHASE_FOV_FAST - CHASE_FOV) * math.min(flight.speed(st) / FAST, 1)
    end
    pcall(function()
        cam:K2_SetActorLocationAndRotation({ X = at[1], Y = at[2], Z = at[3] }, rot, false, {}, true)
    end)
    if not f.fov or math.abs(fov - f.fov) > 0.25 then
        f.fov = fov
        pcall(function() cam.CameraComponent:SetFieldOfView(fov) end)
    end
end

local function view_switch(p, f)
    view_eye = not view_eye
    stats.views = stats.views + 1
    view_keep(p, f)
    if not view_eye then f.view = {} end   -- (back behind it: straight behind, not where it was left)
    notify.show(view_eye and "View: on the bike." or "View: behind the bike.", "info", "hoverbike")
end

-- off a surface whose normal is n (or straight back, none known): what went into it mostly gone, the rest scrapes along
local function rebound(v, n)
    local speed = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
    n = n or (speed > 1e-6 and { -v[1] / speed, -v[2] / speed, -v[3] / speed })
    if not n then return end
    local vn = v[1] * n[1] + v[2] * n[2] + v[3] * n[3]
    if vn < 0 then
        for i = 1, 3 do v[i] = (v[i] - vn * n[i]) * SCRAPE - BOUNCE * vn * n[i] end
    end
end

-- the frame's move, from prev to st.pos, kept out of the world. Returns true if it came down on the ground.
function hoverbike.collide(p, st, prev)
    local dx, dy, dz = st.pos[1] - prev[1], st.pos[2] - prev[2], st.pos[3] - prev[3]
    -- down: the ground under its middle. Too steep to stand on, it slides off instead of going through.
    if dz < 0 then
        local hit, n = trace(p, { X = prev[1], Y = prev[2], Z = prev[3] + BODY_UP },
            { X = prev[1], Y = prev[2], Z = prev[3] + dz - PAD })
        if hit then
            st.pos[3] = prev[3]
            if not n or n[3] >= GROUND_UP then
                st.vel = { 0, 0, 0 }
                return true
            end
            rebound(st.vel, n)
        end
    elseif dz > 0 then
        local hit = trace(p, { X = prev[1], Y = prev[2], Z = prev[3] + TOP },
            { X = prev[1], Y = prev[2], Z = prev[3] + TOP + dz + PAD })
        if hit then
            st.pos[3] = prev[3]
            if st.vel[3] > 0 then st.vel[3] = 0 end
        end
    end
    -- along: the middle and the four sides of the body
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-3 then return false end
    local k = (len + PAD) / len
    for _, o in ipairs(PROBES) do
        local x = prev[1] + st.f[1] * o[1] + st.r[1] * o[2]
        local y = prev[2] + st.f[2] * o[1] + st.r[2] * o[2]
        local z = prev[3] + BODY_UP + st.f[3] * o[1] + st.r[3] * o[2]
        local hit, n = trace(p, { X = x, Y = y, Z = z }, { X = x + dx * k, Y = y + dy * k, Z = z })
        if hit then
            st.pos[1], st.pos[2] = prev[1], prev[2]
            rebound(st.vel, n)
            break
        end
    end
    return false
end

local function physics(car, on, vel)
    pcall(function() car:SetActorEnableCollision(on) end)
    pcall(function() car.Mesh:SetSimulatePhysics(on) end)
    if on then
        local v = vel or { 0, 0, 0 }
        pcall(function() car.Mesh:SetPhysicsLinearVelocity({ X = v[1], Y = v[2], Z = v[3] }, false, FName("None")) end)
        pcall(function() car.Mesh:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
    end
end

local function start(p, car)
    local l, r
    pcall(function() l = car:K2_GetActorLocation(); r = car:K2_GetActorRotation() end)
    if not (l and r) then return end
    local st = flight.new(l.X, l.Y, l.Z, r.Yaw, 4711)
    st.f, st.r, st.u = flight.axes(r.Pitch, r.Yaw, r.Roll)
    physics(car, false)
    local near = trace(p, { X = l.X, Y = l.Y, Z = l.Z + BODY_UP }, { X = l.X, Y = l.Y, Z = l.Z - LAND_LOOK })
    local fine, radio = pcall(radio_open)   -- (physics is off by now: nothing of FPVDrone's may stop this flight starting)
    if not fine then log.warn("hoverbike: no remote: " .. tostring(radio)); radio = nil end
    F = { car = car, st = st, landed = near, rider = { actor = p }, radio = radio }
    seat_rider(p, car, F.rider, false)
    view_on(p, F)
    view_keep(p, F)
    stats.flights = stats.flights + 1
    notify.show("Space lifts off. W S A D fly, Left Ctrl sinks, Left Shift for speed, G switches the view.", "info", "hoverbike")
    local yaw = "?"
    pcall(function() yaw = tostring(p.Mesh.RelativeRotation.Yaw) end)
    log.info(string.format("hoverbike: flying %s (%s; the rider's mesh yaw %s, the model wants -90)",
        tostring(util.fname(car)), near and "on the ground" or "in the air", yaw))
end

local function stop(why)
    if not F then return end
    local f = F
    F = nil
    view_off(f.rider.actor, f)
    rider_off(f.rider)
    if f.radio then share(HOLD, "") end
    if alive(f.car) then physics(f.car, true, f.st.vel) end
    log.info("hoverbike: flight over (" .. why .. ")")
end

-- ---------------------------------------------------------------------------------------------------------------
-- its sound

-- (mirror/bikenoise.lua plays it; here is what the motors are doing)

-- Another player's motors aren't sent: what's seen of the bike says how hard they work. Hovering it's PEER_SPIN, the
-- motors' share that holds it up, and speed or a climb on top of that.
function hoverbike.peer_share(speed, climb)
    local push = math.max(speed / PEER.FULL, climb / CLIMB, 0)
    return PEER_SPIN + PEER.PUSH * math.min(push, 1)
end

-- this frame's motors and speed of a bike in use
local function running(d, motors, speed, dt)
    d.running = true
    d.speed = speed
    local m = d.motors or {}
    d.motors = m
    for k = 1, 4 do m[k] = motors[k] or 0 end
    noise.hear(d, dt, asset)
end

-- nobody on it any more: the props and the sound run down together, then every loop stops
local function run_down(d, dt)
    d.was = nil
    local k, top = math.exp(-dt / PEER.RUN_DOWN_TAU), 0
    for i = 1, 4 do
        d.motors[i] = d.motors[i] * k
        top = math.max(top, d.motors[i])
    end
    d.speed = d.speed * k
    spin(d, d.motors, dt)
    noise.hear(d, dt, asset)
    if top < PEER.RUN_DOWN_END then
        d.running = false
        noise.quiet(d)
    end
end

-- a bike someone else flies here, its motors worked out from how it moves
local function theirs(p, d, dt)
    local l
    pcall(function() l = d.car:K2_GetActorLocation() end)
    if not (l and dt > 0) then return end
    local was = d.was
    d.was = { X = l.X, Y = l.Y, Z = l.Z }
    local k = 1 - math.exp(-dt / PEER.TAU)
    if was then
        local vz = (l.Z - was.Z) / dt
        local v = math.sqrt((l.X - was.X) ^ 2 + (l.Y - was.Y) ^ 2 + (l.Z - was.Z) ^ 2) / dt
        if v < PEER.JUMP then   -- (a faster move is a teleport, or a stale position caught up)
            d.peer_speed = (d.peer_speed or 0) + (v - (d.peer_speed or 0)) * k
            d.peer_climb = (d.peer_climb or 0) + (vz - (d.peer_climb or 0)) * k
        end
    end
    local speed, climb = d.peer_speed or 0, d.peer_climb or 0
    d.peer_look = (d.peer_look or 0) - dt
    if d.peer_look <= 0 then
        d.peer_look = PEER.LOOK_S
        d.peer_parked = speed < PEER.STILL and trace(p, { X = l.X, Y = l.Y, Z = l.Z + BODY_UP }, { X = l.X, Y = l.Y, Z = l.Z - LAND_LOOK })
    end
    local want = d.peer_parked and P.idle or hoverbike.peer_share(speed, climb)
    d.peer_share = (d.peer_share or want) + (want - (d.peer_share or want)) * k
    local m = d.peer_motors or {}
    d.peer_motors = m
    for i = 1, 4 do m[i] = d.peer_share end
    spin(d, m, dt)
    running(d, m, speed, dt)
end

-- down on its back: rolled upright about its nose (flight.settle would leave it lying there), then settle has it
local function right_itself(st, dt)
    local a = math.rad(RIGHT_RATE) * dt
    local c, s = math.cos(a), math.sin(a)
    local u, r = st.u, st.r
    st.u = { u[1] * c + r[1] * s, u[2] * c + r[2] * s, u[3] * c + r[3] * s }
    st.r = { r[1] * c - u[1] * s, r[2] * c - u[2] * s, r[3] * c - u[3] * s }
    st.rate = { 0, 0, 0 }
end

local function fly(p, dt)
    local st, car = F.st, F.car
    dt = math.min(dt, MAX_DT)
    if dt <= 0 then return end
    local keys = F.coming_down and COME_DOWN or keys_now()
    local radio = not F.coming_down and radio_cmd(F.radio, os.clock()) or nil
    local lift = keys.up
    if radio then lift = radio.thr > RADIO_LIFT end
    if F.landed and lift then F.landed = false end
    local cmd = radio
    if not radio then cmd = hoverbike.command(st, keys, F.landed)
    elseif F.landed then cmd = { thr = 0, roll = 0, pitch = 0, yaw = 0, armed = true, mode = radio.mode } end
    local prev = { st.pos[1], st.pos[2], st.pos[3] }
    flight.step(st, cmd, dt, P)
    if F.landed then
        st.pos, st.vel = prev, { 0, 0, 0 }
        if st.u[3] < 0 then right_itself(st, dt) else flight.settle(st, dt, P) end
    elseif hoverbike.collide(p, st, prev) and not lift then   -- (lifting off: the motors are still spooling up)
        F.landed = true
        stats.landed = stats.landed + 1
    end
    local pitch, yaw, roll = flight.rotator(st.f, st.r, st.u)
    pcall(function()
        car:K2_SetActorLocationAndRotation({ X = st.pos[1], Y = st.pos[2], Z = st.pos[3] },
            { Pitch = pitch, Yaw = yaw, Roll = roll }, false, {}, true)
    end)
    -- (a body with no simulation has no speed of its own: vehicles.lua's driver line reads this one)
    pcall(function() car.Mesh.ComponentVelocity = { X = st.vel[1], Y = st.vel[2], Z = st.vel[3] } end)
    if F.landed then rider_anim(F.rider, ANIM_SIT, UUID_SIT, dt) else rider_anim(F.rider, ANIM_DRIVE, UUID_DRIVE, dt) end
    local d = dressed[util.addr(car) or 0]
    if d then
        spin(d, st.motors, dt)
        local v = st.vel
        running(d, st.motors, math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]), dt)
    end
    view_place(p, F, dt)
end

-- ---------------------------------------------------------------------------------------------------------------
-- on it, or not

local function check_seat(p)
    local car
    pcall(function() car = p:GetAttachParentActor() end)
    local on = alive(car) and dressed[util.addr(car) or 0] and car or nil
    if F and not util.same(F.car, on) then stop("got off") end
    -- (the model has one seat: someone riding along stays where the game seats them, and doesn't fly it)
    local v = package.loaded["mirror.vehicles"]
    local along = false
    if on and v then
        pcall(function() along = v.my_ride() ~= nil or v.peer_drives(on) == true end)
    end
    local mine = may_ride()
    -- (locked in the air: the keys and the remote stop counting, it sinks to the ground, then the rider's put off)
    if F and not mine and not F.coming_down then
        F.coming_down, F.down_for = true, 0
        notify.show("The hover bike was locked: it's bringing you down.", "info", "hoverbike")
    elseif F and mine and F.coming_down then
        F.coming_down = nil
        notify.show("The hover bike is yours to fly again.", "info", "hoverbike")
    end
    if F and F.coming_down then
        F.down_for = F.down_for + SEAT_S
        if F.landed or F.down_for >= DOWN_MAX_S then stop("locked") end
    end
    if on and not along and not mine and not F then
        if not util.same(seated_car, on) then
            stats.told = stats.told + 1
            put_off_in = 0
            notify.show("The hover bike is locked: only its owner can ride it.", "info", "hoverbike")
        end
        seated_car = on
        put_off(p, on)
        return
    end
    seated_car = on
    if on and not along and not F then start(p, on) end
    if F then
        view_keep(p, F)
        seat_rider(p, F.car, F.rider, not F.hidden)   -- (kept there: the game's seat may put it back)
    end
end

-- the other player flying a bike here: their ghost sits on the seat with the rider's animation
local function check_ghost(dt)
    local g
    pcall(function() g = require("mirror.ghost").get() end)
    local car
    if util.valid(g) then pcall(function() car = g:GetAttachParentActor() end) end
    local on = alive(car) and dressed[util.addr(car) or 0] and car or nil
    local v = package.loaded["mirror.vehicles"]
    if on and v then
        local drives = false
        pcall(function() drives = v.peer_drives(on) == true end)
        if not drives then on = nil end   -- (riding along: where the game's seats put them)
    end
    if not on then
        if them then rider_off(them); them = nil end
        return
    end
    if not (them and util.same(them.actor, g) and util.same(them.car, on)) then
        them = { actor = g, car = on }
    end
    seat_rider(g, on, them, true)
    rider_anim(them, ANIM_DRIVE, UUID_DRIVE, dt)
end

-- U / I: the seat's height by eye, for now (the log has the number, to go in HIP_Z for good)
local function apply_tune()
    local r = F and F.rider
    if r then
        seat_tune = seat_tune + want_tune * TUNE_STEP
        r.lift = (r.lift or 0) + want_tune * TUNE_STEP
        r.since = os.clock()
        log.info(string.format("hoverbike: seat height tuned %+d cm by hand", seat_tune))
        notify.show(string.format("Seat height %+d cm", seat_tune), "info", "hoverbike")
    end
    want_tune = 0
end

-- ---------------------------------------------------------------------------------------------------------------
-- making it

local function near_player()
    local p, l, yaw = game.player(), nil, nil
    pcall(function() l = util.vec(p:K2_GetActorLocation()); yaw = p:K2_GetActorRotation().Yaw end)
    if not (l and yaw) then return nil end
    local r = math.rad(yaw)
    return { X = l.X + math.cos(r) * SPAWN_AHEAD_CM, Y = l.Y + math.sin(r) * SPAWN_AHEAD_CM, Z = l.Z + SPAWN_UP_CM }, yaw
end

-- "made", "brought", nil while the cart's class loads, or why not
local function make_or_bring()
    if is_guest() then return "guest" end
    if F then return "flying" end   -- (it's under you, and the flight would put it straight back)
    local at, yaw = near_player()
    if not at then return "no player" end
    local function bring(car)
        pcall(function()
            car:K2_SetActorLocationAndRotation(at, { Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
            car.Mesh:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None"))
        end)
        stats.brought = stats.brought + 1
        return "brought"
    end
    for _, d in pairs(dressed) do
        if alive(d.car) then return bring(d.car) end
    end
    -- (a saved bike isn't dressed for a moment after a load: pressed then, the key made a second one, kit 2026-11-04)
    for _, car in ipairs(util.instances("Vehicle_GolfCart_C", MASTER, GROUP)) do
        if alive(car) and is_bike(car) then return bring(car) end
    end
    local cls, w = util.find(CART), game.world()
    if not util.valid(w) then return "no world" end
    if not cls then ask_load(CART, UUID_CART); return nil end
    local car
    pcall(function() car = w:SpawnActor(cls, at, { Pitch = 0, Yaw = yaw, Roll = 0 }) end)
    if not util.valid(car) then return "spawn failed" end
    pcall(function() car.VehicleColor = MARK end)
    keep(car)
    made_here[util.addr(car) or 0] = true
    stats.made = stats.made + 1
    log.info(string.format("hoverbike: made a bike (%s) at %.0f %.0f %.0f", tostring(util.fname(car)), at.X, at.Y, at.Z))
    return "made"
end

local function do_make()
    local r = make_or_bring()
    if r == nil then
        if os.clock() - (make_at or 0) > MAKE_WAIT_S then
            want_make = false
            log.warn("hoverbike: the golf cart class didn't load - no bike made")
        end
        return
    end
    want_make = false
    if r == "guest" then notify.show("The bike is made in the host's world: only the host's game can make it.", "info", "hoverbike")
    elseif r == "made" then notify.show("Hover bike ready. Get on it like a car.", "info", "hoverbike")
    elseif r == "brought" then notify.show("Your hover bike came to you.", "info", "hoverbike")
    elseif r == "flying" then notify.show("You're already on your hover bike.", "info", "hoverbike")
    else log.warn("hoverbike: no bike: " .. tostring(r)) end
end

-- ---------------------------------------------------------------------------------------------------------------

local function check()
    for k, d in pairs(dressed) do
        if not alive(d.car) or not is_bike(d.car) then
            if util.valid(d.model) then pcall(function() d.model:K2_DestroyActor() end) end
            if alive(d.car) then unkeep(d.car) end
            dressed[k] = nil
        elseif util.valid(d.model) then
            keep(d.car)
            fit_grid(d)
            local hidden = false
            pcall(function() hidden = d.car.bHidden == true end)
            pcall(function() d.model:SetActorHiddenInGame(hidden) end)
        else
            dressed[k] = nil   -- (dressed again below)
        end
    end
    for _, car in ipairs(util.instances("Vehicle_GolfCart_C", MASTER, GROUP)) do
        -- (a cart saved as one of the removed trailers, user 2026-11-03: "delete the trailers from the mod": a golf cart
        -- again, whatever is in its trunk still in it)
        local c
        pcall(function() c = car.VehicleColor end)
        if alive(car) and tonumber(c) == OLD_TRAILER then
            unkeep(car)
            pcall(function() car.VehicleColor = 0 end)
            log.info("hoverbike: a saved trailer is a golf cart again: " .. tostring(util.fname(car)))
        end
        if alive(car) and not dressed[util.addr(car) or 0] and is_bike(car) and dress(car) then
            keep(car)
            fit_grid(dressed[util.addr(car) or 0])
        end
    end
end

local function tick(dt)
    local w, p = game.world(), game.player()
    if not (util.valid(w) and util.valid(p)) then return end
    -- another world: its actors are gone, keep no reference to them (L-024)
    local wa = util.addr(w)
    if wa ~= world_at then
        world_at, dressed, F, them, seated_car, want_make = wa, {}, nil, nil, nil, false
        made_here = {}
        noise.reset()
    end
    if want_make then do_make() end
    if want_view then
        want_view = false
        if F then view_switch(p, F) end
    end
    if want_tune ~= 0 then apply_tune() end
    if want_lock then
        want_lock = false
        local to = want_open
        want_open = nil
        if is_owner() then
            if to == nil then to = not open_mine end
            open_mine = to
            share_in = LOCK_SHARE_S
            share_lock()
            log.info("hoverbike: " .. (open_mine and "unlocked" or "locked") .. " for everyone")
            notify.show(open_mine and "Hover bike unlocked for everyone. Ctrl+Shift+P locks it." or "Hover bike locked: only you can ride it.",
                "info", "hoverbike")
        else
            notify.show("Only the hover bike's owner can unlock it.", "info", "hoverbike")
        end
    end
    check_in = check_in - dt
    if check_in <= 0 then
        check_in = CHECK_S
        check()
        if is_owner() then
            share_in = share_in - CHECK_S
            if share_in <= 0 then share_in = LOCK_SHARE_S; share_lock() end
        else
            read_lock()
        end
    end
    seat_in = seat_in - dt
    if seat_in <= 0 then
        seat_in = SEAT_S
        check_seat(p)
        check_ghost(SEAT_S)
    end
    if F then
        if alive(F.car) then fly(p, dt) else stop("the bike is gone") end
    end
    -- the bikes not flown from here: someone else's turning and heard, an empty one's motors running down
    if next(dressed) then
        local v = package.loaded["mirror.vehicles"]
        for _, d in pairs(dressed) do
            if not (F and util.same(F.car, d.car)) then
                local yes = false
                if v and v.peer_drives then pcall(function() yes = v.peer_drives(d.car) == true end) end
                if yes then theirs(p, d, dt) elseif d.running then run_down(d, dt) end
            end
        end
    end
end

function hoverbike.make() want_make, make_at = true, os.clock() end

function hoverbike.status()
    local n = 0
    for _ in pairs(dressed) do n = n + 1 end
    return string.format("bikes %d%s (%s, dressed %d, made %d, brought %d, flights %d, landed %d, grids %d, no model %d)", n,
        F and ", FLYING" or "", (open_mine or open_seen) and "open to all" or "locked", stats.dressed, stats.made, stats.brought, stats.flights, stats.landed, stats.grid, stats.no_model)
end

-- what the keys do, and the chat commands too (chatcmd.lua)
function hoverbike.riding() return F ~= nil end
function hoverbike.key_make() if is_owner() then hoverbike.make() end end
function hoverbike.key_lock() want_lock, want_open = true, nil end
function hoverbike.set_open(open) want_lock, want_open = true, open end
function hoverbike.key_view() if F then want_view = true end end
function hoverbike.key_tune(d) if F then want_tune = want_tune + d end end

-- (the plain letters reach their keybinds while they're typed into the quick chat too)
local function typed_key(fn)
    return function()
        local typing = false
        pcall(function() typing = require("mirror.quickchat").is_open() == true end)
        if not typing then fn() end
    end
end

function hoverbike.init(cfg)
    if cfg and cfg.hoverbike == false then return end
    game.on_tick(function(dt) util.safe(tick, "hoverbike.tick", dt) end)
    game.keybind("V", { ModifierKey.CONTROL, ModifierKey.SHIFT }, hoverbike.key_make)
    -- (keys the game's IMC_General doesn't bind; off the bike these do nothing)
    game.keybind("P", { ModifierKey.CONTROL, ModifierKey.SHIFT }, hoverbike.key_lock)
    game.keybind("G", nil, typed_key(hoverbike.key_view))
    game.keybind("U", nil, typed_key(function() hoverbike.key_tune(1) end))
    game.keybind("I", nil, typed_key(function() hoverbike.key_tune(-1) end))
    log.info("hoverbike: ready")
end

hoverbike._make_now = do_make
hoverbike._open = function() return open_mine, open_seen end
hoverbike._owner_peer = function(id) owner_peer = id and tostring(id) or nil end
hoverbike._flight = function() return F end
hoverbike._dressed = function() return dressed end
hoverbike._stats = stats
hoverbike._consts = { COLS = COLS, ROWS = ROWS, SEAT_X = SEAT_X, SEAT_Z = SEAT_Z, CLIMB = CLIMB, SINK = SINK, STEP_MAX = STEP_MAX,
                      SPIN = SPIN, C_COLS = C_COLS, C_ROWS = C_ROWS, C_NAME = C_NAME, ANIM_SIT = ANIM_SIT, ANIM_DRIVE = ANIM_DRIVE,
                      HIP_Z = HIP_Z, HIP_MAX = HIP_MAX, HIP_DEAD = HIP_DEAD, TUNE_STEP = TUNE_STEP, CHASE_BACK = CHASE_BACK,
                      CHASE_UP = CHASE_UP, CHASE_LOOK = CHASE_LOOK, CHASE_LAG = CHASE_LAG, CHASE_PAD = CHASE_PAD,
                      CHASE_FOV = CHASE_FOV, CHASE_FOV_FAST = CHASE_FOV_FAST, EYE_FOV = EYE_FOV, EYE_X = EYE_X, EYE_Z = EYE_Z }
hoverbike._view_eye = function() return view_eye end
-- The rider and what they wear are hidden for this game's own view: their look isn't read meanwhile (phase1), or the others
-- would see them lose it.
function hoverbike.rider_out_of_sight() return F ~= nil and F.hidden == true end

return hoverbike
