# Samples the pixels across the left, right and bottom edges of a window (by
# title) and prints them outside-in, so a white unpainted strip between the DWM
# border and the client shows up as FFFFFF. Usage:
#   pwsh scripts/sample_window_edge.ps1 [-Title "Celeris Window Edge"]
param([string]$Title = "Celeris Window Edge")
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll", CharSet=CharSet.Ansi)] public static extern IntPtr FindWindowA(string c, string t);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr dc, int x, int y);
}
"@
[W]::SetProcessDPIAware() | Out-Null
$h = [W]::FindWindowA([NullString]::Value, $Title)
if ($h -eq [IntPtr]::Zero) { Write-Error "window '$Title' not found"; exit 2 }
[W]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 400
$r = New-Object W+RECT; [W]::GetWindowRect($h, [ref]$r) | Out-Null
$e = New-Object W+RECT; [W]::DwmGetWindowAttribute($h, 9, [ref]$e, 16) | Out-Null
"window  L=$($r.L) T=$($r.T) R=$($r.R) B=$($r.B)"
"visible L=$($e.L) T=$($e.T) R=$($e.R) B=$($e.B)"
$dc = [W]::GetDC([IntPtr]::Zero)
function px($x, $y) { $c = [W]::GetPixel($dc, $x, $y); '{0:X2}{1:X2}{2:X2}' -f ($c -band 0xFF), (($c -shr 8) -band 0xFF), (($c -shr 16) -band 0xFF) }
$midY = [int](($e.T + $e.B) / 2); $midX = [int](($e.L + $e.R) / 2)
$white = 0
$left  = (-1..3) | % { px ($e.L + $_) $midY }
$right = (-1..3) | % { px ($e.R - 1 - $_) $midY }
$bot   = (-1..3) | % { px $midX ($e.B - 1 - $_) }
$top   = (-1..3) | % { px $midX ($e.T + $_) }
"left   (out->in): $($left -join ' ')"
"right  (out->in): $($right -join ' ')"
"bottom (out->in): $($bot -join ' ')"
"top    (out->in): $($top -join ' ')"
foreach ($v in ($left[1..4] + $right[1..4] + $bot[1..4] + $top[1..4])) { if ($v -eq 'FFFFFF') { $white++ } }
if ($white -gt 0) { "FAIL: $white white edge pixel(s)"; exit 1 } else { "OK: no white edge pixels" }
