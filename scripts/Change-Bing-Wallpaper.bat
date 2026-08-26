@echo off
setlocal
cd /d "%~dp0.."

echo Updating desktop wallpaper from Bing...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Bing-Wallpaper-UI.ps1" -AutoApply

if errorlevel 1 (
    echo.
    echo Wallpaper update failed. Check the message above.
) else (
    echo.
    echo Wallpaper updated successfully.
)

pause
endlocal
