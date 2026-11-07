-- SurrounSync entry point: reads the config, picks the role and starts the modules.

local cfg = require("mirror.config")
local log = require("mirror.log")

log.configure(cfg)

if not cfg.enabled then
    log.info("SurrounSync disabled via config.enabled = false")
    return
end

-- Most of the mod's garbage is short-lived (message strings, pose tables); the generational
-- collector frees it in small minor steps instead of long incremental sweeps.
-- cfg.gc_mode = "incremental" puts Lua's default back.
require("mirror.perf").set_gc(cfg.gc_mode)

local start_clock = os.clock()
local role, source = require("mirror.role").resolve(cfg)
local V = require("mirror.version")
log.info("SurrounSync " .. V.VERSION .. " (protocol " .. V.PROTOCOL .. ") starting (role=" .. role .. " from " .. source .. ")")
local net_source = require("mirror.settings").apply(cfg)
do
    local crumb = require("mirror.crumb")
    crumb.configure(cfg)
    local prev = crumb.start()
    if prev and prev:find("%S") then log.info("crash steps: the last run's final mod step was: " .. prev) end
end
log.configure(cfg)
local util, devtest = require("mirror.util"), require("mirror.devtest")
if cfg.devtest then util.safe(devtest.startup_probe, "devtest.startup_probe") end
util.safe(devtest.watch, "devtest.watch", cfg)
util.safe(function() local l = require("mirror.loader"); l.configure(cfg); l.start(cfg) end, "loader.start")
if role ~= "off" then
    local peer = cfg.steam and cfg.steam.peer or ""
    log.info(string.format("transport=%s%s%s (from %s)", cfg.transport,
        cfg.transport == "steam" and (", peer=" .. (peer ~= "" and peer or "any Steam friend")) or "",
        cfg.netsim.enabled and ", netsim on" or "", net_source))
end

require("mirror.ghost").configure(cfg)
require("mirror.game").init()
-- engine calls that wait for animation tasks (destroying characters, copies, cars) run only once animation is on the
-- game thread: a worker in a hooked Blueprint function waiting for our Lua lock froze the game
util.safe(function() require("mirror.animgate").init() end, "animgate.init")
-- nests saved with the old 1,000,000-health pin get their real health back, in single player too
require("mirror.infest").watch()
-- zombies stop at arm's length instead of standing inside the player (the game's zombie capsule ignores pawns)
util.safe(function() require("mirror.personalspace").init(cfg) end, "personalspace.init")
-- dogs bark (the game has no bark sound; SurrounSyncSounds.pak brings them)
util.safe(function() require("mirror.dogs").init(cfg) end, "dogs.init")
-- the hang glider: Jump while falling from a height opens it (the model is SurrounSyncGlider.pak)
util.safe(function() require("mirror.glider").init(cfg) end, "glider.init")
-- the hover bike: golf carts marked VehicleColor 78 wear SK_HoverBike and fly on FPVDrone's flight engine
util.safe(function() require("mirror.hoverbike").init(cfg) end, "hoverbike.init")
util.safe(function()
    local outrefs, game = require("mirror.outrefs"), require("mirror.game")
    outrefs.start(log.info)
    game.on_tick(function(dt) util.safe(outrefs.tick, "outrefs.tick", dt) end)
end, "outrefs.start")
-- the Colonel's Revenge Double Drum Magazine and the diamond Colonel's Revenge (SurrounSyncArmory.pak)
util.safe(function() require("mirror.armory").init(cfg) end, "armory.init")
-- admin fly: F7, the owner's game only
util.safe(function() require("mirror.adminfly").init(cfg) end, "adminfly.init")
-- who may fly the bundled FPV drone (FPVDrone.allowed): the owner always, solo too
util.safe(function() require("mirror.dronegrant").init() end, "dronegrant.init")
-- an Xbox-style pad plays the game (MY SETTINGS -> CONTROLLER): pad keys added next to the keyboard's
util.safe(function() require("mirror.gamepad").init(cfg) end, "gamepad.init")
-- the message cards' world-reset hook and the history key (Ctrl+F9)
util.safe(function() require("mirror.notify").init() end, "notify.init")
-- the round minimap at the top right (M twice, with a GPS worn)
util.safe(function() require("mirror.minimap").init() end, "minimap.init")
-- car/buildable radios: the game's Radio folder made, a SONGS FOLDER button on the radio screen opens it
util.safe(function() require("mirror.radio").init() end, "radio.init")
-- event site classes kept loaded from every map load on (a guest needs the host's, prefabs.lua)
util.safe(function() require("mirror.prefabs").watch() end, "prefabs.watch")

local menu = require("mirror.menu")
if role == "auto" then
    local link = require("mirror.link")
    link.configure(cfg)
    link.start_lobby()
    require("mirror.session").preinit(cfg)
    util.safe(function() require("mirror.worldset").init() end, "worldset.init")
    menu.init(cfg)
    util.safe(function() require("mirror.realmplay").init(cfg) end, "realmplay.init")
    -- the message of the day (the bridge fetches it): a card in a world, a banner at the main menu
    util.safe(function() require("mirror.motd").init() end, "motd.init")
elseif role == "host" or role == "guest" then
    require("mirror.phase1").init(cfg, role)
    menu.init(cfg)
elseif cfg.phase0 and cfg.phase0.enabled then
    require("mirror.phase0").init(cfg)
end

log.info(string.format("SurrounSync ready (start-up %.0f ms).", (os.clock() - start_clock) * 1000))
