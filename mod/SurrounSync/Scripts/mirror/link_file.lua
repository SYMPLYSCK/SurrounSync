-- File transport for the link (the bridge relays these files over Steam).

local link = {}

local dir
local me, peer
local last_seq = -1

local function path(name) return dir .. "\\mirror_link_" .. name .. ".txt" end

local base_dir
function link.configure(c)
    local base = require("mirror.localdir").get()
    base_dir = (c and c.link_dir) and (base .. "\\" .. c.link_dir) or base
end

-- tags (more than two players): { out = "to2", inn = "from2" } - the file names of this one other player
function link.open(my_role, tags)
    dir = base_dir or (require("mirror.localdir").get())
    me = tags and tags.out or my_role
    peer = tags and tags.inn or ((my_role == "host") and "guest" or "host")
    last_seq = -1
    return path(me), path(peer)
end

-- my own pose file and these blobs under my current tag, before switching roles: the new role reads exactly those
-- names (a guest who becomes host reads "_guest"), and they'd come back as the other player's
function link.remove_mine(names)
    if not (dir and me) then return end
    os.remove(path(me))
    for name in pairs(names or {}) do os.remove(dir .. "\\mirror_" .. name .. "_" .. me .. ".txt") end
end

local MAX_AGE = 5

function link.send(seq, line)
    local f = io.open(path(me), "wb")
    if not f then return false end
    f:write(string.format("%d %d %s END\n", seq, os.time(), line))
    f:close()
    return true
end

function link.poll()
    local f = io.open(path(peer), "rb")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    if not s then return nil end
    s = s:gsub("\r$", "")
    local seq, stamp, payload = s:match("^(%d+) (%d+) (.*) END$")
    seq, stamp = tonumber(seq), tonumber(stamp)
    if not seq or seq == last_seq then return nil end
    if os.time() - stamp > MAX_AGE then return nil end
    last_seq = seq
    return seq, payload
end

local blob_seen = {}
local function blob_path(name, who) return dir .. "\\mirror_" .. name .. "_" .. who .. ".txt" end

function link.put_blob(name, text)
    local f = io.open(blob_path(name, me), "wb")
    if not f then return false end
    f:write(text, "\nEND\n")
    f:close()
    return true
end

local SLOW = { look = true, hello = true, sky = true, life = true, where = true, light = true, world = true,
               doors = true, req = true, mods = true,
               cars = true, ride = true }
local FAST = { zombies = true, anim = true, fire = true, hits = true, zhits = true, dmg = true, hurt = true, impact = true,
               ping = true }
local next_read = {}
local function due(name)
    local t = os.clock()
    if t < (next_read[name] or 0) then return false end
    next_read[name] = t + ((SLOW[name] or name:sub(1, 5) == "file_") and 0.25 or (FAST[name] and 0.03 or 0.05))
    return true
end

-- The bridge keeps mirror_index_<peer>.txt: a counter per blob, bumped after each write. Read at most
-- once per frame, it lets get_blob skip opening blob files that didn't change. Without it (older
-- bridge) every blob is polled on its timer as before.
local index = { gen = {}, seen = {}, stale = {}, run = nil, at = -1, ok = false }
local function read_index()
    local t = os.clock()
    if t - index.at < 0.004 then return index.ok end
    index.at = t
    local f = io.open(blob_path("index", peer), "rb")
    if not f then index.ok = false; return false end
    local s = f:read("*a")
    f:close()
    if not s then return index.ok end
    if s:find("\r", 1, true) then s = s:gsub("\r\n", "\n") end
    if s:sub(-4) ~= "END\n" then return index.ok end
    local run = s:match("^v1 (%d+)\n")
    if not run then index.ok = false; return false end
    if run ~= index.run then index.run, index.seen, index.stale = run, {}, {} end
    local gen = index.gen
    for k in pairs(gen) do gen[k] = nil end
    for n, g in s:gmatch("\n(%S+) (%d+)") do gen[n] = g end
    index.ok = true
    return true
end

function link.get_blob(name)
    local indexed = read_index()
    local g = indexed and index.gen[name]
    if indexed then
        if g == nil or g == index.seen[name] then return nil end
        if SLOW[name] and not due(name) then return nil end
    elseif not due(name) then return nil end
    local f = io.open(blob_path(name, peer), "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    if not s then return nil end
    if s:find("\r", 1, true) then s = s:gsub("\r\n", "\n") end
    local body = s:match("^(.*)\nEND\n$")
    -- unchanged text under a new counter = the bridge's write isn't on disk yet: look again next frame,
    -- for up to 0.25 s (after that it really is the same text again)
    if not body or body == blob_seen[name] then
        if g then
            local t0 = index.stale[name]
            if not t0 then index.stale[name] = os.clock()
            elseif os.clock() - t0 > 0.25 then index.seen[name], index.stale[name] = g, nil end
        end
        return nil
    end
    if g then index.seen[name], index.stale[name] = g, nil end
    blob_seen[name] = body
    return body
end

function link.reset_blob(name) blob_seen[name] = nil; next_read[name] = nil; index.seen[name] = nil; index.stale[name] = nil end

function link.close()
    if me then os.remove(path(me)) end
end

return link
