# Benchmark after an SDK bump: runs bench.ps1 a few times on the current build and
# appends the result (SDK commit, game commit, FPS) to out\bench\sdk_results.jsonl,
# with the change against the previous entry. Skips an SDK commit already measured
# unless -Force. Build the Release first (build.cmd -release fable_2).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\bench\bench_sdk.ps1 [-Runs 2] [-Force]
#
# Prints one summary line at the end, e.g.
#   SDK 9026951 (game 04401f6): avg 163.2 FPS, 1% low 121.0 (2 runs); +1.4% vs SDK 6398334
param(
  [int]$Runs = 2,
  [switch]$Force,
  [string]$Repo = 'E:\Fable 2\Fable-2-Recomp'
)
$ErrorActionPreference = 'Stop'
if (Get-Process fable_2 -ErrorAction SilentlyContinue) { throw 'A game is already running; benchmarks need the PC to themselves.' }

$sdk = (git -C (Join-Path $Repo 'thirdparty\rexglue-sdk') rev-parse --short HEAD).Trim()
$game = (git -C $Repo rev-parse --short HEAD).Trim()
$outDir = Join-Path $Repo 'out\bench'
New-Item -ItemType Directory -Force $outDir | Out-Null
$results = Join-Path $outDir 'sdk_results.jsonl'
$history = @()
if (Test-Path $results) { $history = @(Get-Content $results | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
if (-not $Force -and ($history | Where-Object { $_.sdk -eq $sdk })) {
  "SDK $sdk was already benchmarked (use -Force to run it again)."
  return
}

$avgs = @(); $lows = @()
for ($i = 1; $i -le $Runs; $i++) {
  $line = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'bench.ps1') -Label "sdk-$sdk-$i" |
    Where-Object { $_ -match '\] avg ' } | Select-Object -Last 1
  if ($line -notmatch 'avg ([\d.,]+) FPS .* 1% low ([\d.,]+)') { throw "run $i gave no result: $line" }
  $avgs += [double]($Matches[1] -replace ',', '')
  $lows += [double]($Matches[2] -replace ',', '')
  "run ${i}: $line"
}
$avg = ($avgs | Measure-Object -Average).Average
$low = ($lows | Measure-Object -Average).Average
$entry = [ordered]@{
  date = (Get-Date).ToString('s'); sdk = $sdk; game = $game; runs = $Runs
  avg = [math]::Round($avg, 1); low1 = [math]::Round($low, 1)
}
($entry | ConvertTo-Json -Compress) | Add-Content $results -Encoding utf8

$prev = $history | Where-Object { $_.sdk -ne $sdk } | Select-Object -Last 1
$change = if ($prev) { '; {0:+0.0;-0.0}% vs SDK {1}' -f ((($avg / $prev.avg) - 1) * 100), $prev.sdk } else { '; first entry' }
'SDK {0} (game {1}): avg {2:N1} FPS, 1% low {3:N1} ({4} runs){5}' -f $sdk, $game, $avg, $low, $Runs, $change
