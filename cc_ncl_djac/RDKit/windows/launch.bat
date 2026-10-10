@echo off
setlocal
if not exist "%~dp0SessionControl.exe" (
    echo SessionControl.exe is missing. Extract the complete updated toolkit first.
    pause
    exit /b 1
)
start "" "%~dp0SessionControl.exe" start
