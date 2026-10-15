@echo off
rem One-click online dev export: builds the open-files Windows x64
rem debug package with the export time in the name, for friend testing
rem against a relay. The relay URL is supplied at the prompt and lands
rem only in the generated Start Online Dev.bat inside the package.
setlocal
cd /d "%~dp0"

rem Timestamp like 2026-10-04_16-10-07: locale-independent, filename-safe.
for /f "delims=" %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH-mm-ss"') do set "TIMESTAMP=%%T"
set "NAME=TetrisYankEdition_OnlineDev_%TIMESTAMP%"

echo.
echo ---- Tetris Yank Edition online dev export ---------------
echo Build name: %NAME%
echo Debug build: this package may use plain ws:// relays.
echo ---------------------------------------------------------
echo.

set "RELAY_URL="
set /p "RELAY_URL=Relay URL (ws://host:port): "
if not defined RELAY_URL (
    echo.
    echo No relay URL entered - nothing was exported.
    echo Run this script again and paste the relay URL.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File ".\package_release.ps1" -OnlineDev -RelayUrl "%RELAY_URL%" -Name "%NAME%"
if errorlevel 1 (
    echo.
    echo EXPORT FAILED - see the messages above.
) else (
    echo.
    echo Export finished.
    echo Folder: Exports\%NAME%
    echo Zip:    Exports\%NAME%.zip
    echo Share the zip; recipients extract it anywhere and run
    echo Start Online Dev.bat - not the .exe directly.
)
echo.
pause