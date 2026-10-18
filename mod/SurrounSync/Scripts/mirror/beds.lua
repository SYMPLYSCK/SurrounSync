-- Respawn points per world: your own bed at home, a separate one in a friend's world.

local log = require("mirror.log")
local util = require("mirror.util")
local fs = require("mirror.fs")
local game = require("mirror.game")

local beds = {}

local path = nil

local function pc()
    local c = game.controller()
    if util.valid(c) then return c end
    pcall(function() c = game.player().Controller end)
    return util.valid(c) and c or nil
end

function beds.read()
    local c = pc()
    if not c then return nil end
    local s
    pcall(function()
        local t = c.RespawnLoc
        local l, q = t.Translation, t.Rotation
        s = string.format("%d %.1f %.1f %.1f %.6f %.6f %.6f %.6f", c.RespawnPointEnabled == true and 1 or 0,
            l.X, l.Y, l.Z, q.X, q.Y, q.Z, q.W)
    end)
    return s
end

function beds.is_set(s) return s ~= nil and s:sub(1, 1) == "1" end

function beds.apply(s)
    local c = pc()
    if not (c and s) then return false end
    local on, x, y, z, qx, qy, qz, qw = s:match("^(%d) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
    local ok = pcall(function()
        if on == "1" then
            c.RespawnLoc = { Translation = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) },
                             Rotation = { X = tonumber(qx), Y = tonumber(qy), Z = tonumber(qz), W = tonumber(qw) },
                             Scale3D = { X = 1, Y = 1, Z = 1 } }
            c.RespawnPointEnabled = true
        else
            c.RespawnPointEnabled = false
        end
    end)
    local now = beds.read()
    return ok and now ~= nil and (on == "1") == beds.is_set(now)
end

local function load()
    local t = {}
    local s = path and fs.read(path)
    for line in (s or ""):gmatch("[^\r\n]+") do
        local k, v = line:match("^(.-)=(.*)$")
        if k then t[k] = v end
    end
    return t
end

local function store(t)
    if not path then return false end
    local out = { }
    for k, v in pairs(t) do out[#out + 1] = k .. "=" .. v end
    table.sort(out)
    return fs.write(path, table.concat(out, "\n") .. "\n")
end

local function clean(s) return (tostring(s or "?"):gsub("[|=\r\n]", "_")) end

function beds.world_key(host, host_slot, own_slot) return "world|" .. clean(host) .. "|" .. clean(host_slot) .. "|" .. clean(own_slot) end
function beds.home_key(own_slot) return "home|" .. clean(own_slot) end

function beds.get(key) return load()[key] end

function beds.set(key, value)
    local t = load()
    if t[key] == value then return true end
    t[key] = value
    local ok = store(t)
    if not ok then log.warn("beds: couldn't write " .. tostring(path)) end
    return ok
end

function beds.init(file) path = file end

return beds
