<div align="center">

<h1>
  <img src="assets/bing-color.svg" width="36" height="36" alt="Bing Logo" style="vertical-align: middle; margin-right: 8px;" />
  Bing Wallpaper for Windows
</h1>

<p><b>Daily 4K Bing photography delivered to your Desktop & Lock Screen with near-zero resource consumption.</b></p>

<p align="center">
  <a href="https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1">
    <img src="https://img.shields.io/badge/Download%20for%20Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Download Bing Wallpaper" />
  </a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D4?style=flat-square&logo=windows&logoColor=white" alt="Windows 10 / 11" />
  <img src="https://img.shields.io/badge/Runtime-PowerShell%205.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell 5.1+" />
  <img src="https://img.shields.io/badge/UI-Native%20WPF-68217A?style=flat-square" alt="Native WPF" />
  <img src="https://img.shields.io/badge/Active%20RAM-~50--60%20MB-blue?style=flat-square" alt="Active RAM" />
  <img src="https://img.shields.io/badge/Idle%20RAM-0%20MB-brightgreen?style=flat-square" alt="0 MB Idle RAM" />
  <img src="https://img.shields.io/badge/License-MIT-2EA44F?style=flat-square" alt="MIT License" />
</p>

<br />

<img src="assets/Preview.jpg" width="100%" alt="Bing Wallpaper Application Preview" />

</div>

---

## Why Bing Wallpaper?

Most wallpaper utilities wrap web frameworks like Electron or Chromium, permanently hogging **150 MB to 400 MB of RAM** just to change a wallpaper once a day.

**Bing Wallpaper for Windows is built natively:**
- **~50–60 MB Active RAM**: The lightweight WPF interface uses minimal memory while open.
- **0 MB Idle RAM**: The application exits completely when you close it. Automated background rotations are scheduled directly through Windows Task Scheduler—no background tray process or resident daemon needed.
- **100% Silent Execution**: Uses an invisible native runner to apply wallpapers in the background without terminal flashes or command prompt windows.
- **Zero-Console Standalone App**: Launches instantly via `BingWallpaper.exe` with no terminal pop-up.

---

## Features

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>⚡ Ultra-Low Memory Footprint</h3>
      Built with native PowerShell and WPF. Uses only <b>~50–60 MB RAM</b> when open, and drops to <b>0 MB</b> when closed while Windows Task Scheduler manages background rotation.
    </td>
    <td width="50%" valign="top">
      <h3>🎨 Modern Fluent UI & Hover Effects</h3>
      Windows 11-inspired dark aesthetic featuring smooth card hover animations, reveal borders, rounded controls, custom dark title bar integration, and clean typography.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>🤫 1-Click Silent Background Automation</h3>
      Toggle <b>Auto</b> on to update wallpapers automatically. Choose from <i>On Login</i>, <i>1 minute (test)</i>, <i>Hourly</i>, <i>Every 6 hours</i>, or <i>Daily</i> with zero console pop-ups.
    </td>
    <td width="50%" valign="top">
      <h3>🎯 Desktop & Lock Screen Support</h3>
      Personalize your <b>Desktop</b>, <b>Lock Screen</b>, or <b>Both</b> simultaneously. Select wallpaper styles: <i>Fit</i>, <i>Fill</i>, <i>Stretch</i>, <i>Center</i>, or <i>Tile</i>.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>📐 4K UHD & Crisp Resolutions</h3>
      Select your preferred resolution directly from the toolbar: <b>4K / UHD</b>, <b>1080p Full HD</b>, or standard widescreen formats.
    </td>
    <td width="50%" valign="top">
      <h3>🌍 50+ Global Country Feeds</h3>
      Explore and apply daily wallpapers curated from 50+ international regions (India, United States, United Kingdom, Japan, Germany, France, Australia, and more).
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>💾 Dedicated Wallpaper Downloader</h3>
      Save original, full-resolution 4K wallpaper images directly to your designated download folder with metadata and location info intact.
    </td>
    <td width="50%" valign="top">
      <h3>🔒 Verified In-App Updates</h3>
      Check and install updates directly from GitHub Releases with automatic SHA-256 integrity verification before execution.
    </td>
  </tr>
</table>

---

## Quick Comparison

| Feature | Bing Wallpaper | Official Bing Wallpaper | Electron / Webview Apps |
| :--- | :---: | :---: | :---: |
| **Active Memory (RAM)** | **~50–60 MB** | ~80–120 MB | ~200 MB – 400 MB |
| **Idle Memory (When Closed)** | **0 MB** | ~80 MB (Always resident) | ~200 MB – 400 MB (Always resident) |
| **4K / UHD Resolutions** | **Yes** | No | Varies |
| **Lock Screen Support** | **Yes** | No | Rare |
| **Wallpaper Style (Fit, Fill, Stretch, Tile)** | **Yes** | No | Rare |
| **50+ Country Feeds** | **Yes** | No (US only) | Rare |
| **High-Res Local Downloader** | **Yes** | No | Varies |
| **Modern Fluent UI & Hover Effects** | **Yes** (Native WPF) | Outdated Win32 | Webview / Heavy |
| **Background Automation Engine** | **Native Task Scheduler** | Background Tray Daemon | Background Node.js Process |
| **Single Portable Binary** | **Yes** | No (MSI required) | Large bundle |

---

## Getting Started

### 1. Download & Launch
Download **[`BingWallpaper.exe`](https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1)** and double-click to run. No setup wizard or administrative permissions required.

### 2. Automatic Updates
Inside the application, turn the **Auto** toggle to **ON**:
1. Choose an interval (*On Login*, *1 minute*, *Hourly*, *Every 6h*, or *Daily*).
2. Choose a target (*Desktop*, *Lock screen*, or *Both*) and style (*Fit*, *Fill*, *Stretch*, etc.).
3. Close the app. Windows will automatically rotate your wallpaper silently in the background, even after restarting your PC.

### 3. Headless CLI
You can also run silent updates directly from scripts or the command line:
```powershell
powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "Bing-Wallpaper-UI.ps1" -AutoApply -Region "en-US" -Resolution "UHD" -Target "Both" -Style "Fit"
```

---

## Building from Source

To compile the standalone `BingWallpaper.exe` launcher and create a desktop shortcut:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "scripts\Create-Bing-App-Shortcut.ps1"
```

---

## Security & Privacy

- **Encrypted Connections**: Enforces TLS 1.2 and TLS 1.3 across all network requests.
- **User-Space Only**: Runs with standard user privileges without administrative rights.
- **Integrity Verified**: Releases are signed with SHA-256 checksums verified before updating.

---

## License

This project is open-source under the [MIT License](LICENSE).
Wallpapers and imagery are copyrighted by Microsoft and their respective photographers.