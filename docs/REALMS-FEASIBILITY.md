# SurrounSync Realms: feasibility report

Investigation only, 2026-10-26, at commit `1ba9471` (0.13.2, protocol 54, clean tree). No mod code was changed.

Evidence labels:
- **[code]**: read in the repository.
- **[file]**: seen in real save files, read-only.
- **[play]**: seen working in earlier live sessions (project notes; not re-run today).
- **[inf]**: inferred from code.
- **[hyp]**: a hypothesis that needs the experiment named next to it.

---

## A. Executive verdict

| Scope | Verdict | Confidence |
|---|---|---|
| **Rotating-host Realms (MVP)** | **Feasible with targeted extensions** | Medium-high for networking and joining (almost pure reuse). Medium for persistence until experiments E1 to E3 pass. |
| **Always-online Realms** | **Not currently feasible** | High. The "server" is a full single-player game process with UE4SS inside it. There is no headless SurrounDead, and the AI, spawners and saving only run inside a played game. The only form available is a member leaving their PC running, which is just a normal host session. |

Why it is feasible: a co-op join **already is** cross-PC world portability. The host's `Level.sav` / `General.sav` / `Difficulties.sav` / `Slot.sav` / `Thumb.sav` go to another PC, get combined with that player's own character in a co-op slot, and load there [code: `session.lua:35,475-500,537-563`] [play: many 2-4 player sessions]. A Realm needs that same world-plus-character assembly on the **host** side too, plus a persistent, versioned copy of the world that outlives the session.

Hardest limit (by design, not a bug): without a shared server **nobody can stop two offline members from resuming two different copies**. The MVP can make this rare (it checks whether the Realm is already being hosted before you resume), detect it when it happens (generation numbers) and never lose either copy (archived forks). It cannot make it impossible.

---

## B. Current architecture map (what Realms touches)

| Subsystem | Source of truth | Status |
|---|---|---|
| Entry and main loop | `Scripts/main.lua` → `mirror/phase1.lua` (677 lines) | stable [play] |
| Join/leave, crash recovery, save-slot checks | `mirror/session.lua` (1428): `host_tick` 503, `host_export` 475, `build_coop_slot` 537, `startup_restore` 401, `copy_character_home` path, `on_world_ready` 786, the host-left-to-menu hook 1284 | stable for the guest flow [play] |
| Save-folder writes (the only code allowed to change them) | `mirror/slotguard.lua` (294): `is_coop`, `make_coop_dir`, `seed_character` 214, `import_world` 204, `copy_character_home`, `purge` 252, `apply_restore`; session log `mirror_coop_session.txt` | stable [play] |
| Atomic file writes | `mirror/savefs.lua` (`write`, `write_set`, `repair`): temp file, then swap | stable [code] |
| Backups | `mirror/backups.lua`: `LAYOUT` world/player/sidecars, manifest + checksums, `Saved\SurrounSyncBackups` | stable [code] |
| Keeping the ghost out of saves | `mirror/save_guard.lua` | stable; must never be disabled [play] |
| Lua ↔ bridge | `mirror/link.lua`, `link_file.lua`: blobs, events, chunked `put_file` | stable [code] |
| Transport | `bridge/SurrounSyncBridge.cs`: classic `ISteamNetworking_SendP2PPacket`, a per-peer `Link`, up to 3 guests, guest↔guest relay, password challenge, allow list `mirror_allow.txt`, Steam lobbies (`CreateLobby`, `SetLobbyData`, `RequestLobbyList` with string filters), rich presence key `surrounsync` = role | stable [code]; lobby search needs `--lobby-smoke` on 2 PCs |
| Identity | SteamID64. The join code **is** the host's SteamID (`menu.lua:29 to_steamid`; bridge command `join <id> [pw]`). Bridge guest slots are keyed by SteamID, so reconnecting gets the same slot | stable [code] |
| Multi-player | `peers.lua`, `group.lua`, `split.lua` (load split) | implemented; partly unverified |
| Host rules | `hostrules.lua` → `mirror_host_settings.txt`, **per PC** | implemented |
| UI | `journal_tab.lua` (885): CO-OP and MODS tabs built at runtime from the J handbook's own widgets (`add_ribbon`, `button`, `input`, `text`); `menu.lua` holds the logic; `names.ask` text box; `copy_code` via `clip` | stable; MODS tab position not yet eyeballed |
| Build/release | `tools/build-release.ps1`, `publish-release.ps1`, `installer/Setup.cs` | untouched by this audit |
| Tests | `tools/test-saves.py` (lupa), `test-sync.py`, `test-bridge*.py`, `test-link-e2e.py`, `tools/lint`, `tools/ingame` kit | exist |

**Pre-existing defects and unverified areas** (so they don't get blamed on Realms later): debug case DBG-20261026-001 (solo backpack hover crash, open); 0.13.2 published without a live run of its checklist; seamless death not verified in-game; several changemem records still `needs-verification` (C-…025, 034, 042, 045, 046, 047); traders and quests are not synced (a known gap).

---

## C. Save-system findings

**Layout** [code `backups.LAYOUT`] [file]: one folder per slot under `%LOCALAPPDATA%\SurrounDead\Saved\SaveGames\<slot>\`.

| File | Owner | Size (newest own slot) |
|---|---|---|
| `Level.sav` | **world**: actors, containers, builds, vehicles, bags | 138 KB |
| `General.sav`, `Difficulties.sav`, `Slot.sav`, `Thumb.sav`/`.jpg` | **world** metadata and settings | 0.5 to 11 KB |
| `Player.sav` (position etc.), `PlayerInfo.sav` (Jig inventory, inline `Save_Player`) | **character** | 1.7 KB / 17 KB |
| `<slot>_Quests.sav`, `_SDQuests.sav`, `_SkillTree.sav` (next to the slot folders) | **character** | about 2 KB each |

World and character data are already cleanly separated, and the mod already exploits this.

**Portability** [play]: host world files load on a different PC under a different slot name (the co-op pool `MirrorCoop_Session_N`) with another player's character. No absolute paths or SteamIDs show up as plain text in the world files [file: string scan of Level/General/Slot/Difficulties; `Level.sav` looks compressed, so this is weak evidence]. The real proof is the working join.

**Constraints that shape the design** [code + play]:
1. **The EMS cache.** EasyMultiSave caches slot info and custom saves per slot name for the whole game run and never re-reads disk. That is why the co-op pool exists and why `session.ems_share_player` repoints the cache. A Realm must be loaded through the same "build a pool slot at runtime" path, never by writing files into a slot the game has already cached.
2. **Only a host-saved world is authoritative** [inf, high]. The guest's copy of the world is altered at runtime: spawners stopped, nests on a huge HP scale (`infest.lua`), zombie copies. Whatever the guest's game saves into its co-op slot is **not** a valid Realm world. Rule: only the world files written by the active host's own game become Realm commits.
3. **Saves are periodic** [code `ARCHITECTURE.md` "Saves", `session.checkpoint`]: the game's own saves plus mod checkpoints at most every 90 s. A crash loses everything since the last save. An unclean shutdown is never caught; detection happens at the next start (the existing `startup_restore` pattern).
4. **World state lives outside the save, per PC** [code], and has to travel with the Realm:
   - `mirror_coop_beds.txt`, keyed by **host name + host slot** (`session.lua:101`, `beds.lua`). This is a hardcoded host assumption.
   - `mirror_coop_bed_names.txt`, keyed by position (`bedtags.lua:231`).
   - `mirror_coop_bags.txt` (`deathbags.lua:385`).
   - `mirror_host_settings.txt`, per host PC (`hostrules.lua`).

**Persistent state by category**:

| Category | Saved by the game | Synced by SurrounSync | Realm effect |
|---|---|---|---|
| Builds, placeables, containers, doors, death bags | host Level.sav | yes | travel with world files ✔ |
| Vehicles (position, fuel, damage) | host Level.sav [inf] | yes (car list) | ✔ [hyp E2] |
| Nests and infestations | host Level.sav [inf] | yes, host-run | ✔ only from host saves |
| Zombies and NPCs | respawned by spawners [inf] | snapshots only | transient; fine |
| Time and weather | General.sav [inf] | host decides | ✔ |
| Difficulty | Difficulties.sav | host rules | ✔ |
| Inventory, position, health, XP, skills, quests | character files | look/stats only | each member's own character (see D) |
| Beds, bed names, bag owners, host rules | **mod sidecar files on one PC** | partly | **must be added to the Realm bundle** |
| Traders and quests | per character / not synced | no | known gap, unchanged |

**Safe transaction design**: a Realm store at `Saved\SurrounSyncRealms\<realm-id>\` (outside `SaveGames`, like backups).
- `realm.txt` holds the manifest: id, name, creator, owner, members [SteamID64 + name], game build, mod version, protocol, realm format version.
- `gen-<n>\` holds each commit: world files, sidecar files, and `commit.txt` (n, parent hash, host SteamID, time, per-file size and CRC). It is written with `savefs.write_set` into a temp generation folder, and the `head` pointer is swapped last.
- The last K generations are kept (default 10). Older ones are only deleted after a newer head has been verified. Forks go to `forks\`.
- Integrity: the existing backups manifest and `verify` already do size+CRC, so reuse them. A commit that fails verification never becomes head.
- Ordinary saves are never written by Realm code. This follows from slotguard rule 1 ("world files only into co-op saves") as long as Realm play slots stay co-op-class names.

---

## D. Host and identity findings

- Identities that exist today [code]: the local player, the SteamID64 of each peer, the role (`host`/`guest`, per session), guest slot by SteamID, and the host's per-PC allow list. **Missing**: the Realm itself, its creator, owner and members, and "last committed by".
- Authority is already **relative to the active session host** [code: 84 `role == "host"` checks across 24 modules, set per session]. Zombie AI, spawning, nests, damage, kills/XP, loot arbitration, time and weather, and host rules all follow whoever hosts. Nothing refers to "the original creator". This is the main reason rotating hosts are cheap.
- Hardcoded host-PC assumptions that **do** need changing: the beds file keyed by host name (C.4), host rules per PC, bed names, bag owners, and the allow list per PC.
- **Character model** (the key design choice). Recommended: **carried characters**, which is today's co-op behaviour applied to the host too. The resuming member's own character is seeded into the Realm play slot (`slotguard.seed_character`) and copied home afterwards (`copy_character_home`, with its backup and stamp checks). The Realm keeps only the world. The alternative, characters stored inside the Realm, means a new per-member character store and a second inventory-ownership model. That needs more code and adds dupe risk. See L.
- **Permission model (minimal)**: the owner and members are SteamIDs in the manifest. The host's bridge auto-accepts members (the same path as the existing "always allow"). Anyone else becomes a normal join request (ACCEPT/DECLINE). Only members can resume or receive snapshots. Ownership transfer is an owner action, and recovery when the owner is gone is "any member can promote themselves after N days unseen" (an open question). **Honest limit:** every member holds plain local files, so a member can edit their own copy. Enforcement only happens on whichever PC is hosting. That is fine among friends, and Steam itself vouches for the sender's SteamID on P2P traffic.

---

## E. Networking and Realm-code findings

- The current join code is the host's SteamID, so it changes when the host changes. A Realm code must be a **separate stable id**, for example `R-7F3K-9QXD` (64 random bits, generated by the bridge).
- **Locating the active host with existing APIs** [code]:
  - **Option A, Steam lobby key (recommended).** While hosting a Realm, the bridge's lobby carries `realm=<id>` (and does not set `surrounsync=1`, so it doesn't show in the public browser). Joining runs `RequestLobbyList` with a `realm` string filter at worldwide distance, reads `host`, then sends `join <steamid>`. Lobby search requires a public-type lobby (type 2; today `listed ? 2 : 0`). Steam deletes a lobby when its owner leaves, so "found" is real evidence the host is online. Cost: small, bridge only. [hyp E5: needs 2 PCs; `--lobby-smoke` already covers listing.]
  - **Option B, rich presence.** Set a `surrounsync_realm=<id>` key next to the role key. `FriendsWithPresence` already scans friends. It works only between Steam friends, so it's a good **fallback** for friends.
  - **Option C, relay or directory service.** Not needed. A and B cover discovery.
  - **Option D, manual.** The host copies their friend code, exactly as today. It always works and stays as the fallback.
- Changes needed: additive bridge commands (`realm host <id> <members>`, `realm find <id>`), new lobby keys, and a new blob or file kind for Realm snapshots. **Bump the protocol** (55). No existing packet changes.

---

## F. Native UI plan

- The UI is UMG built at runtime from the J handbook's own widgets (`journal_tab.lua`). Ribbons are cloned with `add_ribbon(…, n, tint)`; MODS is ribbon 2 with its own tint and position. A **REALMS ribbon 3** fits the same pattern. Reuse `button`, `input`, `text`, `vadd`/`hadd`, `place`, `names.ask` (name entry) and `copy_code` (`clip`).
- MVP screen:
  - A Realm list from the local store: name, code, generation, last saved, last host.
  - Status chip: **Online** (lobby found), **Offline**, **Checking…**, **Hosting**, **Saving…**, **Error**.
  - Actions: **Create from my current save**, **Resume**, **Join**, **Copy code**, **Details**, **Export/Import** (manual fallback), **Remove from this PC** (backup first, confirmation).
- Rules:
  - "Online" only when a fresh lobby search succeeds.
  - Buttons are disabled while a request is running (one in flight).
  - Switching tabs never ends a session; only the explicit END/LEAVE buttons and existing exits do.
  - The CO-OP and MODS tabs stay as they are.
- [hyp E6] Ribbon 3's on-screen position needs an in-game look, just as MODS still does.

---

## G. CO-OP preservation strategy

1. Realm code goes in **new modules** (`realm.lua`: store, manifest, commits; `realm_ui` section in `journal_tab`). session.lua and slotguard get **additive** entry points only.
2. A Realm session **is** a co-op session with a flag (`session.realm = id or nil`). Every existing path (join, export, sync, leave, crash recovery) runs unchanged. Realm hooks fire only when the flag is set.
3. Guests of a Realm session use **today's join path unchanged**. The only addition: when the session is a Realm and the guest is a member, it stores the snapshots it receives.
4. Host side, the only new behaviour: resuming builds a co-op pool slot from the Realm head plus the host's own character, then loads it. At the end, it commits world files and sidecars, and copies the character home.
5. The CO-OP tab, direct host/join, passwords, public listing and the 4-player split are not modified.
6. Isolation: Realm state is cleared on stop and in `on_host_world_change`. The session log gains a `realm` field, so crash recovery can tell the two apart. A failed Realm session falls back to the existing "go home" path.

---

## H. Architecture comparison

| | 1. Minimal wrapper | **2. Realm-aware session layer (recommended)** | 3. Persistent hosting/storage |
|---|---|---|---|
| What | local Realm store + "resume" around current hosting; manual code sharing | 1 + manifest, members, generations, lobby discovery, host→member snapshots | 2 + cloud store or always-on host |
| CO-OP changes | none | additive hooks in session/slotguard/bridge | same as 2 + a service |
| Save handoff | manual export only | automatic to connected members + manual fallback | automatic always |
| Fork risk | high | low, detected | lowest |
| Network | none | lobby key, 2 bridge commands, 1 snapshot message (protocol +1) | + server |
| Cost | ~1 week | ~2-3 weeks | months + hosting cost, account system |
| Verdict | too manual: everyone must hand files around | **smallest version that feels native** | not justified by the evidence |

---

## I. Minimum viable Realms scope

**In:**
- Create a Realm from your current own save (its world is copied; your save is untouched).
- Stable code.
- Resume as host, with your carried character.
- Members join through code lookup, or via the friend code as a fallback.
- Members are auto-accepted.
- Snapshots to connected members on every host save and at the end.
- Generations with K backups, forks detected and archived.
- Manual export/import.
- REALMS tab with an honest status.
- Crash recovery: the next start offers the host's last on-disk save as a commit candidate, never automatically.

**Later:** live host migration (needs authority handoff of AI, nests and vehicles mid-session; not supported by today's design), a fresh world created from inside Realms (needs the game's new-game flow), ownership recovery UI, characters stored in the Realm, a shared cloud store.

---

## J. Risks and blockers (severity × likelihood)

| # | Risk | Sev | Like | Mitigation |
|---|---|---|---|---|
| 1 | Two members resume offline copies (fork) | High | Med | lobby check before Resume; generations + parent hash; the host compares heads at join and warns; forks archived |
| 2 | A guest-saved world promoted to the Realm | High | Low once ruled out | only the host's own saves commit (rule in `realm.lua`; test) |
| 3 | EMS cache serves stale data for a Realm slot | High | Med | always load through the runtime pool-slot build (E1) |
| 4 | Host's last state not on disk at session end | Med | Med | END REALM = `save_now` → wait for `IsSavingOrLoading` false → commit; the main-menu hook commits the last on-disk save (E3) |
| 5 | Character dupe/loss on the host side | High | Low | reuse `seed_character`/`copy_character_home` with their backup and stamp checks; item counts logged like the join |
| 6 | Sidecar world files (beds/bags/rules) lost on host change | Med | High if ignored | include them in commits; key the beds file by Realm id |
| 7 | Game or mod update breaks an old Realm | Med | Med | manifest records build/mod/protocol/format; refuse with a clear message, keep the files; migrations only forward and only on a copy |
| 8 | Lobby search unreliable or slow | Low | Med | rich-presence fallback + manual friend code; status "Checking…" |
| 9 | Pre-existing co-op bugs blamed on Realms | Med | High | Stage 1 baseline first (see K) |
| 10 | Storage growth | Low | Low | K=10 × ~0.2 MB per generation |

No blocker found.

---

## K. Implementation roadmap (each milestone ships off by default behind `cfg.realms`)

| M | Objective | Files | Test | Rollback |
|---|---|---|---|---|
| 0 | Baseline: run the existing 0.13.2 live checklist + automated suites; record failures | none | test-saves/sync/bridge, 2-player session | n/a |
| 1 | **Experiments E1-E3** (below), with throwaway devtest commands | `devtest.lua` only | logs + bcount item counts | delete commands |
| 2 | Realm store: manifest, commit, verify, head swap, generations, forks | new `realm.lua` | lupa unit tests in `test-saves.py`: partial write, bad CRC, crash between temp and head | feature flag |
| 3 | Host resume: pool slot from head + own character; end commit; character home | `session.lua` (additive), `slotguard.lua` (allow Realm head → coop) | in-game solo resume ×3, item counts equal | flag off |
| 4 | Sidecars into commits; beds keyed by Realm | `beds`, `bedtags`, `deathbags`, `hostrules` (read/write paths) | unit + resume test | flag off |
| 5 | Bridge: Realm lobby key, `realm find`, member auto-accept; protocol 55 | `SurrounSyncBridge.cs`, `link.lua` | `test-bridge.py`, `--lobby-smoke` with realm key, 2 PCs | old bridge ignores new commands |
| 6 | Snapshots host → members; head compare at join; fork warning | `realm.lua`, `session.lua` | `test-bridge-4p.py` + 2-PC session | flag off |
| 7 | REALMS tab | `journal_tab.lua`, `menu.lua` | in-game look, double-click guard | flag off |
| 8 | Crash recovery, export/import, packaging | `session.startup_restore`, build scripts | kill-the-game tests, release zip check | |

**Experiments that decide the design (before M2):**
- **E1.** Can the **host** resume from the main menu into a runtime-built pool slot (Realm world + own character) and get the right inventory? (The guest path is proven; host from the menu isn't.)
- **E2.** A world saved by host A, resumed as host by B: do builds, containers, vehicles, nests, bags and beds all come through, and do B's spawners run? (Simulate on one PC with two own saves.)
- **E3.** At END: does `save_now` + waiting on `IsSavingOrLoading` give complete files? Time it.
- **E5.** 2 PCs: does a lobby search by `realm` find the host within a few seconds?
- **E6.** Where does REALMS ribbon 3 sit on screen?

---

## L. Open questions (yours to decide)

1. **Characters**: carried (recommended; same as co-op today) or stored per Realm?
2. **Creating**: from an existing own save (MVP) or also a brand-new world (later, harder)?
3. **Owner gone for good**: may any member take ownership after some days unseen, or never?
4. **Join permission**: auto-accept members only, or also let any member's code holder send a request?

---

## M. Final recommendation

Go ahead with **option 2**, in milestone order, **after** M0 (baseline) and M1 (experiments E1-E3). Those are the only places where the design rests on unproven engine behaviour.

Networking and authority are mostly reuse: authority already follows the session host, and the transport already has identity, lobbies, presence and allow lists. Persistence is the real work. It needs a versioned Realm store, host-only commits, and the sidecar files moved into the Realm.

Confidence:
- **High** that existing CO-OP can stay untouched apart from additive hooks.
- **Medium-high** on save portability (the join proves it daily).
- **Medium** on host resume from the menu (E1) and on end-of-session completeness (E3).
- **Certain** about the fork limit without a server.

---

## N. Revised design (user decisions, 2026-10-26)

**Shared store instead of local copies.** The last session's world goes to a small online database. "Join" on a Realm asks the database whether anyone is hosting:
- **Someone is**: the joiner gets a normal co-op join to that host.
- **Nobody is**: the joiner claims the host lease, downloads the head and starts it as host with their own carried character.

Database rules:
- **Atomic lease.** The claim is all-or-nothing: exactly one of two simultaneous claimers wins, and the loser joins the winner. The lease holds the host's SteamID, so no lobby search is needed.
- **Heartbeat.** The host checks in every ~60 s and the lease expires after ~2 min, so a host crash loses at most one save interval (≤90 s).
- **Upload.** On every host save and at the end, the host uploads world files + Realm sidecars (~150-200 KB). Only the lease holder may upload, and only on top of the generation it downloaded.
- **Characters stay local.**
- **Offline fallback.** Each member keeps the last head it saw, and the friend code still works.

All HTTP goes through the bridge, which already makes web requests for update checks and bug reports.

**Steam login check: rejected.**
- Valve's `AuthenticateUserTicket` needs a publisher key (partner docs).
- Whether a user key works on `api.steampowered.com` for another publisher's app is unverified.
- The game's `steam_api64.dll` (Steamv157 folder, `SteamUser_v021`) has no `GetAuthTicketForWebApi`; only `GetAuthSessionTicket`.

**Invite keys, which the player never handles.** The key is a random 256-bit secret per member. The server stores only its hash.
1. **Inside the game (main path).** A friend joins the host's Realm session through the normal join path. The host's ACCEPT row gets **ADD TO REALM**. The host's bridge asks the server to mint a member key, and sends it over the existing P2P link to that SteamID. The guest's bridge saves it to `Saved\SurrounSyncRealms\<realm-id>\member.key`. From then on the Realm appears in the guest's REALMS tab and JOIN just works. There is nothing to type or find.
2. **Invite code (friend not online).** The owner or a member presses **INVITE** in the Realm's details. A one-time invite code is copied to the clipboard (`copy_code`), valid for 7 days, and the friend pastes it into REALMS → **ADD REALM** once. Their bridge redeems it for a member key and stores it as above.
3. **Getting the key back.** Realm details → **COPY MY KEY** / **USE A KEY** for a new PC or a reinstall. Or any member just re-invites, which revokes the old key.

Keys stay in the bridge; Lua only sees "member: yes/no". A member who is removed has their key revoked on the server. The key file is included in the mod's backups, so a save restore doesn't lose membership. Steam Cloud is not used (it is SurrounDead's own quota).

**Roadmap changes**:
- New **M4b, backend**: realms, members, invites, lease and generations tables, plus blob storage. Candidate platforms: Cloudflare Workers + R2/D1, or Supabase. The user chooses and owns the account.
- M5 uses the lease instead of the lobby search.
- New tests: two clients claiming at once (exactly one host), upload by a non-holder refused, crash → lease expiry → resume from the last upload, revoked key refused, invite reused or expired.
- ~~Create from a chosen save~~ **Changed 2026-10-26: CREATE REALM starts a brand-new world** through the game's own New Game flow, so the creator picks every world setting there.
  - The game has the pages for it [object dump]: `/Game/UI/Menus/Pages/NewGameDifficultySelectionPage`, `DifficultySettingsPage` with `Difficulty_AI/_General/_Loot/_Other/_Player/_Vehicles`, `BP_NewGameSettings`, `Save_Difficulties`.
  - The settings land in `Difficulties.sav` (already a world file), so they travel with the Realm.
  - Flow: REALMS → CREATE → name → the mod arms "capture the next new game" and sends the player into the game's New Game pages. On the new world's first completed save, the mod copies its world files into generation 1 (upload). The new fresh character is copied as the creator's Realm character, and also as the Realm's **starter-character template** for every member's first entry. That covers E7's fallback: a fresh character always exists.
  - The new game's own save slot stays in the player's save list (Realms never delete own saves). The player may delete it.
  - New experiments: **E8**, can the mod detect "a new game was started from the menu" and its first save (hook the New Game page's start button, or detect a slot that didn't exist before)? **E9**, are all custom difficulty values really in `Difficulties.sav` (change one, save, compare bytes)?
  - Open: may a later host change the Realm's settings in the in-game difficulty menu, or only the owner? (Default: owner only.)
- **Decided 2026-10-26: characters stored per Realm** (replaces "carried characters" in D).
  - Each member's Realm character (`Player.sav`, `PlayerInfo.sav`, quest/skill sidecars) lives in `SurrounSyncRealms\<id>\character\` on that member's PC.
  - When the member hosts or joins, it is seeded into the co-op play slot instead of the character from their own save. At the end, it is written back into the Realm store with an atomic write and a generation check.
  - Only the member's own game ever writes it (one writer, low dupe risk). An optional encrypted copy on the backend, behind the member key, covers a new PC.
  - **Gain:** Realm play never writes the player's own saves. `copy_character_home` and its stamp/backup logic aren't needed on the Realm path, which removes a whole class of save risk.
  - **Decided: everyone starts fresh, the creator too.** The chosen save contributes only its world. The first entry into a Realm creates a new Realm character (starting kit, new-game spawn). E7 therefore blocks the whole feature.
  - **New experiment E7:** does a co-op slot without character files make the game create a fresh character, with the starting kit and a spawn point? If not, a "new character" template must be captured from a fresh game. Until then this stays a hypothesis.
- **Experiment results 2026-10-26** (one host game, 0.13.3, throwaway `RealmTest_*` slots built from `QuickSave110649_26Jul2026`, all removed afterwards, profile restored):
  - **E7, partly passes; one mod step needed.** A slot with world files only loads. The character is fresh: `CurrentLevel=1`, XP 0, and an **empty** Jig inventory (no starting kit). It is placed at map origin `(0,0)` and falls forever (`MovementMode=3`, Z sinking past -129 000). Calling `Svr_RequestRespawn_Random()` on the living player gives a new pawn at a game spawn point, on the ground (`MovementMode=1`). There are 22 `PlayerStart` actors. The next save writes `Player.sav`, `PlayerInfo.sav`, `_SkillTree.sav` and `_SDQuests.sav`, and a later load restores that character at its spot. **Consequence:** on a member's first entry, the mod respawns them at a spawn point. A starting kit comes only from the New Game template, or from a kit the mod adds itself.
  - **E9, passes.** `Save_Difficulties_C` (functions `SaveDifficulties`/`LoadDifficulties`) holds about 80 fields: loot, zombies, durability, day length, permadeath, keep inventory, and so on. A save copies the live `Difficulty.*` console variables into it and writes `Difficulties.sav`. Editing the object alone was overwritten by the save; setting the `Difficulty.DayLength` console variable changed the file. On load, the file sets the console variables again: on a cold start, the DayLength value from the file came back (30.0). The file is EMS-compressed (header `EMSH`, no plain text), so the check compares bytes, not text.
  - **E1, passes, with the cache rule confirmed.** Re-loading a slot that was **already loaded in this run** serves cached data: the file on disk was swapped, and the game kept the old DayLength. A slot **created after startup** reads its own files, both in-game (`menuload`) and from the main menu (`continue`): world, character position and difficulty all came from disk. This confirms constraint 1: every Realm load uses a fresh pool slot name. Inventory was only checked on an empty character (weak evidence).
  - **E3, passes.** `SaveGameToSlot()` is asynchronous: `IsSavingOrLoading` is true right after the call. All slot files land within about 110 ms (Thumb.sav first, sidecars last; Level.sav was 136 KB), and the flag was false by the first poll about 0.25 s later. Saved slots loaded back complete. END REALM = `save_now` → wait until the flag is false and stays false for about 0.3 s (as `save_guard` does) → commit. Bigger worlds will take longer; the flag covers that.
  - **E2, passes on one PC.** World A (`QuickSave110649_26Jul2026`) was loaded twice. The first time it had its own character (E2A). The second time it had character B from `QuickSave113109_02Aug2026` (level 8, standing elsewhere on the map) and a new slot name (E2B). A census over every actor, sorted by base class, showed the same results in both loads: builds 5, build containers 4 with **9 items**, vehicles 47 with an identical position checksum, nests 31, settlement camps 4, bags 0. The spawners run for B: 14 zombies 15 s after load at B's own spot, then 95 at A's spot after a teleport (83 there in the baseline). Loot containers (2936 vs 2942) and spawners (1009 vs 1036) differ slightly because B's spot loads other map areas. **Not covered:** a different PC/SteamID and the mod's sidecar files (beds, bed names, bag owners, host rules), which must travel in the bundle as planned. Vehicle fuel/damage and nest HP were not compared.
  - **E8, passes: the start can be detected. The slot needs care.** Hooks were attached at the main menu, then the user clicked New Game → a difficulty → Play, played, and saved. Order in the log: `NewGameDifficultySelectionPage_C:Construct` (page opened) → `BndEvt__DifficultySelectionPage_PlayButton_K2Node_ComponentBoundEvent_2_OnButtonClickedEvent__DelegateSignature` (Play) → `SD_GameInstance_C:Event_LoadLevel` in the same second (`GameMode_SpawnPlayer` did not fire). There was **no autosave**: the first files were written about 2 min later, by the user's save. **Key finding:** the new game saved into the **EMS current slot name** (`EmsUser.ini` `[/Script/EasyMultiSave.EMSObject] CurrentSaveGameName`). That was the stale `RealmTest_E2B` left from E2, a slot that no longer existed on disk, so it came back as a new folder. The user's save was a **quick save**, so quick saves write to the current slot. Whether the save menu's "new save" picks a new name is not tested. **Consequence for CREATE:** when Play is pressed, the mod must point EMS at a fresh, unique staging slot name. Then, once the player has spawned, it runs `save_now` and the busy-flag wait itself to capture generation 1. Otherwise the new world could save into whichever slot was current last, possibly the player's own save. Also: the game's "Continue" target lives in `EmsUser.ini`, not in the `SurrounDead.sav` profile. The test kit now backs it up and restores it too.
- **Decided 2026-10-26: Cloudflare.** Workers runs the API, D1 holds realms/members/invites/lease/generations (the lease claim is a single conditional write), and R2 holds the world blobs. It is a free account owned by the user and used only for SurrounSync. Claude writes the Worker code and the setup steps; the user signs up and pastes in the keys. Free-plan limits must be checked against Cloudflare's current pricing at setup.
