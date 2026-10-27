-- The host's game settings (CO-OP tab -> gear -> HOST RULES): saved on this PC and sent to every guest,
-- whose shared world follows them. Outside co-op your own settings apply to your own world.

local log = require("mirror.log")
local link = require("mirror.link")
local notify = require("mirror.notify")

local hostrules = {}

local FILE = "\\mirror_host_settings.txt"
local ONOFF = { { "off", "OFF" }, { "on", "ON" } }

-- key, label, hint (one line under the option), values ({ value, button text }; on/off when left out), default
hostrules.LIST = {
    { key = "pvp", label = "PVP", hint = "Players can hurt each other.", default = "off" },
    { key = "itemclean", label = "ITEM CLEANUP", hint = "Dropped items vanish after this long (death bags stay).",
      values = { { "off", "OFF" }, { "10", "10 MIN" }, { "20", "20 MIN" }, { "40", "40 MIN" } }, default = "off" },
    { key = "loadsplit", label = "LOAD SPLITTING", hint = "Experimental: far apart, a friend's PC runs the zombies near them.",
      default = "off" },
    { key = "players", label = "MAX PLAYERS", hint = "How many players fit in your world (you included).",
      values = { { "2", "2" }, { "3", "3" }, { "4", "4" } }, default = "4" },
    { key = "joins", label = "JOIN REQUESTS", hint = "Who gets in without you pressing ACCEPT.",
      values = { { "ask", "ASK ME" }, { "friends", "FRIENDS IN" }, { "all", "ALL IN" } }, default = "ask" },
    { key = "teleport", label = "TELEPORTS", hint = "Players can use /goto and /bring.", default = "on" },
    { key = "weather", label = "GUEST WEATHER", hint = "Guests can change the shared weather.", default = "on" },
}

local by_key = {}
for _, o in ipairs(hostrules.LIST) do o.values = o.values or ONOFF; by_key[o.key] = o end

local mine = {}
for _, o in ipairs(hostrules.LIST) do mine[o.key] = o.default end
local peer = {}
local peer_raw = ""
local sent, sent_to = nil, {}
local role_fn = function() return nil end

local function valid(o, v)
    for _, x in ipairs(o.values) do if x[1] == v then return true end end
    return false
end

-- my own settings file, or a hosted Realm's (hostrules.use_file)
local own_file = function() return link.dir and (link.dir() .. FILE) end
local file = own_file

local function load()
    for _, o in ipairs(hostrules.LIST) do mine[o.key] = o.default end
    local p = file()
    local f = p and io.open(p, "rb")
    local s = f and f:read("*a") or ""
    if f then f:close() end
    for k, v in s:gmatch("(%w+)%s+(%w+)") do
        local o = by_key[k]
        if o and valid(o, v) then mine[k] = v
        elseif o and v == "on" and o.key == "itemclean" then mine[k] = "20" end   -- (the old on/off file)
    end
end

local function save()
    local p = file()
    local f = p and io.open(p, "wb")
    if not f then return end
    for _, o in ipairs(hostrules.LIST) do f:write(o.key, " ", mine[o.key], "\n") end
    f:close()
end

local function encode(t)
    local parts = {}
    for _, o in ipairs(hostrules.LIST) do parts[#parts + 1] = o.key .. " " .. t[o.key] end
    return table.concat(parts, " ")
end

local function read_peer()
    local body = link.get_blob("rules")
    if body and body ~= peer_raw then
        peer_raw = body
        peer = {}
        for k, v in body:gmatch("(%w+) (%w+)") do peer[k] = v end
    end
end

-- The value for the world I'm in: a guest follows the host's, everyone else uses their own.
function hostrules.value(key)
    local o = by_key[key]
    if not o then return nil end
    if role_fn() == "guest" then
        read_peer()
        local v = peer[key]
        return (v and valid(o, v)) and v or o.default
    end
    return mine[key]
end

-- My own value (what I host with, and what my own world uses outside co-op).
function hostrules.my_value(key) return mine[key] end
function hostrules.mine(key) local v = mine[key]; return v ~= nil and v ~= "off" end
function hostrules.get(key) local v = hostrules.value(key); return v ~= nil and v ~= "off" end

function hostrules.can_edit() return role_fn() ~= "guest" end

local function label_of(o, v)
    for _, x in ipairs(o.values) do if x[1] == v then return x[2] end end
    return tostring(v)
end

-- The settings page's button: the next value.
function hostrules.toggle(key)
    if not hostrules.can_edit() then
        notify.show("Only the host can change these settings.", "info")
        return
    end
    local o = by_key[key]
    if not o then return end
    local n = 1
    for i, x in ipairs(o.values) do if x[1] == mine[key] then n = i % #o.values + 1 end end
    mine[key] = o.values[n][1]
    save()
    log.info("hostrules: " .. key .. " " .. mine[key])
end

-- Rows for the settings page.
function hostrules.rows()
    local out = {}
    for _, o in ipairs(hostrules.LIST) do
        out[#out + 1] = { key = o.key, label = o.label, hint = o.hint, text = label_of(o, hostrules.value(o.key)) }
    end
    return out
end

function hostrules.tick()
    if role_fn() == "host" then
        local s = encode(mine)
        if s ~= sent then sent, sent_to = s, {} end
        -- every guest's link (more than two players: peers.lua), also the ones that start later
        require("mirror.peers").each("mirror.link", function(l, inst)
            local k = inst and inst.tag or "main"
            if not sent_to[k] then sent_to[k] = true; l.put_blob("rules", s) end
        end)
    else
        sent, sent_to = nil, {}
    end
end

-- path = a Realm's settings file while hosting it (realmplay.lua), nil = my own again
function hostrules.use_file(path)
    file = path and function() return path end or own_file
    load()
    log.info("hostrules: " .. (path and "the Realm's" or "my") .. " settings: " .. encode(mine))
end
function hostrules.own_file() return own_file() end

function hostrules.init(role_getter)
    role_fn = role_getter or role_fn
    load()
    log.info("hostrules: my settings: " .. encode(mine))
end

return hostrules
