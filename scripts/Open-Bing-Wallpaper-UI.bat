@echo off
if exist "%~dp0..\AutoScape.exe" (
    start "" "%~dp0..\AutoScape.exe"
) else if exist "%~dp0..\BingWallpaper.exe" (
    start "" "%~dp0..\BingWallpaper.exe"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0..\Bing-Wallpaper-UI.ps1"
)
exit /b 0
