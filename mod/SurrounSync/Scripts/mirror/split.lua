-- P8 load split (host setting LOAD SPLITTING, off by default).
--
-- Normally the host's game runs every AI in the shared world: the ghost (the guest's body on the host) is an
-- AI-optimizer invoker, so the host spawns and simulates the zombies, people and animals around the guest too,
-- and sends them to the guest as copies. When the players are far apart that is a second populated area on the
-- host's CPU. Split, the guest's own game runs the AI around the guest instead:
--
--   host  merged -> splitting : players further apart than split_radius for split_after s, no host AI (or body)
--                               within quiet_radius of the guest, no horde/infestation fight there.
--                               Host blob "p8" = "s <epoch>".
--   guest                     : removes the host's copies, hands back the spawners the mod stopped, stops removing
--                               its own AI; answers "p8g" = "s <epoch> <fighting>".
--   host  splitting -> split  : only on that answer: the ghost leaves the optimizer (the host despawns the AI around
--                               the guest and spawns none there) and the host stops sending zombie snapshots.
--                               No answer within ack_timeout -> stays merged (an older guest never answers).
--   host  split -> merged     : players within merge_radius (and the guest not fighting), within force_radius,
--                               a horde/infestation fight near the guest, the setting turned off or the guest gone.
--                               Ghost back in the optimizer, snapshots resume, "p8" = "m <epoch>".
--   guest                     : own AI near it (and bodies) are kept until done, the rest removed, copies return.
--
-- The host decides every switch; the guest only follows and answers. Kills, XP and loot of the guest's own AI are
-- the guest's (as in its single player game) - nothing it does to them reaches the host's world.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local link = require("mirror.link")
local ghost = require("mirror.ghost")
local zombies = require("mirror.zombies")
local hostrules = require("mirror.hostrules")

local split = {}

local cfg, role, session
local now = 0.0
local state, epoch = "merged", 0
local far_since, asked_at, retry_at = nil, 0.0, 0.0
local gone_since = nil
local eval_in = 0.0
local sent = nil
local guest_state, guest_epoch, guest_fighting = "m", -1, false
local measure = nil         -- { at, what, before } one follow-up AI count after a switch
local stats = { splits = 0, merges = 0, timeouts = 0, reout = 0, last = "-" }
local GHOST_GRACE = 5.0     -- the ghost is briefly gone around saves and respawns
-- 4 players (host): the slot of the guest whose game runs the AI around this one (group split, group.lua)
local leader = nil
local peers_mod
local function P() peers_mod = peers_mod or require("mirror.peers"); return peers_mod end
local function others(fn) P().each("mirror.split", function(m) if m ~= split and m.slot then fn(m) end end) end

local function sp() return cfg.zombies.split end

local function put(body)
    if body == sent then return end
    sent = body
    link.put_blob(role == "host" and "p8" or "p8g", body)
end

local function read_guest()
    local body = link.get_blob("p8g")
    if not body then return end
    local s, e, f = body:match("^(%a) (%d+) (%d)")
    if s then guest_state, guest_epoch, guest_fighting = s, tonumber(e), f == "1" end
end

-- The slot of the guest this copy is for, its ghost's location, and the leader it follows (asking or following).
function split.slot() local t = link.tags and link.tags(); return P().slot_of(t and t.out) end
function split.ghost_loc() return ghost.location() end
function split.lead_slot() return (state == "asking" or state == "following") and leader or nil end
function split.host_state() return state end

-- How far this guest is from the nearest other player: the host, or (more than two players) another guest's ghost.
-- A guest runs its own AI only alone - or in a group: its leader and the leader's other followers don't count
-- (group split). Anyone else coming near merges it, so players together otherwise share the host's AI.
-- Returns that distance, my ghost's location and the distance to the host.
local function players_apart()
    local gl, hl = ghost.location(), nil
    pcall(function() hl = game.player():K2_GetActorLocation() end)
    if not (gl and hl) then return nil, gl end
    local dh = util.dist(gl, hl)
    local d, grp = dh, leader or split.slot()
    others(function(m)
        local l = m.ghost_loc()
        if not l or m.slot() == grp or m.lead_slot() == grp then return end
        d = math.min(d, util.dist(gl, l))
    end)
    return d, gl, dh
end

-- A guest with a lower slot that is split, near enough to lead this one (nil = none).
local function find_leader(gl)
    local me, best, bd = split.slot(), nil, math.huge
    others(function(m)
        if m.slot() < me and m.host_state() == "split" then
            local l = m.ghost_loc()
            local dd = l and util.dist(gl, l)
            if dd and dd < sp().split_radius and dd < bd then best, bd = m, dd end
        end
    end)
    return best, bd
end
local function leader_copy()
    local hit
    others(function(m) if m.slot() == leader then hit = m end end)
    return hit
end

local function blocked(gl)
    if require("mirror.infest").guest_hit_age() < sp().nest_hit_s then return "infestation fight" end
    if gl and require("mirror.horde").active_near(gl, sp().horde_radius) then return "horde" end
    return nil
end

local function merge(why)
    local idx = ghost.exists() and ghost.set_invoker(true) or -1
    zombies.set_split(false)
    local was = state
    state, epoch, far_since, leader = "merged", epoch + 1, nil, nil
    put("m " .. epoch)
    if was == "following" then
        stats.merges = stats.merges + 1
        stats.last = why
        log.info(string.format("split: stopped following (%s) - the host runs the AI around the guest again (invoker %d)", why, idx))
    elseif was == "split" then
        stats.merges = stats.merges + 1
        stats.last = why
        measure = { at = now + 20.0, what = "after the merge", before = ghost.ai_count() }
        log.info(string.format("split: merged (%s) - the host runs the AI around the guest again (invoker %d, host AI %d)",
            why, idx, measure.before))
    else
        log.info("split: split attempt cancelled (" .. why .. ")")
    end
end

local function host_tick(dt)
    local enabled = hostrules.mine("loadsplit")
    local guest = session.guest_in_world()
    if require("mirror.save_guard").busy() then return end
    if not ghost.exists() and state ~= "merged" then
        gone_since = gone_since or now
        if now - gone_since < GHOST_GRACE and guest and enabled then return end
    else
        gone_since = nil
    end
    if not (enabled and guest and ghost.exists()) then
        if state ~= "merged" then merge(not enabled and "setting off" or "guest gone") end
        far_since = nil
        if not guest then sent = nil end
        return
    end
    if sent == nil then put("m " .. epoch) end
    -- a guest nest hit can start waves within a frame: never wait a whole evaluation step for that one
    local urgent = state ~= "merged" and require("mirror.infest").guest_hit_age() < 1.0
    eval_in = eval_in - dt
    if eval_in > 0 and not urgent then return end
    eval_in = (state == "splitting" or state == "asking") and 0.25 or 1.0
    read_guest()
    local d, gl, dh = players_apart()
    if not d then return end
    local why = blocked(gl)
    local c = sp()
    if state == "merged" then
        local near, age = zombies.near_guest()
        local quiet = age < 2.0 and near >= c.quiet_radius
        -- near a split guest (lower slot), far from the host: follow it - its game runs the AI here too
        local lead_m = not why and dh > c.split_radius and now >= retry_at and find_leader(gl)
        if lead_m then
            leader = lead_m.slot()
            state, epoch, asked_at, eval_in, far_since = "asking", epoch + 1, now, 0.25, nil
            put("f " .. epoch .. " " .. leader)
            log.info(string.format("split: %.0f m from the host, next to the split guest in slot %d - asking to follow it (epoch %d)",
                dh / 100, leader, epoch))
            return
        end
        if d > c.split_radius and not why and quiet then
            far_since = far_since or now
        else
            far_since = nil
        end
        if far_since and now - far_since >= c.split_after and now >= retry_at then
            state, epoch, asked_at, eval_in = "splitting", epoch + 1, now, 0.25
            put("s " .. epoch)
            log.info(string.format("split: players %.0f m apart - asking the guest to run the AI around itself (epoch %d)", d / 100, epoch))
        end
    elseif state == "splitting" then
        if why or d < c.split_radius then
            retry_at = now + c.retry_after
            merge(why or "players closer again")
        elseif guest_state == "s" and guest_epoch == epoch then
            local before = ghost.ai_count()
            local idx = ghost.set_invoker(false)
            zombies.set_split(true)
            state = "split"
            stats.splits = stats.splits + 1
            measure = { at = now + 20.0, what = "after the split", before = before }
            log.info(string.format("split: the guest runs the AI around itself now - ghost invoker out (index %d), host AI %d, snapshots off",
                idx, before))
        elseif now - asked_at > c.ack_timeout then
            stats.timeouts = stats.timeouts + 1
            retry_at = now + c.retry_after
            merge("the guest didn't take over in time")
        end
    elseif state == "asking" or state == "following" then
        local lm = leader_copy()
        local ll = lm and lm.host_state() == "split" and lm.ghost_loc()
        local apart = ll and util.dist(gl, ll)
        if not ll then merge("the leader isn't split any more")
        elseif why then merge(why)
        elseif apart > c.split_radius * 1.25 then merge(string.format("%.0f m from the leader", apart / 100))
        elseif d < c.force_radius or (d < c.merge_radius and not guest_fighting) then merge(string.format("players %.0f m apart", d / 100))
        elseif state == "asking" then
            if guest_state == "f" and guest_epoch == epoch then
                local idx = ghost.set_invoker(false)
                zombies.set_split(true)
                state = "following"
                stats.splits = stats.splits + 1
                log.info(string.format("split: the guest in slot %d runs the AI around this guest now - ghost invoker out (index %d), snapshots off",
                    leader, idx))
            elseif now - asked_at > c.ack_timeout then
                stats.timeouts = stats.timeouts + 1
                retry_at = now + c.retry_after
                merge("no follow answer in time")
            end
        elseif ghost.invoker_index() >= 0 then
            ghost.set_invoker(false)
            stats.reout = stats.reout + 1
        end
    else
        if ghost.invoker_index() >= 0 then
            -- a respawned ghost (after a save) registers itself again
            ghost.set_invoker(false)
            stats.reout = stats.reout + 1
        end
        if why then merge(why)
        elseif d < c.force_radius then merge(string.format("players %.0f m apart", d / 100))
        elseif d < c.merge_radius and not guest_fighting then merge(string.format("players %.0f m apart", d / 100))
        end
    end
end

-- Guest -------------------------------------------------------------------------------------------------

local host_want, host_epoch, host_leader = "m", 0, nil
local answer_in = 0.0
local was_in = false

local function guest_tick(dt)
    local in_world = session.in_world()
    if not in_world then
        if was_in then
            was_in, host_want, host_epoch, host_leader, sent = false, "m", 0, nil, nil
            zombies.set_follow(false)
            link.reset_blob("p8")
        end
        return
    end
    was_in = true
    answer_in = answer_in - dt
    if answer_in > 0 then return end
    answer_in = 0.5
    local body = link.get_blob("p8")
    if body then
        local s, e, l = body:match("^(%a) (%d+) ?(%d*)")
        if s then host_want, host_epoch, host_leader = s, tonumber(e), tonumber(l) end
    end
    -- group split: ask the leader's copy to show its AI here; the host hears "f" once the leader confirmed
    local follow, acked = host_want == "f", false
    P().each("mirror.group", function(g, inst)
        if not (inst and g.follow and not g.leads()) then return end
        local mine = follow and inst.slot == host_leader
        g.follow(mine, host_epoch)
        if mine and g.follow_acked(host_epoch) then acked = true end
    end)
    if acked ~= zombies.is_follow() then
        zombies.set_follow(acked)
        log.info(string.format("split: %s (epoch %d)", acked and ("the guest in slot " .. tostring(host_leader) .. " runs the AI around me")
            or "the host runs the AI around me again", host_epoch))
        if acked then stats.splits = stats.splits + 1 else stats.merges = stats.merges + 1 end
    end
    local want = host_want == "s"
    if want ~= zombies.is_split() then
        zombies.set_split(want)
        local n = zombies.own_count()
        measure = { at = now + 20.0, what = want and "after the split" or "after the merge", before = n }
        log.info(string.format("split: %s (epoch %d) - own AI here now %d", want and "running the AI around me" or "the host runs the AI again",
            host_epoch, n))
        if want then stats.splits = stats.splits + 1 else stats.merges = stats.merges + 1 end
    end
    put(string.format("%s %d %d", zombies.is_split() and "s" or (zombies.is_follow() and "f" or "m"), host_epoch,
        zombies.guest_busy() and 1 or 0))
end

function split.tick(dt)
    if role ~= "host" and role ~= "guest" then return end
    now = now + dt
    if role == "host" then host_tick(dt) else guest_tick(dt) end
    if measure and now >= measure.at then
        local n = role == "host" and ghost.ai_count() or zombies.own_count()
        log.info(string.format("split: %s AI in this game %d s %s: %d (was %d)", role == "host" and "host" or "guest",
            20, measure.what, n, measure.before))
        measure = nil
    end
end

function split.state() return role == "host" and state or (zombies.is_split() and "split" or "merged") end

function split.status()
    if role == "host" then
        return string.format("split: %s (%s, epoch %d), splits %d, merges %d (last: %s), no answer %d, invoker re-out %d, host AI %d",
            state, hostrules.mine("loadsplit") and "on" or "off", epoch, stats.splits, stats.merges, stats.last, stats.timeouts,
            stats.reout, ghost.ai_count())
    end
    return string.format("split: %s (host epoch %d), splits %d, merges %d, own AI %d",
        zombies.is_split() and "split" or "merged", host_epoch, stats.splits, stats.merges, zombies.own_count())
end

local function forget_world()
    state, far_since, gone_since, sent, measure = "merged", nil, nil, nil, nil
    guest_state, guest_epoch, guest_fighting = "m", -1, false
    host_want, was_in = "m", false
end

function split.init(c, r, s)
    cfg, role, session = c, r, s
    game.on_world_reset(forget_world)
end

return split
