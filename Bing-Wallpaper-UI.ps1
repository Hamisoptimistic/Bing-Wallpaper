[CmdletBinding()]
param(
    [switch]$AutoApply,
    [string]$Region = 'en-US',
    [ValidateSet('4K', '2K', '1080p', '720p', '4K UHD', 'UHD', '1920x1080', '1366x768')]
    [string]$Resolution = '4K',
    [ValidateSet('Desktop', 'Lock screen', 'Both')]
    [string]$Target = 'Desktop',
    [ValidateSet('Fit', 'Fill', 'Stretch', 'Center', 'Tile', 'Span')]
    [string]$Style = 'Fit'
)

# Enforce modern security protocols to prevent connection blocks or downgrade attacks
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
}
catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# Load necessary modern UI assemblies
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms # Kept only for the Folder Browser dialog
Add-Type -AssemblyName System.Drawing

# Application update metadata. Releases must publish both BingWallpaper.exe and
# BingWallpaper.exe.sha256 (a SHA-256 checksum file for the exact EXE asset).
$script:appVersion = [Version]'1.0.54'
$script:updateRepository = 'Hamisoptimistic/Bing-Wallpaper'
$script:updatePublisherThumbprint = '' # Set this when release EXEs are Authenticode-signed.

# ============================================================
# WINDOWS 11 LOCK SCREEN
# ============================================================
# Windows 11 does NOT reliably change the lock screen by merely
# writing PersonalizationCSP registry values. The supported WinRT
# API is UserProfilePersonalizationSettings.TrySetLockScreenImageAsync.
#
# IMPORTANT:
# Microsoft requires a DIFFERENT filename when setting a new lock
# screen image. Reusing "current_lockscreen.jpg" can silently fail.
#
# This function:
#   1. Copies the downloaded image to a unique filename.
#   2. Disables Spotlight rotation when explicitly applying a picture.
#   3. Calls TrySetLockScreenImageAsync in an isolated runspace.
#   4. Falls back to LockScreen.SetImageFileAsync if necessary.
#   5. Returns FALSE when Windows actually failed instead of claiming
#      success.
# ============================================================

function Set-LockScreenImageIsolated {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath
    )

    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
        throw "Lock screen source image does not exist: $ImagePath"
    }

    # LockScreen.SetImageFileAsync is not supported from x86 console
    # applications on x64 Windows. Always require a 64-bit PowerShell.
    if (-not [Environment]::Is64BitProcess) {
        throw "The lock screen requires 64-bit PowerShell on 64-bit Windows. Run the script with 64-bit powershell.exe."
    }

    $cacheDir = Split-Path -Parent $ImagePath

    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    # ------------------------------------------------------------
    # Stop Windows Spotlight / rotating lock-screen content from
    # immediately replacing the picture we just selected.
    # ------------------------------------------------------------
    try {
        $cdmPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

        if (-not (Test-Path -LiteralPath $cdmPath)) {
            New-Item -Path $cdmPath -Force | Out-Null
        }

        Set-ItemProperty `
            -Path $cdmPath `
            -Name 'RotatingLockScreenEnabled' `
            -Value 0 `
            -Type DWord `
            -Force `
            -ErrorAction SilentlyContinue

        Set-ItemProperty `
            -Path $cdmPath `
            -Name 'RotatingLockScreenOverlayEnabled' `
            -Value 0 `
            -Type DWord `
            -Force `
            -ErrorAction SilentlyContinue

        Set-ItemProperty `
            -Path $cdmPath `
            -Name 'SubscribedContent-338387Enabled' `
            -Value 0 `
            -Type DWord `
            -Force `
            -ErrorAction SilentlyContinue
    }
    catch {
        # These registry values are only a safeguard against Spotlight
        # replacing the selected picture. The WinRT call below is the
        # actual lock-screen operation.
    }

    # ------------------------------------------------------------
    # IMPORTANT: give EVERY lock-screen image a new filename.
    # Windows documents that setting a new image with the same
    # filename can fail.
    # ------------------------------------------------------------
    $uniqueName =
    'BingLockScreen-{0}-{1}.jpg' -f `
    (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), `
    ([Guid]::NewGuid().ToString('N'))

    $uniquePath =
    Join-Path $cacheDir $uniqueName

    Copy-Item `
        -LiteralPath (Resolve-Path -LiteralPath $ImagePath).Path `
        -Destination $uniquePath `
        -Force `
        -ErrorAction Stop

    $resolvedPath =
    (Resolve-Path -LiteralPath $uniquePath).Path

    # ------------------------------------------------------------
    # Use an isolated PowerShell runspace for WinRT.
    # Do not execute the WinRT call on the WPF UI thread.
    # ------------------------------------------------------------
    # WinRT personalization APIs strictly require an STA thread.
    # [PowerShell]::Create() defaults to MTA, which causes these
    # operations to hang indefinitely waiting for a message pump.
    # ------------------------------------------------------------
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.Open()

    $worker = $null
    $async = $null

    try {

        $worker =
        [PowerShell]::Create()
        
        $worker.Runspace = $rs

        $workerScript = {
            param(
                [string]$Path
            )

            try {

                if (-not [Environment]::Is64BitProcess) {
                    return 'ERROR|32BIT'
                }

                # ------------------------------------------------
                # FIX: Properly await WinRT async operations.
                # PowerShell runspaces use thread pool threads which lack 
                # a SynchronizationContext/message pump. WinRT async operations 
                # get "stuck" in Status 0 (Started) because their completion 
                # callbacks are never dispatched. We must convert them to .NET 
                # Tasks using System.Runtime.WindowsRuntime and Wait() on them.
                # ------------------------------------------------
                try { Add-Type -AssemblyName System.Runtime.WindowsRuntime } catch {}

                $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
                        $_.Name -eq 'AsTask' -and
                        $_.GetParameters().Count -eq 1 -and
                        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
                    })[0]

                function Await($WinRtTask, $ResultType) {
                    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
                    $netTask = $asTask.Invoke($null, @($WinRtTask))
                    $netTask.Wait(-1) | Out-Null
                    $netTask.Result
                }

                $asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
                        $_.Name -eq 'AsTask' -and
                        $_.GetParameters().Count -eq 1 -and
                        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
                    })[0]

                function AwaitAction($WinRtTask) {
                    $netTask = $asTaskAction.Invoke($null, @($WinRtTask))
                    $netTask.Wait(-1) | Out-Null
                }

                # Load WinRT types.
                [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] |
                Out-Null

                [Windows.System.UserProfile.UserProfilePersonalizationSettings, Windows.System.UserProfile, ContentType = WindowsRuntime] |
                Out-Null

                [Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime] |
                Out-Null


                # ------------------------------------------------
                # Get the file as a Windows StorageFile.
                # ------------------------------------------------
                try {
                    $storageFile = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
                }
                catch {
                    return "ERROR|STORAGEFILE|$($_.Exception.Message)"
                }


                # ------------------------------------------------
                # FIRST METHOD:
                # UserProfilePersonalizationSettings
                # ------------------------------------------------
                try {

                    if (
                        [Windows.System.UserProfile.UserProfilePersonalizationSettings]::IsSupported()
                    ) {

                        $settings =
                        [Windows.System.UserProfile.UserProfilePersonalizationSettings]::Current

                        $result = Await ($settings.TrySetLockScreenImageAsync($storageFile)) ([bool])

                        if ($result -eq $true) {
                            return 'SUCCESS|PERSONALIZATION'
                        }
                    }
                }
                catch {
                    # Continue to the fallback API.
                }


                # ------------------------------------------------
                # FALLBACK:
                # LockScreen.SetImageFileAsync
                # ------------------------------------------------
                try {
                    AwaitAction ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($storageFile))
                    return 'SUCCESS|LOCKSCREEN'
                }
                catch {
                    # Both WinRT methods failed.
                }

                return 'ERROR|WINRT'
            }
            catch {
                return "ERROR|$($_.Exception.Message)"
            }
        }


        $null =
        $worker.AddScript(
            $workerScript
        ).AddArgument(
            $resolvedPath
        )

        $async =
        $worker.BeginInvoke()

        # Wait up to 30 seconds for the WinRT operation to complete
        $completed =
        $async.AsyncWaitHandle.WaitOne(30000)

        if (-not $completed) {
            throw "Windows did not finish the lock-screen operation within 30 seconds."
        }

        $output =
        @($worker.EndInvoke($async))

        $result =
        if ($output.Count -gt 0) {
            [string]$output[0]
        }
        else {
            ''
        }

        if ($result -like 'SUCCESS|*') {
            return $true
        }

        if ($result -eq 'ERROR|32BIT') {
            throw "The lock-screen API was invoked from 32-bit PowerShell. Use 64-bit Windows PowerShell."
        }

        throw "Windows rejected the lock-screen image. WinRT result: $result"
    }
    finally {

        if ($worker) {
            $worker.Dispose()
        }
        if ($rs) {
            $rs.Dispose()
        }
    }
}


# Load native Windows API for desktop wallpaper and Windows 11 dark titlebar
# Load native Windows API for desktop wallpaper, dark titlebar, and dark dialogs
if (-not ('BingWallpaperNative' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class BingWallpaperNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct MARGINS {
        public int cxLeftWidth;
        public int cxRightWidth;
        public int cyTopHeight;
        public int cyBottomHeight;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(int action, int parameter, string path, int flags);

    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    [DllImport("dwmapi.dll")]
    public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);

    public const int DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19;
    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWA_CAPTION_COLOR = 35;
    public const int DWMWA_TEXT_COLOR = 36;
    public const int DWMWA_SYSTEMBACKDROP_TYPE = 38;

    public static void EnableDarkTitleBar(IntPtr hwnd, int captionColorBgr = 0x00121212) {
        try {
            int trueVal = 1;
            int res = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref trueVal, sizeof(int));
            if (res != 0) {
                DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, ref trueVal, sizeof(int));
            }
            int roundCorner = 2;
            DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref roundCorner, sizeof(int));
            
            // Enable Mica / Fluent Backdrop
            int backdrop = 2; // 2 = Mica, 3 = Acrylic
            DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int));
            
            // Fallback for Windows 11 21H2
            int trueValMica = 1;
            DwmSetWindowAttribute(hwnd, 1029, ref trueValMica, sizeof(int));
            
            if (captionColorBgr >= 0) {
                DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, ref captionColorBgr, sizeof(int));
                int textColor = 0x00FFFFFF;
                DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, ref textColor, sizeof(int));
            }
        } catch { }
    }

    // ---------------------------------------------------------------
    // Modern dark-mode common dialogs (folder / file pickers)
    // ---------------------------------------------------------------
    [DllImport("uxtheme.dll", EntryPoint = "#131")]
    private static extern int SetPreferredAppMode(int mode);        // 2 = ForceDark

    [DllImport("uxtheme.dll", EntryPoint = "#135")]
    private static extern bool AllowDarkModeForApp(bool allow);

    [DllImport("uxtheme.dll", EntryPoint = "#104")]
    private static extern void RefreshImmersiveColorPolicyState();

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    private static extern int SetWindowTheme(IntPtr hwnd, string pszSubAppName, string pszSubIdList);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    // Tell Windows this app wants dark Win32 common dialogs.
    public static void EnableDarkDialogs() {
        try {
            SetPreferredAppMode(2);
            AllowDarkModeForApp(true);
            RefreshImmersiveColorPolicyState();
        } catch { /* older builds: the timer fallback below handles it */ }
    }

    public static IntPtr ForegroundWindow() {
        return GetForegroundWindow();
    }

    public static bool IsDialogWindow(IntPtr hwnd) {
        try {
            StringBuilder sb = new StringBuilder(64);
            GetClassName(hwnd, sb, 64);
            return sb.ToString() == "#32770";
        } catch { return false; }
    }

    // Re-theme an open dialog and all of its child controls into dark mode.
    public static void ForceDarkDialog(IntPtr hwnd) {
        try {
            int trueVal = 1;
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref trueVal, sizeof(int));
            SetWindowTheme(hwnd, "DarkMode_Explorer", null);
            EnumChildWindows(hwnd, delegate (IntPtr child, IntPtr param) {
                SetWindowTheme(child, "DarkMode_Explorer", null);
                return true;
            }, IntPtr.Zero);
        } catch { }
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem {
        void BindToHandler();
        void GetParent();
        void GetDisplayName([In] uint sigdnName, [Out, MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes();
        void Compare();
    }

    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOpenDialog {
        [PreserveSig] int Show([In] IntPtr parent);
        void SetFileTypes();
        void SetFileTypeIndex();
        void GetFileTypeIndex();
        void Advise();
        void Unadvise();
        void SetOptions([In] uint fos);
        void GetOptions([Out] out uint fos);
        void SetDefaultFolder();
        void SetFolder();
        void GetFolder();
        void GetCurrentSelection();
        void SetFileName();
        void GetFileName();
        void SetTitle([In, MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel();
        void SetFileNameLabel();
        void GetResult([Out, MarshalAs(UnmanagedType.Interface)] out IShellItem ppsi);
        void AddPlace();
        void SetDefaultExtension();
        void Close();
        void SetClientGuid();
        void ClearClientData();
        void SetFilter();
        void GetResults();
        void GetSelectedItems();
    }

    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    private class FileOpenDialog { }

    [DllImport("psapi.dll")]
    public static extern int EmptyWorkingSet(IntPtr hwProc);

    public static void FlushMemory() {
        try {
            GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, true, true);
            GC.WaitForPendingFinalizers();
            GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, true, true);
            EmptyWorkingSet(System.Diagnostics.Process.GetCurrentProcess().Handle);
        } catch { }
    }

    public static string PickFolder(IntPtr parent, string title) {
        try {
            IFileOpenDialog dialog = (IFileOpenDialog)new FileOpenDialog();
            uint options;
            dialog.GetOptions(out options);
            dialog.SetOptions(options | 0x20); // FOS_PICKFOLDERS
            dialog.SetTitle(title);
            
            if (dialog.Show(parent) == 0) {
                IShellItem item;
                dialog.GetResult(out item);
                string path;
                item.GetDisplayName(0x80058000, out path); // SIGDN_FILESYSPATH
                return path;
            }
        } catch { }
        return null;
    }
}
"@
}

# ==========================================
# Core Functions
# ==========================================

function Get-DownloadFolder {
    $pictures = [Environment]::GetFolderPath('MyPictures')
    return (Join-Path $pictures 'BingWallpapers')
}

function Get-BingImages {
    param([string]$Region)
    $market = if ($Region -eq 'auto') { 'en-US' } else { $Region }
    
    # Bing API only allows going back ~16 days max. We fetch in two batches.
    $uri1 = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=$market"
    $uri2 = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=8&n=8&mkt=$market"
    
    $batch1 = (Invoke-RestMethod -Uri $uri1 -ErrorAction SilentlyContinue).images
    $batch2 = (Invoke-RestMethod -Uri $uri2 -ErrorAction SilentlyContinue).images
    
    # Combine the arrays and ensure no duplicates based on urlbase
    $allImages = @()
    if ($batch1) { $allImages += $batch1 }
    if ($batch2) { $allImages += $batch2 }
    
    $uniqueImages = $allImages | Group-Object -Property urlbase | ForEach-Object { $_.Group[0] } | Sort-Object -Property enddate -Descending
    return $uniqueImages
}

function Get-BingImageUri {
    param(
        $Image,
        [string]$Resolution
    )
    $urlBase = $Image.urlbase
    if (-not $urlBase -or -not ($urlBase -match '^/th\?id=')) {
        throw "Invalid image URLBase format received from Bing."
    }
    switch -Regex ($Resolution) {
        '4K|UHD' {
            return "https://www.bing.com${urlBase}_UHD.jpg"
        }
        '2K|1440' {
            return "https://www.bing.com${urlBase}_UHD.jpg&w=2560&h=1440&rs=1&c=4"
        }
        '1080' {
            return "https://www.bing.com${urlBase}_1920x1080.jpg"
        }
        '720|1366|768' {
            return "https://www.bing.com${urlBase}_1920x1080.jpg&w=1280&h=720&rs=1&c=4"
        }
        Default {
            return "https://www.bing.com${urlBase}_UHD.jpg"
        }
    }
}

function Set-DesktopWallpaperStyle {
    param(
        [ValidateSet('Fit', 'Fill', 'Stretch', 'Center', 'Tile', 'Span')]
        [string]$Style = 'Fit'
    )
    $regPath = 'HKCU:\Control Panel\Desktop'
    $styleVal = '6'
    $tileVal = '0'
    switch ($Style) {
        'Fit' { $styleVal = '6'; $tileVal = '0' }
        'Fill' { $styleVal = '10'; $tileVal = '0' }
        'Stretch' { $styleVal = '2'; $tileVal = '0' }
        'Center' { $styleVal = '0'; $tileVal = '0' }
        'Tile' { $styleVal = '0'; $tileVal = '1' }
        'Span' { $styleVal = '22'; $tileVal = '0' }
    }
    Set-ItemProperty -Path $regPath -Name 'WallpaperStyle' -Value $styleVal -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $regPath -Name 'TileWallpaper' -Value $tileVal -Force -ErrorAction SilentlyContinue
}

function Get-CurrentDesktopWallpaperStyle {
    try {
        $reg = Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue
        $ws = "$($reg.WallpaperStyle)"
        $tw = "$($reg.TileWallpaper)"
        if ($ws -eq '6') { return 'Fit' }
        if ($ws -eq '10') { return 'Fill' }
        if ($ws -eq '2') { return 'Stretch' }
        if ($ws -eq '22') { return 'Span' }
        if ($ws -eq '0' -and $tw -eq '1') { return 'Tile' }
        if ($ws -eq '0') { return 'Center' }
    }
    catch {}
    return 'Fit'
}

function Set-BingImage {
    param(
        $Image,
        [string]$Resolution,
        [string]$Target = 'Desktop',
        [string]$Style = 'Fit'
    )

    $cacheDir = Join-Path $env:LOCALAPPDATA 'BingWallpaper\Cache'
    if (!(Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    $imageUri = Get-BingImageUri -Image $Image -Resolution $Resolution
    $cachePath = Join-Path $cacheDir "current_wallpaper.jpg"

    Invoke-WebRequest -Uri $imageUri -OutFile $cachePath -UseBasicParsing -ErrorAction Stop

    if ($Target -eq 'Desktop' -or $Target -eq 'Both') {
        Set-DesktopWallpaperStyle -Style $Style
        if (![BingWallpaperNative]::SystemParametersInfo(20, 0, $cachePath, 3)) {
            throw 'Windows could not apply the downloaded image as desktop wallpaper.'
        }
    }

    if ($Target -eq 'Lock screen' -or $Target -eq 'Both') {
        try {
            $fullCachePath = (Resolve-Path -LiteralPath $cachePath).Path
            $lockScreenCachePath = Join-Path $cacheDir "current_lockscreen.jpg"
            Copy-Item -LiteralPath $fullCachePath -Destination $lockScreenCachePath -Force

            $res = Set-LockScreenImageIsolated -imagePath $lockScreenCachePath
            if (-not $res) {
                throw 'Windows could not apply the lock screen image.'
            }
        }
        catch {
            throw "Could not apply the lock screen image. $($_.Exception.Message)"
        }
    }
    return $cachePath
}

function Get-CleanImageTitle {
    param($Image)
    $t = $Image.title
    if (-not $t -or $t.Trim() -eq '' -or $t.Trim() -ieq 'Info' -or $t.Trim() -ieq 'Information') {
        # Fallback to copyright text without the photographer/license parentheses
        if ($Image.copyright) {
            $clean = $Image.copyright -replace '\s*\([^\)]*\)\s*$', ''
            $clean = $clean.Trim()
            if ($clean) { return $clean }
        }
        # Secondary fallback: extract readable name from urlbase
        if ($Image.urlbase -match 'OHR\.([A-Za-z0-9]+)_') {
            $clean = $matches[1] -creplace '([a-z])([A-Z])', '$1 $2'
            return $clean
        }
        return 'Bing Wallpaper'
    }
    return $t.Trim()
}

function Save-BingImage {
    param(
        $Image,
        [string]$Resolution,
        [string]$DownloadFolder
    )

    if (-not (Test-Path -LiteralPath $DownloadFolder)) {
        New-Item -ItemType Directory -Path $DownloadFolder -Force | Out-Null
    }

    $imageUri = Get-BingImageUri -Image $Image -Resolution $Resolution
    $imageDate = if ($Image.enddate -and ($Image.enddate -match '^\d{8}$')) { $Image.enddate } else { (Get-Date).ToString('yyyyMMdd') }
    $displayTitle = Get-CleanImageTitle $Image
    # Strip dangerous filesystem/path traversal characters and limit length
    $cleanTitle = ($displayTitle -replace '[\\/:*?"<>|\x00-\x1F]', '').Trim()
    $cleanTitle = ($cleanTitle -replace '\s+', ' ').Trim()
    if ($cleanTitle.Length -gt 60) { $cleanTitle = $cleanTitle.Substring(0, 60).Trim() }
    
    $fileName = if ($cleanTitle) { "Bing-$imageDate-$cleanTitle.jpg" } else { "Bing-$imageDate.jpg" }
    $downloadPath = Join-Path $DownloadFolder $fileName

    Invoke-WebRequest -Uri $imageUri -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop
    return $downloadPath
}

# ==========================================
# Headless CLI Execution Mode
# (For Task Scheduler / Background Automation)
# ==========================================
if ($AutoApply) {
    try {
        $images = Get-BingImages -Region $Region
        if (-not $images -or $images.Count -eq 0) {
            throw "No Bing wallpaper metadata found for region '$Region'."
        }
        $targetImage = $images[0]
        $title = Get-CleanImageTitle $targetImage
        $appliedPath = Set-BingImage -Image $targetImage -Resolution $Resolution -Target $Target -Style $Style
        Write-Output "Successfully applied Bing Wallpaper: $title ($appliedPath)"
        exit 0
    }
    catch {
        Write-Error "Failed to apply Bing Wallpaper: $($_.Exception.Message)"
        exit 1
    }
}

# ==========================================
# Modern XAML UI Definition
# ==========================================

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Bing Wallpaper" Height="780" Width="1100"
        Background="Transparent" FontFamily="Segoe UI" WindowStartupLocation="CenterScreen">
    
    <Window.Resources>
        <!-- Custom Button Style -->
        <Style TargetType="Button">
            <Setter Property="Background" Value="#252525"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderThickness" Value="1.5"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="RevealBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#333333"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Modern Windows 11 Input Companion Button Style (Borderless Matte) -->
        <Style x:Key="ModernIconButton" TargetType="Button">
            <Setter Property="Background" Value="#2A2A2A"/>
            <Setter Property="Foreground" Value="#F0F0F0"/>
            <Setter Property="BorderThickness" Value="1.5"/>
            <Setter Property="BorderBrush" Value="#1FFFFFFF"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="RevealBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#282828"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#242424"/>
                                <Setter TargetName="RevealBorder" Property="BorderBrush" Value="#0078D4"/>
                                <Setter Property="Foreground" Value="#0078D4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>


        <!-- Modern Windows 11 ComboBox Style (Borderless Matte) -->
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#2A2A2A"/>
            <Setter Property="Foreground" Value="#F0F0F0"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Height" Value="38"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border Name="RevealBorder" Background="{TemplateBinding Background}" BorderBrush="#1FFFFFFF" BorderThickness="1.5" CornerRadius="8">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="34"/>
                                    </Grid.ColumnDefinitions>
                                    <ContentPresenter Grid.Column="0" Content="{TemplateBinding SelectionBoxItem}" TextElement.Foreground="{TemplateBinding Foreground}" VerticalAlignment="Center" Margin="14,0,0,0"/>
                                    <TextBlock Name="ArrowIcon" Grid.Column="1" Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" Foreground="#777" VerticalAlignment="Center" HorizontalAlignment="Center" FontSize="11" IsHitTestVisible="False"/>
                                </Grid>
                            </Border>
                            <ToggleButton Opacity="0" IsChecked="{Binding Path=IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" Cursor="Hand" />
                            <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False">
                                <Border Background="#1E1E1E" CornerRadius="8" Margin="0,4,0,0" MinWidth="{TemplateBinding ActualWidth}" Padding="4">
                                    <ScrollViewer MaxHeight="260" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden">
                                        <ItemsPresenter/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#282828"/>
                                <Setter TargetName="ArrowIcon" Property="Foreground" Value="#DDD"/>
                            </Trigger>
                            <Trigger Property="IsDropDownOpen" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#242424"/>
                                <Setter TargetName="RevealBorder" Property="BorderBrush" Value="#0078D4"/>
                                <Setter TargetName="ArrowIcon" Property="Foreground" Value="#0078D4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Modern ComboBoxItem Style -->
        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="#F0F0F0"/>
            <Setter Property="Padding" Value="12,8"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="1.5"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border Name="RevealBorder" Padding="{TemplateBinding Padding}" Background="Transparent" BorderThickness="{TemplateBinding BorderThickness}" BorderBrush="{TemplateBinding BorderBrush}" CornerRadius="6" Margin="2,1">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#2C2C2C"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#0078D4"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Modern Windows 11 TextBox Style (Borderless Matte) -->
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#2A2A2A"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Height" Value="38"/>
            <Setter Property="Padding" Value="14,0"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="CaretBrush" Value="#0078D4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Name="RevealBorder" Background="{TemplateBinding Background}" BorderBrush="#1FFFFFFF" BorderThickness="1.5" CornerRadius="8">
                            <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#282828"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#242424"/>
                                <Setter TargetName="RevealBorder" Property="BorderBrush" Value="#0078D4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Windows 11 Slim Modern Scrollbar -->
        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="6"/>
            <Setter Property="MinWidth" Value="6"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="Transparent">
                            <Track Name="PART_Track" IsDirectionReversed="true">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Background="Transparent" BorderThickness="0" Focusable="False" Opacity="0"/>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb BorderThickness="0">
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="Thumb">
                                                <Border Name="ThumbBorder" Background="#555555" CornerRadius="3" Margin="0,2"/>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="ThumbBorder" Property="Background" Value="#0078D4"/>
                                                    </Trigger>
                                                    <Trigger Property="IsDragging" Value="True">
                                                        <Setter TargetName="ThumbBorder" Property="Background" Value="#005A9E"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Background="Transparent" BorderThickness="0" Focusable="False" Opacity="0"/>
                                </Track.IncreaseRepeatButton>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Height" Value="6"/>
                    <Setter Property="MinHeight" Value="6"/>
                    <Setter Property="Width" Value="Auto"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- Modern ScrollViewer with slim overlay scrollbar -->
        <Style TargetType="ScrollViewer">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollViewer">
                        <Grid>
                            <ScrollContentPresenter CanContentScroll="{TemplateBinding CanContentScroll}" />
                            <ScrollBar Name="PART_VerticalScrollBar"
                                       Orientation="Vertical"
                                       HorizontalAlignment="Right"
                                       VerticalAlignment="Stretch"
                                       Width="6"
                                       Margin="0,4,4,4"
                                       Value="{TemplateBinding VerticalOffset}"
                                       Maximum="{TemplateBinding ScrollableHeight}"
                                       ViewportSize="{TemplateBinding ViewportHeight}"
                                       Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="32">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Grid Margin="0,0,0,32">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
                <Border Background="#141212ff" Width="52" Height="52" CornerRadius="14" Margin="0,0,20,0">
                    <Viewbox Margin="9">
                        <Canvas Width="24" Height="24">
                            <Path Data="M11.97 7.569a.92.92 0 00-.805.863c-.013.195-.01.209.43 1.347 1 2.59 1.242 3.214 1.283 3.302.099.213.237.413.41.592.134.138.222.212.37.311.26.176.39.224 1.405.527.989.295 1.529.49 1.994.723.603.302 1.024.644 1.29 1.051.191.292.36.815.434 1.342.029.206.029.661 0 .847a2.491 2.491 0 01-.376 1.026c-.1.151-.065.126.081-.058.415-.52.838-1.408 1.054-2.213a6.728 6.728 0 00.102-3.012 6.626 6.626 0 00-3.291-4.53c-.34-.19-.879-.473-1.322-.698l-.254-.133a737.941 737.941 0 01-1.575-.827c-.548-.29-.78-.406-.846-.426a1.376 1.376 0 00-.29-.045l-.093.01z" Fill="#00CACC"/>
                            <Path Data="M13.164 17.24a4.385 4.385 0 00-.202.125 511.45 511.45 0 00-1.795 1.115 163.087 163.087 0 01-.989.614l-.463.288a99.198 99.198 0 01-1.502.941c-.326.2-.704.334-1.09.387-.18.024-.52.024-.7 0a2.807 2.807 0 01-1.318-.538 3.665 3.665 0 01-.543-.545 2.837 2.837 0 01-.506-1.141 2.161 2.161 0 00-.041-.182c-.008-.008.006.138.032.33.027.199.085.487.147.733.482 1.907 1.85 3.457 3.705 4.195a6.31 6.31 0 001.658.412c.22.025.844.035 1.074.017 1.054-.08 1.972-.393 2.913-.992a325.28 325.28 0 01.937-.596l.384-.244.684-.435.234-.149.009-.005.025-.017.013-.007.172-.11.597-.38c.76-.481.987-.65 1.34-.998.148-.146.37-.394.381-.425.002-.007.042-.068.088-.136a2.49 2.49 0 00.373-1.023 4.181 4.181 0 000-.847 4.336 4.336 0 00-.318-1.137c-.224-.472-.7-.9-1.383-1.245a2.972 2.972 0 00-.406-.181c-.01 0-.646.392-1.413.87a7089.171 7089.171 0 01-1.658 1.031l-.439.274z" Fill="#2756A9"/>
                            <Path Data="M4.003 14.946l.004 3.33.042.193c.134.604.366 1.04.77 1.445a2.701 2.701 0 001.955.814c.536 0 1-.135 1.479-.43l.703-.435.556-.346V8.003c0-2.306-.004-3.675-.012-3.782a2.734 2.734 0 00-.797-1.765c-.145-.144-.268-.24-.637-.496A1780.102 1780.102 0 015.762.362C5.406.115 5.38.098 5.271.059a.943.943 0 00-1.254.696C4.003.818 4 1.659 4 6.223v5.394H4l.003 3.329z" Fill="#00BBEC"/>
                        </Canvas>
                    </Viewbox>
                </Border>
                <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Bing Wallpaper" FontSize="28" FontWeight="SemiBold" Foreground="#FAFAFA" Margin="0,0,0,4"/>
                </StackPanel>
            </StackPanel>
        </Grid>

        <!-- Settings Cards -->
        <Grid Grid.Row="1" Margin="0,0,0,24">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="200"/>
                <ColumnDefinition Width="150"/>
                <ColumnDefinition Width="150"/>
                <ColumnDefinition Width="150"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            
            <StackPanel Grid.Column="0" Margin="0,0,16,0">
                <TextBlock Text="Region" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                <Grid Height="38">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <ComboBox Name="RegionBox" FontSize="13.5"/>
                    <Button Name="RefreshBtn" Style="{StaticResource ModernIconButton}" Grid.Column="1" Width="38" Height="38" Margin="8,0,0,0" ToolTip="Refresh Gallery">
                        <Viewbox Width="19" Height="19" Margin="0,2,0,0">
                            <Canvas Name="RefreshIcon" Width="24" Height="24" RenderTransformOrigin="0.5,0.5">
                                <Canvas.RenderTransform>
                                <RotateTransform/>
                                </Canvas.RenderTransform>
                                <Path Data="M18.5,10 A7,7 0 1,0 16.6,15.7"
                                      Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                                      StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                                <Path Data="M18.5,5 V10 H13.5"
                                      Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                                      StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                            </Canvas>
                        </Viewbox>
                    </Button>
                </Grid>
            </StackPanel>
            
            <StackPanel Grid.Column="1" Margin="0,0,16,0">
                <TextBlock Text="Resolution" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                <ComboBox Name="ResolutionBox" FontSize="13.5"/>
            </StackPanel>

            <StackPanel Grid.Column="2" Margin="0,0,16,0">
                <TextBlock Text="Apply To" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                <ComboBox Name="TargetBox" FontSize="13.5"/>
            </StackPanel>

            <StackPanel Grid.Column="3" Margin="0,0,16,0">
                <TextBlock Text="Style" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                <ComboBox Name="StyleBox" FontSize="13.5"/>
            </StackPanel>

            <StackPanel Grid.Column="4">
                <TextBlock Text="Save Image To" HorizontalAlignment="Left" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                <TextBox Name="FolderBox" Height="38" HorizontalAlignment="Stretch" FontSize="13.5" IsReadOnly="True" Cursor="Hand" ToolTip="Click to change save folder" />
            </StackPanel>
        </Grid>

        <!-- Smooth Modern Gallery Container -->
        <Border Grid.Row="2" Background="Transparent" CornerRadius="18" BorderThickness="0" ClipToBounds="True">
            <ScrollViewer Margin="0,16,0,16" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" FocusVisualStyle="{x:Null}">
                <UniformGrid Name="GalleryPanel" Columns="4" VerticalAlignment="Top" />
            </ScrollViewer>
        </Border>

        <!-- Footer / Action Area -->
        <Grid Grid.Row="3" Margin="0,28,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Name="StatusText" Text="" Foreground="#888" FontSize="14" FontWeight="Medium" VerticalAlignment="Center" TextWrapping="Wrap"/>
            
            <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button Name="CheckUpdateBtn" Width="165" Height="46" Margin="0,0,12,0" Background="#262626" Foreground="#E0E0E0" FontSize="15" FontWeight="SemiBold" ToolTip="Check GitHub for a verified app update">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Center">
                        <Ellipse Name="UpdateBadgeDot" Width="8" Height="8" Fill="#EF4444" Margin="0,0,8,0" VerticalAlignment="Center" Visibility="Collapsed"/>
                        <TextBlock Name="CheckUpdateBtnText" Text="Check for updates" VerticalAlignment="Center"/>
                    </StackPanel>
                </Button>
                <Button Name="DownloadBtn" Content="Download" Width="130" Height="46" Margin="0,0,12,0" Background="#262626" Foreground="#E0E0E0" FontSize="15" FontWeight="SemiBold" ToolTip="Save selected image to your download folder" />
                <Button Name="UpdateBtn" Content="Apply" Width="140" Height="46" Background="#0078D4" Foreground="White" FontSize="15" FontWeight="SemiBold" ToolTip="Set selected wallpaper directly" />
            </StackPanel>
        </Grid>
    </Grid>
</Window>
"@

$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

#TEST

# --- Global Reveal Highlight System ---
$script:revealElements = New-Object System.Collections.ArrayList

function Find-RevealBorders($visual) {
    if ($visual -is [System.Windows.Controls.Border] -and $visual.Name -eq "RevealBorder") {
        $revealBrush = New-Object System.Windows.Media.RadialGradientBrush
        $revealBrush.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(60, 255, 255, 255), 0.0)))
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, 255, 255, 255), 1.0)))
        $revealBrush.RadiusX = 160
        $revealBrush.RadiusY = 160
        $visual.BorderBrush = $revealBrush
        $script:revealElements.Add(@{ Element = $visual; Brush = $revealBrush }) | Out-Null
    }
    
    $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($visual)
    for ($i = 0; $i -lt $count; $i++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($visual, $i)
        Find-RevealBorders $child
    }
}

$window.Add_Loaded({
        Find-RevealBorders $window
        Start-BackgroundUpdateCheck

        # Automatically trim working set memory once startup and gallery render settles
        $idleFlush = New-Object System.Windows.Threading.DispatcherTimer
        $idleFlush.Interval = [TimeSpan]::FromSeconds(2.5)
        $idleFlush.Add_Tick({
            $idleFlush.Stop()
            [BingWallpaperNative]::FlushMemory()
        })
        $idleFlush.Start()
    })

$window.Add_MouseMove({
        param($evtSender, $e)
        foreach ($item in $script:revealElements) {
            try {
                $pos = $e.GetPosition($item.Element)
                $item.Brush.Center = $pos
                $item.Brush.GradientOrigin = $pos
            }
            catch {}
        }
    })
# --------------------------------------

# Ensure the app doesn't group with powershell.exe in the taskbar
try {
    $code = @'
    using System.Runtime.InteropServices;
    public class AppUserModel {
        [DllImport("shell32.dll", SetLastError = true)]
        public static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
    }
'@
    Add-Type -TypeDefinition $code -IgnoreWarnings
    [AppUserModel]::SetCurrentProcessExplicitAppUserModelID("BingWallpaper.App")
}
catch {}

# Set authentic Bing icon for window titlebar and taskbar
$exeDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$iconCandidates = @(
    (Join-Path $exeDir 'assets\bing.ico'),
    (Join-Path $exeDir 'bing.ico'),
    (Join-Path $scriptDir 'assets\bing.ico'),
    (Join-Path $scriptDir 'bing.ico')
)

$script:taskbarIconPath = $null
foreach ($iconPath in $iconCandidates) {
    if (Test-Path -LiteralPath $iconPath) {
        try {
            $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([System.Uri]::new((Resolve-Path -LiteralPath $iconPath).Path))
            $script:taskbarIconPath = (Resolve-Path -LiteralPath $iconPath).Path
            break
        }
        catch {}
    }
}

# Apply Windows 11 modern dark title bar, rounded corners, and seamless caption color
$applyDarkTitleBar = {
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        if ($helper.Handle -ne [IntPtr]::Zero) {
            # 0x00121212 matches the #121212 dark background seamlessly
            [BingWallpaperNative]::EnableDarkTitleBar($helper.Handle, -1)
            
            # Make WPF background transparent to allow Mica/Acrylic to show through
            $margins = New-Object BingWallpaperNative+MARGINS
            $margins.cxLeftWidth = -1
            $margins.cxRightWidth = -1
            $margins.cyTopHeight = -1
            $margins.cyBottomHeight = -1
            $null = [BingWallpaperNative]::DwmExtendFrameIntoClientArea($helper.Handle, [ref]$margins)

            $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($helper.Handle)
            if ($hwndSource -and $hwndSource.CompositionTarget) {
                $hwndSource.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
            }
        }
    }
    catch {}
}

$window.Add_SourceInitialized($applyDarkTitleBar)
$helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
$null = $helper.EnsureHandle()
& $applyDarkTitleBar


# ---------------------------------------------------------
# Settings Persistence
# ---------------------------------------------------------
$script:settingsPath = Join-Path $env:LOCALAPPDATA 'BingWallpaper\settings.json'

function Load-Settings {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param()
    if (Test-Path -LiteralPath $script:settingsPath) {
        try {
            return (Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json)
        }
        catch {}
    }
    return @{
        Region     = "auto"
        Resolution = "1920x1080"
        Target     = "Both"
        Style      = (Get-CurrentDesktopWallpaperStyle)
        SaveFolder = (Join-Path $env:USERPROFILE 'Pictures\BingWallpapers')
    }
}

function Save-Settings {
    try {
        $settingsObj = @{
            Region     = if ($RegionBox.SelectedItem) { $RegionBox.SelectedItem.Tag } else { "auto" }
            Resolution = if ($ResolutionBox.SelectedItem) { $ResolutionBox.SelectedItem } else { "1920x1080" }
            Target     = if ($TargetBox.SelectedItem) { $TargetBox.SelectedItem } else { "Both" }
            Style      = if ($StyleBox.SelectedItem) { $StyleBox.SelectedItem } else { "Fit" }
            SaveFolder = $FolderBox.Text
        }
        $dir = Split-Path -Parent $script:settingsPath
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $settingsObj | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $script:settingsPath
    }
    catch {}
}

$script:appSettings = Load-Settings

# Map UI elements
$RegionBox = $window.FindName('RegionBox')
$ResolutionBox = $window.FindName('ResolutionBox')
$TargetBox = $window.FindName('TargetBox')
$StyleBox = $window.FindName('StyleBox')
$FolderBox = $window.FindName('FolderBox')
$RefreshBtn = $window.FindName('RefreshBtn')
$RefreshIcon = $window.FindName('RefreshIcon')
$GalleryPanel = $window.FindName('GalleryPanel')
$StatusText = $window.FindName('StatusText')
$CheckUpdateBtn = $window.FindName('CheckUpdateBtn')
$UpdateBadgeDot = $window.FindName('UpdateBadgeDot')
$CheckUpdateBtnText = $window.FindName('CheckUpdateBtnText')
$DownloadBtn = $window.FindName('DownloadBtn')
$UpdateBtn = $window.FindName('UpdateBtn')

# Helper to force UI redraw during blocking network calls
function Update-UI {
    $dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
}

# Run the visual feedback before the synchronous gallery work starts. WPF owns
# the animation clock, so this needs no timer, polling loop, or background worker.
function Start-RefreshAnimation {
    if (-not $RefreshIcon) { return }

    $rotation = [System.Windows.Media.RotateTransform]$RefreshIcon.RenderTransform
    $spin = New-Object System.Windows.Media.Animation.DoubleAnimation
    $spin.From = 0
    $spin.To = 360
    $spin.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(560))
    $spin.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($spin, 60)
    $rotation.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $spin, [System.Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace)

    # PowerShell does not consistently deliver WPF animation Completed callbacks.
    # Use one dispatcher tick to start the reload after the visual feedback ends.
    $script:refreshDelayTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:refreshDelayTimer.Interval = [TimeSpan]::FromMilliseconds(560)
    $script:refreshDelayTimer.Add_Tick({
            $script:refreshDelayTimer.Stop()
            $script:refreshDelayTimer = $null
            $finishedRotation = [System.Windows.Media.RotateTransform]$RefreshIcon.RenderTransform
            $finishedRotation.Angle = 0
            try {
                Load-Gallery
            }
            finally {
                $script:isRefreshAnimating = $false
                $RefreshBtn.IsEnabled = $true
            }
        })
    $script:refreshDelayTimer.Start()
}

# Populate Settings (Alphabetically sorted, Auto pinned at top)
$countries = @(
    @{ Name = "Auto (Global)"; Code = "auto" },
    @{ Name = "Arab Region"; Code = "ar-XA" },
    @{ Name = "Argentina"; Code = "es-AR" },
    @{ Name = "Australia"; Code = "en-AU" },
    @{ Name = "Austria"; Code = "de-AT" },
    @{ Name = "Belgium (Dutch)"; Code = "nl-BE" },
    @{ Name = "Belgium (French)"; Code = "fr-BE" },
    @{ Name = "Brazil"; Code = "pt-BR" },
    @{ Name = "Bulgaria"; Code = "bg-BG" },
    @{ Name = "Canada (English)"; Code = "en-CA" },
    @{ Name = "Canada (French)"; Code = "fr-CA" },
    @{ Name = "Chile"; Code = "es-CL" },
    @{ Name = "China"; Code = "zh-CN" },
    @{ Name = "Croatia"; Code = "hr-HR" },
    @{ Name = "Czech Republic"; Code = "cs-CZ" },
    @{ Name = "Denmark"; Code = "da-DK" },
    @{ Name = "Estonia"; Code = "et-EE" },
    @{ Name = "Finland"; Code = "fi-FI" },
    @{ Name = "France"; Code = "fr-FR" },
    @{ Name = "Germany"; Code = "de-DE" },
    @{ Name = "Greece"; Code = "el-GR" },
    @{ Name = "Hong Kong"; Code = "zh-HK" },
    @{ Name = "Hungary"; Code = "hu-HU" },
    @{ Name = "India"; Code = "en-IN" },
    @{ Name = "Indonesia"; Code = "en-ID" },
    @{ Name = "Israel"; Code = "he-IL" },
    @{ Name = "Italy"; Code = "it-IT" },
    @{ Name = "Japan"; Code = "ja-JP" },
    @{ Name = "Latvia"; Code = "lv-LV" },
    @{ Name = "Lithuania"; Code = "lt-LT" },
    @{ Name = "Malaysia"; Code = "en-MY" },
    @{ Name = "Mexico"; Code = "es-MX" },
    @{ Name = "Netherlands"; Code = "nl-NL" },
    @{ Name = "New Zealand"; Code = "en-NZ" },
    @{ Name = "Norway"; Code = "nb-NO" },
    @{ Name = "Philippines"; Code = "en-PH" },
    @{ Name = "Poland"; Code = "pl-PL" },
    @{ Name = "Portugal"; Code = "pt-PT" },
    @{ Name = "Romania"; Code = "ro-RO" },
    @{ Name = "Russia"; Code = "ru-RU" },
    @{ Name = "Singapore"; Code = "en-SG" },
    @{ Name = "Slovakia"; Code = "sk-SK" },
    @{ Name = "Slovenia"; Code = "sl-SI" },
    @{ Name = "South Korea"; Code = "ko-KR" },
    @{ Name = "Spain"; Code = "es-ES" },
    @{ Name = "Sweden"; Code = "sv-SE" },
    @{ Name = "Switzerland (French)"; Code = "fr-CH" },
    @{ Name = "Switzerland (German)"; Code = "de-CH" },
    @{ Name = "Taiwan"; Code = "zh-TW" },
    @{ Name = "Thailand"; Code = "th-TH" },
    @{ Name = "Turkey"; Code = "tr-TR" },
    @{ Name = "Ukraine"; Code = "uk-UA" },
    @{ Name = "United Kingdom"; Code = "en-GB" },
    @{ Name = "United States"; Code = "en-US" },
    @{ Name = "Vietnam"; Code = "vi-VN" }
)

$countries = @($countries[0]) + @($countries | Select-Object -Skip 1 | Sort-Object -Property { $_.Name })

$RegionBox.SelectedIndex = 0
foreach ($c in $countries) {
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $c.Name
    $item.Tag = $c.Code
    [void]$RegionBox.Items.Add($item)
    if ($c.Code -eq $script:appSettings.Region) {
        $RegionBox.SelectedItem = $item
    }
}

function Get-SelectedRegionCode {
    if ($RegionBox.SelectedItem -and $RegionBox.SelectedItem.Tag) {
        return $RegionBox.SelectedItem.Tag
    }
    return 'en-US'
}

@('4K', '2K', '1080p', '720p') | ForEach-Object { 
    [void]$ResolutionBox.Items.Add($_)
    if ($_ -eq $script:appSettings.Resolution -or 
        ($_ -eq '4K' -and $script:appSettings.Resolution -match '4K|UHD') -or
        ($_ -eq '2K' -and $script:appSettings.Resolution -match '2K|1440') -or
        ($_ -eq '1080p' -and $script:appSettings.Resolution -match '1080') -or
        ($_ -eq '720p' -and $script:appSettings.Resolution -match '720|1366|768')) { 
        $ResolutionBox.SelectedItem = $_ 
    }
}
if (-not $ResolutionBox.SelectedItem) { $ResolutionBox.SelectedIndex = 0 }

@('Desktop', 'Lock screen', 'Both') | ForEach-Object { 
    [void]$TargetBox.Items.Add($_)
    if ($_ -eq $script:appSettings.Target) { $TargetBox.SelectedItem = $_ }
}
if (-not $TargetBox.SelectedItem) { $TargetBox.SelectedIndex = 2 }

@('Fit', 'Fill', 'Stretch', 'Center', 'Tile', 'Span') | ForEach-Object { 
    [void]$StyleBox.Items.Add($_)
    if ($_ -eq $script:appSettings.Style) { $StyleBox.SelectedItem = $_ }
}
if (-not $StyleBox.SelectedItem) { 
    $detectedStyle = Get-CurrentDesktopWallpaperStyle
    if ($StyleBox.Items -contains $detectedStyle) {
        $StyleBox.SelectedItem = $detectedStyle
    }
    else {
        $StyleBox.SelectedItem = 'Fit'
    }
}

if ($script:appSettings.SaveFolder) {
    $FolderBox.Text = $script:appSettings.SaveFolder
}
else {
    $FolderBox.Text = Get-DownloadFolder
}

# Attach Settings Auto-Save listeners
$saveHandler = { Save-Settings }
$RegionBox.Add_SelectionChanged($saveHandler)
$ResolutionBox.Add_SelectionChanged($saveHandler)
$TargetBox.Add_SelectionChanged($saveHandler)
$StyleBox.Add_SelectionChanged($saveHandler)
$FolderBox.Add_TextChanged($saveHandler)

# Browse Folder Logic
# Browse Folder Logic (modern Windows 11 dark-mode folder picker)
$FolderBox.Add_PreviewMouseLeftButtonDown({
        $picked = $null
        $modernFailed = $false

        try {
            # Modern common folder dialog (IFileOpenDialog under the hood)
            $dialog = New-Object Microsoft.Win32.OpenFolderDialog
            $dialog.Title = 'Select Save Folder'
            if (Test-Path -LiteralPath $FolderBox.Text) {
                $dialog.InitialDirectory = $FolderBox.Text
            }

            # Ask Windows to render Win32 common dialogs in dark mode...
            [BingWallpaperNative]::EnableDarkDialogs()

            # ...and keep it dark while open (backstop for builds where the
            # app-mode APIs are unavailable). WPF's modal loop keeps
            # DispatcherTimers running, so this fires while ShowDialog() blocks.
            $darkTimer = New-Object System.Windows.Threading.DispatcherTimer
            $darkTimer.Interval = [TimeSpan]::FromMilliseconds(30)
            $darkTimer.Add_Tick({
                    $hwnd = [BingWallpaperNative]::ForegroundWindow()
                    if ($hwnd -ne [IntPtr]::Zero -and [BingWallpaperNative]::IsDialogWindow($hwnd)) {
                        [BingWallpaperNative]::ForceDarkDialog($hwnd)
                    }
                })

            $darkTimer.Start()
            try {
                if ($dialog.ShowDialog($window) -eq $true) {
                    $picked = $dialog.FolderName
                }
            }
            finally {
                $darkTimer.Stop()
            }
        }
        catch {
            # OpenFolderDialog missing (very old .NET) -> legacy fallback below
            $modernFailed = $true
        }

        if ($modernFailed) {
            $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
            $legacyRes = [BingWallpaperNative]::PickFolder($helper.Handle, 'Select Save Folder')
            if (-not [string]::IsNullOrEmpty($legacyRes)) {
                $picked = $legacyRes
            }
        }

        if ($picked) {
            $FolderBox.Text = $picked
        }
    })
# Selection tracking & palette
$script:selection = @{
    Card  = $null
    Image = $null
}

$cardUnselectedBg = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(140, 10, 12, 18)))
$cardHoverBg = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(190, 20, 22, 30)))

function Get-ImageAccentBrush([string]$imagePath) {
    $bitmap = $null
    try {
        $bitmap = [System.Drawing.Bitmap]::new($imagePath)
        $sampleWidth = [Math]::Min(32, $bitmap.Width)
        $sampleHeight = [Math]::Min(32, $bitmap.Height)
        if ($sampleWidth -lt 1 -or $sampleHeight -lt 1) { throw 'Image has no pixels' }

        $redTotal = 0.0
        $greenTotal = 0.0
        $blueTotal = 0.0
        $weightTotal = 0.0
        for ($y = 0; $y -lt $sampleHeight; $y++) {
            for ($x = 0; $x -lt $sampleWidth; $x++) {
                $pixel = $bitmap.GetPixel([int](($x / $sampleWidth) * $bitmap.Width), [int](($y / $sampleHeight) * $bitmap.Height))
                $red = $pixel.R
                $green = $pixel.G
                $blue = $pixel.B
                $maximum = [Math]::Max($red, [Math]::Max($green, $blue))
                $minimum = [Math]::Min($red, [Math]::Min($green, $blue))
                $weight = 1.0 + ((($maximum - $minimum) / 255.0) * 2.0)
                $redTotal += $red * $weight
                $greenTotal += $green * $weight
                $blueTotal += $blue * $weight
                $weightTotal += $weight
            }
        }

        $red = [Math]::Min(190, [int]($redTotal / $weightTotal * 1.35))
        $green = [Math]::Min(190, [int]($greenTotal / $weightTotal * 1.35))
        $blue = [Math]::Min(190, [int]($blueTotal / $weightTotal * 1.35))
        return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(235, $red, $green, $blue))
    }
    catch {
        return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(235, 70, 70, 70))
    }
    finally {
        if ($bitmap) { $bitmap.Dispose() }
    }
}

function Get-AccentTextBrush($accentBrush, [byte]$alpha = 255) {
    if (-not $accentBrush) {
        return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb($alpha, 255, 255, 255))
    }

    $color = $accentBrush.Color
    $brightness = (0.299 * $color.R) + (0.587 * $color.G) + (0.114 * $color.B)
    if ($brightness -gt 145) {
        return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb($alpha, 18, 18, 18))
    }
    return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb($alpha, 255, 255, 255))
}

function Set-CardAccent($card, $accentBrush) {
    if (-not $card -or -not $accentBrush) { return }

    $fromColor = [System.Windows.Media.Color]::FromRgb(10, 12, 18)
    if ($card.Background -is [System.Windows.Media.SolidColorBrush]) {
        $fromColor = $card.Background.Color
    }

    $animatedBrush = New-Object System.Windows.Media.SolidColorBrush($fromColor)
    $card.Background = $animatedBrush
    $animation = New-Object System.Windows.Media.Animation.ColorAnimation
    $animation.From = $fromColor
    $animation.To = $accentBrush.Color
    $animation.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220))
    $animation.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
    $animation.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $animatedBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $animation)
}

function Select-Card($card, $image) {
    if ($script:selectedCard -and $script:selectedCard -ne $card) {
        $script:selectedCard.Background = $cardUnselectedBg
        $script:selectedCard.Resources['TitleText'].Foreground = [System.Windows.Media.Brushes]::White
        $script:selectedCard.Resources['DateText'].Foreground = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(160, 160, 160)))
    }
    $script:selectedCard = $card
    $script:selectedImage = $image
    $script:selection.Card = $card
    $script:selection.Image = $image
    if ($card) {
        $accentBrush = $card.Resources['ImageAccentBrush']
        Set-CardAccent $card $accentBrush
        $card.Resources['TitleText'].Foreground = Get-AccentTextBrush $accentBrush
        $card.Resources['DateText'].Foreground = Get-AccentTextBrush $accentBrush 205
    }
}

# Transient Status Message System (Auto-resets after N seconds)
$statusDefaultBrush = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(136, 136, 136)))
$statusSuccessBrush = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(52, 211, 153)))
$statusErrorBrush = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(248, 113, 113)))
$script:statusResetTimer = $null

function Get-AppliedSuccessMessage([string]$target) {
    switch ($target) {
        'Desktop' { return "Success! Wallpaper applied to background" }
        'Lock screen' { return "Success! Wallpaper applied to Lockscreen" }
        'Both' { return "Success! Wallpaper applied to background and Lockscreen" }
        Default { return "Success! Wallpaper applied to $target" }
    }
}

function Set-TransientStatus {
    param(
        [string]$Message,
        [System.Windows.Media.Brush]$Brush = $statusSuccessBrush,
        [double]$Seconds = 3.0
    )
    if ($script:statusResetTimer) {
        $script:statusResetTimer.Stop()
    }
    
    $StatusText.Foreground = $Brush
    $StatusText.Text = $Message
    $StatusText.Opacity = 1.0

    $script:statusResetTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:statusResetTimer.Interval = [TimeSpan]::FromSeconds($Seconds)
    $script:statusResetTimer.Add_Tick({
        $script:statusResetTimer.Stop()
        
        # Smooth fade transition
        $duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(300))
        $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, $duration)
        $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, $duration)
        
        $fadeOut.Add_Completed({
            $StatusText.Foreground = $statusDefaultBrush
            $StatusText.Text = 'Double-click any wallpaper to apply'
            $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)
        })
        $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeOut)
    })
    $script:statusResetTimer.Start()
}

function Get-ReleaseVersion {
    param(
        [string]$TagName,
        [string]$ReleaseName = '',
        [string]$ReleaseBody = ''
    )

    # 1. Try TagName (e.g. v1.0.0, 1.0.0)
    $cleanTag = ($TagName -replace '^[vV]', '').Trim()
    if ($cleanTag -match '^\d+(\.\d+){1,3}$') {
        return [Version]$cleanTag
    }

    # 2. Try ReleaseName (e.g. "Bing Wallpaper v1.0.0" or "Bing Wallpaper 1.0.0")
    if ($ReleaseName -match '[vV]?(\d+\.\d+(\.\d+){0,2})') {
        $v = $Matches[1]
        if ($v -notmatch '\.') { $v = "$v.0" }
        if ($v -match '^\d+(\.\d+){1,3}$') {
            return [Version]$v
        }
    }

    # 3. Try ReleaseBody
    if ($ReleaseBody -match '[vV]?(\d+\.\d+(\.\d+){0,2})') {
        $v = $Matches[1]
        if ($v -notmatch '\.') { $v = "$v.0" }
        if ($v -match '^\d+(\.\d+){1,3}$') {
            return [Version]$v
        }
    }

    throw "Release tag '$TagName' is not a supported version number. Releases should use tags such as v1.2.3."
}

function Invoke-GitHubApiJson([string]$Uri) {
    try {
        return Invoke-RestMethod -Uri $Uri -Headers @{ 'User-Agent' = 'BingWallpaper-Updater' } -UseBasicParsing -ErrorAction Stop
    }
    catch {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'BingWallpaper-Updater')
        return $wc.DownloadString($Uri) | ConvertFrom-Json
    }
}

function Show-ModernDialog {
    param(
        [string]$Title = 'Bing Wallpaper',
        [string]$Header = 'Bing Wallpaper',
        [string]$Message = '',
        [ValidateSet('Info', 'Update', 'Error', 'Success')]
        [string]$Icon = 'Info',
        [ValidateSet('OK', 'YesNo')]
        [string]$Buttons = 'OK',
        [System.Windows.Window]$ParentWindow = $window
    )

    $dialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="430" SizeToContent="Height"
        Background="#181818" Foreground="#F0F0F0" FontFamily="Segoe UI"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        ResizeMode="NoResize" WindowStyle="SingleBorderWindow">
    <Window.Resources>
        <Style x:Key="DialogBtn" TargetType="Button">
            <Setter Property="Height" Value="36"/>
            <Setter Property="MinWidth" Value="100"/>
            <Setter Property="FontSize" Value="13.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="BtnBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="16,6,16,6"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BtnBorder" Property="Opacity" Value="0.88"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BtnBorder" Property="Opacity" Value="0.75"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border Padding="24" Background="#181818">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Header with Badge Icon -->
            <Grid Grid.Row="0" Margin="0,0,0,20">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <Border Name="BadgeBorder" Width="44" Height="44" CornerRadius="22" Margin="0,0,16,0" VerticalAlignment="Top">
                    <Path Name="BadgePath" HorizontalAlignment="Center" VerticalAlignment="Center" Stretch="Uniform" Width="20" Height="20"/>
                </Border>

                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock Name="DialogHeader" FontSize="16.5" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,4" TextWrapping="Wrap"/>
                    <TextBlock Name="DialogMessage" FontSize="13.5" Foreground="#BBBBBB" TextWrapping="Wrap" LineHeight="20"/>
                </StackPanel>
            </Grid>

            <!-- Action Buttons Panel -->
            <StackPanel Name="ButtonPanel" Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,4,0,0"/>
        </Grid>
    </Border>
</Window>
"@

    $stringReader = New-Object System.IO.StringReader $dialogXaml
    $xmlReader = [System.Xml.XmlReader]::Create($stringReader)
    $dlg = [System.Windows.Markup.XamlReader]::Load($xmlReader)
    $xmlReader.Close()
    $stringReader.Close()
    if ($ParentWindow) { $dlg.Owner = $ParentWindow }

    # Set authentic Bing icon for dialog titlebar
    if ($window -and $window.Icon) {
        $dlg.Icon = $window.Icon
    }
    elseif ($script:taskbarIconPath -and (Test-Path -LiteralPath $script:taskbarIconPath)) {
        try {
            $dlg.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([System.Uri]::new($script:taskbarIconPath))
        } catch {}
    }

    # Enable native Windows 11 dark title bar for dialog
    $dlg.Add_SourceInitialized({
        try {
            $helper = New-Object System.Windows.Interop.WindowInteropHelper($dlg)
            if ($helper.Handle -ne [IntPtr]::Zero) {
                [BingWallpaperNative]::EnableDarkTitleBar($helper.Handle, 0x00181818)
            }
        } catch {}
    })

    $badgeBorder = $dlg.FindName('BadgeBorder')
    $badgePath = $dlg.FindName('BadgePath')
    $dialogHeader = $dlg.FindName('DialogHeader')
    $dialogMessage = $dlg.FindName('DialogMessage')
    $buttonPanel = $dlg.FindName('ButtonPanel')

    $dialogHeader.Text = $Header
    $dialogMessage.Text = $Message

    # Configure Icon & Colors
    switch ($Icon) {
        'Update' {
            $badgeBorder.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 16, 52, 88))
            $badgePath.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 56, 189, 248))
            $badgePath.Data = [System.Windows.Media.Geometry]::Parse("M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM17 13l-5 5-5-5h3V9h4v4h3z")
        }
        'Success' {
            $badgeBorder.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 16, 60, 36))
            $badgePath.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 74, 222, 128))
            $badgePath.Data = [System.Windows.Media.Geometry]::Parse("M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z")
        }
        'Error' {
            $badgeBorder.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 68, 24, 24))
            $badgePath.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 248, 113, 113))
            $badgePath.Data = [System.Windows.Media.Geometry]::Parse("M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z")
        }
        Default { # Info
            $badgeBorder.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 18, 48, 76))
            $badgePath.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 96, 165, 250))
            $badgePath.Data = [System.Windows.Media.Geometry]::Parse("M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z")
        }
    }

    $script:dialogChoice = 'Cancel'
    $btnStyle = $dlg.FindResource('DialogBtn')

    if ($Buttons -eq 'YesNo') {
        $btnNo = New-Object System.Windows.Controls.Button
        $btnNo.Style = $btnStyle
        $btnNo.Content = 'Not Now'
        $btnNo.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 42, 42, 42))
        $btnNo.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 220, 220, 220))
        $btnNo.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 60, 60, 60))
        $btnNo.BorderThickness = New-Object System.Windows.Thickness(1)
        $btnNo.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
        $btnNo.Add_Click({
            $script:dialogChoice = 'No'
            $dlg.Close()
        })
        $buttonPanel.Children.Add($btnNo) | Out-Null

        $btnYes = New-Object System.Windows.Controls.Button
        $btnYes.Style = $btnStyle
        $btnYes.Content = 'Update Now'
        $btnYes.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 0, 120, 212))
        $btnYes.Foreground = [System.Windows.Media.Brushes]::White
        $btnYes.BorderThickness = New-Object System.Windows.Thickness(0)
        $btnYes.IsDefault = $true
        $btnYes.Add_Click({
            $script:dialogChoice = 'Yes'
            $dlg.Close()
        })
        $buttonPanel.Children.Add($btnYes) | Out-Null
    }
    else {
        $btnOk = New-Object System.Windows.Controls.Button
        $btnOk.Style = $btnStyle
        $btnOk.Content = 'OK'
        $btnOk.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 0, 120, 212))
        $btnOk.Foreground = [System.Windows.Media.Brushes]::White
        $btnOk.BorderThickness = New-Object System.Windows.Thickness(0)
        $btnOk.IsDefault = $true
        $btnOk.Add_Click({
            $script:dialogChoice = 'OK'
            $dlg.Close()
        })
        $buttonPanel.Children.Add($btnOk) | Out-Null
    }

    $dlg.ShowDialog() | Out-Null
    return $script:dialogChoice
}

function Set-UpdateButtonState {
    param(
        [bool]$HasUpdate,
        [Version]$NewVersion = $null
    )
    if ($HasUpdate) {
        if ($UpdateBadgeDot) { $UpdateBadgeDot.Visibility = [System.Windows.Visibility]::Visible }
        if ($CheckUpdateBtnText) { $CheckUpdateBtnText.Text = 'Update Now' }
        if ($CheckUpdateBtn) {
            $CheckUpdateBtn.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 45, 26, 32))
            $CheckUpdateBtn.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(180, 239, 68, 68))
            $verText = if ($NewVersion) { "Version $NewVersion is available! " } else { "" }
            $CheckUpdateBtn.ToolTip = "${verText}Click to update now."
        }
    }
    else {
        if ($UpdateBadgeDot) { $UpdateBadgeDot.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($CheckUpdateBtnText) { $CheckUpdateBtnText.Text = 'Check for updates' }
        if ($CheckUpdateBtn) {
            $CheckUpdateBtn.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 38, 38, 38))
            $CheckUpdateBtn.BorderBrush = [System.Windows.Media.Brushes]::Transparent
            $CheckUpdateBtn.ToolTip = 'Check GitHub for a verified app update'
        }
    }
}

function Get-OnlineLatestVersion {
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'BingWallpaper-Updater')
    
    # 1. Direct CDN fetch with ZERO rate limits
    try {
        $rawContent = $wc.DownloadString("https://raw.githubusercontent.com/$($script:updateRepository)/main/Bing-Wallpaper-UI.ps1")
        if ($rawContent -match '\$script:appVersion\s*=\s*\[Version\][''"]([^''"]+)[''"]') {
            return [Version]$Matches[1]
        }
    } catch {}

    # 2. Redirect tag inspection fallback
    try {
        $req = [System.Net.HttpWebRequest]::Create("https://github.com/$($script:updateRepository)/releases/latest")
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'BingWallpaper-Updater'
        $res = $req.GetResponse()
        $loc = $res.Headers['Location']
        $res.Dispose()
        if ($loc) {
            $tag = Split-Path -Leaf $loc
            $v = Get-ReleaseVersion -TagName $tag
            if ($v) { return $v }
        }
    } catch {}

    return $null
}

function Start-BackgroundUpdateCheck {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'BingWallpaper-Updater')

        $wc.Add_DownloadStringCompleted({
            param($sender, $e)
            try {
                if (-not $e.Error -and $e.Result) {
                    if ($e.Result -match '\$script:appVersion\s*=\s*\[Version\][''"]([^''"]+)[''"]') {
                        $v = [Version]$Matches[1]
                        if ($v -gt $script:appVersion) {
                            Set-UpdateButtonState -HasUpdate $true -NewVersion $v
                            return
                        }
                    }
                }
            } catch {}
            finally {
                $sender.Dispose()
                [BingWallpaperNative]::FlushMemory()
            }
            Set-UpdateButtonState -HasUpdate $false
        })

        $wc.DownloadStringAsync([System.Uri]::new("https://raw.githubusercontent.com/$($script:updateRepository)/main/Bing-Wallpaper-UI.ps1"))
    }
    catch {}
}

function Start-VerifiedUpdate {
    $CheckUpdateBtn.IsEnabled = $false
    $StatusText.Foreground = $statusDefaultBrush
    $StatusText.Text = 'Checking for updates...'
    Update-UI

    try {
        $latestVersion = Get-OnlineLatestVersion
        if (-not $latestVersion) {
            throw "Unable to connect to GitHub update server. Please check your network connection."
        }

        if ($latestVersion -le $script:appVersion) {
            Set-UpdateButtonState -HasUpdate $false
            Show-ModernDialog -Title "Bing Wallpaper" -Header "You're all up to date" -Message "You already have the latest version ($($script:appVersion))." -Icon "Success" -Buttons "OK" | Out-Null
            Set-TransientStatus -Message 'You are up to date.' -Brush $statusSuccessBrush -Seconds 3.0
            return
        }

        Set-UpdateButtonState -HasUpdate $true -NewVersion $latestVersion

        $confirmation = Show-ModernDialog -Title "Update Available" -Header "Version $latestVersion is Available" -Message "Would you like to install and restart now?" -Icon "Update" -Buttons "YesNo"
        if ($confirmation -ne 'Yes') {
            Set-TransientStatus -Message 'Update cancelled.' -Brush $statusDefaultBrush -Seconds 2.5
            return
        }

        $exeDownloadUrl = "https://github.com/$($script:updateRepository)/releases/latest/download/BingWallpaper.exe"
        $shaDownloadUrl = "https://github.com/$($script:updateRepository)/releases/latest/download/BingWallpaper.exe.sha256"

        $StatusText.Text = "Downloading version $latestVersion..."
        Update-UI
        $downloadPath = Join-Path $env:TEMP "BingWallpaper-$latestVersion-$([Guid]::NewGuid().ToString('N')).exe"
        
        $client = New-Object System.Net.WebClient
        $client.Headers.Add('User-Agent', 'BingWallpaper-Updater')
        $client.DownloadFile($exeDownloadUrl, $downloadPath)

        # Extract SHA-256 hash from checksum file
        $expectedHash = $null
        try {
            $checksumText = $client.DownloadString($shaDownloadUrl)
            $expectedHash = [regex]::Match($checksumText, '(?im)\b[a-f0-9]{64}\b').Value.ToUpperInvariant()
        } catch {}

        if ($expectedHash) {
            $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($actualHash -ne $expectedHash) {
                Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
                throw 'The downloaded update did not match the published SHA-256 checksum.'
            }
        }

        if ($script:updatePublisherThumbprint) {
            $signature = Get-AuthenticodeSignature -FilePath $downloadPath
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $script:updatePublisherThumbprint) {
                Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
                throw 'The update does not have the expected valid Authenticode signature.'
            }
        }

        $exeCandidates = @(
            (Join-Path ([Environment]::CurrentDirectory) 'BingWallpaper.exe'),
            (Join-Path (Get-Location).Path 'BingWallpaper.exe'),
            (Join-Path $PSScriptRoot 'BingWallpaper.exe'),
            (Join-Path (Split-Path -Parent $PSScriptRoot) 'BingWallpaper.exe')
        )
        $installedExe = $exeCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

        if (-not $installedExe -or -not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
            throw 'The installed BingWallpaper.exe could not be found. Run updates from the installed app, not the source script.'
        }

        # Clear temp cache before launching updater
        Remove-Item -LiteralPath (Join-Path $env:TEMP 'BingWallpaper') -Recurse -Force -ErrorAction SilentlyContinue

        $updaterPath = Join-Path $env:TEMP "BingWallpaper-Updater-$([Guid]::NewGuid().ToString('N')).ps1"
        $updaterScript = @'
param(
    [int]$ParentProcessId,
    [string]$DownloadedExe,
    [string]$InstalledExe
)

try { (Get-Process -Id $ParentProcessId -ErrorAction Stop).WaitForExit() } catch {}
$tempDir = Join-Path $env:TEMP "BingWallpaper"
Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue

for ($attempt = 0; $attempt -lt 15; $attempt++) {
    try {
        Copy-Item -LiteralPath $DownloadedExe -Destination $InstalledExe -Force -ErrorAction Stop
        Remove-Item -LiteralPath $DownloadedExe -Force -ErrorAction SilentlyContinue
        Start-Process -FilePath $InstalledExe -WorkingDirectory (Split-Path -Parent $InstalledExe)
        break
    }
    catch {
        Start-Sleep -Milliseconds 500
    }
}
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
'@
        Set-Content -LiteralPath $updaterPath -Value $updaterScript -Encoding UTF8
        $updaterArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$updaterPath`" -ParentProcessId $PID -DownloadedExe `"$downloadPath`" -InstalledExe `"$installedExe`""
        Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $updaterArgs -WindowStyle Hidden

        $StatusText.Text = 'Verified update downloaded. Restarting...'
        $window.Close()
    }
    catch {
        $StatusText.Foreground = $statusErrorBrush
        $StatusText.Text = "Update failed: $($_.Exception.Message)"
        Show-ModernDialog -Title "Update Error" -Header "Update Check Failed" -Message "$($_.Exception.Message)" -Icon "Error" -Buttons "OK" | Out-Null
    }
    finally {
        if ($client) { $client.Dispose() }
        $CheckUpdateBtn.IsEnabled = $true
    }
}

function Show-GalleryCard {
    param([System.Windows.Controls.Border]$Card)

    # Native WPF transforms keep card arrivals smooth without layout work,
    # timers, or a background rendering loop.
    $Card.Opacity = 0
    $translate = New-Object System.Windows.Media.TranslateTransform(0, 12)
    $Card.RenderTransform = $translate

    $duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(320))
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, $duration)
    $fade.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
    $fade.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut

    $slide = New-Object System.Windows.Media.Animation.DoubleAnimation(12, 0, $duration)
    $slide.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
    $slide.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut

    $Card.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    $translate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
}

# Load Gallery Function
function Load-Gallery {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param()
    $GalleryPanel.Children.Clear()
    $script:selectedCard = $null
    $script:selectedImage = $null
    $script:selection.Card = $null
    $script:selection.Image = $null
    $script:loadedImages = @()
    
    # Remove old dynamic cards from reveal tracking to prevent memory leaks
    if ($script:revealElements) {
        $staticElements = $script:revealElements | Where-Object { $_.Element.Name -eq "RevealBorder" }
        $script:revealElements.Clear()
        foreach ($item in $staticElements) { $script:revealElements.Add($item) | Out-Null }
    }
    
    [BingWallpaperNative]::FlushMemory()
    $StatusText.Text = 'Connecting to Bing...'
    $StatusText.Foreground = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(136, 136, 136)))
    Update-UI

    try {
        $selectedRegion = Get-SelectedRegionCode
        $images = Get-BingImages -Region $selectedRegion
        $script:loadedImages = $images
        $total = $images.Count
        $current = 0
        
        foreach ($image in $images) {
            $current++
            $StatusText.Text = "Fetching image $current of $total..."
            Update-UI

            $displayTitle = Get-CleanImageTitle $image

            # Modern edge-to-edge flush Image Card
            $card = New-Object System.Windows.Controls.Border
            $card.Background = $cardUnselectedBg
            $card.CornerRadius = New-Object System.Windows.CornerRadius(12)
            $card.BorderThickness = New-Object System.Windows.Thickness(0)
            $card.ClipToBounds = $true
            $cardClip = New-Object System.Windows.Media.RectangleGeometry
            $cardClip.RadiusX = 12
            $cardClip.RadiusY = 12
            $card.Clip = $cardClip
            $card.Add_SizeChanged({
                    param($evtSender, $e)
                    $evtSender.Clip.Rect = [System.Windows.Rect]::new(0, 0, $evtSender.ActualWidth, $evtSender.ActualHeight)
                })
            $card.Padding = New-Object System.Windows.Thickness(0)
            $card.Margin = New-Object System.Windows.Thickness(0, 0, 16, 16)
            $card.Cursor = [System.Windows.Input.Cursors]::Hand
            $card.Tag = $image
            if ($image.copyright) {
                $card.ToolTip = "$displayTitle`n$($image.copyright)"
            }
            
            # Subtle default drop shadow
            $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
            $shadow.Color = [System.Windows.Media.Colors]::Black
            $shadow.Direction = 270
            $shadow.ShadowDepth = 2
            $shadow.BlurRadius = 10
            $shadow.Opacity = 0.3
            $card.Effect = $shadow

            # Reveal Highlight Effect Setup (Background - Smooth Diffused Falloff)
            $revealBrush = New-Object System.Windows.Media.RadialGradientBrush
            $revealBrush.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute

            # Smooth multi-stop gradient falloff (no harsh circular edges)
            $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(28, 255, 255, 255), 0.0)))
            $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(14, 255, 255, 255), 0.4)))
            $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(4, 255, 255, 255), 0.75)))
            $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, 255, 255, 255), 1.0)))

            # Keep the radius around 160-200 for a soft ambient wash
            $revealBrush.RadiusX = 180
            $revealBrush.RadiusY = 180
            
            $revealRect = New-Object System.Windows.Shapes.Rectangle
            $revealRect.Fill = $revealBrush
            $revealRect.Opacity = 0
            $revealRect.IsHitTestVisible = $false
            $revealRect.RadiusX = 12
            $revealRect.RadiusY = 12
            
            $script:revealElements.Add(@{ Element = $revealRect; Brush = $revealBrush }) | Out-Null

            # Reveal Border Effect Setup (Always visible border glow)
            $revealBorderBrush = New-Object System.Windows.Media.RadialGradientBrush
            $revealBorderBrush.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute
            $revealBorderBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(90, 255, 255, 255), 0.0)))
            $revealBorderBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, 255, 255, 255), 1.0)))
            $revealBorderBrush.RadiusX = 160
            $revealBorderBrush.RadiusY = 160

            $revealBorder = New-Object System.Windows.Controls.Border
            $revealBorder.BorderBrush = $revealBorderBrush
            $revealBorder.BorderThickness = New-Object System.Windows.Thickness(1.5)
            $revealBorder.CornerRadius = New-Object System.Windows.CornerRadius(12)
            $revealBorder.IsHitTestVisible = $false
            
            $script:revealElements.Add(@{ Element = $revealBorder; Brush = $revealBorderBrush }) | Out-Null

            # Hover Effects
            $card.Add_MouseEnter({ 
                    param($evtSender, $e)
                    if ($evtSender -ne $script:selectedCard) {
                        $evtSender.Background = $cardHoverBg
                    }
                
                    # Dynamic hover shadow & reveal light lookup
                    $evtSender.Effect.BlurRadius = 25
                    $evtSender.Effect.ShadowDepth = 8

                    $grid = $evtSender.Child
                    if ($grid -and $grid.Children.Count -gt 1) {
                        $grid.Children[1].Opacity = 1
                    }
                })

            $card.Add_MouseLeave({ 
                    param($evtSender, $e)
                    if ($evtSender -ne $script:selectedCard) {
                        $evtSender.Background = $cardUnselectedBg
                    }
                    else {
                        Set-CardAccent $evtSender $evtSender.Resources['ImageAccentBrush']
                    }

                    # Reset shadow & reveal light
                    $evtSender.Effect.BlurRadius = 10
                    $evtSender.Effect.ShadowDepth = 2
                    $evtSender.Effect.Opacity = 0.3

                    $grid = $evtSender.Child
                    if ($grid -and $grid.Children.Count -gt 1) {
                        $grid.Children[1].Opacity = 0
                    }
                })

            $stack = New-Object System.Windows.Controls.StackPanel
            $stack.IsHitTestVisible = $false

            $cardGrid = New-Object System.Windows.Controls.Grid
            $cardGrid.Children.Add($stack)
            $cardGrid.Children.Add($revealRect)
            $cardGrid.Children.Add($revealBorder)
            
            $card.Child = $cardGrid

            # Image Container (Using Image control for native aspect ratio scaling)
            $imgBorder = New-Object System.Windows.Controls.Border
            $imgBorder.CornerRadius = New-Object System.Windows.CornerRadius(12)
            $imgBorder.ClipToBounds = $true
            $imgBorder.Background = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(20, 20, 20)))

            $imageControl = New-Object System.Windows.Controls.Image
            $imageControl.Stretch = [System.Windows.Media.Stretch]::Uniform
            $imgBorder.Child = $imageControl

            $stack.Children.Add($imgBorder)

            # Download high-res thumbnail with local caching
            try {
                $thumbCacheDir = Join-Path $env:LOCALAPPDATA 'BingWallpaper\Cache\Thumbnails'
                if (-not (Test-Path -LiteralPath $thumbCacheDir)) {
                    New-Item -ItemType Directory -Path $thumbCacheDir -Force | Out-Null
                }
                $safeName = $image.urlbase -replace '[^a-zA-Z0-9]', ''
                $thumbCachePath = Join-Path $thumbCacheDir "${safeName}_thumb.jpg"
                if (-not (Test-Path -LiteralPath $thumbCachePath)) {
                    $wc = New-Object System.Net.WebClient
                    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                    $wc.DownloadFile("https://www.bing.com$($image.urlbase)_1920x1080.jpg", $thumbCachePath)
                    $wc.Dispose()
                }
                
                $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                $bitmap.BeginInit()
                $bitmap.UriSource = New-Object System.Uri((Resolve-Path -LiteralPath $thumbCachePath).Path)
                $bitmap.DecodePixelWidth = 360
                $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bitmap.EndInit()
                $bitmap.Freeze()
                $card.Resources.Add('ImageAccentBrush', (Get-ImageAccentBrush $thumbCachePath))
                
                $window.Dispatcher.Invoke({
                        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($imageControl, [System.Windows.Media.BitmapScalingMode]::HighQuality)
                        $imageControl.Source = $bitmap
                    })
            }
            catch {
                # Failsafe if image completely refuses to download
            }

            # Details Setup
            $details = New-Object System.Windows.Controls.StackPanel
            $details.Margin = New-Object System.Windows.Thickness(14, 10, 14, 12)

            $title = New-Object System.Windows.Controls.TextBlock
            $title.Text = $displayTitle
            $title.Foreground = [System.Windows.Media.Brushes]::White
            $title.FontSize = 15
            $title.FontWeight = [System.Windows.FontWeights]::SemiBold
            $title.TextTrimming = 'CharacterEllipsis'
            $title.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
            $details.Children.Add($title)

            $date = New-Object System.Windows.Controls.TextBlock
            try {
                $date.Text = ([DateTime]::ParseExact($image.enddate.ToString(), 'yyyyMMdd', $null)).ToString('ddd, MMM d')
            }
            catch {
                $date.Text = "Bing Wallpaper"
            }
            $date.Foreground = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(160, 160, 160)))
            $date.FontSize = 13.5
            $details.Children.Add($date)

            $card.Resources.Add('TitleText', $title)
            $card.Resources.Add('DateText', $date)

            $stack.Children.Add($details)

            # Card Click Action: Select card on single click, apply on double click
            $card.Add_MouseLeftButtonDown({
                    param($evtSender, $e)
                    $clickedImage = $evtSender.Tag 
                    Select-Card $evtSender $clickedImage
                    
                    if ($e.ClickCount -eq 2) {
                        $actionTitle = Get-CleanImageTitle $clickedImage
                        $UpdateBtn.IsEnabled = $false
                        $DownloadBtn.IsEnabled = $false
                        $StatusText.Foreground = $statusDefaultBrush
                        $StatusText.Text = "Applying $actionTitle..."
                        Update-UI

                        try {
                            $null = Set-BingImage -Image $clickedImage -Resolution $ResolutionBox.SelectedItem -Target $TargetBox.SelectedItem -Style $StyleBox.SelectedItem
                            Set-TransientStatus -Message (Get-AppliedSuccessMessage $TargetBox.SelectedItem)
                        }
                        catch {
                            Set-TransientStatus -Message "Failed: $($_.Exception.Message)" -Brush $statusErrorBrush -Seconds 5
                        }
                        finally {
                            $UpdateBtn.IsEnabled = $true
                            $DownloadBtn.IsEnabled = $true
                        }
                    }
                })

            $GalleryPanel.Children.Add($card)
            Show-GalleryCard -Card $card

            Update-UI # Force UI draw right away so the user isn't staring at a blank screen
        }
        [BingWallpaperNative]::FlushMemory()
        $StatusText.Text = 'Double-click any wallpaper to apply'
    }
    catch {
        $StatusText.Foreground = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(248, 113, 113)))
        $StatusText.Text = "Gallery failed to load: $($_.Exception.Message)"
    }
}

# Main Apply Button Logic (Sets wallpaper without permanent disk save)
$UpdateBtn.Add_Click({
        $targetImage = if ($script:selectedImage) { 
            $script:selectedImage 
        }
        elseif ($script:selection.Image) { 
            $script:selection.Image 
        }
        elseif ($script:loadedImages -and $script:loadedImages.Count -gt 0) { 
            $script:loadedImages[0] 
        }
        else { 
            (Get-BingImages -Region (Get-SelectedRegionCode) | Select-Object -First 1) 
        }
        if (-not $targetImage) { return }
        $actionTitle = Get-CleanImageTitle $targetImage

        $UpdateBtn.IsEnabled = $false
        $DownloadBtn.IsEnabled = $false
        $StatusText.Foreground = $statusDefaultBrush
        $StatusText.Text = "Applying $actionTitle..."
        Update-UI

        try {
            $null = Set-BingImage -Image $targetImage -Resolution $ResolutionBox.SelectedItem -Target $TargetBox.SelectedItem -Style $StyleBox.SelectedItem
            Set-TransientStatus -Message (Get-AppliedSuccessMessage $TargetBox.SelectedItem)
        }
        catch {
            Set-TransientStatus -Message "Failed: $($_.Exception.Message)" -Brush $statusErrorBrush -Seconds 5
        }
        finally {
            $UpdateBtn.IsEnabled = $true
            $DownloadBtn.IsEnabled = $true
        }
    })

# Dedicated Download Button Logic (Saves image to configured folder)
$DownloadBtn.Add_Click({
        $targetImage = if ($script:selectedImage) { 
            $script:selectedImage 
        }
        elseif ($script:selection.Image) { 
            $script:selection.Image 
        }
        elseif ($script:loadedImages -and $script:loadedImages.Count -gt 0) { 
            $script:loadedImages[0] 
        }
        else { 
            (Get-BingImages -Region (Get-SelectedRegionCode) | Select-Object -First 1) 
        }
        if (-not $targetImage) { return }
        $actionTitle = Get-CleanImageTitle $targetImage

        $UpdateBtn.IsEnabled = $false
        $DownloadBtn.IsEnabled = $false
        $StatusText.Foreground = $statusDefaultBrush
        $StatusText.Text = "Downloading $actionTitle..."
        Update-UI

        try {
            $null = Save-BingImage -Image $targetImage -Resolution $ResolutionBox.SelectedItem -DownloadFolder $FolderBox.Text
            Set-TransientStatus -Message "Wallpaper downloaded"
        }
        catch {
            Set-TransientStatus -Message "Download failed: $($_.Exception.Message)" -Brush $statusErrorBrush -Seconds 5
        }
        finally {
            $UpdateBtn.IsEnabled = $true
            $DownloadBtn.IsEnabled = $true
        }
    })

$CheckUpdateBtn.Add_Click({ Start-VerifiedUpdate })

# Auto-trigger United States on load
$usItem = $RegionBox.Items | Where-Object { $_.Tag -eq 'en-US' } | Select-Object -First 1
if ($usItem) { $RegionBox.SelectedItem = $usItem }

# Bind refresh events after the initial selection so startup never loads the gallery twice.
$RegionBox.Add_SelectionChanged({ Load-Gallery })
$RefreshBtn.Add_Click({
        if ($script:isRefreshAnimating) { return }
        if (-not $RefreshIcon) {
            Load-Gallery
            return
        }
        $script:isRefreshAnimating = $true
        $RefreshBtn.IsEnabled = $false
        Start-RefreshAnimation
    })
$window.Add_ContentRendered({
    Load-Gallery
})

# Show the app
$window.ShowDialog() | Out-Null



















