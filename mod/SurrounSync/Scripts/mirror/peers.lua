-- More than two players. The co-op modules were written for one other player; every further player gets
-- its own copy of them ("instance"), so each one keeps its own ghost, link, look, join and sync state:
--   host:  guest 1 uses the normal modules (the two-player files host/guest), guests 2 and 3 get a full copy
--          each (files to<slot>/from<slot>) - every guest has its own join, ghost and zombie snapshot.
--   guest: the host uses the normal modules; every other guest gets a "mate" copy of only the modules that
--          show a player (ghost, look, animations, shots, lights, name tag, PvP, voice, chat). Their world
--          changes reach us through the host's world. Mate traffic goes through the host's bridge.
-- Copies are loaded with their own chunk name ("...zombies.lua#to2"), so the hook / tick / key slots that
-- util and game key on the call site stay separate per copy. The bridge lists the players in mirror_roster.txt.

local log = require("mirror.log")

local peers = {}

-- One copy for the whole game, shared by every instance (UI, saves, settings, helpers).
local SHARED = {
    config = true, log = true, util = true, crumb = true, game = true, perf = true, settings = true, role = true,
    version = true, notify = true, menu = true, menu_backups = true, journal_tab = true, fs = true, savefs = true,
    slotguard = true, backups = true, beds = true, bedtags = true, names = true, jig = true, instance = true,
    loader = true, hostrules = true, itemclean = true, devtest = true, invdiag = true, probe = true, recorder = true,
    phase0 = true, peers = true, xp = true,
}
-- What a mate instance (another guest, seen from a guest) gets its own copy of; the rest is the host link's.
local PRESENCE = {
    link = true, link_file = true, events = true, phase1 = true, ghost = true, track = true, posepack = true,
    clockmap = true, anim = true, look = true, fire = true, lights = true, tactical = true, nametag = true,
    netq = true, pvp = true, save_guard = true, chat = true, voice = true, teleport = true, compat = true,
    throwables = true, vehicles = true, zombies = true, group = true,
}

local list = {}          -- out tag -> instance
local cfg, role, last_role
local order = {}         -- out tags in creation order
local shared_tables = {}

-- A table every instance sees (state that belongs to the player, not to one link: voice on/off, chat history).
function peers.shared(name, init)
    local t = shared_tables[name]
    if not t then t = init or {}; shared_tables[name] = t end
    return t
end

local function tagged_log(tag)
    -- looked up on use (and cached), so it follows whatever the log module has
    local p = {}
    -- log.every(key, secs, msg): keep the keys apart too
    p.every = function(key, secs, m, ...) return log.every(tag .. key, secs, "[" .. tag .. "] " .. tostring(m), ...) end
    return setmetatable(p, { __index = function(t, k)
        local v = log[k]
        if type(v) == "function" and k ~= "configure" then
            local w = function(m, ...) return v("[" .. tag .. "] " .. tostring(m), ...) end
            rawset(t, k, w)
            return w
        end
        return v
    end })
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function new_instance(tag, kind)
    local inst = { tag = tag, kind = kind, loaded = {} }
    local ilog = tagged_log(tag)
    local function ireq(name)
        local short = type(name) == "string" and name:match("^mirror%.(.+)$")
        if not short or SHARED[short] or (kind == "mate" and not PRESENCE[short]) then
            if short == "log" then return ilog end
            return require(name)
        end
        local m = inst.loaded[name]
        if m ~= nil then return m end
        -- (tests put stand-ins in package.preload: a fresh one per copy, like a file)
        local pre = package.preload[name]
        if pre then
            local r = pre(name, tag)
            if r == nil then r = true end
            inst.loaded[name] = r
            return r
        end
        local path = package.searchpath(name, package.path)
        local src = path and read_file(path)
        if not src then error("peers: can't find " .. name) end
        local env = setmetatable({ require = ireq }, { __index = _G })
        local chunk, err = load(src, "@" .. path .. "#" .. tag, "t", env)
        if not chunk then error("peers: " .. tostring(err)) end
        local r = chunk(name)
        if r == nil then r = true end
        inst.loaded[name] = r
        return r
    end
    inst.require = ireq
    return inst
end
peers._new_instance = new_instance

-- The module `name` ("mirror.ghost") of every running instance, the normal one first.
function peers.each(name, fn)
    local ok_main, main = pcall(require, name)
    if ok_main and main then fn(main, nil) end
    for _, tag in ipairs(order) do
        local inst = list[tag]
        local m = inst and inst.started and inst.loaded[name]
        if m and m ~= main then fn(m, inst) end
    end
end

-- Is obj any player's ghost here? (runs for every character's tick: no closures, no pcall)
local main_ghost
function peers.is_ghost(obj)
    main_ghost = main_ghost or require("mirror.ghost")
    if main_ghost.is(obj) then return true end
    for i = 1, #order do
        local inst = list[order[i]]
        local g = inst.started and inst.loaded["mirror.ghost"]
        if g and g ~= main_ghost and g.is(obj) then return true end
    end
    return false
end

function peers.ghost_list()
    local out = {}
    peers.each("mirror.ghost", function(g) local x = g.get(); if x then out[#out + 1] = x end end)
    return out
end

-- Locations of the other players' ghosts, except the instance `skip` (its own ghost).
function peers.ghost_locations(skip_ghost_module)
    local out = {}
    peers.each("mirror.ghost", function(g)
        if g ~= skip_ghost_module then local l = g.location(); if l then out[#out + 1] = l end end
    end)
    return out
end

-- Host: a world change one guest made, passed on to the other guests. Modules whose changes the host's own
-- hooks don't see when it applies them (spawned builds, drops, used-up nodes) call this from their message
-- handler: every OTHER copy of the module gets fn(copy). While it runs peers.relaying() is true, so a copy's
-- own "tell the others" code doesn't pass the same message on again.
local relaying = false
function peers.relaying() return relaying end
function peers.relay(name, self_mod, fn)
    if relaying or (role ~= "host") then return end
    relaying = true
    peers.each(name, function(m)
        if m ~= self_mod then
            local ok, err = pcall(fn, m)
            if not ok then log.every("peers.relay." .. name, 10, "peers: relay " .. name .. ": " .. tostring(err)) end
        end
    end)
    relaying = false
end
function peers.role() return role end

-- Is my ghost (location gl) nearer to `to` than the local player (pl) and every other player's ghost?
function peers.ghost_nearest(ghost_mod, gl, pl, to)
    local function d(a) return (a.X - to.X) ^ 2 + (a.Y - to.Y) ^ 2 + (a.Z - to.Z) ^ 2 end
    local mine = d(gl)
    if mine >= d(pl) then return false end
    for _, l in ipairs(peers.ghost_locations(ghost_mod)) do if d(l) < mine then return false end end
    return true
end

-- The main game's copy of a module (from inside a copy, require gives the copy's own)
function peers.main(name) return require(name) end

-- A table every copy of a module shares (peers is loaded once): name -> table
local shared_tables = {}
function peers.shared_table(name)
    local t = shared_tables[name]
    if not t then t = setmetatable({}, { __mode = "k" }); shared_tables[name] = t end
    return t
end

function peers.count() local n = 0; for _ in pairs(list) do n = n + 1 end; return n end
function peers.instances() local out = {}; for _, t in ipairs(order) do out[#out + 1] = list[t] end; return out end

local roster_text, read_in = nil, 0.0
local main_out = { host = "host", guest = "guest" }
-- player slots (host 0, guests 1-3) from the roster; without one, the two-player layout
local my_slot, main_slot
function peers.my_slot() return my_slot or (role == "guest" and 1 or 0) end
-- slot of the player a copy shows: out tag of its link (nil = the main link)
function peers.slot_of(out)
    if out and out ~= main_out[role] then
        local inst = list[out]
        return inst and inst.slot or tonumber(out:match("%d+$")) or 9
    end
    return main_slot or (role == "guest" and 0 or 1)
end

local function start_instance(p)
    local inst = list[p.out]
    if not inst then
        inst = new_instance(p.out, role == "host" and "host" or "mate")
        list[p.out] = inst
        order[#order + 1] = p.out
        log.info(string.format("peers: %s in slot %d (%s) - starting its own sync (%s)", p.name, p.slot, p.out, inst.kind))
    end
    if inst.started and inst.id == p.id then return end
    inst.id, inst.slot, inst.name = p.id, p.slot, p.name
    local ok, err = pcall(function()
        local phase1 = inst.require("mirror.phase1")
        phase1.init(cfg, inst.kind == "host" and "host" or "mate", p.id, { out = p.out, inn = p.inn })
        inst.phase1 = phase1
    end)
    if ok then inst.started = true else log.error("peers: couldn't start the sync for " .. p.name .. ": " .. tostring(err)) end
end

local function read_roster()
    local link = require("mirror.link")
    local s = read_file(link.dir() .. "\\mirror_roster.txt")
    if not s or s == roster_text or not s:find("END\n", 1, true) then return end
    roster_text = s
    local live = {}
    for line in s:gmatch("[^\n]+") do
        local o, st = line:match("^peer (%S+) %S+ %d+ %d+ (%S+)")
        if o and st ~= "silent" then live[o] = true end
    end
    -- a player who left (or went quiet for 20 s): their copy stops, which takes their ghost away;
    -- it starts again if they come back
    for _, tag in ipairs(order) do
        local inst = list[tag]
        if inst.started and not live[tag] then
            log.info("peers: " .. tostring(inst.name) .. " (" .. tag .. ") left - stopping their sync")
            if inst.phase1 then pcall(inst.phase1.stop) end
            inst.started = false
        end
    end
    for line in s:gmatch("[^\n]+") do
        local me = line:match("^me (%d+) ")
        if me then my_slot = tonumber(me) end
        local out, inn, slot, id, state, name = line:match("^peer (%S+) (%S+) (%d+) (%d+) (%S+) ?(.*)$")
        if out and out == main_out[role] then main_slot = tonumber(slot) end
        if out and out ~= main_out[role] and state ~= "silent" then
            start_instance({ out = out, inn = inn, slot = tonumber(slot), id = id, state = state, name = name ~= "" and name or id })
        end
    end
end

-- The bridge's player list -> instances. Called every frame by the main link (phase1) while co-op runs.
function peers.tick(dt)
    if not role then return end
    read_in = read_in - dt
    if read_in > 0 then return end
    read_in = 1.0
    local ok, err = pcall(read_roster)
    if not ok then log.every("peers.roster", 30, "peers: " .. tostring(err)) end
end

function peers.start(c, r)
    if r ~= "host" and r ~= "guest" then return end
    if last_role and last_role ~= r then
        -- other role, other kind of copies: new ones (their hook slots are keyed by tag, so nothing doubles up)
        peers.stop()
        list, order = {}, {}
    end
    cfg, role, last_role = c, r, r
    roster_text, read_in = nil, 0.0
end

function peers.stop()
    for _, tag in ipairs(order) do
        local inst = list[tag]
        if inst.started and inst.phase1 then pcall(inst.phase1.stop) end
        inst.started = false
    end
    role = nil
end

return peers
