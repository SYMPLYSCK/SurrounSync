-- The only code that changes save folders. Every operation checks it is allowed first:
-- world files only go into co-op saves, your own save only ever gets its character back,
-- and only after a backup.

local log = require("mirror.log")
local savefs = require("mirror.savefs")
local backups = require("mirror.backups")

local slotguard = {}

local saves_dir, coop_base
local L = backups.LAYOUT
local IMPORTABLE = { ["Level.sav"] = true, ["General.sav"] = true, ["Difficulties.sav"] = true, ["Slot.sav"] = true,
                     ["Thumb.sav"] = true }
local MAX_FILE, MAX_TOTAL, MIN_FILE = 16 * 1024 * 1024, 32 * 1024 * 1024, 16

local legacy_base
function slotguard.configure(c) saves_dir, coop_base, legacy_base = c.saves_dir, c.coop_base, c.legacy_base end

local function refuse(op, why)
    log.error("slotguard: refused " .. op .. ": " .. why)
    return nil, why
end

function slotguard.valid_name(n)
    return type(n) == "string" and n ~= "" and not n:find('[\\/:*?"<>|]') and not n:find("..", 1, true)
end
local function named(l, base)
    if not base then return false end
    local b = base:lower()
    return l == b or (l:sub(1, #b + 1) == b .. "_" and l:sub(#b + 2):match("^%d+$") ~= nil)
end
function slotguard.is_coop(n)
    if not slotguard.valid_name(n) then return false end
    local l = n:lower()
    return named(l, coop_base) or named(l, legacy_base)
end
local function dir(slot) return saves_dir .. "\\" .. slot end

local MARKER = "SurrounSync-coop.txt"
local function marked(slot) return savefs.exists(dir(slot) .. "\\" .. MARKER) end
local function has_saves(slot)
    return savefs.exists(dir(slot) .. "\\Level.sav") or savefs.exists(dir(slot) .. "\\Player.sav")
        or savefs.exists(dir(slot) .. "\\Slot.sav")
end
local function adopt(slot)
    if slotguard.is_coop(slot) and has_saves(slot) and not marked(slot) then
        savefs.write(dir(slot) .. "\\" .. MARKER, "SurrounSync co-op session save - emptied when the session ends.\n")
    end
end

function slotguard.make_coop_dir(slot)
    if not slotguard.is_coop(slot) then return refuse("make_coop_dir", tostring(slot) .. " is not a co-op save") end
    return savefs.mkdir(dir(slot))
end

function slotguard.foreign(slot)
    if not slotguard.is_coop(slot) or marked(slot) or not has_saves(slot) then return false end
    local t = slotguard.log_read()
    return not (t and t.coop == slot)
end
function slotguard.is_own(n)
    return slotguard.valid_name(n) and not slotguard.is_coop(n) and savefs.exists(dir(n) .. "\\Player.sav")
end

function slotguard.stamp(slot)
    if not slotguard.valid_name(slot) then return nil end
    local s = savefs.read(dir(slot) .. "\\Slot.sav")
    return s and savefs.crc32(s) or nil
end

function slotguard.repair(slot, file) if slotguard.valid_name(slot) then savefs.repair(dir(slot) .. "\\" .. file) end end
function slotguard.repair_sidecar(slot, suffix) if slotguard.valid_name(slot) then savefs.repair(saves_dir .. "\\" .. slot .. suffix) end end

local FIELDS = { "step", "own", "coop", "folder", "home", "own_stamp", "host", "time", "version" }
local STEPS = { building = "coop", joined = "coop", leaving = "coop", home = "coop", restoring = "folder" }
local function log_path() return saves_dir .. "\\mirror_coop_session.txt" end

function slotguard.log_write(t)
    local out = { "mirrorcoop-session 1" }
    for _, k in ipairs(FIELDS) do
        if t[k] ~= nil then out[#out + 1] = k .. "=" .. tostring(t[k]):gsub("[\r\n]", " ") end
    end
    return savefs.write(log_path(), table.concat(out, "\n") .. "\n")
end

function slotguard.log_read()
    savefs.repair(log_path())
    local s = savefs.read(log_path())
    if not s then return nil end
    local t = {}
    for line in s:gmatch("[^\r\n]+") do
        local k, v = line:match("^([%a_]+)=(.*)$")
        if k then t[k] = v end
    end
    if s:find("^mirrorcoop%-session 1\n") then
        local need = STEPS[t.step]
        if not need or not t.own or not t[need] then return nil, "bad" end
        if (t.step == "joined" or t.step == "leaving") and not t.own_stamp then return nil, "bad" end
        adopt(t.coop)
        return t
    end
    if t.own and not s:find("[%z\1-\8]") then
        adopt(t.coop or coop_base)
        return { step = s:find("phase=leaving", 1, true) and "home" or "joined", own = t.own,
                 coop = t.coop or coop_base, home = t.home }
    end
    return nil, "bad"
end

function slotguard.log_clear() savefs.remove(log_path()) end

function slotguard.log_exists() return savefs.exists(log_path()) or slotguard.log_quarantined() end
function slotguard.log_quarantined() return savefs.exists(log_path() .. ".mirror-bad") end

function slotguard.log_quarantine()
    local bad = log_path() .. ".mirror-bad"
    savefs.remove(bad)
    os.rename(log_path(), bad)
    log.error("slotguard: unreadable session log kept as " .. bad .. " - nothing was done with it")
end

local function check_files(files)
    if not files["Level.sav"] then return false, "Level.sav missing" end
    local total = 0
    for name, data in pairs(files) do
        if not IMPORTABLE[name] then return false, "unexpected file " .. tostring(name) end
        if type(data) ~= "string" or #data < MIN_FILE or #data > MAX_FILE then return false, name .. " has a bad size" end
        local magic = name == "Thumb.sav" and "\255\216\255" or "EMSH"
        if data:sub(1, #magic) ~= magic then return false, name .. " isn't a save file" end
        total = total + #data
    end
    if total > MAX_TOTAL then return false, "the world is too big" end
    return true
end

function slotguard.validate_world(files, ready)
    if not ready or ready.nonce ~= ready.expect_nonce then return refuse("host world", "not the answer to our join request") end
    if not slotguard.valid_name(ready.slot) then return refuse("host world", "bad host save name") end
    local n = tonumber(ready.count)
    if not n or n < 1 or n > 5 or n % 1 ~= 0 then return refuse("host world", "bad file count") end
    local ok, why = check_files(files)
    if not ok then return refuse("host world", why) end
    return true
end

local function session_coop(op, coop)
    local t = slotguard.log_read()
    if not slotguard.is_coop(coop) then return refuse(op, tostring(coop) .. " is not a co-op save") end
    if not t or t.coop ~= coop then return refuse(op, coop .. " is not this session's co-op save") end
    slotguard.foreign(coop)
    return t
end

local function gather(list)
    local files = {}
    for _, c in ipairs(list) do
        local data, err, missing = savefs.read_file(c[1])
        if data then files[#files + 1] = { path = c[2], data = data }
        elseif not missing then return nil, "can't read " .. c[1] .. ": " .. tostring(err) end
    end
    return files
end

local function character_pairs(from, to)
    local list = {}
    for _, f in ipairs(L.player) do list[#list + 1] = { dir(from) .. "\\" .. f, dir(to) .. "\\" .. f } end
    for _, x in ipairs(L.sidecars) do list[#list + 1] = { saves_dir .. "\\" .. from .. x, saves_dir .. "\\" .. to .. x } end
    return list
end

function slotguard.import_world(coop, files)
    local t, err = session_coop("import_world", coop)
    if not t then return nil, err end
    local ok, why = check_files(files)
    if not ok then return refuse("import_world", why) end
    local set = {}
    for name, data in pairs(files) do set[#set + 1] = { path = dir(coop) .. "\\" .. name, data = data } end
    return savefs.write_set(set)
end

function slotguard.seed_character(own, coop)
    if not slotguard.is_coop(coop) then return refuse("seed_character", tostring(coop) .. " is not a co-op save") end
    if slotguard.foreign(coop) then return refuse("seed_character", coop .. " holds a save SurrounSync didn't make") end
    if not slotguard.is_own(own) then return refuse("seed_character", tostring(own) .. " is not one of your saves") end
    if not savefs.write(dir(coop) .. "\\" .. MARKER, "SurrounSync co-op session save - emptied when the session ends.\n") then
        return refuse("seed_character", "can't mark " .. coop)
    end
    local set, err = gather(character_pairs(own, coop))
    if not set then return nil, err end
    return savefs.write_set(set)
end

function slotguard.copy_character_home(coop, own)
    local t, err = session_coop("copy_character_home", coop)
    if not t then return nil, err end
    if t.own ~= own then return refuse("copy_character_home", tostring(own) .. " is not this session's own save") end
    if not slotguard.is_own(own) then return refuse("copy_character_home", tostring(own) .. " is not one of your saves") end
    if not savefs.exists(dir(coop) .. "\\Player.sav") then return refuse("copy_character_home", coop .. " has no character") end
    if t.own_stamp then
        local now = slotguard.stamp(own)
        if not now then return nil, "can't read " .. own .. "\\Slot.sav right now" end
        if now ~= t.own_stamp then
            local f, e = backups.take{ slot = own, from = coop, kind = "character", reason = "co-op character not applied" }
            if not f then return nil, e end
            backups.take{ slot = own, reason = "before going home" }
            log.warn("slotguard: " .. own .. " was saved after the join - the co-op character was NOT copied over it (kept in backup " .. f .. ")")
            return "kept"
        end
    end
    local f, e = backups.take{ slot = own, reason = "before going home" }
    if not f then return refuse("copy_character_home", "no backup of " .. own .. " (" .. tostring(e) .. ")") end
    local set, gerr = gather(character_pairs(coop, own))
    if not set then return nil, gerr end
    local ok, werr = savefs.write_set(set)
    if not ok then return nil, werr end
    return "copied"
end

function slotguard.purge(coop)
    if not slotguard.is_coop(coop) then refuse("purge", tostring(coop) .. " is not a co-op save"); return 0 end
    if slotguard.foreign(coop) then refuse("purge", coop .. " holds a save SurrounSync didn't make - left alone"); return 0 end
    local n = 0
    for _, list in ipairs({ L.world, L.player }) do
        for _, f in ipairs(list) do
            savefs.repair(dir(coop) .. "\\" .. f)
            if os.remove(dir(coop) .. "\\" .. f) then n = n + 1 end
        end
    end
    for _, x in ipairs(L.sidecars) do if os.remove(saves_dir .. "\\" .. coop .. x) then n = n + 1 end end
    os.remove(dir(coop) .. "\\" .. MARKER)
    if n > 0 then log.info(string.format("slotguard: emptied co-op save %s (%d files)", coop, n)) end
    return n
end

function slotguard.apply_restore(slot, folder)
    if not slotguard.valid_name(slot) or slotguard.is_coop(slot) then return nil, refuse("restore", tostring(slot) .. " can't be restored"), true end
    if not savefs.dir_exists(dir(slot)) then return nil, refuse("restore", slot .. " has no save folder"), true end
    local t = slotguard.log_read()
    if t and not (t.step == "restoring" and t.own == slot) then return nil, refuse("restore", "a co-op session is open"), false end
    local m = backups.manifest(slot, folder)
    if not m or m.slot ~= slot then return nil, refuse("restore", "backup " .. tostring(folder) .. " isn't one of " .. slot), true end
    local ok, why = backups.verify(slot, folder)
    if not ok then return nil, refuse("restore", why), true end
    local f, e = backups.take{ slot = slot, reason = "before restore" }
    if not f and not tostring(e):find("^nothing to back up") then
        return nil, refuse("restore", "no backup of the current state (" .. tostring(e) .. ")"), false
    end
    local src = backups.root() .. "\\" .. slot .. "\\" .. folder .. "\\"
    local list = {}
    for _, file in ipairs(m.files) do
        list[#list + 1] = { src .. file.name, file.sidecar and (saves_dir .. "\\" .. file.name) or (dir(slot) .. "\\" .. file.name) }
    end
    local set, gerr = gather(list)
    if not set then return nil, gerr, false end
    local w, werr = savefs.write_set(set)
    if not w then return nil, werr, false end
    log.info(string.format("slotguard: restored %s from %s (%d files)", slot, folder, #m.files))
    return true
end

return slotguard
