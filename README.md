<div align="center">

<p align="center">
  <img src="assets/bing-color.svg" width="56" height="56" alt="Bing Wallpaper Logo" />
</p>

# Bing Wallpaper for Windows

**Daily 4K Bing photography delivered to your Desktop & Lock Screen with zero background resource drain.**

<p align="center">
  <a href="https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1">
    <img src="https://img.shields.io/badge/Download%20for%20Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Download Bing Wallpaper" />
  </a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D4?style=flat-square&logo=windows&logoColor=white" alt="Windows 10 / 11" />
  <img src="https://img.shields.io/badge/Runtime-PowerShell%205.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell 5.1+" />
  <img src="https://img.shields.io/badge/UI-Native%20WPF-68217A?style=flat-square" alt="Native WPF" />
  <img src="https://img.shields.io/badge/Idle%20Memory-0%20MB-brightgreen?style=flat-square" alt="0 MB Idle Memory" />
  <img src="https://img.shields.io/badge/License-MIT-2EA44F?style=flat-square" alt="MIT License" />
</p>

<br />

<img src="assets/Preview.jpg" width="100%" alt="Bing Wallpaper Application Preview" />

</div>

---

## Why Bing Wallpaper?

Most wallpaper utilities wrap web frameworks like Electron or Chromium, permanently hogging **150 MB to 400 MB of RAM** just to change a wallpaper once a day.

**Bing Wallpaper for Windows is built natively:**
- **0 MB Idle RAM**: The application exits completely when you close it. Automated background rotations are scheduled directly through Windows Task Scheduler—no background tray process or resident daemon needed.
- **100% Silent Execution**: Uses an invisible native runner to apply wallpapers in the background without terminal flashes or command prompt windows.
- **Zero-Console Standalone App**: Launches instantly via `BingWallpaper.exe` with no terminal pop-up.

---

## Features

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>⚡ Zero Resource Overhead</h3>
      Built with native PowerShell and WPF. When the window is closed, memory usage drops to <b>0 MB</b> while Windows Task Scheduler manages your background rotation.
    </td>
    <td width="50%" valign="top">
      <h3>🤫 1-Click Silent Automation</h3>
      Toggle <b>Auto</b> on to update wallpapers automatically. Choose from <i>On Login</i>, <i>1 minute (test)</i>, <i>Hourly</i>, <i>Every 6 hours</i>, or <i>Daily</i> with zero console flashes.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>🎯 Desktop & Lock Screen Support</h3>
      Personalize your <b>Desktop</b>, <b>Lock Screen</b>, or <b>Both</b> simultaneously. Select between UHD (4K), 1080p Full HD, or standard resolutions.
    </td>
    <td width="50%" valign="top">
      <h3>🌍 50+ Global Curations</h3>
      Browse and download daily high-resolution wallpapers curated from 50+ international regions (US, UK, Japan, Germany, France, India, Australia, and more).
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>🖼️ Live HD Gallery & Downloader</h3>
      Browse recent daily wallpapers, view photography metadata and locations, or download originals directly to your Pictures folder.
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
| **Idle Memory (RAM)** | **0 MB** (closed) | ~80 MB | ~200 MB – 400 MB |
| **No Admin Rights Required** | **Yes** | No (requires installer) | Varies |
| **4K / UHD Resolutions** | **Yes** | No | Varies |
| **Lock Screen Support** | **Yes** | No | Rare |
| **50+ Country Feeds** | **Yes** | No (US only) | Rare |
| **Zero Console Popups** | **Yes** | Yes | Yes |
| **Single Portable Binary** | **Yes** | No (MSI required) | Large bundle |

---

## Getting Started

### 1. Download & Launch
Download **[`BingWallpaper.exe`](https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1)** and double-click to run. No setup wizard or administrative permissions required.

### 2. Automatic Updates
Inside the application, turn the **Auto** toggle to **ON**:
1. Choose an interval (*On Login*, *1 minute*, *Hourly*, *Every 6h*, or *Daily*).
2. Choose a target (*Desktop*, *Lock screen*, or *Both*).
3. Close the app. Windows will automatically rotate your wallpaper silently in the background, even after restarting your PC.

### 3. Headless CLI
You can also run silent updates directly from scripts or the command line:
```powershell
powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "Bing-Wallpaper-UI.ps1" -AutoApply -Region "en-US" -Resolution "UHD" -Target "Both"
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