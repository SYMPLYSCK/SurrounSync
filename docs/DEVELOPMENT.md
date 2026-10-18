# Development

How the code is laid out, how to build and test it, and how to release. How it works is in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Layout

```
mod/SurrounSync/Scripts/main.lua   entry point
mod/SurrounSync/Scripts/mirror/    one module per system
mod/SurrounSync/bridge/            built bridge + steam_api64.dll (not in git)
bridge/SurrounSyncBridge.cs        Steam networking, join requests, voice, update checks
bridge/Common.cs                   shared with the setup: finding the game, releases, bug reports
installer/Setup.cs                 SurrounSyncSetup.exe
tools/                             build, release, tests, lint, one-PC test setup, Blueprint decompiler
```

Main modules:

| Module | |
|---|---|
| `phase1.lua` | main loop: sends our pose, shows the other player, ticks every system |
| `link.lua`, `link_file.lua`, `events.lua` | transport: poses, state blobs, ordered events, files |
| `session.lua` | joining and leaving, crash recovery, checkpoint saves, the save firewall |
| `savefs.lua`, `backups.lua`, `slotguard.lua` | save safety: atomic writes, backups, the only code that touches save folders |
| `ghost.lua`, `look.lua`, `anim.lua` | the other player's character, gear and animations |
| `zombies.lua`, `corpses.lua` | zombie and AI snapshots, copies, hits, damage, corpse loot |
| `loot.lua`, `drops.lua`, `builds.lua`, `doors.lua`, `vehicles.lua`, `power.lua`, `world.lua` | the rest of the world |
| `menu.lua`, `journal_tab.lua` | the CO-OP tab |
| `config.lua`, `settings.lua`, `version.lua` | defaults, per-PC overrides, version and protocol |

## Building

```powershell
.\tools\build-bridge.ps1      # mod\SurrounSync\bridge\SurrounSyncBridge.exe
.\tools\dev-link.ps1          # link the mod folder into your game install (once)
.\tools\build-release.ps1     # dist\SurrounSyncSetup.exe, with UE4SS, the mod and PDS inside (-NoPds without)
```

No Visual Studio needed; the scripts use the `csc.exe` that ships with Windows (C# 5). The bridge can't be rebuilt
while a game is running, because each game's bridge keeps the exe open.

Bug reports are uploaded to a Discord webhook. Put its URL in `tools\report-webhook.txt` (git-ignored) before
building; without it, reports are only saved to the desktop.

The setup also runs without a window: `SurrounSyncSetup.exe --install|--update|--uninstall|--report|--check
[--game <folder>] --quiet`, logging to `%LOCALAPPDATA%\SurrounSync\setup.log`. It never replaces a linked mod
folder, so it's safe to run on a dev install.

## Testing on one PC

Two games on one PC need a lot of memory: plan on 32 GB of RAM. With 16 GB, close browsers and Discord first or one
of the games can freeze or crash.

Two games on one PC need two installs with separate save folders. `tools\setup-guest.ps1` makes a second install
(`SurrounDead_Guest`, linked to the real game files, saves in `Saved_Guest`). Then:

| Command | |
|---|---|
| `.\tools\mirror-mode.ps1` | show what mode both installs are in |
| `.\tools\mirror-mode.ps1 bridgetest -Launch` | both games through the real bridge over a local test network. Closest to a real session |
| `.\tools\mirror-mode.ps1 local -Launch` | both games over plain files, no bridge |
| `.\tools\mirror-mode.ps1 local -NetSim -Launch` | same, with fake lag and packet loss |
| `.\tools\mirror-mode.ps1 steam` | real Steam, for playing with someone on another PC |

Restart both games after changing the mod.

`tools/ingame/t.sh` drives both games without anyone at the keyboard (start, join, dev commands). With
`devtest = on` in `mirror_settings.txt`, a command written to `%LOCALAPPDATA%\SurrounDead\mirror_dev_<Saved|Saved_Guest>.txt`
runs within a second, for example `kill 3`, `open`, `dump`, `host`, `join`, `leave`, or `eval <lua>`.

## Testing with someone on another PC

1. Close the games and run `.\tools\build-release.ps1`. Send them `dist\SurrounSyncSetup.exe`.
2. Run `.\tools\mirror-mode.ps1 steam` on your PC. Don't run the setup on your own dev install.
3. Both start the game through Steam. One hosts, the other joins with the friend code.

When you're done, `.\tools\mirror-mode.ps1 bridgetest` switches back.

## Automated tests

```powershell
python -I tools\lint\lualint.py mod\SurrounSync\Scripts\main.lua mod\SurrounSync\Scripts\mirror\*.lua
python -I tools\test-bridge.py          # the bridge: framing, chunking, join requests, passwords
pip install --target <dir> lupa ; $env:PYTHONPATH = "<dir>"
python tools\test-link-e2e.py           # the mod's link code through two bridges
python tools\test-saves.py              # save safety, with simulated crashes (a name prefix runs a subset)
```

Lint runs as a git pre-commit hook too (`.git/hooks/pre-commit`, not versioned).

## Logs

| | |
|---|---|
| Mod | `<game>\SurrounDead\Binaries\Win64\mirror_log.txt` (`.1`, `.2` are the previous runs) |
| UE4SS | `<game>\SurrounDead\Binaries\Win64\ue4ss\UE4SS.log`, lines tagged `[SurrounSync]` |
| Bridge | `%LOCALAPPDATA%\SurrounDead\mirror_bridge.log` |

Every 5 seconds the mod logs a status line and a network line (round trip, poses per second, lateness, how far
behind the other player is shown). Every 30 seconds it logs where its frame time goes.

## Things that bite

- **Never load assets from Lua** (`LoadAsset`, or spawning something that loads its data). It hangs the game. Only
  use objects that are already in memory.
- **Blueprint hooks only get a pre-callback** in UE4SS 3.0.1. The post callback never runs.
- **UE4SS writes out-params back into the tables you pass.** Use fresh tables for every call.
- **A destroyed actor stays valid until garbage collection**, and object addresses get reused afterwards.
- **No engine calls from coroutines.** UE4SS refuses them.
- **`FindAllOf` and `StaticFindObject` are slow** in this build. Cache what you find.
- **Hooks on Blueprint classes die when a level loads** (the class is replaced). Use `util.ensure_hook`.

## Reading the game's Blueprints

See `tools/decompile/README.md`: extract an asset with repak, convert it with UAssetGUI, then `kdump.py` prints
every function as pseudo-code and `trace.py` follows one event through the event graph.

## Releasing

1. Bump `VERSION` in `mirror/version.lua`, and `PROTOCOL` if anything sent between the games changed.
2. Add a section for the version to `CHANGELOG.md`. It becomes the release notes.
3. Run the tests, then `.\tools\build-release.ps1`, and try the setup on a clean install.
4. Commit, then `.\tools\publish-release.ps1`. It tags the release, pushes, and creates the GitHub release with the
   setup attached. Installed copies see it within six hours and offer the update in the CO-OP tab.
