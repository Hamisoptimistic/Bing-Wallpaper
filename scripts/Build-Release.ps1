$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    $scriptDir = (Get-Location).Path
}

$rootFolder = Split-Path -Parent $scriptDir

# Fallback if someone runs the script from repo root instead of scripts folder
if (-not (Test-Path -LiteralPath (Join-Path $rootFolder 'core\Bing-Wallpaper-UI.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $rootFolder 'Bing-Wallpaper-UI.ps1'))) {
    $rootFolder = $scriptDir
}

$coreFolder = Join-Path $rootFolder 'core'
$uiPath = if (Test-Path -LiteralPath (Join-Path $coreFolder 'Bing-Wallpaper-UI.ps1')) { Join-Path $coreFolder 'Bing-Wallpaper-UI.ps1' } else { Join-Path $rootFolder 'Bing-Wallpaper-UI.ps1' }
$setupPs1Path = if (Test-Path -LiteralPath (Join-Path $coreFolder 'Setup.ps1')) { Join-Path $coreFolder 'Setup.ps1' } else { Join-Path $rootFolder 'Setup.ps1' }
$setupBatPath = Join-Path $rootFolder 'Setup.bat'
$userGuideModalPath = if (Test-Path -LiteralPath (Join-Path $coreFolder 'AutoScape-UserGuideModal.ps1')) { Join-Path $coreFolder 'AutoScape-UserGuideModal.ps1' } else { Join-Path $rootFolder 'AutoScape-UserGuideModal.ps1' }
$updaterModulePath = if (Test-Path -LiteralPath (Join-Path $coreFolder 'AutoScape-Updater.ps1')) { Join-Path $coreFolder 'AutoScape-Updater.ps1' } else { Join-Path $rootFolder 'AutoScape-Updater.ps1' }
$sourcesModulePath = if (Test-Path -LiteralPath (Join-Path $coreFolder 'AutoScape-Sources.ps1')) { Join-Path $coreFolder 'AutoScape-Sources.ps1' } else { Join-Path $rootFolder 'AutoScape-Sources.ps1' }
$zipPath = Join-Path $rootFolder 'AutoScape.zip'
$zipShaPath = Join-Path $rootFolder 'AutoScape.zip.sha256'

$iconCandidates = @(
    (Join-Path $rootFolder 'assets\app.ico'),
    (Join-Path $coreFolder 'assets\app.ico'),
    (Join-Path $rootFolder 'app.ico'),
    (Join-Path $rootFolder 'assets\bing.ico'),
    (Join-Path $rootFolder 'bing.ico')
)

$iconPath = $iconCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$logoCandidates = @(
    (Join-Path $rootFolder 'assets\logo.png'),
    (Join-Path $coreFolder 'assets\logo.png'),
    (Join-Path $rootFolder 'logo.png'),
    (Join-Path $rootFolder 'assets\logo.svg'),
    (Join-Path $rootFolder 'logo.svg')
)

$logoPath = $logoCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not (Test-Path -LiteralPath $uiPath)) {
    throw "Cannot find Bing-Wallpaper-UI.ps1 at $uiPath"
}
if (-not (Test-Path -LiteralPath $userGuideModalPath)) {
    throw "Cannot find AutoScape-UserGuideModal.ps1 at $userGuideModalPath"
}
if (-not (Test-Path -LiteralPath $updaterModulePath)) {
    throw "Cannot find AutoScape-Updater.ps1 at $updaterModulePath"
}
if (-not (Test-Path -LiteralPath $sourcesModulePath)) {
    throw "Cannot find AutoScape-Sources.ps1 at $sourcesModulePath"
}
if (-not (Test-Path -LiteralPath $setupPs1Path)) {
    throw "Cannot find Setup.ps1 at $setupPs1Path"
}
if (-not (Test-Path -LiteralPath $setupBatPath)) {
    throw "Cannot find Setup.bat at $setupBatPath"
}

Write-Step "Generating version"

$appVersion = '1.0.0'

try {
    Push-Location $rootFolder
    $commitCount = (git rev-list --count HEAD 2>$null)

    if ($commitCount -and ($commitCount.Trim() -match '^\d+$')) {
        $appVersion = "1.0.$($commitCount.Trim())"
    }

    Pop-Location
} catch {
    Pop-Location -ErrorAction SilentlyContinue
}

Write-Host "Generated Auto-Version: $appVersion"

Write-Step "Stamping version into UI script"

$uiRaw = Get-Content -LiteralPath $uiPath -Raw
$versionPattern = "\`$script:appVersion\s*=\s*\[Version\]'[^']*'"

if ($uiRaw -match $versionPattern) {
    $replacement = '$script:appVersion = [Version]''' + $appVersion + ''''
    $uiRaw = $uiRaw -replace $versionPattern, $replacement
    Set-Content -LiteralPath $uiPath -Value $uiRaw -Encoding UTF8
}

if ($env:GITHUB_OUTPUT) {
    "version=$appVersion" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding ascii -Append
} else {
    Write-Host "version=$appVersion"
}

Write-Step "Packaging AutoScape.zip (script-based distribution, no compiled exe)"

$stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("AutoScapePkg_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

try {
    # The root of the zip contains ONLY Setup.bat
    Copy-Item -LiteralPath $setupBatPath -Destination (Join-Path $stagingDir 'Setup.bat') -Force

    # All scripts, modules, and assets live neatly inside the 'core' folder
    $stagingCore = Join-Path $stagingDir 'core'
    New-Item -ItemType Directory -Path $stagingCore -Force | Out-Null

    Copy-Item -LiteralPath $uiPath -Destination (Join-Path $stagingCore 'Bing-Wallpaper-UI.ps1') -Force
    Copy-Item -LiteralPath $userGuideModalPath -Destination (Join-Path $stagingCore 'AutoScape-UserGuideModal.ps1') -Force
    Copy-Item -LiteralPath $updaterModulePath -Destination (Join-Path $stagingCore 'AutoScape-Updater.ps1') -Force
    Copy-Item -LiteralPath $sourcesModulePath -Destination (Join-Path $stagingCore 'AutoScape-Sources.ps1') -Force
    Copy-Item -LiteralPath $setupPs1Path -Destination (Join-Path $stagingCore 'Setup.ps1') -Force

    $stagingAssets = Join-Path $stagingCore 'assets'
    New-Item -ItemType Directory -Path $stagingAssets -Force | Out-Null

    if ($iconPath) {
        Copy-Item -LiteralPath $iconPath -Destination (Join-Path $stagingAssets 'app.ico') -Force
    }

    if ($logoPath) {
        $logoExt = [System.IO.Path]::GetExtension($logoPath)
        Copy-Item -LiteralPath $logoPath -Destination (Join-Path $stagingAssets "logo$logoExt") -Force
    }

    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $stagingDir '*') -DestinationPath $zipPath -Force
}
finally {
    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $zipPath)) {
    throw "Failed to create $zipPath"
}

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $zipShaPath -Value "$hash  AutoScape.zip" -Encoding ASCII

if ($env:GITHUB_OUTPUT) {
    "hash=$hash" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding ascii -Append
}
Write-Host "hash=$hash"

Write-Step "Done"
Write-Host "Created $zipPath"
Write-Host "Created $zipShaPath"