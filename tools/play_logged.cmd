@echo off
rem ===========================================================================
rem Play Fable 2 with performance logging, for analysing hitches afterwards.
rem
rem   - FABLE2_FPS_METER=1 writes one line per frame to fps_meter.log.
rem   - --d3d12_log_pipeline_timing=true logs every shader translation,
rem     pipeline build and draw wait of 1 ms or more to the game log (logs\).
rem
rem fps_meter.log is recreated on every launch, so when the game closes this
rem moves it to play_logs\fps_meter_<date-time>.log next to the game log.
rem ===========================================================================
setlocal
for %%i in ("%~dp0..") do set "ROOT=%%~fi"
set "BUILD=%ROOT%\out\build\win-amd64-release"
if not exist "%BUILD%\fable_2.exe" (
  echo fable_2.exe not found in "%BUILD%". Build the release first.
  pause
  exit /b 1
)
cd /d "%BUILD%"
if not exist play_logs mkdir play_logs

set FABLE2_FPS_METER=1
rem "start /wait" opens the game as a normal window even though this script's
rem window is minimized by the desktop shortcut (a minimized start makes the
rem game exit), and waits for it so the log can be moved afterwards.
start "" /wait fable_2.exe --game_data_root="%ROOT%" --d3d12_log_pipeline_timing=true

for /f %%t in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%t"
if exist fps_meter.log move /y fps_meter.log "play_logs\fps_meter_%STAMP%.log" >nul
