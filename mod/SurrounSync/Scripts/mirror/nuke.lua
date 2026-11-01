-- The nuke easter egg (BP_EasterEgg_Nuke, a bomb placed in the map) going off on both screens (user 2026-10-30:
-- "sync nuke"). Damaged, it runs Svr_Explode -> MC_Explode once (decompiled): the blast, its sound, the scorch mark,
-- the camera shake, damage to every character in its sphere, then the bomb is destroyed. Only the player whose game
-- did it saw any of it. Here: MC_Explode in one game is sent with where it happened, and the other game runs its own
-- bomb's MC_Explode there - its blast hurts whoever stands in it on that screen, as it would have.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local events = require("mirror.events")

local nuke = {}

local CLS = "/Game/Blueprints/Other/EasterEggs/BP_EasterEgg_Nuke.BP_EasterEgg_Nuke_C"
local FN = CLS .. ":MC_Explode"
local NEAR = 500   -- cm: the other game's bomb is the same map piece, at the same spot

local channel = events.new("nuke", 8, 60)
local applying = false
local hook_in = 0.0

local function loc_of(a)
    local l
    pcall(function() l = a:K2_GetActorLocation() end)
    return l
end

-- MC_Explode ran here (shot, hit, blown up): tell the other game, unless it is us replaying theirs
local function on_explode(self)
    if applying then return end
    local a
    pcall(function() a = self:get() end)
    local l = util.valid(a) and loc_of(a)
    if not l then return end
    channel:send(string.format("E %.0f %.0f %.0f", l.X, l.Y, l.Z))
    log.info(string.format("nuke: went off at %.0f, %.0f, %.0f - sent", l.X, l.Y, l.Z))
end

-- the other game's bomb at x, y, z went off: ours there goes off too
local function apply(p)
    local x, y, z = p:match("^E (%-?%d+) (%-?%d+) (%-?%d+)$")
    if not x then return end
    local want = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    local best, best_d
    for _, a in ipairs(FindAllOf("BP_EasterEgg_Nuke_C") or {}) do
        local l = util.valid(a) and loc_of(a)
        if l then
            local d = util.dist(l, want)
            if d <= NEAR and (not best_d or d < best_d) then best, best_d = a, d end
        end
    end
    if not best then
        log.info(string.format("nuke: the other game's went off at %s, %s, %s - none here (already gone)", x, y, z))
        return
    end
    applying = true
    local ok, err = pcall(function() best:MC_Explode(nil) end)
    applying = false
    log.info("nuke: the other game's went off - ours too" .. (ok and "" or (" FAILED: " .. tostring(err))))
end

function nuke.tick(dt)
    hook_in = hook_in - dt
    if hook_in <= 0 then
        hook_in = 2.0
        util.ensure_hook(FN, on_explode)
    end
    channel:pump(function(p) util.safe(apply, "nuke.apply", p) end)
end

function nuke.init() game.on_world_reset(function() applying = false end) end

return nuke
