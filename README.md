# Bing Wallpaper for Windows

A lightweight, native Windows utility that applies Bing's daily wallpapers without running a heavy background process all day.

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6.svg)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://microsoft.com/PowerShell)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

![Bing Wallpaper preview](assets/Preview.png)

## Download

<a href="https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1"><img src="https://img.shields.io/badge/Download-BingWallpaper.exe-107C10?style=for-the-badge&logo=windows&logoColor=white" alt="Download BingWallpaper.exe"></a>

The standalone `BingWallpaper.exe` includes everything needed to run. No extra dependencies or installations are required.

---

## Features

<<<<<<< HEAD
- **Lightweight & Fast**: Built with PowerShell and native WPF for minimal resource usage.
- **Silent Background Automation**: Set wallpaper updates on a schedule without terminal windows or pop-ups.
- **Customizable Intervals**: Update on login, every minute, hourly, every 6 hours, or daily.
- **Multi-Target Support**: Apply wallpapers to Desktop, Lock Screen, or both.
- **Global Region Selection**: Browse daily wallpapers from over 50 international regions.
- **Resolution Options**: Supports UHD (4K), 1080p Full HD, and 1366×768.
- **Image Gallery & Downloader**: Preview recent daily wallpapers and save high-resolution copies locally.
- **Verified Updates**: Built-in update checker that validates releases via SHA-256 checksums.
=======
- 🪶 **Native by design**: A straightforward PowerShell + WPF UI with minimal moving parts and no heavyweight application framework.
- 🧠 **Ultra-low RAM footprint**: The app avoids a resident browser engine and runs only when you need to choose or apply a wallpaper.
- 🎨 **Clean Windows 11 UI**: Native dark title bar with rounded corners, a compact gallery, borderless inputs, and slim overlay scrollbars.
- 🚀 **Zero-Console Standalone Launcher (`BingWallpaper.exe`)**: Launches immediately with zero terminal flash and the authentic high-resolution Bing icon.
- ⏰ **Automated Background Spotlight (In-App Toggle)**: 1-click automatic wallpaper rotation that runs in the background even when the app is closed and persists across PC restarts.
- 🤫 **100% Silent Execution**: Completely bypasses Windows 11 Windows Terminal pop-ups using a native hidden wrapper—guaranteed zero console flashes.
- ⏱️ **Flexible Intervals**: Choose between **On Login**, **1 minute (test)**, **Hourly**, **Every 6h**, or **Daily**.
- 🌍 **Global Country Support**: Browse wallpapers from 50+ international regions (United States, United Kingdom, Japan, Germany, France, India, Australia, etc.) with automatic clean title parsing.
- 🖼️ **Live HD Gallery**: Visual interactive grid previewing recent Bing wallpapers.
- 🔄 **Verified In-App Updates**: Checks GitHub Releases, shows release notes, and installs only an EXE matching the release's SHA-256 checksum.
- 🖥️ **Multi-Target Personalization**: Apply wallpapers directly to **Desktop**, **Lock Screen**, or **Both**.
- 📐 **Resolution Support**: Choose between **UHD (4K)**, **1080p Full HD**, or **1366×768**.
- 💾 **Dedicated Downloader**: Apply directly from memory cache or save high-res files to your chosen folder.
- ⏱️ **Unified Headless CLI (`-AutoApply`)**: One single unified script for interactive GUI, automation toggle, and background Task Scheduler automation.
>>>>>>> 077ca693e884066bf2fa64e75bc1698ce0100d1b

---

## Usage

### 1. Launching the App
Run **`BingWallpaper.exe`** (or use the **`Bing Wallpaper`** desktop shortcut) to open the interface.

### 2. Automatic Background Updates
Inside the application, turn the **Auto** toggle to **ON**:
- **Interval**: Choose between *On Login*, *1 minute*, *Hourly*, *Every 6h*, or *Daily*.
- **Target**: Choose *Desktop*, *Lock screen*, or *Both*.

The app schedules the update via Windows Task Scheduler. It runs completely silently in the background, even when the application is closed and after computer restarts.

### 3. Command Line (Headless Mode)
You can apply wallpapers directly from the terminal or scripts:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "Bing-Wallpaper-UI.ps1" -AutoApply -Region "en-US" -Resolution "UHD" -Target "Both"
```

### 4. Create / Repair Desktop Shortcut
To regenerate the standalone executable and desktop shortcut:
```powershell
powershell.exe -ExecutionPolicy Bypass -File "scripts\Create-Bing-App-Shortcut.ps1"
```

---

## Security

- **Secure Connections**: Uses TLS 1.2 / 1.3 for all downloads.
- **No Administrator Rights Needed**: Operates entirely in user space.
- **Safe File Handling**: Validates paths and input to prevent traversal issues.

---

## License

This project is licensed under the [MIT License](LICENSE).
Images downloaded through this utility are copyrighted by Microsoft and their respective photographers.
