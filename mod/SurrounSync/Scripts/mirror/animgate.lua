-- Animation on the game thread while anything holds the gate.
-- UE4SS takes its Lua lock in Blueprint code that animation worker threads run. An engine call made from our Lua
-- that waits for a mesh's animation task (a level load, a zombie copy's Death, a mesh swap, destroying the actor)
-- then waits for a worker that waits for us: the game freezes with no CPU use (DBG-20261027-006; guest report
-- 2026-10-30 15:36:52, inside a copy's Death). With a.ParallelAnimUpdate and a.ParallelAnimEvaluation at 0 no new
-- animation task starts; the ones already running end within a frame, so such calls are safe READY_FRAMES frames
-- after the gate closed.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")

local animgate = {}

local CVARS = { "a.ParallelAnimUpdate", "a.ParallelAnimEvaluation" }
local READY_FRAMES = 2
-- A hold not renewed for this long lapses (a part that stopped mid-world - another player's copy, a load call that
-- failed - would otherwise keep animation on the game thread for good). "load" lasts a whole level load; the
-- "later" queue's own hold is ended by animgate.tick.
local STALE_S, STALE_LOAD_S = 5.0, 180.0
local holders = {}   -- who -> os.clock() of the last hold
local saved, since = nil, nil
local broken = false

local function lib() return util.cdo("/Script/Engine.Default__KismetSystemLibrary") end
local function cvar(K, n)
    local v
    pcall(function() v = K:GetConsoleVariableIntValue(n) end)
    return v
end

-- (the engine's values back; without a world it's tried again by animgate.tick - never left at 0)
local function restore()
    local K, w = lib(), game.world()
    if not (K and w) then return end
    for n, v in pairs(saved) do
        pcall(function() K:ExecuteConsoleCommand(w, n .. " " .. tostring(v), nil) end)
    end
    saved, since = nil, nil
end

function animgate.hold(who)
    holders[who] = os.clock()
    if saved or broken then return end
    local K, w = lib(), game.world()
    if not K then
        broken = true
        log.warn("animgate: no KismetSystemLibrary - the animation cvars stay as they are")
        return
    end
    if not w then return end   -- (no world: tried again on the next hold)
    saved = {}
    for _, n in ipairs(CVARS) do
        saved[n] = cvar(K, n) or 1
        pcall(function() K:ExecuteConsoleCommand(w, n .. " 0", nil) end)
        local now = cvar(K, n)
        if now ~= nil and now ~= 0 then
            log.every("animgate-" .. n, 3600, "animgate: " .. n .. " stays " .. tostring(now) .. " - can't move it to the game thread")
        end
    end
    since = util.frame()
end

function animgate.release(who)
    holders[who] = nil
    if saved and not next(holders) then restore() end
end

function animgate.held(who) return holders[who] ~= nil end

-- True when calls that wait for animation tasks are safe now (or the cvars can't be set at all: no world, no
-- KismetSystemLibrary - the calls then run at once as they did before the gate).
function animgate.ready()
    if broken or not game.world() then return true end
    return saved ~= nil and util.frame() - since >= READY_FRAMES
end

-- For the other modules: fn runs now if it's safe, else once it is (animgate.tick, every frame). The gate opens
-- again LINGER s after the last call that needed it.
local LATER, LINGER = "later", 1.0
local queue, need = {}, -100
local doomed = {}   -- address -> actor waiting for its K2_DestroyActor
function animgate.later(fn, what)
    need = os.clock()
    if animgate.ready() then util.safe(fn, what or "animgate.later"); return true end
    animgate.hold(LATER)
    queue[#queue + 1] = { fn = fn, what = what }
    return false
end

-- For a caller that tries every frame: true when its call is safe now; false = the gate is closing, ask again.
function animgate.safe_now()
    need = os.clock()
    if animgate.ready() then return true end
    animgate.hold(LATER)
    return false
end

-- K2_DestroyActor of an animated actor (a character, a vehicle with an anim graph): at once if safe, else it is
-- hidden and without collision right away and destroyed a few frames later.
function animgate.destroy(actor, what)
    if not util.valid(actor) then return end
    local a = util.addr(actor) or 0
    doomed[a] = actor   -- (before later(): it may run the destroy right here)
    if animgate.later(function()
        local still = doomed[a]
        doomed[a] = nil
        if still and util.valid(actor) then actor:K2_DestroyActor() end   -- (not if flush() did it)
    end, what) then return end
    pcall(function() actor:SetActorHiddenInGame(true) end)
    pcall(function() actor:SetActorEnableCollision(false) end)
end

-- Is this actor waiting for its destroy (no longer the ghost / a copy, but not gone either)?
function animgate.pending(actor) return doomed[util.addr(actor) or 0] ~= nil end

-- A save starts: every actor still waiting is destroyed now. A player body kept into a save took the player's
-- inventory with it (ingame lesson 2026-10-17: never keep the ghost during a save) - that outweighs the wait.
function animgate.flush()
    local n = 0
    for a, actor in pairs(doomed) do
        doomed[a] = nil
        if util.valid(actor) then pcall(function() actor:K2_DestroyActor() end); n = n + 1 end
    end
    return n
end

function animgate.tick()
    local t = os.clock()
    if queue[1] and animgate.ready() then
        need = t
        local q = queue
        queue = {}
        for _, e in ipairs(q) do util.safe(e.fn, e.what or "animgate.later") end
    end
    if holders[LATER] and not queue[1] and t - need > LINGER then animgate.release(LATER) end
    for who, at in pairs(holders) do
        if who ~= LATER and t - at > (who == "load" and STALE_LOAD_S or STALE_S) then
            log.info("animgate: " .. tostring(who) .. "'s hold lapsed (not renewed) - animation back on its threads")
            animgate.release(who)
        end
    end
    if saved and not next(holders) then restore() end
end

-- The old world's actors went with it.
local function forget_world()
    queue, doomed = {}, {}
    animgate.release(LATER)
end

function animgate.init()
    game.on_tick(animgate.tick)
    game.on_world_reset(forget_world)
end

return animgate
