-- Crash breadcrumb: mirror_steps.txt (next to the game exe) holds the mod's last RING_N steps, one fixed-width
-- line each, written round-robin with a sequence number and flushed each time, so after a native crash or a freeze
-- its newest line names the tick part or hook the game died in (one step alone didn't explain the 2026-10-27
-- freezes; the bridge puts them back in order, Report.RecentSteps / Diagnose.NewestStep). The last runs' files are
-- kept as mirror_steps.1-3.txt and the last one's step is logged at start.
-- mirror_step.txt (one line, the current step) was written next to it on every step until 2026-11-01: kit A/B,
-- a step cost 8.4-9.4 us in-game, 4.4-5.6 of it the two file writes, ~0.7 ms/frame in all. It now only says where
-- the step went, for a bridge from before then.

local crumb = {}

local FILE = "mirror_step.txt"
local POINTER = "(SurrounSync 1.0.1+: the current mod step is the newest line of mirror_steps.txt)"
local RING, RING_N, RING_W = "mirror_steps.txt", 64, 100
local RING_FMT = "%-" .. (RING_W - 1) .. "s\n"
local out = nil   -- the ring file
local ring_i, ring_seq = 0, 0
local enabled = true
local last = nil
local date_sec, date_s = nil, ""   -- os.date once a second, not per step (0.6-0.8 us in-game)
local written = 0

-- Steps written since the last call (the perf report gives them per frame: each is a file write)
function crumb.taken() local n = written; written = 0; return n end

function crumb.configure(cfg) enabled = not (cfg and cfg.crash_steps == false) end

-- The last KEEP runs' files: <base>.1.txt (the last run) .. <base>.KEEP.txt. A rename keeps the file's time, which
-- is when that run wrote its last step: the bug report picks the run that ended at a crash by it. One run only
-- lost a crash's steps after a few restarts (player report 2026-10-31: crash 23:14, three runs, report 01:05).
local KEEP = 3
local function rotate(name)
    local prev = io.open(name, "rb")
    if not prev then return nil end
    local text = prev:read("*a")
    prev:close()
    local base = name:gsub("%.txt$", "")
    os.remove(base .. "." .. KEEP .. ".txt")
    for i = KEEP - 1, 1, -1 do os.rename(base .. "." .. i .. ".txt", base .. "." .. (i + 1) .. ".txt") end
    os.rename(name, base .. ".1.txt")
    return text
end

-- "<time> <step>" of the ring's newest line (the highest sequence number), or nil
function crumb.newest(text)
    local best, step = -1, nil
    for seq, time, s in (text or ""):gmatch("(%d+) (%d%d:%d%d:%d%d) [%d%.]+ ([^\n]-)%s*\n") do
        seq = tonumber(seq)
        if seq > best then best, step = seq, time .. " " .. s end
    end
    return step
end

local function open_file()
    if out ~= nil then return out end
    out = false
    pcall(function()
        local old = rotate(FILE)   -- a mod from before 1.0.1 wrote its current step there
        old = old and old:sub(1, 1) ~= "(" and old:match("^[^\r\n]*") or nil
        crumb.previous = crumb.newest(rotate(RING)) or old
        local f = io.open(FILE, "w")
        if f then f:write(POINTER, "\n"); f:close() end
        out = io.open(RING, "wb") or false   -- (binary: text mode's \r\n would shift the fixed-width slots)
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
    written = written + 1
    local sec = os.time()
    if sec ~= date_sec then date_sec, date_s = sec, os.date("%H:%M:%S ", sec) end
    -- file methods report failures as return values, so no pcall (no closure per step)
    ring_seq = ring_seq + 1
    f:seek("set", ring_i * RING_W)
    f:write(string.format(RING_FMT, string.format("%d %s%.3f %s", ring_seq, date_s, os.clock(), tostring(step)):sub(1, RING_W - 1)))
    f:flush()
    ring_i = (ring_i + 1) % RING_N
end

-- Around a hook: the step before it, then back to that step afterwards when the hook fired inside mod
-- code (a sound or call the mod made itself) - else a hang in that native call was blamed on the game
-- ("game (after hook audio PlaySoundAtLocation)", report 131713) instead of the mod step that made it.
function crumb.current() return last end
function crumb.leave(prev, after)
    if prev and prev:sub(1, 4) ~= "game" then crumb.at(prev) else crumb.at(after) end
end

return crumb
