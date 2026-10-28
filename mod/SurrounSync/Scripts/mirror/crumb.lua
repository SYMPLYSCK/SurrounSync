-- Crash breadcrumb: mirror_step.txt (next to the game exe) always holds the mod
-- step that is running right now, flushed each time (~2 us), so after a native
-- crash the file names the tick part or hook the game died in. The previous
-- run's file is kept as mirror_step.1.txt and its step is logged at start.

local crumb = {}

local FILE, WIDTH = "mirror_step.txt", 72
local FMT = "%-" .. WIDTH .. "s"
-- mirror_steps.txt: the last RING_N steps, one fixed-width line each, written round-robin with a sequence number -
-- one step alone didn't explain the 2026-10-27 freezes (the report puts them back in order, Report.RecentSteps)
local RING, RING_N, RING_W = "mirror_steps.txt", 64, 100
local RING_FMT = "%-" .. (RING_W - 1) .. "s\n"
local out, ring = nil, nil
local ring_i, ring_seq = 0, 0
local enabled = true
local last = nil

function crumb.configure(cfg) enabled = not (cfg and cfg.crash_steps == false) end

local function rotate(name, older)
    local prev = io.open(name, "r")
    if not prev then return nil end
    local first = prev:read("*l")
    prev:close()
    os.remove(older)
    os.rename(name, older)
    return first
end

local function open_file()
    if out ~= nil then return out end
    out = false
    pcall(function()
        crumb.previous = rotate(FILE, "mirror_step.1.txt")
        rotate(RING, "mirror_steps.1.txt")
        out = io.open(FILE, "w") or false
        ring = io.open(RING, "wb") or false   -- (binary: text mode's \r\n would shift the fixed-width slots)
    end)
    return out
end

-- Called once at load, before any step is recorded: returns the step the last
-- run ended in (nil when there was no file).
function crumb.start()
    open_file()
    return crumb.previous
end

function crumb.at(step)
    if not enabled or step == last then return end
    local f = out -- only the state that called crumb.start() writes (devtest runs its own Lua state)
    if not f then return end
    last = step
    -- file methods report failures as return values, so no pcall (no closure per step)
    local now = os.date("%H:%M:%S ")
    f:seek("set", 0)
    f:write(string.format(FMT, now .. tostring(step)):sub(1, WIDTH))
    f:flush()
    if ring then
        ring_seq = ring_seq + 1
        ring:seek("set", ring_i * RING_W)
        ring:write(string.format(RING_FMT, string.format("%d %s%.3f %s", ring_seq, now, os.clock(), tostring(step)):sub(1, RING_W - 1)))
        ring:flush()
        ring_i = (ring_i + 1) % RING_N
    end
end

-- Around a hook: the step before it, then back to that step afterwards when the hook fired inside mod
-- code (a sound or call the mod made itself) - else a hang in that native call was blamed on the game
-- ("game (after hook audio PlaySoundAtLocation)", report 131713) instead of the mod step that made it.
function crumb.current() return last end
function crumb.leave(prev, after)
    if prev and prev:sub(1, 4) ~= "game" then crumb.at(prev) else crumb.at(after) end
end

return crumb
