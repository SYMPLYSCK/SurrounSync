-- Runs before every save: removes the ghost so it never ends up in a save file, and lets the
-- session check the save goes to the right slot.

local log = require("mirror.log")
local util = require("mirror.util")
local ghost = require("mirror.ghost")
local crumb = require("mirror.crumb")

local save_guard = {}

local cfg
local pending = false
local since = 0.0
local on_respawn
local saved_pose = nil
local seen_own = {}

local SAVE_ENTRIES = {
    "/Game/Blueprints/BP_PlayerController.BP_PlayerController_C:SaveGameToSlot",
    "/Game/Blueprints/BP_SurroundeadGameMode.BP_SurroundeadGameMode_C:EventSave",
    "/Game/Blueprints/BP_SurroundeadGameMode.BP_SurroundeadGameMode_C:AutoSaveGame",
    "/Game/Blueprints/BP_SurroundeadGameMode.BP_SurroundeadGameMode_C:Event_AutoSave",
}
local EMS = "/Script/EasyMultiSave.Default__EMSFunctionLibrary"

function save_guard.configure(c, respawn_fn) cfg = c; on_respawn = respawn_fn end
local before_save = nil
function save_guard.set_before_save(fn) before_save = fn end
function save_guard.run_before_save() if before_save then before_save() end end

function save_guard.busy() return pending end

-- A player body nobody controls (left by a load) was saved with the world and came back on every load of
-- it (2026-10-25: two extra guests, one in the void). Removed before the save, it never reaches a file.
local stray_at = -100
local function drop_stray_bodies()
    -- one look per save (a save runs through several of the hooked entries in the same moment)
    if os.clock() - stray_at < 2.0 then return end
    stray_at = os.clock()
    local me = require("mirror.game").player()
    if not util.valid(me) then return end
    local peers, n = require("mirror.peers"), 0
    for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        local full, ctrl
        local going = true
        pcall(function() full = p:GetFullName(); ctrl = p.Controller; going = p:IsActorBeingDestroyed() end)
        if full and not going and not full:find("Default__", 1, true) and not util.same(p, me) and not util.valid(ctrl)
                and not peers.is_ghost(p) and pcall(function() p:K2_DestroyActor() end) then
            n = n + 1
        end
    end
    if n > 0 then log.info("save: removed " .. n .. " stray player body(ies) so the save doesn't keep them") end
end

local function on_save_start(path)
    log.info("save starting (" .. path:match(":(.+)$") .. ")")
    -- (a guest froze/crashed inside this hook once with no dump: the steps say which part next time)
    crumb.at("save: stray bodies")
    util.safe(drop_stray_bodies, "save_guard.stray")
    crumb.at("save: before_save")
    if before_save then before_save() end
    if not cfg.save.destroy_ghost_on_save then
        if ghost.exists() then log.warn("save with ghost present (destroy_ghost_on_save=false): testing bSkipSave alone") end
        return
    end
    if ghost.exists() then
        crumb.at("save: ghost pose")
        local yaw = 0
        pcall(function() yaw = ghost.get():K2_GetActorRotation().Yaw end)
        saved_pose = { loc = ghost.location(), yaw = yaw }
        crumb.at("save: ghost destroy")
        ghost.destroy("save")
        pending, since = true, 0.0
    end
end

local NATIVE_WORLD = "/Script/EasyMultiSave.EMSAsyncSaveGame:AsyncSaveActors"
local NATIVE_CUSTOM = {
    "/Script/EasyMultiSave.EMSFunctionLibrary:SaveCustom",
    "/Script/EasyMultiSave.EMSFunctionLibrary:SavePlayerActorsCustom",
    "/Script/EasyMultiSave.EMSFunctionLibrary:SaveRawObject",
}

function save_guard.install()
    for _, path in ipairs(SAVE_ENTRIES) do
        util.hook(path, function() util.safe(on_save_start, "save_guard", path) end)
    end
    util.hook(NATIVE_WORLD, function() util.safe(on_save_start, "save_guard", NATIVE_WORLD) end)
    for _, path in ipairs(NATIVE_CUSTOM) do
        util.hook(path, function() save_guard.run_before_save() end)
    end
    local P = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"
    for _, fn in ipairs({ "ActorPreSave", "ActorLoaded" }) do
        util.hook(P .. fn, function(self)
            util.safe(function()
                if ghost.is(self:get()) then
                    log.error("GHOST " .. fn .. " RAN - the ghost is being saved/loaded; check Player.sav!")
                elseif not seen_own[fn] then
                    seen_own[fn] = true
                    log.info("save_guard: " .. fn .. " ran for my own player")
                end
            end, "save_guard." .. fn)
        end)
    end
end

local function saving(world)
    local busy = false
    pcall(function() busy = util.cdo(EMS):IsSavingOrLoading(world) end)
    return busy
end

-- The ghost comes back once the save system has been idle for a moment (a save runs in two parts).
local idle = 0.0
function save_guard.tick(dt, world)
    if not pending then idle = 0.0; return end
    since = since + dt
    if saving(world) then idle = 0.0; return end
    idle = idle + dt
    if since < cfg.save.respawn_delay or idle < 0.3 then return end
    pending = false
    log.info("save finished; respawning ghost where it stood")
    if on_respawn then on_respawn(saved_pose) end
    saved_pose = nil
end

return save_guard
