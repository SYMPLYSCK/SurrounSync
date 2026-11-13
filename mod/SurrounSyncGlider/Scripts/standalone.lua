-- What SurrounSync's glider files (mirror/glider.lua, glideritem.lua, modrecipe.lua, copied in by
-- tools/make-glidermod.py) need from SurrounSync, for the glider on its own: a log, the object helpers, the player and
-- its frame tick, the inventory count. Only the parts the glider calls, written the way SurrounSync's modules do them
-- (util.lua, game.lua, jig.lua); the co-op parts (links, ghosts, notices) are empty: alone there is no other player.

local base = {}

local MODS = { "ue4ss\\Mods\\", "Mods\\" }   -- UE4SS's mod folder from the game's Win64 folder (new layout, old)
local PLAYER = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"

local function exists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

local function read(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

-- SurrounSync installed and switched on (its folder, with its enabled.txt or a 1 in mods.txt): it flies the glider
-- itself, in co-op too, so this copy stays off (two would each open one and set the speed twice a frame)
function base.surrounsync_on(roots)
    for _, m in ipairs(roots or MODS) do
        if exists(m .. "SurrounSync\\Scripts\\main.lua") then
            if exists(m .. "SurrounSync\\enabled.txt") then return true, m end
            local txt = read(m .. "mods.txt") or ""
            for line in txt:gmatch("[^\r\n]+") do
                if line:match("^%s*SurrounSync%s*:%s*1%s*$") then return true, m end
            end
        end
    end
    return false
end

-- log: the UE4SS console and SurrounSyncGlider_log.txt next to the game exe (a new one each run)
local function make_log()
    local log, out = {}, nil
    local function emit(level, msg)
        local line = string.format("[SurrounSyncGlider][%s] %s", level, msg)
        print(line .. "\n")
        if out == nil then out = io.open("SurrounSyncGlider_log.txt", "w") or false end
        if out then pcall(function() out:write(os.date("%H:%M:%S "), line, "\n"); out:flush() end) end
    end
    function log.error(m) emit("ERROR", m) end
    function log.warn(m) emit("WARN", m) end
    function log.info(m) emit("INFO", m) end
    function log.debug() end
    function log.trace() end
    local every_at = {}
    function log.every(key, secs, m)
        local t = os.clock()
        if every_at[key] and t < every_at[key] then return end
        every_at[key] = t + secs
        emit("INFO", m)
    end
    return log
end

local function make_util(log)
    local util = {}
    local seen = {}
    function util.safe(fn, context, ...)
        local ok, res = pcall(fn, ...)
        if not ok then
            local key = (context or "?") .. "|" .. tostring(res)
            local t = os.clock()
            if not seen[key] or t - seen[key] >= 10 then
                seen[key] = t
                log.warn(string.format("safe() caught in %s: %s", context or "?", tostring(res)))
            end
        end
        return ok, res
    end
    -- UE4SS hands out non-nil wrappers for null objects; only IsValid is safe to call on one
    function util.valid(obj)
        local t = type(obj)
        if t ~= "userdata" and t ~= "table" then return false end
        local ok, v = pcall(obj.IsValid, obj)
        return ok and v == true
    end
    local function get_addr(o) return o:GetAddress() end
    local function get_fname(o) return o:GetFName():ToString() end
    function util.addr(obj)
        if not util.valid(obj) then return nil end
        local ok, a = pcall(get_addr, obj)
        return ok and a or nil
    end
    function util.same(a, b)
        local x, y = util.addr(a), util.addr(b)
        return x ~= nil and x == y
    end
    function util.fname(obj)
        if not util.valid(obj) then return nil end
        local ok, n = pcall(get_fname, obj)
        return ok and n or nil
    end
    function util.class_name(obj)
        if not util.valid(obj) then return nil end
        local ok, c = pcall(obj.GetClass, obj)
        if not (ok and util.valid(c)) then return nil end
        local ok2, n = pcall(get_fname, c)
        return ok2 and n or nil
    end
    function util.vec(v) return { X = v.X, Y = v.Y, Z = v.Z } end
    -- a cached object, or nil when it went: IsValid alone passes for a new object at a collected asset's address
    local function cached(cache, path)
        local o = cache[path]
        if o == nil then return nil end
        if util.valid(o) and (path:sub(1, 8) == "/Script/" or util.fname(o) == path:match("[^%.:]+$")) then return o end
        cache[path] = nil
        return nil
    end
    -- StaticFindObject with a negative cache (a miss costs ~15 ms): a missing path is asked again 2 s later,
    -- doubling up to 60 s; util.find_reset() (a new world) forgets the misses
    local found, missed = {}, {}
    function util.find(path)
        if not path or path == "" then return nil end
        local o = cached(found, path)
        if o then return o end
        local miss, now = missed[path], os.clock()
        if miss and now < miss.at then return nil end
        o = StaticFindObject(path)
        if util.valid(o) then found[path], missed[path] = o, nil; return o end
        local wait = miss and math.min(miss.wait * 2, 60.0) or 2.0
        missed[path] = { at = now + wait, wait = wait }
        return nil
    end
    function util.find_reset() missed = {} end
    local cdos = {}
    function util.cdo(path)
        local o = cached(cdos, path)
        if o then return o end
        o = StaticFindObject(path)
        if util.valid(o) then cdos[path] = o; return o end
        return nil
    end
    -- arr:ForEach(fn) with arr kept alive (UE4SS lets Lua collect a temporary array while it loops: a native crash)
    function util.each(arr, fn)
        local keep = arr
        keep:ForEach(fn)
        return keep
    end
    return util
end

-- the local player, its controller and world, and a tick every frame from the player character's ReceiveTick
local function make_game(log, util)
    local game = {}
    local player, controller, world = nil, nil, nil
    local ticks, resets = {}, {}
    local installed = false
    function game.player() return player end
    function game.world() return world end
    function game.controller() return controller end
    function game.on_tick(fn) ticks[#ticks + 1] = fn end
    function game.on_world_reset(fn) resets[#resets + 1] = fn end
    function game.key_down(name)
        local r = false
        pcall(function() r = controller:IsInputKeyDown({ KeyName = FName(name) }) == true end)
        return r
    end

    local function adopt(pawn, pc)
        local old, old_world = player, world
        player, controller, world = pawn, pc, nil
        pcall(function() world = pawn:GetWorld() end)
        -- (a new pawn in the same, still-live world is a respawn there, not a new world)
        if old and util.valid(old) and old_world and util.same(old_world, world) then old = nil end
        util.find_reset()
        log.info((old and "new player (respawn/reload): " or "player is ") .. tostring(util.class_name(pawn)))
        if old then for _, fn in ipairs(resets) do util.safe(fn, "game.on_world_reset") end end
    end

    local last = nil
    local function on_tick(self, DeltaSeconds)
        local ctx = self:get()
        if not util.same(ctx, player) then
            local pc
            pcall(function() pc = ctx.Controller end)
            if not (util.valid(pc) and util.class_name(pc) == "BP_PlayerController_C") then return end
            adopt(ctx, pc)
        end
        -- (real time between frames, at most 0.25 s: a hitch never throws the glider a long step)
        local c = os.clock()
        local dt = last and math.min(math.max(c - last, 0.0), 0.25) or (DeltaSeconds:get() or 0)
        last = c
        for i = 1, #ticks do util.safe(ticks[i], "game.on_tick", dt) end
    end
    local tick_fn = function(self, dt) util.safe(on_tick, "game.tick", self, dt) end

    -- (the class can exist before its functions do: only a hook that took counts, a new character tries again)
    local function install()
        if installed then return end
        local ok, err = pcall(RegisterHook, PLAYER .. ":ReceiveTick", tick_fn)
        if ok then installed = true; log.info("hooked the player's tick") else log.warn("could not hook the player's tick yet: " .. tostring(err)) end
    end
    function game.init()
        if util.valid(StaticFindObject(PLAYER)) then util.safe(install, "game.install") end
        NotifyOnNewObject(PLAYER, function() util.safe(install, "game.install") end)
    end
    game._tick = on_tick
    return game
end

-- the inventory: a full asset path, and how many of an item the player's jig component holds (any grid, bags too)
local function make_jig(util)
    local jig = {}
    local ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
    local INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
    local ITEM_ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
    local COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD"
    function jig.full_path(obj)
        if not util.valid(obj) then return nil end
        local p
        pcall(function() p = obj:GetFullName():match("^%S+ (.+)$") end)
        return p
    end
    function jig.count_of_item(comp, da)
        local n = 0
        pcall(function()
            util.each(comp.MainJigContainers, function(_, c)
                util.each(c:get()[ITEMS], function(_, el)
                    pcall(function()
                        local info = el:get()[INFO]
                        if jig.full_path(info[ITEM_ID]) == da then n = n + (info[COUNT] or 1) end
                    end)
                end)
            end)
        end)
        return n
    end
    return jig
end

-- package.loaded gets the modules the glider files require; returns them (the tests read them)
function base.install()
    local log = make_log()
    local util = make_util(log)
    local game = make_game(log, util)
    local m = {
        ["mirror.log"] = log,
        ["mirror.util"] = util,
        ["mirror.game"] = game,
        ["mirror.jig"] = make_jig(util),
        -- alone: no other player, so no link, no ghost, my glide is the only one
        ["mirror.peers"] = { shared = function(_, init) return init end },
        ["mirror.events"] = { reliable = function() return nil end },
        ["mirror.ghost"] = { get = function() return nil end },
        -- (SurrounSync's on-screen notices; here the glider's log line says it)
        ["mirror.notify"] = { show = function() end },
    }
    for k, v in pairs(m) do package.loaded[k] = v end
    return m
end

return base
