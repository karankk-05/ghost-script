@echo off
setlocal
if not exist "%~dp0windows\SessionControl.exe" (
    echo SessionControl.exe is missing. Extract the complete updated RDKit.zip first.
    pause
    exit /b 1
)
start "" "%~dp0windows\SessionControl.exe" start
