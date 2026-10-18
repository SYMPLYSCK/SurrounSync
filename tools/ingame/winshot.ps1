# Screenshot of one game window, by process id.
param([string]$ExePart, [string]$Out, [double]$Scale = 0.6)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public class W {
  public delegate bool P(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(P f, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  public struct R { public int L, T, Rt, B; }
}
"@
$proc = Get-Process SurrounDead-Win64-Shipping | Where-Object { $_.Path -like "*$ExePart*" } | Select-Object -First 1
$found = $null
[W]::EnumWindows({ param($h, $l) $p = 0; [void][W]::GetWindowThreadProcessId($h, [ref]$p)
  if ($p -eq $proc.Id -and [W]::IsWindowVisible($h)) { $sb = New-Object Text.StringBuilder 256; [void][W]::GetWindowText($h, $sb, 256)
    if ($sb.ToString().StartsWith("SurrounDead")) { $script:found = $h } }; return $true }, [IntPtr]::Zero) | Out-Null
$r = New-Object W+R; [void][W]::GetWindowRect($found, [ref]$r)
$w = $r.Rt - $r.L; $hh = $r.B - $r.T
$bmp = New-Object Drawing.Bitmap $w, $hh; $g = [Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc(); [void][W]::PrintWindow($found, $dc, 2); $g.ReleaseHdc($dc)
$small = New-Object Drawing.Bitmap $bmp, ([int]($w * $Scale)), ([int]($hh * $Scale)); $small.Save($Out)
"$w x $hh"
