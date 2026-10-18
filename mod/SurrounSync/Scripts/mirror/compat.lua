-- Compares the two players' UE4SS mods and warns about ones that change gameplay.

local log = require("mirror.log")
local link = require("mirror.link")
local notify = require("mirror.notify")
local fs = require("mirror.fs")

local compat = {}

local KNOWN = {
    SurrounSync = "self",
    MirrorCoop = "self",
    BPModLoaderMod = "client", BPML_GenericFunctions = "client", Keybinds = "client",
    ConsoleCommandsMod = "client", ConsoleEnablerMod = "client", CheatManagerEnablerMod = "client",
    SuppressorHeatGlow = "client", LineTraceMod = "client", AutoContinue = "client",
    PDS = "gameplay", SDTrainer = "gameplay", WeaponProgression = "gameplay", HeadshotBrains = "gameplay",
    UniversalCraftingNetwork = "gameplay", SplitScreenMod = "gameplay",
    SurrounDeadMP = "gameplay", SurrounDeadMPInput = "gameplay",
}

local mine = nil
local sent, compared = false, nil

local function read_mods()
    local out = {}
    local f = io.open("ue4ss\\Mods\\mods.txt", "r")
    if f then
        for line in f:lines() do
            local name, on = line:match("^%s*([%w_%-]+)%s*:%s*(%d)")
            if name and on == "1" then out[name] = true end
        end
        f:close()
    end
    for _, dir in ipairs({ "..\\..\\Content\\Paks\\~mods", "..\\..\\Content\\Paks\\LogicMods" }) do
        for _, file in ipairs(fs.list_files(dir) or {}) do
            if file:lower():match("%.pak$") then out["pak:" .. file] = true end
        end
    end
    return out
end

local function kind(name)
    if name:sub(1, 4) == "pak:" then return "unknown" end
    return KNOWN[name] or "unknown"
end

local function compare(theirs)
    local who = link.peer_name()
    local warn = {}
    for name in pairs(theirs) do
        if not mine[name] then
            local k = kind(name)
            if k == "gameplay" or k == "unknown" then warn[#warn + 1] = { name = name, k = k, side = who } end
        end
    end
    for name in pairs(mine) do
        if not theirs[name] and kind(name) == "gameplay" then warn[#warn + 1] = { name = name, k = "gameplay", side = "you" } end
    end
    table.sort(warn, function(a, b) return a.name < b.name end)
    local lines = {}
    for _, w in ipairs(warn) do
        lines[#lines + 1] = string.format("%s (%s, only %s)", w.name:gsub("^pak:", ""), w.k, w.side == "you" and "you" or w.side)
    end
    log.info("compat: " .. (#lines > 0 and ("differences: " .. table.concat(lines, "; ")) or "no differences that matter"))
    if #warn > 0 then
        local names = {}
        for i = 1, math.min(3, #warn) do names[#names + 1] = (warn[i].name:gsub("^pak:", "")) end
        notify.show(string.format("Mod check: %s%s differ%s between you and %s - they can change shared play and cause "
            .. "differences. Details in the log.", table.concat(names, ", "), #warn > 3 and (" +" .. (#warn - 3)) or "",
            #warn == 1 and "s" or "", who), "bad")
    end
end

function compat.tick()
    if not mine then mine = read_mods() end
    if not sent then
        sent = true
        local names = {}
        for n in pairs(mine) do names[#names + 1] = n end
        table.sort(names)
        link.put_blob("mods", table.concat(names, "\n"))
    end
    local body = link.get_blob("mods")
    if body and body ~= compared then
        compared = body
        local theirs = {}
        for n in body:gmatch("[^\n]+") do theirs[n] = true end
        compare(theirs)
    end
end

function compat.reset() sent, compared = false, nil end

return compat
