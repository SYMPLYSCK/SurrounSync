# Switches this PC's installs between modes: local / bridgetest (two games on one PC), steam, off.
#   .\tools\mirror-mode.ps1 [local|bridgetest|steam|off] [-Launch]
param(
    [Parameter(Position = 0)][ValidateSet('', 'local', 'steam', 'bridgetest', 'off')][string]$Mode = '',
    [ValidateSet('auto', 'host', 'guest')][string]$Role = 'auto',
    [string]$Peer = '',
    [switch]$NetSim,
    [switch]$Launch,
    [string]$Root  = 'C:\Program Files (x86)\Steam\steamapps\common\SurrounDead',
    [string]$Guest = 'C:\Program Files (x86)\Steam\steamapps\common\SurrounDead_Guest'
)
$ErrorActionPreference = 'Stop'
$AppId = 1645820
$HostWin64  = Join-Path $Root 'SurrounDead\Binaries\Win64'
$GuestWin64 = Join-Path $Guest 'SurrounDead\Binaries\Win64'
$HasGuest = Test-Path (Join-Path $GuestWin64 'SurrounDead-Win64-Shipping.exe')
if (-not (Test-Path $HostWin64)) { throw "Game not found at $Root - pass -Root '<your SurrounDead folder>'" }

function Show($name, $dir) {
    if (-not (Test-Path $dir)) { return }
    $r = Join-Path $dir 'mirror_role.txt'
    $s = Join-Path $dir 'mirror_settings.txt'
    $role = if (Test-Path $r) { (Get-Content $r -Raw).Trim() } else { '(config.lua)' }
    $set = if (Test-Path $s) { ((Get-Content $s) | Where-Object { $_ -match '=' -and $_ -notmatch '^\s*[#;]' }) -join ', ' } else { '' }
    if (-not $set) { $set = 'defaults from config.lua' }
    Write-Host ("  {0,-6} role={1}; {2}" -f $name, $role, $set)
}

function Write-Mode($dir, $role, $lines) {
    [IO.File]::WriteAllText((Join-Path $dir 'mirror_role.txt'), $role)
    $body = @("# Written by tools\mirror-mode.ps1 $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Keys: transport, peer, netsim, saved, linkdir, testnet.") + $lines
    [IO.File]::WriteAllText((Join-Path $dir 'mirror_settings.txt'), ($body -join "`r`n") + "`r`n")
}

function Start-Host { Start-Process "steam://rungameid/$AppId"; Write-Host "host: starting through Steam" }

if ($Mode -eq '') {
    Write-Host "Current mode:"
    Show 'host' $HostWin64
    if ($HasGuest) { Show 'guest' $GuestWin64 }
    Write-Host "Change it: .\tools\mirror-mode.ps1 local | steam -Role host|guest [-Peer id] | off"
    return
}

$ns = if ($NetSim) { 'on' } else { 'off' }
switch ($Mode) {
    'local' {
        if (-not $HasGuest) { throw "No guest install - run tools\setup-guest.ps1 once first." }
        Write-Mode $HostWin64 'auto' @('transport = file', "netsim = $ns", 'saved = Saved', 'devtest = on')
        Write-Mode $GuestWin64 'auto' @('transport = file', "netsim = $ns", 'saved = Saved_Guest', 'devtest = on')
    }
    'steam' {
        if ($Peer -and $Peer -notmatch '^\d{17}$') { throw "-Peer must be a 17-digit SteamID64 (7656119...), got '$Peer'" }
        $bridge = Join-Path $PSScriptRoot '..\mod\SurrounSync\bridge\SurrounSyncBridge.exe'
        if (-not (Test-Path $bridge)) { Write-Warning "SurrounSyncBridge.exe missing - run tools\build-bridge.ps1" }
        if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { Write-Warning "Steam isn't running - start it and log in first." }
        Write-Mode $HostWin64 $Role @('transport = steam', "peer = $Peer", 'netsim = off')
        if ($HasGuest) { Write-Mode $GuestWin64 'off' @('transport = file') }
    }
    'bridgetest' {
        if (-not $HasGuest) { throw "No guest install - run tools\setup-guest.ps1 once first." }
        $base = Join-Path $env:LOCALAPPDATA 'SurrounDead'
        foreach ($d in 'Link_Host', 'Link_Guest') { New-Item -ItemType Directory -Force (Join-Path $base $d) | Out-Null }
        Write-Mode $HostWin64 'auto' @('transport = steam', 'testnet = 47123', 'linkdir = Link_Host', "netsim = $ns", 'saved = Saved', 'devtest = on')
        Write-Mode $GuestWin64 'auto' @('transport = steam', 'testnet = 47123', 'linkdir = Link_Guest', "netsim = $ns", 'saved = Saved_Guest', 'devtest = on')
    }
    'off' {
        Write-Mode $HostWin64 'off' @()
        if ($HasGuest) { Write-Mode $GuestWin64 'off' @() }
    }
}

Write-Host "Mode set:"
Show 'host' $HostWin64
if ($HasGuest) { Show 'guest' $GuestWin64 }
if ($Mode -eq 'steam') {
    Write-Host "Other player: send them dist\SurrounSyncSetup.exe (build: toolsuild-release.ps1); they run it, then use the CO-OP tab of the handbook (J) in-game"
}

$running = Get-Process SurrounDead-Win64-Shipping -ErrorAction SilentlyContinue
if ($running) { Write-Warning "SurrounDead is running - restart it for the new mode to apply." }

if ($Launch -and -not $running) {
    Start-Host
    if ($Mode -eq 'local' -or $Mode -eq 'bridgetest') {
        $hostExe = (Join-Path $HostWin64 'SurrounDead-Win64-Shipping.exe').ToLower()
        Write-Host "waiting for the host to start..." -NoNewline
        $t = 0
        while (-not (Get-Process SurrounDead-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.ToLower() -eq $hostExe })) {
            if ($t -ge 120) { Write-Host ""; throw "The host didn't start within 2 minutes - start SurrounDead from Steam, then run tools\launch-guest.ps1" }
            Start-Sleep 2; $t += 2; Write-Host "." -NoNewline
        }
        Write-Host " up"
        Start-Sleep 5
        & (Join-Path $PSScriptRoot 'launch-guest.ps1') -Guest $Guest
        Write-Host "Load a save in both. Window 1: J -> CO-OP -> Host. Window 2 (small): J -> CO-OP -> Join."
    }
}
