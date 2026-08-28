[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# 1. Determine Version
$commitCount = (git rev-list --count HEAD).Trim()
if (-not ($commitCount -match '^\d+$')) { $commitCount = '1' }
$ver = "1.0.$commitCount"
Write-Host "Generated Auto-Version: $ver"

# 2. Extract Native C# Code from Bing-Wallpaper-UI.ps1
$uiScriptPath = ".\Bing-Wallpaper-UI.ps1"
$uiContent = Get-Content -LiteralPath $uiScriptPath -Raw

$nativePattern = '(?s)\$nativeHelperCode\s*=\s*@''\r?\n(.*?)\r?\n''@'
if ($uiContent -match $nativePattern) {
    $nativeSource = $Matches[1]
} else {
    throw "Could not extract `$nativeHelperCode block from $uiScriptPath"
}

# 3. Pre-compile DLL on CI Runner
$tempDll = Join-Path ([System.IO.Path]::GetTempPath()) "AutoScapeNative.dll"
if (Test-Path -LiteralPath $tempDll) {
    Remove-Item -LiteralPath $tempDll -Force -ErrorAction SilentlyContinue
}

$compileParams = @{
    TypeDefinition       = $nativeSource
    ReferencedAssemblies = @('System.Drawing', 'PresentationCore', 'WindowsBase')
    OutputAssembly       = $tempDll
    OutputType           = 'Library'
    IgnoreWarnings       = $true
}
Add-Type @compileParams | Out-Null

$base64Dll = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($tempDll))

# 4. Inject Version & Base64 Payload into Bing-Wallpaper-UI.ps1
$uiContent = $uiContent -replace '\$script:appVersion\s*=\s*\[Version\][''"][^''"]+[''"]', "`$script:appVersion = [Version]'$ver'"
$uiContent = $uiContent -replace '__AUTOSCAPE_NATIVE_DLL_BASE64__', $base64Dll
Set-Content -LiteralPath $uiScriptPath -Value $uiContent -Encoding UTF8

# 5. Compile Executable
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Create-Bing-App-Shortcut.ps1

if (-not (Test-Path .\AutoScape.exe)) {
    throw "AutoScape.exe failed to compile"
}

# 6. Generate Checksum
$hash = (Get-FileHash -LiteralPath .\AutoScape.exe -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath .\AutoScape.exe.sha256 -Value "$hash  AutoScape.exe" -Encoding ASCII

# Output version to GitHub Environment if running under CI
if ($env:GITHUB_OUTPUT) {
    "version=$ver" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}