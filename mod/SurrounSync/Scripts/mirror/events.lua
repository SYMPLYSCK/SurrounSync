-- A small ordered message channel on top of the link (each message delivered once).

local link = require("mirror.link")

local events = {}
events.__index = events

local epoch = tostring(os.time())

function events.new(name, keep, max_age)
    return setmetatable({ name = name, keep = keep or 32, max_age = max_age or 3,
                          next_id = 0, recent = {}, dirty = false, seen = {} }, events)
end

function events:send(payload)
    self.next_id = self.next_id + 1
    self.recent[#self.recent + 1] = string.format("%s %d %d %s", epoch, self.next_id, os.time(), payload)
    if #self.recent > self.keep then table.remove(self.recent, 1) end
    self.dirty = true
end

function events:pump(fn)
    if self.dirty then
        self.dirty = false
        link.put_blob(self.name, table.concat(self.recent, "\n"))
    end
    local body = link.get_blob(self.name)
    if not body then return end
    for line in body:gmatch("[^\n]+") do
        local ep, id, stamp, payload = line:match("^(%S+) (%d+) (%d+) (.*)$")
        id = tonumber(id)
        if id and id > (self.seen[ep] or 0) then
            self.seen[ep] = id
            if link.peer_age(tonumber(stamp)) <= self.max_age then fn(payload) end
        end
    end
end

return events
