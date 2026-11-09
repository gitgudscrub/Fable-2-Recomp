# Alternate benchmark runs between two configurations (or run just one with -Only).
param([int]$Runs = 3, [string]$ArgsA = '', [string]$ArgsB = '--d3d12_threaded_command_recording=true',
      [string]$NameA = 'off', [string]$NameB = 'on', [string]$Only = '')
$s = $PSScriptRoot
$configs = @(@($NameA, $ArgsA), @($NameB, $ArgsB))
if ($Only) { $configs = @($configs | Where-Object { $_[0] -eq $Only }) }
for ($i = 1; $i -le $Runs; $i++) {
  foreach ($cfg in $configs) {
    $benchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$s\bench.ps1", '-Label', "$($cfg[0])$i")
    # An empty -ExtraArgs value makes PowerShell reject the call, so only pass it when set.
    if ($cfg[1]) { $benchArgs += @('-ExtraArgs', $cfg[1]) }
    $out = & powershell @benchArgs 2>&1
    $lines = $out | Where-Object { "$_" -match '^\[' }
    if ($lines) { $lines } else { "[$($cfg[0])$i] failed: " + (($out | Select-Object -Last 3) -join ' | ') }
  }
}
