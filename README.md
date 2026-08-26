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
    <td width="50%" align="center">
      <br />
      <b>⚡ Ultra-Low Memory Footprint</b>
      <br /><br />
      Built with native PowerShell and WPF. Uses only <b>~50–60 MB RAM</b> when open, and drops to <b>0 MB</b> when closed while Windows Task Scheduler manages background rotation.
      <br /><br />
    </td>
    <td width="50%" align="center">
      <br />
      <b>🎨 Modern Fluent UI & Hover Effects</b>
      <br /><br />
      Windows 11-inspired dark aesthetic featuring smooth card hover animations, reveal borders, rounded controls, custom dark title bar integration, and clean typography.
      <br /><br />
    </td>
  </tr>
  <tr>
    <td width="50%" align="center">
      <br />
      <b>🤫 1-Click Silent Background Automation</b>
      <br /><br />
      Toggle <b>Auto</b> on to update wallpapers automatically. Choose from <i>On Login</i>, <i>1 minute (test)</i>, <i>Hourly</i>, <i>Every 6 hours</i>, or <i>Daily</i> with zero console pop-ups.
      <br /><br />
    </td>
    <td width="50%" align="center">
      <br />
      <b>🎯 Desktop & Lock Screen Support</b>
      <br /><br />
      Personalize your <b>Desktop</b>, <b>Lock Screen</b>, or <b>Both</b> simultaneously. Select wallpaper styles: <i>Fit</i>, <i>Fill</i>, <i>Stretch</i>, <i>Center</i>, or <i>Tile</i>.
      <br /><br />
    </td>
  </tr>
  <tr>
    <td width="50%" align="center">
      <br />
      <b>📐 4K UHD & Crisp Resolutions</b>
      <br /><br />
      Select your preferred resolution directly from the toolbar: <b>4K / UHD</b>, <b>1080p Full HD</b>, or standard widescreen formats.
      <br /><br />
    </td>
    <td width="50%" align="center">
      <br />
      <b>🌍 50+ Global Country Feeds</b>
      <br /><br />
      Explore and apply daily wallpapers curated from 50+ international regions (India, United States, United Kingdom, Japan, Germany, France, Australia, and more).
      <br /><br />
    </td>
  </tr>
  <tr>
    <td width="50%" align="center">
      <br />
      <b>💾 Dedicated Wallpaper Downloader</b>
      <br /><br />
      Save original, full-resolution 4K wallpaper images directly to your designated download folder with metadata and location info intact.
      <br /><br />
    </td>
    <td width="50%" align="center">
      <br />
      <b>🔄 1-Click Seamless In-App Updates</b>
      <br /><br />
      Click <b>Check for updates</b> to instantly check GitHub Releases. The app validates SHA-256 checksums, downloads the new version, and auto-restarts seamlessly—no installers or manual file downloads needed.
      <br /><br />
    </td>
  </tr>
</table>

---

## Quick Comparison

| ![Feature](https://img.shields.io/badge/Feature-d73a49?style=for-the-badge) | ![Bing Wallpaper](https://img.shields.io/badge/Bing_Wallpaper-2ea44f?style=for-the-badge) | ![Official Bing Wallpaper](https://img.shields.io/badge/Official_Bing_Wallpaper-d73a49?style=for-the-badge) | ![Electron / WebView Apps](https://img.shields.io/badge/Electron_%2F_WebView_Apps-d73a49?style=for-the-badge) |
| :--- | :---: | :---: | :---: |
| **Active Memory (RAM)** | ![~50-60 MB](https://img.shields.io/badge/~50--60_MB-2ea44f?style=flat-square) | ~80–120 MB | ~200 MB – 400 MB |
| **Idle Memory (When Closed)** | ![0 MB](https://img.shields.io/badge/0_MB-2ea44f?style=flat-square) | ~80 MB *(Resident)* | ~200 MB – 400 MB *(Resident)* |
| **4K / UHD Resolutions** | ![Yes](https://img.shields.io/badge/✓_Yes-2ea44f?style=flat-square) | No | Varies |
| **Lock Screen Support** | ![Yes](https://img.shields.io/badge/✓_Yes-2ea44f?style=flat-square) | No | Rare |
| **Wallpaper Styles (Fit, Fill, etc.)** | ![Yes](https://img.shields.io/badge/✓_Yes-2ea44f?style=flat-square) | No | Rare |
| **50+ Country Feeds** | ![Yes](https://img.shields.io/badge/✓_Yes-2ea44f?style=flat-square) | No *(US only)* | Rare |
| **High-Res Local Downloader** | ![Yes](https://img.shields.io/badge/✓_Yes-2ea44f?style=flat-square) | No | Varies |
| **Modern Fluent UI & Hover Effects** | ![Native WPF](https://img.shields.io/badge/✓_Native_WPF-2ea44f?style=flat-square) | Outdated Win32 | WebView / Heavy |
| **1-Click Seamless In-App Updates** | ![SHA-256 Verified](https://img.shields.io/badge/✓_SHA--256_Verified-2ea44f?style=flat-square) | Proprietary Updater | Large Re-downloads |
| **Background Automation Engine** | ![Task Scheduler](https://img.shields.io/badge/✓_Task_Scheduler-2ea44f?style=flat-square) | Background Tray Daemon | Background Node.js Process |
| **Single Portable Binary** | ![Yes](https://img.shields.io/badge/✓_Yes-2ea44f?style=flat-square) | No *(MSI required)* | Large bundle |

---

## Getting Started

### 1. Download & Launch
Download **[`BingWallpaper.exe`](https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1)** and double-click to run. No setup wizard or administrative permissions required.

### 2. Automatic Updates
Inside the application, turn the **Auto** toggle to **ON**:
1. Choose an interval (*On Login*, *1 minute*, *Hourly*, *Every 6h*, or *Daily*).
2. Choose a target (*Desktop*, *Lock screen*, or *Both*) and style (*Fit*, *Fill*, *Stretch*, etc.).
3. Close the app. Windows will automatically rotate your wallpaper silently in the background, even after restarting your PC.

### 3. Effortless 1-Click Updates
Whenever a new update is released, staying up to date is completely effortless:
1. Click **Check for updates** in the bottom-left corner of the app.
2. If a new version is found, click **Yes** to update.
3. The app automatically downloads the release, verifies its SHA-256 checksum for security, replaces the executable, and relaunches the newest version in seconds.

### 4. Headless CLI
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
- **Cryptographic Verification**: In-app updates verify cryptographic SHA-256 checksums before applying to prevent corrupted or unauthorized binaries.

---

## License

This project is open-source under the [MIT License](LICENSE).
Wallpapers and imagery are copyrighted by Microsoft and their respective photographers.