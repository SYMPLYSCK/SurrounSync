-- Plays the other player's animations (melee, reloads, using items) on their character here.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local ghost = require("mirror.ghost")
local link = require("mirror.link")

local anim = {}

local KEEP, MAX_AGE = 8, 2
local epoch = tostring(os.time())
local next_id = 0
local recent = {}
local dirty = false
local seen = {}
local cache = {}

local function path_of(obj)
    local p
    pcall(function() p = obj:GetPathName() end)
    if not p then pcall(function() p = obj:GetFullName():match("^%S+ (.+)$") end) end
    return p
end

function anim.count() return next_id end

local function push(line)
    next_id = next_id + 1
    recent[#recent + 1] = string.format("%s %d %d %s", epoch, next_id, os.time(), line)
    if #recent > KEEP then table.remove(recent, 1) end
    dirty = true
end

local function record(kind, montage, rate)
    local m = montage and montage:get()
    local p = util.valid(m) and path_of(m) or nil
    if not p then
        if kind ~= "stop" then return end
        p = "-"
    end
    push(string.format("%s %s %.3f", kind, p, rate or 1.0))
end

local function record_use(asset, montage, mesh)
    local a, m, o
    pcall(function() a = asset:get() end)
    pcall(function() m = montage:get() end)
    pcall(function() o = mesh:get() end)
    local ap, mp = util.valid(a) and path_of(a), util.valid(m) and path_of(m)
    if not (ap and mp) then return end
    push(string.format("use %s 1 %s %s", ap, mp, util.valid(o) and path_of(o) or "-"))
end

local function is_real(self)
    local o = self:get()
    return not ghost.is(o) and util.same(o, game.player())
end

local function find_montage(p)
    local m = cache[p]
    if util.valid(m) then return m end
    m = StaticFindObject(p)
    if util.valid(m) then cache[p] = m; return m end
    return nil
end

local function apply_use(g, asset_p, extra)
    local mp, op = (extra or ""):match("^(%S+) (%S+)$")
    local asset, m = find_montage(asset_p), mp and find_montage(mp)
    if not (asset and m) then
        log.info("anim: the other player used " .. (asset_p:match("[^%.]+$") or asset_p) .. " - not loaded here, not shown")
        return
    end
    local o = op ~= "-" and find_montage(op) or nil
    local ok, err = pcall(function() g:PlayUsingItemMontage(asset, m, o) end)
    if ok then log.info("anim: ghost uses " .. (asset_p:match("[^%.]+$") or asset_p))
    else log.warn("anim: PlayUsingItemMontage failed: " .. tostring(err)) end
end

local function apply(g, kind, p, rate, extra)
    if kind == "use" then apply_use(g, p, extra); return end
    if p == "-" then pcall(function() g:StopAnimMontage(nil) end); return end
    local m = find_montage(p)
    if not m then log.warn("anim: montage not found: " .. p); return end
    if kind == "play" then
        local ok, err = pcall(function() g:PlayAnimMontage(m, rate, FName("None")) end)
        if ok then log.info("anim: ghost plays " .. p:match("[^%.]+$") .. string.format(" x%.2f", rate))
        else log.warn("anim: PlayAnimMontage failed: " .. tostring(err)) end
    else
        pcall(function() g:StopAnimMontage(m) end)
    end
end

function anim.tick()
    if dirty then
        dirty = false
        link.put_blob("anim", table.concat(recent, "\n"))
    end
    local body = link.get_blob("anim")
    if not body then return end
    local g = ghost.get()
    for line in body:gmatch("[^\n]+") do
        local ep, id, stamp, kind, p, rate, extra = line:match("^(%S+) (%d+) (%d+) (%S+) (%S+) (%S+) ?(.*)$")
        id = tonumber(id)
        if id and id > (seen[ep] or 0) then
            seen[ep] = id
            if g and link.peer_age(tonumber(stamp)) <= MAX_AGE then
                util.safe(apply, "anim.apply", g, kind, p, tonumber(rate) or 1.0, extra)
            end
        end
    end
end

function anim.init(cfg)
    if not cfg.ghost.mirror_montages then return end
    game.player_hook("MC_Montage", function(self, montage, rate)
        if is_real(self) then record("play", montage, rate and rate:get()) end
    end)
    game.player_hook("MC_StopMontage", function(self, montage)
        if is_real(self) then record("stop", montage, 1.0) end
    end)
    game.player_hook("PlayUsingItemMontage", function(self, asset, montage, mesh)
        if is_real(self) then util.safe(record_use, "anim.use", asset, montage, mesh) end
    end)
    log.info("anim: mirroring player montages")
end

return anim
