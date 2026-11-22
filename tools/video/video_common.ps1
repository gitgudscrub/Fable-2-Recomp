# Shared helpers for record_run.ps1 and replay_run.ps1 (comparison videos).
# Dot-source it: . "$PSScriptRoot\video_common.ps1"
#
# Each run boots the Release build with one edition's graphics, starts a New
# Game, jumps to the chosen region and turns the hero into an adult in the
# swashbuckler outfit (the prologue child ignores the stick after a level
# jump). Every run sets up the start the same way, so a replay starts where the
# recording did. The build's fable2_config.toml and saves are backed up first
# and put back afterwards (Backup-Build / Restore-Build).

$ErrorActionPreference = 'Stop'
$script:Root = 'E:\Fable 2\Fable-2-Recomp'
$script:Build = Join-Path $script:Root 'out\build\win-amd64-release'

# Graphics per edition: [graphics] keys in fable2_config.toml and SDK
# arguments, as the launcher's editions set them. Remade models are not loaded
# here (the dev build plays from the plain game files).
$script:EditionTable = [ordered]@{
  original = @{ label = 'Original'; fps = 30
                toml = @{ texture_pack = 'false'; ultra = 'false'; sparrow_renderer = 'false' }
                args = '--resolution_scale=1 --anisotropic_override=-1 --swap_post_effect=none' }
  enhanced = @{ label = 'Enhanced'; fps = 60
                toml = @{ texture_pack = 'true'; ultra = 'true'; sparrow_renderer = 'false' }
                args = '--resolution_scale=2 --anisotropic_override=5 --swap_post_effect=fxaa' }
  sparrow  = @{ label = 'Project Sparrow'; fps = 60
                toml = @{ texture_pack = 'true'; ultra = 'true'; sparrow_renderer = 'true' }
                args = '--resolution_scale=2 --anisotropic_override=5 --swap_post_effect=fxaa' }
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class VW {
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rt,B; }
  [StructLayout(LayoutKind.Sequential)] public struct P { public int X,Y; }
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref P p);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
}
'@
[VW]::SetProcessDPIAware() | Out-Null

function Send-Console([string[]]$lines) {
  $in = Join-Path $script:Root 'console\in.txt'
  $deadline = (Get-Date).AddSeconds(10)
  while ((Test-Path $in) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
  $tmp = Join-Path $script:Root 'console\in.tmp'
  Set-Content -Path $tmp -Value ($lines -join "`n") -Encoding ascii
  Move-Item $tmp $in -Force
}
function Count-Log([string]$pattern) { (Select-String $script:log.FullName -Pattern $pattern | Measure-Object).Count }
function Wait-Log([string]$pattern, [int]$afterCount, [int]$timeoutSec) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    if ((Count-Log $pattern) -gt $afterCount) { return $true }
    if ($script:p.HasExited) { throw 'game exited' }
    Start-Sleep -Milliseconds 250
  }
  return $false
}
function Last-Log([string]$pattern) { (Select-String $script:log.FullName -Pattern $pattern | Select-Object -Last 1).Line }

function Set-GraphicsKeys([string]$text, [hashtable]$keys) {
  $lines = $text -split "`r?`n"
  $section = ''
  $seen = @{}
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*\[(\w+)\]') { $section = $Matches[1]; continue }
    if ($section -eq 'graphics' -and $lines[$i] -match '^\s*(\w+)\s*=' -and $keys.ContainsKey($Matches[1])) {
      $lines[$i] = "$($Matches[1]) = $($keys[$Matches[1]])"; $seen[$Matches[1]] = $true
    }
  }
  $missing = @($keys.Keys | Where-Object { -not $seen[$_] } | ForEach-Object { "$_ = $($keys[$_])" })
  if ($missing.Count) {
    $at = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match '^\s*\[graphics\]' })
    if ($at -lt 0) { $lines += '[graphics]'; $at = $lines.Count - 1 }
    $lines = @($lines[0..$at]) + $missing + @($lines[($at + 1)..($lines.Count - 1)])
  }
  $lines -join "`n"
}

function Backup-Build {
  if (Get-Process fable_2 -ErrorAction SilentlyContinue) { throw 'A game is already running; close it first.' }
  $script:backup = Join-Path $env:TEMP ("fable2-video-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Force $script:backup | Out-Null
  Copy-Item (Join-Path $script:Build 'fable2_config.toml') (Join-Path $script:backup 'fable2_config.toml')
  $saves = Join-Path $script:Build 'saves'
  if (Test-Path $saves) { Copy-Item $saves (Join-Path $script:backup 'saves') -Recurse }
  New-Item -ItemType Directory -Force (Join-Path $script:Root 'console') | Out-Null
  "config and saves backed up to $script:backup"
}
function Restore-Build {
  Copy-Item (Join-Path $script:backup 'fable2_config.toml') (Join-Path $script:Build 'fable2_config.toml') -Force
  $saves = Join-Path $script:Build 'saves'
  Remove-Item $saves -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path (Join-Path $script:backup 'saves')) { Copy-Item (Join-Path $script:backup 'saves') $saves -Recurse }
  else { New-Item -ItemType Directory -Force $saves | Out-Null }
  "config and saves restored from $script:backup"
}

# Boots the game in an edition and plays through the menus into a New Game.
function Start-Game([string]$edition, [int]$Width, [int]$Height) {
  $cfg = $script:EditionTable[$edition]
  if (-not $cfg) { throw "unknown edition $edition (original, enhanced, sparrow)" }
  $template = [IO.File]::ReadAllText((Join-Path $script:Root 'config\fable2_config.toml'))
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [IO.File]::WriteAllText((Join-Path $script:Build 'fable2_config.toml'), (Set-GraphicsKeys $template $cfg.toml), $utf8)
  $saves = Join-Path $script:Build 'saves'
  Remove-Item $saves -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $saves | Out-Null
  Remove-Item (Join-Path $script:Root 'console\in.txt') -ErrorAction SilentlyContinue

  $before = Get-Date
  # Uncapped in the menus: the pad presses are timed in frames, as in bench.ps1.
  $gameArgs = "--game_data_root=`"$script:Root`" --vsync=false --fullscreen=false --window_width=$Width --window_height=$Height $($cfg.args)"
  $script:p = Start-Process (Join-Path $script:Build 'fable_2.exe') -ArgumentList $gameArgs -WorkingDirectory $script:Build -PassThru
  $script:log = $null
  for ($i = 0; $i -lt 60 -and -not $script:log; $i++) {
    Start-Sleep 1
    $script:log = Get-ChildItem (Join-Path $script:Build 'logs') -Filter 'fable_2_*.log' -File |
      Where-Object { $_.LastWriteTime -ge $before } | Sort-Object LastWriteTime | Select-Object -Last 1
  }
  if (-not $script:log) { throw 'no log' }
  if (-not (Wait-Log 'video ended' 1 120)) { throw 'title not reached' }
  if (-not (Wait-Log 'fireEvent: END_LEGAL' 0 60)) { throw 'legal text did not finish' }
  Start-Sleep 3
  $hud = Count-Log 'FinishedTransitioningToGame'
  # Title A, New Game (first item), the boy's card twice, confirm.
  Send-Console @('pad A 120'); Start-Sleep 6
  Send-Console @('pad A 60'); Start-Sleep 12
  Send-Console @('pad Left 60'); Start-Sleep 3; Send-Console @('pad A 90'); Start-Sleep 4
  Send-Console @('pad Left 60'); Start-Sleep 3; Send-Console @('pad A 90'); Start-Sleep 8
  Send-Console @('pad A 90')
  if (-not (Wait-Log 'FinishedTransitioningToGame' $hud 300)) { throw 'game not entered' }
  Start-Sleep 4
  Send-Console @('pad Start 60')
  Start-Sleep 20
  Send-Console @("cvar frame_limit $($cfg.fps)", 'godmode on')
  "[$edition] in game (log $($script:log.Name))"
}

# Loads the region and sets up the start: adult hero in the swashbuckler
# outfit, the hour, the follow camera. Same steps every time.
function Prepare-Start([string]$Region, [string]$Marker, [int]$Hour) {
  $expect = '"albion", "' + [regex]::Escape($Region.ToLower()) + '"'
  $seen = Count-Log $expect
  $load = "lua Debug.LoadLevel(`"Albion`", `"$Region`", `"$Marker`")"
  Send-Console @($load)
  $deadline = (Get-Date).AddSeconds(120); $resend = (Get-Date).AddSeconds(30); $loaded = $false
  while (-not $loaded -and (Get-Date) -lt $deadline) {
    Start-Sleep 4
    if ($script:p.HasExited) { throw 'game exited' }
    # A command sent while the game is busy can be dropped: send the load again.
    if ((Get-Date) -gt $resend) { Send-Console @($load); $resend = (Get-Date).AddSeconds(30) }
    Send-Console @('info'); Start-Sleep 1
    $loaded = (Count-Log $expect) -gt $seen
  }
  if (-not $loaded) { throw "$Region did not load" }
  Start-Sleep 8
  Send-Console @('entitytype CreatureHero'); Start-Sleep 5
  Send-Console @('lua Debug.SetHeroWearingSwashBucklerOutfit()'); Start-Sleep 2
  Send-Console @("time $Hour"); Start-Sleep 2
  Send-Console @('lua Debug.ReloadCameras()')
  # Streaming and first-time shader builds settle.
  Start-Sleep 10
}

function Focus-Game([switch]$OnTop) {
  $script:p.Refresh()
  (New-Object -ComObject WScript.Shell).AppActivate($script:p.Id) | Out-Null
  [VW]::SetForegroundWindow($script:p.MainWindowHandle) | Out-Null
  # Filming grabs the screen, so the game must be on top. Windows may refuse
  # to bring it to the front from a script; always-on-top works regardless.
  # HWND_TOPMOST, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW.
  if ($OnTop) { [VW]::SetWindowPos($script:p.MainWindowHandle, [IntPtr](-1), 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0010 -bor 0x0040) | Out-Null }
  Start-Sleep -Milliseconds 500
}

function Close-Game {
  if ($script:p -and -not $script:p.HasExited) {
    $script:p.CloseMainWindow() | Out-Null
    if (-not $script:p.WaitForExit(20000)) { $script:p.Kill() }
  }
  Start-Sleep 2
}

# The game's client area on screen: monitor index (for ffmpeg ddagrab) and
# the offset inside that monitor, in physical pixels.
function Get-GameRect {
  $script:p.Refresh(); $h = $script:p.MainWindowHandle
  $r = New-Object VW+R; [VW]::GetClientRect($h, [ref]$r) | Out-Null
  $pt = New-Object VW+P; [VW]::ClientToScreen($h, [ref]$pt) | Out-Null
  $screens = [System.Windows.Forms.Screen]::AllScreens
  for ($i = 0; $i -lt $screens.Count; $i++) {
    $b = $screens[$i].Bounds
    if ($pt.X -ge $b.Left -and $pt.X -lt $b.Right -and $pt.Y -ge $b.Top -and $pt.Y -lt $b.Bottom) {
      return @{ monitor = $i; x = $pt.X - $b.Left; y = $pt.Y - $b.Top; w = $r.Rt - ($r.Rt % 2); h = $r.B - ($r.B % 2) }
    }
  }
  throw 'game window is not on any monitor'
}

function Get-FFmpeg {
  $f = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg*\*\bin\ffmpeg.exe" -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if (-not $f) { $c = Get-Command ffmpeg -ErrorAction SilentlyContinue; if ($c) { return $c.Source } }
  if (-not $f) { throw 'ffmpeg not found (winget install Gyan.FFmpeg)' }
  $f.FullName
}
