# Changelog

Both players need the same version. The game checks this when you connect and tells you if they differ.

## 0.11.0 (2026-10-19)

- Fixed a crash in long sessions: damage with no damage type or no attacker (fire, explosions, other mods) could
  crash the host. The same kind of mistake is guarded everywhere a game object might be missing.
- Infestations are shared: the host's nest is the real one. Hitting a nest as the guest damages the host's nest,
  the waves come for whoever is fighting there and both players see the same zombies, and a destroyed nest is
  destroyed on both screens. The guest's game no longer spawns its own, invisible waves.
- Containers stay the same on both screens: the host's contents are taken over after every change instead of
  only on the first open. If the host's copy has no room for something you put in, you're told to take it back
  out instead of it silently going missing.
- Much less saving: SurrounSync used to save both games every time loot changed hands, up to every 20 s, with a
  hitch and the other player flickering each time. It now saves only when items move between players, at most
  every 90 s, and the game's own saves count.
- Smoother movement of the other player: each update also carries the two before it, so a slow frame or a lost
  packet no longer makes them stutter.
- Fewer hitches: several once-a-second scans of the whole game's object list are gone or run rarely, and the
  host's zombie updates do far less work for zombies that are far away.
- Fixed shooting some bosses (e.g. the prison warden) crashing the game: bosses report hits without a damage
  type, which SurrounSync didn't expect.
- Items dropped straight out of a container, and part-stacks you split off when dropping, now show up for the
  other player (only whole stacks from your own inventory did before).
- Food, water and other items the other player drops or puts in a container work when used (they arrived without
  their effects, so using them did nothing unless they joined an existing stack).
- The other player's car moves smoothly: its movement now travels with the player updates (fast, with the
  previous two repeated) and the smoothing delay adapts to the connection, instead of a slow channel that made
  cars jump.
- After a save, the other player reappears as soon as the save is done (was 2 s or more after it).
- The setup refuses to install the bundled blood pak into a game version it wasn't made for (that crashes the
  game while loading), warns when the game program itself is an old version, and bug reports now show the
  game's engine version, whether UE4SS started, and installed pak mods.

## 0.10.3 (2026-10-18)

- Fixed SurrounSync sometimes staying switched off for a whole session (no CO-OP tab, nothing synced) when
  the game was slow to finish loading at startup. It now keeps trying until it's hooked in.
- The setup's Check also lists mods that switch themselves on outside UE4SS's mod list.

## 0.10.2 (2026-10-18)

- Updates now come from the project's new home, github.com/SYMPLYSCK/SurrounSync.

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
