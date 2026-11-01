-- Safe file writes for saves: write a temp file, swap it in, and repair after a crash.

local savefs = {}

local NEW, OLD = ".mirror-new", ".mirror-old"

function savefs.read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

function savefs.read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, tostring(err), tostring(err):find("No such file", 1, true) ~= nil end
    local s = f:read("a")
    f:close()
    return s
end

function savefs.exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

function savefs.remove(path) return os.remove(path) == true end

-- A set (write_set) goes in whole or not at all, also across folders (a slot's files and its sidecar beside the
-- slots): one by one, a crash between two swaps left some files new and the rest old, and the per-file repair kept
-- that mix (audit 2026-10-30). JOURNAL in the first file's folder is the commit point: put in place once every new
-- copy is written and checked, removed after the swaps. Each other folder of the set gets a pointer (the same text)
-- before the commit, so the repair of any file of the set finds it: a set whose journal is there is finished, any
-- other is undone file by file.
local JOURNAL = "mirror-saveset.txt"

local function dir_of(path) return path:match("^(.*)[\\/][^\\/]*$") or "." end
local function same_place(a, b) return a:lower():gsub("/", "\\") == b:lower():gsub("/", "\\") end

local function journal_text(primary, files)
    local out = { "set " .. primary }
    for _, f in ipairs(files) do out[#out + 1] = "file " .. f.path end
    out[#out + 1] = "END"
    return table.concat(out, "\n") .. "\n"
end

-- false: this folder is in a committed set that couldn't be finished now (tried again at the next repair)
local function recover(dir)
    local here = dir .. "\\" .. JOURNAL
    os.remove(here .. NEW)
    local s = savefs.read(here)
    if not s then return true end
    local primary = s:match("^set ([^\n]+)\n")
    local committed = primary ~= nil and s:sub(-5) == "\nEND\n" and savefs.read(primary) == s
    if not committed then os.remove(here); return true end
    local files, dirs = {}, {}
    for p in s:gmatch("\nfile ([^\n]+)") do files[#files + 1] = p end
    for _, p in ipairs(files) do
        if savefs.exists(p .. NEW) then
            if savefs.exists(p) then
                if savefs.exists(p .. OLD) then os.remove(p .. OLD) end
                if not os.rename(p, p .. OLD) then return false end
            end
            if not os.rename(p .. NEW, p) then return false end
        end
    end
    for _, p in ipairs(files) do
        os.remove(p .. OLD)
        local d = dir_of(p) .. "\\" .. JOURNAL
        if not same_place(d, primary) then dirs[d] = true end
    end
    -- pointers first, the journal last: a crash in between leaves the journal, which then finds nothing more to do
    for d in pairs(dirs) do os.remove(d) end
    os.remove(primary)
    return true
end

function savefs.repair(path)
    if not recover(dir_of(path)) then return end
    if savefs.exists(path .. OLD) then
        if savefs.exists(path) then os.remove(path .. OLD) else os.rename(path .. OLD, path) end
    end
    if savefs.exists(path .. NEW) then os.remove(path .. NEW) end
end

function savefs.write(path, data)
    savefs.repair(path)
    local new, old = path .. NEW, path .. OLD
    local f, err = io.open(new, "wb")
    if not f then return false, "can't write " .. new .. ": " .. tostring(err) end
    f:write(data)
    f:close()
    if savefs.read(new) ~= data then
        os.remove(new)
        return false, "the written copy differs (disk full?): " .. new
    end
    local had = savefs.exists(path)
    if had then
        local ok, e = os.rename(path, old)
        if not ok then os.remove(new); return false, "can't move " .. path .. " aside: " .. tostring(e) end
    end
    local ok, e = os.rename(new, path)
    if not ok then
        if had then os.rename(old, path) end
        os.remove(new)
        return false, "can't put " .. path .. " in place: " .. tostring(e)
    end
    if had then os.remove(old) end
    return true
end

function savefs.write_set(files)
    if #files == 0 then return true end
    -- (an earlier set that couldn't be finished yet owns the new copies in its folders: none of them are touched)
    for _, f in ipairs(files) do
        if not recover(dir_of(f.path)) then return false, "an earlier save in " .. dir_of(f.path) .. " isn't finished yet" end
    end
    for _, f in ipairs(files) do savefs.repair(f.path) end
    local primary = dir_of(files[1].path) .. "\\" .. JOURNAL
    local text = journal_text(primary, files)
    local pointers = {}
    local function unstage(from)
        for k = from, #files do os.remove(files[k].path .. NEW) end
        for _, p in ipairs(pointers) do os.remove(p) end
    end
    for _, f in ipairs(files) do
        local h, err = io.open(f.path .. NEW, "wb")
        if not h then unstage(1); return false, "can't write " .. f.path .. NEW .. ": " .. tostring(err) end
        h:write(f.data)
        h:close()
        if savefs.read(f.path .. NEW) ~= f.data then unstage(1); return false, "the written copy differs (disk full?): " .. f.path end
    end
    for _, f in ipairs(files) do
        local p = dir_of(f.path) .. "\\" .. JOURNAL
        local known = same_place(p, primary)
        for _, q in ipairs(pointers) do known = known or same_place(p, q) end
        if not known then
            pointers[#pointers + 1] = p
            local h = io.open(p, "wb")
            if h then h:write(text); h:close() end
            if savefs.read(p) ~= text then unstage(1); return false, "can't write " .. p end
        end
    end
    -- the commit point
    local h = io.open(primary .. NEW, "wb")
    if h then h:write(text); h:close() end
    if savefs.read(primary .. NEW) ~= text or not os.rename(primary .. NEW, primary) then
        os.remove(primary .. NEW)
        unstage(1)
        return false, "can't write " .. primary
    end
    local done = {}
    for i, f in ipairs(files) do
        local had = savefs.exists(f.path)
        local ok, e = true, nil
        if had then ok, e = os.rename(f.path, f.path .. OLD) end
        if ok then
            ok, e = os.rename(f.path .. NEW, f.path)
            if not ok and had then os.rename(f.path .. OLD, f.path) end
        end
        if not ok then
            -- undone here, so no longer committed (if even that fails, the next repair finishes the set)
            if not os.remove(primary) then return false, "can't put " .. f.path .. " in place: " .. tostring(e) end
            for j = #done, 1, -1 do
                local d = done[j]
                if d.had then os.rename(d.path, d.path .. NEW); os.rename(d.path .. OLD, d.path); os.remove(d.path .. NEW)
                else os.remove(d.path) end
            end
            unstage(i)
            return false, "can't put " .. f.path .. " in place: " .. tostring(e)
        end
        done[#done + 1] = { path = f.path, had = had }
    end
    for _, d in ipairs(done) do if d.had then os.remove(d.path .. OLD) end end
    for _, p in ipairs(pointers) do os.remove(p) end
    os.remove(primary)
    return true
end

function savefs.copy(src, dst)
    local data = savefs.read(src)
    if not data then return false, "can't read " .. src end
    return savefs.write(dst, data)
end

local BFU = "/Script/BlueprintFileUtils.Default__BlueprintFileUtilsBPLibrary"
local function bfu() return require("mirror.util").cdo(BFU) end
local function str(v)
    if type(v) == "string" then return v end
    local s
    pcall(function() s = v:ToString() end)
    if type(s) ~= "string" then pcall(function() s = v:get():ToString() end) end
    return s
end

local backend = {
    mkdir = function(p)
        local ok, r = pcall(function() return bfu():MakeDirectory(p, true) end)
        return ok and r == true
    end,
    list_dirs = function(p)
        local out = {}
        local ok = pcall(function() bfu():FindRecursive(p, out, "*", false, true) end)
        if not ok then return nil end
        local arr = out.FoundPaths or out
        local names, prefix = {}, (p:gsub("[\\/]+$", "") .. "\\"):lower():gsub("/", "\\")
        local function add(v)
            local full = (str(v) or ""):gsub("/", "\\")
            local rest = full:lower():sub(1, #prefix) == prefix and full:sub(#prefix + 1) or nil
            if rest and rest ~= "" and not rest:find("\\", 1, true) then names[#names + 1] = rest end
        end
        if type(arr) == "table" then for _, v in ipairs(arr) do add(v) end
        else pcall(function() arr:ForEach(function(_, e) add(e:get()) end) end) end
        return names
    end,
    rmdir = function(p)
        local ok, r = pcall(function() return bfu():DeleteDirectory(p, false, true) end)
        return ok and r == true
    end,
    rmdir_empty = function(p)
        local ok, r = pcall(function() return bfu():DeleteDirectory(p, false, false) end)
        return ok and r == true
    end,
}

local uepath = require("mirror.uepath")
function savefs.set_dir_backend(b) if b then backend = b end end
function savefs.mkdir(path)
    if backend.mkdir(uepath.of(path)) == true then return true end
    if uepath.ascii(path) then return false end
    -- last resort: cmd's mkdir reads the path in the ANSI code page, like io.open
    os.execute('mkdir "' .. path:gsub('"', "") .. '" >nul 2>nul')
    return savefs.dir_exists(path)
end
function savefs.list_dirs(path) return backend.list_dirs(uepath.of(path)) end
function savefs.rmdir(path) return backend.rmdir(uepath.of(path)) == true end
-- only an empty folder (anything still in it keeps it)
function savefs.rmdir_empty(path) return backend.rmdir_empty(uepath.of(path)) == true end

function savefs.dir_exists(dir)
    local probe = dir .. "\\.mirror_probe"
    local f = io.open(probe, "wb")
    if not f then return false end
    f:close()
    os.remove(probe)
    return true
end

local CRC = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do c = (c & 1) == 1 and (0xEDB88320 ~ (c >> 1)) or (c >> 1) end
    CRC[i] = c
end

function savefs.crc32(s)
    local c, byte = 0xFFFFFFFF, string.byte
    for i = 1, #s, 64 do
        local b = { byte(s, i, i + 63) }
        for k = 1, #b do c = CRC[(c ~ b[k]) & 0xFF] ~ (c >> 8) end
    end
    return string.format("%08x", c ~ 0xFFFFFFFF)
end

return savefs
