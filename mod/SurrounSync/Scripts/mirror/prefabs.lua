-- Random event sites follow the host: crashed planes and helicopters, convoys, abandoned trucks, camps.
--
-- They're prefabs (PrefabMaster children, built from child actors tagged EMS_SkipSave - never saved). Every load,
-- each BP_PrefabSpawner rolls its own chance and spawns its prefab or destroys itself, and BP_EventManager fires
-- dynamic ones (BP_PrefabSpawner_Dynamic) on its own timer (decompiled 2026-10-29) - so the guest's copy of the host's
-- world rolled its own set (user: "plane crashes are not synced"). The host sends where its prefabs stand; a joined
-- guest removes its own others and spawns the host's at the same spot (their containers then sit where the host's do,
-- so shared loot finds them). Settlements are camps.lua's; quest prefabs follow each game's quests and stay alone.

local log = require("mirror.log")
local util = require("mirror.util")
local link = require("mirror.link")
local loottables = require("mirror.loottables")

local prefabs = {}

local CHECK_EVERY = 5.0
local SETTLE = 10.0          -- after arriving: the world's spawners roll first
local PARENT = "/Game/Prefabs/PrefabMaster.PrefabMaster_C"
local SAME = 100.0           -- cm: a prefab of that class this close is the same one
local MAX_STEPS = 4          -- removals + spawns per check (a load's worth at once was a hitch)

-- Their map markers (BP_PrefabSpawner, decompiled): a spawner that places its site puts up an orange BP_Marker
-- (SpawnMarker, if Marker? and Difficulty.RandomEventMarker); its DistanceToPrefab timer takes it off the map and
-- gives 40-60 XP once the player comes within DistanceToDiscoverPrefab. Per player, like in the game.
local SPAWNER = "BP_PrefabSpawner_C"
local SPAWNER_PATH = "/Game/Prefabs/BP_PrefabSpawner.BP_PrefabSpawner_C"
local MINIMAP = "/Game/Blueprints/MinimapSystem/Blueprints/BPC_MinimapSystem.BPC_MinimapSystem_C"
local KSL = "/Script/Engine.Default__KismetSystemLibrary"

local role, session
local peer_live = function() return true end
local tick_in, joined_for = 0.0, 0.0
local last_sent, want, pending = nil, nil, nil
local destroyed = {}         -- addresses already destroyed here (still listed until the engine lets go)
local spawned_here = {}      -- line -> true: spawned once in this world (never again, even if it isn't seen)
local stats = { removed = 0, spawned = 0, sent = 0, no_marker = 0 }

-- ours to follow: not a settlement (camps.lua), not a quest's, not the empty templates at the world origin
local function followed(cls)
    return cls and cls:find("^Prefab_") and not cls:find("^Prefab_Settlement") and not cls:find("^Prefab_Quest") and true or false
end

local function present()
    local out = {}
    for _, a in ipairs(util.instances("PrefabMaster_C", { PARENT })) do
        local k = util.addr(a)
        if k and not destroyed[k] and util.valid(a) then
            local cls = util.class_name(a)
            local l, r
            pcall(function() l, r = a:K2_GetActorLocation(), a:K2_GetActorRotation() end)
            if followed(cls) and l and (math.abs(l.X) > 100 or math.abs(l.Y) > 100 or math.abs(l.Z) > 100) then
                out[#out + 1] = { a = a, cls = cls, X = l.X, Y = l.Y, Z = l.Z, P = r and r.Pitch or 0, Yw = r and r.Yaw or 0,
                                  R = r and r.Roll or 0 }
            end
        end
    end
    return out
end

local function line_of(p, path)
    return string.format("%s %s %.2f %.2f %.2f %.2f %.2f %.2f", p.cls, path or "-", p.X, p.Y, p.Z, p.P, p.Yw, p.R)
end

-- the spawner standing on a site (it spawns its prefab at its own transform)
local function spawner_at(l)
    for _, s in ipairs(util.instances(SPAWNER, { SPAWNER_PATH })) do
        local sl
        pcall(function() sl = s:K2_GetActorLocation() end)
        if sl and util.valid(s) and util.dist(sl, l) < SAME then return s end
    end
    return nil
end

local function text_of(t)
    local s = ""
    pcall(function() s = t:ToString() end)
    return (tostring(s or ""):gsub("[\t\n\r]", " "))
end

-- "\t<texture>\t<discover distance>\t<marker? 1|0>\t<title>\t<description>" from the host's spawner of the site
local function marker_info(l)
    local s = spawner_at(l)
    if not s then return "" end
    local tex, dist, on, title, desc = "-", 0, false, "", ""
    pcall(function() local t = s["Marker Texture"]; if util.valid(t) then tex = t:GetFullName():match("^%S+ (.+)$") or "-" end end)
    pcall(function() dist = tonumber(s.DistanceToDiscoverPrefab) or 0 end)
    pcall(function() on = s["Marker?"] == true end)
    pcall(function() title = text_of(s["Marker Title"]) end)
    pcall(function() desc = text_of(s["Marker Description"]) end)
    return string.format("\t%s\t%.0f\t%d\t%s\t%s", tex, dist, on and 1 or 0, title, desc)
end

local function host_tick()
    local lines = {}
    for _, p in ipairs(present()) do lines[#lines + 1] = line_of(p, util.class_path(p.a)) .. marker_info(p) end
    table.sort(lines)
    local body = #lines > 0 and table.concat(lines, "\n") or "-"
    if body ~= last_sent then
        last_sent, stats.sent = body, #lines
        link.put_blob("prefabs", body)
        log.info("prefabs: the host's event sites: " .. #lines)
    end
end

local function parse(body)
    local out = {}
    for line in (body or ""):gmatch("[^\n]+") do
        local base, tail = line:match("^([^\t]*)(.*)$")
        local cls, path, x, y, z, p, yw, r = base:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
        if cls and followed(cls) then
            local tex, dist, on, title, desc = tail:match("^\t([^\t]*)\t([^\t]*)\t([01])\t([^\t]*)\t(.*)$")
            out[#out + 1] = { cls = cls, path = path, X = tonumber(x), Y = tonumber(y), Z = tonumber(z), P = tonumber(p) or 0,
                              Yw = tonumber(yw) or 0, R = tonumber(r) or 0, key = base,
                              mk = tex and { tex = tex, dist = tonumber(dist) or 0, on = on == "1", title = title, desc = desc } or nil }
        end
    end
    return out
end

local function minimap_drop(m)
    local cc = StaticFindObject(MINIMAP)
    local c
    pcall(function() c = require("mirror.game").player():GetComponentByClass(cc) end)
    if util.valid(c) then pcall(function() c["Remove World Marker"](c, m.Marker, m) end) end
    pcall(function() m:K2_DestroyActor() end)
end

-- a site this game removed: its spawner goes too (its timer would discover a site that isn't there), marker and all
local function drop_spawner(l)
    local s = spawner_at(l)
    if not s then return end
    local m
    pcall(function() m = s.Marker end)
    if util.valid(m) then minimap_drop(m) end
    pcall(function() s:K2_DestroyActor() end)
end

-- a host's site placed here: the marker the game would show for it
local function show_marker(w)
    local crumb = require("mirror.crumb")
    crumb.at("prefabs.marker find spawner")
    local s = spawner_at(w)
    if s then
        -- (this game's own spawner of the site: its own marker, its own discovery and XP)
        crumb.at("prefabs.marker own spawner SpawnMarker")
        pcall(function() s["Spawned?"] = true end)
        pcall(function() s:SpawnMarker() end)
        crumb.at("prefabs.marker own spawner timer")
        pcall(function() util.cdo(KSL):K2_SetTimer(s, "DistanceToPrefab", 4.0, true, false, 0.0, 0.0) end)
        crumb.at("prefabs")
        return
    end
    crumb.at("prefabs")
    -- No spawner here for the host's site: no map icon. Spawning BP_Marker from Lua with the spawner's look written
    -- into its class defaults (texture, FText title/description, size, colour) crashed the guest natively inside
    -- that SpawnActor at every join (kit 2026-10-28 21:22 + 21:27, crumb "prefabs.marker spawn", AV through a junk
    -- pointer) - DBG-20261028-004. A safe way to show these needs the game's own call (BPC_MinimapSystem), not a CDO.
    if w.mk and w.mk.on then
        stats.no_marker = stats.no_marker + 1
        log.every("prefabs.nomarker", 300, "prefabs: the host's event site at " .. string.format("%.0f, %.0f", w.X, w.Y)
            .. " has no spawner here - no map icon for it")
    end
end

-- what to change: the guest's prefabs the host doesn't have, and the host's this game lacks
local function diff(have, host)
    local used, extra, missing = {}, {}, {}
    for _, w in ipairs(host) do
        local hit
        for i, p in ipairs(have) do
            if not used[i] and p.cls == w.cls and util.dist(p, w) < SAME then hit = i; break end
        end
        if hit then used[hit] = true else missing[#missing + 1] = w end
    end
    for i, p in ipairs(have) do if not used[i] then extra[#extra + 1] = p end end
    return extra, missing
end

local function fix(extra, missing)
    local steps = 0
    for _, p in ipairs(extra) do
        if steps >= MAX_STEPS then return end
        steps = steps + 1
        destroyed[util.addr(p.a) or 0] = true
        drop_spawner(p)
        if pcall(function() p.a:K2_DestroyActor() end) then
            stats.removed = stats.removed + 1
            log.info("prefabs: removed " .. p.cls .. " - the host's world doesn't have it")
        end
    end
    for _, w in ipairs(missing) do
        if steps >= MAX_STEPS then return end
        if not spawned_here[w.key] then
            -- (only a class already loaded here: loading one from Lua can stall the game, L-014; tried again later)
            local cls = w.path ~= "-" and StaticFindObject(w.path) or nil
            if not util.valid(cls) then
                log.every("prefabs.nocls." .. w.cls, 60, "prefabs: " .. w.cls .. " isn't loaded here - not spawning it yet")
            elseif not loottables.ready() then
                -- (its containers' BeginPlay would load the missing loot tables inside our SpawnActor: loottables.lua)
                log.every("prefabs.tables", 60, string.format("prefabs: %d container loot table(s) not loaded yet - "
                    .. "the host's event sites come once the game has them", loottables.missing()))
            else
                steps = steps + 1
                spawned_here[w.key] = true
                local a
                pcall(function()
                    a = require("mirror.game").world():SpawnActor(cls, { X = w.X, Y = w.Y, Z = w.Z }, util.rot(w.P, w.Yw, w.R))
                end)
                if util.valid(a) then
                    stats.spawned = stats.spawned + 1
                    log.info(string.format("prefabs: %s at %.0f, %.0f, %.0f like in the host's world", w.cls, w.X, w.Y, w.Z))
                    util.safe(show_marker, "prefabs.marker", w)
                end
            end
        end
    end
end

local function guest_tick()
    local body = peer_live() and link.get_blob("prefabs") or nil
    if body then want = parse(body) end
    if not want or joined_for < SETTLE then return end
    local extra, missing = diff(present(), want)
    local todo = {}
    for _, m in ipairs(missing) do if not spawned_here[m.key] then todo[#todo + 1] = m end end
    if #extra == 0 and #todo == 0 then pending = nil; return end
    -- the game's spawners may still be rolling: act only on a mismatch that is still there next check
    local sig = #extra .. "|" .. #todo
    if pending ~= sig then pending = sig; return end
    fix(extra, todo)
end

function prefabs.tick(dt)
    if role == "guest" and session and session.in_world() then joined_for = joined_for + dt
    elseif role == "guest" then joined_for, pending = 0.0, nil end
    tick_in = tick_in - dt
    if tick_in > 0 then return end
    tick_in = CHECK_EVERY
    if role == "host" then util.safe(host_tick, "prefabs.host")
    elseif role == "guest" and session and session.in_world() then util.safe(guest_tick, "prefabs.guest") end
end

function prefabs.status()
    if role == "host" then return "prefabs: sending " .. stats.sent .. " event site(s)" end
    return string.format("prefabs: removed %d, spawned %d (%d without a map icon here)", stats.removed, stats.spawned, stats.no_marker)
end

function prefabs.init(c, r, s, connected)
    role, session = r, s
    peer_live = connected or peer_live
    if c and c.prefab_sync == false then role = "off" end
    require("mirror.game").on_world_reset(prefabs.forget)
    last_sent, want, pending, joined_for = nil, nil, nil, 0.0
end

-- a new world: its objects are new (an old address may come back as another actor)
function prefabs.forget() destroyed, spawned_here, pending, last_sent = {}, {}, nil, nil end

return prefabs
