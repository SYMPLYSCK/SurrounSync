-- Main co-op loop: sends our position, shows the other player, and runs the sync modules.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local track = require("mirror.track")
local link = require("mirror.link")
local save_guard = require("mirror.save_guard")
local keepalive = require("mirror.keepalive")
local look = require("mirror.look")
local session = require("mirror.session")
local invdiag = require("mirror.invdiag")
local anim = require("mirror.anim")
local zombies = require("mirror.zombies")
local fire = require("mirror.fire")
local drops = require("mirror.drops")
local notify = require("mirror.notify")
local world = require("mirror.world")
local doors = require("mirror.doors")
local power = require("mirror.power")
local audio = require("mirror.audio")
local loot = require("mirror.loot")
local builds = require("mirror.builds")
local lights = require("mirror.lights")
local tactical = require("mirror.tactical")
local throwables = require("mirror.throwables")
local vehicles = require("mirror.vehicles")
local corpses = require("mirror.corpses")
local deathbags = require("mirror.deathbags")
local nametag = require("mirror.nametag")
local infestmarks = require("mirror.infestmarks")
local netq = require("mirror.netq")
local clockmap = require("mirror.clockmap")
local chat = require("mirror.chat")
local compat = require("mirror.compat")
local voice = require("mirror.voice")
local perf = require("mirror.perf")
local devtest = require("mirror.devtest")

local phase1 = {}

local PROTOCOL = require("mirror.version").PROTOCOL

local cfg, role
local now = 0.0
local peer_protocol = nil
local quiet_logged = false
local hello_missing_logged = false
local my_dead = nil
local peer_dead = false
local revived_at = nil

function phase1.peer_dead() return peer_dead end
local connected = false
local seq = 0
local send_in = 0.0
local remote = nil
local last_rx = -math.huge
local first_rx = nil
local rx_count, status_in = 0, 0.0
local ghost_kind
local look_in = 0.0
local my_look = nil
local peer_look = nil
local applied_to = nil
local look_dirty = false
local look_retry = nil
local dump_look_in = nil
local look_anims, look_combat, look_fast_until = 0, nil, 0.0

local my_combat = nil
local function aim_fields(player)
    local combat, ads, hip, melee, pitch = 0, false, false, false, 0.0
    pcall(function() combat = player.Mesh:GetAnimInstance().BlendSpaceInt or 0 end)
    my_combat = combat
    pcall(function() ads = player["IsADS?"] == true end)
    pcall(function() hip = player["HipFire?"] == true end)
    pcall(function() melee = player["InMeleeStance?"] == true end)
    local view_yaw = 0
    pcall(function()
        local cr = game.controller():GetControlRotation()
        pitch, view_yaw = cr.Pitch, cr.Yaw
        if pitch > 180 then pitch = pitch - 360 end
    end)
    local lh = { X = -32.5, Y = -10.0, Z = -2.5 }
    pcall(function() lh = util.vec(player.LeftHandLoc) end)
    local hy, hr = 0, 0
    pcall(function()
        local h = player.Mesh:GetAnimInstance().HeadRotation
        hy, hr = h.Yaw, h.Roll
    end)
    return string.format(" %d %d %d %d %.1f %.2f %.2f %.2f %.1f %.1f %.1f", combat, ads and 1 or 0, hip and 1 or 0,
        melee and 1 or 0, pitch, lh.X, lh.Y, lh.Z, hy, hr, view_yaw)
end

local function flags(player)
    local f = 0
    pcall(function() if player.bIsCrouched then f = f + 1 end end)
    pcall(function() if player.CharacterMovement:IsFalling() then f = f + 2 end end)
    pcall(function() if player.StaminaComponent.CurrentlySprinting == true then f = f + 4 end end)
    return f
end

local function move_fields(player)
    local walk, crouch, stam = 0, 0, 100
    pcall(function() walk = player.CharacterMovement.MaxWalkSpeed end)
    pcall(function() crouch = player.CharacterMovement.MaxWalkSpeedCrouched end)
    pcall(function()
        local sc = player.StaminaComponent
        if sc.MaxStamina > 0 then stam = sc.CurrentStamina * 100 / sc.MaxStamina end
    end)
    return string.format(" %.0f %.0f %.0f %.3f", walk, crouch, stam, now)
end

local pose_clock = clockmap.new(0.05, 0.25, 0.15)
local pose_gaps = { seq = nil, got = 0, skipped = 0 }

local pose_line = nil
local function sample(player)
    pose_line = nil
    pcall(function()
        local l, r, v = player:K2_GetActorLocation(), player:K2_GetActorRotation(), player:GetVelocity()
        pose_line = string.format("%.1f %.1f %.1f %.1f %.1f %.1f %.1f %d",
            l.X, l.Y, l.Z, r.Yaw, v.X, v.Y, v.Z, flags(player)) .. aim_fields(player) .. move_fields(player)
    end)
end

local function parse(payload)
    local x, y, z, yaw, vx, vy, vz, c, rest = payload:match(
        "^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%d)(.*)$")
    if not c then return nil end
    local pose = {
        loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) },
        yaw = tonumber(yaw),
        vel = { X = tonumber(vx), Y = tonumber(vy), Z = tonumber(vz) },
        crouch = (tonumber(c) or 0) % 2 == 1,
        falling = math.floor((tonumber(c) or 0) / 2) % 2 == 1,
        sprint = (tonumber(c) or 0) >= 4,
    }
    local combat, ads, hip, melee, pitch, lx, ly, lz, hy, hr, vy, mv =
        rest:match("^ (%-?%d+) (%d) (%d) (%d) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)(.*)$")
    local walk, crouch_speed, stam, sent = (mv or ""):match("^ (%S+) (%S+) (%S+) (%S+)$")
    if walk then
        pose.move = { walk = tonumber(walk), crouch = tonumber(crouch_speed), stamina = tonumber(stam) }
        pose.sent = tonumber(sent)
    end
    if pitch then
        pose.aim = { combat = tonumber(combat), ads = ads == "1", hip = hip == "1", melee = melee == "1",
                     pitch = tonumber(pitch) or 0,
                     lhand = { X = tonumber(lx) or 0, Y = tonumber(ly) or 0, Z = tonumber(lz) or 0 },
                     head = { Yaw = tonumber(hy) or 0, Roll = tonumber(hr) or 0 },
                     view_yaw = tonumber(vy) }
    end
    return pose
end

local function status()
    local gl, pl = ghost.location(), nil
    pcall(function() pl = util.vec(game.player():K2_GetActorLocation()) end)
    local age = now - last_rx
    log.info("phase1: link " .. link.status())
    local q = netq.status()
    local late, shown = pose_clock:report()
    local lost = pose_gaps.got + pose_gaps.skipped > 0 and (100 * pose_gaps.skipped / (pose_gaps.got + pose_gaps.skipped)) or 0
    log.info(string.format("phase1: net round trip %s, poses %d/s (%.0f%% skipped), late avg %.0f ms, shown %.0f ms behind%s",
        q.rtt and string.format("%.0f ms", q.rtt) or "?", math.floor(pose_gaps.got / cfg.phase1.status_interval + 0.5), lost,
        late, shown, zombies.net_report and (" | zombies " .. zombies.net_report()) or ""))
    pose_gaps.got, pose_gaps.skipped = 0, 0
    log.info(string.format("phase1[%s]: rx %.1f/s, last %.2fs ago | ghost %s%s",
        role, rx_count / cfg.phase1.status_interval, age,
        ghost.exists() and ghost.kind() or "none",
        ((gl and pl) and string.format(" %.0f m from you", util.dist(gl, pl) / 100) or "")
        .. " | zombies: " .. zombies.status() .. " | " .. fire.status() .. " | " .. drops.status() .. " | " .. world.status() .. " | " .. doors.status() .. " | " .. power.status() .. " | " .. audio.status() .. " | " .. loot.status() .. " | " .. builds.status() .. " | " .. corpses.status() .. " | " .. deathbags.status() .. " | " .. tactical.status() .. " | " .. throwables.status() .. " | " .. vehicles.status()))
    rx_count = 0
end

local my_where, peer_where = nil, nil
local guest_gone_t = nil
local time_check_in = 0.0
local guest_announced = false
local function busy_where(w) return w == "loading" or w == "leaving" end
local function same_world()
    if role == "guest" then return session.in_world() end
    return peer_where == "joined"
end
function phase1.same_world() return same_world() end

local started = false
local cur_peer = nil
function phase1.started() return started and role or nil end
local bye_seen = nil
local function on_tick(dt)
    if not started then return end
    perf.frame_begin()
    now = now + dt
    perf.run("link", util.safe, link.tick, "link.tick", dt)
    local player = game.player()

    send_in = send_in - dt
    if send_in <= 0 then
        send_in = 1.0 / cfg.phase1.send_hz
        perf.run("pose", sample, player)
        if pose_line then seq = seq + 1; link.send(seq, pose_line) end
    end

    local pseq, payload = link.poll()
    pseq = tonumber(pseq)
    if pseq then
        if pose_gaps.seq and pseq > pose_gaps.seq then pose_gaps.skipped = pose_gaps.skipped + (pseq - pose_gaps.seq - 1) end
        if not pose_gaps.seq or pseq > pose_gaps.seq or pseq < pose_gaps.seq - 1000 then pose_gaps.seq = pseq end
        pose_gaps.got = pose_gaps.got + 1
    end
    if payload then
        local pose = parse(payload)
        if pose then
            local t = pose_clock:place(pose.sent, now)
            if t or not pose.sent then remote:push(t or now, pose) end
            last_rx = now; first_rx = first_rx or now; rx_count = rx_count + 1
        end
    end
    if not connected and now - last_rx < 1 then
        connected = true
        local who = link.peer_name()
        if role == "guest" then
            if session.state() == "joined" then notify.show("Reconnected to " .. who .. ".", "good") end
        else
            log.info("phase1: " .. who .. " connected")
        end
    elseif connected and now - last_rx > 30 and not (busy_where(peer_where) or busy_where(session.where())) then
        connected = false
        notify.show("Lost connection to " .. link.peer_name() .. ".", "bad")
    end

    if role == "guest" then
        local bye = link.get_blob("bye")
        if bye and bye ~= bye_seen then
            bye_seen = bye
            if session.state() == "joined" then
                notify.show(link.peer_name() .. " ended the session. Taking you home with your character...", "info")
                session.go_home_now()
            else
                notify.show(link.peer_name() .. " stopped hosting.", "info")
            end
        end
    end

    local mine_where = session.where()
    if mine_where ~= my_where then
        my_where = mine_where
        link.put_blob("where", mine_where)
        log.info("phase1: told the other game I'm " .. mine_where)
    end
    local w = link.get_blob("where")
    if w and w ~= peer_where then
        local was = peer_where
        peer_where = w
        log.info("phase1: the other game is " .. w)
        if role == "host" and w == "loading" then loot.guest_arriving() end
        if role == "host" then
            local who = link.peer_name()
            if w == "joined" and was == "loading" then
                guest_announced = true
                notify.show(who .. " joined your world.", "good")
            elseif (guest_announced and (w == "leaving" or w == "own")) or (w == "own" and was == "loading") then
                guest_announced = false
                notify.show(who .. " left your world.", "info")
                session.checkpoint("guest left")
            end
        end
    end

    if role == "host" and (peer_where == "joined" or busy_where(peer_where)) and link.peer_state(now - last_rx) == "gone" then
        guest_gone_t = (guest_gone_t or 0) + dt
        local wait = link.peer_game_gone() and 2 or (cfg.save and cfg.save.guest_gone_reset or 30)
        if guest_gone_t >= wait then
            guest_gone_t = nil
            log.info("phase1: the guest's game is gone - forgetting it was in my world")
            peer_where, guest_announced = nil, false
            if ghost.exists() then ghost.destroy("guest gone") end
            session.save_now()
            notify.show(link.peer_name() .. "'s game closed. Their character is safe on their side.", "info")
        end
    elseif link.peer_state(now - last_rx) == "ok" then
        guest_gone_t = nil
    end

    if not quiet_logged and last_rx > 0 and now - last_rx > 10 then
        quiet_logged = true
        log.warn("phase1: no data from the other game for 10 s (paused, loading or closed)")
    elseif quiet_logged and now - last_rx < 1 then
        quiet_logged = false
        log.info("phase1: the other game is back")
    end
    local dead = false
    pcall(function() dead = player["PlayerDead?"] == true end)
    if dead ~= my_dead then
        my_dead = dead
        link.put_blob("life", dead and "dead" or "alive")
        log.info("phase1: told the other game I'm " .. (dead and "dead" or "alive"))
    end
    local life = link.get_blob("life")
    if life then
        local d = life == "dead"
        if d ~= peer_dead then
            peer_dead = d
            revived_at = not d and now or nil
            log.info("phase1: the other player is " .. (d and "dead - hiding their ghost" or "alive again"))
        end
    end

    local fresh = now - last_rx < cfg.phase1.peer_timeout
    local together = same_world()
    time_check_in = time_check_in - dt
    if my_dead and together and time_check_in <= 0 then
        time_check_in = 0.5
        local gs, td = util.cdo("/Script/Engine.Default__GameplayStatics"), nil
        pcall(function() td = gs:GetGlobalTimeDilation(player) end)
        if type(td) == "number" and td < 0.99 then
            pcall(function() gs:SetGlobalTimeDilation(player, 1.0) end)
            log.info(string.format("phase1: dead in co-op - game time back from %.2fx to real time (the other player plays on)", td))
        end
    end
    if peer_dead and ghost.exists() then
        ghost.destroy("peer dead")
    elseif not together and ghost.exists() then
        ghost.destroy("not in the same world")
    elseif not fresh and ghost.exists() then
        ghost.destroy("peer silent " .. cfg.phase1.peer_timeout .. " s")
    elseif together and fresh and not peer_dead and not ghost.exists() and not save_guard.busy() and game.world()
            and (not revived_at or now - revived_at > 0.75) then
        local n = remote:newest()
        perf.run("ghost.spawn", ghost.spawn, game.world(), n.loc, n.yaw, ghost_kind)
    end

    local pose_delay = pose_clock:delay(dt)
    if ghost.exists() then
        if now - last_rx > cfg.phase1.hold_after then
            perf.run("ghost", ghost.apply, remote:newest(), false)
        else
            perf.run("ghost", ghost.apply, remote:at(now - pose_delay, util, cfg.phase1.max_extrapolation), true)
        end
    end

    local switching = anim.count() ~= look_anims or my_combat ~= look_combat
    if switching then
        look_anims, look_combat, look_fast_until = anim.count(), my_combat, now + 1.5
        look_in = math.min(look_in, 0.05)
    end
    look_in = look_in - dt
    if look_in <= 0 then
        look_in = now < look_fast_until and 0.15 or cfg.phase1.look_interval
        local ads = false
        pcall(function() ads = player["IsADS?"] == true end)
        local mine = (not ads) and look.capture(player) or my_look
        if mine and mine ~= my_look then
            my_look = mine
            link.put_blob("look", mine)
            log.info("phase1: sent look (" .. select(2, mine:gsub("\n", "")) + 1 .. " lines; gear: " .. look.gear_summary(mine) .. ")")
        end
        local hello = (now - last_rx < 5) and link.get_blob("hello") or nil
        if hello then
            local v = tonumber(hello:match("protocol (%d+)") or "")
            if v ~= peer_protocol then
                peer_protocol = v
                if v == PROTOCOL then
                    log.info("phase1: the other game runs the same SurrounSync protocol (" .. PROTOCOL .. ")")
                else
                    notify.show(link.peer_name() .. " is using a different version of SurrounSync. You both need the same version.", "bad")
                    log.error(string.format("phase1: PROTOCOL MISMATCH - this game %d, the other %s. Restart the game that wasn't "
                        .. "restarted after the last update; until then sync is unreliable.", PROTOCOL, tostring(v)))
                end
            end
        end
        if peer_protocol == nil and not hello_missing_logged and first_rx and now - first_rx > 10 then
            hello_missing_logged = true
            log.error("phase1: the other game sends poses but no protocol announcement - it runs an OLDER SurrounSync; restart it")
        end
    end
    local theirs = link.get_blob("look")
    if theirs then peer_look = theirs; look_dirty = true end
    local g = ghost.get()
    if look_retry and g then
        look_retry.t = look_retry.t - dt
        if look_retry.t <= 0 then
            look_retry.n = look_retry.n + 1
            if look_retry.n > 40 then look_retry = nil else look_retry.t, look_dirty = 3.0, true end
        end
    end
    if g and peer_look and (look_dirty or applied_to ~= ghost.generation()) then
        if applied_to ~= ghost.generation() then look.forget() end
        applied_to, look_dirty = ghost.generation(), false
        local miss = 0
        perf.run("look", util.safe, function() miss = look.apply(g, peer_look) or 0 end, "phase1.look")
        if miss == 0 then look_retry = nil elseif not look_retry then look_retry = { t = 3.0, n = 0 } end
        if cfg.diagnostics then dump_look_in = 2.0 end
    end
    if dump_look_in and g then
        dump_look_in = dump_look_in - dt
        if dump_look_in <= 0 then
            dump_look_in = nil
            util.safe(look.dump, "phase1.look_dump", g)
        end
    end

    perf.run("save_guard", save_guard.tick, dt, game.world())
    perf.run("keepalive", keepalive.tick, dt)
    perf.run("session", session.tick, dt)
    perf.run("anim", anim.tick)
    perf.run("zombies", zombies.tick, dt)
    perf.run("fire", fire.tick, dt)
    perf.run("drops", drops.tick, dt)
    perf.run("world", world.tick, dt)
    perf.run("doors", doors.tick, dt)
    perf.run("jobs", util.jobs_tick, 0.004)
    perf.run("power", util.safe, power.tick, "power.tick", dt)
    perf.run("audio", util.safe, audio.tick, "audio.tick", dt)
    perf.run("loot", loot.tick, dt)
    perf.run("builds", builds.tick, dt)
    perf.run("infestmarks", infestmarks.tick, dt)
    perf.run("netq", util.safe, netq.tick, "netq.tick", dt, first_rx and (now - last_rx) or math.huge)
    perf.run("chat", util.safe, chat.tick, "chat.tick")
    perf.run("compat", util.safe, compat.tick, "compat.tick")
    perf.run("voice", util.safe, voice.tick, "voice.tick", dt)
    perf.run("corpses", corpses.tick, dt)
    perf.run("deathbags", deathbags.tick, dt)
    perf.run("nametag", util.safe, nametag.tick, "nametag.tick", dt)
    perf.run("lights", util.safe, lights.tick, "lights.tick", dt, remote:newest())
    perf.run("tactical", util.safe, tactical.tick, "tactical.tick", dt)
    perf.run("throwables", util.safe, throwables.tick, "throwables.tick", dt)
    perf.run("vehicles", util.safe, vehicles.tick, "vehicles.tick", dt)
    notify.tick(dt)
    util.safe(devtest.tick, "devtest.tick", dt)

    status_in = status_in - dt
    if status_in <= 0 then status_in = cfg.phase1.status_interval; status() end
    perf.frame_end(dt)
end

function phase1.connected() return now - last_rx < 15 end

function phase1.can_switch()
    if not started then return true end
    if role == "guest" then return session.state() == "idle" end
    return not (peer_where == "joined" or peer_where == "loading" or peer_where == "leaving")
end

local function reset_link_state()
    if ghost.exists() then ghost.destroy("co-op restarted in another role") end
    peer_protocol, quiet_logged, hello_missing_logged = nil, false, false
    my_dead, peer_dead, connected, revived_at = nil, false, false, nil
    last_rx, first_rx, rx_count = -math.huge, nil, 0
    my_look, peer_look, applied_to, look_dirty = nil, nil, nil, false
    my_where, peer_where, guest_announced = nil, nil, false
    netq.reset()
    compat.reset()
end

function phase1.peer_where() return peer_where end

function phase1.say_bye() link.put_blob("bye", "stop " .. os.time()) end

function phase1.stop()
    if not started then return end
    log.info("phase1: co-op stopped (" .. tostring(role) .. ")")
    reset_link_state()
    link.bridge_cmd("stop")
    started, cur_peer = false, nil
end

function phase1.init(c, r, peer_id)
    if started and r == role and (peer_id or "") == (cur_peer or "") then return end
    if started then
        log.info(string.format("phase1: switching from %s to %s%s", tostring(role), r, peer_id and (" (" .. tostring(peer_id) .. ")") or ""))
        reset_link_state()
    end
    started = true
    cur_peer = peer_id
    cfg, role = c, r
    ghost_kind = (role == "host") and "host" or "guest"
    remote = track.new(3.0)
    keepalive.configure(cfg)
    perf.configure(cfg)
    save_guard.configure(cfg, function() end)
    link.configure(cfg)
    local mine, theirs = link.open(role, peer_id)
    link.put_blob("hello", "SurrounSync protocol " .. PROTOCOL .. " role " .. role)
    notify.configure(cfg)
    session.init(cfg, role, phase1.connected)
    session.set_peer_state(function() return link.peer_state(now - last_rx) end)
    session.set_guest_in(function() return peer_where == "joined" or busy_where(peer_where) end)
    session.set_peer_locator(function()
        local n = remote:newest()
        return n and n.loc and { X = n.loc.X, Y = n.loc.Y, Z = n.loc.Z } or nil
    end)
    invdiag.init(cfg)
    anim.init(cfg)
    zombies.init(cfg, role, session)
    fire.init(cfg, role)
    drops.init(cfg, role, session)
    world.init(cfg, role, session, phase1.connected)
    doors.init(cfg, role, session, phase1.connected)
    power.init(cfg, role, session)
    audio.init(cfg, role, session, zombies, fire)
    loot.init(cfg, role, session)
    builds.init(cfg, role, session)
    corpses.init(cfg, role, zombies, session)
    tactical.init(cfg)
    throwables.init(cfg)
    vehicles.init(cfg, role, session)
    deathbags.init(cfg, role, session, same_world)
    zombies.set_guest_center(function()
        local gl = ghost.location()
        if gl or role ~= "host" or not same_world() then return gl end
        local n = remote:newest()
        return n and n.loc and { X = n.loc.X, Y = n.loc.Y, Z = n.loc.Z } or nil
    end)
    nametag.init(cfg)
    infestmarks.init(session, role, cfg)
    voice.init(same_world)
    devtest.init(role, zombies, loot)
    game.on_ready(function()
        save_guard.install()
        if role == "guest" and not connected and not (peer_id and peer_id ~= "") then
            log.info("phase1: looking for the host")
        end
    end)
    game.on_tick(on_tick)
    log.info(string.format("phase1: role=%s, sending %s, reading %s", role, mine, theirs))
end

return phase1
