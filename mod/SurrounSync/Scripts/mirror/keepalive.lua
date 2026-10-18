-- Keeps zombie animation running near the ghost so their attacks still land on it.

local util = require("mirror.util")
local ghost = require("mirror.ghost")
local probe = require("mirror.probe")

local keepalive = {}

local cfg
local every = 1.0
local wait = 0.0
local kept = {}
local ALWAYS_TICK_POSE_AND_REFRESH_BONES = 0

function keepalive.configure(c) cfg = c end

local function pass()
    local r = (cfg and cfg.ghost.anim_keepalive_radius) or 0
    local gl = ghost.location()
    local seen = {}
    if r > 0 and gl and ghost.kind() == "host" then
        for _, z in ipairs(require("mirror.zombies").all_cached()) do
            local zl
            pcall(function() zl = z:K2_GetActorLocation() end)
            if zl and util.dist(gl, zl) <= r then
                local a = util.addr(z)
                seen[a] = true
                if not kept[a] then
                    pcall(function()
                        kept[a] = { z = z, old = z.Mesh.VisibilityBasedAnimTickOption }
                        z.Mesh.VisibilityBasedAnimTickOption = ALWAYS_TICK_POSE_AND_REFRESH_BONES
                    end)
                end
            end
        end
    end
    for a, e in pairs(kept) do
        if not seen[a] then
            if util.valid(e.z) then pcall(function() e.z.Mesh.VisibilityBasedAnimTickOption = e.old end) end
            kept[a] = nil
        end
    end
end

function keepalive.tick(dt)
    wait = wait - dt
    if wait > 0 then return end
    wait = every
    pass()
end

return keepalive
