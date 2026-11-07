-- Plain file helpers. Refuses to write into save folders - only slotguard may do that.

local fs = {}

function fs.exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

function fs.read(path)
    local f = io.open(path, "rb")
    if not f then
        -- a crash between fs.write's remove and rename leaves only the finished new copy
        f = io.open(path .. ".new", "rb")
        if not f then return nil end
        local s = f:read("*a")
        f:close()
        os.rename(path .. ".new", path)
        return s
    end
    local s = f:read("*a")
    f:close()
    return s
end

local function protected(path)
    local p = path:lower():gsub("/", "\\")
    return p:find("\\savegames\\", 1, true) ~= nil or p:find("\\mirrorbackups\\", 1, true) ~= nil
        or p:find("\\surrounsyncbackups\\", 1, true) ~= nil
end

function fs.write(path, data)
    if protected(path) then
        require("mirror.log").error("fs: refused a write into a save folder (use slotguard): " .. path)
        return false
    end
    -- whole file or the old one: a crash mid-write (truncate + write) emptied the beds / bag owners / Realm sidecars
    local tmp = path .. ".new"
    local f = io.open(tmp, "wb")
    if not f then return false end
    local ok = f:write(data) ~= nil
    ok = f:close() and ok
    if not ok then os.remove(tmp); return false end
    os.remove(path) -- (Windows rename doesn't replace)
    return os.rename(tmp, path) == true
end

function fs.copy(src, dst)
    local s = fs.read(src)
    if not s then return false end
    return fs.write(dst, s)
end

-- A folder (and its parents) outside the save folders; true when it's there afterwards (UE's MakeDirectory, which
-- also says true for one that already existed). Writes no probe file into it, unlike dir_exists.
function fs.mkdir(dir)
    if protected(dir .. "\\") then
        require("mirror.log").error("fs: refused a folder in a save folder (use slotguard): " .. dir)
        return false
    end
    local cdo = StaticFindObject and StaticFindObject("/Script/BlueprintFileUtils.Default__BlueprintFileUtilsBPLibrary")
    if not cdo then return false end
    local ok, r = pcall(function() return cdo:MakeDirectory(require("mirror.uepath").of(dir), true) end)
    return ok and r == true
end

function fs.dir_exists(dir)
    local probe = dir .. "\\.mirror_probe"
    local f = io.open(probe, "wb")
    if not f then return false end
    f:close()
    os.remove(probe)
    return true
end

-- the names (no folders above) of the files or folders right in dir. One reading of FindRecursive's FoundPaths for
-- both: the files' own version (v.ToString only) read every path as "" in game - the radio never saw a song and
-- the MODS list never a pak (2026-11-03: "15 mods found" = the Lua folders alone, 5 paks there) - while the
-- folders' version (modlist.lua, string / ToString / get():ToString) listed the Lua mods.
local function found(dir, files, dirs)
    local cdo = StaticFindObject and StaticFindObject("/Script/BlueprintFileUtils.Default__BlueprintFileUtilsBPLibrary")
    if not cdo then return nil end
    local out = {}
    dir = require("mirror.uepath").of(dir)
    if not pcall(function() cdo:FindRecursive(dir, out, "*", files, dirs) end) then return nil end
    local arr = out.FoundPaths or out
    local names, prefix = {}, (dir:gsub("[\\/]+$", "") .. "\\"):lower():gsub("/", "\\")
    local function add(v)
        local s = v
        if type(s) ~= "string" then pcall(function() s = v:ToString() end) end
        if type(s) ~= "string" then pcall(function() s = v:get():ToString() end) end
        local full = tostring(type(s) == "string" and s or ""):gsub("/", "\\")
        local rest = full:lower():sub(1, #prefix) == prefix and full:sub(#prefix + 1) or nil
        if rest and rest ~= "" and not rest:find("\\", 1, true) then names[#names + 1] = rest end
    end
    if type(arr) == "table" then for _, v in ipairs(arr) do add(v) end
    else pcall(function() arr:ForEach(function(_, e) add(e:get()) end) end) end
    return names
end

function fs.list_files(dir) return found(dir, true, false) end
function fs.list_dirs(dir) return found(dir, false, true) end

return fs
