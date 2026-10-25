-- 4 players, group load split: two guests together far from the host. The one with the lower slot (the leader)
-- is split (split.lua) and runs the AI around itself; its game also runs it around the other guest (the
-- follower) and sends it to them like the host would. Runs in a guest's copy for another guest (peers.lua,
-- "mate") - this game and that player form the pair:
--   follower side: the host told my main split "f <epoch> <leader slot>" -> group.follow(epoch) on the copy for
--                  the leader: blob "p8f" = "f <epoch>" to them; their "p8l" = "l <epoch>" -> my copy of
--                  zombies shows their AI (guest role); the main split then answers the host "f <epoch>".
--   leader side:   their "p8f" asks; while this game is split, the copy's zombies send my AI around their
--                  ghost (host role) and their ghost here becomes a body the AI goes for; answer "p8l".
-- Anything else ("m", this game merged, the player gone) ends it on both sides.

local log = require("mirror.log")
local link = require("mirror.link")
local zombies = require("mirror.zombies")

local group = {}

local cfg, session
local lead = false          -- this game leads the pair (my slot is the lower)
local on = false
local want, want_e = "m", 0 -- follower: what I asked
local acked = -1            -- follower: epoch the leader confirmed
local their, their_e = "m", 0
local check_in = 0.0
local peers

local function main_zombies() return peers.main("mirror.zombies") end

local function set_on(v, why)
    if v == on then return end
    on = v
    zombies.set_gate(v)
    if lead then require("mirror.phase1").set_ghost_kind(v and "host" or "guest") end
    log.info(string.format("group: %s %s (%s)", lead and "leading" or "following", link.peer_name(), v and ("on - " .. why) or ("off - " .. why)))
end

-- follower: called by my main split on the copy for the leader
function group.follow(v, epoch)
    local w = v and "f" or "m"
    if w == want and (epoch or 0) == want_e then return end
    want, want_e = w, epoch or 0
    link.put_blob("p8f", want .. " " .. want_e)
    if not v then set_on(false, "the host merged me") end
end
function group.follow_acked(epoch) return not lead and want == "f" and acked == epoch and on end
function group.leads() return lead end

function group.tick(dt)
    if not cfg then return end
    check_in = check_in - dt
    if check_in > 0 then return end
    check_in = 0.25
    if lead then
        local b = link.get_blob("p8f")
        if b then
            local s, e = b:match("^(%a) (%d+)")
            if s then their, their_e = s, tonumber(e) end
        end
        local split_here = main_zombies().is_split()
        local v = their == "f" and split_here and session.in_world()
        if v ~= on then
            set_on(v, v and "their game shows my AI" or (their ~= "f" and "they stopped following" or "I'm not split any more"))
            link.put_blob("p8l", (v and "l " or "m ") .. their_e)
        end
    else
        local b = link.get_blob("p8l")
        if b then
            local s, e = b:match("^(%a) (%d+)")
            if s == "l" then acked = tonumber(e) elseif s then acked = -1 end
        end
        local v = want == "f" and acked == want_e and session.in_world()
        if v ~= on then set_on(v, v and "the leader runs the AI here" or "the leader stopped") end
    end
end

function group.status()
    return string.format("group: %s, %s", lead and "leader" or "follower", on and "on" or "off")
end

function group.init(c, s)
    cfg, session = c, s
    peers = require("mirror.peers")
    local t = link.tags()
    lead = peers.my_slot() < peers.slot_of(t and t.out)
    -- this copy's zombies: the host role on the leader (sends), the guest role on the follower (shows)
    zombies.init(cfg, lead and "host" or "guest", s, { secondary = true })
    zombies.set_gate(false)
    if lead then zombies.set_guest_center(function() return require("mirror.ghost").location() end) end
    -- the bodies of that AI carry the same loot for both of us (the leader's game rolls it, like the host's)
    require("mirror.corpses").init(cfg, lead and "host" or "guest", zombies, s)
    on, want, want_e, acked, their, their_e = false, "m", 0, -1, "m", 0
end

return group
