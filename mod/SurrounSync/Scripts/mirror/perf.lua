-- Measures how long each part of the mod takes per frame and logs slow spots.

local log = require("mirror.log")
local crumb = require("mirror.crumb")

local perf = {}

local REPORT_EVERY = 30.0
local parts = {}
local frame_sum, frame_max, frames, wall = 0.0, 0.0, 0, 0.0
local frame_start = nil
local enabled = true
local gc_mode = "incremental"
local gc_slow = 0           -- slow parts (>= 30 ms) a garbage collection ran inside, since the last report

-- Lua 5.4 collector mode for the whole mod (main.lua calls this once at startup).
function perf.set_gc(mode)
    gc_mode = mode == "incremental" and "incremental" or "generational"
    collectgarbage(gc_mode)
end

function perf.configure(cfg) enabled = not (cfg and cfg.perf_log == false) end

-- nested runs (fire.tick's sub-timers) put the outer step back after them, or a freeze later in the outer part
-- was blamed on the last sub-timer; top-level runs don't (one crumb write per run). depth resets each frame, so a
-- run that raised can't leave it counting.
local depth = 0
local top_total = 0.0      -- time in top-level parts so far (the glue between them = the rest)
local function record(name, d, dm, top)
    if top then top_total = top_total + d end
    local p = parts[name]
    if not p then p = { sum = 0.0, max = 0.0, kb = 0.0 }; parts[name] = p end
    p.sum = p.sum + d
    if top then p.top = true end
    if d > p.max then p.max = d end
    if d >= 0.03 then
        -- (Lua memory went down meanwhile = a garbage collection ran inside this part and its time counts here: spikes
        -- of the same size in unrelated parts, live 2026-10-30, heap 32-100 MB)
        local gc = dm < -1024
        if gc then gc_slow = gc_slow + 1 end
        log.info(string.format("perf: %s took %.0f ms%s", name, d * 1000,
            gc and string.format(" (a Lua GC ran inside it: %.1f MB freed)", -dm / 1024) or ""))
    end
    if dm > 0 then p.kb = p.kb + dm end
end
function perf.run(name, fn, ...)
    local top = depth == 0
    local outer = not top and crumb.current() or nil
    crumb.at(name)
    depth = depth + 1
    if not enabled then
        fn(...)
        depth = depth - 1
        if outer then crumb.at(outer) end
        return
    end
    local t, m = os.clock(), collectgarbage("count")
    fn(...)
    depth = depth - 1
    if outer then crumb.at(outer) end
    record(name, os.clock() - t, collectgarbage("count") - m, top)
end

-- A span the caller times itself (code whose results perf.run can't hand back): local s = perf.start() ...
-- perf.stop("name", s). Counts as its own part, at the depth it was started at.
function perf.start()
    if not enabled then return nil end
    return { os.clock(), collectgarbage("count"), depth == 0 }
end
function perf.stop(name, s)
    if s then record(name, os.clock() - s[1], collectgarbage("count") - s[2], s[3]) end
end

-- Glue: the time between two marks that no part took is counted as the part "glue <name of the first mark>"
-- (live 2026-10-31: 0.66 ms/frame was outside every part, in code between them)
local glue = { at = nil, top = 0.0, name = nil, names = {} }
local function glue_flush(t)
    if not glue.at then return end
    local d = (t - glue.at) - (top_total - glue.top)
    if d > 0 then
        local n = glue.names[glue.name]
        if not n then n = "glue " .. glue.name; glue.names[glue.name] = n end
        record(n, d, 0, true)
    end
end
function perf.glue(name)
    if not (enabled and frame_start) then return end
    local t = os.clock()
    glue_flush(t)
    glue.at, glue.top, glue.name = t, top_total, name
end

function perf.frame_begin()
    depth = 0
    if enabled then
        frame_start = os.clock()
        glue.at, glue.top, glue.name = frame_start, top_total, "start"
    end
end

function perf.frame_end(dt)
    crumb.at("game (mod tick done)")   -- (before the last glue is taken: the report counts its write)
    if not (enabled and frame_start) then return end
    glue_flush(os.clock())
    glue.at = nil
    local d = os.clock() - frame_start
    frame_start = nil
    frame_sum, frames, wall = frame_sum + d, frames + 1, wall + (dt or 0)
    if d >= 0.1 then log.info(string.format("perf: slow frame %.0f ms", d * 1000)) end
    if d > frame_max then frame_max = d end
    if wall < REPORT_EVERY then return end
    local list = {}
    for name, p in pairs(parts) do list[#list + 1] = { name = name, sum = p.sum, max = p.max, kb = p.kb, top = p.top } end
    table.sort(list, function(a, b) return a.sum > b.sum end)
    local top = {}
    -- (the 8 listed can hold sub-parts - z.read inside zombies - so they never add up to the mod's time: the
    -- top-level parts left out and the time outside any part are given too, 2026-10-31 ~half of it was unexplained)
    local in_parts, rest, rest_n = 0.0, 0.0, 0
    for i, p in ipairs(list) do
        if i <= 8 then
            top[#top + 1] = string.format("%s %.2f (max %.0f, %.0f KB/s)", p.name, p.sum / frames * 1000, p.max * 1000, p.kb / wall)
        elseif p.top then
            rest, rest_n = rest + p.sum, rest_n + 1
        end
        if p.top then in_parts = in_parts + p.sum end
    end
    top[#top + 1] = string.format("%d more parts %.2f, outside any part %.2f", rest_n, rest / frames * 1000,
        (frame_sum - in_parts) / frames * 1000)
    local gc_on = collectgarbage("isrunning")
    if not gc_on then collectgarbage("restart") end
    log.info(string.format("perf: mod %.2f ms/frame (worst frame %.0f ms), game %.0f fps, Lua memory %.0f KB (%s GC%s)%s | %s",
        frame_sum / frames * 1000, frame_max * 1000, frames / wall, collectgarbage("count"), gc_mode,
        gc_slow > 0 and string.format(", inside %d slow part(s)", gc_slow) or "",
        gc_on and "" or " (GC WAS STOPPED - restarted)", table.concat(top, " | ")))
    parts, frame_sum, frame_max, frames, wall, gc_slow = {}, 0.0, 0.0, 0, 0.0, 0
end

return perf
