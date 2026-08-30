@echo off
setlocal EnableExtensions EnableDelayedExpansion

title AutoScape Setup

:: ============================================================
:: ANSI & COLORS SETUP
:: ============================================================

for /f %%A in ('powershell.exe -NoProfile -Command "[char]27"') do set "ESC=%%A"
reg add "HKCU\Console" /v VirtualTerminalLevel /t REG_DWORD /d 1 /f >nul 2>&1

set "RESET=%ESC%[0m"
set "BOLD=%ESC%[1m"
set "DIM=%ESC%[2m"

set "YELLOW=%ESC%[38;2;252;227;115m"
set "WHITE=%ESC%[38;2;255;255;255m"
set "LIGHTBLUE=%ESC%[38;2;137;180;248m"
set "BLUE=%ESC%[38;2;44;117;211m"
set "DARKBLUE=%ESC%[38;2;8;76;194m"
set "RED=%ESC%[38;2;255;100;100m"

:: ============================================================
:: DRAW INITIAL SCREEN
:: ============================================================

cls
call :LOGO

echo.
echo %DARKBLUE%  ------------------------------------------------------------------------------------------%RESET%
echo.
echo %WHITE%%BOLD%                                          SETUP%RESET%
echo.
echo %LIGHTBLUE%  Installing AutoScape and creating your shortcuts...%RESET%
echo.

:: ============================================================
:: EXECUTION WITH CLEAN ERROR HANDLING
:: ============================================================

set "LOGFILE=%TEMP%\autoscape_setup.log"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1" > "%LOGFILE%" 2>&1
set "PS_EXIT=%ERRORLEVEL%"

if not "%PS_EXIT%"=="0" (
    cls
    call :LOGO
    echo.
    echo %DARKBLUE%  ------------------------------------------------------------------------------------------%RESET%
    echo.
    echo %RED%%BOLD%                                      INSTALLATION FAILED%RESET%
    echo.
    
    :: Check if the error was due to a locked file/running app
    findstr /i /c:"used by another process" "%LOGFILE%" >nul 2>&1
    if not errorlevel 1 (
        echo %WHITE%  AutoScape appears to be currently running or open in the background.%RESET%
        echo %YELLOW%  Please close AutoScape from the system tray or Task Manager and try again.%RESET%
    ) else (
        echo %WHITE%  An unexpected error occurred during installation.%RESET%
        echo %DIM%  Please check your system permissions or restart your PC and try again.%RESET%
    )
    
    echo.
    echo %DARKBLUE%  ------------------------------------------------------------------------------------------%RESET%
    echo.
    echo %DIM%  Press any key to close this window...%RESET%
    pause >nul
    exit /b 1
)

:: ============================================================
:: SUCCESS SCREEN
:: ============================================================

cls
call :LOGO

echo.
echo %DARKBLUE%  ------------------------------------------------------------------------------------------%RESET%
echo.
echo %YELLOW%%BOLD%                                      SETUP COMPLETE%RESET%
echo.
echo %WHITE%  AutoScape has been installed successfully.%RESET%
echo.
echo %LIGHTBLUE%  Shortcuts created:%RESET%
echo.
echo %YELLOW%  [OK]%RESET%  %WHITE%Desktop%RESET%
echo %YELLOW%  [OK]%RESET%  %WHITE%Start Menu%RESET%
echo.
echo %DIM%  You can launch AutoScape from either shortcut.%RESET%
echo.
echo %DARKBLUE%  ------------------------------------------------------------------------------------------%RESET%
echo.
echo %DIM%  Press any key to close.%RESET%

pause >nul
exit /b 0


:: ============================================================
:: AUTOSCAPE LOGO
:: ============================================================

:LOGO
echo.
echo %YELLOW%%BOLD%      ___      _     _   _______    _____     _____    _____     ___      _____   ______ %RESET%
echo %YELLOW%%BOLD%     / _ \    ^| ^|   ^| ^| ^|__   __^|  / ___ \   / ____^|  / ____^|   / _ \    ^|  __ \ ^|  ____^|%RESET%
echo %WHITE%%BOLD%    / / \ \   ^| ^|   ^| ^|    ^| ^|    ^| ^|   ^| ^| ^| (___   ^| ^|       / / \ \   ^| ^|__) ^|^| ^|__   %RESET%
echo %WHITE%%BOLD%   / /___\ \  ^| ^|   ^| ^|    ^| ^|    ^| ^|   ^| ^|  \___ \  ^| ^|      / /___\ \  ^|  ___/ ^|  __^|  %RESET%
echo %LIGHTBLUE%%BOLD%   ^|  ___  ^|  ^| ^|___^| ^|    ^| ^|    ^| ^|___^| ^|  ____) ^| ^| ^|____  ^|  ___  ^|  ^| ^|     ^| ^|____ %RESET%
echo %BLUE%%BOLD%   ^|_^|   ^|_^|   \_____/     ^|_^|     \_____/  ^|_____/   \_____^| ^|_^|   ^|_^|  ^|_^|     ^|______^|%RESET%
echo.
echo %ESC%[38;2;150;150;150m                                    Wallpaper, simplified.%RESET%
echo.
exit /b