<#
.SYNOPSIS
    Compiles the zero-console standalone Windows GUI launcher (BingWallpaper.exe)
    and generates the Desktop application shortcut.
#>

$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

# Root repository folder
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
$exePath = Join-Path $rootFolder 'AutoScape.exe'
$desktopPath = [Environment]::GetFolderPath('Desktop')
$desktopShortcutPath = Join-Path $desktopPath 'AutoScape.lnk'
$uiPath = Join-Path $rootFolder 'Bing-Wallpaper-UI.ps1'

Add-Type -AssemblyName System.Drawing

# Auto-sync version with Git commit count if in a git repository
try {
    $commitCount = (git rev-list --count HEAD 2>$null)
    if ($commitCount -and ($commitCount.Trim() -match '^\d+$')) {
        $autoVer = "1.0.$($commitCount.Trim())"
        $uiRaw = Get-Content -LiteralPath $uiPath -Raw
        if ($uiRaw -match '\$script:appVersion\s*=\s*\[Version\][''"][^''"]+[''"]') {
            $updatedRaw = $uiRaw -replace '\$script:appVersion\s*=\s*\[Version\][''"][^''"]+[''"]', "`$script:appVersion = [Version]'$autoVer'"
            Set-Content -LiteralPath $uiPath -Value $updatedRaw -Encoding UTF8
            Write-Output "--> Synced App Version: $autoVer (commit #$($commitCount.Trim()))"
        }
    }
} catch {}

# 1. Compile standalone Windows GUI executable (AutoScape.exe) with embedded icon
Write-Output "--> Compiling AutoScape.exe (zero-console launcher)..."
$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

$hasExe = $false
if ($csc) {
    $csSource = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

namespace AutoScapeLauncher
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            string appDir = AppDomain.CurrentDomain.BaseDirectory;
            string tempDir = Path.Combine(Path.GetTempPath(), "AutoScape");
            string psScript = Path.Combine(tempDir, "Bing-Wallpaper-UI.ps1");
            string iconPath = Path.Combine(tempDir, "assets", "app.ico");

            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(iconPath));
                
                using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("AutoScapeLauncher.Bing-Wallpaper-UI.ps1"))
                {
                    if (source != null)
                    {
                        bool needsExtract = !File.Exists(psScript) || new FileInfo(psScript).Length != source.Length;
                        if (needsExtract)
                        {
                            using (FileStream destination = File.Create(psScript))
                            {
                                source.CopyTo(destination);
                            }
                        }
                    }
                }

                using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("AutoScapeLauncher.app.ico"))
                {
                    if (source != null && !File.Exists(iconPath))
                    {
                        using (FileStream destination = File.Create(iconPath))
                        {
                            source.CopyTo(destination);
                        }
                    }
                }
            }
            catch {}

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            psi.Arguments = string.Format("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{0}\"", psScript);
            psi.WorkingDirectory = appDir;
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            psi.WindowStyle = ProcessWindowStyle.Hidden;

            Process.Start(psi);
        }
    }
}
"@
    $csTemp = Join-Path $rootFolder 'AppLauncher_temp.cs'
    Set-Content -Path $csTemp -Value $csSource -Encoding UTF8

    $compileArgs = @(
        "/target:winexe",
        "/optimize+",
        "/platform:anycpu",
        "/win32icon:`"$icoPath`"",
        "/resource:`"$uiPath`",AutoScapeLauncher.Bing-Wallpaper-UI.ps1",
        "/resource:`"$icoPath`",AutoScapeLauncher.app.ico",
        "/out:`"$exePath`"",
        "`"$csTemp`""
    )

    $proc = Start-Process -FilePath $csc -ArgumentList $compileArgs -NoNewWindow -Wait -PassThru
    Remove-Item -Path $csTemp -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -eq 0 -and (Test-Path $exePath)) {
        $hasExe = $true
        # Clean up legacy executable and checksum if present
        $legacyExe = Join-Path $rootFolder 'BingWallpaper.exe'
        $legacySha = Join-Path $rootFolder 'BingWallpaper.exe.sha256'
        if (Test-Path $legacyExe) { Remove-Item $legacyExe -Force -ErrorAction SilentlyContinue }
        if (Test-Path $legacySha) { Remove-Item $legacySha -Force -ErrorAction SilentlyContinue }

        $checksumPath = Join-Path $rootFolder 'AutoScape.exe.sha256'
        $checksum = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath $checksumPath -Value "$checksum  AutoScape.exe" -Encoding ASCII
        Write-Output "    Created $exePath (with embedded authentic icon)"
        Write-Output "    Created $checksumPath"
    }
}

# 2. Create Desktop & Start Menu Shortcuts
Write-Output "--> Creating Desktop & Start Menu shortcuts..."
$wsh = New-Object -ComObject WScript.Shell

function Create-Shortcut($targetPath, $outLnkPath, $iconLocation, $args = '') {
    $sc = $wsh.CreateShortcut($outLnkPath)
    $sc.TargetPath = $targetPath
    if ($args) { $sc.Arguments = $args }
    $sc.WorkingDirectory = $rootFolder
    $sc.IconLocation = "$iconLocation,0"
    $sc.Description = 'AutoScape - Bing wallpapers, delivered daily'
    $sc.Save()
}

$targetExe = if ($hasExe) { $exePath } else { "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
$targetArgs = if ($hasExe) { "" } else { "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uiPath`"" }

# Clean up legacy shortcut name if present
$oldDesktopLnk = Join-Path $desktopPath 'Bing Wallpaper.lnk'
if (Test-Path $oldDesktopLnk) { Remove-Item $oldDesktopLnk -Force -ErrorAction SilentlyContinue }

if (Test-Path $desktopPath) {
    Create-Shortcut -targetPath $targetExe -outLnkPath $desktopShortcutPath -iconLocation $icoPath -args $targetArgs
    Write-Output "    Created Desktop shortcut: $desktopShortcutPath"
}

$startMenuPrograms = [Environment]::GetFolderPath('Programs')
if ($startMenuPrograms -and (Test-Path $startMenuPrograms)) {
    $oldStartMenuLnk = Join-Path $startMenuPrograms 'Bing Wallpaper.lnk'
    if (Test-Path $oldStartMenuLnk) { Remove-Item $oldStartMenuLnk -Force -ErrorAction SilentlyContinue }

    $startMenuShortcutPath = Join-Path $startMenuPrograms 'AutoScape.lnk'
    Create-Shortcut -targetPath $targetExe -outLnkPath $startMenuShortcutPath -iconLocation $icoPath -args $targetArgs
    Write-Output "    Created Start Menu shortcut: $startMenuShortcutPath"
}

Write-Output ""
Write-Output "========================================================="
Write-Output " Setup Complete!"
Write-Output " You can launch the app directly from:"
Write-Output "   1. Desktop shortcut:    'AutoScape'"
Write-Output "   2. Start Menu shortcut: 'AutoScape'"
Write-Output "   3. Project root:        'AutoScape.exe'"
Write-Output "========================================================="
