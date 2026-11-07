-- Door code locks (user 2026-10-30): a player-built door's hover menu gets a "Lock door" row; it opens a keypad
-- where the player sets a 4-digit code. The code covers every door that player owns. Another player can't use those
-- doors (no open, close, pick up or move) until they type the code once; from then on all of that owner's doors
-- open for them.
-- Owner = who placed the door while co-op ran (builds.lua tells us), else whoever locks it first (doors built
-- before this, or alone). The menu row is our own widget, as for bed names (bedtags.lua): the game's options are a
-- TMap that Lua can't add to. A locked door's interaction is stopped in BP_JigHelperComp:TryInteract (hooked before
-- it runs): the option index is parked far past the end, where TryInteract runs no option at all.
-- The keypad is the game's own KeypadUI (the keypad door's) when that class is loaded, else the mod's text box.
-- The host keeps the locks of its world (mirror_coop_door_locks.txt, in the Realm while one is hosted) and sends
-- them to the guests (doors.lua blob "locks"); a guest sends what it does as numbered lines (blob "lock_g").
-- Codes are kept and sent only as a hash of owner + code. Four digits are no real secret: this keeps honest
-- players out of each other's bases, not a modder.
-- User 2026-10-31: containers lock the same way (one code per owner covers their doors and containers); the owner's
-- own door gets a "Remove access" row that takes every other player's access away (then change the code); and a
-- player without an owner's code can't build, move or pick up buildings near that owner's locks (ZONE): their
-- Pickup / Move options run nothing there, and the build ghost stays red (BuildingComponent:BuildCycle, hooked after
-- it ran, sets CanBuild false: the game's place click checks it).

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local notify = require("mirror.notify")
local names = require("mirror.names")
local fs = require("mirror.fs")
local bedtags = require("mirror.bedtags")

local doorlock = {}

local DOORS = { Buildable_WoodenDoor_C = true, Buildable_WoodenDoor2_C = true, Buildable_WoodenGate_C = true,
                Buildable_BunkerDoor_C = true, Buildable_BarricadedMetalDoor_C = true }
-- BuildableMaster_Container's children in build 26303910 (unlisted ones are found by IsA)
local CONTAINERS = { BuildableMaster_Container_C = true, Buildable_AmmoCrate_C = true, Buildable_ClothingCupboard_C = true,
                     Buildable_Dresser_C = true, Buildable_FridgeContainer_C = true, Buildable_GunLocker_C = true,
                     Buildable_MilitaryCrate_C = true, Buildable_MilitarySupplyCrates_C = true, Buildable_MoneySafe_C = true,
                     Buildable_OldChest_C = true, Buildable_ShippingContainer_C = true, Buildable_StorageCrate_C = true,
                     Buildable_StorageCrate2_C = true, Buildable_StorageCrate3_C = true, Buildable_StorageCrate4_C = true,
                     Buildable_ToolsCabinet_C = true }
local CONTAINER = "/Game/Blueprints/BuildingSystem/Actors/Containers/BuildableMaster_Container.BuildableMaster_Container_C"
local BUILDABLE = "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Buildable_MASTER_C"
local BC = "/Game/Blueprints/Components/BuildingComponent.BuildingComponent_C"
local ZONE = 3000         -- cm around a coded owner's door or container where only they and their code's players build
local HELPER = "/Game/JigSInventory/Jigsaw/Components/BP_JigHelperComp.BP_JigHelperComp_C"
local KEYPAD = "/Game/UI/Widgets/Other/KeypadUI.KeypadUI_C"
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"
local FILE = "mirror_coop_door_locks.txt"
local MATCH = 50          -- cm between a door in the file and the door in the world
local DIGITS = 4
local MAX_DOORS = 2000
local MAX_OPS = 60
-- KeypadUI checks the typed code itself once it is one digit longer than its AcceptedCode: a 10-digit number keeps
-- that check from ever running before we take the 4 digits
local NEVER = 2147483647
local LABEL = { free = "Lock door", unset = "Set door code", mine = "Change door code", locked = "Enter code" }
local CLABEL = { free = "Lock container", unset = "Set lock code", mine = "Change lock code", locked = "Enter code" }
local REVOKE = "Remove access"

local data_file = nil      -- fn -> path of this world's file (session.data_file)
local local_s, local_of = nil, nil   -- the store this game owns (host, or alone) and the file it came from
local remote_text, remote_ack = nil, 0   -- the host's locks while joined as a guest, and the last op it took
local view = nil           -- what a guest goes by: the host's locks + its own ops the host hasn't taken yet
local gen = 0              -- bumps on every change of the store this game owns (doors.lua re-sends then)
local ops, op_n, ops_gen = {}, 0, 0
local run_id = tostring(math.random(100000, 999999)) .. tostring(os.time() % 100000)
local my_id, my_name = nil, nil
local hook_in, look_in, frame = 0.0, 0.0, -1
local cur = nil            -- { w, actor, label, picked, last, titled }
local cycled_down, cycled_up, interacted = false, false, false
local cycle_dir = 1        -- the last scroll through a hover menu: 1 down, -1 up
local told_at = -100.0     -- os.clock of the last "someone's base" notice
local want = nil           -- what to do next tick: { mode = "set"|"enter"|"claim", owner, loc }
local pad = nil            -- the open keypad: { w, mode, owner, loc }

-- ---------------------------------------------------------------- what an actor is

local kinds = {}           -- class name -> "door" | "container" | "build" | false
local function kind_of_name(cname)
    if not cname then return nil end
    if DOORS[cname] then return "door" end
    if CONTAINERS[cname] then return "container" end
    local k = kinds[cname]
    if k == "container" then return k end
    return nil
end

-- "door" / "container" (lockable), "build" (any other player building), or nil
local function kind_of(actor)
    local cname = util.class_name(actor)
    if not cname then return nil end
    local k = kind_of_name(cname)
    if k then return k end
    k = kinds[cname]
    if k == nil then
        k = false
        local cc, bc = StaticFindObject(CONTAINER), StaticFindObject(BUILDABLE)
        pcall(function() if util.valid(cc) and actor:IsA(cc) == true then k = "container" end end)
        if not k then pcall(function() if util.valid(bc) and actor:IsA(bc) == true then k = "build" end end) end
        kinds[cname] = k
    end
    return k or nil
end
local function lockable(k) return k == "door" or k == "container" end

-- ---------------------------------------------------------------- store

local function new_store() return { codes = {}, doors = {}, access = {}, names = {} } end

-- FNV-1a over owner:code, 8 hex digits
local function hash(owner, code)
    local h, s = 2166136261, owner .. ":" .. code
    for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff end
    return string.format("%08x", h)
end
doorlock.hash = hash

local function parse(text)
    local s = new_store()
    for line in (text or ""):gmatch("[^\r\n]+") do
        local k, a, b, c, d = line:match("^(%a) (%S+) ?(%S*) ?(%S*) ?(%S*)$")
        if k == "C" and b:match("^%x+$") then s.codes[a] = b
        elseif k == "D" and tonumber(a) and tonumber(b) and tonumber(c) and d ~= "" then
            s.doors[#s.doors + 1] = { X = tonumber(a), Y = tonumber(b), Z = tonumber(c), owner = d }
        elseif k == "A" and b ~= "" then s.access[a] = s.access[a] or {}; s.access[a][b] = true
        elseif k == "N" and b ~= "" then s.names[a] = names.clean(names.decode(b)) end
    end
    return s
end

local function dump(s)
    local out = {}
    for o, h in pairs(s.codes) do out[#out + 1] = "C " .. o .. " " .. h end
    for o, t in pairs(s.access) do for p in pairs(t) do out[#out + 1] = "A " .. o .. " " .. p end end
    for id, n in pairs(s.names) do out[#out + 1] = "N " .. id .. " " .. names.encode(n) end
    table.sort(out)
    for _, d in ipairs(s.doors) do out[#out + 1] = string.format("D %.0f %.0f %.0f %s", d.X, d.Y, d.Z, d.owner) end
    return table.concat(out, "\n")
end

local function door_at(s, loc)
    local best, bi, bd = nil, nil, MATCH
    for i, d in ipairs(s.doors) do
        local dist = util.dist(d, loc)
        if dist <= bd then best, bi, bd = d, i, dist end
    end
    return best, bi
end

local function remove_at(s, loc)
    local n = 0
    for i = #s.doors, 1, -1 do if util.dist(s.doors[i], loc) <= MATCH then table.remove(s.doors, i); n = n + 1 end end
    return n > 0
end

local function num(v) return tonumber(v) end
local function at(x, y, z) x, y, z = num(x), num(y), num(z); return x and y and z and { X = x, Y = y, Z = z } or nil end

-- One change. Returns true when the store changed. Every op can be applied twice without harm.
local function apply_op(s, op, a, b, c, d, e)
    if op == "place" or op == "claim" then        -- who x y z: placed (always theirs) / locked a door nobody owns
        local loc = at(b, c, d)
        if not (a and loc) then return false end
        local cur_d = door_at(s, loc)
        if cur_d and (cur_d.owner == a or op == "claim") then return false end
        -- (full: new doors go unowned - dropping the oldest would free a real owner's door for anyone to claim)
        if not cur_d and #s.doors >= MAX_DOORS then return false end
        if cur_d then remove_at(s, loc) end
        s.doors[#s.doors + 1] = { X = loc.X, Y = loc.Y, Z = loc.Z, owner = a }
        return true
    elseif op == "code" then                     -- who hash
        if not (a and b and b:match("^%x+$")) or s.codes[a] == b then return false end
        s.codes[a] = b
        return true
    elseif op == "grant" then                    -- owner who hash: who typed owner's code
        if not (a and b and c) or s.codes[a] ~= c then return false end
        s.access[a] = s.access[a] or {}
        if s.access[a][b] then return false end
        s.access[a][b] = true
        return true
    elseif op == "revoke" then                   -- owner: every other player's access to owner's locks goes
        if not (a and s.access[a] and next(s.access[a])) then return false end
        s.access[a] = nil
        return true
    elseif op == "name" then                     -- who encoded-name
        local n = b and names.clean(names.decode(b))
        if not (a and n and n ~= "") or s.names[a] == n then return false end
        s.names[a] = n
        return true
    end
    return false
end
doorlock._apply_op = apply_op

local function path() return data_file and data_file() end

local function own_store()
    local p = path()
    if local_s and local_of == p then return local_s end
    local_s, local_of = parse(p and fs.read(p) or ""), p
    gen = gen + 1
    return local_s
end

local function save()
    gen = gen + 1
    local p = path()
    if p then fs.write(p, dump(local_s) .. "\n") end
end

local function rebuild_view()
    if not remote_text then view = nil; return end
    view = parse(remote_text)
    for _, o in ipairs(ops) do
        if o.n > remote_ack then apply_op(view, table.unpack(o.args)) end
    end
end

local function store() return view or own_store() end
local function authority() return remote_text == nil end

-- ---------------------------------------------------------------- who am I

-- Me = the id kept in a file of this PC (not the world's: a Realm changes hands); the first time, my Steam id (the
-- bridge's lobby file), or a random one when the lobby isn't read yet (the test kit: one per role). Once kept it never
-- changes: doors and a code already filed under it would turn into someone else's, locked against their own builder.
local id_file = nil        -- fn -> path
local function me()
    if my_id then return my_id end
    local l
    pcall(function() l = require("mirror.link").lobby() end)
    local id = l and l.id and tostring(l.id):match("^%d+$")
    if l and l.name and l.name ~= "" then my_name = l.name end
    local p
    pcall(function() p = id_file and id_file() end)
    local kept = p and (fs.read(p) or ""):match("^(%w+)")
    id = kept or id or ("p" .. tostring(math.random(10000000, 99999999)))
    if p and id ~= kept then fs.write(p, id .. "\n") end
    my_id = id
    return id
end
doorlock.me = me

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
    me()
    if my_name and store().names[my_id] ~= names.clean(my_name) then act("name", my_id, names.encode(names.clean(my_name))) end
end

-- ---------------------------------------------------------------- what a door is to me

-- "free" (nobody's), "unset" (mine, no code yet), "mine", "open" (theirs, no code), "access" (theirs, I typed it),
-- "locked" (theirs and I may not use it); and the owner
local function state_at(loc)
    local s = store()
    local d = loc and door_at(s, loc)
    if not d then return "free" end
    local id = me()
    if d.owner == id then return s.codes[id] and "mine" or "unset", d.owner end
    if not s.codes[d.owner] then return "open", d.owner end
    if s.access[d.owner] and s.access[d.owner][id] then return "access", d.owner end
    return "locked", d.owner
end
doorlock.state_at = state_at

local function owner_name(owner) return (owner and store().names[owner]) or "another player" end

-- How many other players have typed my code.
local function access_count()
    local t, n = store().access[me()], 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- a lock of a player with a code I haven't typed
local function guards(s, d, id)
    return d.owner ~= id and s.codes[d.owner] and not (s.access[d.owner] and s.access[d.owner][id])
end

-- My locks that stand outside every base I may not build in. Only these keep a spot next to them mine: a lock set
-- down just past a base, then the next one nearer, and so on, doesn't walk me into it (Sentinel R5 2026-10-31).
local free_memo = { key = nil, list = nil }
local function my_free_locks(s, id)
    local key = string.format("%s|%d|%d", tostring(s), gen, ops_gen)
    if free_memo.key == key then return free_memo.list end
    local list = {}
    for _, d in ipairs(s.doors) do
        if d.owner == id then
            local inside = false
            for _, o in ipairs(s.doors) do
                if guards(s, o, id) and util.dist(o, d) <= ZONE then inside = true; break end
            end
            if not inside then list[#list + 1] = d end
        end
    end
    free_memo.key, free_memo.list = key, list
    return list
end

-- The owner whose base loc is in for me: a lock of a player with a code, whose code I haven't typed, within ZONE,
-- and nearer than any lock of mine outside their base (a base next to theirs stays mine to build in). nil = I may.
local guard_memo = { key = nil, owner = nil }
local function guard_at(loc)
    if not loc then return nil end
    local s, id = store(), me()
    local key = string.format("%s|%d|%d|%d,%d,%d", tostring(s), gen, ops_gen, loc.X // 50, loc.Y // 50, loc.Z // 50)
    if guard_memo.key == key then return guard_memo.owner end
    local best, bd = nil, ZONE
    for _, d in ipairs(s.doors) do
        if guards(s, d, id) then
            local dist = util.dist(d, loc)
            if dist <= bd then best, bd = d.owner, dist end
        end
    end
    if best then
        for _, d in ipairs(my_free_locks(s, id)) do
            if util.dist(d, loc) <= bd then best = nil; break end
        end
    end
    guard_memo.key, guard_memo.owner = key, best
    return best
end
doorlock.guard_at = guard_at

-- anyone's code I haven't typed in this world (nothing to guard otherwise)
local function anything_guarded()
    local s, id = store(), me()
    for owner in pairs(s.codes) do
        if owner ~= id and not (s.access[owner] and s.access[owner][id]) then return true end
    end
    return false
end

-- A lock that guards against me within reach: a press only lands on a piece within ZONE of one, so away from other
-- players' bases the per-frame guard (the game's trace, the option list) doesn't run. Rechecked every NEAR_EVERY s
-- and whenever the locks change; REACH covers the interact reach and a sprint between two checks.
local REACH, NEAR_EVERY = 1500, 0.25
local near = { left = 0, s = nil, gen = nil, ops = nil, val = false }
local function near_guarded(dt)
    local s = store()
    near.left = near.left - (dt or 0)
    if near.left > 0 and near.s == s and near.gen == gen and near.ops == ops_gen then return near.val end
    near.left, near.s, near.gen, near.ops, near.val = NEAR_EVERY, s, gen, ops_gen, false
    if not anything_guarded() then return false end
    local p
    pcall(function() p = util.vec(game.player():K2_GetActorLocation()) end)
    if not p then near.val = true; return true end     -- (no spot to go by: guard as if near)
    local id = me()
    for _, d in ipairs(s.doors) do
        if guards(s, d, id) and util.dist(d, p) <= ZONE + REACH then near.val = true; break end
    end
    return near.val
end

local function tell_guarded(owner)
    local now = os.clock()
    if now - told_at < 3.0 then return end
    told_at = now
    notify.show(owner_name(owner) .. "'s base - type their code at one of their doors to build, move or pick up here.",
        "warn", "doorlock")
end

-- ---------------------------------------------------------------- calls from builds.lua / doors.lua

-- The class of the door or container I just placed at loc (da = its data asset path). The data asset's
-- BuildActorClass doesn't read as an object in the game: kit 2026-10-31, util.valid refused it (so placed() got nil
-- and no door became its builder's), and GetFName on it crashed the host.
function doorlock.class_at(loc, da)
    if not loc then return nil end
    local set = (da or ""):find("/DoorsAndGates/", 1, true) and DOORS or (da or ""):find("/Storage/", 1, true) and CONTAINERS
    if not set then return nil end
    for cname in pairs(set) do
        for _, a in ipairs(util.all_of(cname, 0)) do
            local l
            pcall(function() l = util.vec(a:K2_GetActorLocation()) end)
            if l and util.dist(l, loc) < 100 then return cname end
        end
    end
    return nil
end

-- I placed a building: a door or container becomes mine (cls = its actor class name)
function doorlock.placed(cls, loc)
    local k = kind_of_name(cls)
    if not (lockable(k) and loc) then return end
    act("place", me(), string.format("%.0f", loc.X), string.format("%.0f", loc.Y), string.format("%.0f", loc.Z))
    say_name()
    log.info(string.format("doorlock: placed a %s at %.0f %.0f %.0f - it's mine", k, loc.X, loc.Y, loc.Z))
end

-- A building went or moved (mine or the other player's); only the game that keeps the locks follows it.
function doorlock.gone(loc)
    if not (loc and authority()) then return end
    if remove_at(own_store(), loc) then save() end
end
function doorlock.moved(from, to)
    if not (from and to and authority()) then return end
    local s = own_store()
    local d = door_at(s, from)
    if not d then return end
    d.X, d.Y, d.Z = to.X, to.Y, to.Z
    save()
end
-- builds.lua's ids are "Class@x,y,z" in 10 cm steps
function doorlock.loc_of_id(id)
    local x, y, z = tostring(id):match("@(%-?%d+),(%-?%d+),(%-?%d+)$")
    return x and { X = tonumber(x) * 10, Y = tonumber(y) * 10, Z = tonumber(z) * 10 } or nil
end

-- host side: what goes to a guest (ack = the last of that guest's ops taken, run = the guest game they came from:
-- another game on the link must not drop its own unsent changes on an ack meant for the one before)
function doorlock.gen() own_store(); return gen end
function doorlock.dump(ack, run)
    return "ack " .. tostring(ack or 0) .. (run and (" " .. run) or "") .. "\n" .. dump(own_store())
end

-- What a guest may not do even as itself: build over another player's door (that would make it theirs), or own more
-- than its share of the list.
local function guest_may(s, w, who)
    if w[1] ~= "place" and w[1] ~= "claim" then return true end
    local loc = at(w[3], w[4], w[5])
    local d = loc and door_at(s, loc)
    if d and d.owner ~= who then return false end
    local n = 0
    for _, e in ipairs(s.doors) do if e.owner == who then n = n + 1 end end
    return d ~= nil or n < MAX_DOORS / 4
end

-- host side: a guest's ops blob -> applied; seen = { run, n, who } kept per guest link (new on every connect: one
-- player per connection, whatever run it names). Returns the last op taken.
function doorlock.take_ops(text, seen)
    local run = (text or ""):match("^run (%S+)")
    if not run then return seen.n or 0 end
    -- (another guest game: its numbers start over - it is still the player this connection began as)
    if seen.run ~= run then seen.run, seen.n = run, 0 end
    local s, changed = own_store(), false
    for line in text:gmatch("[^\n]+") do
        local n, rest = line:match("^(%d+) (.+)$")
        n = tonumber(n)
        if n and n > seen.n then
            seen.n = n
            local w = {}
            for v in rest:gmatch("%S+") do w[#w + 1] = v end
            -- (a guest acts as one player: never as me, and only as the id its first change named)
            local who = w[1] == "grant" and w[3] or w[2]
            local ok = (w[1] == "place" or w[1] == "claim" or w[1] == "code" or w[1] == "grant" or w[1] == "name"
                        or w[1] == "revoke")
                and who and who ~= me() and (seen.who == nil or seen.who == who) and guest_may(s, w, who)
            if ok then
                seen.who = who
                if apply_op(s, table.unpack(w)) then changed = true end
            else
                log.warn("doorlock: refused a guest's change: " .. rest:sub(1, 120))
            end
        end
    end
    if changed then save() end
    return seen.n
end

-- guest side: the last of my changes the host took, from its locks; what it took is in its locks now: no need to send
-- it again. Also read back at home: a change made just before leaving still goes to the host it was made for.
local function ack_of(text)
    local a, r = (text or ""):match("^ack (%d+) ?(%S*)")
    return (r == run_id or r == "") and tonumber(a) or 0
end
local function drop_taken(a)
    local n0 = #ops
    while ops[1] and ops[1].n <= a do table.remove(ops, 1) end
    if #ops ~= n0 then ops_gen = ops_gen + 1 end
end
function doorlock.take_ack(text) if text then drop_taken(ack_of(text)) end end

-- guest side: the host's locks (nil = not joined: back to this game's own)
function doorlock.take(text)
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
-- guest side: my changes the host hasn't taken yet (a guest gone home keeps the link until this is 0, like events)
function doorlock.unconfirmed() return #ops end
-- guest side: the host went - what it never took was for its world, not for the next host's
function doorlock.left()
    if #ops == 0 then return end
    ops = {}
    ops_gen = ops_gen + 1
    rebuild_view()
end
function doorlock.ops_gen() return ops_gen end
function doorlock.ops_text()
    local out = { "run " .. run_id }
    for _, o in ipairs(ops) do out[#out + 1] = o.n .. " " .. table.concat(o.args, " ") end
    return table.concat(out, "\n")
end

-- ---------------------------------------------------------------- keypad

local function release_input()
    local pc = game.controller()
    pcall(function() pc.Pawn:EnableInput(pc) end)
    pcall(function() util.cdo(WBL):SetInputMode_GameOnly(pc, false) end)
    pcall(function() pc.bShowMouseCursor = false end)
end

local function close_pad()
    local p = pad
    pad = nil
    if p and p.w then
        pcall(function() p.w:RemoveFromParent() end)
        release_input()
    end
end

local function finish(mode, owner, loc, code)
    code = tostring(code or ""):gsub("%D", "")
    if #code ~= DIGITS then
        if code ~= "" then notify.show("A door code has " .. DIGITS .. " digits.", "warn", "doorlock") end
        return
    end
    local id = me()
    if mode == "set" then
        act("code", id, hash(id, code))
        if loc and state_at(loc) == "free" then act("claim", id, string.format("%.0f", loc.X), string.format("%.0f", loc.Y), string.format("%.0f", loc.Z)) end
        say_name()
        notify.show("Lock code set to " .. code .. ". Your doors and containers open only for players who type it.", "good", "doorlock")
        log.info("doorlock: door code set")
        return
    end
    local s = store()
    if owner and s.codes[owner] == hash(owner, code) then
        act("grant", owner, id, s.codes[owner])
        say_name()
        notify.show("Code accepted - " .. owner_name(owner) .. "'s doors open for you now.", "good", "doorlock")
        log.info("doorlock: typed the right code for " .. owner_name(owner) .. "'s doors")
    else
        notify.show("Wrong code.", "bad", "doorlock")
        log.info("doorlock: wrong code for " .. owner_name(owner) .. "'s doors")
    end
end
doorlock._finish = finish

local function open_pad(mode, owner, loc)
    close_pad()
    local cls, wbl, pc = StaticFindObject(KEYPAD), util.cdo(WBL), game.controller()
    local w
    if util.valid(cls) and wbl and util.valid(pc) then
        pcall(function() w = wbl:Create(pc, cls, pc) end)
    end
    if util.valid(w) then
        pcall(function() w.AcceptedCode = NEVER end)
        pcall(function() w:AddToViewport(2) end)
        pcall(function() w.AcceptedCode = NEVER end)   -- (its Construct reads a door's code when it has one)
        pcall(function() pc.Pawn:DisableInput(pc) end)
        pcall(function() wbl:SetInputMode_GameAndUIEx(pc, w, 2, false, false) end)
        pcall(function() pc.bShowMouseCursor = true end)
        pad = { w = w, mode = mode, owner = owner, loc = loc }
        notify.show(mode == "set" and "Type a " .. DIGITS .. "-digit code for your doors."
            or ("Type the code for " .. owner_name(owner) .. "'s doors."), "info", "doorlock")
        return
    end
    -- no keypad class loaded (it comes with the keypad door's map part): the mod's own box
    names.ask({ title = mode == "set" and "SET YOUR DOOR CODE" or "ENTER THE DOOR CODE",
                hint = DIGITS .. " digits", cursor = true, clear = false, ok = mode == "set" and "SET" or "UNLOCK",
                done = function(code) finish(mode, owner, loc, code) end })
end

local function poll_pad()
    local p = pad
    if not p then return end
    local shown = false
    pcall(function() shown = util.valid(p.w) and p.w:IsInViewport() end)
    if not shown then pad = nil; return end     -- Cancel / Esc: KeypadUI closed itself
    local code = ""
    pcall(function() code = p.w.CurrentCode:ToString() end)
    code = tostring(code or ""):gsub("%D", "")
    if #code >= DIGITS then
        close_pad()
        finish(p.mode, p.owner, p.loc, code:sub(1, DIGITS))
    end
end

-- ---------------------------------------------------------------- the hover menu

local function looking_at()
    local helper, actor, hud, w
    pcall(function() helper = game.player().BP_JigHelperComp end)
    if not util.valid(helper) then return nil end
    pcall(function() actor = helper.CurrentTracActor end)
    local k = kind_of(actor)
    if not lockable(k) then return nil end
    pcall(function() hud = game.controller().MyHUD end)
    pcall(function() w = hud.InteractWidget end)
    if not util.valid(w) then return nil end
    return helper, actor, w, k
end

local function loc_of(actor)
    local loc
    pcall(function() loc = util.vec(actor:K2_GetActorLocation()) end)
    return loc
end

-- our rows for a lock in state st: the lock row, and on my own coded lock "Remove access" while anyone has it
local function labels_for(st, k)
    local l = (k == "container" and CLABEL or LABEL)[st]
    if not l then return {} end
    if st == "mine" then
        local n = access_count()
        if n > 0 then return { l, string.format("%s (%d)", REVOKE, n) } end
    end
    return { l }
end

local function hover()
    local helper, actor, w, k = looking_at()
    if not helper then cur = nil; cycled_down, cycled_up, interacted = false, false, false; return end
    local vb
    pcall(function() vb = w.InteractOptions end)
    local loc = loc_of(actor)
    if not (util.valid(vb) and loc) then return end
    local rows = bedtags.rows
    local st, owner = state_at(loc)
    local labels = labels_for(st, k)
    local addr = util.addr(w)
    if not (cur and cur.w == addr and util.same(cur.actor, actor)) then
        cur = { w = addr, actor = actor, last = 0, picked = nil, labels = {} }
    end
    local have = rows.list(w, vb)
    local n, idx = rows.count(w.Options), 0
    pcall(function() idx = helper.CurrentInteractOptionIndex end)
    if cur.titled and st ~= "locked" then
        -- (the lock opened up for me: the game's own name is back)
        local was = cur.titled
        if type(was) == "string" and was ~= "" then pcall(function() w.ObjectName:SetText(FText(was)) end) end
        cur.titled = nil
    end
    if #labels == 0 then
        -- (a lock that just opened up for me: our rows go, the game's first option is back)
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
            local what = k == "container" and "container" or "door"
            pcall(function() w.ObjectName:SetText(FText(owner_name(owner) .. "'s " .. what .. " - locked")) end)
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
    if interacted and picked then
        if labels[picked]:sub(1, #REVOKE) == REVOKE then want = { mode = "revoke" }
        elseif st == "free" and store().codes[me()] then want = { mode = "claim", loc = loc }
        else want = { mode = st == "locked" and "enter" or "set", owner = owner, loc = loc } end
    end
    interacted = false
end

local cycle_fn = function(_, value)
    local v
    pcall(function() v = value:get() end)
    if v == false then cycled_down, cycle_dir = true, 1 elseif v == true then cycled_up, cycle_dir = true, -1 end
end

-- the texts of the helper's options (the game's map of tag -> text, in its key order: TryInteract picks by index)
local function option_labels(helper)
    local out = {}
    pcall(function() util.each(helper.CurrentInteractOptions, function(_, v) out[#out + 1] = v:get():ToString() end) end)
    return out
end
local function option_label(helper)
    local idx = 0
    pcall(function() idx = helper.CurrentInteractOptionIndex end)
    return option_labels(helper)[(idx or 0) + 1]
end

-- a building option that changes someone's base: pick it up, move it, take it down
local function build_op(label)
    local l = tostring(label or ""):lower():gsub("[%s%-]", "")
    return l:find("^pickup") ~= nil or l:find("^move") ~= nil or l:find("^dismantle") ~= nil or l:find("^demolish") ~= nil
end
doorlock._build_op = build_op

-- In front of every press, each frame. UE4SS runs a hook on a Blueprint function after the function (sleep.lua's
-- kit run 2026-10-31; Sentinel R5), so TryInteract's own hook comes after the option it ran. TryInteract traces from
-- the camera and uses the option index only when it hits CurrentTracActor, on anything else it runs Option1 (a
-- door's open); CurrentTracActor follows the camera only every 0.4 s (TraceToWorld). So the game's trace runs here
-- every frame, a locked door or container keeps its index past the end (an option key that isn't there runs
-- nothing), and in someone's base Pick up / Move are stepped over in the way the player scrolls, or parked.
local PARK = 64
local function guard_press(dt)
    if not near_guarded(dt) then return end
    local helper
    pcall(function() helper = game.player().BP_JigHelperComp end)
    if not util.valid(helper) then return end
    pcall(function() helper:TraceToWorld() end)
    local actor
    pcall(function() actor = helper.CurrentTracActor end)
    local k = kind_of(actor)
    if not k then return end
    local loc = loc_of(actor)
    if not loc then return end
    local st = lockable(k) and state_at(loc)
    if st == "mine" or st == "unset" then return end
    local idx = 0
    pcall(function() idx = helper.CurrentInteractOptionIndex end)
    if st == "locked" then
        local m = #option_labels(helper)
        if idx < m then pcall(function() helper.CurrentInteractOptionIndex = m end) end
        return
    end
    local owner = guard_at(loc)
    if not owner then return end
    local labels = option_labels(helper)
    if not build_op(labels[idx + 1]) then return end
    local m, to = #labels, PARK
    for step = 1, m - 1 do
        local j = (idx + step * cycle_dir) % m
        if not build_op(labels[j + 1]) then to = j; break end
    end
    pcall(function() helper.CurrentInteractOptionIndex = to end)
    tell_guarded(owner)
end
doorlock._guard_press = guard_press

-- The game's TryInteract has run (see guard_press). Where UE4SS runs this before the function it parks the press
-- outright; after it, the parked index stays for the next one.
local function on_try(self)
    interacted = true
    local helper = self:get()
    pcall(function() helper:TraceToWorld() end)
    local actor
    pcall(function() actor = helper.CurrentTracActor end)
    local k = kind_of(actor)
    if not k then return end
    local loc = loc_of(actor)
    if not loc then return end
    local st = lockable(k) and state_at(loc)
    if st == "locked" then pcall(function() helper.CurrentInteractOptionIndex = PARK end); return end
    -- someone's base: its buildings don't come up or move for a player without the owner's code (my own lock that
    -- stands there stays mine to take)
    if st == "mine" or st == "unset" or not build_op(option_label(helper)) then return end
    local owner = guard_at(loc)
    if not owner then return end
    pcall(function() helper.CurrentInteractOptionIndex = PARK end)
    tell_guarded(owner)
end
local try_fn = function(self) util.safe(on_try, "doorlock.try", self) end
doorlock._on_try = on_try

-- After the game's BuildCycle (it sets CanBuild from its own checks every frame of build mode): a spot in someone's
-- base turns the ghost red; the game's place click checks CanBuild, and moves end through the same click. A piece
-- moved out of someone's base stays red wherever it goes (its Move option should never have run: guard_press).
local function on_build_cycle(self)
    local comp = self:get()
    local on, loc = false, nil
    pcall(function() on = comp["BuildModeOn?"] == true end)
    if not on then return end
    pcall(function() loc = util.vec(comp.BuildTransform.Translation) end)
    local owner = loc and guard_at(loc)
    if not owner then
        local from
        pcall(function() if comp["ReplacingObject?"] == true then from = util.vec(comp.ReplacingActor:K2_GetActorLocation()) end end)
        owner = from and guard_at(from)
    end
    if not owner then return end
    pcall(function() comp:GiveBuildColour(false) end)
    tell_guarded(owner)
end
local build_fn = function(self) util.safe(on_build_cycle, "doorlock.build", self) end
doorlock._on_build_cycle = on_build_cycle

-- Called every frame by each link's builds.lua; runs once a frame.
function doorlock.tick(dt)
    local f = util.frame()
    if f == frame then return end
    frame = f
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 1.0
        util.ensure_hook(HELPER .. ":CycleOptions", cycle_fn)
        util.ensure_hook(HELPER .. ":TryInteract", try_fn)
        util.ensure_hook(BC .. ":BuildCycle", build_fn)
    end
    if pad then util.safe(poll_pad, "doorlock.pad"); return end
    util.safe(guard_press, "doorlock.guard", dt)
    if want then
        local w = want
        want = nil
        if w.mode == "claim" then
            act("claim", me(), string.format("%.0f", w.loc.X), string.format("%.0f", w.loc.Y), string.format("%.0f", w.loc.Z))
            say_name()
            notify.show("Locked with your code.", "good", "doorlock")
        elseif w.mode == "revoke" then
            act("revoke", me())
            notify.show("Access removed - nobody else can use your doors and containers or build at your base. "
                .. "Change your code before you give it out again.", "good", "doorlock")
            log.info("doorlock: removed every other player's access")
        else
            open_pad(w.mode, w.owner, w.loc)
        end
        return
    end
    look_in = look_in - dt
    if cur or cycled_down or interacted or look_in <= 0 then
        look_in = 0.1
        util.safe(hover, "doorlock.hover")
    end
end

function doorlock.status()
    local s = store()
    local n, mine = 0, 0
    for _, d in ipairs(s.doors) do n = n + 1; if d.owner == my_id then mine = mine + 1 end end
    return string.format("doorlock: %d doors with an owner (%d mine)%s%s", n, mine,
        s.codes[my_id or ""] and ", my code set" or "", view and ", from the host" or "")
end

-- session (its data_file follows a hosted Realm); id_path = fn -> where my id is kept
function doorlock.init(session, id_path)
    data_file = session and session.data_file and function() return session.data_file(FILE) end
    id_file = id_path or id_file
end

function doorlock.forget()
    close_pad()
    cur, want, cycled_down, cycled_up, interacted = nil, nil, false, false, false
    guard_memo.key, free_memo.key, cycle_dir = nil, nil, 1
    near.s, near.left = nil, 0
    local_s, local_of = nil, nil
end
game.on_world_reset(doorlock.forget)
-- every widget off the screen (a death): the keypad goes too, before the GC can free it under us
game.on_widgets_cleared(close_pad)

return doorlock
