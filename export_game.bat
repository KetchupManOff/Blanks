@echo off
rem One-click export: builds the open-files Windows x64 release with the
rem export time in the name, so the newest build is easy to spot.
setlocal
cd /d "%~dp0"

rem Timestamp like 2026-10-04_16-10-07: locale-independent, filename-safe.
for /f "delims=" %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH-mm-ss"') do set "TIMESTAMP=%%T"
set "NAME=BLANKS_%TIMESTAMP%"

echo.
echo ---- BLANKS export ----------------------------------------
echo Build name: %NAME%
echo ----------------------------------------------------------
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File ".\package_release.ps1" -Name "%NAME%"
if errorlevel 1 (
    echo.
    echo EXPORT FAILED - see the messages above.
) else (
    echo.
    echo Export finished.
    echo Folder: Exports\%NAME%
    echo Zip:    Exports\%NAME%.zip
)
echo.
pause
