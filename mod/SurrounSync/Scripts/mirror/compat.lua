-- Compares the two players' UE4SS mods and warns about ones that change gameplay.

local log = require("mirror.log")
local link = require("mirror.link")
local notify = require("mirror.notify")
local fs = require("mirror.fs")
local util = require("mirror.util")
local game = require("mirror.game")
local jig = require("mirror.jig")

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
local probe_addr, probe_at, probe_warned = nil, nil, false
local JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigComponent.BP_JigComponent_C"

-- once per player, 10 s in (the inventory is filled by then): does this game build still have what item sync uses?
local function probe_game()
    local player = game.player()
    local addr = util.valid(player) and util.addr(player) or nil
    if not addr or addr == probe_addr then return end
    probe_at = probe_at or (os.clock() + 10)
    if os.clock() < probe_at then return end
    probe_addr, probe_at = addr, nil
    local cls, comp = util.find(JIG), nil
    if cls then pcall(function() comp = player:GetComponentByClass(cls) end) end
    if not util.valid(comp) then log.error("compat: the player has no inventory component - a game update changed it"); return end
    local missing = jig.probe(comp)
    if #missing == 0 then log.info("compat: inventory layout check passed"); return end
    log.error("compat: this game build lacks what item sync uses: " .. table.concat(missing, ", ")
        .. " - loot, drops and trades can fail until SurrounSync is updated for it")
    if not probe_warned then
        probe_warned = true
        notify.show("A SurrounDead update changed the inventory. Item sync may not work until SurrounSync is updated.", "bad")
    end
end

local function read_mods()
    -- what runs in this game (mods.txt, enabled.txt and paks, as the game started): modlist.lua
    local ok, ids = pcall(function() return require("mirror.modlist").loaded_ids() end)
    if ok and type(ids) == "table" and next(ids) then return ids end
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

local peer_set = nil
-- the other side's running mods (on a guest: the host's), for the MODS tab
function compat.peer_mods() return peer_set end
function compat.kind(name) return kind(name) end

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
            .. "differences. Open J -> MODS to match them.", table.concat(names, ", "), #warn > 3 and (" +" .. (#warn - 3)) or "",
            #warn == 1 and "s" or "", who), "bad")
    end
end

function compat.tick()
    probe_game()
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
        peer_set = theirs
        compare(theirs)
    end
end

function compat.reset() sent, compared, peer_set = false, nil, nil end

return compat
