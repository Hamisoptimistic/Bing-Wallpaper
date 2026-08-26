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

- **Lightweight & Fast**: Built with PowerShell and native WPF for minimal resource usage.
- **Silent Background Automation**: Set wallpaper updates on a schedule without terminal windows or pop-ups.
- **Customizable Intervals**: Update on login, every minute, hourly, every 6 hours, or daily.
- **Multi-Target Support**: Apply wallpapers to Desktop, Lock Screen, or both.
- **Global Region Selection**: Browse daily wallpapers from over 50 international regions.
- **Resolution Options**: Supports UHD (4K), 1080p Full HD, and 1366×768.
- **Image Gallery & Downloader**: Preview recent daily wallpapers and save high-resolution copies locally.
- **Verified Updates**: Built-in update checker that validates releases via SHA-256 checksums.

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
