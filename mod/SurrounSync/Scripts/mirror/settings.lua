-- Per-PC settings from mirror_settings.txt (transport, peer, test options).

local log = require("mirror.log")

local settings = {}

local FILE = "mirror_settings.txt"

local function onoff(v)
    v = v:lower()
    if v == "on" or v == "true" or v == "1" or v == "yes" then return true end
    if v == "off" or v == "false" or v == "0" or v == "no" then return false end
    return nil
end

local APPLY = {
    transport = function(cfg, v)
        v = v:lower()
        if v ~= "file" and v ~= "steam" then return false end
        cfg.transport = v
        return true
    end,
    peer = function(cfg, v)
        if v ~= "" and not v:match("^%d+$") then return false end
        cfg.steam = cfg.steam or {}
        cfg.steam.peer = v
        return true
    end,
    netsim = function(cfg, v)
        local b = onoff(v)
        if b == nil then return false end
        cfg.netsim.enabled = b
        return true
    end,
    linkdir = function(cfg, v)
        if not v:match("^[%w_]+$") then return false end
        cfg.link_dir = v
        return true
    end,
    testnet = function(cfg, v)
        local n = tonumber(v)
        if not n then return false end
        cfg.steam = cfg.steam or {}
        cfg.steam.test_port = math.floor(n)
        return true
    end,
    devtest = function(cfg, v) cfg.devtest = (v == "on" or v == "true"); return true end,
    loglevel = function(cfg, v)
        v = v:upper()
        if not ({ ERROR = 1, WARN = 1, INFO = 1, DEBUG = 1 })[v] then return false end
        cfg.debug.log_level = v
        return true
    end,
    saved = function(cfg, v)
        if not v:match("^[%w_]+$") then return false end
        cfg.phase2.saved_override = v
        return true
    end,
    latency_ms = function(cfg, v) cfg.netsim.latency_ms = tonumber(v); return cfg.netsim.latency_ms ~= nil end,
    jitter_ms = function(cfg, v) cfg.netsim.jitter_ms = tonumber(v); return cfg.netsim.jitter_ms ~= nil end,
    loss = function(cfg, v) cfg.netsim.loss = tonumber(v); return cfg.netsim.loss ~= nil end,
}

function settings.apply(cfg)
    local f = io.open(FILE, "r")
    if not f then return "config.lua" end
    local n = 0
    for line in f:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:match("^[#;]") then
            local k, v = line:match("^([%w_]+)%s*=%s*(.-)$")
            local fn = k and APPLY[k:lower()]
            v = v and v:gsub('^"(.*)"$', "%1")
            if not fn then
                log.warn(FILE .. ": unknown line '" .. line .. "' (keys: transport, peer, netsim, saved, linkdir, testnet, devtest, loglevel, latency_ms, jitter_ms, loss)")
            elseif not fn(cfg, v) then
                log.warn(FILE .. ": bad value in '" .. line .. "' - ignored")
            else
                n = n + 1
            end
        end
    end
    f:close()
    return n > 0 and FILE or "config.lua"
end

return settings
