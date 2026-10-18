-- Developer commands read from a text file, for testing without anyone at the keyboard.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local jig = require("mirror.jig")

local devtest = {}

local role, zombies, loot
local check_in, later = 0.0, {}

local function file() return (os.getenv("LOCALAPPDATA") or ".") .. "\\SurrounDead\\mirror_dev_" .. role .. ".txt" end

local function dist_to_player(actor)
    local p, a = game.player(), nil
    local l
    pcall(function() l = actor:K2_GetActorLocation() end)
    if not l or (math.abs(l.X) < 1 and math.abs(l.Y) < 1) then
        pcall(function() l = actor.Mesh:K2_GetComponentLocation() end)
    end
    pcall(function() a = p:K2_GetActorLocation() end)
    if not (l and a) then return math.huge end
    return util.dist(l, a) / 100
end

local function describe(comp)
    local names = {}
    for _, h in ipairs(jig.contents_of(comp)) do
        names[#names + 1] = (h.da and h.da:match("([%w_]+)$") or "?") .. "x" .. h.count
    end
    table.sort(names)
    return #names .. " items [" .. table.concat(names, ", ") .. "]"
end

local function containers_near(max_m)
    local list = {}
    for _, comp in ipairs(FindAllOf("BP_JigComponent_C") or {}) do
        local owner
        pcall(function() owner = comp:GetOwner() end)
        if util.valid(owner) and loot.is_shared(owner) then
            local d = dist_to_player(owner)
            if d <= max_m then list[#list + 1] = { a = owner, d = d } end
        end
    end
    table.sort(list, function(x, y) return x.d < y.d end)
    return list
end

local function nearest_container(max_m)
    local l = containers_near(max_m)[1]
    if l then return l.a, l.d end
    return nil
end

local function nearest_corpse(max_m)
    local best, bd
    local list = {}
    if role == "host" then
        for id, z in pairs(zombies.host_zombies()) do list[#list + 1] = { id = id, z = z } end
    else
        for id, c in pairs(zombies.copies()) do if c.dead_at then list[#list + 1] = { id = id, z = c.z } end end
    end
    for _, e in ipairs(list) do
        local dead = false
        pcall(function() dead = e.z["IsDead?"] == true or e.z.Dead == true end)
        if dead then
            local d = dist_to_player(e.z)
            if d <= max_m and (not bd or d < bd) then best, bd = e, d end
        end
    end
    return best, bd
end

local function open(actor, what)
    local comp
    pcall(function() comp = actor.BP_JigMultiplayer end)
    if not util.valid(comp) then log.info("devtest: " .. what .. " has no inventory"); return end
    local ok, err = pcall(function() game.player():RequestServerData(comp, {}) end)
    log.info("devtest: opened " .. what .. (ok and "" or (" FAILED: " .. tostring(err))))
    later[#later + 1] = { at = os.clock() + 2.5, fn = function() log.info("devtest: " .. what .. " holds " .. describe(comp)) end }
end

local function container_name(a)
    local n = util.class_name(a) or "?"
    local l = a:K2_GetActorLocation()
    return string.format("%s@%d,%d,%d", n, math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5), math.floor(l.Z / 10 + 0.5))
end

local function run(cmd)
    log.info("devtest: command '" .. cmd .. "'")
    local n = tonumber(cmd:match("^kill (%d+)$") or "")
    if n then
        if role ~= "host" then log.info("devtest: kill is for the host"); return end
        local list = {}
        for id, z in pairs(zombies.host_zombies()) do
            local dead = false
            pcall(function() dead = z["IsDead?"] == true or z.Dead == true end)
            local d = dist_to_player(z)
            if not dead and d <= 150 then list[#list + 1] = { id = id, z = z, d = d } end
        end
        table.sort(list, function(a, b) return a.d < b.d end)
        local cls
        pcall(function() cls = StaticFindObject("/Game/Blueprints/Other/Damage/Damage_Body.Default__Damage_Body_C"):GetClass() end)
        local gs = util.cdo("/Script/Engine.Default__GameplayStatics")
        for i = 1, math.min(n, #list) do
            local e = list[i]
            local ok, err = pcall(function() gs:ApplyDamage(e.z, 1000, nil, game.player(), cls) end)
            log.info(string.format("devtest: hit zombie %d (%.0f m) for 1000%s", e.id, e.d, ok and "" or (" FAILED: " .. tostring(err))))
        end
        if #list == 0 then log.info("devtest: no living zombie within 150 m (the snapshot only lists ones near the guest)") end
    elseif cmd == "open" then
        local a, d = nearest_container(6)
        if a then
            loot.prefetch(a)
            later[#later + 1] = { at = os.clock() + 2.0, fn = function() open(a, container_name(a) .. string.format(" (%.1f m)", d)) end }
        else
            log.info("devtest: no shared container within 6 m")
        end
    elseif cmd == "corpse" then
        local e, d = nearest_corpse(150)
        if e then open(e.z, string.format("corpse of zombie %d (%.1f m)", e.id, d)) else log.info("devtest: no corpse within 150 m") end
    elseif cmd == "dump2" then
        for i, e in ipairs(containers_near(20)) do
            if i > 2 then break end
            local comp
            pcall(function() comp = e.a.BP_JigMultiplayer end)
            log.info("devtest: " .. container_name(e.a) .. " holds " .. describe(comp))
        end
    elseif cmd == "addtest" then
        local l = containers_near(20)
        local src, dst
        pcall(function() src = l[1].a.BP_JigMultiplayer end)
        pcall(function() dst = (l[2] or l[1]).a.BP_JigMultiplayer end)
        local first = src and jig.contents_of(src)[1]
        if not (first and dst) then log.info("devtest: no container with an item within 20 m"); return end
        local comp = dst
        local t0 = os.clock()
        local uid, err = jig.add_item(comp, first.da, 1, first.dx, first.dy)
        log.info(string.format("devtest: add_item %s -> %s (%.0f ms); now %s", first.da:match("([%w_]+)$"),
            tostring(uid or err), (os.clock() - t0) * 1000, describe(comp)))
    elseif cmd == "move" then
        local l = containers_near(20)
        if #l < 2 then log.info("devtest: need two shared containers within 20 m"); return end
        local fa, fb
        pcall(function() fa = l[1].a.BP_JigMultiplayer; fb = l[2].a.BP_JigMultiplayer end)
        local item = fa and jig.contents_of(fa)[1]
        if not (item and fb) then log.info("devtest: the nearest container is empty"); return end
        log.info("devtest: moving " .. item.da:match("([%w_]+)$") .. " from " .. container_name(l[1].a) .. " to " .. container_name(l[2].a))
        local n0 = #jig.contents_of(fb)
        local moved, err = false, nil
        local cont, cells = jig.container_arg(fb.MainJigContainers[1])
        for idx = 0, cells - 1 do
            local ok, e = pcall(function()
                fa:SERVER_RequestMoveItemToAnotherComp(fa, fb, jig.guid(item.uid), false, idx, cont[jig.REPUID], 0, {}, 0)
            end)
            if not ok then err = e; break end
            if #jig.contents_of(fb) > n0 then moved = true; break end
        end
        log.info("devtest: move " .. (moved and "done" or ("FAILED " .. tostring(err))) .. " - from: " .. describe(fa) .. " | to: " .. describe(fb))
    elseif cmd:find("^eval ") then
        local chunk, err = load(cmd:sub(6), "eval", "t", setmetatable({ util = util, jig = jig, game = game,
            loot = loot, near = containers_near, log = log }, { __index = _G }))
        if not chunk then log.info("devtest: eval - " .. tostring(err)); return end
        local res = table.pack(pcall(chunk))
        local out = {}
        for i = 2, res.n do out[#out + 1] = tostring(res[i]) end
        log.info("devtest: eval " .. (res[1] and "->" or "FAILED") .. " " .. table.concat(out, " | "))
    elseif cmd == "putin" then
        local a = nearest_container(6)
        local fa, fb
        pcall(function() fa = game.player().BP_JigMultiplayer end)
        pcall(function() fb = a.BP_JigMultiplayer end)
        local items = fa and jig.contents_of(fa) or {}
        if not (items[1] and fb) then log.info("devtest: putin - no container within 6 m or nothing in my inventory"); return end
        local n0 = #jig.contents_of(fb)
        local moved, err, item = false, nil, nil
        local cont, cells = jig.container_arg(fb.MainJigContainers[1])
        for i = 1, math.min(#items, 15) do
            item = items[i]
            for idx = 0, cells - 1 do
                local ok, e = pcall(function()
                    fa:SERVER_RequestMoveItemToAnotherComp(fa, fb, jig.guid(item.uid), false, idx, cont[jig.REPUID], 0, {}, 0)
                end)
                if not ok then err = e; break end
                if #jig.contents_of(fb) > n0 then moved = true; break end
            end
            if moved then break end
        end
        log.info("devtest: putin " .. item.da:match("([%w_]+)$") .. " -> " .. container_name(a) .. ": "
            .. (moved and "done" or ("FAILED " .. tostring(err))) .. " - now " .. describe(fb))
    elseif cmd == "dump" then
        local a = nearest_container(6)
        if a then
            local comp
            pcall(function() comp = a.BP_JigMultiplayer end)
            log.info("devtest: " .. container_name(a) .. " holds " .. describe(comp))
        end
        local e = nearest_corpse(150)
        if e then
            local comp
            pcall(function() comp = e.z.BP_JigMultiplayer end)
            log.info(string.format("devtest: corpse of zombie %d holds %s", e.id, describe(comp)))
        end
    else
        log.info("devtest: unknown command")
    end
end

local container_cmds = run

function devtest.tick(dt)
    for i = #later, 1, -1 do
        if os.clock() >= later[i].at then
            local job = table.remove(later, i)
            util.safe(job.fn, "devtest.later")
        end
    end
    check_in = check_in - dt
    if check_in > 0 then return end
    check_in = 1.0
    local f = io.open(file(), "r")
    if not f then return end
    local cmd = (f:read("*l") or ""):gsub("%s+$", "")
    f:close()
    os.remove(file())
    util.safe(function() run(cmd) end, "devtest.run")
end

function devtest.startup_probe()
    local base = (os.getenv("LOCALAPPDATA") or ".") .. "\\SurrounDead"
    local req = base .. "\\mirror_dev_probe.txt"
    local f = io.open(req, "r")
    if not f then return end
    f:close()
    os.remove(req)
    local savefs = require("mirror.savefs")
    local dir = base .. "\\mirror_probe"
    local function say(op, v) log.info("devtest: fsprobe " .. op .. " -> " .. tostring(v)) end
    say("BlueprintFileUtils CDO", util.cdo("/Script/BlueprintFileUtils.Default__BlueprintFileUtilsBPLibrary") ~= nil)
    say("mkdir " .. dir .. "\\a b\\c", savefs.mkdir(dir .. "\\a b\\c"))
    say("dir_exists", savefs.dir_exists(dir .. "\\a b\\c"))
    local w = io.open(dir .. "\\a b\\c\\x.txt", "wb")
    if w then w:write("x"); w:close() end
    say("write inside", savefs.exists(dir .. "\\a b\\c\\x.txt"))
    local names = savefs.list_dirs(dir)
    say("list_dirs", names and table.concat(names, "|") or "nil")
    say("rmdir", savefs.rmdir(dir))
    say("gone", not savefs.dir_exists(dir))
end

function devtest.watch(cfg)
    if not cfg.devtest then return end
    if type(LoopAsync) ~= "function" or type(ExecuteInGameThread) ~= "function" then return end
    local name = (cfg.phase2 and cfg.phase2.saved_override) or "Saved"
    local path = (os.getenv("LOCALAPPDATA") or ".") .. "\\SurrounDead\\mirror_dev_" .. name .. ".txt"
    local EMS = "/Script/EasyMultiSave.Default__EMSFunctionLibrary"
    local god = false
    local ticks = 0
    local menu_seen, continue_since = nil, nil
    local watch_started = os.clock()
    local build_at = nil
    local function load(slot, from_menu)
        local gi = FindFirstOf("SD_GameInstance_C")
        if not util.valid(gi) then log.info("devtest: no game instance"); return end
        local ok1 = pcall(function() util.cdo(EMS):SetCurrentSaveGameName(gi, slot) end)
        if from_menu then
            local removed = {}
            pcall(function()
                for _, w in ipairs(FindAllOf("UserWidget") or {}) do
                    local on, n = false, util.class_name(w) or ""
                    pcall(function() on = w:IsInViewport() end)
                    if on and (n:find("PressAnyKey") or n:find("Menu")) then
                        removed[#removed + 1] = n
                        pcall(function() w:SetVisibility(1) end)
                    end
                end
            end)
            log.info("devtest: hid main menu widgets: " .. table.concat(removed, ", "))
            pcall(function() StaticFindObject("/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"):DestroyMainMenuActors(gi) end)
        else
            pcall(function() game.player():ClearUI() end)
            pcall(function() game.player():DestroyActors() end)
        end
        local ok2, err = pcall(function() gi:Event_LoadLevel(from_menu and FName("LongdownValley") or gi.CurrentLevel) end)
        log.info(string.format("devtest: load %s -> name %s, level %s %s", slot, tostring(ok1), tostring(ok2), ok2 and "" or tostring(err)))
    end
    local function run(cmd)
        if not (continue_since and cmd:find("^continue ")) then
            log.info("devtest: '" .. (cmd:find("^pw ") and "pw ***" or cmd) .. "'")
        end
        local session = require("mirror.session")
        local arg = cmd:match("^%S+ (.+)$")
        if cmd:find("^continue ") and os.clock() - watch_started < 10.0 then
            local f = io.open(path, "w")
            if f then f:write(cmd, "\n"); f:close() end
            return
        end
        if cmd:find("^continue ") then
            local up = false
            pcall(function()
                for _, w in ipairs(FindAllOf("UserWidget") or {}) do
                    local on = false
                    pcall(function() on = w:IsInViewport() end)
                    local n = util.class_name(w) or ""
                    if on and (n:find("Menu") or n:find("PressAnyKey")) then up = true; break end
                end
            end)
            if up then menu_seen = menu_seen or os.clock() else menu_seen = nil end
            continue_since = continue_since or os.clock()
            local waited = os.clock() - continue_since
            if not (menu_seen and os.clock() - menu_seen >= 10.0) and waited < 30 then
                local f = io.open(path, "w")
                if f then f:write(cmd, "\n"); f:close() end
                return
            end
            log.info(string.format("devtest: loading after %.0f s (menu %s)", waited, menu_seen and "up" or "never seen"))
            continue_since = nil
            load(arg, true)
        elseif cmd:find("^menuload ") then load(arg, false)
        elseif cmd == "host" then require("mirror.menu").dev_host()
        elseif cmd == "join" then require("mirror.menu").dev_join()
        elseif cmd == "leave" then session.request_toggle()
        elseif cmd == "stophost" then require("mirror.menu").dev_stop()
        elseif cmd:find("^accept ") then require("mirror.menu").dev_accept(arg)
        elseif cmd:find("^say ") then require("mirror.chat").send(arg)
        elseif cmd == "public" or cmd == "browse" then require("mirror.menu").dev_act(cmd == "public" and "toggle_public" or "refresh")
        elseif cmd == "power list" then require("mirror.power").dev_list()
        elseif cmd:find("^power toggle") then require("mirror.power").dev_toggle(arg and arg:match("^toggle (%a+)$"))
        elseif cmd:find("^act ") then require("mirror.menu").dev_act(arg)
        elseif cmd == "pw" or cmd:find("^pw ") then require("mirror.menu").dev_password(arg or "")
        elseif cmd == "save" then pcall(function() game.controller():SaveGameToSlot() end)
        elseif cmd == "savetest" then
            cfg.save.destroy_ghost_on_save = false
            pcall(function() game.controller():SaveGameToSlot() end)
            log.info("devtest: savetest - saved with the ghost present: " .. tostring(require("mirror.ghost").exists()))
        elseif cmd == "checkpoint" then session.checkpoint("devtest")
        elseif cmd == "god" or cmd == "mortal" then
            god = cmd == "god"
            local ok = pcall(function() game.player().MedicalComponent["CanTakeDamage?"] = not god end)
            log.info("devtest: " .. cmd .. " -> " .. tostring(ok))
        elseif cmd:find("^tp ") then
            local dx, dy = (arg or ""):match("^(%S+)%s+(%S+)$")
            local p, l = game.player(), nil
            pcall(function() l = p:K2_GetActorLocation() end)
            if not (l and tonumber(dx) and tonumber(dy)) then log.info("devtest: tp needs <dx m> <dy m>"); return end
            local to = { X = l.X + tonumber(dx) * 100, Y = l.Y + tonumber(dy) * 100, Z = l.Z + 3000 }
            local ok, err = pcall(function() p:K2_TeleportTo(to, p:K2_GetActorRotation()) end)
            log.info(string.format("devtest: tp -> (%.0f, %.0f, %.0f) %s", to.X, to.Y, to.Z, ok and "ok" or tostring(err)))
        elseif cmd == "gkill" then require("mirror.zombies").dev_guest_kill()
        elseif cmd == "die" then
            god = false
            pcall(function() game.player().MedicalComponent["CanTakeDamage?"] = true end)
            local ok, err = pcall(function()
                util.cdo("/Script/Engine.Default__GameplayStatics"):ApplyDamage(game.player(), 100000.0, nil, game.player(), nil)
            end)
            log.info("devtest: die -> " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
        elseif cmd == "respawn bed" or cmd == "respawn random" then
            local ok, err = pcall(function()
                if arg == "bed" then game.controller():Svr_RequestRespawn_SpawnPoint() else game.controller():Svr_RequestRespawn_Random() end
            end)
            local closed = 0
            for _, w in ipairs(FindAllOf("RespawnScreen_C") or {}) do
                if pcall(function() w:RemoveFromParent() end) then closed = closed + 1 end
            end
            pcall(function()
                local pc = game.controller()
                util.cdo("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameOnly(pc, false)
                pc.bShowMouseCursor = false
            end)
            log.info("devtest: death screens closed: " .. closed)
            log.info("devtest: " .. cmd .. " -> " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
        elseif cmd == "bedhere" then
            local beds = require("mirror.beds")
            local l = game.player():K2_GetActorLocation()
            beds.apply(string.format("1 %.1f %.1f %.1f 0 0 0 1", l.X, l.Y, l.Z))
            log.info("devtest: bedhere -> " .. tostring(beds.read()))
        elseif cmd:find("^buildtest ") then
            local p = game.player()
            local comp, ok, err
            pcall(function() comp = p.BuildingComponent end)
            local da = StaticFindObject(arg)
            if not (util.valid(comp) and util.valid(da)) then
                log.info("devtest: buildtest - component " .. tostring(util.valid(comp)) .. ", asset " .. tostring(util.valid(da)))
                return
            end
            local l, r = p:K2_GetActorLocation(), p:K2_GetActorRotation()
            local yaw = math.rad(r.Yaw)
            local t = { Translation = { X = l.X + 300 * math.cos(yaw), Y = l.Y + 300 * math.sin(yaw), Z = l.Z - 90 },
                        Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
            ok, err = pcall(function() comp.DARef = da; comp["ReplacingObject?"] = false end)
            build_at = t
            log.info("devtest: buildtest -> " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
        elseif cmd == "buildplace" then
            local ok, err = pcall(function() game.player().BuildingComponent:SpawnBuild(build_at) end)
            log.info("devtest: buildplace -> " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
        elseif cmd == "infest" then
            local n = 0
            for _, a in ipairs(FindAllOf("BP_Infestation_C") or {}) do
                pcall(function()
                    if a:GetFullName():find("Default__", 1, true) then return end
                    local l = a:K2_GetActorLocation()
                    local function b(f) local v = false; pcall(function() v = a[f] == true end); return v and "1" or "0" end
                    log.info(string.format("devtest: infest %.0f %.0f prim=%s rand=%s dead=%s marker=%s", l.X / 100, l.Y / 100,
                        b("PrimaryInfestation?"), b("RandomInfestation?"), b("IsDestroyed?"), b("ShowMarker?")))
                    n = n + 1
                end)
            end
            log.info("devtest: infest done " .. n)
        elseif cmd:find("^count ") then
            local n, vis = 0, 0
            for _, o in ipairs(FindAllOf(arg) or {}) do
                pcall(function()
                    if o:GetFullName():find("Default__", 1, true) then return end
                    n = n + 1
                    local v = false
                    pcall(function() v = o:IsVisible() end)
                    if v then vis = vis + 1 end
                end)
            end
            log.info(string.format("devtest: count %s = %d (%d visible)", arg, n, vis))
        elseif cmd == "markers" then
            local n = 0
            for _, m in ipairs(FindAllOf("BP_Marker_C") or {}) do
                pcall(function()
                    if m:GetFullName():find("Default__", 1, true) then return end
                    local l, t = m:K2_GetActorLocation(), "?"
                    pcall(function() t = m.MarkerTitle:ToString() end)
                    local own = "-"
                    pcall(function() own = util.class_name(m:GetOwner()) or "-" end)
                    log.info(string.format("devtest: markers %.0f %.0f '%s' owner %s", l.X / 100, l.Y / 100, t, own))
                    n = n + 1
                end)
            end
            log.info("devtest: markers done " .. n)
        elseif cmd == "map" then pcall(function() game.player():Client_MapToggle() end); log.info("devtest: map toggled")
        elseif cmd == "clearz" then
            local me, n = game.player():K2_GetActorLocation(), 0
            for _, z in ipairs(FindAllOf("BP_MasterZombie_C") or {}) do
                pcall(function()
                    if z:GetFullName():find("Default__", 1, true) then return end
                    local l = z.Mesh:K2_GetComponentLocation()
                    if util.dist(util.vec(l), util.vec(me)) < 3000 then z:K2_DestroyActor(); n = n + 1 end
                end)
            end
            log.info("devtest: clearz removed " .. n)
        elseif cmd == "xpstat" then
            local out = {}
            pcall(function()
                local lc = game.controller().LevellingComponent
                for _, f in ipairs({ "CurrentLevel", "CurrentXP", "BufferXP", "RemainingXP" }) do
                    out[#out + 1] = f .. "=" .. tostring(lc[f])
                end
            end)
            log.info("devtest: xpstat " .. table.concat(out, " "))
        elseif cmd == "zlist" then
            local function nm(o) local s = "-"; pcall(function() s = o:GetFullName():match("([^%./]+)$"):gsub("_C_Inst_%d+$", ""):gsub("_%d+$", "") end); return s end
            local n = 0
            for _, z in ipairs(FindAllOf("BP_MasterZombie_C") or {}) do
                if not z:GetFullName():find("Default__", 1, true) then
                    pcall(function()
                        local m = z.Mesh
                        local l = m:K2_GetComponentLocation()
                        local v, mode = z.CharacterMovement.Velocity, z.CharacterMovement.MovementMode
                        log.info(string.format("devtest: zlist %.0f %.0f %s %s %s z=%.0f spd=%.0f mode=%s", l.X / 100, l.Y / 100,
                            (util.class_name(z) or "?"):gsub("^BP_Zombie_", ""), nm(m:GetSkinnedAsset()), nm(m:GetMaterial(0)),
                            l.Z, math.sqrt(v.X * v.X + v.Y * v.Y), tostring(mode)))
                        n = n + 1
                    end)
                end
            end
            log.info("devtest: zlist done " .. n)
        elseif cmd == "zlook" then
            local best, bd = nil, math.huge
            local me = game.player():K2_GetActorLocation()
            for _, z in ipairs(FindAllOf("BP_MasterZombie_C") or {}) do
                local d = math.huge
                pcall(function() local l = z.Mesh:K2_GetComponentLocation(); d = util.dist(util.vec(l), util.vec(me)) end)
                if d < bd and not z:GetFullName():find("Default__", 1, true) then best, bd = z, d end
            end
            if not best then log.info("devtest: zlook - no zombie"); return end
            local function nm(o) local s = "-"; pcall(function() s = o:GetFullName():match("([^%./]+)$") end); return s end
            local parts = { string.format("%s at %.1f m", util.class_name(best) or "?", bd / 100) }
            pcall(function()
                local m = best.Mesh
                parts[#parts + 1] = "mesh " .. nm(m:GetSkinnedAsset())
                local mats = {}
                for i = 0, m:GetNumMaterials() - 1 do mats[#mats + 1] = nm(m:GetMaterial(i)) end
                parts[#parts + 1] = "mats " .. table.concat(mats, ",")
                local s = best:GetActorScale3D()
                parts[#parts + 1] = string.format("scale %.2f", s.Z)
            end)
            pcall(function()
                local extra = {}
                for _, c in ipairs(FindAllOf("SkeletalMeshComponent") or {}) do
                    local ok, own = pcall(function() return c:GetOwner() end)
                    if ok and util.same(own, best) and not util.same(c, best.Mesh) then
                        local mats = {}
                        pcall(function() for i = 0, c:GetNumMaterials() - 1 do mats[#mats + 1] = nm(c:GetMaterial(i)) end end)
                        extra[#extra + 1] = nm(c:GetSkinnedAsset()) .. "[" .. table.concat(mats, ",") .. "]"
                    end
                end
                parts[#parts + 1] = "attached " .. (#extra > 0 and table.concat(extra, " ") or "none")
            end)
            log.info("devtest: zlook " .. table.concat(parts, " | "))
        elseif cmd == "hookstat" then log.info("devtest: hookstat top " .. util.lookup_top(6))
        elseif cmd:find("^hookstat ") then log.info("devtest: hookstat " .. arg .. ": " .. util.hook_state(arg))
        elseif cmd:find("^loadtest ") then
            local before = util.valid(StaticFindObject(arg))
            log.info("devtest: loadtest " .. arg .. " - in memory before: " .. tostring(before) .. " - loading...")
            local ok, err = pcall(function() LoadAsset(arg) end)
            local a = StaticFindObject(arg)
            local cls
            pcall(function() cls = a.BuildActorClass end)
            log.info(string.format("devtest: loadtest -> %s %s, in memory now: %s, build class: %s", tostring(ok),
                ok and "" or tostring(err), tostring(util.valid(a)), tostring(util.valid(cls))))
        elseif cmd == "time" then
            local td, ctd
            pcall(function() td = util.cdo("/Script/Engine.Default__GameplayStatics"):GetGlobalTimeDilation(game.player()) end)
            pcall(function() ctd = game.player().CustomTimeDilation end)
            log.info("devtest: time - global " .. tostring(td) .. ", my player " .. tostring(ctd))
        elseif cmd == "bed" then
            log.info("devtest: respawn point " .. tostring(require("mirror.beds").read()))
        elseif cmd == "bags" or cmd == "takebag" then
            local best, bd = nil, math.huge
            for _, b in ipairs(FindAllOf("Container_DeadPlayerLoot_C") or {}) do
                local d = dist_to_player(b)
                local n, items = 0, 0
                pcall(function() for _, h in ipairs(jig.contents_of(b.BP_JigMultiplayer)) do n = n + h.count; items = items + 1 end end)
                log.info(string.format("devtest: bag %s at %.0f m: %d stacks, %d items", b:GetFName():ToString(), d / 100, items, n))
                if d < bd then best, bd = b, d end
            end
            if cmd == "takebag" and best then
                local comp = best.BP_JigMultiplayer
                local h = jig.contents_of(comp)[1]
                local n = h and jig.reduce_item(comp, h.da, jig.count_of_item(comp, h.da) - 1) or 0
                log.info("devtest: takebag -> took " .. n .. " " .. tostring(h and h.da))
            end
        elseif cmd == "ghostz" then
            local function z(tag, a)
                if not util.valid(a) then log.info("devtest: ghostz " .. tag .. " none"); return end
                local loc, mesh, half, mode, falling, floor, walkable = {}, nil, nil, nil, nil, nil, nil
                pcall(function() loc = a:K2_GetActorLocation() end)
                pcall(function() mesh = a.Mesh:K2_GetComponentLocation().Z end)
                pcall(function() half = a.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
                pcall(function() mode = a.CharacterMovement.MovementMode end)
                pcall(function() falling = a.CharacterMovement:IsFalling() end)
                pcall(function() floor = a.CharacterMovement.CurrentFloor.FloorDist end)
                pcall(function() walkable = a.CharacterMovement.CurrentFloor.bWalkableFloor end)
                log.info(string.format("devtest: ghostz %s actor (%.0f, %.0f, %.1f) mesh z %s (offset %s) half %s mode %s falling %s floor %s walkable %s",
                    tag, loc.X or 0, loc.Y or 0, loc.Z or 0, tostring(mesh), mesh and string.format("%.1f", mesh - (loc.Z or 0)) or "?",
                    tostring(half), tostring(mode), tostring(falling), tostring(floor), tostring(walkable)))
            end
            z("me", game.player())
            z("ghost", require("mirror.ghost").get())
        elseif cmd == "ghostcol" then
            local g = require("mirror.ghost").get()
            if not g then log.info("devtest: ghostcol - no ghost"); return end
            local prim = StaticFindObject("/Script/Engine.PrimitiveComponent")
            local n = 0
            local list = {}
            local okl, errl = pcall(function()
                local arr = g:K2_GetComponentsByClass(prim)
                if type(arr) == "table" then for _, c in ipairs(arr) do list[#list + 1] = c end
                else arr:ForEach(function(_, e) list[#list + 1] = e:get() end) end
            end)
            log.info("devtest: ghostcol " .. #list .. " component(s)" .. (okl and "" or (" - listing failed: " .. tostring(errl))))
            pcall(function()
                for _, c in ipairs(list) do
                    local name, en, vis, ext = "?", -1, -1, nil
                    pcall(function() name = c:GetFName():ToString() .. " (" .. util.class_name(c) .. ")" end)
                    pcall(function() en = c:GetCollisionEnabled() end)
                    pcall(function() vis = c:GetCollisionResponseToChannel(3) end)
                    pcall(function() local b = c.Bounds.BoxExtent; ext = string.format("%.0fx%.0fx%.0f", b.X * 2, b.Y * 2, b.Z * 2) end)
                    if en ~= 0 then
                        n = n + 1
                        log.info(string.format("devtest: ghostcol %s enabled %s visibility %s size %s cm", name, tostring(en), tostring(vis), tostring(ext)))
                    end
                end
            end)
            log.info("devtest: ghostcol done - " .. n .. " part(s) with collision")
        elseif cmd == "ghosttrace" then
            local g, p = require("mirror.ghost").get(), game.player()
            if not g then log.info("devtest: ghosttrace - no ghost"); return end
            local ksl = util.cdo("/Script/Engine.Default__KismetSystemLibrary")
            local from, at = util.vec(p:K2_GetActorLocation()), util.vec(g:K2_GetActorLocation())
            from.Z = from.Z + 60
            local dx, dy = at.X - from.X, at.Y - from.Y
            local len = math.sqrt(dx * dx + dy * dy)
            if len < 1 then log.info("devtest: ghosttrace - standing on the ghost"); return end
            local sx, sy = -dy / len, dx / len
            for _, side in ipairs({ 0, 40, 80, 120, 160, 200, 300, 400 }) do
                for _, up in ipairs({ 0, 120, 250 }) do
                    local stop = { X = at.X + sx * side + dx / len * 300, Y = at.Y + sy * side + dy / len * 300, Z = at.Z + up }
                    local out, what = {}, "nothing"
                    local ok, r = pcall(function()
                        return ksl:LineTraceSingle(p, from, stop, 0, true, {}, 0, out, true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
                    end)
                    if not ok then what = "trace failed: " .. tostring(r)
                    elseif r then
                        local h = out.OutHit or out
                        local a, c, d = nil, nil, nil
                        pcall(function() a = h.HitObjectHandle.Actor:Get() end)
                        if not util.valid(a) then pcall(function() a = h.Actor:Get() end) end
                        pcall(function() c = h.Component:Get() end)
                        pcall(function() d = h.Distance end)
                        what = string.format("%s / %s at %s cm", util.valid(a) and (util.class_name(a) .. (util.same(a, g) and " [GHOST]" or "")) or "?",
                            util.valid(c) and c:GetFName():ToString() or "?", tostring(d and math.floor(d)))
                    end
                    log.info(string.format("devtest: ghosttrace side %d cm, height +%d: %s", side, up, what))
                end
            end
        elseif cmd == "journal" then
            local ok, err = pcall(function() game.player():Event_Journal() end)
            log.info("devtest: journal -> " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
        elseif cmd == "coop" then
            log.info("devtest: coop -> " .. tostring(require("mirror.journal_tab").open()))
        elseif cmd:find("^jpage ") then
            local which = ({ info = "Info", skills = "Skills", quests = "Quests" })[arg or ""]
            local jui = game.player().InGameUI.JournalUI
            local ev = { Info = "BndEvt__InfoSkillQuestUI_Button_56_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature",
                         Skills = "BndEvt__JournalUI_Test_SkillsButton_K2Node_ComponentBoundEvent_4_OnButtonClickedEvent__DelegateSignature",
                         Quests = "BndEvt__JournalUI_Test_QuestsButton_K2Node_ComponentBoundEvent_6_OnButtonClickedEvent__DelegateSignature" }
            local ok, err = pcall(function() jui[ev[which]](jui) end)
            log.info("devtest: jpage " .. tostring(which) .. " -> " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
        elseif cmd == "coopbackups" or cmd == "coopfriends" then
            require("mirror.journal_tab").dev_section(cmd == "coopbackups")
        elseif cmd == "ticks" then
            log.info("devtest: player ticks so far " .. tostring(ticks))
        elseif cmd == "status" then
            log.info(string.format("devtest: state %s, where %s, playing %s, host_gone %s", tostring(session.state()),
                tostring(session.where()), tostring(session.playing_slot()), tostring(session.host_gone())))
        elseif cmd:find("^kill %d+$") or ({ open = 1, corpse = 1, dump = 1, dump2 = 1, move = 1, putin = 1, addtest = 1 })[cmd] then
            container_cmds(cmd)
        else log.info("devtest: unknown command") end
    end
    local god_in = 0.0
    game.on_tick(function(dt)
        ticks = ticks + 1
        god_in = god_in - dt
        if god and god_in <= 0 then
            god_in = 1.0
            pcall(function() game.player().MedicalComponent["CanTakeDamage?"] = false end)
        end
    end)
    local empty_reads = 0
    LoopAsync(250, function()
        local f = io.open(path, "r")
        if f then
            local cmd = (f:read("*l") or ""):gsub("%s+$", "")
            f:close()
            if cmd == "" and empty_reads < 8 then empty_reads = empty_reads + 1; return false end
            empty_reads = 0
            os.remove(path)
            ExecuteInGameThread(function() util.safe(run, "devtest.watch", cmd) end)
        end
        return false
    end)
    log.info("devtest: watching " .. path)
end

function devtest.init(r, z, l)
    role, zombies, loot = r, z, l
end

return devtest
