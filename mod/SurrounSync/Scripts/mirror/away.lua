-- "I'm in the game menu": the pause/settings menu stops the player's tick, so poses stop and after 10 s the other
-- game said "X's game isn't responding (paused, loading or frozen)" (player review 2026-10-31), and a file link
-- went "gone" after 45 s. While no tick runs, phase1's game-thread menu watch puts "away menu <n>", n bumped every
-- SEND_EVERY s; the next tick puts "away -". The other game takes "paused"/"gone" as "menu" while the last bump
-- is under FRESH_S old: a game frozen in its menu stops bumping and the normal paused/gone path takes over.
-- One per link (peers.lua PRESENCE): each guest's copy tells its own link.

local link = require("mirror.link")

local away = {}

local IDLE_S = 2        -- no tick for this long while the player exists = in the menu
local SEND_EVERY = 5
local FRESH_S = 20
local BACK_S = 3        -- after "away -": until their poses come again

local last_tick = nil   -- os.clock() of my last game tick
local sent_at = nil     -- os.clock() of my last "menu" bump, nil while I'm not marked away
local n = 0
local peer_at = nil     -- os.clock() when the other game's last "menu" bump arrived

-- every game tick: I'm back if I was away; read the other game's state
function away.tick()
    last_tick = os.clock()
    if sent_at then
        sent_at = nil
        link.put_blob("away", "-")
    end
    local b = link.get_blob("away")
    if b and b:match("^menu ") then peer_at = os.clock()
    elseif b and peer_at then
        -- back from the menu: their first poses can land a moment after this (kit 2026-10-31: "isn't responding"
        -- flashed on the guest as the host closed its menu), so it stays "menu" for BACK_S more
        peer_at = math.min(peer_at, os.clock() - FRESH_S + BACK_S)
    end
end

-- from phase1's menu watch (game thread): can = the player exists and no load/leave is under way
function away.idle(can)
    local t = os.clock()
    if not (can and last_tick and t - last_tick > IDLE_S) then return end
    if sent_at and t - sent_at < SEND_EVERY then return end
    n, sent_at = n + 1, t
    link.put_blob("away", "menu " .. n)
end

-- no game tick of mine for IDLE_S (the pause menu); false before the first tick
function away.stalled() return last_tick ~= nil and os.clock() - last_tick > IDLE_S end

function away.peer_menu() return peer_at ~= nil and os.clock() - peer_at < FRESH_S end

-- the other game sits in its menu (its game still runs): no poses from it is no lost link
function away.in_menu() return away.peer_menu() and not link.peer_game_gone() end

-- link.peer_state as the session should read it: no data because the other game sits in its menu is "menu"
function away.wrap(ps)
    if (ps == "paused" or ps == "gone") and away.in_menu() then return "menu" end
    return ps
end

function away.reset()
    -- (my file would still say "menu" to a link opened later)
    if sent_at then link.put_blob("away", "-") end
    last_tick, sent_at, peer_at = nil, nil, nil
    link.reset_blob("away")
end

return away
