# In-game test helpers

For running both test games without touching the keyboard.

- `t.sh` (source it in Git Bash): `launch`, `cmd host|guest "<command>"`, `waitlog`, `lines`, `setup` (loads both
  games into their saves, god mode on, host starts hosting) and `host_up` (restarts only the host). Needs
  `devtest = on` in each install's `mirror_settings.txt`, which `tools/mirror-mode.ps1 local|bridgetest` sets. The
  commands themselves are in `devtest.lua`.
- `winshot.ps1 -ExePart <path part> -Out <png> [-Scale 0.6]`: screenshot of one game window, even when it's covered.
- `place.ps1`: puts the two game windows side by side.
- `../decompile/wtree.py <asset.json> [--props]`: prints a UMG widget tree from a UAssetGUI dump.
