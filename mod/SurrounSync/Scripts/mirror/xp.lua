-- Kill XP goes to the player who made the kill.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")

local xp = {}

local LC = "/Game/Blueprints/Components/LevellingComponent.LevellingComponent_C"
local GFL_CDO = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"

local hold = 0
local last_held = nil

local function levelling()
    local lc
    pcall(function() lc = game.controller().LevellingComponent end)
    return lc
end

local MULTS = { "MultiplyValue", "Difficulty_MultiplierValue" }
local COUNTERS = { "ZombieKills", "HumanKills", "AnimalKills" }
local held = nil

function xp.without(fn)
    local pc = game.controller()
    local counts = {}
    for _, f in ipairs(COUNTERS) do pcall(function() counts[f] = pc[f] end) end
    local lc = levelling()
    local saved = {}
    if lc and not held then
        for _, f in ipairs(MULTS) do
            pcall(function() saved[f] = lc[f]; lc[f] = 0.0 end)
        end
    end
    last_held = nil
    hold = hold + 1
    local ok, err = pcall(fn)
    hold = hold - 1
    if lc then for f, v in pairs(saved) do pcall(function() lc[f] = v end) end end
    for f, n in pairs(counts) do pcall(function() if pc[f] ~= n then pc[f] = n end end) end
    if last_held then
        log.info(string.format("xp: %.1f XP not paid - not my kill", last_held))
    end
    return ok, err
end

function xp.amount_for(z)
    local amount
    pcall(function() amount = StaticFindObject(GFL_CDO):XpMultiplierCalc(4.0, 8.0, z) end)
    return type(amount) == "number" and amount or nil
end

function xp.reward_kill(z, amount)
    if type(amount) ~= "number" or amount <= 0 then amount = nil end
    amount = amount or xp.amount_for(z) or 6.0
    local ok = pcall(function()
        local pc = game.controller()
        pc.ZombieKills = (pc.ZombieKills or 0) + 1
        pc.LevellingComponent:AddXP(amount, false, {})
    end)
    log.info(string.format("xp: my kill - %.1f XP %s", amount, ok and "given" or "FAILED"))
end

-- Animal and human deaths call AddXP and then always show a "+N XP" notification, even with
-- the multipliers held at 0: hide the one that follows a held AddXP.
local hide_next = false

local function on_add_xp(_, amount)
    if held and hold <= 0 then hide_next = true end
    if hold <= 0 then return end
    local was
    pcall(function() was = amount:get() end)
    if type(was) == "number" then last_held = (last_held or 0) + was end
end

local PANEL = "/Game/UI/Widgets/Notification/NotificationParentWidget.NotificationParentWidget_C"
local function on_notification()
    if hold <= 0 and not hide_next then return end
    hide_next = false
    pcall(function()
        for _, n in ipairs(FindAllOf("NotficationUI_C") or {}) do
            local box = n:GetParent()
            if util.valid(box) then
                local last = box:GetChildAt(box:GetChildrenCount() - 1)
                if util.valid(last) then last:SetVisibility(1) end
                return
            end
        end
    end)
end

function xp.hold_for(seconds)
    local t = os.clock() + seconds
    if held then if t > held["until"] then held["until"] = t end; return end
    held = { ["until"] = t, mults = {}, counts = {} }
    local lc, pc = levelling(), game.controller()
    if lc then for _, f in ipairs(MULTS) do pcall(function() held.mults[f] = lc[f]; lc[f] = 0.0 end) end end
    for _, f in ipairs(COUNTERS) do pcall(function() held.counts[f] = pc[f] end) end
end
local function release_hold()
    if not held or os.clock() < held["until"] then return end
    local lc, pc = levelling(), game.controller()
    if lc then for f, v in pairs(held.mults) do pcall(function() lc[f] = v end) end end
    for f, n in pairs(held.counts) do pcall(function() if pc[f] ~= n then pc[f] = n end end) end
    held = nil
    hide_next = false
end

function xp.tick()
    util.safe(release_hold, "xp.release_hold")
    util.ensure_hook(LC .. ":AddXP", on_add_xp)
    util.ensure_hook(PANEL .. ":Notification", on_notification)
end

return xp
