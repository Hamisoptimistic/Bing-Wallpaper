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

$script:startStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$script:timingLogPath = Join-Path $env:LOCALAPPDATA 'BingWallpaper\startup-timing.log'
function Write-TimingLog {
    param([string]$Message)
    try {
        $dir = Split-Path -Parent $script:timingLogPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $script:timingLogPath -Value "$(Get-Date -Format 'HH:mm:ss.fff')  $Message" -Encoding UTF8
    }
    catch {}
}
Write-TimingLog "SCRIPT: first line executing (in-process launch)"

# Enforce modern security protocols
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
}
catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# Load UI assemblies
[void][System.Reflection.Assembly]::Load("PresentationFramework, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35")
[void][System.Reflection.Assembly]::Load("PresentationCore, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35")
[void][System.Reflection.Assembly]::Load("WindowsBase, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35")
Write-TimingLog "SCRIPT: PresentationFramework/Core/WindowsBase loaded ($($script:startStopwatch.ElapsedMilliseconds)ms since script start)"

function Show-AppErrorDialog {
    param(
        [string]$Message,
        [string]$Title
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show($Message, $Title) | Out-Null
    }
    catch {}
}

# Native helper types - compiled in memory every launch via Add-Type.
# There is no AutoScapeNative.dll anywhere in this pipeline anymore: nothing is
# extracted, cached, or written to disk, so there is no unsigned binary for
# Smart App Control to evaluate or block. csc.exe (Microsoft-signed) does the
# compiling; the resulting assembly lives only in this process's memory.
$script:nativeLoadLogPath = Join-Path $env:LOCALAPPDATA 'BingWallpaper\native-load.log'
function Write-NativeLoadLog {
    param([string]$Message)
    try {
        $logDir = Split-Path -Parent $script:nativeLoadLogPath
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -LiteralPath $script:nativeLoadLogPath -Value "$(Get-Date -Format 'u')  $Message" -Encoding UTF8
    }
    catch {}
}

if (-not ('BingWallpaper.FastAccent' -as [type])) {
    $script:nativeCsSource = @'
using System;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Media;
using System.Windows.Media.Imaging;

public static class AppUserModel
{
    [DllImport("shell32.dll", SetLastError = true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
}

public static class BingWallpaperNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct MARGINS
    {
        public int cxLeftWidth;
        public int cxRightWidth;
        public int cyTopHeight;
        public int cyBottomHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    [DllImport("dwmapi.dll")]
    public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    private static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

    [DllImport("uxtheme.dll", EntryPoint = "#135")]
    private static extern int SetPreferredAppMode(int preferredAppMode);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("psapi.dll")]
    private static extern bool EmptyWorkingSet(IntPtr hProcess);

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19;

    public static void EnableDarkTitleBar(IntPtr hwnd, int enable)
    {
        int useDark = enable != 0 ? 1 : 0;
        if (DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref useDark, sizeof(int)) != 0)
        {
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, ref useDark, sizeof(int));
        }
    }

    public static void EnableDarkDialogs()
    {
        try { SetPreferredAppMode(1); } catch { }
    }

    public static bool IsDialogWindow(IntPtr hwnd)
    {
        var sb = new StringBuilder(256);
        GetClassName(hwnd, sb, sb.Capacity);
        return sb.ToString() == "#32770";
    }

    public static void ForceDarkDialog(IntPtr hwnd)
    {
        try
        {
            SetWindowTheme(hwnd, "DarkMode_Explorer", null);
            int useDark = 1;
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref useDark, sizeof(int));
            EnumChildWindows(hwnd, (child, lParam) =>
            {
                SetWindowTheme(child, "DarkMode_Explorer", null);
                return true;
            }, IntPtr.Zero);
        }
        catch { }
    }

    public static void FlushMemory()
    {
        try { EmptyWorkingSet(System.Diagnostics.Process.GetCurrentProcess().Handle); } catch { }
    }

    // --- IFileOpenDialog folder picker (legacy fallback path) ---
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    private class FileOpenDialogRCW { }

    [ComImport, Guid("d57c7288-d4ad-4768-be02-9d969532d960"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOpenDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName(string pszName);
        void GetFileName(out string pszName);
        void SetTitle(string pszTitle);
        void SetOkButtonLabel(string pszText);
        void SetFileNameLabel(string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, uint alignment);
        void SetDefaultExtension(string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter([MarshalAs(UnmanagedType.IUnknown)] object pFilter);
        void GetResults(out IntPtr ppenum);
        void GetSelectedItems(out IntPtr ppsai);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    private const uint FOS_PICKFOLDERS = 0x00000020;
    private const uint SIGDN_FILESYSPATH = 0x80058000;

    public static string PickFolder(IntPtr owner, string title)
    {
        IFileOpenDialog dialog = null;
        try
        {
            dialog = (IFileOpenDialog)new FileOpenDialogRCW();
            dialog.SetOptions(FOS_PICKFOLDERS);
            if (!string.IsNullOrEmpty(title)) dialog.SetTitle(title);

            int hr = dialog.Show(owner);
            if (hr != 0) return null;

            IShellItem item;
            dialog.GetResult(out item);
            IntPtr pszPath;
            item.GetDisplayName(SIGDN_FILESYSPATH, out pszPath);
            string path = Marshal.PtrToStringUni(pszPath);
            Marshal.FreeCoTaskMem(pszPath);
            return path;
        }
        catch
        {
            return null;
        }
        finally
        {
            if (dialog != null) Marshal.ReleaseComObject(dialog);
        }
    }
}

namespace BingWallpaper
{
    public static class FastAccent
    {
        // Approximate dominant-color extraction: downsample and average, biased
        // away from near-black/near-white pixels so the accent isn't washed out.
        public static SolidColorBrush ExtractBrush(string imagePath)
        {
            var decoder = BitmapDecoder.Create(
                new Uri(imagePath),
                BitmapCreateOptions.IgnoreColorProfile,
                BitmapCacheOption.OnLoad);
            var frame = new TransformedBitmap(decoder.Frames[0],
                new System.Windows.Media.ScaleTransform(
                    32.0 / decoder.Frames[0].PixelWidth,
                    32.0 / decoder.Frames[0].PixelHeight));
            var converted = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);

            int w = converted.PixelWidth, h = converted.PixelHeight;
            int stride = w * 4;
            byte[] pixels = new byte[h * stride];
            converted.CopyPixels(pixels, stride, 0);

            long r = 0, g = 0, b = 0;
            int count = 0;
            for (int i = 0; i < pixels.Length; i += 4)
            {
                byte bb = pixels[i], gg = pixels[i + 1], rr = pixels[i + 2];
                int lum = (rr + gg + bb) / 3;
                if (lum < 18 || lum > 238) continue; // skip near-black / near-white
                r += rr; g += gg; b += bb;
                count++;
            }
            if (count == 0) count = 1;

            var brush = new SolidColorBrush(Color.FromRgb((byte)(r / count), (byte)(g / count), (byte)(b / count)));
            brush.Freeze();
            return brush;
        }
    }

    public static class FastDownloader
    {
        public static void DownloadThumbnailsParallel(string[] urlBases, string cacheDir)
        {
            using (var client = new HttpClient())
            {
                client.DefaultRequestHeaders.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
                client.Timeout = TimeSpan.FromSeconds(20);

                Parallel.ForEach(urlBases, new ParallelOptions { MaxDegreeOfParallelism = 6 }, urlBase =>
                {
                    try
                    {
                        string safe = Regex.Replace(urlBase, "[^a-zA-Z0-9]", "");
                        string target = Path.Combine(cacheDir, safe + "_thumb.jpg");
                        if (File.Exists(target)) return;

                        string uri = "https://www.bing.com" + urlBase + "_1920x1080.jpg";
                        byte[] data = client.GetByteArrayAsync(uri).GetAwaiter().GetResult();
                        File.WriteAllBytes(target, data);
                    }
                    catch { }
                });
            }
        }
    }
}
'@

    try {
        Add-Type -TypeDefinition $script:nativeCsSource -ReferencedAssemblies @(
        'PresentationCore', 'PresentationFramework', 'WindowsBase',
        'System.Net.Http', 'System.Drawing', 'System.Xaml'
    ) -Language CSharp -ErrorAction Stop
        Write-NativeLoadLog "OK: compiled native helpers in-memory (no DLL file written)"
    }
    catch {
        Write-NativeLoadLog "FAIL: in-memory compile failed: $($_.Exception.Message)"
    }
}

# Dynamically detect executable version
$script:appVersion = [Version]'1.0.206'
try {
    $currentProc = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($currentProc -and $currentProc -notmatch '^(?i:powershell|pwsh)(?:\.exe)?$' -and (Test-Path -LiteralPath $currentProc)) {
        $fileVer = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($currentProc).FileVersion
        if ($fileVer -match '^\d+(\.\d+){1,3}$') {
            $script:appVersion = [Version]$fileVer
        }
    }
}
catch {}
$script:updateRepository = 'Hamisoptimistic/Bing-Wallpaper'
$script:updatePublisherThumbprint = ''

function Set-LockScreenImageIsolated {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath
    )

    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
        throw "Lock screen source image does not exist: $ImagePath"
    }

    if (-not [Environment]::Is64BitProcess) {
        throw "The lock screen requires 64-bit PowerShell on 64-bit Windows."
    }

    $cacheDir = Split-Path -Parent $ImagePath
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    try {
        $cdmPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        if (-not (Test-Path -LiteralPath $cdmPath)) { New-Item -Path $cdmPath -Force | Out-Null }
        Set-ItemProperty -Path $cdmPath -Name 'RotatingLockScreenEnabled' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $cdmPath -Name 'RotatingLockScreenOverlayEnabled' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $cdmPath -Name 'SubscribedContent-338387Enabled' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    }
    catch {}

    $uniqueName = 'BingLockScreen-{0}-{1}.jpg' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), ([Guid]::NewGuid().ToString('N'))
    $uniquePath = Join-Path $cacheDir $uniqueName

    Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ImagePath).Path -Destination $uniquePath -Force -ErrorAction Stop
    $resolvedPath = (Resolve-Path -LiteralPath $uniquePath).Path

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.Open()

    $worker = $null
    $async = $null

    try {
        $worker = [PowerShell]::Create()
        $worker.Runspace = $rs

        $workerScript = {
            param([string]$Path)
            try {
                if (-not [Environment]::Is64BitProcess) { return 'ERROR|32BIT' }
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

                [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
                [Windows.System.UserProfile.UserProfilePersonalizationSettings, Windows.System.UserProfile, ContentType = WindowsRuntime] | Out-Null
                [Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime] | Out-Null

                try {
                    $storageFile = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
                }
                catch {
                    return "ERROR|STORAGEFILE|$($_.Exception.Message)"
                }

                try {
                    if ([Windows.System.UserProfile.UserProfilePersonalizationSettings]::IsSupported()) {
                        $settings = [Windows.System.UserProfile.UserProfilePersonalizationSettings]::Current
                        $result = Await ($settings.TrySetLockScreenImageAsync($storageFile)) ([bool])
                        if ($result -eq $true) { return 'SUCCESS|PERSONALIZATION' }
                    }
                }
                catch {}

                try {
                    AwaitAction ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($storageFile))
                    return 'SUCCESS|LOCKSCREEN'
                }
                catch {}

                return 'ERROR|WINRT'
            }
            catch {
                return "ERROR|$($_.Exception.Message)"
            }
        }

        $null = $worker.AddScript($workerScript).AddArgument($resolvedPath)
        $async = $worker.BeginInvoke()
        $completed = $async.AsyncWaitHandle.WaitOne(30000)

        if (-not $completed) {
            throw "Windows did not finish the lock-screen operation within 30 seconds."
        }

        $output = @($worker.EndInvoke($async))
        $result = if ($output.Count -gt 0) { [string]$output[0] } else { '' }

        if ($result -like 'SUCCESS|*') { return $true }
        if ($result -eq 'ERROR|32BIT') { throw "The lock-screen API was invoked from 32-bit PowerShell." }
        throw "Windows rejected the lock-screen image. WinRT result: $result"
    }
    finally {
        if ($worker) { $worker.Dispose() }
        if ($rs) { $rs.Dispose() }
    }
}

function Get-DownloadFolder {
    $pictures = [Environment]::GetFolderPath('MyPictures')
    return (Join-Path $pictures 'BingWallpapers')
}

function Get-BingImages {
    param([string]$Region)
    $market = if ($Region -eq 'auto') { 'en-US' } else { $Region }
    
    $uri1 = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=$market"
    $uri2 = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=8&n=8&mkt=$market"
    
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
    try {
        $json1 = $wc.DownloadString($uri1)
        $json2 = $wc.DownloadString($uri2)
        $batch1 = if ($json1) { (ConvertFrom-Json -InputObject $json1).images } else { @() }
        $batch2 = if ($json2) { (ConvertFrom-Json -InputObject $json2).images } else { @() }
    }
    catch {
        $batch1 = @()
        $batch2 = @()
    }
    finally {
        $wc.Dispose()
    }
    
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
        '4K|UHD' { return "https://www.bing.com${urlBase}_UHD.jpg" }
        '2K|1440' { return "https://www.bing.com${urlBase}_UHD.jpg&w=2560&h=1440&rs=1&c=4" }
        '1080' { return "https://www.bing.com${urlBase}_1920x1080.jpg" }
        '720|1366|768' { return "https://www.bing.com${urlBase}_1920x1080.jpg&w=1280&h=720&rs=1&c=4" }
        Default { return "https://www.bing.com${urlBase}_UHD.jpg" }
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
        if ($Image.copyright) {
            $clean = $Image.copyright -replace '\s*\([^\)]*\)\s*$', ''
            $clean = $clean.Trim()
            if ($clean) { return $clean }
        }
        if ($Image.urlbase -match 'OHR\.([A-Za-z0-9]+)_') {
            $clean = $matches[1] -creplace '([a-z])([A-Z])', '$1 $2'
            return $clean
        }
        return 'AutoScape'
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
    $cleanTitle = ($displayTitle -replace '[\\/:*?"<>|\x00-\x1F]', '').Trim()
    $cleanTitle = ($cleanTitle -replace '\s+', ' ').Trim()
    if ($cleanTitle.Length -gt 60) { $cleanTitle = $cleanTitle.Substring(0, 60).Trim() }
    
    $fileName = if ($cleanTitle) { "Bing-$imageDate-$cleanTitle.jpg" } else { "Bing-$imageDate.jpg" }
    $downloadPath = Join-Path $DownloadFolder $fileName

    Invoke-WebRequest -Uri $imageUri -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop
    return $downloadPath
}

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
        Region            = "auto"
        Resolution        = "4K"
        Target            = "Both"
        Style             = (Get-CurrentDesktopWallpaperStyle)
        SaveFolder        = (Get-DownloadFolder)
        SpotlightEnabled  = $false
        SpotlightInterval = 60
        SpotlightTarget   = "Desktop"
    }
}

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

function Get-DetectedRegionCode {
    try {
        $region = [System.Globalization.RegionInfo]::CurrentRegion.TwoLetterISORegionName
        $match = $countries | Where-Object { $_.Code -match "-$region`$" } | Select-Object -First 1
        if ($match) { return $match.Code }
        
        $culture = [System.Globalization.CultureInfo]::CurrentUICulture
        $tag = $culture.Name
        $match = $countries | Where-Object { $_.Code -eq $tag } | Select-Object -First 1
        if ($match) { return $match.Code }

        $lang = $culture.TwoLetterISOLanguageName
        $match = $countries | Where-Object { $_.Code -like "$lang-*" } | Select-Object -First 1
        if ($match) { return $match.Code }
    }
    catch {}
    return 'auto'
}

if ($AutoApply) {
    try {
        $savedSettings = Load-Settings
        if ($savedSettings) {
            if ($PSBoundParameters.ContainsKey('Region') -eq $false -and $savedSettings.Region -and $savedSettings.Region -ne 'auto') { $Region = $savedSettings.Region }
            elseif ($Region -eq 'en-US') {
                $detected = Get-DetectedRegionCode
                if ($detected) { $Region = $detected }
            }
            if ($PSBoundParameters.ContainsKey('Resolution') -eq $false -and $savedSettings.Resolution) { $Resolution = $savedSettings.Resolution }
            if ($PSBoundParameters.ContainsKey('Style') -eq $false -and $savedSettings.Style) { $Style = $savedSettings.Style }
            if ($PSBoundParameters.ContainsKey('Target') -eq $false -and $savedSettings.SpotlightTarget) { $Target = $savedSettings.SpotlightTarget }
        }
        $images = Get-BingImages -Region $Region
        if (-not $images -or $images.Count -eq 0) {
            throw "No Bing wallpaper metadata found for region '$Region'."
        }
        $targetImage = $images[0]
        $title = Get-CleanImageTitle $targetImage
        $appliedPath = Set-BingImage -Image $targetImage -Resolution $Resolution -Target $Target -Style $Style
        Write-Output "Successfully applied AutoScape wallpaper: $title ($appliedPath)"
        [Environment]::Exit(0)
    }
    catch {
        Write-Error "Failed to apply AutoScape wallpaper: $($_.Exception.Message)"
        [Environment]::Exit(1)
    }
}

try { [AppUserModel]::SetCurrentProcessExplicitAppUserModelID("AutoScape.App") } catch {}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AutoScape" Height="780" Width="1100"
        Background="Transparent" FontFamily="Segoe UI" WindowStartupLocation="CenterScreen" WindowState="Maximized">
    
    <Window.Resources>
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

        <Style x:Key="ModalCloseButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="#2A2A2A"/>
            <Setter Property="Foreground" Value="#CCCCCC"/>
            <Setter Property="BorderThickness" Value="1.5"/>
            <Setter Property="BorderBrush" Value="#1FFFFFFF"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="CloseBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CloseBorder" Property="Background" Value="#E81123"/>
                                <Setter TargetName="CloseBorder" Property="BorderBrush" Value="#E81123"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="CloseBorder" Property="Background" Value="#C42B1C"/>
                                <Setter TargetName="CloseBorder" Property="BorderBrush" Value="#C42B1C"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <ControlTemplate x:Key="ComboBoxToggleButtonTemplate" TargetType="ToggleButton">
            <Border Name="RevealBorder" Background="{TemplateBinding Background}" BorderBrush="#1FFFFFFF" BorderThickness="1.5" CornerRadius="8">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="34"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Name="ArrowIcon" Grid.Column="1" Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" Foreground="#777" VerticalAlignment="Center" HorizontalAlignment="Center" FontSize="11" IsHitTestVisible="False"/>
                </Grid>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter TargetName="RevealBorder" Property="Background" Value="#282828"/>
                    <Setter TargetName="ArrowIcon" Property="Foreground" Value="#DDD"/>
                </Trigger>
                <Trigger Property="IsChecked" Value="True">
                    <Setter TargetName="RevealBorder" Property="Background" Value="#242424"/>
                    <Setter TargetName="RevealBorder" Property="BorderBrush" Value="#0078D4"/>
                    <Setter TargetName="ArrowIcon" Property="Foreground" Value="#0078D4"/>
                </Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate>

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
                            <ToggleButton Name="ToggleButton"
                                          Template="{StaticResource ComboBoxToggleButtonTemplate}"
                                          Background="{TemplateBinding Background}"
                                          Focusable="False"
                                          ClickMode="Press"
                                          IsChecked="{Binding Path=IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
                            <ContentPresenter Name="ContentSite"
                                              IsHitTestVisible="False"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                                              TextElement.Foreground="{TemplateBinding Foreground}"
                                              VerticalAlignment="Center"
                                              Margin="14,0,34,0"/>
                            <Popup Name="PART_Popup"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom"
                                   AllowsTransparency="True"
                                   Focusable="False">
                                <Border Background="#1E1E1E" CornerRadius="8" Margin="0,4,0,0" MinWidth="{TemplateBinding ActualWidth}" Padding="4">
                                    <ScrollViewer CanContentScroll="False" MaxHeight="260" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden">
                                        <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="HasItems" Value="False">
                                <Setter TargetName="PART_Popup" Property="MinHeight" Value="95"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#888888"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

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

    <Grid>
        <Grid Name="MainContent" Margin="32">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Grid Margin="0,0,0,32">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
                    <Border Background="#141212ff" Width="52" Height="52" CornerRadius="14" Margin="0,0,20,0">
                        <Viewbox Margin="3">
                            <Canvas Width="760" Height="720">
                                <Canvas Canvas.Left="-135" Canvas.Top="-135" Width="1024" Height="1024">
                                    <Canvas.Resources>
                                        <LinearGradientBrush x:Key="b1" StartPoint="0,0" EndPoint="1,1">
                                            <GradientStop Color="#174BCB" Offset="0"/>
                                            <GradientStop Color="#0B3AA5" Offset="1"/>
                                        </LinearGradientBrush>
                                        <LinearGradientBrush x:Key="b2" StartPoint="0,0" EndPoint="1,1">
                                            <GradientStop Color="#1470D5" Offset="0"/>
                                            <GradientStop Color="#0758BD" Offset="1"/>
                                        </LinearGradientBrush>
                                        <LinearGradientBrush x:Key="sky" StartPoint="0,0" EndPoint="0,1">
                                            <GradientStop Color="#54A8F4" Offset="0"/>
                                            <GradientStop Color="#8BC8F6" Offset="1"/>
                                        </LinearGradientBrush>
                                        <LinearGradientBrush x:Key="m1" StartPoint="0,0" EndPoint="1,1">
                                            <GradientStop Color="#08459F" Offset="0"/>
                                            <GradientStop Color="#0A62C2" Offset="1"/>
                                        </LinearGradientBrush>
                                        <LinearGradientBrush x:Key="m2" StartPoint="0,0" EndPoint="1,1">
                                            <GradientStop Color="#2C72CB" Offset="0"/>
                                            <GradientStop Color="#5E9FDF" Offset="1"/>
                                        </LinearGradientBrush>
                                        <LinearGradientBrush x:Key="m3" StartPoint="0,0" EndPoint="1,1">
                                            <GradientStop Color="#79B5EA" Offset="0"/>
                                            <GradientStop Color="#9CCDF0" Offset="1"/>
                                        </LinearGradientBrush>
                                        <LinearGradientBrush x:Key="snow" StartPoint="0,0" EndPoint="1,1">
                                            <GradientStop Color="#E5EEFF" Offset="0"/>
                                            <GradientStop Color="#FFFFFF" Offset="1"/>
                                        </LinearGradientBrush>
                                        <RectangleGeometry x:Key="clip" Rect="173,263,678,539" RadiusX="36" RadiusY="36"/>
                                    </Canvas.Resources>

                                    <Rectangle Canvas.Left="245" Canvas.Top="147" Width="534" Height="151" RadiusX="34" RadiusY="34" Fill="{StaticResource b1}">
                                        <Rectangle.Effect>
                                            <DropShadowEffect BlurRadius="24" Direction="270" ShadowDepth="10" Opacity="0.18" Color="Black"/>
                                        </Rectangle.Effect>
                                    </Rectangle>

                                    <Rectangle Canvas.Left="209" Canvas.Top="205" Width="606" Height="168" RadiusX="36" RadiusY="36" Fill="{StaticResource b2}"/>

                                    <Rectangle Canvas.Left="173" Canvas.Top="263" Width="678" Height="539" RadiusX="36" RadiusY="36" Fill="{StaticResource sky}">
                                        <Rectangle.Effect>
                                            <DropShadowEffect BlurRadius="24" Direction="270" ShadowDepth="10" Opacity="0.18" Color="Black"/>
                                        </Rectangle.Effect>
                                    </Rectangle>

                                    <Canvas Clip="{StaticResource clip}">
                                        <Ellipse Canvas.Left="80" Canvas.Top="175" Width="820" Height="380" Fill="#B9DEFA" Opacity="0.18"/>
                                        <Ellipse Canvas.Left="642" Canvas.Top="295" Width="110" Height="110" Fill="#FFE995"/>
                                        <Path Data="M235 625L360 510L425 558L495 424L570 505L635 450L810 616L880 690V830H205V830Z" Fill="{StaticResource m3}"/>
                                        <Path Data="M360 510L495 424L570 505L532 485L500 535L468 501L430 552L403 531Z" Fill="{StaticResource snow}"/>
                                        <Path Data="M175 657L302 544L376 600L458 516L553 625L610 561L720 671L858 760V830H175Z" Fill="{StaticResource m2}"/>
                                        <Path Data="M302 544L376 600L346 584L325 608L302 590L275 613Z" Fill="#BBDCF5" Opacity="0.9"/>
                                        <Path Data="M458 516L553 625L514 601L486 630L458 602L432 625Z" Fill="#CDE5FA" Opacity="0.85"/>
                                        <Path Data="M150 671L268 590L337 632L420 695L505 751L590 793L655 838H150Z" Fill="{StaticResource m1}"/>
                                        <Path Data="M268 590L337 632L420 695L505 751L590 793L458 741L382 699L320 653Z" Fill="#165DB8" Opacity="0.82"/>
                                        <Path Data="M515 830L590 760L675 700L760 747L880 683L900 830Z" Fill="#3984D4" Opacity="0.78"/>
                                        <Path Data="M675 700L760 747L720 735L690 759L654 730Z" Fill="#79B6E9" Opacity="0.62"/>
                                    </Canvas>
                                </Canvas>
                            </Canvas>
                        </Viewbox>
                    </Border>
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="AutoScape" FontSize="28" FontWeight="SemiBold" Foreground="#FAFAFA" Margin="0,0,0,2"/>
                        <TextBlock Text="Bing wallpapers, delivered daily" FontSize="13" Foreground="#9E9E9E" FontWeight="Normal" Margin="0,0,0,0"/>
                    </StackPanel>
                </StackPanel>
            </Grid>

            <Grid Grid.Row="1" Margin="0,0,0,24">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="150"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="130"/>
                    <ColumnDefinition Width="150"/>
                    <ColumnDefinition Width="120"/>
                    <ColumnDefinition Width="310"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                
                <StackPanel Grid.Column="0" Margin="0,0,16,0">
                    <TextBlock Text="Region" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                    <ComboBox Name="RegionBox" FontSize="13.5" Height="38"/>
                </StackPanel>

                <StackPanel Grid.Column="1" Margin="0,0,16,0" VerticalAlignment="Bottom">
                    <Button Name="RefreshBtn" Style="{StaticResource ModernIconButton}" Width="38" Height="38" ToolTip="Refresh Gallery">
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
                </StackPanel>
                
                <StackPanel Grid.Column="2" Margin="0,0,16,0">
                    <TextBlock Text="Resolution" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                    <ComboBox Name="ResolutionBox" FontSize="13.5" Height="38"/>
                </StackPanel>

                <StackPanel Grid.Column="3" Margin="0,0,16,0">
                    <TextBlock Text="Apply To" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                    <ComboBox Name="TargetBox" FontSize="13.5" Height="38"/>
                </StackPanel>

                <StackPanel Grid.Column="4" Margin="0,0,16,0">
                    <TextBlock Text="Style" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                    <ComboBox Name="StyleBox" FontSize="13.5" Height="38"/>
                </StackPanel>

                <StackPanel Grid.Column="5" Margin="0,0,16,0">
                    <TextBlock Text="Download Image To" HorizontalAlignment="Left" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                    <TextBox Name="FolderBox" Height="38" HorizontalAlignment="Stretch" FontSize="13.5" IsReadOnly="True" Cursor="Hand" ToolTip="Click to change download folder" />
                </StackPanel>

                <StackPanel Grid.Column="6" Margin="0,0,16,0">
                    <TextBlock Text="Auto" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                    <Grid Height="38" VerticalAlignment="Center">
                        <Border Name="SpotlightPill" Width="58" Height="32" CornerRadius="16"
                                Background="#262626" BorderBrush="#3D3D3D" BorderThickness="1.5"
                                Cursor="Hand" VerticalAlignment="Center">
                            <Border.Effect>
                                <DropShadowEffect Color="#0078D4" BlurRadius="14" ShadowDepth="0" Opacity="0"/>
                            </Border.Effect>
                            <Ellipse Name="SpotlightThumb" Width="22" Height="22" Fill="#FFFFFF"
                                     HorizontalAlignment="Left" VerticalAlignment="Center" Margin="5,0,0,0">
                                <Ellipse.RenderTransform>
                                    <TranslateTransform X="0" Y="0"/>
                                </Ellipse.RenderTransform>
                            </Ellipse>
                        </Border>
                    </Grid>
                </StackPanel>

                <StackPanel Name="SpotlightOptionsContainer" Grid.Column="7" Orientation="Horizontal" Visibility="Collapsed" Opacity="0">
                    <StackPanel Margin="0,0,16,0">
                        <TextBlock Text="Every" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                        <ComboBox Name="SpotlightIntervalBox" FontSize="13.5" Width="110" Height="38"/>
                    </StackPanel>
                    <StackPanel Margin="0,0,0,0">
                        <TextBlock Text="Apply To" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                        <ComboBox Name="SpotlightTargetBox" FontSize="13.5" Width="145" Height="38"/>
                    </StackPanel>
                </StackPanel>

                <StackPanel Grid.Column="8" HorizontalAlignment="Right" VerticalAlignment="Bottom">
                    <Button Name="GuideBtn" Style="{StaticResource ModernIconButton}" Width="38" Height="38" ToolTip="User Guide">
                        <TextBlock Text="&#xE946;" FontFamily="Segoe MDL2 Assets" FontSize="18" Foreground="#60CDFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Button>
                </StackPanel>
            </Grid>

            <Border Grid.Row="2" Background="Transparent" CornerRadius="18" BorderThickness="0" ClipToBounds="True" VerticalAlignment="Top">
                <ScrollViewer Name="GalleryScrollViewer" Margin="0,16,0,16" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" VerticalAlignment="Top" FocusVisualStyle="{x:Null}">
                    <UniformGrid Name="GalleryPanel" Columns="4" VerticalAlignment="Top" />
                </ScrollViewer>
            </Border>

            <Grid Grid.Row="3" Margin="0,28,0,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="StatusText" Text="" Foreground="#888" FontSize="14" FontWeight="Medium" VerticalAlignment="Center" TextWrapping="Wrap"/>
                
                <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <Button Name="CheckUpdateBtn" Content="Check for updates" Width="155" Height="46" Margin="0,0,12,0" Background="#262626" Foreground="#E0E0E0" FontSize="15" FontWeight="SemiBold" ToolTip="Check GitHub for a verified app update" />
                    <Button Name="DownloadBtn" Content="Download" Width="130" Height="46" Margin="0,0,12,0" Background="#262626" Foreground="#E0E0E0" FontSize="15" FontWeight="SemiBold" ToolTip="Save selected image to your download folder" />
                    <Button Name="UpdateBtn" Content="Apply" Width="140" Height="46" Background="#0078D4" Foreground="White" FontSize="15" FontWeight="SemiBold" ToolTip="Set selected wallpaper directly" />
                </StackPanel>
            </Grid>
        </Grid>

        <Border Name="ModalDimOverlay" Background="#000000" Opacity="0" Visibility="Collapsed" IsHitTestVisible="False" Panel.ZIndex="900"/>
        <Grid Name="ModalHost" Background="Transparent" Visibility="Collapsed" IsHitTestVisible="False" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Panel.ZIndex="1000"/>
    </Grid>
</Window>
"@

$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
Write-TimingLog "SCRIPT: main window XAML parsed/instantiated ($($script:startStopwatch.ElapsedMilliseconds)ms since script start)"

if (-not [System.Windows.Application]::Current) {
    $script:wpfApp = New-Object System.Windows.Application
    $script:wpfApp.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
}
else {
    $script:wpfApp = [System.Windows.Application]::Current
    $script:wpfApp.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
}
$script:wpfApp.MainWindow = $window

$script:revealElements = New-Object System.Collections.ArrayList

function Find-RevealBorders($visual) {
    if (-not $visual) { return }
    if ($visual -is [System.Windows.Controls.Border] -and $visual.Name -eq "RevealBorder") {
        $alreadyAdded = $false
        foreach ($item in $script:revealElements) {
            if ($item.Element -eq $visual) { $alreadyAdded = $true; break }
        }
        if (-not $alreadyAdded) {
            $revealBrush = New-Object System.Windows.Media.RadialGradientBrush
            $revealBrush.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute
            $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(60, 255, 255, 255), 0.0)))
            $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, 255, 255, 255), 1.0)))
            $revealBrush.RadiusX = 160
            $revealBrush.RadiusY = 160
            $visual.BorderBrush = $revealBrush
            $script:revealElements.Add(@{ Element = $visual; Brush = $revealBrush }) | Out-Null
        }
    }
    
    $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($visual)
    for ($i = 0; $i -lt $count; $i++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($visual, $i)
        Find-RevealBorders $child
    }
}

$window.Add_Loaded({ Find-RevealBorders $window })

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

$scriptDir = $PSScriptRoot
if (-not $scriptDir -and $MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

function Set-AutoScapeIcon {
    param([System.Windows.Window]$TargetWindow)
    $candidates = @(
        (Join-Path $scriptDir 'assets\app.ico'),
        (Join-Path $scriptDir 'app.ico'),
        (Join-Path $scriptDir 'assets\bing.ico'),
        (Join-Path $scriptDir 'bing.ico')
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $frame = [System.Windows.Media.Imaging.BitmapFrame]::Create([System.Uri]::new((Resolve-Path -LiteralPath $path).Path), [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                $TargetWindow.Icon = $frame
                return $path
            }
            catch {}
        }
    }

    try {
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.DrawRoundedRectangle([System.Windows.Media.Brushes]::Transparent, $null, [System.Windows.Rect]::new(0, 0, 48, 48), 10, 10)
        $bg = New-Object System.Windows.Media.LinearGradientBrush([System.Windows.Media.Color]::FromRgb(20, 88, 190), [System.Windows.Media.Color]::FromRgb(77, 166, 235), 45)
        $dc.DrawRoundedRectangle($bg, $null, [System.Windows.Rect]::new(3, 3, 42, 42), 8, 8)
        $sun = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(255, 231, 149))
        $dc.DrawEllipse($sun, $null, [System.Windows.Point]::new(33, 14), 4.5, 4.5)
        $mount = New-Object System.Windows.Media.StreamGeometry
        $mountContext = $mount.Open()
        $mountContext.BeginFigure([System.Windows.Point]::new(6, 38), $true, $true)
        $mountContext.LineTo([System.Windows.Point]::new(17, 27), $false, $false)
        $mountContext.LineTo([System.Windows.Point]::new(23, 32), $false, $false)
        $mountContext.LineTo([System.Windows.Point]::new(29, 24), $false, $false)
        $mountContext.LineTo([System.Windows.Point]::new(42, 38), $false, $false)
        $mountContext.Close()
        $mount.Freeze()
        $dc.DrawGeometry([System.Windows.Media.Brushes]::White, $null, $mount)
        $dc.Close()
        $rt = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(48, 48, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rt.Render($dv)
        $rt.Freeze()
        $TargetWindow.Icon = $rt
    }
    catch {}
    return $null
}

$script:taskbarIconPath = Set-AutoScapeIcon -TargetWindow $window

$applyDarkTitleBar = {
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        if ($helper.Handle -ne [IntPtr]::Zero) {
            [BingWallpaperNative]::EnableDarkTitleBar($helper.Handle, -1)
            
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

$window.Add_StateChanged({
        if ($script:activeModalControl) {
            Close-InWindowModal
        }
    })
function Save-Settings {
    try {
        $settingsObj = @{
            Region            = if ($RegionBox.SelectedItem) { $RegionBox.SelectedItem.Tag } else { "auto" }
            Resolution        = if ($ResolutionBox.SelectedItem) { $ResolutionBox.SelectedItem } else { "4K" }
            Target            = if ($TargetBox.SelectedItem) { $TargetBox.SelectedItem } else { "Both" }
            Style             = if ($StyleBox.SelectedItem) { $StyleBox.SelectedItem } else { "Fit" }
            SaveFolder        = $FolderBox.Text
            SpotlightInterval = if ($SpotlightIntervalBox -and $SpotlightIntervalBox.SelectedItem) { $SpotlightIntervalBox.SelectedItem.Tag } else { 60 }
            SpotlightTarget   = if ($SpotlightTargetBox -and $SpotlightTargetBox.SelectedItem) { $SpotlightTargetBox.SelectedItem } else { 'Desktop' }
            SpotlightEnabled  = [bool]$script:SpotlightEnabled
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

$RegionBox = $window.FindName('RegionBox')
$ResolutionBox = $window.FindName('ResolutionBox')
$TargetBox = $window.FindName('TargetBox')
$StyleBox = $window.FindName('StyleBox')
$FolderBox = $window.FindName('FolderBox')
$RefreshBtn = $window.FindName('RefreshBtn')
$RefreshIcon = $window.FindName('RefreshIcon')
$GalleryPanel = $window.FindName('GalleryPanel')
$GalleryScrollViewer = $window.FindName('GalleryScrollViewer')
$StatusText = $window.FindName('StatusText')
$CheckUpdateBtn = $window.FindName('CheckUpdateBtn')
$DownloadBtn = $window.FindName('DownloadBtn')
$UpdateBtn = $window.FindName('UpdateBtn')
$SpotlightPill = $window.FindName('SpotlightPill')
$SpotlightThumb = $window.FindName('SpotlightThumb')
$SpotlightGlow = if ($SpotlightPill) { $SpotlightPill.Effect } else { $null }
$SpotlightOptionsContainer = $window.FindName('SpotlightOptionsContainer')
$SpotlightIntervalBox = $window.FindName('SpotlightIntervalBox')
$SpotlightTargetBox = $window.FindName('SpotlightTargetBox')
$GuideBtn = $window.FindName('GuideBtn')
$ModalDimOverlay = $window.FindName('ModalDimOverlay')
$ModalHost = $window.FindName('ModalHost')
$script:activeModalControl = $null
$script:activeModalKind = $null
$script:activeModalClosing = $false
$script:activeModalCloseCallback = $null    

function Set-AppDimState {
    param([bool]$Dim, [bool]$Immediate = $false)
    if (-not $ModalDimOverlay) { return }

    $target = if ($Dim) { 0.22 } else { 0.0 }
    $ModalDimOverlay.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $null)

    if ($Immediate) {
        $ModalDimOverlay.Opacity = $target
        $ModalDimOverlay.Visibility = if ($Dim) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        $ModalDimOverlay.IsHitTestVisible = $Dim
        return
    }

    if ($Dim) {
        $ModalDimOverlay.Visibility = [System.Windows.Visibility]::Visible
        $ModalDimOverlay.IsHitTestVisible = $true
    }

    $from = [double]$ModalDimOverlay.Opacity
    $ms = if ($Dim) { 190 } else { 150 }
    $duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds($ms))
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation($from, $target, $duration)
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = if ($Dim) { [System.Windows.Media.Animation.EasingMode]::EaseOut } else { [System.Windows.Media.Animation.EasingMode]::EaseIn }
    $anim.EasingFunction = $ease
    $anim.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
    $ModalDimOverlay.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $anim)

    if (-not $Dim) {
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(160)
        $timer.Add_Tick({
                param($sender, $e)
                $sender.Stop()
                $ModalDimOverlay.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $null)
                $ModalDimOverlay.Opacity = 0.0
                $ModalDimOverlay.Visibility = [System.Windows.Visibility]::Collapsed
                $ModalDimOverlay.IsHitTestVisible = $false
            })
        $timer.Start()
    }
}

function Open-InWindowModal {
    param(
        [Parameter(Mandatory = $true)]$Control,
        [ValidateSet('Guide', 'Dialog')][string]$Kind = 'Dialog',
        [scriptblock]$CloseCallback = $null
    )

    if (-not $ModalHost) { throw 'ModalHost is unavailable.' }
    if (-not $ModalDimOverlay) { throw 'ModalDimOverlay is unavailable.' }

    if ($script:activeModalControl) { Close-InWindowModal -Immediate $true }

    $script:activeModalControl = $Control
    $script:activeModalKind = $Kind
    $script:activeModalClosing = $false
    $script:activeModalCloseCallback = $CloseCallback

    try { $Control.CacheMode = $null } catch {}
    try { $Control.RenderTransform = $null } catch {}
    try { $Control.Opacity = 0.0 } catch {}

    $Control.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $Control.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $ModalHost.Children.Clear()
    [void]$ModalHost.Children.Add($Control)
    $ModalHost.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $ModalHost.VerticalAlignment = [System.Windows.VerticalAlignment]::Stretch
    $ModalHost.Visibility = [System.Windows.Visibility]::Visible
    $ModalHost.IsHitTestVisible = $true

    $ModalHost.UpdateLayout()

    $ModalDimOverlay.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $null)
    $ModalDimOverlay.Opacity = 0.0
    $ModalDimOverlay.Visibility = [System.Windows.Visibility]::Visible
    $ModalDimOverlay.IsHitTestVisible = $true

    $duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(190))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut

    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, $duration)
    $fade.EasingFunction = $ease
    $fade.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
    $Control.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)

    $dimAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 0.22, $duration)
    $dimAnim.EasingFunction = $ease
    $dimAnim.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
    $ModalDimOverlay.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $dimAnim)
}

function Close-InWindowModal {
    param([bool]$Immediate = $false)

    if ($script:activeModalClosing -and -not $Immediate) { return }

    $control = $script:activeModalControl
    if (-not $control) {
        Set-AppDimState -Dim $false
        return
    }

    if ($Immediate) {
        $callback = $script:activeModalCloseCallback
        $script:activeModalControl = $null
        $script:activeModalKind = $null
        $script:activeModalCloseCallback = $null
        $script:activeModalClosing = $false

        try { $control.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null) } catch {}
        $ModalHost.Children.Clear()
        $ModalHost.Visibility = [System.Windows.Visibility]::Collapsed
        $ModalHost.IsHitTestVisible = $false
        Set-AppDimState -Dim $false -Immediate $true
        if ($callback) { & $callback }
        return
    }

    $script:activeModalClosing = $true
    $ModalHost.IsHitTestVisible = $false

    try { $control.CacheMode = $null } catch {}
    try { $control.RenderTransform = $null } catch {}

    $duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(150))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseIn

    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation([double]$control.Opacity, 0.0, $duration)
    $fade.EasingFunction = $ease
    $fade.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
    $control.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)

    $dimAnim = New-Object System.Windows.Media.Animation.DoubleAnimation([double]$ModalDimOverlay.Opacity, 0.0, $duration)
    $dimAnim.EasingFunction = $ease
    $dimAnim.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
    $ModalDimOverlay.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $dimAnim)

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(160)
    $timer.Add_Tick({
            param($sender, $e)
            $sender.Stop()

            $callback = $script:activeModalCloseCallback
            $script:activeModalControl = $null
            $script:activeModalKind = $null
            $script:activeModalCloseCallback = $null
            $script:activeModalClosing = $false

            try { $control.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null) } catch {}

            $ModalHost.Children.Clear()
            $ModalHost.Visibility = [System.Windows.Visibility]::Collapsed
            $ModalHost.IsHitTestVisible = $false

            $ModalDimOverlay.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $null)
            $ModalDimOverlay.Opacity = 0.0
            $ModalDimOverlay.Visibility = [System.Windows.Visibility]::Collapsed
            $ModalDimOverlay.IsHitTestVisible = $false

            if ($callback) { & $callback }
        })
    $timer.Start()
}

if ($ModalHost) {
    $ModalHost.Add_PreviewMouseLeftButtonDown({
            param($s, $e)
            if (-not $script:activeModalControl -or $script:activeModalClosing) { return }
            $source = $e.OriginalSource -as [System.Windows.DependencyObject]
            $inside = $false
            try {
                if ($source) { $inside = $source.IsDescendantOf($script:activeModalControl) }
            }
            catch { $inside = $false }
            if (-not $inside) {
                Close-InWindowModal
                $e.Handled = $true
            }
        })
}

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
    return 'auto'
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

$saveHandler = { Save-Settings }
$RegionBox.Add_SelectionChanged($saveHandler)
$ResolutionBox.Add_SelectionChanged($saveHandler)
$TargetBox.Add_SelectionChanged($saveHandler)
$StyleBox.Add_SelectionChanged($saveHandler)
$FolderBox.Add_TextChanged($saveHandler)

$FolderBox.Add_PreviewMouseLeftButtonDown({
        $picked = $null
        $modernFailed = $false

        try {
            $dialog = New-Object Microsoft.Win32.OpenFolderDialog
            $dialog.Title = 'Select Download Folder'
            if (Test-Path -LiteralPath $FolderBox.Text) {
                $dialog.InitialDirectory = $FolderBox.Text
            }

            [BingWallpaperNative]::EnableDarkDialogs()

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
            $modernFailed = $true
        }

        if ($modernFailed) {
            $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
            $legacyRes = [BingWallpaperNative]::PickFolder($helper.Handle, 'Select Download Folder')
            if (-not [string]::IsNullOrEmpty($legacyRes)) {
                $picked = $legacyRes
            }
        }

        if ($picked) {
            $FolderBox.Text = $picked
        }
    })

$script:selection = @{
    Card  = $null
    Image = $null
}

$cardUnselectedBg = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(140, 10, 12, 18)))
$cardHoverBg = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(190, 20, 22, 30)))

function Get-ImageAccentBrush([string]$imagePath) {
    try {
        return [BingWallpaper.FastAccent]::ExtractBrush($imagePath)
    }
    catch {
        return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(235, 70, 70, 70))
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

function Start-CardDownloadAnimation($card) {
    if (-not $card) { return }
    $shimmer = $card.Resources['ShimmerOverlay']
    $transform = $card.Resources['ShimmerTransform']
    if (-not $shimmer -or -not $transform) { return }

    $transform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
    $shimmer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $shimmer.Opacity = 0
    $transform.X = -160

    $duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(850))

    $sweepAnim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $sweepAnim.From = -160
    $sweepAnim.To = 460
    $sweepAnim.Duration = $duration
    $sweepAnim.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
    $sweepAnim.EasingFunction = $ease

    $shimmerOpacityAnim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $shimmerOpacityAnim.From = 1.0
    $shimmerOpacityAnim.To = 1.0
    $shimmerOpacityAnim.Duration = $duration
    $shimmerOpacityAnim.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop

    $transform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $sweepAnim)
    $shimmer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $shimmerOpacityAnim)
}

function Stop-CardDownloadAnimation($card, [bool]$Success) {}

$statusDefaultBrush = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(136, 136, 136)))
$statusSuccessBrush = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(52, 211, 153)))
$statusErrorBrush = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(248, 113, 113)))
$script:statusResetTimer = $null
$script:fadeTimer = $null
$script:loadingStatusTimer = $null
$script:downloadTimer = $null
$script:dlContext = $null
$script:applyTimer = $null
$script:applyContext = $null
$script:galleryTimer = $null
$script:galleryRunspaceContext = $null
$script:updateTimer = $null
$script:updateContext = $null
$script:updateDlTimer = $null
$script:updateDlContext = $null

function Apply-WallpaperAsync {
    param(
        $Image,
        $Card,
        [string]$Resolution,
        [string]$Target,
        [string]$Style
    )
    if (-not $Image) { return }
    $actionTitle = Get-CleanImageTitle $Image

    $UpdateBtn.IsEnabled = $false
    $DownloadBtn.IsEnabled = $false
    $StatusText.Foreground = $statusDefaultBrush
    $StatusText.Text = "Applying $actionTitle..."

    if ($Card) { Start-CardDownloadAnimation $Card }

    $imageUri = Get-BingImageUri -Image $Image -Resolution $Resolution
    $cacheDir = Join-Path $env:LOCALAPPDATA 'BingWallpaper\Cache'
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        try { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null } catch {}
    }
    $cachePath = Join-Path $cacheDir "current_wallpaper.jpg"
    $tempPath = "$cachePath.tmp"

    $fnLockScreenCode = "function Set-LockScreenImageIsolated { " + ${function:Set-LockScreenImageIsolated}.ToString() + " }"

    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param([string]$Uri, [string]$Temp, [string]$Dest, [string]$TargetParam, [string]$StyleParam, [string]$LockScreenFnCode)
            try {
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                $wc.DownloadFile($Uri, $Temp)
                $wc.Dispose()
                if (Test-Path -LiteralPath $Temp) {
                    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue }
                    Move-Item -LiteralPath $Temp -Destination $Dest -Force
                }

                if ($TargetParam -eq 'Desktop' -or $TargetParam -eq 'Both') {
                    $styleVal = '6'; $tileVal = '0'
                    switch ($StyleParam) {
                        'Fit' { $styleVal = '6'; $tileVal = '0' }
                        'Fill' { $styleVal = '10'; $tileVal = '0' }
                        'Stretch' { $styleVal = '2'; $tileVal = '0' }
                        'Center' { $styleVal = '0'; $tileVal = '0' }
                        'Tile' { $styleVal = '0'; $tileVal = '1' }
                        'Span' { $styleVal = '22'; $tileVal = '0' }
                    }
                    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'WallpaperStyle' -Value $styleVal -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'TileWallpaper' -Value $tileVal -Force -ErrorAction SilentlyContinue

                    if (![BingWallpaperNative]::SystemParametersInfo(20, 0, $Dest, 3)) {
                        throw 'Windows could not apply the downloaded image as desktop wallpaper.'
                    }
                }

                if ($TargetParam -eq 'Lock screen' -or $TargetParam -eq 'Both') {
                    Invoke-Expression $LockScreenFnCode
                    $cacheDirectory = Split-Path -Parent $Dest
                    $lockScreenCachePath = Join-Path $cacheDirectory "current_lockscreen.jpg"
                    Copy-Item -LiteralPath $Dest -Destination $lockScreenCachePath -Force
                    $resLock = Set-LockScreenImageIsolated -ImagePath $lockScreenCachePath
                    if (-not $resLock) { throw 'Windows could not apply the lock screen image.' }
                }

                return @{ Success = $true; Error = $null; Dest = $Dest }
            }
            catch {
                return @{ Success = $false; Error = $_.Exception.Message; Dest = $Dest }
            }
        }).AddArgument($imageUri).AddArgument($tempPath).AddArgument($cachePath).AddArgument($Target).AddArgument($Style).AddArgument($fnLockScreenCode)

    $asyncOp = $ps.BeginInvoke()
    $script:applyContext = @{ PS = $ps; AsyncOp = $asyncOp; Target = $Target }

    if ($script:applyTimer) {
        $script:applyTimer.Stop()
        $script:applyTimer = $null
    }

    $script:applyTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:applyTimer.Interval = [TimeSpan]::FromMilliseconds(30)
    $script:applyTimer.Add_Tick({
            param($timerSender, $timerArgs)
            if (-not $script:applyContext) {
                $timerSender.Stop()
                return
            }
            if ($script:applyContext.AsyncOp.IsCompleted) {
                $timerSender.Stop()
                $ctx = $script:applyContext
                $script:applyContext = $null
                $script:applyTimer = $null

                $isSuccess = $false
                $errorMsg = $null
                try {
                    $resCollection = $ctx.PS.EndInvoke($ctx.AsyncOp)
                    $res = if ($resCollection -and $resCollection.Count -gt 0) { $resCollection[0] } else { $null }
                    $isSuccess = ($res -and $res.Success -eq $true)
                    $errorMsg = if ($res) { $res.Error } else { $null }
                }
                catch {
                    $isSuccess = $false
                    $errorMsg = $_.Exception.Message
                }
                finally {
                    try { $ctx.PS.Dispose() } catch {}
                    $UpdateBtn.IsEnabled = $true
                    $DownloadBtn.IsEnabled = $true
                }

                if ($isSuccess) {
                    Set-TransientStatus -Message (Get-AppliedSuccessMessage $ctx.Target)
                }
                else {
                    $errMsg = Get-UserFriendlyNetworkError -Exception (New-Object Exception($errorMsg)) -DefaultAction "apply wallpaper"
                    Set-TransientStatus -Message $errMsg -Brush $statusErrorBrush -Seconds 5
                }
            }
        })
    $script:applyTimer.Start()
}

function Restore-StatusTextDefaultWithFade {
    if (-not $script:loadedImages -or $script:loadedImages.Count -eq 0) {
        $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $StatusText.Opacity = 1
        $StatusText.Foreground = $statusErrorBrush
        $StatusText.Text = 'Unable to load wallpapers. Please check your internet connection.'
        return
    }

    $fadeDuration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(300))
    $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 1, 0, $fadeDuration
    $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeOut)
    
    if ($script:fadeTimer) { $script:fadeTimer.Stop() }
    $script:fadeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:fadeTimer.Interval = [TimeSpan]::FromMilliseconds(320)
    $script:fadeTimer.Add_Tick({
            $script:fadeTimer.Stop()
            if (-not $script:loadedImages -or $script:loadedImages.Count -eq 0) {
                $StatusText.Foreground = $statusErrorBrush
                $StatusText.Text = 'Unable to load wallpapers. Please check your internet connection.'
            }
            else {
                $StatusText.Foreground = $statusDefaultBrush
                $StatusText.Text = 'Double-click any wallpaper to apply'
            }
            $dur = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(300))
            $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, $dur)
            $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)
            [BingWallpaperNative]::FlushMemory()
        })
    $script:fadeTimer.Start()
}

function Get-AppliedSuccessMessage([string]$target) {
    switch ($target) {
        'Desktop' { return "Success! Wallpaper applied to background" }
        'Lock screen' { return "Success! Wallpaper applied to Lockscreen" }
        'Both' { return "Success! Wallpaper applied to background and Lockscreen" }
        Default { return "Success! Wallpaper applied to $target" }
    }
}

function Get-UserFriendlyNetworkError {
    param(
        [System.Exception]$Exception,
        [string]$DefaultAction = "load wallpapers"
    )
    $msg = if ($Exception) { $Exception.Message } else { '' }
    if (-not $msg -or $msg -match 'internet|connection|resolve|network|timed? out|connect|offline|webexception|remote name|host|dns|socket|no such host|server|unable to connect|404|500|502|503') {
        return "Unable to $DefaultAction. Please check your internet connection."
    }
    if ($msg.Length -lt 70 -and $msg -notmatch 'Exception|System\.|at BingWallpaper|at Microsoft|Invoke-') {
        return $msg
    }
    return "Unable to $DefaultAction. Please check your internet connection."
}

$script:SpotlightTaskName = 'BingWallpaperSpotlight'
$script:SpotlightScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$script:SpotlightEnabled = $false
$script:SpotlightHideTimer = $null

$script:pillBgBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(38, 38, 38))
$script:pillBorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(61, 61, 61))
if ($SpotlightPill) {
    $SpotlightPill.Background = $script:pillBgBrush
    $SpotlightPill.BorderBrush = $script:pillBorderBrush
}

$processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:SpotlightScriptPath = if ($processPath -match '\.exe$' -and $processPath -notmatch 'powershell\.exe|pwsh\.exe|pwsh-login\.exe') {
    $processPath
}
elseif ($PSCommandPath) {
    (Resolve-Path -LiteralPath $PSCommandPath).Path
}
elseif ($PSScriptRoot) {
    (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Bing-Wallpaper-UI.ps1')).Path
}
else {
    try { (Resolve-Path -LiteralPath 'Bing-Wallpaper-UI.ps1' -ErrorAction Stop).Path } catch { $null }
}

function Update-SpotlightScheduledTaskAsync {
    param([bool]$Enable)

    $bgEnable = $Enable
    $bgMinutes = if ($SpotlightIntervalBox -and $SpotlightIntervalBox.SelectedItem) { [int]$SpotlightIntervalBox.SelectedItem.Tag } else { 60 }
    $bgTarget = if ($SpotlightTargetBox -and $SpotlightTargetBox.SelectedItem) { [string]$SpotlightTargetBox.SelectedItem } else { 'Desktop' }
    $bgScriptPath = $script:SpotlightScriptPath
    $bgAppDataRoot = $env:LOCALAPPDATA

    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param([bool]$Enable, [int]$Minutes, [string]$Target, [string]$ScriptPath, [string]$AppDataRoot)
            try {
                if ($Enable) {
                    $appDataDir = Join-Path $AppDataRoot 'BingWallpaper'
                    if (-not (Test-Path -LiteralPath $appDataDir)) {
                        New-Item -ItemType Directory -Path $appDataDir -Force | Out-Null
                    }

                    $persistentExePath = Join-Path $appDataDir 'AutoScape.exe'
                    if ($ScriptPath -and (Test-Path -LiteralPath $ScriptPath)) {
                        try { Copy-Item -LiteralPath $ScriptPath -Destination $persistentExePath -Force } catch {}
                    }
                
                    $actionArgs = "-AutoApply -Target `"$Target`""
                    $action = New-ScheduledTaskAction -Execute $persistentExePath -Argument $actionArgs
                    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden -ExecutionTimeLimit (New-TimeSpan -Hours 2)

                    if ($Minutes -eq 0) {
                        $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
                    }
                    elseif ($Minutes -le 1) {
                        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
                    }
                    elseif ($Minutes -lt 60) {
                        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $Minutes)
                    }
                    elseif ($Minutes -lt 1440) {
                        $hours = [math]::Max(1, [int]($Minutes / 60))
                        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours $hours)
                    }
                    else {
                        $trigger = New-ScheduledTaskTrigger -Daily -At ((Get-Date).Date)
                    }

                    Register-ScheduledTask -TaskName "BingWallpaperSpotlight" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
                }
                else {
                    Unregister-ScheduledTask -TaskName "BingWallpaperSpotlight" -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
            catch {}
        }).AddArgument($bgEnable).AddArgument($bgMinutes).AddArgument($bgTarget).AddArgument($bgScriptPath).AddArgument($bgAppDataRoot)

    $null = $ps.BeginInvoke()
}

function Set-SpotlightState {
    param([bool]$Enabled, [bool]$Animate = $true, [bool]$UpdateTask = $true)
    $script:SpotlightEnabled = $Enabled

    if ($script:SpotlightHideTimer) {
        $script:SpotlightHideTimer.Stop()
        $script:SpotlightHideTimer = $null
    }

    $targetX = if ($Enabled) { 26.0 } else { 0.0 }
    $targetBgColor = if ($Enabled) { [System.Windows.Media.Color]::FromRgb(0, 120, 212) } else { [System.Windows.Media.Color]::FromRgb(38, 38, 38) }
    $targetBorderColor = if ($Enabled) { [System.Windows.Media.Color]::FromRgb(0, 120, 212) } else { [System.Windows.Media.Color]::FromRgb(61, 61, 61) }
    $targetGlowOpacity = if ($Enabled) { 0.65 } else { 0.0 }

    if ($Animate) {
        $dur = [TimeSpan]::FromMilliseconds(200)
        $easing = New-Object System.Windows.Media.Animation.CubicEase
        $easing.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut

        $thumbAnim = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList $targetX, (New-Object System.Windows.Duration($dur))
        $thumbAnim.EasingFunction = $easing
        $SpotlightThumb.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $thumbAnim)

        $bgAnim = New-Object System.Windows.Media.Animation.ColorAnimation -ArgumentList $targetBgColor, (New-Object System.Windows.Duration($dur))
        $bgAnim.EasingFunction = $easing
        $script:pillBgBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $bgAnim)

        $borderAnim = New-Object System.Windows.Media.ColorAnimation -ArgumentList $targetBorderColor, (New-Object System.Windows.Duration($dur))
        $borderAnim.EasingFunction = $easing
        $script:pillBorderBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $borderAnim)

        if ($SpotlightGlow) {
            $glowAnim = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList $targetGlowOpacity, (New-Object System.Windows.Duration($dur))
            $glowAnim.EasingFunction = $easing
            $SpotlightGlow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $glowAnim)
        }

        if ($Enabled) {
            $SpotlightOptionsContainer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $SpotlightOptionsContainer.Opacity = 0
            $SpotlightOptionsContainer.Visibility = [System.Windows.Visibility]::Visible

            $fadeAnim = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 0.0, 1.0, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(220)))
            $fadeAnim.EasingFunction = $easing
            $SpotlightOptionsContainer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeAnim)
        }
        else {
            $fadeAnim = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 1.0, 0.0, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(180)))
            $SpotlightOptionsContainer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeAnim)

            $script:SpotlightHideTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:SpotlightHideTimer.Interval = [TimeSpan]::FromMilliseconds(190)
            $script:SpotlightHideTimer.Add_Tick({
                    if ($script:SpotlightHideTimer) {
                        $script:SpotlightHideTimer.Stop()
                        $script:SpotlightHideTimer = $null
                    }
                    if (-not $script:SpotlightEnabled) {
                        $SpotlightOptionsContainer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                        $SpotlightOptionsContainer.Visibility = [System.Windows.Visibility]::Collapsed
                    }
                })
            $script:SpotlightHideTimer.Start()
        }
    }
    else {
        $SpotlightThumb.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
        $SpotlightThumb.RenderTransform.X = $targetX

        $script:pillBgBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $null)
        $script:pillBgBrush.Color = $targetBgColor

        $script:pillBorderBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $null)
        $script:pillBorderBrush.Color = $targetBorderColor

        if ($SpotlightGlow) {
            $SpotlightGlow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $null)
            $SpotlightGlow.Opacity = $targetGlowOpacity
        }

        $SpotlightOptionsContainer.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        if ($Enabled) {
            $SpotlightOptionsContainer.Opacity = 1
            $SpotlightOptionsContainer.Visibility = [System.Windows.Visibility]::Visible
        }
        else {
            $SpotlightOptionsContainer.Opacity = 0
            $SpotlightOptionsContainer.Visibility = [System.Windows.Visibility]::Collapsed
        }
    }

    if ($UpdateTask) {
        Update-SpotlightScheduledTaskAsync -Enable $Enabled
        Save-Settings
    }
}

function Set-TransientStatus {
    param(
        [string]$Message,
        [System.Windows.Media.Brush]$Brush = $statusSuccessBrush,
        [double]$Seconds = 3.5
    )
    if ($script:statusResetTimer) {
        $script:statusResetTimer.Stop()
    }
    
    $StatusText.Foreground = $Brush
    $StatusText.Text = $Message
    
    $fadeDuration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(300))
    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 0, 1, $fadeDuration
    $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)

    $script:statusResetTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:statusResetTimer.Interval = [TimeSpan]::FromSeconds($Seconds)
    $script:statusResetTimer.Add_Tick({
            $script:statusResetTimer.Stop()
            Restore-StatusTextDefaultWithFade
        })
    $script:statusResetTimer.Start()
}

function Format-MarkdownForDialog {
    param([string]$Text)
    if (-not $Text) { return '' }
    $bullet = [char]0x2022
    $lines = $Text -split "\r?\n"
    $cleanLines = @()
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { 
            if ($cleanLines.Count -gt 0 -and $cleanLines[-1] -ne '') { $cleanLines += '' }
            continue 
        }
        $cleaned = $trimmed -replace '^#{1,6}\s*', ''
        $cleaned = $cleaned -replace '\[([^\]]+)\]\([^\)]+\)', '$1'
        $cleaned = $cleaned -replace '\*\*([^\*]+)\*\*', '$1'
        $cleaned = $cleaned -replace '\*([^\*]+)\*', '$1'
        $cleaned = $cleaned -replace '__([^_]+)__', '$1'
        $cleaned = $cleaned -replace '`([^`]+)`', '$1'
        $cleaned = $cleaned -replace '^[-*]\s+', "$bullet "
        $cleaned = $cleaned -replace '\b([a-f0-9]{7})[a-f0-9]{33}\b', '$1'
        $cleanLines += $cleaned
    }
    return ($cleanLines -join "`n").Trim()
}

function Show-ModernDialog {
    param(
        [string]$Title = 'AutoScape',
        [string]$Header = 'AutoScape',
        [string]$Message = '',
        [string]$Details = '',
        [ValidateSet('Info', 'Update', 'Error', 'Success')]
        [string]$Icon = 'Info',
        [ValidateSet('OK', 'YesNo')]
        [string]$Buttons = 'OK',
        [System.Windows.Window]$ParentWindow = $window
    )

    $dialogXaml = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="460" Background="#181818" Foreground="#F0F0F0" FontFamily="Segoe UI">
    <UserControl.Resources>
        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="8"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="Transparent">
                            <Track Name="PART_Track" IsDirectionReversed="true">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.LineUpCommand}" Opacity="0" Focusable="False"/>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb>
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="Thumb">
                                                <Border Name="ThumbBorder" Background="#4A4A4A" CornerRadius="4" Margin="2,0,2,0"/>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="ThumbBorder" Property="Background" Value="#6E6E6E"/>
                                                    </Trigger>
                                                    <Trigger Property="IsDragging" Value="True">
                                                        <Setter TargetName="ThumbBorder" Property="Background" Value="#888888"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.LineDownCommand}" Opacity="0" Focusable="False"/>
                                </Track.IncreaseRepeatButton>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

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
    </UserControl.Resources>

    <Border Name="DialogRoot" Padding="24" Background="#181818" Opacity="0">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Grid Grid.Row="0" Margin="0,0,0,16">
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

            <Border Name="DetailsCard" Grid.Row="1" Background="#212121" BorderBrush="#333333" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,0,0,18" MaxHeight="145" Visibility="Collapsed">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" FocusVisualStyle="{x:Null}">
                    <TextBlock Name="DetailsContent" FontSize="13" Foreground="#CCCCCC" TextWrapping="Wrap" LineHeight="19" FontFamily="Segoe UI"/>
                </ScrollViewer>
            </Border>

            <StackPanel Name="ButtonPanel" Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,6,0,0"/>
        </Grid>
    </Border>
</UserControl>
"@

    $r = New-Object System.Xml.XmlNodeReader ([xml]$dialogXaml)
    $dlg = [Windows.Markup.XamlReader]::Load($r)
    
    $badgeBorder = $dlg.FindName('BadgeBorder')
    $badgePath = $dlg.FindName('BadgePath')
    $dialogHeader = $dlg.FindName('DialogHeader')
    $dialogMessage = $dlg.FindName('DialogMessage')
    $detailsCard = $dlg.FindName('DetailsCard')
    $detailsContent = $dlg.FindName('DetailsContent')
    $buttonPanel = $dlg.FindName('ButtonPanel')

    $dialogHeader.Text = $Header
    $dialogMessage.Text = $Message

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
        Default {
            $badgeBorder.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 18, 48, 76))
            $badgePath.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 96, 165, 250))
            $badgePath.Data = [System.Windows.Media.Geometry]::Parse("M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z")
        }
    }

    if ($Details) {
        $detailsContent.Text = Format-MarkdownForDialog $Details
        $detailsCard.Visibility = [System.Windows.Visibility]::Visible
    }

    $script:dialogChoice = 'Cancel'
    $btnStyle = $dlg.FindResource('DialogBtn')
    $frame = New-Object System.Windows.Threading.DispatcherFrame

    $closeWithFade = {
        param([string]$choice)
        $script:dialogChoice = $choice
        Close-InWindowModal
    }

    if ($Buttons -eq 'YesNo') {
        $btnNo = New-Object System.Windows.Controls.Button
        $btnNo.Style = $btnStyle
        $btnNo.Content = 'Not Now'
        $btnNo.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 42, 42, 42))
        $btnNo.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 220, 220, 220))
        $btnNo.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 60, 60, 60))
        $btnNo.BorderThickness = New-Object System.Windows.Thickness(1)
        $btnNo.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
        $btnNo.Add_Click({ & $closeWithFade 'No' })
        $buttonPanel.Children.Add($btnNo) | Out-Null

        $btnYes = New-Object System.Windows.Controls.Button
        $btnYes.Style = $btnStyle
        $btnYes.Content = 'Update Now'
        $btnYes.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 0, 120, 212))
        $btnYes.Foreground = [System.Windows.Media.Brushes]::White
        $btnYes.BorderThickness = New-Object System.Windows.Thickness(0)
        $btnYes.IsDefault = $true
        $btnYes.Add_Click({ & $closeWithFade 'Yes' })
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
        $btnOk.Add_Click({ & $closeWithFade 'OK' })
        $buttonPanel.Children.Add($btnOk) | Out-Null
    }

    $dlg.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $e.Handled = $true; & $closeWithFade 'Cancel' }
        })

    $root = $dlg.FindName('DialogRoot')
    if ($root) { $root.Opacity = 1.0 }

    Open-InWindowModal -Control $dlg -Kind 'Dialog' -CloseCallback {
        $frame.Continue = $false
        try { [BingWallpaperNative]::FlushMemory() } catch {}
    }

    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    return $script:dialogChoice
}

function Start-VerifiedUpdate {
    if ($script:updateContext -or $script:updateDlContext) { return }
    $CheckUpdateBtn.IsEnabled = $false
    Set-TransientStatus -Message 'Checking for updates...' -Brush $statusDefaultBrush -Seconds 8

    $repo = $script:updateRepository
    $currentVersion = $script:appVersion
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param([string]$Repository, [Version]$CurrentAppVersion)
            try {
                function Invoke-GhJson([string]$Uri) {
                    try {
                        return Invoke-RestMethod -Uri $Uri -Headers @{ 'User-Agent' = 'BingWallpaper-Updater' } -UseBasicParsing -ErrorAction Stop
                    }
                    catch {
                        $wc = New-Object System.Net.WebClient
                        $wc.Headers.Add('User-Agent', 'BingWallpaper-Updater')
                        return $wc.DownloadString($Uri) | ConvertFrom-Json
                    }
                }

                function Parse-RelVer([string]$TagName, [string]$ReleaseName, [string]$ReleaseBody) {
                    $cleanTag = ($TagName -replace '^[vV]', '').Trim()
                    if ($cleanTag -match '^\d+(\.\d+){1,3}$') { return [Version]$cleanTag }
                    if ($ReleaseName -match '[vV]?(\d+\.\d+(\.\d+){0,2})') {
                        $v = $Matches[1]
                        if ($v -notmatch '\.') { $v = "$v.0" }
                        if ($v -match '^\d+(\.\d+){1,3}$') { return [Version]$v }
                    }
                    if ($ReleaseBody -match '[vV]?(\d+\.\d+(\.\d+){0,2})') {
                        $v = $Matches[1]
                        if ($v -notmatch '\.') { $v = "$v.0" }
                        if ($v -match '^\d+(\.\d+){1,3}$') { return [Version]$v }
                    }
                    return $null
                }

                $release = $null
                $latestVersion = $null

                try {
                    $releaseUri = "https://api.github.com/repos/$Repository/releases/latest"
                    $latestRel = Invoke-GhJson -Uri $releaseUri
                    $latestVersion = Parse-RelVer -TagName $latestRel.tag_name -ReleaseName $latestRel.name -ReleaseBody $latestRel.body
                    $release = $latestRel
                }
                catch {
                    $allReleasesUri = "https://api.github.com/repos/$Repository/releases?per_page=10"
                    $allReleases = Invoke-GhJson -Uri $allReleasesUri
                    foreach ($rel in $allReleases) {
                        try {
                            $ver = Parse-RelVer -TagName $rel.tag_name -ReleaseName $rel.name -ReleaseBody $rel.body
                            if ($ver -and ($null -eq $latestVersion -or $ver -gt $latestVersion)) {
                                $latestVersion = $ver
                                $release = $rel
                            }
                        }
                        catch {}
                    }
                }

                if (-not $release -or -not $latestVersion) {
                    return @{ Success = $false; Error = "No releases with a valid version tag were found in repository '$Repository'." }
                }

                $hasUpdate = ($latestVersion -gt $CurrentAppVersion)
                return @{
                    Success       = $true
                    HasUpdate     = $hasUpdate
                    LatestVersion = $latestVersion.ToString()
                    Release       = $release
                    Error         = $null
                }
            }
            catch {
                return @{ Success = $false; Error = $_.Exception.Message }
            }
        }).AddArgument($repo).AddArgument($currentVersion)

    $asyncOp = $ps.BeginInvoke()
    $script:updateContext = @{
        PS        = $ps
        AsyncOp   = $asyncOp
        Stopwatch = $stopwatch
    }

    if ($script:updateTimer) {
        $script:updateTimer.Stop()
        $script:updateTimer = $null
    }

    $script:updateTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:updateTimer.Interval = [TimeSpan]::FromMilliseconds(40)
    $script:updateTimer.Add_Tick({
            param($timerSender, $timerArgs)
            if (-not $script:updateContext) {
                $timerSender.Stop()
                return
            }

            if ($script:updateContext.AsyncOp.IsCompleted -and $script:updateContext.Stopwatch.ElapsedMilliseconds -ge 750) {
                $timerSender.Stop()
                $ctx = $script:updateContext
                $script:updateContext = $null
                $script:updateTimer = $null

                $isSuccess = $false
                $errorMsg = $null
                $hasUpdate = $false
                $latestVersionStr = ''
                $release = $null

                try {
                    $resCollection = $ctx.PS.EndInvoke($ctx.AsyncOp)
                    $res = if ($resCollection -and $resCollection.Count -gt 0) { $resCollection[0] } else { $null }
                    $isSuccess = ($res -and $res.Success -eq $true)
                    if ($isSuccess) {
                        $hasUpdate = [bool]$res.HasUpdate
                        $latestVersionStr = [string]$res.LatestVersion
                        $release = $res.Release
                    }
                    else {
                        $errorMsg = if ($res) { $res.Error } else { "Failed to check for updates." }
                    }
                }
                catch {
                    $isSuccess = $false
                    $errorMsg = $_.Exception.Message
                }
                finally {
                    try { $ctx.PS.Dispose() } catch {}
                    $CheckUpdateBtn.IsEnabled = $true
                }

                if (-not $isSuccess) {
                    $errMsg = Get-UserFriendlyNetworkError -Exception (New-Object Exception($errorMsg)) -DefaultAction "check for updates"
                    Set-TransientStatus -Message $errMsg -Brush $statusErrorBrush -Seconds 5
                    Show-ModernDialog -Title "Update Error" -Header "Connection Error" -Message $errMsg -Icon "Error" -Buttons "OK" | Out-Null
                    return
                }

                if (-not $hasUpdate) {
                    Set-TransientStatus -Message 'You are up to date.' -Brush $statusSuccessBrush -Seconds 3.5
                    Show-ModernDialog -Title "AutoScape" -Header "You're all up to date" -Message "You already have the latest version ($($script:appVersion))." -Icon "Success" -Buttons "OK" | Out-Null
                    return
                }

                Set-TransientStatus -Message "Version $latestVersionStr is available." -Brush $statusDefaultBrush -Seconds 60
                $confirmation = Show-ModernDialog -Title "Update Available" -Header "Version $latestVersionStr is Available" -Message "A new update is available. Would you like to install it now? The app will restart automatically when finished." -Icon "Update" -Buttons "YesNo"
            
                if ($confirmation -ne 'Yes') {
                    Set-TransientStatus -Message 'Update cancelled.' -Brush $statusDefaultBrush -Seconds 3.5
                    return
                }

                Start-VerifiedUpdateDownloadAsync -Release $release -LatestVersionStr $latestVersionStr
            }
        })
    $script:updateTimer.Start()
}

function Start-VerifiedUpdateDownloadAsync {
    param(
        $Release,
        [string]$LatestVersionStr
    )

    $exeAsset = $Release.assets | Where-Object { $_.name -match '(?i)\.exe$' } | Select-Object -First 1
    $checksumAsset = $Release.assets | Where-Object { $_.name -match '(?i)\.sha256$' } | Select-Object -First 1

    if (-not $exeAsset) {
        $errMsg = 'This release does not include an executable (.exe) asset.'
        Set-TransientStatus -Message $errMsg -Brush $statusErrorBrush -Seconds 5
        Show-ModernDialog -Title "Update Error" -Header "Update Failed" -Message $errMsg -Icon "Error" -Buttons "OK" | Out-Null
        return
    }

    $installedExe = $null
    $candidates = @()
    if ($PSScriptRoot) { $candidates += (Join-Path $PSScriptRoot 'AutoScape.exe') }
    $candidates += (Join-Path (Get-Location).Path 'AutoScape.exe')
    $candidates += (Join-Path $env:LOCALAPPDATA 'BingWallpaper\AutoScape.exe')

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            $installedExe = (Resolve-Path -LiteralPath $c).Path
            break
        }
    }

    if (-not $installedExe) {
        $appDir = Join-Path $env:LOCALAPPDATA 'BingWallpaper'
        if (-not (Test-Path -LiteralPath $appDir)) { New-Item -ItemType Directory -Path $appDir -Force | Out-Null }
        $installedExe = Join-Path $appDir 'AutoScape.exe'
    }

    $CheckUpdateBtn.IsEnabled = $false
    Set-TransientStatus -Message "Downloading version $LatestVersionStr..." -Brush $statusDefaultBrush -Seconds 60

    $downloadUrl = [string]$exeAsset.browser_download_url
    $checksumUrl = if ($checksumAsset) { [string]$checksumAsset.browser_download_url } else { $null }
    $publisherThumbprint = $script:updatePublisherThumbprint

    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param([string]$DownloadUrl, [string]$ChecksumUrl, [string]$LatestVer, [string]$PublisherThumbprint)

            $client = $null
            $downloadPath = $null
            try {
                $downloadPath = Join-Path $env:TEMP "AutoScape-update-$([Guid]::NewGuid().ToString('N')).exe"
                $client = New-Object System.Net.WebClient
                $client.Headers.Add('User-Agent', 'AutoScape-Updater')
                $client.DownloadFile($DownloadUrl, $downloadPath)

                if ($ChecksumUrl) {
                    try {
                        $checksumText = $client.DownloadString($ChecksumUrl)
                        $match = [regex]::Match($checksumText, '(?im)\b[a-f0-9]{64}\b')
                        if ($match.Success) {
                            $expectedHash = $match.Value.ToUpperInvariant()
                            $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToUpperInvariant()
                            if ($actualHash -ne $expectedHash) {
                                throw 'The downloaded update failed SHA-256 verification.'
                            }
                        }
                    }
                    catch {
                        if ($_ -like "*failed SHA-256*") { throw $_ }
                    }
                }

                if ($PublisherThumbprint) {
                    $signature = Get-AuthenticodeSignature -FilePath $downloadPath
                    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $PublisherThumbprint) {
                        throw 'The update failed Authenticode signature verification.'
                    }
                }

                return @{ Success = $true; DownloadPath = $downloadPath; Error = $null }
            }
            catch {
                if ($downloadPath) { Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue }
                return @{ Success = $false; DownloadPath = $null; Error = $_.Exception.Message }
            }
            finally {
                if ($client) { $client.Dispose() }
            }
        }).AddArgument($downloadUrl).AddArgument($checksumUrl).AddArgument($LatestVersionStr).AddArgument($publisherThumbprint)

    $asyncOp = $ps.BeginInvoke()
    $script:updateDlContext = @{
        PS           = $ps
        AsyncOp      = $asyncOp
        InstalledExe = $installedExe
    }

    if ($script:updateDlTimer) { $script:updateDlTimer.Stop() }
    $script:updateDlTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:updateDlTimer.Interval = [TimeSpan]::FromMilliseconds(40)

    $script:updateDlTimer.Add_Tick({
            param($timerSender, $timerArgs)
            if (-not $script:updateDlContext) { $timerSender.Stop(); return }
            if (-not $script:updateDlContext.AsyncOp.IsCompleted) { return }

            $timerSender.Stop()
            $ctx = $script:updateDlContext
            $script:updateDlContext = $null
            $script:updateDlTimer = $null

            try {
                $results = $ctx.PS.EndInvoke($ctx.AsyncOp)
                $res = if ($results -and $results.Count) { $results[0] } else { $null }

                if (-not $res -or $res.Success -ne $true) {
                    throw (if ($res -and $res.Error) { [string]$res.Error } else { 'The update could not be downloaded.' })
                }

                $downloadPath = [string]$res.DownloadPath
                $installedExe = [string]$ctx.InstalledExe
                $installDir = Split-Path -Parent $installedExe

                Set-TransientStatus -Message "Update downloaded. Restarting..." -Brush $statusSuccessBrush -Seconds 10
                $StatusText.Text = "Installing version $LatestVersionStr..."

                $updaterPath = Join-Path $env:TEMP "AutoScape-Updater-$([Guid]::NewGuid().ToString('N')).ps1"
                $updaterScript = @'
param(
    [string]$DownloadedExe,
    [string]$InstalledExe,
    [string]$WorkingDirectory
)

$ErrorActionPreference = 'Stop'

try {
    Start-Sleep -Seconds 1
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        $running = $false
        try {
            Get-Process -Name 'AutoScape','BingWallpaper' -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    if ($_.MainModule.FileName -and ([IO.Path]::GetFullPath($_.MainModule.FileName) -ieq [IO.Path]::GetFullPath($InstalledExe))) {
                        $running = $true
                    }
                } catch {}
            }
        } catch {}
        if (-not $running) { break }
        Start-Sleep -Milliseconds 300
    }

    $lastError = $null
    $done = $false
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $targetDir = Split-Path -Parent $InstalledExe
            if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
            Copy-Item -LiteralPath $DownloadedExe -Destination $InstalledExe -Force -ErrorAction Stop
            $done = $true
            break
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 500
        }
    }

    if (-not $done) { throw "Could not replace $InstalledExe. $lastError" }
    if (Test-Path -LiteralPath $InstalledExe) {
        Start-Process -FilePath $InstalledExe -WorkingDirectory $WorkingDirectory -ErrorAction Stop | Out-Null
    }
}
catch {
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show(
            "AutoScape could not complete the update.`n`n$($_.Exception.Message)",
            'AutoScape Update',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    } catch {}
}
finally {
    Remove-Item -LiteralPath $DownloadedExe -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}
'@

                Set-Content -LiteralPath $updaterPath -Value $updaterScript -Encoding UTF8 -ErrorAction Stop
                $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

                function Quote-UpdaterArgument([string]$Value) {
                    if ($null -eq $Value) { return '""' }
                    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
                }

                $updaterArgumentLine = @(
                    '-NoProfile'
                    '-ExecutionPolicy Bypass'
                    '-WindowStyle Hidden'
                    ('-File ' + (Quote-UpdaterArgument $updaterPath))
                    ('-DownloadedExe ' + (Quote-UpdaterArgument $downloadPath))
                    ('-InstalledExe ' + (Quote-UpdaterArgument $installedExe))
                    ('-WorkingDirectory ' + (Quote-UpdaterArgument $installDir))
                ) -join ' '

                Start-Process -FilePath $powershellExe -ArgumentList $updaterArgumentLine -WindowStyle Hidden -ErrorAction Stop | Out-Null
            
                [System.Windows.Application]::Current.Shutdown()
                [Environment]::Exit(0)
            }
            catch {
                try { $ctx.PS.Dispose() } catch {}
                if ($downloadPath) { Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue }
                if ($updaterPath) { Remove-Item -LiteralPath $updaterPath -Force -ErrorAction SilentlyContinue }

                $CheckUpdateBtn.IsEnabled = $true
                $errMsg = "The update could not be started: $($_.Exception.Message)"
                Set-TransientStatus -Message $errMsg -Brush $statusErrorBrush -Seconds 8
                Show-ModernDialog -Title "Update Error" -Header "Installation Could Not Start" -Message $errMsg -Icon "Error" -Buttons "OK" | Out-Null
            }
            finally {
                try { $ctx.PS.Dispose() } catch {}
            }
        })

    $script:updateDlTimer.Start()
}

function Show-GalleryCard {
    param(
        [System.Windows.Controls.Border]$Card,
        [int]$DelayMs = 0
    )

    $Card.Opacity = 0
    $translate = New-Object System.Windows.Media.TranslateTransform(0, 12)
    $Card.RenderTransform = $translate

    $duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(400))
    $beginTime = [TimeSpan]::FromMilliseconds($DelayMs)

    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 0, 1, $duration
    $fade.BeginTime = $beginTime
    $fade.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
    $fade.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut

    $slide = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 12, 0, $duration
    $slide.BeginTime = $beginTime
    $slide.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
    $slide.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut

    $Card.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    $translate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
}

function Update-GalleryViewportHeight {
    if ($GalleryPanel -and $GalleryPanel.Children.Count -gt 0 -and $GalleryScrollViewer) {
        $card = $GalleryPanel.Children[0]
        if ($card.ActualHeight -gt 50) {
            $rowHeight = $card.ActualHeight + 16
            $twoRowsHeight = ($rowHeight * 2) - 16
            if ($GalleryScrollViewer.MaxHeight -ne $twoRowsHeight) {
                $GalleryScrollViewer.MaxHeight = $twoRowsHeight
            }
        }
    }
}

function Render-GalleryGrid {
    param(
        [array]$Images,
        [string]$ThumbCacheDir,
        [switch]$SkipAnimation
    )

    if (-not $Images -or $Images.Count -eq 0) { return }

    $GalleryPanel.Children.Clear()
    $script:selectedCard = $null
    $script:selectedImage = $null
    $script:selection.Card = $null
    $script:selection.Image = $null
    $script:loadedImages = $Images
    $script:galleryImageControls = New-Object System.Collections.ArrayList
    $script:galleryCards = New-Object System.Collections.ArrayList

    if ($script:revealElements) {
        $staticElements = $script:revealElements | Where-Object { $_.Element.Name -eq "RevealBorder" }
        $script:revealElements.Clear()
        foreach ($item in $staticElements) { $script:revealElements.Add($item) | Out-Null }
    }

    $total = $Images.Count
    $current = 0
    $firstCard = $null

    foreach ($image in $Images) {
        $current++
        $displayTitle = Get-CleanImageTitle $image

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
                Update-GalleryViewportHeight
            })
        $card.Padding = New-Object System.Windows.Thickness(0)
        $card.Margin = New-Object System.Windows.Thickness(0, 0, 16, 16)
        $card.Cursor = [System.Windows.Input.Cursors]::Hand
        $card.Tag = $image
        if ($image.copyright) {
            $card.ToolTip = "$displayTitle`n$($image.copyright)"
        }
    
        $card.BorderThickness = New-Object System.Windows.Thickness(0)
        $card.BorderBrush = $null

        $revealBrush = New-Object System.Windows.Media.RadialGradientBrush
        $revealBrush.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(28, 255, 255, 255), 0.0)))
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(14, 255, 255, 255), 0.4)))
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(4, 255, 255, 255), 0.75)))
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, 255, 255, 255), 1.0)))
        $revealBrush.RadiusX = 180
        $revealBrush.RadiusY = 180
    
        $revealRect = New-Object System.Windows.Shapes.Rectangle
        $revealRect.Fill = $revealBrush
        $revealRect.Opacity = 0
        $revealRect.IsHitTestVisible = $false
        $revealRect.RadiusX = 12
        $revealRect.RadiusY = 12
    
        $script:revealElements.Add(@{ Element = $revealRect; Brush = $revealBrush }) | Out-Null

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

        $card.Add_MouseEnter({ 
                param($evtSender, $e)
                if ($evtSender -ne $script:selectedCard) {
                    $evtSender.Background = $cardHoverBg
                }
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

        $imgBorder = New-Object System.Windows.Controls.Border
        $imgBorder.CornerRadius = New-Object System.Windows.CornerRadius(12)
        $imgBorder.ClipToBounds = $true
        $imgBorder.Background = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(20, 20, 20)))

        $imageControl = New-Object System.Windows.Controls.Image
        $imageControl.Stretch = [System.Windows.Media.Stretch]::UniformToFill
        $imgBorder.Child = $imageControl
        $stack.Children.Add($imgBorder)

        try {
            $safeName = $image.urlbase -replace '[^a-zA-Z0-9]', ''
            $thumbCachePath = Join-Path $ThumbCacheDir "${safeName}_thumb.jpg"
            if (Test-Path -LiteralPath $thumbCachePath) {
                $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                $bitmap.BeginInit()
                $bitmap.UriSource = New-Object System.Uri((Resolve-Path -LiteralPath $thumbCachePath).Path)
                $bitmap.DecodePixelWidth = 360
                $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bitmap.EndInit()
                $bitmap.Freeze()

                [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($imageControl, [System.Windows.Media.BitmapScalingMode]::LowQuality)
                $imageControl.Source = $bitmap
                $card.Resources.Add('ImageAccentBrush', (Get-ImageAccentBrush $thumbCachePath))
                [void]$script:galleryImageControls.Add($imageControl)
            }
        }
        catch {}

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

        $detailsContainer = New-Object System.Windows.Controls.Grid
        $detailsContainer.ClipToBounds = $true
        $detailsContainer.Children.Add($details)

        $shimmerOverlay = New-Object System.Windows.Controls.Border
        $shimmerOverlay.Width = 130
        $shimmerOverlay.HorizontalAlignment = 'Left'
        $shimmerOverlay.IsHitTestVisible = $false
        $shimmerOverlay.Opacity = 0

        $shimmerBrush = New-Object System.Windows.Media.LinearGradientBrush
        $shimmerBrush.StartPoint = New-Object System.Windows.Point(0, 0.5)
        $shimmerBrush.EndPoint = New-Object System.Windows.Point(1, 0.5)
        $shimmerBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Colors]::Transparent, 0.0)))
        $shimmerBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(75, 255, 255, 255), 0.5)))
        $shimmerBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Colors]::Transparent, 1.0)))
        $shimmerOverlay.Background = $shimmerBrush

        $shimmerTransform = New-Object System.Windows.Media.TranslateTransform
        $shimmerOverlay.RenderTransform = $shimmerTransform
        $detailsContainer.Children.Add($shimmerOverlay)

        $card.Resources.Add('ShimmerOverlay', $shimmerOverlay)
        $card.Resources.Add('ShimmerTransform', $shimmerTransform)

        $stack.Children.Add($detailsContainer)

        $card.Add_MouseLeftButtonDown({
                param($evtSender, $e)
                $clickedImage = $evtSender.Tag 
                $script:userHasExplicitlySelectedWallpaper = $true
                Select-Card $evtSender $clickedImage
        
                if ($e.ClickCount -eq 2) {
                    Apply-WallpaperAsync -Image $clickedImage -Card $evtSender -Resolution $ResolutionBox.SelectedItem -Target $TargetBox.SelectedItem -Style $StyleBox.SelectedItem
                }
            })

        $GalleryPanel.Children.Add($card)
        [void]$script:galleryCards.Add($card)
        if (-not $firstCard) { $firstCard = $card }
    
        if ($SkipAnimation) {
            $card.Opacity = 1
        }
        else {
            $staggerDelay = ($current - 1) * 35
            Show-GalleryCard -Card $card -DelayMs $staggerDelay
        }
    }

    if ($firstCard -and $Images.Count -gt 0 -and (-not $script:userHasExplicitlySelectedWallpaper)) {
        Select-Card $firstCard $Images[0]
        $script:userHasExplicitlySelectedWallpaper = $false
    }

    Update-GalleryViewportHeight
    if ($GalleryScrollViewer) { $GalleryScrollViewer.ScrollToTop() }

    $upgradeDelay = [System.Math]::Min($total * 35 + 200, 1200)
    $script:qualityUpgradeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:qualityUpgradeTimer.Interval = [TimeSpan]::FromMilliseconds($upgradeDelay)
    $localPanel = $GalleryPanel
    $script:qualityUpgradeTimer.Add_Tick({
            param($qtSender, $qtArgs)
            $qtSender.Stop()
            foreach ($c in $localPanel.Children) {
                $grid = $c.Child
                if ($grid) {
                    $st = $grid.Children | Where-Object { $_ -is [System.Windows.Controls.StackPanel] } | Select-Object -First 1
                    if ($st -and $st.Children.Count -gt 0) {
                        $ib = $st.Children[0]
                        if ($ib -and $ib.Child -is [System.Windows.Controls.Image]) {
                            [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($ib.Child, [System.Windows.Media.BitmapScalingMode]::HighQuality)
                        }
                    }
                }
            }
        })
    $script:qualityUpgradeTimer.Start()
}

function Load-Gallery {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param()

    if ($script:fadeTimer) { $script:fadeTimer.Stop() }
    if ($script:statusResetTimer) { $script:statusResetTimer.Stop() }
    if ($script:loadingStatusTimer) { $script:loadingStatusTimer.Stop() }

    if ($script:galleryTimer) {
        $script:galleryTimer.Stop()
        $script:galleryTimer = $null
    }
    if ($script:galleryRunspaceContext) {
        try { $script:galleryRunspaceContext.PS.Dispose() } catch {}
        $script:galleryRunspaceContext = $null
    }

    $selectedRegion = Get-SelectedRegionCode
    $cacheBaseDir = Join-Path $env:LOCALAPPDATA 'BingWallpaper\Cache'
    $thumbCacheDir = Join-Path $cacheBaseDir 'Thumbnails'

    if (Test-Path -LiteralPath $thumbCacheDir) {
        try { Remove-Item -LiteralPath $thumbCacheDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
    try { New-Item -ItemType Directory -Path $thumbCacheDir -Force | Out-Null } catch {}

    $GalleryPanel.Children.Clear()
    $script:selectedCard = $null
    $script:selectedImage = $null
    $script:selection.Card = $null
    $script:selection.Image = $null
    $script:loadedImages = @()
    $script:userHasExplicitlySelectedWallpaper = $false
    $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $StatusText.Opacity = 1
    $StatusText.Text = 'Connecting to Bing...'
    $StatusText.Foreground = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(136, 136, 136)))

    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param([string]$Region, [string]$CacheDir)
            try {
                # BingWallpaper.FastDownloader was already compiled in-memory at
                # script startup and is visible to this runspace (same process,
                # same default AppDomain) - nothing to load here.
                $market = if ($Region -eq 'auto') { 'en-US' } else { $Region }
                $uri1 = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=$market"
                $uri2 = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=8&n=8&mkt=$market"
        
                $wc = New-Object System.Net.WebClient
                $wc.Encoding = [System.Text.Encoding]::UTF8
                $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                $json1 = $wc.DownloadString($uri1)
                $json2 = $wc.DownloadString($uri2)
                $wc.Dispose()

                $batch1 = if ($json1) { (ConvertFrom-Json -InputObject $json1).images } else { @() }
                $batch2 = if ($json2) { (ConvertFrom-Json -InputObject $json2).images } else { @() }

                $allImages = @()
                if ($batch1) { $allImages += $batch1 }
                if ($batch2) { $allImages += $batch2 }

                $uniqueImages = $allImages | Group-Object -Property urlbase | ForEach-Object { $_.Group[0] } | Sort-Object -Property enddate -Descending
                if (-not $uniqueImages -or $uniqueImages.Count -eq 0) {
                    return @{ Success = $false; Error = "Unable to connect to Bing."; Images = @() }
                }

                $urlBases = [string[]]($uniqueImages | ForEach-Object { [string]$_.urlbase })
                if ('BingWallpaper.FastDownloader' -as [type]) {
                    [BingWallpaper.FastDownloader]::DownloadThumbnailsParallel($urlBases, $CacheDir)
                }
                else {
                    $wc2 = New-Object System.Net.WebClient
                    $wc2.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                    foreach ($ub in $urlBases) {
                        $safe = $ub -replace '[^a-zA-Z0-9]', ''
                        $target = Join-Path $CacheDir "${safe}_thumb.jpg"
                        if (-not (Test-Path -LiteralPath $target)) {
                            try { $wc2.DownloadFile("https://www.bing.com${ub}_1920x1080.jpg", $target) } catch {}
                        }
                    }
                    $wc2.Dispose()
                }

                $resultImages = @()
                foreach ($img in $uniqueImages) {
                    $resultImages += [PSCustomObject]@{
                        urlbase   = [string]$img.urlbase
                        url       = [string]$img.url
                        title     = [string]$img.title
                        copyright = [string]$img.copyright
                        enddate   = [string]$img.enddate
                    }
                }

                return @{ Success = $true; Error = $null; Images = $resultImages }
            }
            catch {
                return @{ Success = $false; Error = $_.Exception.Message; Images = @() }
            }
        }).AddArgument($selectedRegion).AddArgument($thumbCacheDir)

    $asyncOp = $ps.BeginInvoke()

    $script:galleryRunspaceContext = @{
        PS            = $ps
        AsyncOp       = $asyncOp
        ThumbCacheDir = $thumbCacheDir
    }

    $script:galleryTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:galleryTimer.Interval = [TimeSpan]::FromMilliseconds(30)
    $script:galleryTimer.Add_Tick({
            param($timerSender, $timerArgs)
            if (-not $script:galleryRunspaceContext) {
                $timerSender.Stop()
                return
            }
            if ($script:galleryRunspaceContext.AsyncOp.IsCompleted) {
                $timerSender.Stop()
                $ctx = $script:galleryRunspaceContext
                $script:galleryRunspaceContext = $null
                $script:galleryTimer = $null

                $images = @()
                $isSuccess = $false
                $errorMsg = $null
                try {
                    $resCollection = $ctx.PS.EndInvoke($ctx.AsyncOp)
                    $res = if ($resCollection -and $resCollection.Count -gt 0) { $resCollection[0] } else { $null }
                    $isSuccess = ($res -and $res.Success -eq $true)
                    $images = if ($res -and $res.Images) { @($res.Images) } else { @() }
                    $errorMsg = if ($res) { $res.Error } else { "Failed to load wallpapers." }
                }
                catch {
                    $isSuccess = $false
                    $errorMsg = $_.Exception.Message
                }
                finally {
                    try { $ctx.PS.Dispose() } catch {}
                }

                if (-not $isSuccess -or $images.Count -eq 0) {
                    $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                    $StatusText.Opacity = 1
                    $StatusText.Foreground = $statusErrorBrush
                    $StatusText.Text = Get-UserFriendlyNetworkError -Exception (New-Object Exception($errorMsg)) -DefaultAction "load wallpapers"
                    return
                }

                Render-GalleryGrid -Images $images -ThumbCacheDir $ctx.ThumbCacheDir

                $script:loadingCounter = 0
                $script:loadingTotal = $images.Count
        
                if ($script:loadingStatusTimer) { $script:loadingStatusTimer.Stop() }
                $script:loadingStatusTimer = New-Object System.Windows.Threading.DispatcherTimer
                $script:loadingStatusTimer.Interval = [TimeSpan]::FromMilliseconds(35)
                $script:loadingStatusTimer.Add_Tick({
                        $script:loadingCounter++
                        if ($script:loadingCounter -le $script:loadingTotal) {
                            $StatusText.Text = "Loading $($script:loadingCounter) of $($script:loadingTotal) wallpapers from Bing..."
                        }
                        else {
                            $script:loadingStatusTimer.Stop()
                            Restore-StatusTextDefaultWithFade
                        }
                    })
                $script:loadingStatusTimer.Start()
            }
        })
    $script:galleryTimer.Start()
}

$script:isScrolling = $false
$script:scrollIdleTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:scrollIdleTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:scrollIdleTimer.Add_Tick({
        param($sit, $sia)
        $sit.Stop()
        $script:isScrolling = $false
        if ($script:galleryCards) {
            foreach ($c in $script:galleryCards) {
                $c.CacheMode = $null
            }
        }
        if ($script:galleryImageControls) {
            foreach ($img in $script:galleryImageControls) {
                [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, [System.Windows.Media.BitmapScalingMode]::HighQuality)
            }
        }
    })

$GalleryScrollViewer.Add_ScrollChanged({
        param($scSender, $scArgs)
        if ($scArgs.VerticalChange -eq 0) { return }
        if (-not $script:isScrolling) {
            $script:isScrolling = $true
            if ($script:galleryCards) {
                $bmpCache = New-Object System.Windows.Media.BitmapCache
                foreach ($c in $script:galleryCards) {
                    $c.CacheMode = $bmpCache
                }
            }
            if ($script:galleryImageControls) {
                foreach ($img in $script:galleryImageControls) {
                    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, [System.Windows.Media.BitmapScalingMode]::LowQuality)
                }
            }
        }
        $script:scrollIdleTimer.Stop()
        $script:scrollIdleTimer.Start()
    })

$UpdateBtn.Add_Click({
        $targetImage = $null
        $targetCard = $null

        if ($script:selectedCard -and $script:selectedImage) { 
            $targetImage = $script:selectedImage 
            $targetCard = $script:selectedCard
        }
        elseif ($script:selection.Card -and $script:selection.Image) { 
            $targetImage = $script:selection.Image 
            $targetCard = $script:selection.Card
        }
        elseif ($script:loadedImages -and $script:loadedImages.Count -gt 0) { 
            $targetImage = $script:loadedImages[0] 
            if ($GalleryPanel -and $GalleryPanel.Children.Count -gt 0) {
                $targetCard = $GalleryPanel.Children[0]
            }
        }
        else { 
            $targetImage = (Get-BingImages -Region (Get-SelectedRegionCode) | Select-Object -First 1) 
            if ($GalleryPanel -and $GalleryPanel.Children.Count -gt 0) {
                $targetCard = $GalleryPanel.Children[0]
            }
        }
        if (-not $targetImage) { return }

        Apply-WallpaperAsync -Image $targetImage -Card $targetCard -Resolution $ResolutionBox.SelectedItem -Target $TargetBox.SelectedItem -Style $StyleBox.SelectedItem
    })

$DownloadBtn.Add_Click({
        $targetImage = $null
        $targetCard = $null

        if ($script:selectedCard -and $script:selectedImage) {
            $targetImage = $script:selectedImage
            $targetCard = $script:selectedCard
        }
        elseif ($script:selection.Card -and $script:selection.Image) {
            $targetImage = $script:selection.Image
            $targetCard = $script:selection.Card
        }
        elseif ($script:loadedImages -and $script:loadedImages.Count -gt 0) {
            $targetImage = $script:loadedImages[0]
            if ($GalleryPanel -and $GalleryPanel.Children.Count -gt 0) {
                $targetCard = $GalleryPanel.Children[0]
            }
        }
        else {
            $targetImage = (Get-BingImages -Region (Get-SelectedRegionCode) | Select-Object -First 1)
            if ($GalleryPanel -and $GalleryPanel.Children.Count -gt 0) {
                $targetCard = $GalleryPanel.Children[0]
            }
        }

        if (-not $targetImage) { return }
        $actionTitle = Get-CleanImageTitle $targetImage

        $UpdateBtn.IsEnabled = $false
        $DownloadBtn.IsEnabled = $false
        $StatusText.Foreground = $statusDefaultBrush
        $StatusText.Text = "Downloading $actionTitle..."

        if ($targetCard) { Start-CardDownloadAnimation $targetCard }

        $downloadFolder = $FolderBox.Text
        if (-not (Test-Path -LiteralPath $downloadFolder)) {
            try { New-Item -ItemType Directory -Path $downloadFolder -Force | Out-Null } catch {}
        }

        $imageUri = Get-BingImageUri -Image $targetImage -Resolution $ResolutionBox.SelectedItem
        $imageDate = if ($targetImage.enddate -and ($targetImage.enddate -match '^\d{8}$')) { $targetImage.enddate } else { (Get-Date).ToString('yyyyMMdd') }
        $cleanTitle = ($actionTitle -replace '[\\/:*?"<>|\x00-\x1F]', '').Trim()
        $cleanTitle = ($cleanTitle -replace '\s+', ' ').Trim()
        if ($cleanTitle.Length -gt 60) { $cleanTitle = $cleanTitle.Substring(0, 60).Trim() }
        $fileName = if ($cleanTitle) { "Bing-$imageDate-$cleanTitle.jpg" } else { "Bing-$imageDate.jpg" }
        $downloadPath = Join-Path $downloadFolder $fileName
        $tempPath = "$downloadPath.tmp"

        $ps = [powershell]::Create()
        [void]$ps.AddScript({
                param([string]$Uri, [string]$Temp, [string]$Dest)
                try {
                    $wc = New-Object System.Net.WebClient
                    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                    $wc.DownloadFile($Uri, $Temp)
                    $wc.Dispose()
                    if (Test-Path -LiteralPath $Temp) {
                        if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue }
                        Move-Item -LiteralPath $Temp -Destination $Dest -Force
                    }
                    return @{ Success = $true; Error = $null }
                }
                catch {
                    return @{ Success = $false; Error = $_.Exception.Message }
                }
            }).AddArgument($imageUri).AddArgument($tempPath).AddArgument($downloadPath)

        $asyncOp = $ps.BeginInvoke()
        $script:dlContext = @{ PS = $ps; AsyncOp = $asyncOp; TargetCard = $targetCard }

        if ($script:downloadTimer) {
            $script:downloadTimer.Stop()
            $script:downloadTimer = $null
        }

        $script:downloadTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:downloadTimer.Interval = [TimeSpan]::FromMilliseconds(30)
        $script:downloadTimer.Add_Tick({
                param($timerSender, $timerArgs)
                if (-not $script:dlContext) {
                    $timerSender.Stop()
                    return
                }
                if ($script:dlContext.AsyncOp.IsCompleted) {
                    $timerSender.Stop()
                    $ctx = $script:dlContext
                    $script:dlContext = $null
                    $script:downloadTimer = $null

                    $isSuccess = $false
                    $errorMsg = $null
                    try {
                        $resCollection = $ctx.PS.EndInvoke($ctx.AsyncOp)
                        $res = if ($resCollection -and $resCollection.Count -gt 0) { $resCollection[0] } else { $null }
                        $isSuccess = ($res -and $res.Success -eq $true)
                        $errorMsg = if ($res) { $res.Error } else { $null }
                    }
                    catch {
                        $isSuccess = $false
                        $errorMsg = $_.Exception.Message
                    }
                    finally {
                        try { $ctx.PS.Dispose() } catch {}
                        $UpdateBtn.IsEnabled = $true
                        $DownloadBtn.IsEnabled = $true
                    }

                    if ($isSuccess) {
                        if ($ctx.TargetCard) { Stop-CardDownloadAnimation $ctx.TargetCard $true }
                        Set-TransientStatus -Message "Wallpaper downloaded"
                    }
                    else {
                        if ($ctx.TargetCard) { Stop-CardDownloadAnimation $ctx.TargetCard $false }
                        $errMsg = Get-UserFriendlyNetworkError -Exception (New-Object Exception($errorMsg)) -DefaultAction "download wallpaper"
                        Set-TransientStatus -Message $errMsg -Brush $statusErrorBrush -Seconds 5
                    }
                }
            })
        $script:downloadTimer.Start()
    })

$CheckUpdateBtn.Add_Click({
        try {
            Start-VerifiedUpdate
        }
        catch {
            Show-AppErrorDialog `
                -Message "Start-VerifiedUpdate failed:`n`n$($_.Exception.GetType().FullName)`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)" `
                -Title "Update check error"
        }
    })

@(
    @{ Label = 'On Login'; Minutes = 0 },
    @{ Label = '1 minute'; Minutes = 1 },
    @{ Label = 'Hourly'; Minutes = 60 },
    @{ Label = 'Every 6h'; Minutes = 360 },
    @{ Label = 'Daily'; Minutes = 1440 }
) | ForEach-Object {
    $it = New-Object System.Windows.Controls.ComboBoxItem
    $it.Content = $_.Label
    $it.Tag = $_.Minutes
    [void]$SpotlightIntervalBox.Items.Add($it)
}

$savedMinutes = if ($script:appSettings.SpotlightInterval -ne $null) { [int]$script:appSettings.SpotlightInterval } else { 60 }
$SpotlightIntervalBox.SelectedIndex = switch ($savedMinutes) { 0 { 0 } { $_ -eq 1 -or $_ -eq -1 } { 1 } 60 { 2 } 360 { 3 } default { 4 } }

@('Desktop', 'Lock screen', 'Both') | ForEach-Object { [void]$SpotlightTargetBox.Items.Add($_) }
$savedTarget = if ($script:appSettings.SpotlightTarget) { $script:appSettings.SpotlightTarget } else { 'Desktop' }
$SpotlightTargetBox.SelectedItem = $SpotlightTargetBox.Items | Where-Object { $_ -eq $savedTarget } | Select-Object -First 1
if (-not $SpotlightTargetBox.SelectedItem) { $SpotlightTargetBox.SelectedIndex = 0 }

$spotlightWasEnabled = ($script:appSettings.SpotlightEnabled -eq $true)
if ($spotlightWasEnabled) {
    Set-SpotlightState -Enabled $true -Animate $false -UpdateTask $false
    Update-SpotlightScheduledTaskAsync -Enable $true
}

$SpotlightPill.Add_PreviewMouseLeftButtonDown({
        param($sender, $e)
        $e.Handled = $true
        $newState = -not $script:SpotlightEnabled
        Set-SpotlightState -Enabled $newState
        Update-SpotlightScheduledTaskAsync -Enable $newState
        Save-Settings
    
        if ($newState) {
            Set-TransientStatus -Message "Automatic wallpaper changing enabled." -Brush $statusSuccessBrush
        }
        else {
            Set-TransientStatus -Message "Automatic wallpaper changing disabled." -Brush $statusErrorBrush
        }
    })

$SpotlightIntervalBox.Add_SelectionChanged({ if ($script:SpotlightEnabled) { Update-SpotlightScheduledTaskAsync -Enable $true; Save-Settings } })
$SpotlightTargetBox.Add_SelectionChanged({ if ($script:SpotlightEnabled) { Update-SpotlightScheduledTaskAsync -Enable $true; Save-Settings } })

$initialRegionCode = Get-DetectedRegionCode
$detectedItem = $RegionBox.Items | Where-Object { $_.Tag -eq $initialRegionCode } | Select-Object -First 1
if ($detectedItem) { 
    $RegionBox.SelectedItem = $detectedItem 
}

$window.Add_ContentRendered({
    $RegionBox.Add_SelectionChanged({ Load-Gallery })
    Load-Gallery
})

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

$window.Add_SizeChanged({ Update-GalleryViewportHeight })
$GalleryPanel.Add_SizeChanged({ Update-GalleryViewportHeight })

$script:activeGuideDialog = $null
$script:isClosingGuideDialog = $false

function Close-UserGuideDialog {
    if ($script:isClosingGuideDialog) { return }
    if ($script:activeModalControl -and $script:activeModalKind -eq 'Guide') {
        $script:isClosingGuideDialog = $true
        Close-InWindowModal
        $script:isClosingGuideDialog = $false
    }
}

function Show-UserGuideDialog {
    if ($script:activeModalControl -and $script:activeModalKind -eq 'Guide' -and -not $script:activeModalClosing) {
        Close-UserGuideDialog
        return
    }
    $cleanTitle = "AutoScape"
    $cleanDate = "Today's Wallpaper"
    $thumbPath = $null

    try {
        if ($script:loadedImages -and $script:loadedImages.Count -gt 0) {
            $latest = $script:loadedImages[0]
            $cleanTitle = [System.Security.SecurityElement]::Escape((Get-CleanImageTitle $latest))
            try {
                $cleanDate = ([DateTime]::ParseExact($latest.enddate.ToString(), 'yyyyMMdd', $null)).ToString('ddd, MMM d')
            }
            catch {
                $cleanDate = if ($latest.copyright) { [System.Security.SecurityElement]::Escape($latest.copyright) } else { "Today's Wallpaper" }
            }
            $safeName = $latest.urlbase -replace '[^a-zA-Z0-9]', ''
            $tPath = Join-Path $env:LOCALAPPDATA "BingWallpaper\Cache\Thumbnails\${safeName}_thumb.jpg"
            if (Test-Path -LiteralPath $tPath) {
                $thumbPath = (Resolve-Path -LiteralPath $tPath).Path
            }
        }
        elseif (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'BingWallpaper\Cache\current_wallpaper.jpg')) {
            $thumbPath = (Resolve-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'BingWallpaper\Cache\current_wallpaper.jpg')).Path
        }
    }
    catch {}

    $screenWidth = [System.Windows.SystemParameters]::PrimaryScreenWidth
    $screenHeight = [System.Windows.SystemParameters]::PrimaryScreenHeight
    if ($window -and $window.ActualWidth -gt 600) {
        $screenWidth = $window.ActualWidth
        $screenHeight = $window.ActualHeight
    }
    $maxModalWidth = [Math]::Max(320, [int]$screenWidth - 48)
    $maxModalHeight = [Math]::Max(320, [int]$screenHeight - 48)
    $modalWidth = [Math]::Min($maxModalWidth, [Math]::Max(700, [int]($screenWidth * 0.72)))
    $modalHeight = [Math]::Min($maxModalHeight, [Math]::Max(520, [int]($screenHeight * 0.72)))

    $dialogXaml = @"
<UserControl xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="$modalWidth" Height="$modalHeight"
        Background="#181818" Foreground="#F0F0F0" FontFamily="Segoe UI">
    <Border Name="DialogRoot" Padding="28,24,28,22" Background="#181818" Opacity="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Close Button -->
            <Button Name="GuideCloseButton" Width="32" Height="32"
                    HorizontalAlignment="Right" VerticalAlignment="Top" Background="#262626" Foreground="#E8E8E8"
                    BorderThickness="0" Cursor="Hand" ToolTip="Close" Panel.ZIndex="100">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border Name="CloseBorder" Background="{TemplateBinding Background}" CornerRadius="7">
                            <Canvas Width="20" Height="20">
                                <Path Data="M 5,5 L 15,15 M 15,5 L 5,15"
                                      Stroke="{TemplateBinding Foreground}" StrokeThickness="2.6"
                                      StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                            </Canvas>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CloseBorder" Property="Background" Value="#E81123"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="CloseBorder" Property="Background" Value="#C50F1F"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>

            <!-- Header -->
            <Grid Grid.Row="0" Margin="0,0,0,24" HorizontalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                    <Viewbox Width="36" Height="36" Margin="0,0,14,0">
                        <Canvas Width="760" Height="720">
                            <Canvas Canvas.Left="-135" Canvas.Top="-135" Width="1024" Height="1024">
                                <Rectangle Canvas.Left="245" Canvas.Top="147" Width="534" Height="151" RadiusX="34" RadiusY="34">
                                    <Rectangle.Fill>
                                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                            <GradientStop Color="#174BCB" Offset="0"/>
                                            <GradientStop Color="#0B3AA5" Offset="1"/>
                                        </LinearGradientBrush>
                                    </Rectangle.Fill>
                                    <Rectangle.Effect>
                                        <DropShadowEffect BlurRadius="24" Direction="270" ShadowDepth="10" Opacity="0.18" Color="Black"/>
                                    </Rectangle.Effect>
                                </Rectangle>

                                <Rectangle Canvas.Left="209" Canvas.Top="205" Width="606" Height="168" RadiusX="36" RadiusY="36">
                                    <Rectangle.Fill>
                                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                            <GradientStop Color="#1470D5" Offset="0"/>
                                            <GradientStop Color="#0758BD" Offset="1"/>
                                        </LinearGradientBrush>
                                    </Rectangle.Fill>
                                </Rectangle>

                                <Rectangle Canvas.Left="173" Canvas.Top="263" Width="678" Height="539" RadiusX="36" RadiusY="36">
                                    <Rectangle.Fill>
                                        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                            <GradientStop Color="#54A8F4" Offset="0"/>
                                            <GradientStop Color="#8BC8F6" Offset="1"/>
                                        </LinearGradientBrush>
                                    </Rectangle.Fill>
                                    <Rectangle.Effect>
                                        <DropShadowEffect BlurRadius="24" Direction="270" ShadowDepth="10" Opacity="0.18" Color="Black"/>
                                    </Rectangle.Effect>
                                </Rectangle>

                                <Canvas>
                                    <Canvas.Clip>
                                        <RectangleGeometry Rect="173,263,678,539" RadiusX="36" RadiusY="36"/>
                                    </Canvas.Clip>
                                    <Ellipse Canvas.Left="80" Canvas.Top="175" Width="820" Height="380" Fill="#B9DEFA" Opacity="0.18"/>
                                    <Ellipse Canvas.Left="642" Canvas.Top="295" Width="110" Height="110" Fill="#FFE995"/>
                                    <Path Data="M235 625L360 510L425 558L495 424L570 505L635 450L810 616L880 690V830H205V830Z">
                                        <Path.Fill>
                                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                                <GradientStop Color="#79B5EA" Offset="0"/>
                                                <GradientStop Color="#9CCDF0" Offset="1"/>
                                            </LinearGradientBrush>
                                        </Path.Fill>
                                    </Path>
                                    <Path Data="M360 510L495 424L570 505L532 485L500 535L468 501L430 552L403 531Z">
                                        <Path.Fill>
                                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                                <GradientStop Color="#E5EEFF" Offset="0"/>
                                                <GradientStop Color="#FFFFFF" Offset="1"/>
                                            </LinearGradientBrush>
                                        </Path.Fill>
                                    </Path>
                                    <Path Data="M175 657L302 544L376 600L458 516L553 625L610 561L720 671L858 760V830H175Z">
                                        <Path.Fill>
                                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                                <GradientStop Color="#2C72CB" Offset="0"/>
                                                <GradientStop Color="#5E9FDF" Offset="1"/>
                                            </LinearGradientBrush>
                                        </Path.Fill>
                                    </Path>
                                    <Path Data="M302 544L376 600L346 584L325 608L302 590L275 613Z" Fill="#BBDCF5" Opacity="0.9"/>
                                    <Path Data="M458 516L553 625L514 601L486 630L458 602L432 625Z" Fill="#CDE5FA" Opacity="0.85"/>
                                    <Path Data="M150 671L268 590L337 632L420 695L505 751L590 793L655 838H150Z">
                                        <Path.Fill>
                                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                                <GradientStop Color="#08459F" Offset="0"/>
                                                <GradientStop Color="#0A62C2" Offset="1"/>
                                            </LinearGradientBrush>
                                        </Path.Fill>
                                    </Path>
                                    <Path Data="M268 590L337 632L420 695L505 751L590 793L458 741L382 699L320 653Z" Fill="#165DB8" Opacity="0.82"/>
                                    <Path Data="M515 830L590 760L675 700L760 747L880 683L900 830Z" Fill="#3984D4" Opacity="0.78"/>
                                    <Path Data="M675 700L760 747L720 735L690 759L654 730Z" Fill="#79B6E9" Opacity="0.62"/>
                                </Canvas>
                            </Canvas>
                        </Canvas>
                    </Viewbox>
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="AutoScape" FontSize="26" FontWeight="SemiBold" Foreground="#FFFFFF" Margin="0,0,0,2"/>
                        <TextBlock Text="Bing wallpapers, delivered daily" FontSize="13" Foreground="#9E9E9E" FontWeight="Normal" Margin="0,0,0,0"/>
                    </StackPanel>
                </StackPanel>
            </Grid>

            <ScrollViewer Grid.Row="1" Margin="0,0,0,18" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="1.35*" MinWidth="260" MaxWidth="380"/>
                    <ColumnDefinition Width="24"/>
                    <ColumnDefinition Width="2*" MinWidth="320"/>
                </Grid.ColumnDefinitions>

                <Grid Grid.Column="0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <Grid Grid.Row="0" Margin="0,0,0,16">
                        <Border Name="GuidePreviewShadow" Background="#212121" CornerRadius="12" BorderThickness="0" IsHitTestVisible="False">
                            <Border.Effect>
                                <DropShadowEffect Color="#000000" BlurRadius="10" ShadowDepth="2" Opacity="0.3" Direction="270"/>
                            </Border.Effect>
                        </Border>
                        <Border Name="GuidePreviewCard" Background="#212121" CornerRadius="12" BorderThickness="0" ClipToBounds="True" Cursor="Hand">
                            <Grid>
                                <StackPanel IsHitTestVisible="False">
                                    <Border Height="185" CornerRadius="12,12,0,0" ClipToBounds="True" Background="#141414">
                                        <Image Name="GuideLatestImage" Stretch="UniformToFill"/>
                                    </Border>
                                    <StackPanel Margin="14,12,14,14">
                                        <TextBlock Name="GuideLatestTitle" Text="$cleanTitle" FontSize="15" FontWeight="SemiBold" Foreground="#FFFFFF" TextTrimming="CharacterEllipsis" Margin="0,0,0,4"/>
                                        <TextBlock Name="GuideLatestDate" Text="$cleanDate" FontSize="13" Foreground="#A0A0A0" TextTrimming="CharacterEllipsis"/>
                                    </StackPanel>
                                </StackPanel>
                                <Rectangle Name="GuideRevealRect" RadiusX="12" RadiusY="12" Opacity="0" IsHitTestVisible="False"/>
                                <Border Name="GuideRevealBorder" CornerRadius="12" BorderThickness="1.5" IsHitTestVisible="False"/>
                            </Grid>
                        </Border>
                    </Grid>

                    <Border Grid.Row="1" Name="GuideDefaultCard" Background="#212121" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="12" Padding="20,18" VerticalAlignment="Top">
                        <StackPanel VerticalAlignment="Top">
                            <TextBlock Text="Default Behavior" FontSize="18" FontWeight="Bold" Foreground="#0078D4" Margin="0,0,0,16"/>
                            <TextBlock Text="4K resolution is used by default" FontSize="13.5" Foreground="#FFFFFF" TextWrapping="Wrap" LineHeight="20" Margin="0,0,0,12"/>
                            <TextBlock Text="Everyday wallpaper changes automatically at 12am" FontSize="13.5" Foreground="#FFFFFF" TextWrapping="Wrap" LineHeight="20" Margin="0,0,0,12"/>
                            <TextBlock Text="Fit is the default wallpaper style" FontSize="13.5" Foreground="#FFFFFF" TextWrapping="Wrap" LineHeight="20" Margin="0,0,0,12"/>
                            <TextBlock Text="Default region is selected based on your location" FontSize="13.5" Foreground="#FFFFFF" TextWrapping="Wrap" LineHeight="20" Margin="0,0,0,12"/>
                            <TextBlock Text="Wallpapers change hourly by default" FontSize="13.5" Foreground="#FFFFFF" TextWrapping="Wrap" LineHeight="20"/>
                        </StackPanel>
                    </Border>
                </Grid>

                <Border Grid.Column="2" Name="GuideFeaturesPanel" Background="#212121" BorderBrush="#2E2E2E" BorderThickness="1" CornerRadius="12" Padding="20,18" VerticalAlignment="Top">
                    <StackPanel>
                        <TextBlock Text="Essential Features" FontSize="18" FontWeight="Bold" Foreground="#0078D4" Margin="0,0,0,16"/>

                        <Border Background="#1A1A1A" CornerRadius="8" Padding="16,12" Margin="0,0,0,10">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="36"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#0078D4" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                                    <TextBlock Text="Download" FontSize="14.5" FontWeight="SemiBold" Foreground="#FAFAFA"/>
                                    <TextBlock Text="Save original 4K Ultra HD images directly to your device without any watermarks" FontSize="13" Foreground="#A0A0A0" TextWrapping="Wrap" LineHeight="18" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border Background="#1A1A1A" CornerRadius="8" Padding="16,12" Margin="0,0,0,10">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="36"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#xE8B9;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#00CACC" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                                    <TextBlock Text="Browse" FontSize="14.5" FontWeight="SemiBold" Foreground="#FAFAFA"/>
                                    <TextBlock Text="Explore recent days of Bing imagery. Single click to inspect, double-click to apply" FontSize="13" Foreground="#A0A0A0" TextWrapping="Wrap" LineHeight="18" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border Background="#1A1A1A" CornerRadius="8" Padding="16,12" Margin="0,0,0,10">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="36"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#xE771;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#60CDFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                                    <TextBlock Text="Apply Wallpaper" FontSize="14.5" FontWeight="SemiBold" Foreground="#FAFAFA"/>
                                    <TextBlock Text="Set image for Desktop, Lock Screen, or Both with customized sizing (Fit, Fill, Stretch, Center, Span)" FontSize="13" Foreground="#A0A0A0" TextWrapping="Wrap" LineHeight="18" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border Background="#1A1A1A" CornerRadius="8" Padding="16,12" Margin="0,0,0,10">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="36"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#xE774;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#A78BFA" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                                    <TextBlock Text="Customize Region" FontSize="14.5" FontWeight="SemiBold" Foreground="#FAFAFA"/>
                                    <TextBlock Text="Switch between global regions (US, UK, Japan, Germany, etc.) for localized photography" FontSize="13" Foreground="#A0A0A0" TextWrapping="Wrap" LineHeight="18" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border Background="#1A1A1A" CornerRadius="8" Padding="16,12" Margin="0,0,0,10">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="36"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#34D399" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                                    <TextBlock Text="Automatic Changes" FontSize="14.5" FontWeight="SemiBold" Foreground="#FAFAFA"/>
                                    <TextBlock Text="Enable Auto switch to cycle wallpapers at custom intervals (1 min, Hourly, Daily, on Login)" FontSize="13" Foreground="#A0A0A0" TextWrapping="Wrap" LineHeight="18" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border Background="#1A1A1A" CornerRadius="8" Padding="16,12">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="36"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="19" Foreground="#FBBF24" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="16,0,0,0">
                                    <TextBlock Text="Download Location" FontSize="14.5" FontWeight="SemiBold" Foreground="#FAFAFA"/>
                                    <TextBlock Text="Click the folder path at any time to choose where your saved wallpapers are stored" FontSize="13" Foreground="#A0A0A0" TextWrapping="Wrap" LineHeight="18" Margin="0,2,0,0"/>
                                </StackPanel>
                            </Grid>
                        </Border>
                    </StackPanel>
                </Border>
            </Grid>
            </ScrollViewer>

            <Grid Grid.Row="2" Margin="0,12,0,0">
                <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                    <Button Name="GuideGithubRepoBtn"
                            Width="38" Height="38"
                            HorizontalAlignment="Center"
                            Background="#262626"
                            Foreground="#D8D8D8"
                            BorderThickness="0"
                            Cursor="Hand"
                            ToolTip="Open GitHub Repository"
                            Margin="0,0,0,15">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border Name="GithubBorder"
                                        Background="{TemplateBinding Background}"
                                        CornerRadius="10">
                                    <Viewbox Width="18" Height="18" HorizontalAlignment="Center" VerticalAlignment="Center">
                                        <Canvas Width="24" Height="24">
                                            <Path Data="M12 0C5.37 0 0 5.37 0 12c0 5.31 3.435 9.795 8.205 11.385.6.105.825-.255.825-.57 0-.285-.015-1.23-.015-2.235-3.015.555-3.795-.735-4.035-1.41-.135-.345-.72-1.41-1.23-1.695-.42-.225-1.02-.78-.015-.795.945-.015 1.62.87 1.845 1.23 1.08 1.815 2.805 1.305 3.495.99.105-.78.42-1.305.765-1.605-2.67-.3-5.46-1.335-5.46-5.925 0-1.305.465-2.385 1.23-3.225-.12-.3-.54-1.53.12-3.18 0 0 1.005-.315 3.3 1.23.96-.27 1.98-.405 3-.405s2.04.135 3 .405c2.295-1.56 3.3-1.23 3.3-1.23.66 1.65.24 2.88.12 3.18.765.84 1.23 1.905 1.23 3.225 0 4.605-2.805 5.625-5.475 5.925.435.375.81 1.095.81 2.22 0 1.605-.015 2.895-.015 3.3 0 .315.225.69.825.57A12.02 12.02 0 0 0 24 12c0-6.63-5.37-12-12-12z"
                                                  Fill="{TemplateBinding Foreground}"/>
                                        </Canvas>
                                    </Viewbox>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="GithubBorder" Property="Background" Value="#333333"/>
                                        <Setter Property="Foreground" Value="#FFFFFF"/>
                                    </Trigger>
                                    <Trigger Property="IsPressed" Value="True">
                                        <Setter TargetName="GithubBorder" Property="Background" Value="#1F1F1F"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>

                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                        <TextBlock Text="Crafted with " FontSize="13" Foreground="#7A7A7A" VerticalAlignment="Center"/>
                        <TextBlock Name="GuideHeartIcon" Text="&#xEB52;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="#FF334B" VerticalAlignment="Center" Margin="3,2,3,0"/>
                        <TextBlock Text=" by HamB" FontSize="13" Foreground="#7A7A7A" VerticalAlignment="Center"/>
                    </StackPanel>
                </StackPanel>
            </Grid>
        </Grid>
    </Border>
</UserControl>
"@

    $r = New-Object System.Xml.XmlNodeReader ([xml]$dialogXaml)
    $dlg = [Windows.Markup.XamlReader]::Load($r)

    $guideRoot = $dlg.FindName('DialogRoot')
    if ($guideRoot) { $guideRoot.Opacity = 1.0 }

    $guideGithubRepoBtn = $dlg.FindName('GuideGithubRepoBtn')
    if ($guideGithubRepoBtn) {
        $guideGithubRepoBtn.Add_Click({
                try {
                    Start-Process "https://github.com/Hamisoptimistic/Bing-Wallpaper" | Out-Null
                }
                catch {}
            })
    }

    $imgControl = $dlg.FindName('GuideLatestImage')
    if ($imgControl -and $thumbPath) {
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.UriSource = New-Object System.Uri($thumbPath)
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.EndInit()
            $bmp.Freeze()
            [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($imgControl, [System.Windows.Media.BitmapScalingMode]::HighQuality)
            $imgControl.Source = $bmp
        }
        catch {}
    }

    $heart = $dlg.FindName('GuideHeartIcon')
    if ($heart) {
        try {
            $scale = New-Object System.Windows.Media.ScaleTransform(1.0, 1.0)
            $heart.RenderTransform = $scale
            $heart.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)

            $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
            $glow.Color = [System.Windows.Media.Color]::FromRgb(255, 51, 75)
            $glow.ShadowDepth = 0
            $glow.BlurRadius = 6
            $glow.Opacity = 0.85
            $heart.Effect = $glow

            $scaleAnim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
            $scaleAnim.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(1200))
            $scaleAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever

            $scaleAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame(1.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(0))))) | Out-Null
            $scaleAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.35, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(140))))) | Out-Null
            $scaleAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.06, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(260))))) | Out-Null
            $scaleAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.25, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(380))))) | Out-Null
            $scaleAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(540))))) | Out-Null
            $scaleAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame(1.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(1200))))) | Out-Null

            $glowAnim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
            $glowAnim.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(1200))
            $glowAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever

            $glowAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame(6.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(0))))) | Out-Null
            $glowAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(18.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(140))))) | Out-Null
            $glowAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(8.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(260))))) | Out-Null
            $glowAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(14.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(380))))) | Out-Null
            $glowAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(6.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(540))))) | Out-Null
            $glowAnim.KeyFrames.Add((New-Object System.Windows.Media.Animation.DiscreteDoubleKeyFrame(6.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(1200))))) | Out-Null

            $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $scaleAnim)
            $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $scaleAnim)
            $glow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty, $glowAnim)
        }
        catch {}
    }

    $card = $dlg.FindName('GuidePreviewCard')
    $previewShadow = $dlg.FindName('GuidePreviewShadow')
    $defaultCard = $dlg.FindName('GuideDefaultCard')
    $featuresPanel = $dlg.FindName('GuideFeaturesPanel')
    $revealRect = $dlg.FindName('GuideRevealRect')
    $revealBorder = $dlg.FindName('GuideRevealBorder')

    $syncGuideColumns = {
        try {
            if (-not $defaultCard -or -not $featuresPanel -or -not $card) { return }
            $previewHeight = $card.ActualHeight + 16
            $defaultNatural = $defaultCard.DesiredSize.Height
            $featuresNatural = $featuresPanel.DesiredSize.Height
            $bodyHeight = [Math]::Max($featuresNatural, ($previewHeight + $defaultNatural))
            $defaultCard.MinHeight = [Math]::Max(0, $bodyHeight - $previewHeight)
            $featuresPanel.MinHeight = $bodyHeight
        }
        catch {}
    }

    if ($featuresPanel) { $featuresPanel.Add_SizeChanged({ & $syncGuideColumns }) }
    if ($card) {
        $card.Add_SizeChanged({ & $syncGuideColumns })
        $dlg.Add_Loaded({
                $dlg.Dispatcher.BeginInvoke([Action] { & $syncGuideColumns }, [System.Windows.Threading.DispatcherPriority]::Loaded) | Out-Null
            })
    }

    if ($card) {
        $cardClip = New-Object System.Windows.Media.RectangleGeometry
        $cardClip.RadiusX = 12
        $cardClip.RadiusY = 12
        $card.Clip = $cardClip
        $card.Add_SizeChanged({
                param($s, $e)
                $s.Clip.Rect = [System.Windows.Rect]::new(0, 0, $s.ActualWidth, $s.ActualHeight)
            })

        $revealBrush = New-Object System.Windows.Media.RadialGradientBrush
        $revealBrush.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(28, 255, 255, 255), 0.0)))
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(14, 255, 255, 255), 0.4)))
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(4, 255, 255, 255), 0.75)))
        $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, 255, 255, 255), 1.0)))
        $revealBrush.RadiusX = 180
        $revealBrush.RadiusY = 180
        if ($revealRect) { $revealRect.Fill = $revealBrush }

        $revealBorderBrush = New-Object System.Windows.Media.RadialGradientBrush
        $revealBorderBrush.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute
        $revealBorderBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(90, 255, 255, 255), 0.0)))
        $revealBorderBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, 255, 255, 255), 1.0)))
        $revealBorderBrush.RadiusX = 160
        $revealBorderBrush.RadiusY = 160
        if ($revealBorder) { $revealBorder.BorderBrush = $revealBorderBrush }

        $cardUnselected = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 33, 33, 33))
        $cardHover = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 45, 45, 45))

        $card.Add_MouseEnter({
                $card.Background = $cardHover
                if ($previewShadow -and $previewShadow.Effect) {
                    $previewShadow.Effect.BlurRadius = 25
                    $previewShadow.Effect.ShadowDepth = 8
                }
                if ($revealRect) { $revealRect.Opacity = 1 }
            })

        $card.Add_MouseLeave({
                $card.Background = $cardUnselected
                if ($previewShadow -and $previewShadow.Effect) {
                    $previewShadow.Effect.BlurRadius = 10
                    $previewShadow.Effect.ShadowDepth = 2
                }
                if ($revealRect) { $revealRect.Opacity = 0 }
            })

        $card.Add_MouseMove({
                param($s, $e)
                try {
                    $pos = $e.GetPosition($card)
                    $revealBrush.Center = $pos
                    $revealBrush.GradientOrigin = $pos
                    $revealBorderBrush.Center = $pos
                    $revealBorderBrush.GradientOrigin = $pos
                }
                catch {}
            })
    }

    $script:activeGuideDialog = $dlg
    $closeButton = $dlg.FindName('GuideCloseButton')
    if ($closeButton) { $closeButton.Add_Click({ Close-UserGuideDialog }) }

    $dlg.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $e.Handled = $true; Close-UserGuideDialog }
        })

    Open-InWindowModal -Control $dlg -Kind 'Guide' -CloseCallback { $script:activeGuideDialog = $null }
}

if ($GuideBtn) {
    try {
        $guideGlow = New-Object System.Windows.Media.Effects.DropShadowEffect
        $guideGlow.Color = [System.Windows.Media.Color]::FromRgb(0, 144, 255)
        $guideGlow.ShadowDepth = 0
        $guideGlow.BlurRadius = 10
        $guideGlow.Opacity = 0.4
        $GuideBtn.Effect = $guideGlow

        $glowEase = New-Object System.Windows.Media.Animation.QuadraticEase
        $glowEase.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut

        $glowOpacityAnim = New-Object System.Windows.Media.Animation.DoubleAnimation
        $glowOpacityAnim.From = 0.25
        $glowOpacityAnim.To = 0.85
        $glowOpacityAnim.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(1800))
        $glowOpacityAnim.AutoReverse = $true
        $glowOpacityAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $glowOpacityAnim.EasingFunction = $glowEase

        $glowBlurAnim = New-Object System.Windows.Media.Animation.DoubleAnimation
        $glowBlurAnim.From = 6.0
        $glowBlurAnim.To = 16.0
        $glowBlurAnim.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(1800))
        $glowBlurAnim.AutoReverse = $true
        $glowBlurAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $glowBlurAnim.EasingFunction = $glowEase

        $guideGlow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $glowOpacityAnim)
        $guideGlow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty, $glowBlurAnim)
    }
    catch {}

    $GuideBtn.Add_Click({
            try {
                Show-UserGuideDialog
            }
            catch {
                Show-AppErrorDialog `
                    -Message "Show-UserGuideDialog failed:`n`n$($_.Exception.GetType().FullName)`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)" `
                    -Title "Guide dialog error"
            }
        })
}

$window.Add_Closed({
        try {
            if ($script:activeModalControl) { Close-InWindowModal -Immediate $true }
            $script:activeGuideDialog = $null
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
        }
        catch {}
    })

$window.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            if ($script:activeGuideDialog -and $script:activeGuideDialog.IsVisible) {
                $e.Handled = $true
                Close-UserGuideDialog
            }
        }
        elseif ($e.Key -eq [System.Windows.Input.Key]::F5) {
            $e.Handled = $true
            Load-Gallery
        }
        elseif (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0) {
            if ($script:activeGuideDialog -and $script:activeGuideDialog.IsVisible) { return }
            if ($UpdateBtn -and -not $UpdateBtn.IsEnabled) { return }

            if ($e.Key -eq [System.Windows.Input.Key]::B) {
                if ($script:userHasExplicitlySelectedWallpaper -and $script:selectedCard -and $script:selectedImage) {
                    $e.Handled = $true
                    Apply-WallpaperAsync -Image $script:selectedImage -Card $script:selectedCard -Resolution $ResolutionBox.SelectedItem -Target 'Desktop' -Style $StyleBox.SelectedItem
                }
            }
            elseif ($e.Key -eq [System.Windows.Input.Key]::L) {
                if ($script:userHasExplicitlySelectedWallpaper -and $script:selectedCard -and $script:selectedImage) {
                    $e.Handled = $true
                    Apply-WallpaperAsync -Image $script:selectedImage -Card $script:selectedCard -Resolution $ResolutionBox.SelectedItem -Target 'Lock screen' -Style $StyleBox.SelectedItem
                }
            }
        }
    })

$window.Add_StateChanged({
        if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
            [BingWallpaperNative]::FlushMemory()
        }
    })

$script:memTrimTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:memTrimTimer.Interval = [TimeSpan]::FromSeconds(45)
$script:memTrimTimer.Add_Tick({ [BingWallpaperNative]::FlushMemory() })
$script:memTrimTimer.Start()

[System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
        param($s, $e)
        try {
            Show-AppErrorDialog `
                -Message "Unhandled error:`n`n$($e.Exception.GetType().FullName)`n$($e.Exception.Message)`n`n$($e.Exception.ScriptStackTrace)" `
                -Title "AutoScape error"
        }
        catch {}
        $e.Handled = $true
    })

Write-TimingLog "SCRIPT: Window Ready, about to call Show() ($($script:startStopwatch.ElapsedMilliseconds)ms since script start)"
$window.Show()
[System.Windows.Threading.Dispatcher]::Run()
