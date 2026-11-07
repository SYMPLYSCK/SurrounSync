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

-- ---- the public server list (REALMS page, SERVERS) ----

local browsed_at = -100
-- A Realm server older than the list: it reads "public" as a Realm code (bad_input), or has no such route (not_found).
local NOT_ON_SERVER = { bad_input = true, not_found = true }
-- what the SERVERS tab says when the last browse failed (nil: it worked), or it would wait on "Getting the list..."
members.browse_failed = nil
-- the list from the server, at most every 10 s (force) or 60 s (the open tab's own refresh)
function members.browse(force)
    if not realm.enabled() then return end
    if os.time() - browsed_at < (force and 10 or 60) then return end
    browsed_at = os.time()
    realm.send("browse", "", function(ok, w, text)
        if ok then members.browse_failed = nil; return end
        members.browse_failed = NOT_ON_SERVER[w[1]] and "The server list isn't switched on yet."
            or "Couldn't get the server list. Trying again in a minute."
        if force then say(NOT_ON_SERVER[w[1]] and members.browse_failed or ("Couldn't get the server list (" .. text .. ")."), "bad") end
    end)
end

-- JOIN from the list: a membership of my own (locked Realms need the owner's password), then open it like any of
-- mine - a hosted one joins its host. The password goes to the bridge and the server only, never to the log.
function members.join_public(id, password, name)
    if not (realm.enabled() and realm.valid_id(id)) then return end
    password = tostring(password or ""):gsub("[%c]", "")
    realm.send("joinpublic", id .. (password ~= "" and (" " .. password) or ""), function(ok, w, text)
        if not ok then
            local why = w[1] == "bad_password" and (password == "" and "it needs the owner's password" or "wrong password")
                or w[1] == "full" and "it has no free places" or w[1] == "no_realm" and "it isn't on the list any more"
                or w[1] == "slow_down" and "too many tries, wait a while" or text
            say("Couldn't join " .. (name or realm.code(id)) .. " (" .. why .. ").", "bad")
            return
        end
        say("You're in " .. (name or realm.code(id)) .. " - opening it...", "good")
        realm.send("list", "", function() require("mirror.realmplay").open(id) end)
    end)
end

-- the owner's PUBLIC switch: on (open, or locked with a password) or off. Locking or taking it off removes the
-- players who joined from the list; invited members stay.
members.MIN_LIST_PASSWORD = 6   -- the server's MIN_PASSWORD
function members.set_public(id, on, password)
    if not (realm.enabled() and realm.valid_id(id)) then return end
    password = tostring(password or ""):gsub("[%c]", "")
    if on and password ~= "" and #password < members.MIN_LIST_PASSWORD then
        say("A server list password needs at least " .. members.MIN_LIST_PASSWORD .. " characters.", "bad")
        return
    end
    realm.send("public", id .. (on and (" on" .. (password ~= "" and (" " .. password) or "")) or " off"), function(ok, w, text)
        if not ok then
            local why = w[1] == "too_many_listed" and "this connection already has 3 Realms on the list"
                or w[1] == "delisted" and "it was taken off the server list for good"
                or w[1] == "slow_down" and "too many changes, wait a while"
                or w[1] == "not_found" and "it isn't switched on yet"
                or w[1] == "bad_input" and (text:gsub("^bad_input%s*", "")) or text
            say("Couldn't change the server list (" .. why .. ").", "bad")
            return
        end
        say(not on and "Your Realm is off the server list." or w[2] == "locked"
            and "Your Realm is on the server list, locked: players need your password to join."
            or "Your Realm is on the server list: anyone can join while you host it.", "good")
        browsed_at = -100
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
