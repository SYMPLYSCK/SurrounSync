-- Pose packets: the link keeps only the newest pose at every hop, so a slow frame on either side
-- loses samples. Each packet also carries the previous few; the reader plays back every one it hasn't seen.

local posepack = {}
posepack.__index = posepack

function posepack.new(keep) return setmetatable({ keep = keep or 2, hist = {} }, posepack) end

function posepack:pack(seq, line)
    local parts = { line }
    for i = #self.hist, 1, -1 do parts[#parts + 1] = self.hist[i].seq .. " " .. self.hist[i].line end
    self.hist[#self.hist + 1] = { seq = seq, line = line }
    if #self.hist > self.keep then table.remove(self.hist, 1) end
    return table.concat(parts, "\t")
end

-- The poses in a packet newer than `after` (nil = all), oldest first; the packet's own pose is `live`.
function posepack.unpack(pseq, payload, after)
    local cur, extra = payload:match("^([^\t]*)\t?(.*)$")
    local out = {}
    for part in extra:gmatch("[^\t]+") do
        local s, line = part:match("^(%d+) (.*)$")
        s = tonumber(s)
        if s and s < pseq and (not after or s > after) then out[#out + 1] = { seq = s, line = line } end
    end
    table.sort(out, function(a, b) return a.seq < b.seq end)
    if not after or pseq > after then out[#out + 1] = { seq = pseq, line = cur, live = true } end
    return out
end

return posepack
