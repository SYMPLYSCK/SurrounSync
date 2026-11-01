-- A world's difficulty as the game runs it: the Difficulty.* and Loot.* console variables. AutoSettings keeps every
-- one in Saved\Config\Windows\UserSettings.ini under its real name (the save file's names differ: XpMultiplier is
-- Difficulty.XPMultiplier, GeneralLoot is Loot.General), and a save writes them into the world's Difficulties.sav
-- (Realms experiment E9). A Realm takes its creator's: read here while they are in their own save, set in the new world.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local localdir = require("mirror.localdir")
local fs = require("mirror.fs")

local difficulty = {}

local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local GROUPS = { "Difficulty", "Loot" }
local MINE = "mirror_my_difficulty.txt"

local ini_path = function() return localdir.get() .. "\\Saved\\Config\\Windows\\UserSettings.ini" end

-- { { name = "Difficulty.ZombieAmount", bool = false }, ... } from the game's settings file (nil: not readable)
function difficulty.names(text)
    text = text or fs.read(ini_path())
    if not text then return nil end
    local out, seen = {}, {}
    for line in text:gmatch("[^\r\n]+") do
        local name, v = line:match("^%s*([%w_]+%.[^=%s]+)%s*=%s*(%S*)")
        local group = name and name:match("^([%w_]+)%.")
        for _, g in ipairs(GROUPS) do
            if group == g and not seen[name] then
                seen[name] = true
                out[#out + 1] = { name = name, bool = (v == "true" or v == "false") }
            end
        end
    end
    return #out > 0 and out or nil
end

-- what this game runs now: { [name] = "1" / "0" / number text }
function difficulty.snapshot(names)
    names = names or difficulty.names()
    local k = util.cdo(KSL)
    if not (names and k) then return nil end
    local snap, n = {}, 0
    for _, e in ipairs(names) do
        local v
        if e.bool then
            pcall(function() local b = k:GetConsoleVariableBoolValue(e.name); if b ~= nil then v = b and "1" or "0" end end)
        else
            pcall(function() local f = tonumber(k:GetConsoleVariableFloatValue(e.name)); if f then v = string.format("%.6g", f) end end)
        end
        if v then snap[e.name], n = v, n + 1 end
    end
    return n > 0 and snap or nil
end

-- set them in this game (the next save puts them into the world's Difficulties.sav); returns how many
function difficulty.apply(snap)
    local k, w = util.cdo(KSL), game.world()
    if not (snap and k and w) then return 0 end
    local n = 0
    for name, v in pairs(snap) do
        if name:match("^[%w_]+%.[%w_&]+$") and v:match("^%-?[%d.e+-]+$") then
            if pcall(function() k:ExecuteConsoleCommand(w, name .. " " .. v, nil) end) then n = n + 1 end
        end
    end
    return n
end

function difficulty.encode(snap)
    local out = {}
    for name, v in pairs(snap or {}) do out[#out + 1] = name .. "=" .. v end
    table.sort(out)
    return table.concat(out, "\n") .. "\n"
end
function difficulty.decode(text)
    local snap, n = {}, 0
    for name, v in (text or ""):gmatch("([%w_]+%.[%w_&]+)=([^\r\n]+)") do snap[name], n = v, n + 1 end
    return n > 0 and snap or nil
end

-- same value: numbers to a few digits (the game keeps floats, the text has 6)
local function same_value(a, b)
    if a == b then return true end
    local x, y = tonumber(a), tonumber(b)
    return x ~= nil and y ~= nil and math.abs(x - y) <= 1e-4 * math.max(1, math.abs(y))
end
-- the settings of `want` that `cur` doesn't run (a setting `cur` lacks counts as differing)
function difficulty.differing(cur, want)
    local out, n = {}, 0
    for name, v in pairs(want or {}) do
        if not same_value((cur or {})[name], v) then out[name], n = v, n + 1 end
    end
    return out, n
end
function difficulty.same(cur, want) local _, n = difficulty.differing(cur, want); return want ~= nil and n == 0 end

-- A restore owed to the player's own save: written when a co-op join leaves it (worldset.lua), so the own
-- values come back in that save after the trip, a crash or a main-menu exit. "loads" is what the join's load
-- showed: "yes" = a world load sets these from its Difficulties.sav, "no" = it doesn't, "?" = not seen.
local PENDING = "mirror_difficulty_restore.txt"
local pending, pending_read = nil, false
local function pending_path() return localdir.get() .. "\\" .. PENDING end
function difficulty.pending()
    if not pending_read then
        pending_read = true
        local text = fs.read(pending_path())
        local slot = text and text:match("^slot ([^\r\n]+)")
        pending = slot and { slot = slot, loads = text:match("\nloads (%S+)") or "?" } or nil
    end
    return pending
end
function difficulty.set_pending(slot, loads)
    local ok = fs.write(pending_path(), "slot " .. tostring(slot) .. "\nloads " .. (loads or "?") .. "\n")
    -- (kept in memory even when the file couldn't be written: this run still restores)
    pending, pending_read = { slot = tostring(slot), loads = loads or "?" }, true
    return ok
end
function difficulty.clear_pending()
    pending, pending_read = nil, true
    os.remove(pending_path())
end

-- The player's own difficulty, kept from the last time they were in one of their own saves (for a Realm's owner
-- to give an existing Realm theirs; in the Realm the game runs the Realm's). Never while a restore is owed: the
-- game may still run the host's values then.
local function mine_path() return localdir.get() .. "\\" .. MINE end
function difficulty.remember_mine(save_name, snap)
    if difficulty.pending() then return false end
    snap = snap or difficulty.snapshot()
    if not snap then return false end
    local ok = fs.write(mine_path(), "# " .. tostring(save_name) .. "\n" .. difficulty.encode(snap))
    if ok then log.info("difficulty: remembered your own difficulty (" .. tostring(save_name) .. ")") end
    return ok
end
function difficulty.mine()
    local text = fs.read(mine_path())
    return difficulty.decode(text), text and text:match("^# ([^\r\n]+)")
end

return difficulty
