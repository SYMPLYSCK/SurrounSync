# Bug reports

How a SurrounSync bug report is made, what it explains, and how to extend it.

## Where reports come from

| Path | Code |
|---|---|
| In game: J → CO-OP → BUG REPORT (asks for a message first) | `mirror/menu.lua` `report()` → `names.ask` box → bridge command `report <message>` |
| Connector | `bridge/SurrounSyncBridge.cs` `StartReport(message)` |
| Setup: **Bug report** button / Start-menu shortcut (`--report`) (asks for a message first) | `installer/Setup.cs` `ReportDialog`, `MakeReport(game, say, message)` |
| Packing + sending (shared by both) | `bridge/Common.cs` `Report.Create` / `Report.Send` |
| Explaining | `bridge/Diagnose.cs` `Diagnose.Run` / `Diagnose.Text` / `Diagnose.Scrub` |

Nothing in the diagnosis runs while playing - it runs only when a report is made, in the connector or setup process.
The only in-game cost is the crash-step file (`mirror/crumb.lua`, ~0.07 ms/frame, measured earlier).

## What a report contains

`SurrounSync-report-<time>.zip` on the desktop:

- `report.txt`
  - **PLAYER SUMMARY** - issue title, category, severity, how sure, time, role, version; what happened / what it affects /
    why / expected vs actual (when known) / what to try / workaround; the player's message; other findings.
  - **DEVELOPER DIAGNOSTICS** - role + other player, connection (round trip, drops), last sync status, versions (SurrounSync,
    protocol, game build, Unreal, UE4SS), other UE4SS mods; every finding with category, severity, confidence, count, cause,
    evidence, where to look, how to reproduce; repeated problems grouped by message; the last 25 meaningful events of the
    run (of the run that crashed, if the game was restarted since); missing-information warnings; how long the diagnosis took.
  - **SYSTEM DETAILS** - the previous report body (Windows, memory, mods, pak mods, last 40 problems, newest crash).
- `message.txt` - what the player typed.
- `game/` logs (mirror_log x3, mirror_step x2, settings, UE4SS log/settings/mods.txt, SurrounDead.log), `connector/` logs,
  `crash/` newest crash folder (minidump left out of the small copy used when the zip is over 9 MB).

The Discord post carries the message, the plain summary of the top finding (with its confidence), its evidence, the other
findings and the versions; the zip is attached.

## Confidence

- **confirmed** - shown directly by the files (an error line, an engine mismatch, UE4SS failing to start).
- **likely** - strong evidence (a GPU crash dump; a crash while a SurrounSync hook was running).
- **possible** - fits but isn't proven (game crashed while the mod was idle; different mods; game build differs).

Nothing is blamed on the game, UE4SS or the mod without one of these. With no evidence the finding is
"No problem found in the logs" and the player's message is named as the main clue.

## Known problems it recognises

Log: tactical TrivialObject loop, older SurrounSync on the other side, save protection refusals, joining from the co-op slot,
host world export failure, connection drops (grouped; ≥5 = ERROR), hook failures (game update), different mods, save
backup failure, connector restarts, and any `safe() caught` Lua error (feature, plain meaning, file:line).
Crashes: GPU crash dump, render-thread freeze, damaged/mismatched game files, out of memory, crash inside UE4SS, crash in the
game; plus the mod step at the crash (`mirror_step*.txt`) mapped to the feature that was running. Known crash addresses
(UE4SS `1de5ad`, game `3ecd5ff`) are named when the crash context lists them. Install: engine mismatch, UE4SS missing or
failed, game build vs `made_for_build.txt` (now written into the mod folder by setup).

Add a rule: a new `if` block in `Diagnose.Known` (log lines) or `CrashFinding` (crashes), and a case in `tools/test-report.cs`.

## Privacy

`Diagnose.Scrub` runs over report.txt, message.txt, the Discord post and every packed text file: webhook addresses,
`password/token/secret/api key/auth/ticket` values, e-mail addresses, strings of 48+ token characters and the Windows user
name in paths are replaced. The reporter's Steam name/ID stays (it's how the developer replies).

## Duplicates and limits

- The same problem (same top finding, count and crash) sent again within 15 minutes with no new message isn't sent again
  (`%LOCALAPPDATA%\SurrounSync\last_report.txt`); a message or a different problem always goes.
- Bounded: 200 problem groups, 25 timeline events, 8 findings in the post. A 200,000-line (22 MB) log is diagnosed in ~1.5 s;
  the 29 real tester reports took 7-118 ms each.
- Only the reporting player's files are included; the report asks for the other player's report.
- Minidumps are stack-only, so the exact Lua step comes from `mirror_step*.txt`, not from the dump.
- The crash context in tester reports often lists no offsets, so known crash addresses are matched only when present.

## Tests

`python tools/test-report.py` (builds `tools/test-report.cs` with Common.cs + Diagnose.cs, no network): grouping/counting,
every rule family, crash classification with and without mod steps, the crashed-run choice after a restart, old crashes,
missing logs/folders, scrubbing, the zip layout and message, the Discord post, the duplicate guard, and a 200k-line
performance case.
