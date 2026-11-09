# Hands-free in-game FPS benchmark: boot, load the latest save with console `pad` presses,
# let the hero stand still, measure uncapped FPS for MeasureSec, screenshot, close.
param(
  [string]$Label = 'bench',
  [string]$ExtraArgs = '',
  [int]$SettleSec = 20,
  [int]$MeasureSec = 60,
  [string]$Build = 'E:\Fable 2\Fable-2-Recomp\out\build\win-amd64-release'
)
$ErrorActionPreference = 'Stop'
$root = 'E:\Fable 2\Fable-2-Recomp'          # game data root (console\ lives here)
$s = Join-Path $env:TEMP 'fable2-bench'   # screenshots go here
New-Item -ItemType Directory -Force $s | Out-Null
$fpsLog = Join-Path $Build 'fps_meter.log'

function Send-Console([string[]]$lines) {
  $in = Join-Path $root 'console\in.txt'
  $deadline = (Get-Date).AddSeconds(10)
  while ((Test-Path $in) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }  # previous batch not consumed yet
  $tmp = Join-Path $root 'console\in.tmp'
  Set-Content -Path $tmp -Value ($lines -join "`n") -Encoding ascii
  Move-Item $tmp $in -Force
}
function Wait-Log([string]$pattern, [int]$afterCount, [int]$timeoutSec) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    $n = (Select-String $script:log.FullName -Pattern $pattern | Measure-Object).Count
    if ($n -gt $afterCount) { return $true }
    if ($script:p.HasExited) { throw "game exited" }
    Start-Sleep -Milliseconds 250
  }
  return $false
}
function Count-Log([string]$pattern) { (Select-String $script:log.FullName -Pattern $pattern | Measure-Object).Count }

New-Item -ItemType Directory -Force (Join-Path $root 'console') | Out-Null
Remove-Item (Join-Path $root 'console\in.txt') -ErrorAction SilentlyContinue
Remove-Item $fpsLog -ErrorAction SilentlyContinue
$env:FABLE2_FPS_METER = '1'
$before = Get-Date
$script:p = Start-Process (Join-Path $Build 'fable_2.exe') -ArgumentList ("--game_data_root=`"$root`" --vsync=false " + $ExtraArgs) -WorkingDirectory $Build -PassThru
try {
  $script:log = $null
  for ($i = 0; $i -lt 60 -and -not $script:log; $i++) {
    Start-Sleep 1
    $script:log = Get-ChildItem (Join-Path $Build 'logs') -File | Where-Object { $_.LastWriteTime -ge $before } | Sort-Object LastWriteTime | Select-Object -Last 1
  }
  if (-not $script:log) { throw "no log" }

  # Title screen ready: the logo videos and the intro video have ended.
  if (-not (Wait-Log 'video ended' 1 120)) { throw "title not reached" }
  # Title: the legal text ends (END_LEGAL), then "Press A". The main menu logs
  # no marker of its own, so drive it by time: title A, then the documented
  # menu sequence (docs/console/CONSOLE-COMMANDS.md) to load the latest save.
  # Entering the game logs "FinishedTransitioningToGame" when the HUD loads.
  if (-not (Wait-Log 'fireEvent: END_LEGAL' 0 60)) { throw "legal text did not finish" }
  Start-Sleep 3
  $hud = Count-Log 'FinishedTransitioningToGame'
  # Title A, then A on the first main-menu item (Continue = latest save).
  # (Down then A starts a New Game on this setup.)
  # Main menu: New Game, Continue, ... Continue loads the autosave from right
  # after character creation, so every run replays the same opening without
  # creating a new save (New Game would, after the character cards).
  # Continue then shows the save cards; A picks the first (every save starts
  # right after character creation).
  Send-Console @('pad A 120', 'wait 5s', 'pad Down 60', 'wait 2s', 'pad A 60', 'wait 3s', 'pad A 60')
  if (-not (Wait-Log 'FinishedTransitioningToGame' $hud 120)) { throw "game not entered" }
  $tInGame = Get-Date
  # The opening cutscene runs at 30 FPS; Start skips it. Then wait until the
  # frame rate stays clearly above 30 for 3 checks in a row (~6 s): player in
  # control. A single check was fooled by a burst of fast loading frames.
  Start-Sleep 4
  Send-Console @('pad Start 60')
  $deadline = (Get-Date).AddSeconds(240)
  $control = $false
  $streak = 0
  while ((Get-Date) -lt $deadline -and -not $control) {
    Start-Sleep 2
    $tail = Get-Content $fpsLog -Tail 400 | ForEach-Object { if ($_ -match 'rate=([\d.]+)') { [double]$Matches[1] } } | Where-Object { $_ -gt 0 }
    $ms = ($tail | Select-Object -Last 200 | ForEach-Object { 1000.0 / $_ } | Measure-Object -Sum).Sum
    if ($ms -gt 0 -and (200 / ($ms / 1000)) -gt 50) { $streak++ } else { $streak = 0 }
    if ($streak -ge 3) { $control = $true }
  }
  if (-not $control) { throw "still in a 30 FPS scene after 240 s" }
  "[{0}] in control {1:N0} s after the HUD loaded" -f $Label, ((Get-Date) - $tInGame).TotalSeconds
  Start-Sleep $SettleSec

  # Measure: frames logged during the window (one fps_meter line per frame).
  $n0 = (Get-Content $fpsLog | Measure-Object).Count
  $t0 = Get-Date
  Start-Sleep $MeasureSec
  $lines = Get-Content $fpsLog
  $t1 = Get-Date
  $window = $lines[$n0..($lines.Count - 1)] | ForEach-Object { if ($_ -match 'rate=([\d.]+)') { [double]$Matches[1] } } | Where-Object { $_ -gt 0 }
  $ft = $window | ForEach-Object { 1000.0 / $_ } | Sort-Object
  $secs = ($t1 - $t0).TotalSeconds
  $avg = $window.Count / $secs
  $p1 = 1000.0 / $ft[[int]($ft.Count * 0.99)]
  $med = 1000.0 / $ft[[int]($ft.Count * 0.5)]

  # Screenshot to confirm we were in game.
  Add-Type -AssemblyName System.Drawing
  Add-Type @'
using System; using System.Runtime.InteropServices;
public static class WB {
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rt,B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
  [WB]::SetProcessDPIAware() | Out-Null
  $script:p.Refresh(); $h = $script:p.MainWindowHandle
  $r = New-Object WB+R; [WB]::GetWindowRect($h, [ref]$r) | Out-Null
  $bmp = New-Object System.Drawing.Bitmap ($r.Rt - $r.L), ($r.B - $r.T)
  $g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc(); [WB]::PrintWindow($h, $dc, 2) | Out-Null; $g.ReleaseHdc($dc); $g.Dispose()
  $small = New-Object System.Drawing.Bitmap $bmp, ([int]($bmp.Width / 4)), ([int]($bmp.Height / 4))
  $small.Save((Join-Path $s "bench_$Label.png")); $small.Dispose(); $bmp.Dispose()

  $errs = Count-Log 'device removed|\[error\] \[gpu\]'
  "[{0}] avg {1:N1} FPS  median {2:N1}  1% low {3:N1}  ({4} frames / {5:N0} s)  gpu_errors {6}" -f $Label, $avg, $med, $p1, $window.Count, $secs, $errs
} finally {
  if (-not $script:p.HasExited) { $script:p.CloseMainWindow() | Out-Null; if (-not $script:p.WaitForExit(15000)) { $script:p.Kill() } }
}

