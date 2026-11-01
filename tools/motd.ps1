# The message of the day: one message every SurrounSync player gets (a card in a world, a banner at the main menu).
#   tools\motd.ps1 -Setup                       makes the admin token (tools\motd-token.txt, not in git) once
#   tools\motd.ps1 "Servers down tonight 9-10"   sends it (the bridges fetch it within a minute)
#   tools\motd.ps1 "Weekend event!" -Hours 48    goes by itself after 48 hours
#   tools\motd.ps1 "Back in 5" -Minutes 30       goes by itself after 30 minutes (give -Hours or -Minutes, not both)
#   tools\motd.ps1 -Show                         what players get now
#   tools\motd.ps1 -Clear                        no message
# -Url <server> for another Realms server (default: the one the bridge uses). The same controls in a window: tools\MOTD.cmd
param(
    [Parameter(Position = 0)][string]$Text,
    [int]$Hours = 0,
    [int]$Minutes = 0,
    [switch]$Show,
    [switch]$Clear,
    [switch]$Setup,
    [string]$Url = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'motd-api.ps1')
if (-not $Url) { $Url = $MotdDefaultUrl }
$TokenFile = $MotdTokenFile

function Call($Method, $Body) { Invoke-Motd $Method $Body $Url }

function Say($m) {
    if (-not $m.id) { Write-Host 'No message of the day.'; return }
    Write-Host ("Message " + $m.id + " (" + (Format-MotdTill $m) + "): " + $m.text)
}

if ($Setup) {
    if (-not (New-MotdToken)) { Write-Host "$TokenFile already exists (delete it first to make a new token)." }
    else { Write-Host "Token written to $TokenFile." }
    Write-Host 'Then set up the server once: tools\MOTD-setup-server.cmd (the motd table, this token, deploy).'
    return
}
if ($Clear) { Say (Call 'DELETE' $null); return }
if ($Show -or -not $Text) { Say (Call 'GET' $null); return }
if ($Hours -gt 0 -and $Minutes -gt 0) { throw 'give -Hours or -Minutes, not both' }
Say (Call 'PUT' (New-MotdBody $Text $Hours $Minutes))
Write-Host 'Players get it within a minute (0.14.2 and older: within 10 minutes).'
