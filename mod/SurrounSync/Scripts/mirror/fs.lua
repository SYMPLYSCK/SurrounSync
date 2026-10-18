-- Plain file helpers. Refuses to write into save folders - only slotguard may do that.

local fs = {}

function fs.exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

function fs.read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
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
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

function fs.copy(src, dst)
    local s = fs.read(src)
    if not s then return false end
    return fs.write(dst, s)
end

function fs.dir_exists(dir)
    local probe = dir .. "\\.mirror_probe"
    local f = io.open(probe, "wb")
    if not f then return false end
    f:close()
    os.remove(probe)
    return true
end

function fs.list_files(dir)
    local cdo = StaticFindObject and StaticFindObject("/Script/BlueprintFileUtils.Default__BlueprintFileUtilsBPLibrary")
    if not cdo then return nil end
    local out = {}
    local ok = pcall(function() cdo:FindRecursive(dir, out, "*", true, false) end)
    if not ok then return nil end
    local arr = out.FoundPaths or out
    local names, prefix = {}, (dir:gsub("[\\/]+$", "") .. "\\"):lower():gsub("/", "\\")
    local function add(v)
        local full = tostring(type(v) == "string" and v or (v.ToString and v:ToString()) or ""):gsub("/", "\\")
        local rest = full:lower():sub(1, #prefix) == prefix and full:sub(#prefix + 1) or nil
        if rest and rest ~= "" and not rest:find("\\", 1, true) then names[#names + 1] = rest end
    end
    if type(arr) == "table" then for _, v in ipairs(arr) do add(v) end
    else pcall(function() arr:ForEach(function(_, e) add(e:get()) end) end) end
    return names
end

return fs
