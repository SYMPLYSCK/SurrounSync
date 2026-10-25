-- The host's game settings (CO-OP tab -> gear): saved on this PC and sent to the guest, whose
-- shared world follows them. Outside co-op your own settings apply to your own world.

local log = require("mirror.log")
local link = require("mirror.link")
local notify = require("mirror.notify")

local hostrules = {}

local FILE = "\\mirror_host_settings.txt"

-- key, label, what ON does (shown under the option), default
hostrules.LIST = {
    { key = "pvp", label = "PVP", hint = "Players can hurt each other.", default = false },
    { key = "itemclean", label = "ITEM CLEANUP", hint = "Items dropped on the ground vanish after 20 minutes (death bags stay).",
      default = false },
    { key = "loadsplit", label = "LOAD SPLITTING (EXPERIMENTAL)", hint = "When you're far apart, your friend's PC runs the zombies around them instead of yours.",
      default = false },
}

local mine = {}
local peer = {}
local peer_raw = ""
local sent, sent_to = nil, {}
local role_fn = function() return nil end

local function load()
    for _, o in ipairs(hostrules.LIST) do mine[o.key] = o.default end
    local f = io.open(link.dir() .. FILE, "rb")
    local s = f and f:read("*a") or ""
    if f then f:close() end
    for k, v in s:gmatch("(%w+)%s+(%w+)") do
        if mine[k] ~= nil then mine[k] = v == "on" end
    end
end

local function save()
    local f = io.open(link.dir() .. FILE, "wb")
    if not f then return end
    for _, o in ipairs(hostrules.LIST) do f:write(o.key, " ", mine[o.key] and "on" or "off", "\n") end
    f:close()
end

local function encode(t)
    local parts = {}
    for _, o in ipairs(hostrules.LIST) do parts[#parts + 1] = o.key .. " " .. (t[o.key] and 1 or 0) end
    return table.concat(parts, " ")
end

local function read_peer()
    local body = link.get_blob("rules")
    if body and body ~= peer_raw then
        peer_raw = body
        peer = {}
        for k, v in body:gmatch("(%w+) (%d)") do peer[k] = v == "1" end
    end
end

-- My own value (what I host with, and what my own world uses outside co-op).
function hostrules.mine(key) return mine[key] == true end

-- The value for the world I'm in: a guest follows the host's, everyone else uses their own.
function hostrules.get(key)
    if role_fn() == "guest" then read_peer(); return peer[key] == true end
    return mine[key] == true
end

function hostrules.can_edit() return role_fn() ~= "guest" end

function hostrules.toggle(key)
    if not hostrules.can_edit() then
        notify.show("Only the host can change these settings.", "info")
        return
    end
    if mine[key] == nil then return end
    mine[key] = not mine[key]
    save()
    for _, o in ipairs(hostrules.LIST) do
        if o.key == key then
            notify.show(o.label .. (mine[key] and " on: " .. o.hint or " off."), "info")
        end
    end
    log.info("hostrules: " .. key .. " " .. (mine[key] and "on" or "off"))
end

-- Rows for the settings page.
function hostrules.rows()
    local out = {}
    for _, o in ipairs(hostrules.LIST) do
        out[#out + 1] = { key = o.key, label = o.label, hint = o.hint, on = hostrules.get(o.key) }
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

function hostrules.init(role_getter)
    role_fn = role_getter or role_fn
    load()
    local on = {}
    for _, o in ipairs(hostrules.LIST) do if mine[o.key] then on[#on + 1] = o.key end end
    log.info("hostrules: my settings: " .. (#on > 0 and table.concat(on, ", ") or "all off"))
end

return hostrules
