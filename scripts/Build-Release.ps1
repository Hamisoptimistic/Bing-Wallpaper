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

# 3. Pre-compile AutoScapeNative.dll on the CI runner as a REAL file sitting next
#    to the script - not a Base64 blob pasted into the .ps1. Embedding a large
#    Base64-encoded assembly literal directly in PowerShell script text is one of
#    the heaviest triggers for AMSI/Defender's static-analysis heuristics, and it
#    materially slows down every launch on a machine that hasn't seen the script
#    before (i.e. every end user's machine). Create-Bing-App-Shortcut.ps1 embeds
#    this DLL as its own resource inside AutoScape.exe, alongside the script and
#    the icon, and extracts it back to a real .dll file at runtime.
$nativeDllOutPath = Join-Path (Get-Location) "AutoScapeNative.dll"
if (Test-Path -LiteralPath $nativeDllOutPath) {
    Remove-Item -LiteralPath $nativeDllOutPath -Force -ErrorAction SilentlyContinue
}

$compileParams = @{
    TypeDefinition       = $nativeSource
    ReferencedAssemblies = @('System.Drawing', 'PresentationCore', 'WindowsBase')
    OutputAssembly       = $nativeDllOutPath
    OutputType           = 'Library'
    IgnoreWarnings       = $true
}
Add-Type @compileParams | Out-Null

if (-not (Test-Path -LiteralPath $nativeDllOutPath)) {
    throw "AutoScapeNative.dll failed to compile"
}
Write-Host "Compiled native helper DLL: $nativeDllOutPath"

# 4. Inject Version into Bing-Wallpaper-UI.ps1. No Base64 payload injection
#    anymore - the native DLL now travels as a real file / embedded resource.
$uiContent = $uiContent -replace '\$script:appVersion\s*=\s*\[Version\][''"][^''"]+[''"]', "`$script:appVersion = [Version]'$ver'"
Set-Content -LiteralPath $uiScriptPath -Value $uiContent -Encoding UTF8

# 5. Compile Executable (embeds Bing-Wallpaper-UI.ps1, AutoScapeNative.dll and
#    the icon as resources inside AutoScape.exe)
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Create-Bing-App-Shortcut.ps1

if (-not (Test-Path .\AutoScape.exe)) {
    throw "AutoScape.exe failed to compile"
}

# 6. Generate Checksum
$hash = (Get-FileHash -LiteralPath .\AutoScape.exe -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath .\AutoScape.exe.sha256 -Value "$hash  AutoScape.exe" -Encoding ASCII

# 7. Clean up the loose build-time DLL now that it's embedded in AutoScape.exe
Remove-Item -LiteralPath $nativeDllOutPath -Force -ErrorAction SilentlyContinue

# Output version to GitHub Environment if running under CI
if ($env:GITHUB_OUTPUT) {
    "version=$ver" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}