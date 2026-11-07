# Builds mod/LogicMods/SurrounSyncGlider.pak: model (make_glider.py) -> UE 5.6 import (import_glider.py) -> cook ->
# UnrealPak with only the mod's own files (a whole-cook pak sweeps in engine files the game already has).
$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Repo = Split-Path (Split-Path $Here -Parent) -Parent
$Ue = 'C:\Program Files\Epic Games\UE_5.6\Engine\Binaries\Win64'
$Proj = Join-Path $Here 'SurrounDead.uproject'
$Mod = 'SurrounSyncGlider'

python (Join-Path $Here 'make_glider.py')
if ($LASTEXITCODE -ne 0) { throw 'make_glider.py failed' }

# forward slashes: the commandlet reads "\t" in "...\tools\..." as a tab
& (Join-Path $Ue 'UnrealEditor-Cmd.exe') $Proj -run=pythonscript "-script=$((Join-Path $Here 'import_glider.py').Replace('\', '/'))" -unattended -nopause -nosplash -stdout -NoLogTimes | Out-Null
if (-not (Select-String -Path (Join-Path $Here 'Saved\Logs\SurrounDead.log') -Pattern 'SURROUNSYNC_GLIDER_OK' -Quiet)) { throw 'import failed (Saved\Logs\SurrounDead.log)' }

$Cooked = Join-Path $Here "Saved\Cooked\Windows\SurrounDead\Content\Mods\$Mod"
if (Test-Path $Cooked) { Remove-Item -Recurse -Force $Cooked }
# versioned (no -unversioned): DA_HangGlider is cooked against a stub of the game's item class (import_glider.py), so
# its values must be tagged by name for the game's real class to read them
& (Join-Path $Ue 'UnrealEditor-Cmd.exe') $Proj -run=cook -targetplatform=Windows -unattended -nopause -stdout -NoLogTimes | Out-Null
foreach ($a in 'SM_Glider', 'DA_HangGlider', 'ModActor') {
    if (-not (Test-Path (Join-Path $Cooked "$a.uasset"))) { throw "cook made no $a ($Cooked)" }
}

$List = Join-Path $Here 'Saved\paklist.txt'
$Lines = Get-ChildItem -Recurse -File $Cooked | ForEach-Object {
    '"' + $_.FullName + '" "../../../SurrounDead/Content/Mods/' + $Mod + '/' + $_.FullName.Substring($Cooked.Length + 1).Replace('\', '/') + '"'
}
Set-Content -Path $List -Value $Lines -Encoding ascii
$Pak = Join-Path $Repo "mod\LogicMods\$Mod.pak"
& (Join-Path $Ue 'UnrealPak.exe') $Pak "-create=$List" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'UnrealPak failed' }
& (Join-Path $Ue 'UnrealPak.exe') $Pak -List | Select-String -Pattern $Mod
Write-Host "Built $Pak"
