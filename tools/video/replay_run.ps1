# Film a recorded run (record_run.ps1) in each edition.
#
# For each edition: boots the Release build with that edition's graphics, sets
# up the same start as the recording, hides the HUD, starts ffmpeg on the game
# window and replays the input. Clips land in out\video\<Name>\<edition>.mp4,
# with <edition>.json holding how far the hero drifted from the recorded path
# and where the replay starts in the clip (lead_s), for lining the clips up.
#
# The game window stays on top of everything while it films (it grabs the screen).
# Needs the PC to itself: about 4 minutes per edition plus the run's length.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\video\replay_run.ps1 -Name lake1 [-Editions original,enhanced,sparrow]
param(
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$Name,
  [string[]]$Editions = @('original', 'enhanced', 'sparrow'),
  [double]$LeadSeconds = 2.0
)
. "$PSScriptRoot\video_common.ps1"

$Editions = @($Editions | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$metaPath = Join-Path $script:Root "console\replays\$Name.json"
if (-not (Test-Path $metaPath)) { throw "no recording settings at $metaPath (record with record_run.ps1)" }
$meta = Get-Content $metaPath -Raw | ConvertFrom-Json
$rec = Join-Path $script:Root "console\replays\$Name.f2rec"
$endLine = Select-String $rec -Pattern '^E (\d+)' | Select-Object -Last 1
$length = [double]$endLine.Matches[0].Groups[1].Value / 1e6
$ffmpeg = Get-FFmpeg
$outDir = Join-Path $script:Root "out\video\$Name"
New-Item -ItemType Directory -Force $outDir | Out-Null
"'$Name': $([math]::Round($length, 1)) s in $($meta.region) at $($meta.hour):00"

Backup-Build
try {
  foreach ($edition in $Editions) {
    try {
      Start-Game $edition $meta.width $meta.height
      Prepare-Start $meta.region $meta.marker $meta.hour
      Send-Console @('gui off'); Start-Sleep 2
      Focus-Game -OnTop
      $r = Get-GameRect
      $clip = Join-Path $outDir "$edition.mp4"
      $total = [math]::Ceiling($LeadSeconds + $length + 2)
      $ffArgs = "-hide_banner -y -f lavfi -i ddagrab=output_idx=$($r.monitor):framerate=60:draw_mouse=0:video_size=$($r.w)x$($r.h):offset_x=$($r.x):offset_y=$($r.y) " +
                "-t $total -c:v h264_nvenc -preset p6 -rc vbr -cq 14 -b:v 0 `"$clip`""
      $ff = Start-Process $ffmpeg -ArgumentList $ffArgs -PassThru -NoNewWindow -RedirectStandardError (Join-Path $outDir "$edition.ffmpeg.log")
      $ffStart = Get-Date
      Start-Sleep -Seconds $LeadSeconds
      $n = Count-Log '\[play\] finished'
      Send-Console @("play $Name")
      if (-not (Wait-Log '\[play\] playing' 0 20)) { throw 'replay did not start' }
      $playLine = Last-Log '\[play\] playing'
      if (-not (Wait-Log '\[play\] finished' $n ([int]$length + 60))) { throw 'replay did not finish' }
      $done = Last-Log '\[play\] finished'
      $ff.WaitForExit(([int]$total + 30) * 1000) | Out-Null
      # Where the replay starts in the clip, from the log's timestamp.
      $playAt = [datetime]::ParseExact(($playLine -replace '^\[([^\]]+)\].*', '$1'), 'yyyy-MM-dd HH:mm:ss.fff', $null)
      $drift = if ($done -match 'end ([\d.]+) m, largest ([\d.]+) m') { @{ end_m = [double]$Matches[1]; max_m = [double]$Matches[2] } } else { @{} }
      @{ edition = $edition; clip = $clip; lead_s = [math]::Round(($playAt - $ffStart).TotalSeconds, 3)
         length_s = $length; drift = $drift } | ConvertTo-Json | Set-Content (Join-Path $outDir "$edition.json") -Encoding utf8
      Copy-Item (Join-Path $script:Root "console\replays\$Name.played.txt") (Join-Path $outDir "$edition.played.txt") -Force
      "[$edition] $done"
    } finally {
      Close-Game
    }
  }
} finally {
  Restore-Build
}
"clips in $outDir"
