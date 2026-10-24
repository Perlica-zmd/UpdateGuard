@echo off
rem Trust the Update Guard certificate so Windows shows the publisher name.
rem Default: machine-wide, all users (a UAC prompt will appear once).
rem Usage  : trust-cert.bat          -> all users (recommended, fixes "Unknown publisher")
rem          trust-cert.bat user     -> current user only, no admin needed
setlocal
set ARG=
if /i "%~1"=="user" set ARG=-User
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0trust-cert.ps1" %ARG%
pause
