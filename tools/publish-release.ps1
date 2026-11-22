# Publishes a release on GitHub: the SurrounDead Mod Launcher (Fabinext's newest), the mod zip and version.json.
# Players install with the launcher, which reads version.json from our latest release.
#   .\tools\publish-release.ps1 [-NoBuild] [-Draft]
param([switch]$NoBuild, [switch]$Draft)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path $PSScriptRoot -Parent
$Slug = 'SYMPLYSCK/SurrounSync'
Set-Location $Repo

$Version = ([regex]::Match((Get-Content 'mod\SurrounSync\Scripts\mirror\version.lua' -Raw), 'VERSION\s*=\s*"([^"]+)"')).Groups[1].Value
$Tag = "v$Version"
if (git status --porcelain) { throw "Commit or stash your changes first - a release is built from a clean tree." }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) not found: https://cli.github.com, then gh auth login" }

# UTF-8 both ways, no BOM: Windows PowerShell reads a BOM-less file as ANSI and its utf8 writes a BOM - that put
# garbage before lines in the 0.13.2 notes on GitHub
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$log = [IO.File]::ReadAllText((Join-Path $Repo 'CHANGELOG.md'), $Utf8)
$m = [regex]::Match(($log -replace "`r`n", "`n"), "(?ms)^## \[?$([regex]::Escape($Version))\]?[^\n]*\n(.*?)(?=^## |\z)")
if (-not $m.Success) { throw "CHANGELOG.md has no section '## $Version'" }
$notes = Join-Path $env:TEMP "surrounsync-notes-$Version.md"
$body = $m.Groups[1].Value.Trim() + "`n`n**How to install:** download SurrounDeadModLauncher.exe below and run it, pick SurrounSync and click Install. It keeps SurrounSync updated too. The launcher is made by Fabinext: https://github.com/Fabinext/SurrounDead-ModLauncher"
if ($body -match '[^\x09\x0A\x0D\x20-\x7E]') { throw "The $Version notes have non-ASCII characters (emoji, arrows, dashes) - plain text only" }
[IO.File]::WriteAllText($notes, $body, $Utf8)

if (-not $NoBuild) { & (Join-Path $PSScriptRoot 'build-release.ps1') }
# the zip + version.json the launcher installs from (make-modzip.py); version.json names this version and this zip
# (dist\SurrounSyncSetup.exe is still built for the test kit, but no longer released)
$ModZip = Join-Path $Repo "dist\SurrounSync-$Version.zip"
$VerJson = Join-Path $Repo 'dist\version.json'
if (-not (Test-Path $ModZip) -or -not (Test-Path $VerJson)) { throw "dist\SurrounSync-$Version.zip or dist\version.json missing - run tools\build-release.ps1" }
$vj = Get-Content $VerJson -Raw | ConvertFrom-Json
if ($vj.version -ne $Version -or $vj.download.sha256 -ne (Get-FileHash $ModZip -Algorithm SHA256).Hash.ToLower()) { throw "dist\version.json doesn't match dist\SurrounSync-$Version.zip - rebuild" }
# (the Hang Glider on its own, dist\SurrounSyncGlider-<version>.zip, is built but not attached: its owner releases it
# elsewhere, user 2026-11-12)

# the launcher players download goes up with each release: Fabinext's newest, checked before anything is pushed
$LauncherRepo = 'Fabinext/SurrounDead-ModLauncher'
$LauncherDir = Join-Path $Repo 'dist\launcher'
New-Item -ItemType Directory -Force $LauncherDir | Out-Null
gh release download --repo $LauncherRepo --pattern 'SurrounDeadModLauncher.exe' --dir $LauncherDir --clobber
if ($LASTEXITCODE -ne 0) { throw "Couldn't download SurrounDeadModLauncher.exe from $LauncherRepo - nothing was published." }
$Launcher = Join-Path $LauncherDir 'SurrounDeadModLauncher.exe'
$launcherTag = gh release view --repo $LauncherRepo --json tagName --jq .tagName
Write-Host "Mod Launcher $launcherTag, SHA-256 $((Get-FileHash $Launcher -Algorithm SHA256).Hash.ToLower())"

gh repo view $Slug *> $null
if ($LASTEXITCODE -ne 0) {
    $a = Read-Host "GitHub repository $Slug doesn't exist. Create it (public - the updater reads its releases)? [y/N]"
    if ($a -ne 'y') { throw "Stopped - nothing was published." }
    gh repo create $Slug --public --description "Co-op for SurrounDead: play together over Steam" --source . --remote origin
    if ($LASTEXITCODE -ne 0) { throw "gh repo create failed" }
}
if (-not (git remote 2>$null | Select-String -SimpleMatch 'origin')) { git remote add origin "https://github.com/$Slug.git" }

if (-not (git tag --list $Tag)) { git tag -a $Tag -m "SurrounSync $Version" }
$ErrorActionPreference = 'Continue'                 # git reports progress on stderr
git push origin HEAD:master --follow-tags 2>&1 | Out-Host
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) { throw "git push failed" }

$ghArgs = @('release', 'create', $Tag, $Launcher, $ModZip, $VerJson, '--repo', $Slug, '--title', "SurrounSync $Version", '--notes-file', $notes)
if ($Draft) { $ghArgs += '--draft' }
gh @ghArgs
if ($LASTEXITCODE -ne 0) { throw "gh release create failed" }
Write-Host "Published SurrounSync ${Version}: https://github.com/$Slug/releases/tag/$Tag"
