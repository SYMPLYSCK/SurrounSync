# Changelog

Both players need the same version. The game checks this when you connect and tells you if they differ.

## 0.13.0 (2026-10-25)

Hey everyone! Big one this time: you can finally play with more than one friend.

**👥 New: 4-player co-op**
The host plus up to three friends can now play in one world. Everyone sees everyone, cars seat four (first in, first seated), and voice, chat, teleports and loot work for all players. If two of you wander far from the host, Load Splitting (still experimental) lets the friend closest to the group run the zombies around you.

**⚙️ New: a proper settings page**
CO-OP tab → ⚙️ now has two tabs:
- **HOST RULES** (the host's rules for everyone): PvP, item cleanup (off / 10 / 20 / 40 min), load splitting, max players (2-4), join requests (ask me / let friends in / let everyone in), teleports on or off, and whether guests can change the weather.
- **MY SETTINGS** (only your game): name tags, co-op messages (all / important / off), chat pop-ups, shared sounds, the join alert sound, auto-accept teleports, and guest performance (how far out zombies are copied to you: 150 / 100 / 60 m. Lower helps slower PCs).

**🦶 New: kick players**
When you host, the CO-OP tab lists the players in your world with a KICK button (press it twice to confirm). They go home with everything they carry and can't come back until you host again.

**✨ Also new**
- Settlement (raider) camps are the same for everyone.
- Zombie looks match better: acidic and radiated zombies show their effects for both players, and the blood moon is shared.
- Rocks and trees you use up disappear for the other players too.
- Bunker doors and keycard scanners open for everyone.
- The handbook (J) opens and closes faster.
- When an update is out, the game asks you once you're in the world (and again after loading until you accept).

**🔧 Fixes**
- The host's base could end up in a guest's own save after playing together. Fixed.
- Dropped magazines keep their ammo, and attachments on weapons lying on the ground show for everyone.
- Weather and car fuel / damage / paint stay in sync while you play.
- The host sometimes couldn't see a guest after they joined (their "I'm here" got lost on a connection hiccup). Fixed.
- Loot always shows the host's items. No more wrong items flashing for a moment when you open a container.
- Zombie loot is the same for every player, also with four.
- Going back to the main menu as host now ends hosting properly.
- A crash when hovering certain items, plus a batch of other crash fixes from your bug reports.
- The connection program no longer stalls when your disk or antivirus is slow.

**⚠️ Known issues**
- A backpack inside another backpack can still show up twice or go missing after a trip through a storage box. Drop it and pick it back up to fix it.
- Items a guest takes from a container while the host is paused or disconnected can end up duplicated.
- Weather can occasionally differ between players. If you see it, please send a bug report right then. That helps me find it.

Thanks again for all the bug reports and for testing with friends. Have fun, and watch each other's backs. 🧡

## 0.12.0 (2026-10-24)

Hey everyone! This one took a while. I spent most of it chasing bugs you reported, plus one experiment I've wanted to try for a long time.

**🧪 New (experimental): Load Splitting**
Until now the host's PC has run *every* zombie in the world, including the ones around your friend on the other side of the map. That's a lot of work for one machine. With Load Splitting on, once you two are far apart (400 m or so), your friend's game takes over the zombies around them. When you meet up again it hands them back, and anything you're mid-fight with stays until it's dead, so nothing vanishes in your face.

It's **off by default** and marked experimental for a reason. If you want to try it: CO-OP tab → ⚙️ → **LOAD SPLITTING (EXPERIMENTAL)**. Only the host can turn it on. If anything weird happens, turn it off and send me a bug report. That really helps.

**🔧 Fixes**
- **Horde beacons**: only the host's beacon runs the horde now. Either of you can start it, you both see the countdown and waves, and there's no more double horde. Also fixed a host crash right after a horde finished.
- **Infestations**: no more nests with millions of health. Old saves that got stuck like that are repaired automatically.
- **Tracers**: they come from the gun you're holding, not the one you just put away.
- **Vehicles**: fuel and repairs show up for the other player right away, no need to hop in first.
- **Backpack names**: a named bag keeps its name when you drop it or move it between containers.
- **Bug reports**: Send works in single player too, tells you whether it went through, and won't double-send.
- **Text boxes**: the rename and bug report boxes have readable black text now.
- **Co-op teleport requests**: long names wrap properly instead of running off the page.

**⚠️ Known issues** (working on these next)
- Dropping a magazine with ammo: the other player still gets it empty.
- Adding an attachment to a weapon lying on the ground doesn't show for the other player yet, and it can flicker for you.
- A backpack inside another backpack can go invisible after a trip through a storage box. Drop it and pick it back up to fix it.
- Some zombies may still look a bit different between the two games.

Huge thanks to everyone who's been sending bug reports and testing with friends. A lot of these fixes came straight from you. Have fun out there, and as always, watch your back. 🧡

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
