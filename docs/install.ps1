# =====================================================================
# AutoScape 2.0 Web Installer & Bootstrapper (GitHub Pages Edition)
# Run in PowerShell:
#   irm https://hamisoptimistic.github.io/Bing-Wallpaper/install.ps1 | iex
# =====================================================================

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "               AutoScape 2.0 Web Installer            " -ForegroundColor White
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

$repoOwner = "Hamisoptimistic"
$repoName  = "Bing-Wallpaper"
$branch    = "main"

$zipUrl    = "https://github.com/$repoOwner/$repoName/archive/refs/heads/$branch.zip"
$appDir    = Join-Path $env:LOCALAPPDATA "AutoScape\app"
$tempZip   = Join-Path $env:TEMP "AutoScape_install.zip"
$tempDir   = Join-Path $env:TEMP "AutoScape_extracted"

# 1. Download latest repository zip
Write-Host "[1/4] Downloading latest AutoScape files from GitHub..." -ForegroundColor Yellow
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
    Write-Host "      Download completed successfully." -ForegroundColor Green
}
catch {
    Write-Host "      ERROR: Failed to download from GitHub. $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 2. Extract and install
Write-Host "[2/4] Installing to $appDir..." -ForegroundColor Yellow
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
Expand-Archive -Path $tempZip -DestinationPath $tempDir -Force

$extractedRoot = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
if (!(Test-Path $appDir)) {
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
}

Copy-Item -Path "$($extractedRoot.FullName)\*" -Destination $appDir -Recurse -Force

# 3. Clean temporary files
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "      Installation files extracted." -ForegroundColor Green

# 4. Create Desktop & Start Menu Shortcuts
Write-Host "[3/4] Creating Shortcuts..." -ForegroundColor Yellow
try {
    $wshShell = New-Object -ComObject WScript.Shell
    
    # Desktop Shortcut
    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $shortcutDesktop = $wshShell.CreateShortcut((Join-Path $desktopPath "AutoScape.lnk"))
    $shortcutDesktop.TargetPath = "powershell.exe"
    $shortcutDesktop.Arguments = "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$appDir\core\Bing-Wallpaper-UI.ps1`""
    $shortcutDesktop.WorkingDirectory = "$appDir\core"
    $shortcutDesktop.IconLocation = "$appDir\assets\icon.ico,0"
    $shortcutDesktop.Description = "AutoScape 4K Wallpaper Manager"
    $shortcutDesktop.Save()

    # Start Menu Shortcut
    $startMenuPrograms = [Environment]::GetFolderPath('Programs')
    $shortcutStart = $wshShell.CreateShortcut((Join-Path $startMenuPrograms "AutoScape.lnk"))
    $shortcutStart.TargetPath = "powershell.exe"
    $shortcutStart.Arguments = "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$appDir\core\Bing-Wallpaper-UI.ps1`""
    $shortcutStart.WorkingDirectory = "$appDir\core"
    $shortcutStart.IconLocation = "$appDir\assets\icon.ico,0"
    $shortcutStart.Description = "AutoScape 4K Wallpaper Manager"
    $shortcutStart.Save()
    Write-Host "      Shortcuts created." -ForegroundColor Green
}
catch {
    Write-Host "      (Optional shortcut creation skipped)" -ForegroundColor DarkGray
}

# 5. Launch the App
Write-Host "[4/4] Launching AutoScape..." -ForegroundColor Cyan
Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$appDir\core\Bing-Wallpaper-UI.ps1`""

Write-Host ""
Write-Host ">>> Done! AutoScape is now running." -ForegroundColor Green
