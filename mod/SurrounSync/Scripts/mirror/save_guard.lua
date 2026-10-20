-- Runs before every save: removes the ghost so it never ends up in a save file, and lets the
-- session check the save goes to the right slot.

local log = require("mirror.log")
local util = require("mirror.util")
local ghost = require("mirror.ghost")

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

local function on_save_start(path)
    log.info("save starting (" .. path:match(":(.+)$") .. ")")
    if before_save then before_save() end
    if not cfg.save.destroy_ghost_on_save then
        if ghost.exists() then log.warn("save with ghost present (destroy_ghost_on_save=false): testing bSkipSave alone") end
        return
    end
    if ghost.exists() then
        local yaw = 0
        pcall(function() yaw = ghost.get():K2_GetActorRotation().Yaw end)
        saved_pose = { loc = ghost.location(), yaw = yaw }
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
