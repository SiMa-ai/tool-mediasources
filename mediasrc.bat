:: Always relaunch this script under PowerShell (pwsh if present), once.
if not defined __PS_WRAPPED (
  set "__PS_WRAPPED=1"
  rem Prefer PowerShell 7 (pwsh); fallback to Windows PowerShell
  where pwsh >nul 2>&1 && (
    pwsh -NoProfile -ExecutionPolicy Bypass -Command "$env:__PS_WRAPPED='1'; & cmd /c '\"%~f0\" %*'"
  ) || (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:__PS_WRAPPED='1'; & cmd /c '\"%~f0\" %*'"
  )
  exit /b %ERRORLEVEL%
)

@echo off
setlocal enabledelayedexpansion

:: ---------------------------------------
:: Configuration
:: ---------------------------------------
set "MEDIA_DIR=%~1"
set "TOOLS_DIR=%~dp0tools"
set "FFMPEG_PATH=%TOOLS_DIR%\ffmpeg\bin"
set "MEDIAMTX_PATH=%TOOLS_DIR%\mediamtx"

:: Validate input directory
if "%MEDIA_DIR%"=="" (
    echo Usage: %~nx0 ^<media-folder^>
    exit /b 1
)

:: Normalize MEDIA_DIR to absolute path and ensure it exists
for %%F in ("%MEDIA_DIR%") do set "MEDIA_DIR=%%~fF"
if not exist "%MEDIA_DIR%\" (
    echo Error: "%MEDIA_DIR%" is not a valid directory.
    exit /b 1
)

:: Ensure tools directory exists
if not exist "%TOOLS_DIR%" (
    mkdir "%TOOLS_DIR%" >nul 2>&1
)

:: Temporarily add tools to PATH
set "PATH=%FFMPEG_PATH%;%MEDIAMTX_PATH%;%PATH%"

:: ---------------------------------------
:: ffmpeg install (Windows static build)
:: ---------------------------------------
echo Checking for ffmpeg...
where ffmpeg >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ffmpeg not found. Installing...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$zip = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip';" ^
        "$out = '%TOOLS_DIR%\ffmpeg.zip';" ^
        "Invoke-WebRequest $zip -OutFile $out;" ^
        "Expand-Archive $out -DestinationPath '%TOOLS_DIR%';" ^
        "$dir = Get-ChildItem '%TOOLS_DIR%' -Directory | Where-Object { $_.Name -like 'ffmpeg-*' } | Select-Object -First 1;" ^
        "Move-Item $dir.FullName '%FFMPEG_PATH%\..' -Force;" ^
        "Remove-Item $out;" ^
        "Write-Host '✅ ffmpeg installed to %FFMPEG_PATH%'"
    if not exist "%FFMPEG_PATH%\ffmpeg.exe" (
        echo Error: ffmpeg installation failed.
        exit /b 1
    )
)

:: ---------------------------------------
:: MediaMTX install
:: ---------------------------------------
set "VERSION=1.14.0"
set "MTX_URL=https://github.com/bluenviron/mediamtx/releases/download/v%VERSION%/mediamtx_v%VERSION%_windows_amd64.zip"

echo Checking for MediaMTX...
where mediamtx >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo MediaMTX not found. Installing...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$url = '%MTX_URL%';" ^
        "$out = '%TOOLS_DIR%\mediamtx.zip';" ^
        "Invoke-WebRequest -Uri $url -OutFile $out;" ^
        "Expand-Archive -Path $out -DestinationPath '%MEDIAMTX_PATH%';" ^
        "Remove-Item $out;" ^
        "Write-Host 'MediaMTX installed to %MEDIAMTX_PATH%'"
    if not exist "%MEDIAMTX_PATH%\mediamtx.exe" (
        echo Error: MediaMTX installation failed.
        exit /b 1
    )
)

:: ---------------------------------------
:: Start MediaMTX
:: ---------------------------------------
echo Checking if MediaMTX is running...
tasklist /FI "IMAGENAME eq mediamtx.exe" 2>nul | find /I "mediamtx.exe" >nul
if %ERRORLEVEL% NEQ 0 (
    echo Starting MediaMTX server...
    start /B /HIGH mediamtx mediamtx.yml > "%TEMP%\mediamtx.log" 2>&1
)

:: ---------------------------------------
:: Get non-loopback IP
:: ---------------------------------------
echo Retrieving IP address...
set "LOCAL_IP="
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /C:"IPv4 Address"') do (
    set "LOCAL_IP=%%A"
    set "LOCAL_IP=!LOCAL_IP:~1!"
    goto :ip_found
)
:ip_found
if "!LOCAL_IP!"=="" (
    set "LOCAL_IP=127.0.0.1"
)

echo MediaMTX running on rtsp://!LOCAL_IP!:8554/

:: ---------------------------------------
:: Scan and stream video files
:: ---------------------------------------
echo Scanning media directory for video files...
set "INDEX=0"
for /f "delims=" %%F in ('dir /b /a-d /on "%MEDIA_DIR%\*.mp4"') do (
    set /A INDEX+=1
    call :launch_stream !INDEX! "%%F"
)

if !INDEX! EQU 0 (
    echo Error: No .mp4 files found in "%MEDIA_DIR%".
    exit /b 1
)

goto :after_streams

:launch_stream
set "INDEX=%1"
set "FILE=%2"
set /A SRC=%INDEX% - 1
set "INPUT=%MEDIA_DIR%\%FILE%"

:: Verify file existence
if not exist "!INPUT!" (
    echo Error: File !INPUT! does not exist.
    goto :eof
)

set "URL=rtsp://!LOCAL_IP!:8554/src!SRC!"
echo Streaming !INPUT! : !URL!

:: Debug: Verify ffmpeg path
where ffmpeg >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo Error: ffmpeg not found in PATH.
    goto :eof
)

:: Run ffmpeg command
start "Stream !SRC!" /MIN ffmpeg -re -stream_loop -1 -i "!INPUT!" -c:v copy -an -f rtsp "!URL!" > "%TEMP%\ffmpeg_src!SRC!.log" 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo Error: ffmpeg failed to start for stream !SRC!. Check %TEMP%\ffmpeg_src!SRC!.log
)

goto :eof

:after_streams
echo All available streams launched.
echo Example: ffplay rtsp://!LOCAL_IP!:8554/src1

pause

:: Stop MediaMTX process
echo Stopping MediaMTX...
taskkill /F /IM mediamtx.exe >nul 2>&1

echo MediaMTX stopped.
endlocal
exit /b 0