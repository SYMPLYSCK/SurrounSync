-- Shared sleep (user 2026-10-30, "all must sleep"): the night is skipped only once every player has gone to sleep.
-- The game's sleep (SleepingUI_C's sleep button, decompiled from build 26303910) calls the sky's
-- "Transition Time of Day"(650, 2.0, 7, 2.0, false): 06:50 over 2 s. Joined, the host's clock is everyone's, so
-- one sleeping host skipped the night for all and a sleeping guest was snapped back to the host's night.
-- Now, while another player is connected, that transition is held: its target becomes the time it is now
-- (Blueprint hooks here run before the function, so its argument is changed - New Time of Day just past the
-- current time; equal would read as "a day ahead" in Tick Time Transition). The player stays asleep until they
-- walk away from where they lay down. The host counts itself and every connected guest; when all are asleep it
-- runs the transition itself and tells the guests, who run the same one. Alone, the game's sleep is untouched.
-- While held, the game's sleeping screen stays up until the morning, saying how many are still awake and that moving
-- cancels the sleep (user 2026-10-31); the player has their input back under it, so a step is the way out.
-- The host has one copy of this file per guest link: what they share is in peers.shared("sleep").

local log = require("mirror.log")
local util = require("mirror.util")
local link = require("mirror.link")
local game = require("mirror.game")
local notify = require("mirror.notify")
local peers = require("mirror.peers")

local sleep = {}

local UDS_FN = "/Game/UltraDynamicSky/Blueprints/Ultra_Dynamic_Sky.Ultra_Dynamic_Sky_C:Transition Time of Day"
local MORNING, FADE, EASE, EXP = 650.0, 2.0, 7, 2.0
local GET_UP_CM = 50   -- a step: "Move to cancel sleep"
local SCREEN = "SleepingUI_C"
local SCREEN_BACK_S = 4.0   -- the game takes its screen down 2.5 s after the sleep button (Exit); put back in this time
local SCREEN_FADE_S = 2.5   -- at morning it stays while the sky moves, as the game's does
local FRESH_S = 6.0    -- a guest copy that stopped updating its line no longer counts
local QUIET_S = 10.0   -- a guest that says nothing this long after it came (an older build, world sync off) doesn't hold the night
local TICK_S = 0.5

-- me: this game's sleep request { at = where they lay down }; guests: copy key -> { on, t };
-- go: nights skipped (sent to the guests); bypass: our own transition is running; shown: the notice on screen
local sh = peers.shared("sleep", { guests = {}, go = 0 })
local key = {}         -- this copy's entry in sh.guests
local role = "off"
local peer_live = function() return false end
local tick_in = 0.0
local sent, got, seen_go = nil, nil, nil
local my_go = 0        -- host copy: the skip its guest's "asleep" was from (it's awake after one)
local was_live, live_at = false, 0.0

-- The link hands a blob out only when its text changed: back after a stall (or another guest on this link), the
-- other side's unchanged "1" would never be read again.
local function relink(name)
    was_live, live_at = true, os.clock()
    pcall(function() link.reset_blob(name) end)
end

local function player_at()
    local at
    pcall(function() at = util.vec(game.player():K2_GetActorLocation()) end)
    return at
end

local function sky()
    local found
    pcall(function()
        for _, o in ipairs(FindAllOf("Ultra_Dynamic_Sky_C") or {}) do
            if util.valid(o) and not o:GetFullName():find("Default__", 1, true) then found = o; break end
        end
    end)
    return found
end

-- The game's sleeping screen (SleepingUI_C: a blur and its SleepingText "Sleeping . . ."). The sleep button hides its
-- Choices, shows SleepingText and 2.5 s later calls Exit: the screen off, input and the game's input mode back
-- (decompiled 2026-10-31; it has no Construct, so adding it again re-runs nothing). sh.scr = { ui, since, back,
-- text, off_at }: back = put back after that Exit. Taken down again later (its Tick calls Exit on the pause key)
-- it stays down - still asleep, the card says so.
local function screen_find()
    for _, w in ipairs(FindAllOf(SCREEN) or {}) do
        local on = false
        pcall(function() on = w:IsInViewport() end)
        if util.valid(w) and on == true then return w end
    end
    return nil
end
local function screen_text(left)
    local wait = ""
    if left and left > 0 then wait = string.format("\nWaiting for %d more player%s to sleep", left, left == 1 and "" or "s") end
    return "Sleeping . . ." .. wait .. "\nMove to cancel sleep"
end
local function screen_keep()
    local s = sh.scr
    if not s then return end
    if not util.valid(s.ui) then sh.scr = nil; return end
    local on = false
    pcall(function() on = s.ui:IsInViewport() end)
    if s.off_at then
        if os.clock() >= s.off_at then
            if on == true then pcall(function() s.ui:RemoveFromParent() end) end
            sh.scr = nil
        end
        return
    end
    if on ~= true then
        if s.back and os.clock() - s.since > SCREEN_BACK_S then sh.scr = nil; return end
        s.back, s.text = true, nil
        pcall(function() s.ui:AddToViewport(0) end)
        pcall(function() s.ui.Choices:SetVisibility(2) end)        -- Hidden
        pcall(function() s.ui.SleepingText:SetVisibility(4) end)   -- SelfHitTestInvisible
        pcall(function() s.ui:PlayAnimationForward(s.ui.BlurAnim, 1.0, false) end)
    end
    local t = screen_text(sh.left)
    if t ~= s.text then
        s.text = t
        pcall(function() s.ui.SleepingText:SetText(FText(t)) end)
    end
end
-- the screen goes: now (got up, alone again) or after the morning's sky move
local function screen_off(after)
    if sh.scr and not sh.scr.off_at then sh.scr.off_at = os.clock() + (after or 0) end
    screen_keep()
end

-- The game's own sleep transition, run by us (not held by our hook).
local function skip(why)
    local s = sky()
    if not s then log.warn("sleep: no sky to move to morning (" .. why .. ")"); return false end
    sh.bypass = true
    local ok, err = pcall(function() local f = s["Transition Time of Day"]; f(s, MORNING, FADE, EASE, EXP, false) end)
    sh.bypass = false
    log.info("sleep: " .. why .. " - morning" .. (ok and "" or (" FAILED: " .. tostring(err))))
    return ok
end

local function show(n, total)
    local line = n .. "/" .. total .. (sh.me and "m" or "")
    local left = total - n
    sh.left = sh.me and left or nil
    if sh.scr then screen_keep() end
    if line == sh.shown then return end
    local was = sh.shown
    sh.shown = line
    -- (nobody asleep: a count card goes; "morning comes" and "you got up" stay their time)
    if n <= 0 then if was and was:find("/", 1, true) then notify.clear("sleep") end; return end
    if sh.me then
        notify.show(string.format("You're asleep - waiting for %d more player%s to sleep. Move to cancel sleep.",
            left, left == 1 and "" or "s"), "info", "sleep")
    else
        notify.show(string.format("%d of %d players asleep - sleep in a bed or sleeping bag to skip the night.",
            n, total), "info", "sleep")
    end
end

local function morning(why)
    sh.me, sh.shown, sh.left = nil, "morning", nil
    notify.show("Everyone is asleep - morning comes.", "good", "sleep")
    skip(why)
    screen_off(SCREEN_FADE_S)
end

-- pre-hook of the sky's Transition Time of Day: the game's sleep, held while someone else is here
local function on_transition(self, new_tod, secs)
    if sh.bypass or not (role == "host" or role == "guest") or not peer_live() then return end
    local t, d
    pcall(function() t, d = new_tod:get(), secs:get() end)
    if t ~= MORNING or d ~= FADE then return end
    local sky_o, tod
    pcall(function() sky_o = self:get(); tod = sky_o["Time of Day"] end)
    if type(tod) ~= "number" then return end
    -- Kit 2026-10-31: setting the argument alone didn't hold it (the clock went 54 -> 655): this hook ran after the
    -- function, which had already stored its target in Transition Time B for Tick Time Transition to ease towards.
    -- So both: the argument (a hook that runs first) and the stored target (one that runs after).
    pcall(function() new_tod:set(tod + 0.01) end)
    local ok = pcall(function() if sky_o["Transitioning Time"] then sky_o["Transition Time B"] = tod + 0.01 end end)
    -- (a hold that didn't take: the night goes here now - marked asleep, the morning after everyone slept would be a day on)
    local now_t
    pcall(function() now_t = sky_o["Transitioning Time"] and sky_o["Transition Time B"] or new_tod:get() end)
    if not ok or now_t == MORNING then log.warn("sleep: couldn't hold the game's sleep - it skips the night here"); return end
    sh.me, sh.shown = { at = player_at() }, "asleep"
    local ui = screen_find()
    sh.scr = ui and { ui = ui, since = os.clock(), back = false } or nil
    log.info(string.format("sleep: I went to sleep at %.0f - held until everyone sleeps%s", tod, ui and "" or " (no sleeping screen found)"))
    notify.show("You're asleep - the night passes when everyone sleeps. Move to cancel sleep.", "info", "sleep")
    screen_keep()
end

local function got_up()
    local me = sh.me
    if not (me and me.at) then return end
    local at = player_at()
    if at and util.dist(at, me.at) > GET_UP_CM then
        sh.me, sh.shown, sh.left = nil, "up", nil
        log.info("sleep: I got up")
        notify.show("You got up - no longer asleep.", "info", "sleep")
        screen_off()
    end
end

-- n asleep of total counted; silent = here but never says (doesn't hold the night)
local function count()
    local n, total, silent, t = sh.me and 1 or 0, 1, 0, os.clock()
    for _, e in pairs(sh.guests) do
        if t - e.t <= FRESH_S then
            if e.silent then silent = silent + 1
            else
                total = total + 1
                if e.on then n = n + 1 end
            end
        end
    end
    return n, total, silent
end

-- asleep while everyone else left: nobody to wait for, and alone the game's sleep isn't held - get up, sleep again
local function left_alone(who)
    if not sh.me then return end
    local _, total, silent = count()
    if total > 1 or silent > 0 then return end
    sh.me, sh.shown, sh.left = nil, "up", nil
    screen_off()
    log.info("sleep: " .. who .. " left while I slept - awake")
    notify.show(who:gsub("^%l", string.upper) .. " left - you're awake. Sleep again to skip the night.", "info", "sleep")
end

local function host_tick(live)
    if not live then
        sh.guests[key], got, sent, was_live = nil, nil, nil, false
        left_alone("everyone else")
        return
    end
    if not was_live then relink("slp_g") end
    local b = link.get_blob("slp_g")
    if b then got = b end
    -- (a night skipped: the guest is awake until it says otherwise - its "1" is still the last line read)
    if my_go ~= sh.go then my_go, got = sh.go, got and "0" end
    sh.guests[key] ={ on = got == "1", t = os.clock(), silent = got == nil and os.clock() - live_at > QUIET_S }
    local n, total, silent = count()
    if sh.me and (total >= 2 or silent > 0) and n == total then
        sh.go = sh.go + 1
        my_go, got = sh.go, got and "0"   -- (a guest that never says stays one that never says)
        sh.guests[key].on = false
        log.info(string.format("sleep: all %d players asleep", total))
        morning("everyone asleep")
        n = 0
    end
    local line = string.format("%d %d %d", n, total, sh.go)
    if line ~= sent then link.put_blob("slp_h", line); sent = line end
    show(n, total)
end

local function guest_tick(live)
    if not live then
        sent, was_live = nil, false
        left_alone("the host")
        return
    end
    if not was_live then relink("slp_h"); seen_go = nil end
    local want = sh.me and "1" or "0"
    if want ~= sent then link.put_blob("slp_g", want); sent = want end
    local b = link.get_blob("slp_h")
    local n, total, go = (b or ""):match("^(%d+) (%d+) (%d+)$")
    if not go then return end
    n, total, go = tonumber(n), tonumber(total), tonumber(go)
    if seen_go and go ~= seen_go then
        seen_go = go
        morning("the host says everyone is asleep")
        link.put_blob("slp_g", "0"); sent = "0"
        return
    end
    seen_go = go
    show(n, total)
end

function sleep.tick(dt)
    -- every frame while there is a screen: put back the moment the game takes it down (no flash of the world)
    if sh.scr then screen_keep() end
    tick_in = tick_in - dt
    if tick_in > 0 then return end
    tick_in = TICK_S
    if role ~= "host" and role ~= "guest" then return end
    local live = peer_live()
    if live then util.ensure_hook(UDS_FN, on_transition) end
    got_up()
    if role == "host" then host_tick(live) else guest_tick(live) end
end

function sleep.init(r, connected)
    role = r or "off"
    peer_live = connected or peer_live
    sent, got, seen_go, was_live = nil, nil, nil, false
end

-- a new world: whoever was asleep is in a new one now
function sleep.forget() sh.me, sh.shown, sh.left, sh.scr = nil, nil, nil, nil end

sleep._on_transition = on_transition
sleep._shared = sh

return sleep
