-- Crash breadcrumb: mirror_step.txt (next to the game exe) always holds the mod
-- step that is running right now, flushed each time (~2 us), so after a native
-- crash the file names the tick part or hook the game died in. The previous
-- run's file is kept as mirror_step.1.txt and its step is logged at start.

local crumb = {}

local FILE, WIDTH = "mirror_step.txt", 72
local FMT = "%-" .. WIDTH .. "s"
local out = nil
local enabled = true
local last = nil

function crumb.configure(cfg) enabled = not (cfg and cfg.crash_steps == false) end

local function open_file()
    if out ~= nil then return out end
    out = false
    pcall(function()
        local prev = io.open(FILE, "r")
        if prev then
            crumb.previous = prev:read("*l")
            prev:close()
            os.remove("mirror_step.1.txt")
            os.rename(FILE, "mirror_step.1.txt")
        end
        out = io.open(FILE, "w") or false
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
    f:seek("set", 0)
    f:write(string.format(FMT, os.date("%H:%M:%S ") .. tostring(step)):sub(1, WIDTH))
    f:flush()
end

-- Around a hook: the step before it, then back to that step afterwards when the hook fired inside mod
-- code (a sound or call the mod made itself) - else a hang in that native call was blamed on the game
-- ("game (after hook audio PlaySoundAtLocation)", report 131713) instead of the mod step that made it.
function crumb.current() return last end
function crumb.leave(prev, after)
    if prev and prev:sub(1, 4) ~= "game" then crumb.at(prev) else crumb.at(after) end
end

return crumb
