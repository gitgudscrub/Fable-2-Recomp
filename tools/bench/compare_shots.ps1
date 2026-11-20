# Classic vs Modern screenshot pairs for the launcher's comparison slider.
# Boots the Release build twice: once with the Original edition's settings
# (Classic) and once with Project Sparrow's (Modern). In each run it starts a
# New Game, loads each region, sets the hour, hides the HUD, turns the hero to
# face north and takes one shot from the region's start camera, so every
# Classic shot has a Modern twin taken from the same spot.
#
# Shots land in %TEMP%\fable2-compare\<classic|modern>\<Region>.png.
# The build's fable2_config.toml and saves folder are backed up first and put
# back when the run ends. Needs the PC to itself (about 30 min).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\bench\compare_shots.ps1 [-Only "BowerLake,BWSMarket"] [-Pass modern]
param(
  [string[]]$Only = @(),
  [ValidateSet('both', 'classic', 'modern')][string]$Pass = 'both',
  [int]$Hour = 15,
  [int]$Width = 1920,
  [int]$Height = 1080,
  [string]$Root = 'E:\Fable 2\Fable-2-Recomp',
  [string]$Build = 'E:\Fable 2\Fable-2-Recomp\out\build\win-amd64-release'
)
$ErrorActionPreference = 'Stop'
if (Get-Process fable_2 -ErrorAction SilentlyContinue) { throw 'A game is already running; close it first.' }

# Region path and start marker ('' = default). Outdoor regions only.
$regions = @(
  @('BWSMarket', ''), @('BowerLake', ''), @('Brightwood', ''), @('Ravenscar', ''), @('DunecrestNew', 'PlayerStart'),
  @('Westcliff', ''), @('Wraithmarsh', ''), @('Bloodstone', ''), @('FairfaxCastleGardens', ''), @('BWSCemetary', 'PlayerStart')
)
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($Only.Count) { $regions = @($regions | Where-Object { $Only -contains $_[0] }) }

# Graphics per pass: [graphics] keys in fable2_config.toml and SDK arguments,
# as the launcher's Original and Project Sparrow editions set them.
$passes = [ordered]@{
  classic = @{ toml = @{ texture_pack = 'false'; ultra = 'false'; sparrow_renderer = 'false' }
               args = '--resolution_scale=1 --anisotropic_override=-1 --swap_post_effect=none' }
  modern  = @{ toml = @{ texture_pack = 'true'; ultra = 'true'; sparrow_renderer = 'true' }
               args = '--resolution_scale=2 --anisotropic_override=5 --swap_post_effect=fxaa' }
}
if ($Pass -ne 'both') { $passes = [ordered]@{ $Pass = $passes[$Pass] } }

function Send-Console([string[]]$lines) {
  $in = Join-Path $Root 'console\in.txt'
  $deadline = (Get-Date).AddSeconds(10)
  while ((Test-Path $in) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
  $tmp = Join-Path $Root 'console\in.tmp'
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
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class CW {
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rt,B; }
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[CW]::SetProcessDPIAware() | Out-Null
function Shot([string]$path) {
  $script:p.Refresh(); $h = $script:p.MainWindowHandle
  $r = New-Object CW+R; [CW]::GetClientRect($h, [ref]$r) | Out-Null
  $bmp = New-Object System.Drawing.Bitmap $r.Rt, $r.B
  # Flag 3 = client area only, full content (PW_CLIENTONLY | PW_RENDERFULLCONTENT).
  $g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc(); [CW]::PrintWindow($h, $dc, 3) | Out-Null; $g.ReleaseHdc($dc); $g.Dispose()
  $bmp.Save($path); $bmp.Dispose()
}
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

$out = Join-Path $env:TEMP 'fable2-compare'
$config = Join-Path $Build 'fable2_config.toml'
$template = [IO.File]::ReadAllText((Join-Path $Root 'config\fable2_config.toml'))
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $env:TEMP "fable2-compare-backup-$stamp"
New-Item -ItemType Directory -Force $backup | Out-Null
$saves = Join-Path $Build 'saves'
Copy-Item $config (Join-Path $backup 'fable2_config.toml')
if (Test-Path $saves) { Copy-Item $saves (Join-Path $backup 'saves') -Recurse }
"config and saves backed up to $backup"
New-Item -ItemType Directory -Force (Join-Path $Root 'console') | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding $false

try {
  foreach ($name in $passes.Keys) {
    $cfg = $passes[$name]
    $dir = Join-Path $out $name
    New-Item -ItemType Directory -Force $dir | Out-Null
    [IO.File]::WriteAllText($config, (Set-GraphicsKeys $template $cfg.toml), $utf8)
    # Each pass starts from the same empty saves folder (New Game path).
    Remove-Item $saves -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $saves | Out-Null
    Remove-Item (Join-Path $Root 'console\in.txt') -ErrorAction SilentlyContinue

    $before = Get-Date
    # Uncapped while in the menus: the pad presses are timed in frames, as in bench.ps1.
    $gameArgs = "--game_data_root=`"$Root`" --vsync=false --fullscreen=false --window_width=$Width --window_height=$Height $($cfg.args)"
    $script:p = Start-Process (Join-Path $Build 'fable_2.exe') -ArgumentList $gameArgs -WorkingDirectory $Build -PassThru
    try {
      $script:log = $null
      for ($i = 0; $i -lt 60 -and -not $script:log; $i++) {
        Start-Sleep 1
        $script:log = Get-ChildItem (Join-Path $Build 'logs') -File | Where-Object { $_.LastWriteTime -ge $before } |
          Sort-Object LastWriteTime | Select-Object -Last 1
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
      Send-Console @('cvar frame_limit 60', 'godmode on')
      "[$name] in game (log $($script:log.Name))"

      foreach ($rg in $regions) {
        $region, $marker = $rg
        $expect = '"albion", "' + [regex]::Escape($region.ToLower()) + '"'
        $seen = Count-Log $expect
        $load = "lua Debug.LoadLevel(`"Albion`", `"$region`", `"$marker`")"
        Send-Console @($load)
        $loaded = $false
        $deadline = (Get-Date).AddSeconds(120)
        $resend = (Get-Date).AddSeconds(30)
        while (-not $loaded -and (Get-Date) -lt $deadline) {
          Start-Sleep 4
          if ($script:p.HasExited) { throw 'game exited' }
          # A command sent while the game is busy can be dropped: send the load again.
          if ((Get-Date) -gt $resend) { Send-Console @($load); $resend = (Get-Date).AddSeconds(30) }
          Send-Console @('info'); Start-Sleep 1
          $loaded = (Count-Log $expect) -gt $seen
        }
        if (-not $loaded) { "[$name] $region did not load"; continue }
        Start-Sleep 8
        Send-Console @("time $Hour", 'gui off')
        Start-Sleep 4
        # The start camera stays where it is; facing only turns the hero, so both passes match.
        Send-Console @('lua local h=GetPlayerHero() pcall(Physics.SetFacingVector, h, CVector3(0, 1, 0)) Debug.ReloadCameras()')
        # Long enough for streaming and first-time shader builds to settle.
        Start-Sleep 12
        Shot (Join-Path $dir "$region.png")
        Send-Console @('gui on')
        "[$name] $region done"
      }
    } finally {
      if ($script:p -and -not $script:p.HasExited) {
        $script:p.CloseMainWindow() | Out-Null
        if (-not $script:p.WaitForExit(20000)) { $script:p.Kill() }
      }
      Start-Sleep 2
    }
  }
} finally {
  Copy-Item (Join-Path $backup 'fable2_config.toml') $config -Force
  Remove-Item $saves -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path (Join-Path $backup 'saves')) { Copy-Item (Join-Path $backup 'saves') $saves -Recurse } else { New-Item -ItemType Directory -Force $saves | Out-Null }
  "config and saves restored from $backup"
}
"shots in $out"
