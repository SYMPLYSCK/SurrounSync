-- Log file (mirror_log.txt next to the game exe), rotated over the last three runs.

local log = {}

local LEVELS = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5 }
local threshold = LEVELS.INFO
local enabled = true

local FILE, KEEP = "mirror_log", 2
local out = nil
local function open_file()
    if out ~= nil then return out end
    out = false
    pcall(function()
        os.remove(FILE .. "." .. KEEP .. ".txt")
        for i = KEEP - 1, 1, -1 do os.rename(FILE .. "." .. i .. ".txt", FILE .. "." .. (i + 1) .. ".txt") end
        os.rename(FILE .. ".txt", FILE .. ".1.txt")
        out = io.open(FILE .. ".txt", "w") or false
    end)
    return out
end

function log.configure(cfg)
    enabled = cfg.debug.enabled ~= false
    threshold = LEVELS[cfg.debug.log_level] or LEVELS.INFO
end

local function emit(level, msg)
    if not enabled then return end
    if LEVELS[level] > threshold then return end
    local line = string.format("[SurrounSync][%s] %s\n", level, msg)
    print(line)
    local f = open_file()
    if f then pcall(function() f:write(os.date("%H:%M:%S "), line); f:flush() end) end
end

function log.error(m) emit("ERROR", m) end
function log.warn(m)  emit("WARN",  m) end
function log.info(m)  emit("INFO",  m) end
function log.debug(m) emit("DEBUG", m) end
function log.trace(m) emit("TRACE", m) end

return log
