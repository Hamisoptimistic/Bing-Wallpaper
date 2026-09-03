# =====================================================================
# AutoScape-Updater.ps1
# Auto-Updater Subsystem: GitHub Release Checks, SHA-256 & Installs
# =====================================================================

$script:updateRepository = 'Hamisoptimistic/Bing-Wallpaper'
$script:updatePublisherThumbprint = ''
$script:updateContext = $null
$script:updateDlContext = $null
$script:updateTimer = $null
$script:updateDlTimer = $null

# Every step of "Check for updates" (check, download, hash, extract, relaunch)
# is logged here so a failure can be diagnosed from the log file instead of
# guesswork. The background helper process (spawned during install) writes
# to this same file via its own copy of this function, since it's a plain
# text file append and needs no cross-process coordination.
$script:updateLogPath = Join-Path $env:LOCALAPPDATA 'BingWallpaper\update.log'
function Write-UpdateLog {
    param([string]$Message)
    try {
        $logDir = Split-Path -Parent $script:updateLogPath
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -LiteralPath $script:updateLogPath -Value "$((Get-Date -Format 'u'))  $Message" -Encoding UTF8
    }
    catch {}
}

function Start-VerifiedUpdate {
    if ($script:updateContext -or $script:updateDlContext) { return }
    if ($CheckUpdateBtn) { $CheckUpdateBtn.IsEnabled = $false }
    Set-TransientStatus -Message 'Checking for updates...' -Brush $statusDefaultBrush -Seconds 8

    $repo = $script:updateRepository
    $currentVersion = $script:appVersion
    Write-UpdateLog "CHECK: started. repo=$repo currentVersion=$currentVersion"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param([string]$Repository, [Version]$CurrentAppVersion)
            try {
                function Invoke-GhJson([string]$Uri) {
                    try {
                        return Invoke-RestMethod -Uri $Uri -Headers @{ 'User-Agent' = 'BingWallpaper-Updater' } -UseBasicParsing -ErrorAction Stop
                    }
                    catch {
                        $wc = New-Object System.Net.WebClient
                        $wc.Headers.Add('User-Agent', 'BingWallpaper-Updater')
                        return $wc.DownloadString($Uri) | ConvertFrom-Json
                    }
                }

                function Parse-RelVer([string]$TagName, [string]$ReleaseName, [string]$ReleaseBody) {
                    $cleanTag = ($TagName -replace '^[vV]', '').Trim()
                    if ($cleanTag -match '^\d+(\.\d+){1,3}$') { return [Version]$cleanTag }
                    if ($ReleaseName -match '[vV]?(\d+\.\d+(\.\d+){0,2})') {
                        $v = $Matches[1]
                        if ($v -notmatch '\.') { $v = "$v.0" }
                        if ($v -match '^\d+(\.\d+){1,3}$') { return [Version]$v }
                    }
                    if ($ReleaseBody -match '[vV]?(\d+\.\d+(\.\d+){0,2})') {
                        $v = $Matches[1]
                        if ($v -notmatch '\.') { $v = "$v.0" }
                        if ($v -match '^\d+(\.\d+){1,3}$') { return [Version]$v }
                    }
                    return $null
                }

                $release = $null
                $latestVersion = $null

                try {
                    $releaseUri = "https://api.github.com/repos/$Repository/releases/latest"
                    $latestRel = Invoke-GhJson -Uri $releaseUri
                    $latestVersion = Parse-RelVer -TagName $latestRel.tag_name -ReleaseName $latestRel.name -ReleaseBody $latestRel.body
                    $release = $latestRel
                }
                catch {
                    $allReleasesUri = "https://api.github.com/repos/$Repository/releases?per_page=10"
                    $allReleases = Invoke-GhJson -Uri $allReleasesUri
                    foreach ($rel in $allReleases) {
                        try {
                            $ver = Parse-RelVer -TagName $rel.tag_name -ReleaseName $rel.name -ReleaseBody $rel.body
                            if ($ver -and ($null -eq $latestVersion -or $ver -gt $latestVersion)) {
                                $latestVersion = $ver
                                $release = $rel
                            }
                        }
                        catch {}
                    }
                }

                if (-not $release -or -not $latestVersion) {
                    return @{ Success = $false; Error = "No releases with a valid version tag were found in repository '$Repository'." }
                }

                $hasUpdate = ($latestVersion -gt $CurrentAppVersion)
                return @{
                    Success       = $true
                    HasUpdate     = $hasUpdate
                    LatestVersion = $latestVersion.ToString()
                    Release       = $release
                    Error         = $null
                }
            }
            catch {
                return @{ Success = $false; Error = $_.Exception.Message }
            }
        }).AddArgument($repo).AddArgument($currentVersion)

    $asyncOp = $ps.BeginInvoke()
    $script:updateContext = @{
        PS        = $ps
        AsyncOp   = $asyncOp
        Stopwatch = $stopwatch
    }

    if ($script:updateTimer) {
        $script:updateTimer.Stop()
        $script:updateTimer = $null
    }

    $script:updateTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:updateTimer.Interval = [TimeSpan]::FromMilliseconds(40)
    $script:updateTimer.Add_Tick({
            param($timerSender, $timerArgs)
            if (-not $script:updateContext) {
                $timerSender.Stop()
                return
            }

            if ($script:updateContext.AsyncOp.IsCompleted -and $script:updateContext.Stopwatch.ElapsedMilliseconds -ge 750) {
                $timerSender.Stop()
                $ctx = $script:updateContext
                $script:updateContext = $null
                $script:updateTimer = $null

                $isSuccess = $false
                $errorMsg = $null
                $hasUpdate = $false
                $latestVersionStr = ''
                $release = $null

                try {
                    $resCollection = $ctx.PS.EndInvoke($ctx.AsyncOp)
                    $res = if ($resCollection -and $resCollection.Count -gt 0) { $resCollection[0] } else { $null }
                    $isSuccess = ($res -and $res.Success -eq $true)
                    if ($isSuccess) {
                        $hasUpdate = [bool]$res.HasUpdate
                        $latestVersionStr = [string]$res.LatestVersion
                        $release = $res.Release
                    }
                    else {
                        $errorMsg = if ($res) { $res.Error } else { "Failed to check for updates." }
                    }
                }
                catch {
                    $isSuccess = $false
                    $errorMsg = $_.Exception.Message
                }
                finally {
                    try { $ctx.PS.Dispose() } catch {}
                    if ($CheckUpdateBtn) { $CheckUpdateBtn.IsEnabled = $true }
                }

                if (-not $isSuccess) {
                    Write-UpdateLog "CHECK: failed. error=$errorMsg"
                    $errMsg = Get-UserFriendlyNetworkError -Exception (New-Object Exception($errorMsg)) -DefaultAction "check for updates"
                    Set-TransientStatus -Message $errMsg -Brush $statusErrorBrush -Seconds 5
                    Show-ModernDialog -Title "Update Error" -Header "Connection Error" -Message $errMsg -Icon "Error" -Buttons "OK" | Out-Null
                    return
                }

                if (-not $hasUpdate) {
                    Write-UpdateLog "CHECK: up to date. latestVersion=$latestVersionStr"
                    Set-TransientStatus -Message 'You are up to date.' -Brush $statusSuccessBrush -Seconds 3.5
                    Show-ModernDialog -Title "AutoScape" -Header "You're all up to date" -Message "You already have the latest version ($($script:appVersion))." -Icon "Success" -Buttons "OK" | Out-Null
                    return
                }

                Write-UpdateLog "CHECK: update available. latestVersion=$latestVersionStr"
                Set-TransientStatus -Message "Version $latestVersionStr is available." -Brush $statusDefaultBrush -Seconds 60
                $confirmation = Show-ModernDialog -Title "Update Available" -Header "Version $latestVersionStr is Available" -Message "A new update is available. Would you like to install it now? The app will restart automatically when finished. It might take a few seconds." -Icon "Update" -Buttons "YesNo"
            
                if ($confirmation -ne 'Yes') {
                    Write-UpdateLog "CHECK: user declined update to $latestVersionStr."
                    Set-TransientStatus -Message 'Update cancelled.' -Brush $statusDefaultBrush -Seconds 3.5
                    return
                }

                Start-VerifiedUpdateDownloadAsync -Release $release -LatestVersionStr $latestVersionStr
            }
        })
    $script:updateTimer.Start()
}

function Start-VerifiedUpdateDownloadAsync {
    param(
        $Release,
        [string]$LatestVersionStr
    )

    $zipAsset = $Release.assets | Where-Object { $_.name -match '(?i)\.zip$' } | Select-Object -First 1
    $checksumAsset = $Release.assets | Where-Object { $_.name -match '(?i)\.sha256$' } | Select-Object -First 1

    if (-not $zipAsset) {
        Write-UpdateLog "INSTALL: aborted. release has no .zip asset."
        $errMsg = 'This release does not include a downloadable (.zip) asset.'
        Set-TransientStatus -Message $errMsg -Brush $statusErrorBrush -Seconds 5
        Show-ModernDialog -Title "Update Error" -Header "Update Failed" -Message $errMsg -Icon "Error" -Buttons "OK" | Out-Null
        return
    }

    # Standardized install location - matches where Setup.ps1 copies the app
    # to. No more guessing where the user happened to extract the zip.
    $installDir = Join-Path $env:LOCALAPPDATA 'AutoScape\app'
    $uiScriptPath = Join-Path $installDir 'Bing-Wallpaper-UI.ps1'
    Write-UpdateLog "INSTALL: starting. version=$LatestVersionStr installDir=$installDir zipAsset=$($zipAsset.name)"

    # Prefer the hash embedded in the release body/notes text: that comes
    # from the same Releases API JSON call that already correctly reported
    # each new version instantly, so it's proven fresh. The separate
    # AutoScape.zip.sha256 *asset* has been observed serving the exact same
    # stale hash across multiple different releases (likely never actually
    # replaced by the publish action / stuck behind a CDN cache) - so it's
    # now only a fallback, not the primary source of truth.
    $expectedHashFromBody = $null
    if ($Release.body -and ($Release.body -match '(?im)^SHA256:\s*([a-fA-F0-9]{64})\s*$')) {
        $expectedHashFromBody = $Matches[1].ToUpperInvariant()
    }
    Write-UpdateLog "INSTALL: hash source=$(if ($expectedHashFromBody) { 'release-body' } elseif ($checksumAsset) { 'checksum-asset (fallback, may be stale)' } else { 'none' })"

    if ($CheckUpdateBtn) { $CheckUpdateBtn.IsEnabled = $false }
    Set-TransientStatus -Message "Downloading version $LatestVersionStr..." -Brush $statusDefaultBrush -Seconds 60

    $downloadUrl = [string]$zipAsset.browser_download_url
    $checksumUrl = if ($checksumAsset) { [string]$checksumAsset.browser_download_url } else { $null }
    $updateLogPathForJob = $script:updateLogPath

    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param([string]$DownloadUrl, [string]$ChecksumUrl, [string]$ExpectedHashFromBody, [string]$LogPath)

            function Write-JobLog([string]$Message) {
                try {
                    Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format 'u')  $Message" -Encoding UTF8
                }
                catch {}
            }

            $client = $null
            $downloadPath = $null
            try {
                $downloadPath = Join-Path $env:TEMP "AutoScape-update-$([Guid]::NewGuid().ToString('N')).zip"
                Write-JobLog "DOWNLOAD: fetching $DownloadUrl -> $downloadPath"
                $client = New-Object System.Net.WebClient
                $client.Headers.Add('User-Agent', 'AutoScape-Updater')
                $client.DownloadFile($DownloadUrl, $downloadPath)
                Write-JobLog "DOWNLOAD: complete ($((Get-Item -LiteralPath $downloadPath).Length) bytes)"

                $expectedHash = $null
                if ($ExpectedHashFromBody) {
                    $expectedHash = $ExpectedHashFromBody
                    Write-JobLog "HASH: using expected hash from release body ($expectedHash)"
                }
                elseif ($ChecksumUrl) {
                    try {
                        $checksumText = $client.DownloadString($ChecksumUrl)
                        $match = [regex]::Match($checksumText, '(?im)\b[a-f0-9]{64}\b')
                        if ($match.Success) {
                            $expectedHash = $match.Value.ToUpperInvariant()
                            Write-JobLog "HASH: using expected hash from checksum asset ($expectedHash)"
                        }
                        else {
                            Write-JobLog "HASH: no hash found in checksum asset, skipping verification."
                        }
                    }
                    catch {
                        Write-JobLog "HASH: could not fetch/parse checksum asset - $($_.Exception.Message)"
                    }
                }
                else {
                    Write-JobLog "HASH: no hash source available, skipping verification."
                }

                if ($expectedHash) {
                    $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToUpperInvariant()
                    if ($actualHash -ne $expectedHash) {
                        Write-JobLog "HASH: MISMATCH expected=$expectedHash actual=$actualHash"
                        throw 'The downloaded update failed SHA-256 verification.'
                    }
                    Write-JobLog "HASH: verified OK ($actualHash)"
                }

                return @{ Success = $true; DownloadPath = $downloadPath; Error = $null }
            }
            catch {
                Write-JobLog "DOWNLOAD: FAILED - $($_.Exception.Message)"
                if ($downloadPath) { Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue }
                return @{ Success = $false; DownloadPath = $null; Error = $_.Exception.Message }
            }
            finally {
                if ($client) { $client.Dispose() }
            }
        }).AddArgument($downloadUrl).AddArgument($checksumUrl).AddArgument($expectedHashFromBody).AddArgument($updateLogPathForJob)

    $asyncOp = $ps.BeginInvoke()
    $script:updateDlContext = @{
        PS         = $ps
        AsyncOp    = $asyncOp
        InstallDir = $installDir
    }

    if ($script:updateDlTimer) { $script:updateDlTimer.Stop() }
    $script:updateDlTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:updateDlTimer.Interval = [TimeSpan]::FromMilliseconds(40)

    $script:updateDlTimer.Add_Tick({
            param($timerSender, $timerArgs)
            if (-not $script:updateDlContext) { $timerSender.Stop(); return }
            if (-not $script:updateDlContext.AsyncOp.IsCompleted) { return }

            $timerSender.Stop()
            $ctx = $script:updateDlContext
            $script:updateDlContext = $null
            $script:updateDlTimer = $null

            try {
                $results = $ctx.PS.EndInvoke($ctx.AsyncOp)
                $res = if ($results -and $results.Count) { $results[0] } else { $null }

                if (-not $res -or $res.Success -ne $true) {
                    $failMsg = if ($res -and $res.Error) { [string]$res.Error } else { 'The update could not be downloaded.' }
                    throw $failMsg
                }

                $downloadedZip = [string]$res.DownloadPath
                $installDir = [string]$ctx.InstallDir
                $uiScriptPath = Join-Path $installDir 'Bing-Wallpaper-UI.ps1'

                Set-TransientStatus -Message "Update downloaded. Restarting..." -Brush $statusSuccessBrush -Seconds 10
                $StatusText.Text = "Installing version $LatestVersionStr..."
                Write-UpdateLog "INSTALL: download+hash OK. spawning background installer."

                $updaterPath = Join-Path $env:TEMP "AutoScape-Updater-$([Guid]::NewGuid().ToString('N')).ps1"
                $updaterScript = @'
param(
    [string]$DownloadedZip,
    [string]$InstallDir,
    [string]$UiScriptPath,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

function Write-UpdaterLog([string]$Message) {
    try {
        Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format 'u')  $Message" -Encoding UTF8
    } catch {}
}

try {
    Set-Location -LiteralPath $env:TEMP
    Write-UpdaterLog "UPDATER: started. zip=$DownloadedZip installDir=$InstallDir"
    Start-Sleep -Seconds 1
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        $running = $false
        try {
            Get-Process -Name 'powershell', 'conhost' -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    if ($_.MainModule.FileName -and (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*$UiScriptPath*") {
                        $running = $true
                    }
                } catch {}
            }
        } catch {}
        if (-not $running) { break }
        Start-Sleep -Milliseconds 300
    }
    Write-UpdaterLog "UPDATER: old instance confirmed closed, proceeding with install."

    $stagingDir = Join-Path $env:TEMP "AutoScape-extract-$([Guid]::NewGuid().ToString('N'))"
    Write-UpdaterLog "UPDATER: extracting zip to staging $stagingDir"
    Expand-Archive -LiteralPath $DownloadedZip -DestinationPath $stagingDir -Force

    $lastError = $null
    $done = $false
    for ($i = 0; $i -lt 20; $i++) {
        try {
            if (Test-Path -LiteralPath $InstallDir) {
                Write-UpdaterLog "UPDATER: removing previous install at $InstallDir"
                Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
            }
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
            $copySource = if (Test-Path -LiteralPath (Join-Path $stagingDir 'core\Bing-Wallpaper-UI.ps1')) { Join-Path $stagingDir 'core\*' } else { Join-Path $stagingDir '*' }
            Copy-Item -Path $copySource -Destination $InstallDir -Recurse -Force -ErrorAction Stop
            $done = $true
            break
        } catch {
            $lastError = $_.Exception.Message
            Write-UpdaterLog "UPDATER: install attempt $($i + 1) failed - $lastError"
            Start-Sleep -Milliseconds 500
        }
    }

    if (-not $done) { throw "Could not install to $InstallDir. $lastError" }
    Write-UpdaterLog "UPDATER: install complete. relaunching."

    if (Test-Path -LiteralPath $UiScriptPath) {
        $conhostExe = Join-Path $env:WINDIR 'System32\conhost.exe'
        $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argString = "--headless `"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -File `"$UiScriptPath`""
        Start-Process -FilePath $conhostExe -ArgumentList $argString -WorkingDirectory $InstallDir -ErrorAction Stop | Out-Null
        Write-UpdaterLog "UPDATER: relaunched successfully. done."
    }
    else {
        throw "Installed but $UiScriptPath was not found after extraction."
    }
}
catch {
    Write-UpdaterLog "UPDATER: FAILED - $($_.Exception.Message)"
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show(
            "AutoScape could not complete the update.`n`n$($_.Exception.Message)`n`nSee update.log in %LOCALAPPDATA%\BingWallpaper for details.",
            'AutoScape Update',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    } catch {}
}
finally {
    Remove-Item -LiteralPath $DownloadedZip -Force -ErrorAction SilentlyContinue
    if ($stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}
'@

                Set-Content -LiteralPath $updaterPath -Value $updaterScript -Encoding UTF8 -ErrorAction Stop
                $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

                function Quote-UpdaterArgument([string]$Value) {
                    if ($null -eq $Value) { return '""' }
                    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
                }

                $updaterArgumentLine = @(
                    '-NoProfile'
                    '-ExecutionPolicy Bypass'
                    '-WindowStyle Hidden'
                    ('-File ' + (Quote-UpdaterArgument $updaterPath))
                    ('-DownloadedZip ' + (Quote-UpdaterArgument $downloadedZip))
                    ('-InstallDir ' + (Quote-UpdaterArgument $installDir))
                    ('-UiScriptPath ' + (Quote-UpdaterArgument $uiScriptPath))
                    ('-LogPath ' + (Quote-UpdaterArgument $script:updateLogPath))
                ) -join ' '

                # WorkingDirectory is deliberately outside $installDir: a
                # process's current directory is locked by Windows for its
                # entire lifetime, and this helper's whole job is to delete
                # and recreate $installDir - it can't do that while standing
                # inside it.
                Start-Process -FilePath $powershellExe -ArgumentList $updaterArgumentLine -WorkingDirectory $env:TEMP -WindowStyle Hidden -ErrorAction Stop | Out-Null
            
                [System.Windows.Application]::Current.Shutdown()
                [Environment]::Exit(0)
            }
            catch {
                Write-UpdateLog "INSTALL: FAILED - $($_.Exception.Message)"
                try { $ctx.PS.Dispose() } catch {}
                if ($downloadedZip) { Remove-Item -LiteralPath $downloadedZip -Force -ErrorAction SilentlyContinue }
                if ($updaterPath) { Remove-Item -LiteralPath $updaterPath -Force -ErrorAction SilentlyContinue }

                if ($CheckUpdateBtn) { $CheckUpdateBtn.IsEnabled = $true }
                $errMsg = "The update could not be started: $($_.Exception.Message)"
                Set-TransientStatus -Message $errMsg -Brush $statusErrorBrush -Seconds 8
                Show-ModernDialog -Title "Update Error" -Header "Installation Could Not Start" -Message $errMsg -Icon "Error" -Buttons "OK" | Out-Null
            }
            finally {
                try { $ctx.PS.Dispose() } catch {}
            }
        })

    $script:updateDlTimer.Start()
}

# Invoked by the "Check for updates" button inside the User Guide modal's footer.
# Kept as a named function (rather than an inline Add_Click) since that button
# is rebuilt fresh each time the modal opens.
function Invoke-CheckForUpdatesClick {
    try {
        Start-VerifiedUpdate
    }
    catch {
        Show-AppErrorDialog `
            -Message "Start-VerifiedUpdate failed:`
`
$($_.Exception.GetType().FullName)`
$($_.Exception.Message)`
`
$($_.ScriptStackTrace)" `
            -Title "Update check error"
    }
}

