-- Playing a Realm as its host: claim the lease, take the newest world from the server, play it in a co-op
-- save with my Realm character, upload after saves, and at the end hand the world back and go home.
-- My own save is never written: it is saved before the Realm loads and loaded again afterwards.
-- (Joining a Realm someone else hosts is the normal co-op join, with the Realm character: session.lua.)

local log = require("mirror.log")
local util = require("mirror.util")
local game = require("mirror.game")
local notify = require("mirror.notify")
local slotguard = require("mirror.slotguard")
local realm = require("mirror.realm")
local V = require("mirror.version")
local fs = require("mirror.fs")
local hostrules = require("mirror.hostrules")
local members = require("mirror.realmmembers")
local link = require("mirror.link")

local realmplay = {}

local cfg, session, menu
local UPLOAD_EVERY = 60.0      -- s between uploads after saves (the last one at the end always goes)
local SETTLE = 3.0             -- s in the loaded Realm before it counts as arrived
local S = nil                  -- the Realm session: { id, name, step, ... }

local left_by_menu
local function say(msg, kind) notify.show(msg, kind or "info") end
local function step(s) S.step, S.t = s, 0.0; log.info("realmplay: " .. s) end

-- bed names, bag owners and host rules belong to the world: while hosting, the mod uses the Realm's copies
local RULES = "mirror_host_settings.txt"
local function open_live(side)
    side = side or {}
    if (side[RULES] or "") == "" then side[RULES] = fs.read(hostrules.own_file()) end   -- (a new Realm starts with mine)
    local ok, err = realm.open_live(S.id, side)
    if not ok then return nil, err end
    S.live = true
    hostrules.use_file(realm.live_dir(S.id) .. "\\" .. RULES)
    return true
end
local function close_live()
    if not (S and S.live) then return end
    S.live = false
    hostrules.use_file(nil)
end

local function session_log(st)
    return { step = st, own = S.own, coop = S.coop, own_stamp = S.own_stamp, realm = S.id, gen = tostring(S.gen or 0),
             time = os.date("%Y-%m-%d %H:%M:%S"), version = V.VERSION }
end

local function abort(msg)
    log.warn("realmplay: stopped - " .. msg)
    close_live()
    if S and S.leased then realm.send("release", S.id) end
    if S and S.coop and S.built then slotguard.purge(S.coop) end
    if S and S.logged then slotguard.log_clear() end
    S = nil
    say(msg, "bad")
end

function realmplay.active() return S ~= nil end
-- ADD TO REALM: friends in the Realm I host (who = a friend's name, nil = everyone here) become members
function realmplay.add_members(who)
    if not (S and S.step == "playing") then say("Host a Realm first.", "info"); return end
    members.add(S.id, S.name, who)
end
function realmplay.state() return S and S.step or "idle", S and S.id end

-- ---- what the REALMS tab shows (journal_tab.refresh_realms) ----

local STEP_TEXT = {
    creating = "Creating the Realm...",
    armed = "Taking you to the New Game screen. Pick your character and the settings, then press PLAY.",
    new_game = "Starting the Realm's first day...", capturing = "Saving the Realm's first day...",
    claim_new = "Sending the new world to the Realm...",
    claim = "Asking the Realm who's playing...", pending_upload = "Sending your last session first...",
    download = "Downloading the newest world...", saving_own = "Saving your own world first...",
    loading = "Loading the Realm...",
    playing = "You're hosting. Members join you from their REALMS tab.",
    stopping = "Sending your friends home...", ending_save = "Saving the Realm...", ending_upload = "Uploading the Realm...",
    going_home = "Taking you back to your own world...",
}
local function plural(n, what) return n .. " " .. what .. (n == 1 and "" or "s") end
-- hosting, or inside someone's world. (A guest who left keeps the link role "guest" with the session idle -
-- refusing every role locked anyone who had joined a friend out of their Realms until a restart.)
local function in_coop()
    return (menu ~= nil and menu.role() == "host") or (session ~= nil and session.state() ~= "idle")
end

-- "Ann (owner) - hosting   Bob - here   Cy" : every member of the Realm, the ones playing first.
-- here = in this session with me (my name + the players the bridge has connected), hosting = holds the lease.
local function people_text(r, in_session)
    if not r or not r.people or #r.people == 0 then return nil end
    local on = {}
    local l = in_session and link.lobby() or nil
    if l then
        if l.name and l.name ~= "" then on[l.name] = true end
        if l.peer and l.peer.connected and l.peer.name then on[l.peer.name] = true end
        for _, p in ipairs(l.players or {}) do if p.state ~= "connecting" then on[p.name] = true end end
    end
    local first, rest = {}, {}
    for _, p in ipairs(r.people) do
        local st = (r.host and p.steam == r.host) and "hosting" or (on[p.name] and "here") or nil
        local s = p.name .. (p.owner and " (owner)" or "") .. (st and (" - " .. st) or "")
        if st then first[#first + 1] = s else rest[#rest + 1] = s end
    end
    for _, s in ipairs(rest) do first[#first + 1] = s end
    return table.concat(first, "     ")
end

function realmplay.model()
    local svc = realm.service()
    local joined = session and session.realm_joined()
    local m = { service = svc, rows = {}, hosting = S ~= nil and S.step == "playing", armed = S ~= nil and S.step == "armed",
                free = S == nil and not in_coop() }
    m.invite = members.last_invite and members.last_invite() or nil
    if svc == nil then m.note = "Waiting for the Steam connection..."
    elseif svc == "unset" then m.note = "This version has no Realms server set up yet." end
    for _, r in ipairs(realm.list()) do
        local info, open
        local here = (S and S.id == r.id) or joined == r.id
        -- (short: one line of the handbook's wide capitals on the note)
        if r.offline then
            info, open = "Server out of reach - last copy kept", nil
        elseif r.host then
            info, open = "LIVE: " .. (r.host_name or "a member") .. " is playing", "JOIN"
        elseif (r.gen or 0) < 1 then
            info = r.role == "owner" and "No world yet - START it" or "No world yet"
            open = r.role == "owner" and "START" or nil
        else
            info, open = "Nobody's on - OPEN to host it", "OPEN"
        end
        if not r.offline then
            -- (no "save <gen>": the upload count meant nothing to players)
            info = info .. " | " .. plural(r.members or 0, "member")
        end
        m.rows[#m.rows + 1] = { id = r.id, name = r.name, info = info, open = open, live = r.host ~= nil, here = here,
                                owner = r.role == "owner" }
    end
    if S then
        local r = S.id and realm.find(S.id)
        m.state = STEP_TEXT[S.step] or "One moment..."
        -- opened before the list came in (dev/KEY path): the card showed the code until now
        if r and r.name and r.name ~= "" and S.name == realm.code(S.id) then S.name = r.name end
        m.current = { id = S.id, name = S.name, code = S.id and realm.code(S.id) or nil,
                      info = r and plural(r.members or 0, "member") or nil,
                      people = people_text(r, S.step == "playing") }
    elseif joined then
        local r = realm.find(joined)
        m.state = "You're playing in " .. (r and r.name or "a Realm") .. (r and r.host_name and (", hosted by " .. r.host_name) or "") .. "."
        -- a visiting member gets the card too (who's in, INVITE CODE / COPY MY KEY)
        m.visiting = true
        m.current = { id = joined, name = r and r.name or realm.code(joined), code = realm.code(joined),
                      info = r and plural(r.members or 0, "member") or nil,
                      people = people_text(r, true) }
    end
    return m
end

-- the REALMS tab's buttons
function realmplay.open(id, how)
    if how == "START" then realmplay.create_world(id) else realmplay.start(id) end
end
local listed_at = -100
-- The bridge deletes its command file when it starts, so a list asked for before then was lost ("list failed:
-- timeout" at every game start). Until its Realms file was written this run, the list waits (tick sends it).
local booted, list_wanted = nil, true
local function bridge_up() return booted ~= nil and (realm.service_at() or 0) >= booted - 1 end
function realmplay.refresh_list(force)
    local now = os.time()
    if not realm.enabled() then return end
    if not bridge_up() then list_wanted = true; return end
    if now - listed_at < (force and 3 or 10) then return end
    listed_at, list_wanted = now, false
    realm.send("list", "")
end

-- ---- start ----

function realmplay.start(id)
    if not realm.enabled() then return end
    if S then say("You're already in a Realm.", "info"); return end
    if not realm.valid_id(id) then return end
    if in_coop() then
        say("Stop hosting or leave your friend's world first, then open the Realm.", "info")
        return
    end
    if slotguard.log_exists() then say("A co-op session isn't finished yet. Restart the game, then try again.", "bad"); return end
    local cur = session.current_name()
    if not cur or not slotguard.is_own(cur) then say("Load one of your own saves first, then open the Realm.", "bad"); return end
    local r = realm.find(id)
    S = { id = id, name = r and r.name or realm.code(id), t = 0.0 }
    step("claim")
    say("Opening " .. S.name .. "...")
    realm.send("claim", id, function(ok, w, text)
        if not S or S.id ~= id then return end
        if not ok then abort("Couldn't reach the Realm (" .. text .. ")."); return end
        if w[1] == "hosted" then
            -- somebody already hosts it: join them like any co-op host (R4)
            local steam, who = w[2], table.concat(w, " ", 3)
            S = nil
            local function join_host()
                log.info("realmplay: " .. id .. " is hosted by " .. steam .. " - joining")
                menu.realm_join(steam, who ~= "" and who or nil)
                session.realm_guest(id)
            end
            if steam and steam ~= "0" and (realm.has_character(id) or realm.starter(id)) then
                join_host()
            elseif steam and steam ~= "0" then
                -- first visit: the Realm's starter character comes with its newest world
                realm.send("download", id, function(got, d, why)
                    local gen, err = nil, why
                    if got and d[1] ~= "none" then gen, err = realm.accept_download(id, tonumber(d[1]) or 0) end
                    if not gen then log.warn("realmplay: no starter character for the first visit (" .. tostring(err) .. ")") end
                    join_host()
                end)
            else
                say("Someone is opening this Realm right now. Try again in a moment.", "info")
            end
            return
        end
        S.leased, S.server_gen = true, tonumber(w[2]) or 0
        realmplay.after_claim()
    end)
end

-- a world that didn't reach the server last time goes first, if nothing newer came since
function realmplay.after_claim()
    local id = S.id
    local p = realm.pending(id)
    if p and p.base == S.server_gen then
        step("pending_upload")
        local ok, why = realm.stage_upload(id, p.files, p.side)
        if not ok then log.warn("realmplay: pending world can't be staged: " .. tostring(why)); realm.drop_pending(id); return realmplay.after_claim() end
        realm.send("upload", id .. " " .. (S.server_gen + 1), function(good, _, text)
            if not S or S.id ~= id then return end
            if good then
                S.server_gen = S.server_gen + 1
                realm.store_world(id, S.server_gen, p.files, p.side)
                log.info("realmplay: last session's world uploaded as generation " .. S.server_gen)
            else
                log.warn("realmplay: last session's world not uploaded (" .. text .. ")")
            end
            realm.drop_pending(id)
            realmplay.fetch()
        end)
        return
    elseif p then
        log.warn(string.format("realmplay: last session's world (on top of %d) is older than the Realm's %d - dropped",
            p.base, S.server_gen))
        say("Your last session in this Realm didn't reach the server and someone played since, so it was left out.", "bad")
        realm.drop_pending(id)
    end
    realmplay.fetch()
end

function realmplay.fetch()
    local id = S.id
    if S.server_gen < 1 then abort("This Realm has no world yet. Its owner starts it with a New Game (REALMS tab)."); return end
    if realm.head(id) == S.server_gen and realm.world(id) then
        S.gen = S.server_gen
        return realmplay.save_own()
    end
    step("download")
    realm.send("download", id, function(ok, w, text)
        if not S or S.id ~= id then return end
        if not ok or w[1] == "none" then abort("Couldn't download the Realm's world (" .. text .. ")."); return end
        local gen, why = realm.accept_download(id, tonumber(w[1]) or 0)
        if not gen then abort("The Realm's world arrived damaged (" .. tostring(why) .. ")."); return end
        S.gen = gen
        realmplay.save_own()
    end)
end

function realmplay.save_own()
    step("saving_own")
    session.save_now()
end

local function build()
    local own = session.current_slot()
    if not slotguard.is_own(own) then abort("Couldn't tell which save you're on, so the Realm didn't open."); return end
    local w = realm.world(S.id)
    if not w then abort("The Realm's world is missing on this PC."); return end
    S.own, S.own_stamp = own, slotguard.stamp(own)
    S.coop = session.next_coop_slot()
    if not S.coop or not S.own_stamp then abort("Couldn't prepare a save for the Realm."); return end
    slotguard.purge(S.coop)
    if not slotguard.log_write(session_log("building")) then abort("Couldn't record the Realm session."); return end
    S.logged = true
    -- (first time here: the Realm's starter character, or a fresh one the game makes)
    local character = realm.character(S.id) or realm.starter(S.id)
    S.fresh = character == nil
    local ok, err = slotguard.build_realm(S.coop, w.files, character)
    S.built = true
    if not ok then abort("Couldn't prepare the Realm's save (" .. tostring(err) .. ")."); return end
    if not slotguard.log_write(session_log("joined")) then abort("Couldn't record the Realm session."); return end
    local live, why = open_live(w.side)
    if not live then abort("Couldn't prepare the Realm's files (" .. tostring(why) .. ")."); return end
    log.info(string.format("realmplay: %s generation %d in %s, %s character, home is %s", S.id, S.gen, S.coop,
        S.fresh and "a fresh" or "my Realm", own))
    step("loading")
    session.load_slot(S.coop)
end

-- ---- in the Realm ----

local function upload(final, done)
    local id = S.id
    local world, character = slotguard.read_realm(S.coop)
    if not world then log.error("realmplay: can't read the Realm save: " .. tostring(character)); if done then done(false) end; return end
    if character then
        local ok, err = realm.store_character(id, character)
        if not ok then log.error("realmplay: Realm character not stored: " .. tostring(err)) end
    end
    if S.lost then if done then done(false) end; return end
    local side = realm.read_live(id)
    local ok, why = realm.stage_upload(id, world, side)
    if not ok then log.error("realmplay: world not staged: " .. tostring(why)); if done then done(false) end; return end
    S.uploading = true
    local gen = S.gen + 1
    realm.send("upload", id .. " " .. gen, function(good, w, text)
        if not S or S.id ~= id then return end
        S.uploading = false
        if good then
            S.gen, S.last_up = gen, S.clock
            realm.store_world(id, gen, world, side)
            slotguard.log_write(session_log("joined"))
            log.info("realmplay: uploaded generation " .. gen .. (final and " (final)" or ""))
        elseif w[1] == "lease_lost" or w[1] == "stale" then
            S.lost = true
            say("Someone else is hosting this Realm now, so your game no longer saves to it.", "bad")
        else
            log.warn("realmplay: upload failed (" .. text .. ") - kept for the next save")
        end
        if done then done(good) end
    end)
end

local function playing_tick(dt)
    -- after a bridge restart the lease isn't heartbeated until we say so
    local lease = realm.lease(S.id)
    S.resume_in = (S.resume_in or 0) - dt
    if lease == "lost" and not S.lost then
        S.lost = true
        say("This Realm is now hosted by someone else (your game lost the connection to the server for too long).", "bad")
    elseif lease == nil and not S.lost and S.resume_in <= 0 and realm.service() == "on" then
        S.resume_in = 30.0
        realm.send("resume", S.id)
    end
    -- a save finished: store the character, upload now and then
    if session.saving() then S.saw_save, S.quiet = true, 0.0
    elseif S.saw_save then
        S.quiet = S.quiet + dt
        if S.quiet >= 0.3 and not S.uploading then
            S.saw_save = false
            S.dirty = true
        end
    end
    if S.dirty and not S.uploading and S.clock - (S.last_up or -math.huge) >= UPLOAD_EVERY then
        S.dirty = false
        upload(false)
    end
end

local function arrived_tick(dt)
    local p = game.player()
    if session.current_name() ~= S.coop or session.loading() or not util.valid(p) then S.t = 0.0; return end
    S.t = S.t + dt
    if S.t < SETTLE then return end
    if S.fresh then
        -- a slot without a character puts the new one at the map origin, falling (experiment E7)
        local ok = pcall(function() game.controller():Svr_RequestRespawn_Random() end)
        log.info("realmplay: fresh character - respawned at a random start: " .. tostring(ok))
    end
    step("playing")
    S.last_up = S.clock
    menu.realm_host()
    say("You're hosting " .. S.name .. ". Members can join you from the REALMS tab.", "good")
    if S.fresh then S.save_in = 5.0 end
end

-- ---- leaving ----

function realmplay.leave()
    if not S then return end
    if S.step ~= "playing" then say("One moment, please.", "info"); return end
    say("Saving " .. S.name .. " and taking you home...")
    step("stopping")
    if menu.role() == "host" then menu.realm_stop("You left " .. S.name .. ". The Realm is saved.") end
end

local function go_home()
    local own, coop = S.own, S.coop
    close_live()
    step("going_home")
    S.home_at = S.clock
    session.load_slot(own)
    slotguard.purge(coop)
    slotguard.log_clear()
    S.logged, S.built = false, false
end

local function ending_tick(dt)
    if S.step == "stopping" then
        if menu.role() then return end            -- the guests are being sent home
        step("ending_save")
        session.save_now()
    elseif S.step == "ending_save" then
        if S.t < 1.5 or session.saving() then return end
        step("ending_upload")
        upload(true, function(ok)
            if not S then return end
            if not ok and not S.lost then
                -- the world stays on this PC and goes up the next time I host this Realm
                local world = slotguard.read_realm(S.coop)
                if world then realm.stash_pending(S.id, S.gen, world, realm.read_live(S.id)) end
                say("Couldn't reach the Realm's server. Your session is kept on this PC and sent next time you open the Realm.", "bad")
            end
            realm.send("release", S.id)
            go_home()
        end)
    elseif S.step == "going_home" then
        if session.current_name() == S.own and not session.loading() and util.valid(game.player()) then
            log.info("realmplay: home in " .. S.own)
            say("Back in your own world.", "good")
            S = nil
        elseif S.clock - S.home_at > 120 then
            log.warn("realmplay: still not home after 120 s")
            S = nil
        end
    end
end

-- the game's own menu took the player out of the Realm (another save, the main menu): the last save on disk counts
function left_by_menu()
    log.warn("realmplay: left the Realm through the game's menu (now in " .. tostring(session.current_name()) .. ")")
    if menu.role() == "host" then menu.realm_stop("You left the Realm.") end
    close_live()   -- (the world the player is in now uses its own files; the upload reads the Realm's from disk)
    step("ending_upload")
    upload(true, function(ok)
        if not S then return end
        if not ok and not S.lost then
            local world = slotguard.read_realm(S.coop)
            if world then realm.stash_pending(S.id, S.gen, world, realm.read_live(S.id)) end
        end
        realm.send("release", S.id)
        -- the game's Continue must not point at the emptied Realm save
        if session.current_name() == S.coop then session.point_at(S.own) end
        slotguard.purge(S.coop)
        slotguard.log_clear()
        S = nil
    end)
end

-- ---- CREATE: a brand-new world from the game's own New Game pages (experiment E8) ----
-- create -> "armed" (the player goes to the main menu, picks the settings, presses Play) -> "new_game": EMS
-- already points at a fresh co-op save, so no save of the new world can land in one of the player's own ->
-- "capturing": saved once, its world is generation 1 and its character the Realm's starter character.

local NEWGAME = "/Game/UI/Menus/Pages/NewGameDifficultySelectionPage.NewGameDifficultySelectionPage_C"
local PLAY = NEWGAME .. ":BndEvt__DifficultySelectionPage_PlayButton_K2Node_ComponentBoundEvent_2_OnButtonClickedEvent__DelegateSignature"
local NEW_WORLD_SETTLE = 5.0   -- s after the new world's player appears before its first save

local function on_play()
    if not (S and S.step == "armed") then return end
    S.coop = session.next_coop_slot()
    if not S.coop then abort("Every co-op save was used this game run. Restart the game, then create the Realm's world again."); return end
    slotguard.purge(S.coop)
    S.own_stamp = slotguard.stamp(S.own)
    if not S.own_stamp then abort("Couldn't read your save " .. tostring(S.own) .. ", so the Realm's world wasn't started."); return end
    S.gen = 0
    if not slotguard.log_write(session_log("joined")) then abort("Couldn't record the Realm session."); return end
    S.logged, S.built = true, true
    step("new_game")
    local ok = session.point_at(S.coop)
    log.info("realmplay: New Game started for " .. S.id .. " - its saves go to " .. S.coop .. " (" .. tostring(ok) .. ")")
end
local play_fn = function() util.safe(on_play, "realmplay.play") end
local function hook_play() util.ensure_hook(PLAY, play_fn, nil, true) end

local function arm(id, name)
    S = { id = id, name = name or realm.code(id), own = S and S.own or session.current_slot(), t = 0.0 }
    if not slotguard.is_own(S.own) then S = nil; say("Load one of your own saves first, then create the Realm.", "bad"); return end
    step("armed")
    S.auto = "leave"   -- the mod takes the player to the game's New Game screen itself (CANCEL stops it)
    util.safe(hook_play, "realmplay.hook_play")
    say("Taking you to the New Game screen for " .. S.name .. ". Pick your character and the world's settings, then press PLAY.", "good")
end

-- ---- the way to the New Game screen (what the pause screen's MAIN MENU and the main menu's NEW GAME do) ----

local MENU = "MenuWidget_C"
local GFL = "/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C"
local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local WLL = "/Script/UMG.Default__WidgetLayoutLibrary"
-- The main menu first shows PRESS ANY KEY (PressAnyKeyWidget_C, decompiled + traced): when its Tick sees a key it
-- jumps to ubergraph offset 167 = fade out, Delay 0.5 s, resume at 15 = broadcast EventKeyDown (the menu comes up)
-- and remove itself. The mod runs offset 167: exactly what a key press does.
local ANY_KEY = "PressAnyKeyWidget_C"
local ANY_KEY_DONE = 167
local ANY_KEY_SETTLE = 8     -- polls (2 s): its fade-in is over first
local NEW_GAME = "BndEvt__Play_K2Node_ComponentBoundEvent_11_OnButtonClickedEvent__DelegateSignature"
local LEAVE_AFTER = 3.0      -- s the card shows "taking you there" (time to CANCEL) before the world closes
local MENU_SETTLE = 12       -- polls (x 250 ms) the main menu must be up before NEW GAME is pressed: its
                             -- fade-in and 1 s start delay are over (removing a starting menu crashed the game)
local MENU_GIVE_UP = 480     -- polls: 120 s

local function to_main_menu()
    if type(ExecuteInGameThread) ~= "function" then
        S.auto = nil
        say("Go to the main menu and choose NEW GAME to start " .. S.name .. ".", "info")
        return
    end
    -- (outside the player's tick: the player and its UI go away with the world)
    ExecuteInGameThread(function()
        util.safe(function()
            if not (S and S.step == "armed" and S.auto == "menu") then return end
            local gi = FindFirstOf("SD_GameInstance_C")
            if not util.valid(gi) then log.error("realmplay: no game instance - can't go to the main menu"); S.auto = nil; return end
            -- exactly the pause screen's MAIN MENU (PauseScreen_C, decompiled): every player's UI cleared and the
            -- player removed, all actors removed, the autosave timer stopped, then the MainMenu level
            -- (ClearUI alone left world prompts like "[F] Clothing Cupboard" over the main menu)
            for _, pc in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
                if util.valid(pc) then
                    pcall(function() pc:ClearUI() end)
                    pcall(function() pc:K2_DestroyActor() end)
                end
            end
            local okd = pcall(function() util.cdo(GFL):DestroyAllActors(gi) end)
            -- (the game's hover menu - "[F] Clothing Cupboard / Interact / Move" - sits on the screen itself and
            -- stayed over the main menu in-game: nothing of the world's UI goes along)
            pcall(function() util.cdo(WLL):RemoveAllWidgets(gi) end)
            local gm = FindFirstOf("BP_SurroundeadGameMode_C")
            local okt = util.valid(gm) and pcall(function() util.cdo(KSL):K2_ClearTimer(gm, "AutoSaveGame") end)
            log.info("realmplay: leaving the world like the pause menu (actors removed " .. tostring(okd)
                .. ", autosave timer stopped " .. tostring(okt) .. ")")
            local ok, err = pcall(function() gi:Event_LoadLevel(FName("MainMenu")) end)
            log.info("realmplay: to the main menu for the New Game -> " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
        end, "realmplay.to_main_menu")
    end)
end

-- at the main menu (no player ticks there): poll until the menu is up, then press its NEW GAME
local function press_new_game()
    if type(LoopAsync) ~= "function" or type(ExecuteInGameThread) ~= "function" then return end
    local polls, up_since, done = 0, nil, false
    local key_since, key_done = nil, false
    LoopAsync(250, function()
        if done then return true end
        ExecuteInGameThread(function()
            util.safe(function()
                if done then return end
                polls = polls + 1
                if not (S and S.step == "armed" and S.auto == "menu") then done = true; return end
                if not key_done then
                    local k = FindFirstOf(ANY_KEY)
                    local shown = false
                    if util.valid(k) then pcall(function() shown = k:IsInViewport() end) end
                    if shown then key_since = key_since or polls else key_since = nil end
                    if key_since and polls - key_since >= ANY_KEY_SETTLE then
                        key_done = true
                        local ok, err = pcall(function() k:ExecuteUbergraph_PressAnyKeyWidget(ANY_KEY_DONE) end)
                        log.info("realmplay: past the main menu's PRESS ANY KEY -> " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
                    end
                end
                -- the main menu on the screen. (In-game FindFirstOf found the one from the game's start - removed
                -- when the save loaded, not freed yet - so every one is checked. session.loading() is no use here:
                -- it clears only when a world's player appears, never at the main menu.)
                local m
                for _, w in ipairs(FindAllOf(MENU) or {}) do
                    local on = false
                    if util.valid(w) then pcall(function() on = w:IsInViewport() end) end
                    if on then m = w; break end
                end
                if not m then up_since = nil elseif not up_since then up_since = polls end
                if up_since and polls - up_since >= MENU_SETTLE then
                    done = true
                    S.auto = nil
                    local ok, err = pcall(function() m[NEW_GAME](m) end)
                    log.info("realmplay: pressed the main menu's NEW GAME -> " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
                elseif polls >= MENU_GIVE_UP then
                    done = true
                    S.auto = nil
                    log.warn("realmplay: the main menu didn't come up in 120 s - the player presses NEW GAME")
                end
            end, "realmplay.press_new_game")
        end)
        return false
    end)
end

local function free_to_start()
    if not realm.enabled() then return false end
    if S then say("You're already in a Realm.", "info"); return false end
    if in_coop() then
        say("Stop hosting or leave your friend's world first.", "info")
        return false
    end
    if slotguard.log_exists() then say("A co-op session isn't finished yet. Restart the game, then try again.", "bad"); return false end
    if not slotguard.is_own(session.current_name()) then say("Load one of your own saves first.", "bad"); return false end
    return true
end

function realmplay.create(name)
    if not free_to_start() then return end
    name = tostring(name or ""):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return end
    S = { name = name, own = session.current_slot(), t = 0.0 }
    step("creating")
    session.save_now()   -- (the player leaves for the main menu next)
    realm.send("create", name, function(ok, w, text)
        if not S or S.step ~= "creating" then return end
        if not ok and w[1] == "slow_down" then
            -- (the server allows 5 new Realms a day from one internet connection)
            abort("You've made the most Realms allowed for one day. You can make another one tomorrow.")
            return
        end
        if not ok or not realm.valid_id(w[1]) then abort("Couldn't create the Realm (" .. text .. ")."); return end
        log.info("realmplay: created Realm " .. w[1])
        arm(w[1], table.concat(w, " ", 2))
    end)
end

-- the owner of a Realm without a world (a CREATE that never reached its New Game) tries again
function realmplay.create_world(id)
    if not (free_to_start() and realm.valid_id(id)) then return end
    local r = realm.find(id)
    arm(id, r and r.name)
end

function realmplay.cancel_create()
    if S and S.step == "armed" then
        log.info("realmplay: Realm world creation cancelled")
        S = nil
        say("Stopped. The Realm stays empty until you start its world again.", "info")
    end
end

local function capture()
    local world, character = slotguard.read_realm(S.coop)
    if not (world and world["Level.sav"] and character) then
        abort("The new world didn't save, so the Realm stays empty (" .. tostring(world and "no character" or character) .. ").")
        return
    end
    local ok, err = realm.store_starter(S.id, character)
    if ok then ok, err = realm.store_character(S.id, character) end
    if not ok then abort("Couldn't keep the Realm's character (" .. tostring(err) .. ")."); return end
    local live, why = open_live(nil)
    if not live then abort("Couldn't prepare the Realm's files (" .. tostring(why) .. ")."); return end
    step("claim_new")
    local id = S.id
    realm.send("claim", id, function(good, w, text)
        if not S or S.id ~= id then return end
        local gen = good and w[1] == "won" and tonumber(w[2])
        if gen ~= 0 then
            -- the world stays on this PC and goes up the next time the Realm opens (only on an empty Realm)
            realm.stash_pending(id, 0, world, realm.read_live(id))
            if good and w[1] == "won" then realm.send("release", id) end
            abort(gen and "This Realm already has a world, so the new one wasn't used."
                or ("Couldn't reach the Realm's server (" .. text .. "). The new world is kept and sent when you open the Realm."))
            return
        end
        S.leased = true
        step("playing")
        S.last_up = S.clock
        menu.realm_host()
        say(S.name .. " is ready, and you're hosting it. Members can join you from the REALMS tab.", "good")
        upload(false)
    end)
end

local function create_tick(dt)
    if S.step == "armed" then
        -- back in a world without pressing New Game's Play: nothing to make. (The world being left still ticks
        -- its player in the frame the menu load starts - in-game that cancelled the trip at once - so only a
        -- different player, or one ticking a while after the menu, counts. The main menu has no player ticks.)
        local p = game.player()
        if S.menu_seen and util.valid(p) and (util.addr(p) ~= S.menu_player or os.time() - S.menu_at >= 3) then
            realmplay.cancel_create()
            return
        end
        if S.auto == "leave" and S.t >= LEAVE_AFTER and not session.saving() and not session.loading() then
            S.auto = "menu"
            to_main_menu()
        end
    elseif S.step == "new_game" then
        if session.loading() or not util.valid(game.player()) then S.t = 0.0; return end
        if S.t < NEW_WORLD_SETTLE then return end
        if session.current_name() ~= S.coop then session.point_at(S.coop) end
        step("capturing")
        session.save_now()
    elseif S.step == "capturing" then
        if S.t > 1.5 and not session.saving() then capture() end
    end
end

local function tick(dt)
    realm.tick(dt)
    members.tick(dt)
    if list_wanted and bridge_up() then realmplay.refresh_list(true) end
    if not S then return end
    S.t, S.clock = S.t + dt, (S.clock or 0) + dt
    if S.step == "armed" or S.step == "new_game" or S.step == "capturing" then
        create_tick(dt)
    elseif S.step == "saving_own" then
        if S.t > 1.5 and not session.saving() then build() end
    elseif S.step == "loading" then
        S.wait = (S.wait or 0) + dt
        if S.wait > 180 and not S.slow_told then S.slow_told = true; log.error("realmplay: the Realm didn't load in 3 min") end
        arrived_tick(dt)
    elseif S.step == "playing" then
        if S.save_in then
            S.save_in = S.save_in - dt
            if S.save_in <= 0 and not session.saving() then S.save_in = nil; session.save_now() end
        end
        local cur = session.current_name()
        if cur and cur ~= "" and cur ~= S.coop and not session.loading() then
            S.away = (S.away or 0) + dt
            if S.away >= 2.0 then left_by_menu(); return end
        else
            S.away = 0
        end
        playing_tick(dt)
    elseif S.step == "stopping" or S.step == "ending_save" or S.step == "going_home" then
        ending_tick(dt)
    end
end

-- ---- a Realm session the game didn't finish (crash, power cut) ----

function realmplay.recover()
    local t = slotguard.log_read()
    if not (t and t.realm and realm.valid_id(t.realm)) then return end
    local id = t.realm
    local guest = t.realm_role == "guest"   -- (a guest's copy of the world is never uploaded: the host's counts)
    if t.step == "building" then
        log.info("realmplay: the last Realm start stopped while preparing - nothing to keep")
    elseif t.step == "home" then
        log.info("realmplay: the last Realm leave stopped on the way home - the Realm character was already stored")
    else
        local world, character = slotguard.read_realm(t.coop)
        if not world and character then
            log.error("realmplay: can't read the unfinished Realm save " .. tostring(t.coop) .. ": " .. tostring(character))
            return
        end
        if character then
            local ok, err = realm.store_character(id, character)
            if not ok then log.error("realmplay: Realm character not rescued yet: " .. tostring(err)); return end
            -- (a CREATE that crashed before its first upload: the New Game character is the starter too)
            if not guest and t.gen == "0" and not realm.starter(id) then realm.store_starter(id, character) end
        end
        if not guest and world and world["Level.sav"] then realm.stash_pending(id, tonumber(t.gen) or 0, world, realm.read_live(id)) end
        log.info("realmplay: rescued the unfinished Realm session of " .. id .. (guest and " (as a guest)"
            or (" (generation " .. tostring(t.gen) .. ")")))
        notify.show(guest and "Your last Realm visit didn't finish. Your Realm character is safe."
            or "Your last Realm session didn't finish. Your Realm character is safe, and the world goes up the next time you open the Realm.", "info")
    end
    slotguard.purge(t.coop)
    slotguard.log_clear()
end

function realmplay.init(c)
    cfg = c
    realm.configure(c)
    -- (even with Realms off: a leftover Realm session log would block every co-op join)
    util.safe(realmplay.recover, "realmplay.recover")
    if not realm.enabled() then return end
    session = require("mirror.session")
    menu = require("mirror.menu")
    session.set_data_dir(function() return S and S.live and realm.live_dir(S.id) or nil end)
    session.set_realm_slot(function()
        if not (S and S.coop and S.built) then return nil, nil end
        local inside = S.step == "playing" or S.step == "stopping" or S.step == "ending_save"
            or S.step == "new_game" or S.step == "capturing" or S.step == "claim_new"
        return inside and S.coop or nil, S.coop
    end)
    session.on_main_menu(function()
        if S and (S.step == "playing" or S.step == "stopping" or S.step == "ending_save") then left_by_menu()
        elseif S and S.step == "armed" then
            S.menu_seen, S.menu_at = true, os.time()
            S.menu_player = util.addr(game.player())
            util.safe(hook_play, "realmplay.hook_play")
            if S.auto == "menu" then press_new_game() end
        end
    end)
    -- (the New Game page's class can load only when the page first opens. Its functions aren't linked yet while
    -- the object is being made - RegisterHook refused "UFunction::Func: 0x0" in-game - so hook one frame later,
    -- and only when a CREATE waits for that page)
    pcall(function()
        NotifyOnNewObject(NEWGAME, function()
            if not (S and S.step == "armed") or type(ExecuteInGameThread) ~= "function" then return end
            ExecuteInGameThread(function() util.safe(hook_play, "realmplay.hook_play") end)
        end)
    end)
    game.on_tick(function(dt) util.safe(tick, "realmplay.tick", dt or 0) end)
    booted, list_wanted = os.time(), true   -- (the first list goes once the bridge is up)
    log.info("realmplay: Realms on")
end

return realmplay
