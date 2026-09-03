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

# Enforce modern security protocols and higher concurrent connection limit
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
}
catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
[Net.ServicePointManager]::DefaultConnectionLimit = 32

# Load UI assemblies
[void][System.Reflection.Assembly]::Load("PresentationFramework, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35")
[void][System.Reflection.Assembly]::Load("PresentationCore, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35")
[void][System.Reflection.Assembly]::Load("WindowsBase, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35")
Write-TimingLog "SCRIPT: PresentationFramework/Core/WindowsBase loaded ($($script:startStopwatch.ElapsedMilliseconds)ms since script start)"

# Native WPF physics-based inertial smooth scrolling (Windows 11 Settings style).
#
# The old implementation kicked off a brand-new fixed-duration DoubleAnimation
# (280ms, CircleEase) on every single wheel notch. That explains the "flows but
# doesn't glide" feeling:
#   1. It's driven by WPF's animation/timing clock and has to be torn down and
#      rebuilt (SnapshotAndReplace) on every notch - each restart is a tiny
#      discontinuity in velocity.
#   2. Duration is fixed regardless of how fast you're flicking, so quick
#      successive notches never build real momentum.
#
# Windows 11 Settings (and inertial trackpad/touch scrolling generally) is a
# velocity + friction physics model: each wheel notch adds an *impulse* to a
# running velocity, and velocity decays smoothly (exponentially) over time -
# so it keeps gliding after you stop turning the wheel, and stacking notches
# quickly makes it glide further and faster, exactly like Settings.
#
# This drives that model directly off CompositionTarget.Rendering (the actual
# per-frame render tick) with frame-time-independent integration, so the curve
# looks identical whether frames are landing at 60Hz, 120Hz, or a variable
# refresh rate - and it unhooks itself the instant it comes to rest, per
# Microsoft's own guidance not to leave CompositionTarget.Rendering attached
# when nothing is moving.
$script:smoothScrollCsSource = @'
using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

public static class AutoScapeSmoothScroll
{
    private static ScrollViewer _sv;
    private static double _offset;      // our own precise (sub-pixel) offset
    private static double _velocity;    // pixels / second, +down / -up
    private static bool _hooked;
    private static readonly Stopwatch _clock = new Stopwatch();
    private static long _lastTicks;

    // Tuned to match the Windows 11 Settings feel:
    private const double WheelImpulse = 500.0;     // px/sec added per wheel notch
    private const double MaxVelocity = 9000.0;      // px/sec safety clamp
    private const double FrictionPerSec = 5.0;      // exponential decay rate
    private const double StopThreshold = 3.0;       // px/sec - below this we snap & stop
    private const double MaxFrameDelta = 1.0 / 20.0; // guard vs. huge dt after a stall

    public static void Attach(ScrollViewer sv)
    {
        if (sv == null) return;
        _sv = sv;
        _offset = sv.ContentVerticalOffset;
        _velocity = 0;

        sv.PreviewMouseWheel += (s, e) =>
        {
            double max = sv.ScrollableHeight;
            if (max <= 0) return;

            e.Handled = true;

            // Resync from the live offset if we weren't already gliding (covers
            // programmatic scrolls, scrollbar drags, etc. that happened meanwhile).
            if (Math.Abs(_velocity) < StopThreshold)
            {
                _offset = sv.ContentVerticalOffset;
            }

            double direction = e.Delta > 0 ? -1.0 : 1.0;
            double notches = Math.Abs(e.Delta) / 120.0;
            if (notches <= 0) notches = 1.0;

            _velocity += direction * WheelImpulse * notches;
            if (_velocity > MaxVelocity) _velocity = MaxVelocity;
            if (_velocity < -MaxVelocity) _velocity = -MaxVelocity;

            StartRendering();
        };

        // Any manual interaction (click, drag, keyboard) should kill the glide
        // immediately rather than fight the user for control.
        sv.PreviewMouseDown += (s, e) => StopGliding();
        sv.PreviewKeyDown += (s, e) => StopGliding();
        sv.PreviewStylusDown += (s, e) => StopGliding();

        sv.ScrollChanged += (s, e) =>
        {
            // If something else moved the offset (scrollbar thumb drag, resize,
            // ScrollToTop, etc.) while we're not actively gliding, stay in sync.
            if (!_hooked && Math.Abs(e.VerticalChange) > 0.0001)
            {
                _offset = sv.ContentVerticalOffset;
            }
        };
    }

    private static void StopGliding()
    {
        _velocity = 0;
        if (_sv != null) _offset = _sv.ContentVerticalOffset;
        StopRendering();
    }

    private static void StartRendering()
    {
        if (_hooked) return;
        _hooked = true;
        if (!_clock.IsRunning) _clock.Start();
        _lastTicks = _clock.ElapsedTicks;
        CompositionTarget.Rendering += OnRendering;
    }

    private static void StopRendering()
    {
        if (!_hooked) return;
        _hooked = false;
        CompositionTarget.Rendering -= OnRendering;
    }

    // Runs once per composition frame (tracks whatever cadence the render
    // thread actually lands at) for as long as there's momentum left, then
    // unhooks itself so it never spins while the list is at rest.
    private static void OnRendering(object sender, EventArgs e)
    {
        if (_sv == null) { StopRendering(); return; }

        long now = _clock.ElapsedTicks;
        double dt = (now - _lastTicks) / (double)Stopwatch.Frequency;
        _lastTicks = now;
        if (dt <= 0 || dt > MaxFrameDelta) dt = 1.0 / 60.0;

        double max = _sv.ScrollableHeight;

        _offset += _velocity * dt;

        if (_offset < 0.0)
        {
            _offset = 0.0;
            _velocity = 0.0;
        }
        else if (_offset > max)
        {
            _offset = max;
            _velocity = 0.0;
        }

        // Frame-rate-independent exponential friction (same decay curve at any fps).
        _velocity *= Math.Exp(-FrictionPerSec * dt);

        _sv.ScrollToVerticalOffset(_offset);

        if (Math.Abs(_velocity) < StopThreshold)
        {
            _velocity = 0.0;
            StopRendering();
        }
    }

    public static void Reset()
    {
        _velocity = 0.0;
        _offset = 0.0;
        StopRendering();
        if (_sv != null) _sv.ScrollToVerticalOffset(0.0);
    }
}
'@

try {
    Add-Type -TypeDefinition $script:smoothScrollCsSource -ReferencedAssemblies @('PresentationCore', 'PresentationFramework', 'WindowsBase', 'System.Xaml') -Language CSharp -ErrorAction Stop
}
catch {
    Write-TimingLog "WARN: AutoScapeSmoothScroll compile: $($_.Exception.Message)"
}

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

# --- Auto-Updater Subsystem --------------------------------------------
$updaterModulePath = Join-Path $PSScriptRoot 'AutoScape-Updater.ps1'
if (-not (Test-Path -LiteralPath $updaterModulePath)) {
    $updaterModulePath = Join-Path $PSScriptRoot 'core\AutoScape-Updater.ps1'
}
if (Test-Path -LiteralPath $updaterModulePath) {
    . $updaterModulePath
}


if (-not ('BingWallpaperNative' -as [type])) {
    # CORE: only what's needed synchronously before/at window creation -
    # taskbar app-id, Mica/dark title bar, and SystemParametersInfo (desktop
    # wallpaper apply). SystemParametersInfo has to live here rather than in
    # the deferred block below because the headless -AutoApply/Spotlight
    # path (see "if ($AutoApply)" above) calls it directly and exits before
    # any WPF Dispatcher exists to pump a deferred/background compile.
    # None of this needs WPF/Http assemblies - it's plain P/Invoke - so the
    # Add-Type call below intentionally omits -ReferencedAssemblies.
    $script:nativeCsSourceCore = @'
using System;
using System.Runtime.InteropServices;

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

    private const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    private const int DWMSBT_MAINWINDOW = 2; // Mica

    public static int EnableMica(IntPtr hwnd)
    {
        int backdrop = DWMSBT_MAINWINDOW;
        return DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);

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
}
'@

    try {
        Add-Type -TypeDefinition $script:nativeCsSourceCore -Language CSharp -ErrorAction Stop
        Write-NativeLoadLog "OK: compiled core native helpers in-memory (no DLL file written)"
    }
    catch {
        Write-NativeLoadLog "FAIL: core in-memory compile failed: $($_.Exception.Message)"
        Show-AppErrorDialog `
            -Message "Native helper compilation failed. AutoScape will not work correctly.`n`n$($_.Exception.Message)`n`nThis is often caused by antivirus/EDR software blocking runtime C# compilation (csc.exe). Check that AutoScape / csc.exe isn't being blocked, then restart the app." `
            -Title "AutoScape: native compile failed"
    }
    Write-TimingLog "SCRIPT: core native C# helpers compiled ($($script:startStopwatch.ElapsedMilliseconds)ms since script start)"
}

# EXTRA: everything only touched after the window is already visible -
# folder-picker dark theming + legacy COM fallback, working-set trimming,
# thumbnail accent extraction, and parallel thumbnail download. Compiled on
# a background runspace (Start-DeferredNativeExtraCompile, kicked off from
# ContentRendered below) instead of blocking the window from appearing.
# Only this half needs the WPF imaging / HttpClient assemblies.
$script:nativeCsSourceExtra = @'
using System;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Media;
using System.Windows.Media.Imaging;

public static class BingWallpaperNativeExtra
{
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    private static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

    [DllImport("uxtheme.dll", EntryPoint = "#135")]
    private static extern int SetPreferredAppMode(int preferredAppMode);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("psapi.dll")]
    private static extern bool EmptyWorkingSet(IntPtr hProcess);

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
        private class TimeoutWebClient : System.Net.WebClient
        {
            private int _timeout;
            public TimeoutWebClient(int timeoutSeconds) { _timeout = timeoutSeconds * 1000; }
            protected override System.Net.WebRequest GetWebRequest(Uri uri)
            {
                var w = base.GetWebRequest(uri);
                if (w != null) w.Timeout = _timeout;
                return w;
            }
        }

        public static void DownloadThumbnailsParallel(string[] urlBases, string cacheDir)
        {
            Parallel.ForEach(urlBases, new ParallelOptions { MaxDegreeOfParallelism = 6 }, urlBase =>
            {
                try
                {
                    string safe = Regex.Replace(urlBase, "[^a-zA-Z0-9]", "");
                    string target = Path.Combine(cacheDir, safe + "_thumb.jpg");
                    if (File.Exists(target)) return;

                    string uri = "https://www.bing.com" + urlBase + "_1920x1080.jpg&w=640&h=360&rs=1&c=4";
                    using (var wc = new TimeoutWebClient(20))
                    {
                        wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
                        wc.DownloadFile(uri, target);
                    }
                }
                catch { }
            });
        }

        // Generic version for sources (like Wallhaven/Spotlight) whose
        // thumbnail URLs are already-complete, arbitrary URLs rather than a
        // Bing-style urlBase pattern. urls[i] downloads to targets[i]; a
        // blank/null url or an already-cached target is skipped, same as the
        // Bing path. timeoutSeconds defaults to 20 (matches prior behavior)
        // but callers dealing with small thumbnails should pass something
        // shorter - a single dead/unreachable URL otherwise stalls the
        // entire batch for the full timeout before the rest can return.
        public static void DownloadUrlsParallel(string[] urls, string[] targets, int timeoutSeconds = 20)
        {
            Parallel.For(0, urls.Length, new ParallelOptions { MaxDegreeOfParallelism = 20 }, i =>
            {
                try
                {
                    string url = urls[i];
                    string target = targets[i];
                    if (string.IsNullOrEmpty(url) || File.Exists(target)) return;

                    using (var wc = new TimeoutWebClient(timeoutSeconds))
                    {
                        wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
                        wc.DownloadFile(url, target);
                    }
                }
                catch { }
            });
        }
    }
}
'@

function Start-DeferredNativeExtraCompile {
    # Every call site for BingWallpaperNativeExtra / BingWallpaper.FastAccent /
    # BingWallpaper.FastDownloader already tolerates the type not existing
    # yet (try/catch, or a `-as [type]` check with a fallback path), so it's
    # safe for this background compile to still be running when the window
    # first appears.
    if ('BingWallpaperNativeExtra' -as [type]) { return }
    if ($script:nativeExtraContext) { return }
    if ($script:nativeExtraCompileFailed) { return }

    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param([string]$Source)
            try {
                Add-Type -TypeDefinition $Source -ReferencedAssemblies @(
                    'PresentationCore', 'WindowsBase', 'System.Xaml', 'System.Net.Http'
                ) -Language CSharp -ErrorAction Stop
                return @{ Success = $true; Error = $null }
            }
            catch {
                return @{ Success = $false; Error = $_.Exception.Message }
            }
        }).AddArgument($script:nativeCsSourceExtra)

    $asyncOp = $ps.BeginInvoke()
    $script:nativeExtraContext = @{ PS = $ps; AsyncOp = $asyncOp }

    $script:nativeExtraTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:nativeExtraTimer.Interval = [TimeSpan]::FromMilliseconds(50)
    $script:nativeExtraTimer.Add_Tick({
            param($timerSender, $timerArgs)
            if (-not $script:nativeExtraContext) {
                $timerSender.Stop()
                return
            }
            if ($script:nativeExtraContext.AsyncOp.IsCompleted) {
                $timerSender.Stop()
                Complete-NativeExtraCompile
            }
        })
    $script:nativeExtraTimer.Start()
}

# Finishes the deferred compile kicked off above: EndInvoke, log the result,
# dispose the background PS instance. Idempotent/safe to call from more than
# one place (the timer tick above, or a caller blocked inside
# Wait-NativeExtraCompile below) - only does real work the first time it's
# called after a compile is in flight.
function Complete-NativeExtraCompile {
    $ctx = $script:nativeExtraContext
    if (-not $ctx) { return }
    $script:nativeExtraContext = $null
    if ($script:nativeExtraTimer) {
        try { $script:nativeExtraTimer.Stop() } catch {}
        $script:nativeExtraTimer = $null
    }
    try {
        $resCollection = $ctx.PS.EndInvoke($ctx.AsyncOp)
        $res = if ($resCollection -and $resCollection.Count -gt 0) { $resCollection[0] } else { $null }
        if ($res -and $res.Success -eq $true) {
            Write-NativeLoadLog "OK: compiled extra native helpers in-memory (deferred, no DLL file written)"
        }
        else {
            $err = if ($res) { $res.Error } else { 'Unknown error' }
            $script:nativeExtraCompileFailed = $true
            Write-NativeLoadLog "FAIL: deferred extra compile failed: $err"
        }
    }
    catch {
        $script:nativeExtraCompileFailed = $true
        Write-NativeLoadLog "FAIL: deferred extra compile failed: $($_.Exception.Message)"
    }
    finally {
        try { $ctx.PS.Dispose() } catch {}
    }
}

# Every call site for BingWallpaperNativeExtra / BingWallpaper.FastAccent /
# BingWallpaper.FastDownloader tolerates the type not existing yet - but a
# few of them (folder-picker dialog, per-card accent extraction) need the
# real thing *right now*, not "whenever the background timer above happens
# to catch up." Those call this instead of just try/catching around the
# type reference: it blocks briefly (bounded by TimeoutMs) on the in-flight
# compile's wait handle, finishes it, and returns whether the type is
# actually available by the time it returns.
function Wait-NativeExtraCompile {
    param([int]$TimeoutMs = 2500)

    if ('BingWallpaperNativeExtra' -as [type]) { return $true }
    if ($script:nativeExtraCompileFailed) { return $false }

    if (-not $script:nativeExtraContext) { Start-DeferredNativeExtraCompile }

    if ($script:nativeExtraContext) {
        try { $script:nativeExtraContext.AsyncOp.AsyncWaitHandle.WaitOne($TimeoutMs) | Out-Null } catch {}
        Complete-NativeExtraCompile
    }

    return [bool]('BingWallpaperNativeExtra' -as [type])
}

# Dynamically detect executable version
$script:appVersion = [Version]'1.0.276'
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
                        if ($_.Name -ne 'AsTask') { return $false }
                        try {
                            $p = $_.GetParameters()
                            return ($p.Length -eq 1 -and $p[0].ParameterType.Name -eq 'IAsyncOperation`1')
                        } catch { return $false }
                    })[0]

                function Await($WinRtTask, $ResultType) {
                    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
                    $netTask = $asTask.Invoke($null, @($WinRtTask))
                    $netTask.Wait(-1) | Out-Null
                    $netTask.Result
                }

                $asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
                        if ($_.Name -ne 'AsTask') { return $false }
                        try {
                            $p = $_.GetParameters()
                            return ($p.Length -eq 1 -and $p[0].ParameterType.Name -eq 'IAsyncAction')
                        } catch { return $false }
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

        if ($result -like 'SUCCESS|*') {
            # A brand-new file per apply is required (Windows' lock-screen
            # WinRT APIs sometimes won't refresh if given a StorageFile at a
            # path it's seen before, even with new content) - but nothing
            # was ever removing the older generations, so this folder grew
            # by one file per apply, forever. Now that Windows has accepted
            # the new one, remove every other BingLockScreen-*.jpg here.
            # Best-effort: a delete failing (e.g. OS still briefly holding a
            # handle on the just-replaced one) is not fatal, it'll just be
            # cleaned up on the next successful apply.
            try {
                Get-ChildItem -LiteralPath $cacheDir -Filter 'BingLockScreen-*.jpg' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -ne $resolvedPath } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            }
            catch {}
            return $true
        }
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

# The "Download Image To" box is only 190px wide (was 300px) so it no longer
# forces a 2nd toolbar row. $script:DownloadFolderPath always holds the real,
# full path used for actual file operations; FolderBox.Text only ever holds
# a shortened display string, and the ToolTip carries the full path so it's
# never actually hidden from the user - just not spelled out inline.
function Set-DownloadFolderDisplay {
    param([string]$Path)
    $script:DownloadFolderPath = $Path
    if ([string]::IsNullOrEmpty($Path)) {
        if ($FolderBox) { $FolderBox.Text = ''; $FolderBox.ToolTip = $null }
        return
    }
    $maxChars = if ($script:ToolbarIsCompact) { 15 } else { 20 }
    if ($Path.Length -le $maxChars) {
        $FolderBox.Text = $Path
    }
    else {
        $leaf = Split-Path -Path $Path -Leaf
        $root = [System.IO.Path]::GetPathRoot($Path)
        $candidate = "$root...\$leaf"
        if ($candidate.Length -le $maxChars) {
            $FolderBox.Text = $candidate
        }
        else {
            $FolderBox.Text = "...\$leaf"
        }
    }
    if ($FolderBox) { $FolderBox.ToolTip = $Path }
}

# --- Wallpaper Source Engines (Bing, Spotlight, Wallhaven, Pexels) ----
$sourcesModulePath = Join-Path $PSScriptRoot 'AutoScape-Sources.ps1'
if (-not (Test-Path -LiteralPath $sourcesModulePath)) {
    $sourcesModulePath = Join-Path $PSScriptRoot 'core\AutoScape-Sources.ps1'
}
if (Test-Path -LiteralPath $sourcesModulePath) {
    . $sourcesModulePath
}



function Get-ResolutionDimensions {
    param([string]$Resolution)
    switch -Regex ($Resolution) {
        '4K|UHD' { return @{ Width = 3840; Height = 2160 } }
        '2K|1440' { return @{ Width = 2560; Height = 1440 } }
        '1080' { return @{ Width = 1920; Height = 1080 } }
        '720|1366|768' { return @{ Width = 1280; Height = 720 } }
        default { return @{ Width = 3840; Height = 2160 } }
    }
}

function Resize-WallpaperToResolution {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][int]$TargetWidth,
        [Parameter(Mandatory = $true)][int]$TargetHeight
    )

    Add-Type -AssemblyName System.Drawing

    $source = $null
    $bitmap = $null
    $graphics = $null
    try {
        $source = [System.Drawing.Image]::FromFile($InputPath)

        # Crop to the selected aspect ratio, then resize to exact target pixels.
        $targetRatio = [double]$TargetWidth / [double]$TargetHeight
        $sourceRatio = [double]$source.Width / [double]$source.Height

        if ($sourceRatio -gt $targetRatio) {
            $cropHeight = $source.Height
            $cropWidth = [int][Math]::Round($source.Height * $targetRatio)
            $cropX = [int][Math]::Round(($source.Width - $cropWidth) / 2)
            $cropY = 0
        }
        else {
            $cropWidth = $source.Width
            $cropHeight = [int][Math]::Round($source.Width / $targetRatio)
            $cropX = 0
            $cropY = [int][Math]::Round(($source.Height - $cropHeight) / 2)
        }

        $bitmap = New-Object System.Drawing.Bitmap($TargetWidth, $TargetHeight)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

        $srcRect = New-Object System.Drawing.Rectangle($cropX, $cropY, $cropWidth, $cropHeight)
        $dstRect = New-Object System.Drawing.Rectangle(0, 0, $TargetWidth, $TargetHeight)
        $graphics.DrawImage($source, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)

        $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
        Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
        $encoderParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
            [System.Drawing.Imaging.Encoder]::Quality, [long]95
        )
        $bitmap.Save($OutputPath, $jpegCodec, $encoderParams)
        return $true
    }
    finally {
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        if ($source) { $source.Dispose() }
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

    if ($Image.source -eq 'Local' -or (Test-Path -LiteralPath $imageUri)) {
        Copy-Item -LiteralPath $imageUri -Destination $cachePath -Force
    }
    else {
        Invoke-WebRequest -Uri $imageUri -OutFile $cachePath -UseBasicParsing -ErrorAction Stop
    }

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
        Region               = "auto"
        Resolution           = "4K"
        Target               = "Both"
        Style                = (Get-CurrentDesktopWallpaperStyle)
        SaveFolder           = (Get-DownloadFolder)
        SpotlightEnabled     = $false
        AutoDesktopSource    = "Bing"
        AutoLockScreenSource = "Bing"
        WallhavenApiKey      = ""
        PexelsApiKey         = ""
        LocalFolderPath      = ""
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
        }

        $desktopSource = if ($savedSettings -and $savedSettings.AutoDesktopSource) { [string]$savedSettings.AutoDesktopSource } else { 'Bing' }
        $lockSource = if ($savedSettings -and $savedSettings.AutoLockScreenSource) { [string]$savedSettings.AutoLockScreenSource } else { 'Bing' }

        $todayStamp = Get-Date -Format 'yyyyMMdd'
        if ($savedSettings -and 
            $savedSettings.LastAutoAppliedDate -eq $todayStamp -and 
            $savedSettings.LastAutoDesktopSource -eq $desktopSource -and 
            $savedSettings.LastAutoLockSource -eq $lockSource) {
            # Already applied for today, exit quietly without redundant work
            [Environment]::Exit(0)
        }

        function Invoke-AutoSource {
            param([string]$Source, [string]$Target)

            switch ($Source) {
                'Bing' {
                    $images = Get-BingImages -Region $Region
                }
                'Spotlight' {
                    $images = Get-SpotlightImages -Count 1
                }
                'Wallhaven' {
                    $wallhavenKey = if ($savedSettings -and $savedSettings.WallhavenApiKey) { [string]$savedSettings.WallhavenApiKey } else { '' }
                    $images = Get-WallhavenImages -Count 1 -ApiKey $wallhavenKey
                }
                'Pexels' {
                    $pexelsKey = if ($savedSettings -and $savedSettings.PexelsApiKey) { [string]$savedSettings.PexelsApiKey } else { '' }
                    $images = Get-PexelsImages -Count 1 -ApiKey $pexelsKey
                }
                'Local' {
                    $localFolder = if ($savedSettings -and $savedSettings.LocalFolderPath) { [string]$savedSettings.LocalFolderPath } else { '' }
                    $images = Get-LocalImages -FolderPath $localFolder -Count 1
                }
                'None' {
                    return
                }
                default {
                    throw "Unknown wallpaper source: $Source"
                }
            }

            if (-not $images -or $images.Count -eq 0) {
                throw "No wallpaper was returned by $Source."
            }

            Set-BingImage -Image $images[0] -Resolution $Resolution -Target $Target -Style $Style | Out-Null
        }

        $applySuccess = $false
        $lastApplyError = $null

        for ($attempt = 1; $attempt -le 5; $attempt++) {
            $errors = @()
            if ($desktopSource -eq 'Bing' -and $lockSource -eq 'Bing') {
                try {
                    $images = Get-BingImages -Region $Region
                    if (-not $images -or $images.Count -eq 0) { throw "No wallpaper was returned by Bing." }
                    Set-BingImage -Image $images[0] -Resolution $Resolution -Target 'Both' -Style $Style | Out-Null
                    $applySuccess = $true
                } catch {
                    $errors += "AutoApply Both: $($_.Exception.Message)"
                }
            }
            elseif ($desktopSource -eq 'Local' -and $lockSource -eq 'Local') {
                try {
                    $localFolder = if ($savedSettings -and $savedSettings.LocalFolderPath) { [string]$savedSettings.LocalFolderPath } else { '' }
                    $images = Get-LocalImages -FolderPath $localFolder -Count 1
                    if (-not $images -or $images.Count -eq 0) { throw "No wallpaper was found in the local folder." }
                    Set-BingImage -Image $images[0] -Resolution $Resolution -Target 'Both' -Style $Style | Out-Null
                    $applySuccess = $true
                } catch {
                    $errors += "AutoApply Both Local: $($_.Exception.Message)"
                }
            }
            else {
                try { Invoke-AutoSource -Source $desktopSource -Target 'Desktop' } catch { $errors += "Desktop: $($_.Exception.Message)" }
                try { Invoke-AutoSource -Source $lockSource -Target 'Lock screen' } catch { $errors += "Lock screen: $($_.Exception.Message)" }
                if ($errors.Count -eq 0) { $applySuccess = $true }
            }

            if ($applySuccess) {
                break
            }

            $lastApplyError = ($errors -join '; ')
            if ($attempt -lt 5) {
                Start-Sleep -Seconds 60
            }
        }

        if (-not $applySuccess) {
            throw $lastApplyError
        }

        # Mark successful auto-apply for today
        try {
            $existing = Load-Settings
            $settingsObj = @{
                Region               = if ($existing -and $existing.Region) { $existing.Region } else { "auto" }
                Resolution           = if ($existing -and $existing.Resolution) { $existing.Resolution } else { "4K" }
                Target               = if ($existing -and $existing.Target) { $existing.Target } else { "Both" }
                Style                = if ($existing -and $existing.Style) { $existing.Style } else { "Fit" }
                SaveFolder           = if ($existing -and $existing.SaveFolder) { $existing.SaveFolder } else { (Get-DownloadFolder) }
                AutoDesktopSource    = $desktopSource
                AutoLockScreenSource = $lockSource
                AutoSchedule         = if ($existing -and $existing.AutoSchedule) { $existing.AutoSchedule } else { 'Daily' }
                SpotlightEnabled     = if ($existing -and $null -ne $existing.SpotlightEnabled) { [bool]$existing.SpotlightEnabled } else { $true }
                WallhavenApiKey      = if ($existing -and $existing.WallhavenApiKey) { $existing.WallhavenApiKey } else { '' }
                PexelsApiKey         = if ($existing -and $existing.PexelsApiKey) { $existing.PexelsApiKey } else { '' }
                LocalFolderPath      = if ($existing -and $existing.LocalFolderPath) { [string]$existing.LocalFolderPath } else { '' }
                LastAutoAppliedDate  = $todayStamp
                LastAutoDesktopSource= $desktopSource
                LastAutoLockSource   = $lockSource
            }
            $settingsObj | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $script:settingsPath
        } catch {}

        [Environment]::Exit(0)
    }
    catch {
        Write-Error "Failed to apply AutoScape wallpaper: $($_.Exception.Message)"
        [Environment]::Exit(1)
    }
}

try { [AppUserModel]::SetCurrentProcessExplicitAppUserModelID("AutoScape.App") } catch {}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AutoScape" Height="780" Width="1100" MinWidth="820" MinHeight="560"
        Background="Transparent" FontFamily="Segoe UI" WindowStartupLocation="CenterScreen" WindowState="Maximized">
    
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="ToolTipService.InitialShowDelay" Value="600"/>
            <Setter Property="ToolTipService.BetweenShowDelay" Value="600"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="RevealBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#15FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ModernIconButton" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#F0F0F0"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#15FFFFFF"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="RevealBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#15FFFFFF"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#25FFFFFF"/>
                                <Setter TargetName="RevealBorder" Property="BorderBrush" Value="#0078D4"/>
                                <Setter Property="Foreground" Value="#0078D4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <ControlTemplate x:Key="ComboBoxToggleButtonTemplate" TargetType="ToggleButton">
            <Border Name="RevealBorder" Background="{TemplateBinding Background}" BorderBrush="#15FFFFFF" BorderThickness="1" CornerRadius="6">
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
                    <Setter TargetName="RevealBorder" Property="Background" Value="#15FFFFFF"/>
                    <Setter TargetName="ArrowIcon" Property="Foreground" Value="#DDD"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                    <Setter TargetName="RevealBorder" Property="Background" Value="#25FFFFFF"/>
                    <Setter TargetName="RevealBorder" Property="BorderBrush" Value="#0078D4"/>
                    <Setter TargetName="ArrowIcon" Property="Foreground" Value="#0078D4"/>
                </Trigger>
                <Trigger Property="IsChecked" Value="True">
                    <Setter TargetName="RevealBorder" Property="Background" Value="#25FFFFFF"/>
                    <Setter TargetName="RevealBorder" Property="BorderBrush" Value="#0078D4"/>
                    <Setter TargetName="ArrowIcon" Property="Foreground" Value="#0078D4"/>
                </Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate>

        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#F0F0F0"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Height" Value="38"/>
            <Setter Property="MinWidth" Value="90"/>
            <Setter Property="HorizontalAlignment" Value="Left"/>
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
                            <ContentPresenter Name="IconSite"
                                              Content="{TemplateBinding Tag}"
                                              IsHitTestVisible="False"
                                              HorizontalAlignment="Left"
                                              VerticalAlignment="Center"
                                              Margin="13,0,0,0"/>
                            <ContentPresenter Name="ContentSite"
                                              IsHitTestVisible="False"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                                              TextElement.Foreground="{TemplateBinding Foreground}"
                                              TextElement.FontSize="{TemplateBinding FontSize}"
                                              VerticalAlignment="Center"
                                              Margin="40,0,34,0"/>
                            <Popup Name="PART_Popup"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom"
                                   VerticalOffset="8"
                                   PopupAnimation="None"
                                   AllowsTransparency="True"
                                   StaysOpen="False"
                                   Focusable="False">
                                <Border Background="#F21E1E1E" BorderBrush="#15FFFFFF" BorderThickness="1" CornerRadius="8" Margin="0" MinWidth="{TemplateBinding ActualWidth}" Padding="4">
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
            <Setter Property="Focusable" Value="False"/>
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
                                <Setter TargetName="RevealBorder" Property="Background" Value="#15FFFFFF"/>
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
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Height" Value="38"/>
            <Setter Property="Padding" Value="40,0,14,0"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="CaretBrush" Value="#0078D4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Name="RevealBorder" Background="{TemplateBinding Background}" BorderBrush="#15FFFFFF" BorderThickness="1" CornerRadius="6">
                            <Grid>
                                <ContentPresenter Content="{TemplateBinding Tag}" IsHitTestVisible="False" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="13,0,0,0"/>
                                <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#15FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#25FFFFFF"/>
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

        <Style TargetType="ToolTip">
            <Setter Property="Background" Value="#2E2E2E"/>
            <Setter Property="Foreground" Value="#F5F5F5"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="HasDropShadow" Value="False"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToolTip">
                        <Border Background="{TemplateBinding Background}" BorderBrush="#454545" BorderThickness="1.5" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <Border.Effect>
                                <DropShadowEffect BlurRadius="14" ShadowDepth="3" Opacity="0.4" Color="Black"/>
                            </Border.Effect>
                            <ContentPresenter/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid Name="MainContent" Margin="24,20,24,16">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Grid Name="HeaderGrid" Margin="0,0,0,24">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <StackPanel Name="HeaderTitlePanel" Grid.Row="0" Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
                    <Border Name="LogoBorder" Background="Transparent" Width="46" Height="46" Margin="0,0,14,0" VerticalAlignment="Center"/>
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock Text="AutoScape" FontSize="26" FontWeight="SemiBold" Foreground="#FAFAFA" LineHeight="29" Margin="0,0,0,2"/>
                        <TextBlock Name="AppSubtitleText" Text="Bing wallpapers, delivered daily" FontSize="12.5" Foreground="#9E9E9E" FontWeight="Normal" LineHeight="16"/>
                    </StackPanel>
                </StackPanel>

                <!-- Bing / Spotlight / Wallhaven / Pexels source toggle pill centered in header -->
                <Border Name="SourceTogglePill" Grid.Row="0" HorizontalAlignment="Center" VerticalAlignment="Center"
                        Background="Transparent" BorderBrush="#15FFFFFF" BorderThickness="1" CornerRadius="8" Padding="3">
                    <StackPanel Orientation="Horizontal">
                        <Grid>
                            <Border Name="SourceBingIndicator" Background="#25FFFFFF" CornerRadius="5" Opacity="1" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                            <Button Name="SourceBingBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                <TextBlock Name="SourceBingLabel" Text="Bing" FontSize="13" FontWeight="SemiBold" Foreground="#FFFFFF" HorizontalAlignment="Center" Margin="16,6,16,7"/>
                            </Button>
                        </Grid>
                        <Grid>
                            <Border Name="SourceSpotlightIndicator" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                            <Button Name="SourceSpotlightBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                <TextBlock Name="SourceSpotlightLabel" Text="Spotlight" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="16,6,16,7"/>
                            </Button>
                        </Grid>
                        <Grid>
                            <Border Name="SourceWallhavenIndicator" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                            <Button Name="SourceWallhavenBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                <TextBlock Name="SourceWallhavenLabel" Text="Wallhaven" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="16,6,16,7"/>
                            </Button>
                        </Grid>
                        <Grid>
                            <Border Name="SourcePexelsIndicator" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                            <Button Name="SourcePexelsBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                <TextBlock Name="SourcePexelsLabel" Text="Pexels" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="16,6,16,7"/>
                            </Button>
                        </Grid>
                        <Grid>
                            <Border Name="SourceLocalIndicator" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                            <Button Name="SourceLocalBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                <TextBlock Name="SourceLocalLabel" Text="Local" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="16,6,16,7"/>
                            </Button>
                        </Grid>
                    </StackPanel>
                </Border>
            </Grid>

            <WrapPanel Grid.Row="1" Name="ToolbarWrap" Orientation="Horizontal" Margin="0,0,0,20">

                <StackPanel Name="ColRegion" Margin="0,0,16,16">
                    <TextBlock Name="LabelRegion" Text="Region" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                    <ComboBox Name="RegionBox" Width="235" FontSize="13.5" Height="38">
                        <ComboBox.Tag>
                            <Viewbox Width="16.5" Height="16.5">
                                <Canvas Width="20" Height="20">
                                    <Ellipse Canvas.Left="1" Canvas.Top="1" Width="18" Height="18" Stroke="#9E9E9E" StrokeThickness="1.6"/>
                                    <Ellipse Canvas.Left="6" Canvas.Top="1" Width="8" Height="18" Stroke="#9E9E9E" StrokeThickness="1.6"/>
                                    <Line X1="1" Y1="10" X2="19" Y2="10" Stroke="#9E9E9E" StrokeThickness="1.6"/>
                                </Canvas>
                            </Viewbox>
                        </ComboBox.Tag>
                    </ComboBox>
                    <!-- Universal API Key Grid for all current and future sources (Wallhaven, Pexels, NASA, etc.) -->
                    <Grid Name="ApiKeyGrid" Visibility="Collapsed">
                        <TextBox Name="ApiKeyBox" Width="235" FontSize="13.5" Height="38" Padding="36,0,32,0">
                            <TextBox.Tag>
                                <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="#9E9E9E"/>
                            </TextBox.Tag>
                        </TextBox>
                        <TextBlock Name="ApiKeyPlaceholder" Text="Paste API key here" Foreground="#55FFFFFF" 
                                   FontSize="{Binding FontSize, ElementName=ApiKeyBox}" 
                                   IsHitTestVisible="False" VerticalAlignment="Center" Margin="36,-1,32,0"/>
                        <Button Name="ClearApiKeyBtn" Style="{StaticResource ModernIconButton}" Width="26" Height="26" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,6,0" ToolTip="Clear API Key" Visibility="Collapsed">
                            <TextBlock Text="&#xE8BB;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="#9E9E9E" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Button>
                    </Grid>
                    <!-- Local Folder Selection Button in Toolbar -->
                    <Border Name="LocalFolderBorder" Visibility="Collapsed" Width="235" Height="38" Background="#18FFFFFF" BorderBrush="#25FFFFFF" BorderThickness="1" CornerRadius="8">
                        <Button Name="LocalFolderBtn" Background="Transparent" BorderThickness="0" Cursor="Hand" HorizontalContentAlignment="Stretch" VerticalContentAlignment="Center" Padding="12,0,10,0">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="&#xED25;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="#9E9E9E" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                <TextBlock Name="LocalFolderLabel" Grid.Column="1" Text="Select Folder..." FontSize="13" Foreground="#E0E0E0" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                                <TextBlock Grid.Column="2" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="#888888" VerticalAlignment="Center" Margin="6,0,0,0"/>
                            </Grid>
                        </Button>
                    </Border>
                </StackPanel>

                <StackPanel Name="ColRefresh" Margin="0,0,16,16">
                    <TextBlock Name="LabelRefresh" Text=" " FontSize="13" FontWeight="SemiBold" Margin="4,0,0,8" IsHitTestVisible="False"/>
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

                <StackPanel Name="ColResolution" Margin="0,0,16,16">
                    <TextBlock Name="LabelResolution" Text="Resolution" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                    <ComboBox Name="ResolutionBox" Width="110" FontSize="13.5" Height="38">
                        <ComboBox.Tag>
                            <TextBlock Text="&#xE8B9;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#9E9E9E"/>
                        </ComboBox.Tag>
                    </ComboBox>
                </StackPanel>

                <StackPanel Name="ColApplyTo" Margin="0,0,16,16">
                    <TextBlock Name="LabelApplyTo" Text="Apply To" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                    <ComboBox Name="TargetBox" Width="155" FontSize="13.5" Height="38">
                        <ComboBox.Tag>
                            <Viewbox Width="16.5" Height="16.5">
                                <Canvas Width="20" Height="20">
                                    <Rectangle Canvas.Left="1" Canvas.Top="2" Width="18" Height="12" RadiusX="1.5" RadiusY="1.5" Stroke="#9E9E9E" StrokeThickness="1.6"/>
                                    <Line X1="10" Y1="14" X2="10" Y2="17" Stroke="#9E9E9E" StrokeThickness="1.6"/>
                                    <Line X1="6" Y1="17" X2="14" Y2="17" Stroke="#9E9E9E" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                                </Canvas>
                            </Viewbox>
                        </ComboBox.Tag>
                    </ComboBox>
                </StackPanel>

                <StackPanel Name="ColStyle" Margin="0,0,16,16">
                    <TextBlock Name="LabelStyle" Text="Style" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                    <ComboBox Name="StyleBox" Width="125" FontSize="13.5" Height="38">
                        <ComboBox.Tag>
                            <Viewbox Width="16.5" Height="16.5">
                                <Canvas Width="20" Height="20">
                                    <Path Data="M2,7 V2 H7" Stroke="#9E9E9E" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                                    <Path Data="M18,13 V18 H13" Stroke="#9E9E9E" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                                </Canvas>
                            </Viewbox>
                        </ComboBox.Tag>
                    </ComboBox>
                </StackPanel>

                <StackPanel Name="ColDownloadTo" Margin="0,0,16,14" Width="190">
                    <TextBlock Name="LabelDownloadTo" Text="Download Image To" HorizontalAlignment="Left" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8" TextTrimming="CharacterEllipsis"/>
                    <TextBox Name="FolderBox" Height="38" HorizontalAlignment="Stretch" FontSize="13.5" IsReadOnly="True" Cursor="Hand">
                        <TextBox.Tag>
                            <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#9E9E9E"/>
                        </TextBox.Tag>
                    </TextBox>
                </StackPanel>

                <StackPanel Name="ColAuto" Margin="0,0,16,14">
                    <TextBlock Name="LabelAuto" Text="Automation" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="4,0,0,8"/>
                    
                    <Button Name="AutoUnifiedButton" Style="{StaticResource ModernIconButton}" Height="38" Padding="0,0,8,0">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <TextBlock Text="Auto" FontSize="13" FontWeight="SemiBold" Foreground="White" VerticalAlignment="Center" Margin="12,0,8,0"/>

                            <Grid Name="AutoPillRow" VerticalAlignment="Center" Margin="0,0,4,0">
                                <Border Name="SpotlightPill" Width="44" Height="20" CornerRadius="10"
                                        Background="#404040" BorderBrush="#5A5A5A" BorderThickness="1"
                                        Cursor="Hand" VerticalAlignment="Center"
                                        SnapsToDevicePixels="True" UseLayoutRounding="True">
                                    <Ellipse Name="SpotlightThumb" Width="14" Height="14" Fill="#C8C8C8"
                                             HorizontalAlignment="Left" VerticalAlignment="Center" Margin="3,0,0,0"
                                             SnapsToDevicePixels="True" UseLayoutRounding="True">
                                        <Ellipse.RenderTransform>
                                            <TranslateTransform X="0" Y="0"/>
                                        </Ellipse.RenderTransform>
                                    </Ellipse>
                                </Border>
                            </Grid>
    
                            <Button Name="SpotlightSetBtn" Width="30" Height="30" Margin="0,0,4,0" VerticalAlignment="Center"
                                    Cursor="Hand" IsEnabled="False" ToolTip="Configure automatic wallpaper changes"
                                    Background="Transparent" BorderBrush="Transparent" BorderThickness="0" Foreground="#777">
                                <Button.Style>
                                    <Style TargetType="Button">
                                        <Setter Property="Template">
                                            <Setter.Value>
                                                <ControlTemplate TargetType="Button">
                                                    <Border Name="ChevronBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                                                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                                    </Border>
                                                    <ControlTemplate.Triggers>
                                                        <Trigger Property="IsMouseOver" Value="True">
                                                            <Setter TargetName="ChevronBorder" Property="Background" Value="#15FFFFFF"/>
                                                            <Setter Property="Foreground" Value="#DDD"/>
                                                        </Trigger>
                                                        <Trigger Property="IsPressed" Value="True">
                                                            <Setter TargetName="ChevronBorder" Property="Background" Value="#25FFFFFF"/>
                                                            <Setter Property="Foreground" Value="#0078D4"/>
                                                        </Trigger>
                                                    </ControlTemplate.Triggers>
                                                </ControlTemplate>
                                            </Setter.Value>
                                        </Setter>
                                    </Style>
                                </Button.Style>

                                <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="11"
                                           Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Button>
                        </StackPanel>
                    </Button>

                    <Popup Name="SpotlightOptionsPopup" PlacementTarget="{Binding ElementName=AutoUnifiedButton}"
                               Placement="Bottom" VerticalOffset="6" HorizontalOffset="0" AllowsTransparency="True" StaysOpen="False"
                               PopupAnimation="None" Focusable="False">
                            <Grid Name="SpotlightPopupTransformHost" Margin="14" RenderTransformOrigin="0.5,0.5">
                                <Grid.RenderTransform>
                                    <TranslateTransform x:Name="SpotlightPopupTransform" Y="-8"/>
                                </Grid.RenderTransform>
                                <Border Name="SpotlightPopupCard" Background="#F21E1E1E" BorderBrush="#15FFFFFF" BorderThickness="1"
                                        CornerRadius="8" Padding="16" Width="490" Opacity="0" SnapsToDevicePixels="False">
                                    <Border.Effect>
                                        <DropShadowEffect Color="#000000" BlurRadius="14" ShadowDepth="3" Opacity="0.4"/>
                                    </Border.Effect>
                                    <StackPanel>
                                        <TextBlock Text="Choose your wallpaper source" FontSize="14" FontWeight="SemiBold" Foreground="#FAFAFA" Margin="0,0,0,10"/>
                                        <Border Height="1" Background="#2A2A2A" Margin="0,0,0,14"/>
                                        
                                        <!-- Hidden ComboBoxes for logic retention -->
                                        <ComboBox Name="AutoDesktopSourceBox" Visibility="Collapsed" />
                                        <ComboBox Name="AutoLockScreenSourceBox" Visibility="Collapsed" />
                                        <ComboBox Name="AutoScheduleBox" Visibility="Collapsed" />
                                        
                                        <TextBlock Text="Desktop" FontSize="15" FontWeight="Bold" Foreground="#FAFAFA" Margin="0,0,0,8"/>
                                        <Border HorizontalAlignment="Stretch" Background="Transparent" BorderBrush="#15FFFFFF" BorderThickness="1" CornerRadius="8" Padding="3" Margin="0,0,0,16">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                </Grid.ColumnDefinitions>
                                                <Grid Grid.Column="0">
                                                    <Border Name="DeskBingInd" Background="#25FFFFFF" CornerRadius="5" Opacity="1" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="DeskBingBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="DeskBingLbl" Text="Bing" FontSize="13" FontWeight="SemiBold" Foreground="#FFFFFF" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                                <Grid Grid.Column="1">
                                                    <Border Name="DeskSpotlightInd" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="DeskSpotlightBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="DeskSpotlightLbl" Text="Spotlight" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                                <Grid Grid.Column="2">
                                                    <Border Name="DeskWallhavenInd" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="DeskWallhavenBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="DeskWallhavenLbl" Text="Wallhaven" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                                <Grid Grid.Column="3">
                                                    <Border Name="DeskPexelsInd" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="DeskPexelsBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="DeskPexelsLbl" Text="Pexels" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                                <Grid Grid.Column="4">
                                                    <Border Name="DeskLocalInd" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="DeskLocalBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="DeskLocalLbl" Text="Local" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                                <Grid Grid.Column="5">
                                                    <Border Name="DeskNoneInd" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="DeskNoneBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="DeskNoneLbl" Text="None" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                            </Grid>
                                        </Border>
                                        
                                        <TextBlock Text="Lock screen" FontSize="15" FontWeight="Bold" Foreground="#FAFAFA" Margin="0,0,0,8"/>
                                        <Border HorizontalAlignment="Stretch" Background="Transparent" BorderBrush="#15FFFFFF" BorderThickness="1" CornerRadius="8" Padding="3" Margin="0,0,0,16">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                </Grid.ColumnDefinitions>
                                                <Grid Grid.Column="0">
                                                    <Border Name="LockBingInd" Background="#25FFFFFF" CornerRadius="5" Opacity="1" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="LockBingBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="LockBingLbl" Text="Bing" FontSize="13" FontWeight="SemiBold" Foreground="#FFFFFF" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                                <Grid Grid.Column="1">
                                                    <Border Name="LockSpotlightInd" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="LockSpotlightBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="LockSpotlightLbl" Text="Spotlight" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                                <Grid Grid.Column="2">
                                                    <Border Name="LockWallhavenInd" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="LockWallhavenBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="LockWallhavenLbl" Text="Wallhaven" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                                <Grid Grid.Column="3">
                                                    <Border Name="LockPexelsInd" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="LockPexelsBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="LockPexelsLbl" Text="Pexels" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                                <Grid Grid.Column="4">
                                                    <Border Name="LockLocalInd" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="LockLocalBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="LockLocalLbl" Text="Local" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                                <Grid Grid.Column="5">
                                                    <Border Name="LockNoneInd" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="LockNoneBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="LockNoneLbl" Text="None" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                            </Grid>
                                        </Border>
                                        
                                        <TextBlock Text="Schedule" FontSize="15" FontWeight="Bold" Foreground="#FAFAFA" Margin="0,0,0,8"/>
                                        <Border HorizontalAlignment="Stretch" Background="Transparent" BorderBrush="#15FFFFFF" BorderThickness="1" CornerRadius="8" Padding="3" Margin="0,0,0,10">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="*"/>
                                                </Grid.ColumnDefinitions>
                                                <Grid Grid.Column="0">
                                                    <Border Name="SchedEverydayInd" Background="#25FFFFFF" CornerRadius="5" Opacity="1" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="SchedEverydayBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="SchedEverydayLbl" Text="Everyday" FontSize="13" FontWeight="SemiBold" Foreground="#FFFFFF" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                                <Grid Grid.Column="1">
                                                    <Border Name="SchedTestInd" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                                    <Button Name="SchedTestBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand">
                                                        <TextBlock Name="SchedTestLbl" Text="1 Minute (Test)" FontSize="13" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,6,0,7"/>
                                                    </Button>
                                                </Grid>
                                            </Grid>
                                        </Border>
                                        
                                        <TextBlock Text="Changes are saved Automatically" FontSize="11" Foreground="#888888" HorizontalAlignment="Left" Margin="6,0,0,0" FontStyle="Italic"/>
                                    </StackPanel>
                                </Border>
                            </Grid>
                        </Popup>
                </StackPanel>

            </WrapPanel>

            <Border Grid.Row="2" Background="Transparent" CornerRadius="18" BorderThickness="0" ClipToBounds="True" VerticalAlignment="Top">
                <Grid>
                    <ScrollViewer Name="GalleryScrollViewer" CanContentScroll="False" Margin="0,16,0,16" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" VerticalAlignment="Top" FocusVisualStyle="{x:Null}">
                        <UniformGrid Name="GalleryPanel" Columns="4" VerticalAlignment="Top" />
                    </ScrollViewer>
                    <!-- Centered Empty State for Local Tab when no folder is selected -->
                    <Border Name="LocalEmptyStatePanel" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,40,0,40">
                        <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                            <Border Width="72" Height="72" CornerRadius="36" Background="#14FFFFFF" BorderBrush="#20FFFFFF" BorderThickness="1" HorizontalAlignment="Center" Margin="0,0,0,16">
                                <TextBlock Text="&#xED25;" FontFamily="Segoe MDL2 Assets" FontSize="32" Foreground="#88FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <TextBlock Text="Choose a Wallpaper Folder" FontSize="18" FontWeight="SemiBold" Foreground="White" HorizontalAlignment="Center" Margin="0,0,0,6"/>
                            <TextBlock Text="Select a folder on your PC to load all images into AutoScape" FontSize="13" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,0,0,20"/>
                            <Button Name="EmptyStateSelectFolderBtn" Width="210" Height="42" Background="#20FFFFFF" BorderBrush="#35FFFFFF" BorderThickness="1" Foreground="White" FontSize="14" FontWeight="SemiBold" Cursor="Hand">
                                <Button.Resources>
                                    <Style TargetType="Border">
                                        <Setter Property="CornerRadius" Value="8"/>
                                    </Style>
                                </Button.Resources>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                                    <TextBlock Text="&#xE8B7;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="White" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                    <TextBlock Text="Select a Local Folder" VerticalAlignment="Center"/>
                                </StackPanel>
                            </Button>
                        </StackPanel>
                    </Border>
                </Grid>
            </Border>

            <Grid Grid.Row="3" Margin="0,28,16,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="StatusText" Text="" Foreground="#888" FontSize="14" FontWeight="Medium" VerticalAlignment="Center" TextWrapping="Wrap"/>
                
                <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <Button Name="InfoBtn" Style="{StaticResource ModernIconButton}" Width="46" Height="46" Margin="0,0,12,0" ToolTip="User Guide">
                        <TextBlock Text="&#xE946;" FontFamily="Segoe MDL2 Assets" FontSize="18" Foreground="#9E9E9E" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Button>
                    <Button Name="DownloadBtn" Content="Download" Width="130" Height="46" Margin="0,0,12,0" Background="Transparent" BorderBrush="#15FFFFFF" BorderThickness="1" Foreground="#E0E0E0" FontSize="15" FontWeight="SemiBold" />
                    <Button Name="UpdateBtn" Content="Apply" Width="140" Height="46" Background="Transparent" BorderBrush="#15FFFFFF" BorderThickness="1" Foreground="White" FontSize="15" FontWeight="SemiBold" />
                </StackPanel>
            </Grid>
        </Grid>

        <Border Name="ModalDimOverlay" Background="#000000" Opacity="0" Visibility="Collapsed" IsHitTestVisible="False" Panel.ZIndex="900"/>
        <Grid Name="ModalHost" Background="Transparent" Visibility="Collapsed" IsHitTestVisible="False" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Panel.ZIndex="1000"/>
        <!-- Dedicated layer for Show-ModernDialog (Keyboard Shortcuts, Check for
             Updates, etc.) so those dialogs stack ON TOP of a still-open User
             Guide modal instead of sharing ModalHost's single slot and evicting
             it. Sits above ModalHost's z-index of 1000. -->
        <Border Name="DialogDimOverlay" Background="#000000" Opacity="0" Visibility="Collapsed" IsHitTestVisible="False" Panel.ZIndex="1050"/>
        <Grid Name="DialogModalHost" Background="Transparent" Visibility="Collapsed" IsHitTestVisible="False" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Panel.ZIndex="1100"/>
    </Grid>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
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

function Test-IsInsideToolbar($visual) {
    # Walks up the visual tree to see if $visual sits inside the main
    # toolbar (Region/Resolution/Apply To/Style/Download Image To row).
    $current = $visual
    while ($current) {
        if ($current -is [System.Windows.FrameworkElement] -and $current.Name -eq 'ToolbarWrap') {
            return $true
        }
        $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
    }
    return $false
}

function Find-RevealBorders($visual) {
    if (-not $visual) { return }
    if ($visual -is [System.Windows.Controls.Border] -and ($visual.Name -eq "RevealBorder" -or $visual.Name -eq "AutoUnifiedButton")) {
        $alreadyAdded = $false
        foreach ($item in $script:revealElements) {
            if ($item.Element -eq $visual) { $alreadyAdded = $true; break }
        }
        if (-not $alreadyAdded) {
            $revealBrush = New-Object System.Windows.Media.RadialGradientBrush
            $revealBrush.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute
            $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(60, 255, 255, 255), 0.0)))
            $revealBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(21, 255, 255, 255), 1.0)))
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

$window.Add_Loaded({
        $tb = $window.FindName('ApiKeyBox')
        if ($tb) { $tb.ApplyTemplate() | Out-Null }
        Find-RevealBorders $window
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

            # Explicitly require Windows 11 (Build 22000+) to prevent the pitch-black Transparent bug on Win10
            $os = [System.Environment]::OSVersion.Version
            $isWin11 = ($os.Major -ge 10 -and $os.Build -ge 22000)
            
            $isMicaCapable = $false
            if ($isWin11) {
                $micaResult = [BingWallpaperNative]::EnableMica($helper.Handle)
                $isMicaCapable = ($micaResult -eq 0)
            }

            if ($isMicaCapable) {
                $margins = New-Object BingWallpaperNative+MARGINS
                $margins.cxLeftWidth = -1
                $margins.cxRightWidth = -1
                $margins.cyTopHeight = -1
                $margins.cyBottomHeight = -1
                $null = [BingWallpaperNative]::DwmExtendFrameIntoClientArea($helper.Handle, [ref]$margins)
            }
            else {
                # Provide a nice dark gray fallback so cards maintain contrast on Windows 10
                $window.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(32, 32, 32))
            }

            if ($isMicaCapable) {
                $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($helper.Handle)
                if ($hwndSource -and $hwndSource.CompositionTarget) {
                    $hwndSource.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
                }
            }
        }
    }
    catch {}
}
$window.Add_SourceInitialized($applyDarkTitleBar)

# Header logo: loaded from a PNG instead of being built from inline XAML
# gradients/paths. A BitmapImage load is cheap and synchronous, so this can
# run immediately - no deferral, no pop-in, and no risk of the vector
# recreation being subtly wrong since it's just displaying the real artwork.
try {
    $logoPath = Join-Path $scriptDir 'assets\logo.png'
    if (Test-Path -LiteralPath $logoPath) {
        $logoBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $logoBitmap.BeginInit()
        $logoBitmap.UriSource = New-Object System.Uri((Resolve-Path -LiteralPath $logoPath).Path)
        $logoBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $logoBitmap.EndInit()
        $logoBitmap.Freeze()

        $logoImage = New-Object System.Windows.Controls.Image
        $logoImage.Source = $logoBitmap
        $logoImage.Stretch = [System.Windows.Media.Stretch]::Uniform
        $logoImage.Margin = New-Object System.Windows.Thickness(0)

        $logoBorder = $window.FindName('LogoBorder')
        if ($logoBorder) { $logoBorder.Child = $logoImage }
    }
}
catch {}

$window.Add_StateChanged({
        if ($script:activeModalControl) {
            Close-InWindowModal
        }
        if ($script:activeDialogModalControl) {
            Close-DialogModal
        }
    })
$script:appSettings = Load-Settings
$script:localFolderPath = if ($script:appSettings -and $script:appSettings.LocalFolderPath) { [string]$script:appSettings.LocalFolderPath } else { '' }

$script:ApiKeySources = @{
    'Wallhaven' = @{
        Label        = 'Wallhaven API Key'
        Placeholder  = 'Paste API key here'
        Tooltip      = 'Optional - Wallhaven works without one for SFW wallpapers. Add a key from wallhaven.cc/settings/account for a higher rate limit.'
        ExpectedLen  = 32
        CharPattern  = '^[a-zA-Z0-9]+$'
        IsOptional   = $true
        SettingsProp = 'WallhavenApiKey'
    }
    'Pexels'    = @{
        Label        = 'Pexels API Key'
        Placeholder  = 'Paste API key here'
        Tooltip      = 'Required - Get a free instant API key from pexels.com/api'
        ExpectedLen  = 56
        CharPattern  = '^[a-zA-Z0-9_-]+$'
        IsOptional   = $false
        SettingsProp = 'PexelsApiKey'
    }
}

function Test-SourceApiKey([string]$Source, [string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Key)) {
        $isOpt = if ($script:ApiKeySources.ContainsKey($Source)) { [bool]$script:ApiKeySources[$Source].IsOptional } else { $false }
        if ($isOpt) {
            return @{ Valid = $true; Error = $null }
        }
        return @{ Valid = $false; Error = "Please enter a valid $Source API key." }
    }

    $trimmed = $Key.Trim()

    # Reject if user pasted another source's key!
    foreach ($otherSource in $script:ApiKeySources.Keys) {
        if ($otherSource -ne $Source) {
            $otherSpec = $script:ApiKeySources[$otherSource]
            if ($trimmed.Length -eq $otherSpec.ExpectedLen) {
                return @{
                    Valid = $false
                    Error = "Invalid $Source key: That is a $otherSource API key ($($otherSpec.ExpectedLen) characters). Please enter a valid $Source API key."
                }
            }
        }
    }

    $spec = if ($script:ApiKeySources.ContainsKey($Source)) { $script:ApiKeySources[$Source] } else { $null }
    if ($spec) {
        if ($spec.ExpectedLen -and $trimmed.Length -ne $spec.ExpectedLen) {
            return @{
                Valid = $false
                Error = "Invalid $Source API key. $Source API keys must be $($spec.ExpectedLen) characters."
            }
        }
        if ($spec.CharPattern -and -not ($trimmed -match $spec.CharPattern)) {
            return @{
                Valid = $false
                Error = "Invalid $Source API key format."
            }
        }
    }

    return @{ Valid = $true; Error = $null }
}

$script:ApiKeys = @{}
foreach ($sName in $script:ApiKeySources.Keys) {
    $prop = $script:ApiKeySources[$sName].SettingsProp
    $storedVal = if ($script:appSettings -and $script:appSettings.$prop) { [string]$script:appSettings.$prop } else { '' }
    if ($storedVal) {
        $valResult = Test-SourceApiKey -Source $sName -Key $storedVal
        if ($valResult.Valid) {
            $script:ApiKeys[$sName] = $storedVal
        }
        else {
            $script:ApiKeys[$sName] = ''
            if ($script:appSettings) { $script:appSettings.$prop = '' }
        }
    }
    else {
        $script:ApiKeys[$sName] = ''
    }
}

function Get-SourceApiKey([string]$Source) {
    if ($script:ApiKeys.ContainsKey($Source)) {
        return [string]$script:ApiKeys[$Source]
    }
    return ''
}

function Set-SourceApiKey([string]$Source, [string]$Key) {
    $script:ApiKeys[$Source] = [string]$Key
    $prop = if ($script:ApiKeySources.ContainsKey($Source)) { $script:ApiKeySources[$Source].SettingsProp } else { "${Source}ApiKey" }
    if ($script:appSettings) {
        $script:appSettings.$prop = [string]$Key
    }
    Save-Settings
}

function Get-MaskedApiKey([string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }
    $trimmed = $Key.Trim()
    if ($trimmed.Length -le 5) { return $trimmed }
    $visible = $trimmed.Substring(0, 5)
    $maskCount = [Math]::Min(20, [Math]::Max(10, $trimmed.Length - 5))
    return $visible + ('*' * $maskCount)
}

function Save-Settings {
    try {
        $existing = Load-Settings
        $settingsObj = @{
            Region               = if ($RegionBox.SelectedItem) { $RegionBox.SelectedItem.Tag } else { "auto" }
            Resolution           = if ($ResolutionBox.SelectedItem) { $ResolutionBox.SelectedItem } else { "4K" }
            Target               = if ($TargetBox.SelectedItem) { $TargetBox.SelectedItem } else { "Both" }
            Style                = if ($StyleBox.SelectedItem) { $StyleBox.SelectedItem } else { "Fit" }
            SaveFolder           = $script:DownloadFolderPath
            AutoDesktopSource    = if ($AutoDesktopSourceBox -and $AutoDesktopSourceBox.SelectedItem) { [string]$AutoDesktopSourceBox.SelectedItem } else { 'Bing' }
            AutoLockScreenSource = if ($AutoLockScreenSourceBox -and $AutoLockScreenSourceBox.SelectedItem) { [string]$AutoLockScreenSourceBox.SelectedItem } else { 'Bing' }
            AutoSchedule         = if ($AutoScheduleBox -and $AutoScheduleBox.SelectedItem) { [string]$AutoScheduleBox.SelectedItem.Tag } else { 'Daily' }
            SpotlightEnabled     = [bool]$script:SpotlightEnabled
            WallhavenApiKey      = (Get-SourceApiKey 'Wallhaven')
            PexelsApiKey         = (Get-SourceApiKey 'Pexels')
            LocalFolderPath      = if ($script:localFolderPath) { $script:localFolderPath } elseif ($existing -and $existing.LocalFolderPath) { [string]$existing.LocalFolderPath } else { '' }
            LastAutoAppliedDate  = if ($existing -and $existing.LastAutoAppliedDate) { [string]$existing.LastAutoAppliedDate } else { '' }
            LastAutoDesktopSource= if ($existing -and $existing.LastAutoDesktopSource) { [string]$existing.LastAutoDesktopSource } else { '' }
            LastAutoLockSource   = if ($existing -and $existing.LastAutoLockSource) { [string]$existing.LastAutoLockSource } else { '' }
        }
        $dir = Split-Path -Parent $script:settingsPath
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $settingsObj | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $script:settingsPath
    }
    catch {}
}

# WPF's own ToolTipService.InitialShowDelay/BetweenShowDelay machinery has
# a known "recently shown, skip the delay" fast-path that isn't scoped to
# just the element that was hovered - it's effectively global, and it
# turns out toggling ToolTipService.IsEnabled around it isn't reliable
# either: flipping it back on while the mouse is already sitting still on
# an element doesn't retroactively make WPF start showing a tooltip
# (its hover-detection kicks off from the MouseEnter event itself, which
# has already passed by the time IsEnabled flips), so that approach could
# make tooltips silently stop appearing altogether. Rather than continue
# fighting that internal state machine, this takes tooltips over
# entirely: WPF's automatic display is disabled once per element, and a
# dedicated DispatcherTimer drives the open/close ourselves - so every
# hover, first one or the hundredth in a row, behaves identically:
# exactly 600ms after entering before it appears, gone the instant you
# leave. No shared state between elements, nothing to fight.
function Enable-StrictToolTipDelay($targetElement) {
    if (-not $targetElement) { return }

    # A plain string ToolTip (set via `$x.ToolTip = "..."` or a ToolTip=
    # XAML attribute) only gets wrapped into a real ToolTip object by
    # WPF's own automatic display machinery, which we're bypassing here -
    # so wrap it ourselves up front to guarantee .IsOpen works below.
    if ($targetElement.ToolTip -and -not ($targetElement.ToolTip -is [System.Windows.Controls.ToolTip])) {
        $wrapped = New-Object System.Windows.Controls.ToolTip
        $wrapped.Content = $targetElement.ToolTip
        $targetElement.ToolTip = $wrapped
    }

    # Normally WPF's own ToolTipService sets this internally when it opens
    # a tooltip automatically, which is also what lets the tooltip resolve
    # the app's implicit dark ToolTip style from Window.Resources. Since
    # we're opening it manually (IsOpen = $true below, not through
    # ToolTipService), that link never gets made unless we set it
    # ourselves - without it the tooltip renders with plain default WPF
    # chrome (white background, square corners) instead of the app's
    # style.
    if ($targetElement.ToolTip -is [System.Windows.Controls.ToolTip]) {
        $targetElement.ToolTip.PlacementTarget = $targetElement
    }

    [System.Windows.Controls.ToolTipService]::SetIsEnabled($targetElement, $false)

    $showTimer = New-Object System.Windows.Threading.DispatcherTimer
    $showTimer.Interval = [TimeSpan]::FromMilliseconds(600)
    $showTimer.Tag = $targetElement
    $showTimer.Add_Tick({
            param($tickSender, $tickArgs)
            $tickSender.Stop()
            $el = $tickSender.Tag
            if ($el.ToolTip -is [System.Windows.Controls.ToolTip]) {
                $el.ToolTip.IsOpen = $true
            }
        })

    $targetElement.Add_MouseEnter({
            $showTimer.Stop()
            $showTimer.Start()
        }.GetNewClosure())

    $targetElement.Add_MouseLeave({
            param($leaveSender, $leaveArgs)
            $showTimer.Stop()
            if ($leaveSender.ToolTip -is [System.Windows.Controls.ToolTip]) {
                $leaveSender.ToolTip.IsOpen = $false
            }
        }.GetNewClosure())
}

$RegionBox = $window.FindName('RegionBox')
$ApiKeyGrid = $window.FindName('ApiKeyGrid')
$ApiKeyBox = $window.FindName('ApiKeyBox')
$ApiKeyPlaceholder = $window.FindName('ApiKeyPlaceholder')
$ClearApiKeyBtn = $window.FindName('ClearApiKeyBtn')
Enable-StrictToolTipDelay $ClearApiKeyBtn
$ResolutionBox = $window.FindName('ResolutionBox')
$TargetBox = $window.FindName('TargetBox')
$StyleBox = $window.FindName('StyleBox')
$FolderBox = $window.FindName('FolderBox')
$RefreshBtn = $window.FindName('RefreshBtn')
Enable-StrictToolTipDelay $RefreshBtn
$RefreshIcon = $window.FindName('RefreshIcon')
$GalleryPanel = $window.FindName('GalleryPanel')
$GalleryScrollViewer = $window.FindName('GalleryScrollViewer')
if ($GalleryScrollViewer -and ('AutoScapeSmoothScroll' -as [type])) {
    [AutoScapeSmoothScroll]::Attach($GalleryScrollViewer)
}
$StatusText = $window.FindName('StatusText')
$InfoBtn = $window.FindName('InfoBtn')
Enable-StrictToolTipDelay $InfoBtn
# CheckUpdateBtn no longer lives in the main toolbar - it now lives inside the
# User Guide modal's footer (see Show-UserGuideDialog) and this variable is
# (re)pointed at that inner button each time the modal is built.
$CheckUpdateBtn = $null
$DownloadBtn = $window.FindName('DownloadBtn')
$UpdateBtn = $window.FindName('UpdateBtn')

# --- Source toggle pill -----------------
$SourceBingBtn = $window.FindName('SourceBingBtn')
$SourceSpotlightBtn = $window.FindName('SourceSpotlightBtn')
$SourceWallhavenBtn = $window.FindName('SourceWallhavenBtn')
$SourcePexelsBtn = $window.FindName('SourcePexelsBtn')
$SourceLocalBtn = $window.FindName('SourceLocalBtn')
$SourceBingIndicator = $window.FindName('SourceBingIndicator')
$SourceSpotlightIndicator = $window.FindName('SourceSpotlightIndicator')
$SourceWallhavenIndicator = $window.FindName('SourceWallhavenIndicator')
$SourcePexelsIndicator = $window.FindName('SourcePexelsIndicator')
$SourceLocalIndicator = $window.FindName('SourceLocalIndicator')
$SourceBingLabel = $window.FindName('SourceBingLabel')
$SourceSpotlightLabel = $window.FindName('SourceSpotlightLabel')
$SourceWallhavenLabel = $window.FindName('SourceWallhavenLabel')
$SourcePexelsLabel = $window.FindName('SourcePexelsLabel')
$SourceLocalLabel = $window.FindName('SourceLocalLabel')
$LocalFolderBorder = $window.FindName('LocalFolderBorder')
$LocalFolderBtn = $window.FindName('LocalFolderBtn')
$LocalFolderLabel = $window.FindName('LocalFolderLabel')
$LocalEmptyStatePanel = $window.FindName('LocalEmptyStatePanel')
$EmptyStateSelectFolderBtn = $window.FindName('EmptyStateSelectFolderBtn')
$AppSubtitleText = $window.FindName('AppSubtitleText')

$script:currentSource = 'Bing'

function Update-LocalFolderVisual {
    if (-not $LocalFolderLabel) { return }
    if ($script:localFolderPath -and (Test-Path -LiteralPath $script:localFolderPath)) {
        $folderLeaf = Split-Path -Leaf $script:localFolderPath
        if ([string]::IsNullOrWhiteSpace($folderLeaf)) { $folderLeaf = $script:localFolderPath }
        $LocalFolderLabel.Text = $folderLeaf
        if ($LocalFolderBtn) {
            $LocalFolderBtn.ToolTip = "Folder: $($script:localFolderPath)`nClick to change folder"
        }
    }
    else {
        $LocalFolderLabel.Text = "Select Folder..."
        if ($LocalFolderBtn) {
            $LocalFolderBtn.ToolTip = "Click to choose a local wallpaper folder"
        }
    }
}

function Select-LocalWallpaperFolder {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select a folder containing wallpaper images"
    $dialog.ShowNewFolderButton = $false
    $dialog.AutoUpgradeEnabled = $true
    if ($script:localFolderPath -and (Test-Path -LiteralPath $script:localFolderPath)) {
        $dialog.SelectedPath = $script:localFolderPath
    }

    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    $wrapper = New-Object -TypeName System.Windows.Forms.NativeWindow
    $wrapper.AssignHandle($hwnd)

    $result = $dialog.ShowDialog($wrapper)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and -not [string]::IsNullOrWhiteSpace($dialog.SelectedPath)) {
        $script:localFolderPath = $dialog.SelectedPath
        Save-Settings
        Update-LocalFolderVisual
        Load-Gallery
    }
}

function Update-GlobalApiKeyBoxState([string]$Key) {
    if (-not $ApiKeyBox) { return }
    if ([string]::IsNullOrWhiteSpace($Key)) {
        $ApiKeyBox.IsReadOnly = $false
        $ApiKeyBox.Cursor = [System.Windows.Input.Cursors]::IBeam
        $ApiKeyBox.Text = ''
        if ($ApiKeyPlaceholder) { $ApiKeyPlaceholder.Visibility = [System.Windows.Visibility]::Visible }
        if ($ClearApiKeyBtn) { $ClearApiKeyBtn.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    else {
        $ApiKeyBox.IsReadOnly = $true
        $ApiKeyBox.Cursor = [System.Windows.Input.Cursors]::Arrow
        $ApiKeyBox.Text = Get-MaskedApiKey $Key
        if ($ApiKeyPlaceholder) { $ApiKeyPlaceholder.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($ClearApiKeyBtn) { $ClearApiKeyBtn.Visibility = [System.Windows.Visibility]::Visible }
    }
}

function Update-SourceToggleVisual {
    $activeColor = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(255, 255, 255))
    $inactiveColor = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(158, 158, 158))
    $isSpotlight = ($script:currentSource -eq 'Spotlight')
    $isWallhaven = ($script:currentSource -eq 'Wallhaven')
    $isPexels = ($script:currentSource -eq 'Pexels')
    $isLocal = ($script:currentSource -eq 'Local')

    if ($SourceBingLabel) { $SourceBingLabel.Foreground = if ($script:currentSource -eq 'Bing') { $activeColor } else { $inactiveColor } }
    if ($SourceSpotlightLabel) { $SourceSpotlightLabel.Foreground = if ($isSpotlight) { $activeColor } else { $inactiveColor } }
    if ($SourceWallhavenLabel) { $SourceWallhavenLabel.Foreground = if ($isWallhaven) { $activeColor } else { $inactiveColor } }
    if ($SourcePexelsLabel) { $SourcePexelsLabel.Foreground = if ($isPexels) { $activeColor } else { $inactiveColor } }
    if ($SourceLocalLabel) { $SourceLocalLabel.Foreground = if ($isLocal) { $activeColor } else { $inactiveColor } }

    if ($SourceBingIndicator) { $SourceBingIndicator.Opacity = if ($script:currentSource -eq 'Bing') { 1 } else { 0 } }
    if ($SourceSpotlightIndicator) { $SourceSpotlightIndicator.Opacity = if ($isSpotlight) { 1 } else { 0 } }
    if ($SourceWallhavenIndicator) { $SourceWallhavenIndicator.Opacity = if ($isWallhaven) { 1 } else { 0 } }
    if ($SourcePexelsIndicator) { $SourcePexelsIndicator.Opacity = if ($isPexels) { 1 } else { 0 } }
    if ($SourceLocalIndicator) { $SourceLocalIndicator.Opacity = if ($isLocal) { 1 } else { 0 } }

    if ($AppSubtitleText) {
        $AppSubtitleText.Text = if ($isSpotlight) { 'Windows Spotlight, curated daily' } elseif ($isWallhaven) { 'Wallhaven #nature wallpapers' } elseif ($isPexels) { 'Pexels 4K nature photography' } elseif ($isLocal) { 'Your local wallpaper collection' } else { 'Bing wallpapers, delivered daily' }
    }

    if ($isLocal) {
        if ($RegionBox) { $RegionBox.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($ApiKeyGrid) { $ApiKeyGrid.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($LocalFolderBorder) { $LocalFolderBorder.Visibility = [System.Windows.Visibility]::Visible }
        if ($LabelRegion) { $LabelRegion.Text = 'Wallpaper Folder' }
        Update-LocalFolderVisual
    }
    else {
        if ($LocalFolderBorder) { $LocalFolderBorder.Visibility = [System.Windows.Visibility]::Collapsed }

        # Universal handling for any current or future API-key-based source
        $isApiKeySource = $script:ApiKeySources.ContainsKey($script:currentSource)
        if ($isApiKeySource) {
            $spec = $script:ApiKeySources[$script:currentSource]
            if ($RegionBox) { $RegionBox.Visibility = [System.Windows.Visibility]::Collapsed }
            if ($ApiKeyGrid) { $ApiKeyGrid.Visibility = [System.Windows.Visibility]::Visible }
            if ($LabelRegion) { $LabelRegion.Text = $spec.Label }
            if ($ApiKeyBox) { $ApiKeyBox.ToolTip = $spec.Tooltip }
            if ($ApiKeyPlaceholder) { $ApiKeyPlaceholder.Text = $spec.Placeholder }

            $currentKey = Get-SourceApiKey $script:currentSource
            Update-GlobalApiKeyBoxState -Key $currentKey
        }
        else {
            if ($RegionBox) { $RegionBox.Visibility = [System.Windows.Visibility]::Visible }
            if ($ApiKeyGrid) { $ApiKeyGrid.Visibility = [System.Windows.Visibility]::Collapsed }
            if ($LabelRegion) { $LabelRegion.Text = 'Region' }
        }
    }
}
Update-SourceToggleVisual

# Clear button handler: wipes the key for the active source in memory & settings.json, unlocks box, and prompts user
if ($ClearApiKeyBtn) {
    $ClearApiKeyBtn.Add_Click({
            $src = $script:currentSource
            if (-not $script:ApiKeySources.ContainsKey($src)) { return }

            Set-SourceApiKey -Source $src -Key ''
            Update-GlobalApiKeyBoxState -Key ''

            if ($ApiKeyBox) {
                $ApiKeyBox.Focus()
            }

            $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $StatusText.Opacity = 1
            $StatusText.Foreground = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(158, 158, 158)))
            $StatusText.Text = "$src API key cleared. Paste your key and press Enter."
        })
}

# Universal API key box event wiring
if ($ApiKeyBox) {
    $ApiKeyBox.Add_TextChanged({
            if ($ApiKeyBox.IsReadOnly) { return }
            $txt = $ApiKeyBox.Text.Trim()
            if ($ApiKeyPlaceholder) {
                $ApiKeyPlaceholder.Visibility = if ([string]::IsNullOrEmpty($txt)) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
            }
        })

    $ApiKeyBox.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
                $e.Handled = $true
                $src = $script:currentSource
                if (-not $script:ApiKeySources.ContainsKey($src)) { return }

                if ($ApiKeyBox.IsReadOnly) {
                    # Already locked with valid key: Enter key simply refreshes gallery!
                    Load-Gallery
                    return
                }

                $rawInput = $ApiKeyBox.Text.Trim()
                if ([string]::IsNullOrWhiteSpace($rawInput) -and $script:ApiKeySources[$src].IsOptional) {
                    Set-SourceApiKey -Source $src -Key ''
                    Update-GlobalApiKeyBoxState -Key ''
                    if ($window) { $window.Focus() }
                    Load-Gallery
                    return
                }

                $validation = Test-SourceApiKey -Source $src -Key $rawInput

                if (-not $validation.Valid) {
                    $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                    $StatusText.Opacity = 1
                    $StatusText.Foreground = $statusErrorBrush
                    $StatusText.Text = $validation.Error
                    $ApiKeyBox.SelectAll()
                    return
                }

                # Valid key! Save to memory & settings.json, lock, mask, and refresh gallery!
                Set-SourceApiKey -Source $src -Key $rawInput
                Update-GlobalApiKeyBoxState -Key $rawInput
                if ($window) { $window.Focus() }

                Load-Gallery
            }
        })
}

if ($SourceBingBtn) {
    $SourceBingBtn.Add_Click({
            if ($script:currentSource -eq 'Bing') { return }
            $script:currentSource = 'Bing'
            Update-SourceToggleVisual
            Load-Gallery
        })
}
if ($SourceSpotlightBtn) {
    $SourceSpotlightBtn.Add_Click({
            if ($script:currentSource -eq 'Spotlight') { return }
            $script:currentSource = 'Spotlight'
            Update-SourceToggleVisual
            Load-Gallery
        })
}
if ($SourceWallhavenBtn) {
    $SourceWallhavenBtn.Add_Click({
            if ($script:currentSource -eq 'Wallhaven') { return }
            $script:currentSource = 'Wallhaven'
            Update-SourceToggleVisual
            Load-Gallery
        })
}
if ($SourcePexelsBtn) {
    $SourcePexelsBtn.Add_Click({
            if ($script:currentSource -eq 'Pexels') { return }
            $script:currentSource = 'Pexels'
            Update-SourceToggleVisual
            Load-Gallery
        })
}
if ($SourceLocalBtn) {
    $SourceLocalBtn.Add_Click({
            if ($script:currentSource -eq 'Local') { return }
            $script:currentSource = 'Local'
            Update-SourceToggleVisual
            Load-Gallery
        })
}
if ($LocalFolderBtn) {
    $LocalFolderBtn.Add_Click({
            Select-LocalWallpaperFolder
        })
}
if ($EmptyStateSelectFolderBtn) {
    $EmptyStateSelectFolderBtn.Add_Click({
            Select-LocalWallpaperFolder
        })
}
# ------------------------------------------------------------------------

$SpotlightPill = $window.FindName('SpotlightPill')
$SpotlightThumb = $window.FindName('SpotlightThumb')
$SpotlightThumbTranslate = $null
$SpotlightThumbScale = $null
if ($SpotlightThumb -and $SpotlightThumb.RenderTransform) {
    try {
        $SpotlightThumbTranslate = $SpotlightThumb.RenderTransform
        $SpotlightThumbScale = New-Object System.Windows.Media.ScaleTransform(1.0, 1.0)
        $thumbTransformGroup = New-Object System.Windows.Media.TransformGroup
        [void]$thumbTransformGroup.Children.Add($SpotlightThumbScale)
        [void]$thumbTransformGroup.Children.Add($SpotlightThumbTranslate)
        $SpotlightThumb.RenderTransform = $thumbTransformGroup
        $SpotlightThumb.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
    }
    catch {
        # If anything here fails, fall back to the plain translate transform
        # so the toggle still slides even without the squish flourish.
        $SpotlightThumbScale = $null
    }
}
$SpotlightSetBtn = $window.FindName('SpotlightSetBtn')
Enable-StrictToolTipDelay $SpotlightSetBtn
$SpotlightSetBtnGlow = if ($SpotlightSetBtn) { $SpotlightSetBtn.Effect } else { $null }
$SpotlightOptionsPopup = $window.FindName('SpotlightOptionsPopup')
$SpotlightPopupCard = $window.FindName('SpotlightPopupCard')
$SpotlightPopupTransform = $window.FindName('SpotlightPopupTransform')
$AutoDesktopSourceBox = $window.FindName('AutoDesktopSourceBox')
$AutoLockScreenSourceBox = $window.FindName('AutoLockScreenSourceBox')
$AutoUnifiedButton = $window.FindName('AutoUnifiedButton')
$AutoScheduleBox = $window.FindName('AutoScheduleBox')

# Compact-mode toolbar elements (see Update-ToolbarCompactState below)
$ToolbarWrap = $window.FindName('ToolbarWrap')
$ColRegion = $window.FindName('ColRegion')
$ColRefresh = $window.FindName('ColRefresh')
$ColResolution = $window.FindName('ColResolution')
$ColApplyTo = $window.FindName('ColApplyTo')
$ColStyle = $window.FindName('ColStyle')
$ColDownloadTo = $window.FindName('ColDownloadTo')
$ColAuto = $window.FindName('ColAuto')
$AutoPillRow = $window.FindName('AutoPillRow')
$LabelRegion = $window.FindName('LabelRegion')
$LabelResolution = $window.FindName('LabelResolution')
$LabelApplyTo = $window.FindName('LabelApplyTo')
$LabelStyle = $window.FindName('LabelStyle')
$LabelDownloadTo = $window.FindName('LabelDownloadTo')
$LabelAuto = $window.FindName('LabelAuto')
$LabelRefresh = $window.FindName('LabelRefresh')
$HeaderGrid = $window.FindName('HeaderGrid')
$MainContent = $window.FindName('MainContent')
$SourceTogglePill = $window.FindName('SourceTogglePill')

$ModalDimOverlay = $window.FindName('ModalDimOverlay')
$ModalHost = $window.FindName('ModalHost')
$script:activeModalControl = $null
$script:activeModalKind = $null
$script:activeModalClosing = $false
$script:activeModalCloseCallback = $null

# Second, higher layer used exclusively by Show-ModernDialog so it can stack
# above an already-open User Guide modal (see Open-DialogModal/Close-DialogModal).
$DialogDimOverlay = $window.FindName('DialogDimOverlay')
$DialogModalHost = $window.FindName('DialogModalHost')
$script:activeDialogModalControl = $null
$script:activeDialogModalClosing = $false
$script:activeDialogModalCloseCallback = $null

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
        [ValidateSet('Guide', 'Dialog', 'Info')][string]$Kind = 'Dialog',
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

function Open-DialogModal {
    param(
        [Parameter(Mandatory = $true)]$Control,
        [scriptblock]$CloseCallback = $null
    )

    if (-not $DialogModalHost) { throw 'DialogModalHost is unavailable.' }
    if (-not $DialogDimOverlay) { throw 'DialogDimOverlay is unavailable.' }

    if ($script:activeDialogModalControl) { Close-DialogModal -Immediate $true }

    $script:activeDialogModalControl = $Control
    $script:activeDialogModalClosing = $false
    $script:activeDialogModalCloseCallback = $CloseCallback

    try { $Control.CacheMode = $null } catch {}
    try { $Control.RenderTransform = $null } catch {}
    try { $Control.Opacity = 0.0 } catch {}

    $Control.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $Control.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $DialogModalHost.Children.Clear()
    [void]$DialogModalHost.Children.Add($Control)
    $DialogModalHost.Visibility = [System.Windows.Visibility]::Visible
    $DialogModalHost.IsHitTestVisible = $true

    $DialogModalHost.UpdateLayout()

    $DialogDimOverlay.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $null)
    $DialogDimOverlay.Opacity = 0.0
    $DialogDimOverlay.Visibility = [System.Windows.Visibility]::Visible
    $DialogDimOverlay.IsHitTestVisible = $true

    $duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(190))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut

    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, $duration)
    $fade.EasingFunction = $ease
    $fade.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
    $Control.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)

    # This layer's own dim is intentionally light - it stacks on top of the
    # Guide modal's existing 0.22 dim (when open), and the two combine visually
    # (1-(1-0.22)*(1-0.08) ~= 0.28 total), so this alone should stay subtle.
    $dimAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 0.6, $duration)
    $dimAnim.EasingFunction = $ease
    $dimAnim.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
    $DialogDimOverlay.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $dimAnim)
}

function Close-DialogModal {
    param([bool]$Immediate = $false)

    if ($script:activeDialogModalClosing -and -not $Immediate) { return }

    $control = $script:activeDialogModalControl
    if (-not $control) { return }

    if ($Immediate) {
        $callback = $script:activeDialogModalCloseCallback
        $script:activeDialogModalControl = $null
        $script:activeDialogModalCloseCallback = $null
        $script:activeDialogModalClosing = $false

        try { $control.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null) } catch {}
        $DialogModalHost.Children.Clear()
        $DialogModalHost.Visibility = [System.Windows.Visibility]::Collapsed
        $DialogModalHost.IsHitTestVisible = $false

        $DialogDimOverlay.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $null)
        $DialogDimOverlay.Opacity = 0.0
        $DialogDimOverlay.Visibility = [System.Windows.Visibility]::Collapsed
        $DialogDimOverlay.IsHitTestVisible = $false

        if ($callback) { & $callback }
        return
    }

    $script:activeDialogModalClosing = $true
    $DialogModalHost.IsHitTestVisible = $false

    try { $control.CacheMode = $null } catch {}
    try { $control.RenderTransform = $null } catch {}

    $duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(150))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseIn

    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation([double]$control.Opacity, 0.0, $duration)
    $fade.EasingFunction = $ease
    $fade.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
    $control.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)

    $dimAnim = New-Object System.Windows.Media.Animation.DoubleAnimation([double]$DialogDimOverlay.Opacity, 0.0, $duration)
    $dimAnim.EasingFunction = $ease
    $dimAnim.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
    $DialogDimOverlay.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $dimAnim)

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(160)
    $timer.Add_Tick({
            param($sender, $e)
            $sender.Stop()

            $callback = $script:activeDialogModalCloseCallback
            $script:activeDialogModalControl = $null
            $script:activeDialogModalCloseCallback = $null
            $script:activeDialogModalClosing = $false

            try { $control.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null) } catch {}

            $DialogModalHost.Children.Clear()
            $DialogModalHost.Visibility = [System.Windows.Visibility]::Collapsed
            $DialogModalHost.IsHitTestVisible = $false

            $DialogDimOverlay.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $null)
            $DialogDimOverlay.Opacity = 0.0
            $DialogDimOverlay.Visibility = [System.Windows.Visibility]::Collapsed
            $DialogDimOverlay.IsHitTestVisible = $false

            if ($callback) { & $callback }
        })
    $timer.Start()
}

if ($DialogModalHost) {
    $DialogModalHost.Add_PreviewMouseLeftButtonDown({
            param($s, $e)
            if (-not $script:activeDialogModalControl -or $script:activeDialogModalClosing) { return }
            $source = $e.OriginalSource -as [System.Windows.DependencyObject]
            $inside = $false
            try {
                if ($source) { $inside = $source.IsDescendantOf($script:activeDialogModalControl) }
            }
            catch { $inside = $false }
            if (-not $inside) {
                Close-DialogModal
                $e.Handled = $true
            }
        })
}

function Start-RefreshAnimation {
    if (-not $RefreshIcon) { return }

    $src = $script:currentSource
    if ($script:ApiKeySources.ContainsKey($src) -and $ApiKeyBox -and -not $ApiKeyBox.IsReadOnly) {
        $raw = $ApiKeyBox.Text.Trim()
        $val = Test-SourceApiKey -Source $src -Key $raw
        if (-not $val.Valid) {
            $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $StatusText.Opacity = 1
            $StatusText.Foreground = $statusErrorBrush
            $StatusText.Text = $val.Error
            $ApiKeyBox.SelectAll()
            return
        }
        Set-SourceApiKey -Source $src -Key $raw
        Update-GlobalApiKeyBoxState -Key $raw
    }

    $rotation = [System.Windows.Media.RotateTransform]$RefreshIcon.RenderTransform
    
    # 0 -> accelerate -> fast rotation -> slow down -> 366° -> gently settle -> 360°
    $spin = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $spin.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(700))
    $spin.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($spin, 60)

    # Keyframe 1: 0° -> accelerate -> fast rotation -> slow down -> 366° (EaseInOut)
    $kf1 = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame
    $kf1.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(520))
    $kf1.Value = 366
    $ease1 = New-Object System.Windows.Media.Animation.CubicEase
    $ease1.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
    $kf1.EasingFunction = $ease1
    [void]$spin.KeyFrames.Add($kf1)

    # Keyframe 2: 366° -> gently settle -> 360° (EaseOut)
    $kf2 = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame
    $kf2.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(700))
    $kf2.Value = 360
    $ease2 = New-Object System.Windows.Media.Animation.CubicEase
    $ease2.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $kf2.EasingFunction = $ease2
    [void]$spin.KeyFrames.Add($kf2)

    $rotation.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $spin, [System.Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace)

    if ($script:refreshDelayTimer) {
        $script:refreshDelayTimer.Stop()
        $script:refreshDelayTimer = $null
    }

    $script:refreshDelayTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:refreshDelayTimer.Interval = [TimeSpan]::FromMilliseconds(700)
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
    Set-DownloadFolderDisplay -Path $script:appSettings.SaveFolder
}
else {
    Set-DownloadFolderDisplay -Path (Get-DownloadFolder)
}

$saveHandler = { Save-Settings }
$RegionBox.Add_SelectionChanged($saveHandler)
if ($ApiKeyBox) { $ApiKeyBox.Add_LostFocus($saveHandler) }
$ResolutionBox.Add_SelectionChanged($saveHandler)
$TargetBox.Add_SelectionChanged($saveHandler)
$StyleBox.Add_SelectionChanged($saveHandler)

# Toolbar dropdowns (Region/Resolution/Apply To/Style) should behave as a
# mutually-exclusive set: clicking one while another is open must close the
# other AND open the clicked one on that SAME click, not require a second
# click. We hook each combo's own PreviewMouseLeftButtonDown (tunnel phase,
# fires before the ToggleButton's ClickMode="Press" logic runs) and close
# any other open dropdown there. This only fires when the click lands on the
# ComboBox control itself (its closed toggle), never for clicks inside an
# open popup's item list - popups render in their own top-level window, so
# those clicks never route through this handler - meaning selection and
# click-away-to-close behavior are untouched.
$script:toolbarDropdowns = @($RegionBox, $ResolutionBox, $TargetBox, $StyleBox)
foreach ($combo in $script:toolbarDropdowns) {
    if ($combo) {
        $combo.Add_PreviewMouseLeftButtonDown({
                param($evtSender, $e)
                foreach ($other in $script:toolbarDropdowns) {
                    if ($other -and $other -ne $evtSender -and $other.IsDropDownOpen) {
                        $other.IsDropDownOpen = $false
                    }
                }
            })
    }
}

$FolderBox.Add_PreviewMouseLeftButtonDown({
        $picked = $null
        $modernFailed = $false

        # EnableDarkDialogs/GetForegroundWindow/PickFolder below all need
        # BingWallpaperNativeExtra. If it's still compiling in the
        # background (e.g. this is clicked right after launch),
        # EnableDarkDialogs would throw before ShowDialog ever runs, and
        # the legacy PickFolder fallback needs the exact same type - so
        # without waiting here the whole click can silently do nothing.
        [void](Wait-NativeExtraCompile)

        try {
            $dialog = New-Object Microsoft.Win32.OpenFolderDialog
            $dialog.Title = 'Select Download Folder'
            if (Test-Path -LiteralPath $script:DownloadFolderPath) {
                $dialog.InitialDirectory = $script:DownloadFolderPath
            }

            [BingWallpaperNativeExtra]::EnableDarkDialogs()

            $darkTimer = New-Object System.Windows.Threading.DispatcherTimer
            $darkTimer.Interval = [TimeSpan]::FromMilliseconds(30)
            $darkTimer.Add_Tick({
                    $hwnd = [BingWallpaperNativeExtra]::GetForegroundWindow()
                    if ($hwnd -ne [IntPtr]::Zero -and [BingWallpaperNativeExtra]::IsDialogWindow($hwnd)) {
                        [BingWallpaperNativeExtra]::ForceDarkDialog($hwnd)
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
            $legacyRes = $null
            try {
                $legacyRes = [BingWallpaperNativeExtra]::PickFolder($helper.Handle, 'Select Download Folder')
            }
            catch {}
            if (-not [string]::IsNullOrEmpty($legacyRes)) {
                $picked = $legacyRes
            }
        }

        if ($picked) {
            Set-DownloadFolderDisplay -Path $picked
            Save-Settings
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
        # ExtractBrush lives in the deferred/background-compiled extra
        # native type. Cards are built shortly after that compile is
        # kicked off, and the accent brush is only ever computed once per
        # card (cached in card.Resources) - so without waiting here, every
        # card would silently and permanently fall back to the flat gray
        # brush below if the compile hadn't finished yet.
        [void](Wait-NativeExtraCompile)
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
    $fnResizeCode = "function Resize-WallpaperToResolution { " + ${function:Resize-WallpaperToResolution}.ToString() + " }"
    $resolutionSize = Get-ResolutionDimensions -Resolution $Resolution
    $needsLocalResize = ($Image.source -ne 'Bing' -and $Image.source -ne 'Local')

    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param([string]$Uri, [string]$Temp, [string]$Dest, [string]$TargetParam, [string]$StyleParam, [string]$LockScreenFnCode, [string]$ResizeFnCode, [bool]$NeedsLocalResize, [int]$TargetWidth, [int]$TargetHeight)
            try {
                if (Test-Path -LiteralPath $Uri) {
                    Copy-Item -LiteralPath $Uri -Destination $Temp -Force
                }
                else {
                    $wc = New-Object System.Net.WebClient
                    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                    $wc.DownloadFile($Uri, $Temp)
                    $wc.Dispose()
                }
                if (Test-Path -LiteralPath $Temp) {
                    if ($NeedsLocalResize) {
                        Invoke-Expression $ResizeFnCode
                        $resizedTemp = "$Temp.resized.jpg"
                        Resize-WallpaperToResolution -InputPath $Temp -OutputPath $resizedTemp -TargetWidth $TargetWidth -TargetHeight $TargetHeight | Out-Null
                        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
                        Move-Item -LiteralPath $resizedTemp -Destination $Temp -Force
                    }
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
        }).AddArgument($imageUri).AddArgument($tempPath).AddArgument($cachePath).AddArgument($Target).AddArgument($Style).AddArgument($fnLockScreenCode).AddArgument($fnResizeCode).AddArgument($needsLocalResize).AddArgument($resolutionSize.Width).AddArgument($resolutionSize.Height)

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
            try { [BingWallpaperNativeExtra]::FlushMemory() } catch {}
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

$script:pillBgBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(64, 64, 64))
$script:pillBorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(90, 90, 90))
$script:pillThumbBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(200, 200, 200))
if ($SpotlightPill) {
    $SpotlightPill.Background = $script:pillBgBrush
    $SpotlightPill.BorderBrush = $script:pillBorderBrush
}
if ($SpotlightThumb) {
    $SpotlightThumb.Fill = $script:pillThumbBrush
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
    $bgSchedule = if ($AutoScheduleBox -and $AutoScheduleBox.SelectedItem) { [string]$AutoScheduleBox.SelectedItem.Tag } else { 'Daily' }
    $bgScriptPath = $script:SpotlightScriptPath

    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param([bool]$Enable, [string]$Schedule, [string]$ScriptPath)
            try {
                $taskName = 'AutoScapeDailyWallpaper'
                $legacyTaskName = 'BingWallpaperSpotlight'

                if ($Enable) {
                    if (-not ($ScriptPath -and (Test-Path -LiteralPath $ScriptPath))) { return }

                    $conhostExe = Join-Path $env:WINDIR 'System32\conhost.exe'
                    $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    $fullArgs = "--headless `"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -AutoApply"
                    $workingDir = Split-Path -Parent $ScriptPath

                    $action = New-ScheduledTaskAction -Execute $conhostExe -Argument $fullArgs -WorkingDirectory $workingDir
                    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden -ExecutionTimeLimit (New-TimeSpan -Hours 2) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
                    if ($Schedule -eq 'Test1Minute') {
                        # Temporary test mode: repeat once per minute so Auto can be verified quickly.
                        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
                    }
                    else {
                        # Daily starting at local midnight, repeating every hour for 24h.
                        # PC is never woken up from sleep. If asleep at midnight, it catches up when awake,
                        # and retries 5 times with a 1-minute gap if missed or network is unavailable.
                        $trigger = New-ScheduledTaskTrigger -Daily -At '12:00AM'
                        $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 1)).Repetition
                    }

                    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
                    Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false -ErrorAction SilentlyContinue
                }
                else {
                    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                    Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
            catch {}
        }).AddArgument($bgEnable).AddArgument($bgSchedule).AddArgument($bgScriptPath)

    $null = $ps.BeginInvoke()
}

function Set-SpotlightState {
    param(
        [switch]$Enabled,
        [switch]$Animate = $true,
        [switch]$UpdateTask = $true
    )
    $script:SpotlightEnabled = $Enabled

    # Travel distance = track width (44) - thumb diameter (14) - 2x margin (3) = 24px.
    $targetX = if ($Enabled) { 24.0 } else { 0.0 }
    $targetBgColor = if ($Enabled) { [System.Windows.Media.Color]::FromRgb(0, 120, 212) } else { [System.Windows.Media.Color]::FromRgb(64, 64, 64) }
    $targetBorderColor = if ($Enabled) { [System.Windows.Media.Color]::FromRgb(0, 120, 212) } else { [System.Windows.Media.Color]::FromRgb(90, 90, 90) }
    $targetThumbColor = if ($Enabled) { [System.Windows.Media.Color]::FromRgb(255, 255, 255) } else { [System.Windows.Media.Color]::FromRgb(200, 200, 200) }

    if ($SpotlightSetBtn) { $SpotlightSetBtn.IsEnabled = $Enabled }
    if (-not $Enabled -and $SpotlightOptionsPopup) { $SpotlightOptionsPopup.IsOpen = $false }

    if ($Animate) {
        $dur = [TimeSpan]::FromMilliseconds(220)
        $easing = New-Object System.Windows.Media.Animation.CubicEase
        $easing.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut

        $thumbAnim = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList $targetX, (New-Object System.Windows.Duration($dur))
        $thumbAnim.EasingFunction = $easing
        $SpotlightThumbTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $thumbAnim)

        $bgAnim = New-Object System.Windows.Media.Animation.ColorAnimation -ArgumentList $targetBgColor, (New-Object System.Windows.Duration($dur))
        $bgAnim.EasingFunction = $easing
        $script:pillBgBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $bgAnim)

        $borderAnim = New-Object System.Windows.Media.Animation.ColorAnimation -ArgumentList $targetBorderColor, (New-Object System.Windows.Duration($dur))
        $borderAnim.EasingFunction = $easing
        $script:pillBorderBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $borderAnim)

        $thumbColorAnim = New-Object System.Windows.Media.Animation.ColorAnimation -ArgumentList $targetThumbColor, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(180)))
        $script:pillThumbBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $thumbColorAnim)

        if ($SpotlightThumbScale) {
            try {
                $squish = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
                $squishOutEase = New-Object System.Windows.Media.Animation.QuadraticEase
                $squishOutEase.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
                $k0 = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(1.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero))
                $k1 = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.2, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(80)))
                $k1.EasingFunction = $squishOutEase
                $k2 = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan($dur))
                $k2.EasingFunction = $easing
                [void]$squish.KeyFrames.Add($k0)
                [void]$squish.KeyFrames.Add($k1)
                [void]$squish.KeyFrames.Add($k2)
                $SpotlightThumbScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $squish)
            }
            catch {}
        }
    }
    else {
        $SpotlightThumbTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
        $SpotlightThumbTranslate.X = $targetX

        $script:pillBgBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $null)
        $script:pillBgBrush.Color = $targetBgColor

        $script:pillBorderBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $null)
        $script:pillBorderBrush.Color = $targetBorderColor

        $script:pillThumbBrush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $null)
        $script:pillThumbBrush.Color = $targetThumbColor
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
        Width="460" Background="Transparent" Foreground="#F0F0F0" FontFamily="Segoe UI">
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

    <Border Name="DialogRoot" Padding="24" Background="#181818" BorderBrush="#2E2E2E" BorderThickness="1.5" CornerRadius="12" Opacity="0">
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
        Close-DialogModal
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

    Open-DialogModal -Control $dlg -CloseCallback {
        $frame.Continue = $false
        try { [BingWallpaperNativeExtra]::FlushMemory() } catch {}
    }

    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    return $script:dialogChoice
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

# Compact toolbar mode: below ~1260px window width, tighten margins/heights/
# fonts on the toolbar row so it stays on one line on smaller/scaled laptop
# screens (e.g. 13" 1366x768 @125% ~= 1093 logical px). This swaps to real,
# natively-rendered smaller values rather than a LayoutTransform scale, so
# text stays crisp and hit targets remain reasonable. A small gap between
# the enter/exit thresholds (hysteresis) stops it flapping back and forth
# if the window sits right at the boundary while being resized.
$script:ToolbarIsCompact = $false
$script:ToolbarCompactEnterWidth = 1260
$script:ToolbarCompactExitWidth = 1300

function Set-ToolbarCompact {
    param([bool]$Compact)

    $script:ToolbarIsCompact = $Compact
    $tc = New-Object System.Windows.ThicknessConverter
    $colMargin = $tc.ConvertFromString($(if ($Compact) { '0,0,8,10' } else { '0,0,16,16' }))
    $comboHeight = if ($Compact) { 34 } else { 38 }
    $comboFont = if ($Compact) { 12.5 } else { 13.5 }
    $labelFont = if ($Compact) { 12 } else { 13 }
    $iconSize = if ($Compact) { 34 } else { 38 }

    foreach ($col in @($ColRegion, $ColRefresh, $ColResolution, $ColApplyTo, $ColStyle, $ColDownloadTo, $ColAuto)) {
        if ($col) { $col.Margin = $colMargin }
    }

    foreach ($box in @($RegionBox, $ApiKeyBox, $ResolutionBox, $TargetBox, $StyleBox, $FolderBox)) {
        if ($box) { $box.Height = $comboHeight; $box.FontSize = $comboFont }
    }
    if ($ApiKeyPlaceholder) { $ApiKeyPlaceholder.FontSize = $comboFont }
    if ($RefreshBtn) { $RefreshBtn.Width = $iconSize; $RefreshBtn.Height = $iconSize }
    if ($AutoUnifiedButton) { $AutoUnifiedButton.Height = $comboHeight }
    if ($SpotlightSetBtn) {
        $btnSz = if ($Compact) { 26 } else { 30 }
        $SpotlightSetBtn.Width = $btnSz
        $SpotlightSetBtn.Height = $btnSz
    }
    foreach ($label in @($LabelRegion, $LabelRefresh, $LabelResolution, $LabelApplyTo, $LabelStyle, $LabelDownloadTo, $LabelAuto)) {
        if ($label) { $label.FontSize = $labelFont }
    }
    if ($AutoPillRow) { $AutoPillRow.Height = $comboHeight }

    $keyBoxWidth = if ($Compact) { 185 } else { 235 }
    if ($RegionBox) { $RegionBox.Width = $keyBoxWidth }
    if ($ApiKeyBox) { $ApiKeyBox.Width = $keyBoxWidth }
    if ($ResolutionBox) { $ResolutionBox.Width = if ($Compact) { 95 } else { 110 } }
    if ($TargetBox) { $TargetBox.Width = if ($Compact) { 135 } else { 155 } }
    if ($StyleBox) { $StyleBox.Width = if ($Compact) { 105 } else { 125 } }
    if ($ColDownloadTo) { $ColDownloadTo.Width = if ($Compact) { 160 } else { 190 } }

    if ($MainContent) {
        $MainContent.Margin = if ($Compact) { [System.Windows.Thickness]::new(20, 14, 20, 14) } else { [System.Windows.Thickness]::new(24, 20, 24, 16) }
    }

    if ($script:DownloadFolderPath) {
        Set-DownloadFolderDisplay $script:DownloadFolderPath
    }
}

function Update-ToolbarCompactState {
    if (-not $window -or $window.ActualWidth -le 0) { return }
    $width = $window.ActualWidth

    if (-not $script:ToolbarIsCompact -and $width -lt $script:ToolbarCompactEnterWidth) {
        Set-ToolbarCompact -Compact $true
    }
    elseif ($script:ToolbarIsCompact -and $width -gt $script:ToolbarCompactExitWidth) {
        Set-ToolbarCompact -Compact $false
    }

    # Responsive Header: center source tabs pill in header, or wrap under title when window is narrow
    if ($SourceTogglePill) {
        if ($width -lt 860) {
            [System.Windows.Controls.Grid]::SetRow($SourceTogglePill, 1)
            $SourceTogglePill.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
            $SourceTogglePill.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
        }
        else {
            [System.Windows.Controls.Grid]::SetRow($SourceTogglePill, 0)
            $SourceTogglePill.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
            $SourceTogglePill.Margin = [System.Windows.Thickness]::new(0, 0, 0, 0)
        }
    }

    # Responsive Gallery: 3 columns on narrow screens, 4 on wide
    if ($GalleryPanel) {
        $targetCols = if ($width -lt 850) { 3 } else { 4 }
        if ($GalleryPanel.Columns -ne $targetCols) {
            $GalleryPanel.Columns = $targetCols
        }
    }
}


function Render-GalleryGrid {
    param(
        [array]$Images,
        [string]$ThumbCacheDir,
        [switch]$SkipAnimation,
        [switch]$InsertAtTop,
        [switch]$Append
    )

    if (-not $Images -or $Images.Count -eq 0) { return }

    if ($Append) {
        $newLoaded = New-Object System.Collections.ArrayList
        if ($script:loadedImages) {
            foreach ($img in $script:loadedImages) { [void]$newLoaded.Add($img) }
        }
        foreach ($img in $Images) { [void]$newLoaded.Add($img) }
        $script:loadedImages = $newLoaded.ToArray()
        if (-not $script:galleryImageControls) { $script:galleryImageControls = New-Object System.Collections.ArrayList }
        if (-not $script:galleryCards) { $script:galleryCards = New-Object System.Collections.ArrayList }
    }
    elseif (-not $InsertAtTop) {
        $GalleryPanel.Children.Clear()
        $script:selectedCard = $null
        $script:selectedImage = $null
        $script:selection.Card = $null
        $script:selection.Image = $null
        $script:loadedImages = $Images
        $script:galleryImageControls = New-Object System.Collections.ArrayList
        $script:galleryCards = New-Object System.Collections.ArrayList
    }
    else {
        $newLoaded = New-Object System.Collections.ArrayList
        foreach ($img in $Images) { [void]$newLoaded.Add($img) }
        foreach ($img in $script:loadedImages) { [void]$newLoaded.Add($img) }
        $script:loadedImages = $newLoaded.ToArray()
    }

    if (-not $Append -and $script:revealElements) {
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
            [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($card, 600)
            [System.Windows.Controls.ToolTipService]::SetBetweenShowDelay($card, 600)
            Enable-StrictToolTipDelay $card
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
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($imageControl, [System.Windows.Media.BitmapScalingMode]::LowQuality)
        $imgBorder.Child = $imageControl
        $stack.Children.Add($imgBorder)

        # Bing/Spotlight thumbnails are already native 16:9, so their card
        # height is left exactly as before (driven by the image's own
        # aspect). Wallhaven's, Pexels', and Local aren't guaranteed 16:9,
        # which makes cards different heights - so they get an explicit height
        # locked to 16:9 of the card's width, cropped to fit via UniformToFill.
        if ($image.source -eq 'Wallhaven' -or $image.source -eq 'Pexels' -or $image.source -eq 'Local') {
            $imgBorder.Add_SizeChanged({
                    param($evtSender, $e)
                    if ($e.NewSize.Width -gt 0) {
                        $desiredHeight = [Math]::Round($e.NewSize.Width * 9.0 / 16.0, 2)
                        if ([double]::IsNaN($evtSender.Height) -or [Math]::Abs($evtSender.Height - $desiredHeight) -gt 0.5) {
                            $evtSender.Height = $desiredHeight
                        }
                    }
                })
        }

        try {
            $imagePathToLoad = $null
            if ($image.source -eq 'Local' -and (Test-Path -LiteralPath $image.url)) {
                $imagePathToLoad = $image.url
            }
            else {
                $safeName = $image.urlbase -replace '[^a-zA-Z0-9]', ''
                $thumbCachePath = Join-Path $ThumbCacheDir "${safeName}_thumb.jpg"
                if (Test-Path -LiteralPath $thumbCachePath) {
                    $imagePathToLoad = $thumbCachePath
                }
            }

            if ($imagePathToLoad -and (Test-Path -LiteralPath $imagePathToLoad)) {
                $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                $bitmap.BeginInit()
                $bitmap.UriSource = New-Object System.Uri((Resolve-Path -LiteralPath $imagePathToLoad).Path)
                $bitmap.DecodePixelWidth = 360
                $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bitmap.EndInit()
                $bitmap.Freeze()

                $imageControl.Source = $bitmap
                $card.Resources.Add('ImageAccentBrush', (Get-ImageAccentBrush $imagePathToLoad))
                [void]$script:galleryImageControls.Add($imageControl)
            }
            else {
                $card.Resources.Add('ImageAccentBrush', (Get-ImageAccentBrush ''))
            }
        }
        catch {}

        $details = New-Object System.Windows.Controls.StackPanel
        $details.Margin = New-Object System.Windows.Thickness(14, 0, 14, 0)
        $details.VerticalAlignment = 'Center'
        $details.HorizontalAlignment = 'Left'

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
            $date.Text = if ($image.source -eq 'Spotlight') {
                if ($image.copyright) { $image.copyright } else { 'Windows Spotlight' }
            }
            elseif ($image.source -eq 'Wallhaven') { 'Wallhaven' }
            elseif ($image.source -eq 'Local') {
                if ($image.copyright) { $image.copyright } else { 'Local' }
            }
            elseif ($image.source -eq 'Pexels') {
                $authorName = if ($image.photographer) { [string]$image.photographer }
                elseif ($image.copyright -match '^Photo by (.+?) on Pexels') { $Matches[1] }
                elseif ($image.copyright) { [string]$image.copyright }
                else { '' }
                $dimText = if ($image.resX -and $image.resY) { "$($image.resX) x $($image.resY)" } else { '' }
                if ($dimText -and $authorName) {
                    "$dimText  $([char]8226)  $authorName"
                }
                elseif ($dimText) {
                    $dimText
                }
                elseif ($authorName) {
                    $authorName
                }
                else {
                    'Pexels'
                }
            }
            else { 'Bing Wallpaper' }
        }
        $date.Foreground = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(160, 160, 160)))
        $date.FontSize = 13.5
        $date.TextTrimming = 'CharacterEllipsis'
        $details.Children.Add($date)

        # Wallhaven & Local: collapse into compact single line
        # - e.g. "3840 × 2160 • JPEG • 5.2 MB"
        if ($image.source -eq 'Wallhaven' -or $image.source -eq 'Local') {
            $infoParts = @()
            if ($image.resX -and $image.resY) { $infoParts += "$($image.resX) $([char]215) $($image.resY)" }
            if ($image.fileType) {
                $typeShort = ($image.fileType -split '/')[-1].ToUpper()
                if ($typeShort) { $infoParts += $typeShort }
            }
            if ($image.fileSize) {
                $sizeMB = [Math]::Round([double]$image.fileSize / 1MB, 1)
                $infoParts += "$sizeMB MB"
            }
            if ($infoParts.Count -gt 0) {
                $title.Text = $infoParts -join "  $([char]8226)  "
                $title.Margin = New-Object System.Windows.Thickness(0, 0, 0, 0)
                $date.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }

        $card.Resources.Add('TitleText', $title)
        $card.Resources.Add('DateText', $date)

        $detailsContainer = New-Object System.Windows.Controls.Grid
        $detailsContainer.ClipToBounds = $true
        # Fixed height (rather than auto-sizing to content) so every card's
        # info bar is the same size regardless of source - previously
        # Wallhaven's single-line info text made its bar noticeably shorter
        # than the two-line Bing/Spotlight title+date bar.
        $detailsContainer.Height = 64
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

        if ($InsertAtTop) {
            $GalleryPanel.Children.Insert($current - 1, $card)
            $script:galleryCards.Insert($current - 1, $card)
        }
        else {
            $GalleryPanel.Children.Add($card)
            [void]$script:galleryCards.Add($card)
        }
        if (-not $firstCard) { $firstCard = $card }
    
        if ($SkipAnimation) {
            $card.Opacity = 1
        }
        else {
            $staggerDelay = ($current - 1) * 35
            Show-GalleryCard -Card $card -DelayMs $staggerDelay
        }
    }

    if ($firstCard -and $Images.Count -gt 0 -and (-not $script:userHasExplicitlySelectedWallpaper) -and (-not $Append)) {
        Select-Card $firstCard $Images[0]
        $script:userHasExplicitlySelectedWallpaper = $false
    }

    if ($InsertAtTop) {
        $limit = if ($script:currentSource -in @('Wallhaven', 'Pexels')) { 60 } else { 360 }
        while ($GalleryPanel.Children.Count -gt $limit) {
            $lastIdx = $GalleryPanel.Children.Count - 1
            $GalleryPanel.Children.RemoveAt($lastIdx)
            $script:galleryCards.RemoveAt($lastIdx)
            if ($script:galleryImageControls.Count -gt $lastIdx) {
                $script:galleryImageControls.RemoveAt($lastIdx)
            }
        }
    }

    Update-GalleryViewportHeight
    if (-not $Append) {
        if ('AutoScapeSmoothScroll' -as [type]) { [AutoScapeSmoothScroll]::Reset() }
        if ($GalleryScrollViewer) { $GalleryScrollViewer.ScrollToTop() }
    }

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
    if ('AutoScapeSmoothScroll' -as [type]) { [AutoScapeSmoothScroll]::Reset() }

    if ($script:galleryTimer) {
        $script:galleryTimer.Stop()
        $script:galleryTimer = $null
    }
    if ($script:galleryRunspaceContext) {
        $oldCtx = $script:galleryRunspaceContext
        $script:galleryRunspaceContext = $null
        if ($oldCtx.CancelToken) {
            $oldCtx.CancelToken.Cancelled = $true
        }
        [System.Threading.Tasks.Task]::Run([Action] {
                try {
                    $oldCtx.PS.Stop()
                    $oldCtx.PS.Dispose()
                }
                catch {}
            })
    }

    $selectedRegion = Get-SelectedRegionCode
    $fetchSource = $script:currentSource

    if ($fetchSource -eq 'Local') {
        if (-not $script:localFolderPath -or -not (Test-Path -LiteralPath $script:localFolderPath)) {
            if ($LocalEmptyStatePanel) { $LocalEmptyStatePanel.Visibility = [System.Windows.Visibility]::Visible }
            if ($GalleryScrollViewer) { $GalleryScrollViewer.Visibility = [System.Windows.Visibility]::Collapsed }
            $StatusText.Text = "Select a local wallpaper folder to display images."
            $GalleryPanel.Children.Clear()
            return
        }
        else {
            if ($LocalEmptyStatePanel) { $LocalEmptyStatePanel.Visibility = [System.Windows.Visibility]::Collapsed }
            if ($GalleryScrollViewer) { $GalleryScrollViewer.Visibility = [System.Windows.Visibility]::Visible }
        }
    }
    else {
        if ($LocalEmptyStatePanel) { $LocalEmptyStatePanel.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($GalleryScrollViewer) { $GalleryScrollViewer.Visibility = [System.Windows.Visibility]::Visible }
    }

    if ($script:ApiKeySources.ContainsKey($fetchSource)) {
        $sourceKey = Get-SourceApiKey $fetchSource
        $val = Test-SourceApiKey -Source $fetchSource -Key $sourceKey
        if (-not $val.Valid) {
            $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $StatusText.Opacity = 1
            $StatusText.Foreground = $statusErrorBrush
            $StatusText.Text = $val.Error
            $GalleryPanel.Children.Clear()
            return
        }
    }
    $cacheBaseDir = Join-Path $env:LOCALAPPDATA 'BingWallpaper\Cache'
    $thumbCacheDir = Join-Path $cacheBaseDir 'Thumbnails'
    
    if ($fetchSource -eq 'Bing') {
        $sourceThumbDir = Join-Path $thumbCacheDir "Bing_$selectedRegion"
    }
    else {
        $sourceThumbDir = Join-Path $thumbCacheDir $fetchSource
    }

    if (-not (Test-Path -LiteralPath $thumbCacheDir)) {
        try { New-Item -ItemType Directory -Path $thumbCacheDir -Force | Out-Null } catch {}
    }
    if (-not (Test-Path -LiteralPath $sourceThumbDir)) {
        try { New-Item -ItemType Directory -Path $sourceThumbDir -Force | Out-Null } catch {}
    }

    $script:phase1Images = @()
    $script:selectedCard = $null
    $script:selectedImage = $null
    $script:selection.Card = $null
    $script:selection.Image = $null
    $script:loadedImages = @()
    $script:userHasExplicitlySelectedWallpaper = $false
    
    $historyPath = Join-Path $sourceThumbDir '_history.json'
    if ($fetchSource -ne 'Local' -and (Test-Path -LiteralPath $historyPath)) {
        try {
            $rawHistory = Get-Content -LiteralPath $historyPath -Raw -ErrorAction SilentlyContinue
            if ($rawHistory) {
                $cachedArray = @(ConvertFrom-Json -InputObject $rawHistory)
                if ($cachedArray.Count -gt 0) {
                    $limit = if ($fetchSource -in @('Wallhaven', 'Pexels')) { 60 } else { 360 }
                    $validItems = $cachedArray | Select-Object -First $limit
                    foreach ($img in $validItems) {
                        $pAuthor = if ($img.photographer) { [string]$img.photographer }
                        elseif ($img.copyright -match '^Photo by (.+?) on Pexels') { $Matches[1] }
                        elseif ($img.copyright) { [string]$img.copyright }
                        else { '' }
                        $script:phase1Images += [PSCustomObject]@{
                            source       = $fetchSource
                            urlbase      = [string]$img.urlbase
                            url          = [string]$img.url
                            title        = if ($img.title) { [string]$img.title } else { '' }
                            copyright    = if ($img.copyright) { [string]$img.copyright } else { '' }
                            photographer = $pAuthor
                            enddate      = if ($img.enddate) { [string]$img.enddate } else { '' }
                            resX         = if ($img.resX) { [int]$img.resX } else { 0 }
                            resY         = if ($img.resY) { [int]$img.resY } else { 0 }
                            fileSize     = if ($img.fileSize) { [long]$img.fileSize } else { 0 }
                            fileType     = if ($img.fileType) { [string]$img.fileType } else { '' }
                        }
                    }
                }
            }
        }
        catch {}
    }

    $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $StatusText.Foreground = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(136, 136, 136)))

    $script:phase1ThumbDir = $sourceThumbDir
    $script:phase1FetchSource = $fetchSource

    if ($script:phase1Timer) { $script:phase1Timer.Stop() }
    $script:phase1Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:phase1Timer.Interval = [TimeSpan]::FromMilliseconds(50)
    $script:phase1Timer.Add_Tick({
            param($timerSender, $timerArgs)
            $timerSender.Stop()
            if ($script:phase1FetchSource -notin @('Wallhaven', 'Pexels') -and $script:phase1Images.Count -gt 0) {
                $StatusText.Opacity = 0
                Render-GalleryGrid -Images $script:phase1Images -ThumbCacheDir $script:phase1ThumbDir
            }
            else {
                $GalleryPanel.Children.Clear()
                $StatusText.Opacity = 1
                $StatusText.Text = if ($script:phase1FetchSource -eq 'Spotlight') { 'Connecting to Windows Spotlight...' } elseif ($script:phase1FetchSource -eq 'Wallhaven') { 'Connecting to Wallhaven...' } elseif ($script:phase1FetchSource -eq 'Pexels') { 'Connecting to Pexels...' } elseif ($script:phase1FetchSource -eq 'Local') { 'Scanning local wallpaper folder...' } else { 'Connecting to Bing...' }
            }
        })
    $script:phase1Timer.Start()

    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:GalleryFetchWorkerScriptBlock)

    $batchQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    $cancelToken = [hashtable]::Synchronized(@{ Cancelled = $false })

    [void]$ps.AddArgument($selectedRegion)
    [void]$ps.AddArgument($sourceThumbDir)
    [void]$ps.AddArgument($fetchSource)
    [void]$ps.AddArgument(24)
    [void]$ps.AddArgument((Get-SourceApiKey 'Wallhaven'))
    [void]$ps.AddArgument(360)
    [void]$ps.AddArgument((Get-SourceApiKey 'Pexels'))
    [void]$ps.AddArgument($batchQueue)
    [void]$ps.AddArgument($cancelToken)
    [void]$ps.AddArgument($script:localFolderPath)

    $asyncOp = $ps.BeginInvoke()

    $script:galleryRunspaceContext = @{
        PS                   = $ps
        AsyncOp              = $asyncOp
        ThumbCacheDir        = $sourceThumbDir
        BatchQueue           = $batchQueue
        CancelToken          = $cancelToken
        Source               = $fetchSource
        StreamingDone        = $false
        HasRendered          = $false
        NextBatchAllowedTime = [DateTime]::MinValue
    }

    $script:galleryTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:galleryTimer.Interval = [TimeSpan]::FromMilliseconds(30)
    $script:galleryTimer.Add_Tick({
            param($timerSender, $timerArgs)
            if (-not $script:galleryRunspaceContext) {
                $timerSender.Stop()
                return
            }
            $ctx = $script:galleryRunspaceContext

            # Process queued batches from progressive streaming (Wallhaven / Pexels)
            if ($ctx.BatchQueue) {
                while ($ctx.BatchQueue.Count -gt 0) {
                    if ($ctx.HasRendered -and [DateTime]::UtcNow -lt $ctx.NextBatchAllowedTime) {
                        break
                    }

                    $item = $ctx.BatchQueue.Dequeue()
                    if ($item.Type -eq 'Error') {
                        $timerSender.Stop()
                        $script:galleryRunspaceContext = $null
                        $script:galleryTimer = $null
                        try { $ctx.PS.Dispose() } catch {}
                        $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                        $StatusText.Opacity = 1
                        $StatusText.Foreground = $statusErrorBrush
                        if ($ctx.Source -eq 'Local') {
                            $StatusText.Text = if ($item.Error) { $item.Error } else { "No wallpaper images found in this folder." }
                        }
                        else {
                            $StatusText.Text = Get-UserFriendlyNetworkError -Exception (New-Object Exception($item.Error)) -DefaultAction "load wallpapers"
                        }
                        return
                    }
                    elseif ($item.Type -eq 'Batch') {
                        if ($item.IsFirst) {
                            $ctx.HasRendered = $true
                            Render-GalleryGrid -Images $item.Images -ThumbCacheDir $ctx.ThumbCacheDir
                        }
                        else {
                            Render-GalleryGrid -Images $item.Images -ThumbCacheDir $ctx.ThumbCacheDir -Append
                        }
                        # Card 8 delay = 7 * 35 = 245ms + 400ms animation = 645ms.
                        # Wait 680ms so the 8th card has completely settled before appending cards 9-16.
                        $ctx.NextBatchAllowedTime = [DateTime]::UtcNow.AddMilliseconds(680)
                        $curCount = $GalleryPanel.Children.Count
                        $StatusText.Text = "Loading $curCount of $($item.Total) wallpapers from $($item.Source)..."
                        if ($StatusText.Opacity -ne 1) {
                            $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                            $StatusText.Opacity = 1
                        }
                        break
                    }
                    elseif ($item.Type -eq 'Done') {
                        $ctx.StreamingDone = $true
                    }
                }
            }

            if ($ctx.AsyncOp.IsCompleted) {
                if ($ctx.HasRendered) {
                    if ($ctx.BatchQueue -and $ctx.BatchQueue.Count -gt 0) {
                        return
                    }
                    $timerSender.Stop()
                    $script:galleryRunspaceContext = $null
                    $script:galleryTimer = $null
                    try { $ctx.PS.Dispose() } catch {}
                    Restore-StatusTextDefaultWithFade
                    return
                }

                $timerSender.Stop()
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
                    if ($fetchSource -eq 'Local') {
                        $StatusText.Text = if ($errorMsg) { $errorMsg } else { "No supported images found in the selected folder." }
                    }
                    else {
                        $StatusText.Text = Get-UserFriendlyNetworkError -Exception (New-Object Exception($errorMsg)) -DefaultAction "load wallpapers"
                    }
                    return
                }

                $isPexelsOrWallhaven = ($script:currentSource -in @('Wallhaven', 'Pexels') -or $fetchSource -in @('Wallhaven', 'Pexels'))
                $newImages = @()
                if (-not $isPexelsOrWallhaven -and $script:phase1Images -and $script:phase1Images.Count -gt 0) {
                    $existingUrlBases = New-Object System.Collections.Generic.HashSet[string]
                    foreach ($p1 in $script:phase1Images) { [void]$existingUrlBases.Add($p1.urlbase) }
                    
                    foreach ($img in $images) {
                        if (-not $existingUrlBases.Contains($img.urlbase)) {
                            $newImages += $img
                        }
                    }
                }
                else {
                    $newImages = @($images)
                }

                if (-not $isPexelsOrWallhaven -and $newImages.Count -eq 0 -and $script:phase1Images.Count -gt 0) {
                    Restore-StatusTextDefaultWithFade
                }
                else {
                    $isTopInsert = (-not $isPexelsOrWallhaven -and $script:phase1Images -and $script:phase1Images.Count -gt 0)
                    
                    if ($isTopInsert) {
                        Render-GalleryGrid -Images $newImages -ThumbCacheDir $ctx.ThumbCacheDir -InsertAtTop
                    }
                    else {
                        Render-GalleryGrid -Images $images -ThumbCacheDir $ctx.ThumbCacheDir
                    }

                    $script:loadingCounter = 0
                    $script:loadingTotal = if ($isTopInsert) { $newImages.Count } else { $images.Count }
            
                    if ($script:loadingStatusTimer) { $script:loadingStatusTimer.Stop() }
                    $script:loadingStatusTimer = New-Object System.Windows.Threading.DispatcherTimer
                    $script:loadingStatusTimer.Interval = [TimeSpan]::FromMilliseconds(35)
                    $script:loadingStatusTimer.Add_Tick({
                            $script:loadingCounter++
                            if ($script:loadingCounter -le $script:loadingTotal) {
                                $sourceName = if ($script:currentSource -eq 'Spotlight') { 'Windows Spotlight' } elseif ($script:currentSource -eq 'Wallhaven') { 'Wallhaven' } elseif ($script:currentSource -eq 'Pexels') { 'Pexels' } else { 'Bing' }
                                $StatusText.Text = "Loading $($script:loadingCounter) of $($script:loadingTotal) wallpapers from $sourceName..."
                            }
                            else {
                                $script:loadingStatusTimer.Stop()
                                Restore-StatusTextDefaultWithFade
                            }
                        })
                    $script:loadingStatusTimer.Start()
                }
            }
        })
    $script:galleryTimer.Start()
}

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
            $targetImage = if ($script:currentSource -eq 'Spotlight') {
                (Get-SpotlightImages | Select-Object -First 1)
            }
            elseif ($script:currentSource -eq 'Wallhaven') {
                (Get-WallhavenImages -Count 1 -ApiKey (Get-SourceApiKey 'Wallhaven') | Select-Object -First 1)
            }
            elseif ($script:currentSource -eq 'Pexels') {
                (Get-PexelsImages -Count 1 -ApiKey (Get-SourceApiKey 'Pexels') | Select-Object -First 1)
            }
            else {
                (Get-BingImages -Region (Get-SelectedRegionCode) | Select-Object -First 1)
            }
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
            $targetImage = if ($script:currentSource -eq 'Spotlight') {
                (Get-SpotlightImages | Select-Object -First 1)
            }
            elseif ($script:currentSource -eq 'Wallhaven') {
                (Get-WallhavenImages -Count 1 -ApiKey (Get-SourceApiKey 'Wallhaven') | Select-Object -First 1)
            }
            elseif ($script:currentSource -eq 'Pexels') {
                (Get-PexelsImages -Count 1 -ApiKey (Get-SourceApiKey 'Pexels') | Select-Object -First 1)
            }
            else {
                (Get-BingImages -Region (Get-SelectedRegionCode) | Select-Object -First 1)
            }
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

        $downloadFolder = $script:DownloadFolderPath
        if (-not (Test-Path -LiteralPath $downloadFolder)) {
            try { New-Item -ItemType Directory -Path $downloadFolder -Force | Out-Null } catch {}
        }

        $imageUri = Get-BingImageUri -Image $targetImage -Resolution $ResolutionBox.SelectedItem
        $resolutionSize = Get-ResolutionDimensions -Resolution $ResolutionBox.SelectedItem
        $needsLocalResize = ($targetImage.source -ne 'Bing' -and $targetImage.source -ne 'Local')
        $imageDate = if ($targetImage.enddate -and ($targetImage.enddate -match '^\d{8}$')) { $targetImage.enddate } else { (Get-Date).ToString('yyyyMMdd') }
        $cleanTitle = ($actionTitle -replace '[\\/:*?"<>|\x00-\x1F]', '').Trim()
        $cleanTitle = ($cleanTitle -replace '\s+', ' ').Trim()
        if ($cleanTitle.Length -gt 60) { $cleanTitle = $cleanTitle.Substring(0, 60).Trim() }
        $fileName = if ($targetImage.source -eq 'Local') {
            if ($cleanTitle -and $targetImage.fileType) { "$cleanTitle.$($targetImage.fileType.ToLower())" }
            else { [System.IO.Path]::GetFileName($imageUri) }
        }
        elseif ($cleanTitle) { "Bing-$imageDate-$cleanTitle.jpg" } else { "Bing-$imageDate.jpg" }
        $downloadPath = Join-Path $downloadFolder $fileName
        $tempPath = "$downloadPath.tmp"

        $fnResizeCode = "function Resize-WallpaperToResolution { " + ${function:Resize-WallpaperToResolution}.ToString() + " }"

        $ps = [powershell]::Create()
        [void]$ps.AddScript({
                param([string]$Uri, [string]$Temp, [string]$Dest, [string]$ResizeFnCode, [bool]$NeedsLocalResize, [int]$TargetWidth, [int]$TargetHeight)
                try {
                    if (Test-Path -LiteralPath $Uri) {
                        Copy-Item -LiteralPath $Uri -Destination $Temp -Force
                    }
                    else {
                        $wc = New-Object System.Net.WebClient
                        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                        $wc.DownloadFile($Uri, $Temp)
                        $wc.Dispose()
                    }
                    if (Test-Path -LiteralPath $Temp) {
                        if ($NeedsLocalResize) {
                            Invoke-Expression $ResizeFnCode
                            $resizedTemp = "$Temp.resized.jpg"
                            Resize-WallpaperToResolution -InputPath $Temp -OutputPath $resizedTemp -TargetWidth $TargetWidth -TargetHeight $TargetHeight | Out-Null
                            Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
                            Move-Item -LiteralPath $resizedTemp -Destination $Temp -Force
                        }
                        if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue }
                        Move-Item -LiteralPath $Temp -Destination $Dest -Force
                    }
                    return @{ Success = $true; Error = $null }
                }
                catch {
                    return @{ Success = $false; Error = $_.Exception.Message }
                }
            }).AddArgument($imageUri).AddArgument($tempPath).AddArgument($downloadPath).AddArgument($fnResizeCode).AddArgument($needsLocalResize).AddArgument($resolutionSize.Width).AddArgument($resolutionSize.Height)

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



@('Bing', 'Spotlight', 'Wallhaven', 'Pexels', 'Local', 'None') | ForEach-Object {
    [void]$AutoDesktopSourceBox.Items.Add($_)
    [void]$AutoLockScreenSourceBox.Items.Add($_)
}

$savedDesktopSource = if ($script:appSettings.AutoDesktopSource) { [string]$script:appSettings.AutoDesktopSource } else { 'Bing' }
$savedLockScreenSource = if ($script:appSettings.AutoLockScreenSource) { [string]$script:appSettings.AutoLockScreenSource } else { 'Bing' }

$AutoDesktopSourceBox.SelectedItem = $savedDesktopSource
if (-not $AutoDesktopSourceBox.SelectedItem) { $AutoDesktopSourceBox.SelectedItem = 'Bing' }
$AutoLockScreenSourceBox.SelectedItem = $savedLockScreenSource
if (-not $AutoLockScreenSourceBox.SelectedItem) { $AutoLockScreenSourceBox.SelectedItem = 'Bing' }

if ($AutoScheduleBox) {
    $dailyItem = New-Object System.Windows.Controls.ComboBoxItem
    $dailyItem.Content = "Daily $([char]183) 12:00 AM"
    $dailyItem.Tag = 'Daily'
    [void]$AutoScheduleBox.Items.Add($dailyItem)

    $testItem = New-Object System.Windows.Controls.ComboBoxItem
    $testItem.Content = 'Every 1 minute (Test)'
    $testItem.Tag = 'Test1Minute'
    [void]$AutoScheduleBox.Items.Add($testItem)

    $savedSchedule = if ($script:appSettings.AutoSchedule) { [string]$script:appSettings.AutoSchedule } else { 'Daily' }
    $AutoScheduleBox.SelectedItem = $AutoScheduleBox.Items | Where-Object { [string]$_.Tag -eq $savedSchedule } | Select-Object -First 1
    if (-not $AutoScheduleBox.SelectedItem) { $AutoScheduleBox.SelectedIndex = 0 }
}

$spotlightWasEnabled = ($script:appSettings.SpotlightEnabled -eq $true)
if ($spotlightWasEnabled) {
    Set-SpotlightState -Enabled:$true -Animate:$false -UpdateTask:$false
    Update-SpotlightScheduledTaskAsync -Enable $true
}

$AutoUnifiedButton.Add_Click({
        param($sender, $e)
        if ($e) {
            $e.Handled = $true
            if ($e.Source -ne $AutoUnifiedButton) { return }
        }
        $newState = -not $script:SpotlightEnabled
        Set-SpotlightState -Enabled:$newState

        if ($newState) {
            Set-TransientStatus -Message "Automatic wallpaper changing enabled. Default schedule: daily at 12:00 AM." -Brush $statusSuccessBrush
            if ($SpotlightOptionsPopup) {
                $openPopupTimer = New-Object System.Windows.Threading.DispatcherTimer
                $openPopupTimer.Interval = [TimeSpan]::FromMilliseconds(240)
                $openPopupTimer.Add_Tick({
                        if ($script:SpotlightEnabled -and -not $SpotlightOptionsPopup.IsOpen) {
                            $SpotlightOptionsPopup.IsOpen = $true
                        }
                        $this.Stop()
                    })
                $openPopupTimer.Start()
            }
        }
        else {
            Set-TransientStatus -Message "Automatic wallpaper changing disabled." -Brush $statusErrorBrush
        }
    })

function Update-AutoOptionUI {
    param([string]$Category, $SelectedItem)
    if (-not $SelectedItem) { return }

    $inds = @(); $lbls = @(); $vals = @()
    if ($Category -eq 'Desktop') {
        $inds = @($window.FindName('DeskBingInd'), $window.FindName('DeskSpotlightInd'), $window.FindName('DeskWallhavenInd'), $window.FindName('DeskPexelsInd'), $window.FindName('DeskLocalInd'), $window.FindName('DeskNoneInd'))
        $lbls = @($window.FindName('DeskBingLbl'), $window.FindName('DeskSpotlightLbl'), $window.FindName('DeskWallhavenLbl'), $window.FindName('DeskPexelsLbl'), $window.FindName('DeskLocalLbl'), $window.FindName('DeskNoneLbl'))
        $vals = @('Bing', 'Spotlight', 'Wallhaven', 'Pexels', 'Local', 'None')
    }
    elseif ($Category -eq 'LockScreen') {
        $inds = @($window.FindName('LockBingInd'), $window.FindName('LockSpotlightInd'), $window.FindName('LockWallhavenInd'), $window.FindName('LockPexelsInd'), $window.FindName('LockLocalInd'), $window.FindName('LockNoneInd'))
        $lbls = @($window.FindName('LockBingLbl'), $window.FindName('LockSpotlightLbl'), $window.FindName('LockWallhavenLbl'), $window.FindName('LockPexelsLbl'), $window.FindName('LockLocalLbl'), $window.FindName('LockNoneLbl'))
        $vals = @('Bing', 'Spotlight', 'Wallhaven', 'Pexels', 'Local', 'None')
    }
    elseif ($Category -eq 'Schedule') {
        $inds = @($window.FindName('SchedEverydayInd'), $window.FindName('SchedTestInd'))
        $lbls = @($window.FindName('SchedEverydayLbl'), $window.FindName('SchedTestLbl'))
        if ($AutoScheduleBox.Items.Count -ge 2) {
            $vals = @($AutoScheduleBox.Items[0], $AutoScheduleBox.Items[1])
        }
    }
    
    for ($i = 0; $i -lt $inds.Count; $i++) {
        if ($inds[$i] -and $lbls[$i] -and $vals[$i]) {
            $match = $false
            if ($vals[$i] -is [System.Windows.Controls.ComboBoxItem]) {
                $selTag = if ($SelectedItem -is [System.Windows.Controls.ComboBoxItem]) { $SelectedItem.Tag } else { [string]$SelectedItem }
                $match = ($vals[$i].Tag -eq $selTag -or $vals[$i].Content -eq $SelectedItem)
            }
            else {
                $match = ($vals[$i] -eq [string]$SelectedItem)
            }
            if ($match) {
                $inds[$i].Opacity = 1
                $lbls[$i].Foreground = "#FFFFFF"
            }
            else {
                $inds[$i].Opacity = 0
                $lbls[$i].Foreground = "#9E9E9E"
            }
        }
    }
}

$DeskBingBtn = $window.FindName('DeskBingBtn')
if ($DeskBingBtn) { $DeskBingBtn.Add_Click({ $AutoDesktopSourceBox.SelectedItem = 'Bing' }) }
$DeskSpotlightBtn = $window.FindName('DeskSpotlightBtn')
if ($DeskSpotlightBtn) { $DeskSpotlightBtn.Add_Click({ $AutoDesktopSourceBox.SelectedItem = 'Spotlight' }) }
$DeskWallhavenBtn = $window.FindName('DeskWallhavenBtn')
if ($DeskWallhavenBtn) { $DeskWallhavenBtn.Add_Click({ $AutoDesktopSourceBox.SelectedItem = 'Wallhaven' }) }
$DeskPexelsBtn = $window.FindName('DeskPexelsBtn')
if ($DeskPexelsBtn) { $DeskPexelsBtn.Add_Click({ $AutoDesktopSourceBox.SelectedItem = 'Pexels' }) }
$DeskLocalBtn = $window.FindName('DeskLocalBtn')
if ($DeskLocalBtn) { $DeskLocalBtn.Add_Click({ $AutoDesktopSourceBox.SelectedItem = 'Local' }) }
$DeskNoneBtn = $window.FindName('DeskNoneBtn')
if ($DeskNoneBtn) { $DeskNoneBtn.Add_Click({ $AutoDesktopSourceBox.SelectedItem = 'None' }) }

$LockBingBtn = $window.FindName('LockBingBtn')
if ($LockBingBtn) { $LockBingBtn.Add_Click({ $AutoLockScreenSourceBox.SelectedItem = 'Bing' }) }
$LockSpotlightBtn = $window.FindName('LockSpotlightBtn')
if ($LockSpotlightBtn) { $LockSpotlightBtn.Add_Click({ $AutoLockScreenSourceBox.SelectedItem = 'Spotlight' }) }
$LockWallhavenBtn = $window.FindName('LockWallhavenBtn')
if ($LockWallhavenBtn) { $LockWallhavenBtn.Add_Click({ $AutoLockScreenSourceBox.SelectedItem = 'Wallhaven' }) }
$LockPexelsBtn = $window.FindName('LockPexelsBtn')
if ($LockPexelsBtn) { $LockPexelsBtn.Add_Click({ $AutoLockScreenSourceBox.SelectedItem = 'Pexels' }) }
$LockLocalBtn = $window.FindName('LockLocalBtn')
if ($LockLocalBtn) { $LockLocalBtn.Add_Click({ $AutoLockScreenSourceBox.SelectedItem = 'Local' }) }
$LockNoneBtn = $window.FindName('LockNoneBtn')
if ($LockNoneBtn) { $LockNoneBtn.Add_Click({ $AutoLockScreenSourceBox.SelectedItem = 'None' }) }

$SchedEverydayBtn = $window.FindName('SchedEverydayBtn')
if ($SchedEverydayBtn) { $SchedEverydayBtn.Add_Click({ $AutoScheduleBox.SelectedItem = $AutoScheduleBox.Items[0] }) }
$SchedTestBtn = $window.FindName('SchedTestBtn')
if ($SchedTestBtn) { $SchedTestBtn.Add_Click({ $AutoScheduleBox.SelectedItem = $AutoScheduleBox.Items[1] }) }

$AutoDesktopSourceBox.Add_SelectionChanged({
        Update-AutoOptionUI 'Desktop' $AutoDesktopSourceBox.SelectedItem
        if ($script:SpotlightEnabled) {
            Save-Settings
        }
    })

$AutoLockScreenSourceBox.Add_SelectionChanged({
        Update-AutoOptionUI 'LockScreen' $AutoLockScreenSourceBox.SelectedItem
        if ($script:SpotlightEnabled) {
            Save-Settings
        }
    })

if ($AutoScheduleBox) {
    $AutoScheduleBox.Add_SelectionChanged({
            Update-AutoOptionUI 'Schedule' $AutoScheduleBox.SelectedItem
            if ($script:SpotlightEnabled) {
                Update-SpotlightScheduledTaskAsync -Enable $true
                Save-Settings
            }
        })
    Update-AutoOptionUI 'Schedule' $AutoScheduleBox.SelectedItem
}
Update-AutoOptionUI 'Desktop' $AutoDesktopSourceBox.SelectedItem
Update-AutoOptionUI 'LockScreen' $AutoLockScreenSourceBox.SelectedItem

if ($SpotlightSetBtn -and $SpotlightOptionsPopup) {
    $script:spotlightPopupClosedAt = [DateTime]::MinValue
    $spotlightSetBtnAccentBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(0, 120, 212))

    # The card's on-screen size is fixed by its fixed-width children (135 +
    # 155 columns, fixed padding/margins), so we can compute it once instead
    # of measuring at runtime.
    $spotlightPopupCardWidth = 490.0
    $spotlightPopupCardHeight = 310.0
    $spotlightPopupEdgePad = 8.0

    # If the window gets resized while the flyout is open, just close it
    # rather than let it sit at a now-stale (possibly off-window) position.
    $window.Add_SizeChanged({
            if ($SpotlightOptionsPopup -and $SpotlightOptionsPopup.IsOpen) { $SpotlightOptionsPopup.IsOpen = $false }
        })

    $SpotlightSetBtn.Add_Click({
            param($sender, $e)
            if ($e) { $e.Handled = $true }

            # Popup has StaysOpen="False": clicking this same button while the
            # popup is open first fires the popup's own light-dismiss (the
            # button is outside the popup's visual tree), THEN this Click
            # event fires - which used to immediately reopen it. Ignore a
            # click that lands right after a light-dismiss so a second click
            # on the button actually closes it instead of bouncing back open.
            $msSinceClosed = ([DateTime]::Now - $script:spotlightPopupClosedAt).TotalMilliseconds
            if ($msSinceClosed -lt 200) { return }

            if (-not $SpotlightOptionsPopup.IsOpen) {
                # Work out where the button actually sits in the window right
                # now, and clamp the popup's offsets so the card can't render
                # past any edge of the (possibly small/resized) window. Falls
                # back to the old fixed offsets if anything here goes wrong.
                try {
                    $targetPos = $SpotlightSetBtn.TranslatePoint([System.Windows.Point]::new(0, 0), $window)

                    $hOffset = 0.0
                    $maxH = ($window.ActualWidth - $spotlightPopupEdgePad) - $targetPos.X - $spotlightPopupCardWidth
                    $minH = $spotlightPopupEdgePad - $targetPos.X
                    if ($hOffset -gt $maxH) { $hOffset = $maxH }
                    if ($hOffset -lt $minH) { $hOffset = $minH }
                    $SpotlightOptionsPopup.HorizontalOffset = $hOffset

                    $vOffset = 6.0
                    $targetBottom = $targetPos.Y + $SpotlightSetBtn.ActualHeight
                    $roomBelow = $window.ActualHeight - $spotlightPopupEdgePad - $targetBottom
                    if ($roomBelow -lt $spotlightPopupCardHeight) {
                        # Not enough room below - flip the card above the button instead.
                        $vOffset = - ($SpotlightSetBtn.ActualHeight + $spotlightPopupCardHeight + 6.0)
                    }
                    $SpotlightOptionsPopup.VerticalOffset = $vOffset
                }
                catch {
                    $SpotlightOptionsPopup.HorizontalOffset = 0.0
                    $SpotlightOptionsPopup.VerticalOffset = 6.0
                }
            }

            $SpotlightOptionsPopup.IsOpen = -not $SpotlightOptionsPopup.IsOpen
        })

    # Same slide + fade entrance every open, mirroring the ~200ms CubicEase
    # timing used elsewhere in the toolbar (e.g. Set-SpotlightState's pill
    # animation) so this flyout feels consistent with the rest of the app.
    $SpotlightOptionsPopup.Add_Opened({
            $easing = New-Object System.Windows.Media.Animation.CubicEase
            $easing.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
            $dur = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(160))

            $fadeAnim = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 1.0, $dur
            $fadeAnim.EasingFunction = $easing
            $SpotlightPopupCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeAnim)

            $slideAnim = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 0.0, $dur
            $slideAnim.EasingFunction = $easing
            $SpotlightPopupTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slideAnim)

            # (Removed glow/border highlight per user request)
        })

    $SpotlightOptionsPopup.Add_Closed({
            $script:spotlightPopupClosedAt = [DateTime]::Now

            $SpotlightPopupCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $SpotlightPopupCard.Opacity = 0
            $SpotlightPopupTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
            $SpotlightPopupTransform.Y = -8

            # (Removed glow/border highlight per user request)
        })
}


$initialRegionCode = Get-DetectedRegionCode
$detectedItem = $RegionBox.Items | Where-Object { $_.Tag -eq $initialRegionCode } | Select-Object -First 1
if ($detectedItem) { 
    $RegionBox.SelectedItem = $detectedItem 
}

$window.Add_ContentRendered({
        Start-DeferredNativeExtraCompile
        $RegionBox.Add_SelectionChanged({ Load-Gallery })
        Load-Gallery

        # Auto-Wallpaper catch-up: if auto daily is enabled and today's wallpaper hasn't been applied yet, catch up immediately!
        if ($script:SpotlightEnabled) {
            $today = Get-Date -Format 'yyyyMMdd'
            $currentSettings = Load-Settings
            if (-not $currentSettings.LastAutoAppliedDate -or $currentSettings.LastAutoAppliedDate -ne $today) {
                $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { (Join-Path $PSScriptRoot 'Bing-Wallpaper-UI.ps1') }
                $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $conhostExe = Join-Path $env:WINDIR 'System32\conhost.exe'
                Start-Process -FilePath $conhostExe -ArgumentList "--headless `"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -AutoApply" -WindowStyle Hidden
            }
        }
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
$window.Add_SizeChanged({ Update-ToolbarCompactState })
$window.Add_Loaded({ Update-ToolbarCompactState })
$GalleryPanel.Add_SizeChanged({ Update-GalleryViewportHeight })

# --- User Guide & Shortcuts Modal --------------------------------------
$guideModalPath = Join-Path $PSScriptRoot 'AutoScape-UserGuideModal.ps1'
if (-not (Test-Path -LiteralPath $guideModalPath)) {
    $guideModalPath = Join-Path $PSScriptRoot 'core\AutoScape-UserGuideModal.ps1'
}
if (Test-Path -LiteralPath $guideModalPath) {
    . $guideModalPath
}

if ($InfoBtn) {
    $InfoBtn.Add_Click({
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
            if ($script:activeDialogModalControl) { Close-DialogModal -Immediate $true }
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

            if ($e.Key -eq [System.Windows.Input.Key]::S) {
                if ($script:userHasExplicitlySelectedWallpaper -and $script:selectedCard -and $script:selectedImage) {
                    $e.Handled = $true
                    # Call your download button click logic here
                    $DownloadBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
                }
            }
            elseif ($e.Key -eq [System.Windows.Input.Key]::B) {
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
            try { [BingWallpaperNativeExtra]::FlushMemory() } catch {}
        }
    })

$script:memTrimTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:memTrimTimer.Interval = [TimeSpan]::FromSeconds(45)
$script:memTrimTimer.Add_Tick({ try { [BingWallpaperNativeExtra]::FlushMemory() } catch {} })
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
[Environment]::Exit(0)



