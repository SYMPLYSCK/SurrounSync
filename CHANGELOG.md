# Changelog

Both players need the same version. The game checks this when you connect and tells you if they differ.

## 0.14.1 (2026-10-29)

**I apologize for the spam patches.** This download now also fixes a crash when switching SyncFX on, a "host's game closed" message that could stay stuck on screen, and the REALMS tab's join requests - if you installed 0.14.1 earlier today, download it again.

**SyncFX grows up, Realms stop reloading, and a long list of co-op fixes.** Plays with friends on 0.14.0, but get everyone on 0.14.1 to get all of it.

**SyncFX: eight looks that live up to their names**
- Every preset is now its own look, not just Dread turned up or down: Nightmare's crimson sky and blood moon, Cinematic's teal and orange with god rays, Vibrant's turquoise days and magenta sunsets in clear air, Moody's cold blue-grey overcast, Realistic's true colors, Clean's sharp picture, Subtle's quiet version of Dread.
- The scary world events (strange events, flickering wrecks and lamps, horns, night screams, burning zombies) belong to Dread and Nightmare. The other presets are calm.
- Nights are far less dark in Dread and Moody, so you can actually play them.
- New: now and then a zombie in sight bursts into flames, and screams and howls carry through the night (Dread and Nightmare).
- SyncFX now comes installed and ready, but switched off: the game looks exactly as it always did until you press F8 (or open its menu with F6). It remembers your choice. Already using it? It stays on.
- Damage numbers are only hidden while SyncFX is on.

**Realms that never reload**
- When the Realm host leaves, a player who is still there takes over right where they stand. No loading screen, nobody sent home.
- Items no longer vanish from Realm characters, and ending a Realm while moving no longer freezes the game.
- Realms and co-op are kept apart: Realm members get in by themselves, anyone else shows up as a JOIN REQUEST on the REALMS tab with a clear ACCEPT and DECLINE, a JOINING card has a CANCEL button, and new Realm characters start with the starting kit.
- The REALMS tab shows who's online in green, and its chat stays on the page.
- Creating a Realm uses the difficulty of your own world, and the owner can change it with MY DIFFICULTY.

**The world you share is the host's world**
- Airdrops: the guest sees the host's crates land in the same spots, and no longer gets planes of its own.
- Crash sites and event sites, with their map markers and discovery XP, follow the host's world.
- Raiders carry the same weapon on both screens, and their bullets no longer pass through your friend.
- Zombies can no longer walk through you or stand inside you.
- Hounds bark and growl when they come for you.
- Cars the host makes for a guest's drive are not saved into the host's world any more, and a driver always sees their own car lights.

**Fewer surprises**
- New notifications in the top right: clear cards that update in place instead of stacking up. Missed one? Ctrl+F9 or /messages shows the history.
- Message boxes such as the update prompt were blank - they show their text again.
- A false "your friend has an OLDER SurrounSync" message is gone.
- A New Game no longer saves into a co-op slot.
- A guest crash a few seconds after going home is fixed, and so is a host freeze when load splitting hands zombies back.
- Join requests expire after 2 minutes, and a request for co-op can no longer land you in a Realm (or the other way round).
- A new SurrounSync intro plays when the game starts (your own intro is kept and comes back if you uninstall).

## 0.14.0 (2026-10-28)

**The biggest SurrounSync update yet.** Seven versions' worth of fixes that never shipped on their own (0.13.3 to 0.13.9), a fresh round of freeze and crash fixes on top, Realms that keep running when the host leaves - and a brand-new graphics mod built right in. Works with friends on 0.13.2 and newer, but get everyone on 0.14.0 to get all of it. The full notes for 0.13.3 - 0.13.9 are in CHANGELOG.md.

**NEW: SyncFX - make SurrounDead terrifying (experimental)**
- One switch turns the world darker, foggier and a lot scarier: wrong-colored skies, living fog and drifting fog banks, dead street lights that sputter back on, wrecked cars whose headlights stutter in the dark, zombie eyes glowing at night, and strange events that roll in a few times a week.
- Its own in-game menu (F6) with 8 presets - Dread, Subtle, Nightmare, Clean, Cinematic, Realistic, Vibrant and Moody - sliders for fog, sky, camera and lights, and a Before/After switch to see the difference instantly.
- Zero cost until you want it: it ships switched off. Handbook (J), CO-OP, gear, MY SETTINGS, SYNCFX GRAPHICS - flip it on and restart the game.
- Experimental: it can lower your FPS on slower PCs (switch it off the same way). It only changes your own screen, so friends can play with or without it.

**Way fewer freezes and crashes**
- The big one is gone: joining a friend or heading home could freeze the game for good. Loads no longer get stuck.
- A freeze after a car crash or a death is fixed: hearing the other players' one-shot sounds (shots, tools) is switched off for now, because hooking the game's sound functions caused it.
- The host no longer freezes when load splitting hands zombies back (load splitting is still an experimental host rule, off by default).
- And if anything does go wrong, bug reports now capture far more evidence, so fixes land faster.

**Realms that keep going**
- Host left? The Realm carries on - a guest takes it over instead of everyone being sent home.
- Realm characters that arrived with empty pockets get them back, so taking and wearing items works again.
- A host who closes the game frees the Realm instantly instead of after 2 minutes.
- Leave right from the REALMS tab, chat right from the REALMS tab, and the Realm list updates the moment someone joins or leaves.

**Better co-op all round**
- Shared map pings and military laptop scans, keycard doors that open for everyone, and no more ghost grenades or duplicated items when ripping clothes in a shared container (from 0.13.5 - 0.13.9).
- Bounties bought before a friend joined now show on their map too, and "X joined your world" is back.
- The other player's stomp shows again without hurting you, and a stomp in PvP is one hit, not an instant kill.
- Chat: type / to see every command and the players' names, then press Enter to send.
- The updater refuses a download that was cut off instead of running a broken setup.

## 0.13.9 (2026-10-27)

Works together with 0.13.2 - 0.13.8.

**Freezes and crashes leave much more evidence**
- SurrounSync now watches the game the whole session. If the game stops responding for 8 seconds it saves a snapshot of what the game is stuck on, by itself - no need to press anything. Leave a frozen game for 30 seconds before closing it: a second snapshot shows whether it was still moving.
- Every 30 seconds it notes the game's memory and CPU use, so running out of memory shows up.
- Bug reports now include these snapshots, the mod's last 64 steps before a crash or freeze (not just the last one), and Windows' own crash and freeze records for the game.
- A long loading screen is no longer reported as a frozen game, and a friend's frozen game is now named as such instead of "connection dropped".

**Fixes**
- Fixed: the military trader stood somewhere else in each player's game. Guests now find it where the host's is.
- Fixed: a guest who left co-op went home with the items they had when they joined - everything picked up in co-op was lost, and everything put away in the host's world came back.
- Fixed: a new save made while in a friend's world showed up in the load list but couldn't be loaded. In co-op the game saves to the co-op session (your own save gets your character when you leave), and that empty new save is now removed.
- Fixed: an item that didn't fit a guest's copy of a shared container could be deleted for everyone.
- Fixed: taking items from a container far from the host could duplicate them if the host didn't come near it within 10 minutes.
- Fixed: the other player's flashlight went dark after every save or rejoin.
- Fixed: after rejoining, a guest who died respawned at a random start instead of the host's bed.
- Fixed: nests and generators/lights could show an old state on a guest after a reload.
- Fixed: the friend's mod list vanished from J -> MODS after restarting co-op.
- Fixed: backpacks from older versions whose pockets existed twice, hiding the items in the second copy. Those items now move into the pocket you see, once, when you load in.
- Fixed: an item taken from a container right as it opened, while the host lagged, could come back and exist twice.
- Fixed: picking up a turret could leave it standing in the other player's game, so placing it again stacked two there.
- Your beds, bed names, backpack names and death-bag owners can no longer be wiped by a crash while they are being saved.
- Fewer hitches after dying and when the other player picks up items from the ground.
- Long chat messages in Cyrillic or with emoji no longer end in a broken character.

## 0.13.8 (2026-10-27)

Works together with 0.13.2 - 0.13.7.

**Fixed: ripping clothes (and eating, reading...) inside a container still duplicated**
- Ripping clothes, eating or reading a book straight out of a shared container or a body now takes the item for everyone. Before, the clothes came back a few seconds later.

**Better bug reports**
- If a game freezes, the report now shows exactly which step it stopped in, and lag reports show which part of the gunfire sync was slow.

## 0.13.7 (2026-10-27)

Shared map pings, laptop scans and a pile of fixes. Works together with 0.13.2 - 0.13.6 (pings and laptop scans need both players on 0.13.7).

**New: map pings are shared**
- Pings you put on the big map show on everyone's map, with your icon and colour. Removing one (double-click) removes it for everyone.
- A friend's pings in your world are saved with your world.
- Off for your own pings: J -> CO-OP -> gear -> MY SETTINGS -> SHARE MAP PINGS.

**New: military laptop scans are shared**
- The bounty a laptop starts shows its map icon for everyone. For a "classified container" bounty the crate shows up for everyone too. The item inside and the quest stay with whoever scanned it; when they search it, the lid opens for everyone.

**Fixed: a friend couldn't damage a big infestation after clearing the small ones**
- As a guest, the main nest kept saying "destroy the smaller infestations first" for the rest of the session once the host's game had destroyed them. It now opens as soon as all of them are gone.

**Fixed: items put into a bag in a shared cabinet could vanish**
- Taking an item out of a container and putting it back in was ignored by the host's game. Later the item (or the bag) disappeared.

**Fixed: one grenade showed up as several**
- A thrown grenade's copy near the thrower was sent back as a new throw - 2 to 8 grenades from one, each going off.

**Fixed: keycard doors needed a keycard on each game**
- Keycard and keypad doors opened by one player now open for everyone.

**Backpacks**
- The hint "Rename (F2)" shows on every backpack, and renamed backpacks keep their name in the inventory's backpack list (top right). F2 renames the backpack you're actually hovering.
- Fixed a crash while items moved between containers (the mod read lists the game had already thrown away).

**Smoother**
- Joining stutters less (the mod finds the world's objects in a few big passes instead of dozens of small ones).
- Some of the mod's hooks (animal hits, traders, loot) could take minutes to start working after a load. They now all start within a few seconds, without a freeze.
- Fewer hitches from looking up game objects in power, doors and loot.

**Other**
- The CO-OP tab keeps the friends list while you're asking to join someone.
- The settings page fits all of MY SETTINGS.

## 0.13.6 (2026-10-27)

A duplicate fix. Works together with 0.13.2 - 0.13.5 (update everyone to get the fix).

**Fixed: ripping clothes inside a shared container duplicated them**
- Ripping clothing (or eating, drinking, reading, opening a loot box, repairing...) straight out of a container, zombie body or death bag never told the other game. You kept the rags and the clothes came back in the container. Using an item there now counts as taking it.

**Realms are on for everyone**
- The REALMS tab is in the handbook (J) without editing any settings. The MODS list moved to the settings page. Put `realms = off` in mirror_settings.txt to hide Realms.

## 0.13.5 (2026-10-27)

A crash fix. Works together with 0.13.2 - 0.13.4.

**Fixed: crash when opening a backpack while hovering it**
- Hovering a backpack made the mod check your whole inventory from inside the game's tooltip code; opening the backpack at that moment crashed the game. Hovering no longer reads your inventory at all. (The F2 rename hint now shows on any backpack you hover.)

## 0.13.4 (2026-10-27)

A crash fix. Works together with 0.13.2 and 0.13.3.

**Fixed: crash while moving and hovering backpack items (for real this time)**
- 0.13.3 didn't stop it. The real cause: when you hovered a new item, the backpack-name tooltip looked at the item it showed *before* - and if you had just moved that item, the game had already deleted it. It now only looks at the item you're hovering.

## 0.13.3 (2026-10-27)

A crash fix. Works together with 0.13.2, so friends don't have to update at the same time.

**Fixed: crash while moving items between backpacks**
- The game could close (access violation in UE4SS) while you moved or hovered items in your backpacks, even playing alone. The mod's backpack-name tooltip did too much work every frame while the inventory was changing. It now looks at a hovered item only once, and leaves the inventory alone right after a move.
- If you ever need it: `backpack_names = off` in `mirror_settings.txt` (next to the game's .exe) switches custom backpack names off completely.

## 0.13.2 (2026-10-25)

A loot fix update. Everyone needs to update (it won't connect to 0.13.1).

**Looting as a guest works again**
- Taking an item from a container as a guest often made it vanish with "Someone else took that at the same moment", even when nobody else was near. Fixed.
- Dropping an item onto a stack of the same item (nails, ammo, cloth...) didn't reach the other player: taken onto a stack in your bag the items were copied, put onto a stack in a container the other player never got them. Both directions now sync, also for zombie bodies.
- Splitting a stack (the split slider) out of a container or inside one now syncs too - it used to copy the part you split off.

**New: DAMAGE NUMBERS setting**
Handbook (J) -> CO-OP -> gear -> MY SETTINGS. Turn the hit numbers off for your own game; each player chooses for themselves.

**Fixes**
- The other player's weapon laser no longer trails behind their gun when they move it.
- Extra copies of a player's body could be saved into the world and show up after every load (one even floating in the void). They're removed before saving now.
- The message when the other game stops sending for a moment now says it isn't responding (paused, loading or frozen) instead of always "paused".

## 0.13.1 (2026-10-25)

A safety update: your saves, your loot and getting into a friend's world. Everyone needs to update (it won't connect to 0.13.0).

**New: MODS tab in the handbook (J)**
A new tab lists every mod you have installed (UE4SS and pak mods) with an ON/OFF switch. In co-op you see which mods the host runs: different ones are marked, mods only the host has show as MISSING, and **MATCH HOST** switches yours to match in one click. Mods load when the game starts, so it tells you when a restart is needed.

**New: one-click FIX in SurrounSync Setup**
Setup now shows your game version, Steam branch and UE4SS version, and the new **FIX** button repairs most problems by itself: a missing or old UE4SS, SurrounSync switched off, old multiplayer mods in the way, read-only saves, a game stuck loading a leftover co-op save, Steam not running, and more. SurrounSync is made for the **Experimental 0.8** branch (Steam -> SurrounDead -> Properties -> Betas); Setup tells you if you're on another one.

**Saves**
- Windows user names with non-English letters (Cyrillic and others) broke backups and joining ("Couldn't back up your save"). Fixed.
- After a crash, the game's Continue could open a leftover co-op save instead of your own world ("Load one of your own saves first"). It now points back at your own save, and if you do land in a co-op save, one click loads yours.
- A co-op session that couldn't be finished no longer blocks joining forever: your co-op character is kept in Backups and you can join again.
- Error messages now say what is actually wrong (disk full, antivirus blocking, etc.) instead of always blaming disk space.
- Help messages are now in English, Russian, German, Spanish, French and Portuguese (from your Windows language).

**No more duplicated items**
- Two players taking the same item at the same moment (from the ground, a container or a zombie) both got it. Now the first one keeps it and the other gets a message.
- Taking from a car's trunk, or from a container far away from the host, could leave the item in both places. Fixed.
- Loot taken from containers could come back after reopening them or after the host restarted. Fixed.
- Death bags stay in sync even after a long connection drop.

**Fixes**
- Players who crash or quit now drop out of the host's player list within a minute.
- Joining is quicker (the world is sent smaller).
- Chat no longer runs off the page when players are listed in the CO-OP tab.
- The time of day no longer jumps every few seconds for guests.
- If one of you has an older SurrounSync, the message now says who needs to update.

**Known issues**
- A backpack inside another backpack can still show up twice or go missing after a trip through a storage box. Drop it and pick it back up to fix it.

## 0.13.0 (2026-10-25)

Hey everyone! Big one this time: you can finally play with more than one friend.

**New: 4-player co-op**
The host plus up to three friends can now play in one world. Everyone sees everyone, cars seat four (first in, first seated), and voice, chat, teleports and loot work for all players. If two of you wander far from the host, Load Splitting (still experimental) lets the friend closest to the group run the zombies around you.

**New: a proper settings page**
CO-OP tab -> now has two tabs:
- **HOST RULES** (the host's rules for everyone): PvP, item cleanup (off / 10 / 20 / 40 min), load splitting, max players (2-4), join requests (ask me / let friends in / let everyone in), teleports on or off, and whether guests can change the weather.
- **MY SETTINGS** (only your game): name tags, co-op messages (all / important / off), chat pop-ups, shared sounds, the join alert sound, auto-accept teleports, and guest performance (how far out zombies are copied to you: 150 / 100 / 60 m. Lower helps slower PCs).

**New: kick players**
When you host, the CO-OP tab lists the players in your world with a KICK button (press it twice to confirm). They go home with everything they carry and can't come back until you host again.

**Also new**
- Settlement (raider) camps are the same for everyone.
- Zombie looks match better: acidic and radiated zombies show their effects for both players, and the blood moon is shared.
- Rocks and trees you use up disappear for the other players too.
- Bunker doors and keycard scanners open for everyone.
- The handbook (J) opens and closes faster.
- When an update is out, the game asks you once you're in the world (and again after loading until you accept).

**Fixes**
- The host's base could end up in a guest's own save after playing together. Fixed.
- Dropped magazines keep their ammo, and attachments on weapons lying on the ground show for everyone.
- Weather and car fuel / damage / paint stay in sync while you play.
- The host sometimes couldn't see a guest after they joined (their "I'm here" got lost on a connection hiccup). Fixed.
- Loot always shows the host's items. No more wrong items flashing for a moment when you open a container.
- Zombie loot is the same for every player, also with four.
- Going back to the main menu as host now ends hosting properly.
- A crash when hovering certain items, plus a batch of other crash fixes from your bug reports.
- The connection program no longer stalls when your disk or antivirus is slow.

**Known issues**
- A backpack inside another backpack can still show up twice or go missing after a trip through a storage box. Drop it and pick it back up to fix it.
- Items a guest takes from a container while the host is paused or disconnected can end up duplicated.
- Weather can occasionally differ between players. If you see it, please send a bug report right then. That helps me find it.

Thanks again for all the bug reports and for testing with friends. Have fun, and watch each other's backs. 

## 0.12.0 (2026-10-24)

Hey everyone! This one took a while. I spent most of it chasing bugs you reported, plus one experiment I've wanted to try for a long time.

**New (experimental): Load Splitting**
Until now the host's PC has run *every* zombie in the world, including the ones around your friend on the other side of the map. That's a lot of work for one machine. With Load Splitting on, once you two are far apart (400 m or so), your friend's game takes over the zombies around them. When you meet up again it hands them back, and anything you're mid-fight with stays until it's dead, so nothing vanishes in your face.

It's **off by default** and marked experimental for a reason. If you want to try it: CO-OP tab -> -> **LOAD SPLITTING (EXPERIMENTAL)**. Only the host can turn it on. If anything weird happens, turn it off and send me a bug report. That really helps.

**Fixes**
- **Horde beacons**: only the host's beacon runs the horde now. Either of you can start it, you both see the countdown and waves, and there's no more double horde. Also fixed a host crash right after a horde finished.
- **Infestations**: no more nests with millions of health. Old saves that got stuck like that are repaired automatically.
- **Tracers**: they come from the gun you're holding, not the one you just put away.
- **Vehicles**: fuel and repairs show up for the other player right away, no need to hop in first.
- **Backpack names**: a named bag keeps its name when you drop it or move it between containers.
- **Bug reports**: Send works in single player too, tells you whether it went through, and won't double-send.
- **Text boxes**: the rename and bug report boxes have readable black text now.
- **Co-op teleport requests**: long names wrap properly instead of running off the page.

**Known issues** (working on these next)
- Dropping a magazine with ammo: the other player still gets it empty.
- Adding an attachment to a weapon lying on the ground doesn't show for the other player yet, and it can flicker for you.
- A backpack inside another backpack can go invisible after a trip through a storage box. Drop it and pick it back up to fix it.
- Some zombies may still look a bit different between the two games.

Huge thanks to everyone who's been sending bug reports and testing with friends. A lot of these fixes came straight from you. Have fun out there, and as always, watch your back. 

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
