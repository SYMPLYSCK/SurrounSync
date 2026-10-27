-- Realms: shared worlds kept on the Realms server between sessions. This is the mod's side of the store:
-- it talks to the bridge (bridge/Realms.cs) through commands and mirror_realms.txt, decides what a Realm
-- bundle holds, checks every downloaded world before anything uses it, and keeps this PC's copies:
--   <link dir>\Saved\SurrounSyncRealms\<id>\
--     world\       newest world this PC has seen (+ head.txt: its generation)
--     character\   my character in this Realm (only my own game writes it)
--     up\ down\    the bridge's upload / download folders
-- The bridge keeps the member key and lease token next to them; the mod never reads those.

local log = require("mirror.log")
local link = require("mirror.link")
local fs = require("mirror.fs")
local savefs = require("mirror.savefs")
local slotguard = require("mirror.slotguard")
local backups = require("mirror.backups")

local realm = {}

local L = backups.LAYOUT
realm.WORLD = { "Level.sav", "General.sav", "Difficulties.sav", "Slot.sav", "Thumb.sav" }
-- the mod's own files that belong to a world, not to a PC (bed names, death bag owners, the host rules)
realm.SIDECARS = { "mirror_coop_bed_names.txt", "mirror_coop_bags.txt", "mirror_host_settings.txt" }
local MAX_SIDECAR = 256 * 1024
local MAX_STARTER_FILE = 16 * 1024 * 1024
local TIMEOUT = { download = 150, upload = 150 }
local DEFAULT_TIMEOUT = 40

local is_world, is_sidecar = {}, {}
local is_starter = {}   -- "starter_Player.sav" -> "Player.sav" (filled below with realm.CHARACTER)
local STARTER = "starter_"
for _, n in ipairs(realm.WORLD) do is_world[n] = true end
for _, n in ipairs(realm.SIDECARS) do is_sidecar[n] = true end

local cfg
function realm.configure(c) cfg = c end
function realm.enabled() return cfg ~= nil and cfg.realms ~= nil and cfg.realms.enabled == true end

function realm.valid_id(id) return type(id) == "string" and id:match("^[0-9A-HJKMNP-TV-Z]+$") ~= nil and #id == 10 end
function realm.code(id) return "R-" .. id:sub(1, 5) .. "-" .. id:sub(6) end

local function root() return link.dir() .. "\\Saved\\SurrounSyncRealms" end
function realm.dir(id) return root() .. "\\" .. id end
local function sub(id, name) return realm.dir(id) .. "\\" .. name end

local function ensure(path)
    if fs.dir_exists(path) then return true end
    return savefs.mkdir(path)
end

-- ---- bridge commands ----

local seq = (os.time() % 100000) * 1000
local pending = {}     -- seq -> { verb, cb, t }
local state = { realms = nil, list = {}, leases = {} }
local read_in = 0.0

-- cb(ok, words, text): words = the answer after "ok"/"fail" split on spaces; text = the same unsplit
function realm.send(verb, args, cb)
    seq = seq + 1
    local line = "realm " .. seq .. " " .. verb .. (args and args ~= "" and (" " .. args) or "")
    if not link.bridge_cmd((line:gsub("[\r\n]", " "))) then
        if cb then cb(false, { "no_bridge" }, "no_bridge the Steam connection isn't running") end
        return nil
    end
    pending[seq] = { verb = verb, cb = cb, t = 0.0, limit = TIMEOUT[verb] or DEFAULT_TIMEOUT }
    read_in = 0.0
    return seq
end

local function split(s)
    local w = {}
    for x in s:gmatch("%S+") do w[#w + 1] = x end
    return w
end

-- "realm <id> <role> <hostSteam|-> <gen> <members> <hostName|-> <name...>"
local function parse_realm(rest)
    local id, role, host, gen, members, host_name, name = rest:match("^(%S+) (%S+) (%S+) (%d+) (%d+) (%S+) ?(.*)$")
    if not id or not realm.valid_id(id) then return nil end
    return { id = id, role = role, host = host ~= "-" and host or nil, gen = tonumber(gen), members = tonumber(members),
             host_name = host_name ~= "-" and host_name:gsub("_", " ") or nil, name = name ~= "" and name or id,
             offline = role == "offline" }
end

local function read_state()
    local s = fs.read(link.dir() .. "\\mirror_realms.txt")
    if not s or s:sub(-4) ~= "END\n" then return nil end
    local t = { list = {}, leases = {}, ops = {} }
    for line in s:gmatch("[^\n]+") do
        local k, rest = line:match("^(%a+) (.*)$")
        if k == "realms" then
            t.realms = rest:match("^(%a+)")
            t.realms_at = tonumber(rest:match("^%a+ (%d+)") or "")
        elseif k == "realm" then
            local r = parse_realm(rest)
            if r then r.people = {}; t.list[#t.list + 1] = r end
        elseif k == "member" then
            -- "member <realmId> <owner|member> <steam|-> <lastSeen> <name...>", right after its realm line
            local id, role, steam, seen, name = rest:match("^(%S+) (%a+) (%S+) (%d+) ?(.*)$")
            local r = t.list[#t.list]
            if id and r and r.id == id then
                r.people[#r.people + 1] = { name = name ~= "" and name or "?", owner = role == "owner",
                                            steam = steam ~= "-" and steam or nil, seen = tonumber(seen) }
            end
        elseif k == "lease" then
            local id, st = rest:match("^(%S+) (%a+)$")
            if id then t.leases[id] = st end
        elseif k == "op" then
            local n, verb, res, more = rest:match("^(%d+) (%S+) (%a+) ?(.*)$")
            if n then t.ops[tonumber(n)] = { verb = verb, ok = res == "ok", text = more } end
        end
    end
    return t
end

local function deliver(n, p, ok, text)
    pending[n] = nil
    if not ok then log.warn(string.format("realm: %s failed: %s", p.verb, text)) end
    if p.cb then
        local good, err = pcall(p.cb, ok, split(text), text)
        if not good then log.error("realm: " .. p.verb .. " answer handler: " .. tostring(err)) end
    end
end

function realm.tick(dt)
    local any = next(pending) ~= nil
    read_in = read_in - dt
    if read_in > 0 then return end
    read_in = any and 0.25 or 2.0
    local t = read_state()
    if t then state.realms, state.realms_at, state.list, state.leases = t.realms, t.realms_at, t.list, t.leases end
    -- answers are handed out after the walk: a handler that sends the next request adds to `pending`, and a
    -- table that grows during pairs() fails ("invalid key to 'next'" in-game: claim_new -> upload)
    local ready = {}
    for n, p in pairs(pending) do
        p.t = p.t + (any and 0.25 or 2.0)
        local op = t and t.ops[n]
        if op then ready[#ready + 1] = { n, p, op.ok, op.text }
        elseif p.t > p.limit then ready[#ready + 1] = { n, p, false, "timeout no answer from the Steam connection" } end
    end
    table.sort(ready, function(a, b) return a[1] < b[1] end)
    for _, r in ipairs(ready) do deliver(r[1], r[2], r[3], r[4]) end
end

-- "on", "unset" (this version has no server address) or nil (the bridge isn't running)
function realm.service() return state.realms end
-- when the bridge last wrote its Realms file (unix s); it writes once at start, after dropping old commands
function realm.service_at() return state.realms_at end
function realm.list() return state.list end
function realm.find(id) for _, r in ipairs(state.list) do if r.id == id then return r end end return nil end
function realm.lease(id) return state.leases[id] end
function realm.busy() return next(pending) ~= nil end

-- ---- the local copy of the newest world ----

function realm.head(id)
    local s = fs.read(sub(id, "world") .. "\\head.txt")
    return tonumber(s and s:match("gen=(%d+)") or "") or 0
end

local function read_set(folder, names)
    local out = {}
    for _, n in ipairs(names) do
        local data = savefs.read(folder .. "\\" .. n)
        if data then out[n] = data end
    end
    return out
end

-- A world from the server: only known names, world files must be real saves, sidecars plain text. Files the
-- mod doesn't know are left out (a newer version may add some), never trusted.
-- The starter character (the Realm's New Game character, every member's first) is optional: a bad one is
-- left out, never the whole world.
local function starter_ok(starter)
    if not (starter["Player.sav"] and starter["Player.sav"]:sub(1, 4) == "EMSH") then return false end
    for _, data in pairs(starter) do if #data < 16 or #data > MAX_STARTER_FILE then return false end end
    return true
end

function realm.check_bundle(files)
    local world, side, starter = {}, {}, {}
    for name, data in pairs(files) do
        if is_world[name] then world[name] = data
        elseif is_sidecar[name] then
            if #data > MAX_SIDECAR or data:find("%z") then return nil, name .. " isn't a text file" end
            side[name] = data
        elseif is_starter[name] then starter[is_starter[name]] = data
        end
    end
    local ok, why = slotguard.check_world(world)
    if not ok then return nil, why end
    if not starter_ok(starter) then
        if next(starter) then log.warn("realm: the world's starter character is damaged - left out") end
        starter = nil
    end
    return world, side, starter
end

local function bundle_names()
    local names = {}
    for _, n in ipairs(realm.WORLD) do names[#names + 1] = n end
    for _, n in ipairs(realm.SIDECARS) do names[#names + 1] = n end
    for n in pairs(is_starter) do names[#names + 1] = n end
    return names
end

-- the bridge's download folder -> checked -> world\ (all files or none), returns the generation
function realm.accept_download(id, gen)
    local world, side, starter = realm.check_bundle(read_set(sub(id, "down"), bundle_names()))
    if not world then return nil, side end
    return realm.store_world(id, gen, world, side, starter)
end

-- starter: the starter character to keep with the world (nil = keep the one already there)
function realm.store_world(id, gen, world, side, starter)
    local dir = sub(id, "world")
    if not (ensure(realm.dir(id)) and ensure(dir)) then return nil, "can't make " .. dir end
    local set = {}
    for _, n in ipairs(realm.WORLD) do
        if world[n] then set[#set + 1] = { path = dir .. "\\" .. n, data = world[n] } end
    end
    for _, n in ipairs(realm.SIDECARS) do
        set[#set + 1] = { path = dir .. "\\" .. n, data = side and side[n] or "" }
    end
    for _, n in ipairs(starter and realm.CHARACTER or {}) do
        if starter[n] then set[#set + 1] = { path = dir .. "\\" .. STARTER .. n, data = starter[n] } end
    end
    set[#set + 1] = { path = dir .. "\\head.txt", data = "gen=" .. tostring(gen) .. "\n" }
    local ok, err = savefs.write_set(set)
    if not ok then return nil, err end
    -- a world without some optional file (Thumb.sav) must not keep the older one
    for _, n in ipairs(realm.WORLD) do if not world[n] then os.remove(dir .. "\\" .. n) end end
    for _, n in ipairs(starter and realm.CHARACTER or {}) do if not starter[n] then os.remove(dir .. "\\" .. STARTER .. n) end end
    return gen
end

-- the starter character by plain name (Player.sav ...), nil = none on this PC
function realm.starter(id)
    local dir, out = sub(id, "world"), {}
    for _, n in ipairs(realm.CHARACTER) do
        local data = savefs.read(dir .. "\\" .. STARTER .. n)
        if data then out[n] = data end
    end
    return starter_ok(out) and out or nil
end

-- the Realm's New Game character becomes its starter (CREATE, realmplay.lua)
function realm.store_starter(id, files)
    if not (files and starter_ok(files)) then return nil, "not a usable starter character" end
    local dir = sub(id, "world")
    if not (ensure(realm.dir(id)) and ensure(dir)) then return nil, "can't make " .. dir end
    local set = {}
    for _, n in ipairs(realm.CHARACTER) do
        if files[n] then set[#set + 1] = { path = dir .. "\\" .. STARTER .. n, data = files[n] } end
    end
    local ok, err = savefs.write_set(set)
    if not ok then return nil, err end
    for _, n in ipairs(realm.CHARACTER) do if not files[n] then os.remove(dir .. "\\" .. STARTER .. n) end end
    return true
end

-- the world the next session starts from: { files = world files, side = sidecars, gen }
function realm.world(id)
    local dir = sub(id, "world")
    local world = read_set(dir, realm.WORLD)
    if not world["Level.sav"] then return nil end
    local side = read_set(dir, realm.SIDECARS)
    return { files = world, side = side, gen = realm.head(id) }
end

-- world files + sidecars into the bridge's upload folder (only these: the bridge sends whatever is there)
function realm.stage_upload(id, world, side)
    local ok, why = slotguard.check_world(world)
    if not ok then return nil, why end
    local dir = sub(id, "up")
    if not ensure(dir) then return nil, "can't make " .. dir end
    for _, n in ipairs(bundle_names()) do os.remove(dir .. "\\" .. n) end
    for name, data in pairs(world) do
        if not fs.write(dir .. "\\" .. name, data) then return nil, "can't write " .. name end
    end
    -- (the server keeps only the newest bundle: the starter character goes up every time)
    for n, data in pairs(realm.starter(id) or {}) do
        if not fs.write(dir .. "\\" .. STARTER .. n, data) then return nil, "can't write the starter " .. n end
    end
    for _, n in ipairs(realm.SIDECARS) do
        local data = side and side[n]
        if data and data ~= "" and not fs.write(dir .. "\\" .. n, data) then return nil, "can't write " .. n end
    end
    return true
end

-- the sidecars of the Realm I host right now: the mod's modules read and write them here (realmplay.lua)
function realm.live_dir(id) return sub(id, "live") end

function realm.open_live(id, side)
    local dir = sub(id, "live")
    if not (ensure(realm.dir(id)) and ensure(dir)) then return nil, "can't make " .. dir end
    for _, n in ipairs(realm.SIDECARS) do
        if not fs.write(dir .. "\\" .. n, side and side[n] or "") then return nil, "can't write " .. n end
    end
    return true
end

function realm.read_live(id) return read_set(sub(id, "live"), realm.SIDECARS) end

-- ---- my character in a Realm ----
-- stored by file name: Player.sav, PlayerInfo.sav and the slot sidecars without the slot name (_SDQuests.sav ...)

realm.CHARACTER = {}
for _, f in ipairs(L.player) do realm.CHARACTER[#realm.CHARACTER + 1] = f end
for _, x in ipairs(L.sidecars) do realm.CHARACTER[#realm.CHARACTER + 1] = x end
for _, n in ipairs(realm.CHARACTER) do is_starter[STARTER .. n] = n end

function realm.char_dir(id) return sub(id, "character") end
function realm.has_character(id) return savefs.exists(sub(id, "character") .. "\\Player.sav") end

-- nil = no character yet (the first visit makes a fresh one)
function realm.character(id)
    local files = read_set(sub(id, "character"), realm.CHARACTER)
    return files["Player.sav"] and files or nil
end

-- all files or none; a file the new character doesn't have is removed afterwards
function realm.store_character(id, files)
    if not (files and files["Player.sav"]) then return nil, "no character to store" end
    local dir = sub(id, "character")
    if not (ensure(realm.dir(id)) and ensure(dir)) then return nil, "can't make " .. dir end
    local set = {}
    for _, n in ipairs(realm.CHARACTER) do
        if files[n] then set[#set + 1] = { path = dir .. "\\" .. n, data = files[n] } end
    end
    local ok, err = savefs.write_set(set)
    if not ok then return nil, err end
    for _, n in ipairs(realm.CHARACTER) do if not files[n] then os.remove(dir .. "\\" .. n) end end
    return true
end

-- a session that ended without reaching the server (crash, offline): its world waits here for the next host
-- turn on top of generation `base`; uploaded only if the Realm is still at that generation then
function realm.stash_pending(id, base, world, side)
    local dir = sub(id, "pending")
    if not (ensure(realm.dir(id)) and ensure(dir)) then return nil, "can't make " .. dir end
    local set = {}
    for name, data in pairs(world) do set[#set + 1] = { path = dir .. "\\" .. name, data = data } end
    for _, n in ipairs(realm.SIDECARS) do set[#set + 1] = { path = dir .. "\\" .. n, data = side and side[n] or "" } end
    set[#set + 1] = { path = dir .. "\\base.txt", data = "gen=" .. tostring(base) .. "\n" }
    return savefs.write_set(set)
end

function realm.pending(id)
    local dir = sub(id, "pending")
    local s = fs.read(dir .. "\\base.txt")
    local base = tonumber(s and s:match("gen=(%d+)") or "")
    if not base then return nil end
    local world = read_set(dir, realm.WORLD)
    if not world["Level.sav"] then return nil end
    return { base = base, files = world, side = read_set(dir, realm.SIDECARS) }
end

function realm.drop_pending(id)
    local dir = sub(id, "pending")
    os.remove(dir .. "\\base.txt")
    for _, n in ipairs(realm.WORLD) do os.remove(dir .. "\\" .. n) end
    for _, n in ipairs(realm.SIDECARS) do os.remove(dir .. "\\" .. n) end
end

return realm
