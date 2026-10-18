-- Offline ghost test: replays your own movement on a ghost a couple of seconds later.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local recorder = require("mirror.recorder")
local ghost = require("mirror.ghost")
local probe = require("mirror.probe")
local save_guard = require("mirror.save_guard")
local keepalive = require("mirror.keepalive")
local look = require("mirror.look")

local phase0 = {}

local cfg
local HEARING = "/Script/AIModule.Default__AISense_Hearing"

local mode = "follow"
local want = {}
local probe_in = 0.0

local function sample(player)
    local s = {}
    local ok = pcall(function()
        s.loc = util.vec(player:K2_GetActorLocation())
        s.yaw = player:K2_GetActorRotation().Yaw
        s.vel = util.vec(player:GetVelocity())
        s.crouch = player.bIsCrouched == true
    end)
    return ok and s or nil
end

local function spawn_ghost(at)
    local pose = (at and at.loc) and at or recorder.at(recorder.time() - cfg.phase0.delay)
    if not pose then log.warn("phase0: nothing recorded yet; walk around a second first"); return end
    if not game.world() then log.warn("phase0: no world"); return end
    local g = ghost.spawn(game.world(), pose.loc, pose.yaw, "host")
    if g then
        look.forget()
        util.safe(function() look.apply(g, look.capture(game.player())) end, "phase0.look")
    end
end

local function make_noise()
    local g = ghost.get()
    if not g then log.warn("phase0: no ghost for noise"); return end
    local loc = ghost.location()
    util.safe(function()
        util.cdo(HEARING):ReportNoiseEvent(g, loc, 1.0, g, 0.0, FName("None"))
        log.info(string.format("phase0: noise at ghost (%.0f, %.0f, %.0f)", loc.X, loc.Y, loc.Z))
    end, "phase0.noise")
end

local function handle_keys()
    if want.toggle_ghost then
        want.toggle_ghost = nil
        if ghost.exists() then ghost.destroy("Ctrl+F1") else mode = "follow"; spawn_ghost() end
    end
    if want.toggle_mode then
        want.toggle_mode = nil
        mode = (mode == "follow") and "park" or "follow"
        if mode == "park" then
            pcall(function() ghost.get().CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 } end)
        end
        log.info("phase0: ghost mode = " .. mode)
    end
    if want.noise then want.noise = nil; make_noise() end
    if want.status then want.status = nil; ghost.report(); probe.report(game.player()) end
end

local function on_tick(dt)
    local player = game.player()
    local s = sample(player)
    if s then recorder.push(dt, s) end

    handle_keys()

    if ghost.exists() and mode == "follow" then
        ghost.apply(recorder.at(recorder.time() - cfg.phase0.delay), true)
    end

    save_guard.tick(dt, game.world())
    keepalive.tick(dt)

    probe_in = probe_in - dt
    if probe_in <= 0 then
        probe_in = cfg.phase0.probe_interval
        if ghost.exists() then probe.report(player) end
    end
end

function phase0.init(c)
    cfg = c
    recorder.configure(cfg.phase0.buffer)
    probe.configure(cfg)
    keepalive.configure(cfg)
    save_guard.configure(cfg, spawn_ghost)

    game.on_ready(function()
        util.hook("/Game/Blueprints/Components/PassiveSkillsComponent.PassiveSkillsComponent_C:AddXP_Toughness",
            function() probe.on_toughness_xp() end)
        save_guard.install()
    end)
    game.on_tick(on_tick)
    game.player_hook("ReceiveAnyDamage", function(self, Damage, DamageType, InstigatedBy, DamageCauser)
        util.safe(function()
            if ghost.is(self:get()) then probe.on_ghost_damage(Damage:get(), DamageCauser:get()) end
        end, "phase0.damage")
    end)
    game.player_hook("Event_LoadPlayer", function(self)
        util.safe(function() probe.on_load_player(ghost.is(self:get())) end, "phase0.loadplayer")
    end)

    RegisterKeyBind(Key.F1, { ModifierKey.CONTROL }, function() want.toggle_ghost = true end)
    RegisterKeyBind(Key.F2, { ModifierKey.CONTROL }, function() want.toggle_mode = true end)
    RegisterKeyBind(Key.F3, { ModifierKey.CONTROL }, function() want.noise = true end)
    RegisterKeyBind(Key.F4, { ModifierKey.CONTROL }, function() want.status = true end)
    log.info("phase0: ready. In-game: Ctrl+F1 ghost on/off, Ctrl+F2 follow/park, Ctrl+F3 noise at ghost, Ctrl+F4 status")
end

return phase0
