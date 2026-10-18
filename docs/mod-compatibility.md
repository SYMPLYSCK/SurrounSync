# Other mods

You and your friend don't need identical mod setups. When the games connect, each tells the other which mods it
runs (enabled UE4SS mods, and pak files in `Content/Paks/~mods` and `Content/Paks/LogicMods`). If something
differs that could matter, you both get a notice. Nothing is blocked. The full comparison goes to the log.

Mods fall into three groups:

| | | Different between players? |
|---|---|---|
| client | only changes your own view, UI or tools | fine |
| gameplay | changes damage, zombies, items, crafting, saves or anything shared | you should both run the same version |
| unknown | not in the list below (pak mods always count as unknown) | you get a warning; try it before relying on it |

## Known mods

| Mod | | Notes |
|---|---|---|
| BPModLoaderMod, BPML_GenericFunctions, Keybinds | client | UE4SS helpers |
| ConsoleCommandsMod, ConsoleEnablerMod, CheatManagerEnablerMod | client | console access; cheats aren't synced |
| SuppressorHeatGlow, LineTraceMod, AutoContinue | client | visuals and tools |
| PDS (Procedural Damage System) | gameplay | gore and ragdolls; both players should have it to see each other's blood |
| SDTrainer | gameplay | trainer, changes stats and items locally |
| WeaponProgression | gameplay | weapon upgrades; the other player sees base stats |
| HeadshotBrains | gameplay | replaced by PDS |
| UniversalCraftingNetwork | gameplay | crafting and storage changes |
| SplitScreenMod, SurrounDeadMP, SurrounDeadMPInput | gameplay | older multiplayer attempts. Don't run them with SurrounSync (the setup switches them off) |

To add a mod, put its folder name in `KNOWN` in `mod/SurrounSync/Scripts/mirror/compat.lua` as `"client"` or
`"gameplay"`, and add a row here.
