-- The host's game settings (CO-OP tab -> gear -> HOST RULES): saved on this PC and sent to every guest,
-- whose shared world follows them. Outside co-op your own settings apply to your own world.
-- In a Realm the owner sets them, whoever hosts: the server keeps the owner's rules, the host plays by them.

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
    { key = "debugmenu", label = "DEBUG MENU", hint = "Everyone can open the game's debug menu (items, skills, weather).",
      default = "on" },
}

local by_key = {}
for _, o in ipairs(hostrules.LIST) do o.values = o.values or ONOFF; by_key[o.key] = o end

local mine = {}
for _, o in ipairs(hostrules.LIST) do mine[o.key] = o.default end
local peer = {}
local peer_raw = ""
local sent, sent_to = nil, {}
local role_fn = function() return nil end
-- The Realm I'm in (realmplay: hostrules.set_realm): { id, owner = am I its owner, rules = the server's or nil }
local realm_fn = function() return nil end
local push_fn = nil
local pushed = nil   -- { id, rules, at }: my change on its way to the server - its older rules don't undo it meanwhile
local draft = nil    -- the owner visiting as a guest: { rules, raw, at } shown until the host plays by it
local seeded = {}    -- Realm id -> when this game first sent the rules of a Realm the server had none for
local seed_told = {} -- Realm id -> true: its rules' first send failed and the owner was told (the retries only log)
local old_bridge = false   -- the bridge answered bad_command (older than the rules verb): nothing more is sent

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
    local s = p and require("mirror.fs").read(p) or ""
    for k, v in s:gmatch("(%w+)%s+(%w+)") do
        local o = by_key[k]
        if o and valid(o, v) then mine[k] = v
        elseif o and v == "on" and o.key == "itemclean" then mine[k] = "20" end   -- (the old on/off file)
    end
end

-- (whole file or the old one: written in place, a crash mid-write left a Realm's rules empty - it travels with the world)
local function save()
    local p = file()
    if not p then return end
    local out = {}
    for _, o in ipairs(hostrules.LIST) do out[#out + 1] = o.key .. " " .. mine[o.key] .. "\n" end
    if not require("mirror.fs").write(p, table.concat(out)) then log.warn("hostrules: couldn't save " .. p) end
end

local function encode(t)
    local parts = {}
    for _, o in ipairs(hostrules.LIST) do parts[#parts + 1] = o.key .. " " .. t[o.key] end
    return table.concat(parts, " ")
end

-- "<key> <value> ..." into a full table: keys it lacks keep base's value (the defaults without one)
local function parse(s, base)
    local t = {}
    for _, o in ipairs(hostrules.LIST) do t[o.key] = (base and base[o.key]) or o.default end
    for k, v in (s or ""):gmatch("(%w+) (%w+)") do
        local o = by_key[k]
        if o and valid(o, v) then t[k] = v end
    end
    return t
end

-- Out of a guest's seat: forget the last host's rules, so the next host's are read fresh (get_blob hands an
-- unchanged blob out once - without the reset a rejoin to the same host would stay on the defaults) and a guest
-- of another host never runs on the old host's rules until the new ones arrive.
local function forget_peer()
    if peer_raw == "" then return end
    peer, peer_raw = {}, ""
    link.reset_blob("rules")
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
    forget_peer()
    return mine[key]
end

-- Whose rules value() reads: "mine", "host" (a guest with the host's rules in hand) or nil (a guest before
-- they arrive, when value() falls back to the defaults).
function hostrules.source()
    if role_fn() ~= "guest" then forget_peer(); return "mine" end
    read_peer()   -- (get_blob hands a blob out once: only read_peer may take it)
    return peer_raw ~= "" and "host" or nil
end

-- My own value (what I host with, and what my own world uses outside co-op).
function hostrules.my_value(key) return mine[key] end
function hostrules.mine(key) local v = mine[key]; return v ~= nil and v ~= "off" end
function hostrules.get(key) local v = hostrules.value(key); return v ~= nil and v ~= "off" end

-- In a Realm only its owner changes the rules (hosting or not); elsewhere the host or a player on their own.
function hostrules.can_edit()
    local r = realm_fn()
    if r then return r.owner == true end
    return role_fn() ~= "guest"
end

-- the settings page's line about whose rules these are in a Realm (nil = not in one)
function hostrules.note()
    local r = realm_fn()
    if not r then return nil end
    return r.owner and "Your Realm's rules. Everyone in it plays by them, whoever hosts."
        or "The Realm's rules - only its owner can change them."
end

local function label_of(o, v)
    for _, x in ipairs(o.values) do if x[1] == v then return x[2] end end
    return tostring(v)
end

-- The owner's rules to the server. Until it answers, its older rules don't undo the change; refused, they do.
-- seeding = the first send of a Realm the server has none for (retried every minute: only its first failure is told)
local function push(id, s, seeding)
    if not push_fn or old_bridge then return end
    pushed = { id = id, rules = s, at = os.clock() }
    push_fn(id, s, function(ok, _, text)
        if pushed and pushed.rules == s then pushed = nil end
        if not ok and tostring(text):find("^bad_command") then
            -- (a bridge older than this mod: no red line every minute, the owner's rules just don't reach the server)
            old_bridge, draft = true, nil
            log.warn("hostrules: this bridge can't send a Realm's rules (" .. tostring(text) .. ") - reinstall SurrounSync")
        elseif not ok then
            draft = nil
            log.warn("hostrules: the Realm's rules didn't reach the server: " .. tostring(text))
            if not (seeding and seed_told[id]) then
                notify.show("Couldn't save the Realm's rules (" .. tostring(text) .. ").", "bad")
            end
            if seeding then seed_told[id] = true end
        end
    end)
end

-- The server's rules for Realm r into the file in use (keys they lack keep their value); true = they changed it.
local function take_realm(r)
    local t = parse(r.rules, mine)
    if encode(t) == encode(mine) then return false end
    for k, v in pairs(t) do mine[k] = v end
    save()
    return true
end

-- The settings page's button: the next value.
function hostrules.toggle(key)
    local r = realm_fn()
    if not hostrules.can_edit() then
        notify.show(r and "Only the Realm's owner can change its rules." or "Only the host can change these settings.", "info")
        return
    end
    local o = by_key[key]
    if not o then return end
    -- (the owner visiting their Realm edits a copy of the host's rules: the host plays by it once the server has it)
    local t = mine
    if r and role_fn() == "guest" then
        if not draft then
            local cur = {}
            for _, x in ipairs(hostrules.LIST) do cur[x.key] = hostrules.value(x.key) end
            draft = { rules = cur }
        end
        t = draft.rules
    end
    local n = 1
    for i, x in ipairs(o.values) do if x[1] == t[key] then n = i % #o.values + 1 end end
    t[key] = o.values[n][1]
    if t == mine then save() end
    log.info("hostrules: " .. key .. " " .. t[key] .. (r and (" (Realm " .. r.id .. ")") or ""))
    if r then
        if draft then draft.raw, draft.at = encode(t), os.clock() end
        push(r.id, encode(t))
    end
end

-- what the page shows: the visiting owner's change until the host plays by it (2 min at most), else value()
local function shown_draft()
    if not draft then return nil end
    if role_fn() ~= "guest" or not realm_fn() or os.clock() - draft.at > 120
        or (hostrules.source() == "host" and encode(parse(peer_raw)) == draft.raw) then
        draft = nil
    end
    return draft
end

-- Rows for the settings page.
function hostrules.rows()
    local out = {}
    local d = shown_draft()
    for _, o in ipairs(hostrules.LIST) do
        local v = d and d.rules[o.key] or hostrules.value(o.key)
        out[#out + 1] = { key = o.key, label = o.label, hint = o.hint, text = label_of(o, v) }
    end
    return out
end

-- Hosting a Realm: play by the owner's rules from the server (into the Realm's own file, which travels with the
-- world). The owner hosting a Realm the server has none for yet (made before) sends theirs.
local function follow_realm()
    local r = realm_fn()
    if not r or role_fn() == "guest" then return end
    if pushed and (pushed.id ~= r.id or os.clock() - pushed.at > 60) then pushed = nil end
    if pushed then return end
    if r.rules == nil then
        if r.owner and os.clock() - (seeded[r.id] or -math.huge) > 60 then
            seeded[r.id] = os.clock()
            log.info("hostrules: the server has no rules for Realm " .. r.id .. " - sending mine: " .. encode(mine))
            push(r.id, encode(mine), true)
        end
        return
    end
    if take_realm(r) then log.info("hostrules: the Realm owner's rules: " .. encode(mine)) end
end

function hostrules.tick()
    follow_realm()
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
    -- (a Realm's file: the owner's rules the Realm list already has go in now, not after the switch - a guest taking
    -- over played about 1 s by the file's older rules, kit 2026-10-30 20:09:09)
    local r = path and realm_fn()
    local by_owner = r and r.rules ~= nil and not (pushed and pushed.id == r.id) and take_realm(r)
    log.info("hostrules: " .. (path and "the Realm's" or "my") .. " settings" .. (by_owner and " (the owner's)" or "")
        .. ": " .. encode(mine))
end
function hostrules.own_file() return own_file() end

-- fn() -> { id, owner, rules } for the Realm I'm in (nil = none); push(id, rules, cb) sends the owner's to the server
function hostrules.set_realm(fn, push)
    realm_fn = fn or function() return nil end
    push_fn = push
end

function hostrules.init(role_getter)
    role_fn = role_getter or role_fn
    load()
    log.info("hostrules: my settings: " .. encode(mine))
end

return hostrules
