-- Detects the same install running twice (two games sharing one folder).

local log = require("mirror.log")
local fs = require("mirror.fs")

local instance = {}

local FILE = "mirror_instance.txt"
local nonce = string.format("%d%06d", os.time(), math.random(0, 999999))
local beat_in = 0.0
local other_seen = -math.huge
local warned = false

function instance.duplicate() return os.time() - other_seen <= 8 end

function instance.tick(dt, on_found)
    beat_in = beat_in - dt
    if beat_in > 0 then return end
    beat_in = 2.0
    local s = fs.read(FILE)
    local n, t = (s or ""):match("^(%d+) (%d+)")
    if n and n ~= nonce and os.time() - (tonumber(t) or 0) <= 6 then
        other_seen = os.time()
        if not warned then
            warned = true
            log.warn("instance: this game install is running TWICE (same folder, same saves) - co-op joining is "
                .. "blocked in this setup; use the separate guest install for one-PC tests")
            if on_found then on_found() end
        end
    end
    fs.write(FILE, nonce .. " " .. os.time() .. "\n")
end

return instance
