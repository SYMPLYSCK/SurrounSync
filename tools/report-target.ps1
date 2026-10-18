# Writes the bug-report webhook from tools/report-webhook.txt (not in git) into a generated .cs file.
$Repo = Split-Path $PSScriptRoot -Parent
$HookFile = Join-Path $Repo 'tools\report-webhook.txt'
$Hook = ''
if (Test-Path $HookFile) { $Hook = (Get-Content $HookFile -Raw).Trim() }
if ($Hook -and $Hook -notmatch '^https://(discord\.com|discordapp\.com|ptb\.discord\.com|canary\.discord\.com)/api/webhooks/\d+/[A-Za-z0-9_-]+$') {
    throw "tools\report-webhook.txt doesn't hold a Discord webhook URL (https://discord.com/api/webhooks/<id>/<token>)"
}
$Out = Join-Path $env:TEMP 'SurrounSync-ReportTarget.cs'
Set-Content $Out ("namespace SurrounSyncShared { static class ReportTarget { public const string Webhook = `"" + $Hook + "`"; } }") -Encoding ascii
if (-not $Hook) { Write-Host "Bug reports: NOT sent automatically (no tools\report-webhook.txt)" } else { Write-Host "Bug reports: sent to the Discord webhook" }
$Out
