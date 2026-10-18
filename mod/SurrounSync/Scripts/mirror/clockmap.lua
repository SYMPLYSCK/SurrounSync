-- Puts the other game's updates on our clock by when they were sent, and picks the smoothing
-- delay from how evenly they arrive.

local clockmap = {}
clockmap.__index = clockmap

local WINDOW = 90

function clockmap.new(min_d, max_d, start)
    return setmetatable({ min_d = min_d, max_d = max_d, d = start or max_d, need = {}, ni = 0,
                          off = nil, last_sent = nil, last_place = nil, late_sum = 0.0, late_n = 0 }, clockmap)
end

function clockmap:place(sent, now)
    if not sent then return nil end
    if self.last_sent and (sent < self.last_sent - 1.0 or sent > self.last_sent + 30.0) then self.off = nil end
    local sample = now - sent
    if not self.off or sample < self.off or sample > self.off + 0.5 then self.off = sample
    else self.off = self.off + (sample - self.off) * 0.01 end
    local late = sample - self.off
    local gap = self.last_sent and math.max(0, sent - self.last_sent) or 0
    if not self.last_sent or sent > self.last_sent then
        self.ni = self.ni % WINDOW + 1
        self.need[self.ni] = late + gap
        self.late_sum, self.late_n = self.late_sum + late, self.late_n + 1
    end
    self.last_sent = math.max(self.last_sent or sent, sent)
    local t = sent + self.off
    if self.last_place and t <= self.last_place then return nil end
    if t > now then t = now end
    self.last_place = t
    return t
end

function clockmap:percentile(q)
    local n = #self.need
    if n == 0 then return nil end
    local s = {}
    for i = 1, n do s[i] = self.need[i] end
    table.sort(s)
    return s[math.max(1, math.min(n, math.ceil(q * n)))]
end

function clockmap:delay(dt)
    self.target_in = (self.target_in or 0) - dt
    if self.target_in <= 0 then
        self.target_in = 0.25
        local p = self:percentile(0.95)
        if p then self.target = math.max(self.min_d, math.min(self.max_d, p + 0.015)) end
        local m = self:percentile(0.75)
        if m then self.near = math.max(0.04, math.min(self.max_d, m + 0.01)) end
    end
    local tgt = self.target or self.d
    local k = tgt > self.d and math.min(1, dt * 8) or math.min(1, dt * 0.5)
    self.d = self.d + (tgt - self.d) * k
    return self.d
end

function clockmap:near_delay() return math.min(self.d, self.near or self.d) end

function clockmap:report()
    local avg = self.late_n > 0 and (self.late_sum / self.late_n * 1000) or 0
    self.late_sum, self.late_n = 0.0, 0
    return avg, self.d * 1000
end

return clockmap
