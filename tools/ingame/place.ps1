# Places the two game windows side by side (for watching both test games at once).
param([int]$ProcessId, [string]$Side)
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class W {
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool r);
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public static IntPtr Find(uint want) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid != want || !IsWindowVisible(h)) return true;
            var s = new StringBuilder(64); GetClassName(h, s, 64);
            if (s.ToString() == "UnrealWindow") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@
$a = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$w = [int]($a.Width / 2)
$x = if ($Side -eq "right") { $a.X + $w } else { $a.X }
$placed = $false
for ($i = 0; $i -lt 160; $i++) {
    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { "pid $ProcessId gone"; exit 1 }
    $h = [W]::Find([uint32]$ProcessId)
    if ($h -ne [IntPtr]::Zero) {
        $r = New-Object W+RECT
        [W]::GetWindowRect($h, [ref]$r) | Out-Null
        if ($r.Left -ne $x -or $r.Top -ne $a.Y -or ($r.Right - $r.Left) -ne $w -or ($r.Bottom - $r.Top) -ne $a.Height) {
            [W]::MoveWindow($h, $x, $a.Y, $w, $a.Height, $true) | Out-Null
            if (-not $placed) { "pid $ProcessId -> $Side ($x,$($a.Y) ${w}x$($a.Height)) after $i tries" }
            $placed = $true
        }
    }
    Start-Sleep -Milliseconds 250
}
if (-not $placed) { "pid ${ProcessId}: no game window found" }
