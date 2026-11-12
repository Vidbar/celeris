# Samples the corner pixels of the cards in `zig build rounded_clip` and fails if
# a child paints outside its rounded overflowHidden parent. Usage:
#   pwsh scripts/sample_rounded_clip.ps1 [-Title "Celeris Rounded Clip"]
param([string]$Title = "Celeris Rounded Clip")
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [StructLayout(LayoutKind.Sequential)] public struct PT { public int X, Y; }
  [DllImport("user32.dll", CharSet=CharSet.Ansi)] public static extern IntPtr FindWindowA(string c, string t);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref PT p);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr dc, int x, int y);
}
"@
[W]::SetProcessDPIAware() | Out-Null
$h = [W]::FindWindowA([NullString]::Value, $Title)
if ($h -eq [IntPtr]::Zero) { Write-Error "window '$Title' not found"; exit 2 }
[W]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 500
$o = New-Object W+PT; [W]::ClientToScreen($h, [ref]$o) | Out-Null
$s = [W]::GetDpiForWindow($h) / 96.0
$dc = [W]::GetDC([IntPtr]::Zero)
function hex($c) { '{0:X2}{1:X2}{2:X2}' -f ($c -band 0xFF), (($c -shr 8) -band 0xFF), (($c -shr 16) -band 0xFF) }
# The app bar sits inside the client area: the page starts at the first row of
# page color at x=10.
$top = 0
while ($top -lt 200 -and (hex ([W]::GetPixel($dc, [int]($o.X + 10 * $s), [int]($o.Y + $top * $s)))) -ne "202020") { $top++ }
"page top = $top (logical px below the client origin)"
# Logical page px -> hex color of the screen pixel.
function px($x, $y) {
  hex ([W]::GetPixel($dc, [int]($o.X + $x * $s), [int]($o.Y + ($y + $top) * $s)))
}
$fail = 0
function expect($name, $x, $y, $want) {
  $got = px $x $y
  if ($got -eq $want) { "ok    $name ($x,$y) = $got" } else { "FAIL  $name ($x,$y) = $got, want $want"; $script:fail++ }
}
# Card 1 at (40,40) 240x160 r=24, red child: corners show the page.
expect "card1 top-left corner"     43  43  "202020"
expect "card1 top-right corner"    276 43  "202020"
expect "card1 bottom-left corner"  43  196 "202020"
expect "card1 bottom-right corner" 276 196 "202020"
expect "card1 center"              160 150 "E03C3C"
# Card 2 at (320,40), 4px white border: inside the border ring the child is clipped.
expect "card2 outside corner"      323 43  "202020"
expect "card2 border ring corner"  328 48  "FFFFFF"
expect "card2 center"              440 120 "3CC05A"
# Card 3 at (40,240): grandchild under a square overflowHidden box still rounded.
expect "card3 top-left corner"     43  243 "202020"
expect "card3 bottom-right corner" 276 396 "202020"
expect "card3 center"              160 320 "3C78E0"
if ($fail -gt 0) { "FAIL: $fail pixel(s)"; exit 1 } else { "OK: all corners clipped" }
