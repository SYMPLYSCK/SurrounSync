-- Loads missing meshes and materials on the game thread, one at a time, with a crash guard.

local log = require("mirror.log")

local loader = {}

local INTERVAL = 3.0
local cfg, on = nil, false
local queue, queued, failed = {}, {}, {}
local next_at = 0.0
local guard, banned_file

local function saved_dir()
    local name = (cfg and cfg.phase2 and cfg.phase2.saved_override) or "Saved"
    return (os.getenv("LOCALAPPDATA") or ".") .. "\\SurrounDead\\" .. name
end

local function read_lines(path)
    local t = {}
    local f = io.open(path, "r")
    if f then for l in f:lines() do l = l:gsub("%s+$", ""); if l ~= "" then t[l] = true end end; f:close() end
    return t
end

local function loadable(path)
    if type(path) ~= "string" or path:sub(1, 6) ~= "/Game/" then return false end
    if path:find(":", 1, true) or path:find("_C$") or path:find("/Levels/", 1, true) then return false end
    local name = path:match("([^%./]+)$") or ""
    return name:find("^SK_") or name:find("^M_") or name:find("^MI_") or name:find("^Mat_") or name:find("^MID_") ~= nil
end

function loader.want(path)
    if not on or queued[path] or failed[path] or not loadable(path) then return end
    queued[path] = true
    queue[#queue + 1] = path
    log.info("loader: will load " .. (path:match("[^%./]+$") or path) .. " (" .. #queue .. " waiting)")
end

local said_busy = 0
function loader.tick(dt, busy)
    if not on or #queue == 0 then return end
    if busy then
        if os.clock() - said_busy > 30 then said_busy = os.clock(); log.info("loader: " .. #queue .. " waiting - the game is busy") end
        return
    end
    local t = os.clock()
    if t < next_at then return end
    next_at = t + INTERVAL
    local p = table.remove(queue, 1)
    if StaticFindObject(p) then return end
    local f = io.open(guard, "w")
    if f then f:write(p, "\n"); f:close() end
    local t0 = os.clock()
    local ok, err = pcall(function() LoadAsset(p) end)
    os.remove(guard)
    local found = false
    pcall(function() found = StaticFindObject(p):IsValid() end)
    if not found then failed[p] = true end
    log.info(string.format("loader: %s %s (%.0f ms)%s", p:match("[^%./]+$") or p, found and "loaded" or "NOT loaded",
        (os.clock() - t0) * 1000, ok and "" or (": " .. tostring(err))))
end

function loader.configure(c)
    cfg = c
    on = c and c.asset_loader ~= false
    if not on then return end
    guard = saved_dir() .. "\\mirror_loading.txt"
    banned_file = saved_dir() .. "\\mirror_load_banned.txt"
    local last = read_lines(guard)
    if next(last) then
        local f = io.open(banned_file, "a")
        if f then for p in pairs(last) do f:write(p, "\n") end; f:close() end
        os.remove(guard)
    end
    failed = read_lines(banned_file)
    if next(failed) then
        on = false
        log.warn("loader: an asset load took the game down before - loading zombie looks stays off (" .. banned_file .. ")")
    end
end

function loader.start() end

return loader
