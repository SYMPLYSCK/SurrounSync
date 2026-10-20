-- Shared helpers: hooks, object checks, vectors, error handling.

local log = require("mirror.log")

local util = {}

local SEEN_ERR_MAX = 256
local seen_err, seen_n = {}, 0
local errors = 0
function util.error_count() return errors end
function util.safe(fn, context, ...)
    local ok, res = pcall(fn, ...)
    if not ok then
        local key = (context or "?") .. "|" .. tostring(res)
        local e, t = seen_err[key], os.clock()
        if not e then
            if seen_n >= SEEN_ERR_MAX then seen_err, seen_n = {}, 0 end
            seen_err[key], seen_n = { last = t, repeats = 0 }, seen_n + 1
            errors = errors + 1
            log.warn(string.format("safe() caught in %s: %s", context or "?", tostring(res)))
        else
            e.repeats = e.repeats + 1
            if t - e.last >= 10 then
                log.warn(string.format("safe() caught in %s (x%d in %.0f s): %s", context or "?", e.repeats, t - e.last, tostring(res)))
                e.last, e.repeats = t, 0
            end
        end
    end
    return ok, res
end

-- UE4SS refuses engine calls from coroutines, so jobs just run right away.
function util.job(name, fn, ...) fn(...); return true end
function util.job_running(name) return false end
function util.pause() end
function util.jobs_tick() end

-- UE4SS hands out non-nil wrappers for null objects; any method on one but
-- IsValid reads through a null pointer and kills the game (pcall can't catch it).
function util.valid(obj)
    local t = type(obj)
    if t ~= "userdata" and t ~= "table" then return false end
    local ok, v = pcall(obj.IsValid, obj)
    return ok and v == true
end

-- Object-typed hook parameter -> valid object or nil.
function util.obj(param)
    local t = type(param)
    if t ~= "userdata" and t ~= "table" then return nil end
    local ok, o = pcall(param.get, param)
    if ok and util.valid(o) then return o end
    return nil
end

function util.class_path(obj)
    if not util.valid(obj) then return nil end
    local ok, c = pcall(obj.GetClass, obj)
    if not (ok and c) then return nil end
    local ok2, n = pcall(c.GetFullName, c)
    return ok2 and type(n) == "string" and n:match("^%S+ (.+)$") or nil
end

-- Object addresses get reused after GC: don't use them as long-lived ids.
function util.addr(obj)
    if not util.valid(obj) then return nil end
    local ok, a = pcall(function() return obj:GetAddress() end)
    return ok and a or nil
end

function util.same(a, b)
    local x, y = util.addr(a), util.addr(b)
    return x ~= nil and x == y
end

function util.class_name(obj)
    if not util.valid(obj) then return nil end
    local ok, c = pcall(obj.GetClass, obj)
    if not (ok and c) then return nil end
    local ok2, n = pcall(function() return c:GetFName():ToString() end)
    return ok2 and n or nil
end

-- FindAllOf walks every object in the game; lookups of the same class share one result for a few seconds.
local all_cache, ALL_TTL = {}, 5.0
function util.all_of(cls, max_age)
    local t = os.clock()
    local c = all_cache[cls]
    if c and t - c.at <= (max_age or ALL_TTL) then return c.list, t - c.at end
    local list = {}
    pcall(function() list = FindAllOf(cls) or {} end)
    all_cache[cls] = { at = t, list = list }
    return list, 0
end

local function nearest_of(list, gx, gy, gz, near)
    local best, best_d = nil, near or -1
    pcall(function()
        for _, o in ipairs(list) do
            if util.valid(o) and not o:GetFullName():find("Default__", 1, true) then
                local ok, l = pcall(function() return o:K2_GetActorLocation() end)
                if ok and l then
                    local x, y, z = math.floor(l.X / 10 + 0.5) * 10, math.floor(l.Y / 10 + 0.5) * 10, math.floor(l.Z / 10 + 0.5) * 10
                    if x == gx and y == gy and z == gz then best = o; return end
                    local d = math.sqrt((l.X - gx) ^ 2 + (l.Y - gy) ^ 2 + (l.Z - gz) ^ 2)
                    if d < best_d then best, best_d = o, d end
                end
            end
        end
    end)
    return best
end

function util.find_by_id(id, near)
    local cls, gx, gy, gz = id:match("^([^@]+)@(%-?%d+),(%-?%d+),(%-?%d+)$")
    if not cls then return nil end
    gx, gy, gz = tonumber(gx) * 10, tonumber(gy) * 10, tonumber(gz) * 10
    local list, age = util.all_of(cls)
    local best = nearest_of(list, gx, gy, gz, near)
    if not best and age > 0.5 then best = nearest_of(util.all_of(cls, 0), gx, gy, gz, near) end
    return best
end

function util.vec(v)
    return { X = v.X, Y = v.Y, Z = v.Z }
end

function util.dist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function util.lerp(a, b, t) return a + (b - a) * t end

function util.lerp_angle(a, b, t)
    local d = (b - a + 180) % 360 - 180
    return a + d * t
end

function util.callsite(level)
    local info = debug.getinfo((level or 2) + 1, "Sl")
    return info and (tostring(info.short_src) .. ":" .. tostring(info.currentline)) or nil
end

local hook_slots = {}
function util.hook(path, pre, post, force)
    local site = util.callsite(2)
    local key = site and (path .. "@" .. site) or nil
    local slot = key and hook_slots[key]
    if slot and not force then
        slot.pre, slot.post = pre, post
        return true
    end
    slot = { pre = pre, post = post }
    if key then hook_slots[key] = slot end
    local tramp_pre = function(...) if slot.pre then return slot.pre(...) end end
    local tramp_post = post and function(...) if slot.post then return slot.post(...) end end or nil
    local ok, err = pcall(function()
        if tramp_post then RegisterHook(path, tramp_pre, tramp_post) else RegisterHook(path, tramp_pre) end
    end)
    if ok then log.info("hooked " .. path) else log.warn("could not hook " .. path .. ": " .. tostring(err)) end
    return ok
end

local hooked_fn = {}
local next_check = {}
local backoff = {}
local RECHECK, LOOKUPS_PER_FRAME, MAX_BACKOFF = 15.0, 1, 60
local lookups, lookup_frame, frame_no = 0, -1, 0
local lookup_count = {}
function util.recheck_hooks() next_check, backoff = {}, {} end
function util.new_frame() frame_no = frame_no + 1 end
function util.ensure_hook(path, pre, post)
    local t = os.clock()
    local hk = path .. "|" .. tostring(pre)
    if next_check[hk] and t < next_check[hk] then return hooked_fn[hk] ~= nil end
    if lookup_frame ~= frame_no then lookup_frame, lookups = frame_no, 0 end
    if lookups >= LOOKUPS_PER_FRAME and next_check[hk] then return hooked_fn[hk] ~= nil end
    lookups = lookups + 1
    lookup_count[path] = (lookup_count[path] or 0) + 1
    local fn = StaticFindObject(path)
    if not util.valid(fn) then
        backoff[hk] = math.min((backoff[hk] or 1) * 2, MAX_BACKOFF)
        next_check[hk] = t + backoff[hk]
        return false
    end
    backoff[hk] = nil
    next_check[hk] = t + RECHECK
    local a = util.addr(fn)
    if hooked_fn[hk] == a then return true end
    if util.hook(path, pre, post, true) then hooked_fn[hk] = a; return true end
    return false
end

function util.lookup_top(n)
    local t = {}
    for p, c in pairs(lookup_count) do t[#t + 1] = { p = p, c = c } end
    table.sort(t, function(a, b) return a.c > b.c end)
    local out = {}
    for i = 1, math.min(n, #t) do out[#out + 1] = t[i].c .. " " .. t[i].p end
    return #t .. " paths; " .. table.concat(out, " | ")
end

function util.hook_state(path)
    local hooked = {}
    for k, a in pairs(hooked_fn) do if k:sub(1, #path + 1) == path .. "|" then hooked[#hooked + 1] = tostring(a) end end
    return string.format("next check in %s s, backoff %s, hooked %s, found now %s",
        (function() for k, v in pairs(next_check) do if k:sub(1, #path + 1) == path .. "|" then return string.format("%.1f", v - os.clock()) end end return "-" end)(), "-",
        #hooked > 0 and table.concat(hooked, ",") or "no", tostring(util.valid(StaticFindObject(path))))
end

local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
function util.rot(pitch, yaw, roll)
    rot.Pitch, rot.Yaw, rot.Roll = pitch or 0, yaw or 0, roll or 0
    return rot
end

function util.move(actor, loc, yaw)
    local ok, moved = pcall(function() return actor:K2_TeleportTo(loc, util.rot(0, yaw, 0)) end)
    return ok and moved ~= false
end

local cdo_cache = {}
function util.cdo(path)
    local o = cdo_cache[path]
    if util.valid(o) then return o end
    o = StaticFindObject(path)
    if util.valid(o) then cdo_cache[path] = o; return o end
    return nil
end

return util
