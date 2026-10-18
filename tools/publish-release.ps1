# Publishes a release on GitHub with the setup attached; installed copies pick it up as an update.
#   .\tools\publish-release.ps1 [-NoBuild] [-Draft]
param([switch]$NoBuild, [switch]$Draft)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path $PSScriptRoot -Parent
$Slug = 'munroejayden20-star/SurrounSync'
Set-Location $Repo

$Version = ([regex]::Match((Get-Content 'mod\SurrounSync\Scripts\mirror\version.lua' -Raw), 'VERSION\s*=\s*"([^"]+)"')).Groups[1].Value
$Tag = "v$Version"
if (git status --porcelain) { throw "Commit or stash your changes first - a release is built from a clean tree." }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) not found: https://cli.github.com, then gh auth login" }

$log = Get-Content 'CHANGELOG.md' -Raw
$m = [regex]::Match(($log -replace "`r`n", "`n"), "(?ms)^## \[?$([regex]::Escape($Version))\]?[^\n]*\n(.*?)(?=^## |\z)")
if (-not $m.Success) { throw "CHANGELOG.md has no section '## $Version'" }
$notes = Join-Path $env:TEMP "surrounsync-notes-$Version.md"
Set-Content $notes ($m.Groups[1].Value.Trim() + "`n`n**Install:** download SurrounSyncSetup.exe below and run it. Already installed? Update from the game: handbook (J) -> CO-OP -> UPDATE.") -Encoding utf8

if (-not $NoBuild) { & (Join-Path $PSScriptRoot 'build-release.ps1') }
$Exe = Join-Path $Repo 'dist\SurrounSyncSetup.exe'
if (-not (Test-Path $Exe)) { throw "dist\SurrounSyncSetup.exe missing - run tools\build-release.ps1" }
$built = (& $Exe --version | Out-String).Trim()
if ($built -ne $Version) { throw "dist\SurrounSyncSetup.exe is $built, version.lua says $Version - rebuild" }

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

$ghArgs = @('release', 'create', $Tag, $Exe, "$Exe.sha256", '--repo', $Slug, '--title', "SurrounSync $Version", '--notes-file', $notes)
if ($Draft) { $ghArgs += '--draft' }
gh @ghArgs
if ($LASTEXITCODE -ne 0) { throw "gh release create failed" }
Write-Host "Published SurrounSync ${Version}: https://github.com/$Slug/releases/tag/$Tag"
