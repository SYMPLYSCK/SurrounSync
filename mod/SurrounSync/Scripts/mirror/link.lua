-- Connection to the other game: player positions, named state blobs and files. Over Steam this
-- goes through SurrounSyncBridge.exe; for testing, two games on one PC use plain files.

local log = require("mirror.log")

local link = {}

local cfg, backend, kind
local bridge_role = nil
local auto = false
local function app_dir()
    local base = (os.getenv("LOCALAPPDATA") or ".") .. "\\SurrounDead"
    return (cfg and cfg.link_dir) and (base .. "\\" .. cfg.link_dir) or base
end
link.dir = app_dir
local now = 0.0
local pose_q, pose_last = {}, nil
local blob_q, blob_out = {}, {}

local function sim() return cfg and cfg.netsim and cfg.netsim.enabled end
local function delay()
    local ns = cfg.netsim
    return ((ns.latency_ms or 0) + (math.random() * 2 - 1) * (ns.jitter_ms or 0)) / 1000
end

function link.configure(c)
    cfg = c
    kind = (c.transport == "steam") and "steam" or "file"
    backend = require("mirror.link_file")
    if backend.configure then backend.configure(c) end
end

function link.kind() return kind end
function link.same_clock() return kind == "file" end

local cmd_queue = {}
local last_role_cmd = nil
local after_restart = nil
local function cmd_path() return app_dir() .. "\\mirror_bridge_cmd.txt" end
local function flush_cmds()
    if #cmd_queue == 0 then return end
    local busy = io.open(cmd_path(), "rb")
    if busy then busy:close(); return end
    local f = io.open(cmd_path(), "wb")
    if not f then return end
    f:write(table.remove(cmd_queue, 1))
    f:close()
end
function link.bridge_cmd(text)
    if kind ~= "steam" then return false end
    cmd_queue[#cmd_queue + 1] = text
    flush_cmds()
    return true
end

function link.restart_bridge(extra)
    if kind ~= "steam" or not auto then return false end
    cmd_queue = {}
    os.remove(cmd_path())
    os.remove(app_dir() .. "\\mirror_lobby.txt")
    local role = bridge_role
    link.start_bridge("auto")
    bridge_role = role
    after_restart = {}
    if last_role_cmd then after_restart[#after_restart + 1] = last_role_cmd end
    for _, c in ipairs(extra or {}) do after_restart[#after_restart + 1] = c end
    return true
end
local function resend_after_restart()
    if not after_restart or not link.bridge_alive() then return end
    for _, c in ipairs(after_restart) do cmd_queue[#cmd_queue + 1] = c end
    after_restart = nil
end

local join_password = ""
function link.set_join_password(pw) join_password = tostring(pw or ""):gsub("[\r\n]", "") end

function link.open(role, peer_id)
    if not backend then link.configure({ transport = "file" }) end
    local a, b = backend.open(role)
    bridge_role = role
    if kind == "steam" then
        if auto then
            local c = role == "host" and "host" or ("join " .. tostring(peer_id or 0)
                .. (join_password ~= "" and (" " .. join_password) or ""))
            last_role_cmd = c
            if not link.bridge_cmd(c) then log.error("link: couldn't tell the bridge to " .. role) end
        else
            link.start_bridge(role)
        end
    end
    if sim() then
        log.info(string.format("link: NETSIM on - latency %d ms +-%d, loss %.0f%%",
            cfg.netsim.latency_ms or 0, cfg.netsim.jitter_ms or 0, (cfg.netsim.loss or 0) * 100))
    end
    return a, b
end

function link.tick(dt)
    resend_after_restart()
    flush_cmds()
    now = now + dt
    if backend.tick then backend.tick(dt) end
    if sim() then
        local seq, payload = backend.poll()
        if seq and math.random() >= (cfg.netsim.loss or 0) then
            pose_q[#pose_q + 1] = { t = now + delay(), seq = seq, payload = payload }
        end
    end
end

function link.send(seq, line) return backend.send(seq, line) end

function link.poll()
    if not sim() then return backend.poll() end
    local best, keep = nil, {}
    for _, e in ipairs(pose_q) do
        if e.t <= now then
            if not best or e.seq > best.seq then best = e end
        else
            keep[#keep + 1] = e
        end
    end
    pose_q = keep
    if best and (not pose_last or best.seq ~= pose_last) then
        pose_last = best.seq
        return best.seq, best.payload
    end
    return nil
end

function link.put_blob(name, text) return backend.put_blob(name, text) end

function link.get_blob(name)
    if not sim() then return backend.get_blob(name) end
    local body = backend.get_blob(name)
    local q = blob_q[name] or {}
    blob_q[name] = q
    if body then q[#q + 1] = { t = now + delay(), body = body } end
    local out
    while q[1] and q[1].t <= now do out = table.remove(q, 1).body end
    if out and out ~= blob_out[name] then blob_out[name] = out; return out end
    return nil
end

function link.reset_blob(name)
    blob_out[name] = nil
    if backend.reset_blob then backend.reset_blob(name) end
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC = { B64:byte(1, 64) }
local PAD = 61
local function b64enc(data)
    local out, k, n = {}, 0, #data
    for i = 1, n, 3 do
        local a, b, c = data:byte(i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        k = k + 1
        out[k] = string.char(ENC[v // 262144 + 1], ENC[v // 4096 % 64 + 1],
            b and ENC[v // 64 % 64 + 1] or PAD, c and ENC[v % 64 + 1] or PAD)
    end
    return table.concat(out)
end
local DEC = {}
for i = 1, 64 do DEC[B64:byte(i)] = i - 1 end
local function b64dec(s)
    local out = {}
    s = s:gsub("[^%w%+/=]", "")
    for i = 1, #s, 4 do
        local c1, c2, c3, c4 = s:byte(i, i + 3)
        local v = (DEC[c1] or 0) * 262144 + (DEC[c2] or 0) * 4096 + (DEC[c3] or 0) * 64 + (DEC[c4] or 0)
        local b1, b2, b3 = math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256
        if c3 == 61 then out[#out + 1] = string.char(b1)
        elseif c4 == 61 then out[#out + 1] = string.char(b1, b2)
        else out[#out + 1] = string.char(b1, b2, b3) end
    end
    return table.concat(out)
end
link.b64enc, link.b64dec = b64enc, b64dec

function link.put_file(name, data, tag)
    return link.put_blob("file_" .. name, tostring(tag or "-") .. ":" .. #data .. ":" .. b64enc(data))
end

function link.get_file(name)
    local body = link.get_blob("file_" .. name)
    if not body then return nil end
    local tag, len, enc = body:match("^([^:]*):(%d+):(.*)$")
    if not len then return nil end
    local data = b64dec(enc)
    if #data ~= tonumber(len) then
        log.warn(string.format("link: file %s arrived damaged (%d of %s bytes)", name, #data, len))
        return nil
    end
    return data, tag
end

local clock_off, clock_read_at = 0, -100
function link.peer_age(stamp)
    if kind == "steam" and now - clock_read_at > 2 then
        clock_read_at = now
        local f = io.open(app_dir() .. "\\mirror_clock_offset.txt", "r")
        if f then clock_off = tonumber(f:read("*a")) or clock_off; f:close() end
    end
    if kind ~= "steam" then return os.time() - stamp end
    return os.time() - (stamp + clock_off) - 2
end

function link.start_bridge(role)
    bridge_role = role
    local dir = "ue4ss\\Mods\\SurrounSync\\bridge"
    local exe = dir .. "\\SurrounSyncBridge.exe"
    local f = io.open(exe, "rb")
    if not f then log.error("link: " .. exe .. " missing - run tools\\build-bridge.ps1 (or reinstall)"); return end
    f:close()
    local peer = cfg.steam and cfg.steam.peer or ""
    local extra = ""
    if cfg.link_dir then extra = extra .. ' --dir "' .. app_dir() .. '"' end
    if cfg.steam and cfg.steam.test_port then extra = extra .. " --test-net " .. cfg.steam.test_port end
    local cmd = string.format('start "" /min "%s" --role %s%s%s', exe, role,
        peer ~= "" and (" --peer " .. peer) or "", extra)
    local ok, err = pcall(function() os.execute(cmd) end)
    if not ok then
        log.error("link: couldn't start the bridge (" .. tostring(err) .. ") - start " .. exe .. " --role " .. role .. " yourself")
    else
        log.info("link: started SurrounSyncBridge (" .. role .. ") - Steam P2P; its log: "
            .. (role == "auto" and "mirror_bridge.log" or ("mirror_bridge_" .. role .. ".log")))
    end
end

function link.start_lobby()
    auto = true
    if kind == "steam" then link.start_bridge("auto") end
end

local lobby, lobby_read = nil, -100
function link.lobby()
    if kind ~= "steam" or not auto then return nil end
    if now - lobby_read < 1 then return lobby end
    lobby_read = now
    local f = io.open(app_dir() .. "\\mirror_lobby.txt", "r")
    if not f then lobby = nil; return nil end
    local s = f:read("*a") or ""
    f:close()
    if not s:find("\nEND\n", 1, true) then return lobby end
    local l = { hosts = {}, requests = {}, allowed = 0, servers = {} }
    for line in s:gmatch("[^\n]+") do
        local k, rest = line:match("^(%a+) (.*)$")
        if k == "me" then
            l.id, l.code, l.name = rest:match("^(%d+) (%d+) ?(.*)$")
        elseif k == "role" then
            l.role = rest
        elseif k == "peer" then
            local id, name, st = rest:match("^(%d+) (.-) (%a+)$")
            if id then l.peer = { id = id, name = name, connected = st == "connected" } end
        elseif k == "host" then
            local id, name = rest:match("^(%d+) ?(.*)$")
            if id then l.hosts[#l.hosts + 1] = { id = id, name = name ~= "" and name or id } end
        elseif k == "request" then
            local id, name = rest:match("^(%d+) ?(.*)$")
            if id then l.requests[#l.requests + 1] = { id = id, name = name ~= "" and name or id } end
        elseif k == "kicked" then
            local id, name = rest:match("^(%d+) ?(.*)$")
            if id then l.kicked = { id = id, name = name ~= "" and name or id } end
        elseif k == "allowed" then
            l.allowed = tonumber(rest) or 0
        elseif k == "password" then
            l.password = rest == "on"
        elseif k == "voice" then
            l.voice = rest
        elseif k == "public" then
            l.public = rest
        elseif k == "server" then
            local id, locked, players, proto, name = rest:match("^(%d+) (%d) (%S+) (%S+) ?(.*)$")
            if id then
                l.servers[#l.servers + 1] = { id = id, locked = locked == "1", players = players, proto = proto,
                                              name = (name ~= "" and name or id):gsub("_", " ") }
            end
        elseif k == "joinerror" then
            l.joinerror = rest
        elseif k == "update" then
            l.update = rest
        elseif k == "report" then
            l.report = rest
        elseif k == "reportsent" then
            l.report_sent = rest
        elseif k == "reporterror" then
            l.report_error = rest
        elseif k == "reporting" then
            l.reporting = true
        end
    end
    lobby = l.id and l or nil
    return lobby
end

function link.idle_tick(dt) now = now + dt; resend_after_restart(); flush_cmds() end

function link.status()
    local s = kind
    if kind == "steam" and bridge_role then
        local f = io.open(app_dir() .. "\\mirror_bridge_status_" .. bridge_role .. ".txt", "r")
        if f then s = f:read("*a") or s; f:close() else s = "steam: bridge not reporting (not running?)" end
    end
    if sim() then
        s = s .. string.format(" + netsim %d+-%d ms, %.0f%% loss", cfg.netsim.latency_ms or 0, cfg.netsim.jitter_ms or 0,
            (cfg.netsim.loss or 0) * 100)
    end
    return s
end

local peer_name, name_read_at = nil, -100
function link.peer_name()
    if kind == "steam" and bridge_role and now - name_read_at > 2 then
        name_read_at = now
        local f = io.open(app_dir() .. "\\mirror_peer_" .. bridge_role .. ".name", "r")
        if f then
            local s = (f:read("*a") or ""):gsub("^%s+", ""):gsub("%s+$", "")
            f:close()
            peer_name = s ~= "" and s or nil
        end
    end
    return peer_name or (bridge_role == "host" and "the guest" or (bridge_role and "the host" or "the other player"))
end

function link.bridge_alive()
    if kind ~= "steam" then return nil end
    local name = (auto or not bridge_role) and "mirror_lobby.txt" or ("mirror_bridge_status_" .. bridge_role .. ".txt")
    local f = io.open(app_dir() .. "\\" .. name, "rb")
    if not f then return false end
    local s = f:read("*a") or ""
    f:close()
    local t = tonumber(s:match(" at (%d+)") or s:match("\ntime (%d+)") or "")
    return t ~= nil and os.time() - t < 15
end

local ps_at, ps_val = -100, nil
function link.peer_state(rx_age)
    if os.clock() - ps_at < 1.0 and ps_val then return ps_val end
    ps_at = os.clock()
    ps_val = link.peer_state_now(rx_age)
    return ps_val
end

function link.peer_game_gone()
    if kind ~= "steam" or not link.bridge_alive() then return false end
    return link.status():match("peer_game (%S+)") == "gone"
end

function link.peer_state_now(rx_age)
    local c = cfg and cfg.save or {}
    if kind ~= "steam" then
        if rx_age == nil then return "unknown" end
        return rx_age > (c.file_link_gone_after or 45) and "gone" or "ok"
    end
    if not link.bridge_alive() then return "unknown" end
    local s = link.status()
    local hb, game = tonumber(s:match("peer_hb (%-?[%d.]+)") or ""), s:match("peer_game (%S+)")
    if game == "gone" then return "gone" end
    if not hb or hb < 0 then return "unknown" end
    if hb > (c.peer_gone_after or 15) then return "gone" end
    if rx_age and rx_age > 10 then return "paused" end
    return "ok"
end

function link.close() if backend and backend.close then backend.close() end end

return link
