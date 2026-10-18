-- File transport for the link (the bridge relays these files over Steam).

local link = {}

local dir
local me, peer
local last_seq = -1

local function path(name) return dir .. "\\mirror_link_" .. name .. ".txt" end

local base_dir
function link.configure(c)
    local base = (os.getenv("LOCALAPPDATA") or ".") .. "\\SurrounDead"
    base_dir = (c and c.link_dir) and (base .. "\\" .. c.link_dir) or base
end

function link.open(my_role)
    dir = base_dir or ((os.getenv("LOCALAPPDATA") or ".") .. "\\SurrounDead")
    me = my_role
    peer = (my_role == "host") and "guest" or "host"
    last_seq = -1
    return path(me), path(peer)
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

function link.get_blob(name)
    if not due(name) then return nil end
    local f = io.open(blob_path(name, peer), "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    if not s then return nil end
    if s:find("\r", 1, true) then s = s:gsub("\r\n", "\n") end
    local body = s:match("^(.*)\nEND\n$")
    if not body or body == blob_seen[name] then return nil end
    blob_seen[name] = body
    return body
end

function link.reset_blob(name) blob_seen[name] = nil; next_read[name] = nil end

function link.close()
    if me then os.remove(path(me)) end
end

return link
