# Bing Wallpaper for Windows

> A deliberately native, low-overhead Windows wallpaper utility for people who want Bing's daily images without a heavy desktop app running all day.

This project keeps the UI intentionally simple: one PowerShell script, a small WPF surface, and a tiny launcher. There is no browser shell, background framework, or bundled runtime. The result is a focused tool designed for ultra-low RAM consumption while it is idle, with an optional headless mode for scheduled wallpaper updates.

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6.svg)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://microsoft.com/PowerShell)
[![UI](https://img.shields.io/badge/design-Windows%2011%20Fluent%20Dark-8B5CF6.svg)](#features)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Admin](https://img.shields.io/badge/privileges-No%20Admin%20Required-brightgreen.svg)](#)

![Bing Wallpaper preview](assets/Preview.png)

## 📦 Download

<a href="https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1"><img src="https://img.shields.io/badge/Download-BingWallpaper.exe-107C10?style=for-the-badge&logo=windows&logoColor=white" alt="Download BingWallpaper.exe"></a>

The standalone EXE embeds the PowerShell UI and works by itself. No additional files are required.

---

## ✨ Features

- 🪶 **Naive by design**: A straightforward PowerShell + WPF UI with minimal moving parts and no heavyweight application framework.
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

---

## 🔐 Publishing a verified update

The **Check for updates** button reads the repository's latest GitHub Release. To publish an update it can accept, use a versioned tag such as `v1.0.1`, then upload these two release assets with exactly these names:

- `BingWallpaper.exe`
- `BingWallpaper.exe.sha256`

Run `scripts\Create-Bing-App-Shortcut.ps1` after updating `$script:appVersion` in `Bing-Wallpaper-UI.ps1`; it builds the EXE and generates the matching checksum file. Upload both files to the same GitHub Release. For Authenticode enforcement, sign the EXE before generating its checksum, then set `$script:updatePublisherThumbprint` to the signing certificate's thumbprint before building the next version.

---

## 📁 Project Structure

```
WinDesktop-Bing-wallpapers/
│
├── assets/                       # High-resolution icons and vector assets
│   ├── bing-color.svg
│   └── bing.ico
│
├── scripts/                      # Setup and batch helper scripts
│   ├── Change-Bing-Wallpaper.bat
│   ├── Create-Bing-App-Shortcut.ps1
│   └── Open-Bing-Wallpaper-UI.bat
│
├── .gitignore                    # Git ignore rules
├── BingWallpaper.exe             # Standalone zero-console launcher with embedded icon
├── Bing-Wallpaper-UI.ps1         # Unified application (GUI & CLI -AutoApply)
├── LICENSE                       # MIT License
└── README.md                     # Documentation
```

---

## 🚀 Usage

### 1. Interactive GUI App
Double-click **`BingWallpaper.exe`** (or the **`Bing Wallpaper`** desktop shortcut) to launch the GUI.

### 2. Automated Background Updates (Built-in Toggle)
Inside the app, simply switch the **Auto** toggle to **ON**:
- Select your preferred interval (**On Login**, **1 minute**, **Hourly**, **Every 6h**, or **Daily**).
- Choose the target (**Desktop**, **Lock screen**, or **Both**).
- The app automatically configures Windows Task Scheduler to run completely silently in the background with zero pop-ups, even when the UI is closed and after restarting your PC.

### 3. Headless CLI / Manual Automation
You can also run the script manually or from your own scripts using headless mode:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "Bing-Wallpaper-UI.ps1" -AutoApply -Region "en-US" -Resolution "UHD" -Target "Both"
```

### 4. Re-create Desktop Shortcut
To create or refresh the desktop shortcut and compile `BingWallpaper.exe`:
```powershell
powershell -ExecutionPolicy Bypass -File "scripts\Create-Bing-App-Shortcut.ps1"
```

---

## 🔒 Security & Reliability

- **Modern TLS Protocols**: Enforced TLS 1.3 / 1.2 negotiation (`[Net.SecurityProtocolType]::Tls12 -bor Tls13`).
- **Safe URI & Path Validation**: Strict regex character stripping and path traversal protection.
- **No Elevated Privileges**: Runs 100% in user-space without requiring Administrator rights.

---

## 📜 License

This project is licensed under the [MIT License](LICENSE).
Images downloaded through this utility are copyrighted by Microsoft and their respective photographers.
