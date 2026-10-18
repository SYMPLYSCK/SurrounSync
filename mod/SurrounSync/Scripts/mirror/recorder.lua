-- Pose recorder used by the offline ghost test.

local util = require("mirror.util")

local recorder = {}

local samples = {}
local head, tail = 0, 1
local now = 0.0
local keep = 10.0

function recorder.configure(buffer_seconds) keep = buffer_seconds end

function recorder.time() return now end

function recorder.push(dt, s)
    now = now + dt
    s.t = now
    head = head + 1
    samples[head] = s
    while tail < head and now - samples[tail].t > keep do
        samples[tail] = nil
        tail = tail + 1
    end
end

function recorder.count() return head - tail + 1 end

function recorder.at(t)
    if head < tail then return nil end
    if t <= samples[tail].t then return samples[tail] end
    if t >= samples[head].t then return samples[head] end
    local i = head
    while i > tail + 1 and samples[i - 1].t > t do i = i - 1 end
    local a, b = samples[i - 1], samples[i]
    local k = (t - a.t) / math.max(b.t - a.t, 1e-6)
    return {
        loc = { X = util.lerp(a.loc.X, b.loc.X, k), Y = util.lerp(a.loc.Y, b.loc.Y, k), Z = util.lerp(a.loc.Z, b.loc.Z, k) },
        yaw = util.lerp_angle(a.yaw, b.yaw, k),
        vel = { X = util.lerp(a.vel.X, b.vel.X, k), Y = util.lerp(a.vel.Y, b.vel.Y, k), Z = util.lerp(a.vel.Z, b.vel.Z, k) },
        crouch = b.crouch,
        t = t,
    }
end

return recorder
