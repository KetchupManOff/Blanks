@echo off
rem Convert background videos into OGV (Ogg Theora) that plays correctly
rem in the game. Drag and drop one or more videos onto this file, or run:
rem   convert_to_ogv.bat "video1.mp4" "video2.mp4"
rem Each output lands next to its source as <name>.ogv.
setlocal

rem FFmpeg 8.x-era libtheora encoders emit a bitstream Godot 4.7's built-in
rem Theora decoder misreads (corrupted frames in-game). Use a 4.x-era build
rem (libtheora 1.1.1); the one bundled with Soundux is verified working.
rem NOTE: keep this path outside parenthesized blocks - the (x86) breaks them.
set "COMPAT_FFMPEG=C:\Program Files (x86)\Soundux\ffmpeg.exe"

rem Background decode cost settings: 720p30 keeps CPU usage low; the game
rem draws the video behind tint/opacity, so higher resolution is not visible.
set "WIDTH=1280"
set "HEIGHT=720"
set "FPS=30"
set "VIDEO_QUALITY=6"
set "AUDIO_QUALITY=4"

set "FF="
set "FFVER="
set "OK=0"
set "FAIL=0"

if not exist "%COMPAT_FFMPEG%" goto :try_path
set "FF=%COMPAT_FFMPEG%"
goto :encoder_ready

:try_path
where ffmpeg >nul 2>nul
if errorlevel 1 goto :no_ffmpeg
set "FF=ffmpeg"

rem Version gate for the PATH ffmpeg: refuse 8.x+ builds unless overridden.
for /f "tokens=2 delims= " %%v in ('ffmpeg -version 2^>^&1 ^| findstr /i /c:"ffmpeg version"') do set "FFVER=%%v"
set "MAJOR="
if defined FFVER for /f "delims=." %%m in ("%FFVER%") do set "MAJOR=%%m"
if not defined MAJOR goto :version_unknown
echo %MAJOR%| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 goto :version_unknown
if %MAJOR% GEQ 8 goto :version_bad
goto :encoder_ready

:version_bad
echo.
echo WARNING: ffmpeg %FFVER% is an 8.x+ build. Its libtheora encoder produces
echo files Godot 4.7 decodes with corrupted frames. Install a 4.x-7.x build
echo ^(e.g. gyan "4.3.2 essentials"^) or point COMPAT_FFMPEG at one.
echo.
choice /c YN /n /d N /t 15 /m "Continue with this build anyway? [Y/N] "
if errorlevel 2 (
    echo Aborted.
    goto :end_pause
)
goto :encoder_ready

:version_unknown
echo.
echo WARNING: could not determine the PATH ffmpeg version. 8.x+ builds
echo produce files that glitch in-game; 4.x-7.x builds are safe.
echo.
choice /c YN /n /d Y /t 15 /m "Continue with this build? [Y/N] "
if errorlevel 2 (
    echo Aborted.
    goto :end_pause
)

:encoder_ready
if "%FF%"=="ffmpeg" goto :show_path_encoder
echo Using encoder: "%FF%"
goto :encoder_shown
:show_path_encoder
echo Using encoder: ffmpeg %FFVER% from PATH
:encoder_shown
if "%~1"=="" goto :usage
echo.

:next_arg
if "%~1"=="" goto :summary
call :convert "%~1"
shift
goto :next_arg

:usage
echo Usage: drag videos onto this file, or run:
echo   convert_to_ogv.bat "video1.mp4" "video2.mp4"
echo Output: same folder and name as each source, with a .ogv extension.
goto :end_pause

:no_ffmpeg
echo ERROR: no usable ffmpeg found.
echo Expected a 4.x-era build at: %COMPAT_FFMPEG%
echo or ffmpeg on PATH ^(version gate: must not be an 8.x+ build^).
goto :end_pause

:summary
echo.
echo Done. Converted: %OK%   Failed: %FAIL%
goto :end_pause

:convert
set "SRC=%~1"
set "OUT=%~dpn1.ogv"
echo ----
echo Converting: "%SRC%"
echo      into: "%OUT%"
rem Keep the first audio stream: Godot's Theora playback is driven by the
rem audio clock, so the track must exist even though the game plays it muted.
"%FF%" -hide_banner -y -i "%SRC%" -map 0:v:0 -map 0:a:0 ^
    -vf "scale=%WIDTH%:%HEIGHT%:flags=lanczos,fps=%FPS%" ^
    -c:v libtheora -q:v %VIDEO_QUALITY% -pix_fmt yuv420p ^
    -c:a libvorbis -q:a %AUDIO_QUALITY% -dn -sn "%OUT%"
if errorlevel 1 goto :convert_noaudio
goto :verify

:convert_noaudio
rem Retry with a generated silence track when the source has no audio.
echo Source has no usable audio - retrying with a silent Vorbis track.
"%FF%" -hide_banner -y -i "%SRC%" -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=48000" ^
    -map 0:v:0 -map 1:a:0 -shortest ^
    -vf "scale=%WIDTH%:%HEIGHT%:flags=lanczos,fps=%FPS%" ^
    -c:v libtheora -q:v %VIDEO_QUALITY% -pix_fmt yuv420p ^
    -c:a libvorbis -q:a %AUDIO_QUALITY% -dn -sn "%OUT%"
if errorlevel 1 goto :convert_failed
goto :verify

:convert_failed
echo FAILED: conversion of "%SRC%" did not complete.
set /a FAIL+=1
goto :eof

:verify
rem The theme loader accepts a video only if the file starts with the OggS
rem signature; confirm the container is valid before calling it done.
set "MAGIC="
for /f "usebackq delims=" %%m in (`powershell -NoProfile -Command "[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes('%OUT%')[0..3])"`) do set "MAGIC=%%m"
if /i not "%MAGIC%"=="OggS" goto :verify_failed
for %%z in ("%OUT%") do echo OK: %%~nz%%~xz ^(%%~zz bytes^)
set /a OK+=1
goto :eof

:verify_failed
echo FAILED: "%OUT%" is not a valid Ogg container.
set /a FAIL+=1
goto :eof

:end_pause
echo.
pause
