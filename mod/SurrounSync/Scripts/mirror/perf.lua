-- Measures how long each part of the mod takes per frame and logs slow spots.

local log = require("mirror.log")

local perf = {}

local REPORT_EVERY = 30.0
local parts = {}
local frame_sum, frame_max, frames, wall = 0.0, 0.0, 0, 0.0
local frame_start = nil
local enabled = true

function perf.configure(cfg) enabled = not (cfg and cfg.perf_log == false) end

function perf.run(name, fn, ...)
    if not enabled then return fn(...) end
    local t, m = os.clock(), collectgarbage("count")
    fn(...)
    local d, dm = os.clock() - t, collectgarbage("count") - m
    local p = parts[name]
    if not p then p = { sum = 0.0, max = 0.0, kb = 0.0 }; parts[name] = p end
    p.sum = p.sum + d
    if d > p.max then p.max = d end
    if d >= 0.03 then log.info(string.format("perf: %s took %.0f ms", name, d * 1000)) end
    if dm > 0 then p.kb = p.kb + dm end
end

function perf.frame_begin() if enabled then frame_start = os.clock() end end

function perf.frame_end(dt)
    if not (enabled and frame_start) then return end
    local d = os.clock() - frame_start
    frame_start = nil
    frame_sum, frames, wall = frame_sum + d, frames + 1, wall + (dt or 0)
    if d >= 0.1 then log.info(string.format("perf: slow frame %.0f ms", d * 1000)) end
    if d > frame_max then frame_max = d end
    if wall < REPORT_EVERY then return end
    local list = {}
    for name, p in pairs(parts) do list[#list + 1] = { name = name, sum = p.sum, max = p.max, kb = p.kb } end
    table.sort(list, function(a, b) return a.sum > b.sum end)
    local top = {}
    for i = 1, math.min(8, #list) do
        local p = list[i]
        top[#top + 1] = string.format("%s %.2f (max %.0f, %.0f KB/s)", p.name, p.sum / frames * 1000, p.max * 1000, p.kb / wall)
    end
    local gc_on = collectgarbage("isrunning")
    if not gc_on then collectgarbage("restart") end
    log.info(string.format("perf: mod %.2f ms/frame (worst frame %.0f ms), game %.0f fps, Lua memory %.0f KB%s | %s",
        frame_sum / frames * 1000, frame_max * 1000, frames / wall, collectgarbage("count"),
        gc_on and "" or " (GC WAS STOPPED - restarted)", table.concat(top, " | ")))
    parts, frame_sum, frame_max, frames, wall = {}, 0.0, 0.0, 0, 0.0
end

return perf
