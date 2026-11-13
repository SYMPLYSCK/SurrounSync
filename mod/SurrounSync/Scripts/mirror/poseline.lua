-- The pose line's state flags and its parser (phase1 sends and reads it; kept apart so tests can load it alone).
-- Flags: 1 crouched, 2 falling, 4 sprinting, 8 swimming, 16 under water, 32 sitting on the floor. An older build
-- reads only the bits it knows, so a new bit never changes what it sees.

local poseline = {}

local function bit(f, b) return math.floor(f / b) % 2 == 1 end

function poseline.flags(player)
    local f = 0
    pcall(function() if player.bIsCrouched then f = f + 1 end end)
    pcall(function() if player.CharacterMovement:IsFalling() then f = f + 2 end end)
    pcall(function() if player.StaminaComponent.CurrentlySprinting == true then f = f + 4 end end)
    pcall(function()
        local sw = player.SwimmingComponent
        if sw["IsSwimming?"] == true then f = f + 8 end
        if sw["UnderWater?"] == true then f = f + 16 end
    end)
    -- BP_PlayerCharacter IA_SitDown: Chr_SittingFloor_Montage + Sitting? (not an MC_Montage, so anim.lua never sees it)
    pcall(function() if player["Sitting?"] == true then f = f + 32 end end)
    return f
end

function poseline.parse(payload)
    local x, y, z, yaw, vx, vy, vz, c, rest = payload:match(
        "^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%d+)(.*)$")
    if not c then return nil end
    local f = tonumber(c) or 0
    local pose = {
        loc = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) },
        yaw = tonumber(yaw),
        vel = { X = tonumber(vx), Y = tonumber(vy), Z = tonumber(vz) },
        crouch = bit(f, 1),
        falling = bit(f, 2),
        sprint = bit(f, 4),
        swim = bit(f, 8),
        underwater = bit(f, 16),
        sit = bit(f, 32),
    }
    local combat, ads, hip, melee, pitch, lx, ly, lz, hy, hr, vy, mv =
        rest:match("^ (%-?%d+) (%d) (%d) (%d) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)(.*)$")
    local walk, crouch_speed, stam, sent, lean = (mv or ""):match("^ (%S+) (%S+) (%S+) (%S+) ?(%S*)$")
    if walk then
        pose.move = { walk = tonumber(walk), crouch = tonumber(crouch_speed), stamina = tonumber(stam) }
        pose.sent = tonumber(sent)
    end
    if pitch then
        pose.aim = { combat = tonumber(combat), ads = ads == "1", hip = hip == "1", melee = melee == "1",
                     pitch = tonumber(pitch) or 0,
                     lhand = { X = tonumber(lx) or 0, Y = tonumber(ly) or 0, Z = tonumber(lz) or 0 },
                     head = { Yaw = tonumber(hy) or 0, Roll = tonumber(hr) or 0 },
                     view_yaw = tonumber(vy) }
        local lv, ls = (lean or ""):match("^(%-?[%d%.]+),(%d)$")
        if lv then pose.aim.lean, pose.aim.lean_side = tonumber(lv), tonumber(ls) end
    end
    return pose
end

-- "B <car> <forward> <right> <up> <yaw>" after the pose (vehicles.base_line): standing on that car, at that spot of it.
function poseline.parse_base(seg)
    local n, x, y, z, yaw = seg:match("^B (%S+) (%S+) (%S+) (%S+) (%S+)$")
    x, y, z, yaw = tonumber(x), tonumber(y), tonumber(z), tonumber(yaw)
    if not (n and x and y and z and yaw) then return nil end
    return { name = n, X = x, Y = y, Z = z, yaw = yaw }
end

-- What follows the pose, each after its own "|": the car I stand on ("B ...") and the car I drive (the rest:
-- "D ..."). Returns the base (parsed), an FPV quad segment ("Q ...", sent by releases up to 1.1.0, unused now) and
-- the car's.
function poseline.segments(rest)
    local base, quad, car = nil, nil, nil
    for seg in (rest or ""):gmatch("[^|]+") do
        local k = seg:sub(1, 2)
        if k == "B " then base = poseline.parse_base(seg)
        elseif k == "Q " then quad = seg
        else car = seg end
    end
    return base, quad, car
end

return poseline
