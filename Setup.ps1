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
$nativeDllPath = Join-Path $rootFolder 'AutoScapeNative.dll'

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

# powershell.exe is Microsoft-signed and trusted. -WindowStyle Hidden suppresses
# the console window, so no VBScript wrapper is needed (VBScript is being
# deprecated/disabled by default on newer Windows builds).
$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psArgString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uiPath`""

if (Test-Path $desktopPath) {
    Create-Shortcut -targetPath $powershellExe -outLnkPath $desktopShortcutPath -iconLocation $icoPath -workingDir $rootFolder -argString $psArgString
    Write-Output "    Created Desktop shortcut: $desktopShortcutPath"
}

$startMenuPrograms = [Environment]::GetFolderPath('Programs')
if ($startMenuPrograms -and (Test-Path $startMenuPrograms)) {
    $oldStartMenuLnk = Join-Path $startMenuPrograms 'Bing Wallpaper.lnk'
    if (Test-Path $oldStartMenuLnk) { Remove-Item $oldStartMenuLnk -Force -ErrorAction SilentlyContinue }

    $startMenuShortcutPath = Join-Path $startMenuPrograms 'AutoScape.lnk'
    Create-Shortcut -targetPath $powershellExe -outLnkPath $startMenuShortcutPath -iconLocation $icoPath -workingDir $rootFolder -argString $psArgString
    Write-Output "    Created Start Menu shortcut: $startMenuShortcutPath"
}

Write-Output ""
Write-Output "========================================================="
Write-Output " Setup Complete! (No compiled exe, no VBScript - launches via powershell.exe directly)"
Write-Output "========================================================="