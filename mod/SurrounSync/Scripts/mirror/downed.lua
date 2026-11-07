-- Downed, not dead (user 2026-11-02: downed + revive, "make it so the player can choose to bleed out if they want as
-- well"). In co-op a hit that would kill the player downs them instead while another player is in the same world:
-- they sit on the floor (the game's floor sit: the other players' ghosts show it through the pose's Sitting? flag),
-- can't move, fight or loot, and take no more damage. A teammate who holds F within REACH_CM for REVIVE_S gets them up
-- with REVIVE_HP health; holding F while down gives up, and after BLEED_S they bleed out. Either way the hit that
-- kills them is a real one, so the game's own death runs (death bag, respawn screen). Alone, or with nobody in the
-- same world, a lethal hit kills as it always did.
-- The intercept: BP_PlayerCharacter's ReceiveAnyDamage, at Health <= 0, calls DeathBringer(out Used?) (the
-- Deathbringer skill: survive at 25 health once) and runs the death when Used? is false (decompiled, build 26303910;
-- the runtime name has a capital B). UE4SS runs a Blueprint function's hook after the function, and an out parameter
-- set there is what the caller reads (kit 2026-11-02: Used? set true in the hook, a 500 hit left the player at 1
-- health and alive). The skill keeps its turn: a Used? already true is the game's own save.
-- One copy of this file per other player (peers.lua, mates too): each sends my state on its link and shows its
-- player's; my own state (one per game) is in peers.shared("downed") and only the main copy acts on it.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local events = require("mirror.events")
local ghost = require("mirror.ghost")
local link = require("mirror.link")
local notify = require("mirror.notify")
local peers = require("mirror.peers")
local hostrules = require("mirror.hostrules")

local downed = {}

local BLEED_S, REVIVE_S, GIVE_UP_S = 60, 4.0, 1.5
local REACH_CM, REVIVE_HP = 250, 30
local KEYS = { "F", "Gamepad_FaceButton_Left" }   -- the game's interact (gamepad.lua)
local FRESH_S = 3.0      -- a copy that stopped ticking (its player left) is nobody who can come
local ALONE_S = 5.0      -- down with nobody in my world this long: the death goes on
local SWITCH_GRACE_S = 20.0   -- after co-op starts again (a host switch, a new role): alone doesn't count this long
local RESEND_S = 5.0     -- while down, said again (a player who joins meanwhile hears it)
local PEER_LATE_S = 10   -- a downed player not heard of this long past their bleed-out isn't down any more
local DIE_DMG = 100000.0
local SIT_FLOOR = "/Game/Character/Anims/Interaction/Chr_SittingFloor_Montage.Chr_SittingFloor_Montage"
local GS = "/Script/Engine.Default__GameplayStatics"

-- down/ep/till/revive: my state (ep counts my downs, so a late revive for an older one does nothing);
-- links: copy key -> { t, here }; cantake: CanTakeDamage? from before I went down; dying: until when a death goes on
local sh = peers.shared("downed", { links = {}, ep = 0 })
local key = {}
local main, on = false, false
local same_world = function() return false end
local channel = nil
local sent, resend_in = nil, 0.0
local peer = { down = false }     -- this copy's player
local hold = 0.0                  -- s F held next to them
local stats = peers.shared("downed.stats", { downs = 0, revived = 0, gave_up = 0, bled = 0, alone = 0, got_up = 0 })

local function name() return link.peer_name() or "Your teammate" end

local function key_held()
    for _, k in ipairs(KEYS) do if game.key_down(k) then return true end end
    return false
end

local function anyone_here()
    local t = os.clock()
    for _, e in pairs(sh.links) do if e.here and t - e.t <= FRESH_S then return true end end
    return false
end

local function med(p) return p.MedicalComponent end

-- the host's REVIVE rule (a guest plays by the host's; an older host sends none: on) and this PC's revive = false
local function allowed() return on and hostrules.get("revive") end

local function on_deathbringer(self, used)
    local p = game.player()
    if not (on and util.valid(p) and util.same(util.obj(self), p)) then return end
    local u
    pcall(function() u = used:get() end)
    if sh.dying and os.clock() < sh.dying then
        -- (gave up or bled out: the death goes on, the Deathbringer skill too)
        if u == true then pcall(function() used:set(false) end) end
        return
    end
    if u == true then return end
    if not sh.down and not (anyone_here() and allowed()) then return end
    pcall(function() used:set(true) end)
    pcall(function() med(p).Health = 1.0 end)
    if sh.down then return end
    sh.ep = sh.ep + 1
    sh.down, sh.till, sh.revive, sh.revive_by = true, os.clock() + BLEED_S, nil, nil
    -- (F already held when the hit came - looting - gives nothing up: it has to be let go first)
    sh.give, sh.give_ok, sh.apply_in, sh.card_in, sh.alone = 0.0, false, 0.0, 0.0, nil
    stats.downs = stats.downs + 1
    log.info("downed: a lethal hit - down, bleeding out in " .. BLEED_S .. " s")
end

-- (the hit montage of the lethal hit plays after the hook: the sit is put on from the next tick, and again each
-- second - the game's own stop-all or EnableInput would undo it)
local function lie_down(p)
    pcall(function() if sh.cantake == nil then sh.cantake = med(p)["CanTakeDamage?"] end end)
    pcall(function() med(p)["CanTakeDamage?"] = false end)
    pcall(function() p.CharacterMovement:DisableMovement() end)
    pcall(function() p:DisableInput(game.controller()) end)
    pcall(function() p["Sitting?"] = true end)
    local m = util.find(SIT_FLOOR)
    if not m then return end
    local cur
    pcall(function() cur = p:GetCurrentMontage() end)
    if not util.same(cur, m) then pcall(function() p:PlayAnimMontage(m, 1.0, FName("None")) end) end
end

-- what the game's stand-up does (IA_SitDown: StopAnimMontage + SetMovementMode walking), and the rest put back
local function get_up(p)
    local m = util.find(SIT_FLOOR)
    if m then pcall(function() p:StopAnimMontage(m) end) end
    pcall(function() p["Sitting?"] = false end)
    pcall(function() p.CharacterMovement:SetMovementMode(1, 0) end)
    pcall(function() p:EnableInput(game.controller()) end)
    pcall(function() med(p)["CanTakeDamage?"] = sh.cantake ~= false end)
    sh.cantake = nil
end

local function end_down()
    sh.down, sh.revive, sh.revive_by = false, nil, nil
    local p = game.player()
    if util.valid(p) then get_up(p) end
end

local function revive_me()
    local by = sh.revive_by
    end_down()
    local p = game.player()
    local hp = REVIVE_HP
    pcall(function() hp = math.min(REVIVE_HP, tonumber(med(p).MaxHealth) or REVIVE_HP) end)
    pcall(function() med(p).Health = hp end)
    pcall(function() p:SendHealthToClient(hp) end)
    pcall(function() p:SetPostProcessHealth(false) end)
    stats.got_up = stats.got_up + 1
    notify.show((by or "A teammate") .. " got you up.", "good", "downed.me", true)
    log.info("downed: revived by " .. tostring(by))
end

local function die(why)
    end_down()
    sh.dying = os.clock() + 5.0
    notify.clear("downed.me")
    log.info("downed: " .. why .. " - the death goes on")
    -- a hit that kills runs the death inside ApplyDamage, which waits for my animation task (pvp.lua): through the gate
    require("mirror.animgate").later(function()
        local q = game.player()
        if not util.valid(q) then return end
        pcall(function() med(q)["CanTakeDamage?"] = true end)
        local ok, err = pcall(function() util.cdo(GS):ApplyDamage(q, DIE_DMG, nil, q, nil) end)
        if not ok then log.warn("downed: the death hit failed: " .. tostring(err)) end
    end, "downed.die")
end

local function card(t)
    local left = math.max(0, math.ceil(sh.till - t))
    if sh.give > 0 then
        notify.show("Keep holding F to give up.", "bad", "downed.me", true,
            { title = "GIVING UP", progress = math.min(1, sh.give / GIVE_UP_S), sticky = true, quiet = true })
    else
        notify.show("A teammate can hold F next to you to get you up. Hold F to give up.", "bad", "downed.me", true,
            { title = "YOU'RE DOWN - " .. left .. " S", progress = math.max(0, (sh.till - t) / BLEED_S), sticky = true,
              quiet = true })
    end
end

local function own_tick(dt)
    local p = game.player()
    if not util.valid(p) then return end
    local dead = false
    pcall(function() dead = p["PlayerDead?"] == true end)
    if dead then
        if sh.down then sh.down, sh.revive = false, nil; notify.clear("downed.me") end
        sh.dying = nil
        return
    end
    if not sh.down then return end
    local t = os.clock()
    sh.apply_in = sh.apply_in - dt
    if sh.apply_in <= 0 then sh.apply_in = 1.0; lie_down(p) end
    if sh.revive == sh.ep then revive_me(); return end
    if not allowed() then die("the host turned revive off"); return end
    local held = key_held()
    if not held then sh.give_ok = true end
    sh.give = (held and sh.give_ok) and (sh.give + dt) or 0.0
    if sh.give >= GIVE_UP_S then stats.gave_up = stats.gave_up + 1; die("gave up"); return end
    if t >= sh.till then stats.bled = stats.bled + 1; die("bled out"); return end
    if anyone_here() or t < (sh.grace or -math.huge) then sh.alone = nil
    else
        sh.alone = sh.alone or t
        if t - sh.alone >= ALONE_S then stats.alone = stats.alone + 1; die("nobody left to get me up"); return end
    end
    sh.card_in = sh.card_in - dt
    if sh.card_in <= 0 then sh.card_in = 0.25; card(t) end
end

local function peer_up()
    peer.down, hold = false, 0.0
    notify.clear("downed.peer." .. name())
    notify.clear("downed.revive." .. name())
end

local function apply(p)
    local kind, ep, secs = p:match("^(%u) (%d+) ?(%d*)$")
    ep = tonumber(ep)
    if not ep then return end
    if kind == "D" then
        local fresh = not peer.down or peer.ep ~= ep
        peer.down, peer.ep, peer.till = true, ep, os.clock() + (tonumber(secs) or BLEED_S)
        if fresh then
            notify.show(name() .. " is down - hold F next to them to get them up.", "warn", "downed.peer." .. name(), true)
        end
    elseif kind == "U" then
        if peer.ep == ep then peer_up() end
    elseif kind == "V" then
        if sh.down and ep == sh.ep then sh.revive, sh.revive_by = ep, name() end
    end
end

local function near_peer()
    local p, g = game.player(), ghost.location()
    if not (g and util.valid(p)) then return false end
    local alive, l = true, nil
    pcall(function() alive = p["PlayerDead?"] ~= true end)
    pcall(function() l = util.vec(p:K2_GetActorLocation()) end)
    return alive and l ~= nil and util.dist(l, g) <= REACH_CM
end

local function peer_tick(dt, here)
    if peer.down and os.clock() > peer.till + PEER_LATE_S then peer_up() end
    local close = peer.down and here and not sh.down and near_peer()
    if close and key_held() then
        hold = hold + dt
        if hold >= REVIVE_S then
            channel:send("V " .. peer.ep)
            stats.revived = stats.revived + 1
            log.info("downed: got " .. name() .. " up")
            -- (until their "U": no second revive; their next "D" says if it didn't take)
            peer_up()
            notify.show("You got " .. name() .. " up.", "good", "downed.revive." .. name(), true)
        else
            notify.show("Keep holding F.", "info", "downed.revive." .. name(), true,
                { title = "GETTING " .. name():upper() .. " UP", progress = hold / REVIVE_S, sticky = true, quiet = true })
        end
    elseif hold > 0 then
        hold = 0.0
        notify.clear("downed.revive." .. name())
    end
end

function downed.tick(dt)
    if not on then return end
    local here = same_world() == true
    local e = sh.links[key]
    if not e then e = {}; sh.links[key] = e end
    e.t, e.here = os.clock(), here
    -- (messages first: a revive that came in this frame gets me up this frame)
    channel:pump(function(p) util.safe(apply, "downed.apply", p) end)
    if main then util.safe(own_tick, "downed.own", dt) end
    local st = (sh.down and "D " or "U ") .. sh.ep
    resend_in = resend_in - dt
    if here and (st ~= sent or (sh.down and resend_in <= 0)) then
        resend_in, sent = RESEND_S, st
        if sh.down then channel:send(string.format("D %d %d", sh.ep, math.max(0, math.ceil(sh.till - os.clock()))))
        elseif sh.ep > 0 then channel:send("U " .. sh.ep) end
    end
    peer_tick(dt, here)
end

function downed.status()
    return string.format("downed: %s, downs %d, got up %d, revived others %d, gave up %d, bled out %d",
        not allowed() and "off" or (sh.down and "DOWN" or (peer.down and "they're down" or "up")), stats.downs, stats.got_up,
        stats.revived, stats.gave_up, stats.bled)
end

-- co-op stops while I'm down (main copy): nobody can come any more, and my tick stops with it
function downed.stop()
    if main and sh.down then die("co-op ended") end
    peer_up()
    sh.links[key] = nil
end

local function forget()
    -- (down when the world went: its card goes too, else "you're down" stays up in the next world)
    if main and sh.down then notify.clear("downed.me") end
    if main then sh.down, sh.revive, sh.dying, sh.cantake = false, nil, nil, nil end
    peer, hold, sent = { down = false }, 0.0, nil
end

-- c: config (revive = false turns it off); same_world_fn: this copy's player is in my world; is_main: the copy that
-- acts on my own state (the main link's)
function downed.init(c, same_world_fn, is_main)
    same_world = same_world_fn or same_world
    main = is_main == true
    on = not (c and c.revive == false)
    -- (down while co-op starts again - a host switch makes the links anew, with nobody "here" for a few seconds:
    -- that isn't being left alone, so it doesn't kill; the bleed-out still runs; audit 2026-11-03)
    if main and sh.down then sh.alone, sh.grace = nil, os.clock() + SWITCH_GRACE_S end
    channel = channel or events.reliable("downed", 16)
    game.on_world_reset(forget)
    if main and on then
        game.player_hook("DeathBringer", function(self, used) util.safe(on_deathbringer, "downed.hook", self, used) end)
    end
    log.info("downed: " .. (on and "ready" or "off") .. (main and "" or " (another player's copy)"))
end

downed._shared = sh
downed._consts = { BLEED_S = BLEED_S, REVIVE_S = REVIVE_S, GIVE_UP_S = GIVE_UP_S, REACH_CM = REACH_CM, ALONE_S = ALONE_S,
                   SWITCH_GRACE_S = SWITCH_GRACE_S }

return downed
