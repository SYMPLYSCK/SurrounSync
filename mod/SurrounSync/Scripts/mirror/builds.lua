-- Placing, moving and picking up buildings, on both screens.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local events = require("mirror.events")
local bedtags = require("mirror.bedtags")
local doorlock = require("mirror.doorlock")

local builds = {}

local BC = "/Game/Blueprints/Components/BuildingComponent.BuildingComponent_C"
local BM = "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C"
-- The auto turret's pick-up (OnInteractBuildable) drops its item and destroys itself without Svr_Spawn/MC_Destroy.
local TURRET = "/Game/Blueprints/BuildingSystem/Actors/Turret/Buildable_Turret.Buildable_Turret_C"
-- A land mine goes off by itself (Event_Explode: effects, radial damage, K2_DestroyActor) - none of the hooks
-- above see it. Its place is read at BeginPlay: once destroyed it reads 0,0,0.
local MINE = "/Game/Blueprints/BuildingSystem/Actors/Traps/Buildable_LandMine.Buildable_LandMine_C"
-- A horde beacon K2_DestroyActor's itself right after its final-wave SpawnRewards (no MC_Destroy).
local BEACON = "/Game/Blueprints/HordeSystem/Beacon/Buildable_HordeBeacon.Buildable_HordeBeacon_C"
-- A storage container's name (the game's Rename: BuildableRenameObject Confirm -> OverrideBuildName, which sets its
-- ContainerName, a SaveGame text shown on its hover and its inventory panel). The other game sets the same
-- ContainerName on its copy; the host's save keeps it, and a joining guest gets it in that save.
local CONTAINER = "/Game/Blueprints/BuildingSystem/Actors/Containers/BuildableMaster_Container.BuildableMaster_Container_C"
local MAX_NAME = 64
local BOOM_FX = "/Game/PolygonFiles/PolygonMilitary/FX/FX_Explosion_New.FX_Explosion_New"
local BOOM_CUE = "/Game/Audio/WARFARE_SOUNDS/Explosion_Fire_Gas/Cues/explosion_large_06_Cue.explosion_large_06_Cue"

local cfg, role, session
local channel = events.reliable("builds")
local peers = require("mirror.peers")
local hook_in = 0.0
local hooked_logged = nil
local last_moving_id = nil
local last_moving = nil
local move_from = nil   -- { actor, id }: the piece the game's Move option (Buildable_MASTER ReplacingObject) last picked up
local last_obj = nil
local last_da = nil
local applying = false
local expect_gone, EXPECT_GONE_S = {}, 2.0
local stats = { placed = 0, moved = 0, removed = 0, renamed = 0, made = 0, applied_moves = 0, applied_removes = 0,
                applied_renames = 0, missing = 0 }

local function shared() return role == "host" or (session and session.in_world()) end
local function traded() if session and session.checkpoint and shared() then session.checkpoint("builds") end end
channel.send = function(self, p) if true then traded() end return events.send(self, p) end

local function full_path(obj)
    local p
    pcall(function() p = obj:GetFullName():match("^%S+ (.+)$") end)
    return p
end

local function grid(l) return math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5), math.floor(l.Z / 10 + 0.5) end

local function id_of(actor)
    local cls = util.class_name(actor)
    local l = actor:K2_GetActorLocation()
    local x, y, z = grid(l)
    return string.format("%s@%d,%d,%d", cls, x, y, z)
end

local function rotator(q)
    local x, y, z, w = q.X, q.Y, q.Z, q.W
    local sing = z * x - w * y
    local yy, yx = 2 * (w * z + x * y), 1 - 2 * (y * y + z * z)
    local deg = 180 / math.pi
    local yaw = math.atan(yy, yx) * deg
    local pitch, roll
    if sing < -0.4999995 then
        pitch = -90
        roll = (-yaw - 2 * math.atan(x, w) * deg)
    elseif sing > 0.4999995 then
        pitch = 90
        roll = (yaw - 2 * math.atan(x, w) * deg)
    else
        pitch = math.asin(2 * sing) * deg
        roll = math.atan(-2 * (w * x + y * z), 1 - 2 * (x * x + y * y)) * deg
    end
    roll = (roll + 180) % 360 - 180
    return { Pitch = pitch, Yaw = yaw, Roll = roll }
end

local function is_ours(comp)
    local owner
    pcall(function() owner = comp:GetOwner() end)
    return util.same(owner, game.player())
end

local function on_spawn_build(self, SpawnTransform)
    if applying or not shared() then return end
    local comp = self:get()
    if not is_ours(comp) then return end
    local t
    pcall(function() t = SpawnTransform:get() end)
    if not t then return end
    local l, r, s = t.Translation, rotator(t.Rotation), t.Scale3D
    local replacing, actor = false, nil
    pcall(function() replacing = comp["ReplacingObject?"] == true end)
    pcall(function() actor = comp.ReplacingActor end)
    local moving_id = last_moving_id
    if not replacing and last_moving and util.valid(last_moving) then replacing, actor = true, last_moving end
    -- The hook runs after SpawnBuild, whose StopBuildMode has cleared ReplacingObject? and ReplacingActor: a move is
    -- known from the tick's sample above, or from the game's Move option (ReplacingObject, move_from) when the
    -- piece now stands on the spot just built. Missed, the move went out as a new place: the other game built a
    -- second piece there and kept its own where it was (user 2026-11-03: duplicate containers, moves not shown).
    local from = move_from
    move_from = nil
    if not replacing and from and util.valid(from.actor) then
        local at
        pcall(function() at = util.vec(from.actor:K2_GetActorLocation()) end)
        if at and util.dist(at, l) < 1.0 then
            replacing, actor, moving_id = true, from.actor, from.id
            log.info("builds: the move was seen by the Move option, not the build mode")
        end
    end
    last_moving, last_moving_id = nil, nil
    if replacing then
        if util.valid(actor) then
            local ok, id = true, moving_id
            if not id then ok, id = pcall(id_of, actor) end
            if ok then
                channel:send(string.format("M %s %.1f %.1f %.1f %.2f %.2f %.2f", id, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll))
                util.safe(function() doorlock.moved(doorlock.loc_of_id(id), { X = l.X, Y = l.Y, Z = l.Z }) end, "builds.doorlock")
                stats.moved = stats.moved + 1
                log.info("builds: moved " .. id .. " - telling the other game")
            end
        end
        return
    end
    local da
    pcall(function() da = full_path(comp.DARef) end)
    da = da or last_da
    if not da then log.warn("builds: placed something but couldn't read what"); return end
    channel:send(string.format("P %s %.1f %.1f %.1f %.2f %.2f %.2f %.3f %.3f %.3f", da, l.X, l.Y, l.Z,
        r.Pitch, r.Yaw, r.Roll, s.X or 1, s.Y or 1, s.Z or 1))
    stats.placed = stats.placed + 1
    log.info("builds: placed " .. (da:match("[^%.]+$") or da) .. " - telling the other game")
    util.safe(function() bedtags.placed(da, { X = l.X, Y = l.Y, Z = l.Z }) end, "builds.bedtag")
    util.safe(function()
        local cname
        pcall(function() cname = util.fname(comp.DARef.BuildActorClass) end)
        local at = { X = l.X, Y = l.Y, Z = l.Z }
        doorlock.placed(cname or doorlock.class_at(at, da), at)
    end, "builds.doorlock")
end

local known_ids = {}
local function remember_id(b)
    local ok, id = pcall(id_of, b)
    if ok and not id:find("@0,0,0$") then known_ids[util.addr(b) or 0] = id end
end
local function on_gone(self, why)
    if applying or not shared() then return end
    local b = self:get()
    local ok, id = pcall(id_of, b)
    local addr = util.addr(b) or 0
    if not ok or id:find("@0,0,0$") then ok, id = known_ids[addr] ~= nil, known_ids[addr] end
    known_ids[addr] = nil
    if not ok then log.info("builds: one of our builds went (" .. why .. ") - its place unknown, not sent"); return end
    -- (the other game's removal, applied here a moment ago, isn't told back; a mark older than that is an old one
    -- whose hook never came: a later real removal at the same spot is told)
    local marked = expect_gone[id]
    expect_gone[id] = nil
    if marked and os.clock() - marked < EXPECT_GONE_S then return end
    pcall(function() bedtags.gone(util.vec(b:K2_GetActorLocation())) end)
    util.safe(function() doorlock.gone(doorlock.loc_of_id(id)) end, "builds.doorlock")
    channel:send("R " .. id)
    stats.removed = stats.removed + 1
    log.info("builds: " .. id .. " " .. why .. " - telling the other game")
end

local function find(id, near) return util.find_by_id(id, near) end

local mine_fn = function(self) util.safe(function() remember_id(self:get()) end, "builds.mine") end
local function on_explode(self)
    if applying or not shared() then return end
    local addr = util.addr(self:get()) or 0
    local id = known_ids[addr]
    known_ids[addr] = nil
    if not id then log.info("builds: a land mine went off - its place unknown, not sent"); return end
    channel:send("X " .. id)
    stats.removed = stats.removed + 1
    log.info("builds: land mine " .. id .. " went off - telling the other game")
end
local explode_fn = function(self) util.safe(on_explode, "builds.explode", self) end

-- The other game's mine went off: show it here and remove ours, without its damage (that happened there).
local function exploded(payload)
    local id = payload:match("^X (%S+)$")
    local b = id and find(id, 100)
    if not b then log.info("builds: land mine " .. tostring(id) .. " went off there - not here (gone off here too?)"); return end
    local l
    pcall(function() l = util.vec(b:K2_GetActorLocation()) end)
    known_ids[util.addr(b) or 0] = nil
    applying = true
    pcall(function() b:K2_DestroyActor() end)
    applying = false
    local gs = util.cdo("/Script/Engine.Default__GameplayStatics")
    if l and gs then
        local fx, cue = StaticFindObject(BOOM_FX), StaticFindObject(BOOM_CUE)
        local rot = { Pitch = 0, Yaw = math.random() * 360, Roll = 0 }
        if util.valid(fx) then pcall(function() gs:SpawnEmitterAtLocation(game.player(), fx, l, rot, { X = 1, Y = 1, Z = 1 }, true, 0, true) end) end
        if util.valid(cue) then pcall(function() gs:PlaySoundAtLocation(game.player(), cue, l, rot, 1.0, 1.0, 0.0, nil, nil, nil, nil) end) end
    end
    stats.applied_removes = stats.applied_removes + 1
    log.info("builds: the other player's land mine " .. id .. " went off - shown here")
end

local SAME_PIECE, STACKED = 15, 100   -- cm (a piece sent again is within 1 cm; land mines can lie 20 cm apart)
local function place(payload)
    local da, x, y, z, pi, ya, ro, sx, sy, sz =
        payload:match("^P (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
    if not da then return end
    local asset = util.find(da)
    local cls
    pcall(function() cls = asset.BuildActorClass end)
    if not util.valid(cls) then
        stats.missing = stats.missing + 1
        log.info("builds: the other player built " .. (da:match("[^%.]+$") or da) .. " - not loaded here, not shown")
        return
    end
    local loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    local rot = { Pitch = tonumber(pi), Yaw = tonumber(ya), Roll = tonumber(ro) }
    local cname
    pcall(function() cname = util.fname(cls) end)
    -- (one of that kind within SAME_PIECE is this one: a place sent again - a join's save already holding it - lands a
    -- few cm off across a 10 cm grid line, and the exact id alone built it twice)
    if cname and find(string.format("%s@%d,%d,%d", cname, grid(loc)), SAME_PIECE) then return end
    -- (diagnosis for "turrets stacking up", 2026-10-27: is a copy being built on top of one that's already here?
    -- Within 3 m it fired for every fence row - its pieces stand 2-2.6 m apart, live 2026-10-30)
    local near = cname and find(string.format("%s@%d,%d,%d", cname, grid(loc)), STACKED)
    if near then
        local d
        pcall(function() d = util.dist(util.vec(near:K2_GetActorLocation()), loc) end)
        log.warn(string.format("builds: the other player's %s goes %s cm from one of the same kind already here",
            da:match("[^%.]+$") or da, d and string.format("%.0f", d) or "?"))
    end
    local actor
    log.info("builds: building the other player's " .. (da:match("[^%.]+$") or da) .. "...")
    applying = true
    local ok, err = pcall(function() actor = game.world():SpawnActor(cls, loc, rot) end)
    applying = false
    if not (ok and util.valid(actor)) then
        log.warn("builds: couldn't build the other player's " .. (da:match("[^%.]+$") or da) .. ": " .. tostring(err))
        return
    end
    local scale = { X = tonumber(sx) or 1, Y = tonumber(sy) or 1, Z = tonumber(sz) or 1 }
    if math.abs(scale.X - 1) + math.abs(scale.Y - 1) + math.abs(scale.Z - 1) > 0.001 then
        pcall(function() actor:SetActorScale3D(scale) end)
    end
    stats.made = stats.made + 1
    log.info("builds: built the other player's " .. (da:match("[^%.]+$") or da))
    util.safe(function() bedtags.placed(da, loc) end, "builds.bedtag")
end

local function move(payload)
    local id, x, y, z, pi, ya, ro = payload:match("^M (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
    if not id then return end
    local b = find(id, 100)
    if not b then stats.missing = stats.missing + 1; log.info("builds: " .. id .. " moved - not here"); return end
    util.safe(function()
        doorlock.moved(util.vec(b:K2_GetActorLocation()), { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) })
    end, "builds.doorlock")
    local to = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    local ok, err = pcall(function()
        b:K2_SetActorLocationAndRotation(to, { Pitch = tonumber(pi), Yaw = tonumber(ya), Roll = tonumber(ro) }, false, {}, true)
    end)
    local at
    pcall(function() at = util.vec(b:K2_GetActorLocation()) end)
    if not ok or not at or util.dist(at, to) > 5.0 then
        log.warn(string.format("builds: the other player moved %s - it didn't move here (%s)", id,
            not ok and tostring(err) or (at and string.format("%.0f cm off", util.dist(at, to)) or "no place")))
        return
    end
    stats.applied_moves = stats.applied_moves + 1
    log.info("builds: the other player moved " .. id)
end

local interact_fn = function(self) util.safe(function() remember_id(self:get()) end, "builds.interact") end

-- the game's Move option on a piece: it opens build mode with that piece to put down again (still where it was)
local function on_move_option(self)
    if applying or not shared() then return end
    local b = self:get()
    local ok, id = pcall(id_of, b)
    if ok and not id:find("@0,0,0$") then move_from = { actor = b, id = id } end
end
local move_option_fn = function(self) util.safe(on_move_option, "builds.move_option", self) end

local function clean_name(s)
    s = tostring(s or ""):gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return util.utf8_cut(s, MAX_NAME)
end

-- the player renamed a container here (any container: the game lets anyone rename one)
local function on_rename(self, Name)
    if applying or not shared() then return end
    local b = self:get()
    local name
    pcall(function() name = Name:get():ToString() end)
    name = clean_name(name)
    if name == "" then return end
    local ok, id = pcall(id_of, b)
    if not ok or id:find("@0,0,0$") then log.warn("builds: renamed a container - its place unknown, not sent"); return end
    channel:send("C " .. id .. " " .. require("mirror.names").encode(name))
    stats.renamed = stats.renamed + 1
    log.info("builds: renamed " .. id .. " - telling the other game")
end

local function rename(payload)
    local id, enc = payload:match("^C (%S+) (%S+)$")
    if not id then return end
    local name = clean_name(require("mirror.names").decode(enc))
    if name == "" then return end
    local b = find(id, 100)
    if not b then stats.missing = stats.missing + 1; log.info("builds: " .. id .. " renamed - not here"); return end
    -- The hover and the inventory panel show ContainerName as it is when looked at (decompiled), so a write that
    -- didn't take is how a live rename stayed unseen until a rejoin brought the host's save (user 2026-11-10). Read
    -- back; if it didn't take, the game's own Rename (decompiled: OverrideBuildName only sets ContainerName).
    local function now_name()
        local s
        pcall(function() s = b.ContainerName:ToString() end)
        return s
    end
    local ok, err = pcall(function() b.ContainerName = FText(name) end)
    local how = "set"
    if now_name() ~= name then
        applying = true
        local ok2, err2 = pcall(function() b:OverrideBuildName(FText(name)) end)
        applying = false
        how = "the game's Rename"
        if now_name() ~= name then
            log.warn("builds: couldn't rename " .. id .. ": " .. tostring(ok and "the name didn't take" or err)
                .. (ok2 and "" or (" / " .. tostring(err2))))
            return
        end
    end
    stats.applied_renames = stats.applied_renames + 1
    log.info("builds: the other player renamed " .. id .. " (" .. how .. ")")
end
local rename_fn = function(self, Name) util.safe(on_rename, "builds.rename", self, Name) end

local function remove(payload)
    local id = payload:match("^R (%S+)$")
    if not id then return end
    local b = find(id, 100)
    if not b then stats.missing = stats.missing + 1; log.info("builds: " .. id .. " removed - not here"); return end
    local ok_id, our_id = pcall(id_of, b)
    expect_gone[ok_id and our_id or id] = os.clock()
    pcall(function() bedtags.gone(util.vec(b:K2_GetActorLocation())) end)
    util.safe(function() doorlock.gone(util.vec(b:K2_GetActorLocation())) end, "builds.doorlock")
    applying = true
    pcall(function() b:K2_DestroyActor() end)
    applying = false
    stats.applied_removes = stats.applied_removes + 1
    log.info("builds: the other player removed " .. id .. " - removed here")
end

local spawn_fn = function(self, SpawnTransform)
    util.safe(on_spawn_build, "builds.spawn", self, SpawnTransform)
end
local pickup_fn = function(self) util.safe(on_gone, "builds.pickup", self, "picked up") end
local destroy_fn = function(self) util.safe(on_gone, "builds.destroy", self, "destroyed") end
local horde_done_fn = function(self) util.safe(on_gone, "builds.horde_done", self, "finished its horde") end

function builds.tick(dt)
    util.safe(doorlock.tick, "doorlock.tick", dt)   -- (door locks hold with build sharing off too)
    if role == "off" then return end
    util.safe(bedtags.tick, "bedtags.tick", dt)
    if shared() then
        local obj, comp
        pcall(function() comp = game.player().BuildingComponent end)
        pcall(function() obj = comp.DARef end)
        if util.valid(obj) and not util.same(obj, last_obj) then last_obj, last_da = obj, full_path(obj) or last_da end
        local mv, ra = false, nil
        pcall(function() mv = comp["ReplacingObject?"] == true end)
        if mv then pcall(function() ra = comp.ReplacingActor end) end
        if mv and util.valid(ra) then
            if not util.same(ra, last_moving) then
                local ok, id = pcall(id_of, ra)
                last_moving, last_moving_id = ra, ok and id or nil
            end
        else
            last_moving, last_moving_id = nil, nil
        end
    end
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 1.0
        local ok = util.ensure_hook(BC .. ":SpawnBuild", spawn_fn)
        if ok ~= hooked_logged then
            hooked_logged = ok
            log.info("builds: build hook " .. (ok and "on" or ("not on yet (" .. util.hook_state(BC .. ":SpawnBuild") .. ")")))
        end
        util.ensure_hook(BM .. ":Svr_Spawn", pickup_fn)
        util.ensure_hook(BM .. ":MC_Destroy", destroy_fn)
        util.ensure_hook(TURRET .. ":OnInteractBuildable", pickup_fn)
        -- (that hook runs after the turret destroyed itself - its place reads 0,0,0 there: kept from BeginPlay, or
        -- the pick-up wasn't sent and the other game kept its copy, DBG-20261027-004)
        util.ensure_hook(TURRET .. ":ReceiveBeginPlay", mine_fn)
        util.ensure_hook(MINE .. ":ReceiveBeginPlay", mine_fn)
        util.ensure_hook(MINE .. ":Event_Explode", explode_fn)
        util.ensure_hook(BEACON .. ":SpawnRewards", horde_done_fn)
        util.ensure_hook(BM .. ":OnBeginInteract", interact_fn)
        util.ensure_hook(BM .. ":OnExecuteInteract", interact_fn)
        util.ensure_hook(BM .. ":ReplacingObject", move_option_fn)
        util.ensure_hook(CONTAINER .. ":OverrideBuildName", rename_fn)
        if not shared() then expect_gone = {} end
    end
    channel:pump(function(p)
        if not shared() then return end
        local k = p:sub(1, 1)
        traded()
        if k == "P" then util.safe(place, "builds.place", p)
        elseif k == "M" then util.safe(move, "builds.move", p)
        elseif k == "R" then util.safe(remove, "builds.remove", p)
        elseif k == "X" then util.safe(exploded, "builds.exploded", p)
        elseif k == "C" then util.safe(rename, "builds.rename", p)
        elseif k == "N" then util.safe(bedtags.apply, "builds.bedname", p) end
        -- more than two players: the host built / moved / removed it with plain actor calls no hook sees,
        -- so the other guests hear it from here (ids are places, the same in every world)
        peers.relay("mirror.builds", builds, function(m) m.relay_send(p) end)
    end)
end

function builds.relay_send(p) channel:send(p) end

function builds.status()
    return string.format("builds: placed %d, moved %d, removed %d, renamed %d | made %d, moves %d, removes %d, renames %d%s",
        stats.placed, stats.moved, stats.removed, stats.renamed, stats.made, stats.applied_moves, stats.applied_removes,
        stats.applied_renames,
        stats.missing > 0 and (", not here " .. stats.missing) or "")
end

-- Respawn/reload: the old world's objects are freed - drop them without touching them.
local function forget_world() last_moving, last_obj, last_moving_id, move_from = nil, nil, nil, nil end
function builds.init(c, r, s)
    game.on_world_reset(forget_world)
    cfg, role, session = c, r, s
    if cfg.build_sync == false then role = "off" end
    bedtags.init(s, function(p) channel:send(p) end, shared)
    doorlock.init(s, function() return require("mirror.localdir").get() .. "\\mirror_coop_lock_id_" .. tostring(r) .. ".txt" end)
    log.info("builds: " .. (role == "off" and "off" or "builds are shared"))
end

return builds
