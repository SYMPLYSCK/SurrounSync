-- Shares sounds that only play on one screen: AI growls and shots near the guest, tool sounds.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local events = require("mirror.events")

local audio = {}

local GS = "/Script/Engine.GameplayStatics:"
local KIND = { PlaySoundAtLocation = "at", SpawnSoundAtLocation = "at", SpawnSoundAttached = "attached" }
local SKIP = { "Footstep", "footstep", "Sprint", "Grass_Cue", "Dirt_Cue", "Concrete_Cue", "Wood_Cue", "Metal_Cue",
               "Water_Cue", "Death", "Hit", "Impact", "Flesh", "Bite", "explosion", "Explosion", "CarLand",
               "VehicleCollision", "door", "Door", "UI_" }
local MAX_PER_S = 25

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

local function path_of(o)
    local p
    pcall(function() p = o:GetFullName():match("^%S+ (.+)$") end)
    return p
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
    pcall(function() name = snd:GetFName():ToString() end)
    if skipped(name) then drop("skip"); return end
    local a, owner = chain(ctx)
    if not util.valid(a) or ghost.is(a) or ghost.is(owner) then return end
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
    if util.same(owner, p) or (util.same(a, p) and not util.same(ctx, p)) then
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
                RegisterHook(GS .. fn, function(self, a, b, c, d, e, f, g, h, i)
                    local ctx, snd, l, vol, pitch
                    if kind == "attached" then
                        pcall(function() snd = a:get() end)
                        pcall(function() ctx = b:get() end)
                        pcall(function() l = vec_of(ctx:K2_GetComponentLocation()) end)
                        pcall(function() vol, pitch = h:get(), i:get() end)
                    else
                        pcall(function() ctx = a:get() end)
                        pcall(function() snd = b:get() end)
                        pcall(function() l = vec_of(c:get()) end)
                        pcall(function() vol, pitch = e:get(), f:get() end)
                    end
                    util.safe(on_sound, "audio.sound", kind, ctx, snd, l, tonumber(vol), tonumber(pitch))
                end)
            end)
            log.info("audio: hook " .. fn .. (ok and " on" or " FAILED"))
        end
    end
end

local function sound(path)
    local s = cache[path]
    if util.valid(s) then return s end
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
    if copy ~= "" then
        local c = zombies.copy(tonumber(copy))
        if c and util.valid(c.z) then pcall(function() l = vec_of(c.z.Mesh:K2_GetComponentLocation()) or l end) end
    end
    local gs = util.cdo("/Script/Engine.Default__GameplayStatics")
    playing = true
    pcall(function()
        gs:PlaySoundAtLocation(game.player(), s, l, { Pitch = 0, Yaw = 0, Roll = 0 }, tonumber(vol) or 1, tonumber(pitch) or 1, 0.0, nil, nil, nil, nil)
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
    channel:pump(function(p) if shared() then util.safe(play, "audio.play", p) end end)
end

function audio.status()
    local t = {}
    for k, v in pairs(why) do t[#t + 1] = k .. "=" .. v end
    return string.format("sounds sent %d, played %d (dropped %s)", stats.sent, stats.played, table.concat(t, " "))
end

function audio.init(c, r, s, z, f)
    cfg, role, session, zombies, fire = c, r, s, z, f
    if cfg.audio_sync == false then role = "off" end
    log.info("audio: " .. (role == "off" and "off" or "AI and tool sounds are shared"))
end

return audio
