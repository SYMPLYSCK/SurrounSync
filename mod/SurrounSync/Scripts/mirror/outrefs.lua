-- Lets go of the Lua tables UE4SS 3.0.1 keeps for good. Every call of a UFunction with an out parameter takes a registry
-- reference to the table passed for it (LuaUObject.cpp make_ref) and never releases it, a reused table included, so each
-- K2_SetActorLocation or trace leaves its FHitResult behind for the rest of the session. Live 2026-11-04: 56 MB and 88000
-- userdata after 2 minutes on the hover bike, 2.6 GB after 23 minutes in the user's game, and 280-586 ms frames from the
-- collections over them. The calls can't be avoided (a trace has no form without one), so they are released here, the way
-- luaL_unref does it: the slot joins lauxlib's free list, which the next reference reuses, and the registry leaves no holes.
--
-- UE4SS reads such a reference back once, when the call returns. So only a plain table seen in the same slot by two sweeps
-- is released, EVERY_S apart: nothing in flight is that old. Slots there at start-up stay as they are (only part of UE4SS's
-- source was read, and it can't have made one of these before the mod's first call). A registry not laid out as expected
-- turns this off, loudly, and touches nothing.

local outrefs = {}

local EVERY_S = 5.0
local REPORT_S = 60.0
local FREELIST = 3          -- lauxlib's slot for the head of the free list since Lua 5.4.3 (UE4SS 3.0.1's is 5.4.7)

local reg, first, say = nil, nil, nil
local prev = {}             -- slot -> the plain table the last sweep saw there
local wait, report_in, off = EVERY_S, REPORT_S, false
local released_now = 0

outrefs.stats = { released = 0, sweeps = 0, worst_ms = 0.0 }

function outrefs.start(log_fn, registry)
    say = log_fn or function() end
    reg = registry or debug.getregistry()
    first = math.max(#reg + 1, FREELIST + 1)
    prev, wait, report_in, off, released_now = {}, EVERY_S, REPORT_S, false, 0
end

function outrefs.sweep()
    if off or not reg then return 0 end
    if math.type(reg[FREELIST]) ~= "integer" then
        off = true
        say("outrefs: the Lua registry isn't laid out as expected (slot 3 holds a " .. type(reg[FREELIST]) .. "), off: UE4SS's out-parameter tables stay in memory")
        return 0
    end
    local t, n = os.clock(), 0
    for k = first, #reg do
        local v = reg[k]
        if type(v) == "table" and debug.getmetatable(v) == nil then
            if prev[k] == v then
                reg[k] = reg[FREELIST]
                reg[FREELIST] = k
                prev[k] = nil
                n = n + 1
            else
                prev[k] = v
            end
        else
            prev[k] = nil
        end
    end
    local s = outrefs.stats
    s.released, s.sweeps = s.released + n, s.sweeps + 1
    s.worst_ms = math.max(s.worst_ms, (os.clock() - t) * 1000)
    released_now = released_now + n
    return n
end

function outrefs.tick(dt)
    wait, report_in = wait - dt, report_in - dt
    if wait <= 0 then
        wait = EVERY_S
        outrefs.sweep()
    end
    if report_in <= 0 then
        report_in = REPORT_S
        if released_now > 0 then
            say(string.format("outrefs: released %d out-parameter tables in the last minute (registry %d slots, worst sweep %.2f ms)",
                released_now, #reg, outrefs.stats.worst_ms))
            released_now = 0
        end
    end
end

function outrefs.is_off() return off end

return outrefs
