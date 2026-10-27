# Changelog

Both players need the same version. The game checks this when you connect and tells you if they differ.

## 0.13.6 (2026-10-27)

A duplicate fix. Works together with 0.13.2 - 0.13.5 (update everyone to get the fix).

**👕 Fixed: ripping clothes inside a shared container duplicated them**
- Ripping clothing (or eating, drinking, reading, opening a loot box, repairing...) straight out of a container, zombie body or death bag never told the other game. You kept the rags and the clothes came back in the container. Using an item there now counts as taking it.

**🌍 Realms are on for everyone**
- The REALMS tab is in the handbook (J) without editing any settings. The MODS list moved to the settings page. Put `realms = off` in mirror_settings.txt to hide Realms.

## 0.13.5 (2026-10-27)

A crash fix. Works together with 0.13.2 - 0.13.4.

**🎒 Fixed: crash when opening a backpack while hovering it**
- Hovering a backpack made the mod check your whole inventory from inside the game's tooltip code; opening the backpack at that moment crashed the game. Hovering no longer reads your inventory at all. (The F2 rename hint now shows on any backpack you hover.)

## 0.13.4 (2026-10-27)

A crash fix. Works together with 0.13.2 and 0.13.3.

**🎒 Fixed: crash while moving and hovering backpack items (for real this time)**
- 0.13.3 didn't stop it. The real cause: when you hovered a new item, the backpack-name tooltip looked at the item it showed *before* - and if you had just moved that item, the game had already deleted it. It now only looks at the item you're hovering.

## 0.13.3 (2026-10-27)

A crash fix. Works together with 0.13.2, so friends don't have to update at the same time.

**🎒 Fixed: crash while moving items between backpacks**
- The game could close (access violation in UE4SS) while you moved or hovered items in your backpacks, even playing alone. The mod's backpack-name tooltip did too much work every frame while the inventory was changing. It now looks at a hovered item only once, and leaves the inventory alone right after a move.
- If you ever need it: `backpack_names = off` in `mirror_settings.txt` (next to the game's .exe) switches custom backpack names off completely.

## 0.13.2 (2026-10-25)

A loot fix update. Everyone needs to update (it won't connect to 0.13.1).

**🎒 Looting as a guest works again**
- Taking an item from a container as a guest often made it vanish with "Someone else took that at the same moment", even when nobody else was near. Fixed.
- Dropping an item onto a stack of the same item (nails, ammo, cloth...) didn't reach the other player: taken onto a stack in your bag the items were copied, put onto a stack in a container the other player never got them. Both directions now sync, also for zombie bodies.
- Splitting a stack (the split slider) out of a container or inside one now syncs too - it used to copy the part you split off.

**⚙️ New: DAMAGE NUMBERS setting**
Handbook (J) → CO-OP → gear → MY SETTINGS. Turn the hit numbers off for your own game; each player chooses for themselves.

**🔧 Fixes**
- The other player's weapon laser no longer trails behind their gun when they move it.
- Extra copies of a player's body could be saved into the world and show up after every load (one even floating in the void). They're removed before saving now.
- The message when the other game stops sending for a moment now says it isn't responding (paused, loading or frozen) instead of always "paused".

## 0.13.1 (2026-10-25)

A safety update: your saves, your loot and getting into a friend's world. Everyone needs to update (it won't connect to 0.13.0).

**🧩 New: MODS tab in the handbook (J)**
A new tab lists every mod you have installed (UE4SS and pak mods) with an ON/OFF switch. In co-op you see which mods the host runs: different ones are marked, mods only the host has show as MISSING, and **MATCH HOST** switches yours to match in one click. Mods load when the game starts, so it tells you when a restart is needed.

**🛠️ New: one-click FIX in SurrounSync Setup**
Setup now shows your game version, Steam branch and UE4SS version, and the new **FIX** button repairs most problems by itself: a missing or old UE4SS, SurrounSync switched off, old multiplayer mods in the way, read-only saves, a game stuck loading a leftover co-op save, Steam not running, and more. SurrounSync is made for the **Experimental 0.8** branch (Steam → SurrounDead → Properties → Betas); Setup tells you if you're on another one.

**💾 Saves**
- Windows user names with non-English letters (Cyrillic and others) broke backups and joining ("Couldn't back up your save"). Fixed.
- After a crash, the game's Continue could open a leftover co-op save instead of your own world ("Load one of your own saves first"). It now points back at your own save, and if you do land in a co-op save, one click loads yours.
- A co-op session that couldn't be finished no longer blocks joining forever: your co-op character is kept in Backups and you can join again.
- Error messages now say what is actually wrong (disk full, antivirus blocking, etc.) instead of always blaming disk space.
- Help messages are now in English, Russian, German, Spanish, French and Portuguese (from your Windows language).

**🎒 No more duplicated items**
- Two players taking the same item at the same moment (from the ground, a container or a zombie) both got it. Now the first one keeps it and the other gets a message.
- Taking from a car's trunk, or from a container far away from the host, could leave the item in both places. Fixed.
- Loot taken from containers could come back after reopening them or after the host restarted. Fixed.
- Death bags stay in sync even after a long connection drop.

**🔧 Fixes**
- Players who crash or quit now drop out of the host's player list within a minute.
- Joining is quicker (the world is sent smaller).
- Chat no longer runs off the page when players are listed in the CO-OP tab.
- The time of day no longer jumps every few seconds for guests.
- If one of you has an older SurrounSync, the message now says who needs to update.

**⚠️ Known issues**
- A backpack inside another backpack can still show up twice or go missing after a trip through a storage box. Drop it and pick it back up to fix it.

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
