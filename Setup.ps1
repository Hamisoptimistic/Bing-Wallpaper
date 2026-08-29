<#
.SYNOPSIS
    Creates Desktop & Start Menu shortcuts for AutoScape WITHOUT compiling a
    custom .exe host. This avoids Smart App Control / SmartScreen blocking
    unsigned unknown binaries, because the process actually launched is
    powershell.exe, which is Microsoft-signed and trusted.
#>

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$rootFolder = if (Test-Path (Join-Path $scriptDir 'Bing-Wallpaper-UI.ps1')) {
    $scriptDir
} else {
    Split-Path -Parent $scriptDir
}

$assetsFolder = Join-Path $rootFolder 'assets'
$icoCandidates = @(
    (Join-Path $assetsFolder 'app.ico'),
    (Join-Path $assetsFolder 'bing.ico')
)
$icoPath = $icoCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $icoPath) {
    $genScript = Join-Path $scriptDir 'Generate-App-Icon.ps1'
    if (Test-Path $genScript) {
        & $genScript
        $icoPath = Join-Path $assetsFolder 'app.ico'
    }
}

$uiPath = Join-Path $rootFolder 'Bing-Wallpaper-UI.ps1'

if (-not (Test-Path -LiteralPath $uiPath)) { throw "Bing-Wallpaper-UI.ps1 not found at $uiPath" }

$desktopPath = [Environment]::GetFolderPath('Desktop')
$desktopShortcutPath = Join-Path $desktopPath 'AutoScape.lnk'

$wsh = New-Object -ComObject WScript.Shell

function Create-Shortcut($targetPath, $outLnkPath, $iconLocation, $workingDir, $argString = '') {
    $sc = $wsh.CreateShortcut($outLnkPath)
    $sc.TargetPath = $targetPath
    if ($argString) { $sc.Arguments = $argString }
    $sc.WorkingDirectory = $workingDir
    if ($iconLocation) { $sc.IconLocation = "$iconLocation,0" }
    $sc.Description = 'AutoScape - Bing wallpapers, delivered daily'
    $sc.Save()
}

# Clean up old shortcuts if present
$oldDesktopLnk = Join-Path $desktopPath 'Bing Wallpaper.lnk'
if (Test-Path $oldDesktopLnk) { Remove-Item $oldDesktopLnk -Force -ErrorAction SilentlyContinue }

# Launch through Windows Console Host in headless mode.
# On Windows 11, Windows Terminal may be configured as the default terminal
# application. Launching powershell.exe directly can therefore create a
# visible Windows Terminal window even when -WindowStyle Hidden is supplied.
#
# conhost.exe is a Microsoft-signed Windows component. --headless gives
# PowerShell a console host without creating a visible console window.
$conhostExe = Join-Path $env:WINDIR 'System32\conhost.exe'
if (-not (Test-Path -LiteralPath $conhostExe)) {
    throw "Windows Console Host was not found at $conhostExe"
}

$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psArgString = "--headless `"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -File `"$uiPath`""

if (Test-Path $desktopPath) {
    Create-Shortcut -targetPath $conhostExe -outLnkPath $desktopShortcutPath -iconLocation $icoPath -workingDir $rootFolder -argString $psArgString
    Write-Host "    [OK] Desktop shortcut created" -ForegroundColor Green
}

$startMenuPrograms = [Environment]::GetFolderPath('Programs')
if ($startMenuPrograms -and (Test-Path $startMenuPrograms)) {
    $oldStartMenuLnk = Join-Path $startMenuPrograms 'Bing Wallpaper.lnk'
    if (Test-Path $oldStartMenuLnk) { Remove-Item $oldStartMenuLnk -Force -ErrorAction SilentlyContinue }

    $startMenuShortcutPath = Join-Path $startMenuPrograms 'AutoScape.lnk'
    Create-Shortcut -targetPath $conhostExe -outLnkPath $startMenuShortcutPath -iconLocation $icoPath -workingDir $rootFolder -argString $psArgString
    Write-Host "    [OK] Start Menu shortcut created" -ForegroundColor Green
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkCyan
Write-Host " AutoScape installation complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor DarkCyan
Write-Host ""
Write-Host " AutoScape is installed and ready to use." -ForegroundColor White
Write-Host " Desktop and Start Menu shortcuts have been created." -ForegroundColor White
Write-Host ""
Write-Host " Launch AutoScape from either shortcut." -ForegroundColor Gray
Write-Host ""