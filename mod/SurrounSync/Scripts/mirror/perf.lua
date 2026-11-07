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
local top_kb = 0.0         -- Lua memory the top-level parts took so far, the same for the glue's own KB/s
local function record(name, d, dm, top)
    if top then top_total, top_kb = top_total + d, top_kb + dm end
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

-- A hook body (it runs inside the game's own call, outside every tick, so no part ever counted it: the per-shot
-- hooks while a fast gun fired, player report #6): listed like a part, never added to the mod's own frame time
-- (it isn't inside that frame), no crash step (one write per shot).
function perf.hook(name, fn, ...)
    if not enabled then return fn(...) end
    local t, m = os.clock(), collectgarbage("count")
    fn(...)
    record(name, os.clock() - t, collectgarbage("count") - m, false)
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
-- (and its Lua memory: "0 KB/s" on every glue part hid what filled the heap to 2.6 GB, live 2026-11-04)
local glue = { at = nil, top = 0.0, kb = 0.0, top_kb = 0.0, name = nil, names = {} }
local function glue_flush(t, kb)
    if not glue.at then return end
    local d = (t - glue.at) - (top_total - glue.top)
    if d > 0 then
        local n = glue.names[glue.name]
        if not n then n = "glue " .. glue.name; glue.names[glue.name] = n end
        local own_kb = (kb - glue.kb) - (top_kb - glue.top_kb)
        record(n, d, own_kb, true)
    end
end
function perf.glue(name)
    if not (enabled and frame_start) then return end
    local t, kb = os.clock(), collectgarbage("count")
    glue_flush(t, kb)
    glue.at, glue.top, glue.kb, glue.top_kb, glue.name = t, top_total, kb, top_kb, name
end

function perf.frame_begin()
    depth = 0
    if enabled then
        frame_start = os.clock()
        glue.at, glue.top, glue.kb, glue.top_kb, glue.name = frame_start, top_total, collectgarbage("count"), top_kb, "start"
    end
end

function perf.frame_end(dt)
    crumb.at("game (mod tick done)")   -- (before the last glue is taken: the report counts its write)
    if not (enabled and frame_start) then return end
    glue_flush(os.clock(), collectgarbage("count"))
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
    -- ("all ticks": since 2026-11-01 the frame spans every game.on_tick handler, so it reads higher than before)
    log.info(string.format("perf: mod %.2f ms/frame (all ticks, worst frame %.0f ms, %.0f crash steps/frame), game %.0f fps, Lua memory %.0f KB (%s GC%s)%s | %s",
        frame_sum / frames * 1000, frame_max * 1000, crumb.taken() / frames, frames / wall, collectgarbage("count"), gc_mode,
        gc_slow > 0 and string.format(", inside %d slow part(s)", gc_slow) or "",
        gc_on and "" or " (GC WAS STOPPED - restarted)", table.concat(top, " | ")))
    parts, frame_sum, frame_max, frames, wall, gc_slow = {}, 0.0, 0.0, 0, 0.0, 0
end

return perf
