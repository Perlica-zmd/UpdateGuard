@echo off
rem ---------------------------------------------------------------------------
rem  Win11 Toolbox  -  Win11 工具集
rem
rem  Master launcher for both scripts. Put this file, Disable-WindowsUpdate.ps1
rem  and DefenderTune.ps1 in the SAME folder, then double-click this file.
rem
rem  It exists because Windows refuses to run a downloaded .ps1 that is not
rem  digitally signed. -ExecutionPolicy Bypass below affects this one process
rem  only, so nothing system-wide is changed.
rem ---------------------------------------------------------------------------

chcp 65001 >nul
setlocal
cd /d "%~dp0"

:menu
cls
echo.
echo  ==================================================
echo    Win11 Toolbox  -  Win11 工具集
echo  ==================================================
echo    1)  Windows Update control   /  更新控制
echo    2)  Defender tuning          /  Defender 性能调节
echo    0)  Exit                     /  退出
echo.

set "choice="
set /p "choice=  Select an option / 请选择: "

if "%choice%"=="1" goto update
if "%choice%"=="2" goto defender
if "%choice%"=="0" goto done
goto menu

:update
if not exist "%~dp0Disable-WindowsUpdate.ps1" (
    echo.
    echo   [x] Disable-WindowsUpdate.ps1 not found.
    echo   [x] 未找到 Disable-WindowsUpdate.ps1，请把它放到本文件夹。
    echo.
    pause
    goto menu
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Disable-WindowsUpdate.ps1"
goto menu

:defender
if not exist "%~dp0DefenderTune.ps1" (
    echo.
    echo   [x] DefenderTune.ps1 not found.
    echo   [x] 未找到 DefenderTune.ps1，请把它放到本文件夹。
    echo.
    pause
    goto menu
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DefenderTune.ps1"
goto menu

:done
endlocal
exit /b 0
