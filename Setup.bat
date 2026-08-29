@echo off
REM Setup.bat - one-time installer for AutoScape shortcuts.
REM Double-click this file directly; no "Run with PowerShell" context
REM menu entry needed (some newer Windows builds have removed it).

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1"

echo.
echo Setup complete. Press any key to close this window.
pause >nul