-- Who may play a Realm: invite codes, keys for a new PC, and ADD TO REALM for a friend already in my Realm
-- session. Member keys never pass through here: the bridge makes, keeps and copies them (bridge/Realms.cs).
-- ADD TO REALM sends a one-time invite code over the co-op link; the friend's bridge redeems it for its own key.

local log = require("mirror.log")
local notify = require("mirror.notify")
local realm = require("mirror.realm")
local peers = require("mirror.peers")

local members = {}

local BLOB = "realm_invite"   -- "<realm id> <invite code> <realm name...>", host -> guest
local POLL = 1.0
local poll_in = 0.0
local redeemed = {}           -- invite codes already used this run

local function say(msg, kind) notify.show(msg, kind or "info") end

-- (the server sends codes already dashed, XXXX-XXXX-XXXX-XXXX: dashing them again gave "JFNK--PBT-9-62-KE-DX6E")
local function bare(code) return (tostring(code or ""):upper():gsub("[^0-9A-Z]", "")) end
local function pretty(code)
    code = bare(code)
    return code:sub(1, 4) .. "-" .. code:sub(5, 8) .. "-" .. code:sub(9, 12) .. "-" .. code:sub(13)
end

local INVITE_SHOWN = 15 * 60   -- the REALMS page keeps the last code selectable this long (seconds)
local last_invite = nil        -- { code = "XXXX-...", id, at }

-- INVITE: a one-time code for a friend who isn't online (valid 7 days). The bridge copies it to the clipboard
-- (an io.popen("clip") here froze the game for a second); the REALMS page also shows it in a selectable box.
function members.invite(id)
    if not (realm.enabled() and realm.valid_id(id)) then return end
    realm.send("invite", id .. " copy", function(ok, w, text)
        if not ok or not w[1] then say("Couldn't make an invite code (" .. text .. ").", "bad"); return end
        local code = pretty(w[1])
        last_invite = { code = code, id = id, at = os.time() }
        say((w[2] == "copied" and ("Invite code " .. code .. " copied.") or ("Invite code: " .. code .. "."))
            .. " Your friend adds it in their REALMS tab (ADD REALM). It works once, for 7 days.", "good")
    end)
end

-- the last INVITE code for the REALMS page, while it's fresh
function members.last_invite()
    if last_invite and os.time() - last_invite.at > INVITE_SHOWN then last_invite = nil end
    return last_invite
end

-- ADD REALM: redeem a code a member sent
function members.redeem(code)
    code = tostring(code or ""):gsub("%s", "")
    if not realm.enabled() or code == "" then return end
    realm.send("redeem", code, function(ok, w, text)
        if not ok then say("That invite code didn't work (" .. text .. ").", "bad"); return end
        say("You're a member of " .. (table.concat(w, " ", 2) ~= "" and table.concat(w, " ", 2) or "the Realm") .. " now.", "good")
        realm.send("list", "")
    end)
end

-- COPY MY KEY / USE A KEY: the same membership on another PC
function members.copy_key(id)
    if not (realm.enabled() and realm.valid_id(id)) then return end
    realm.send("copykey", id, function(ok, _, text)
        say(ok and "Your Realm key is copied. Keep it private: whoever has it plays as you in this Realm."
            or ("Couldn't copy your key (" .. text .. ")."), ok and "good" or "bad")
    end)
end

function members.use_key(text)
    text = tostring(text or ""):gsub("[%c]", "")
    if not realm.enabled() or text == "" then return end
    realm.send("usekey", text, function(ok, w, why)
        if not ok then say("That key didn't work (" .. why .. ").", "bad"); return end
        say("Key accepted: " .. (table.concat(w, " ", 2) ~= "" and table.concat(w, " ", 2) or "the Realm") .. " is back in your REALMS tab.", "good")
        realm.send("list", "")
    end)
end

-- ADD TO REALM (host, in a Realm session): the friend named `who` (nil = every friend here) becomes a member
function members.add(id, name, who)
    if not (realm.enabled() and realm.valid_id(id)) then return 0 end
    local n = 0
    peers.each("mirror.link", function(l)
        local peer = l.peer_name and l.peer_name()
        local st = l.peer_state and l.peer_state()
        if st ~= "ok" and st ~= "paused" then return end   -- (a link nobody is on)
        if who and peer ~= who then return end
        n = n + 1
        realm.send("invite", id, function(ok, w, text)
            if not ok or not w[1] then say("Couldn't add " .. tostring(peer) .. " to the Realm (" .. text .. ").", "bad"); return end
            -- (bare: the guest only takes [0-9A-Z]+ - the dashed code was dropped there, nobody was ever added)
            l.put_blob(BLOB, id .. " " .. bare(w[1]) .. " " .. tostring(name or id))
            log.info("realmmembers: invite sent to " .. tostring(peer))
            say(tostring(peer) .. " is being added to " .. tostring(name or "the Realm") .. ".", "good")
        end)
    end)
    if n == 0 then say("Nobody to add right now.", "info") end
    return n
end

-- guest: an invite from the host I play with
local function poll()
    local b = require("mirror.link").get_blob(BLOB)
    if not b then return end
    local id, code, name = b:match("^(%S+) (%S+) ?(.*)$")
    code = code and bare(code)
    if not (id and realm.valid_id(id) and code and code:match("^[0-9A-Z]+$")) or redeemed[code] then return end
    redeemed[code] = true
    if realm.find(id) then log.info("realmmembers: already a member of " .. id); return end
    log.info("realmmembers: the host added me to Realm " .. id)
    realm.send("redeem", code, function(ok, _, text)
        if not ok then say("Couldn't join the Realm " .. name .. " (" .. text .. ").", "bad"); return end
        say("You're now a member of the Realm " .. (name ~= "" and name or id) .. ". Find it in your REALMS tab.", "good")
        realm.send("list", "")
    end)
end

function members.tick(dt)
    if not realm.enabled() then return end
    poll_in = poll_in - dt
    if poll_in > 0 then return end
    poll_in = POLL
    if peers.role() == "guest" or require("mirror.menu").role() == "guest" then poll() end
end

return members
