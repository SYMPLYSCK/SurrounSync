-- Debug probes for zombie targeting and AI around the ghost.

local log = require("mirror.log")
local util = require("mirror.util")
local ghost = require("mirror.ghost")

local probe = {}

local cfg
local stats = { hits = 0, dmg = 0.0, last_hit = "", xp_calls = 0, load_player = 0 }
local xp_start = nil
local layers_logged = false

function probe.configure(c) cfg = c end
function probe.stats() return stats end

function probe.on_ghost_damage(amount, causer)
    stats.hits = stats.hits + 1
    stats.dmg = stats.dmg + (tonumber(amount) or 0)
    stats.last_hit = util.class_name(causer) or "?"
end

function probe.on_toughness_xp() stats.xp_calls = stats.xp_calls + 1 end
function probe.on_load_player(is_ghost)
    stats.load_player = stats.load_player + 1
    log.info("Event_LoadPlayer called on " .. (is_ghost and "GHOST" or "real player"))
end

function probe.zombies()
    local list = FindAllOf("BP_MasterZombie_C")
    if list and #list > 0 then return list end
    local out = {}
    for _, c in ipairs(FindAllOf("Character") or {}) do
        local n = util.class_name(c)
        if n and n:find("Zombie", 1, true) then out[#out + 1] = c end
    end
    return out
end

local function target_of(z)
    local t
    pcall(function()
        local bb = z.Controller.Blackboard
        t = bb:GetValueAsObject(FName("AttackTarget"))
    end)
    return t
end

local function toughness_xp()
    local v
    pcall(function() v = FindFirstOf("PassiveSkillsComponent_C").CurrentToughessXP end)
    return v
end

local function log_layer_radii(z)
    if layers_logged then return end
    local radii = {}
    pcall(function()
        z.AIOSubject.OptimizationLayers:ForEach(function(_, layer)
            radii[#radii + 1] = string.format("%.0f m", layer:get().LayerRadius / 100)
        end)
    end)
    if #radii > 0 then
        layers_logged = true
        log.info("probe: zombie optimization layer radii = " .. table.concat(radii, ", "))
    end
end

function probe.report(player)
    local gl = ghost.location()
    local pl
    pcall(function() pl = util.vec(player:K2_GetActorLocation()) end)

    local near, on_ghost, on_player, total = 0, 0, 0, 0
    local layer_hist, wrong_invoker = {}, 0
    for _, z in ipairs(probe.zombies()) do
        if util.valid(z) then
            total = total + 1
            local zl
            pcall(function() zl = z:K2_GetActorLocation() end)
            if gl and zl and util.dist(gl, zl) <= cfg.phase0.probe_radius then
                near = near + 1
                log_layer_radii(z)
                local layer, inv_d = -9, nil
                pcall(function() layer = z.AIOSubject:GetCurrentOptimizationLayer() end)
                pcall(function() inv_d = z.AIOSubject:GetDistanceToClosestInvoker() end)
                layer_hist[layer] = (layer_hist[layer] or 0) + 1
                if inv_d and inv_d > util.dist(gl, zl) + 200 then wrong_invoker = wrong_invoker + 1 end
            end
            local t = target_of(z)
            if t and util.valid(t) then
                if ghost.is(t) then on_ghost = on_ghost + 1
                elseif util.same(t, player) then on_player = on_player + 1 end
            end
        end
    end

    local hist = {}
    for k, v in pairs(layer_hist) do hist[#hist + 1] = string.format("L%d:%d", k, v) end
    table.sort(hist)

    local invokers = "?"
    pcall(function() invokers = tostring(ghost.optimizer().Invokers:GetArrayNum()) end)

    local xp = toughness_xp()
    if xp_start == nil then xp_start = xp end
    local health = "?"
    pcall(function() health = string.format("%.0f", ghost.get().MedicalComponent.Health) end)

    local gpos = gl and string.format("(%.0f, %.0f, %.0f)", gl.X, gl.Y, gl.Z) or "none"
    local dist = (gl and pl) and string.format("%.0f m", util.dist(gl, pl) / 100) or "-"
    log.info(string.format(
        "probe: ghost=%s dist=%s | zombies total=%d near-ghost=%d targeting ghost=%d you=%d | ghost hits=%d dmg=%.0f last=%s health=%s | invokers=%s ghost-invoker-idx=%d near-ghost layers [%s] ignoring-ghost=%d | ToughnessXP=%s (start %s, AddXP calls %d) | LoadPlayer calls=%d",
        gpos, dist, total, near, on_ghost, on_player, stats.hits, stats.dmg, stats.last_hit, health,
        invokers, ghost.invoker_index(), table.concat(hist, " "), wrong_invoker,
        tostring(xp), tostring(xp_start), stats.xp_calls, stats.load_player))
end

return probe
