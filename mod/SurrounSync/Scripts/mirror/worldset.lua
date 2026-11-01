-- World settings in co-op: the host's Difficulty.* and Loot.* values (trader currency cap, loot, XP...) run in the
-- guest's game while joined (player review 2026-10-31: the host changed the trader currency cap and the guest had
-- to change it too). The host's go over as the "diff" blob (world.lua); follow() sets the ones that differ.
-- Those are the guest's own AutoSettings values as well (kept per PC, written into each world's Difficulties.sav by
-- a save), so a restore is owed to the guest's own save from the moment a join leaves it: back in that save, the
-- own values (difficulty.mine, kept here while in it) are set again before anything saves it. After a crash the
-- player may open another own save: its values are set too only when the join showed that a world load doesn't
-- set them from its Difficulties.sav (then the game still runs the host's); otherwise that world keeps its own.
-- One for the game (peers.lua SHARED); ticks in solo too.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local difficulty = require("mirror.difficulty")
local slotguard = require("mirror.slotguard")
local notify = require("mirror.notify")

local worldset = {}

local LOOK_EVERY = 5.0   -- own world: remember changes, or run an owed restore
local NAMES_FOR = 60.0   -- the setting names come from the settings file
local HOST_FOR = 3.0     -- the host's values, read once for every guest's copy

local session_mod
local function session()
    session_mod = session_mod or require("mirror.session")
    return session_mod
end

local names_at, names_cache = -math.huge, nil
local function names()
    local t = os.clock()
    if t - names_at >= NAMES_FOR or not names_cache then
        names_at = t
        names_cache = difficulty.names() or names_cache
    end
    return names_cache
end

local function snapshot() return difficulty.snapshot(names()) end

-- the own save this world is (nil: loading, a co-op slot, no player yet)
local function own_world()
    local slot = session().world_save()
    if slot and util.valid(game.player()) and slotguard.is_own(slot) then return slot end
    return nil
end

local look_in = 0.0
local retry_at = -math.huge   -- an owed restore that couldn't set everything tries again from then
local last_state = "idle"
local last_own = nil      -- the own save I was last in
local remembered = nil    -- encode() of what difficulty.mine holds, as remembered this run
local join = nil          -- this join: { matched = {name = true}, text, told }

-- Set the own values again when an owed restore applies to this world. Returns true once nothing is owed.
-- (from the save path too: session save_now, realmplay before it reads the difficulty)
function worldset.restore_now()
    local p = difficulty.pending()
    if not p then return true end
    if session().state() ~= "idle" then return false end
    local slot = own_world()
    if not slot then return false end
    local mine, from = difficulty.mine()
    if mine and from == p.slot and (slot == p.slot or p.loads == "no") then
        local want, n = difficulty.differing(snapshot(), mine)
        if n > 0 then
            local done = difficulty.apply(want)
            if done < n then
                log.every("worldset.restore", 30, string.format("worldset: set only %d of %d own world settings - trying again", done, n))
                return false
            end
            log.info(string.format("worldset: your own world settings are back (%d set, save %s)", n, slot))
        else
            log.info("worldset: your own world settings already run (save " .. slot .. ")")
        end
    else
        log.info(string.format("worldset: save %s keeps its own world settings (the restore was owed to %s, loads %s)",
            slot, tostring(p.slot), tostring(p.loads)))
    end
    difficulty.clear_pending()
    return true
end

local function own_tick()
    local slot = own_world()
    if not slot then return end
    last_own = slot
    if difficulty.pending() then worldset.restore_now(); return end
    local snap = snapshot()
    if not snap then return end
    local text = slot .. "\n" .. difficulty.encode(snap)
    if text ~= remembered and difficulty.remember_mine(slot, snap) then remembered = text end
end

function worldset.tick(dt)
    local S = session()
    local st = S.state()
    if st ~= "idle" and last_state == "idle" and not difficulty.pending() then
        -- a join leaves this world: from here the game may run the host's values (kept now: the last look can be
        -- up to LOOK_EVERY old)
        if own_world() then remembered = nil; own_tick() end
        local _, from = difficulty.mine()
        local slot = own_world() or last_own or from
        if slot then difficulty.set_pending(slot, "?"); log.info("worldset: own world settings owed to save " .. slot) end
    end
    last_state = st
    if st == "idle" then join = nil end
    -- owed: every tick until it ran (the own world can be saved any moment once it is up)
    if st == "idle" and difficulty.pending() and os.clock() >= retry_at and own_world() then
        if not worldset.restore_now() then retry_at = os.clock() + 1.0 end
        return
    end
    look_in = look_in - (dt or 0)
    if look_in > 0 then return end
    look_in = LOOK_EVERY
    if st == "idle" then own_tick() end
end

-- the host's values as text for the "diff" blob (nil: none readable)
local host_at, host_text = -math.huge, nil
function worldset.host_text()
    local t = os.clock()
    if t - host_at < HOST_FOR then return host_text end
    host_at = t
    local snap = snapshot()
    if snap then host_text = difficulty.encode(snap) end
    return host_text
end

-- The guest's game runs the host's values while in the host's world (text: the blob, who: the host's name).
function worldset.follow(text, who)
    local host = difficulty.decode(text)
    if not (host and session().in_world()) then return end
    local cur = snapshot()
    if not cur then return end
    local mine, from = difficulty.mine()
    if not join then
        join = { matched = {} }
        local p = difficulty.pending()
        if not p and from then difficulty.set_pending(from, "?"); p = difficulty.pending() end
        -- what the join's load did: it shows only where the own values and the host's differ
        if p and p.loads == "?" and mine and not difficulty.same(mine, host) then
            local loads = difficulty.same(cur, host) and "yes" or difficulty.same(cur, mine) and "no" or nil
            if loads then
                difficulty.set_pending(p.slot, loads)
                log.info("worldset: a world load " .. (loads == "yes" and "sets" or "doesn't set") .. " the world settings from its save")
            end
        end
    end
    if join.text ~= text then join.text, join.matched = text, {} end
    local want, n = difficulty.differing(cur, host)
    if n > 0 then
        local back = false
        for name in pairs(want) do if join.matched[name] then back = true end end
        local done = difficulty.apply(want)
        log.every("worldset.follow", 10, string.format("worldset: %d of %d world settings set to %s's", done, n, tostring(who)))
        if back and not join.told then
            join.told = true
            notify.show("World settings come from " .. tostring(who) .. " while you're in their world.", "info", "worldset")
        end
    end
    -- (only what ran already: a setting that wouldn't set never reads as changed back)
    for name in pairs(host) do if not want[name] then join.matched[name] = true end end
end

local started = false
function worldset.init()
    if started then return end
    started = true
    game.on_tick(function(dt) util.safe(worldset.tick, "worldset.tick", dt) end)
end

return worldset
