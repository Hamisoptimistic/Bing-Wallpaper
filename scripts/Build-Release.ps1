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
if (-not (Test-Path -LiteralPath (Join-Path $rootFolder 'Bing-Wallpaper-UI.ps1'))) {
    $rootFolder = $scriptDir
}

$uiPath = Join-Path $rootFolder 'Bing-Wallpaper-UI.ps1'
$vbsPath = Join-Path $rootFolder 'Launch-AutoScape.vbs'
$setupPs1Path = Join-Path $rootFolder 'Setup.ps1'
$setupBatPath = Join-Path $rootFolder 'Setup.bat'
$nativeDllPath = Join-Path $rootFolder 'AutoScapeNative.dll'
$zipPath = Join-Path $rootFolder 'AutoScape.zip'
$zipShaPath = Join-Path $rootFolder 'AutoScape.zip.sha256'

$nativeCsCandidates = @(
    (Join-Path $rootFolder 'AutoScapeNative.cs'),
    (Join-Path $rootFolder 'src\AutoScapeNative.cs'),
    (Join-Path $rootFolder 'scripts\AutoScapeNative.cs')
)

$nativeCsPath = $nativeCsCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$iconCandidates = @(
    (Join-Path $rootFolder 'assets\app.ico'),
    (Join-Path $rootFolder 'app.ico'),
    (Join-Path $rootFolder 'assets\bing.ico'),
    (Join-Path $rootFolder 'bing.ico')
)

$iconPath = $iconCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$logoCandidates = @(
    (Join-Path $rootFolder 'assets\logo.png'),
    (Join-Path $rootFolder 'logo.png'),
    (Join-Path $rootFolder 'assets\logo.svg'),
    (Join-Path $rootFolder 'logo.svg')
)

$logoPath = $logoCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not (Test-Path -LiteralPath $uiPath)) {
    throw "Cannot find Bing-Wallpaper-UI.ps1 at $uiPath"
}
if (-not (Test-Path -LiteralPath $vbsPath)) {
    throw "Cannot find Launch-AutoScape.vbs at $vbsPath"
}
if (-not (Test-Path -LiteralPath $setupPs1Path)) {
    throw "Cannot find Setup.ps1 at $setupPs1Path"
}
if (-not (Test-Path -LiteralPath $setupBatPath)) {
    throw "Cannot find Setup.bat at $setupBatPath"
}

Write-Step "Resolving compiler (needed for AutoScapeNative.dll only)"

$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)

$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc -and $nativeCsPath) {
    throw 'csc.exe not found (needed to compile AutoScapeNative.dll).'
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

Write-Step "Building AutoScapeNative.dll"

if ($nativeCsPath) {
    Remove-Item -LiteralPath $nativeDllPath -Force -ErrorAction SilentlyContinue

    $nativeRefs = @()

    foreach ($asmName in @('System.Drawing', 'PresentationCore', 'WindowsBase')) {
        try {
            Add-Type -AssemblyName $asmName -ErrorAction Stop

            $loaded = [AppDomain]::CurrentDomain.GetAssemblies() |
                Where-Object { $_.GetName().Name -eq $asmName } |
                Select-Object -First 1

            if ($loaded -and $loaded.Location) {
                $nativeRefs += $loaded.Location
            }
        } catch {}
    }

    $compiledNative = $false

    if ($nativeRefs.Count -ge 3) {
        $nativeArgs = @(
            '/nologo',
            '/target:library',
            '/optimize+',
            '/nowarn:CS0618'
        )

        foreach ($ref in $nativeRefs) {
            $nativeArgs += "/reference:`"$ref`""
        }

        $nativeArgs += "/out:`"$nativeDllPath`""
        $nativeArgs += "`"$nativeCsPath`""

        & $csc @nativeArgs

        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $nativeDllPath)) {
            $compiledNative = $true
        }
    }

    if (-not $compiledNative) {
        Add-Type -Path $nativeCsPath `
            -ReferencedAssemblies @('System.Drawing', 'PresentationCore', 'WindowsBase') `
            -OutputAssembly $nativeDllPath `
            -OutputType Library `
            -IgnoreWarnings `
            -ErrorAction Stop
    }

    if (-not (Test-Path -LiteralPath $nativeDllPath)) {
        throw "Failed to compile AutoScapeNative.dll from $nativeCsPath"
    }
}
elseif (-not (Test-Path -LiteralPath $nativeDllPath)) {
    throw "Cannot find AutoScapeNative.cs or AutoScapeNative.dll. Add AutoScapeNative.cs to the repo root, or commit AutoScapeNative.dll."
}

Write-Step "Packaging AutoScape.zip (script-based distribution, no compiled exe)"

$stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("AutoScapePkg_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

try {
    Copy-Item -LiteralPath $uiPath -Destination (Join-Path $stagingDir 'Bing-Wallpaper-UI.ps1') -Force
    Copy-Item -LiteralPath $vbsPath -Destination (Join-Path $stagingDir 'Launch-AutoScape.vbs') -Force
    Copy-Item -LiteralPath $setupPs1Path -Destination (Join-Path $stagingDir 'Setup.ps1') -Force
    Copy-Item -LiteralPath $setupBatPath -Destination (Join-Path $stagingDir 'Setup.bat') -Force
    Copy-Item -LiteralPath $nativeDllPath -Destination (Join-Path $stagingDir 'AutoScapeNative.dll') -Force

    if ($iconPath) {
        $stagingAssets = Join-Path $stagingDir 'assets'
        New-Item -ItemType Directory -Path $stagingAssets -Force | Out-Null
        Copy-Item -LiteralPath $iconPath -Destination (Join-Path $stagingAssets 'app.ico') -Force
    }

    if ($logoPath) {
        $stagingAssets = Join-Path $stagingDir 'assets'
        New-Item -ItemType Directory -Path $stagingAssets -Force | Out-Null
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