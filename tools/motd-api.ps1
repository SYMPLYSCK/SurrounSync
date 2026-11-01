# The message of the day API (the Realms server's /v1/motd), shared by tools\motd.ps1 (command line) and
# tools\motd-gui.ps1 (the MOTD.cmd window). Dot-source it: . (Join-Path $PSScriptRoot 'motd-api.ps1')
# Server rules (realms-backend/src/index.js): text 1-500 characters, no control characters (one line), hours 1-2160
# or minutes 1-129600 (90 days) or neither; PUT/DELETE need the admin token and exist only once the server has the MOTD_TOKEN secret; 30 admin
# calls an hour per IP (a wrong token counts too).

$MotdDefaultUrl = 'https://surrounsync-realms.surrounsync-realms.workers.dev'
$MotdTokenFile = Join-Path $PSScriptRoot 'motd-token.txt'
$MotdMaxText = 500
$MotdMaxHours = 90 * 24
$MotdMaxMinutes = 90 * 24 * 60

function Get-MotdToken {
    if (-not (Test-Path $MotdTokenFile)) { return $null }
    $t = (Get-Content $MotdTokenFile -Raw)
    if ($t) { $t = $t.Trim() }
    if ($t) { return $t } else { return $null }
}

# GET (public), PUT { text, hours? or minutes? } or DELETE; returns the server's answer, throws "the server said <code>: <body>"
function Invoke-Motd([string]$Method, $Body, [string]$Url = $MotdDefaultUrl) {
    $h = @{}
    if ($Method -ne 'GET') {
        $tok = Get-MotdToken
        if (-not $tok) { throw "no admin token: make one first (tools\motd.ps1 -Setup, or Setup in the MOTD window)" }
        $h['Authorization'] = 'Admin ' + $tok
    }
    $req = @{ Uri = $Url.TrimEnd('/') + '/v1/motd'; Method = $Method; Headers = $h; UseBasicParsing = $true }
    if ($Body) { $req['Body'] = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress)); $req['ContentType'] = 'application/json; charset=utf-8' }
    # (the bytes as UTF-8: PowerShell 5.1 reads a JSON answer without a charset as Latin-1)
    try { return [Text.Encoding]::UTF8.GetString((Invoke-WebRequest @req).RawContentStream.ToArray()) | ConvertFrom-Json }
    catch {
        $r = $_.Exception.Response
        if (-not $r) { throw }
        $msg = (New-Object IO.StreamReader($r.GetResponseStream())).ReadToEnd()
        throw ("the server said " + [int]$r.StatusCode + ": " + $msg)
    }
}

# the body for a new message: one line (the server refuses control characters); minutes when > 0, else hours
# when > 0, else no expiry (the server refuses both together)
function New-MotdBody([string]$Text, [int]$Hours = 0, [int]$Minutes = 0) {
    $t = ($Text -replace '[\x00-\x1f\x7f]+', ' ').Trim()
    $b = @{ text = $t }
    if ($Minutes -gt 0) { $b['minutes'] = $Minutes }
    elseif ($Hours -gt 0) { $b['hours'] = $Hours }
    return $b
}

# makes the admin token file; $false when one already exists (delete it first for a new one)
function New-MotdToken {
    if (Test-Path $MotdTokenFile) { return $false }
    $b = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    $t = [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    Set-Content $MotdTokenFile $t -Encoding ascii -NoNewline
    return $true
}

function Format-MotdTill($m) {
    if ($m.expires_at) { return 'until ' + ([DateTimeOffset]::FromUnixTimeSeconds($m.expires_at).LocalDateTime) }
    return 'until cleared'
}
