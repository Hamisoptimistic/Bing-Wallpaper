<div align="center">

# Bing Wallpaper

### Daily 4K Bing wallpapers on Windows without background bloat.

<br/>

[![Download for Windows](https://img.shields.io/badge/Download-BingWallpaper.exe-0078D4?style=for-the-badge&logo=windows&logoColor=white)](https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1)

<br/><br/>

[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=flat-square&logo=windows&logoColor=white)](https://microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-5391FE?style=flat-square&logo=powershell&logoColor=white)](https://microsoft.com/PowerShell)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![Idle RAM](https://img.shields.io/badge/Idle%20RAM-0%20MB-brightgreen?style=flat-square)](#)

<br/><br/>

<img src="assets/Preview.jpg" alt="Bing Wallpaper for Windows" width="100%" />

</div>

---

## Highlights

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>⚡ Zero Background RAM</h3>
      Unlike Chromium or Electron wallpaper tools that eat 200MB+ of memory all day, this app exits completely when closed. Automated updates run through Windows Task Scheduler (<b>0 MB RAM</b> when idle).
    </td>
    <td width="50%" valign="top">
      <h3>🤫 100% Silent Automation</h3>
      Turn on the <b>Auto</b> toggle to update wallpapers on a schedule (On Login, 1 minute, Hourly, Every 6h, or Daily). Runs invisibly with zero terminal flashes or command prompt pop-ups.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>🎯 Multi-Target & 4K</h3>
      Apply wallpapers to your <b>Desktop</b>, <b>Lock Screen</b>, or <b>Both</b> with one click. Supports UHD (4K), 1080p Full HD, and custom aspect ratios.
    </td>
    <td width="50%" valign="top">
      <h3>🌍 50+ Global Feeds</h3>
      Browse recent daily wallpapers curated from over 50 international regions (US, UK, Japan, Germany, France, India, Australia, and more) with clean metadata.
    </td>
  </tr>
</table>

---

## Quick Start

### 1. Download & Launch
Download **[BingWallpaper.exe](https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1)** and double-click to run. No installer or administrator permissions needed.

### 2. Automatic Updates
Inside the application, turn the **Auto** switch to **ON**:
* **Interval**: Choose *On Login*, *1 minute (test)*, *Hourly*, *Every 6h*, or *Daily*.
* **Target**: Choose *Desktop*, *Lock screen*, or *Both*.

Close the app. Windows will update your wallpaper on schedule in the background, even after restarting your PC.

### 3. Headless CLI
You can also trigger silent updates directly from scripts or terminal:
```powershell
powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "Bing-Wallpaper-UI.ps1" -AutoApply -Region "en-US" -Resolution "UHD" -Target "Both"
```

---

## Comparison

| Feature | Bing Wallpaper | Official Bing Wallpaper | Electron / Webview Apps |
| :--- | :---: | :---: | :---: |
| **Idle RAM Usage** | **0 MB** (closed) | ~80 MB | ~200–400 MB |
| **No Admin Rights Needed** | **Yes** | No (requires install) | Varies |
| **4K / UHD Resolutions** | **Yes** | No | Varies |
| **Lock Screen Support** | **Yes** | No | Rare |
| **50+ Country Feeds** | **Yes** | No (US only) | Rare |
| **Zero Console Flashes** | **Yes** | Yes | Yes |
| **Standalone Executable** | **Yes** | No (MSI installer) | Large installer |

---

## Build from Source

To compile the standalone `BingWallpaper.exe` launcher from source:
```powershell
powershell.exe -ExecutionPolicy Bypass -File "scripts\Create-Bing-App-Shortcut.ps1"
```

---

## Security

- Enforces TLS 1.2 / TLS 1.3 encryption on all connections.
- Runs entirely in user-space without elevated privileges.
- SHA-256 integrity verification on in-app updates.

---

## License

This project is licensed under the [MIT License](LICENSE).
Images downloaded through this utility are copyrighted by Microsoft and their respective photographers.