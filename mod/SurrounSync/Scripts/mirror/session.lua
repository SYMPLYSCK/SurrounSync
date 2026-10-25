-- Joining and leaving a friend's world. The guest plays a copy of the host's world (a co-op save)
-- with its own character, which is copied back to its own save on the way home. Also crash
-- recovery at startup and the checks that keep every save in the right slot.

local log = require("mirror.log")
local util = require("mirror.util")
local fs = require("mirror.fs")
local backups = require("mirror.backups")
local slotguard = require("mirror.slotguard")
local V = require("mirror.version")
local game = require("mirror.game")
local link = require("mirror.link")
local ghost = require("mirror.ghost")
local invdiag = require("mirror.invdiag")
local notify = require("mirror.notify")
local jig = require("mirror.jig")
local beds = require("mirror.beds")

local session = {}

local carry = { join = nil, leave = nil }
local function carried()
    local n = -1
    pcall(function() n = #jig.contents_of(game.player().BP_JigMultiplayer) end)
    return n
end

local cfg, role
local started, preinit_done = false, false
local peer_connected = function() return true end
local EMS = "/Script/EasyMultiSave.Default__EMSFunctionLibrary"

local WORLD_FILES  = { "Level.sav", "General.sav", "Difficulties.sav", "Slot.sav", "Thumb.sav" }
local later_notes = {}

local state = "idle"
local own_slot = nil
local join_slot, join_stamp = nil, nil
local nonce = nil
local wait = 0.0
local want_toggle = false
local key_join_refused = false
local host_job = nil
local tp = nil
local home = nil
local startup_home = nil
local shared_save = nil
local home_bed, host_world, bed_fix, bed_applied, bed_poll = nil, nil, nil, nil, 0.0
local home_bed_wait = { player = nil, t = 0.0 }
local restore_home_bed, beds_tick

local function preset_spawn(loc, yaw)
    local obj = shared_save
    if not util.valid(obj) then log.info("session: no cached Save_Player to preset the spawn on"); return end
    local h = math.rad(yaw or 0) / 2
    local t = { Translation = { X = loc.X, Y = loc.Y, Z = loc.Z }, Rotation = { X = 0, Y = 0, Z = math.sin(h), W = math.cos(h) },
                Scale3D = { X = 1, Y = 1, Z = 1 } }
    local ok = pcall(function() obj.PlayerLocation = t end)
    if not ok then
        ok = pcall(function()
            local pl = obj.PlayerLocation
            pl.Translation.X, pl.Translation.Y, pl.Translation.Z = loc.X, loc.Y, loc.Z
        end)
    end
    log.info(string.format("session: spawn preset to (%.0f, %.0f, %.0f): %s", loc.X, loc.Y, loc.Z, ok and "ok" or "failed"))
end

local peer_locator = function() return nil end
function session.set_peer_locator(fn) peer_locator = fn end

local function tp_target()
    if not tp then return nil end
    if tp.goal == "host" then
        local gl = peer_locator() or ghost.location() or tp.host_pos
        return gl and { X = gl.X + 150, Y = gl.Y, Z = gl.Z + 50 } or nil
    end
    return tp.home.loc
end
local inv_fix = nil
local home_check = nil

local function base() return (os.getenv("LOCALAPPDATA") or ".") .. "\\SurrounDead" end
local function saves_dir()
    local d = cfg.phase2.saved_override or ((link.kind() == "steam") and "Saved" or cfg.phase2.saved_dir[role])
    return base() .. "\\" .. d .. "\\SaveGames"
end
function session.data_file(name) return saves_dir():gsub("\\SaveGames$", "") .. "\\" .. name end
local world_in, world_ready = {}, nil
local world_shown, world_poll = 0, 0
local JOIN_TIMEOUT = 120
local own_stamp = nil
local leave_try = nil

local function configure_store()
    backups.configure{ saves_dir = saves_dir(), kept = cfg.save and cfg.save.backups_kept or 10, version = V.VERSION }
    slotguard.configure{ saves_dir = saves_dir(), coop_base = cfg.phase2.coop_slot, legacy_base = cfg.phase2.legacy_coop_slot }
    beds.init(saves_dir():gsub("\\SaveGames$", "") .. "\\mirror_coop_beds.txt")
end

local coop_used = 0
local coop = nil
local function coop_name(i) return cfg.phase2.coop_slot .. "_" .. i end
local function is_coop(name) return name ~= nil and slotguard.is_coop(name) end
local function next_coop_slot()
    local n = cfg.phase2.coop_slots or 1
    if coop_used >= n then
        log.warn(string.format("session: all %d co-op slots used this run - reusing; world settings (weather, difficulty) may be stale until you restart the game", n))
    end
    coop_used = coop_used + 1
    for k = 0, n - 1 do
        local name = coop_name(((coop_used - 1 + k) % n) + 1)
        local d = saves_dir() .. "\\" .. name
        if not fs.dir_exists(d) then slotguard.make_coop_dir(name) end
        if fs.dir_exists(d) and not slotguard.foreign(name) then coop_used = coop_used + k; return name end
    end
    return nil
end

local function lib() return util.cdo(EMS) end

local function pose_str(p) return string.format("%.1f %.1f %.1f %.1f", p.loc.X, p.loc.Y, p.loc.Z, p.yaw) end
-- A home far below the map is the void (the player was falling when it was taken): sending
-- anyone there drops them until the game deletes the body.
local VOID_Z = -200000
local function sane_pose(p)
    return p ~= nil and p.loc ~= nil and tonumber(p.loc.Z) ~= nil and p.loc.Z > VOID_Z
end

local function parse_pose(str)
    local x, y, z, yaw = (str or ""):match("^(%S+) (%S+) (%S+) (%S+)$")
    if not yaw then return nil end
    local p = { loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, yaw = tonumber(yaw) }
    if not sane_pose(p) then log.warn("session: ignoring a saved home spot below the map (" .. str .. ")"); return nil end
    return p
end

-- Where I last stood on solid ground in my own world: the home spot when I join mid-fall or mid-load.
local last_ground, ground_in = nil, 0.0
local function track_ground(dt)
    ground_in = ground_in - dt
    if ground_in > 0 then return end
    ground_in = 2.0
    local p = game.player()
    if not util.valid(p) then return end
    local on, pose = false, nil
    pcall(function() on = p.CharacterMovement:IsMovingOnGround() == true end)
    pcall(function() pose = { loc = util.vec(p:K2_GetActorLocation()), yaw = p:K2_GetActorRotation().Yaw } end)
    if on and sane_pose(pose) then last_ground = pose end
end

local function home_now()
    local p, pose, on = game.player(), nil, false
    pcall(function() pose = { loc = util.vec(p:K2_GetActorLocation()), yaw = p:K2_GetActorRotation().Yaw } end)
    pcall(function() on = p.CharacterMovement:IsMovingOnGround() == true end)
    if on and sane_pose(pose) then return pose end
    if last_ground then
        log.warn("session: not standing on solid ground at join - home is where I last stood instead")
        return last_ground
    end
    return sane_pose(pose) and pose or nil
end

local function to_str(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local g
    pcall(function() g = v:get() end)
    if type(g) == "string" then return g end
    if g ~= nil and type(g) ~= "number" then
        local s; pcall(function() s = g:ToString() end)
        if type(s) == "string" then return s end
    end
    local s2; pcall(function() s2 = v:ToString() end)
    if type(s2) == "string" then return s2 end
    return nil
end

local function slot_exists(name)
    local ok = false
    pcall(function() ok = lib():DoesSaveSlotExist(game.world(), name) end)
    return ok == true
end

local function slot_names()
    local names, arr = {}, nil
    pcall(function() arr = lib():GetSortedSaveSlots(game.world()) end)
    if type(arr) == "table" then
        for _, v in pairs(arr) do local s = to_str(v); if s and s ~= "" then names[#names + 1] = s end end
    elseif arr ~= nil then
        pcall(function() arr:ForEach(function(_, e) local s = to_str(e); if s and s ~= "" then names[#names + 1] = s end end) end)
    end
    return names
end

local function slot_ticks(name)
    local t
    pcall(function() t = lib():GetNamedSlotInfo(game.world(), name).SlotInfo.Timestamp.Ticks end)
    return type(t) == "number" and t or nil
end

local function newest_slot(exclude)
    local best, best_t
    for _, n in ipairs(slot_names()) do
        if n ~= exclude then
            local t = slot_ticks(n)
            if t and (not best_t or t > best_t) then best, best_t = n, t end
        end
    end
    return best
end

local ems_obj = nil
local function ems_current_name()
    if not util.valid(ems_obj) then
        ems_obj = nil
        pcall(function()
            for _, o in ipairs(FindAllOf("EMSObject") or {}) do
                if util.class_name(o) == "EMSObject" then ems_obj = o end
            end
        end)
    end
    local name
    if ems_obj then pcall(function() name = to_str(ems_obj.CurrentSaveGameName) end) end
    return name
end

local function current_slot(exclude)
    local w, name = game.world(), nil
    local cur = ems_current_name()
    if cur and cur ~= "" and cur ~= exclude and slot_exists(cur) then return cur, "EMS CurrentSaveGameName" end
    pcall(function() name = to_str(lib():GetSlotInfoSaveGame(w).SlotInfo.Name) end)
    if not (name and slot_exists(name)) then
        local out = {}
        pcall(function() local info = lib():GetSlotInfoSaveGame(w, out); name = to_str(info.SlotInfo.Name) end)
        if not (name and slot_exists(name)) then name = to_str(out.SaveGameName) or to_str(out[1]) end
    end
    if name and name ~= exclude and slot_exists(name) then return name, "EMS current" end
    local n = newest_slot(exclude)
    if n then return n, "newest saved" end
    return nil, "none"
end

local function saving()
    local busy = false
    pcall(function() busy = lib():IsSavingOrLoading(game.world()) end)
    return busy
end

local function save_now()
    local pc = game.controller()
    local ok = pcall(function() pc:SaveGameToSlot() end)
    log.info("session: SaveGameToSlot -> " .. tostring(ok))
    return ok
end

local PLAYER_SAVES = { playerinfo = true }

-- EMS caches every slot's custom saves at startup and never re-reads them. Only the cached
-- value is swapped here: removing or adding TMap entries from Lua crashes UE4SS.
local function ems_share_player(coop, own)
    local ems
    for _, o in ipairs(FindAllOf("EMSObject") or {}) do
        if util.class_name(o) == "EMSObject" then ems = o end
    end
    if not ems then log.warn("session: no EMSObject - can't fix its cache"); return end
    local c, o = "@cso@" .. coop:lower(), "@cso@" .. own:lower()
    local own_objs, coop_vals = {}, {}
    pcall(function()
        ems.CachedCustomSaves:ForEach(function(k, v)
            local key = (to_str(k) or ""):lower()
            local file = key:match("^(.-)@cso@")
            if file and PLAYER_SAVES[file] then
                if key:sub(-#o) == o then own_objs[file] = v:get()
                elseif key:sub(-#c) == c then coop_vals[file] = v end
            end
        end)
    end)
    shared_save = own_objs.playerinfo
    for file in pairs(PLAYER_SAVES) do
        local src, dst = own_objs[file], coop_vals[file]
        if dst and util.valid(src) then
            local ok, err = pcall(function() dst:set(src) end)
            log.info(string.format("session: EMS cache %s@%s -> own object %s: %s",
                file, coop, util.fname(src), ok and "ok" or tostring(err)))
        elseif dst then
            log.warn(string.format("session: EMS cache has a stale %s for %s but none for %s", file, coop, own))
        else
            log.info(string.format("session: EMS cache has no %s for %s - it will read the file", file, coop))
        end
    end
end

local own_load = false
local function clear_home_log()
    local t = slotguard.log_read()
    if t and t.step == "home" then slotguard.log_clear() end
end

local function load_slot(slot)
    if session.hold_autosave then session.hold_autosave() end
    local w = game.world()
    local okn = pcall(function() lib():SetCurrentSaveGameName(w, slot) end)
    log.info(string.format("session: SetCurrentSaveGameName(%s) -> %s", slot, tostring(okn)))
    ghost.destroy("level reload")
    local p = game.player()
    pcall(function() p:ClearUI() end)
    pcall(function() p:DestroyActors() end)
    local gi = FindFirstOf("SD_GameInstance_C")
    if not util.valid(gi) then log.error("session: no SD_GameInstance_C"); return false end
    own_load = true
    local ok, err = pcall(function() gi:Event_LoadLevel(gi.CurrentLevel) end)
    own_load = false
    log.info("session: Event_LoadLevel -> " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
    return ok
end

local function say_later(msg, kind) later_notes[#later_notes + 1] = { msg, kind } end
local restore_now

local function flush_notes()
    if #later_notes == 0 or not util.valid(game.player()) then return end
    for _, n in ipairs(later_notes) do notify.show(n[1], n[2]) end
    later_notes = {}
end

local function purge_all_coop_slots()
    local t, bad = slotguard.log_read()
    if bad or slotguard.log_quarantined() then
        log.warn("session: a damaged session log is kept - leaving every co-op save alone (it may hold your character)")
        return
    end
    local keep = t and t.coop
    local function purge(name) if name ~= keep then slotguard.purge(name) end end
    purge(cfg.phase2.coop_slot)
    for i = 1, cfg.phase2.coop_slots or 1 do purge(coop_name(i)) end
    local lb = cfg.phase2.legacy_coop_slot
    if lb then purge(lb); for i = 1, cfg.phase2.coop_slots or 1 do purge(lb .. "_" .. i) end end
end

local function repair_slot(slot)
    if not slotguard.valid_name(slot) then return end
    for _, list in ipairs({ backups.LAYOUT.world, backups.LAYOUT.player }) do
        for _, f in ipairs(list) do slotguard.repair(slot, f) end
    end
    for _, x in ipairs(backups.LAYOUT.sidecars) do slotguard.repair_sidecar(slot, x) end
end

restore_now = function(slot, folder)
    local ok, err, permanent = slotguard.apply_restore(slot, folder)
    if ok or permanent then
        backups.cancel_restore()
        slotguard.log_clear()
    end
    if ok then say_later("Restored " .. slot .. " to the backup from " .. folder .. ".", "good")
    elseif permanent then say_later("Couldn't restore " .. slot .. ". Your save is unchanged.", "bad")
    else say_later("Couldn't restore " .. slot .. " yet. Your save is unchanged, and the restore will be retried next time you start the game.", "bad") end
end

function session.startup_restore()
    configure_store()
    local t, bad = slotguard.log_read()
    if bad then
        slotguard.log_quarantine()
        say_later("Found a damaged co-op session file and left your saves untouched. Please report this with your SurrounSync log.", "bad")
    elseif t then
        repair_slot(t.own); repair_slot(t.coop)
        if t.step == "building" then
            log.info("session: the last join stopped while building the co-op save - your save was never touched")
            slotguard.purge(t.coop)
            slotguard.log_clear()
        elseif t.step == "joined" or t.step == "leaving" then
            t.step = "leaving"
            slotguard.log_write(t)
            local r, err = slotguard.copy_character_home(t.coop, t.own)
            if r == "copied" or r == "empty" then
                log.info("session: restore after unfinished session - character copied home to " .. t.own .. " (" .. r .. ")")
                local pose = parse_pose(t.home)
                if pose then startup_home = { slot = t.own, pose = pose } end
                slotguard.log_clear()
                slotguard.purge(t.coop)
            elseif r == "kept" then
                say_later("Your own save changed during co-op, so it was not overwritten. Your co-op character is kept in Backups (handbook J, CO-OP tab).", "bad")
                slotguard.log_clear()
                slotguard.purge(t.coop)
            else
                t.tries = tostring((tonumber(t.tries) or 0) + 1)
                if tonumber(t.tries) >= 5 then
                    slotguard.log_quarantine()
                    say_later("Couldn't bring your co-op character home after 5 tries. Your saves are untouched and backed up. "
                        .. "Please report this with your SurrounSync log.", "bad")
                else
                    slotguard.log_write(t)
                    log.error("session: couldn't copy your co-op character home (" .. tostring(err) .. ") - will try again next start")
                    say_later("Couldn't bring your co-op character home yet. It is safe, and this is retried when you restart the game.", "bad")
                end
            end
        elseif t.step == "home" then
            local pose = parse_pose(t.home)
            if pose then startup_home = { slot = t.own, pose = pose } end
            log.info("session: the last leave didn't finish - your character was already copied back; moving you home")
            slotguard.log_clear()
            slotguard.purge(t.coop)
        elseif t.step == "restoring" then
            restore_now(t.own, t.folder)
        end
    end
    if slotguard.log_read() then return end
    local req = backups.pending_restore()
    if req then
        slotguard.log_write{ step = "restoring", own = req.slot, folder = req.folder, time = os.date("%Y-%m-%d %H:%M:%S"), version = V.VERSION }
        restore_now(req.slot, req.folder)
    end
end

local function host_export(job)
    local slot, how = current_slot()
    if not slot then
        log.error(string.format("session: host has no current slot (%d slots visible)", #slot_names()))
        link.put_blob("world", "fail " .. job.nonce)
        return false
    end
    log.info("session: host slot " .. slot .. " (" .. how .. ")")
    if not backups.take{ slot = slot, reason = "a guest is joining" } then
        notify.show("Couldn't back up your save, so " .. link.peer_name() .. " can't join right now. Check that your disk has free space.", "bad")
        link.put_blob("world", "fail " .. job.nonce)
        return false
    end
    local dir = saves_dir() .. "\\" .. slot
    local n = 0
    for _, f in ipairs(WORLD_FILES) do
        local data = fs.read(dir .. "\\" .. f)
        if data then link.put_file("world_" .. f, data, job.nonce); n = n + 1 end
    end
    link.put_blob("hostbed", beds.read() or "0")
    link.put_blob("world", string.format("ready %s %s %d", job.nonce, slot, n))
    log.info(string.format("session: host exported %d world file(s) from %s for join %s", n, slot, job.nonce))
    return true
end

local function host_tick(dt)
    local req = link.get_blob("req")
    if req then
        local n = req:match("^join (%S+)")
        if n and link.peer_age(tonumber(n) or 0) > 300 then
            log.info("session: ignoring stale join request " .. n)
            n = nil
        end
        if n then
            log.info("session: join request " .. n .. " - saving")
            notify.show(link.peer_name() .. " is joining your world...", "info")
            host_job = { nonce = n, t = 0.0 }
            save_now()
        end
    end
    if host_job then
        host_job.t = host_job.t + dt
        if host_job.t > 1.5 and not saving() then
            host_export(host_job)
            host_job = nil
        end
    end
end

local function session_log(step)
    return {
        step = step, own = own_slot, coop = coop, home = home and pose_str(home) or nil, own_stamp = own_stamp,
        host = link.peer_name(), time = os.date("%Y-%m-%d %H:%M:%S"), version = V.VERSION,
    }
end

local function build_coop_slot(own, files)
    coop = next_coop_slot()
    if not coop then
        log.error("session: no co-op slot folder " .. coop_name(1) .. " in " .. saves_dir() .. " (run tools\\setup-guest.ps1)")
        return false
    end
    slotguard.purge(coop)
    if not slotguard.log_write(session_log("building")) then return false end
    local ok, err = slotguard.seed_character(own, coop)
    if ok then ok, err = slotguard.import_world(coop, files) end
    if not ok then
        log.error("session: could not build " .. coop .. ": " .. tostring(err))
        slotguard.purge(coop)
        slotguard.log_clear()
        return false
    end
    slotguard.log_write(session_log("joined"))
    log.info(string.format("session: built %s from the host's world + own %s character", coop, own))
    return true
end

local exit_check = 0.0
local home_reload = nil
local function unplanned_exit(cur, before_load)
    log.warn("session: left the co-op world through the game's menu (now in " .. tostring(cur) .. ")")
    state, tp, inv_fix = "idle", nil, nil
    local t = slotguard.log_read()
    if not t or not t.coop then return end
    t.step = "leaving"
    slotguard.log_write(t)
    local r, err = slotguard.copy_character_home(t.coop, t.own)
    if r == "copied" or r == "empty" then
        slotguard.purge(t.coop)
        if cur == t.own then
            t.step = "home"
            slotguard.log_write(t)
            local pose = parse_pose(t.home)
            tp = pose and { goal = "home", home = pose, settle = 0.0, tries = 0 } or nil
            notify.show("Bringing your co-op character home...", "info")
            if not before_load then home_reload = { slot = t.own, t = 0.0 } end
        else
            slotguard.log_clear()
            notify.show("Your co-op character was saved to " .. t.own .. ".", "good")
        end
    elseif r == "kept" then
        notify.show("Your own save changed during co-op, so it was not overwritten. Your co-op character is kept in "
            .. "Backups (handbook J, CO-OP tab). Restart the game before you continue.", "bad")
        slotguard.log_clear()
        slotguard.purge(t.coop)
    else
        log.error("session: couldn't copy the character home after the menu exit: " .. tostring(err))
        notify.show("Couldn't bring your co-op character home yet. It is safe, and this is retried when you restart the game.", "bad")
    end
end

function session.on_load_level()
    if own_load or role ~= "guest" or state ~= "joined" or not coop then return end
    local cur = ems_current_name()
    if cur and cur ~= "" and cur ~= coop then unplanned_exit(cur, true) end
end

local coop_player = nil
local function keep_coop_slot(why)
    if role ~= "guest" or state ~= "joined" or not coop then return false end
    local cur = ems_current_name()
    if not cur or cur == "" or cur == coop then return false end
    local ok = pcall(function() lib():SetCurrentSaveGameName(game.world(), coop) end)
    log.info(string.format("session: %s picked slot %s while joined - kept the co-op slot %s (%s)", why, cur, coop,
        tostring(ok)))
    notify.show("You're in " .. link.peer_name() .. "'s world, so the game saves to the co-op session. Your own save "
        .. "gets your character when you leave.", "info")
    return ok
end
local world_slot = nil
local level_loading = false
local restore_name = nil
local cleared_world, discard_pending = false, false
local function point_at(slot)
    return pcall(function() lib():SetCurrentSaveGameName(game.world(), slot) end)
end
-- Runs before every save. A save writes the world in memory into whatever slot EMS points at,
-- so make sure that's the slot this world belongs to (the Save menu and the 'autosave to a
-- new slot' option both switch slots first).
local function firewall(why)
    if keep_coop_slot(why) then return end
    local cur = ems_current_name()
    if not cur or cur == "" then return end
    local my_session = role == "guest" and coop == cur and state ~= "idle"
    if is_coop(cur) and not my_session and world_slot and world_slot ~= cur and not is_coop(world_slot) then
        local ok = point_at(world_slot)
        log.warn(string.format("session: firewall - a save pointed at the co-op save %s outside its session; sent to %s (%s)",
            cur, world_slot, tostring(ok)))
        return
    end
    if level_loading and cleared_world then
        -- The old world's actors are already removed and the new one isn't loaded: this save would write
        -- a half-empty world over either save. Send it to a scratch co-op slot that gets emptied.
        local scratch = cfg.phase2.coop_slot
        if cur ~= scratch then
            local ok = point_at(scratch)
            restore_name = restore_name or cur
            discard_pending = true
            log.warn(string.format("session: firewall - a save started during a load (%s); sent to the scratch slot %s (%s)",
                cur, scratch, tostring(ok)))
        end
        return
    end
    if level_loading and world_slot and cur ~= world_slot and slotguard.valid_name(world_slot) then
        local ok = point_at(world_slot)
        restore_name = restore_name or cur
        log.warn(string.format("session: firewall - a save started while %s loads; it goes to %s, the world it holds (%s)",
            cur, world_slot, tostring(ok)))
    end
end
require("mirror.save_guard").set_before_save(function()
    util.safe(firewall, "session.firewall", "the game's save")
    session.on_any_save()
end)

local function hold_autosave()
    pcall(function()
        local gm = util.cdo("/Script/Engine.Default__GameplayStatics"):GetGameMode(game.world())
        if util.valid(gm) then util.cdo("/Script/Engine.Default__KismetSystemLibrary"):K2_ClearTimer(gm, "AutoSaveGame") end
    end)
end
session.hold_autosave = hold_autosave

-- The game "loads" a save in place: the level blueprint only swaps the LongdownValley sublevel, so
-- everything spawned at runtime into the persistent level (buildings, crates, cars, item spawners,
-- traders) stays and the next save writes it into the new world - the host's base turned up in the
-- guest's own save. A load must start from an empty persistent level like a fresh game: remove every
-- actor EMS saves there; EMS spawns the loaded world's own ones from its file.
local PERSISTENT = "/Game/Levels/PersistentLevel.PersistentLevel:PersistentLevel."
local function clear_runtime_actors()
    local w = game.world()
    if not w then return end
    local gs = util.cdo("/Script/Engine.Default__GameplayStatics")
    local ic = StaticFindObject("/Script/EasyMultiSave.EMSActorSaveInterface")
    if not util.valid(gs) or not util.valid(ic) then
        log.warn("session: can't clear the old world's actors (no GameplayStatics / EMS save interface)")
        return
    end
    local out = {}
    local ok, err = pcall(function() gs:GetAllActorsWithInterface(w, ic, out) end)
    if not ok then log.warn("session: can't list the old world's actors: " .. tostring(err)); return end
    local n, failed, kinds = 0, 0, {}
    for _, ref in ipairs(out) do
        local a
        pcall(function() a = ref:get() end)
        local cls = util.valid(a) and util.class_name(a) or nil
        local full
        if cls then pcall(function() full = a:GetFullName() end) end
        if full and full:find(PERSISTENT, 1, true) and not cls:find("^BP_PlayerC") then
            local ctrl
            pcall(function() ctrl = a.Controller end)
            if pcall(function() a:K2_DestroyActor() end) then
                n = n + 1
                local k = cls:gsub("_C$", ""):gsub("^Container_", ""):gsub("^Buildable_", "B:")
                kinds[k] = (kinds[k] or 0) + 1
                if util.valid(ctrl) and util.class_name(ctrl) ~= "BP_PlayerController_C" then
                    pcall(function() ctrl:K2_DestroyActor() end)
                end
            else failed = failed + 1 end
        end
    end
    cleared_world = true
    game.reset_world()
    local top = {}
    for k, c in pairs(kinds) do top[#top + 1] = { k, c } end
    table.sort(top, function(x, y) return x[2] > y[2] end)
    local s = {}
    for i = 1, math.min(8, #top) do s[#s + 1] = top[i][2] .. " " .. top[i][1] end
    log.info(string.format("session: load - removed %d runtime actor(s) of the old world%s (%s)", n,
        failed > 0 and (", " .. failed .. " failed") or "", table.concat(s, ", ")))
end

local function on_any_load()
    level_loading = true
    util.safe(clear_runtime_actors, "session.clear_runtime_actors")
end
local function on_world_ready()
    level_loading, cleared_world = false, false
    world_slot = ems_current_name()
    log.info("session: this world is save " .. tostring(world_slot))
end
local function firewall_tick()
    if restore_name and not saving() then
        local n = restore_name
        restore_name = nil
        local ok = point_at(n)
        log.info(string.format("session: firewall - pointed the game at %s again (%s)", n, tostring(ok)))
    end
    if discard_pending and not restore_name and not level_loading and not saving() then
        discard_pending = false
        slotguard.adopt(cfg.phase2.coop_slot)
        slotguard.purge(cfg.phase2.coop_slot)
    end
end

local function check_exit()
    if state ~= "joined" or not coop then return end
    local cur = ems_current_name()
    if not (cur and cur ~= "" and cur ~= coop) then return end
    if coop_player and util.valid(coop_player) and util.same(game.player(), coop_player) then
        keep_coop_slot("the game's menu")
        return
    end
    unplanned_exit(cur)
end

local peer_state = function() return "unknown" end
local player_dead
function session.set_peer_state(fn) peer_state = fn end
local gone = nil
local paused_told = false

local alive_for = 0.0
local dead_told = false
player_dead = function()
    local dead = false
    pcall(function() dead = game.player()["PlayerDead?"] == true end)
    return dead or alive_for < 3.0
end

local function watch_host(dt)
    if state ~= "joined" then gone, paused_told = nil, false; return end
    local ps = peer_state()
    if ps == "gone" or (gone and ps ~= "ok") then
        gone = gone or { left = cfg.save and cfg.save.host_gone_countdown or 30, next_msg = 0.0 }
        if gone.waiting then return end
        local secs = math.ceil(gone.left)
        if not gone.told or (secs <= 10 and gone.told > 10) then
            gone.told = secs
            notify.show(string.format("%s's game closed. Returning you home in %d seconds...", link.peer_name(), secs), "bad", "hostgone")
        end
        gone.left = gone.left - dt
        if gone.left <= 0 and not player_dead() then
            log.info("session: host gone - going home")
            gone, want_toggle = nil, true
        end
    elseif ps == "ok" then
        if gone then notify.show(link.peer_name() .. " is back.", "good"); gone = nil end
        paused_told = false
    elseif ps == "paused" and not paused_told then
        paused_told = true
        notify.show(link.peer_name() .. " paused their game.", "info")
    end
end

function session.host_gone() return gone and not gone.waiting and math.ceil(gone.left) or nil end
function session.go_home_now() if state == "joined" then gone, want_toggle = nil, true end end
function session.wait_for_host()
    if gone then gone.waiting = true; notify.show("Waiting for " .. link.peer_name() .. ". Choose Leave in the handbook's CO-OP tab (J) when you want to go home.", "info") end
end

restore_home_bed = function()
    local cur = ems_current_name()
    local hb = cur and cur ~= "" and not is_coop(cur) and beds.get(beds.home_key(cur))
    if not hb then return false end
    local ok = beds.apply(hb)
    log.info("session: respawn point back to your own world's" .. (ok and "" or " - FAILED"))
    if ok then beds.set(beds.home_key(cur), nil) end
    return ok
end

beds_tick = function(dt)
    if state == "joined" and not tp then
        if bed_fix and not inv_fix and not saving() then
            bed_fix.t = bed_fix.t + dt
            if bed_fix.t >= 2.0 and not bed_fix.want then
                local mine = host_world and beds.get(host_world)
                local hb = link.get_blob("hostbed")
                local why
                if beds.is_set(mine) then bed_fix.want, why = mine, "the bed you set in this world"
                elseif beds.is_set(hb) then bed_fix.want, why = hb, link.peer_name() .. "'s bed"
                else bed_fix.want, why = "0", "a random start (no bed here yet)" end
                local ok = beds.apply(bed_fix.want)
                bed_applied = beds.read()
                log.info("session: respawn point in this world = " .. why .. (ok and "" or " - FAILED"))
            elseif bed_fix.want and bed_fix.t >= 6.0 then
                if beds.read() ~= bed_applied then
                    log.info("session: respawn point was reset by the game - putting it back")
                    beds.apply(bed_fix.want)
                    bed_applied = beds.read()
                end
                bed_fix = nil
            end
        elseif not bed_fix and bed_applied and host_world then
            bed_poll = bed_poll - dt
            if bed_poll <= 0 then
                bed_poll = 2.0
                local now_bed = beds.read()
                if now_bed and now_bed ~= bed_applied then
                    bed_applied = now_bed
                    if beds.is_set(now_bed) and beds.set(host_world, now_bed) then
                        log.info("session: new respawn point in this world - remembered for your next visit")
                    end
                end
            end
        end
    elseif state == "idle" and not tp and not home_reload then
        local p = game.player()
        if not util.same(p, home_bed_wait.player) then home_bed_wait = { player = p, t = 0.0 } end
        home_bed_wait.t = home_bed_wait.t + dt
        if util.valid(p) and home_bed_wait.t >= 5.0 and not home_bed_wait.done and not saving() then
            home_bed_wait.done = true
            if restore_home_bed() then save_now() end
        end
    end
end

local function guest_tick(dt)
    if home_reload then
        home_reload.t = home_reload.t + dt
        if home_reload.t >= 3.0 and not saving() and util.valid(game.player()) then
            local slot = home_reload.slot
            home_reload = nil
            log.info("session: level settled - reloading " .. slot .. " to bring the co-op character home")
            load_slot(slot)
        end
    end
    exit_check = exit_check - dt
    if exit_check <= 0 then exit_check = 1.0; check_exit() end
    local dead_now = false
    pcall(function() dead_now = game.player()["PlayerDead?"] == true end)
    alive_for = dead_now and 0.0 or (alive_for + dt)
    watch_host(dt)
    local hold_join = want_toggle and state == "idle" and tp ~= nil
    local hold_leave = (want_toggle and state == "joined" and player_dead()) or hold_join
    if hold_join and not dead_told then
        dead_told = true
        notify.show("One moment. Finishing your trip home first.", "info")
    elseif hold_leave and not dead_told then
        dead_told = true
        notify.show("You'll return home once you respawn.", "info")
    elseif not hold_leave then
        dead_told = false
    end
    if key_join_refused then
        key_join_refused = false
        notify.show("You're in your own world. To join " .. link.peer_name() .. ", open the CO-OP tab of your handbook (J).", "info")
    end
    if want_toggle and not hold_leave then
        want_toggle = false
        if state == "idle" and not peer_connected() then
            notify.show("No host is connected yet. Your friend needs to be in-game with SurrounSync and choose Host.", "bad")
        elseif state == "idle" and slotguard.log_exists() then
            notify.show("Your last co-op session hasn't finished yet. Restart the game to complete it, then join.", "bad")
        elseif state == "idle" then
            notify.show("Joining " .. link.peer_name() .. "'s world...", "info")
            log.info("session: joining - saving my own world first")
            home = home_now()
            home_bed = beds.read()
            if cfg.diagnostics then util.safe(invdiag.snapshot, "invdiag", "before join") end
            carry.join = carried()
            log.info("session: carrying " .. carry.join .. " item stack(s) into the co-op world")
            join_slot, join_stamp = ems_current_name(), nil
            if join_slot then join_stamp = fs.read(saves_dir() .. "\\" .. join_slot .. "\\Slot.sav") end
            save_now()
            state, wait = "saving_own", 0.0
        elseif state == "joined" then
            log.info("session: leaving - saving into the co-op slot")
            carry.leave = carried()
            log.info("session: taking " .. carry.leave .. " item stack(s) home")
            notify.show("Leaving " .. link.peer_name() .. "'s world...", "info")
            local hb = own_slot and beds.get(beds.home_key(own_slot))
            if hb then
                log.info("session: respawn point back to your own world's" .. (beds.apply(hb) and "" or " - FAILED"))
            end
            bed_fix, bed_applied = nil, nil
            save_now()
            state, wait = "leaving_save", 0.0
        else
            log.info("session: busy (" .. state .. "), key ignored")
            notify.show("One moment, please.", "info")
        end
    end

    if state == "saving_own" then
        wait = wait + dt
        if wait > 1.5 and not saving() then
            local how
            own_slot, how = current_slot(nil)
            local unchanged = own_slot and join_stamp and own_slot == join_slot
                and fs.read(saves_dir() .. "\\" .. own_slot .. "\\Slot.sav") == join_stamp
            if unchanged and wait < 8.0 then
            elseif unchanged then
                log.error("session: your game did NOT save (saving may be blocked here) - not joining, so your save can't get mixed up")
                notify.show("Your game couldn't be saved here, so you can't join yet. Move to a spot where saving works and try again.", "bad")
                own_slot, state = nil, "idle"
            elseif is_coop(own_slot) then
                log.error("session: you're playing the co-op slot itself (" .. own_slot .. ") - load one of your own saves, then join")
                notify.show("Load one of your own saves first, then join.", "bad")
                own_slot, state = nil, "idle"
            elseif not slotguard.is_own(own_slot) then
                log.error(string.format("session: can't tell which slot I'm on (%d slots visible); not joining", #slot_names()))
                notify.show("Couldn't identify your current save, so you can't join. Please report this with your SurrounSync log.", "bad")
                state = "idle"
            else
                log.info("session: my slot is " .. own_slot .. " (" .. how .. ")")
                local backed = backups.take{ slot = own_slot, reason = "before joining" }
                own_stamp = slotguard.stamp(own_slot)
                if not backed or not own_stamp then
                    log.error("session: no backup / fingerprint of " .. own_slot .. " - not joining")
                    notify.show("Couldn't back up your save, so you can't join. Check that your disk has free space.", "bad")
                    own_slot, state = nil, "idle"
                    return
                end
                nonce = tostring(os.time())
                link.reset_blob("world")
                world_in, world_ready, world_shown, world_poll = {}, nil, 0, 0
                link.put_blob("req", "join " .. nonce)
                state, wait = "requested", 0.0
                log.info("session: join requested (" .. nonce .. ")")
            end
        end
    elseif state == "requested" then
        wait = wait + dt
        world_poll = (world_poll or 0) - dt
        if world_poll <= 0 then
            world_poll = 0.25
            for _, f in ipairs(WORLD_FILES) do
                local data, tag = link.get_file("world_" .. f)
                if data and tag == nonce then world_in[f] = data end
            end
        end
        local got = 0
        for _ in pairs(world_in) do got = got + 1 end
        if got ~= (world_shown or 0) and got > 0 then
            world_shown = got
            log.info(string.format("session: receiving %s's world... %d/%d", link.peer_name(), got, #WORLD_FILES))
        end
        local w = link.get_blob("world")
        if w and w == "fail " .. nonce then
            log.error("session: host could not export its world")
            notify.show(link.peer_name() .. " couldn't send their world. Please try again.", "bad")
            state = "idle"
        elseif w then
            local n, host_slot, count = w:match("^ready (%S+) (.+) (%d+)$")
            if n == nonce then world_ready = { slot = host_slot, count = tonumber(count) or #WORLD_FILES, raw = count } end
        end
        if state == "requested" and world_ready and got >= world_ready.count and world_in["Level.sav"] then
            do
                local host_slot = world_ready.slot
                local world_ready_count = world_ready.raw
                world_ready = nil
                local own = own_slot
                log.info(string.format("session: host world received (host slot %s, %d files); my slot %s", host_slot, got, tostring(own)))
                local valid = slotguard.validate_world(world_in, { nonce = nonce, expect_nonce = nonce, slot = host_slot, count = world_ready_count })
                if not valid then
                    notify.show("The world from " .. link.peer_name() .. " arrived damaged. Please try again.", "bad")
                    state = "idle"
                elseif own and not is_coop(own) and build_coop_slot(own, world_in) then
                    ems_share_player(coop, own)
                    if home_bed then beds.set(beds.home_key(own), home_bed) end
                    host_world = beds.world_key(link.peer_name(), host_slot, own)
                    tp = { goal = "host", settle = 0.0, tries = 0, host_pos = peer_locator() or ghost.location() }
                    local t = tp_target()
                    if t then preset_spawn(t, home and home.yaw or 0) end
                    log.info("session: world received - loading in")
                    load_slot(coop)
                    state = "joined"
                else
                    log.error("session: could not build the co-op slot; staying in own world")
                    notify.show("Couldn't prepare the co-op save, so you stayed in your own world. Reinstalling SurrounSync may help.", "bad")
                    state = "idle"
                end
            end
        elseif state == "requested" and wait > JOIN_TIMEOUT then
            log.warn(string.format("session: host did not send its world within %d s (%d file(s) arrived, ready=%s)",
                JOIN_TIMEOUT, got, tostring(world_ready ~= nil)))
            notify.show(link.peer_name() .. " didn't send their world in time. Please try again.", "bad")
            state = "idle"
        end
    -- Wait for the save to finish before touching any files.
    elseif state == "leaving_save" then
        wait = wait + dt
        if wait > 1.5 and not saving() then
            local t = slotguard.log_read()
            if not t or not t.own then
                log.error("session: no session log - don't know my own slot; staying")
                notify.show("Couldn't find your own save to return to, so you stayed here.", "bad")
                state, bed_fix = "joined", { t = 0.0 }
            else
                leave_try = leave_try or { n = 0, wait = 0.0 }
                leave_try.wait = leave_try.wait - dt
                if leave_try.wait <= 0 then
                    leave_try.n, leave_try.wait = leave_try.n + 1, 0.5
                    t.step = "leaving"
                    slotguard.log_write(t)
                    local r, err = slotguard.copy_character_home(t.coop, t.own)
                    if r then
                        leave_try = nil
                        beds.set(beds.home_key(t.own), nil)
                        local pose = parse_pose(t.home) or (sane_pose(home) and home or nil)
                        if r == "kept" then
                            notify.show("Your own save changed during co-op, so it was not overwritten. Your co-op character is kept in "
                                .. "Backups (handbook J, CO-OP tab). Quit and restart the game to continue in your own world.", "bad")
                            slotguard.log_clear()
                            tp = nil
                        else
                            t.step = "home"
                            slotguard.log_write(t)
                            tp = pose and { goal = "home", home = pose, settle = 0.0, tries = 0 } or nil
                            if pose then preset_spawn(pose.loc, pose.yaw) end
                            load_slot(t.own)
                            slotguard.purge(t.coop)
                        end
                        state = "idle"
                    elseif leave_try.n >= 10 then
                        leave_try = nil
                        log.error("session: couldn't copy the character home: " .. tostring(err))
                        notify.show("Couldn't bring your character home. Your save is unchanged and you're still in co-op. Try Leave again.", "bad")
                        state, bed_fix = "joined", { t = 0.0 }
                    end
                end
            end
        end
    end

    if not tp and startup_home and util.valid(game.player()) then
        local cur
        pcall(function()
            for _, o in ipairs(FindAllOf("EMSObject") or {}) do
                if util.class_name(o) == "EMSObject" then cur = to_str(o.CurrentSaveGameName) end
            end
        end)
        if cur == startup_home.slot then
            log.info("session: " .. cur .. " loaded after an unfinished session - moving back to where I joined from")
            tp = { goal = "home", home = startup_home.pose, settle = 0.0, tries = 0 }
        end
        startup_home = nil
    end
    if tp then
        local p = game.player()
        local target = tp_target()
        if not util.same(p, tp.player) then tp.player, tp.settle = p, 0.0 end
        if not util.valid(p) or not target or saving() then
            tp.settle = 0.0
        else
            tp.settle = tp.settle + dt
            local pl
            pcall(function() pl = util.vec(p:K2_GetActorLocation()) end)
            local what = tp.goal == "host" and "next to the host" or "back home"
            if tp.sent_at then
                if tp.settle - tp.sent_at >= 1.0 then
                    local d = pl and util.dist(target, pl) or math.huge
                    if d <= cfg.phase2.teleport_tolerance then
                        log.info(string.format("session: %s (%.0f m)",
                            tp.goal == "host" and "joined - next to the host" or "left - back home", d / 100))
                        if tp.goal == "host" then
                            coop_player = game.player()
                            notify.show("Joined " .. link.peer_name() .. "'s world. Leave any time with Ctrl+F10 or the handbook's CO-OP tab (J).", "good")
                        end
                        if tp.goal == "host" then
                            inv_fix, bed_fix = { t = 0.0 }, { t = 0.0 }
                        else
                            restore_home_bed()
                            save_now()
                            clear_home_log()
                            home_check = { t = 0.0 }
                        end
                        tp = nil
                    elseif tp.tries >= 3 then
                        log.warn(string.format("session: teleport %s didn't stick after 3 tries (%.0f m off)", what, d / 100))
                        notify.show(tp.goal == "host" and ("Joined " .. link.peer_name() .. "'s world, but couldn't place you next to them.")
                            or "Back in your own world, but not at the spot you left from.", "info")
                        if tp.goal == "host" then inv_fix, bed_fix = { t = 0.0 }, { t = 0.0 }
                        else
                            if restore_home_bed() then save_now() end
                            home_check = { t = 0.0 }; clear_home_log()
                        end
                        tp = nil
                    else
                        log.info(string.format("session: teleport undone (%.0f m off); retrying", d / 100))
                        tp.sent_at = nil
                    end
                end
            elseif tp.settle >= cfg.phase2.teleport_settle and pl and util.dist(target, pl) <= cfg.phase2.teleport_tolerance then
                tp.sent_at = tp.settle - 1.0
            elseif tp.settle >= cfg.phase2.teleport_settle then
                local rot
                pcall(function() rot = p:K2_GetActorRotation() end)
                if rot and tp.goal == "home" then rot = { Pitch = 0, Yaw = tp.home.yaw, Roll = 0 } end
                pcall(function() p:K2_TeleportTo(target, rot) end)
                tp.tries = tp.tries + 1
                tp.sent_at = tp.settle
                log.info(string.format("session: teleport #%d %s (%.0f, %.0f, %.0f)", tp.tries, what, target.X, target.Y, target.Z))
            end
        end
    end

    if home_check and not saving() then
        home_check.t = home_check.t + dt
        if home_check.t >= 2.0 then
            local have = carried()
            if carry.leave and carry.leave > 0 and have >= 0 and have < carry.leave then
                log.warn(string.format("session: home with %d of %d item stacks", have, carry.leave))
                notify.show(string.format("Warning: you came home with %d of your %d items. A copy of your co-op character is in "
                    .. "Backups (handbook J, CO-OP tab). Please report this with your SurrounSync log.", have, carry.leave), "bad")
            elseif have >= 0 then
                log.info(string.format("session: home with %d item stack(s) (left with %s)", have, tostring(carry.leave)))
                notify.show("Back in your own world. Your character came home with you.", "good")
            end
            carry.leave, home_check = nil, nil
        end
    end

    if inv_fix and not saving() then
        inv_fix.t = inv_fix.t + dt
        if inv_fix.t >= 1.0 and not inv_fix.done then
            inv_fix.done = true
            local n = invdiag.live_containers()
            if n == 0 then
                local ok, err = pcall(function() game.player():Event_LoadPlayer() end)
                log.info("session: inventory empty after join - Event_LoadPlayer -> " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
            else
                log.info(string.format("session: inventory present after join (%d containers)", n))
                inv_fix = nil
                local have = carried()
                if carry.join and carry.join > 0 and have >= 0 and have < carry.join then
                    log.warn(string.format("session: brought %d of %d item stacks into the co-op world", have, carry.join))
                    notify.show(string.format("Warning: you arrived with %d of your %d items. Your own save is untouched and backed up. "
                        .. "Leave to return to it.", have, carry.join), "bad")
                elseif have >= 0 then
                    log.info(string.format("session: arrived with %d item stack(s)", have))
                end
                carry.join = nil
            end
        elseif inv_fix.done and inv_fix.t >= 5.0 then
            util.safe(invdiag.snapshot, "invdiag", "after inventory reload")
            inv_fix = nil
        end
    end

    util.safe(beds_tick, "session.beds", dt)
end

local function on_actor_loaded(self)
    if not tp then return end
    local p = self:get()
    if ghost.is(p) then return end
    local target = tp_target()
    if not target then return end
    local rot = { Pitch = 0, Yaw = tp.goal == "home" and tp.home.yaw or 0, Roll = 0 }
    if tp.goal == "host" then pcall(function() rot.Yaw = p:K2_GetActorRotation().Yaw end) end
    local ok = pcall(function() p:K2_TeleportTo(target, rot) end)
    log.info(string.format("session: ActorLoaded - snapped %s to (%.0f, %.0f, %.0f): %s",
        tp.goal == "host" and "next to the host" or "back home", target.X, target.Y, target.Z, tostring(ok)))
end

local firewall_on = false
local function install_firewall()
    if firewall_on then return end
    firewall_on = true
    game.on_new_player(function() util.safe(on_world_ready, "session.world_ready") end)
    -- (the game instance class isn't loaded yet when the mod starts: hooked once it is, and again after loads)
    local hook_in = 0.0
    local on_load = function() on_any_load() end
    game.on_tick(function(dt)
        hook_in = hook_in - (dt or 0)
        if hook_in <= 0 then
            hook_in = 2.0
            util.ensure_hook("/Game/Blueprints/SD_GameInstance.SD_GameInstance_C:Event_LoadLevel", on_load)
        end
        util.safe(firewall_tick, "session.firewall_tick")
    end)
    if game.player() then on_world_ready() end
end

function session.preinit(c)
    cfg, role = c, "guest"
    preinit_done = true
    install_firewall()
    session.startup_restore()
    purge_all_coop_slots()
    game.player_hook("ActorLoaded", function(self) util.safe(on_actor_loaded, "session.actor_loaded", self) end)
    game.on_tick(function(dt)
        if not started then util.safe(function() flush_notes(); guest_tick(dt) end, "session.recover") end
    end)
end

function session.init(c, r, connected)
    cfg, role = c, r
    started = true
    install_firewall()
    peer_connected = connected or peer_connected
    configure_store()
    if role == "guest" then
        if not preinit_done then
            session.startup_restore()
            purge_all_coop_slots()
            game.player_hook("ActorLoaded", function(self) util.safe(on_actor_loaded, "session.actor_loaded", self) end)
        end
        game.keybind("F10", { ModifierKey.CONTROL }, function()
            if state == "idle" then key_join_refused = true else want_toggle = true end
        end)
        game.on_new_player(function() util.safe(check_exit, "session.check_exit") end)
        util.hook("/Game/Blueprints/SD_GameInstance.SD_GameInstance_C:Event_LoadLevel",
            function() util.safe(session.on_load_level, "session.on_load_level") end)
        log.info("session: guest - Ctrl+F10 leaves the host's world (join from the handbook's CO-OP tab)")
    end
end

local cp_clock, cp_due, cp_last, cp_first = 0.0, nil, -math.huge, nil
local guest_in = function() return false end
function session.set_guest_in(fn) guest_in = fn end
function session.guest_in_world() return role == "host" and guest_in() end
-- Any save (the game's autosave, a manual one, ours) covers the trades made before it.
function session.on_any_save() cp_due, cp_last = nil, cp_clock end
function session.checkpoint(reason)
    if not (cfg and cfg.save and cfg.save.checkpoints ~= false) then return end
    if role == "host" and not guest_in() then return end
    local delay = cfg.save.checkpoint_delay or 10.0
    cp_first = cp_due and cp_first or cp_clock
    cp_due = math.min(cp_clock + delay, cp_first + delay + 30.0)
    log.debug("session: checkpoint due (" .. tostring(reason) .. ")")
end

local function checkpoint_tick(dt)
    cp_clock = cp_clock + dt
    if not cp_due or cp_clock < cp_due then return end
    if cfg.save and cfg.save.checkpoints == false then cp_due = nil; return end
    if cp_clock < cp_last + (cfg.save.checkpoint_min_interval or 90.0) then return end
    if role == "guest" then
        if state == "idle" then cp_due = nil; return end
        if state ~= "joined" or tp then return end
    end
    local dead = false
    pcall(function() dead = game.player()["PlayerDead?"] == true end)
    if dead or saving() then return end
    cp_due, cp_last = nil, cp_clock
    log.info("session: checkpoint save (items changed hands)")
    save_now()
end

function session.tick(dt)
    if state == "idle" then util.safe(track_ground, "session.ground", dt) end
    flush_notes()
    checkpoint_tick(dt)
    if role == "host" then host_tick(dt) else guest_tick(dt) end
end

function session.state() return state end
function session.save_now() return save_now() end
function session.playing_slot()
    local cur = ems_current_name()
    if not cur or cur == "" or is_coop(cur) then return nil end
    return cur
end
function session.role() return started and role or nil end
function session.request_toggle() want_toggle = true end
function session.in_world() return state == "joined" and tp == nil end

-- "arriving": loaded into the host's world and already next to the host, but the spot isn't confirmed yet
-- (the game can still move the player for a few seconds). Enough to show both players to each other.
local function arrived_spot()
    if not (tp and tp.goal == "host") or saving() then return false end
    local p, target = game.player(), tp_target()
    if not (util.valid(p) and target and util.same(p, tp.player)) then return false end
    local pl
    pcall(function() pl = util.vec(p:K2_GetActorLocation()) end)
    return pl ~= nil and util.dist(target, pl) <= cfg.phase2.teleport_tolerance
end
function session.where()
    if role ~= "guest" then return "host" end
    if state == "joined" then
        if not tp then return "joined" end
        return arrived_spot() and "arriving" or "loading"
    end
    if state == "leaving_save" or (tp and tp.goal == "home") then return "leaving" end
    return "own"
end

return session
