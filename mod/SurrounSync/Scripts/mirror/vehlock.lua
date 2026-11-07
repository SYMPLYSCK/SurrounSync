-- Vehicle locks (user 2026-11-01): a car's hover menu gets a "Claim vehicle" row. The claimer owns it and gets
-- "Lock vehicle" / "Unlock vehicle" and "Unclaim vehicle". A locked car runs none of its options (get in, storage,
-- push, tow, refuel, repair) for anyone but its owner; an unlocked claimed car is everyone's to use.
-- Kept apart from the door locks (doorlock.lua): its own store, file, blobs and menu rows. Only the player id is
-- shared (doorlock.me), so a player is the same owner of doors and cars.
-- A car is known by the host's name of it (vehicles.peer_name_of: the same on every game for cars from the save),
-- plus its class and last spot: a claimed name missing after a load is taken over by the same-class car nearest its
-- last spot (REFIND), in case a load names cars anew.
-- The host keeps the claims of its world (mirror_coop_vehicle_locks.txt, in the Realm while one is hosted) and sends
-- them to the guests (doors.lua blob "vlocks"); a guest sends what it does as numbered lines (blob "vlock_g").
-- Each game guards its own player (as the door locks do): this keeps honest players out of each other's cars, not a
-- modder.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local notify = require("mirror.notify")
local names = require("mirror.names")
local fs = require("mirror.fs")
local bedtags = require("mirror.bedtags")

local vehlock = {}

local MASTER = "/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C"
local HELPER = "/Game/JigSInventory/Jigsaw/Components/BP_JigHelperComp.BP_JigHelperComp_C"
local FILE = "mirror_coop_vehicle_locks.txt"
local MAX_CARS = 400
local MAX_OPS = 60
local REFIND = 500         -- cm: how near its last spot a claimed car is found again under a new name
local MOVED = 1000         -- cm a claimed car goes before the host writes its new spot
local WATCH_EVERY = 10.0   -- s between the host's checks of where its claimed cars are
local SETTLE = 20.0        -- s in a world before a claimed name that isn't there is looked for elsewhere
local CLAIM, LOCK, UNLOCK, UNCLAIM, LOCKED = "Claim vehicle", "Lock vehicle", "Unlock vehicle", "Unclaim vehicle", "Locked"

local data_file = nil      -- fn -> path of this world's file (session.data_file)
local session = nil
local local_s, local_of = nil, nil   -- the store this game owns (host, or alone) and the file it came from
local remote_text, remote_ack = nil, 0   -- the host's claims while joined as a guest, and the last op it took
local view = nil           -- what a guest goes by: the host's claims + its own ops the host hasn't taken yet
local gen = 0              -- bumps on every change of the store this game owns (doors.lua re-sends then)
local ops, op_n, ops_gen = {}, 0, 0
local run_id = tostring(math.random(100000, 999999)) .. tostring(os.time() % 100000)
local hook_in, look_in, frame = 0.0, 0.0, -1
local cur = nil            -- { w, actor, labels, picked, last, titled }
local cycled_down, cycled_up, interacted = false, false, false
local want = nil           -- what to do next tick: { label, name, owner, car }
local watch_in, world_for, refound = 0.0, 0.0, {}

-- ---------------------------------------------------------------- store

local function new_store() return { cars = {}, names = {} } end

local function valid_name(n) return type(n) == "string" and n:match("^[%w_]+$") ~= nil end

local function parse(text)
    local s = new_store()
    for line in (text or ""):gmatch("[^\r\n]+") do
        local k, rest = line:match("^(%a) (.+)$")
        local w = {}
        for v in (rest or ""):gmatch("%S+") do w[#w + 1] = v end
        -- V name owner L|U class x y z
        if k == "V" and #w == 7 and valid_name(w[1]) and w[2] ~= "" and (w[3] == "L" or w[3] == "U") and valid_name(w[4])
                and tonumber(w[5]) and tonumber(w[6]) and tonumber(w[7]) then
            -- (w[1] name, w[2] owner, w[3] L|U, w[4] class, w[5..7] spot)
            s.cars[w[1]] = { owner = w[2], locked = w[3] == "L", cls = w[4],
                             X = tonumber(w[5]), Y = tonumber(w[6]), Z = tonumber(w[7]) }
        elseif k == "N" and #w == 2 then
            s.names[w[1]] = names.clean(names.decode(w[2]))
        end
    end
    return s
end

local function dump(s)
    local out = {}
    for n, c in pairs(s.cars) do
        out[#out + 1] = string.format("V %s %s %s %s %.0f %.0f %.0f", n, c.owner, c.locked and "L" or "U", c.cls, c.X, c.Y, c.Z)
    end
    for id, n in pairs(s.names) do out[#out + 1] = "N " .. id .. " " .. names.encode(n) end
    table.sort(out)
    return table.concat(out, "\n")
end

local function count(s, who)
    local n = 0
    for _, c in pairs(s.cars) do if who == nil or c.owner == who then n = n + 1 end end
    return n
end

-- One change. Returns true when the store changed. Every op can be applied twice without harm.
local function apply_op(s, op, who, name, cls, x, y, z)
    if not who or who == "" then return false end
    if op == "claim" then                         -- who name class x y z: a car nobody owns becomes who's
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if not (valid_name(name) and valid_name(cls) and x and y and z) or s.cars[name] then return false end
        -- (full: no new claims - dropping the oldest would free a real owner's car)
        if count(s) >= MAX_CARS then return false end
        s.cars[name] = { owner = who, locked = false, cls = cls, X = x, Y = y, Z = z }
        return true
    elseif op == "lock" or op == "unlock" then    -- who name: the owner locks / unlocks it
        local c = valid_name(name) and s.cars[name]
        if not c or c.owner ~= who or c.locked == (op == "lock") then return false end
        c.locked = op == "lock"
        return true
    elseif op == "unclaim" then                   -- who name: the owner lets it go
        local c = valid_name(name) and s.cars[name]
        if not c or c.owner ~= who then return false end
        s.cars[name] = nil
        return true
    elseif op == "name" then                      -- who encoded-name
        local n = name and names.clean(names.decode(name))
        if not (n and n ~= "") or s.names[who] == n then return false end
        s.names[who] = n
        return true
    end
    return false
end
vehlock._apply_op = apply_op

local function path() return data_file and data_file() end

local function own_store()
    local p = path()
    if local_s and local_of == p then return local_s end
    local_s, local_of = parse(p and fs.read(p) or ""), p
    gen = gen + 1
    return local_s
end

local function write_file()
    local p = path()
    if p then fs.write(p, dump(local_s) .. "\n") end
end
local function save() gen = gen + 1; write_file() end

local function rebuild_view()
    if not remote_text then view = nil; return end
    view = parse(remote_text)
    for _, o in ipairs(ops) do
        if o.n > remote_ack then apply_op(view, table.unpack(o.args)) end
    end
end

local function store() return view or own_store() end
local function authority() return remote_text == nil end

-- ---------------------------------------------------------------- who am I, which car is it

-- the same id the door locks file a player under (kept in a file of this PC)
local function me() return require("mirror.doorlock").me() end
vehlock.me = me

local function my_name()
    local l
    pcall(function() l = require("mirror.link").lobby() end)
    return l and l.name ~= "" and l.name or nil
end

-- a change made here: into the store this game owns, or (a guest) sent to the host and shown until it took it
local function act(op, ...)
    local args = { op, ... }
    if authority() then
        if apply_op(own_store(), op, ...) then save() end
        return
    end
    op_n = op_n + 1
    ops[#ops + 1] = { n = op_n, args = args }
    while #ops > MAX_OPS do table.remove(ops, 1) end
    ops_gen = ops_gen + 1
    rebuild_view()
end

local function say_name()
    local n = my_name()
    if n and store().names[me()] ~= names.clean(n) then act("name", me(), names.encode(names.clean(n))) end
end

local function vehicles() return require("mirror.vehicles") end

local car_kinds = {}       -- class name -> is a car
local master_cls = nil
local function is_car(a)
    local cname = util.class_name(a)
    if not cname then return false end
    local k = car_kinds[cname]
    if k ~= nil then return k end
    if not util.valid(master_cls) then master_cls = StaticFindObject(MASTER) end
    if not util.valid(master_cls) then return false end     -- (not known yet: asked again next time)
    k = false
    pcall(function() k = a:IsA(master_cls) == true end)
    car_kinds[cname] = k
    return k
end

-- the host's name of a car (what claims are filed under)
local function name_of(car)
    local n
    pcall(function() n = vehicles().peer_name_of(car) end)
    return valid_name(n) and n or nil
end

local function car_named(name)
    local c
    pcall(function() c = vehicles().car_named(name) end)
    return util.valid(c) and c or nil
end

local function loc_of(actor)
    local loc
    pcall(function() loc = util.vec(actor:K2_GetActorLocation()) end)
    return loc
end

-- Is another player in car (driving, towing it or riding in it)? Then it isn't free to claim.
-- guest: on the host, checking a guest's claim - the vehicles module of the link it came from (false: unknown). Then
-- the host's own seat counts as taken and that guest's own seat doesn't.
local function someone_in(car, name, guest)
    local hit = false
    pcall(function()
        local v = vehicles()
        if v.my_car and util.same(v.my_car(), car) then
            if guest ~= nil then hit = true end
            return   -- (me: I may claim the car I sit in)
        end
        require("mirror.peers").each("mirror.vehicles", function(m)
            if hit or (guest and m == guest) then return end
            if m.peer_drives and m.peer_drives(car) then hit = true end
            if m.rides_in and name and m.rides_in() == name then hit = true end
        end)
    end)
    return hit
end
vehlock._someone_in = someone_in

-- ---------------------------------------------------------------- what a car is to me

-- "free", "mine" (unlocked), "mine_locked", "open" (theirs, unlocked), "locked" (theirs, I may not use it); owner
local function state_of(name)
    local c = name and store().cars[name]
    if not c then return "free" end
    if c.owner == me() then return c.locked and "mine_locked" or "mine", c.owner end
    return c.locked and "locked" or "open", c.owner
end
vehlock.state_of = state_of

local function owner_name(owner) return (owner and store().names[owner]) or "another player" end

local function labels_for(st, car, name)
    if st == "free" then return someone_in(car, name) and {} or { CLAIM } end
    if st == "mine" then return { LOCK, UNCLAIM } end
    if st == "mine_locked" then return { UNLOCK, UNCLAIM } end
    if st == "locked" then return { LOCKED } end
    return {}
end

-- ---------------------------------------------------------------- host side

-- what goes to a guest (ack = the last of that guest's ops taken, run = the guest game they came from)
function vehlock.gen() own_store(); return gen end
function vehlock.dump(ack, run)
    return "ack " .. tostring(ack or 0) .. (run and (" " .. run) or "") .. "\n" .. dump(own_store())
end

-- What a guest may not do even as itself: claim a car this world doesn't have, one someone else sits in, or more
-- than its share of the list.
local function guest_may(s, w, who, sender)
    if w[1] ~= "claim" then return true end
    if count(s, who) >= MAX_CARS / 4 then return false end
    local car = car_named(w[3])
    return car ~= nil and not someone_in(car, w[3], sender or false)
end

-- host side: a guest's ops blob -> applied; seen = { run, n, who } kept per guest link (new on every connect: one
-- player per connection, whatever run it names). Returns the last op taken.
local OPS = { claim = true, lock = true, unlock = true, unclaim = true, name = true }
-- sender: the vehicles module of the link these came from (doors.lua), so the guest's own seat isn't "someone else's"
function vehlock.take_ops(text, seen, sender)
    local run = (text or ""):match("^run (%S+)")
    if not run then return seen.n or 0 end
    if seen.run ~= run then seen.run, seen.n = run, 0 end
    local s, changed = own_store(), false
    for line in text:gmatch("[^\n]+") do
        local n, rest = line:match("^(%d+) (.+)$")
        n = tonumber(n)
        if n and n > (seen.n or 0) then
            seen.n = n
            local w = {}
            for v in rest:gmatch("%S+") do w[#w + 1] = v end
            local who = w[2]
            -- (a guest acts as one player: never as me, and only as the id its first change named)
            local ok = OPS[w[1]] and who and who ~= me() and (seen.who == nil or seen.who == who) and guest_may(s, w, who, sender)
            if ok then
                seen.who = who
                if apply_op(s, table.unpack(w)) then changed = true end
            else
                log.warn("vehlock: refused a guest's change: " .. rest:sub(1, 120))
            end
        end
    end
    if changed then save() end
    return seen.n or 0
end

-- The host's claimed cars: their spots kept (a car is found again by them if a load names it anew), and a claimed
-- name this world doesn't have taken over by the same-class car nearest its last spot.
local function watch()
    local s = own_store()
    local spots, renamed = false, {}
    local taken = {}
    for n in pairs(s.cars) do taken[n] = true end
    for n, c in pairs(s.cars) do
        local car = car_named(n)
        if car then
            local l = loc_of(car)
            if l and util.dist(l, c) > MOVED then c.X, c.Y, c.Z = l.X, l.Y, l.Z; spots = true end
        elseif world_for >= SETTLE and not refound[n] then
            refound[n] = true
            local best, bd = nil, REFIND
            for _, a in ipairs(util.all_of(c.cls, 0)) do
                local an, l = name_of(a), loc_of(a)
                if an and not taken[an] and l then
                    local d = util.dist(l, c)
                    if d <= bd then best, bd = an, d end
                end
            end
            if best then
                taken[best] = true
                renamed[n] = best
                log.info(string.format("vehlock: claimed car %s is %s in this world now (%.0f cm from its last spot)", n, best, bd))
            end
        end
    end
    -- (after the walk: a new key added during pairs() is undefined in Lua)
    for old, new in pairs(renamed) do s.cars[new], s.cars[old] = s.cars[old], nil end
    if next(renamed) then save() elseif spots then write_file() end   -- (a spot alone: the guests don't need it)
end

-- ---------------------------------------------------------------- guest side

local function ack_of(text)
    local a, r = (text or ""):match("^ack (%d+) ?(%S*)")
    return (r == run_id or r == "") and tonumber(a) or 0
end
local function drop_taken(a)
    local n0 = #ops
    while ops[1] and ops[1].n <= a do table.remove(ops, 1) end
    if #ops ~= n0 then ops_gen = ops_gen + 1 end
end
function vehlock.take_ack(text) if text then drop_taken(ack_of(text)) end end

-- the host's claims (nil = not joined: back to this game's own)
function vehlock.take(text)
    if text == nil then
        if remote_text then remote_text, view, remote_ack = nil, nil, 0 end
        return
    end
    if text == remote_text then return end
    remote_text = text
    remote_ack = ack_of(text)
    drop_taken(remote_ack)
    rebuild_view()
    say_name()
end
function vehlock.unconfirmed() return #ops end
function vehlock.left()
    if #ops == 0 then return end
    ops = {}
    ops_gen = ops_gen + 1
    rebuild_view()
end
function vehlock.ops_gen() return ops_gen end
function vehlock.ops_text()
    local out = { "run " .. run_id }
    for _, o in ipairs(ops) do out[#out + 1] = o.n .. " " .. table.concat(o.args, " ") end
    return table.concat(out, "\n")
end

-- ---------------------------------------------------------------- the hover menu

local function looking_at()
    local helper, actor, hud, w
    pcall(function() helper = game.player().BP_JigHelperComp end)
    if not util.valid(helper) then return nil end
    pcall(function() actor = helper.CurrentTracActor end)
    if not (util.valid(actor) and is_car(actor)) then return nil end
    pcall(function() hud = game.controller().MyHUD end)
    pcall(function() w = hud.InteractWidget end)
    if not util.valid(w) then return nil end
    return helper, actor, w
end

local function hover()
    local helper, actor, w = looking_at()
    if not helper then cur = nil; cycled_down, cycled_up, interacted = false, false, false; return end
    local vb
    pcall(function() vb = w.InteractOptions end)
    local name = name_of(actor)
    if not (util.valid(vb) and name) then return end
    local rows = bedtags.rows
    local st, owner = state_of(name)
    local labels = labels_for(st, actor, name)
    local addr = util.addr(w)
    if not (cur and cur.w == addr and util.same(cur.actor, actor)) then
        cur = { w = addr, actor = actor, last = 0, picked = nil, labels = {} }
    end
    local have = rows.list(w, vb)
    local n, idx = rows.count(w.Options), 0
    pcall(function() idx = helper.CurrentInteractOptionIndex end)
    if cur.titled and st ~= "locked" then
        -- (the car opened up for me: the game's own name is back)
        local was = cur.titled
        if type(was) == "string" and was ~= "" then pcall(function() w.ObjectName:SetText(FText(was)) end) end
        cur.titled = nil
    end
    if #labels == 0 then
        if #have > 0 then
            for _, r in ipairs(have) do pcall(function() r:RemoveFromParent() end) end
            if idx >= n then pcall(function() helper.CurrentInteractOptionIndex = 0 end) end
        end
        cur.labels, cur.picked = {}, nil
        cycled_down, cycled_up, interacted = false, false, false
        return
    end
    if #have ~= #labels then
        for _, r in ipairs(have) do pcall(function() r:RemoveFromParent() end) end
        have = {}
        for i, l in ipairs(labels) do
            local r = rows.add(w, vb, l, i - 1)
            if not r then cur = nil; return end
            have[i] = r
        end
        cur.labels, cur.picked = {}, nil
        for i, l in ipairs(labels) do cur.labels[i] = l end
        if idx >= n + #labels then pcall(function() helper.CurrentInteractOptionIndex = n end); idx = n end
    end
    for i, l in ipairs(labels) do
        if cur.labels[i] ~= l then
            pcall(function() have[i].OptionName = FText(l) end)
            pcall(function() have[i]:UpdateText(FText(l)) end)
            cur.labels[i] = l
        end
    end
    local last_ours = n + #labels - 1
    if st == "locked" then
        -- nothing of the game's: our row is the only choice
        if idx ~= n then pcall(function() helper.CurrentInteractOptionIndex = n end); idx = n end
        if not cur.titled then
            local was
            pcall(function() was = w.ObjectName:GetText():ToString() end)
            pcall(function() w.ObjectName:SetText(FText(owner_name(owner) .. "'s vehicle - locked")) end)
            cur.titled = was or true
        end
    elseif cycled_down and n > 0 and idx == 0 and cur.last >= n - 1 and cur.last < last_ours then
        -- (the game wraps to 0 past its own last option: the step goes on into our rows)
        idx = cur.last + 1
        pcall(function() helper.CurrentInteractOptionIndex = idx end)
    elseif cycled_up and n > 0 and idx == 0 and cur.last > n and cur.last <= last_ours then
        -- (the game sends an index past its own options back to 0: up from our second row is our first)
        idx = cur.last - 1
        pcall(function() helper.CurrentInteractOptionIndex = idx end)
    end
    cycled_down, cycled_up = false, false
    local picked = (n > 0 or st == "locked") and idx >= n and idx <= last_ours and (idx - n + 1) or nil
    if picked ~= cur.picked then
        for i, r in ipairs(have) do if i ~= picked then rows.select(w, r, false) end end
        if picked then rows.select(w, have[picked], true) end
        cur.picked = picked
    end
    cur.last = idx
    if interacted and picked then want = { label = labels[picked], name = name, owner = owner, car = actor } end
    interacted = false
end

local cycle_fn = function(_, value)
    local v
    pcall(function() v = value:get() end)
    if v == false then cycled_down = true elseif v == true then cycled_up = true end
end

local function option_count(helper)
    local m = 0
    pcall(function() util.each(helper.CurrentInteractOptions, function() m = m + 1 end) end)
    return m
end

-- A car locked against me, in front of me now (the game's own trace: its hover follows the camera only every 0.4 s)
local function locked_ahead(helper)
    pcall(function() helper:TraceToWorld() end)
    local actor
    pcall(function() actor = helper.CurrentTracActor end)
    if not (util.valid(actor) and is_car(actor)) then return false end
    return (state_of(name_of(actor))) == "locked"
end

-- Someone else's locked car within reach: only then does the per-frame guard (the game's trace) run. Rechecked
-- every NEAR_EVERY s and whenever the claims change.
local REACH, NEAR_EVERY = 1500, 0.25
local near = { left = 0, s = nil, gen = nil, ops = nil, val = false }
local function near_locked(dt)
    local s = store()
    near.left = near.left - (dt or 0)
    if near.left > 0 and near.s == s and near.gen == gen and near.ops == ops_gen then return near.val end
    near.left, near.s, near.gen, near.ops, near.val = NEAR_EVERY, s, gen, ops_gen, false
    local id, p = me(), nil
    for n, c in pairs(s.cars) do
        if c.locked and c.owner ~= id then
            if not p then
                pcall(function() p = util.vec(game.player():K2_GetActorLocation()) end)
                if not p then near.val = true; return true end   -- (no spot to go by: guard as if near)
            end
            local car = car_named(n)
            local l = car and loc_of(car)
            if l and util.dist(l, p) <= REACH then near.val = true; return true end
        end
    end
    return false
end

-- In front of every press, each frame (UE4SS runs a Blueprint function's hook after it): a locked car keeps the
-- helper's index past the end of its options, where TryInteract runs none of them.
local PARK = 64
local function guard_press(dt)
    if not near_locked(dt) then return end
    local helper
    pcall(function() helper = game.player().BP_JigHelperComp end)
    if not util.valid(helper) or not locked_ahead(helper) then return end
    local idx, m = 0, option_count(helper)
    pcall(function() idx = helper.CurrentInteractOptionIndex end)
    if idx < m then pcall(function() helper.CurrentInteractOptionIndex = m end) end
end
vehlock._guard_press = guard_press

local function on_try(self)
    interacted = true
    local helper = self:get()
    if locked_ahead(helper) then pcall(function() helper.CurrentInteractOptionIndex = PARK end) end
end
local try_fn = function(self) util.safe(on_try, "vehlock.try", self) end

local function run_want(w)
    local st, owner = state_of(w.name)
    local id = me()
    if w.label == CLAIM then
        if st ~= "free" then return end
        if someone_in(w.car, w.name) then notify.show("Someone is in that vehicle.", "warn", "vehlock"); return end
        local l = loc_of(w.car)
        local cls = util.class_name(w.car)
        if not (l and valid_name(cls)) then return end
        if count(store(), id) >= MAX_CARS / 4 then notify.show("You have claimed too many vehicles.", "warn", "vehlock"); return end
        act("claim", id, w.name, cls, string.format("%.0f", l.X), string.format("%.0f", l.Y), string.format("%.0f", l.Z))
        say_name()
        notify.show("Vehicle claimed - lock it to keep everyone else out.", "good", "vehlock")
        log.info("vehlock: claimed " .. w.name)
    elseif w.label == LOCK and st == "mine" then
        act("lock", id, w.name)
        notify.show("Vehicle locked - only you can get in.", "good", "vehlock")
        log.info("vehlock: locked " .. w.name)
    elseif w.label == UNLOCK and st == "mine_locked" then
        act("unlock", id, w.name)
        notify.show("Vehicle unlocked.", "good", "vehlock")
        log.info("vehlock: unlocked " .. w.name)
    elseif w.label == UNCLAIM and (st == "mine" or st == "mine_locked") then
        act("unclaim", id, w.name)
        notify.show("Vehicle unclaimed - anyone can claim it now.", "info", "vehlock")
        log.info("vehlock: unclaimed " .. w.name)
    elseif w.label == LOCKED and st == "locked" then
        notify.show(owner_name(owner) .. "'s vehicle is locked.", "warn", "vehlock")
    end
end

-- Called every frame by each link's doors.lua; runs once a frame.
function vehlock.tick(dt)
    local f = util.frame()
    if f == frame then return end
    frame = f
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 1.0
        util.ensure_hook(HELPER .. ":CycleOptions", cycle_fn)
        util.ensure_hook(HELPER .. ":TryInteract", try_fn)
    end
    local inside = false
    pcall(function() inside = session and session.in_world() == true end)
    world_for = inside and world_for + dt or 0.0
    if authority() and inside then
        watch_in = watch_in - dt
        if watch_in <= 0 then watch_in = WATCH_EVERY; util.safe(watch, "vehlock.watch") end
    end
    util.safe(guard_press, "vehlock.guard", dt)
    if want then
        local w = want
        want = nil
        util.safe(run_want, "vehlock.want", w)
        return
    end
    look_in = look_in - dt
    if cur or cycled_down or cycled_up or interacted or look_in <= 0 then
        look_in = 0.1
        util.safe(hover, "vehlock.hover")
    end
end

function vehlock.status()
    local s = store()
    local n, mine, locked = 0, 0, 0
    local id = me()
    for _, c in pairs(s.cars) do
        n = n + 1
        if c.owner == id then mine = mine + 1 end
        if c.locked then locked = locked + 1 end
    end
    return string.format("vehlock: %d claimed vehicles (%d mine, %d locked)%s", n, mine, locked, view and ", from the host" or "")
end

-- session (its data_file follows a hosted Realm)
function vehlock.init(s)
    session = s
    data_file = s and s.data_file and function() return s.data_file(FILE) end
end

function vehlock.forget()
    cur, want, cycled_down, cycled_up, interacted = nil, nil, false, false, false
    near.s, near.left = nil, 0
    local_s, local_of = nil, nil
    watch_in, world_for, refound = 0.0, 0.0, {}
end
game.on_world_reset(vehlock.forget)

return vehlock
