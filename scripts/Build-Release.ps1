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
$exePath = Join-Path $rootFolder 'AutoScape.exe'
$shaPath = Join-Path $rootFolder 'AutoScape.exe.sha256'
$nativeDllPath = Join-Path $rootFolder 'AutoScapeNative.dll'

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

if (-not (Test-Path -LiteralPath $uiPath)) {
    throw "Cannot find Bing-Wallpaper-UI.ps1 at $uiPath"
}

Write-Step "Resolving compiler"

$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)

$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) {
    throw 'csc.exe not found.'
}

$smaPath = [psobject].Assembly.Location
if (-not (Test-Path -LiteralPath $smaPath)) {
    $smaPath = "$env:WINDIR\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll"
}

if (-not (Test-Path -LiteralPath $smaPath)) {
    throw 'System.Management.Automation.dll not found.'
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

Write-Step "Creating launcher source"

$manifestPath = Join-Path $rootFolder 'app.manifest'

$manifestContent = @'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity version="1.0.0.0" name="AutoScape.App"/>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
      <supportedOS Id="{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}"/>
    </application>
  </compatibility>
</assembly>
'@

Set-Content -LiteralPath $manifestPath -Value $manifestContent -Encoding UTF8

$csTemp = Join-Path $rootFolder 'AutoScapeLauncher_temp.cs'

$launcherCode = @'
using System;
using System.IO;
using System.Reflection;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace AutoScapeLauncher
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            string tempDir = Path.Combine(Path.GetTempPath(), "AutoScape");
            string scriptPath = Path.Combine(tempDir, "Bing-Wallpaper-UI.ps1");
            string nativeDllPath = Path.Combine(tempDir, "AutoScapeNative.dll");
            string iconPath = Path.Combine(tempDir, "assets", "app.ico");
            string crashLogPath = Path.Combine(tempDir, "launcher_crash.log");
            string psErrorLogPath = Path.Combine(tempDir, "ps_errors.log");

            try { Directory.CreateDirectory(tempDir); } catch {}
            try { Directory.CreateDirectory(Path.GetDirectoryName(iconPath)); } catch {}

            try
            {
                ExtractResource("AutoScapeLauncher.Bing-Wallpaper-UI.ps1", scriptPath, true);
                ExtractResource("AutoScapeLauncher.AutoScapeNative.dll", nativeDllPath, true);
                ExtractResource("AutoScapeLauncher.app.ico", iconPath, false);
            }
            catch (Exception ex)
            {
                try { File.WriteAllText(crashLogPath, "Extraction Failed:\r\n" + ex.ToString()); } catch {}
                return;
            }

            if (!File.Exists(scriptPath)) 
            {
                try { File.WriteAllText(crashLogPath, "Script missing after extraction."); } catch {}
                return;
            }

            string argString = string.Empty;
            if (args != null && args.Length > 0)
            {
                foreach (string a in args)
                {
                    string item = a ?? string.Empty;
                    if (item.Contains(" ")) item = "\"" + item + "\"";
                    argString += item + " ";
                }
            }

            try
            {
                using (Runspace rs = RunspaceFactory.CreateRunspace())
                {
                    rs.ApartmentState = System.Threading.ApartmentState.STA;
                    rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                    rs.Open();

                    using (PowerShell ps = PowerShell.Create())
                    {
                        ps.Runspace = rs;
                        ps.AddScript("& '" + scriptPath.Replace("'", "''") + "' " + argString);
                        ps.Invoke();

                        if (ps.Streams.Error.Count > 0)
                        {
                            string errText = "PowerShell Streams.Error:\r\n";
                            foreach (var err in ps.Streams.Error)
                            {
                                errText += err.Exception.ToString() + "\r\n";
                            }
                            try { File.WriteAllText(psErrorLogPath, errText); } catch {}
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                try 
                { 
                    File.WriteAllText(crashLogPath, "Fatal Launcher Exception:\r\n" + ex.ToString()); 
                } 
                catch { }
            }
        }

        private static void ExtractResource(string resourceName, string destinationPath, bool overwrite)
        {
            try
            {
                using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
                {
                    if (source == null) return;
                    if (!overwrite && File.Exists(destinationPath)) return;
                    try { if (File.Exists(destinationPath)) File.Delete(destinationPath); } catch { return; }
                    using (FileStream destination = File.Create(destinationPath))
                    {
                        source.CopyTo(destination);
                    }
                }
            }
            catch { }
        }
    }
}
'@

Set-Content -LiteralPath $csTemp -Value $launcherCode -Encoding UTF8

Write-Step "Compiling AutoScape.exe"

Remove-Item -LiteralPath $exePath -Force -ErrorAction SilentlyContinue

$cscArgs = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/platform:anycpu',
    "/reference:`"$smaPath`"",
    "/win32manifest:`"$manifestPath`"",
    "/resource:`"$uiPath`",AutoScapeLauncher.Bing-Wallpaper-UI.ps1"
)

if ($iconPath) {
    $cscArgs += "/win32icon:`"$iconPath`""
    $cscArgs += "/resource:`"$iconPath`",AutoScapeLauncher.app.ico"
}

if (Test-Path -LiteralPath $nativeDllPath) {
    $cscArgs += "/resource:`"$nativeDllPath`",AutoScapeLauncher.AutoScapeNative.dll"
}

$cscArgs += "/out:`"$exePath`""
$cscArgs += "`"$csTemp`""

& $csc @cscArgs

if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exePath)) {
    throw "Failed to compile AutoScape.exe"
}

$hash = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $shaPath -Value "$hash  AutoScape.exe" -Encoding ASCII

Remove-Item -LiteralPath $csTemp -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue

Write-Step "Done"
Write-Host "Created $exePath"
Write-Host "Created $shaPath"