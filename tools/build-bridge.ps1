# Builds bridge/SurrounSyncBridge.cs into mod/SurrounSync/bridge (uses the csc.exe that ships with Windows).
param([string]$Out = '')
$ErrorActionPreference = 'Stop'
$Repo = Split-Path $PSScriptRoot -Parent
$Csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not $Out) { $Out = Join-Path $Repo 'mod\SurrounSync\bridge' }
$Game = 'C:\Program Files (x86)\Steam\steamapps\common\SurrounDead'
New-Item -ItemType Directory -Force $Out | Out-Null
$ReportTarget = & (Join-Path $PSScriptRoot 'report-target.ps1') | Select-Object -Last 1
& $Csc /nologo /optimize+ /platform:x64 /target:exe "/out:$(Join-Path $Out 'SurrounSyncBridge.exe')" `
    /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:Microsoft.VisualBasic.dll `
    (Join-Path $Repo 'bridge\SurrounSyncBridge.cs') (Join-Path $Repo 'bridge\Common.cs') (Join-Path $Repo 'bridge\Diagnose.cs') $ReportTarget
if ($LASTEXITCODE -ne 0) { throw "csc failed" }
Copy-Item (Join-Path $Game 'Engine\Binaries\ThirdParty\Steamworks\Steamv157\Win64\steam_api64.dll') $Out -Force
Set-Content (Join-Path $Out 'steam_appid.txt') '1645820' -Encoding ascii -NoNewline
Write-Host "Built $Out\SurrounSyncBridge.exe"
