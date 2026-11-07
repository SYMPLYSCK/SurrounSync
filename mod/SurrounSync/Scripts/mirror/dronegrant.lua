-- Who may fly the FPV drone that comes with SurrounSync. FPVDrone is sold on its own; the copy SurrounSync installs
-- (bundled.txt, FPVDrone's fpv/gate.lua) flies only while the UE4SS shared variable FPVDrone.allowed says so
-- (user 2026-11-03: "If others wanna use it make it so there's a permissions tab in the menu where they can only use
-- it if I give them permission, I wanna sell the mod separately").
--
-- The owner (adminfly.OWNER, SYMPLYSCK's Steam account) allows players in SETTINGS -> PERMISSIONS; the list is saved
-- on the owner's PC. Each link's drone.lua copy sends it to its player ("A id1 id2 ..." on the reliable channel
-- dronegrant) when it changes and every SEND_S; a player whose id is in a list that came from the owner's link may fly
-- for HOLD_S after it, so leaving the owner's game (or being taken off the list) lands the quad within seconds.
-- One copy per game (peers.lua SHARED). A Lua check keeps honest players out; whoever edits the files can take it out.
-- On top of the list, the owner's /fpv unlock and /fpv lock (user 2026-11-04: "lock and unlocks the FPV system for
-- everyone but myself"): everyone may fly ("A *"), or nobody ("A "), whoever the list names. The list is kept: /fpv list
-- goes back to it. Saved with it, so it holds until the owner changes it.

local log = require("mirror.log")

local dronegrant = {}

dronegrant.SHARED = "FPVDrone.allowed"
dronegrant.FILE = "SurrounSync_drone_grants.txt"
dronegrant.SEND_S = 5.0      -- the owner's list again this often
dronegrant.HOLD_S = 15.0     -- a player stays allowed this long after the last list that named them

local G = { list = nil, until_t = -math.huge, set = nil, heard = 0, said = nil, mode = nil }   -- mode: nil = the list, "open", "locked"

local function say(text, kind) pcall(function() require("mirror.notify").show(text, kind or "info", "dronegrant") end) end
local function adminfly() return require("mirror.adminfly") end
local function peers() return require("mirror.peers") end

local function path()
    local ok, dir = pcall(function() return require("mirror.localdir").get() end)
    return (ok and dir or ".") .. "\\" .. dronegrant.FILE
end

-- the owner's list: { {id=, name=}, ... } in the order allowed
local function load()
    if G.list then return G.list end
    G.list = {}
    local f = io.open(path(), "r")
    if not f then return G.list end
    for line in f:lines() do
        local id, name = line:match("^(%d+) ?(.*)$")
        if id then G.list[#G.list + 1] = { id = id, name = name ~= "" and name or id } end
        if line == "mode open" or line == "mode locked" then G.mode = line:sub(6) end
    end
    f:close()
    return G.list
end

local function save()
    local out = {}
    if G.mode then out[1] = "mode " .. G.mode .. "\n" end
    for _, p in ipairs(G.list) do out[#out + 1] = p.id .. " " .. p.name:gsub("[\r\n]", " ") .. "\n" end
    local f, err = io.open(path(), "w")
    if not f then log.error("dronegrant: couldn't save " .. path() .. ": " .. tostring(err)); return end
    f:write(table.concat(out))
    f:close()
end

local function find(id)
    for i, p in ipairs(load()) do if p.id == id then return i end end
    return nil
end

-- this game is the drone owner's (the permissions tab shows only there)
function dronegrant.owner()
    local ok, yes = pcall(function() return adminfly().is_owner() end)
    return ok and yes == true
end

local function allowed_id(id)
    load()
    if G.mode == "open" then return true end
    if G.mode == "locked" then return false end
    return find(id) ~= nil
end

function dronegrant.allowed(id) return allowed_id(tostring(id)) end

-- /fpv unlock, /fpv lock, /fpv list: "open", "locked" or nil
function dronegrant.set_mode(mode)
    if not dronegrant.owner() then return end
    load()
    G.mode = mode
    save()
    log.info("dronegrant: " .. (mode == "open" and "everyone may fly the FPV drone" or mode == "locked"
        and "nobody but the owner may fly the FPV drone" or "the permissions list decides who flies the FPV drone"))
    say(mode == "open" and "FPV drone unlocked for everyone. /fpv lock locks it."
        or mode == "locked" and "FPV drone locked: only you can fly it."
        or "FPV drone: your PERMISSIONS list decides who flies it again.")
end
function dronegrant.mode() load(); return G.mode end

-- the owner allows / stops allowing a player (key: their SteamID64; name: shown in the list)
function dronegrant.toggle(id, name)
    if not dronegrant.owner() then return end
    id = tostring(id)
    if id == dronegrant.PAGE_KEY then G.page = (G.page or 1) + 1; return end
    if not id:match("^%d+$") then return end
    load()
    if G.mode then
        say("The FPV drone is " .. (G.mode == "open" and "unlocked" or "locked") .. " for everyone. /fpv list goes back to this list.")
        return
    end
    local i = find(id)
    if i then
        log.info("dronegrant: " .. G.list[i].name .. " may no longer fly the FPV drone")
        table.remove(G.list, i)
    else
        local p = { id = id, name = name or id }
        for _, q in ipairs(peers().players()) do if q.id == id then p.name = q.name end end
        G.list[#G.list + 1] = p
        log.info("dronegrant: " .. p.name .. " may fly the FPV drone")
    end
    save()
end

-- the tab's rows: everyone in co-op with me, then everyone allowed who isn't
function dronegrant.rows()
    local rows, seen = {}, {}
    for _, p in ipairs(peers().players()) do
        if not seen[p.id] then
            seen[p.id] = true
            rows[#rows + 1] = { id = p.id, name = p.name, allowed = allowed_id(p.id), here = true }
        end
    end
    for _, p in ipairs(load()) do
        if not seen[p.id] then rows[#rows + 1] = { id = p.id, name = p.name, allowed = allowed_id(p.id), here = false } end
    end
    return rows
end

-- SETTINGS -> PERMISSIONS (journal_tab.lua): a settings row per player, key = their SteamID64
dronegrant.SUB = "Who may fly your FPV drone in co-op with you - saved on this PC."
dronegrant.EMPTY = "Nobody in co-op with you yet: the players who join you show up here."
-- (more players than the tab's rows: pages of ROWS - 1, the last row turns the page; the tab's row widgets as they
-- are, no new layout; audit 2026-11-03: the 13th allowed player was never shown, so could never be taken off)
dronegrant.ROWS = 12   -- journal_tab.lua SETTING_ROWS
dronegrant.PAGE_KEY = "page"
dronegrant.NAME_MAX = 18
function dronegrant.setting_rows()
    local all = dronegrant.rows()
    local per = #all > dronegrant.ROWS and dronegrant.ROWS - 1 or dronegrant.ROWS
    local pages = math.max(1, math.ceil(#all / per))
    G.page = G.page or 1
    if G.page > pages or G.page < 1 then G.page = 1 end   -- (past the last page: back to the first)
    local out = {}
    for i = (G.page - 1) * per + 1, math.min(#all, G.page * per) do
        local r = all[i]
        -- (a Steam name runs to 32 characters; cut under the 21-letter caps label MY SETTINGS fits, on a whole letter)
        out[#out + 1] = { key = r.id, label = require("mirror.util").utf8_cut(r.name, dronegrant.NAME_MAX),
            text = G.mode == "open" and "UNLOCKED" or G.mode == "locked" and "LOCKED" or r.allowed and "ALLOWED" or "NOT ALLOWED",
            hint = G.mode and "FPV drone - set for everyone by /fpv lock or /fpv unlock; /fpv list goes back to this list"
                or r.here and "FPV drone - in co-op with you now; it lands within seconds when you take it away"
                or "FPV drone - not with you now; allowed again when they join you" }
    end
    if pages > 1 then
        out[#out + 1] = { key = dronegrant.PAGE_KEY, label = "MORE PLAYERS", text = string.format("PAGE %d / %d", G.page, pages),
            hint = "Shows the next " .. per .. " players" }
    end
    return out
end

-- what the owner's game sends: "A" and the allowed ids, "A *" for everyone
function dronegrant.message()
    local list = load()
    if G.mode == "open" then return "A *" end
    if G.mode == "locked" then return "A " end
    local ids = {}
    for _, p in ipairs(list) do ids[#ids + 1] = p.id end
    return "A " .. table.concat(ids, " ")
end

-- a link's copy heard a list (from: the SteamID64 of the player on that link); only the owner's counts
function dronegrant.heard(msg, from, now)
    if tostring(from) ~= adminfly().OWNER or type(msg) ~= "string" or msg:sub(1, 1) ~= "A" then return end
    local me = peers().my_id()
    if not me then return end
    local yes = msg:sub(2):match("^%s*%*") ~= nil
    for id in msg:sub(2):gmatch("%d+") do if id == me then yes = true end end
    G.heard = G.heard + 1
    G.until_t = yes and (now + dronegrant.HOLD_S) or -math.huge
    if yes ~= G.said then
        -- (only a real change is told: not the "no" every player hears first)
        if yes then say("The owner allows you to fly the FPV drone.", "good")
        elseif G.said then say("The owner locked the FPV drone.") end
        G.said = yes
        log.info("dronegrant: the drone's owner " .. (yes and "allows" or "doesn't allow") .. " me to fly it")
    end
end

-- what FPVDrone.allowed says now ("owner", "until <os.clock>" or "")
function dronegrant.value(now)
    if dronegrant.owner() then return "owner" end
    if now < G.until_t then return string.format("until %.1f", G.until_t) end
    return ""
end

-- every frame (each link's drone copy; only a change is written)
function dronegrant.tick(now)
    local v = dronegrant.value(now)
    if v == G.set or ModRef == nil then return end
    G.set = v
    pcall(function() ModRef:SetSharedVariable(dronegrant.SHARED, v) end)
end

-- main.lua: every frame from the start, not only with a link up, so the owner flies solo too (drone.tick runs only
-- in co-op; FPVDrone.allowed was never set in a solo game; audit 2026-11-03)
local inited = false
function dronegrant.init()
    if inited then return end
    inited = true
    require("mirror.game").on_tick(function() dronegrant.tick(os.clock()) end)
end

function dronegrant.status()
    if dronegrant.owner() then return "drone permissions: owner, " .. #load() .. " allowed" .. (G.mode and (", " .. G.mode .. " for everyone") or "") end
    return "drone permissions: " .. ((G.set or "") ~= "" and "allowed" or "not allowed") .. ", lists heard " .. G.heard
end

dronegrant._state = G
dronegrant._reset = function() G.list, G.until_t, G.set, G.heard, G.said, G.page, G.mode = nil, -math.huge, nil, 0, nil, nil, nil end
return dronegrant
