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

# Unified industry-standard directory structure under %LOCALAPPDATA%\AutoScape
$script:autoScapeRoot = Join-Path $env:LOCALAPPDATA 'AutoScape'
$script:logsDir       = Join-Path $script:autoScapeRoot 'logs'
$script:cacheDir      = Join-Path $script:autoScapeRoot 'cache'
$script:settingsPath  = Join-Path $script:autoScapeRoot 'settings.json'

function Initialize-AutoScapeDirectories {
    try {
        foreach ($d in @($script:autoScapeRoot, $script:logsDir, $script:cacheDir)) {
            if (-not (Test-Path -LiteralPath $d)) {
                New-Item -ItemType Directory -Path $d -Force | Out-Null
            }
        }

        # 1. Seamless migration: copy legacy settings.json if new one doesn't exist yet
        $legacySettingsPath = Join-Path $env:LOCALAPPDATA 'BingWallpaper\settings.json'
        if (-not (Test-Path -LiteralPath $script:settingsPath) -and (Test-Path -LiteralPath $legacySettingsPath)) {
            Copy-Item -LiteralPath $legacySettingsPath -Destination $script:settingsPath -Force
        }

        # 2. Seamless migration: copy legacy cache & thumbnails if new cache is empty
        $legacyCacheDir = Join-Path $env:LOCALAPPDATA 'BingWallpaper\Cache'
        if (Test-Path -LiteralPath $legacyCacheDir) {
            $legacyThumbs = Join-Path $legacyCacheDir 'Thumbnails'
            $newThumbs = Join-Path $script:cacheDir 'Thumbnails'
            if (-not (Test-Path -LiteralPath $newThumbs) -and (Test-Path -LiteralPath $legacyThumbs)) {
                Copy-Item -Path $legacyThumbs -Destination $newThumbs -Recurse -Force
            }
            $legacyCurrent = Join-Path $legacyCacheDir 'current_wallpaper.jpg'
            $newCurrent = Join-Path $script:cacheDir 'current_wallpaper.jpg'
            if (-not (Test-Path -LiteralPath $newCurrent) -and (Test-Path -LiteralPath $legacyCurrent)) {
                Copy-Item -LiteralPath $legacyCurrent -Destination $newCurrent -Force
            }
        }

        # 3. Seamless migration: move root-level local_index.json into cache
        $legacyIndex = Join-Path $script:autoScapeRoot 'local_index.json'
        $newIndex = Join-Path $script:cacheDir 'local_index.json'
        if (Test-Path -LiteralPath $legacyIndex) {
            if (-not (Test-Path -LiteralPath $newIndex)) {
                Move-Item -LiteralPath $legacyIndex -Destination $newIndex -Force
            }
            else {
                Remove-Item -LiteralPath $legacyIndex -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {}
}
Initialize-AutoScapeDirectories

$script:timingLogPath = Join-Path $script:logsDir 'startup-timing.log'
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

$script:interactionLogPath = Join-Path $script:logsDir 'autoscape-interactions.log'
$script:archiveLogPath     = $script:interactionLogPath

function Write-InteractionLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $script:logsDir)) {
            New-Item -ItemType Directory -Path $script:logsDir -Force | Out-Null
        }
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        $memMB = [Math]::Round(([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB), 1)
        Add-Content -Path $script:interactionLogPath -Value "[$ts] [MEM: ${memMB}MB] $Message" -ErrorAction SilentlyContinue
    } catch {}
}

function Write-ArchiveLog {
    param([string]$Message)
    Write-InteractionLog $Message
}

function Invoke-MemoryFlush {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param(
        [string]$Reason = '',
        [switch]$Async
    )

    if ($Async) {
        if ('BingWallpaperNative' -as [type]) {
            try {
                [BingWallpaperNative]::FlushMemoryBackground($script:interactionLogPath, $Reason)
                return
            } catch {}
        }
    }

    try {
        $beforeMemMB = [Math]::Round(([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB), 1)

        if ('BingWallpaperNative' -as [type]) {
            try { [BingWallpaperNative]::FlushMemory() } catch {}
        }
        elseif ('BingWallpaperNativeExtra' -as [type]) {
            try { [BingWallpaperNativeExtra]::FlushMemory() } catch {}
        }

        $afterMemMB = [Math]::Round(([System.Diagnostics.Process]::GetCurrentProcess().WorkingSet64 / 1MB), 1)
        if ($Reason) {
            Write-InteractionLog "[MEM_FLUSH] ($Reason) WorkingSet: ${beforeMemMB}MB -> ${afterMemMB}MB"
        }
    } catch {}
}
$script:galleryIdleSettleTimer = $null
Write-InteractionLog "[APP_INIT] AutoScape initialized. Initial WorkingSet recorded."

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
$script:nativeLoadLogPath = Join-Path $script:logsDir 'native-load.log'
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
using System.Threading.Tasks;

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
    private const int DWMSBT_TRANSIENTWINDOW = 3; // Acrylic

    public static int EnableMica(IntPtr hwnd)
    {
        int backdrop = DWMSBT_MAINWINDOW;
        return DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int));
    }

    public static int EnableTransientBackdrop(IntPtr hwnd)
    {
        int backdrop = DWMSBT_TRANSIENTWINDOW;
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

    [DllImport("psapi.dll")]
    private static extern bool EmptyWorkingSet(IntPtr hProcess);

    public static void FlushMemory()
    {
        try {
            EmptyWorkingSet(System.Diagnostics.Process.GetCurrentProcess().Handle);
        } catch { }
    }

    public static void FlushMemoryBackground(string logPath = null, string reason = null)
    {
        Task.Run(() => {
            try {
                long before = System.Diagnostics.Process.GetCurrentProcess().WorkingSet64;
                GC.Collect(2, GCCollectionMode.Forced, false);
                EmptyWorkingSet(System.Diagnostics.Process.GetCurrentProcess().Handle);
                long after = System.Diagnostics.Process.GetCurrentProcess().WorkingSet64;
                if (!string.IsNullOrEmpty(logPath) && !string.IsNullOrEmpty(reason)) {
                    double bMB = Math.Round(before / (1024.0 * 1024.0), 1);
                    double aMB = Math.Round(after / (1024.0 * 1024.0), 1);
                    string ts = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff");
                    string line = string.Format("[{0}] [MEM: {1}MB] [MEM_FLUSH] ({2}) WorkingSet: {3}MB -> {4}MB\r\n", ts, aMB, reason, bMB, aMB);
                    System.IO.File.AppendAllText(logPath, line);
                }
            } catch { }
        });
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
using System.Collections.Generic;
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
        try {
            EmptyWorkingSet(System.Diagnostics.Process.GetCurrentProcess().Handle);
        } catch { }
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

    [DllImport("shell32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern int SHCreateItemFromParsingName(
        [MarshalAs(UnmanagedType.LPWStr)] string pszPath,
        IntPtr pbc,
        ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItem ppv);

    private const uint FOS_PICKFOLDERS = 0x00000020;
    private const uint FOS_FORCEFILESYSTEM = 0x00000040;
    private const uint SIGDN_FILESYSPATH = 0x80058000;

    public static string PickFolder(IntPtr owner, string title, string initialPath = null)
    {
        IFileOpenDialog dialog = null;
        try
        {
            dialog = (IFileOpenDialog)new FileOpenDialogRCW();
            dialog.SetOptions(FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
            if (!string.IsNullOrEmpty(title)) dialog.SetTitle(title);
            dialog.SetOkButtonLabel("Select Folder");

            if (!string.IsNullOrEmpty(initialPath) && System.IO.Directory.Exists(initialPath))
            {
                Guid riid = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
                IShellItem folderItem;
                if (SHCreateItemFromParsingName(initialPath, IntPtr.Zero, ref riid, out folderItem) == 0 && folderItem != null)
                {
                    dialog.SetFolder(folderItem);
                }
            }

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

namespace AutoScapeLocal
{
    public class LocalItem
    {
        public string SourcePath;
        public string ThumbPath;
        public string SafeKey;
        public string Title;
        public string Folder;
        public string FileType;
        public int Width;
        public int Height;
        public long FileSize;
        public byte R;
        public byte G;
        public byte B;
    }

    public static class Helper
    {
        private static readonly HashSet<string> Extensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            ".jpg", ".jpeg", ".png", ".bmp", ".webp"
        };

        public static List<string> SafeScanFiles(string rootFolder, int maxCount)
        {
            var results = new List<string>();
            if (string.IsNullOrEmpty(rootFolder) || !Directory.Exists(rootFolder))
                return results;

            var queue = new Queue<string>();
            queue.Enqueue(rootFolder);

            while (queue.Count > 0)
            {
                string dir = queue.Dequeue();
                try
                {
                    foreach (string f in Directory.EnumerateFiles(dir))
                    {
                        string ext = Path.GetExtension(f);
                        if (Extensions.Contains(ext))
                        {
                            results.Add(f);
                            if (maxCount > 0 && results.Count >= maxCount)
                                return results;
                        }
                    }
                }
                catch {}

                try
                {
                    foreach (string sub in Directory.EnumerateDirectories(dir))
                    {
                        try
                        {
                            var attr = File.GetAttributes(sub);
                            if ((attr & (FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint)) != 0)
                                continue;
                            queue.Enqueue(sub);
                        }
                        catch {}
                    }
                }
                catch {}
            }
            return results;
        }

        public static List<LocalItem> ProcessBatch(string[] filePaths, string cacheDir, int decodeWidth)
        {
            var results = new LocalItem[filePaths.Length];

            Parallel.For(0, filePaths.Length, new ParallelOptions { MaxDegreeOfParallelism = 4 }, i =>
            {
                string path = filePaths[i];
                var item = new LocalItem();
                item.SourcePath = path;
                item.Title = Path.GetFileNameWithoutExtension(path);
                item.Folder = Path.GetFileName(Path.GetDirectoryName(path));
                string ext = Path.GetExtension(path);
                item.FileType = string.IsNullOrEmpty(ext) ? "JPG" : ext.TrimStart('.').ToUpperInvariant();

                try
                {
                    var fi = new FileInfo(path);
                    item.FileSize = fi.Length;

                    uint hash = (uint)path.ToLowerInvariant().GetHashCode();
                    item.SafeKey = "local_" + hash.ToString();
                    item.ThumbPath = Path.Combine(cacheDir, item.SafeKey + "_thumb.jpg");

                    using (var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    {
                        var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None);
                        if (decoder.Frames.Count > 0)
                        {
                            item.Width = decoder.Frames[0].PixelWidth;
                            item.Height = decoder.Frames[0].PixelHeight;
                        }
                    }

                    if (!File.Exists(item.ThumbPath))
                    {
                        var bmp = new BitmapImage();
                        bmp.BeginInit();
                        bmp.UriSource = new Uri(path);
                        bmp.DecodePixelWidth = decodeWidth;
                        bmp.CacheOption = BitmapCacheOption.OnLoad;
                        bmp.EndInit();
                        bmp.Freeze();

                        string dir = Path.GetDirectoryName(item.ThumbPath);
                        if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);

                        var encoder = new JpegBitmapEncoder();
                        encoder.QualityLevel = 80;
                        encoder.Frames.Add(BitmapFrame.Create(bmp));
                        using (var fs = File.Open(item.ThumbPath, FileMode.Create, FileAccess.Write, FileShare.None))
                        {
                            encoder.Save(fs);
                        }

                        try
                        {
                            var frame = new TransformedBitmap(bmp, new ScaleTransform(32.0 / bmp.PixelWidth, 32.0 / bmp.PixelHeight));
                            var converted = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
                            int w = converted.PixelWidth, h = converted.PixelHeight;
                            int stride = w * 4;
                            byte[] pixels = new byte[h * stride];
                            converted.CopyPixels(pixels, stride, 0);

                            long r = 0, g = 0, b = 0;
                            int count = 0;
                            for (int p = 0; p < pixels.Length; p += 4)
                            {
                                byte bb = pixels[p], gg = pixels[p + 1], rr = pixels[p + 2];
                                int lum = (rr + gg + bb) / 3;
                                if (lum < 18 || lum > 238) continue;
                                r += rr; g += gg; b += bb;
                                count++;
                            }
                            if (count == 0) count = 1;
                            item.R = (byte)(r / count);
                            item.G = (byte)(g / count);
                            item.B = (byte)(b / count);
                        }
                        catch
                        {
                            item.R = 70; item.G = 70; item.B = 70;
                        }
                    }
                    else
                    {
                        item.R = 70; item.G = 70; item.B = 70;
                    }
                }
                catch
                {
                    item.R = 70; item.G = 70; item.B = 70;
                }

                results[i] = item;
            });

            return new List<LocalItem>(results);
        }
    }
}

namespace BingWallpaper
{
    public static class FastAccent
    {
        // Approximate dominant-color extraction: downsample and average, biased
        // away from near-black/near-white pixels so the accent isn't washed out.
        public static byte[] ExtractRgb(string imagePath)
        {
            try
            {
                var decoder = BitmapDecoder.Create(
                    new Uri(System.IO.Path.GetFullPath(imagePath)),
                    BitmapCreateOptions.IgnoreColorProfile,
                    BitmapCacheOption.OnLoad);
                if (decoder.Frames.Count == 0)
                    return new byte[] { 0, 120, 215 };

                var frame = new TransformedBitmap(decoder.Frames[0],
                    new ScaleTransform(
                        32.0 / decoder.Frames[0].PixelWidth,
                        32.0 / decoder.Frames[0].PixelHeight));
                var converted = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);

                int w = converted.PixelWidth, h = converted.PixelHeight;
                int stride = w * 4;
                byte[] pixels = new byte[h * stride];
                converted.CopyPixels(pixels, stride, 0);

                long r = 0, g = 0, b = 0;
                long rAll = 0, gAll = 0, bAll = 0;
                int count = 0;
                for (int i = 0; i < pixels.Length; i += 4)
                {
                    byte bb = pixels[i], gg = pixels[i + 1], rr = pixels[i + 2];
                    rAll += rr; gAll += gg; bAll += bb;
                    int lum = (rr + gg + bb) / 3;
                    if (lum < 18 || lum > 238) continue; // skip near-black / near-white
                    r += rr; g += gg; b += bb;
                    count++;
                }
                if (count > 0)
                    return new byte[] { (byte)(r / count), (byte)(g / count), (byte)(b / count) };
                else if (pixels.Length >= 4)
                {
                    int totalPix = pixels.Length / 4;
                    return new byte[] { (byte)(rAll / totalPix), (byte)(gAll / totalPix), (byte)(bAll / totalPix) };
                }
                return new byte[] { 0, 120, 215 };
            }
            catch
            {
                return new byte[] { 0, 120, 215 };
            }
        }

        public static void ExtractBatchRgb(string[] paths, out byte[] rOut, out byte[] gOut, out byte[] bOut)
        {
            int n = paths == null ? 0 : paths.Length;
            byte[] r = new byte[n];
            byte[] g = new byte[n];
            byte[] b = new byte[n];
            if (n == 0) { rOut = r; gOut = g; bOut = b; return; }

            Parallel.For(0, n, i => {
                if (string.IsNullOrEmpty(paths[i]) || !System.IO.File.Exists(paths[i])) {
                    r[i] = 0; g[i] = 120; b[i] = 215;
                    return;
                }
                byte[] rgb = ExtractRgb(paths[i]);
                r[i] = rgb[0];
                g[i] = rgb[1];
                b[i] = rgb[2];
            });

            rOut = r;
            gOut = g;
            bOut = b;
        }

        public static SolidColorBrush ExtractBrush(string imagePath)
        {
            byte[] rgb = ExtractRgb(imagePath);
            var brush = new SolidColorBrush(Color.FromArgb(235, rgb[0], rgb[1], rgb[2]));
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
                        }
                        catch { return $false }
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
                        }
                        catch { return $false }
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

    $cacheDir = $script:cacheDir
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

$script:settingsPath = Join-Path $script:autoScapeRoot 'settings.json'

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
        $scheduleMode = if ($savedSettings -and $savedSettings.AutoSchedule) { [string]$savedSettings.AutoSchedule } else { 'Daily' }
        if ($scheduleMode -ne 'Test1Minute' -and
            $savedSettings -and 
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
                }
                catch {
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
                }
                catch {
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
                Region                = if ($existing -and $existing.Region) { $existing.Region } else { "auto" }
                Resolution            = if ($existing -and $existing.Resolution) { $existing.Resolution } else { "4K" }
                Target                = if ($existing -and $existing.Target) { $existing.Target } else { "Both" }
                Style                 = if ($existing -and $existing.Style) { $existing.Style } else { "Fit" }
                SaveFolder            = if ($existing -and $existing.SaveFolder) { $existing.SaveFolder } else { (Get-DownloadFolder) }
                AutoDesktopSource     = $desktopSource
                AutoLockScreenSource  = $lockSource
                AutoSchedule          = if ($existing -and $existing.AutoSchedule) { $existing.AutoSchedule } else { 'Daily' }
                SpotlightEnabled      = if ($existing -and $null -ne $existing.SpotlightEnabled) { [bool]$existing.SpotlightEnabled } else { $true }
                WallhavenApiKey       = if ($existing -and $existing.WallhavenApiKey) { $existing.WallhavenApiKey } else { '' }
                PexelsApiKey          = if ($existing -and $existing.PexelsApiKey) { $existing.PexelsApiKey } else { '' }
                LocalFolderPath       = if ($existing -and $existing.LocalFolderPath) { [string]$existing.LocalFolderPath } else { '' }
                LastAutoAppliedDate   = if ($scheduleMode -eq 'Test1Minute') { '' } else { $todayStamp }
                LastAutoDesktopSource = $desktopSource
                LastAutoLockSource    = $lockSource
            }
            $settingsObj | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $script:settingsPath
        }
        catch {}

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
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="AutoScape" Height="680" Width="1100" MinWidth="780" MinHeight="520"
        WindowStyle="None"
        Background="Transparent" FontFamily="Segoe UI" WindowStartupLocation="CenterScreen" WindowState="Maximized">
    
    <shell:WindowChrome.WindowChrome>
        <shell:WindowChrome CaptionHeight="48"
                            ResizeBorderThickness="6"
                            CornerRadius="0"
                            GlassFrameThickness="0"
                            UseAeroCaptionButtons="False" />
    </shell:WindowChrome.WindowChrome>
    
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
                        <Border Name="RevealBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
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
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#F0F0F0"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Padding" Value="10,0,10,0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="RevealBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#15FFFFFF"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="RevealBorder" Property="Background" Value="#25FFFFFF"/>
                                <Setter TargetName="RevealBorder" Property="BorderBrush" Value="#10FFFFFF"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="FluentCardContextMenu" TargetType="ContextMenu">
            <Setter Property="SnapsToDevicePixels" Value="True"/>
            <Setter Property="OverridesDefaultStyle" Value="True"/>
            <Setter Property="Grid.IsSharedSizeScope" Value="True"/>
            <Setter Property="HasDropShadow" Value="False"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="MinWidth" Value="210"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ContextMenu">
                        <Border Margin="8" Background="#1E1F24" BorderBrush="#25FFFFFF" BorderThickness="1" CornerRadius="8" Padding="4">
                            <Border.Effect>
                                <DropShadowEffect BlurRadius="12" Opacity="0.5" ShadowDepth="3" Direction="270" Color="#000000"/>
                            </Border.Effect>
                            <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="FluentCardMenuItem" TargetType="MenuItem">
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="FontSize" Value="13.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="MenuItem">
                        <Border Name="ItemBorder" Background="Transparent" CornerRadius="5" Padding="12,8,14,8" BorderThickness="1" BorderBrush="Transparent">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <ContentPresenter Grid.Column="0" ContentSource="Icon" Margin="0,0,10,0" VerticalAlignment="Center"/>
                                <ContentPresenter Grid.Column="1" ContentSource="Header" RecognizesAccessKey="False" VerticalAlignment="Center"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="ItemBorder" Property="Background" Value="#25FFFFFF"/>
                                <Setter TargetName="ItemBorder" Property="BorderBrush" Value="#10FFFFFF"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#55FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="AutoToggleSwitchStyle" TargetType="CheckBox">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Border x:Name="Track" Width="40" Height="20" CornerRadius="10"
                                Background="#00000000" BorderBrush="#38FFFFFF" BorderThickness="1"
                                SnapsToDevicePixels="True" UseLayoutRounding="True">
                            <Grid HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                                <Border x:Name="Thumb" Width="14" Height="14" CornerRadius="7"
                                        Background="#9E9E9E"
                                        HorizontalAlignment="Left" VerticalAlignment="Center" Margin="2,0,0,0"
                                        SnapsToDevicePixels="True" UseLayoutRounding="True">
                                    <Border.RenderTransform>
                                        <TranslateTransform x:Name="ThumbPos" X="0" Y="0"/>
                                    </Border.RenderTransform>
                                </Border>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Track" Property="Background" Value="#FFFFFF"/>
                                <Setter TargetName="Track" Property="BorderBrush" Value="#FFFFFF"/>
                                <Setter TargetName="Thumb" Property="Background" Value="#1A1C23"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Thumb"
                                                             Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)"
                                                             To="20" Duration="0:0:0.18">
                                                <DoubleAnimation.EasingFunction>
                                                    <CubicEase EasingMode="EaseOut"/>
                                                </DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                            <ColorAnimation Storyboard.TargetName="Track"
                                                            Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)"
                                                            To="#FFFFFF" Duration="0:0:0.15"/>
                                            <ColorAnimation Storyboard.TargetName="Track"
                                                            Storyboard.TargetProperty="(Border.BorderBrush).(SolidColorBrush.Color)"
                                                            To="#FFFFFF" Duration="0:0:0.15"/>
                                            <ColorAnimation Storyboard.TargetName="Thumb"
                                                            Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)"
                                                            To="#1A1C23" Duration="0:0:0.15"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Thumb"
                                                             Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)"
                                                             To="0" Duration="0:0:0.18">
                                                <DoubleAnimation.EasingFunction>
                                                    <CubicEase EasingMode="EaseOut"/>
                                                </DoubleAnimation.EasingFunction>
                                            </DoubleAnimation>
                                            <ColorAnimation Storyboard.TargetName="Track"
                                                            Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)"
                                                            To="#00000000" Duration="0:0:0.15"/>
                                            <ColorAnimation Storyboard.TargetName="Track"
                                                            Storyboard.TargetProperty="(Border.BorderBrush).(SolidColorBrush.Color)"
                                                            To="#38FFFFFF" Duration="0:0:0.15"/>
                                            <ColorAnimation Storyboard.TargetName="Thumb"
                                                            Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)"
                                                            To="#9E9E9E" Duration="0:0:0.15"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
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
                                              Margin="13,1.5,0,0"/>
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
                                   VerticalOffset="6"
                                   PopupAnimation="None"
                                   AllowsTransparency="True"
                                   StaysOpen="False"
                                   Focusable="False">
                                <Border Background="#1a1a1a" BorderBrush="#20FFFFFF" BorderThickness="1" CornerRadius="8" Margin="0,2,0,8" MinWidth="{TemplateBinding ActualWidth}" Padding="4">
                                    <ScrollViewer CanContentScroll="False" MaxHeight="260" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden">
                                        <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="Tag" Value="{x:Null}">
                                <Setter TargetName="IconSite" Property="Visibility" Value="Collapsed"/>
                                <Setter TargetName="ContentSite" Property="Margin" Value="14,0,34,0"/>
                            </Trigger>
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
                                <ContentPresenter Content="{TemplateBinding Tag}" IsHitTestVisible="False" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="13,1.5,0,0"/>
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
            <Setter Property="SnapsToDevicePixels" Value="True"/>
            <Setter Property="OverridesDefaultStyle" Value="True"/>
            <Setter Property="HasDropShadow" Value="False"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="Foreground" Value="#E0E0E0"/>
            <Setter Property="FontSize" Value="13.5"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToolTip">
                        <Border Margin="8" Background="#1E1F24" BorderBrush="#25FFFFFF" BorderThickness="1" CornerRadius="8" Padding="12,8,14,8">
                            <Border.Effect>
                                <DropShadowEffect BlurRadius="12" Opacity="0.5" ShadowDepth="3" Direction="270" Color="#000000"/>
                            </Border.Effect>
                            <ContentPresenter/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>


        <Style x:Key="CaptionButtonStyle" TargetType="Button">
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Width" Value="46"/>
            <Setter Property="Height" Value="32"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="BgBorder" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BgBorder" Property="Background" Value="#25FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BgBorder" Property="Background" Value="#35FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="CaptionCloseButtonStyle" TargetType="Button">
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Width" Value="46"/>
            <Setter Property="Height" Value="32"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="BgBorder" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BgBorder" Property="Background" Value="#E81123"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BgBorder" Property="Background" Value="#C4101F"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Name="WindowRootGrid">
        <Grid.Style>
            <Style TargetType="Grid">
                <Setter Property="Margin" Value="0"/>
                <Style.Triggers>
                    <DataTrigger Binding="{Binding WindowState, RelativeSource={RelativeSource AncestorType=Window}}" Value="Maximized">
                        <Setter Property="Margin" Value="8"/>
                    </DataTrigger>
                </Style.Triggers>
            </Style>
        </Grid.Style>
        <!-- Top-right custom window caption buttons (Minimize, Maximize/Restore, Close) -->
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Panel.ZIndex="999" shell:WindowChrome.IsHitTestVisibleInChrome="True">
            <Button Name="CaptionMinBtn" Style="{StaticResource CaptionButtonStyle}" ToolTip="Minimize">
                <TextBlock Text="&#xE921;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="#CCCCCC"/>
            </Button>
            <Button Name="CaptionMaxBtn" Style="{StaticResource CaptionButtonStyle}" ToolTip="Restore">
                <TextBlock Name="CaptionMaxIcon" Text="&#xE923;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="#CCCCCC"/>
            </Button>
            <Button Name="CaptionCloseBtn" Style="{StaticResource CaptionCloseButtonStyle}" ToolTip="Close">
                <TextBlock Text="&#xE8BB;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="#CCCCCC"/>
            </Button>
        </StackPanel>

        <Grid Name="MainContent" Margin="24,20,24,16">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Grid Name="HeaderGrid" Margin="0,0,0,16">
                <!-- Center: 2-Tier Floating Control Deck (Tabs on Top, Action Controls Below) -->
                <Border Name="ControlDeckCard" HorizontalAlignment="Center" VerticalAlignment="Center"
                        Background="Transparent" BorderThickness="0" Padding="0"
                        shell:WindowChrome.IsHitTestVisibleInChrome="True">
                    <StackPanel Orientation="Vertical" HorizontalAlignment="Center" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                        
                        <!-- Tier 1: Source Toggle Pill (Matches HeaderActionPill width responsively) -->
                        <Border Name="SourceTogglePill" HorizontalAlignment="Center" VerticalAlignment="Center" Height="41"
                                Width="{Binding ActualWidth, ElementName=HeaderActionPill}"
                                Background="Transparent" BorderBrush="#15FFFFFF" BorderThickness="1" CornerRadius="8" Padding="3"
                                shell:WindowChrome.IsHitTestVisibleInChrome="True">
                            <Grid shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Grid Grid.Column="0" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                    <Border Name="SourceBingIndicator" Background="#25FFFFFF" CornerRadius="5" Opacity="1" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                    <Button Name="SourceBingBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand" HorizontalAlignment="Stretch" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                        <TextBlock Name="SourceBingLabel" Text="Bing" FontSize="13.5" FontWeight="SemiBold" Foreground="#FFFFFF" HorizontalAlignment="Center" Margin="0,7,0,8"/>
                                    </Button>
                                </Grid>
                                <Grid Grid.Column="1" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                    <Border Name="SourceSpotlightIndicator" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                    <Button Name="SourceSpotlightBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand" HorizontalAlignment="Stretch" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                        <TextBlock Name="SourceSpotlightLabel" Text="Spotlight" FontSize="13.5" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,7,0,8"/>
                                    </Button>
                                </Grid>
                                <Grid Grid.Column="2" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                    <Border Name="SourceWallhavenIndicator" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                    <Button Name="SourceWallhavenBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand" HorizontalAlignment="Stretch" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                        <TextBlock Name="SourceWallhavenLabel" Text="Wallhaven" FontSize="13.5" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,7,0,8"/>
                                    </Button>
                                </Grid>
                                <Grid Grid.Column="3" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                    <Border Name="SourcePexelsIndicator" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                    <Button Name="SourcePexelsBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand" HorizontalAlignment="Stretch" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                        <TextBlock Name="SourcePexelsLabel" Text="Pexels" FontSize="13.5" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,7,0,8"/>
                                    </Button>
                                </Grid>
                                <Grid Grid.Column="4" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                    <Border Name="SourceLocalIndicator" Background="#25FFFFFF" CornerRadius="5" Opacity="0" BorderBrush="#10FFFFFF" BorderThickness="1"/>
                                    <Button Name="SourceLocalBtn" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand" HorizontalAlignment="Stretch" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                        <TextBlock Name="SourceLocalLabel" Text="Local" FontSize="13.5" FontWeight="SemiBold" Foreground="#9E9E9E" HorizontalAlignment="Center" Margin="0,7,0,8"/>
                                    </Button>
                                </Grid>
                            </Grid>
                        </Border>

                        <Border Name="HeaderActionPill" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,10,0,0" Height="41"
                                Background="Transparent" BorderBrush="#15FFFFFF" BorderThickness="1" CornerRadius="8" Padding="3"
                                shell:WindowChrome.IsHitTestVisibleInChrome="True">
                            <StackPanel Name="HeaderActionRow" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center"
                                        shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                
                                <!-- Refresh gallery button (left) -->
                                <Button Name="RefreshBtn" Style="{StaticResource ModernIconButton}" BorderThickness="0" Width="36" Height="33" Padding="0" Margin="0" ToolTip="Refresh Gallery (F5)" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                    <TextBlock Name="RefreshIcon" Text="&#xE72C;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13.5"
                                               Foreground="#9E9E9E"
                                               HorizontalAlignment="Center" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
                                        <TextBlock.RenderTransform>
                                            <RotateTransform Angle="0"/>
                                        </TextBlock.RenderTransform>
                                    </TextBlock>
                                </Button>

                                

                                <!-- Automation unified pill button (middle) -->
                                <Button Name="AutoUnifiedButton" Style="{StaticResource ModernIconButton}" BorderThickness="0" Height="33" Padding="0,0,6,0" Margin="0" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                        <TextBlock Name="AutoLabel" Text="Auto" FontSize="13.5" FontWeight="SemiBold" Foreground="#9E9E9E" VerticalAlignment="Center" Margin="12,0,8,0"/>

                                        <CheckBox Name="AutoToggleCheckbox" Style="{StaticResource AutoToggleSwitchStyle}" IsChecked="False" IsHitTestVisible="False" VerticalAlignment="Center" Margin="0,0,4,0"/>
                
                                        <Button Name="SpotlightSetBtn" Width="26" Height="26" Margin="0,0,3,0" VerticalAlignment="Center"
                                                Cursor="Hand" IsEnabled="False" ToolTip="Configure automatic wallpaper changes"
                                                Background="Transparent" BorderBrush="Transparent" BorderThickness="0" Foreground="#777"
                                                shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                            <Button.Style>
                                                <Style TargetType="Button">
                                                    <Setter Property="Template">
                                                        <Setter.Value>
                                                            <ControlTemplate TargetType="Button">
                                                                <Border Name="ChevronBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
                                                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                                                </Border>
                                                                <ControlTemplate.Triggers>
                                                                    <Trigger Property="IsEnabled" Value="True">
                                                                        <Setter Property="Foreground" Value="#FFFFFF"/>
                                                                    </Trigger>
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

                                

                                <!-- Preferences button (right) -->
                                <Button Name="FiltersBtn" Style="{StaticResource ModernIconButton}" BorderThickness="0" Height="33" Padding="14,0,16,0" ToolTip="Preferences" Margin="0" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                        <TextBlock Text="&#xE771;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" Foreground="#9E9E9E" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                        <TextBlock Name="FiltersBtnText" Text="Preferences" FontSize="13.5" FontWeight="SemiBold" Foreground="#9E9E9E" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Button>

                                <!-- Archive Search button (right of Preferences) -->
                                <Button Name="ArchiveSearchBtn" Style="{StaticResource ModernIconButton}" BorderThickness="0" Height="33" Padding="14,0,16,0" ToolTip="Search Bing Wallpapers by Date" Margin="0" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center" shell:WindowChrome.IsHitTestVisibleInChrome="True">
                                        <TextBlock Text="&#xE787;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13.5" Foreground="#9E9E9E" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                        <TextBlock Name="ArchiveSearchBtnText" Text="Archive Search" FontSize="13.5" FontWeight="SemiBold" Foreground="#9E9E9E" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Button>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </Border>
            </Grid>

            <!-- Spotlight Automation Options Popup -->
            <Popup Name="SpotlightOptionsPopup" PlacementTarget="{Binding ElementName=AutoUnifiedButton}"
                   Placement="Bottom" VerticalOffset="16" HorizontalOffset="-180" AllowsTransparency="True" StaysOpen="False"
                   PopupAnimation="None" Focusable="False">
                <Grid Name="SpotlightPopupTransformHost" Margin="0" Background="Transparent" RenderTransformOrigin="0.5,0.5">
                    <Grid.RenderTransform>
                        <TranslateTransform x:Name="SpotlightPopupTransform" Y="0"/>
                    </Grid.RenderTransform>
                    <Border Name="SpotlightPopupCard" Background="#1a1a1a" BorderBrush="#25FFFFFF" BorderThickness="1"
                            CornerRadius="10" Padding="18" Width="490" Opacity="0" SnapsToDevicePixels="False">
                        <StackPanel>
                            <TextBlock Text="Choose your wallpaper source" FontSize="14" FontWeight="SemiBold" Foreground="#FAFAFA" Margin="0,0,0,14"/>
                            
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

            <!-- Filters & Preferences Popup -->
            <Popup Name="FiltersPopup" PlacementTarget="{Binding ElementName=FiltersBtn}"
                   Placement="Bottom" VerticalOffset="16" HorizontalOffset="-180" AllowsTransparency="True" StaysOpen="False"
                   PopupAnimation="None" Focusable="False">
                <Grid Name="FiltersPopupTransformHost" Margin="0" Background="Transparent" RenderTransformOrigin="0.5,0.5">
                    <Grid.RenderTransform>
                        <TranslateTransform x:Name="FiltersPopupTransform" Y="0"/>
                    </Grid.RenderTransform>
                    <Border Name="FiltersPopupCard" Background="#1a1a1a" BorderBrush="#25FFFFFF" BorderThickness="1"
                            CornerRadius="10" Padding="18" Width="440" Opacity="0" SnapsToDevicePixels="False">
                        <!-- Removed DropShadowEffect to prevent gray box background bug -->
                        <StackPanel>
                            <!-- 1. Dynamic Source Section (Region / API Key / Local Folder) -->
                            <StackPanel Name="ColRegion" Margin="0,4,0,14">
                                <TextBlock Name="LabelRegion" Text="Region" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="2,0,0,6"/>
                                <ComboBox Name="RegionBox" HorizontalAlignment="Stretch" FontSize="13" Height="38">
                                    <ComboBox.Tag>
                                        <TextBlock Text="&#xE909;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#9E9E9E"/>
                                    </ComboBox.Tag>
                                </ComboBox>
                                <!-- Universal API Key Grid for Wallhaven, Pexels, etc. -->
                                <Grid Name="ApiKeyGrid" Visibility="Collapsed">
                                    <TextBox Name="ApiKeyBox" HorizontalAlignment="Stretch" FontSize="13" Height="38" Padding="36,0,32,0">
                                        <TextBox.Tag>
                                            <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="#9E9E9E"/>
                                        </TextBox.Tag>
                                    </TextBox>
                                    <TextBlock Name="ApiKeyPlaceholder" Text="Paste API key here" Foreground="#55FFFFFF" 
                                               FontSize="{Binding FontSize, ElementName=ApiKeyBox}" 
                                               IsHitTestVisible="False" VerticalAlignment="Center" Margin="36,-1,32,0"/>
                                    <Button Name="ClearApiKeyBtn" Style="{StaticResource ModernIconButton}" Width="28" Height="28" Padding="0" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,5,0" ToolTip="Clear API Key" Visibility="Collapsed">
                                        <TextBlock Text="&#xE711;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="12.5" Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Button>
                                </Grid>
                                <!-- Local Folder Selection Button -->
                                <Border Name="LocalFolderBorder" Visibility="Collapsed" HorizontalAlignment="Stretch" Height="38" Background="#18FFFFFF" BorderBrush="#25FFFFFF" BorderThickness="1" CornerRadius="6">
                                    <Button Name="LocalFolderBtn" Background="Transparent" BorderThickness="0" Cursor="Hand" HorizontalContentAlignment="Stretch" VerticalContentAlignment="Center" Padding="12,0,10,0">
                                        <Grid>
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="Auto"/>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="#9E9E9E" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                            <TextBlock Name="LocalFolderLabel" Grid.Column="1" Text="Select Folder..." FontSize="13" Foreground="#E0E0E0" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                                            <TextBlock Grid.Column="2" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="#888888" VerticalAlignment="Center" Margin="6,0,0,0"/>
                                        </Grid>
                                    </Button>
                                </Border>
                            </StackPanel>

                            <!-- 2. Display Options: Resolution & Apply To -->
                            <Grid Margin="0,0,0,14">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="14"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Name="ColResolution" Grid.Column="0">
                                    <TextBlock Name="LabelResolution" Text="Resolution" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="2,0,0,6"/>
                                    <ComboBox Name="ResolutionBox" HorizontalAlignment="Stretch" FontSize="13" Height="38">
                                        <ComboBox.Tag>
                                            <TextBlock Text="&#xE8B9;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#9E9E9E"/>
                                        </ComboBox.Tag>
                                    </ComboBox>
                                </StackPanel>

                                <StackPanel Name="ColApplyTo" Grid.Column="2">
                                    <TextBlock Name="LabelApplyTo" Text="Apply To" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="2,0,0,6"/>
                                    <ComboBox Name="TargetBox" HorizontalAlignment="Stretch" FontSize="13" Height="38">
                                        <ComboBox.Tag>
                                            <TextBlock Text="&#xE7F4;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#9E9E9E"/>
                                        </ComboBox.Tag>
                                    </ComboBox>
                                </StackPanel>
                            </Grid>

                            <!-- 3. Style & Download Folder -->
                            <Grid Margin="0,0,0,6">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="14"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Name="ColStyle" Grid.Column="0">
                                    <TextBlock Name="LabelStyle" Text="Style" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="2,0,0,6"/>
                                    <ComboBox Name="StyleBox" HorizontalAlignment="Stretch" FontSize="13" Height="38">
                                        <ComboBox.Tag>
                                            <TextBlock Text="&#xE7A8;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#9E9E9E"/>
                                        </ComboBox.Tag>
                                    </ComboBox>
                                </StackPanel>

                                <StackPanel Name="ColDownloadTo" Grid.Column="2">
                                    <TextBlock Name="LabelDownloadTo" Text="Download Folder" FontSize="13" FontWeight="SemiBold" Foreground="White" Margin="2,0,0,6" TextTrimming="CharacterEllipsis"/>
                                    <TextBox Name="FolderBox" HorizontalAlignment="Stretch" Height="38" FontSize="13" IsReadOnly="True" Cursor="Hand">
                                        <TextBox.Tag>
                                            <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#9E9E9E"/>
                                        </TextBox.Tag>
                                    </TextBox>
                                </StackPanel>
                            </Grid>
                        </StackPanel>
                    </Border>
                </Grid>
            </Popup>

            <!-- Archive & Date Search Popup -->
            <Popup Name="ArchiveSearchPopup" PlacementTarget="{Binding ElementName=ArchiveSearchBtn}"
                   Placement="Bottom" VerticalOffset="16" HorizontalOffset="-180" AllowsTransparency="True" StaysOpen="False"
                   PopupAnimation="None" Focusable="False">
                <Grid Name="ArchiveSearchPopupTransformHost" Margin="0" Background="Transparent" RenderTransformOrigin="0.5,0.5">
                    <Grid.RenderTransform>
                        <TranslateTransform x:Name="ArchiveSearchPopupTransform" Y="0"/>
                    </Grid.RenderTransform>
                    <Border Name="ArchiveSearchPopupCard" Background="#1a1a1a" BorderBrush="#25FFFFFF" BorderThickness="1"
                            CornerRadius="10" Padding="18" Width="430" Opacity="0" SnapsToDevicePixels="False">
                        <StackPanel>
                            <!-- Header -->
                            <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,0,14">
                                <TextBlock Text="&#xE787;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#60CDFF" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                <TextBlock Text="Search Bing wallpapers by date" FontSize="14" FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"/>
                            </StackPanel>

                            <!-- Scope Selector Tabs -->
                            <Border Background="#20FFFFFF" BorderBrush="#15FFFFFF" BorderThickness="1" CornerRadius="7" Padding="2.5" Margin="0,0,0,12">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Grid Grid.Column="0">
                                        <Border Name="ScopeDayIndicator" Background="#28FFFFFF" CornerRadius="5" Opacity="1"/>
                                        <Button Name="ScopeDayBtn" Background="Transparent" BorderThickness="0" Cursor="Hand" Height="30">
                                            <TextBlock Name="ScopeDayLabel" Text="Specific Day" FontSize="12" FontWeight="SemiBold" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Button>
                                    </Grid>
                                    <Grid Grid.Column="1">
                                        <Border Name="ScopeMonthIndicator" Background="#28FFFFFF" CornerRadius="5" Opacity="0"/>
                                        <Button Name="ScopeMonthBtn" Background="Transparent" BorderThickness="0" Cursor="Hand" Height="30">
                                            <TextBlock Name="ScopeMonthLabel" Text="Full Month" FontSize="12" FontWeight="SemiBold" Foreground="#888888" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Button>
                                    </Grid>
                                    <Grid Grid.Column="2">
                                        <Border Name="ScopeYearIndicator" Background="#28FFFFFF" CornerRadius="5" Opacity="0"/>
                                        <Button Name="ScopeYearBtn" Background="Transparent" BorderThickness="0" Cursor="Hand" Height="30">
                                            <TextBlock Name="ScopeYearLabel" Text="Full Year" FontSize="12" FontWeight="SemiBold" Foreground="#888888" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Button>
                                    </Grid>
                                </Grid>
                            </Border>

                            <!-- Date Selection Controls (Year, Month, Day) & Year-mode Region Host -->
                            <Grid Margin="0,0,0,12">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Name="ColArchiveYear" Width="*"/>
                                    <ColumnDefinition Name="ColArchiveMonthGap" Width="10"/>
                                    <ColumnDefinition Name="ColArchiveMonth" Width="1.2*"/>
                                    <ColumnDefinition Name="ColArchiveDayGap" Width="10"/>
                                    <ColumnDefinition Name="ColArchiveDay" Width="*"/>
                                </Grid.ColumnDefinitions>

                                <!-- Year -->
                                <StackPanel Grid.Column="0">
                                    <TextBlock Text="Year" FontSize="12" FontWeight="SemiBold" Foreground="#FFFFFF" Margin="2,0,0,5"/>
                                    <ComboBox Name="ArchiveYearBox" HorizontalAlignment="Stretch" FontSize="13" Height="38"/>
                                </StackPanel>

                                <!-- Month -->
                                <StackPanel Name="StackArchiveMonth" Grid.Column="2">
                                    <TextBlock Text="Month" FontSize="12" FontWeight="SemiBold" Foreground="#FFFFFF" Margin="2,0,0,5"/>
                                    <ComboBox Name="ArchiveMonthBox" HorizontalAlignment="Stretch" FontSize="13" Height="38"/>
                                </StackPanel>

                                <!-- Day -->
                                <StackPanel Name="StackArchiveDay" Grid.Column="4">
                                    <TextBlock Text="Day" FontSize="12" FontWeight="SemiBold" Foreground="#FFFFFF" Margin="2,0,0,5"/>
                                    <ComboBox Name="ArchiveDayBox" HorizontalAlignment="Stretch" FontSize="13" Height="38"/>
                                </StackPanel>

                                <!-- Top Region Host (Used in Full Year mode) -->
                                <Grid Name="RegionTopHost" Grid.Column="2" Grid.ColumnSpan="3" Visibility="Collapsed"/>
                            </Grid>

                            <!-- Full Year Notice (Shown only when Full Year mode is active) -->
                            <StackPanel Name="ArchiveYearNotice" Visibility="Collapsed" Margin="2,0,0,12">
                                <TextBlock Text="Unstable" FontSize="12" FontWeight="Bold" Foreground="#FFA048" Margin="0,0,0,2"/>
                                <TextBlock Text="might take a few minutes to load all wallpapers." FontSize="11" Foreground="#AAAAAA"/>
                            </StackPanel>

                            <!-- Bottom Row: Region & Search Button (Day/Month modes) or Full-width Search (Year mode) -->
                            <Grid Name="ArchiveBottomRow" Margin="0,0,0,2">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Name="ColBottomRegion" Width="*"/>
                                    <ColumnDefinition Name="ColBottomGap" Width="10"/>
                                    <ColumnDefinition Name="ColBottomSearch" Width="130"/>
                                </Grid.ColumnDefinitions>

                                <!-- Bottom Region Host (Used in Day and Month modes) -->
                                <Grid Name="RegionBottomHost" Grid.Column="0">
                                    <StackPanel Name="StackArchiveRegion">
                                        <TextBlock Text="Region" FontSize="12" FontWeight="SemiBold" Foreground="#FFFFFF" Margin="2,0,0,5"/>
                                        <ComboBox Name="ArchiveRegionBox" HorizontalAlignment="Stretch" FontSize="13" Height="38"/>
                                    </StackPanel>
                                </Grid>

                                <!-- Search Action Button -->
                                <Button Name="FetchArchiveBtn" Grid.Column="2" Height="38" VerticalAlignment="Bottom" Background="#0078D4" BorderThickness="0" Cursor="Hand" HorizontalAlignment="Stretch">
                                    <Button.Resources>
                                        <Style TargetType="Border">
                                            <Setter Property="CornerRadius" Value="6"/>
                                        </Style>
                                    </Button.Resources>
                                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                                        <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="13.5" Foreground="#FFFFFF" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                        <TextBlock Name="FetchArchiveBtnText" Text="Search" FontSize="13" FontWeight="Bold" Foreground="#FFFFFF" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Button>
                            </Grid>
                        </StackPanel>
                    </Border>
                </Grid>
            </Popup>

            <Grid Grid.Row="1" Name="ToolbarWrap" Visibility="Collapsed" Height="0" />

            <Border Grid.Row="2" Background="Transparent" CornerRadius="18" BorderThickness="0" ClipToBounds="True" VerticalAlignment="Center">
                <Grid>
                    <ScrollViewer Name="GalleryScrollViewer" CanContentScroll="False" Margin="0,16,0,16" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" VerticalAlignment="Center" FocusVisualStyle="{x:Null}">
                        <UniformGrid Name="GalleryPanel" Columns="4" VerticalAlignment="Center" />
                    </ScrollViewer>
                    <!-- Centered Empty State for Local Tab when no folder is selected -->
                    <Border Name="LocalEmptyStatePanel" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,40,0,40">
                        <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                            <Border Width="72" Height="72" CornerRadius="36" Background="#14FFFFFF" BorderBrush="#20FFFFFF" BorderThickness="1" HorizontalAlignment="Center" Margin="0,0,0,16">
                                <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="32" Foreground="#88FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
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
                                    <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="White" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                    <TextBlock Text="Select a Local Folder" VerticalAlignment="Center"/>
                                </StackPanel>
                            </Button>
                        </StackPanel>
                    </Border>

                    <!-- Centered Empty State for Pexels Tab when no API key is configured -->
                    <Border Name="PexelsEmptyStatePanel" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,40,0,40">
                        <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="440">
                            <Border Width="72" Height="72" CornerRadius="36" Background="#14FFFFFF" BorderBrush="#20FFFFFF" BorderThickness="1" HorizontalAlignment="Center" Margin="0,0,0,16">
                                <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="30" Foreground="#88FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <TextBlock Text="Pexels API Key Required" FontSize="18" FontWeight="SemiBold" Foreground="White" HorizontalAlignment="Center" Margin="0,0,0,6"/>
                            <TextBlock Text="Get a free instant API key from Pexels to browse 4K nature photography" FontSize="13" Foreground="#9E9E9E" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" Margin="0,0,0,20"/>
                            
                            <Grid HorizontalAlignment="Center" Margin="0,0,0,14" Width="360">
                                <TextBox Name="PexelsEmptyKeyBox" Height="40" FontSize="13" HorizontalAlignment="Stretch" Padding="38,0,14,0">
                                    <TextBox.Tag>
                                        <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="#9E9E9E"/>
                                    </TextBox.Tag>
                                </TextBox>
                                <TextBlock Name="PexelsEmptyKeyPlaceholder" Text="Paste Pexels API key here..." Foreground="#55FFFFFF" 
                                           FontSize="13" IsHitTestVisible="False" VerticalAlignment="Center" Margin="40,0,14,0"/>
                            </Grid>

                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                                <Button Name="PexelsEmptySaveBtn" Height="40" Padding="20,0,20,0" Background="#20FFFFFF" BorderBrush="#35FFFFFF" BorderThickness="1" Foreground="White" FontSize="13.5" FontWeight="SemiBold" Cursor="Hand" Margin="0,0,10,0">
                                    <Button.Resources>
                                        <Style TargetType="Border">
                                            <Setter Property="CornerRadius" Value="8"/>
                                        </Style>
                                    </Button.Resources>
                                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                        <TextBlock Text="&#xE74E;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="White" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                        <TextBlock Text="Save Key" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Button>

                                <Button Name="PexelsEmptyGetBtn" Height="40" Padding="16,0,16,0" Background="#12FFFFFF" BorderBrush="#20FFFFFF" BorderThickness="1" Foreground="#E0E0E0" FontSize="13.5" Cursor="Hand">
                                    <Button.Resources>
                                        <Style TargetType="Border">
                                            <Setter Property="CornerRadius" Value="8"/>
                                        </Style>
                                    </Button.Resources>
                                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                        <TextBlock Text="&#xE8A7;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="#AAA" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                        <TextBlock Text="Get Free Key" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Button>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                </Grid>
            </Border>

            <Grid Grid.Row="3" Margin="0,16,16,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="StatusText" Text="" Foreground="#888" FontSize="14" FontWeight="Medium" VerticalAlignment="Center" TextWrapping="Wrap" Margin="14,0,16,0"/>
                
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
    $parentDir = Split-Path -Parent $scriptDir
    $candidates = @(
        (Join-Path $scriptDir 'assets\app.ico'),
        (Join-Path $scriptDir 'app.ico'),
        (Join-Path $parentDir 'assets\app.ico'),
        (Join-Path $parentDir 'app.ico'),
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

if (-not ('AutoScapeChromeHelper' -as [type])) {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;

public static class AutoScapeChromeHelper
{
    private const int WM_GETMINMAXINFO = 0x0024;
    private const uint MONITOR_DEFAULTTONEAREST = 0x00000002;

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr LoadImage(IntPtr hinst, string lpszName, uint uType, int cxDesired, int cyDesired, uint fuLoad);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MINMAXINFO
    {
        public POINT ptReserved;
        public POINT ptMaxSize;
        public POINT ptMaxPosition;
        public POINT ptMinTrackSize;
        public POINT ptMaxTrackSize;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct RECT
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    public const uint WM_SETICON = 0x0080;
    public const uint IMAGE_ICON = 1;
    public const uint LR_LOADFROMFILE = 0x0010;
    public const uint LR_DEFAULTSIZE = 0x0040;

    private const int GWL_STYLE = -16;
    private const int WS_CAPTION = 0x00C00000;
    private const int WS_MINIMIZEBOX = 0x00020000;
    private const int WS_MAXIMIZEBOX = 0x00010000;
    private const int WS_SYSMENU = 0x00080000;

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hwnd, int index);

    [DllImport("user32.dll")]
    private static extern int SetWindowLong(IntPtr hwnd, int index, int newStyle);

    public static void EnableWindowAnimations(IntPtr hwnd)
    {
        try {
            int style = GetWindowLong(hwnd, GWL_STYLE);
            SetWindowLong(hwnd, GWL_STYLE, style | WS_CAPTION | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU);
        } catch {}
    }

    public static void Attach(IntPtr hwnd)
    {
        try {
            EnableWindowAnimations(hwnd);
            HwndSource source = HwndSource.FromHwnd(hwnd);
            if (source != null)
            {
                source.AddHook(new HwndSourceHook(HookProc));
            }
        } catch {}
    }

    public static IntPtr HookProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_GETMINMAXINFO)
        {
            try {
                IntPtr hMonitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
                if (hMonitor != IntPtr.Zero)
                {
                    MONITORINFO mi = new MONITORINFO();
                    mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                    if (GetMonitorInfo(hMonitor, ref mi))
                    {
                        MINMAXINFO mmi = (MINMAXINFO)Marshal.PtrToStructure(lParam, typeof(MINMAXINFO));
                        
                        mmi.ptMaxPosition.x = Math.Abs(mi.rcWork.left - mi.rcMonitor.left);
                        mmi.ptMaxPosition.y = Math.Abs(mi.rcWork.top - mi.rcMonitor.top);
                        mmi.ptMaxSize.x = Math.Abs(mi.rcWork.right - mi.rcWork.left);
                        mmi.ptMaxSize.y = Math.Abs(mi.rcWork.bottom - mi.rcWork.top);
                        mmi.ptMaxTrackSize.x = mmi.ptMaxSize.x;
                        mmi.ptMaxTrackSize.y = mmi.ptMaxSize.y;

                        Marshal.StructureToPtr(mmi, lParam, true);
                        handled = true;
                    }
                }
            } catch {}
        }
        return IntPtr.Zero;
    }

    public static void ApplyAppIcon(IntPtr hwnd, string iconPath)
    {
        try {
            if (!string.IsNullOrEmpty(iconPath) && System.IO.File.Exists(iconPath))
            {
                // 1. Big icon (32x32 / 48x48) for Taskbar button and Alt+Tab
                IntPtr hBigIcon = LoadImage(IntPtr.Zero, iconPath, IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE);
                if (hBigIcon != IntPtr.Zero)
                {
                    SendMessage(hwnd, WM_SETICON, new IntPtr(1), hBigIcon);
                }

                // 2. Small icon (16x16) for Taskbar hover preview header and Alt+Tab corner badge
                IntPtr hSmallIcon = LoadImage(IntPtr.Zero, iconPath, IMAGE_ICON, 16, 16, LR_LOADFROMFILE);
                if (hSmallIcon != IntPtr.Zero)
                {
                    SendMessage(hwnd, WM_SETICON, new IntPtr(0), hSmallIcon);
                }
            }
        } catch {}
    }
}
"@ -ReferencedAssemblies WindowsBase, PresentationCore, PresentationFramework -ErrorAction SilentlyContinue
    } catch {}
}

$applyDarkTitleBar = {
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        if ($helper.Handle -ne [IntPtr]::Zero) {
            try { [AutoScapeChromeHelper]::Attach($helper.Handle) } catch {}
            try { [AutoScapeChromeHelper]::ApplyAppIcon($helper.Handle, $script:taskbarIconPath) } catch {}
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

$WindowRootGrid = $window.FindName('WindowRootGrid')
function Update-MaximizedLayout {
    if ($WindowRootGrid) {
        $isMax = ($window.WindowState -eq [System.Windows.WindowState]::Maximized)
        $WindowRootGrid.Margin = if ($isMax) { [System.Windows.Thickness]::new(8) } else { [System.Windows.Thickness]::new(0) }
    }
}

$window.Add_StateChanged({
        Update-MaximizedLayout
        if ($script:activeModalControl) {
            Close-InWindowModal
        }
        if ($script:activeDialogModalControl) {
            Close-DialogModal
        }
        if ($CaptionMaxIcon) {
            $isMax = ($window.WindowState -eq [System.Windows.WindowState]::Maximized)
            $CaptionMaxIcon.Text = if ($isMax) { [char]0xE923 } else { [char]0xE922 }
            if ($CaptionMaxBtn) { $CaptionMaxBtn.ToolTip = if ($isMax) { 'Restore' } else { 'Maximize' } }
        }
    })
Update-MaximizedLayout
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
            Region                = if ($RegionBox.SelectedItem) { $RegionBox.SelectedItem.Tag } else { "auto" }
            Resolution            = if ($ResolutionBox.SelectedItem) { $ResolutionBox.SelectedItem } else { "4K" }
            Target                = if ($TargetBox.SelectedItem) { $TargetBox.SelectedItem } else { "Both" }
            Style                 = if ($StyleBox.SelectedItem) { $StyleBox.SelectedItem } else { "Fit" }
            SaveFolder            = $script:DownloadFolderPath
            AutoDesktopSource     = if ($AutoDesktopSourceBox -and $AutoDesktopSourceBox.SelectedItem) { [string]$AutoDesktopSourceBox.SelectedItem } else { 'Bing' }
            AutoLockScreenSource  = if ($AutoLockScreenSourceBox -and $AutoLockScreenSourceBox.SelectedItem) { [string]$AutoLockScreenSourceBox.SelectedItem } else { 'Bing' }
            AutoSchedule          = if ($AutoScheduleBox -and $AutoScheduleBox.SelectedItem) { [string]$AutoScheduleBox.SelectedItem.Tag } else { 'Daily' }
            SpotlightEnabled      = [bool]$script:SpotlightEnabled
            WallhavenApiKey       = (Get-SourceApiKey 'Wallhaven')
            PexelsApiKey          = (Get-SourceApiKey 'Pexels')
            LocalFolderPath       = if ($script:localFolderPath) { $script:localFolderPath } elseif ($existing -and $existing.LocalFolderPath) { [string]$existing.LocalFolderPath } else { '' }
            LastAutoAppliedDate   = if ($existing -and $existing.LastAutoAppliedDate) { [string]$existing.LastAutoAppliedDate } else { '' }
            LastAutoDesktopSource = if ($existing -and $existing.LastAutoDesktopSource) { [string]$existing.LastAutoDesktopSource } else { '' }
            LastAutoLockSource    = if ($existing -and $existing.LastAutoLockSource) { [string]$existing.LastAutoLockSource } else { '' }
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
        if (-not $targetElement.ToolTip.Style -and $window -and $window.Resources -and $window.Resources.Contains([System.Windows.Controls.ToolTip])) {
            $targetElement.ToolTip.Style = $window.Resources[[System.Windows.Controls.ToolTip]]
        }
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
$FiltersBtn = $window.FindName('FiltersBtn')
$FiltersBtnText = $window.FindName('FiltersBtnText')
Enable-StrictToolTipDelay $FiltersBtn
$FiltersPopup = $window.FindName('FiltersPopup')
$FiltersPopupCard = $window.FindName('FiltersPopupCard')
$FiltersPopupTransform = $window.FindName('FiltersPopupTransform')

# --- Archive Search Controls ---
$ArchiveSearchBtn = $window.FindName('ArchiveSearchBtn')
$ArchiveSearchBtnText = $window.FindName('ArchiveSearchBtnText')
Enable-StrictToolTipDelay $ArchiveSearchBtn
$ArchiveSearchPopup = $window.FindName('ArchiveSearchPopup')
$ArchiveSearchPopupCard = $window.FindName('ArchiveSearchPopupCard')
$ArchiveSearchPopupTransform = $window.FindName('ArchiveSearchPopupTransform')

$ScopeDayBtn = $window.FindName('ScopeDayBtn')
$ScopeMonthBtn = $window.FindName('ScopeMonthBtn')
$ScopeYearBtn = $window.FindName('ScopeYearBtn')
$ScopeDayIndicator = $window.FindName('ScopeDayIndicator')
$ScopeMonthIndicator = $window.FindName('ScopeMonthIndicator')
$ScopeYearIndicator = $window.FindName('ScopeYearIndicator')
$ScopeDayLabel = $window.FindName('ScopeDayLabel')
$ScopeMonthLabel = $window.FindName('ScopeMonthLabel')
$ScopeYearLabel = $window.FindName('ScopeYearLabel')

$StackArchiveMonth = $window.FindName('StackArchiveMonth')
$StackArchiveDay = $window.FindName('StackArchiveDay')
$ArchiveYearNotice = $window.FindName('ArchiveYearNotice')

$ArchiveYearBox = $window.FindName('ArchiveYearBox')
$ArchiveMonthBox = $window.FindName('ArchiveMonthBox')
$ArchiveDayBox = $window.FindName('ArchiveDayBox')
$ArchiveRegionBox = $window.FindName('ArchiveRegionBox')
$FetchArchiveBtn = $window.FindName('FetchArchiveBtn')
$FetchArchiveBtnText = $window.FindName('FetchArchiveBtnText')

# Populate Archive dropdowns
if ($ArchiveYearBox) {
    $curYr = [DateTime]::Now.Year
    for ($y = $curYr; $y -ge 2010; $y--) {
        [void]$ArchiveYearBox.Items.Add($y.ToString())
    }
    $ArchiveYearBox.SelectedIndex = 0
}

if ($ArchiveMonthBox) {
    $archiveMonths = @(
        'January', 'February', 'March', 'April',
        'May', 'June', 'July', 'August',
        'September', 'October', 'November', 'December'
    )
    foreach ($mName in $archiveMonths) {
        [void]$ArchiveMonthBox.Items.Add($mName)
    }
    $ArchiveMonthBox.SelectedIndex = [Math]::Max(0, [DateTime]::Now.Month - 1)
}

if ($ArchiveDayBox) {
    for ($d = 1; $d -le 31; $d++) {
        [void]$ArchiveDayBox.Items.Add($d.ToString("00"))
    }
    $ArchiveDayBox.SelectedIndex = [Math]::Max(0, [DateTime]::Now.Day - 1)
}

if ($ArchiveRegionBox) {
    $peapixRegions = @(
        @{ Name = 'United States'; Code = 'us' },
        @{ Name = 'United Kingdom'; Code = 'gb' },
        @{ Name = 'Canada'; Code = 'ca' },
        @{ Name = 'Germany'; Code = 'de' },
        @{ Name = 'France'; Code = 'fr' },
        @{ Name = 'India'; Code = 'in' },
        @{ Name = 'Japan'; Code = 'jp' },
        @{ Name = 'China'; Code = 'cn' },
        @{ Name = 'Italy'; Code = 'it' },
        @{ Name = 'Spain'; Code = 'es' },
        @{ Name = 'Brazil'; Code = 'br' },
        @{ Name = 'Australia'; Code = 'au' }
    )
    foreach ($pReg in $peapixRegions) {
        $cbItem = New-Object System.Windows.Controls.ComboBoxItem
        $cbItem.Content = $pReg.Name
        $cbItem.Tag = $pReg.Code
        [void]$ArchiveRegionBox.Items.Add($cbItem)
    }
    $ArchiveRegionBox.SelectedIndex = 0
}
$LabelRegion = $window.FindName('LabelRegion')
$RefreshBtn = $window.FindName('RefreshBtn')
Enable-StrictToolTipDelay $RefreshBtn
$RefreshIcon = $window.FindName('RefreshIcon')

function Update-FiltersBtnText {
    if ($FiltersBtnText) {
        $FiltersBtnText.Text = "Preferences"
    }
}
$GalleryPanel = $window.FindName('GalleryPanel')
$GalleryScrollViewer = $window.FindName('GalleryScrollViewer')
if ($GalleryScrollViewer -and ('AutoScapeSmoothScroll' -as [type])) {
    [AutoScapeSmoothScroll]::Attach($GalleryScrollViewer)
}
$StatusText = $window.FindName('StatusText')
$script:StatusText = $StatusText
$InfoBtn = $window.FindName('InfoBtn')
Enable-StrictToolTipDelay $InfoBtn
# CheckUpdateBtn no longer lives in the main toolbar - it now lives inside the
# User Guide modal's footer (see Show-UserGuideDialog) and this variable is
# (re)pointed at that inner button each time the modal is built.
$CheckUpdateBtn = $null
$DownloadBtn = $window.FindName('DownloadBtn')
$UpdateBtn = $window.FindName('UpdateBtn')
$script:UpdateBtn = $UpdateBtn

$CaptionMinBtn = $window.FindName('CaptionMinBtn')
$CaptionMaxBtn = $window.FindName('CaptionMaxBtn')
$CaptionCloseBtn = $window.FindName('CaptionCloseBtn')
$CaptionMaxIcon = $window.FindName('CaptionMaxIcon')

if ($CaptionMinBtn) {
    $CaptionMinBtn.Add_Click({ [System.Windows.SystemCommands]::MinimizeWindow($window) })
}
if ($CaptionMaxBtn) {
    $CaptionMaxBtn.Add_Click({
        if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
            [System.Windows.SystemCommands]::RestoreWindow($window)
        } else {
            [System.Windows.SystemCommands]::MaximizeWindow($window)
        }
    })
}
if ($CaptionCloseBtn) {
    $CaptionCloseBtn.Add_Click({ [System.Windows.SystemCommands]::CloseWindow($window) })
}

$HeaderGrid = $window.FindName('HeaderGrid')
if ($HeaderGrid) {
    $HeaderGrid.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($e.OriginalSource -and ($e.OriginalSource -is [System.Windows.Controls.Button] -or $e.OriginalSource -is [System.Windows.Controls.Primitives.ButtonBase])) { return }
        if ($e.ClickCount -ge 2) {
            if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
                [System.Windows.SystemCommands]::RestoreWindow($window)
            } else {
                [System.Windows.SystemCommands]::MaximizeWindow($window)
            }
        }
        else {
            try { $window.DragMove() } catch {}
        }
    })
}

# --- Source toggle pill -----------------
$SourceTogglePill = $window.FindName('SourceTogglePill')
$HeaderActionPill = $window.FindName('HeaderActionPill')
if ($SourceTogglePill -and $HeaderActionPill) {
    $HeaderActionPill.Add_SizeChanged({
        if ($HeaderActionPill.ActualWidth -gt 0) {
            $SourceTogglePill.Width = $HeaderActionPill.ActualWidth
        }
    })
}
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
$PexelsEmptyStatePanel = $window.FindName('PexelsEmptyStatePanel')
$PexelsEmptyKeyBox = $window.FindName('PexelsEmptyKeyBox')
$PexelsEmptyKeyPlaceholder = $window.FindName('PexelsEmptyKeyPlaceholder')
$PexelsEmptySaveBtn = $window.FindName('PexelsEmptySaveBtn')
$PexelsEmptyGetBtn = $window.FindName('PexelsEmptyGetBtn')
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
    $picked = $null
    $modernFailed = $false

    [void](Wait-NativeExtraCompile)

    try {
        $dialog = New-Object Microsoft.Win32.OpenFolderDialog
        $dialog.Title = 'Select Wallpaper Folder'
        if ($script:localFolderPath -and (Test-Path -LiteralPath $script:localFolderPath)) {
            $dialog.InitialDirectory = $script:localFolderPath
        }

        if ('BingWallpaperNativeExtra' -as [type]) {
            [BingWallpaperNativeExtra]::EnableDarkDialogs()
        }

        $darkTimer = New-Object System.Windows.Threading.DispatcherTimer
        $darkTimer.Interval = [TimeSpan]::FromMilliseconds(30)
        $darkTimer.Add_Tick({
                if ('BingWallpaperNativeExtra' -as [type]) {
                    $hwnd = [BingWallpaperNativeExtra]::GetForegroundWindow()
                    if ($hwnd -ne [IntPtr]::Zero -and [BingWallpaperNativeExtra]::IsDialogWindow($hwnd)) {
                        [BingWallpaperNativeExtra]::ForceDarkDialog($hwnd)
                    }
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
            if ('BingWallpaperNativeExtra' -as [type]) {
                $legacyRes = [BingWallpaperNativeExtra]::PickFolder($helper.Handle, 'Select Wallpaper Folder', $script:localFolderPath)
            }
        }
        catch {}
        if (-not [string]::IsNullOrEmpty($legacyRes)) {
            $picked = $legacyRes
        }
    }

    if ($picked -and (Test-Path -LiteralPath $picked)) {
        if ($script:localFolderPath -ne $picked) {
            $indexPath = Join-Path $script:cacheDir 'local_index.json'
            if (Test-Path -LiteralPath $indexPath) { Remove-Item -LiteralPath $indexPath -Force -ErrorAction SilentlyContinue }
        }
        $script:localFolderPath = $picked
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

    $ApiKeyBox.Add_GotFocus({
            if ($ApiKeyPlaceholder -and -not $ApiKeyBox.IsReadOnly) {
                $ApiKeyPlaceholder.Visibility = [System.Windows.Visibility]::Collapsed
            }
        })

    $ApiKeyBox.Add_LostFocus({
            if ($ApiKeyPlaceholder -and -not $ApiKeyBox.IsReadOnly) {
                $txt = $ApiKeyBox.Text.Trim()
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
            if ($script:currentSource -eq 'Bing' -and -not $script:isArchiveView) { return }
            $script:isArchiveView = $false
            Write-InteractionLog "[TAB_CLICK] Switched to Bing tab"
            Stop-ArchiveSearch -Reason "Switched to Bing"
            $script:currentSource = 'Bing'
            Update-SourceToggleVisual
            Load-Gallery
        })
}
if ($SourceSpotlightBtn) {
    $SourceSpotlightBtn.Add_Click({
            if ($script:currentSource -eq 'Spotlight' -and -not $script:isArchiveView) { return }
            $script:isArchiveView = $false
            Write-InteractionLog "[TAB_CLICK] Switched to Spotlight tab"
            Stop-ArchiveSearch -Reason "Switched to Spotlight"
            $script:currentSource = 'Spotlight'
            Update-SourceToggleVisual
            Load-Gallery
        })
}
if ($SourceWallhavenBtn) {
    $SourceWallhavenBtn.Add_Click({
            if ($script:currentSource -eq 'Wallhaven' -and -not $script:isArchiveView) { return }
            $script:isArchiveView = $false
            Write-InteractionLog "[TAB_CLICK] Switched to Wallhaven tab"
            Stop-ArchiveSearch -Reason "Switched to Wallhaven"
            $script:currentSource = 'Wallhaven'
            Update-SourceToggleVisual
            Load-Gallery
        })
}
if ($SourcePexelsBtn) {
    $SourcePexelsBtn.Add_Click({
            if ($script:currentSource -eq 'Pexels' -and -not $script:isArchiveView) { return }
            $script:isArchiveView = $false
            Write-InteractionLog "[TAB_CLICK] Switched to Pexels tab"
            Stop-ArchiveSearch -Reason "Switched to Pexels"
            $script:currentSource = 'Pexels'
            Update-SourceToggleVisual
            Load-Gallery
        })
}
if ($SourceLocalBtn) {
    $SourceLocalBtn.Add_Click({
            if ($script:currentSource -eq 'Local' -and -not $script:isArchiveView) { return }
            $script:isArchiveView = $false
            Write-InteractionLog "[TAB_CLICK] Switched to Local tab"
            Stop-ArchiveSearch -Reason "Switched to Local"
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

if ($PexelsEmptyKeyBox) {
    $PexelsEmptyKeyBox.Add_TextChanged({
        if ($PexelsEmptyKeyPlaceholder) {
            $txt = $PexelsEmptyKeyBox.Text.Trim()
            $PexelsEmptyKeyPlaceholder.Visibility = if ([string]::IsNullOrEmpty($txt)) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        }
    })
    $PexelsEmptyKeyBox.Add_GotFocus({
        if ($PexelsEmptyKeyPlaceholder) {
            $PexelsEmptyKeyPlaceholder.Visibility = [System.Windows.Visibility]::Collapsed
        }
    })
    $PexelsEmptyKeyBox.Add_LostFocus({
        if ($PexelsEmptyKeyPlaceholder) {
            $txt = $PexelsEmptyKeyBox.Text.Trim()
            $PexelsEmptyKeyPlaceholder.Visibility = if ([string]::IsNullOrEmpty($txt)) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        }
    })
    $PexelsEmptyKeyBox.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
            $e.Handled = $true
            if ($PexelsEmptySaveBtn) {
                $PexelsEmptySaveBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            }
        }
    })
}

if ($PexelsEmptySaveBtn) {
    $PexelsEmptySaveBtn.Add_Click({
        $raw = if ($PexelsEmptyKeyBox) { $PexelsEmptyKeyBox.Text.Trim() } else { '' }
        $validation = Test-SourceApiKey -Source 'Pexels' -Key $raw
        if (-not $validation.Valid) {
            $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $StatusText.Opacity = 1
            $StatusText.Foreground = $statusErrorBrush
            $StatusText.Text = $validation.Error
            return
        }

        Set-SourceApiKey -Source 'Pexels' -Key $raw
        Update-GlobalApiKeyBoxState -Key $raw
        if ($PexelsEmptyKeyBox) { $PexelsEmptyKeyBox.Text = '' }
        if ($PexelsEmptyStatePanel) { $PexelsEmptyStatePanel.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($window) { $window.Focus() }
        Load-Gallery
    })
}

if ($PexelsEmptyGetBtn) {
    $PexelsEmptyGetBtn.Add_Click({
        try {
            [System.Diagnostics.Process]::Start((New-Object System.Diagnostics.ProcessStartInfo -Property @{
                FileName = 'https://www.pexels.com/api/'
                UseShellExecute = $true
            })) | Out-Null
        }
        catch {
            try { Start-Process 'https://www.pexels.com/api/' } catch {}
        }
    })
}
# ------------------------------------------------------------------------

$AutoToggleCheckbox = $window.FindName('AutoToggleCheckbox')
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
$ControlDeckCard = $window.FindName('ControlDeckCard')
$HeaderActionRow = $window.FindName('HeaderActionRow')
$AutoLabel = $window.FindName('AutoLabel')
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
    
    # Fluent Snappy Settle: 0° -> 360° with CubicEase EaseOut (680ms)
    $spin = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 0.0, 360.0, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(680)))
    $easing = New-Object System.Windows.Media.Animation.CubicEase
    $easing.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $spin.EasingFunction = $easing
    $spin.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop

    $rotation.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $spin, [System.Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace)

    if ($script:refreshDelayTimer) {
        $script:refreshDelayTimer.Stop()
        $script:refreshDelayTimer = $null
    }

    $script:refreshDelayTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:refreshDelayTimer.Interval = [TimeSpan]::FromMilliseconds(680)
    $script:refreshDelayTimer.Add_Tick({
            $script:refreshDelayTimer.Stop()
            $script:refreshDelayTimer = $null
            $finishedRotation = [System.Windows.Media.RotateTransform]$RefreshIcon.RenderTransform
            $finishedRotation.Angle = 0
            try {
                if ($script:currentSource -eq 'Local') {
                    $indexPath = Join-Path $script:cacheDir 'local_index.json'
                    if (Test-Path -LiteralPath $indexPath) { Remove-Item -LiteralPath $indexPath -Force -ErrorAction SilentlyContinue }
                }
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
$ResolutionBox.Add_SelectionChanged({ Update-FiltersBtnText })
Update-FiltersBtnText
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
        $combo.Add_DropDownOpened({
                if ($FiltersPopup) { $FiltersPopup.StaysOpen = $true }
            })
        $combo.Add_DropDownClosed({
                if ($FiltersPopup) {
                    $stayTimer = New-Object System.Windows.Threading.DispatcherTimer
                    $stayTimer.Interval = [TimeSpan]::FromMilliseconds(160)
                    $stayTimer.Add_Tick({
                            $this.Stop()
                            if ($FiltersPopup) { $FiltersPopup.StaysOpen = $false }
                        })
                    $stayTimer.Start()
                }
            })
    }
}

$FolderBox.Add_PreviewMouseLeftButtonDown({
        if ($FiltersPopup) { $FiltersPopup.IsOpen = $false }
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
        if (-not $imagePath -or -not (Test-Path -LiteralPath $imagePath)) {
            return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(235, 0, 120, 215))
        }
        [void](Wait-NativeExtraCompile)
        $resolved = (Resolve-Path -LiteralPath $imagePath).Path
        return [BingWallpaper.FastAccent]::ExtractBrush($resolved)
    }
    catch {
        return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(235, 0, 120, 215))
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
    if ($image) {
        Write-InteractionLog "[CARD_SELECT] Title='$($image.title)' Source='$($image.source)'"
    }
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
$script:hoverRestoreTimer = $null
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
    Write-InteractionLog "[WALLPAPER_APPLY_START] Title='$actionTitle' Target='$Target' Style='$Style' Resolution='$Resolution'"

    $UpdateBtn.IsEnabled = $false
    $DownloadBtn.IsEnabled = $false
    $StatusText.Foreground = $statusDefaultBrush
    $StatusText.Text = "Applying $actionTitle..."

    if ($Card) { Start-CardDownloadAnimation $Card }

    $imageUri = Get-BingImageUri -Image $Image -Resolution $Resolution
    $cacheDir = $script:cacheDir
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
                    Write-InteractionLog "[WALLPAPER_APPLY_SUCCESS] Wallpaper applied successfully to $($ctx.Target)"
                    Set-TransientStatus -Message (Get-AppliedSuccessMessage $ctx.Target)
                    Invoke-MemoryFlush -Reason "PostWallpaperApply" -Async
                }
                else {
                    Write-InteractionLog "[WALLPAPER_APPLY_FAIL] Failed: $errorMsg"
                    $errMsg = Get-UserFriendlyNetworkError -Exception (New-Object Exception($errorMsg)) -DefaultAction "apply wallpaper"
                    Set-TransientStatus -Message $errMsg -Brush $statusErrorBrush -Seconds 5
                }
            }
        })
    $script:applyTimer.Start()
}

function Set-StatusTextWithFade {
    param([string]$Text)
    $targetCtrl = if ($script:StatusText) { $script:StatusText } else { $StatusText }
    if (-not $targetCtrl -or -not $Text) { return }

    # If applying or a transient status is actively displaying (e.g. Success / Error message), do not overwrite
    if ($script:statusResetTimer -and $script:statusResetTimer.IsEnabled) { return }
    if ($script:applyTimer -and $script:applyTimer.IsEnabled) { return }

    # Cancel any pending restore timer (e.g. from mouse leaving an adjacent card)
    if ($script:hoverRestoreTimer) { $script:hoverRestoreTimer.Stop() }

    # If already displaying this exact text, nothing to do
    if ($targetCtrl.Text -eq $Text) { return }

    # Remove any existing animation lock so opacity is directly controllable
    $targetCtrl.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)

    # Set text immediately so there is never a blank gap or null reference
    $targetCtrl.Foreground = $statusDefaultBrush
    $targetCtrl.Text = $Text

    # Smooth fade-in ("come nicely"): from 0.3 to 1.0 over 220ms
    $fadeDur = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(220))
    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 0.3, 1.0, $fadeDur
    $targetCtrl.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)
}

function Invoke-RestoreStatusDefaultImmediate {
    $ctrl = if ($script:StatusText) { $script:StatusText } else { $StatusText }
    if (-not $ctrl) { return }
    if ($script:statusResetTimer -and $script:statusResetTimer.IsEnabled) { return }
    if ($script:applyTimer -and $script:applyTimer.IsEnabled) { return }

    $defaultText = if (-not $script:loadedImages -or $script:loadedImages.Count -eq 0) {
        'Unable to load wallpapers. Please check your internet connection.'
    }
    else {
        'Double-click any wallpaper to apply'
    }

    if ($ctrl.Text -eq $defaultText) { return }

    $ctrl.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $ctrl.Foreground = if (-not $script:loadedImages -or $script:loadedImages.Count -eq 0) { $statusErrorBrush } else { $statusDefaultBrush }
    $ctrl.Text = $defaultText

    # Fade back to default text nice and slow (420ms duration)
    $slowDur = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(420))
    $slowFade = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 0.25, 1.0, $slowDur
    $ctrl.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $slowFade)
}

function Restore-StatusTextDefaultWithFade {
    param([switch]$Immediate)
    if ($Immediate) {
        if ($script:hoverRestoreTimer) { $script:hoverRestoreTimer.Stop() }
        Invoke-RestoreStatusDefaultImmediate
        return
    }

    # Debounce for smooth card-to-card movement: wait 150ms before returning to default text
    if ($script:hoverRestoreTimer) { $script:hoverRestoreTimer.Stop() }
    $script:hoverRestoreTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:hoverRestoreTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:hoverRestoreTimer.Add_Tick({
            $script:hoverRestoreTimer.Stop()
            Invoke-RestoreStatusDefaultImmediate
        })
    $script:hoverRestoreTimer.Start()
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
    $script:SpotlightEnabled = [bool]$Enabled

    if ($SpotlightSetBtn) { $SpotlightSetBtn.IsEnabled = $script:SpotlightEnabled }
    if (-not $script:SpotlightEnabled -and $SpotlightOptionsPopup) { $SpotlightOptionsPopup.IsOpen = $false }

    if ($AutoToggleCheckbox) {
        $AutoToggleCheckbox.IsChecked = $script:SpotlightEnabled
        if (-not $Animate) {
            try {
                $AutoToggleCheckbox.UpdateLayout()
                $thumb = $AutoToggleCheckbox.Template.FindName('Thumb', $AutoToggleCheckbox)
                if ($thumb -and $thumb.RenderTransform) {
                    $thumb.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
                    $thumb.RenderTransform.X = if ($script:SpotlightEnabled) { 20 } else { 0 }
                }
            }
            catch {}
        }
    }

    if ($UpdateTask) {
        Update-SpotlightScheduledTaskAsync -Enable $script:SpotlightEnabled
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
        Invoke-MemoryFlush -Reason "ConfirmDialogClosed" -Async
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
    if ($MainContent) {
        $MainContent.Margin = if ($Compact) { [System.Windows.Thickness]::new(20, 14, 20, 14) } else { [System.Windows.Thickness]::new(24, 18, 24, 16) }
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

    if ($AutoLabel) {
        $AutoLabel.Visibility = if ($width -lt 980) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
    }
    if ($FiltersBtnText) {
        $FiltersBtnText.Text = "Preferences"
    }
    if ($ArchiveSearchBtnText) {
        $ArchiveSearchBtnText.Text = if ($width -lt 920) { "Search" } else { "Archive Search" }
    }

    # Responsive Header: ControlDeckCard is centered across top bar
    if ($ControlDeckCard) {
        $ControlDeckCard.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $ControlDeckCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 0)
    }

    # Responsive Gallery: 4 columns on wide displays, 3 on standard/scaled laptops, 2 on narrow
    if ($GalleryPanel) {
        $targetCols = if ($width -lt 740) { 2 } elseif ($width -lt 1060) { 3 } else { 4 }
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
        $skipTooltip = ($image.source -eq 'Local') -or ($script:currentSource -eq 'Local') -or ($image.source -eq 'Wallhaven') -or ($script:currentSource -eq 'Wallhaven')
        if (-not $skipTooltip -and ($image.copyright -or $displayTitle)) {
            $tipPanel = New-Object System.Windows.Controls.StackPanel
            $tipPanel.MaxWidth = 360

            if ($displayTitle) {
                $titleBlock = New-Object System.Windows.Controls.TextBlock
                $titleBlock.Text = $displayTitle
                $titleBlock.FontWeight = [System.Windows.FontWeights]::SemiBold
                $titleBlock.FontSize = 13.5
                $titleBlock.Foreground = [System.Windows.Media.Brushes]::White
                $titleBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
                $tipPanel.Children.Add($titleBlock) | Out-Null
            }

            if ($image.copyright) {
                $copyBlock = New-Object System.Windows.Controls.TextBlock
                $copyBlock.Text = $image.copyright
                $copyBlock.FontSize = 12
                $copyBlock.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#AAAAAA")
                $copyBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
                if ($displayTitle) {
                    $copyBlock.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
                }
                $tipPanel.Children.Add($copyBlock) | Out-Null
            }

            $card.ToolTip = $tipPanel
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

        # Context Menu: Explore in 3D (Google Earth) styled to match the Tab Bar pill
        $cleanLocation = $null
        if ($image.source -eq 'Spotlight' -and $image.title) {
            $cleanLocation = $image.title.Trim()
        }
        elseif ($image.copyrightlink -and $image.copyrightlink -match 'q=([^&]+)') {
            $rawQ = [System.Uri]::UnescapeDataString($Matches[1]) -replace '\+', ' '
            if ($rawQ.Trim().Length -gt 1) {
                $cleanLocation = $rawQ.Trim()
            }
        }
        if (-not $cleanLocation -and $image.title -and $image.title.Trim().Length -gt 1 -and $image.title -notmatch '^AutoScape') {
            $cleanLocation = $image.title.Trim()
        }
        if (-not $cleanLocation -and $image.copyright -and $image.source -ne 'Local') {
            $rawLoc = ($image.copyright -replace '\s*\(.*?\)', '') -replace '^Photo by .+? on Pexels', ''
            $rawLoc = ($rawLoc -replace '^[©\s]+', '').Trim()
            if ($rawLoc.Length -gt 2) {
                $cleanLocation = $rawLoc
            }
        }

        if ($cleanLocation) {
            $cardMenu = New-Object System.Windows.Controls.ContextMenu
            $cardMenu.Style = $window.Resources['FluentCardContextMenu']

            $earthMenuItem = New-Object System.Windows.Controls.MenuItem
            $earthMenuItem.Style = $window.Resources['FluentCardMenuItem']
            $earthMenuItem.Header = "Explore in 3D (Google Earth)"

            $iconBlock = New-Object System.Windows.Controls.TextBlock
            $iconBlock.Text = [char]0xE707
            $iconBlock.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets")
            $iconBlock.FontSize = 13.5
            $iconBlock.Foreground = [System.Windows.Media.Brushes]::White
            $iconBlock.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $earthMenuItem.Icon = $iconBlock
            $encodedQ = [System.Uri]::EscapeDataString($cleanLocation)
            $earthUrl = "https://earth.google.com/web/search/$encodedQ"
            $earthMenuItem.Tag = $earthUrl

            $earthMenuItem.Add_Click({
                param($s, $e)
                $targetUrl = [string]$s.Tag
                if ($targetUrl) {
                    try {
                        [System.Diagnostics.Process]::Start((New-Object System.Diagnostics.ProcessStartInfo -Property @{
                            FileName = $targetUrl
                            UseShellExecute = $true
                        })) | Out-Null
                    }
                    catch {
                        try { Start-Process $targetUrl } catch {}
                    }
                }
            })

            $cardMenu.Items.Add($earthMenuItem) | Out-Null
            $card.ContextMenu = $cardMenu
        }

        $card.Add_PreviewMouseRightButtonDown({
            param($evtSender, $e)
            Select-Card $evtSender $evtSender.Tag
        })

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

        # Ensure thumbnail border always maintains 16:9 ratio of card width so cards never collapse
        $imgBorder.Add_SizeChanged({
                param($evtSender, $e)
                if ($e.NewSize.Width -gt 0) {
                    $desiredHeight = [Math]::Round($e.NewSize.Width * 9.0 / 16.0, 2)
                    if ([double]::IsNaN($evtSender.Height) -or [Math]::Abs($evtSender.Height - $desiredHeight) -gt 0.5) {
                        $evtSender.Height = $desiredHeight
                    }
                }
            })

        try {
            $safeName = $image.urlbase -replace '[^a-zA-Z0-9]', ''
            $thumbCachePath = Join-Path $ThumbCacheDir "${safeName}_thumb.jpg"

            $imagePathToLoad = $null
            if (Test-Path -LiteralPath $thumbCachePath) {
                $imagePathToLoad = $thumbCachePath
            }
            elseif ($image.thumbUrl -and (Test-Path -LiteralPath $image.thumbUrl)) {
                $imagePathToLoad = $image.thumbUrl
            }
            elseif ($image.url -and (Test-Path -LiteralPath $image.url)) {
                $imagePathToLoad = $image.url
            }
            elseif ($image.thumbUrl -and ($image.thumbUrl -match '^https?://')) {
                $imagePathToLoad = $image.thumbUrl
            }

            $isWeb = $imagePathToLoad -and ($imagePathToLoad -match '^https?://')
            if ($imagePathToLoad -and ($isWeb -or (Test-Path -LiteralPath $imagePathToLoad))) {
                $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                $bitmap.BeginInit()
                $bitmap.UriSource = if ($isWeb) { New-Object System.Uri($imagePathToLoad) } else { New-Object System.Uri((Resolve-Path -LiteralPath $imagePathToLoad).Path) }
                $bitmap.DecodePixelWidth = 360
                $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bitmap.EndInit()
                $bitmap.Freeze()

                $imageControl.Source = $bitmap

                # Use pre-computed accent color from background worker (ZERO UI freeze!)
                $hasValidAccent = ($image.accentR -ne $null -and $image.accentG -ne $null -and $image.accentB -ne $null -and -not ($image.accentR -eq 70 -and $image.accentG -eq 70 -and $image.accentB -eq 70))
                if ($hasValidAccent) {
                    $accentBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(235, [byte]$image.accentR, [byte]$image.accentG, [byte]$image.accentB))
                    $accentBrush.Freeze()
                    $card.Resources.Add('ImageAccentBrush', $accentBrush)
                }
                else {
                    $card.Resources.Add('ImageAccentBrush', (Get-ImageAccentBrush $imagePathToLoad))
                }
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
    if ($script:qualityUpgradeTimer) { $script:qualityUpgradeTimer.Stop() }
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
            Write-InteractionLog "[GALLERY_SETTLED] Gallery cards rendered and settled ($total cards)"
            if ($script:galleryIdleSettleTimer) { $script:galleryIdleSettleTimer.Stop() }
            $script:galleryIdleSettleTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:galleryIdleSettleTimer.Interval = [TimeSpan]::FromSeconds(5)
            $script:galleryIdleSettleTimer.Add_Tick({
                $script:galleryIdleSettleTimer.Stop()
                $script:galleryIdleSettleTimer = $null
                Invoke-MemoryFlush -Reason "GalleryIdleSettle" -Async
            })
            $script:galleryIdleSettleTimer.Start()
        })
    $script:qualityUpgradeTimer.Start()
}

function Load-Gallery {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    [CmdletBinding()]
    param()

    if ($script:galleryIdleSettleTimer) {
        $script:galleryIdleSettleTimer.Stop()
        $script:galleryIdleSettleTimer = $null
    }
    if ($script:fadeTimer) { $script:fadeTimer.Stop() }
    if ($script:hoverRestoreTimer) { $script:hoverRestoreTimer.Stop() }
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
    if ($script:archiveSearchContext) {
        try { $script:archiveSearchContext.Timer.Stop() } catch {}
        try { $script:archiveSearchContext.PS.Stop() } catch {}
        try { $script:archiveSearchContext.PS.Dispose() } catch {}
        $script:archiveSearchContext = $null
    }

    $selectedRegion = Get-SelectedRegionCode
    $fetchSource = $script:currentSource

    if ($fetchSource -eq 'Local') {
        if (-not $script:localFolderPath -or -not (Test-Path -LiteralPath $script:localFolderPath)) {
            if ($LocalEmptyStatePanel) { $LocalEmptyStatePanel.Visibility = [System.Windows.Visibility]::Visible }
            if ($PexelsEmptyStatePanel) { $PexelsEmptyStatePanel.Visibility = [System.Windows.Visibility]::Collapsed }
            if ($GalleryScrollViewer) { $GalleryScrollViewer.Visibility = [System.Windows.Visibility]::Collapsed }
            $StatusText.Text = "Select a local wallpaper folder to display images."
            $GalleryPanel.Children.Clear()
            return
        }
        else {
            if ($LocalEmptyStatePanel) { $LocalEmptyStatePanel.Visibility = [System.Windows.Visibility]::Collapsed }
            if ($PexelsEmptyStatePanel) { $PexelsEmptyStatePanel.Visibility = [System.Windows.Visibility]::Collapsed }
            if ($GalleryScrollViewer) { $GalleryScrollViewer.Visibility = [System.Windows.Visibility]::Visible }
        }
    }
    elseif ($fetchSource -eq 'Pexels') {
        $sourceKey = Get-SourceApiKey 'Pexels'
        $val = Test-SourceApiKey -Source 'Pexels' -Key $sourceKey
        if (-not $val.Valid) {
            if ($LocalEmptyStatePanel) { $LocalEmptyStatePanel.Visibility = [System.Windows.Visibility]::Collapsed }
            if ($PexelsEmptyStatePanel) { $PexelsEmptyStatePanel.Visibility = [System.Windows.Visibility]::Visible }
            if ($GalleryScrollViewer) { $GalleryScrollViewer.Visibility = [System.Windows.Visibility]::Collapsed }
            $StatusText.Text = "Enter a Pexels API key to browse wallpapers."
            $GalleryPanel.Children.Clear()
            return
        }
        else {
            if ($LocalEmptyStatePanel) { $LocalEmptyStatePanel.Visibility = [System.Windows.Visibility]::Collapsed }
            if ($PexelsEmptyStatePanel) { $PexelsEmptyStatePanel.Visibility = [System.Windows.Visibility]::Collapsed }
            if ($GalleryScrollViewer) { $GalleryScrollViewer.Visibility = [System.Windows.Visibility]::Visible }
        }
    }
    else {
        if ($LocalEmptyStatePanel) { $LocalEmptyStatePanel.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($PexelsEmptyStatePanel) { $PexelsEmptyStatePanel.Visibility = [System.Windows.Visibility]::Collapsed }
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
    $cacheBaseDir = $script:cacheDir
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
                        if ($ctx.Source -eq 'Local' -or $fetchSource -eq 'Local' -or $script:currentSource -eq 'Local') {
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
                    if ($fetchSource -eq 'Local' -or ($ctx -and $ctx.Source -eq 'Local') -or $script:currentSource -eq 'Local') {
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
        Write-InteractionLog "[DOWNLOAD_CLICK] Target='$actionTitle' Source='$($targetImage.source)' Resolution='$($ResolutionBox.SelectedItem)'"

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
                        Write-InteractionLog "[DOWNLOAD_SUCCESS] Downloaded '$actionTitle'"
                        if ($ctx.TargetCard) { Stop-CardDownloadAnimation $ctx.TargetCard $true }
                        Set-TransientStatus -Message "Wallpaper downloaded"
                        Invoke-MemoryFlush -Reason "PostDownload" -Async
                    }
                    else {
                        Write-InteractionLog "[DOWNLOAD_FAIL] Download failed: $errorMsg"
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
                if ($FiltersPopup -and $FiltersPopup.IsOpen) {
                    $FiltersPopup.IsOpen = $false
                }
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

                    $vOffset = 16.0
                    $targetBottom = $targetPos.Y + $SpotlightSetBtn.ActualHeight
                    $roomBelow = $window.ActualHeight - $spotlightPopupEdgePad - $targetBottom
                    if ($roomBelow -lt $spotlightPopupCardHeight) {
                        # Not enough room below - flip the card above the button instead.
                        $vOffset = - ($SpotlightSetBtn.ActualHeight + $spotlightPopupCardHeight + 16.0)
                    }
                    $SpotlightOptionsPopup.VerticalOffset = $vOffset
                }
                catch {
                    $SpotlightOptionsPopup.HorizontalOffset = 0.0
                    $SpotlightOptionsPopup.VerticalOffset = 16.0
                }
            }

            $SpotlightOptionsPopup.IsOpen = -not $SpotlightOptionsPopup.IsOpen
        })

    # Same slide + fade entrance every open, mirroring the ~200ms CubicEase
    # timing used elsewhere in the toolbar (e.g. Set-SpotlightState's pill
    # animation) so this flyout feels consistent with the rest of the app.
    $SpotlightOptionsPopup.Add_Opened({
            Write-InteractionLog "[AUTO_OPTIONS_OPEN] Automatic wallpaper schedule options opened"
            try {
                $source = [System.Windows.Interop.HwndSource]::FromVisual($SpotlightOptionsPopup.Child)
                if ($source -and $source.Handle -ne [IntPtr]::Zero) {
                    [BingWallpaperNative]::EnableDarkTitleBar($source.Handle, 1)
                }
            } catch {}

            if ($AutoUnifiedButton) {
                $AutoUnifiedButton.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(37, 255, 255, 255))
                $AutoUnifiedButton.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(16, 255, 255, 255))
            }

            $easing = New-Object System.Windows.Media.Animation.CubicEase
            $easing.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
            $dur = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(150))

            $fadeAnim = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 1.0, $dur
            $fadeAnim.EasingFunction = $easing
            $SpotlightPopupCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeAnim)
        })

    $SpotlightOptionsPopup.Add_Closed({
            $script:spotlightPopupClosedAt = [DateTime]::Now
            Write-InteractionLog "[AUTO_OPTIONS_CLOSE] Automatic wallpaper schedule options closed"

            if ($AutoUnifiedButton) {
                $AutoUnifiedButton.Background = [System.Windows.Media.Brushes]::Transparent
                $AutoUnifiedButton.BorderBrush = [System.Windows.Media.Brushes]::Transparent
            }

            $SpotlightPopupCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $SpotlightPopupCard.Opacity = 0
            Invoke-MemoryFlush -Reason "AutoOptionsClosed" -Async
        })
}

if ($FiltersBtn -and $FiltersPopup) {
    $script:filtersPopupClosedAt = [DateTime]::MinValue
    $filtersPopupCardWidth = 440.0
    $filtersPopupCardHeight = 195.0
    $filtersPopupEdgePad = 8.0

    $window.Add_SizeChanged({
            if ($FiltersPopup -and $FiltersPopup.IsOpen) { $FiltersPopup.IsOpen = $false }
        })

    $FiltersBtn.Add_Click({
            param($sender, $e)
            if ($e) { $e.Handled = $true }

            $msSinceClosed = ([DateTime]::Now - $script:filtersPopupClosedAt).TotalMilliseconds
            if ($msSinceClosed -lt 200) { return }

            if (-not $FiltersPopup.IsOpen) {
                if ($SpotlightOptionsPopup -and $SpotlightOptionsPopup.IsOpen) {
                    $SpotlightOptionsPopup.IsOpen = $false
                }
                if ($ArchiveSearchPopup -and $ArchiveSearchPopup.IsOpen) {
                    $ArchiveSearchPopup.IsOpen = $false
                }

                try {
                    $targetPos = $FiltersBtn.TranslatePoint([System.Windows.Point]::new(0, 0), $window)

                    $hOffset = -180.0
                    $maxH = ($window.ActualWidth - $filtersPopupEdgePad) - $targetPos.X - $filtersPopupCardWidth
                    $minH = $filtersPopupEdgePad - $targetPos.X
                    if ($hOffset -gt $maxH) { $hOffset = $maxH }
                    if ($hOffset -lt $minH) { $hOffset = $minH }
                    $FiltersPopup.HorizontalOffset = $hOffset

                    $vOffset = 16.0
                    $targetBottom = $targetPos.Y + $FiltersBtn.ActualHeight
                    $roomBelow = $window.ActualHeight - $filtersPopupEdgePad - $targetBottom
                    if ($roomBelow -lt $filtersPopupCardHeight) {
                        $vOffset = - ($FiltersBtn.ActualHeight + $filtersPopupCardHeight + 16.0)
                    }
                    $FiltersPopup.VerticalOffset = $vOffset
                }
                catch {
                    $FiltersPopup.HorizontalOffset = -180.0
                    $FiltersPopup.VerticalOffset = 16.0
                }
            }

            $FiltersPopup.IsOpen = -not $FiltersPopup.IsOpen
        })

    $FiltersPopup.Add_Opened({
            Write-InteractionLog "[PREFERENCES_OPEN] Preferences flyout opened"
            try {
                $source = [System.Windows.Interop.HwndSource]::FromVisual($FiltersPopup.Child)
                if ($source -and $source.Handle -ne [IntPtr]::Zero) {
                    [BingWallpaperNative]::EnableDarkTitleBar($source.Handle, 1)
                }
            } catch {}

            if ($FiltersBtn) {
                $FiltersBtn.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(37, 255, 255, 255))
                $FiltersBtn.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(16, 255, 255, 255))
            }

            $easing = New-Object System.Windows.Media.Animation.CubicEase
            $easing.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
            $dur = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(150))

            $fadeAnim = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 1.0, $dur
            $fadeAnim.EasingFunction = $easing
            $FiltersPopupCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeAnim)
        })

    $FiltersPopup.Add_Closed({
            $script:filtersPopupClosedAt = [DateTime]::Now
            Write-InteractionLog "[PREFERENCES_CLOSE] Preferences flyout closed"

            if ($FiltersBtn) {
                $FiltersBtn.Background = [System.Windows.Media.Brushes]::Transparent
                $FiltersBtn.BorderBrush = [System.Windows.Media.Brushes]::Transparent
            }

            $FiltersPopupCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
            $FiltersPopupCard.Opacity = 0
            Invoke-MemoryFlush -Reason "PreferencesClosed" -Async
        })
}

# --- Peapix Bing Archive Scraper & Date Search Handlers ---
function Get-PeapixBingMonth {
    param(
        [string]$Country = 'us',
        [int]$Year = 2026,
        [int]$Month = 8
    )

    $monthStr = $Month.ToString("00")
    $url = "https://peapix.com/bing/$Country/$Year/$monthStr"
    try {
        $response = Invoke-WebRequest -Uri $url -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -UseBasicParsing -TimeoutSec 10
        $html = $response.Content
    } catch {
        return @()
    }

    $pattern = '(?s)<div class="[^"]*rounded-bottom">.*?<img[^>]*data-src="([^"]+)"[^>]*>.*?<a[^>]*href="(/bing/\d+)"[^>]*>([^<]+)</a>.*?<span class="text-body-tertiary fs-sm">([^<]+)</span>'
    $matches = [regex]::Matches($html, $pattern)
    
    $results = @()
    foreach ($m in $matches) {
        $thumbUrl = $m.Groups[1].Value
        $pageUrl  = "https://peapix.com" + $m.Groups[2].Value
        $rawTitle = $m.Groups[3].Value.Trim()
        $title    = [System.Net.WebUtility]::HtmlDecode($rawTitle)
        $dateText = $m.Groups[4].Value.Trim()

        $baseImg  = $thumbUrl -replace '_640\.jpg$', ''
        $full1080 = $baseImg + '_1920.jpg'
        $full4k   = $baseImg + '.jpg'

        $parsedDate = $null
        try {
            $parsedDate = [DateTime]::ParseExact("$dateText $Year", "MMMM dd yyyy", [System.Globalization.CultureInfo]::InvariantCulture).ToString("yyyy-MM-dd")
        } catch {
            $parsedDate = "$Year-$monthStr"
        }

        $results += [PSCustomObject]@{
            source       = 'Bing'
            title        = $title
            date         = $parsedDate
            dateText     = $dateText
            thumbUrl     = $thumbUrl
            url          = $full4k
            urlbase      = $full1080
            copyright    = "Bing Wallpaper - $parsedDate"
            photographer = ''
            pageUrl      = $pageUrl
            enddate      = ($parsedDate -replace '-', '')
            resX         = 3840
            resY         = 2160
        }
    }
    return $results
}

$script:archiveSearchScope = 'Day' # 'Day', 'Month', 'Year'
function Set-ArchiveSearchScope {
    param([string]$Scope)
    Write-InteractionLog "[ARCHIVE_SCOPE_CHANGE] Scope changed to '$Scope'"
    $script:archiveSearchScope = $Scope
    $grayBrush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#888888")

    # Move StackArchiveRegion between Top Host (Year mode) and Bottom Host (Day/Month mode)
    if ($Scope -eq 'Year') {
        if ($RegionTopHost -and $RegionBottomHost -and $StackArchiveRegion) {
            if ($RegionBottomHost.Children.Contains($StackArchiveRegion)) {
                $RegionBottomHost.Children.Remove($StackArchiveRegion)
            }
            if (-not $RegionTopHost.Children.Contains($StackArchiveRegion)) {
                $RegionTopHost.Children.Add($StackArchiveRegion)
            }
            $RegionTopHost.Visibility = [System.Windows.Visibility]::Visible
        }
        if ($ColBottomRegion) { $ColBottomRegion.Width = New-Object System.Windows.GridLength(0) }
        if ($ColBottomGap) { $ColBottomGap.Width = New-Object System.Windows.GridLength(0) }
        if ($ColBottomSearch) { $ColBottomSearch.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
    } else {
        if ($RegionTopHost -and $RegionBottomHost -and $StackArchiveRegion) {
            if ($RegionTopHost.Children.Contains($StackArchiveRegion)) {
                $RegionTopHost.Children.Remove($StackArchiveRegion)
            }
            if (-not $RegionBottomHost.Children.Contains($StackArchiveRegion)) {
                $RegionBottomHost.Children.Add($StackArchiveRegion)
            }
            $RegionTopHost.Visibility = [System.Windows.Visibility]::Collapsed
        }
        if ($ColBottomRegion) { $ColBottomRegion.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
        if ($ColBottomGap) { $ColBottomGap.Width = New-Object System.Windows.GridLength(10) }
        if ($ColBottomSearch) { $ColBottomSearch.Width = New-Object System.Windows.GridLength(130) }
    }

    if ($Scope -eq 'Day') {
        if ($ScopeDayIndicator) { $ScopeDayIndicator.Opacity = 1 }
        if ($ScopeDayLabel) { $ScopeDayLabel.Foreground = [System.Windows.Media.Brushes]::White }
        if ($ScopeMonthIndicator) { $ScopeMonthIndicator.Opacity = 0 }
        if ($ScopeMonthLabel) { $ScopeMonthLabel.Foreground = $grayBrush }
        if ($ScopeYearIndicator) { $ScopeYearIndicator.Opacity = 0 }
        if ($ScopeYearLabel) { $ScopeYearLabel.Foreground = $grayBrush }

        if ($ColArchiveYear) { $ColArchiveYear.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
        if ($ColArchiveMonthGap) { $ColArchiveMonthGap.Width = New-Object System.Windows.GridLength(10) }
        if ($ColArchiveMonth) { $ColArchiveMonth.Width = New-Object System.Windows.GridLength(1.2, [System.Windows.GridUnitType]::Star) }
        if ($ColArchiveDayGap) { $ColArchiveDayGap.Width = New-Object System.Windows.GridLength(10) }
        if ($ColArchiveDay) { $ColArchiveDay.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }

        if ($StackArchiveMonth) { $StackArchiveMonth.Visibility = [System.Windows.Visibility]::Visible }
        if ($StackArchiveDay) { $StackArchiveDay.Visibility = [System.Windows.Visibility]::Visible }
        if ($ArchiveYearNotice) { $ArchiveYearNotice.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    elseif ($Scope -eq 'Month') {
        if ($ScopeDayIndicator) { $ScopeDayIndicator.Opacity = 0 }
        if ($ScopeDayLabel) { $ScopeDayLabel.Foreground = $grayBrush }
        if ($ScopeMonthIndicator) { $ScopeMonthIndicator.Opacity = 1 }
        if ($ScopeMonthLabel) { $ScopeMonthLabel.Foreground = [System.Windows.Media.Brushes]::White }
        if ($ScopeYearIndicator) { $ScopeYearIndicator.Opacity = 0 }
        if ($ScopeYearLabel) { $ScopeYearLabel.Foreground = $grayBrush }

        if ($ColArchiveYear) { $ColArchiveYear.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
        if ($ColArchiveMonthGap) { $ColArchiveMonthGap.Width = New-Object System.Windows.GridLength(10) }
        if ($ColArchiveMonth) { $ColArchiveMonth.Width = New-Object System.Windows.GridLength(1.8, [System.Windows.GridUnitType]::Star) }
        if ($ColArchiveDayGap) { $ColArchiveDayGap.Width = New-Object System.Windows.GridLength(0) }
        if ($ColArchiveDay) { $ColArchiveDay.Width = New-Object System.Windows.GridLength(0) }

        if ($StackArchiveMonth) { $StackArchiveMonth.Visibility = [System.Windows.Visibility]::Visible }
        if ($StackArchiveDay) { $StackArchiveDay.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($ArchiveYearNotice) { $ArchiveYearNotice.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    elseif ($Scope -eq 'Year') {
        if ($ScopeDayIndicator) { $ScopeDayIndicator.Opacity = 0 }
        if ($ScopeDayLabel) { $ScopeDayLabel.Foreground = $grayBrush }
        if ($ScopeMonthIndicator) { $ScopeMonthIndicator.Opacity = 0 }
        if ($ScopeMonthLabel) { $ScopeMonthLabel.Foreground = $grayBrush }
        if ($ScopeYearIndicator) { $ScopeYearIndicator.Opacity = 1 }
        if ($ScopeYearLabel) { $ScopeYearLabel.Foreground = [System.Windows.Media.Brushes]::White }

        if ($ColArchiveYear) { $ColArchiveYear.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
        if ($ColArchiveMonthGap) { $ColArchiveMonthGap.Width = New-Object System.Windows.GridLength(10) }
        if ($ColArchiveMonth) { $ColArchiveMonth.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
        if ($ColArchiveDayGap) { $ColArchiveDayGap.Width = New-Object System.Windows.GridLength(0) }
        if ($ColArchiveDay) { $ColArchiveDay.Width = New-Object System.Windows.GridLength(0) }

        if ($StackArchiveMonth) { $StackArchiveMonth.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($StackArchiveDay) { $StackArchiveDay.Visibility = [System.Windows.Visibility]::Collapsed }
        if ($ArchiveYearNotice) { $ArchiveYearNotice.Visibility = [System.Windows.Visibility]::Visible }
    }
}

if ($ScopeDayBtn) { $ScopeDayBtn.Add_Click({ Set-ArchiveSearchScope 'Day' }) }
if ($ScopeMonthBtn) { $ScopeMonthBtn.Add_Click({ Set-ArchiveSearchScope 'Month' }) }
if ($ScopeYearBtn) { $ScopeYearBtn.Add_Click({ Set-ArchiveSearchScope 'Year' }) }

if ($ArchiveSearchBtn -and $ArchiveSearchPopup) {
    $script:archivePopupClosedAt = [DateTime]::MinValue
    $archivePopupCardWidth = 430.0
    $archivePopupCardHeight = 280.0
    $archivePopupEdgePad = 8.0

    $window.Add_SizeChanged({
        if ($ArchiveSearchPopup -and $ArchiveSearchPopup.IsOpen) { $ArchiveSearchPopup.IsOpen = $false }
    })

    $ArchiveSearchBtn.Add_Click({
        param($sender, $e)
        if ($e) { $e.Handled = $true }

        $msSinceClosed = ([DateTime]::Now - $script:archivePopupClosedAt).TotalMilliseconds
        if ($msSinceClosed -lt 200) { return }

        if (-not $ArchiveSearchPopup.IsOpen) {
            if ($FiltersPopup -and $FiltersPopup.IsOpen) { $FiltersPopup.IsOpen = $false }
            if ($SpotlightOptionsPopup -and $SpotlightOptionsPopup.IsOpen) { $SpotlightOptionsPopup.IsOpen = $false }

            try {
                $targetPos = $ArchiveSearchBtn.TranslatePoint([System.Windows.Point]::new(0, 0), $window)

                $hOffset = -180.0
                $maxH = ($window.ActualWidth - $archivePopupEdgePad) - $targetPos.X - $archivePopupCardWidth
                $minH = $archivePopupEdgePad - $targetPos.X
                if ($hOffset -gt $maxH) { $hOffset = $maxH }
                if ($hOffset -lt $minH) { $hOffset = $minH }
                $ArchiveSearchPopup.HorizontalOffset = $hOffset

                $vOffset = 16.0
                $targetBottom = $targetPos.Y + $ArchiveSearchBtn.ActualHeight
                $roomBelow = $window.ActualHeight - $archivePopupEdgePad - $targetBottom
                if ($roomBelow -lt $archivePopupCardHeight) {
                    $vOffset = - ($ArchiveSearchBtn.ActualHeight + $archivePopupCardHeight + 16.0)
                }
                $ArchiveSearchPopup.VerticalOffset = $vOffset
            }
            catch {
                $ArchiveSearchPopup.HorizontalOffset = -180.0
                $ArchiveSearchPopup.VerticalOffset = 16.0
            }
        }

        $ArchiveSearchPopup.IsOpen = -not $ArchiveSearchPopup.IsOpen
    })

    $ArchiveSearchPopup.Add_Opened({
        Write-InteractionLog "[ARCHIVE_POPUP_OPEN] Archive Search popup opened"
        try {
            $source = [System.Windows.Interop.HwndSource]::FromVisual($ArchiveSearchPopup.Child)
            if ($source -and $source.Handle -ne [IntPtr]::Zero) {
                [BingWallpaperNative]::EnableDarkTitleBar($source.Handle, 1)
            }
        } catch {}

        if ($ArchiveSearchBtn) {
            $ArchiveSearchBtn.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(37, 255, 255, 255))
            $ArchiveSearchBtn.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(16, 255, 255, 255))
        }

        $easing = New-Object System.Windows.Media.Animation.CubicEase
        $easing.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
        $dur = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(150))
        $fadeAnim = New-Object System.Windows.Media.Animation.DoubleAnimation -ArgumentList 1.0, $dur
        $fadeAnim.EasingFunction = $easing
        $ArchiveSearchPopupCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeAnim)
    })

    $ArchiveSearchPopup.Add_Closed({
        $script:archivePopupClosedAt = [DateTime]::Now
        Write-InteractionLog "[ARCHIVE_POPUP_CLOSE] Archive Search popup closed"
        if ($ArchiveSearchBtn) {
            $ArchiveSearchBtn.Background = [System.Windows.Media.Brushes]::Transparent
            $ArchiveSearchBtn.BorderBrush = [System.Windows.Media.Brushes]::Transparent
        }
        $ArchiveSearchPopupCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $ArchiveSearchPopupCard.Opacity = 0
        Invoke-MemoryFlush -Reason "ArchivePopupClosed" -Async
    })
}

if ($FetchArchiveBtn) {
    $script:archiveSearchContext = $null

    $FetchArchiveBtn.Add_Click({
        if ($ArchiveSearchPopup) { $ArchiveSearchPopup.IsOpen = $false }

        # Cancel any previous running search
        if ($script:archiveSearchContext) {
            try { $script:archiveSearchContext.Timer.Stop() } catch {}
            try { $script:archiveSearchContext.PS.Stop() } catch {}
            try { $script:archiveSearchContext.PS.Dispose() } catch {}
            $script:archiveSearchContext = $null
        }

        $selYear = if ($ArchiveYearBox -and $ArchiveYearBox.SelectedItem) { [int]$ArchiveYearBox.SelectedItem } else { [DateTime]::Now.Year }
        $selMonth = if ($ArchiveMonthBox) { $ArchiveMonthBox.SelectedIndex + 1 } else { [DateTime]::Now.Month }
        $selDay = if ($ArchiveDayBox -and $ArchiveDayBox.SelectedItem) { [int]$ArchiveDayBox.SelectedItem } else { 1 }
        $selRegionCode = if ($ArchiveRegionBox -and $ArchiveRegionBox.SelectedItem -and $ArchiveRegionBox.SelectedItem.Tag) { [string]$ArchiveRegionBox.SelectedItem.Tag } else { 'us' }
        $scope = $script:archiveSearchScope

        # Switch visually to Bing tab
        if ($script:currentSource -ne 'Bing') {
            $script:currentSource = 'Bing'
            Update-SourceToggleVisual
        }

        $StatusText.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $StatusText.Opacity = 1
        $StatusText.Foreground = (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(136, 136, 136)))

        $thumbDir = Join-Path $script:cacheDir "Thumbnails\Bing_$selRegionCode"
        if (-not (Test-Path -LiteralPath $thumbDir)) {
            try { New-Item -ItemType Directory -Path $thumbDir -Force | Out-Null } catch {}
        }

        if ($scope -eq 'Day') {
            $targetDateStr = "$selYear-" + $selMonth.ToString("00") + "-" + $selDay.ToString("00")
            $StatusText.Text = "Searching Bing archive for $targetDateStr..."
        }
        elseif ($scope -eq 'Month') {
            $monthStr = $selMonth.ToString("00")
            $StatusText.Text = "Loading Bing wallpapers for $selYear-$monthStr..."
        }
        elseif ($scope -eq 'Year') {
            $StatusText.Text = "Loading full year archive for $selYear (this may take a few seconds)..."
        }

        $queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({
            param($Scope, $Country, $Year, $Month, $Day, $Queue, $LogPath, $ThumbDir)

            function LogMsg($msg) {
                if ($LogPath) {
                    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
                    Add-Content -Path $LogPath -Value "[$ts] $msg" -ErrorAction SilentlyContinue
                }
            }

            function FetchMonth($c, $y, $m) {
                $mStr = $m.ToString("00")
                $url = "https://peapix.com/bing/$c/$y/$mStr"
                LogMsg "Requesting URL: $url"
                try {
                    $resp = Invoke-WebRequest -Uri $url -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -UseBasicParsing -TimeoutSec 12
                    LogMsg "Received response: $($resp.StatusCode), Length: $($resp.Content.Length)"
                    $html = $resp.Content
                } catch {
                    LogMsg "HTTP Error for $($url): $($_.Exception.Message)"
                    return @()
                }

                $pattern = '(?s)<div class="[^"]*rounded-bottom">.*?<img[^>]*data-src="([^"]+)"[^>]*>.*?<a[^>]*href="(/bing/\d+)"[^>]*>([^<]+)</a>.*?<span class="text-body-tertiary fs-sm">([^<]+)</span>'
                $matches = [regex]::Matches($html, $pattern)
                LogMsg "Parsed $($matches.Count) wallpapers from $url"

                $items = @()
                foreach ($match in $matches) {
                    $thumbUrl = $match.Groups[1].Value
                    $pageUrl  = "https://peapix.com" + $match.Groups[2].Value
                    $rawTitle = $match.Groups[3].Value.Trim()
                    $title    = [System.Net.WebUtility]::HtmlDecode($rawTitle)
                    $dateText = $match.Groups[4].Value.Trim()

                    $baseImg  = $thumbUrl -replace '_640\.jpg$', ''
                    $full1080 = $baseImg + '_1920.jpg'
                    $full4k   = $baseImg + '.jpg'

                    $parsedDate = $null
                    try {
                        $parsedDate = [DateTime]::ParseExact("$dateText $y", "MMMM dd yyyy", [System.Globalization.CultureInfo]::InvariantCulture).ToString("yyyy-MM-dd")
                    } catch {
                        $parsedDate = "$y-$mStr"
                    }

                    $items += [PSCustomObject]@{
                        source       = 'Bing'
                        title        = $title
                        date         = $parsedDate
                        dateText     = $dateText
                        thumbUrl     = $thumbUrl
                        url          = $full4k
                        urlbase      = $full1080
                        copyright    = "Bing Wallpaper - $parsedDate"
                        photographer = ''
                        pageUrl      = $pageUrl
                        enddate      = ($parsedDate -replace '-', '')
                        resX         = 3840
                        resY         = 2160
                        accentR      = $null
                        accentG      = $null
                        accentB      = $null
                    }
                }

                # Download thumbnails in parallel in the background runspace before rendering
                if ($items.Count -gt 0 -and $ThumbDir) {
                    try {
                        $thumbUrls = [string[]]($items | ForEach-Object { [string]$_.thumbUrl })
                        $thumbTargets = [string[]]($items | ForEach-Object {
                            $safe = $_.urlbase -replace '[^a-zA-Z0-9]', ''
                            Join-Path $ThumbDir "${safe}_thumb.jpg"
                        })
                        if ('BingWallpaper.FastDownloader' -as [type]) {
                            [BingWallpaper.FastDownloader]::DownloadUrlsParallel($thumbUrls, $thumbTargets, 10)
                        } else {
                            $wc = New-Object System.Net.WebClient
                            $wc.Headers.Add("User-Agent", "Mozilla/5.0")
                            for ($k = 0; $k -lt $thumbUrls.Length; $k++) {
                                if (-not (Test-Path -LiteralPath $thumbTargets[$k])) {
                                    try { $wc.DownloadFile($thumbUrls[$k], $thumbTargets[$k]) } catch {}
                                }
                            }
                            $wc.Dispose()
                        }
                        for ($k = 0; $k -lt $items.Count; $k++) {
                            if (Test-Path -LiteralPath $thumbTargets[$k]) {
                                $items[$k].thumbUrl = $thumbTargets[$k]
                            }
                        }

                        # Extract dynamic accent colors in parallel on the background worker thread (ZERO UI freeze!)
                        if ('BingWallpaper.FastAccent' -as [type]) {
                            [byte[]]$rOut = $null
                            [byte[]]$gOut = $null
                            [byte[]]$bOut = $null
                            [BingWallpaper.FastAccent]::ExtractBatchRgb($thumbTargets, [ref]$rOut, [ref]$gOut, [ref]$bOut)
                            for ($k = 0; $k -lt $items.Count; $k++) {
                                if ($rOut -and $k -lt $rOut.Length) {
                                    $items[$k].accentR = $rOut[$k]
                                    $items[$k].accentG = $gOut[$k]
                                    $items[$k].accentB = $bOut[$k]
                                }
                            }
                            # RAM optimization: clean up temporary image decoding memory in background runspace
                            [System.GC]::Collect(0, [System.GCCollectionMode]::Forced, $false)
                        }

                        LogMsg "Downloaded and verified $($items.Count) thumbnails with dynamic accents in $ThumbDir"
                    } catch {
                        LogMsg "Error during parallel thumbnail download/accent extraction: $($_.Exception.Message)"
                    }
                }

                return $items
            }

            try {
                if ($Scope -eq 'Day') {
                    $targetDateStr = "$Year-" + $Month.ToString("00") + "-" + $Day.ToString("00")
                    LogMsg "Executing Day search for $targetDateStr in region $Country..."
                    $monthItems = FetchMonth $Country $Year $Month
                    $matched = $monthItems | Where-Object { $_.date -eq $targetDateStr }
                    if (-not $matched -and $monthItems.Count -gt 0) {
                        $matched = $monthItems | Where-Object { $_.dateText -match "\b0?$Day\b" }
                    }
                    if ($matched) {
                        LogMsg "Found matching wallpaper: $($matched.title) ($($matched.date))"
                    } else {
                        LogMsg "No wallpaper matched $targetDateStr in $($monthItems.Count) month items"
                    }
                    $Queue.Enqueue(@{ Type = 'DayResult'; Date = $targetDateStr; Matched = $matched })
                }
                elseif ($Scope -eq 'Month') {
                    $mStr = $Month.ToString("00")
                    LogMsg "Executing Month search for $Year-$mStr in region $Country..."
                    $monthItems = FetchMonth $Country $Year $Month
                    $Queue.Enqueue(@{ Type = 'MonthResult'; MonthStr = "$Year-$mStr"; Items = $monthItems })
                }
                elseif ($Scope -eq 'Year') {
                    LogMsg "Executing Year search for $Year in region $Country..."
                    $maxM = if ($Year -eq [DateTime]::Now.Year) { [DateTime]::Now.Month } else { 12 }
                    for ($m = $maxM; $m -ge 1; $m--) {
                        $mItems = FetchMonth $Country $Year $m
                        $Queue.Enqueue(@{ Type = 'YearMonthChunk'; Month = $m; Items = $mItems })
                        Start-Sleep -Milliseconds 120
                    }
                }
            }
            catch {
                LogMsg "Fatal error in archive worker: $($_.Exception.ToString())"
                $Queue.Enqueue(@{ Type = 'Error'; Message = $_.Exception.Message })
            }
            finally {
                $Queue.Enqueue(@{ Type = 'Completed' })
            }
        })

        [void]$ps.AddArgument($scope)
        [void]$ps.AddArgument($selRegionCode)
        [void]$ps.AddArgument($selYear)
        [void]$ps.AddArgument($selMonth)
        [void]$ps.AddArgument($selDay)
        [void]$ps.AddArgument($queue)
        [void]$ps.AddArgument($script:archiveLogPath)
        [void]$ps.AddArgument($thumbDir)

        Write-ArchiveLog "[SEARCH_START] Scope=$scope, Year=$selYear, Month=$selMonth, Day=$selDay, Region=$selRegionCode"

        $asyncHandle = $ps.BeginInvoke()

        $script:archiveSearchTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:archiveSearchTimer.Interval = [TimeSpan]::FromMilliseconds(40)

        $script:archiveSearchContext = @{
            PS           = $ps
            Handle       = $asyncHandle
            Queue        = $queue
            Scope        = $scope
            Year         = $selYear
            ThumbDir     = $thumbDir
            TotalCount   = 0
            IsFirstChunk = $true
            Timer        = $script:archiveSearchTimer
        }

        $script:archiveSearchTimer.Add_Tick({
            param($timerSender, $timerArgs)
            if (-not $script:archiveSearchContext) {
                $timerSender.Stop()
                return
            }

            $ctx = $script:archiveSearchContext
            while ($ctx.Queue.Count -gt 0) {
                $msg = $ctx.Queue.Dequeue()
                if ($msg.Type -eq 'DayResult') {
                    if ($msg.Matched) {
                        $StatusText.Text = "Loaded wallpaper for $($msg.Date)"
                        Render-GalleryGrid -Images @($msg.Matched) -ThumbCacheDir $ctx.ThumbDir
                        Write-ArchiveLog "[UI_RENDER] Rendered wallpaper for $($msg.Date): $($msg.Matched.title)"
                    } else {
                        $StatusText.Foreground = $statusErrorBrush
                        $StatusText.Text = "No Bing wallpaper found for $($msg.Date)"
                        Write-ArchiveLog "[UI_RESULT] No wallpaper found for $($msg.Date)"
                    }
                }
                elseif ($msg.Type -eq 'MonthResult') {
                    if ($msg.Items -and $msg.Items.Count -gt 0) {
                        $StatusText.Text = "Loaded $($msg.Items.Count) wallpapers for $($msg.MonthStr)"
                        Render-GalleryGrid -Images $msg.Items -ThumbCacheDir $ctx.ThumbDir
                        Write-ArchiveLog "[UI_RENDER] Rendered $($msg.Items.Count) wallpapers for $($msg.MonthStr)"
                    } else {
                        $StatusText.Foreground = $statusErrorBrush
                        $StatusText.Text = "No Bing wallpapers found for $($msg.MonthStr)"
                        Write-ArchiveLog "[UI_RESULT] No wallpapers found for $($msg.MonthStr)"
                    }
                }
                elseif ($msg.Type -eq 'YearMonthChunk') {
                    if ($msg.Items -and $msg.Items.Count -gt 0) {
                        $ctx.TotalCount += $msg.Items.Count
                        $curCount = $ctx.TotalCount
                        $mNum = $msg.Month
                        $StatusText.Text = "Loading $($ctx.Year) archive: $curCount wallpapers loaded (Month $mNum)..."
                        if ($ctx.IsFirstChunk) {
                            $ctx.IsFirstChunk = $false
                            Render-GalleryGrid -Images $msg.Items -ThumbCacheDir $ctx.ThumbDir
                        } else {
                            Render-GalleryGrid -Images $msg.Items -ThumbCacheDir $ctx.ThumbDir -Append
                        }
                        Write-ArchiveLog "[UI_RENDER] Appended Month $mNum ($($msg.Items.Count) items). Total: $curCount"
                    }
                }
                elseif ($msg.Type -eq 'Error') {
                    $StatusText.Foreground = $statusErrorBrush
                    $StatusText.Text = "Archive error: $($msg.Message)"
                    Write-ArchiveLog "[UI_ERROR] $($msg.Message)"
                }
                elseif ($msg.Type -eq 'Completed') {
                    $timerSender.Stop()
                    if ($ctx.Scope -eq 'Year') {
                        if ($ctx.TotalCount -gt 0) {
                            $StatusText.Text = "Loaded $($ctx.TotalCount) wallpapers for year $($ctx.Year)"
                        } else {
                            $StatusText.Foreground = $statusErrorBrush
                            $StatusText.Text = "No Bing wallpapers found for year $($ctx.Year)"
                        }
                    }
                    Write-ArchiveLog "[SEARCH_COMPLETE] Finished processing $($ctx.Scope) for $($ctx.Year)"
                    try { $ctx.PS.Dispose() } catch {}
                    $script:archiveSearchContext = $null
                    Invoke-MemoryFlush -Reason "ArchiveSearchComplete" -Async
                    return
                }
            }
        })

        $script:archiveSearchTimer.Start()
    })
}


$initialRegionCode = Get-DetectedRegionCode
$detectedItem = $RegionBox.Items | Where-Object { $_.Tag -eq $initialRegionCode } | Select-Object -First 1
if ($detectedItem) { 
    $RegionBox.SelectedItem = $detectedItem 
}

$window.Add_ContentRendered({
        Write-InteractionLog "[APP_STARTUP] ContentRendered fired"
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

        # Fast post-startup memory settle timer: 2.8 seconds after window renders, do a clean flush
        $script:initSettleTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:initSettleTimer.Interval = [TimeSpan]::FromMilliseconds(2800)
        $script:initSettleTimer.Add_Tick({
            $script:initSettleTimer.Stop()
            $script:initSettleTimer = $null
            Invoke-MemoryFlush -Reason "PostStartup-InitialSettle" -Async
        })
        $script:initSettleTimer.Start()
    })

$RefreshBtn.Add_Click({
        Write-InteractionLog "[REFRESH_CLICK] User clicked Refresh"
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
            Write-InteractionLog "[WINDOW_MINIMIZE] Window minimized"
            Invoke-MemoryFlush -Reason "WindowMinimized" -Async
        }
    })

$script:memTrimTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:memTrimTimer.Interval = [TimeSpan]::FromSeconds(30)
$script:memTrimTimer.Add_Tick({ Invoke-MemoryFlush -Reason "Periodic-Idle-Trim" -Async })
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




