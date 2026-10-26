-- Weapon lasers and flashlights on the other player's gun.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local link = require("mirror.link")
local look = require("mirror.look")

local tactical = {}

local DIR = "/Game/Inventory/Items/LocalAttachments/Tactical/"
local NAMES = { "BP_SmallTacticalLaserSightLocalAttachment", "BP_TacticalLaserLightComboLocalAttachment",
                "BP_SmallTacticalLightLocalAttachment", "BP_TacticalLightLocalAttachment" }
local SCAN_EVERY = 4.0

local cfg
local mine = {}
local copies = {}
local made = {}
local poll_in, scan_in, scan_idx = 0.0, 0.0, 0
local sent, applied, applied_gen = nil, nil, nil
local peer_blob = ""

local function path_of(obj)
    local p
    pcall(function() p = obj:GetFullName():match("^%S+ (.+)$") end)
    return p
end

local function class_path(short) return DIR .. short .. "." .. short .. "_C" end

local function is_ours(a)
    if not util.valid(a) or made[util.addr(a) or 0] then return false end
    local weapon, holder
    pcall(function() weapon = a:GetAttachParentActor() end)
    if not util.valid(weapon) then pcall(function() weapon = a:GetOwner() end) end
    pcall(function() holder = weapon:GetAttachParentActor() end)
    if not util.valid(holder) then pcall(function() holder = weapon:GetOwner() end) end
    return util.same(holder, game.player())
end

local function remember(a)
    if is_ours(a) then mine[util.addr(a) or 0] = a end
end

-- Each class has only some of the lights (the laser sight has no SpotLight, the
-- flashlights no PointLight); reading through a missing one gives a placeholder, not a number.
local function intensity(a, name)
    local comp, v
    pcall(function() comp = a[name] end)
    if not util.valid(comp) then return 0 end
    pcall(function() v = comp.Intensity end)
    return type(v) == "number" and v or 0
end

local function read_line(a)
    local spot, point, mesh, short = intensity(a, "SpotLight"), intensity(a, "PointLight"), nil, nil
    if spot <= 0 and point <= 0 then return nil end
    pcall(function() mesh = path_of(a.StaticMesh.StaticMesh) end)
    short = (util.class_name(a) or ""):gsub("_C$", "")
    if short == "" then return nil end
    local line = string.format("%s %s %.0f %.0f", short, mesh or "-", spot, point)
    if point > 0 then
        local out = {}
        local ok = pcall(function() a:LaserEndPoint(out) end)
        local v = ok and (out.Vector or (out.X and out)) or nil
        if v and (v.X ~= 0 or v.Y ~= 0 or v.Z ~= 0) then line = line .. string.format(" %.0f %.0f %.0f", v.X, v.Y, v.Z) end
    end
    return line, point > 0
end

local function send(dt)
    scan_in = scan_in - dt
    if scan_in <= 0 then
        scan_in = SCAN_EVERY / #NAMES
        scan_idx = scan_idx % #NAMES + 1
        for _, a in ipairs(util.instances(NAMES[scan_idx] .. "_C", class_path(NAMES[scan_idx]))) do remember(a) end
    end
    poll_in = poll_in - dt
    if poll_in > 0 then return end
    local lines, laser = {}, false
    for k, a in pairs(mine) do
        if not is_ours(a) then mine[k] = nil
        else
            local l, las = read_line(a)
            if l then lines[#lines + 1] = l; laser = laser or las end
        end
    end
    poll_in = laser and 0.1 or 0.25
    table.sort(lines)
    local blob = table.concat(lines, "\n")
    if blob ~= sent then sent = blob; link.put_blob("tactical", blob) end
end

local function destroy_copy(key)
    local c = copies[key]
    copies[key] = nil
    if c and util.valid(c.actor) then
        made[util.addr(c.actor) or 0] = nil
        pcall(function() c.actor:K2_DestroyActor() end)
    end
end

local function clear()
    for k in pairs(copies) do destroy_copy(k) end
    applied, applied_gen = nil, nil
end

local function gear_with(mesh)
    for _, c in ipairs(look.components() or {}) do
        local m
        pcall(function() m = path_of(c.StaticMesh) end)
        if m and m == mesh then return c end
    end
    return nil
end

-- The laser's frame: its location and axes (4 engine calls; only for a laser that is on).
local function frame(a)
    local l, fx, rx, ux
    local ok = pcall(function()
        l = a:K2_GetActorLocation(); fx = a:GetActorForwardVector(); rx = a:GetActorRightVector(); ux = a:GetActorUpVector()
    end)
    if not (ok and l and fx and rx and ux) then return nil end
    return l, fx, rx, ux
end
-- a world point as an offset along the laser's axes, and back
local function to_local(a, x, y, z)
    local l, fx, rx, ux = frame(a)
    if not l then return nil end
    local dx, dy, dz = x - l.X, y - l.Y, z - l.Z
    return { X = dx * fx.X + dy * fx.Y + dz * fx.Z, Y = dx * rx.X + dy * rx.Y + dz * rx.Z, Z = dx * ux.X + dy * ux.Y + dz * ux.Z }
end
local function to_world(a, rel, out)
    local l, fx, rx, ux = frame(a)
    if not l then return false end
    out.X = l.X + fx.X * rel.X + rx.X * rel.Y + ux.X * rel.Z
    out.Y = l.Y + fx.Y * rel.X + rx.Y * rel.Y + ux.Y * rel.Z
    out.Z = l.Z + fx.Z * rel.X + rx.Z * rel.Y + ux.Z * rel.Z
    return true
end

local function make_copy(short, mesh)
    local cls = StaticFindObject(class_path(short))
    local parent = gear_with(mesh)
    if not (util.valid(cls) and parent) then return nil end
    local a
    local ok, err = pcall(function()
        a = game.world():SpawnActor(cls, parent:K2_GetComponentLocation(), parent:K2_GetComponentRotation())
    end)
    if not (ok and util.valid(a)) then log.warn("tactical: couldn't make the other player's " .. short .. ": " .. tostring(err)); return nil end
    made[util.addr(a) or 0] = true
    pcall(function() a.StaticMesh:SetVisibility(false, false) end)
    pcall(function() a:K2_AttachToComponent(parent, FName(""), 2, 2, 2, false) end)
    log.info("tactical: the other player's " .. short .. " shown on their gun")
    return { actor = a, laser = false }
end

local function apply(blob)
    local want = {}
    for line in blob:gmatch("[^\n]+") do
        local short, mesh, spot, point, x, y, z = line:match("^(%S+) (%S+) (%S+) (%S+) ?(%S*) ?(%S*) ?(%S*)$")
        if short then
            local key = short .. " " .. mesh
            want[key] = true
            local c = copies[key] or make_copy(short, mesh)
            if c then
                copies[key] = c
                local a = c.actor
                pcall(function() a.SpotLight:SetIntensity(tonumber(spot) or 0) end)
                pcall(function() a.PointLight:SetIntensity(tonumber(point) or 0) end)
                local laser = (tonumber(point) or 0) > 0
                if laser ~= c.laser then
                    pcall(function() if laser then a.NS_LaserSight:Activate(true) else a.NS_LaserSight:Deactivate() end end)
                    c.laser = laser
                end
                if laser and tonumber(x) then
                    -- kept relative to the laser on the ghost's gun (the end point and the ghost's pose are about
                    -- equally old): each frame it's placed from where the gun is now, so it no longer trails the gun
                    local rel = to_local(a, tonumber(x), tonumber(y), tonumber(z))
                    if rel then
                        c.ends = rel
                        c.at = c.at or { X = rel.X, Y = rel.Y, Z = rel.Z }
                    end
                end
            end
        end
    end
    for k in pairs(copies) do if not want[k] then destroy_copy(k) end end
end

local beam_end_name
local world_end = { X = 0, Y = 0, Z = 0 }
local function ease_beams(dt)
    local f = math.min(1.0, dt * 15)
    for _, c in pairs(copies) do
        if c.laser and c.ends and c.at and util.valid(c.actor) then
            c.at.X = c.at.X + (c.ends.X - c.at.X) * f
            c.at.Y = c.at.Y + (c.ends.Y - c.at.Y) * f
            c.at.Z = c.at.Z + (c.ends.Z - c.at.Z) * f
            if to_world(c.actor, c.at, world_end) then
                beam_end_name = beam_end_name or FName("User.Beam End")
                pcall(function() c.actor.NS_LaserSight:SetVectorParameter(beam_end_name, world_end) end)
            end
        end
    end
end

local hook_in = 0.0
local switched_fn = function(self) util.safe(function() remember(self:get()) end, "tactical.switched") end

function tactical.tick(dt)
    if not (cfg and cfg.mirror_tactical) then return end
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 1.0
        for _, n in ipairs(NAMES) do util.ensure_hook(class_path(n) .. ":Jig_SetAttachmentActiveState", switched_fn) end
    end
    local g = ghost.get()
    if not g then
        if next(copies) then clear() end
        sent, scan_in = nil, 0.0
        return
    end
    util.safe(send, "tactical.send", dt)
    if applied_gen ~= ghost.generation() then clear() end
    local got = link.get_blob("tactical")
    if got then peer_blob = got end
    local blob = peer_blob
    if blob ~= applied or applied_gen ~= ghost.generation() or (blob ~= "" and hook_in == 1.0) then
        applied, applied_gen = blob, ghost.generation()
        util.safe(apply, "tactical.apply", blob)
    end
    ease_beams(dt)
end

function tactical.status()
    local n = 0
    for _ in pairs(copies) do n = n + 1 end
    local m = 0
    for _ in pairs(mine) do m = m + 1 end
    return string.format("tactical: mine %d (sent %q) | the other player's shown %d", m, (sent or ""):gsub("\n", "; "), n)
end

local registered = false
-- Respawn/reload: the old world's objects are freed - drop them without touching them.
local function forget_world() mine, copies, made, sent, applied, applied_gen = {}, {}, {}, nil, nil, nil end
function tactical.init(c)
    cfg = c
    game.on_world_reset(forget_world)
    if not registered then registered = true; ghost.on_destroy(clear) end
end

return tactical
