@echo off
rem ---------------------------------------------------------------------------
rem  Update Guard - launcher
rem
rem  Double-click this file instead of the .ps1.
rem
rem  Windows refuses to run a downloaded PowerShell script that is not digitally
rem  signed (the file carries the "came from the internet" mark after you unzip
rem  it). Passing -ExecutionPolicy Bypass only affects this one process, so no
rem  system-wide setting is changed and nothing needs to be unblocked.
rem ---------------------------------------------------------------------------

setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Disable-WindowsUpdate.ps1" %*

if errorlevel 1 (
    echo.
    echo The script exited with an error. Press any key to close this window.
    pause >nul
)
