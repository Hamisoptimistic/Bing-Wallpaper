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
$icoPath = Join-Path $assetsFolder 'bing.ico'
$exePath = Join-Path $rootFolder 'BingWallpaper.exe'
$desktopPath = [Environment]::GetFolderPath('Desktop')
$desktopShortcutPath = Join-Path $desktopPath 'Bing Wallpaper.lnk'
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

# 1. Compile standalone Windows GUI executable (BingWallpaper.exe) with embedded icon
Write-Output "--> Compiling BingWallpaper.exe (zero-console launcher)..."
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

namespace BingWallpaperLauncher
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            string appDir = AppDomain.CurrentDomain.BaseDirectory;
            string tempDir = Path.Combine(Path.GetTempPath(), "BingWallpaper");
            string psScript = Path.Combine(tempDir, "Bing-Wallpaper-UI.ps1");
            string iconPath = Path.Combine(tempDir, "assets", "bing.ico");

            for (int attempt = 0; attempt < 20; attempt++)
            {
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(iconPath));
                    using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("BingWallpaperLauncher.Bing-Wallpaper-UI.ps1"))
                    using (FileStream destination = new FileStream(psScript, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        source.CopyTo(destination);
                    }
                    using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("BingWallpaperLauncher.bing.ico"))
                    using (FileStream destination = new FileStream(iconPath, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        source.CopyTo(destination);
                    }
                    break;
                }
                catch
                {
                    System.Threading.Thread.Sleep(250);
                }
            }

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
        "/resource:`"$uiPath`",BingWallpaperLauncher.Bing-Wallpaper-UI.ps1",
        "/resource:`"$icoPath`",BingWallpaperLauncher.bing.ico",
        "/out:`"$exePath`"",
        "`"$csTemp`""
    )

    $proc = Start-Process -FilePath $csc -ArgumentList $compileArgs -NoNewWindow -Wait -PassThru
    Remove-Item -Path $csTemp -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -eq 0 -and (Test-Path $exePath)) {
        $hasExe = $true
        $checksumPath = Join-Path $rootFolder 'BingWallpaper.exe.sha256'
        $checksum = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath $checksumPath -Value "$checksum  BingWallpaper.exe" -Encoding ASCII
        Write-Output "    Created $exePath (with embedded authentic icon)"
        Write-Output "    Created $checksumPath"
    }
}

# 2. Create Desktop Shortcut
Write-Output "--> Creating Desktop shortcut..."
$wsh = New-Object -ComObject WScript.Shell

function Create-Shortcut($targetPath, $outLnkPath, $iconLocation, $args = '') {
    $sc = $wsh.CreateShortcut($outLnkPath)
    $sc.TargetPath = $targetPath
    if ($args) { $sc.Arguments = $args }
    $sc.WorkingDirectory = $rootFolder
    $sc.IconLocation = "$iconLocation,0"
    $sc.Description = 'Bing Wallpaper - Daily HD & 4K Wallpapers'
    $sc.Save()
}

$targetExe = if ($hasExe) { $exePath } else { "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
$targetArgs = if ($hasExe) { "" } else { "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uiPath`"" }

if (Test-Path $desktopPath) {
    Create-Shortcut -targetPath $targetExe -outLnkPath $desktopShortcutPath -iconLocation $icoPath -args $targetArgs
    Write-Output "    Created Desktop shortcut: $desktopShortcutPath"
}

Write-Output ""
Write-Output "========================================================="
Write-Output " Setup Complete!"
Write-Output " You can launch the app directly from:"
Write-Output "   1. Desktop shortcut: 'Bing Wallpaper'"
Write-Output "   2. Project root:     'BingWallpaper.exe'"
Write-Output "========================================================="
