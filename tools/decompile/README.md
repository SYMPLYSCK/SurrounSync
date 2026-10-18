# Blueprint decompiler

Turns the game's cooked Blueprint bytecode into rough pseudo-code, to see what a function actually does.

1. Extract: `repak.exe unpack -o <out> -i SurrounDead/Content/<path>.uasset -i SurrounDead/Content/<path>.uexp <SurrounDead-Windows.pak>`
2. Convert (put the current `Mappings.usmap` at `%LOCALAPPDATA%\UAssetGUI\Mappings\SurrounDead.usmap`;
   run from PowerShell with `Start-Process ... -Wait`, it returns early otherwise):
   `UAssetGUI.exe tojson <asset>.uasset <asset>.json VER_UE5_6 SurrounDead`
3. Pseudo-code for every function: `python -I kdump.py <asset>.json <out>.txt [name-filter...]`
4. Follow one event through the ubergraph (entry offset = the number in the event stub's
   `ExecuteUbergraph_X(<offset>)` call): run from this folder,
   `python trace.py <asset>.json ExecuteUbergraph_<Class> <out>.txt Name=<offset> ...`

`ksize.py` computes each statement's in-memory size (UE5 LWC layout) so offsets can be matched to
jump targets. `trace.py` does not follow `Delay` resumes. Pass their
`LatentActionInfo` offsets as extra entries.
