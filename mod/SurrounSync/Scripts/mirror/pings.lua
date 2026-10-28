-- Map pings (the markers players put on the big map) show on every player's map.
-- A ping is a BP_PlayerMarker actor the game saves with the world, so the host's world keeps the guests' pings
-- too, and a joining guest gets every ping with the world. Only new pings and removals travel:
--   new:     MapWidget click -> BPC_MinimapSystem Svr_SpawnPlayerMarker -> BP_PlayerMarker Event_AddMarker (a
--            ping loaded from a save runs ActorLoaded instead, so Event_AddMarker means "just placed")
--   removed: double click -> BPC_MinimapSystem "Remove Player Marker"(actor) -> the actor's ReceiveDestroyed
--            (a world unload never runs Remove Player Marker: only a player's removal is sent)
-- The other game places it through the same Svr_SpawnPlayerMarker, with the sender's look swapped into the
-- picker's DefaultPlayerMarkerData for that call. MY SETTINGS -> SHARE MAP PINGS off: yours stay yours.
--
-- Military laptop scans (decompiled 2026-10-27): using the laptop starts a random bounty quest
-- (BP_BountyQuestManager CallRandomEvent -> Narrative BeginQuest). Its Quest_Event_SpawnMarker spawns a
-- BP_QuestMarker (map icon) at a fixed place, a "find the classified container" one also has its
-- BP_Quest_Spawner_Object (tag = the quest's name) spawn a BP_GuaranteedSpawner_Classified there (seen in-game:
-- not the Container_LaptopEventCrate the assets suggest); Quest_Event_RemoveMarker takes the icon away when it's
-- done. The other game gets a copy of the icon and of the crate. The quest and the crate's item stay the
-- scanner's: searching runs Svr_CrateOpen (quest progress + one random item spawned in that world), so the copy
-- starts as already searched (Opened) and plays the lid opening when the scanner searches theirs.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local events = require("mirror.events")
local peers = require("mirror.peers")
local mysettings = require("mirror.mysettings")

local pings = {}

local MARKER = "/Game/Blueprints/MinimapSystem/Blueprints/Marker/BP_PlayerMarker.BP_PlayerMarker_C"
local MINIMAP = "/Game/Blueprints/MinimapSystem/Blueprints/BPC_MinimapSystem.BPC_MinimapSystem_C"
-- the S_MarkerData fields the marker picker (PlayerMarkerSelectionUI) changes
local F = {
    tex = "MarkerTexture_10_217A4B4A49F28BE075685196E3EC66CD",
    color = "MarkerColor_52_AB92BD2E4886BEC45F39A59226A8B872",
    size = "TextureSize_30_0FC614D34939DCCA4077899925344EDF",
    compass = "CompassMarker?_45_173EEC314B156D67370A86A9FF973EA4",
}
local QUEST_SPAWN = "/Game/Quests/Events/Quest_Event_SpawnMarker.Quest_Event_SpawnMarker_C:ExecuteEvent"
local QUEST_REMOVE = "/Game/Quests/Events/Quest_Event_RemoveMarker.Quest_Event_RemoveMarker_C:ExecuteEvent"
local SPAWNER = "/Game/Quests/Blueprints/Spawner/BP_Quest_Spawner_Object.BP_Quest_Spawner_Object_C:Quest_Spawn"
local QMARKER_ASSET = "/Game/Quests/Blueprints/Objects/BP_QuestMarker"
local QMARKER = QMARKER_ASSET .. ".BP_QuestMarker_C"
local QMARKER_CDO = QMARKER_ASSET .. ".Default__BP_QuestMarker_C"
local CRATE_OPEN = "/Game/Quests/Blueprints/Objects/BP_GuaranteedSpawner.BP_GuaranteedSpawner_C:Svr_CrateOpen"
local BOUNTY = "^Quest_Bounty_"
local SAME = 100        -- cm: a removed ping is the one this close to the sent place (both games trace the same ground)
local RETRY, TRIES = 2.0, 30

local cfg, role, session
local channel = events.reliable("pings")
-- every copy of this module (one per guest on the host) hooks the same functions: while one copy places or
-- removes a ping for its player, no copy may take it for a local one (the host passes it on with peers.relay)
local busy = peers.shared("pings.busy", { on = false })
local known = {}        -- addr -> { o = marker, l = location }: pings seen here (placed, loaded or made by us)
local dying = nil       -- { a = addr, l = location } of the marker whose ReceiveDestroyed just ran
local pending = {}      -- { p = message, n = tries }
-- quest marker tag -> the copy made here (BP_QuestMarker isn't saved with the world: a copy ends with the session,
-- and the scanner's game spawns its icon again when the quest loads)
local theirs_q = {}
local theirs_c = {}     -- addr -> true: crate copies made here (searching one of them is nothing to send)
-- my bounty icons and crates still active, by quest tag: sent again when a guest arrives (a bounty bought before the
-- guest joined only went out at my world's load, to nobody - kit 2026-10-27: the host's 004 missing on the guest)
local mine_q, mine_c = {}, {}
local hook_in, retry_in = 0.0, 0.0
local stats = { sent = 0, removed = 0, made = 0, unmade = 0, scans = 0, crates = 0 }

local function shared() return role == "host" or (session and session.in_world()) end
local function share_mine() return shared() and mysettings.on("pings") end

local function path_of(o)
    local p
    pcall(function() p = o:GetFullName():match("^%S+ (.+)$") end)
    return p
end
local function loc_of(m)
    local l
    pcall(function() l = m:K2_GetActorLocation() end)
    return l and { X = l.X, Y = l.Y, Z = l.Z } or nil
end
local function remember(m)
    local a, l = util.addr(m), loc_of(m)
    if a and l then known[a] = { o = m, l = l } end
end

local function on_add(m)
    remember(m)
    if busy.on or not share_mine() then return end
    local l, d = loc_of(m), nil
    pcall(function() d = m["Marker Data"] end)
    if not (l and d) then return end
    local tex, c, s, compass
    pcall(function() tex = path_of(d[F.tex]) end)
    pcall(function() local v = d[F.color]; c = { v.R, v.G, v.B, v.A } end)
    pcall(function() local v = d[F.size]; s = { v.X, v.Y } end)
    pcall(function() compass = d[F.compass] == true end)
    c, s = c or { 1, 1, 1, 1 }, s or { 0, 0 }
    channel:send(string.format("A %.0f %.0f %.0f %s %.3f %.3f %.3f %.3f %.1f %.1f %d", l.X, l.Y, l.Z, tex or "-",
        c[1], c[2], c[3], c[4], s[1], s[2], compass and 1 or 0))
    stats.sent = stats.sent + 1
    log.info(string.format("pings: placed one at %.0f %.0f - sent", l.X, l.Y))
end

local function on_destroyed(m)
    local a, l = util.addr(m), loc_of(m)
    if a and l then dying = { a = a, l = l } end
end

local function on_remove(actor)
    local d = dying
    dying = nil
    if busy.on or not d or not share_mine() then return end
    local a
    pcall(function() a = actor:GetAddress() end)
    if a and a ~= d.a then return end
    known[d.a] = nil
    channel:send(string.format("R %.0f %.0f %.0f", d.l.X, d.l.Y, d.l.Z))
    stats.removed = stats.removed + 1
    log.info(string.format("pings: removed the one at %.0f %.0f - sent", d.l.X, d.l.Y))
end

local function text_of(v)
    if type(v) == "string" then return v end
    local s
    pcall(function() s = v:ToString() end)
    return s
end
local function word(s) return (tostring(s or ""):gsub("%s+", "_")) end
-- bounty quests only (the laptop's): story quests' icons stay with their player
local function from_bounty(ev)
    local n
    pcall(function() n = ev:GetFullName() end)
    return n ~= nil and n:find("Quest_Bounty_", 1, true) ~= nil
end

local function on_quest_marker(ev)
    if busy.on or not share_mine() or not from_bounty(ev) then return end
    local l, tex, c, ug
    pcall(function() local v = ev.Location; l = { X = v.X, Y = v.Y, Z = v.Z } end)
    pcall(function() tex = path_of(ev["Marker Texture"]) end)
    pcall(function() local v = ev.Color; c = { v.R, v.G, v.B, v.A } end)
    pcall(function() ug = ev["Underground?"] == true end)
    local tag, text = word(text_of(ev.ActorTag)), text_of(ev.Text) or ""
    if not l or tag == "" or tag == "None" then return end
    c = c or { 1, 1, 1, 1 }
    mine_q[tag] = string.format("Q %.0f %.0f %.0f %s %.3f %.3f %.3f %.3f %d %s %s", l.X, l.Y, l.Z, tex or "-",
        c[1], c[2], c[3], c[4], ug and 1 or 0, tag, (text:gsub("[\r\n]+", " ")))
    channel:send(mine_q[tag])
    stats.scans = stats.scans + 1
    log.info(string.format("pings: laptop scan marked %s at %.0f %.0f - sent", tag, l.X, l.Y))
end

local function on_quest_unmarker(ev)
    if busy.on or not share_mine() or not from_bounty(ev) then return end
    local tag = word(text_of(ev.ActorTag))
    if tag ~= "" and tag ~= "None" then
        mine_q[tag], mine_c[tag] = nil, nil
        channel:send("X " .. tag)
    end
end

local function on_spawner(sp)
    if busy.on or not share_mine() then return end
    local cls
    pcall(function() cls = sp.ObjectToSpawn end)
    if not (util.valid(cls) and (text_of(sp.QuestTag) or ""):find(BOUNTY)) then return end
    local path, l, r = path_of(cls), loc_of(sp), nil
    pcall(function() local v = sp:K2_GetActorRotation(); r = { v.Pitch, v.Yaw, v.Roll } end)
    if not (path and l) then return end
    r = r or { 0, 0, 0 }
    local msg = string.format("C %s %.1f %.1f %.1f %.2f %.2f %.2f", path, l.X, l.Y, l.Z, r[1], r[2], r[3])
    mine_c[word(text_of(sp.QuestTag))] = msg
    channel:send(msg)
    log.info(string.format("pings: laptop scan crate at %.0f %.0f - sent", l.X, l.Y))
end

-- the scanner searched its crate: the copies' lids open too
local function on_crate_open(c)
    if busy.on or not share_mine() then return end
    local l, cls = loc_of(c), util.class_name(c)
    if l and cls and theirs_c[util.addr(c) or 0] == nil then
        channel:send(string.format("O %s %.1f %.1f %.1f", cls, l.X, l.Y, l.Z))
    end
end

local function minimap()
    local cc, c = StaticFindObject(MINIMAP), nil
    if not util.valid(cc) then return nil end
    pcall(function() c = game.player():GetComponentByClass(cc) end)
    return util.valid(c) and c or nil
end

local function nearest(l)
    local best, bd = nil, SAME
    for a, e in pairs(known) do
        if not util.valid(e.o) then known[a] = nil
        else
            local dd = util.dist(e.l, l)
            if dd < bd then best, bd = e.o, dd end
        end
    end
    return best
end

-- pings loaded before our hooks stood are not in `known`: one walk, only when a removal misses
local function walk()
    local all
    pcall(function() all = FindAllOf("BP_PlayerMarker_C") end)
    for _, m in ipairs(all or {}) do if util.valid(m) then remember(m) end end
end

local function make(p)
    local x, y, z, tex, r, g, b, a, sx, sy, cmp =
        p:match("^A (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) ([01])$")
    local l = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    if not (l.X and l.Y and l.Z) then return true end
    if nearest(l) then return true end
    local c = minimap()
    if not c then return false end
    local d = c.DefaultPlayerMarkerData
    local old = {}
    pcall(function() old.tex = d[F.tex] end)
    pcall(function() local v = d[F.color]; old.color = { R = v.R, G = v.G, B = v.B, A = v.A } end)
    pcall(function() local v = d[F.size]; old.size = { X = v.X, Y = v.Y } end)
    pcall(function() old.compass = d[F.compass] end)
    local t = tex ~= "-" and StaticFindObject(tex) or nil
    busy.on = true
    local ok, err = pcall(function()
        if util.valid(t) then d[F.tex] = t end
        d[F.color] = { R = tonumber(r), G = tonumber(g), B = tonumber(b), A = tonumber(a) }
        if tonumber(sx) > 0 and tonumber(sy) > 0 then d[F.size] = { X = tonumber(sx), Y = tonumber(sy) } end
        d[F.compass] = cmp == "1"
        c:Svr_SpawnPlayerMarker(l, true)
    end)
    for k, v in pairs(old) do pcall(function() d[F[k]] = v end) end
    busy.on = false
    if ok then stats.made = stats.made + 1 else log.warn("pings: couldn't place the other player's ping: " .. tostring(err)) end
    log.info(string.format("pings: the other player placed one at %.0f %.0f%s", l.X, l.Y, util.valid(t) and "" or " (default look)"))
    return true
end

local function unmake(p)
    local x, y, z = p:match("^R (%S+) (%S+) (%S+)$")
    local l = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    if not (l.X and l.Y and l.Z) then return true end
    local m = nearest(l)
    if not m then walk(); m = nearest(l) end
    if not m then log.info(string.format("pings: the other player removed one at %.0f %.0f - not here", l.X, l.Y)); return true end
    local c = minimap()
    if not c then return false end
    busy.on = true
    local ok, err = pcall(function() c["Remove Player Marker"](c, m) end)
    busy.on = false
    dying = nil
    known[util.addr(m) or 0] = nil
    if ok then stats.unmade = stats.unmade + 1 else log.warn("pings: couldn't remove the other player's ping: " .. tostring(err)) end
    return true
end

-- the class's defaults get the scan's look for one SpawnActor (BeginPlay builds the map icon from them)
local QF = { tex = "Marker Texture", color = "Color", text = "Text", ug = "Underground?" }
local function make_quest_marker(p)
    local x, y, z, tex, r, g, b, a, ug, tag, text =
        p:match("^Q (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) ([01]) (%S+) ?(.*)$")
    local l = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    if not (tag and l.X and l.Y and l.Z) then return true end
    if util.valid(theirs_q[tag]) then return true end
    local cls = StaticFindObject(QMARKER)
    if not util.valid(cls) then pcall(function() LoadAsset(QMARKER) end); cls = StaticFindObject(QMARKER) end
    local cdo, w = StaticFindObject(QMARKER_CDO), game.world()
    if not (util.valid(cls) and util.valid(cdo) and w) then return false end
    local old = {}
    pcall(function() old.tex = cdo[QF.tex] end)
    pcall(function() local v = cdo[QF.color]; old.color = { R = v.R, G = v.G, B = v.B, A = v.A } end)
    pcall(function() old.text = cdo[QF.text]:ToString() end)
    pcall(function() old.ug = cdo[QF.ug] end)
    local t = tex ~= "-" and StaticFindObject(tex) or nil
    local m
    busy.on = true
    local ok, err = pcall(function()
        if util.valid(t) then cdo[QF.tex] = t end
        cdo[QF.color] = { R = tonumber(r), G = tonumber(g), B = tonumber(b), A = tonumber(a) }
        cdo[QF.text] = text
        cdo[QF.ug] = ug == "1"
        m = w:SpawnActor(cls, l, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    for k, v in pairs(old) do pcall(function() cdo[QF[k]] = v end) end
    busy.on = false
    if not (ok and util.valid(m)) then log.warn("pings: couldn't show the other player's laptop scan: " .. tostring(err)); return true end
    theirs_q[tag] = m
    log.info(string.format("pings: the other player's laptop scan %s at %.0f %.0f", tag, l.X, l.Y))
    return true
end

local function unmake_quest_marker(p)
    local tag = p:match("^X (%S+)$")
    local m = tag and theirs_q[tag]
    if tag then theirs_q[tag] = nil end
    if util.valid(m) then pcall(function() m:K2_DestroyActor() end); log.info("pings: the other player's laptop scan " .. tag .. " is done") end
    return true
end

local function make_crate(p)
    local path, x, y, z, rp, ry, rr = p:match("^C (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
    local l = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    if not (path and l.X and l.Y and l.Z) then return true end
    -- already here (both scanned the same bounty, or it came with the world)
    local short = path:match("%.([^%.]+)$")
    local all
    pcall(function() all = FindAllOf(short) end)
    for _, c in ipairs(all or {}) do
        local cl = util.valid(c) and loc_of(c)
        if cl and util.dist(cl, l) < SAME then return true end
    end
    local cls = StaticFindObject(path)
    if not util.valid(cls) then pcall(function() LoadAsset(path) end); cls = StaticFindObject(path) end
    local w = game.world()
    if not (util.valid(cls) and w) then return false end
    local c
    busy.on = true
    local ok, err = pcall(function() c = w:SpawnActor(cls, l, { Pitch = tonumber(rp), Yaw = tonumber(ry), Roll = tonumber(rr) }) end)
    busy.on = false
    if not (ok and util.valid(c)) then log.warn("pings: couldn't place the other player's laptop crate: " .. tostring(err)); return true end
    -- searched already: its item and the quest's progress are the scanner's
    pcall(function() c.Opened = true end)
    theirs_c[util.addr(c) or 0] = true
    stats.crates = stats.crates + 1
    log.info(string.format("pings: the other player's laptop crate at %.0f %.0f", l.X, l.Y))
    return true
end

local function open_crate(p)
    local cls, x, y, z = p:match("^O (%S+) (%S+) (%S+) (%S+)$")
    local l = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    if not (cls and l.X and l.Y and l.Z) then return true end
    local all
    pcall(function() all = FindAllOf(cls) end)
    for _, c in ipairs(all or {}) do
        local cl = util.valid(c) and loc_of(c)
        if cl and util.dist(cl, l) < SAME then
            busy.on = true
            pcall(function() c.Opened = true; c:MC_CrateOpen() end)
            busy.on = false
            log.info(string.format("pings: the other player searched the laptop crate at %.0f %.0f", l.X, l.Y))
            return true
        end
    end
    return true
end

local APPLY = { A = make, R = unmake, Q = make_quest_marker, X = unmake_quest_marker, C = make_crate, O = open_crate }
local function apply(p)
    local f = APPLY[p:sub(1, 1)]
    if f then return f(p) end
    return true
end

local add_fn = function(self) util.safe(function() on_add(self:get()) end, "pings.add") end
local loaded_fn = function(self) util.safe(function() remember(self:get()) end, "pings.loaded") end
local destroyed_fn = function(self) util.safe(function() on_destroyed(self:get()) end, "pings.destroyed") end
local remove_fn = function(self, actor) util.safe(function() on_remove(actor and actor:get()) end, "pings.remove") end
local qmark_fn = function(self) util.safe(function() on_quest_marker(self:get()) end, "pings.quest_marker") end
local qunmark_fn = function(self) util.safe(function() on_quest_unmarker(self:get()) end, "pings.quest_unmarker") end
local spawner_fn = function(self) util.safe(function() on_spawner(self:get()) end, "pings.spawner") end
local crate_open_fn = function(self) util.safe(function() on_crate_open(self:get()) end, "pings.crate_open") end

function pings.tick(dt)
    if role == "off" then return end
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 1.0
        util.ensure_hook(MARKER .. ":Event_AddMarker", add_fn)
        util.ensure_hook(MARKER .. ":ActorLoaded", loaded_fn)
        util.ensure_hook(MARKER .. ":ReceiveDestroyed", destroyed_fn)
        util.ensure_hook(MINIMAP .. ":Remove Player Marker", remove_fn)
        util.ensure_hook(QUEST_SPAWN, qmark_fn)
        util.ensure_hook(QUEST_REMOVE, qunmark_fn)
        util.ensure_hook(SPAWNER, spawner_fn)
        util.ensure_hook(CRATE_OPEN, crate_open_fn)
    end
    channel:pump(function(p)
        if not shared() then return end
        -- false = no map component / world yet (respawning, loading): try again; an error is logged and dropped
        if select(2, util.safe(apply, "pings.apply", p)) == false then pending[#pending + 1] = { p = p, n = 0 } end
        -- more than two players: the host placed it under `busy`, so the other guests hear it from here
        peers.relay("mirror.pings", pings, function(m) m.relay_send(p) end)
    end)
    retry_in = retry_in - dt
    if #pending > 0 and retry_in <= 0 then
        retry_in = RETRY
        if not shared() then pending = {}; return end
        local left = {}
        for _, e in ipairs(pending) do
            e.n = e.n + 1
            local wait = select(2, util.safe(apply, "pings.apply", e.p)) == false
            if wait and e.n < TRIES then left[#left + 1] = e
            elseif wait then log.warn("pings: gave up on the other player's '" .. e.p:sub(1, 1) .. "' after " .. TRIES .. " tries") end
        end
        pending = left
    end
end

function pings.relay_send(p) channel:send(p) end

-- a guest arrived in my world: my bounties still running (the other game skips any it already shows). Icons the
-- game put back at my world's load came before the hooks: they're picked up here by their quest tag.
function pings.resend_mine()
    if role == "off" or not share_mine() then return end
    local copies = {}
    for _, m in pairs(theirs_q) do if util.valid(m) then copies[util.addr(m) or 0] = true end end
    local all
    pcall(function() all = FindAllOf("BP_QuestMarker_C") end)
    for _, m in ipairs(all or {}) do
        local tag
        pcall(function()
            for i = 1, m.Tags:GetArrayNum() do
                local t = m.Tags[i]:ToString()
                if t:find(BOUNTY) then tag = word(t) end
            end
        end)
        local l = loc_of(m)
        if tag and l and not mine_q[tag] and not copies[util.addr(m) or 0] then
            local tex, c, ug, text
            pcall(function() tex = path_of(m[QF.tex]) end)
            pcall(function() local v = m[QF.color]; c = { v.R, v.G, v.B, v.A } end)
            pcall(function() ug = m[QF.ug] == true end)
            pcall(function() text = m[QF.text]:ToString() end)
            c = c or { 1, 1, 1, 1 }
            mine_q[tag] = string.format("Q %.0f %.0f %.0f %s %.3f %.3f %.3f %.3f %d %s %s", l.X, l.Y, l.Z, tex or "-",
                c[1], c[2], c[3], c[4], ug and 1 or 0, tag, ((text or ""):gsub("[\r\n]+", " ")))
        end
    end
    local n = 0
    for _, m in pairs(mine_q) do channel:send(m); n = n + 1 end
    for _, m in pairs(mine_c) do channel:send(m) end
    if n > 0 then log.info("pings: sent my " .. n .. " running bounty scan(s) to the arriving player") end
end

function pings.status()
    return string.format("pings: sent %d, removed %d, scans %d | placed %d, removed %d, crates %d%s", stats.sent,
        stats.removed, stats.scans, stats.made, stats.unmade, stats.crates, #pending > 0 and (", waiting " .. #pending) or "")
end

-- Respawn/reload: the old world's objects are freed - drop them without touching them.
local function forget_world() known, dying, pending, theirs_q, theirs_c, mine_q, mine_c = {}, nil, {}, {}, {}, {}, {} end
function pings.init(c, r, s)
    game.on_world_reset(forget_world)
    cfg, role, session = c, r, s
    if cfg.ping_sync == false then role = "off" end
    log.info("pings: " .. (role == "off" and "off" or "map pings are shared"))
end

return pings
