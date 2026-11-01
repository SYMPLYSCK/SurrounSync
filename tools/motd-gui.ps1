# The message of the day in a window: what players see now, send a new one, clear it, and the one-time admin token
# setup. Start it with tools\MOTD.cmd (double-click). Same server calls as tools\motd.ps1 (both use motd-api.ps1).
# -NoShow builds the window without showing it (tests dot-source it and press its buttons).
param([string]$Url = '', [switch]$NoShow)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'motd-api.ps1')
if (-not $Url) { $Url = $MotdDefaultUrl }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# (MOTD.cmd hides the console: an error that ends the script shows here instead of nowhere)
trap { if (-not $NoShow) { [void][Windows.Forms.MessageBox]::Show("The MOTD window stopped: $_", 'SurrounSync MOTD', 'OK', 'Error') }; break }
[Windows.Forms.Application]::EnableVisualStyles()

$Backend = Join-Path (Split-Path $PSScriptRoot -Parent) 'realms-backend'

function Confirm-Motd([string]$Question) {
    return [Windows.Forms.MessageBox]::Show($Question, 'SurrounSync MOTD', 'YesNo', 'Question') -eq 'Yes'
}

# a refused send or clear is said in a box too: the status line alone was missed
function Show-MotdProblem([string]$Text) {
    [void][Windows.Forms.MessageBox]::Show($Text, 'SurrounSync MOTD', 'OK', 'Warning')
}

function P($x, $y) { New-Object Drawing.Point($x, $y) }
function S($w, $h) { New-Object Drawing.Size($w, $h) }
function Add-Ui($parent, [string]$type, [hashtable]$props) {
    $c = New-Object "Windows.Forms.$type" -Property $props
    $parent.Controls.Add($c)
    return $c
}

$form = New-Object Windows.Forms.Form -Property @{
    Text = 'SurrounSync - Message of the day'; ClientSize = (S 640 566); FormBorderStyle = 'FixedSingle'
    MaximizeBox = $false; StartPosition = 'CenterScreen'; Font = (New-Object Drawing.Font('Segoe UI', 10))
}

# what players get now
$gNow = Add-Ui $form GroupBox @{ Text = 'Players see now'; Location = (P 12 8); Size = (S 616 146) }
$nowText = Add-Ui $gNow TextBox @{ Location = (P 12 24); Size = (S 592 56); Multiline = $true; ReadOnly = $true; WordWrap = $true; ScrollBars = 'Vertical' }
$nowInfo = Add-Ui $gNow Label @{ Location = (P 12 86); Size = (S 380 22); Text = 'Checking...' }
$eta = Add-Ui $gNow Label @{ Location = (P 12 110); Size = (S 384 30); ForeColor = [Drawing.Color]::DarkSlateBlue
    Font = (New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)) }
$btnRefresh = Add-Ui $gNow Button @{ Text = 'Refresh'; Location = (P 400 102); Size = (S 92 30) }
$btnClear = Add-Ui $gNow Button @{ Text = 'Clear message'; Location = (P 498 102); Size = (S 106 30); Enabled = $false }

# a new message
$gNew = Add-Ui $form GroupBox @{ Text = 'New message (one line, up to 500 characters)'; Location = (P 12 162); Size = (S 616 210) }
$newText = Add-Ui $gNew TextBox @{ Location = (P 12 24); Size = (S 592 80); Multiline = $true; WordWrap = $true; AcceptsReturn = $false; MaxLength = $MotdMaxText; ScrollBars = 'Vertical' }
$count = Add-Ui $gNew Label @{ Location = (P 12 108); Size = (S 120 22); Text = "0 / $MotdMaxText" }
Add-Ui $gNew Label @{ Location = (P 12 140); Size = (S 112 24); Text = 'Goes away after' } | Out-Null
$expiry = Add-Ui $gNew NumericUpDown @{ Location = (P 126 138); Size = (S 80 26); Minimum = 0; Maximum = $MotdMaxMinutes; Value = 0 }
$unit = Add-Ui $gNew ComboBox @{ Location = (P 212 138); Size = (S 86 26); DropDownStyle = 'DropDownList' }
[void]$unit.Items.AddRange(@('minutes', 'hours'))
$unit.SelectedIndex = 0
# (the server takes up to 90 days either way; lowering Maximum clamps the number)
$unit.Add_SelectedIndexChanged({ $expiry.Maximum = if ($unit.Text -eq 'hours') { $MotdMaxHours } else { $MotdMaxMinutes } })
Add-Ui $gNew Label @{ Location = (P 304 140); Size = (S 136 24); Text = '(0 = until cleared)' } | Out-Null
$presets = @()
$x = 12
foreach ($p in @(@('Never', 0, 'minutes'), @('30 min', 30, 'minutes'), @('1 h', 1, 'hours'), @('24 h', 24, 'hours'), @('1 week', 168, 'hours'))) {
    $b = Add-Ui $gNew Button @{ Text = $p[0]; Location = (P $x 172); Size = (S 74 28); Tag = $p }
    $b.Add_Click({ $unit.Text = $this.Tag[2]; $expiry.Value = [int]$this.Tag[1] })
    $presets += $b
    $x += 80
}
$btnSend = Add-Ui $gNew Button @{ Text = 'Send to players'; Location = (P 446 158); Size = (S 158 42); Enabled = $false
    Font = (New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)) }

# the admin token (once)
$gTok = Add-Ui $form GroupBox @{ Text = 'Admin token (once per PC / server)'; Location = (P 12 380); Size = (S 616 116) }
$tokInfo = Add-Ui $gTok Label @{ Location = (P 12 22); Size = (S 592 44) }
$btnMake = Add-Ui $gTok Button @{ Text = 'Make token'; Location = (P 12 72); Size = (S 110 30) }
$btnCopy = Add-Ui $gTok Button @{ Text = 'Copy token'; Location = (P 128 72); Size = (S 110 30) }
$btnSetup = Add-Ui $gTok Button @{ Text = 'Set up server (table, token, deploy)'; Location = (P 244 72); Size = (S 360 30) }

Add-Ui $form Label @{ Location = (P 12 506); Size = (S 54 24); Text = 'Server' } | Out-Null
$urlBox = Add-Ui $form TextBox @{ Location = (P 68 503); Size = (S 560 26); Text = $Url }
$status = Add-Ui $form Label @{ Location = (P 12 536); Size = (S 616 24); AutoEllipsis = $true
    Font = (New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)) }

function Set-Status([string]$Text, [bool]$Bad = $false) {
    $status.Text = $Text
    $status.ForeColor = if ($Bad) { [Drawing.Color]::Firebrick } else { [Drawing.Color]::DarkGreen }
}

# the server's refusals in words (realms-backend: 404 on GET = a server without /v1/motd (not deployed since the
# MOTD was added), 404 on PUT/DELETE = that or no MOTD_TOKEN secret yet, 403 = another token, 429 = 30 an hour)
function Get-MotdHint([string]$Message, [bool]$Read = $false) {
    if ($Message -match 'said 404' -and $Read) { return "(404): the server doesn't have the message of the day yet - Set up server" }
    if ($Message -match 'said 404') { return '(404): the server has no admin token yet - Set up server' }
    if ($Message -match 'said 403') { return "(403): this PC's token isn't the server's - Set up server again" }
    if ($Message -match 'said 429') { return '(429): too many admin calls (30 an hour) - wait a while' }
    return ''
}

function Invoke-Ui([string]$What, [scriptblock]$Do) {
    $form.Cursor = 'WaitCursor'
    try { & $Do; return $true }
    catch {
        $m = $_.Exception.Message
        $hint = Get-MotdHint $m ($What -eq 'Checking')
        $line = if ($hint) { "$What failed $hint" } else { "$What failed: $m" }
        Set-Status $line $true
        if ($What -eq 'Checking') {
            $nowText.Text = ''
            $nowInfo.Text = "Couldn't check - see the red line below."
            $btnClear.Enabled = $false
        } elseif ($What -in 'Sending', 'Clearing') { Show-MotdProblem $line }
        return $false
    }
    finally { $form.Cursor = 'Default' }
}

# When every running game has the change: each bridge asks on its own timer (60 s from the next update, every
# 10 min in 0.14.2 and older), then the mod reads the file within 5 s. Counted from the server's time of the message.
$EtaNew, $EtaOld = 65, 605
$script:changedAt = 0        # unix s of the last send/clear seen here (0: nothing to count)
$script:changeWord = 'have it'

function Format-Eta([long]$Secs) { return ('{0}:{1:00}' -f [math]::Floor($Secs / 60), ($Secs % 60)) }

function Update-Eta([long]$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
    if (-not $script:changedAt) { $eta.Text = ''; return }
    $new = $script:changedAt + $EtaNew - $Now
    $old = $script:changedAt + $EtaOld - $Now
    $w = $script:changeWord
    $eta.Text = if ($new -gt 0) { "Every running game will $w in $(Format-Eta $new)`r`n(games on 0.14.2 or older: in $(Format-Eta $old))" }
                elseif ($old -gt 0) { "Every updated game will $w now`r`n(games on 0.14.2 or older: in $(Format-Eta $old))" }
                else { "Every running game will $w now." }
}

function Show-Now($m) {
    if ($m.id -and $m.created_at) { $script:changedAt = [long]$m.created_at; $script:changeWord = 'have it' }
    Update-Eta
    if (-not $m.id) {
        $nowText.Text = ''
        $nowInfo.Text = 'No message of the day.'
        $btnClear.Enabled = $false
    } else {
        $nowText.Text = $m.text
        $nowInfo.Text = 'Message ' + $m.id + ', ' + (Format-MotdTill $m)
        $btnClear.Enabled = [bool](Get-MotdToken)
    }
}

function Update-Ui {
    $tok = [bool](Get-MotdToken)
    $n = (New-MotdBody $newText.Text).text.Length
    $count.Text = "$n / $MotdMaxText"
    $btnSend.Enabled = $tok -and $n -ge 1 -and $n -le $MotdMaxText
    if (-not $tok) { $btnClear.Enabled = $false }
    $btnMake.Enabled = -not $tok
    $btnCopy.Enabled = $tok
    $btnSetup.Enabled = $tok
    $tokInfo.Text = if ($tok) { "Token found (tools\motd-token.txt). The server needs it once: Set up server (a console runs the three steps)." }
                    else { 'No admin token on this PC yet: Make token, then Set up server (once; a console runs the table, token and deploy steps).' }
}

function Invoke-Refresh {
    if (Invoke-Ui 'Checking' { Show-Now (Invoke-Motd 'GET' $null $urlBox.Text) }) { Set-Status ('Checked at ' + (Get-Date -Format 'HH:mm:ss') + '.') }
}

function Invoke-Send {
    $n = [int]$expiry.Value
    $body = if ($unit.Text -eq 'hours') { New-MotdBody $newText.Text $n } else { New-MotdBody $newText.Text 0 $n }
    if (-not $body.text) { return }
    $till = if ($body.minutes) { "for $($body.minutes) minutes" } elseif ($body.hours) { "for $($body.hours) hours" } else { 'until you clear it' }
    if (-not (Confirm-Motd ("Send this to every SurrounSync player, ${till}? It replaces the current message.`r`n`r`n" + $body.text))) { return }
    if (Invoke-Ui 'Sending' { Show-Now (Invoke-Motd 'PUT' $body $urlBox.Text) }) {
        $newText.Clear()
        Set-Status 'Sent. Players get it within a minute (0.14.2 and older: within 10 minutes).'
    }
}

function Invoke-Clear {
    if (-not (Confirm-Motd 'Remove the message of the day for every player?')) { return }
    if (Invoke-Ui 'Clearing' {
            $r = Invoke-Motd 'DELETE' $null $urlBox.Text
            $script:changedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $script:changeWord = 'have it gone'
            Show-Now $r
        }) { Set-Status 'Cleared. Players see it gone within a minute (0.14.2 and older: 10 minutes).' }
}

# tools\MOTD-setup-server.cmd in its own console (wrangler may ask to log in or confirm; its result shows there)
function Start-Setup {
    $script = Join-Path $PSScriptRoot 'MOTD-setup-server.cmd'
    if (-not (Test-Path (Join-Path $Backend 'wrangler.toml'))) { Set-Status "realms-backend not found at $Backend" $true; return }
    if (-not (Test-Path $script)) { Set-Status "$script not found" $true; return }
    if (-not (Confirm-Motd "Set up the message of the day on the Realms server? A console runs:`r`n1. the motd table`r`n2. this PC's admin token as the server's MOTD_TOKEN`r`n3. npx wrangler deploy (realms-backend as it is in this folder)`r`nPress Refresh here when it says Done.")) { return }
    Start-Process $script -WorkingDirectory $Backend
    Set-Status 'Opened the setup console - press Refresh when it says Done.'
}

$btnRefresh.Add_Click({ Invoke-Refresh })
$btnSend.Add_Click({ Invoke-Send })
$btnClear.Add_Click({ Invoke-Clear })
$newText.Add_TextChanged({ Update-Ui })
$btnMake.Add_Click({
    if (Invoke-Ui 'Making the token' { [void](New-MotdToken) }) { Set-Status 'Token made. Next: Put token on server, then Create table on server.'; Update-Ui }
})
$btnCopy.Add_Click({
    if (Invoke-Ui 'Copying' { [Windows.Forms.Clipboard]::SetText((Get-MotdToken)) }) { Set-Status 'Token copied - keep it private.' }
})
$btnSetup.Add_Click({ Start-Setup })
$timer = New-Object Windows.Forms.Timer -Property @{ Interval = 1000 }
$timer.Add_Tick({ Update-Eta })
$form.Add_Shown({ Update-Ui; Invoke-Refresh; $timer.Start() })
$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })

if (-not $NoShow) { [void]$form.ShowDialog() }
