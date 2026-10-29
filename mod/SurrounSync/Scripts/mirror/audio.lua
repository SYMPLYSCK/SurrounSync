-- Shares sounds that only play on one screen: AI growls and shots near the guest, tool sounds.

local log = require("mirror.log")
local util = require("mirror.util")
local crumb = require("mirror.crumb")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local peers = require("mirror.peers")
local events = require("mirror.events")

local audio = {}

local GS = "/Script/Engine.GameplayStatics:"
local KIND = { PlaySoundAtLocation = "at", SpawnSoundAtLocation = "at", SpawnSoundAttached = "attached" }
local SKIP = { "Footstep", "footstep", "Sprint", "Grass_Cue", "Dirt_Cue", "Concrete_Cue", "Wood_Cue", "Metal_Cue",
               "Water_Cue", "Death", "Hit", "Impact", "Flesh", "Bite", "explosion", "Explosion", "CarLand",
               "VehicleCollision", "door", "Door", "UI_",
               "DogBark", "DogGrowl" }   -- (dogs.lua barks in each game for its own player's hounds)
local MAX_PER_S = 25
local NEAR_CM = 400

local cfg, role, session, zombies, fire
local channel = events.new("audio", 64, 3)
local hooked = {}
local playing = false
local queue = {}
local sent_this_s, sec_at = 0, 0
local cache, missing = {}, {}
local stats = { sent = 0, played = 0 }
local why = {}
local function drop(r) why[r] = (why[r] or 0) + 1 end

local function shared() return role == "host" or (session and session.in_world()) end

-- Sounds are long-lived assets: their paths are cached by address.
local paths, paths_n = {}, 0
local function path_of(o)
    if not util.valid(o) then return nil end
    local a = util.addr(o)
    local p = a and paths[a]
    if p then return p end
    pcall(function() p = o:GetFullName():match("^%S+ (.+)$") end)
    if p and a then
        if paths_n > 1024 then paths, paths_n = {}, 0 end
        paths[a], paths_n = p, paths_n + 1
    end
    return p
end

-- Sounds the player's own actions make (reload, bolt, insert, tools) are often 2D cues - no attenuation, since
-- only the player hears them. Replayed for the other player they'd sound right next to them at any distance:
-- give such cues one of the game's own attenuations.
local ATT = "/Game/Audio/Attenuation/"
local ATT_LOUD = { "GunshotsRifle", "GunshotsPistol", "GunshotsShotgun" }
local ATT_NEAR = { "DoorOpeningClosing", "FootSteps", "BulletImpact" }
local att_of, att_obj, att_warned = {}, {}, false
local function att_asset(list)
    for _, n in ipairs(list) do
        local p = ATT .. n .. "." .. n
        local a = util.cached(att_obj, p)
        if not a then a = StaticFindObject(p); att_obj[p] = util.valid(a) and a or nil end
        if att_obj[p] then return att_obj[p] end
    end
    return nil
end
function audio.attenuation_for(snd, path)
    if not util.valid(snd) then return nil end
    local key = path or path_of(snd) or tostring(util.addr(snd))
    local a = att_of[key]
    if a == nil then
        local own = false
        pcall(function() own = util.valid(snd.AttenuationSettings) or snd.bOverrideAttenuation == true end)
        if own then a = false
        else
            local n = (key:match("[^%./]+$") or key):lower()
            local handling = false
            for _, w in ipairs({ "insert", "reload", "chamber", "bolt", "draw", "empty", "mag", "equip" }) do
                if n:find(w, 1, true) then handling = true; break end
            end
            local loud = not handling and (n:find("shot", 1, true) or n:find("fire", 1, true) or n:find("boom", 1, true)
                or n:find("explo", 1, true) or n:find("firecracker", 1, true))
            a = att_asset(loud and ATT_LOUD or ATT_NEAR)
            -- Not loaded yet: don't remember the miss, ask again next time.
            if not a and not att_warned then att_warned = true; log.warn("audio: no attenuation asset loaded yet - 2D sounds stay 2D for now") end
        end
        if a ~= nil then att_of[key] = a end
    end
    return a or nil
end

-- Sounds this game played itself, to drop a replay of the same sound at the same spot (both games played it).
local recent = {}
local RECENT_S, RECENT_CM = 1.5, 300
local function remember(path, l)
    local t = os.clock()
    while #recent > 0 and t - recent[1].t > RECENT_S do table.remove(recent, 1) end
    if #recent < 96 then recent[#recent + 1] = { path = path, l = l, t = t } end
end
local function played_here(path, l)
    local t = os.clock()
    for _, r in ipairs(recent) do
        if r.path == path and t - r.t <= RECENT_S and util.dist(r.l, l) <= RECENT_CM then return true end
    end
    return false
end

local function skipped(name)
    for _, s in ipairs(SKIP) do if name:find(s, 1, true) then return true end end
    return false
end

local function chain(obj)
    local a, o
    pcall(function() a = obj:GetOwner() end)
    if not util.valid(a) or (util.class_name(obj) or ""):find("^BP_") then a = obj end
    pcall(function() o = a:GetOwner() end)
    return a, o
end

local function send(snd, l, vol, pitch, copy)
    local now = os.clock()
    if now - sec_at >= 1 then sec_at, sent_this_s = now, 0 end
    if sent_this_s >= MAX_PER_S then return end
    sent_this_s = sent_this_s + 1
    channel:send(string.format("%s %.0f %.0f %.0f %.2f %.2f%s", snd, l.X, l.Y, l.Z, vol or 1, pitch or 1, copy and (" " .. copy) or ""))
    stats.sent = stats.sent + 1
end

local function on_sound(kind, ctx, snd, l, vol, pitch)
    if playing then return end
    if not shared() then drop("notshared"); return end
    if not util.valid(snd) or not util.valid(ctx) then drop("invalid"); return end
    local name = ""
    pcall(function() name = util.fname(snd) end)
    if skipped(name) then drop("skip"); return end
    local path0 = path_of(snd)
    if path0 and l then remember(path0, l) end
    local a, owner = chain(ctx)
    if not util.valid(a) or peers.is_ghost(a) or peers.is_ghost(owner) then return end
    if zombies.is_copy(a) or zombies.is_copy(owner) then return end
    local cls = util.class_name(a) or ""
    if cls:find("^AnimBP_") or cls:find("Throwable") then return end
    local path = path_of(snd)
    if not path or not l then drop(not path and "nopath" or "noloc"); return end
    if role == "host" then
        local id = zombies.host_id_of(a) or (util.valid(owner) and zombies.host_id_of(owner))
        if id then
            if not name:lower():find("shot", 1, true) then send(path, l, vol, pitch, id) end
            return
        end
    end
    local p = game.player()
    local mine = util.same(owner, p) or (util.same(a, p) and not util.same(ctx, p))
    -- One-shot sounds of things the player uses (containers, tools, cars, builds) come from those actors.
    -- (Not with the player as the context: that's how this mod replays the other player's sounds.)
    if not mine and kind == "at" and not util.same(ctx, p) and not zombies.family_of(a) and not zombies.family_of(owner) then
        local pl
        pcall(function() pl = p:K2_GetActorLocation() end)
        mine = pl ~= nil and util.dist(pl, l) <= NEAR_CM
    end
    if mine then
        queue[#queue + 1] = { path = path, l = l, vol = vol, pitch = pitch, at = os.clock() }
    end
end

local function vec_of(v)
    local r
    pcall(function() r = { X = v.X, Y = v.Y, Z = v.Z } end)
    return r
end

local function hook_all()
    for fn, kind in pairs(KIND) do
        if not hooked[fn] then
            hooked[fn] = true
            local ok = pcall(function()
                local step, after = "hook audio " .. fn, "game (after hook audio " .. fn .. ")"
                RegisterHook(GS .. fn, function(self, a, b, c, d, e, f, g, h, i)
                    local ctx, snd, l, vol, pitch
                    if kind == "attached" then
                        snd, ctx = util.obj(a), util.obj(b)
                        if ctx then pcall(function() l = vec_of(ctx:K2_GetComponentLocation()) end) end
                        pcall(function() vol, pitch = h:get(), i:get() end)
                    else
                        ctx, snd = util.obj(a), util.obj(b)
                        pcall(function() l = vec_of(c:get()) end)
                        pcall(function() vol, pitch = e:get(), f:get() end)
                    end
                    local prev = crumb.current()
                    crumb.at(step)
                    util.safe(on_sound, "audio.sound", kind, ctx, snd, l, tonumber(vol), tonumber(pitch))
                    crumb.leave(prev, after)
                end)
            end)
            log.info("audio: hook " .. fn .. (ok and " on" or " FAILED"))
        end
    end
end

local function sound(path)
    local s = util.cached(cache, path)
    if s then return s end
    if os.clock() < (missing[path] or 0) then return nil end
    s = StaticFindObject(path)
    if util.valid(s) then cache[path] = s; return s end
    missing[path] = os.clock() + 30
    return nil
end

local function play(payload)
    local path, x, y, z, vol, pitch, copy = payload:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) ?(%d*)$")
    if not path then return end
    local s = sound(path)
    if not s then return end
    local l = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    if played_here(path, l) then drop("dupe"); return end
    if copy ~= "" then
        local c = zombies.copy(tonumber(copy))
        if c and util.valid(c.z) then pcall(function() l = vec_of(c.z.Mesh:K2_GetComponentLocation()) or l end) end
    end
    local gs = util.cdo("/Script/Engine.Default__GameplayStatics")
    playing = true
    pcall(function()
        gs:PlaySoundAtLocation(game.player(), s, l, { Pitch = 0, Yaw = 0, Roll = 0 }, tonumber(vol) or 1, tonumber(pitch) or 1, 0.0,
            audio.attenuation_for(s, path), nil, nil, nil)
    end)
    playing = false
    stats.played = stats.played + 1
end

function audio.tick(dt)
    if role == "off" then return end
    util.safe(hook_all, "audio.hook")
    local now, keep = os.clock(), {}
    for _, q in ipairs(queue) do
        if now - q.at < 0.1 then keep[#keep + 1] = q
        elseif math.abs((fire.last_shot or -100) - q.at) > 0.3 then send(q.path, q.l, q.vol, q.pitch) end
    end
    queue = keep
    local hear = require("mirror.mysettings").on("sounds")
    channel:pump(function(p) if hear and shared() then util.safe(play, "audio.play", p) end end)
end

function audio.status()
    local t = {}
    for k, v in pairs(why) do t[#t + 1] = k .. "=" .. v end
    return string.format("sounds sent %d, played %d (dropped %s)", stats.sent, stats.played, table.concat(t, " "))
end

function audio.init(c, r, s, z, f)
    cfg, role, session, zombies, fire = c, r, s, z, f
    game.on_world_reset(function() paths, paths_n, att_of, att_obj, recent, queue, cache = {}, 0, {}, {}, {}, {}, {} end)
    if cfg.audio_sync == false then role = "off" end
    log.info("audio: " .. (role == "off" and "off" or "AI and tool sounds are shared"))
end

return audio
