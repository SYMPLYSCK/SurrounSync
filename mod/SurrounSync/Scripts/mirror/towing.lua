-- Tow hitches, on every game. The game keeps a hitch on the towing car (TowingVehicle?, saved with it) and a
-- physics constraint it adds to the towed car; only the game whose player hitched had them, so on the other games
-- (and in the host's save) the towed car stayed where it was (user 2026-11-01: "towing vehicles is client side vs
-- server side"). A hitch or unhitch made here is sent on; the other game puts both cars where they stood on the
-- sender's and runs the game's own load-time hitch, AddTowingComp(true, true): a trace at the tow point, then the
-- constraint on the car it finds. A guest's hitch reaches the other guests through the host's (its hook fires there).

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local events = require("mirror.events")

local towing = {}

local MASTER = "/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C"
local SETTLE = 0.3        -- s after the game's call before a hitch is read (it sets the constraint a tick later)
-- s after the last tow call on a car before its change is sent: longer than SETTLE, so on the host a hitch another
-- guest's copy is still checking (and may undo: wrong car) isn't passed on to the other guests in between
local SEND_AFTER = 0.6
local PLACE_WAIT = 0.1    -- s between putting the cars in place and the hitch's trace
local TRIES = 3
local PENDING_FOR = 30.0  -- s a hitch waits for cars that aren't here yet

local cfg, role, session
local channel = events.reliable("tow")
local dirty = {}          -- tower address -> { car, before, at }: the game's tow functions ran on it
local told = {}           -- tower's host name -> towed car's host name or "-": what both games last agreed on
local work = {}           -- tower's host name -> a hitch from the other game being made here
local hook_in, now = 0.0, 0.0
local stats = { sent = 0, applied = 0, failed = 0 }

local function vehicles() return require("mirror.vehicles") end
local function shared() return role == "host" or (session and session.in_world()) end
local function alive(a) return a ~= nil and util.valid(a) end

-- The car this one tows, or nil.
local function hitched(car)
    local on, towed = false, nil
    pcall(function() on = car["TowingVehicle?"] == true end)
    if on then pcall(function() towed = car.PhysicsConstraintComp:GetOwner() end) end
    if on and alive(towed) and not util.same(towed, car) then return towed end
    return nil
end
-- "-" (tows nothing), the towed car's host name, or nil (it tows a car that has no name we can send)
local function state(car)
    local towed = hitched(car)
    if not towed then
        local on = false
        pcall(function() on = car["TowingVehicle?"] == true end)
        return not on and "-" or nil
    end
    return vehicles().peer_name_of(towed)
end

local function pose(car)
    local l, r
    pcall(function() l = car:K2_GetActorLocation(); r = car:K2_GetActorRotation() end)
    if not (l and r) then return nil end
    return string.format("%.1f %.1f %.1f %.2f %.2f %.2f", l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll)
end

-- (pre hook of AddTowingComp and RemoveTowingComp: the state before the first of them is what changed from)
local on_tow = function(self)
    local car
    pcall(function() car = self:get() end)
    if not alive(car) then return end
    local a = util.addr(car) or 0
    local d = dirty[a]
    if not d then d = { car = car, before = state(car) }; dirty[a] = d end
    d.at = now
end

local function forget_dirty(car)
    for a, d in pairs(dirty) do
        if util.same(d.car, car) then dirty[a] = nil end
    end
end

-- A car another player locked (vehlock "locked") isn't towed away: the lock parks only that car's own menu, and any
-- other car's Tow option traces for a car and hitches it (audit 2026-11-03). The hitch made here is undone, not sent.
local function locked_away(towed_name)
    local st
    pcall(function() st = require("mirror.vehlock").state_of(towed_name) end)
    return st == "locked"
end

local function send_changes()
    for a, d in pairs(dirty) do
        if now - d.at >= SEND_AFTER then
            dirty[a] = nil
            local car = d.car
            local name = alive(car) and vehicles().peer_name_of(car)
            local after = name and state(car)
            if after and after ~= "-" and not work[name] and locked_away(after) then
                pcall(function() car:RemoveTowingComp() end)
                pcall(function() require("mirror.notify").show("That car is locked by its owner - it can't be towed.", "warn", "tow.locked") end)
                log.info("towing: " .. name .. " hitched " .. after .. ", which another player locked - unhitched")
            elseif after and not work[name] and after ~= d.before and after ~= (told[name] or "-") then
                told[name] = after
                if after == "-" then
                    channel:send("U " .. name)
                    log.info("towing: " .. name .. " unhitched - telling the other game")
                else
                    local p1, p2 = pose(car), pose(hitched(car))
                    if p1 and p2 then
                        channel:send(string.format("H %s %s %s %s", name, after, p1, p2))
                        log.info("towing: " .. name .. " tows " .. after .. " - telling the other game")
                    end
                end
                stats.sent = stats.sent + 1
            end
        end
    end
end

local function driven(car)
    local v = vehicles()
    return util.same(car, v.my_car()) or v.peer_drives(car)
end
local function place(car, l, r)
    pcall(function() car:K2_SetActorLocationAndRotation(l, r, false, {}, true) end)
end

-- A hitch from the other game: both cars where they were there, then the game's own hitch, then a look at what
-- it hitched (its trace takes whatever car is at the tow point).
local function step(name, w)
    local v = vehicles()
    local car, towed = v.car_named(name), v.car_named(w.towed)
    if not (alive(car) and alive(towed)) then
        if now > w.give_up then
            work[name] = nil
            log.warn("towing: the other player's tow " .. name .. " -> " .. w.towed .. ": car not here")
        end
        return
    end
    local cur = hitched(car)
    if w.phase == "check" then
        if now - w.at < SETTLE then return end
        if cur and util.same(cur, towed) then
            work[name] = nil
            forget_dirty(car)
            stats.applied = stats.applied + 1
            log.info("towing: the other player hitched " .. w.towed .. " to " .. name .. " - hitched here")
            return
        end
        if cur then pcall(function() car:RemoveTowingComp() end) end
        w.tries = w.tries + 1
        if w.tries >= TRIES then
            work[name] = nil
            forget_dirty(car)
            stats.failed = stats.failed + 1
            log.warn("towing: couldn't hitch " .. w.towed .. " to " .. name .. " here (" .. (cur and "the tow point found another car" or "no car at the tow point") .. ")")
            return
        end
        w.phase, w.at = nil, now
        return
    end
    if w.phase == "placed" then
        if now - w.at < PLACE_WAIT then return end
        pcall(function() car:AddTowingComp(true, true) end)
        w.phase, w.at = "check", now
        return
    end
    if cur and util.same(cur, towed) then work[name] = nil; forget_dirty(car); return end
    if cur then pcall(function() car:RemoveTowingComp() end) end
    if not driven(car) then place(car, w.tl, w.tr) end
    if not driven(towed) then place(towed, w.ol, w.orot) end
    w.phase, w.at = "placed", now
end

local function num_pose(s)
    local x, y, z, p, yw, r = s:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
    x, y, z, p, yw, r = tonumber(x), tonumber(y), tonumber(z), tonumber(p), tonumber(yw), tonumber(r)
    if not (x and y and z and p and yw and r) then return nil end
    return { X = x, Y = y, Z = z }, { Pitch = p, Yaw = yw, Roll = r }
end

local function take(p)
    local kind, rest = p:match("^(%a) (.+)$")
    if kind == "U" then
        local name = rest:match("^([%w_]+)$")
        if not name then return end
        work[name] = nil
        told[name] = "-"
        local car = vehicles().car_named(name)
        if alive(car) and hitched(car) then
            pcall(function() car:RemoveTowingComp() end)
            forget_dirty(car)
            stats.applied = stats.applied + 1
            log.info("towing: the other player unhitched " .. name .. " - unhitched here")
        end
    elseif kind == "H" then
        local name, tn, a, b = rest:match("^([%w_]+) ([%w_]+) (%S+ %S+ %S+ %S+ %S+ %S+) (%S+ %S+ %S+ %S+ %S+ %S+)$")
        if not name or name == tn then return end
        local tl, tr = num_pose(a)
        local ol, orot = num_pose(b)
        if not (tl and ol) then return end
        told[name] = tn
        work[name] = { towed = tn, tl = tl, tr = tr, ol = ol, orot = orot, tries = 0, at = now, give_up = now + PENDING_FOR }
    end
end

function towing.tick(dt)
    if role == "off" then return end
    now = now + dt
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 2.0
        util.ensure_hook(MASTER .. ":AddTowingComp", on_tow)
        util.ensure_hook(MASTER .. ":RemoveTowingComp", on_tow)
    end
    local on = shared()
    channel:pump(function(p) if on then util.safe(take, "towing.take", p) end end)
    if not on then
        if next(dirty) or next(work) then dirty, work = {}, {} end
        return
    end
    for name, w in pairs(work) do util.safe(step, "towing.step", name, w) end
    send_changes()
end

function towing.status()
    return string.format("towing: sent %d, hitched/unhitched here %d, failed %d", stats.sent, stats.applied, stats.failed)
end

-- Respawn/reload: the old world's cars are freed - drop them without touching them.
local function forget_world() dirty, told, work = {}, {}, {} end
function towing.init(c, r, s)
    game.on_world_reset(forget_world)
    cfg, role, session = c, r, s
    if cfg.tow_sync == false then role = "off" end
    log.info("towing: " .. (role == "off" and "off" or "tow hitches are shared"))
end

return towing
