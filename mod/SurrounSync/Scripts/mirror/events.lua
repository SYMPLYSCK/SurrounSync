-- A small ordered message channel on top of the link (each message delivered once).
--
-- Plain channels drop a message older than max_age seconds (combat / cosmetic: late is wrong).
-- Reliable channels (events.reliable: trades, builds, loot) never expire a message because of a pause
-- or a link stall - a lost "picked up" means a duplicate item. They skip only messages stamped before
-- the cut: the host's save for the current join (that save already holds them), or this game's start
-- before any join. The guest holds them unread while it loads into the host's world, and the receiver
-- acks what it read so the sender keeps everything unread instead of the newest `keep` only.

local link = require("mirror.link")
local log = require("mirror.log")

local events = {}
events.__index = events

local epoch = tostring(os.time())
local cut = os.time() - 5        -- my clock; reliable messages stamped before it are skipped
local hold = nil                 -- fn: true while reliable messages must stay unread (guest joining)
-- (a guest who chose WAIT while the host was gone kept looting: its takes must still be there when the host is back;
-- once a new join starts, older ones are skipped by the cut anyway)
local MAX, UNREAD_S = 512, 1800

local reliable = {}          -- name -> channel (reliable channels only)
local acked = {}             -- name -> highest id of my epoch the other game has read
local acks_dirty, acks_read_at, acks_sent_at = false, -100, -100

function events.new(name, keep, max_age)
    return setmetatable({ name = name, keep = keep or 32, max_age = max_age or 3,
                          next_id = 0, recent = {}, dirty = false, seen = {} }, events)
end

-- keep: how many messages stay when the other game doesn't read them (not connected / at home)
function events.reliable(name, keep)
    local ch = events.new(name, keep or 64, nil)
    ch.max_age, ch.sure, ch.ids = nil, true, {}
    reliable[name] = ch
    return ch
end

function events.set_cut(t) cut = t end
function events.set_hold(fn) hold = fn end

local function read_acks()
    local t = os.clock()
    if t - acks_read_at < 0.2 then return end
    acks_read_at = t
    local body = link.get_blob("acks")
    if not body then return end
    for name, ep, id in body:gmatch("(%S+) (%S+) (%d+)") do
        if ep == epoch then acked[name] = tonumber(id) end
    end
end

local function send_acks()
    local t = os.clock()
    if not acks_dirty or t - acks_sent_at < 0.5 then return end
    acks_dirty, acks_sent_at = false, t
    local out = {}
    for name, ch in pairs(reliable) do
        if ch.last_ep then out[#out + 1] = name .. " " .. ch.last_ep .. " " .. ch.seen[ch.last_ep] end
    end
    table.sort(out)
    link.put_blob("acks", table.concat(out, "\n"))
end

local function drop_oldest(self)
    table.remove(self.recent, 1)
    if not self.ids then return end
    local e = table.remove(self.ids, 1)
    return e.id > (acked[self.name] or 0) and e or nil
end

function events:send(payload)
    self.next_id = self.next_id + 1
    self.recent[#self.recent + 1] = string.format("%s %d %d %s", epoch, self.next_id, os.time(), payload)
    if not self.ids then
        if #self.recent > self.keep then drop_oldest(self) end
    else
        local now = os.clock()
        self.ids[#self.ids + 1] = { id = self.next_id, t = now }
        if #self.recent > MAX and drop_oldest(self) then
            log.every("events.over." .. self.name, 10, "events: " .. self.name .. " has more unread messages than it keeps - the oldest is lost")
        end
        -- nobody has read the oldest for minutes (no other game, or it sits at home): keep only a few
        while #self.recent > self.keep and now - self.ids[1].t > UNREAD_S do drop_oldest(self) end
    end
    self.dirty = true
end

-- How many messages on reliable channels this game sent that the other game hasn't confirmed reading yet (a guest
-- that went home keeps the link until this is 0: a take the host never read would leave the item on both sides).
function events.unconfirmed()
    read_acks()
    local n = 0
    for name, ch in pairs(reliable) do
        local a = acked[name] or 0
        for _, e in ipairs(ch.ids) do if e.id > a then n = n + 1 end end
    end
    return n
end

-- drop what the other game has read already (reliable channels)
function events:trim()
    local a = acked[self.name]
    if not a then return end
    local n = 0
    while self.ids[n + 1] and self.ids[n + 1].id <= a do n = n + 1 end
    if n == 0 then return end
    table.move(self.recent, n + 1, #self.recent + n, 1)
    table.move(self.ids, n + 1, #self.ids + n, 1)
end

function events:pump(fn)
    if self.sure then read_acks() end
    if self.dirty then
        self.dirty = false
        if self.sure then self:trim() end
        link.put_blob(self.name, table.concat(self.recent, "\n"))
    end
    -- unread blobs stay: the next read gets the newest body with everything not yet trimmed
    local body = not (self.sure and hold and hold()) and link.get_blob(self.name)
    if body then
        for line in body:gmatch("[^\n]+") do
            local ep, id, stamp, payload = line:match("^(%S+) (%d+) (%d+) (.*)$")
            id = tonumber(id)
            local last = self.seen[ep]
            if id and id > (last or 0) then
                self.seen[ep] = id
                local age = link.peer_age(tonumber(stamp))
                if self.sure then
                    self.last_ep, acks_dirty = ep, true
                    if last and id > last + 1 then
                        log.every("events.gap." .. self.name, 10, string.format("events: %s missed %d message(s)", self.name, id - last - 1))
                    end
                    if age <= os.time() - cut + 1 then fn(payload) end
                elseif age <= self.max_age then
                    fn(payload)
                end
            end
        end
    end
    if self.sure then send_acks() end
end

return events
