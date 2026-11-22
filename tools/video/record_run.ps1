# Record a run for a comparison video: you play, the game records your input.
#
# Boots the Release build (Project Sparrow graphics by default), starts a New
# Game, jumps to the region, makes the hero an adult in the swashbuckler outfit
# and sets the hour. When "Recording" shows at the top of the screen, play.
# Press F10 in the game window to stop (or wait for -MaxSeconds). The game
# closes and the recording is saved as console\replays\<Name>.f2rec.
# Then run replay_run.ps1 -Name <Name> to film it in each edition.
#
# Keyboard and mouse or a controller both work. Exploring replays well;
# fights don't (enemies won't do the same thing twice).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\video\record_run.ps1 -Name lake1 [-Region BowerLake] [-Hour 15]
param(
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$Name,
  [string]$Region = 'BowerLake',
  [string]$Marker = '',
  [int]$Hour = 15,
  [ValidateSet('original', 'enhanced', 'sparrow')][string]$Edition = 'sparrow',
  [int]$MaxSeconds = 300,
  [int]$Width = 1920,
  [int]$Height = 1080
)
. "$PSScriptRoot\video_common.ps1"

Backup-Build
try {
  Start-Game $Edition $Width $Height
  Prepare-Start $Region $Marker $Hour
  Focus-Game
  $n = Count-Log '\[rec\] saved'
  Send-Console @("rec start $Name")
  "recording '$Name': play now, press F10 in the game window to stop"
  $deadline = (Get-Date).AddSeconds($MaxSeconds)
  while ((Count-Log '\[rec\] saved') -le $n) {
    if ($script:p.HasExited) { throw 'game exited before the recording was saved' }
    if ((Get-Date) -gt $deadline) { Send-Console @('rec stop'); Wait-Log '\[rec\] saved' $n 20 | Out-Null; break }
    Start-Sleep -Milliseconds 500
  }
  Last-Log '\[rec\] saved'
  Start-Sleep 3
  # Keep a copy of the start settings next to the recording, for the replay.
  $meta = @{ name = $Name; region = $Region; marker = $Marker; hour = $Hour; edition = $Edition
             width = $Width; height = $Height; recorded = (Get-Date -Format s) }
  $meta | ConvertTo-Json | Set-Content (Join-Path $script:Root "console\replays\$Name.json") -Encoding utf8
} finally {
  Close-Game
  Restore-Build
}
