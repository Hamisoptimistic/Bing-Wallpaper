<#
.SYNOPSIS
    Installs AutoScape into a standardized per-user location
    (%LOCALAPPDATA%\AutoScape\app) and creates Desktop & Start Menu
    shortcuts pointing there - WITHOUT compiling a custom .exe host.
    This avoids Smart App Control / SmartScreen blocking unsigned unknown
    binaries, because the process actually launched is powershell.exe,
    which is Microsoft-signed and trusted.

    Installing to a fixed AppData location (instead of wherever the user
    happened to extract the zip) means:
      - the user can delete the extracted zip folder in Downloads right
        after running this, since the real copy now lives in AppData
      - "Check for updates" always knows exactly where to install to,
        with no guessing
#>

$ErrorActionPreference = 'Stop'

$setupLogPath = Join-Path $env:LOCALAPPDATA 'AutoScape\logs\setup.log'
function Write-SetupLog {
    param([string]$Message)
    try {
        $logDir = Split-Path -Parent $setupLogPath
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -LiteralPath $setupLogPath -Value "$(Get-Date -Format 'u')  $Message" -Encoding UTF8
    } catch {}
}

Write-SetupLog "SETUP: started."

# Stamps System.AppUserModel.ID onto a .lnk file. WScript.Shell (used below
# to actually create the shortcuts) has no way to set this property itself.
# Bing-Wallpaper-UI.ps1 calls SetCurrentProcessExplicitAppUserModelID with
# this same ID at startup, to group the taskbar button correctly since it's
# really launched via conhost.exe/powershell.exe, not its own exe. Without a
# shortcut declaring the same ID, Windows has no cached icon association for
# it on a fresh profile, and the taskbar button shows blank on first launch
# (it self-heals on later launches once Windows learns the association from
# use - this makes that immediate instead of eventual).
try {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class AutoScapeShortcutAppId
{
    [ComImport, Guid("0000010b-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPersistFile
    {
        void GetClassID(out Guid pClassID);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, int dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROPERTYKEY
    {
        public Guid fmtid;
        public int pid;
        public PROPERTYKEY(Guid fmtid, int pid) { this.fmtid = fmtid; this.pid = pid; }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROPVARIANT
    {
        public ushort vt;
        public ushort wReserved1, wReserved2, wReserved3;
        public IntPtr p;
        public int p2;
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        int GetCount(out uint cProps);
        int GetAt(uint iProp, out PROPERTYKEY pkey);
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
        int SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
        int Commit();
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class ShellLinkCoClass { }

    public static void SetAppId(string shortcutPath, string appId)
    {
        var link = (IPersistFile)new ShellLinkCoClass();
        try
        {
            link.Load(shortcutPath, 0); // STGM_READWRITE
            var store = (IPropertyStore)link;
            try
            {
                var pkeyAppUserModelId = new PROPERTYKEY(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);
                var pv = new PROPVARIANT();
                pv.vt = 31; // VT_LPWSTR
                pv.p = Marshal.StringToCoTaskMemUni(appId);
                try
                {
                    int hr = store.SetValue(ref pkeyAppUserModelId, ref pv);
                    if (hr == 0) { store.Commit(); }
                }
                finally
                {
                    Marshal.FreeCoTaskMem(pv.p);
                }
            }
            finally
            {
                Marshal.ReleaseComObject(store);
            }
            link.Save(shortcutPath, true);
        }
        finally
        {
            Marshal.ReleaseComObject(link);
        }
    }
}
'@ -ErrorAction Stop
    $script:appUserModelIdHelperAvailable = $true
}
catch {
    Write-SetupLog "SETUP: AppUserModel.ID helper failed to compile - $($_.Exception.Message)"
    $script:appUserModelIdHelperAvailable = $false
}


$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$sourceRoot = if (Test-Path (Join-Path $scriptDir 'Bing-Wallpaper-UI.ps1')) {
    $scriptDir
} else {
    Split-Path -Parent $scriptDir
}

$uiSourcePath = Join-Path $sourceRoot 'Bing-Wallpaper-UI.ps1'
if (-not (Test-Path -LiteralPath $uiSourcePath)) {
    Write-SetupLog "SETUP: FAILED - Bing-Wallpaper-UI.ps1 not found at $uiSourcePath"
    throw "Bing-Wallpaper-UI.ps1 not found at $uiSourcePath"
}

# Standardized install location - "Check for updates" targets this exact
# same path, so it always knows where to install without guessing.
$installDir = Join-Path $env:LOCALAPPDATA 'AutoScape\app'
Write-SetupLog "SETUP: source=$sourceRoot installDir=$installDir"

try {
    if (Test-Path -LiteralPath $installDir) {
        Write-SetupLog "SETUP: removing previous install at $installDir"
        Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction Stop
    }
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Copy-Item -Path (Join-Path $sourceRoot '*') -Destination $installDir -Recurse -Force -ErrorAction Stop
    if (-not (Test-Path -LiteralPath (Join-Path $installDir 'assets'))) {
        $parentAssets = Join-Path (Split-Path -Parent $sourceRoot) 'assets'
        if (Test-Path -LiteralPath $parentAssets) {
            Copy-Item -Path $parentAssets -Destination (Join-Path $installDir 'assets') -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-SetupLog "SETUP: copied app files to $installDir"
}
catch {
    Write-SetupLog "SETUP: FAILED - could not copy to $installDir - $($_.Exception.Message)"
    throw "Could not install AutoScape to $installDir. $($_.Exception.Message)"
}

$uiPath = Join-Path $installDir 'Bing-Wallpaper-UI.ps1'
$assetsFolder = Join-Path $installDir 'assets'
$icoCandidates = @(
    (Join-Path $assetsFolder 'app.ico'),
    (Join-Path $assetsFolder 'bing.ico')
)
$icoPath = $icoCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

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

    if ($script:appUserModelIdHelperAvailable) {
        try {
            [AutoScapeShortcutAppId]::SetAppId($outLnkPath, 'AutoScape.App')
            Write-SetupLog "SETUP: stamped AppUserModel.ID on $outLnkPath"
        }
        catch {
            Write-SetupLog "SETUP: could not stamp AppUserModel.ID on $outLnkPath - $($_.Exception.Message)"
        }
    }
}

# Clean up old shortcuts if present (older naming scheme)
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
    Write-SetupLog "SETUP: FAILED - conhost.exe not found at $conhostExe"
    throw "Windows Console Host was not found at $conhostExe"
}

$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psArgString = "--headless `"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -File `"$uiPath`""

if (Test-Path $desktopPath) {
    Create-Shortcut -targetPath $conhostExe -outLnkPath $desktopShortcutPath -iconLocation $icoPath -workingDir $installDir -argString $psArgString
    Write-SetupLog "SETUP: desktop shortcut created -> $desktopShortcutPath"
    Write-Host "    [OK] Desktop shortcut created" -ForegroundColor Green
}

$startMenuPrograms = [Environment]::GetFolderPath('Programs')
if ($startMenuPrograms -and (Test-Path $startMenuPrograms)) {
    $oldStartMenuLnk = Join-Path $startMenuPrograms 'Bing Wallpaper.lnk'
    if (Test-Path $oldStartMenuLnk) { Remove-Item $oldStartMenuLnk -Force -ErrorAction SilentlyContinue }

    $startMenuShortcutPath = Join-Path $startMenuPrograms 'AutoScape.lnk'
    Create-Shortcut -targetPath $conhostExe -outLnkPath $startMenuShortcutPath -iconLocation $icoPath -workingDir $installDir -argString $psArgString
    Write-SetupLog "SETUP: start menu shortcut created -> $startMenuShortcutPath"
    Write-Host "    [OK] Start Menu shortcut created" -ForegroundColor Green
}

Write-SetupLog "SETUP: complete."

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkCyan
Write-Host " AutoScape installation complete" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor DarkCyan
Write-Host ""
Write-Host " AutoScape is installed and ready to use." -ForegroundColor White
Write-Host " Desktop and Start Menu shortcuts have been created." -ForegroundColor White
Write-Host ""
Write-Host " You can now delete the extracted folder - AutoScape has been" -ForegroundColor Gray
Write-Host " copied to your user profile at:" -ForegroundColor Gray
Write-Host " $installDir" -ForegroundColor Gray
Write-Host ""
Write-Host " Launch AutoScape from either shortcut." -ForegroundColor Gray
Write-Host ""