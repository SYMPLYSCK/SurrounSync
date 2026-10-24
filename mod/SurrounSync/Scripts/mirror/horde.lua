-- Horde beacons in co-op: only the host's beacon runs a horde. The guest's copy would run its own
-- (its waves get removed by the zombie sync, so it stalls) - a guest press is sent to the host instead,
-- and the host's horde state, countdown/wave messages and dish movement are shown on the guest's copy.
-- Waves (host zombies), rewards (drops) and the beacon's removal (builds) are synced elsewhere.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local link = require("mirror.link")
local ghost = require("mirror.ghost")
local events = require("mirror.events")

local horde = {}

local BEACON = "/Game/Blueprints/HordeSystem/Beacon/Buildable_HordeBeacon.Buildable_HordeBeacon_C"
local GFL = "/Game/Blueprints/GameFunctionLibrary.GameFunctionLibrary_C"
local SAI = "/Game/AI/SD_AIComponent.SD_AIComponent_C"
local CLS = "Buildable_HordeBeacon_C"
-- A guest press runs the copy's own Event_StartHorde: its countdown is a chain of Delays (gaps up to
-- 15 s) that stops at the first step that finds HordeStarted? false. The copy's flag stays false that
-- long after such a press, so the chain is dead before the host's state is shown on it.
local LOCAL_CHAIN_S = 17.0
local MUTE_S = 3.0          -- the guest's own press already showed the message the host's answer repeats
local WAVE_RADIUS = 1500.0  -- waves spawn within 850 of the beacon (FindLocation)
local STATE_EVERY = 1.0

local cfg, role, session
local same_world = function() return false end
local channel = events.new("horde", 32, 10)
local now, state_in, hook_in = 0.0, 0.0, 0.0
local active = {}          -- host: addr -> { obj, id }
local last_blob = nil
local guest_body = ""     -- guest: the host's last hordes list (re-applied each STATE_EVERY)
local shown = {}           -- guest: id -> { s, c } last host state applied
local local_at = {}        -- guest: id -> time of the copy's own start
local pressed_at = {}      -- guest: id -> time of the last press sent to the host
local mute_until = 0.0
local retargeting = false
local stats = { requests = 0, started = 0, stopped = 0, ignored = 0, texts = 0, retargeted = 0, missing = 0 }

local function shared() return role == "host" or (session and session.in_world()) end
local function on() return (role == "host" or role == "guest") and same_world() and shared() end

local function grid(l) return math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5), math.floor(l.Z / 10 + 0.5) end
local function id_of(b)
    local l = b:K2_GetActorLocation()
    return string.format("%s@%d,%d,%d", CLS, grid(l))
end
local function flags(b)
    local s, c = false, false
    pcall(function() s = b["HordeStarted?"] == true; c = b["CanStopHorde?"] == true end)
    return s, c
end

-- Host ------------------------------------------------------------------------------------------

local function put_state()
    local lines = {}
    for a, h in pairs(active) do
        local s, c = false, false
        if util.valid(h.obj) then s, c = flags(h.obj) end
        if s then lines[#lines + 1] = string.format("%s %d", h.id, c and 1 or 0) else active[a] = nil end
    end
    table.sort(lines)
    local body = table.concat(lines, "\n")
    if body ~= last_blob then
        last_blob = body
        link.put_blob("hordes", body)
    end
end

-- A finished beacon destroys itself right after SpawnRewards: it must leave `active` then, or the next zombie
-- retarget / state step touches a freed object (host crash 0xc0000005 at 0x18, 2026-10-24).
local finished = {}        -- host: addr -> time it finished (ignored by note() for a while)
local function note(b)
    if not util.valid(b) then return end
    local a = util.addr(b) or 0
    if finished[a] and now - finished[a] < 30 then return end
    local ok, id = pcall(id_of, b)
    local l
    pcall(function() l = util.vec(b:K2_GetActorLocation()) end)
    if ok and l then active[a] = { obj = b, id = id, loc = l } end
    state_in = 0
end

local function on_finished(self)
    if role ~= "host" then return end
    local b = util.obj(self)
    local a = b and util.addr(b)
    if not a then return end
    finished[a] = now
    if active[a] then
        active[a] = nil
        last_blob = nil
        put_state()
    end
end

local function on_host_event(self)
    if role ~= "host" or not on() then return end
    note(util.obj(self))
end

local function on_request(p)
    local id, what = p:match("^I (%S+) (%a+)$")
    if not id then return end
    stats.requests = stats.requests + 1
    local b = util.find_by_id(id, 100)
    if not b then stats.missing = stats.missing + 1; log.info("horde: guest pressed beacon " .. id .. " - not here"); return end
    local s, c = flags(b)
    if what == "start" and not s then
        b:Event_StartHorde()
        stats.started = stats.started + 1
        log.info("horde: the guest started the horde at " .. id)
    elseif what == "stop" and s and c then
        b:Event_StopHorde()
        stats.stopped = stats.stopped + 1
        log.info("horde: the guest stopped the horde at " .. id)
    else
        stats.ignored = stats.ignored + 1
        log.info(string.format("horde: guest %s at %s ignored (started %s, can stop %s)", what, id, tostring(s), tostring(c)))
    end
    note(b)
end

-- The beacon's countdown / wave / done messages (CreateNotificationUI with the beacon as context).
local function on_notification(self, Text, Icon, Color, Duration, Flag, Ctx)
    if role ~= "host" or not on() then return end
    local ctx = Ctx and util.obj(Ctx)
    if not ctx or util.class_name(ctx) ~= CLS then return end
    local text
    pcall(function() text = Text:get():ToString() end)
    if not text or text == "" then return end
    local ok, id = pcall(id_of, ctx)
    channel:send("T " .. (ok and id or "?") .. " " .. text:gsub("\n", " "))
end

-- A wave started by the guest's beacon (or nearer the guest) should come for the guest.
local function on_lock_target(self)
    if role ~= "host" or retargeting or not on() or next(active) == nil then return end
    local comp = util.obj(self)
    local g = ghost.get()
    if not (comp and g) then return end
    local z, zl, pl
    pcall(function() z = comp:GetOwner() end)
    if not util.valid(z) then return end
    pcall(function() zl = util.vec(z:K2_GetActorLocation()) end)
    local gl = ghost.location()
    local p = game.player()
    if util.valid(p) then pcall(function() pl = util.vec(p:K2_GetActorLocation()) end) end
    if not (zl and gl and pl) then return end
    for _, h in pairs(active) do
        local bl = h.loc
        if bl and util.dist(zl, bl) < WAVE_RADIUS then
            if util.dist(gl, bl) < util.dist(pl, bl) then
                retargeting = true
                pcall(function() comp:SetBB_LockOnTarget(gl) end)
                retargeting = false
                stats.retargeted = stats.retargeted + 1
            end
            return
        end
    end
end

-- Guest -----------------------------------------------------------------------------------------

local function show(b, id, s, c)
    local was = shown[id]
    if was and was.s == s and was.c == c and not was.pending then return end
    local in_chain = local_at[id] ~= nil and now - local_at[id] < LOCAL_CHAIN_S
    if not in_chain then local_at[id] = nil end
    pcall(function()
        b["HordeStarted?"] = s and not in_chain
        b["CanStopHorde?"] = c
    end)
    if not was or was.s ~= s then pcall(function() b:Event_DishMovement(s) end) end
    shown[id] = { s = s, c = c, pending = in_chain and s or nil }
end

-- The host's list may not have the answer to a press yet: leave that beacon alone for a moment.
local function answering(id) return pressed_at[id] ~= nil and now - pressed_at[id] < MUTE_S end

local function take_state(body)
    local want = {}
    for line in body:gmatch("[^\n]+") do
        local id, c = line:match("^(%S+) (%d)$")
        if id then want[id] = c == "1" end
    end
    for id, c in pairs(want) do
        local b = not answering(id) and util.find_by_id(id, 100)
        if b then show(b, id, true, c) end
    end
    for id, st in pairs(shown) do
        if want[id] == nil and st.s and not answering(id) then
            local b = util.find_by_id(id, 100)
            if b then show(b, id, false, false) else shown[id] = nil end
        end
    end
end

local function guest_pressed(self, what)
    if role ~= "guest" or not on() then return end
    local b = util.obj(self)
    if not b then return end
    local ok, id = pcall(id_of, b)
    if not ok then return end
    if what == "start" then
        pcall(function() b["HordeStarted?"] = false end)   -- the host's beacon runs the horde
        local_at[id] = now
        shown[id] = { s = true, c = true, pending = true }    -- dish is turning; the host's answer corrects it
    else
        shown[id] = { s = false, c = false }
    end
    mute_until, pressed_at[id] = now + MUTE_S, now
    channel:send("I " .. id .. " " .. what)
    log.info("horde: pressed beacon " .. id .. " (" .. what .. ") - asking the host")
end

local function on_text(p)
    local id, text = p:match("^T (%S+) (.+)$")
    if not text or now < mute_until then return end
    local pl = game.player()
    if not util.valid(pl) then return end
    stats.texts = stats.texts + 1
    pcall(function() pl:CreateNotificationUI(FText(text), nil, { R = 1.0, G = 0.0, B = 0.0, A = 1.0 }, 2.0) end)
end

-- Hooks + tick ----------------------------------------------------------------------------------

local start_fn = function(self)
    if role == "host" then util.safe(on_host_event, "horde.start", self) else util.safe(guest_pressed, "horde.press", self, "start") end
end
-- In case this hook ran before the event: the flag the event just set is cleared again after it.
local start_post_fn = function(self)
    if role ~= "guest" or not on() then return end
    local b = util.obj(self)
    if b then pcall(function() b["HordeStarted?"] = false end) end
end
local stop_fn = function(self)
    if role == "host" then util.safe(on_host_event, "horde.stop", self) else util.safe(guest_pressed, "horde.press", self, "stop") end
end
local wave_fn = function(self) util.safe(on_host_event, "horde.wave", self) end
local text_fn = function(...) util.safe(on_notification, "horde.text", ...) end
local lock_fn = function(self) util.safe(on_lock_target, "horde.lock", self) end
local finished_fn = function(self) util.safe(on_finished, "horde.finished", self) end

function horde.tick(dt)
    if role ~= "host" and role ~= "guest" then return end
    now = now + dt
    if not on() then
        if next(shown) or next(active) then shown, active, local_at, pressed_at, last_blob, guest_body = {}, {}, {}, {}, nil, "" end
        return
    end
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 1.0
        util.ensure_hook(BEACON .. ":Event_StartHorde", start_fn, start_post_fn)
        util.ensure_hook(BEACON .. ":Event_StopHorde", stop_fn)
        if role == "host" then
            util.ensure_hook(BEACON .. ":Event_NextWave", wave_fn)
            util.ensure_hook(BEACON .. ":FinalWaveDefeated?", wave_fn)
            util.ensure_hook(GFL .. ":CreateNotificationUI", text_fn)
            util.ensure_hook(SAI .. ":SetBB_LockOnTarget", lock_fn)
            util.ensure_hook(BEACON .. ":SpawnRewards", finished_fn)
        end
    end
    if role == "host" then
        channel:pump(function(p) if p:sub(1, 2) == "I " then util.safe(on_request, "horde.request", p) end end)
        state_in = state_in - dt
        if state_in <= 0 then state_in = STATE_EVERY; put_state() end
    else
        channel:pump(function(p) if p:sub(1, 2) == "T " then util.safe(on_text, "horde.text_in", p) end end)
        local body = link.get_blob("hordes")
        if body then guest_body = body; state_in = 0 end
        state_in = state_in - dt
        if state_in <= 0 then
            state_in = STATE_EVERY
            if guest_body ~= "" or next(shown) then util.safe(take_state, "horde.state", guest_body) end
        end
    end
end

-- Host: is a horde running at a beacon within r of loc? (the P8 load split keeps hordes on the host)
function horde.active_near(loc, r)
    if role ~= "host" or not loc then return false end
    for _, h in pairs(active) do
        if h.loc and util.dist(loc, h.loc) < r then return true end
    end
    return false
end

function horde.status()
    return string.format("horde: guest presses %d (started %d, stopped %d, ignored %d), texts shown %d, waves retargeted %d, missing %d",
        stats.requests, stats.started, stats.stopped, stats.ignored, stats.texts, stats.retargeted, stats.missing)
end

local function forget_world() active, shown, local_at, pressed_at, last_blob, guest_body, finished = {}, {}, {}, {}, nil, "", {} end
function horde.init(c, r, s, sw)
    cfg, role, session = c, r, s
    if sw then same_world = sw end
    game.on_world_reset(forget_world)
end

return horde
