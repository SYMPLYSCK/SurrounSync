-- Shared helpers: hooks, object checks, vectors, error handling.

local log = require("mirror.log")
local crumb = require("mirror.crumb")

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

-- An object's name, or nil. GetFName on a wrapper around NULL is a native crash pcall can't catch
-- (UE4SS GetNamePrivate on NULL, AV 0x18: six crashes in tick code 2026-10-24) - always check first.
function util.fname(obj)
    if not util.valid(obj) then return nil end
    local ok, n = pcall(function() return obj:GetFName():ToString() end)
    return ok and n or nil
end

function util.class_name(obj)
    if not util.valid(obj) then return nil end
    local ok, c = pcall(obj.GetClass, obj)
    if not (ok and util.valid(c)) then return nil end
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

-- id -> the object found for it last time (a walk is 30-40 ms; events for one container come in runs)
local by_id, id_of_addr = {}, {}
local function forget_ids() by_id, id_of_addr = {}, {} end
function util.find_by_id(id, near)
    local cls, gx, gy, gz = id:match("^([^@]+)@(%-?%d+),(%-?%d+),(%-?%d+)$")
    if not cls then return nil end
    gx, gy, gz = tonumber(gx) * 10, tonumber(gy) * 10, tonumber(gz) * 10
    local c = by_id[id]
    if c then
        if util.addr(c.o) == c.a and util.class_name(c.o) == cls and nearest_of({ c.o }, gx, gy, gz, near) then return c.o end
        by_id[id], id_of_addr[c.a] = nil, nil
    end
    local list, age = util.all_of(cls)
    local best = nearest_of(list, gx, gy, gz, near)
    if not best and age > 0.5 then best = nearest_of(util.all_of(cls, 0), gx, gy, gz, near) end
    local a = best and util.addr(best)
    if a then by_id[id], id_of_addr[a] = { o = best, a = a }, id end
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
    local short = path:match("([^%./]+:[^:]+)$") or path   -- Class_C:Function fits the 72-char crash step
    local in_pre, in_post, after = "hook " .. short, "hook post " .. short, "game (after hook " .. short .. ")"
    local tramp_pre = function(...)
        if not slot.pre then return end
        local prev = crumb.current()
        crumb.at(in_pre)
        local r = slot.pre(...)
        crumb.leave(prev, after)
        return r
    end
    local tramp_post = post and function(...)
        if not slot.post then return end
        local prev = crumb.current()
        crumb.at(in_post)
        local r = slot.post(...)
        crumb.leave(prev, after)
        return r
    end or nil
    local ok, err = pcall(function()
        if tramp_post then RegisterHook(path, tramp_pre, tramp_post) else RegisterHook(path, tramp_pre) end
    end)
    if ok then log.info("hooked " .. path) else log.warn("could not hook " .. path .. ": " .. tostring(err)) end
    return ok
end

local hooked_fn = {}
local hooked_obj = {}   -- hk -> the UFunction we hooked
local next_check = {}
local backoff = {}
-- One budget for ALL hook lookups (first ones too): ~160 hook paths looked up in one frame froze the game
-- 0.7-1.2 s at co-op start and after every join/leave load. A lookup runs while this frame's lookups took
-- under LOOKUP_MS (at least one per frame). A miss is shared by every function of that class: while
-- the class isn't loaded, its other functions skip their lookup too (each miss ~15 ms) - unless one of
-- them was found since the world load (then the class is there and only that function is missing).
local RECHECK, LOOKUP_MS, MAX_BACKOFF = 15.0, 2.0, 60   -- 60: a class that loads later (a placed beacon) gets hooked within a minute
local lookup_ms, lookup_frame, frame_no = 0, -1, 0
local lookup_count = {}
local class_miss, class_hit = {}, {}
function util.recheck_hooks() next_check, backoff, class_miss, class_hit = {}, {}, {}, {} end
function util.new_frame() frame_no = frame_no + 1 end
-- urgent: look it up now, outside the budget (a hook that must stand before the next level load)
function util.ensure_hook(path, pre, post, urgent)
    local t = os.clock()
    local hk = path .. "|" .. tostring(pre)
    if next_check[hk] and t < next_check[hk] then return hooked_fn[hk] ~= nil end
    -- StaticFindObject costs ~1.7 ms (a miss ~15 ms, measured in-game): while the function we hooked
    -- is still the live object of that name the hook stands - only a gone/replaced one needs a lookup
    local held = hooked_obj[hk]
    if held and util.valid(held) and util.addr(held) == hooked_fn[hk] then
        local same = false
        pcall(function() same = held:GetFName():ToString() == path:match("([^:]+)$") end)
        if same then next_check[hk] = t + RECHECK; return true end
    end
    local cls = path:match("^(.-):[^:]+$") or path
    local cm = class_miss[cls]
    if cm and t < cm and not urgent then return hooked_fn[hk] ~= nil end
    if lookup_frame ~= frame_no then lookup_frame, lookup_ms = frame_no, 0 end
    if lookup_ms >= LOOKUP_MS and not urgent then return hooked_fn[hk] ~= nil end
    lookup_count[path] = (lookup_count[path] or 0) + 1
    local fn = StaticFindObject(path)
    lookup_ms = lookup_ms + (os.clock() - t) * 1000
    if not util.valid(fn) then
        backoff[hk] = math.min((backoff[hk] or 1) * 2, MAX_BACKOFF)
        next_check[hk] = t + backoff[hk]
        if not class_hit[cls] then class_miss[cls] = math.max(class_miss[cls] or 0, next_check[hk]) end
        return false
    end
    class_hit[cls], class_miss[cls] = true, nil
    backoff[hk] = nil
    next_check[hk] = t + RECHECK
    local a = util.addr(fn)
    if hooked_fn[hk] == a then hooked_obj[hk] = fn; return true end
    if util.hook(path, pre, post, true) then hooked_fn[hk], hooked_obj[hk] = a, fn; return true end
    return false
end

-- Live lists of a class's objects. FindAllOf walks every object in the game (30-40 ms, a visible
-- hitch, worse in a big world): each class is walked once per world, then a ReceiveBeginPlay hook
-- adds new ones - BeginPlay also runs for level actors that stream in. `hooks` names the class(es)
-- whose BeginPlay to hook (the class itself or a parent - a parent's runs for its children too).
-- While that class isn't loaded nothing of it can exist, so nothing is walked; once it loads, the hook
-- goes in and one walk picks up what came before. Classes without a BeginPlay are re-walked every
-- TRACK_NO_HOOK s. At most one walk per frame, and re-walks at most one per TRACK_GAP s overall.
local TRACK_HOOKED, TRACK_UNHOOKED, TRACK_NO_HOOK, TRACK_GAP = 1800.0, 60.0, 300.0, 5.0
local tracked, track_hooks = {}, {}
local track_frame, track_rewalk_at = -1, -100
-- EndPlay: an ended object leaves every list at once. A freed object's slot is reused and its wrapper
-- still passes IsValid, so a list holding it until the next prune can call into a different object.
local end_fns, ended_n, end_hooked = {}, 0, false
function util.on_end(fn) end_fns[#end_fns + 1] = fn end
util.on_end(function(a)
    local id = id_of_addr[a]
    if id then by_id[id], id_of_addr[a] = nil, nil end
end)
local function on_end_play(self)
    local o
    pcall(function() o = self:get() end)
    local a = util.addr(o)
    if not a then return end
    for _, t in pairs(tracked) do
        if t.set[a] then t.set[a], t.gone = nil, true; ended_n = ended_n + 1 end
    end
    for _, fn in ipairs(end_fns) do pcall(fn, a) end
end
local function hook_end_play()
    if end_hooked then return end
    end_hooked = true
    -- classes without their own ReceiveEndPlay run the engine's (an override is hooked per class below)
    util.hook("/Script/Engine.Actor:ReceiveEndPlay", on_end_play, nil, true)
    util.hook("/Script/Engine.ActorComponent:ReceiveEndPlay", on_end_play, nil, true)
end
local function track_add(t, o)
    local a = util.addr(o)
    if a and not t.set[a] then t.set[a] = util.class_name(o) or true; t.list[#t.list + 1] = o end
end
local function on_begin(self)
    local o
    pcall(function() o = self:get() end)
    if not util.valid(o) then return end
    local t = tracked[util.class_name(o) or ""]
    if t then track_add(t, o) end
end
-- Hooked, whether the first class is loaded at all, and a count of (re)hooks.
local function track_hooked(paths, clock)
    local on, loaded, gen = false, false, 0
    for i, p in ipairs(paths) do
        local h = track_hooks[p]
        if not h then h = { check = 0, on = false, loaded = false }; track_hooks[p] = h end
        if clock >= h.check then
            h.check = clock + (h.on and 15.0 or 2.0)
            local fn = StaticFindObject(p .. ":ReceiveBeginPlay")
            local a = util.valid(fn) and util.addr(fn) or nil
            h.loaded = a ~= nil or util.valid(StaticFindObject(p))
            -- loaded without a BeginPlay of its own: it won't get one, and each miss costs ~15 ms
            if not a and h.loaded then h.check = clock + 30.0 end
            if not a then h.on, h.addr = false, nil
            elseif a ~= h.addr then
                h.on = util.hook(p .. ":ReceiveBeginPlay", on_begin, nil, true) == true
                h.addr = h.on and a or nil
                if h.on then
                    h.gen = (h.gen or 0) + 1
                    -- (looked up once per class load: a miss costs ~15 ms)
                    local ef = StaticFindObject(p .. ":ReceiveEndPlay")
                    if util.valid(ef) then util.hook(p .. ":ReceiveEndPlay", on_end_play, nil, true) end
                end
            end
        end
        on, gen = on or h.on, gen + (h.gen or 0)
        if i == 1 then loaded = h.loaded end
    end
    return on, loaded, gen
end
function util.instances(cls, hooks)
    local t = tracked[cls]
    if not t then
        t = { list = {}, set = {}, due = 0, walked = false, pruned = 0,
              hooks = type(hooks) == "string" and { hooks } or hooks or {} }
        tracked[cls] = t
    end
    local clock = os.clock()
    hook_end_play()
    local loaded, gen = true, 0
    if #t.hooks > 0 then t.hooked, loaded, gen = track_hooked(t.hooks, clock) end
    if t.hooked and gen ~= t.walked_gen then t.due = 0 end   -- a hook just went in: catch what came before it
    if clock >= t.due and #t.hooks > 0 and not t.hooked and not loaded then
        t.list, t.set, t.walked, t.due = {}, {}, true, clock + 2.0
    elseif clock >= t.due and track_frame ~= frame_no and (not t.walked or clock - track_rewalk_at >= TRACK_GAP) then
        track_frame = frame_no
        if t.walked then track_rewalk_at = clock end
        local found = {}
        pcall(function() found = FindAllOf(cls) or {} end)
        t.list, t.set = {}, {}
        for _, o in ipairs(found) do
            local cdo = false
            pcall(function() cdo = o:GetFullName():find("Default__", 1, true) ~= nil end)
            if not cdo then track_add(t, o) end
        end
        if not t.logged then
            t.logged = true
            log.info(string.format("instances: %s - %d here, %s", cls, #t.list,
                #t.hooks > 0 and "new ones via BeginPlay" or "re-walked every " .. TRACK_NO_HOOK .. " s"))
        end
        t.walked, t.walked_gen = true, gen
        t.due = clock + (t.hooked and TRACK_HOOKED or #t.hooks > 0 and TRACK_UNHOOKED or TRACK_NO_HOOK)
        t.pruned = clock
    elseif t.gone or clock - t.pruned >= 1.0 then
        t.pruned, t.gone = clock, nil
        -- A freed object's address can come back as a different object: keep only the same class.
        local list, set = {}, {}
        for _, o in ipairs(t.list) do
            local a = util.addr(o)
            local c = a and t.set[a]
            if c and not set[a] and (c == true or util.class_name(o) == c) then set[a] = c; list[#list + 1] = o end
        end
        t.list, t.set = list, set
    end
    return t.list, t.walked
end
-- World reset: the old objects are freed - drop them untouched; every class is walked again.
function util.instances_reset()
    forget_ids()
    for _, t in pairs(tracked) do t.list, t.set, t.due, t.walked = {}, {}, 0, false end
end
function util.instances_status()
    local n, hooked, walked = 0, 0, 0
    for _, t in pairs(tracked) do
        n = n + 1
        if t.hooked then hooked = hooked + 1 end
        if t.walked then walked = walked + 1 end
    end
    return string.format("%d classes tracked, %d by BeginPlay, %d walked, %d ended", n, hooked, walked, ended_n)
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

-- A cached object found by path, or nil. IsValid alone can't tell a garbage-collected asset from a
-- new object the engine put at the same address and index - it then passes as the old one (a zombie
-- copy got a non-material as its material: native crash in the material relevance code, 4 reports) -
-- so a hit must still carry the path's own name.
function util.cached(cache, path)
    local o = cache[path]
    if o == nil then return nil end
    -- native (/Script) classes and their defaults are never collected: IsValid is enough there
    if util.valid(o) and (path:sub(1, 8) == "/Script/" or util.fname(o) == path:match("[^%.:]+$")) then return o end
    cache[path] = nil
    return nil
end

-- StaticFindObject with a positive AND a negative cache: a miss costs ~15 ms (measured in-game), and hot paths
-- (received shots, events, item adds) asked again for the same unloaded path every time. A missing path is asked
-- again 2 s after the miss, doubling up to 60 s; util.find_reset() (world load) forgets the misses.
local find_cache, find_missed = {}, {}
util.find_misses = 0
function util.find(path)
    if not path or path == "" or path == "-" then return nil end
    local o = util.cached(find_cache, path)
    if o then return o end
    local miss = find_missed[path]
    local now = os.clock()
    if miss and now < miss.at then return nil end
    o = StaticFindObject(path)
    if util.valid(o) then
        find_cache[path], find_missed[path] = o, nil
        return o
    end
    util.find_misses = util.find_misses + 1
    local wait = miss and math.min(miss.wait * 2, 60.0) or 2.0
    find_missed[path] = { at = now + wait, wait = wait }
    return nil
end
function util.find_reset() find_missed = {}; forget_ids() end

local cdo_cache = {}
function util.cdo(path)
    local o = util.cached(cdo_cache, path)
    if o then return o end
    o = StaticFindObject(path)
    if util.valid(o) then cdo_cache[path] = o; return o end
    return nil
end

return util
