-- Connection quality shown on the other player's name tag.

local events = require("mirror.events")
local link = require("mirror.link")

local netq = {}

local pings = events.new("ping", 8, 10)
local next_id, ping_in = 0, 0.0
local rtt = nil
local rtt_at = nil
local age = math.huge

local function ms() return os.clock() * 1000.0 end

-- The name tag shows the network's own round trip, measured by the connectors between themselves. The
-- game-to-game trip below also counts both games' frames and the file hand-offs (and every loading stall).
local net_rtt, net_in = nil, 0.0
local function read_net_rtt()
    local s = link.status() or ""
    local r = tonumber(s:match("rtt (%d+) ms"))
    net_rtt = r
end

function netq.tick(dt, update_age)
    age = update_age or math.huge
    net_in = net_in - dt
    if net_in <= 0 then net_in = 2.0; pcall(read_net_rtt) end
    ping_in = ping_in - dt
    if ping_in <= 0 then
        ping_in = 2.0
        next_id = next_id + 1
        pings:send(string.format("q %d %.1f", next_id, ms()))
    end
    pings:pump(function(p)
        local k, id, t = p:match("^(%a) (%d+) (%S+)$")
        if k == "q" then
            pings:send(string.format("a %s %s", id, t))
        elseif k == "a" then
            local r = ms() - (tonumber(t) or ms())
            if r >= 0 and r < 10000 then
                rtt = rtt and (rtt * 0.7 + r * 0.3) or r
                rtt_at = os.clock()
            end
        end
    end)
end

function netq.status()
    local r = (rtt_at and os.clock() - rtt_at < 10) and rtt or nil
    -- graded by the number the tag shows (the network one when known): a tag read "40 ms" in red when the colour
    -- came from the game-to-game time (frames + file hand-offs)
    local shown = net_rtt or r
    local state
    if age == math.huge then state = "unknown"
    elseif age > 5 then state = "lost"
    elseif age > 1.5 or (shown and shown > 900) then state = "poor"
    elseif age > 0.5 or (shown and shown > 400) then state = "moderate"
    else state = "good" end
    return { state = state, rtt = r, net = net_rtt }
end

local COLOR = {
    good = { R = 0.55, G = 1.0, B = 0.55, A = 1 }, moderate = { R = 1.0, G = 0.85, B = 0.35, A = 1 },
    poor = { R = 1.0, G = 0.45, B = 0.35, A = 1 }, lost = { R = 0.6, G = 0.6, B = 0.6, A = 1 },
    unknown = { R = 1, G = 1, B = 1, A = 1 },
}
function netq.tag(name)
    local s = netq.status()
    local shown = s.net or s.rtt
    local extra = s.state == "lost" and " · no signal" or (shown and string.format(" · %d ms", math.floor(shown + 0.5)) or "")
    return name .. extra, COLOR[s.state]
end

function netq.reset() rtt, rtt_at, age, net_rtt = nil, nil, math.huge, nil end

return netq
