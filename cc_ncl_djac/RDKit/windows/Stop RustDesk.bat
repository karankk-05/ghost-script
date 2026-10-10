@echo off
setlocal
if not exist "%~dp0SessionControl.exe" (
    echo SessionControl.exe is missing. Keep the extracted toolkit until you have stopped RustDesk.
    pause
    exit /b 1
)
start "" "%~dp0SessionControl.exe" stop
