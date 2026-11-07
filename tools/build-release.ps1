# Builds dist/SurrounSyncSetup.exe: the setup with UE4SS, the mod and the bridge packed in.
#   .\tools\build-release.ps1
param(
    [string]$Game = 'C:\Program Files (x86)\Steam\steamapps\common\SurrounDead',
    # the SyncFX graphics mod (its own repo); packed in and installed off
    [string]$SyncFX = (Join-Path $env:USERPROFILE 'Desktop\DreadFX\mod\SyncFX'),
    # the gore mod (its own repo): its Lua mod and cooked pak; installed off, switched in MY SETTINGS
    [string]$Gore = (Join-Path $env:USERPROFILE 'Desktop\SurrounDeadGore'),
    # the FPV drone mod (its own repo, sold on its own): its committed files, marked bundled.txt, fly only for a
    # player its owner allows (mirror/dronegrant.lua)
    [string]$Drone = (Join-Path $env:USERPROFILE 'Desktop\FPVDrone')
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path $PSScriptRoot -Parent
$Win64 = Join-Path $Game 'SurrounDead\Binaries\Win64'
$Dist = Join-Path $Repo 'dist'
$Stage = Join-Path $Dist 'stage'
$Csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

$Version = ([regex]::Match((Get-Content (Join-Path $Repo 'mod\SurrounSync\Scripts\mirror\version.lua') -Raw), 'VERSION\s*=\s*"([^"]+)"')).Groups[1].Value
if (-not $Version) { throw "No VERSION in version.lua" }
Write-Host "SurrounSync $Version"

python -I (Join-Path $Repo 'tools\lint\lualint.py') (Get-ChildItem (Join-Path $Repo 'mod\SurrounSync\Scripts') -Recurse -Filter *.lua | ForEach-Object FullName)
if ($LASTEXITCODE -ne 0) { throw "lint failed" }

# a mod from its own repo: what that repo has committed (git archive HEAD), never work in progress in its folder
# (audit 2026-11-03: the gore mod was copied from the working tree, 6 changed and 7 new Lua files would have shipped)
function Copy-Committed([string]$RepoDir, [string]$Sub, [string]$Dest) {
    $dirty = git -C $RepoDir status --porcelain -- $Sub
    if ($dirty) { Write-Warning "$RepoDir has uncommitted changes in $Sub - the release packs its last commit, not them" }
    $tmp = Join-Path $Stage ('git-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    git -C $RepoDir archive --format=tar -o (Join-Path $tmp 'a.tar') HEAD $Sub
    if ($LASTEXITCODE -ne 0) { throw "git archive of $Sub in $RepoDir failed" }
    tar -xf (Join-Path $tmp 'a.tar') -C $tmp
    if ($LASTEXITCODE -ne 0) { throw "unpacking $Sub from $RepoDir failed" }
    Copy-Item (Join-Path $tmp $Sub) $Dest -Recurse
    Remove-Item $tmp -Recurse -Force
}

if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
$P = Join-Path $Stage 'payload'
$Ue = Join-Path $P 'game\ue4ss'
New-Item -ItemType Directory -Force (Join-Path $Ue 'Mods') | Out-Null
Copy-Item (Join-Path $Win64 'dwmapi.dll') (Join-Path $P 'game')
foreach ($f in 'UE4SS.dll', 'UE4SS-settings.ini', 'LICENSE') { Copy-Item (Join-Path $Win64 "ue4ss\$f") $Ue }
Copy-Item (Join-Path $Win64 'ue4ss\UE4SS_Signatures') $Ue -Recurse
$ini = Join-Path $Ue 'UE4SS-settings.ini'
(Get-Content $ini) -replace '^(ConsoleEnabled|GuiConsoleEnabled|GuiConsoleVisible)\s*=.*', '$1 = 0' | Set-Content $ini -Encoding ascii
Copy-Item (Join-Path $Repo 'mod\SurrounSync') (Join-Path $Ue 'Mods') -Recurse
Get-ChildItem (Join-Path $Ue 'Mods\SurrounSync') -Recurse -Include '*.bak*', '*.log', 'dlls' | Remove-Item -Recurse -Force
# SyncFX without the developer's own settings / lamp calibration (players start from the shipped defaults) and
# without enabled.txt (it stays off until switched on in MY SETTINGS)
if (-not (Test-Path (Join-Path $SyncFX 'Scripts\main.lua'))) { throw "SyncFX not found in $SyncFX" }
$Fx = Join-Path $Ue 'Mods\SyncFX'
Copy-Committed (Split-Path (Split-Path $SyncFX -Parent) -Parent) 'mod/SyncFX' $Fx
Get-ChildItem $Fx -Recurse -Include 'SyncFX.user.ini', 'SyncFX.calib.ini', 'noise.txt', 'enabled.txt', '*.tmp', '*.bak*', '*.log' | Remove-Item -Force
# the gore mod without enabled.txt (off until switched on in MY SETTINGS); its pak outside content\ (Setup names it
# .pak or .pak.off to match the player's on/off)
$GoreLua = Join-Path $Gore 'mod\SurrounDeadGore'
$GorePak = Join-Path $Gore 'cook\Saved\Pak\SurrounDeadGore.pak'
if (-not (Test-Path (Join-Path $GoreLua 'Scripts\main.lua'))) { throw "gore mod not found in $GoreLua" }
if (-not (Test-Path $GorePak)) { throw "gore pak not found: $GorePak" }
Copy-Committed $Gore 'mod/SurrounDeadGore' (Join-Path $Ue 'Mods\SurrounDeadGore')
Get-ChildItem (Join-Path $Ue 'Mods\SurrounDeadGore') -Recurse -Include 'enabled.txt', '*.tmp', '*.bak*', '*.log' | Remove-Item -Force
New-Item -ItemType Directory -Force (Join-Path $P 'gore') | Out-Null
Copy-Item $GorePak (Join-Path $P 'gore')
# the FPV drone mod: what its repo has committed (never the developer's own FPVDrone.ini or logs), its radio helper
# built fresh, bundled.txt so it flies only once its owner allows the player; switched on by Setup (InstallDrone)
if (-not (Test-Path (Join-Path $Drone 'mod\FPVDrone\Scripts\main.lua'))) { throw "FPVDrone not found in $Drone" }
$DroneTmp = Join-Path $Stage 'fpvdrone'
New-Item -ItemType Directory -Force $DroneTmp | Out-Null
git -C $Drone archive --format=tar -o (Join-Path $DroneTmp 'fpvdrone.tar') HEAD mod/FPVDrone
if ($LASTEXITCODE -ne 0) { throw "git archive of FPVDrone failed" }
tar -xf (Join-Path $DroneTmp 'fpvdrone.tar') -C $DroneTmp
if ($LASTEXITCODE -ne 0) { throw "unpacking FPVDrone failed" }
$Dr = Join-Path $Ue 'Mods\FPVDrone'
Copy-Item (Join-Path $DroneTmp 'mod\FPVDrone') $Dr -Recurse
Get-ChildItem $Dr -Recurse -Include 'enabled.txt' | Remove-Item -Force
# (owned.txt marks the copy sold on its own, which always flies: never in the SurrounSync copy)
Remove-Item (Join-Path $Dr 'owned.txt') -Force -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $Dr 'owned.txt')) { throw "owned.txt is still in the bundled FPVDrone" }
& (Join-Path $Drone 'tools\build-helper.ps1')
New-Item -ItemType Directory -Force (Join-Path $Dr 'helper') | Out-Null
Copy-Item (Join-Path $Drone 'mod\FPVDrone\helper\FPVRadio.exe') (Join-Path $Dr 'helper')
Set-Content (Join-Path $Dr 'bundled.txt') 'This FPVDrone came with SurrounSync: it flies once its owner allows you (their SETTINGS -> PERMISSIONS).' -Encoding ascii
# SurrounSync's game content (Setup puts content\ into SurrounDead\Content): the startup intro and the dog sounds pak,
# with UE4SS's BPModLoaderMod that loads Paks\LogicMods (Setup adds it only where it is missing)
$Content = Join-Path $P 'content'
New-Item -ItemType Directory -Force (Join-Path $Content 'Movies'), (Join-Path $Content 'Paks\LogicMods') | Out-Null
Copy-Item (Join-Path $Repo 'mod\Movies\UE5 Intro.mp4') (Join-Path $Content 'Movies')
Copy-Item (Join-Path $Repo 'mod\LogicMods\SurrounSyncSounds.pak') (Join-Path $Content 'Paks\LogicMods')
# the hang glider's model (mirror/glider.lua; tools/glider builds it)
Copy-Item (Join-Path $Repo 'mod\LogicMods\SurrounSyncGlider.pak') (Join-Path $Content 'Paks\LogicMods')
# the Double Drum Magazine and the diamond Colonel's Revenge (mirror/armory.lua; tools/armory builds it)
Copy-Item (Join-Path $Repo 'mod\LogicMods\SurrounSyncArmory.pak') (Join-Path $Content 'Paks\LogicMods')
# the FPV drone's models, so every player sees another's quad (mirror/drone.lua; a copy of FPVDrone's FPVDrone_P.pak)
Copy-Item (Join-Path $Repo 'mod\LogicMods\SurrounSyncDrone.pak') (Join-Path $Content 'Paks\LogicMods')
$Bp = Join-Path $Ue 'Mods\BPModLoaderMod\Scripts'
New-Item -ItemType Directory -Force $Bp | Out-Null
Copy-Item (Join-Path $Win64 'ue4ss\Mods\BPModLoaderMod\Scripts\main.lua') $Bp
# what BPModLoaderMod requires first (a player's PC had none: 'module UEHelpers not found', no dog sounds)
$Uh = Join-Path $Ue 'Mods\shared\UEHelpers'
New-Item -ItemType Directory -Force $Uh | Out-Null
Copy-Item (Join-Path $Win64 'ue4ss\Mods\shared\UEHelpers\UEHelpers.lua') $Uh
# always a fresh bridge, built straight into the package (a running game locks the one in mod\SurrounSync\bridge)
& (Join-Path $PSScriptRoot 'build-bridge.ps1') -Out (Join-Path $Ue 'Mods\SurrounSync\bridge')
$Manifest = Join-Path (Split-Path (Split-Path $Game -Parent) -Parent) 'appmanifest_1645820.acf'
$GameBuild = ''
if (Test-Path $Manifest) { $m = Select-String -Path $Manifest -Pattern '"buildid"\s+"(\d+)"'; if ($m) { $GameBuild = $m.Matches[0].Groups[1].Value } }
Set-Content (Join-Path $P 'made_for_build.txt') $GameBuild -Encoding ascii
# the Steam branch (Betas) this build is on - Setup tells players on another branch to switch ("" = the normal branch)
$GameBeta = ''
if (Test-Path $Manifest) { $m = Select-String -Path $Manifest -Pattern '"BetaKey"\s+"([^"]*)"'; if ($m) { $GameBeta = $m.Matches[-1].Groups[1].Value } }
Set-Content (Join-Path $P 'made_for_beta.txt') $GameBeta -Encoding ascii
Write-Host "Made for game build $GameBuild (branch: $GameBeta)"
$Zip = Join-Path $Stage 'payload.zip'
Add-Type -AssemblyName System.IO.Compression
$fs = [IO.File]::Create($Zip)
$za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
foreach ($f in Get-ChildItem $P -Recurse -File) {
    $e = $za.CreateEntry($f.FullName.Substring($P.Length + 1).Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal)
    $w = $e.Open(); $r = [IO.File]::OpenRead($f.FullName); $r.CopyTo($w); $r.Close(); $w.Close()
}
$za.Dispose(); $fs.Close()

$ReportTarget = & (Join-Path $PSScriptRoot 'report-target.ps1') | Select-Object -Last 1
$Out = Join-Path $Dist 'SurrounSyncSetup.exe'
& $Csc /nologo /optimize+ /platform:anycpu /target:winexe "/out:$Out" `
    "/win32icon:$(Join-Path $Repo 'installer\SurrounSync.ico')" "/resource:$Zip,payload.zip" "/resource:$(Join-Path $Repo 'installer\SurrounSync.png'),logo.png" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.IO.Compression.dll `
    /r:System.IO.Compression.FileSystem.dll /r:Microsoft.VisualBasic.dll `
    (Join-Path $Repo 'installer\Setup.cs') (Join-Path $Repo 'bridge\Common.cs') (Join-Path $Repo 'bridge\Diagnose.cs') $ReportTarget
if ($LASTEXITCODE -ne 0) { throw "csc failed (setup)" }
Remove-Item $Stage -Recurse -Force
$hash = (Get-FileHash $Out -Algorithm SHA256).Hash
Set-Content (Join-Path $Dist 'SurrounSyncSetup.exe.sha256') "$hash  SurrounSyncSetup.exe" -Encoding ascii
Write-Host ("Built {0} ({1:N1} MB) - SurrounSync {2}" -f $Out, ((Get-Item $Out).Length / 1MB), $Version)
