<div align="center">

# <img src="./assets/bing-color.svg" width="32" height="32" alt="Bing" /> Bing Wallpaper for Windows

**Daily Bing photography for your Desktop & Lock Screen — lightweight, native, and silent.**

<br>

[![Download for Windows](https://img.shields.io/badge/Download%20for%20Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white)](https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1)

<br>

![Windows 10 / 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?style=flat-square&logo=windows&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white)
![WPF](https://img.shields.io/badge/UI-Native%20WPF-68217A?style=flat-square)
![RAM](https://img.shields.io/badge/Active%20RAM-~50--60%20MB-0078D4?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-2EA44F?style=flat-square)

<br><br>

<img src="./assets/Preview.png" width="900" alt="Bing Wallpaper for Windows preview">

</div>

---

## Why Bing Wallpaper?

Bing Wallpaper for Windows is a lightweight native Windows utility for discovering, downloading, and applying Bing's daily wallpapers.

Unlike wallpaper applications built around heavyweight web runtimes, this project uses **PowerShell and native WPF** and exits completely when you close the interface. Automatic updates are handled by **Windows Task Scheduler**, so there is no resident tray process required.

| | |
|---|---|
| **~50–60 MB Active RAM** | Lightweight native WPF interface while the app is open |
| **0 MB Idle RAM** | The GUI exits completely when closed |
| **Silent Automation** | Background rotation is handled by Windows Task Scheduler |
| **Standalone EXE** | Launch directly without an installer or console window |

---

## Features

<table>
<tr>
<td width="50%" valign="top">

### Ultra-Low Memory Footprint

Built with native PowerShell and WPF rather than a heavyweight web framework.

**~50–60 MB RAM while open**  
**0 MB when closed**

</td>
<td width="50%" valign="top">

### Modern Windows 11 UI

A clean native interface with rounded controls, subtle hover effects, a custom dark title bar, compact gallery, and focused typography.

</td>
</tr>

<tr>
<td width="50%" valign="top">

### Silent Background Automation

Enable **Auto** and choose:

`On Login` · `1 minute (test)` · `Hourly` · `Every 6 hours` · `Daily`

Updates continue silently through Windows Task Scheduler, even after restarting your PC.

</td>
<td width="50%" valign="top">

### Desktop & Lock Screen

Apply wallpapers to:

`Desktop` · `Lock Screen` · `Both`

Choose from:

`Fit` · `Fill` · `Stretch` · `Center` · `Tile`

</td>
</tr>

<tr>
<td width="50%" valign="top">

### 4K UHD Support

Choose the resolution that fits your display:

`UHD / 4K` · `1920 × 1080` · `1366 × 768`

</td>
<td width="50%" valign="top">

### 50+ Global Regions

Browse daily Bing photography from more than **50 international regions**, including India, United States, United Kingdom, Japan, Germany, France, Australia, and more.

</td>
</tr>

<tr>
<td width="50%" valign="top">

### Full-Resolution Downloads

Save original high-resolution wallpapers directly to your preferred folder, with available metadata and location information preserved.

</td>
<td width="50%" valign="top">

### Verified In-App Updates

Check GitHub Releases directly from the application. Updates are downloaded, validated with **SHA-256**, installed, and followed by an automatic restart.

</td>
</tr>
</table>

---

## Quick Comparison

| Feature | **Bing Wallpaper** | Official Bing Wallpaper | Electron / WebView Apps |
|---|:---:|:---:|:---:|
| **Active RAM** | **~50–60 MB** | ~80–120 MB | ~200–400 MB |
| **Idle RAM** | **0 MB** | ~80 MB | ~200–400 MB |
| **4K / UHD** | **Yes** | No | Varies |
| **Lock Screen** | **Yes** | No | Rare |
| **Wallpaper Styles** | **Yes** | No | Rare |
| **50+ Country Feeds** | **Yes** | No (US only) | Rare |
| **High-Res Downloader** | **Yes** | No | Varies |
| **Native WPF UI** | **Yes** | Limited | No |
| **In-App Updates** | **Yes** | Yes | Varies |
| **Background Automation** | **Task Scheduler** | Background Process | Node.js Process |
| **Portable Binary** | **Yes** | No | Large Bundle |

---

## Getting Started

### 1. Download

[![Download BingWallpaper.exe](https://img.shields.io/badge/Download%20BingWallpaper.exe-0078D4?style=for-the-badge&logo=windows&logoColor=white)](https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1)

Run `BingWallpaper.exe` directly.

No setup wizard or administrator permissions are required.

### 2. Choose Your Preferences

Select your:

- **Region**
- **Resolution**
- **Target**
- **Wallpaper Style**

### 3. Browse & Apply

Browse recent Bing wallpapers in the gallery, select an image, and apply it to your Desktop, Lock Screen, or both.

You can also save the original high-resolution image locally.

### 4. Enable Automatic Updates

Turn **Auto** on and select your preferred interval and target.

Once configured, you can close the application. Windows Task Scheduler handles future wallpaper rotations silently in the background.

---

## Automatic Wallpaper

Automatic wallpaper rotation works without keeping the application open.

```text
Automatic Wallpaper
────────────────────────────────────────

Interval     [ Daily ▾ ]
Target       [ Desktop ▾ ]

                         [ ON ]
```

### Intervals

`On Login` · `1 minute (test)` · `Hourly` · `Every 6 hours` · `Daily`

### Targets

`Desktop` · `Lock Screen` · `Both`

---

## Global Regions

Bing Wallpaper supports more than **50 international Bing regions**.

Some examples:

| | | |
|---|---|---|
| United States | United Kingdom | Japan |
| Germany | France | India |
| Australia | Canada | More available |

---

## Command Line

The application includes a unified headless mode for scripting and automation.

### Example

```powershell
powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "Bing-Wallpaper-UI.ps1" -AutoApply -Region "en-US" -Resolution "UHD" -Target "Both" -Style "Fit"
```

### Parameters

| Parameter | Description |
|---|---|
| `-AutoApply` | Runs wallpaper application without opening the GUI |
| `-Region` | Selects the Bing region, for example `en-US` |
| `-Resolution` | `UHD`, `1920x1080`, or `1366x768` |
| `-Target` | `Desktop`, `Lock screen`, or `Both` |
| `-Style` | `Fit`, `Fill`, `Stretch`, `Center`, or `Tile` |

---

## Building from Source

To generate the standalone executable and desktop shortcut:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "scripts\Create-Bing-App-Shortcut.ps1"
```

---

## Requirements

| Requirement | Details |
|---|---|
| **Operating System** | Windows 10 / Windows 11 |
| **PowerShell** | 5.1+ |
| **Internet Connection** | Required for Bing wallpaper and update downloads |
| **Administrator Rights** | Not required |

The standalone executable includes everything required to run the application.

---

## Security

- **TLS 1.2 / 1.3** — Secure network connections for downloads.
- **SHA-256 Verification** — Updates are verified before installation.
- **User-Space Operation** — No administrator privileges required.
- **Safe File Handling** — Input and file paths are validated.
- **Silent Execution** — Scheduled operations run without visible console windows.

---

## Project Structure

```text
Bing-Wallpaper/
│
├── Bing-Wallpaper-UI.ps1
├── BingWallpaper.exe
├── assets/
│   ├── bing-color.svg
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

<img src="./assets/bing-color.svg" width="28" height="28" alt="Bing">

### Bing Wallpaper for Windows

**Beautiful wallpapers. Simple controls. Native Windows experience.**

<br>

[![View Source](https://img.shields.io/badge/View%20Source%20Code-181717?style=for-the-badge&logo=github&logoColor=white)](https://github.com/Hamisoptimistic/Bing-Wallpaper)
[![Download](https://img.shields.io/badge/Download-0078D4?style=for-the-badge&logo=windows&logoColor=white)](https://github.com/Hamisoptimistic/Bing-Wallpaper/raw/main/BingWallpaper.exe?download=1)

<br>

<sub>Built with PowerShell and native WPF for Windows.</sub>

</div>
