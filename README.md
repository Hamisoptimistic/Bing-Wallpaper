<div align="center">

# Bing Wallpaper for Windows

### A lightweight, native Windows utility for discovering, downloading, and applying Bing's daily wallpapers.

<br>

<a href="https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1">
  <img src="https://img.shields.io/badge/DOWNLOAD-BingWallpaper.exe-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Download BingWallpaper.exe">
</a>

<br><br>

<img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=flat-square&logo=windows&logoColor=white" alt="Windows">
<img src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white" alt="PowerShell">
<img src="https://img.shields.io/badge/UI-Native%20WPF-68217A?style=flat-square" alt="WPF">
<img src="https://img.shields.io/badge/License-MIT-2EA44F?style=flat-square" alt="MIT License">

<br><br>

<img src="assets/Preview.png" alt="Bing Wallpaper Preview" width="850">

</div>

---

## Overview

**Bing Wallpaper for Windows** brings Bing's daily photography directly to your desktop.

Browse recent wallpapers, choose your preferred region and resolution, apply images to your Desktop or Lock Screen, and optionally automate wallpaper changes in the background.

The application is designed to stay lightweight and use native Windows components rather than a heavyweight application framework.

---

## Features

<table>
<tr>
<td width="50%" valign="top">

### Native Windows Experience

Built with **PowerShell + WPF**, using native Windows components for a lightweight desktop application.

* Windows 10 and Windows 11 support
* Modern Windows 11-inspired interface
* Rounded corners and compact controls
* Borderless inputs
* Slim overlay scrollbars
* No heavyweight browser engine

</td>
<td width="50%" valign="top">

### Live Wallpaper Gallery

Browse recent Bing wallpapers directly from the application.

* Interactive wallpaper gallery
* High-resolution previews
* Recent daily wallpapers
* Multiple international regions
* Clean title parsing

</td>
</tr>

<tr>
<td width="50%" valign="top">

### Automatic Background Updates

Set your wallpaper to update automatically without keeping the application open.

**Available intervals**

* On Login
* 1 minute — test mode
* Hourly
* Every 6 hours
* Daily

Updates are handled through Windows Task Scheduler and continue after system restarts.

</td>
<td width="50%" valign="top">

### Flexible Personalization

Choose exactly where and how your wallpaper should be applied.

**Targets**

* Desktop
* Lock Screen
* Both

**Resolutions**

* UHD / 4K
* 1920 × 1080
* 1366 × 768

</td>
</tr>

<tr>
<td width="50%" valign="top">

### Download & Apply

Use wallpapers directly from the local cache or save high-resolution copies for later use.

* Apply directly
* Save wallpapers locally
* Select a destination folder
* High-resolution downloads

</td>
<td width="50%" valign="top">

### Verified Updates

The built-in updater checks GitHub Releases and verifies downloaded updates before installation.

* Release checking
* Release notes
* SHA-256 verification
* Verified executable updates

</td>
</tr>
</table>

---

## Download

<div align="center">

<a href="https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1">
  <img src="https://img.shields.io/badge/Download%20for%20Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Download for Windows">
</a>

<br><br>

**Standalone executable — no additional installation required.**

</div>

The standalone `BingWallpaper.exe` contains everything required to run the application.

---

## Getting Started

### 1. Launch

Run:

```text
BingWallpaper.exe
```

You can also launch the application using the **Bing Wallpaper** desktop shortcut.

### 2. Choose Your Preferences

Select:

| Setting        | Available Options              |
| -------------- | ------------------------------ |
| **Region**     | 50+ international Bing regions |
| **Resolution** | UHD, 1920×1080, 1366×768       |
| **Target**     | Desktop, Lock Screen, Both     |

### 3. Browse

Use the gallery to explore recent Bing wallpapers and select the image you want.

### 4. Apply or Save

Apply the selected wallpaper directly or save a high-resolution copy to your preferred folder.

---

## Automatic Wallpaper

Want Bing to change your wallpaper automatically?

Turn **Auto** on inside the application and select your preferred interval and target.

```text
Automatic Wallpaper
────────────────────────────────────────

Interval     [ Daily ▾ ]
Target       [ Desktop ▾ ]

                         [ ON ]
```

The application creates a Windows Task Scheduler task that performs wallpaper updates silently in the background.

The application does not need to remain open for scheduled updates to run.

---

## Supported Regions

Bing Wallpaper supports **50+ international regions**, allowing you to browse wallpapers from different Bing markets.

Examples include:

```text
United States     United Kingdom
Japan             Germany
France            India
Australia         Canada
```

Additional regions supported by Bing can be selected through the application's region selector.

---

## Command Line

The application includes a unified headless mode for automation and scripting.

### Example

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "Bing-Wallpaper-UI.ps1" -AutoApply -Region "en-US" -Resolution "UHD" -Target "Both"
```

### Parameters

| Parameter     | Description                                        |
| ------------- | -------------------------------------------------- |
| `-AutoApply`  | Runs wallpaper application without opening the GUI |
| `-Region`     | Selects the Bing region, for example `en-US`       |
| `-Resolution` | `UHD`, `1920x1080`, or `1366x768`                  |
| `-Target`     | `Desktop`, `Lock screen`, or `Both`                |

This makes the same application suitable for both interactive use and scheduled background execution.

---

## Desktop Shortcut

To regenerate the standalone executable and desktop shortcut:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "scripts\Create-Bing-App-Shortcut.ps1"
```

---

## Requirements

<div align="center">

| Requirement              | Version                                             |
| ------------------------ | --------------------------------------------------- |
| **Operating System**     | Windows 10 / Windows 11                             |
| **PowerShell**           | 5.1+                                                |
| **Internet**             | Required for retrieving Bing wallpapers and updates |
| **Administrator Rights** | Not required                                        |

</div>

The standalone executable does not require additional application dependencies.

---

## Security

The application is designed to operate entirely within the user's account.

* **Secure Connections** — TLS 1.2 / 1.3 is used for downloads.
* **Update Verification** — Updates are validated using SHA-256 checksums.
* **No Administrator Rights** — The application operates in user space.
* **Safe File Handling** — Paths and input are validated to help prevent unsafe file operations.
* **Silent Execution** — Background operations run without visible console windows.

---

## Architecture

Bing Wallpaper uses a deliberately lightweight architecture:

```text
┌─────────────────────────────────────┐
│          Bing Wallpaper UI          │
│          PowerShell + WPF           │
└──────────────────┬──────────────────┘
                   │
        ┌──────────┴──────────┐
        │                     │
        ▼                     ▼
   Bing Wallpaper        Local Cache
       API                    │
        │                     │
        └──────────┬──────────┘
                   │
                   ▼
          Windows Wallpaper
             Management
                   │
                   ▼
        Windows Task Scheduler
          (Automatic Updates)
```

The GUI, headless mode, and background automation share the same underlying application rather than requiring separate utilities.

---

## Project Structure

```text
Bing-Wallpaper/
│
├── Bing-Wallpaper-UI.ps1
├── BingWallpaper.exe
├── assets/
│   └── Preview.png
├── scripts/
│   └── Create-Bing-App-Shortcut.ps1
├── LICENSE
└── README.md
```

---

## License

This project is licensed under the **MIT License**.

See [LICENSE](LICENSE) for the complete license text.

Wallpaper images downloaded through this utility are copyrighted by Microsoft and their respective photographers.

---

<div align="center">

### Bing Wallpaper for Windows

**Beautiful wallpapers. Simple controls. Native Windows experience.**

<br>

<a href="https://github.com/Hamisoptimistic/Bing-Wallpaper">
  <img src="https://img.shields.io/badge/View%20Source%20Code-181717?style=for-the-badge&logo=github&logoColor=white" alt="View Source Code">
</a>

<a href="https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1">
  <img src="https://img.shields.io/badge/Download-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Download">
</a>

</div>
