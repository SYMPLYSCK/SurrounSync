# Dev setup: links the game's Mods\SurrounSync folder to this repo, so edits apply on the next game start.
$ErrorActionPreference = 'Stop'

$GameMods = 'C:\Program Files (x86)\Steam\steamapps\common\SurrounDead\SurrounDead\Binaries\Win64\ue4ss\Mods'
$Source   = Join-Path (Split-Path $PSScriptRoot -Parent) 'mod\SurrounSync'
$Target   = Join-Path $GameMods 'SurrounSync'
$ModsTxt  = Join-Path $GameMods 'mods.txt'

if (-not (Test-Path $GameMods)) { throw "Mods folder not found: $GameMods" }
if (-not (Test-Path $Source))   { throw "Source mod not found: $Source" }

if (Test-Path $Target) {
    $item = Get-Item $Target -Force
    if ($item.LinkType -eq 'Junction') {
        Write-Host "Removing existing junction..."
        (Get-Item $Target -Force).Delete()
    } else {
        throw "A real folder already exists at $Target - remove it manually first (won't touch it)."
    }
}

New-Item -ItemType Junction -Path $Target -Target $Source | Out-Null
Write-Host "Linked SurrounSync -> $Target"

if (Test-Path $ModsTxt) {
    $lines = Get-Content $ModsTxt
    if ($lines -match '^\s*SurrounSync\s*:') {
        $new = $lines | ForEach-Object { if ($_ -match '^\s*SurrounSync\s*:') { 'SurrounSync : 1' } else { $_ } }
        if (Compare-Object $lines $new) {
            Copy-Item $ModsTxt "$ModsTxt.mirror-backup-$(Get-Date -Format yyyyMMdd_HHmmss)"
            $new | Set-Content $ModsTxt -Encoding utf8
            Write-Host "Enabled existing SurrounSync entry in mods.txt."
        } else {
            Write-Host "SurrounSync already enabled in mods.txt."
        }
    } else {
        Copy-Item $ModsTxt "$ModsTxt.mirror-backup-$(Get-Date -Format yyyyMMdd_HHmmss)"
        Add-Content $ModsTxt "`r`nSurrounSync : 1"
        Write-Host "Registered SurrounSync in mods.txt."
    }
} else {
    Write-Warning "mods.txt not found at $ModsTxt - add 'SurrounSync : 1' manually so UE4SS loads it."
}

$ModsJson = Join-Path $GameMods 'mods.json'
if (Test-Path $ModsJson) {
    $json = Get-Content $ModsJson -Raw
    if ($json -match '"mod_name":\s*"SurrounSync"') {
        $new = $json -replace '("mod_name":\s*"SurrounSync",\s*"mod_enabled":\s*)false', '${1}true'
        if ($new -ne $json) {
            Copy-Item $ModsJson "$ModsJson.mirror-backup-$(Get-Date -Format yyyyMMdd_HHmmss)"
            [IO.File]::WriteAllText($ModsJson, $new)
            Write-Host "Enabled existing SurrounSync entry in mods.json."
        } else {
            Write-Host "SurrounSync already enabled in mods.json."
        }
    } else {
        Copy-Item $ModsJson "$ModsJson.mirror-backup-$(Get-Date -Format yyyyMMdd_HHmmss)"
        $entry = '    { "mod_name": "SurrounSync",                "mod_enabled": true  }'
        $new = $json -replace '\}\s*\r?\n\]\s*$', ("},`r`n" + $entry + "`r`n]`r`n")
        [IO.File]::WriteAllText($ModsJson, $new)
        Write-Host "Registered SurrounSync in mods.json."
    }
}

Write-Host "Launch the game; check UE4SS.log for lines tagged [SurrounSync]."
