-- Logic behind the CO-OP tab: hosting, joining, requests, passwords, updates and bug reports.

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local link = require("mirror.link")
local notify = require("mirror.notify")
local session = require("mirror.session")
local page = require("mirror.menu_backups")
local journal_tab = require("mirror.journal_tab")
local instance = require("mirror.instance")

local menu = {}

local STEAM_BASE = 76561197960265728

local cfg
local want_host, want_join = false, nil
local pending_join = false
local wait_since, wait_told, wait_who = nil, nil, nil
local request_nag = {}
local request_seen_at = {}

local phase1
local function p1() phase1 = phase1 or require("mirror.phase1"); return phase1 end

local function my_role() return p1().started() end

local function to_steamid(code)
    code = (code or ""):gsub("%s", "")
    if not code:match("^%d+$") then return nil end
    local n = math.tointeger(tonumber(code))
    if not n or n <= 0 then return nil end
    if n < 4294967296 then n = STEAM_BASE + n end
    if n < STEAM_BASE then return nil end
    return string.format("%d", n)
end

local password = ""
local function accepted_path() return link.dir() .. "\\mirror_session_accepted.txt" end
local function accepted_ids()
    local t, f = {}, io.open(accepted_path(), "r")
    if f then for id in f:lines() do t[id] = true end; f:close() end
    return t
end
local function set_accepted(t)
    local f = io.open(accepted_path(), "w")
    if f then for id in pairs(t) do f:write(id, "\n") end; f:close() end
end
local function host()
    local r = my_role()
    if r == "host" then notify.show("You're already hosting.", "info"); return end
    if r and not p1().can_switch() then
        notify.show("Leave the host's world first, then you can host.", "info")
        return
    end
    p1().init(cfg, "host")
    set_accepted({})
    link.bridge_cmd("password " .. password)
    notify.show("You're hosting" .. (password ~= "" and " with a password" or "") .. ". Friends join you from the CO-OP tab of their handbook (J).", "good")
end

local joined_peer = nil
local sent_password = ""
local function join(steamid, who)
    local r = my_role()
    if r == "host" then
        if not p1().can_switch() then
            notify.show("Someone is in your world. They need to leave before you can join someone else.", "bad")
            return
        end
        r = nil
    end
    if instance.duplicate() then
        notify.show("This game is already running from the same folder, so joining is blocked. "
            .. "Run a second game from a separate install.", "bad")
        return
    end
    if r == "guest" then
        if session.state() ~= "idle" then
            notify.show("You're already in co-op.", "info")
            return
        end
        if (not steamid or steamid == "" or steamid == joined_peer) and password ~= sent_password then
            sent_password = password
            link.set_join_password(password)
            link.bridge_cmd("join " .. tostring(joined_peer or 0) .. (password ~= "" and (" " .. password) or ""))
            pending_join = true
            notify.show("Asking " .. (who or link.peer_name()) .. " again...", "info")
            return
        end
        if not steamid or steamid == "" or steamid == joined_peer then session.request_toggle(); return end
    end
    joined_peer = steamid
    sent_password = password
    link.set_join_password(password)
    p1().init(cfg, "guest", steamid)
    pending_join = true
    wait_since, wait_told, wait_who = os.clock(), nil, who
    notify.show("Asked " .. (who or "the host") .. " to join - waiting for them to accept...", "info", "join_wait")
end

local stopping = nil
local function stop_hosting()
    if my_role() ~= "host" then notify.show("You're not hosting.", "info"); return end
    if stopping then notify.show("Stopping - one moment.", "info"); return end
    stopping = { t = 0.0 }
    p1().say_bye()
    session.save_now()
    log.info("menu: stop hosting - guest told, world saving")
    notify.show("Stopping the session: saving your world and sending your friend home...", "info")
end
local function stopping_tick(dt)
    if not stopping then return end
    stopping.t = stopping.t + dt
    local w = p1().peer_where()
    local guest_in = w == "joined" or w == "loading" or w == "arriving" or w == "leaving"
    if guest_in and stopping.t < 15 then return end
    if stopping.t < 1.5 then return end
    if guest_in then log.warn("menu: stop hosting - the guest didn't leave within 15 s (unreachable?) - stopping anyway") end
    p1().stop()
    stopping = nil
    notify.show("You stopped hosting. Your world is saved.", "good")
end

local function leave()
    if my_role() == "guest" and session.state() == "joined" then session.request_toggle()
    else notify.show("You're not in someone else's world.", "info") end
end

local function copy_code(code)
    if not code then return end
    local ok = pcall(function()
        local h = io.popen("clip", "w")
        h:write(code)
        h:close()
    end)
    notify.show(ok and ("Your friend code " .. code .. " was copied. Send it to your friend.") or
        ("Your friend code: " .. code), "good")
end

local function status_text()
    local r, l = my_role(), link.lobby()
    if not r then
        return "Not in co-op. Host so friends can join you, or join a friend below."
    end
    if r == "host" then
        local who = l and l.peer and l.peer.name
        return who and ("Hosting - " .. who .. (l.peer.connected and " is connected" or " is connecting"))
            or "Hosting - waiting for a friend to join"
    end
    local st = session.state()
    if st == "joined" then return "In " .. link.peer_name() .. "'s world - Leave takes you back to yours" end
    if st ~= "idle" then return "Joining " .. link.peer_name() .. "..." end
    if p1().connected() then return "Connected to " .. link.peer_name() .. " - Join enters their world" end
    return "Looking for the host..."
end

local function model()
    local l, r = link.lobby(), my_role()
    local steam = link.kind() == "steam"
    local m = { steam = steam, playing_slot = session.playing_slot() }
    m.hosts = {}
    local seen = {}
    for _, h in ipairs((l and l.hosts) or {}) do
        seen[h.id] = true
        m.hosts[#m.hosts + 1] = { id = h.id, name = h.name, label = h.name, joinable = true }
    end
    local PROTO = tostring(require("mirror.version").PROTOCOL)
    for _, sv in ipairs((l and l.servers) or {}) do
        if not seen[sv.id] then
            local tags, ok = { "public", sv.players }, true
            if sv.locked then tags[#tags + 1] = "password" end
            if sv.players == "2/2" then tags[#tags + 1] = "full"; ok = false end
            if sv.proto ~= "?" and sv.proto ~= PROTO then tags[#tags + 1] = "other version"; ok = false end
            m.hosts[#m.hosts + 1] = { id = sv.id, name = sv.name, label = sv.name .. " (" .. table.concat(tags, ", ") .. ")", joinable = ok }
        end
    end
    m.public_state = r == "host" and l and l.public or nil
    m.show_voice = r ~= nil
    m.voice_label, m.voice_vol = require("mirror.voice").label()
    if l and l.voice == "talking" then m.voice_label = "VOICE: TALKING" end
    m.settings = require("mirror.hostrules").rows()
    m.settings_editable = require("mirror.hostrules").can_edit()
    if steam then
        m.me = l and ("Signed in as " .. (l.name or "?")) or
            "The Steam connection isn't running. Make sure Steam is running and your antivirus isn't blocking SurrounSyncBridge."
        m.code = l and l.code or nil
    else
        m.me = "One-PC test mode: both games talk through files on this PC."
    end
    m.status = status_text()
    local who = link.peer_name()
    if not r then
        m.headline, m.detail = "NOT IN CO-OP", "Host a game so friends can join you, or join a friend who is hosting."
    elseif r == "host" then
        local p = l and l.peer
        m.headline = "HOSTING"
        m.detail = p and (p.name .. (p.connected and " is connected." or " is connecting...")) or "Waiting for a friend to join."
    elseif session.state() == "joined" then
        m.headline = "IN " .. who:upper() .. "'S WORLD"
        m.detail = "Leave any time - your character goes home with everything you have."
    elseif session.state() ~= "idle" then
        m.headline, m.detail = "JOINING " .. who:upper() .. "...", "Saving your game and loading their world."
    else
        m.headline = p1().connected() and ("CONNECTED TO " .. who:upper()) or "LOOKING FOR THE HOST..."
        m.detail = "Choose JOIN to enter their world."
    end
    m.requests = (r == "host" and l and l.requests) or {}
    m.allowed = (r == "host" and l and l.allowed) or 0
    m.show_host = r == nil or (r == "guest" and session.state() == "idle")
    m.show_join_local = (not steam and r ~= "host") or (r == "guest" and session.state() == "idle")
    m.show_leave = r == "guest" and session.state() == "joined"
    m.show_stop = r == "host"
    m.show_chat = r ~= nil
    m.password_on = r == "host" and l and l.password or false
    m.chat = require("mirror.chat").recent(3)
    m.tp = require("mirror.teleport").pending()
    m.update = l and l.update or nil
    m.show_report = steam
    m.host_gone = r == "guest" and session.host_gone() ~= nil
    return m
end

local function join_code(txt)
    local id = to_steamid(txt)
    if id then join(id, "code " .. txt:gsub("%s", ""))
    else notify.show("That code doesn't look right. Use the number shown in your friend's co-op menu.", "bad") end
end

local update_told = false
local report_asked_at, report_seen = nil, nil
local errors_told, errors_told_at = 0, -1000
local function update()
    if link.bridge_cmd("update") then
        notify.show("The SurrounSync updater is open - it installs the update when you close the game.", "good")
    else
        notify.show("Updates need the Steam connection. Run SurrounSync Setup from the Start menu instead.", "bad")
    end
end
local function send_report(message)
    message = tostring(message or ""):gsub("\r", ""):gsub("[%z\1-\9\11-\31]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #message > 1500 then message = message:sub(1, 1500) end
    if report_asked_at then
        notify.show("A bug report is already being sent - you'll see here when it's done.", "info")
        return
    end
    if not link.bridge_cmd(message ~= "" and ("report " .. message) or "report") then
        notify.show("Bug reports need the Steam connection. Run SurrounSync Setup -> BUG REPORT instead.", "bad")
        return
    end
    report_asked_at = os.clock()
    notify.show("Saving a bug report and sending it to the SurrounSync developer...", "info")
end
-- asks what went wrong first; SEND makes and sends the report with that message
local function report()
    if not require("mirror.names").ask({ title = "BUG REPORT - ANYTHING ELSE TO ADD?", multiline = true, ok = "SEND", clear = false,
                                         hint = "What happened, and what were you doing just before? (optional)",
                                         done = send_report }) then
        send_report("")
    end
end
local function watch_release()
    local l = link.lobby()
    if l and l.update and not update_told and util.valid(game.player()) then
        update_told = true
        notify.show("SurrounSync " .. l.update .. " is out. Open the handbook (J) -> CO-OP -> UPDATE.", "info")
    end
    local r = l and (l.report or l.report_error)
    if r and r ~= report_seen then
        local first = report_seen == nil and report_asked_at == nil
        report_seen = r
        if not first then
            report_asked_at = nil
            if l.report and l.report_sent == "ok" then
                notify.show("Bug report sent to the SurrounSync developer (a copy is on your desktop). Tell them what "
                    .. "you were doing when it went wrong.", "good")
            elseif l.report then
                local why = (l.report_sent or ""):match("^failed:(.*)$")
                notify.show("Bug report saved on your desktop: " .. (l.report:match("[^\\]+$") or l.report)
                    .. (why and (" - couldn't send it (" .. why .. ")") or "") .. ". Send it to the SurrounSync developer.",
                    why and "bad" or "good")
            else
                notify.show("Couldn't save the bug report (" .. l.report_error .. "). Run SurrounSync Setup -> BUG REPORT.", "bad")
            end
        end
    elseif report_asked_at and os.clock() - report_asked_at > 180 then
        report_asked_at = nil
        notify.show("The bug report didn't come back. Run SurrounSync Setup -> BUG REPORT instead.", "bad")
    end
    local n = util.error_count()
    if n > errors_told and os.clock() - errors_told_at > 600 and util.valid(game.player()) then
        errors_told, errors_told_at = n, os.clock()
        notify.show("SurrounSync hit a problem. If something isn't working: J -> CO-OP -> BUG REPORT, and send it in.", "info")
    end
end

local bridge_dead_for, bridge_warned, bridge_check_in = 0.0, false, 0.0
local bridge_restarted_at = nil

local function answer(cmd, id, name)
    if not link.bridge_cmd(cmd .. " " .. id) then notify.show("Couldn't reach the Steam connection.", "bad"); return end
    local said = { accept = " can join now.", allow = " can join now - and always will without asking.",
                   decline = " was turned away." }
    notify.show((name or id) .. said[cmd], cmd == "decline" and "info" or "good")
    local t = accepted_ids(); t[tostring(id)] = cmd ~= "decline" or nil; set_accepted(t)
end
local seen_requests, last_kick, last_joinerror = {}, nil, nil
local JOIN_ERRORS = {
    needpass = "This host needs a password. Type it in the PASSWORD box (CO-OP tab) and join again.",
    badpass = "Wrong password. Check it with the host and join again.",
    blocked = "Too many wrong passwords. The host has to host again before you can retry.",
    declined = "The host declined your request to join.",
}
local function watch_requests()
    local l = link.lobby()
    if l and l.joinerror ~= last_joinerror then
        last_joinerror = l.joinerror
        if l.joinerror and JOIN_ERRORS[l.joinerror] then
            notify.show(JOIN_ERRORS[l.joinerror], "bad", "join_wait")
            pending_join, wait_since = false, nil
        end
    end
    if not (l and my_role() == "host") then return end
    local now_ids = {}
    for _, q in ipairs(l.requests or {}) do
        now_ids[q.id] = true
        -- Steam only names your friends; the joining player sends their name a moment after asking
        local name = (q.name and q.name ~= "Someone" and q.name ~= tostring(q.id)) and q.name or nil
        if not seen_requests[q.id] and accepted_ids()[tostring(q.id)] then
            link.bridge_cmd("accept " .. q.id)
            log.info("menu: " .. (name or q.id) .. " rejoined - accepted earlier this session")
        elseif not request_nag[q.id] then
            request_seen_at[q.id] = request_seen_at[q.id] or os.clock()
            if name or os.clock() - request_seen_at[q.id] > 2 then
                log.info("menu: join request from " .. (name or "?") .. " (" .. q.id .. ")")
                notify.show((name or "Someone") .. " wants to join your world - open the handbook (J), CO-OP tab, to ACCEPT or DECLINE.",
                    "good", "join_req_" .. q.id)
                notify.ping(2)
                request_nag[q.id] = os.clock()
            end
        elseif os.clock() - request_nag[q.id] > 30 then
            request_nag[q.id] = os.clock()
            notify.show((name or "Someone") .. " is still waiting to join - handbook (J), CO-OP tab.", "info", "join_req_" .. q.id)
        end
    end
    for id in pairs(request_nag) do if not now_ids[id] then request_nag[id] = nil end end
    for id in pairs(request_seen_at) do if not now_ids[id] then request_seen_at[id] = nil end end
    seen_requests = now_ids
    local k = l.kicked and l.kicked.id
    if k and k ~= last_kick then
        local t = accepted_ids(); t[tostring(k)] = nil; set_accepted(t)
        notify.show(l.kicked.name .. " was disconnected (sent too much data). They can't rejoin until you host again.", "bad")
    end
    last_kick = k
end

local function tick(dt)
    util.safe(require("mirror.hostrules").tick, "hostrules.tick")
    -- the rename / bug report box runs in single player too (it used to tick only in a co-op session,
    -- so SEND in a solo game did nothing)
    util.safe(require("mirror.names").tick, "names.tick", dt)
    instance.tick(dt, function()
        notify.show("This game is already running from the same folder. Run a second game from a separate install.", "bad")
    end)
    bridge_check_in = bridge_check_in - dt
    local alive = nil
    if bridge_check_in <= 0 then bridge_check_in = 1.0; alive = link.bridge_alive() end
    if alive == false then
        bridge_dead_for = bridge_dead_for + 1.0
        if my_role() and bridge_dead_for >= 8 and (bridge_restarted_at or -100) < os.clock() - 30 then
            bridge_restarted_at = os.clock()
            local extra = (my_role() == "host" and password ~= "") and { "password " .. password } or nil
            if link.restart_bridge(extra) then
                log.warn("menu: the Steam connection (SurrounSyncBridge) stopped - restarted it")
                notify.show("The connection program stopped - restarted it, reconnecting...", "info")
            end
        end
        if bridge_dead_for > 15 and not bridge_warned then
            bridge_warned = true
            log.warn("menu: SurrounSyncBridge isn't running (no lobby/status file for 15 s)")
            notify.show("The Steam connection (SurrounSyncBridge) isn't running. Make sure Steam is running and your antivirus "
                .. "isn't blocking it, then restart the game.", "bad")
        end
    elseif alive then
        bridge_dead_for = 0.0
    end
    if not my_role() then link.idle_tick(dt); notify.tick(dt) end
    if bridge_check_in == 1.0 then watch_requests(); watch_release() end
    if want_host then want_host = false; host() end
    stopping_tick(dt)
    if want_join then
        local i = want_join; want_join = nil
        local h = ((link.lobby() or {}).hosts or {})[i]
        if h then join(h.id, h.name) else notify.show("Friend #" .. i .. " isn't hosting.", "info") end
    end
    if pending_join and wait_since and my_role() == "guest" and not p1().connected() then
        local t = os.clock()
        if t - (wait_told or wait_since) >= 20 then
            wait_told = t
            notify.show("Still waiting for " .. (wait_who or link.peer_name()) .. " to accept your request (" ..
                math.floor(t - wait_since) .. " s)...", "info", "join_wait")
        end
    end
    if pending_join and my_role() == "guest" and p1().connected() then
        if wait_since then
            notify.show(link.peer_name() .. " accepted - joining their world...", "good", "join_wait")
            notify.ping(1)
        end
        wait_since = nil
        pending_join = false
        if session.state() == "idle" then session.request_toggle() end
    end
    journal_tab.tick(dt)
end

function menu.dev_host() host() end
function menu.dev_join() join(nil, nil) end
function menu.dev_stop() stop_hosting() end
function menu.dev_accept(id) answer("accept", id) end
function menu.dev_act(name) journal_tab.act(name) end
local function set_password(pw)
    password = tostring(pw or "")
    if my_role() == "host" then
        link.bridge_cmd("password " .. password)
        notify.show(password ~= "" and "Password set. Friends type it before joining." or "Password removed.", "good")
    else
        notify.show(password ~= "" and "Password kept: used when you host or join." or "No password.", "info")
    end
end
menu.dev_password = set_password

function menu.init(c)
    cfg = c
    require("mirror.hostrules").init(my_role)
    require("mirror.itemclean").init(my_role)
    require("mirror.names").init()
    journal_tab.configure{
        model = model,
        act = {
            copy = function() copy_code((link.lobby() or {}).code) end,
            host = host, join = join, join_code = join_code, join_local = function() join(nil, nil) end,
            leave = leave, go_home = session.go_home_now, wait = session.wait_for_host,
            stop = stop_hosting,
            toggle_public = function()
                local l = link.lobby()
                local on = l and l.public and l.public ~= "off"
                if on then
                    link.bridge_cmd("public off")
                    notify.show("Your game is no longer listed.", "info")
                else
                    local name = ((l and l.name) or "Someone") .. "'s game"
                    link.bridge_cmd("public on " .. require("mirror.version").PROTOCOL .. " " .. name)
                    notify.show("Your game is listed in the server browser" .. (password ~= "" and " (with your password)" or "")
                        .. ". Anyone can ask to join - you still accept each one.", "good")
                end
            end,
            voice = function() require("mirror.voice").toggle() end,
            voice_vol = function() require("mirror.voice").cycle_volume() end,
            setting = function(key) require("mirror.hostrules").toggle(key) end,
            refresh = function()
                if link.bridge_cmd("browse") then notify.show("Looking for public games...", "info") end
            end,
            set_password = set_password,
            chat_send = function(txt) return require("mirror.chat").send(txt) end,
            tp_accept = function() require("mirror.teleport").accept() end,
            tp_decline = function() require("mirror.teleport").decline() end,
            update = update,
            report = report,
            accept = function(id, name) answer("accept", id, name) end,
            allow = function(id, name) answer("allow", id, name) end,
            decline = function(id, name) answer("decline", id, name) end,
            clear_allowed = function()
                if link.bridge_cmd("clearallow") then notify.show("Nobody joins without asking any more.", "info") end
            end,
        },
        backups = page,
        can_restore = function() return p1().can_switch() and not require("mirror.slotguard").log_exists() end,
    }
    game.keybind("H", { ModifierKey.CONTROL }, function() want_host = true end)
    for i, k in ipairs({ "One", "Two", "Three" }) do
        game.keybind(k, { ModifierKey.CONTROL }, function() want_join = i end)
    end
    game.on_tick(function(dt) util.safe(tick, "menu.tick", dt) end)
    game.on_ready(function()
        notify.show("SurrounSync is ready. Open the handbook (J) and choose CO-OP.", "info")
    end)
    log.info("menu: the co-op menu is the handbook's CO-OP tab (J)")
end

return menu
