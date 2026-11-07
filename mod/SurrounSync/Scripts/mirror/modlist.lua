-- Mod Management (J handbook -> MODS tab): this PC's UE4SS mods (ue4ss\Mods; on in mods.txt or by their own
-- enabled.txt) and pak mods (Content\Paks\~mods and LogicMods; off = renamed to .pak.off), switched on and off
-- right there. UE4SS and the game load mods only when the game starts, so a change waits for a restart.
-- In co-op the other side's running mods (compat.lua swaps the lists) are shown next to mine, and a guest can
-- match the host's with one click.

local log = require("mirror.log")

local modlist = {}

-- io paths are relative to the game's Win64 (the working directory); the listing goes through UE, which wants
-- full paths (see roots())
local io_root = ""
local lister = nil
local list_win64, list_paks = nil, nil
local NOT_MODS = { shared = true, SurrounSync = true, MirrorCoop = true }
-- Mods SurrounSync switches from its own settings (MY SETTINGS), not from the MODS list: they only change how this
-- PC's game looks, so they're never matched with the host either.
modlist.BUILT_IN = { SyncFX = true, SurrounDeadGore = true, ["pak:SurrounDeadGore.pak"] = true }
modlist.FX = "SyncFX"
modlist.GORE, modlist.GORE_PAK = "SurrounDeadGore", "pak:SurrounDeadGore.pak"
local PAKS = { "~mods", "LogicMods" }
local PAK_PARTS = { ".pak", ".ucas", ".utoc", ".sig" }

local entries = {}
local scanned_at = nil
local loaded = nil      -- id -> on, as the game started (what is running now)
local now = os.clock

local function read(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end
-- whole file or the old one: UE4SS starts SurrounSync from mods.txt, and a write in place that failed half-way (a full
-- disk) left it empty - the next start without SurrounSync, so without its save protection
local function write(p, s) return require("mirror.fs").write(p, s) == true end
local function exists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

local function mods_io() return io_root .. "ue4ss\\Mods\\" end
local function paks_io(sub) return io_root .. "..\\..\\Content\\Paks\\" .. sub .. "\\" end

-- full paths for UE's file listing: ProjectDir() made absolute (..\SurrounDead\); relative ones as a fallback
local function roots()
    if list_win64 then return list_win64, list_paks end
    local proj
    pcall(function()
        local util = require("mirror.util")
        local bp = util.cdo("/Script/Engine.Default__BlueprintPathsLibrary")
        local d = bp:ProjectDir()
        d = type(d) == "string" and d or d:ToString()
        local full = bp:ConvertRelativePathToFull(d, "")
        proj = type(full) == "string" and full or full:ToString()
    end)
    proj = proj and proj:gsub("/", "\\"):gsub("\\+$", "")
    if proj and proj:match("^%a:\\") then
        list_win64, list_paks = proj .. "\\Binaries\\Win64", proj .. "\\Content\\Paks"
    else
        list_win64, list_paks = ".", "..\\..\\Content\\Paks"
    end
    log.info("modlist: mods in " .. list_win64 .. "\\ue4ss\\Mods and " .. list_paks)
    return list_win64, list_paks
end

-- folder and file names in p (UE's BlueprintFileUtils, fs.lua; savefs is only for the save code)
local function default_lister()
    local fs = require("mirror.fs")
    return { dirs = fs.list_dirs, files = fs.list_files }
end

-- mods.txt: "Name : 1" per line
local function txt_state(s)
    local t = {}
    for line in (s or ""):gmatch("[^\r\n]+") do
        local n, v = line:match("^%s*(.-)%s*:%s*(%d)%s*$")
        if n and n ~= "" then t[n] = v end
    end
    return t
end

local function scan()
    lister = lister or default_lister()
    local w64, paks = roots()
    local out = {}
    local txt = txt_state(read(mods_io() .. "mods.txt"))
    local lua = {}
    local dirs = lister.dirs(w64 .. "\\ue4ss\\Mods")
    for _, n in ipairs(dirs or {}) do
        if not NOT_MODS[n] and not n:match("^SurrounSync") then lua[#lua + 1] = n end
    end
    table.sort(lua, function(a, b) return a:lower() < b:lower() end)
    for _, n in ipairs(lua) do
        local on = txt[n] == "1" or exists(mods_io() .. n .. "\\enabled.txt")
        out[#out + 1] = { id = n, name = n, kind = "lua", on = on }
    end
    for _, sub in ipairs(PAKS) do
        local seen = {}
        local files = lister.files(paks .. "\\" .. sub) or {}
        table.sort(files, function(a, b) return a:lower() < b:lower() end)
        for _, f in ipairs(files) do
            local l = f:lower()
            local base, on
            if l:sub(-4) == ".pak" then base, on = f:sub(1, -5), true
            elseif l:sub(-8) == ".pak.off" then base, on = f:sub(1, -9), false end
            -- (SurrounSync's own paks - armory, glider, sounds - are part of it, like its Lua folder: never listed,
            -- switched or matched with a host)
            if base and not seen[base:lower()] and not base:match("^SurrounSync") then
                seen[base:lower()] = true
                out[#out + 1] = { id = "pak:" .. base .. ".pak", name = base, kind = "pak", sub = sub, base = base, on = on }
            end
        end
    end
    entries, scanned_at = out, now()
    -- (only from a listing that worked: an empty snapshot would mark every mod as changed)
    if not loaded and dirs then
        loaded = {}
        for _, e in ipairs(out) do loaded[e.id] = e.on end
    end
    return out
end

local function fresh()
    if not scanned_at or now() - scanned_at > 3 then scan() end
    return entries
end

local function find(id)
    for _, e in ipairs(fresh()) do if e.id == id then return e end end
    return nil
end

local function esc(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

local function set_txt(name, on)
    local p = mods_io() .. "mods.txt"
    local s = read(p) or ""
    local nl = s:find("\r\n", 1, true) and "\r\n" or "\n"
    local lines, found = {}, false
    for line in s:gmatch("[^\r\n]+") do
        local n = line:match("^%s*(.-)%s*:%s*%d%s*$")
        if n == name then
            if not found then lines[#lines + 1] = name .. " : " .. (on and "1" or "0") end
            found = true
        else
            lines[#lines + 1] = line
        end
    end
    if not found then
        -- UE4SS starts the mods in mods.txt order; keep its own keybinds line last like the stock list
        local at = #lines + 1
        for i, l in ipairs(lines) do if l:match("^%s*Keybinds%s*:") then at = i end end
        while at > 1 and lines[at - 1]:match("^%s*;") do at = at - 1 end   -- (its "; Built-in keybinds" note too)
        table.insert(lines, at, name .. " : " .. (on and "1" or "0"))
    end
    if not write(p, table.concat(lines, nl) .. nl) then return false end
    -- newer UE4SS read mods.json instead (same switch)
    local jp = mods_io() .. "mods.json"
    local j = read(jp)
    if j then
        local pat = '("mod_name"%s*:%s*"' .. esc(name) .. '"%s*,%s*"mod_enabled"%s*:%s*)(%a+)'
        local nj, hits = j:gsub(pat, "%1" .. (on and "true" or "false"))
        if hits == 0 and on then
            local at = j:match(".*()%]")
            if at then
                local before = j:sub(1, at - 1):gsub("%s+$", "")
                local sep = before:sub(-1) == "[" and "" or ","
                nj = before .. sep .. '\r\n    {\r\n        "mod_name": "' .. name .. '",\r\n        "mod_enabled": true\r\n    }\r\n' .. j:sub(at)
            end
        end
        if nj ~= j then write(jp, nj) end
    end
    return true
end

-- Switches one mod on or off on disk; the game uses it from the next start.
function modlist.set(id, on)
    local e = find(id)
    if not e or e.on == on then return false end
    if e.kind == "lua" then
        if not set_txt(e.id, on) then log.warn("modlist: couldn't write mods.txt"); return false end
        local en = mods_io() .. e.id .. "\\enabled.txt"
        if not on and exists(en) then os.remove(en .. ".off"); os.rename(en, en .. ".off") end
        if on and not exists(en) and exists(en .. ".off") then os.rename(en .. ".off", en) end
    else
        local dir = paks_io(e.sub)
        local moved = 0
        for _, ext in ipairs(PAK_PARTS) do
            local live, off = dir .. e.base .. ext, dir .. e.base .. ext .. ".off"
            local from, to = on and off or live, on and live or off
            if exists(from) and not exists(to) then
                local ok = os.rename(from, to)
                if ok then moved = moved + 1 else log.warn("modlist: couldn't rename " .. from) end
            end
        end
        if moved == 0 then return false end
    end
    log.info("modlist: " .. e.id .. " -> " .. (on and "on" or "off") .. " (from the next game start)")
    scan()
    return true
end

-- ReShade's dxgi.dll follows SyncFX from the next game start, through SyncFX's own syncfx/reshade.lua (no requires).
-- Switched off in MY SETTINGS, SyncFX doesn't run next time to do it itself; switched on, ReShade comes back when
-- SyncFX's own switch (F8, in its SyncFX.user.ini) is on too. "on" / "off" = moved, nil = nothing to do, false = failed.
function modlist.follow_reshade(on)
    local src = read(mods_io() .. modlist.FX .. "\\Scripts\\syncfx\\reshade.lua")
    if not src then return nil end
    local ok, done, err = pcall(function()
        local fn, lerr = load(src, "@SyncFX/reshade.lua")
        if not fn then error(lerr) end
        local rs = fn()
        return rs.follow(on and rs.syncfx_on(mods_io() .. modlist.FX .. "\\"), io_root)
    end)
    if not ok then log.warn("modlist: SyncFX's reshade.lua failed: " .. tostring(done)); return false end
    if done == false then log.warn("modlist: couldn't switch ReShade for the next start: " .. tostring(err)) end
    if done then log.info("modlist: ReShade " .. done .. " from the next game start (follows SyncFX)") end
    return done
end

-- The gore mod is its Lua mod plus the pak of its blood assets (LogicMods: BPModLoaderMod loads them at every level
-- load even with the Lua off), so both switch together; the Lua mod's state is the switch's. true = done.
function modlist.set_gore(on)
    scan()   -- (on the disk now: the listing can be 3 s old, and a pak renamed by hand since made the switch fail)
    local lua, pak = find(modlist.GORE), find(modlist.GORE_PAK)
    if not lua then return false end
    if lua.on ~= on and not modlist.set(modlist.GORE, on) then return false end
    if pak and pak.on ~= on and not modlist.set(modlist.GORE_PAK, on) then
        log.warn("modlist: SurrounDeadGore.pak couldn't follow the gore switch")
        return false
    end
    return true
end

function modlist.toggle(id)
    local e = find(id)
    if not e then return false end
    return modlist.set(id, not e.on)
end

-- A built-in mod's switch: installed?, on (from the next start), and whether that differs from what runs now.
function modlist.state(id)
    local e = find(id)
    if not e then return false, false, false end
    local was = loaded and loaded[e.id] or false
    return true, e.on, was ~= e.on
end

-- ids that run in this game (as it started): what compat.lua tells the other side
function modlist.loaded_ids()
    if not loaded then scan() end
    if not loaded then return {} end
    local t = {}
    for id, on in pairs(loaded) do if on then t[id] = true end end
    return t
end

local function was_on(e) if not loaded then return e.on end return loaded[e.id] or false end

function modlist.restart_needed()
    for _, e in ipairs(fresh()) do
        if was_on(e) ~= e.on then return true end
    end
    return false
end

local function short(s, n) return #s > n and (s:sub(1, n - 2) .. "..") or s end

-- peer: { set = { id = true }, who = "Name", kind = function(id) -> "client"/"gameplay"/..., host = true when
-- the other side is my host }. A "client" mod only changes my own screen/keys, so it never needs to match.
local function matters(peer, id) return not (peer and peer.kind and peer.kind(id) == "client") end

function modlist.model(peer)
    local rows, differs = {}, 0
    local mine = {}
    local listed = {}
    for _, e in ipairs(fresh()) do
        mine[e.id] = true
        if not modlist.BUILT_IN[e.id] then listed[#listed + 1] = e end
    end
    for _, e in ipairs(listed) do
        local r = { id = e.id, label = short(e.name, 26) .. (e.kind == "pak" and " (pak)" or ""), on = e.on,
                    text = e.on and "ON" or "OFF" }
        if was_on(e) ~= e.on then r.note = e.on and "on after a restart" or "off after a restart" end
        if peer and peer.set then
            local theirs = peer.set[e.id] == true
            if theirs ~= e.on then
                if matters(peer, e.id) then
                    differs = differs + 1
                    r.differs = true
                    r.note = short(peer.who, 14) .. " has it " .. (theirs and "ON" or "OFF")
                else
                    r.note = (r.note and (r.note .. ", ") or "") .. "only changes your screen"
                end
            end
        end
        rows[#rows + 1] = r
    end
    local missing = {}
    if peer and peer.set then
        for id in pairs(peer.set) do
            if not mine[id] and matters(peer, id) and not NOT_MODS[id] and not modlist.BUILT_IN[id] then missing[#missing + 1] = id end
        end
        table.sort(missing)
        for _, id in ipairs(missing) do
            rows[#rows + 1] = { id = id, label = short((id:gsub("^pak:", "")), 26), text = "MISSING", locked = true,
                                differs = true, note = "only " .. short(peer.who, 14) .. " has it" }
        end
    end
    return { rows = rows, restart = modlist.restart_needed(), differs = differs + #missing, missing = #missing,
             can_match = peer ~= nil and peer.host == true and differs > 0, who = peer and peer.who }
end

-- Sets every mod that matters like the host's. Returns how many changed and the ones I don't have.
function modlist.match(peer)
    local changed, missing = 0, {}
    if not (peer and peer.set) then return 0, missing end
    local mine = {}
    for _, e in ipairs(fresh()) do
        mine[e.id] = true
        local theirs = peer.set[e.id] == true
        if theirs ~= e.on and matters(peer, e.id) and not modlist.BUILT_IN[e.id] and modlist.set(e.id, theirs) then
            changed = changed + 1
        end
    end
    for id in pairs(peer.set) do
        if not mine[id] and matters(peer, id) and not NOT_MODS[id] and not modlist.BUILT_IN[id] then
            missing[#missing + 1] = (id:gsub("^pak:", ""))
        end
    end
    table.sort(missing)
    return changed, missing
end

function modlist.init()
    if not loaded then
        local ok, err = pcall(scan)
        if not ok then log.warn("modlist: couldn't list the mods (" .. tostring(err) .. ")") end
        local n = 0
        for _ in pairs(loaded or {}) do n = n + 1 end
        log.info("modlist: " .. n .. " mods found")
    end
end

-- tests: point it at a folder and a lister
function modlist.configure(c)
    io_root = c.io_root or io_root
    lister = c.lister or lister
    list_win64, list_paks = c.list_win64 or list_win64, c.list_paks or list_paks
    if c.clock then now = c.clock end
    if c.reset then entries, scanned_at, loaded = {}, nil, nil end
end

return modlist
