-- Inventory dump to the log (Ctrl+F11), for debugging.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")

local invdiag = {}

local ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"
local INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"
local ITEM_ID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"
local PICKUP = "PickupRef_20_A3E97763428AC84AF4DBB8A56CFAC657"
local EQUIP_FLAGS = { "PrimaryWeaponEquipped?", "SecondaryWeaponEquipped?", "SidearmWeaponEquipped?", "MeleeWeaponEquipped?" }

local want = false
local cfg_diag = false
local last_player = nil
local timers = {}

local function name_of(obj)
    if not util.valid(obj) then return "nil" end
    local n; pcall(function() n = obj:GetFName():ToString() end)
    return n or "?"
end

local function len(arr)
    local n = 0
    pcall(function() n = arr:GetArrayNum() end)
    return n
end

local function summarize(containers)
    local s = { containers = 0, items = 0, picked = 0, ids = {} }
    pcall(function()
        containers:ForEach(function(_, c)
            s.containers = s.containers + 1
            local items = c:get()[ITEMS]
            items:ForEach(function(_, it)
                local item = it:get()
                s.items = s.items + 1
                if util.valid(item[PICKUP]) then s.picked = s.picked + 1 end
                if #s.ids < 12 then
                    local id = "?"
                    pcall(function() id = name_of(item[INFO][ITEM_ID]) end)
                    s.ids[#s.ids + 1] = id
                end
            end)
        end)
    end)
    return string.format("%d containers, %d items (%d with PickupRef) [%s]",
        s.containers, s.items, s.picked, table.concat(s.ids, ","))
end

local function ems_object()
    for _, o in ipairs(FindAllOf("EMSObject") or {}) do
        if util.class_name(o) == "EMSObject" then return o end
    end
    return nil
end

local function str(v)
    local s; pcall(function() s = v:ToString() end)
    if s == nil then pcall(function() s = v:get():ToString() end) end
    return s or "?"
end

local function ems_state(why)
    local ems = ems_object()
    if not ems then log.info("invdiag[" .. why .. "]: no EMSObject"); return end
    local cur = str(ems.CurrentSaveGameName)
    local slots, customs = {}, {}
    pcall(function() ems.CachedSaveSlots:ForEach(function(k, _) slots[#slots + 1] = str(k) end) end)
    pcall(function() ems.CachedCustomSaves:ForEach(function(k, v) customs[#customs + 1] = str(k) .. "=" .. name_of(v:get()) end) end)
    local info = false
    pcall(function()
        local lib = util.cdo("/Script/EasyMultiSave.Default__EMSFunctionLibrary")
        info = util.valid(lib:GetSlotInfoSaveGame(game.world()))
    end)
    log.info(string.format("invdiag[%s]: EMS current=%s slotinfo valid=%s | cached slots [%s] | cached custom [%s]",
        why, cur, tostring(info), table.concat(slots, ","), table.concat(customs, ",")))
end

function invdiag.summary(containers) return summarize(containers) end

function invdiag.live_containers()
    local n = -1
    pcall(function() n = len(game.player().BP_JigMultiplayer.MainJigContainers) end)
    return n
end

function invdiag.snapshot(why, verbose)
    ems_state(why)

    local saves = FindAllOf("Save_Player_C") or {}
    for _, s in ipairs(saves) do
        if verbose and not name_of(s):find("Default__", 1, true) then
            log.info(string.format("invdiag[%s]: save %s: %s, MainUIDs=%d",
                why, name_of(s), summarize(s.MainJigContainers), len(s.MainUIDs)))
        end
    end
    if not verbose then log.info(string.format("invdiag[%s]: %d Save_Player_C instance(s)", why, #saves)) end

    local p = game.player()
    if not util.valid(p) then log.info("invdiag[" .. why .. "]: no real player"); return end
    local jig
    pcall(function() jig = p.BP_JigMultiplayer end)
    if util.valid(jig) then
        log.info(string.format("invdiag[%s]: live %s: %s, MainContainersIDs=%d",
            why, name_of(p), summarize(jig.MainJigContainers), len(jig.MainContainersIDs)))
    else
        log.info("invdiag[" .. why .. "]: player has no BP_JigMultiplayer")
    end
    local flags = {}
    for _, f in ipairs(EQUIP_FLAGS) do
        local v; pcall(function() v = p[f] end)
        flags[#flags + 1] = f:gsub("WeaponEquipped%?", "") .. "=" .. tostring(v)
    end
    log.info(string.format("invdiag[%s]: equipped %s", why, table.concat(flags, " ")))
end

local function on_tick(dt)
    local p = game.player()
    if util.valid(p) and not util.same(p, last_player) then
        last_player = p
        if cfg_diag then timers = { 3.0, 10.0 } end
    end
    for i = #timers, 1, -1 do
        timers[i] = timers[i] - dt
        if timers[i] <= 0 then
            table.remove(timers, i)
            util.safe(invdiag.snapshot, "invdiag", "after load")
        end
    end
    if want then
        want = false
        util.safe(invdiag.snapshot, "invdiag", "key", true)
    end
end

function invdiag.init(cfg)
    cfg_diag = cfg and cfg.diagnostics or false
    game.keybind("F11", { ModifierKey.CONTROL }, function() want = true end)
    game.on_tick(on_tick)
    for _, fn in ipairs({ "LoadPlayerInventory", "Event_LoadPlayer" }) do
        game.player_hook(fn, function(self)
            log.info("invdiag: " .. fn .. " called on " .. name_of(self:get()))
        end)
    end
    game.on_ready(function()
        util.hook("/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C:LoadJigComponent",
            function(self)
                util.safe(function() log.info("invdiag: LoadJigComponent called on " .. name_of(self:get():GetOuter())) end, "invdiag.pre")
            end,
            function(self)
                util.safe(function()
                    log.info(string.format("invdiag: LoadJigComponent done -> %d containers", len(self:get().MainJigContainers)))
                end, "invdiag.post")
            end)
    end)
    log.info("invdiag: Ctrl+F11 logs the inventory (auto after each load)")
end

return invdiag
