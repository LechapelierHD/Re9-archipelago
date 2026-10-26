@echo off
setlocal
set GAME_DIR=%~1
if "%GAME_DIR%"=="" (
  echo Usage: run_bridge.bat "D:\Steam\...\RESIDENT EVIL requiem BIOHAZARD requiem"
  exit /b 1
)
py -3 -m pip install -q -r "%~dp0requirements.txt"
py -3 "%~dp0ap_bridge.py" --game-dir "%GAME_DIR%"
endlocal
