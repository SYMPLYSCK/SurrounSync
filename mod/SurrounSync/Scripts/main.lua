-- SurrounSync entry point: reads the config, picks the role and starts the modules.

local cfg = require("mirror.config")
local log = require("mirror.log")

log.configure(cfg)

if not cfg.enabled then
    log.info("SurrounSync disabled via config.enabled = false")
    return
end

local role, source = require("mirror.role").resolve(cfg)
local V = require("mirror.version")
log.info("SurrounSync " .. V.VERSION .. " (protocol " .. V.PROTOCOL .. ") starting (role=" .. role .. " from " .. source .. ")")
local net_source = require("mirror.settings").apply(cfg)
log.configure(cfg)
local util, devtest = require("mirror.util"), require("mirror.devtest")
util.safe(devtest.startup_probe, "devtest.startup_probe")
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

local menu = require("mirror.menu")
if role == "auto" then
    local link = require("mirror.link")
    link.configure(cfg)
    link.start_lobby()
    require("mirror.session").preinit(cfg)
    menu.init(cfg)
elseif role == "host" or role == "guest" then
    require("mirror.phase1").init(cfg, role)
    menu.init(cfg)
elseif cfg.phase0 and cfg.phase0.enabled then
    require("mirror.phase0").init(cfg)
end

log.info("SurrounSync ready.")
