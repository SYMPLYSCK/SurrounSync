# Changelog

Both players need the same version. The game checks this when you connect and tells you if they differ.

## 0.10.1 (2026-10-18)

- The other player's name shows above their head and in join requests even when you aren't Steam friends
  (it said "Unknown" before).

## 0.10.0 (2026-10-18)

First public release.

**Co-op**
- Host a game or join a friend from the CO-OP tab in the handbook (J): by Steam friend list, friend code or the
  public game list. Optional password.
- The host gets a notice and a sound when someone asks to join; the guest sees that it's waiting, and is told if
  the request is declined.
- You join with your own character and inventory and go home with whatever you found.

**Synced**
- Players: movement, sprinting and stamina, gear, weapons, aiming, animations, flashlights and lasers.
- Zombies, bosses, bandits, soldiers, scavengers and animals, with hits, kills, loot and XP going to the right
  player. Bleeding, infection and radiation from the host's zombies, including radiation clouds and blasts.
- Loot in containers and corpses, dropped items, death bags, building, doors, generators and lights, cars,
  grenades and projectiles, time and weather, sounds.
- Smoother movement over long distances: updates are timed by when they were sent and the smoothing adjusts to
  the connection.
- Less lag: bigger messages are compressed (about half the data), and zombie snapshots no longer hold up hits,
  loot and other events when a packet is lost. On a simulated long-distance link with 5% loss, events arrive in
  about 140 ms instead of 250 ms.

**Saves**
- Your own save is backed up before you join and never written while you're in a friend's world.
- Every save, including the game's Save menu and autosave, goes to the right slot while you're in co-op.
- Crashes and disconnects are recovered on the next start. Backups can be restored from the CO-OP tab.

**Setup**
- One installer for install, update, repair and uninstall. It checks your PC and tells you what's wrong and how
  to fix it, switches off old multiplayer mods that get in the way, and puts back missing UE4SS files.
- Bug reports from the game or the Start menu are sent straight to the developer, graded by how serious they are.
- Updates are offered in the game when a new version is out.

Earlier versions (0.1 to 0.9, under the working name MirrorCoop) were private test builds. Installing this one
takes care of an old MirrorCoop install and moves its backups.
