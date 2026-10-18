-- Buffer of timestamped poses, played back with interpolation.

local track = {}
track.__index = track

function track.new(keep_seconds)
    return setmetatable({ s = {}, head = 0, tail = 1, keep = keep_seconds or 3.0 }, track)
end

function track:push(t, pose)
    pose.t = t
    self.head = self.head + 1
    self.s[self.head] = pose
    while self.tail < self.head and t - self.s[self.tail].t > self.keep do
        self.s[self.tail] = nil
        self.tail = self.tail + 1
    end
end

function track:empty() return self.head < self.tail end
function track:newest() return self.s[self.head] end

function track:at(t, util, max_extrap)
    if self:empty() then return nil end
    local s, lo, hi = self.s, self.tail, self.head
    if t <= s[lo].t then return s[lo] end
    local r = self.r
    if not r then r = { loc = {}, vel = {} }; self.r = r end
    if t >= s[hi].t then
        local n = s[hi]
        local e = math.min(t - n.t, max_extrap or 0.25)
        r.loc.X, r.loc.Y, r.loc.Z = n.loc.X + n.vel.X * e, n.loc.Y + n.vel.Y * e, n.loc.Z + n.vel.Z * e
        r.vel.X, r.vel.Y, r.vel.Z = n.vel.X, n.vel.Y, n.vel.Z
        r.yaw, r.crouch, r.falling, r.aim, r.t, r.stale = n.yaw, n.crouch, n.falling, n.aim, t, t - n.t
        r.sprint, r.move = n.sprint, n.move
        return r
    end
    local i = hi
    while i > lo + 1 and s[i - 1].t > t do i = i - 1 end
    local a, b = s[i - 1], s[i]
    local k = (t - a.t) / math.max(b.t - a.t, 1e-6)
    r.loc.X, r.loc.Y, r.loc.Z = util.lerp(a.loc.X, b.loc.X, k), util.lerp(a.loc.Y, b.loc.Y, k), util.lerp(a.loc.Z, b.loc.Z, k)
    r.vel.X, r.vel.Y, r.vel.Z = util.lerp(a.vel.X, b.vel.X, k), util.lerp(a.vel.Y, b.vel.Y, k), util.lerp(a.vel.Z, b.vel.Z, k)
    r.yaw, r.crouch, r.falling, r.t, r.stale = util.lerp_angle(a.yaw, b.yaw, k), b.crouch, b.falling, t, 0
    r.sprint, r.move = b.sprint, b.move
    if b.aim and a.aim then
        local ra, ba, aa = r.aim_s, b.aim, a.aim
        if not ra then ra = { head_s = {} }; r.aim_s = ra end
        ra.combat, ra.ads, ra.hip, ra.melee, ra.lhand = ba.combat, ba.ads, ba.hip, ba.melee, ba.lhand
        ra.view_yaw = (aa.view_yaw and ba.view_yaw) and util.lerp_angle(aa.view_yaw, ba.view_yaw, k) or ba.view_yaw
        if aa.head and ba.head then
            ra.head_s.Yaw, ra.head_s.Roll = util.lerp(aa.head.Yaw, ba.head.Yaw, k), util.lerp(aa.head.Roll, ba.head.Roll, k)
            ra.head = ra.head_s
        else
            ra.head = ba.head
        end
        ra.pitch = util.lerp(aa.pitch, ba.pitch, k)
        r.aim = ra
    else
        r.aim = b.aim
    end
    return r
end

return track
