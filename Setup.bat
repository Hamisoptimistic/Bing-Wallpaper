@echo off
setlocal
title AutoScape Setup

echo.
echo  ============================================================
echo                       AUTOSCAPE SETUP
echo  ============================================================
echo.
echo  Installing AutoScape and creating your shortcuts...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1"

if errorlevel 1 (
    echo.
    echo  [X] Installation could not be completed.
    echo.
    echo  Please review the message above and try again.
    echo.
    echo  Press any key to close this window...
    pause >nul
    exit /b 1
)

echo.
echo  ------------------------------------------------------------
echo  Installation complete.
echo  ------------------------------------------------------------
echo.
echo  AutoScape is now installed and ready to use.
echo.
echo  Shortcuts created:
echo    * Desktop
echo    * Start Menu
echo.
echo  You can launch AutoScape from either shortcut.
echo.
echo  Press any key to close this window...
pause >nul
exit /b 0
