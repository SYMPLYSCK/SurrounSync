-- Chat commands /goto <player> and /bring <player> (+ /accept, /deny). Nothing moves until the other player accepts.
-- Each game only ever moves its own player: /goto moves me next to my view of the other player (the ghost) once they
-- accept, /bring asks the other player to come - accepting runs their own goto to me (same checks) and answers.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local events = require("mirror.events")
local link = require("mirror.link")
local notify = require("mirror.notify")
local hostrules = require("mirror.hostrules")

local teleport = {}

local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local GAP = 5.0                  -- seconds between commands
local RINGS = { 150, 250, 400 }  -- cm around the other player
local STEP = 8                   -- directions per ring
local CLIMB, DROP = 150, 150     -- a spot this much above / below the other player's feet is fine
local HOLD_FOR = 10.0            -- seconds to wait for the ground to load under a held player
local MOVE_WALKING, MOVE_FLYING = 1, 5

local channel = events.new("tp", 8, 30)
local last_cmd = -100
local hold = nil
local vehicles

local function say(text, kind) notify.show(text, kind or "info"); log.info("teleport: " .. text) end

local function swimming(a)
    local s
    pcall(function() s = a.SwimmingComponent["IsSwimming?"] == true end)
    return s == true
end

local function dead(a)
    local d
    pcall(function() d = a["PlayerDead?"] == true end)
    return d == true
end

local function name_matches(arg)
    if arg == "" then return true end
    local peer = tostring(link.peer_name() or "")
    return peer:lower() == arg:lower() or peer:lower():find(arg:lower(), 1, true) == 1
end

-- Why the local player can't be moved to the other player right now (nil = fine).
local function blocked()
    local p, g = game.player(), ghost.get()
    if not util.valid(p) then return "you aren't in the world yet" end
    if not g then return "the other player isn't in your world right now" end
    if dead(p) then return "you are dead" end
    if dead(g) then return "the other player is dead" end
    vehicles = vehicles or require("mirror.vehicles")
    local busy = vehicles.busy and vehicles.busy()
    if busy then return busy end
    if swimming(p) then return "you are swimming - get out of the water first" end
    if swimming(g) then return "the other player is swimming" end
    return nil
end

local function ground_at(p, x, y, z)
    local ksl = util.cdo(KSL)
    if not ksl then return nil end
    local out, hit = {}, nil
    local ok, r = pcall(function()
        return ksl:LineTraceSingle(p, { X = x, Y = y, Z = z + CLIMB + 100 }, { X = x, Y = y, Z = z - DROP - 100 }, 0, false, {}, 0,
            out, true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
    end)
    if not (ok and r) then return nil end
    local h = out.OutHit or out
    pcall(function() hit = util.vec(h.ImpactPoint) end)
    if not hit then return nil end
    local a
    pcall(function() a = h.HitObjectHandle.Actor:Get() end)
    if not util.valid(a) then pcall(function() a = h.Actor:Get() end) end
    if util.valid(a) then
        local c = util.class_path(a) or ""
        if c:find("Vehicle", 1, true) or c:find("PlayerCharacter", 1, true) then return nil end  -- not on cars or people
    end
    if hit.Z > z + CLIMB or hit.Z < z - DROP then return nil end  -- a roof or a drop, not the other player's level
    return hit
end

local function move(p, to)
    local moved
    pcall(function() moved = p:K2_TeleportTo(to, p:K2_GetActorRotation()) end)  -- refuses spots that overlap something
    return moved == true
end

local function set_mode(p, mode)
    pcall(function()
        p.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 }
        p.CharacterMovement:SetMovementMode(mode, 0)
    end)
end

-- Move the local player next to the other player. Returns nil on success or a reason.
local function go_to_peer()
    local why = blocked()
    if why then return why end
    local p, at = game.player(), ghost.location()
    local from = util.vec(p:K2_GetActorLocation())
    if not at then return "the other player's position isn't known yet" end
    local dx, dy = at.X - from.X, at.Y - from.Y
    if dx * dx + dy * dy < 300 * 300 and math.abs(at.Z - from.Z) < 200 then return "you are already there" end
    for _, r in ipairs(RINGS) do
        for i = 0, STEP - 1 do
            local a = (i / STEP) * 2 * math.pi
            local x, y = at.X + math.cos(a) * r, at.Y + math.sin(a) * r
            local g = ground_at(p, x, y, at.Z - 90)
            if g and move(p, { X = g.X, Y = g.Y, Z = g.Z + 100 }) then
                log.info(string.format("teleport: moved to (%.0f, %.0f, %.0f), %d cm from the other player", g.X, g.Y, g.Z, r))
                return nil
            end
        end
    end
    -- No ground found: far away, the ground there may not be loaded in this game yet. Hold the player in the air
    -- beside the other player until it is, or put them back where they were.
    local spot = { X = at.X + RINGS[1], Y = at.Y, Z = at.Z + 150 }
    if not move(p, spot) then return "there's no free spot next to the other player" end
    set_mode(p, MOVE_FLYING)
    hold = { left = HOLD_FOR, back = from, at = at }
    log.info("teleport: no ground yet - holding the player until it loads")
    return nil
end

local function hold_tick(dt)
    local p = game.player()
    if not util.valid(p) then hold = nil; return end
    hold.left = hold.left - dt
    local l = util.vec(p:K2_GetActorLocation())
    local g = ground_at(p, l.X, l.Y, hold.at.Z - 90)
    if g then
        hold = nil
        move(p, { X = g.X, Y = g.Y, Z = g.Z + 100 })
        set_mode(p, MOVE_WALKING)
        log.info("teleport: the ground loaded - landed")
    elseif hold.left <= 0 then
        local back = hold.back
        hold = nil
        set_mode(p, MOVE_WALKING)
        move(p, back)
        say("Couldn't find solid ground next to the other player - you were put back.", "warn")
    end
end

local ASK_FOR = 30.0              -- seconds a request waits for an answer
local asked = nil                 -- my open request: { kind = "goto"|"bring", left = s }
local pending = nil               -- the other player's open request to me: { kind, left }

local function peer() return tostring(link.peer_name()) end

local function bring_blocked()
    local p = game.player()
    if not util.valid(p) then return "you aren't in the world yet" end
    if dead(p) then return "you are dead" end
    vehicles = vehicles or require("mirror.vehicles")
    local busy = vehicles.busy and vehicles.busy()
    if busy then return busy end
    if swimming(p) then return "you are swimming" end
    return nil
end

-- "you ..." as seen by the other player
local function theirs(why)
    return (why:gsub("^you are", "they are"):gsub("^you aren't", "they aren't"):gsub("^the other player is", "you are"))
end

-- The other player said yes: whoever moves runs its own checks now.
local function do_goto()
    local why = go_to_peer()
    if why then say("Can't teleport: " .. why .. ".", "warn"); channel:send("N " .. theirs(why))
    else say("Teleported to " .. peer() .. "."); channel:send("G") end
end

local function answer(yes)
    if not pending then say("Nobody asked to teleport."); return end
    local kind = pending.kind
    pending = nil
    if not yes then channel:send("D"); say("Turned down " .. peer() .. "'s teleport."); return end
    if kind == "goto" then
        channel:send("A")
        say(peer() .. " is coming to you.")
    else
        local why = go_to_peer()
        if why then say("Can't go to " .. peer() .. ": " .. why .. ".", "warn"); channel:send("N " .. theirs(why))
        else say("You went to " .. peer() .. "."); channel:send("Y") end
    end
end

function teleport.matches(arg) return ghost.get() ~= nil and arg ~= "" and name_matches(arg) end

-- More than two players: every other player's link has its own copy of this module. The main one hands
-- /accept and /deny to the copy with an open request, and /goto <name> to the copy whose player has that name.
local function other_copy(cmd, arg)
    if (link.tags and link.tags()) then return nil end
    local target
    require("mirror.peers").each("mirror.teleport", function(t, inst)
        if not inst or target then return end
        if cmd == "accept" or cmd == "yes" or cmd == "deny" or cmd == "decline" or cmd == "no" then
            if not pending and t.pending() then target = t end
        elseif (cmd == "goto" or cmd == "bring") and not (ghost.get() and name_matches(arg)) and t.matches(arg) then
            target = t
        end
    end)
    return target
end

-- Handles a chat line starting with "/". Returns true when it was a command (not chat).
function teleport.command(text)
    local cmd, arg = text:match("^/(%a+)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    local other = other_copy(cmd, arg or "")
    if other then return other.command(text) end
    if cmd == "accept" or cmd == "yes" then answer(true); return true end
    if cmd == "deny" or cmd == "decline" or cmd == "no" then answer(false); return true end
    if cmd ~= "goto" and cmd ~= "bring" then
        say("Commands: /goto <player>, /bring <player>, /accept, /deny")
        return true
    end
    if not hostrules.get("teleport") then say("The host turned teleports off for this world.", "warn"); return true end
    if not ghost.get() then say("The other player isn't in your world right now.", "warn"); return true end
    if not name_matches(arg or "") then
        say(string.format("No player called '%s' - the other player is %s.", arg, peer()), "warn")
        return true
    end
    local t = os.clock()
    if t - last_cmd < GAP then say("Wait a few seconds between teleports."); return true end
    if hold then say("Still waiting for the last teleport to land."); return true end
    if asked then say("Still waiting for " .. peer() .. " to answer."); return true end
    local why = cmd == "goto" and blocked() or bring_blocked()
    if why then say("Can't teleport: " .. why .. ".", "warn"); return true end
    last_cmd = t
    asked = { kind = cmd, left = ASK_FOR }
    channel:send(cmd == "goto" and "Q G" or "Q B")
    say("Asked " .. peer() .. " - waiting for them to accept...")
    return true
end

function teleport.pending()
    if pending then return { kind = pending.kind, who = peer() } end
    local other = other_copy("accept", "")
    return other and other.pending() or nil
end
function teleport.accept() local o = other_copy("accept", ""); if o then o.accept() else answer(true) end end
function teleport.decline() local o = other_copy("deny", ""); if o then o.decline() else answer(false) end end

function teleport.tick(dt)
    if hold then util.safe(hold_tick, "teleport.hold", dt) end
    if asked then
        asked.left = asked.left - dt
        if asked.left <= 0 then asked = nil; say(peer() .. " didn't answer the teleport request.") end
    end
    if pending then
        pending.left = pending.left - dt
        if pending.left <= 0 then pending = nil; channel:send("X"); say("Teleport request from " .. peer() .. " timed out.") end
    end
    channel:pump(function(msg)
        local who = peer()
        if msg == "Q G" or msg == "Q B" then
            pending = { kind = msg == "Q G" and "goto" or "bring", left = ASK_FOR }
            say(msg == "Q G" and (who .. " wants to teleport to you.") or (who .. " wants to bring you to them."))
            if not hostrules.get("teleport") then
                pending = nil
                channel:send("N teleports are turned off in this world")
            elseif require("mirror.mysettings").on("autotp") then
                answer(true)
            else
                say("Type /accept or /deny in the CO-OP chat, or answer in the handbook (J), CO-OP tab.")
            end
        elseif msg == "A" then
            if asked and asked.kind == "goto" then asked = nil; do_goto() end
        elseif msg == "D" then
            if asked then asked = nil; say(who .. " turned down the teleport.") end
        elseif msg == "X" then
            if asked then asked = nil; say(who .. " didn't answer the teleport request.") end
        elseif msg == "G" then say(who .. " teleported to you.")
        elseif msg == "Y" then asked = nil; say(who .. " is here.")
        elseif msg:sub(1, 2) == "N " then asked = nil; say("Teleport didn't work: " .. msg:sub(3) .. ".", "warn") end
    end)
end

function teleport.forget() hold, asked, pending = nil, nil, nil end
game.on_world_reset(teleport.forget)

return teleport
