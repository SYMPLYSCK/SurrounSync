# How SurrounSync works

## The idea

Neither game knows it's in a multiplayer session. There's no listen server, no replication and no second
PlayerController. Both players run the normal single-player game, and a UE4SS Lua mod on each side copies a small,
explicit set of state across.

An earlier attempt used a real listen server. The networking worked, but SurrounDead's Blueprints assume single
player everywhere (input, the death flow, player 0 lookups, saving), and it kept breaking. This design never runs
that code in a networked context, so those problems don't exist.

|  | Host | Guest |
|---|---|---|
| Own character, input, UI, inventory, death | the normal game | the normal game |
| World (doors, buildings, containers) | its own save | a copy of the host's save; changes are mirrored |
| Zombies and AI | the real ones | copies that follow the host's snapshots |
| The other player | a real player character zombies can attack | a visual copy |
| Time and weather | decides | follows the host |

## Shared world

When the guest joins, the host sends its world save (`Level.sav` and friends, usually under 1 MB). The guest
builds a co-op save from that plus its own character files and loads it. From then on only changes are sent.

When the guest leaves, its character files are copied from the co-op save back into its own save, and its own
world is loaded again. The guest's own world files are never written. See [Save safety](#save-safety).

## Why the host can run the AI for both

These are the engine facts the whole thing rests on. They were checked against object dumps and decompiled
Blueprints; if a game update breaks something, start here.

- **Spawning follows "invokers", not player 0.** `BP_AISpawner_Master_C` spawns when an AI optimizer invoker is in
  range. Every `BP_PlayerCharacter_C` has an `AIOInvoker`, so the guest's copy on the host makes the host's game
  spawn zombies around the guest with its own spawners.
- **Zombies pick targets by a tag.** The zombie controller's perception casts to `BP_AIInterface`, checks
  `ActorHasTag("ZombieCanAttack")` and that the target isn't dead. No `GetPlayerCharacter` anywhere in the AI.
  So the guest's copy on the host is a valid target, and copies on the guest can be made harmless.
- **Attacks are traces.** `PlayZombieAttack` → `AttackTrace` (a sphere trace) → `MedicalComponent_C` damage on
  whatever was hit. Human AI uses visibility traces.
- **Spawners can be switched off** (`SetIsSpawningStopped`), which the guest does while it's in the host's world.
- **All zombie damage goes through `DamageComponent_C:DamageTaken`**, which makes hits easy to forward.
- **The whole map is one loaded level** (`LongdownValley`), so spawners exist everywhere.

## Pieces

```
game (Lua, UE4SS)  ->  link files in %LOCALAPPDATA%\SurrounDead  ->  SurrounSyncBridge.exe  ->  Steam P2P
```

- **Lua mod** (`mod/SurrounSync/Scripts`). `phase1.lua` is the main loop; each synced system has its own module
  (`zombies.lua`, `loot.lua`, `doors.lua`, `vehicles.lua`, ...). `session.lua` handles joining and leaving.
- **Bridge** (`bridge/SurrounSyncBridge.cs`). Lua in UE4SS can't call the Steam API usefully (Steam IDs come
  through as empty tables), so a small .NET program does the networking using the game's own `steam_api64.dll`.
  It reads the files the mod writes and sends them, and writes what arrives. It also handles join requests,
  passwords, public games (Steam lobbies), voice and update checks.
- **Setup** (`installer/Setup.cs`). Installs UE4SS and the mod, checks the PC, sends bug reports, updates.

## What goes over the wire

- **Poses**, 30 a second, unreliable, newest wins: position, velocity, rotation, crouch/sprint, aim, run speed,
  stamina and the sender's clock. Every hop (game -> file -> bridge -> Steam -> bridge -> file -> game) keeps only
  the newest, so a slow frame on either side drops samples; each packet therefore also carries the previous two
  poses (`posepack.lua`) and the receiver plays back every one it hasn't seen.
- **State blobs**, reliable, newest wins: zombie snapshots (15 a second), the player's look, weather, car list, etc.
- **Events**, reliable and ordered (`events.lua`): shots, hits, damage, loot taken / put in, doors, builds, drops.
- **Files**, chunked: the host's world save at join.

Updates carry the sender's clock. `clockmap.lua` places them on the local clock by when they were sent and picks
the interpolation delay from how unevenly they arrive, so a bursty connection doesn't make players and zombies
speed up and slow down.

## The other player ("ghost")

A real `BP_PlayerCharacter_C`, spawned and moved by the mod. It's never possessed. On the host it's a target for
the AI (zombies attack it, and damage is forwarded to the guest); on the guest it's purely visual. Its clothes and
gear are copied from the other game (`look.lua`), animations are replayed (`anim.lua`), and an AI controller is
assigned (not possessed) so the animation blueprint can work out aim and head direction.

The ghost must never end up in a save file: its `ActorPreSave` would write its data into the local player's save.
`save_guard.lua` removes it right before every save and puts it back afterwards.

## Zombies

The host sends a snapshot of every zombie within 150 m of the guest: class, mesh and material (looks are random
per zombie), position, velocity, current animation and whether it's dead. The guest spawns copies without an AI
controller and moves them along the snapshots. The copies can't hurt the guest themselves; the host's real zombie
does the damage, and the guest checks the copy was actually close enough before taking it.

When the guest hits a copy, the hit is sent to the host and applied to the real zombie. Kills, loot and XP
follow from the host.

## Infestations

Nests (`BP_Infestation` and its variants) run on the host only (`infest.lua`). A nest starts spawning waves (every
30 s) once it drops below 2/3 health and spawns them at player 0, so each game would otherwise run its own waves.
On the guest every nest keeps `CurrentHealth`/`StandardHealthValue` on a huge scale: the wave threshold
(`MaxHealth / 1.5`) and death are out of reach, while the health bar still shows the host's percentage. The guest's
hits go to the host's nest through the nest's own `Damage_Object`; the waves are real host zombies and reach the
guest as copies. Waves started by the guest's fighting are pointed at the guest. A nest destroyed on the host is
destroyed on the guest with the nest's own `Event_OnDestroyed` (explosion and XP when the guest is near).

## Containers

Each game applies the other's "taken"/"put in" events to its copy of a container, and the host also sends the
container's full contents after every change (`lootc`). The guest takes those over once the host has applied all
of the guest's own events for that container (each event carries a number, the host's contents carry the last one
applied), so nothing in flight is undone. If the host has no room for something the guest put in, it says so and
the guest's container is left alone until the guest takes the item back.

## Saves

Besides the game's own saves, both games save shortly after items move between players (put in a container, a
drop picked up, a build, a death bag, a take from player-built storage), at most every 90 s; any save restarts that
clock. Looting the world doesn't trigger one. The ghost is removed for every save, so fewer saves also means less
flicker.

## UE4SS rules learned the hard way

- An object-typed value (a hook parameter, a property, a function result) can be a non-nil wrapper around a null
  pointer. Any method on it except `IsValid` crashes the game natively; `pcall` doesn't help. Check with
  `util.valid` / `util.obj` first.
- `FindAllOf` walks every object in the game (~30 ms on a slow PC). Scan level objects once, rescan only what
  players can create, one class at a time, and share results (`util.all_of`).

Never load assets synchronously from Lua (`LoadAsset`, or spawning something that loads its data): it hangs the
game. Copies wait until the game has loaded what they need itself.

## Save safety

All save folder changes go through `slotguard.lua`, which checks every operation:

1. World files are only ever written into co-op saves.
2. The guest's own save only ever gets its character files back, from the current session's co-op save, after
   a fresh backup, and only if it hasn't been saved since the join (checked with a CRC of `Slot.sav`).
3. Files are only deleted in co-op saves.

Every file is written to a temp file and swapped in (`savefs.lua`), so a crash leaves either the old or the new
file. A session log in the saves folder records each step (building → joined → leaving → home); after a crash the
next start finishes whatever step was interrupted.

Before every save the session checks the save goes to the slot the world in memory came from. The game's Save
menu and its "autosave to a new slot" option both switch slots first, which would otherwise write the host's
world into the guest's own save list.

Backups go to `Saved\SurrounSyncBackups`, outside the game's save list.

## Known gaps

Traders and quests aren't synced. Zombies only hear the other player's shots and explosions. Two players per
session.
