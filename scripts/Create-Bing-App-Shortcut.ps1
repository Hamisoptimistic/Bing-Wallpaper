<#
.SYNOPSIS
    Compiles the zero-console standalone Windows GUI launcher (AutoScape.exe)
    with embedded Windows 11 Mica manifest and STA PowerShell hosting.
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

# 1. Compile standalone in-process GUI executable (AutoScape.exe)
Write-Output "--> Compiling AutoScape.exe (in-process PowerShell host + Mica manifest)..."
$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

# Locate System.Management.Automation.dll
$smaPath = [psobject].Assembly.Location
if (-not (Test-Path -LiteralPath $smaPath)) {
    $smaPath = "$env:WINDIR\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll"
}

# Create Windows 11 compatibility manifest for Mica & Dark Mode
$manifestPath = Join-Path $rootFolder 'app.manifest'
$manifestContent = @'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity version="1.0.0.0" name="AutoScape.App"/>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
      <supportedOS Id="{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}"/>
    </application>
  </compatibility>
</assembly>
'@
Set-Content -Path $manifestPath -Value $manifestContent -Encoding UTF8

$hasExe = $false
if ($csc) {
    $csSource = @'
using System;
using System.IO;
using System.Reflection;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace AutoScapeLauncher
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            string tempDir = Path.Combine(Path.GetTempPath(), "AutoScape");
            string iconPath = Path.Combine(tempDir, "assets", "app.ico");

            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(iconPath));

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
                // No native DLL to extract - BingWallpaper.FastAccent / FastDownloader /
                // BingWallpaperNative are compiled in-memory by the script itself via
                // Add-Type. Nothing unsigned ever touches disk.
            }
            catch { }

            string scriptContent = string.Empty;
            using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("AutoScapeLauncher.Bing-Wallpaper-UI.ps1"))
            {
                if (source != null)
                {
                    using (StreamReader reader = new StreamReader(source))
                    {
                        scriptContent = reader.ReadToEnd();
                    }
                }
            }

            if (string.IsNullOrEmpty(scriptContent)) return;

            using (Runspace rs = RunspaceFactory.CreateRunspace())
            {
                rs.ApartmentState = System.Threading.ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();

                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;

                    string argString = string.Empty;
                    if (args != null && args.Length > 0)
                    {
                        for (int i = 0; i < args.Length; i++)
                        {
                            string a = args[i];
                            if (a.Contains(" ")) a = "\"" + a + "\"";
                            argString += a + " ";
                        }
                    }

                    string escapedTemp = tempDir.Replace("'", "''");
                    string initScript = "$script:injectedScriptRoot = '" + escapedTemp + "';\n";

                    ps.AddScript(initScript + "& {\n" + scriptContent + "\n} " + argString);
                    ps.Invoke();
                }
            }
        }
    }
}
'@
    $csTemp = Join-Path $rootFolder 'AppLauncher_temp.cs'
    Set-Content -Path $csTemp -Value $csSource -Encoding UTF8

    $compileArgs = @(
        "/target:winexe",
        "/optimize+",
        "/platform:anycpu",
        "/reference:`"$smaPath`"",
        "/win32icon:`"$icoPath`"",
        "/win32manifest:`"$manifestPath`"",
        "/resource:`"$uiPath`",AutoScapeLauncher.Bing-Wallpaper-UI.ps1",
        "/resource:`"$icoPath`",AutoScapeLauncher.app.ico"
    )
    $compileArgs += @(
        "/out:`"$exePath`"",
        "`"$csTemp`""
    )

    $proc = Start-Process -FilePath $csc -ArgumentList $compileArgs -NoNewWindow -Wait -PassThru
    Remove-Item -Path $csTemp -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $manifestPath -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -eq 0 -and (Test-Path $exePath)) {
        $hasExe = $true
        $legacyExe = Join-Path $rootFolder 'BingWallpaper.exe'
        $legacySha = Join-Path $rootFolder 'BingWallpaper.exe.sha256'
        if (Test-Path $legacyExe) { Remove-Item $legacyExe -Force -ErrorAction SilentlyContinue }
        if (Test-Path $legacySha) { Remove-Item $legacySha -Force -ErrorAction SilentlyContinue }

        $checksumPath = Join-Path $rootFolder 'AutoScape.exe.sha256'
        $checksum = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath $checksumPath -Value "$checksum  AutoScape.exe" -Encoding ASCII
        Write-Output "    Created $exePath (in-process host with authentic icon & Mica support)"
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
Write-Output " Launcher: $exePath"
Write-Output "========================================================="