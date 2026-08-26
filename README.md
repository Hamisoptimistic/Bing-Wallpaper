<div align="center">

# Bing Wallpaper for Windows

**A native, ultra-lightweight Windows wallpaper utility that delivers Bing's daily high-resolution photography without draining your system resources.**

<br>

<a href="https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1">
  <img src="https://img.shields.io/badge/Download%20for%20Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Download for Windows" height="42">
</a>

<br><br>

<img src="https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D4?style=flat-square&logo=windows&logoColor=white" alt="Windows">
<img src="https://img.shields.io/badge/Runtime-PowerShell%205.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell">
<img src="https://img.shields.io/badge/Interface-Native%20WPF-68217A?style=flat-square" alt="WPF">
<img src="https://img.shields.io/badge/License-MIT-2EA44F?style=flat-square" alt="MIT License">

<br><br>

<img src="assets/Preview.jpg" alt="Bing Wallpaper Preview" width="880" style="border-radius: 8px; box-shadow: 0 8px 24px rgba(0,0,0,0.25);">

</div>

---

## Why this exists

Most modern wallpaper changers are bundled inside multi-megabyte Chromium or Electron wrappers that constantly consume 150MB to 400MB of RAM in the background just to swap a picture once a day.

**Bing Wallpaper for Windows is built differently:**

- **Near-Zero RAM Footprint**: Built directly with native PowerShell and Windows Presentation Foundation (WPF). There are no webviews, Node.js runtimes, or heavy background daemons sitting in memory.
- **Zero-Console Standalone App**: Launches instantly with `BingWallpaper.exe` with no command prompt window flashes.
- **True Background Automation**: When automated, updates are handed off to Windows Task Scheduler and executed invisibly through a native hidden runner. The UI never needs to stay open in the background.

---

## Key Features

### 1-Click Background Automation
Flip the **Auto** toggle inside the app, and Windows will automatically keep your wallpaper updated.
- **Custom Intervals**: Choose between *On Login*, *1 minute (test mode)*, *Hourly*, *Every 6 hours*, or *Daily*.
- **100% Silent Execution**: Bypasses Windows Terminal pop-ups completely using an invisible background runner.
- **Survives Restarts**: Managed directly by the Windows Task Scheduler engine—no need to keep the app running in your system tray.

### Complete Personalization
- **Multi-Target Support**: Apply images to your **Desktop**, **Lock Screen**, or **Both** simultaneously.
- **4K & High Resolutions**: Choose between **UHD (4K)**, **1080p Full HD**, or standard widescreen.
- **50+ International Regions**: Browse daily curated feeds from the US, UK, Japan, Germany, France, India, Australia, and dozens more.

### Live Gallery & Downloader
- **Interactive Grid**: Preview recent daily wallpapers with clean titles and photography credits.
- **Local Saver**: Apply wallpapers directly from memory cache or save high-resolution originals to your Pictures folder.

### Safe & Verified In-App Updates
- Check GitHub Releases directly from the app interface with integrated changelogs.
- Downloads are verified against published SHA-256 checksums before installation to ensure integrity.

---

## Getting Started

### Quick Start
1. Download **[`BingWallpaper.exe`](https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1)**.
2. Double-click to launch. No installer or administrative privileges required.
3. Pick any photo from the gallery and click **Apply**, or switch the **Auto** toggle to **ON** to automate daily updates.

---

## Usage Guide

### Interactive Mode
Launch `BingWallpaper.exe` to explore the gallery, switch regions, or change resolutions on demand.

### Automated Background Mode
1. Open the app.
2. Turn the **Auto** switch to **ON**.
3. Select your preferred interval (e.g. *Daily* or *Hourly*) and target (*Desktop* or *Both*).
4. Close the application. Windows will handle the rest silently in the background.

### Headless CLI Mode
For custom automation scripts or power users, run the script directly with arguments:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "Bing-Wallpaper-UI.ps1" -AutoApply -Region "en-US" -Resolution "UHD" -Target "Both"
```

---

## Building from Source

To compile the standalone `BingWallpaper.exe` launcher and create a desktop shortcut:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "scripts\Create-Bing-App-Shortcut.ps1"
```

---

## Security & System Impact

- **No Administrator Rights**: Runs entirely within standard user permissions.
- **Secure Networking**: Enforces TLS 1.2 and TLS 1.3 encryption on all connections.
- **Clean System Integration**: Settings and cache are kept organized under `%LOCALAPPDATA%\BingWallpaper`.

---

## License

This project is open source and available under the [MIT License](LICENSE).
Wallpapers and metadata provided by the Bing service are copyrighted by Microsoft and their respective photographers.