-- Every hotkey as a chat command too (user 2026-11-04: "all the Hotkeys we have for stuff can also be / commands in
-- chat"). A command runs what its key runs, so the same checks hold: the owner's stay the owner's, and the keys of a
-- thing that isn't here (a bike nobody flies) answer the same way. chat.lua sends every "/" line here; the teleport
-- commands stay in teleport.lua. Left out: F2 (renames the item under the mouse, and no chat box opens over the
-- inventory), the game's own keys, Enter and Esc in the menus.
-- FPVDrone and SyncFX are other Lua states: a command goes over their UE4SS shared variable <mod>.cmd, which they read
-- from their tick and clear. <mod>.commands is set when such a mod is loaded and listening.

local log = require("mirror.log")
local util = require("mirror.util")
local notify = require("mirror.notify")

local chatcmd = {}

local function m(name) return require("mirror." .. name) end
local function say(text, kind) notify.show(text, kind or "info") end

local function is_owner()
    local ok, yes = pcall(function() return m("adminfly").is_owner() end)
    return ok and yes == true
end

local function in_session()
    local ok, role = pcall(function() return m("phase1").started() end)
    return ok and role ~= nil
end

local function shared(k)
    local ok, v = pcall(function() return ModRef:GetSharedVariable(k) end)
    if ok then return v end
    return nil
end

local function riding()
    local ok, yes = pcall(function() return m("hoverbike").riding() end)
    return ok and yes == true
end

-- what's asked of another mod: the words after the command, in the order the tip lists them
local DRONE = {
    { "menu", "settings menu", "Ctrl+Shift+M" }, { "fly", "fly it", "Ctrl+Shift+D" }, { "follow", "follow you", "Ctrl+Shift+O" },
    { "upright", "set it upright", "Ctrl+Shift+F" }, { "reset", "back on you", "Ctrl+Shift+X" }, { "bindings", "bindings window", "Ctrl+Shift+B" },
    { "radio", "show the radio", "Ctrl+Shift+R" }, { "charge", "charge it", "G" }, { "pickup", "pick it up", "H" },
}
local SYNCFX = {
    { "toggle", "on or off", "F8" }, { "menu", "its menu", "F6" }, { "quality", "next quality", "Shift+F8" },
    { "night", "skip to night", "Alt+F8" }, { "wrecks", "test wrecks", "Ctrl+F8" }, { "bench", "benchmark", "Ctrl+F9" },
}

local function words_of(list)
    local t = {}
    for _, w in ipairs(list) do t[#t + 1] = w[1] end
    return table.concat(t, ", ")
end

local function mail(mod, list, arg)
    arg = arg:lower()
    local found = false
    for _, w in ipairs(list) do if w[1] == arg then found = true end end
    local cmd = "/" .. mod:lower()
    if not found then say(cmd .. " " .. words_of(list), "warn"); return end
    if not shared(mod .. ".commands") then say(mod .. " isn't running.", "warn"); return end
    pcall(function() ModRef:SetSharedVariable(mod .. ".cmd", arg) end)
end

local function bike_only(fn)
    return function(arg)
        if not riding() then say("Only while you fly the hover bike.", "warn"); return end
        fn(arg)
    end
end

-- group: its line in the "/" list. show: nil = everyone. Someone it isn't shown to gets "isn't a command".
local COMMANDS = {
    { name = "messages", also = { "message", "msgs" }, group = "Players", key = "Ctrl+F9", what = "notification history",
      run = function() notify.open_history() end },
    { name = "host", group = "Co-op", key = "Ctrl+H", what = "host a game", run = function() m("menu").key_host() end },
    { name = "join", args = "<1-3>", group = "Co-op", key = "Ctrl+1-3", what = "join hosting friend 1, 2 or 3",
      run = function(arg)
          local i = math.tointeger(tonumber(arg))
          if i ~= 1 and i ~= 2 and i ~= 3 then say("/join 1, /join 2 or /join 3: which hosting friend.", "warn"); return end
          m("menu").key_join(i)
      end },
    { name = "leave", group = "Co-op", key = "Ctrl+F10", what = "leave the host's world",
      run = function()
          local key = m("session").key_leave
          if key then key() else say("You aren't in someone else's world.", "warn") end
      end },
    { name = "status", group = "Co-op", key = "Ctrl+F12", what = "write the connection status to the log",
      run = function()
          if not in_session() then say("No co-op session is running.", "warn"); return end
          m("zombies").key_status()
          say("Connection status written to the log.")
      end },
    { name = "inventory", group = "Co-op", key = "Ctrl+F11", what = "write an inventory report to the log",
      run = function() m("invdiag").key_report(); say("Inventory report written to the log.") end },
    { name = "minimap", group = "World", key = "M twice", what = "minimap on or off",
      run = function() local mini = m("minimap"); mini.set(not mini.on()) end },
    { name = "giant", group = "World", key = "Ctrl+G", what = "the forest giant guards this spot",
      run = function() m("giant").place_here() end },
    { name = "bikeview", group = "Bike", show = riding, key = "G", what = "the bike's other camera",
      run = bike_only(function() m("hoverbike").key_view() end) },
    { name = "bikeseat", args = "<up|down>", group = "Bike", show = riding, key = "U / I", what = "the rider's height",
      run = bike_only(function(arg)
          arg = arg:lower()
          if arg ~= "up" and arg ~= "down" then say("/bikeseat up or /bikeseat down", "warn"); return end
          m("hoverbike").key_tune(arg == "up" and 1 or -1)
      end) },
    { name = "fly", group = "Owner", show = is_owner, key = "F7", what = "admin fly on or off",
      run = function() m("adminfly").key_toggle() end },
    { name = "bike", group = "Owner", show = is_owner, key = "Ctrl+Shift+V", what = "make the hover bike or bring it",
      run = function() m("hoverbike").key_make() end },
    { name = "bikelock", group = "Owner", show = is_owner, key = "Ctrl+Shift+P", what = "lock or unlock the bike for everyone",
      run = function() m("hoverbike").key_lock() end },
    { name = "lock", group = "Owner", show = is_owner, what = "only you can ride your hover bike",
      run = function() m("hoverbike").set_open(false) end },
    { name = "unlock", group = "Owner", show = is_owner, what = "anyone can ride your hover bike",
      run = function() m("hoverbike").set_open(true) end },
    { name = "fpv", args = "<lock|unlock|list>", group = "Owner", show = is_owner, what = "who flies the FPV drone: nobody but you, everyone, or your PERMISSIONS list",
      run = function(arg)
          arg = arg:lower()
          local g = m("dronegrant")
          if arg == "lock" then g.set_mode("locked")
          elseif arg == "unlock" then g.set_mode("open")
          elseif arg == "list" then g.set_mode(nil)
          else say("/fpv lock, /fpv unlock or /fpv list", "warn") end
      end },
    { name = "drone", args = "<what>", group = "FPVDrone", words = DRONE, show = function() return shared("FPVDrone.commands") ~= nil end,
      what = "the FPV drone", run = function(arg) mail("FPVDrone", DRONE, arg) end },
    { name = "syncfx", args = "<what>", group = "SyncFX", words = SYNCFX, show = function() return shared("SyncFX.commands") ~= nil end,
      what = "the graphics mod", run = function(arg) mail("SyncFX", SYNCFX, arg) end },
}
local GROUPS = { "Players", "Co-op", "World", "Bike", "Owner", "FPVDrone", "SyncFX" }
local MAX_TIP_LINES = 6

local function shown(c) return c.show == nil or c.show() end

local function names_of(c)
    local t = { c.name }
    for _, a in ipairs(c.also or {}) do t[#t + 1] = a end
    return t
end

local function tip_line(c)
    local s = "/" .. c.name .. (c.args and (" " .. c.args) or "") .. " - " .. c.what
    if c.key then s = s .. " (" .. c.key .. ")" end
    return s
end

local function teleport_known(word)
    local t = m("teleport")
    return t.known ~= nil and t.known(word)
end

-- \lock and \\FPV Unlock are /lock and /fpv unlock
function chatcmd.is_command(text) return tostring(text or ""):match("^%s*[/\\]") ~= nil end
local function normal(text) return (tostring(text or ""):gsub("^%s*[/\\]+", "/", 1)) end

local function full_list()
    local lines = {}
    for _, g in ipairs(GROUPS) do
        local names = {}
        if g == "Players" then names = { "/goto", "/bring", "/accept", "/deny" } end
        for _, c in ipairs(COMMANDS) do
            if c.group == g and shown(c) then
                if c.words then names[#names + 1] = "/" .. c.name .. " " .. words_of(c.words)
                else names[#names + 1] = "/" .. c.name end
            end
        end
        if #names > 0 then lines[#lines + 1] = g .. ": " .. table.concat(names, " ") end
    end
    return table.concat(lines, "\n")
end

-- The tip for what's typed so far, nil when it isn't a command. one_line: for the handbook's chat, which has one line
-- for it; the quick chat's box grows.
function chatcmd.tip(text, one_line)
    text = normal(text)
    local word = text:match("^/(%S*)")
    if not word then return nil end
    word = word:lower()
    if word == "" then
        if one_line then return "Commands: /goto /bring /accept /deny /messages /host /join /leave - press / in the world for all" end
        return full_list()
    end
    local past = text:find("%s") ~= nil   -- (past the command word: only an exact name counts)
    local found = {}
    for _, c in ipairs(COMMANDS) do
        if shown(c) then
            for _, n in ipairs(names_of(c)) do
                if (past and n == word) or (not past and n:sub(1, #word) == word) then found[#found + 1] = c; break end
            end
        end
    end
    -- "/drone f": the words that fit
    if past and found[1] and found[1].words then
        local part = (text:match("^/%S+%s+(.-)%s*$") or ""):lower()
        local fit = {}
        for _, w in ipairs(found[1].words) do
            if w[1]:sub(1, #part) == part then fit[#fit + 1] = "/" .. word .. " " .. w[1] .. " - " .. w[2] .. " (" .. w[3] .. ")" end
        end
        if #fit == 0 then return "/" .. word .. " " .. words_of(found[1].words) end
        if one_line then return fit[1] end
        return table.concat(fit, "\n", 1, math.min(#fit, #found[1].words))
    end
    local lines = {}
    local tp = m("teleport").tip(text)
    if tp and not tp:find("isn't a command", 1, true) then lines[1] = tp end
    for _, c in ipairs(found) do
        if #lines < MAX_TIP_LINES then lines[#lines + 1] = tip_line(c) end
    end
    if #lines == 0 then return "/" .. word:sub(1, 12) .. " isn't a command. Clear it back to / for the list." end
    if one_line then return lines[1] end
    return table.concat(lines, "\n")
end

-- a chat line starting with "/"
function chatcmd.run(text)
    text = normal(text)
    local word, arg = text:match("^/(%S*)%s*(.-)%s*$")
    word = (word or ""):lower()
    for _, c in ipairs(COMMANDS) do
        if shown(c) then
            for _, n in ipairs(names_of(c)) do
                if n == word then
                    log.info("chat command: /" .. c.name .. (c.words and (" " .. arg:sub(1, 12)) or ""))
                    util.safe(c.run, "chatcmd." .. c.name, arg or "")
                    return true
                end
            end
        end
    end
    if teleport_known(word) then return m("teleport").command(text) end
    say(word == "" and "Type a command after the /. Its list shows while you type."
        or ("/" .. word:sub(1, 12) .. " isn't a command. Type / to see them."), "warn")
    return true
end

return chatcmd
