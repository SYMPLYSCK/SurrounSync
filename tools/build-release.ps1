# Builds dist/SurrounSyncSetup.exe: the setup with UE4SS, the mod, the bridge and (optionally) PDS packed in.
#   .\tools\build-release.ps1 [-NoPds]
param(
    [string]$Game = 'C:\Program Files (x86)\Steam\steamapps\common\SurrounDead',
    [string]$Pds = (Join-Path $env:USERPROFILE 'Desktop\PDS-(Precedural damage system)\mod\PDS'),
    [switch]$NoPds
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
# always a fresh bridge, built straight into the package (a running game locks the one in mod\SurrounSync\bridge)
& (Join-Path $PSScriptRoot 'build-bridge.ps1') -Out (Join-Path $Ue 'Mods\SurrounSync\bridge')
if (-not $NoPds -and (Test-Path $Pds)) {
    Copy-Item $Pds (Join-Path $Ue 'Mods') -Recurse
    Get-ChildItem (Join-Path $Ue 'Mods\PDS') -Recurse -Include '*.bak*', '*.log' | Remove-Item -Force
    $pak = Join-Path $Game 'SurrounDead\Content\Paks\~mods\BLOODSHOT_DRYING_BRAINS_TESTING_2_P.pak'
    if (Test-Path $pak) { New-Item -ItemType Directory -Force (Join-Path $P 'paks') | Out-Null; Copy-Item $pak (Join-Path $P 'paks') }
    Write-Host "PDS included"
} else { Write-Host "PDS not included" }
$Manifest = Join-Path (Split-Path (Split-Path $Game -Parent) -Parent) 'appmanifest_1645820.acf'
$GameBuild = ''
if (Test-Path $Manifest) { $m = Select-String -Path $Manifest -Pattern '"buildid"\s+"(\d+)"'; if ($m) { $GameBuild = $m.Matches[0].Groups[1].Value } }
Set-Content (Join-Path $P 'made_for_build.txt') $GameBuild -Encoding ascii
Write-Host "Made for game build $GameBuild"
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
    (Join-Path $Repo 'installer\Setup.cs') (Join-Path $Repo 'bridge\Common.cs') $ReportTarget
if ($LASTEXITCODE -ne 0) { throw "csc failed (setup)" }
Remove-Item $Stage -Recurse -Force
$hash = (Get-FileHash $Out -Algorithm SHA256).Hash
Set-Content (Join-Path $Dist 'SurrounSyncSetup.exe.sha256') "$hash  SurrounSyncSetup.exe" -Encoding ascii
Write-Host ("Built {0} ({1:N1} MB) - SurrounSync {2}" -f $Out, ((Get-Item $Out).Length / 1MB), $Version)
