SurrounSync Hang Glider
=======================

The Hang Glider from SurrounSync, on its own, for single player.

Install
-------
Unzip SurrounSyncGlider-<version>.zip into the game's install folder, the one that holds SurrounDead.exe
(Steam: Library > SurrounDead > Manage > Browse local files). If Windows asks to replace UE4SS files you already
have, you can keep yours.

It needs UE4SS (in the zip) and UE4SS's BPModLoaderMod switched on (also in the zip). If you already had UE4SS and
turned BPModLoaderMod off, set "BPModLoaderMod : 1" in SurrounDead\Binaries\Win64\ue4ss\Mods\mods.txt.

Use
---
Make a Hang Glider at the crafting workbench (12 cloth, 3 rope, 4 metal rods). Carrying it, jump off an edge with 5 m
or more of drop, or jump while running down a hill, and it opens by itself. A jump on flat ground stays a jump. Walked
off an edge without jumping? Press Jump in the air and it opens. Look down to dive, up to flare. Jump again, land, swim or die
and it closes. Why it didn't open is in SurrounDead\Binaries\Win64\SurrounSyncGlider_log.txt.

With SurrounSync
----------------
SurrounSync already has the glider, in co-op too. With SurrounSync installed and on, this mod stays off by itself.

Remove
------
Delete SurrounDead\Binaries\Win64\ue4ss\Mods\SurrounSyncGlider and
SurrounDead\Content\Paks\LogicMods\SurrounSyncGlider.pak (keep the pak if SurrounSync is installed).
