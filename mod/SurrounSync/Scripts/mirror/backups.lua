-- Backup copies of a save, taken before co-op touches it. Kept in Saved\SurrounSyncBackups.
-- Realm characters have their own scope (take_realm / list_realm / restore_realm): the same folders, manifests and
-- retention, under SurrounSyncBackups\SurrounSync Realms\<Realm id>. Co-op's lists and requests never see them.

local log = require("mirror.log")
local savefs = require("mirror.savefs")

local backups = {}

backups.LAYOUT = {
    world = { "Level.sav", "General.sav", "Difficulties.sav", "Slot.sav", "Thumb.sav", "Thumb.jpg" },
    player = { "Player.sav", "PlayerInfo.sav" },
    sidecars = { "_SDQuests.sav", "_SkillTree.sav", "_Quests.sav" },
}

local saves_dir, root, kept, version = nil, nil, 10, "?"

local README = [[
SurrounSync backups of your SurrounDead saves.

Every folder in here is one save; inside it, every dated folder is one complete copy of that save, taken
before co-op touched it ("before joining", "before going home", ...). The oldest copy of each save is the
one from before you first used co-op - it is never deleted automatically.

The easy way back: open the co-op menu in the game -> Backups -> Restore (it applies when you restart).
The folder "SurrounSync Realms" holds your character of each Realm (one folder per Realm id). Bring one back in the
game: handbook (J) -> REALMS -> BACKUPS -> Restore (it applies the next time you open that Realm).

By hand (game closed):
  1. Copy every .sav / .jpg file of the dated folder, EXCEPT the ones whose name starts with the save's name,
     into  ..\SaveGames\<save name>\  (replace the files there).
  2. Copy the files whose name starts with the save's name (<save>_SDQuests.sav, <save>_SkillTree.sav ...)
     into  ..\SaveGames\  itself.
backup.txt lists every file with its size and checksum. Older SurrounSync versions left *.mirror-bak1..3 copies
next to the save files; they are still there and work the same way (rename to the original name).
]]

local function parent(p) return p:match("^(.*)[\\/][^\\/]+$") end
function backups.root() return root end
local function slot_dir(slot) return root .. "\\" .. slot end

function backups.configure(c)
    saves_dir, kept, version = c.saves_dir, c.kept or 10, c.version or "?"
    root = parent(saves_dir) .. "\\SurrounSyncBackups"
    local old = parent(saves_dir) .. "\\MirrorBackups"
    if savefs.dir_exists(old) then
        if not savefs.dir_exists(root) then
            if os.rename(old, root) then log.info("backups: moved " .. old .. " -> " .. root)
            else root = old; log.warn("backups: couldn't rename " .. old .. " - backups stay there") end
        else
            for _, slot in ipairs(savefs.list_dirs(old) or {}) do
                if not savefs.dir_exists(root .. "\\" .. slot) and os.rename(old .. "\\" .. slot, root .. "\\" .. slot) then
                    log.info("backups: moved the backups of " .. slot .. " to " .. root)
                end
            end
        end
    end
    if not savefs.mkdir(root) then log.warn("backups: can't create " .. root) return end
    if not savefs.exists(root .. "\\README.txt") then savefs.write(root .. "\\README.txt", README) end
end

function backups.manifest(slot, folder)
    local s = savefs.read(slot_dir(slot) .. "\\" .. folder .. "\\backup.txt")
    if not s or not s:find("^mirrorcoop%-backup 1\n") then return nil end
    local m = { files = {} }
    for line in s:gmatch("[^\n]+") do
        local k, v = line:match("^(%a+)=(.*)$")
        if k then m[k] = v
        elseif line:sub(1, 5) == "file " then
            local sidecar = line:sub(-8) == " sidecar"
            if sidecar then line = line:sub(1, -9) end
            local name, size, crc = line:match("^file (.+) (%d+) (%x+)$")
            if name then m.files[#m.files + 1] = { name = name, size = tonumber(size), crc = crc, sidecar = sidecar } end
        end
    end
    m.pinned = m.pinned == "1"
    return m
end

local function index_path(slot) return slot_dir(slot) .. "\\index.txt" end

local function rebuild_index(slot)
    local entries = {}
    for _, folder in ipairs(savefs.list_dirs(slot_dir(slot)) or {}) do
        local m = backups.manifest(slot, folder)
        if m then
            entries[#entries + 1] = { folder = folder, time = m.time or "", reason = m.reason or "", kind = m.kind or "full",
                                      pinned = m.pinned, version = m.version or "?" }
        end
    end
    table.sort(entries, function(a, b) if a.time ~= b.time then return a.time < b.time end return a.folder < b.folder end)
    if #entries > 0 then log.warn(string.format("backups: rebuilt the index of %s from %d backup(s)", slot, #entries)) end
    return entries
end

local function read_index(slot)
    local s = savefs.read(index_path(slot))
    if not s then return rebuild_index(slot) end
    local entries = {}
    for line in s:gmatch("[^\n]+") do
        local f, t, r, k, p, v = line:match("^([^|]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
        if f then entries[#entries + 1] = { folder = f, time = t, reason = r, kind = k, pinned = p == "1", version = v } end
    end
    return entries
end

local function write_index(slot, entries)
    local out = {}
    for _, e in ipairs(entries) do
        out[#out + 1] = table.concat({ e.folder, e.time, e.reason, e.kind, e.pinned and "1" or "0", e.version }, "|")
    end
    return savefs.write(index_path(slot), table.concat(out, "\n") .. "\n")
end

local function prune(slot, entries)
    local req = backups.pending_restore()
    local function prunable(e)
        return not e.pinned and e.kind ~= "character" and not (req and req.slot == slot and req.folder == e.folder)
    end
    local unpinned = 0
    for _, e in ipairs(entries) do if prunable(e) then unpinned = unpinned + 1 end end
    if unpinned <= kept then return end
    local drop, keep = {}, {}
    for _, e in ipairs(entries) do
        if prunable(e) and unpinned > kept then drop[#drop + 1] = e; unpinned = unpinned - 1
        else keep[#keep + 1] = e end
    end
    if not write_index(slot, keep) then return end
    for _, e in ipairs(drop) do savefs.rmdir(slot_dir(slot) .. "\\" .. e.folder) end
end

function backups.take(o)
    local slot, from, kind, reason = o.slot, o.from or o.slot, o.kind or "full", o.reason or "backup"
    local src = saves_dir .. "\\" .. from
    local files = {}
    local function add(path, name, sidecar) if savefs.exists(path) then files[#files + 1] = { path, name, sidecar } end end
    if o.dir then
        -- a Realm character: kept by plain file name in its own folder, no world
        for _, f in ipairs(backups.LAYOUT.player) do add(o.dir .. "\\" .. f, f) end
        for _, x in ipairs(backups.LAYOUT.sidecars) do add(o.dir .. "\\" .. x, x, true) end
    else
        if kind == "full" then for _, f in ipairs(backups.LAYOUT.world) do add(src .. "\\" .. f, f) end end
        for _, f in ipairs(backups.LAYOUT.player) do add(src .. "\\" .. f, f) end
        for _, x in ipairs(backups.LAYOUT.sidecars) do add(saves_dir .. "\\" .. from .. x, slot .. x, true) end
    end
    if #files == 0 then return nil, "nothing to back up in " .. from end
    local sig = {}
    for _, f in ipairs(files) do
        local data, err = savefs.read_file(f[1])
        if not data then return nil, "can't read " .. f[1] .. ": " .. tostring(err) end
        f[4], f[5] = data, savefs.crc32(data)
        sig[#sig + 1] = f[2] .. " " .. #data .. " " .. f[5]
    end

    local sdir = slot_dir(slot)
    if not savefs.mkdir(sdir) then return nil, "can't create " .. sdir end
    local entries = read_index(slot)
    for i = #entries, 1, -1 do
        if entries[i].kind == kind then
            local m = backups.manifest(slot, entries[i].folder)
            if m and #m.files == #sig then
                local same = true
                for k, mf in ipairs(m.files) do
                    if sig[k] ~= mf.name .. " " .. mf.size .. " " .. mf.crc then same = false; break end
                end
                if same then return entries[i].folder end
            end
            break
        end
    end
    local base = os.date("%Y-%m-%d %H.%M.%S") .. " " .. reason
    local name, n = base, 1
    while savefs.dir_exists(sdir .. "\\" .. name) or savefs.exists(sdir .. "\\" .. name .. "\\backup.txt") do
        n = n + 1; name = base .. " (" .. n .. ")"
    end
    local dir = sdir .. "\\" .. name
    local wrote_manifest = false
    local function fail(why)
        if not savefs.exists(dir .. "\\backup.txt") or wrote_manifest then savefs.rmdir(dir) end
        log.error("backups: backup of " .. slot .. " failed: " .. why)
        return nil, why
    end
    if not savefs.mkdir(dir) then return fail("can't create " .. dir) end

    local lines = {}
    for _, f in ipairs(files) do
        local dst = dir .. "\\" .. f[2]
        local ok, err = savefs.write(dst, f[4])
        if not ok then return fail(err) end
        local data = savefs.read(dst)
        if not data then return fail("can't read back " .. dst) end
        -- the copy must be byte-equal to what we read: then it has the CRC we already have (CRC32 in Lua is slow)
        if data ~= f[4] then return fail("read-back of " .. dst .. " differs from the source") end
        lines[#lines + 1] = string.format("file %s %d %s%s", f[2], #data, f[5], f[3] and " sidecar" or "")
    end
    local pinned = #entries == 0 and not o.dir   -- (a Realm keeps its newest copies only)
    local time = os.date("%Y-%m-%d %H:%M:%S")
    local manifest = table.concat({ "mirrorcoop-backup 1", "slot=" .. slot, "time=" .. time, "reason=" .. reason,
        "kind=" .. kind, "pinned=" .. (pinned and "1" or "0"), "version=" .. version }, "\n") .. "\n"
        .. table.concat(lines, "\n") .. "\n"
    if not savefs.write(dir .. "\\backup.txt", manifest) then return fail("can't write backup.txt") end
    wrote_manifest = true
    entries[#entries + 1] = { folder = name, time = time, reason = reason, kind = kind, pinned = pinned, version = version }
    if not write_index(slot, entries) then return fail("can't write the index") end
    prune(slot, entries)
    log.info(string.format("backups: %s backed up (%s, %d files) -> %s", slot, reason, #files, dir))
    return name
end

function backups.list(slot)
    local out = {}
    local entries = read_index(slot)
    for i = #entries, 1, -1 do
        if savefs.exists(slot_dir(slot) .. "\\" .. entries[i].folder .. "\\backup.txt") then out[#out + 1] = entries[i] end
    end
    return out
end

function backups.verify(slot, folder)
    local m = backups.manifest(slot, folder)
    if not m or #m.files == 0 then return false, "no manifest" end
    for _, f in ipairs(m.files) do
        local data = savefs.read(slot_dir(slot) .. "\\" .. folder .. "\\" .. f.name)
        if not data or #data ~= f.size or savefs.crc32(data) ~= f.crc then return false, f.name .. " doesn't match its checksum" end
    end
    return true
end

function backups.cleanup_orphans(slot)
    for _, folder in ipairs(savefs.list_dirs(slot_dir(slot)) or {}) do
        if not savefs.exists(slot_dir(slot) .. "\\" .. folder .. "\\backup.txt") then
            log.info("backups: removing unfinished backup " .. slot .. "\\" .. folder)
            savefs.rmdir(slot_dir(slot) .. "\\" .. folder)
        end
    end
end

local function request_path() return root .. "\\restore_request.txt" end

function backups.request_restore(slot, folder)
    return savefs.write(request_path(), "slot=" .. slot .. "\nfolder=" .. folder .. "\n")
end

function backups.pending_restore()
    local s = savefs.read(request_path())
    if not s then return nil end
    local slot, folder = s:match("slot=([^\n]+)"), s:match("folder=([^\n]+)")
    if not (slot and folder) then return nil end
    return { slot = slot, folder = folder }
end

function backups.cancel_restore() savefs.remove(request_path()) end

-- ---- Realm characters ----
-- The character a Realm keeps for me (realm.lua's character folder: Player.sav, PlayerInfo.sav and the sidecars by plain
-- name). The key is a folder no save is called, so co-op's listing, pruning and orphan cleanup never reach it.

local REALM_DIR = "SurrounSync Realms"
local is_character_file = {}
for _, f in ipairs(backups.LAYOUT.player) do is_character_file[f] = true end
for _, f in ipairs(backups.LAYOUT.sidecars) do is_character_file[f] = true end

function backups.realm_key(id)
    if type(id) ~= "string" or not id:match("^%w+$") then return nil end
    return REALM_DIR .. "\\" .. id
end

-- dir = the Realm's character folder. nil, nil = no character yet (nothing to keep); nil, why = it failed
function backups.take_realm(id, dir, reason)
    local key = backups.realm_key(id)
    if not (key and root and dir) then return nil, "no backup folder for this Realm" end
    if not savefs.exists(dir .. "\\Player.sav") then return nil end
    local name, err = backups.take{ slot = key, dir = dir, kind = "realm", reason = reason }
    if not name then log.warn("backups: Realm " .. id .. " character not backed up: " .. tostring(err)) end
    return name, err
end

-- newest first, each with the size of all its files
function backups.list_realm(id)
    local key = backups.realm_key(id)
    if not (key and root) then return {} end
    local out = backups.list(key)
    for _, e in ipairs(out) do
        local m, bytes = backups.manifest(key, e.folder), 0
        for _, f in ipairs(m and m.files or {}) do bytes = bytes + f.size end
        e.size = bytes
    end
    return out
end

-- Puts a backup back as the Realm's character. `store` is realm.store_character: that file owns the Realm's folder and
-- its atomic set write, this one never writes there. The character as it is now is backed up first.
function backups.restore_realm(id, folder, dir, store)
    local key = backups.realm_key(id)
    if not (key and root) then return nil, "no backup folder for this Realm" end
    local ok, why = backups.verify(key, folder)
    if not ok then return nil, why end
    local files = {}
    for _, f in ipairs(backups.manifest(key, folder).files) do
        if not is_character_file[f.name] then return nil, "unexpected file " .. f.name .. " in the backup" end
        files[f.name] = savefs.read(slot_dir(key) .. "\\" .. folder .. "\\" .. f.name)
        if not files[f.name] then return nil, "can't read " .. f.name end
    end
    if not files["Player.sav"] then return nil, "the backup has no Player.sav" end
    if savefs.exists(dir .. "\\Player.sav") then
        local kept, err = backups.take_realm(id, dir, "before restore")
        if not kept then return nil, "couldn't back up the current character first: " .. tostring(err) end
    end
    local stored, err = store(id, files)
    if not stored then return nil, err end
    -- (a held character reports done without writing: that is not a restore)
    if savefs.read(dir .. "\\Player.sav") ~= files["Player.sav"] then return nil, "the Realm kept its current character (held?)" end
    log.info("backups: Realm " .. id .. " character restored from " .. folder)
    return true
end

return backups
