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

local function path_of(obj)
    if not util.valid(obj) then return nil end
    local p
    pcall(function() p = obj:GetFullName():match("^%S+ (.+)$") end)
    return p
end

function anim.count() return next_id end

local function push(line)
    next_id = next_id + 1
    recent[#recent + 1] = string.format("%s %d %d %s", epoch, next_id, os.time(), line)
    if #recent > KEEP then table.remove(recent, 1) end
    dirty = true
end

-- My last mirrored montage, watched until it stops playing on me. A looping one (the shotgun's and revolver's ReloadB:
-- its one section's next section is itself) is ended by the game without MC_StopMontage, so the other game played it
-- forever (user 2026-10-31: "a never ending reload animation"). Once it stops here a "stop" goes out - for a looping
-- montage, or one that stopped well before its end (a non-looping one ending on its own ends there too).
local watch = nil
local WATCH_START, EARLY = 1.0, 0.3

-- does a section lead back to itself or an earlier one? (unreadable: taken as looping - a stop too many only cuts
-- the other game's last moment short)
local function loops(m)
    local r
    pcall(function()
        local names, back = {}, false
        util.each(m.CompositeSections, function(_, e)
            local s = e:get()
            local own, nxt = s.SectionName:ToString(), s.NextSectionName:ToString()
            names[own] = true
            if nxt ~= "None" and names[nxt] then back = true end
        end)
        r = back
    end)
    if r == nil then return true end
    return r
end

local function record(kind, montage, rate)
    local m = montage and montage:get()
    local p = util.valid(m) and path_of(m) or nil
    if not p then
        if kind ~= "stop" then return end
        p = "-"
    end
    push(string.format("%s %s %.3f", kind, p, rate or 1.0))
    if kind == "play" then
        local len
        pcall(function() len = m:GetPlayLength() / math.max(rate or 1.0, 0.01) end)
        watch = { m = m, p = p, at = os.clock(), seen = false, loops = loops(m), len = len }
    elseif watch and (p == "-" or p == watch.p) then
        watch = nil
    end
end

local function watch_tick()
    local w = watch
    if not w then return end
    local playing
    if util.valid(w.m) then
        pcall(function() playing = game.player().Mesh:GetAnimInstance():Montage_IsPlaying(w.m) == true end)
    else
        playing = false
    end
    if playing == nil then return end   -- (no player or anim instance this frame)
    local age = os.clock() - w.at
    if playing then w.seen = true; return end
    if not w.seen and age <= WATCH_START then return end   -- (not started yet)
    watch = nil
    if w.seen and (w.loops or not w.len or age < w.len - EARLY) then   -- (never played here: nothing to end)
        push(string.format("stop %s 1.000", w.p))
        log.debug("anim: " .. (w.p:match("[^%.]+$") or w.p) .. " stopped here - stopping it on the other game")
    end
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

local find_montage = util.find

local function apply_use(g, asset_p, extra)
    local mp, op = (extra or ""):match("^(%S+) (%S+)$")
    local asset, m = find_montage(asset_p), mp and find_montage(mp)
    if not (asset and m) then
        log.info("anim: the other player used " .. (asset_p:match("[^%.]+$") or asset_p) .. " - not loaded here, not shown")
        return
    end
    local o = op ~= "-" and find_montage(op) or nil
    local ok, err = pcall(function() g:PlayUsingItemMontage(asset, m, o) end)
    -- (every swing, loot and hit is one: debug only, ~1000 lines in 75 min of play, live 2026-10-30)
    if ok then log.debug("anim: ghost uses " .. (asset_p:match("[^%.]+$") or asset_p))
    else log.warn("anim: PlayUsingItemMontage failed: " .. tostring(err)) end
end

-- Montages whose notifies run the attack itself: played on the other player's character here, the stomp killed whoever
-- stood at its feet (kit 2026-10-27: a DamageTaken right at its start, PvP off). Their raw animation shows the same
-- move with none of the montage's notifies (kit: foot swings 50 cm, no damage); the hit stays in their own game.
local SHOW_ONLY = { Chr_Stomp_Montage = "/Game/Character/Anims/Chr_Stomp.Chr_Stomp" }

local function apply(g, kind, p, rate, extra)
    if kind == "use" then apply_use(g, p, extra); return end
    if p == "-" then pcall(function() g:StopAnimMontage(nil) end); return end
    local seq_path = kind == "play" and SHOW_ONLY[p:match("[^%.]+$") or ""]
    if seq_path then
        local seq = find_montage(seq_path)
        local ok = seq and pcall(function()
            g.Mesh:GetAnimInstance():PlaySlotAnimationAsDynamicMontage(seq, FName("DefaultSlot"), 0.1, 0.1, rate, 1, -1.0, 0.0)
        end)
        log.info("anim: ghost shows " .. seq_path:match("[^%.]+$") .. (ok and "" or " - not loaded here, not shown"))
        return
    end
    local m = find_montage(p)
    if not m then log.warn("anim: montage not found: " .. p); return end
    if kind == "play" then
        local ok, err = pcall(function() g:PlayAnimMontage(m, rate, FName("None")) end)
        if ok then log.debug("anim: ghost plays " .. p:match("[^%.]+$") .. string.format(" x%.2f", rate))
        else log.warn("anim: PlayAnimMontage failed: " .. tostring(err)) end
    else
        pcall(function() g:StopAnimMontage(m) end)
    end
end

function anim.tick()
    util.safe(watch_tick, "anim.watch")
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
