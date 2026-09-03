# =====================================================================
# AutoScape-Sources.ps1
# Wallpaper Source Engines: Bing, Windows Spotlight, Wallhaven & Pexels
# =====================================================================

function Get-BingImages {
    param([string]$Region)
    $market = if ($Region -eq 'auto') { 'en-US' } else { $Region }
    
    $uri1 = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=$market"
    $uri2 = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=8&n=8&mkt=$market"
    
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
    try {
        $json1 = $wc.DownloadString($uri1)
        $json2 = $wc.DownloadString($uri2)
        $batch1 = if ($json1) { (ConvertFrom-Json -InputObject $json1).images } else { @() }
        $batch2 = if ($json2) { (ConvertFrom-Json -InputObject $json2).images } else { @() }
    }
    catch {
        $batch1 = @()
        $batch2 = @()
    }
    finally {
        $wc.Dispose()
    }
    
    $allImages = @()
    if ($batch1) { $allImages += $batch1 }
    if ($batch2) { $allImages += $batch2 }
    
    $uniqueImages = $allImages | Group-Object -Property urlbase | ForEach-Object { $_.Group[0] } | Sort-Object -Property enddate -Descending
    return $uniqueImages
}

function Get-SpotlightImages {
    # Uses the Peapix public API (https://peapix.com/api), which archives the
    # Windows Spotlight lock-screen feed with a stable, documented JSON
    # endpoint. Microsoft's own feed is an unofficial, undocumented endpoint
    # with no history of its own - Peapix already solves that problem.
    param([int]$Count = 24)

    # A bare "?n=$Count" is the exact same URL every single call, which is
    # exactly what lets a caching layer (WinINet on the client, or Peapix's
    # own CDN at the edge) serve back a stale response instead of hitting
    # the origin - explains "the website shows a new wallpaper but this app
    # doesn't". The timestamp forces a genuinely unique URL every request,
    # and the no-cache headers are belt-and-suspenders on top of that.
    $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $uri = "https://peapix.com/spotlight/feed?n=$Count&_=$cacheBust"
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
    $wc.Headers.Add("Cache-Control", "no-cache, no-store")
    $wc.Headers.Add("Pragma", "no-cache")
    try {
        $json = $wc.DownloadString($uri)
        $items = if ($json) { @(ConvertFrom-Json -InputObject $json) } else { @() }
    }
    catch {
        $items = @()
    }
    finally {
        $wc.Dispose()
    }

    $results = @()
    foreach ($item in $items) {
        $idMatch = [regex]::Match([string]$item.pageUrl, '(\d+)\s*$')
        $id = if ($idMatch.Success) { $idMatch.Value } else { [string]$item.imageUrl }
        $results += [PSCustomObject]@{
            source    = 'Spotlight'
            urlbase   = "spotlight_$id"
            url       = [string]$item.fullUrl
            thumbUrl  = [string]$item.thumbUrl
            title     = [string]$item.title
            copyright = [string]$item.copyright
            enddate   = ''
        }
    }
    return $results
}

function Get-WallhavenImages {
    # Wallhaven's public search API (https://wallhaven.cc/api/v1/search).
    # Per Wallhaven's own docs, an apikey is NOT required to receive SFW
    # (purity=100) results - anonymous requests are already restricted to
    # SFW content server-side. If the user has entered a key (for a higher
    # rate limit, or because they want their own account's settings
    # honored down the line), it's appended; otherwise the request is sent
    # keyless and still works.
    param(
        [int]$Count = 16,
        [string]$ApiKey = ''
    )

    # '+nature' (URL-encoded as %2Bnature) is Wallhaven's tag-restrict
    # syntax - it limits results to wallpapers tagged #nature specifically,
    # rather than a loose full-text match on the word "nature".
    $tagQuery = [System.Uri]::EscapeDataString('+nature')

    # Wallpapers must be at least 4K. If that comes back too thin (fewer
    # than $Count results), fall back to at-least-1440p. We run both queries
    # concurrently in parallel via async tasks so there is zero extra wait for the fallback!
    $uri4k = "https://wallhaven.cc/api/v1/search?q=$tagQuery&categories=100&purity=100&sorting=random&atleast=3840x2160&ratios=16x9"
    $uri2k = "https://wallhaven.cc/api/v1/search?q=$tagQuery&categories=100&purity=100&sorting=random&atleast=2560x1440&ratios=16x9"
    if ($ApiKey) {
        $escapedKey = [System.Uri]::EscapeDataString($ApiKey)
        $uri4k += "&apikey=$escapedKey"
        $uri2k += "&apikey=$escapedKey"
    }

    $swc1 = New-Object System.Net.WebClient
    $swc2 = New-Object System.Net.WebClient
    $swc1.Encoding = [System.Text.Encoding]::UTF8
    $swc2.Encoding = [System.Text.Encoding]::UTF8
    $swc1.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
    $swc2.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")

    $task4k = $swc1.DownloadStringTaskAsync($uri4k)
    $task2k = $swc2.DownloadStringTaskAsync($uri2k)
    try {
        [void][System.Threading.Tasks.Task]::WaitAll(@($task4k, $task2k))
    }
    catch {}

    $items4k = if ($task4k.Status -eq 'RanToCompletion' -and $task4k.Result) {
        try { @((ConvertFrom-Json -InputObject $task4k.Result).data) } catch { @() }
    }
    else { @() }

    $items2k = if ($task2k.Status -eq 'RanToCompletion' -and $task2k.Result) {
        try { @((ConvertFrom-Json -InputObject $task2k.Result).data) } catch { @() }
    }
    else { @() }

    try { $swc1.Dispose() } catch {}
    try { $swc2.Dispose() } catch {}

    $items = if ($items4k.Count -ge $Count) {
        $items4k
    }
    elseif ($items2k.Count -gt $items4k.Count) {
        $items2k
    }
    else {
        $items4k
    }

    $results = @()
    foreach ($item in ($items | Select-Object -First $Count)) {
        $uploaderName = if ($item.uploader -and $item.uploader.username) { [string]$item.uploader.username } else { '' }
        $results += [PSCustomObject]@{
            source    = 'Wallhaven'
            urlbase   = "wallhaven_$($item.id)"
            url       = [string]$item.path
            thumbUrl  = [string]$item.thumbs.large
            title     = 'Nature Wallpaper'
            copyright = if ($uploaderName) { "by $uploaderName" } else { '' }
            enddate   = ''
            resX      = [int]$item.dimension_x
            resY      = [int]$item.dimension_y
            fileSize  = [long]$item.file_size
            fileType  = [string]$item.file_type
        }
    }
    return $results
}

function Get-PexelsImages {
    param(
        [int]$Count = 40,
        [string]$ApiKey = ''
    )

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        return @()
    }

    # Curated premium landscape wallpaper queries requested by user
    $wallpaperQueries = @(
        'beautiful scenery',
        'beautiful view',
        'peaceful nature',
        'nature beauty',
        'mountain',
        'mountain landscape',
        'mountain lake',
        'lakes',
        'summer landscape',
        'autumn landscape',
        'autumn forest'
    )
    # Rejection keywords to guarantee zero humans, portraits, or amateur macro closeups
    $humanKeywords = @('woman', 'man', 'person', 'people', 'girl', 'boy', 'model', 'portrait', 'selfie', 'posing', 'couple', 'crowd', 'face', 'bikini', 'insect', 'bug', 'larva', 'worm', 'macro')

    $data = @()

    if ($Count -le 2) {
        # Fast path for automated background wallpaper rotation (1 query, 1 request)
        $query = Get-Random -InputObject $wallpaperQueries
        $escapedQuery = [System.Uri]::EscapeDataString($query)
        $randomPage = Get-Random -Minimum 1 -Maximum 4
        $uri = "https://api.pexels.com/v1/search?query=$escapedQuery&orientation=landscape&per_page=15&page=$randomPage"

        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        $wc.Headers.Add("Authorization", $ApiKey.Trim())
        try {
            $json = $wc.DownloadString($uri)
            if ($json) { $data = @((ConvertFrom-Json -InputObject $json).photos) }
        }
        catch {}
        finally {
            $wc.Dispose()
        }
    }
    else {
        # Multi-query parallel sampling: select multiple distinct categories
        # and fetch in parallel so wallpapers are a balanced, shuffled mix across themes
        $queryCount = [Math]::Min(8, $wallpaperQueries.Count)
        $chosenQueries = @($wallpaperQueries | Get-Random -Count $queryCount)
        $perQueryTarget = [Math]::Max(3, [Math]::Ceiling($Count / $chosenQueries.Count))

        $clients = @()
        $tasks = @()
        foreach ($q in $chosenQueries) {
            $escQ = [System.Uri]::EscapeDataString($q)
            $rndPage = Get-Random -Minimum 1 -Maximum 4
            $qUri = "https://api.pexels.com/v1/search?query=$escQ&orientation=landscape&per_page=15&page=$rndPage"
            $c = New-Object System.Net.WebClient
            $c.Encoding = [System.Text.Encoding]::UTF8
            $c.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            $c.Headers.Add("Authorization", $ApiKey.Trim())
            $clients += $c
            $tasks += [PSCustomObject]@{
                Query  = $q
                Client = $c
                Task   = $c.DownloadStringTaskAsync($qUri)
            }
        }

        try {
            [void][System.Threading.Tasks.Task]::WaitAll(@($tasks | ForEach-Object { $_.Task }), 8000)
        }
        catch {}

        $categoryBuckets = @()
        $leftoverBucket = @()

        foreach ($t in $tasks) {
            $catPhotos = @()
            if ($t.Task.Status -eq 'RanToCompletion' -and $t.Task.Result) {
                try {
                    $parsed = ConvertFrom-Json -InputObject $t.Task.Result
                    if ($parsed -and $parsed.photos) {
                        foreach ($p in $parsed.photos) {
                            if (-not $p.src) { continue }
                            $w = if ($p.width) { [int]$p.width } else { 0 }
                            $h = if ($p.height) { [int]$p.height } else { 0 }
                            if ($w -lt 1920 -or $h -lt 1080 -or $w -le $h) { continue }
                            $alt = if ($p.alt) { [string]$p.alt } else { '' }
                            $hasH = $false
                            foreach ($hk in $humanKeywords) {
                                if ($alt -match "\b$hk\b") { $hasH = $true; break }
                            }
                            if ($hasH) { continue }
                            $catPhotos += $p
                        }
                    }
                }
                catch {}
            }

            $taken = @($catPhotos | Select-Object -First $perQueryTarget)
            $categoryBuckets += $taken
            $excess = @($catPhotos | Select-Object -Skip $perQueryTarget)
            if ($excess.Count -gt 0) { $leftoverBucket += $excess }
        }

        foreach ($c in $clients) {
            try { $c.Dispose() } catch {}
        }

        # Pool from category buckets, and top-up from leftover buffer if needed
        $pooled = @($categoryBuckets)
        if ($pooled.Count -lt $Count -and $leftoverBucket.Count -gt 0) {
            $needed = $Count - $pooled.Count
            $pooled += @($leftoverBucket | Select-Object -First $needed)
        }

        # Thoroughly shuffle the pooled candidates across categories
        $data = if ($pooled.Count -gt 1) {
            @($pooled | Get-Random -Count $pooled.Count)
        }
        else {
            @($pooled)
        }
    }

    if ($data.Count -eq 0) {
        $fallbackQueries = @('beautiful scenery', 'mountain landscape', 'lakes')
        foreach ($fq in $fallbackQueries) {
            try {
                $fEsc = [System.Uri]::EscapeDataString($fq)
                $fallbackUri = "https://api.pexels.com/v1/search?query=$fEsc&orientation=landscape&per_page=50&page=1"
                $wc2 = New-Object System.Net.WebClient
                $wc2.Encoding = [System.Text.Encoding]::UTF8
                $wc2.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                $wc2.Headers.Add("Authorization", $ApiKey.Trim())
                $fJson = $wc2.DownloadString($fallbackUri)
                $wc2.Dispose()
                if ($fJson) {
                    $data = @((ConvertFrom-Json -InputObject $fJson).photos)
                    if ($data.Count -gt 0) { break }
                }
            }
            catch {}
        }
    }

    $results = @()
    foreach ($item in $data) {
        if (-not $item.src) { continue }

        $w = if ($item.width) { [int]$item.width } else { 0 }
        $h = if ($item.height) { [int]$item.height } else { 0 }
        if ($w -lt 1920 -or $h -lt 1080 -or $w -le $h) { continue }

        $altText = if ($item.alt) { [string]$item.alt } else { '' }
        $hasHuman = $false
        foreach ($hk in $humanKeywords) {
            if ($altText -match "\b$hk\b") { $hasHuman = $true; break }
        }
        if ($hasHuman) { continue }

        $fullUrl = if ($item.src.original) { [string]$item.src.original } elseif ($item.src.large2x) { [string]$item.src.large2x } else { [string]$item.src.large }
        $thumbUrl = if ($item.src.medium) { [string]$item.src.medium } else { [string]$item.src.small }
        $photoTitle = if ($altText) {
            $altText.Trim()
        }
        else {
            'Nature Landscape'
        }
        $creator = if ($item.photographer) { "Photo by $([string]$item.photographer) on Pexels" } else { "Photo on Pexels" }

        $results += [PSCustomObject]@{
            source       = 'Pexels'
            urlbase      = "pexels_$($item.id)"
            url          = $fullUrl
            thumbUrl     = $thumbUrl
            title        = $photoTitle
            copyright    = $creator
            photographer = [string]$item.photographer
            enddate      = ''
            resX         = $w
            resY         = $h
            fileSize     = 0
            fileType     = 'image/jpeg'
        }

        if ($results.Count -ge $Count) { break }
    }
    return $results
}

function Get-BingImageUri {
    param(
        $Image,
        [string]$Resolution
    )
    if ($Image.source -eq 'Spotlight') {
        if ($Image.url) { return $Image.url }
        throw "Invalid Spotlight image data - missing image URL."
    }
    if ($Image.source -eq 'Wallhaven') {
        if ($Image.url) { return $Image.url }
        throw "Invalid Wallhaven image data - missing image URL."
    }
    if ($Image.source -eq 'Pexels') {
        if ($Image.url) { return $Image.url }
        throw "Invalid Pexels image data - missing image URL."
    }
    if ($Image.source -eq 'Local') {
        if ($Image.url) { return $Image.url }
        throw "Invalid Local image data - missing file path."
    }

    $urlBase = $Image.urlbase
    if (-not $urlBase -or -not ($urlBase -match '^/th\?id=')) {
        throw "Invalid image URLBase format received from Bing."
    }
    switch -Regex ($Resolution) {
        '4K|UHD' { return "https://www.bing.com${urlBase}_UHD.jpg" }
        '2K|1440' { return "https://www.bing.com${urlBase}_UHD.jpg&w=2560&h=1440&rs=1&c=4" }
        '1080' { return "https://www.bing.com${urlBase}_1920x1080.jpg" }
        '720|1366|768' { return "https://www.bing.com${urlBase}_1920x1080.jpg&w=1280&h=720&rs=1&c=4" }
        Default { return "https://www.bing.com${urlBase}_UHD.jpg" }
    }
}

function Get-CleanImageTitle {
    param($Image)
    $t = $Image.title
    if (-not $t -or $t.Trim() -eq '' -or $t.Trim() -ieq 'Info' -or $t.Trim() -ieq 'Information') {
        if ($Image.copyright) {
            $clean = $Image.copyright -replace '\s*\([^\)]*\)\s*$', ''
            $clean = $clean.Trim()
            if ($clean) { return $clean }
        }
        if ($Image.urlbase -match 'OHR\.([A-Za-z0-9]+)_') {
            $clean = $matches[1] -creplace '([a-z])([A-Z])', '$1 $2'
            return $clean
        }
        return 'AutoScape'
    }
    return $t.Trim()
}

function Get-LocalImages {
    param(
        [string]$FolderPath,
        [int]$Count = 1
    )
    if ([string]::IsNullOrWhiteSpace($FolderPath) -or (-not (Test-Path -LiteralPath $FolderPath -PathType Container))) {
        return @()
    }

    $files = if ('AutoScapeLocal.Helper' -as [type]) {
        [AutoScapeLocal.Helper]::SafeScanFiles($FolderPath, 0)
    }
    else {
        $extensions = @('.jpg', '.jpeg', '.png', '.bmp', '.webp')
        @(Get-ChildItem -LiteralPath $FolderPath -File -ErrorAction SilentlyContinue | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } | ForEach-Object { $_.FullName })
    }

    if (-not $files -or $files.Count -eq 0) { return @() }

    $picked = @($files | Get-Random -Count ([Math]::Min($Count, $files.Count)))
    $res = @()
    foreach ($p in $picked) {
        $fi = New-Object System.IO.FileInfo($p)
        $res += [PSCustomObject]@{
            source    = 'Local'
            urlbase   = "local_" + [System.Math]::Abs($p.ToLowerInvariant().GetHashCode()).ToString()
            url       = $p
            thumbUrl  = $p
            title     = [System.IO.Path]::GetFileNameWithoutExtension($p)
            copyright = $fi.Directory.Name
            enddate   = ''
            fileSize  = $fi.Length
            fileType  = $fi.Extension.TrimStart('.').ToUpperInvariant()
        }
    }
    return $res
}

# ---------------------------------------------------------------------
# Gallery Background Worker ScriptBlock
# Executed in a background runspace to fetch, cache, and stream thumbnails
# for Bing, Windows Spotlight, Wallhaven, and Pexels.
# ---------------------------------------------------------------------
$script:GalleryFetchWorkerScriptBlock = {
    param([string]$Region, [string]$CacheDir, [string]$Source, [int]$Count, [string]$WallhavenKey, [int]$HistoryMaxDays = 360, [string]$PexelsKey = '', [System.Collections.Queue]$BatchQueue = $null, [hashtable]$CancelToken = $null, [string]$LocalFolder = '')
    try {
        [System.Net.ServicePointManager]::DefaultConnectionLimit = 64
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls

        if ($Source -eq 'Local') {
            if ([string]::IsNullOrWhiteSpace($LocalFolder) -or (-not (Test-Path -LiteralPath $LocalFolder -PathType Container))) {
                if ($BatchQueue) {
                    $BatchQueue.Enqueue([PSCustomObject]@{
                        Type  = 'Error'
                        Error = "Please select a valid local folder."
                    })
                }
                return @{ Success = $false; Error = "Please select a valid local folder."; Images = @() }
            }

            # Fast safe file discovery (<20ms for 20,000 files)
            $foundFiles = if ('AutoScapeLocal.Helper' -as [type]) {
                [AutoScapeLocal.Helper]::SafeScanFiles($LocalFolder, 0)
            }
            else {
                $exts = @('.jpg', '.jpeg', '.png', '.bmp', '.webp')
                $lst = New-Object System.Collections.Generic.List[string]
                try {
                    $raw = [System.IO.Directory]::GetFiles($LocalFolder, '*.*', [System.IO.SearchOption]::TopDirectoryOnly)
                    foreach ($p in $raw) {
                        $ext = [System.IO.Path]::GetExtension($p)
                        if ($exts -contains $ext.ToLowerInvariant()) { $lst.Add($p) }
                    }
                } catch {}
                $lst
            }

            if (-not $foundFiles -or $foundFiles.Count -eq 0) {
                if ($BatchQueue) {
                    $BatchQueue.Enqueue([PSCustomObject]@{
                        Type  = 'Error'
                        Error = "No wallpaper images found in this folder."
                    })
                }
                return @{ Success = $false; Error = "No wallpaper images found in this folder."; Images = @() }
            }

            # Fisher-Yates random shuffle
            $rng = New-Object System.Random
            $n = $foundFiles.Count
            for ($i = $n - 1; $i -gt 0; $i--) {
                $j = $rng.Next($i + 1)
                $temp = $foundFiles[$i]
                $foundFiles[$i] = $foundFiles[$j]
                $foundFiles[$j] = $temp
            }

            $batchSize = 24
            $totalCount = $foundFiles.Count
            $allResultImages = @()

            for ($i = 0; $i -lt $totalCount; $i += $batchSize) {
                if ($CancelToken -and $CancelToken.Cancelled) { break }
                $chunkCount = [Math]::Min($batchSize, $totalCount - $i)
                $chunkFiles = $foundFiles.GetRange($i, $chunkCount)

                $chunkResult = @()
                if ('AutoScapeLocal.Helper' -as [type]) {
                    # Fast parallel batch processing in C# (header reads + 360px thumbs + accents)
                    $processedItems = [AutoScapeLocal.Helper]::ProcessBatch($chunkFiles.ToArray(), $CacheDir, 360)
                    foreach ($item in $processedItems) {
                        $chunkResult += [PSCustomObject]@{
                            source    = 'Local'
                            urlbase   = $item.SafeKey
                            url       = $item.SourcePath
                            thumbUrl  = $item.ThumbPath
                            title     = $item.Title
                            copyright = $item.Folder
                            enddate   = ''
                            resX      = $item.Width
                            resY      = $item.Height
                            fileSize  = $item.FileSize
                            fileType  = $item.FileType
                            accentR   = $item.R
                            accentG   = $item.G
                            accentB   = $item.B
                        }
                    }
                }
                else {
                    # Fallback if native helper not compiled yet
                    foreach ($filePath in $chunkFiles) {
                        $fi = New-Object System.IO.FileInfo($filePath)
                        $cleanTitle = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
                        $parentFolder = $fi.Directory.Name
                        $hash = [System.Math]::Abs($filePath.ToLowerInvariant().GetHashCode()).ToString()
                        $chunkResult += [PSCustomObject]@{
                            source    = 'Local'
                            urlbase   = "local_$hash"
                            url       = $filePath
                            thumbUrl  = $filePath
                            title     = $cleanTitle
                            copyright = $parentFolder
                            enddate   = ''
                            resX      = 0
                            resY      = 0
                            fileSize  = $fi.Length
                            fileType  = $fi.Extension.TrimStart('.').ToUpperInvariant()
                            accentR   = 70
                            accentG   = 70
                            accentB   = 70
                        }
                    }
                }

                $allResultImages += $chunkResult

                if ($BatchQueue) {
                    $BatchQueue.Enqueue([PSCustomObject]@{
                        Type       = 'Batch'
                        Source     = 'Local'
                        BatchIndex = [int]($i / $batchSize)
                        Images     = $chunkResult
                        Total      = $totalCount
                        IsFirst    = ($i -eq 0)
                        IsLast     = (($i + $batchSize) -ge $totalCount)
                    })
                }
            }

            if ($BatchQueue) {
                $BatchQueue.Enqueue([PSCustomObject]@{
                    Type = 'Done'
                })
                return @{ Success = $true; Error = $null; Images = @() }
            }

            return @{ Success = $true; Error = $null; Images = $allResultImages }
        }

        if ($Source -eq 'Spotlight') {
            # --- Fetch the latest batch from Peapix (cheap - small JSON,
            # not the thumbnails themselves) ------------------------------
            $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $uri = "https://peapix.com/spotlight/feed?n=$Count&_=$cacheBust"
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            $wc.Headers.Add("Cache-Control", "no-cache, no-store")
            $wc.Headers.Add("Pragma", "no-cache")
            $json = $null
            try { $json = $wc.DownloadString($uri) } catch {}
            $wc.Dispose()

            $items = if ($json) { @(ConvertFrom-Json -InputObject $json) } else { @() }

            # --- Load the persisted history (images we've already seen
            # in a previous session, within the last $HistoryMaxDays) ---
            $historyPath = Join-Path $CacheDir '_history.json'
            $historyMap = @{}
            if (Test-Path -LiteralPath $historyPath) {
                try {
                    $rawHistory = Get-Content -LiteralPath $historyPath -Raw -ErrorAction Stop
                    if ($rawHistory) {
                        # Repair pass: an OLDER version of this script (or a
                        # crash/edit mid-write) could have saved several
                        # entries with the EXACT SAME firstSeenUtc stamp. A
                        # collision like that can never be fully ordered by
                        # Sort-Object, so the tie falls back to $historyMap's
                        # Hashtable enumeration order - and .NET randomizes
                        # each PROCESS's string-hash seed, so that tie-break
                        # order is different every single time the app is
                        # relaunched (confirmed: same input, 3 different
                        # orders across 3 separate process runs). Walking the
                        # freshly-parsed JSON array here (its on-disk order is
                        # fixed - it is NOT a Hashtable) lets us permanently
                        # de-duplicate any collided/unparsable stamps, so this
                        # can't keep reshuffling on every launch. -----------
                        $loadedArray = @(ConvertFrom-Json -InputObject $rawHistory)
                        $seenStampCounts = @{}
                        foreach ($h in $loadedArray) {
                            $stampKey = [string]$h.firstSeenUtc
                            $parsedOk = $false
                            $baseTime = [DateTime]::MinValue
                            if (-not [string]::IsNullOrWhiteSpace($stampKey)) {
                                try {
                                    $baseTime = [DateTime]::Parse($stampKey, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                    $parsedOk = $true
                                }
                                catch {}
                            }
                            if (-not $parsedOk) { $baseTime = [DateTime]::UtcNow; $stampKey = $baseTime.ToString('o') }
                            if ($seenStampCounts.ContainsKey($stampKey)) {
                                $bump = $seenStampCounts[$stampKey]
                                $seenStampCounts[$stampKey] = $bump + 1
                                $h.firstSeenUtc = $baseTime.AddMilliseconds(-1 * $bump).ToString('o')
                            }
                            else {
                                $seenStampCounts[$stampKey] = 1
                                $h.firstSeenUtc = $baseTime.ToString('o')
                            }
                            if ($h.urlbase) { $historyMap[[string]$h.urlbase] = $h }
                        }
                    }
                }
                catch {}
            }

            if ((-not $items -or $items.Count -eq 0) -and $historyMap.Count -eq 0) {
                return @{ Success = $false; Error = "Unable to connect to Spotlight."; Images = @() }
            }

            # --- Merge today's feed into the history. Existing entries
            # keep their original FirstSeenUtc (so they age out on
            # schedule) but get refreshed metadata/URLs. New entries
            # are stamped with "now" MINUS a tiny per-item offset that
            # preserves the feed's own newest-first order.
            #
            # Why the offset matters: $historyMap is a plain
            # Hashtable, and .Values does NOT enumerate in insertion
            # order - it's effectively arbitrary. If every new item
            # in this batch got the exact same $nowUtc stamp (as
            # before), the later "Sort-Object firstSeenUtc
            # -Descending" would have a big tie among them, and ties
            # fall back to that same arbitrary hashtable order - a
            # DIFFERENT arbitrary order on every single load. That's
            # what was causing the "random" gallery order. Giving
            # each new item its own strictly-decreasing millisecond
            # stamp (in the order Peapix returned them, which is
            # newest-first) makes the sort key itself unique and
            # deterministic, so ties never happen and the visual
            # order stops depending on hashtable enumeration at all.
            # Items with no thumbnail URL at all are skipped outright
            # - there's nothing to ever render for them. -------------
            $nowUtc = [DateTime]::UtcNow
            $newBatchIndex = 0
            foreach ($item in $items) {
                if ([string]::IsNullOrWhiteSpace([string]$item.thumbUrl)) { continue }
                $idMatch = [regex]::Match([string]$item.pageUrl, '(\d+)\s*$')
                $id = if ($idMatch.Success) { $idMatch.Value } else { [string]$item.imageUrl }
                $urlbase = "spotlight_$id"
                $firstSeen = if ($historyMap.ContainsKey($urlbase) -and $historyMap[$urlbase].firstSeenUtc) {
                    [string]$historyMap[$urlbase].firstSeenUtc
                }
                else {
                    $stamp = $nowUtc.AddMilliseconds(-1 * $newBatchIndex)
                    $newBatchIndex++
                    $stamp.ToString('o')
                }
                $historyMap[$urlbase] = [PSCustomObject]@{
                    urlbase      = $urlbase
                    url          = [string]$item.fullUrl
                    thumbUrl     = [string]$item.thumbUrl
                    title        = [string]$item.title
                    copyright    = [string]$item.copyright
                    firstSeenUtc = $firstSeen
                }
            }

            # --- Prune anything older than the retention window, then
            # cap how many we actually render/download this load, so
            # a full $HistoryMaxDays of accumulated Spotlight images
            # can't turn into hundreds of cards (each one decoded +
            # accent-extracted on the UI thread) and make the gallery
            # slow to appear. Same $spotlightShowCount pattern as
            # Wallhaven's cap. -------------------------------------
            $spotlightShowCount = 360
            $cutoffUtc = $nowUtc.AddDays(-1 * [Math]::Abs($HistoryMaxDays))
            $candidateImages = @(
                $historyMap.Values | Where-Object {
                    $ok = $true
                    $seen = [DateTime]::MinValue
                    try {
                        $seen = [DateTime]::Parse(
                            [string]$_.firstSeenUtc,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind
                        )
                    }
                    catch { $ok = $false }
                    (-not $ok) -or ($seen.ToUniversalTime() -ge $cutoffUtc)
                } | Sort-Object -Property firstSeenUtc -Descending | Select-Object -First $spotlightShowCount
            )

            $urlBases = [string[]]($candidateImages | ForEach-Object { [string]$_.urlbase })

            # Prune thumbnails that have aged out of the retention
            # window entirely (NOT just "not in today's feed" - that's
            # what used to wipe the whole history on every refresh).
            try {
                $keepNames = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($ub in $urlBases) {
                    [void]$keepNames.Add(($ub -replace '[^a-zA-Z0-9]', '') + '_thumb.jpg')
                }
                Get-ChildItem -LiteralPath $CacheDir -Filter '*_thumb.jpg' -File -ErrorAction SilentlyContinue |
                Where-Object { -not $keepNames.Contains($_.Name) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            }
            catch {}

            # Parallel download, short timeout (8s) - these are small
            # thumbnails, and a single dead/unreachable URL should not
            # be able to stall the whole batch for 20s. Only the
            # thumbnails we don't already have on disk actually hit the
            # network (DownloadUrlsParallel skips any target that
            # already exists), so images carried over from history
            # cost nothing here.
            if ('BingWallpaper.FastDownloader' -as [type]) {
                $thumbUrls = [string[]]($candidateImages | ForEach-Object { [string]$_.thumbUrl })
                $thumbTargets = [string[]]($candidateImages | ForEach-Object {
                        $safe = $_.urlbase -replace '[^a-zA-Z0-9]', ''
                        Join-Path $CacheDir "${safe}_thumb.jpg"
                    })
                [BingWallpaper.FastDownloader]::DownloadUrlsParallel($thumbUrls, $thumbTargets, 8)
            }
            else {
                $wc2 = New-Object System.Net.WebClient
                $wc2.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                foreach ($img in $candidateImages) {
                    $safe = $img.urlbase -replace '[^a-zA-Z0-9]', ''
                    $target = Join-Path $CacheDir "${safe}_thumb.jpg"
                    if (-not (Test-Path -LiteralPath $target) -and $img.thumbUrl) {
                        try { $wc2.DownloadFile($img.thumbUrl, $target) } catch {}
                    }
                }
                $wc2.Dispose()
            }

            # --- Validate: only keep entries whose thumbnail actually
            # exists on disk with real content. Anything that failed to
            # download (dead URL, 404, etc.) is dropped here - both from
            # what we render AND from the persisted history, so a
            # permanently-broken item can't squat in the 30-day history
            # forever showing up as a black card on every load. -------
            $uniqueImages = @($candidateImages | Where-Object {
                    $safe = $_.urlbase -replace '[^a-zA-Z0-9]', ''
                    $target = Join-Path $CacheDir "${safe}_thumb.jpg"
                    (Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -gt 0)
                })

            if ($uniqueImages.Count -eq 0 -and $candidateImages.Count -gt 0) {
                # Every thumbnail failed (e.g. offline) - fall back to
                # whatever was already valid on disk rather than an
                # empty gallery, but don't persist a stale/empty history.
                return @{ Success = $false; Error = "Unable to connect to Spotlight."; Images = @() }
            }

            try {
                $uniqueImages | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $historyPath -Encoding UTF8
            }
            catch {}

            $resultImages = @()
            foreach ($img in $uniqueImages) {
                $resultImages += [PSCustomObject]@{
                    source    = 'Spotlight'
                    urlbase   = [string]$img.urlbase
                    url       = [string]$img.url
                    title     = [string]$img.title
                    copyright = [string]$img.copyright
                    enddate   = ''
                }
            }

            return @{ Success = $true; Error = $null; Images = $resultImages }
        }

        if ($Source -eq 'Wallhaven') {
            # Each load pulls a fresh random batch of $whFetchCount
            # from Wallhaven, then MERGES it into a persisted history
            # (same pattern as Spotlight) instead of replacing the
            # gallery outright. That means: repeat opens reuse
            # thumbnails already on disk (only the newly-sampled ids
            # actually hit the network) and the visible pool grows
            # across runs up to $HistoryMaxDays, instead of resetting
            # to 16 brand-new random wallpapers - and a fresh 16
            # network+disk round trip - every single time.
            $whFetchCount = 24
            $whShowCount = 24
            $tagQuery = [System.Uri]::EscapeDataString('+nature')

            # Wallpapers must be at least 4K. If that comes back too
            # thin (fewer than $whFetchCount results), fall back to
            # at-least-1440p. Both searches are executed concurrently in
            # parallel so there is zero extra wait for the fallback query!
            $uri4k = "https://wallhaven.cc/api/v1/search?q=$tagQuery&categories=100&purity=100&sorting=random&atleast=3840x2160&ratios=16x9"
            $uri2k = "https://wallhaven.cc/api/v1/search?q=$tagQuery&categories=100&purity=100&sorting=random&atleast=2560x1440&ratios=16x9"
            if ($WallhavenKey) {
                $escapedKey = [System.Uri]::EscapeDataString($WallhavenKey)
                $uri4k += "&apikey=$escapedKey"
                $uri2k += "&apikey=$escapedKey"
            }

            $swc1 = New-Object System.Net.WebClient
            $swc2 = New-Object System.Net.WebClient
            $swc1.Encoding = [System.Text.Encoding]::UTF8
            $swc2.Encoding = [System.Text.Encoding]::UTF8
            $swc1.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            $swc2.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")

            $task4k = $swc1.DownloadStringTaskAsync($uri4k)
            $task2k = $swc2.DownloadStringTaskAsync($uri2k)
            try {
                [void][System.Threading.Tasks.Task]::WaitAll(@($task4k, $task2k))
            }
            catch {}

            $items4k = if ($task4k.Status -eq 'RanToCompletion' -and $task4k.Result) {
                try { @((ConvertFrom-Json -InputObject $task4k.Result).data) } catch { @() }
            }
            else { @() }

            $items2k = if ($task2k.Status -eq 'RanToCompletion' -and $task2k.Result) {
                try { @((ConvertFrom-Json -InputObject $task2k.Result).data) } catch { @() }
            }
            else { @() }

            try { $swc1.Dispose() } catch {}
            try { $swc2.Dispose() } catch {}

            $items = if ($items4k.Count -ge $whFetchCount) {
                $items4k
            }
            elseif ($items2k.Count -gt $items4k.Count) {
                $items2k
            }
            else {
                $items4k
            }
            $items = @($items | Select-Object -First $whFetchCount)

            # --- Load the persisted history (wallpapers we've
            # already sampled in a previous session, within the last
            # $HistoryMaxDays) -------------------------------------
            $historyPath = Join-Path $CacheDir '_history.json'
            $historyMap = @{}
            if (Test-Path -LiteralPath $historyPath) {
                try {
                    $rawHistory = Get-Content -LiteralPath $historyPath -Raw -ErrorAction Stop
                    if ($rawHistory) {
                        # Repair pass - see the matching comment in the
                        # Spotlight branch above for why this is needed:
                        # collided/duplicate firstSeenUtc stamps saved by
                        # an older version of this script would otherwise
                        # keep reshuffling the gallery order on every
                        # relaunch (Hashtable enumeration order is
                        # randomized per process). -----------------------
                        $loadedArray = @(ConvertFrom-Json -InputObject $rawHistory)
                        $seenStampCounts = @{}
                        foreach ($h in $loadedArray) {
                            $stampKey = [string]$h.firstSeenUtc
                            $parsedOk = $false
                            $baseTime = [DateTime]::MinValue
                            if (-not [string]::IsNullOrWhiteSpace($stampKey)) {
                                try {
                                    $baseTime = [DateTime]::Parse($stampKey, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                    $parsedOk = $true
                                }
                                catch {}
                            }
                            if (-not $parsedOk) { $baseTime = [DateTime]::UtcNow; $stampKey = $baseTime.ToString('o') }
                            if ($seenStampCounts.ContainsKey($stampKey)) {
                                $bump = $seenStampCounts[$stampKey]
                                $seenStampCounts[$stampKey] = $bump + 1
                                $h.firstSeenUtc = $baseTime.AddMilliseconds(-1 * $bump).ToString('o')
                            }
                            else {
                                $seenStampCounts[$stampKey] = 1
                                $h.firstSeenUtc = $baseTime.ToString('o')
                            }
                            if ($h.urlbase) { $historyMap[[string]$h.urlbase] = $h }
                        }
                    }
                }
                catch {}
            }

            if ((-not $items -or $items.Count -eq 0) -and $historyMap.Count -eq 0) {
                return @{ Success = $false; Error = "Unable to connect to Wallhaven."; Images = @() }
            }

            # --- Merge this batch into history. Existing entries
            # keep their original FirstSeenUtc (so they age out on
            # schedule); newly-sampled ids get a strictly-decreasing
            # per-item stamp (not one shared $nowUtc for the whole
            # batch) so ties can't fall back to $historyMap's
            # arbitrary Hashtable enumeration order on sort - see the
            # comment in the Spotlight branch above for why that was
            # producing a different "random" order on every load. --
            $nowUtc = [DateTime]::UtcNow
            $newBatchIndex = 0
            foreach ($item in $items) {
                if ([string]::IsNullOrWhiteSpace([string]$item.id)) { continue }
                $urlbase = "wallhaven_$($item.id)"
                $uploaderName = if ($item.uploader -and $item.uploader.username) { [string]$item.uploader.username } else { '' }
                $firstSeen = if ($historyMap.ContainsKey($urlbase) -and $historyMap[$urlbase].firstSeenUtc) {
                    [string]$historyMap[$urlbase].firstSeenUtc
                }
                else {
                    $stamp = $nowUtc.AddMilliseconds(-1 * $newBatchIndex)
                    $newBatchIndex++
                    $stamp.ToString('o')
                }
                $historyMap[$urlbase] = [PSCustomObject]@{
                    urlbase      = $urlbase
                    url          = [string]$item.path
                    thumbUrl     = [string]$item.thumbs.large
                    title        = 'Nature Wallpaper'
                    copyright    = if ($uploaderName) { "by $uploaderName" } else { '' }
                    resX         = [int]$item.dimension_x
                    resY         = [int]$item.dimension_y
                    fileSize     = [long]$item.file_size
                    fileType     = [string]$item.file_type
                    firstSeenUtc = $firstSeen
                }
            }

            # --- Prune anything older than the retention window,
            # then cap how many we actually render/download this
            # load so the gallery doesn't grow unbounded. -----------
            $cutoffUtc = $nowUtc.AddDays(-1 * [Math]::Abs($HistoryMaxDays))
            $candidateImages = @(
                $historyMap.Values | Where-Object {
                    $ok = $true
                    $seen = [DateTime]::MinValue
                    try {
                        $seen = [DateTime]::Parse(
                            [string]$_.firstSeenUtc,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind
                        )
                    }
                    catch { $ok = $false }
                    (-not $ok) -or ($seen.ToUniversalTime() -ge $cutoffUtc)
                } | Sort-Object -Property firstSeenUtc -Descending | Select-Object -First $whShowCount
            )

            $urlBases = [string[]]($candidateImages | ForEach-Object { [string]$_.urlbase })

            # Prune thumbnails that have aged out of the retention
            # window entirely (NOT just "not in this random batch" -
            # that's what used to wipe the whole gallery to 16 fresh
            # downloads on every single refresh).
            try {
                $keepNames = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($ub in $urlBases) {
                    [void]$keepNames.Add(($ub -replace '[^a-zA-Z0-9]', '') + '_thumb.jpg')
                }
                Get-ChildItem -LiteralPath $CacheDir -Filter '*_thumb.jpg' -File -ErrorAction SilentlyContinue |
                Where-Object { -not $keepNames.Contains($_.Name) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            }
            catch {}

            if ($BatchQueue) {
                $batchSize = 8
                $allValidImages = @()
                for ($i = 0; $i -lt $candidateImages.Count; $i += $batchSize) {
                    if ($CancelToken -and $CancelToken.Cancelled) { break }
                    $chunkCount = [Math]::Min($batchSize, $candidateImages.Count - $i)
                    $chunkCandidates = @($candidateImages | Select-Object -Skip $i -First $chunkCount)

                    if ('BingWallpaper.FastDownloader' -as [type]) {
                        $chunkUrls = [string[]]($chunkCandidates | ForEach-Object { [string]$_.thumbUrl })
                        $chunkTargets = [string[]]($chunkCandidates | ForEach-Object {
                                $safe = $_.urlbase -replace '[^a-zA-Z0-9]', ''
                                Join-Path $CacheDir "${safe}_thumb.jpg"
                            })
                        [BingWallpaper.FastDownloader]::DownloadUrlsParallel($chunkUrls, $chunkTargets, 8)
                    }
                    else {
                        $wcChunk = New-Object System.Net.WebClient
                        $wcChunk.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                        foreach ($img in $chunkCandidates) {
                            $safe = $img.urlbase -replace '[^a-zA-Z0-9]', ''
                            $target = Join-Path $CacheDir "${safe}_thumb.jpg"
                            if (-not (Test-Path -LiteralPath $target) -and $img.thumbUrl) {
                                try { $wcChunk.DownloadFile($img.thumbUrl, $target) } catch {}
                            }
                        }
                        $wcChunk.Dispose()
                    }

                    if ($CancelToken -and $CancelToken.Cancelled) { break }

                    $validChunk = @($chunkCandidates | Where-Object {
                            $safe = $_.urlbase -replace '[^a-zA-Z0-9]', ''
                            $target = Join-Path $CacheDir "${safe}_thumb.jpg"
                            (Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -gt 0)
                        })

                    if ($validChunk.Count -gt 0) {
                        $chunkResult = @()
                        foreach ($img in $validChunk) {
                            $chunkResult += [PSCustomObject]@{
                                source    = 'Wallhaven'
                                urlbase   = [string]$img.urlbase
                                url       = [string]$img.url
                                title     = [string]$img.title
                                copyright = [string]$img.copyright
                                enddate   = ''
                                resX      = $img.resX
                                resY      = $img.resY
                                fileSize  = $img.fileSize
                                fileType  = [string]$img.fileType
                            }
                        }
                        $allValidImages += $validChunk

                        $BatchQueue.Enqueue([PSCustomObject]@{
                                Type       = 'Batch'
                                Source     = 'Wallhaven'
                                BatchIndex = [int]($i / $batchSize)
                                Images     = $chunkResult
                                Total      = $candidateImages.Count
                                IsFirst    = ($i -eq 0)
                                IsLast     = (($i + $batchSize) -ge $candidateImages.Count)
                            })
                    }
                }

                if ($allValidImages.Count -eq 0 -and $candidateImages.Count -gt 0) {
                    $BatchQueue.Enqueue([PSCustomObject]@{
                            Type  = 'Error'
                            Error = "Unable to connect to Wallhaven."
                        })
                    return @{ Success = $false; Error = "Unable to connect to Wallhaven."; Images = @() }
                }

                try {
                    $allValidImages | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $historyPath -Encoding UTF8
                }
                catch {}

                $BatchQueue.Enqueue([PSCustomObject]@{
                        Type = 'Done'
                    })
                return @{ Success = $true; Error = $null; Images = @() }
            }

            # Only the thumbnails we don't already have on disk
            # actually hit the network (DownloadUrlsParallel skips
            # any target that already exists) - so wallpapers
            # carried over from history cost nothing here.
            if ('BingWallpaper.FastDownloader' -as [type]) {
                $thumbUrls = [string[]]($candidateImages | ForEach-Object { [string]$_.thumbUrl })
                $thumbTargets = [string[]]($candidateImages | ForEach-Object {
                        $safe = $_.urlbase -replace '[^a-zA-Z0-9]', ''
                        Join-Path $CacheDir "${safe}_thumb.jpg"
                    })
                [BingWallpaper.FastDownloader]::DownloadUrlsParallel($thumbUrls, $thumbTargets, 8)
            }
            else {
                $wc2 = New-Object System.Net.WebClient
                $wc2.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                foreach ($img in $candidateImages) {
                    $safe = $img.urlbase -replace '[^a-zA-Z0-9]', ''
                    $target = Join-Path $CacheDir "${safe}_thumb.jpg"
                    if (-not (Test-Path -LiteralPath $target) -and $img.thumbUrl) {
                        try { $wc2.DownloadFile($img.thumbUrl, $target) } catch {}
                    }
                }
                $wc2.Dispose()
            }

            # --- Validate: only keep entries whose thumbnail
            # actually exists on disk with real content, and drop
            # dead ones from the persisted history too. -------------
            $uniqueImages = @($candidateImages | Where-Object {
                    $safe = $_.urlbase -replace '[^a-zA-Z0-9]', ''
                    $target = Join-Path $CacheDir "${safe}_thumb.jpg"
                    (Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -gt 0)
                })

            if ($uniqueImages.Count -eq 0 -and $candidateImages.Count -gt 0) {
                return @{ Success = $false; Error = "Unable to connect to Wallhaven."; Images = @() }
            }

            try {
                $uniqueImages | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $historyPath -Encoding UTF8
            }
            catch {}

            $resultImages = @()
            foreach ($img in $uniqueImages) {
                $resultImages += [PSCustomObject]@{
                    source    = 'Wallhaven'
                    urlbase   = [string]$img.urlbase
                    url       = [string]$img.url
                    title     = [string]$img.title
                    copyright = [string]$img.copyright
                    enddate   = ''
                    resX      = $img.resX
                    resY      = $img.resY
                    fileSize  = $img.fileSize
                    fileType  = [string]$img.fileType
                }
            }

            return @{ Success = $true; Error = $null; Images = $resultImages }
        }

        if ($Source -eq 'Pexels') {
            if ([string]::IsNullOrWhiteSpace($PexelsKey)) {
                return @{ Success = $false; Error = "Please enter your Pexels API key in the toolbar."; Images = @() }
            }

            $pexFetchCount = 40
            $pexShowCount = 40

            # Curated premium landscape wallpaper queries requested by user
            $wallpaperQueries = @(
                'beautiful scenery',
                'beautiful view',
                'peaceful nature',
                'nature beauty',
                'mountain',
                'mountain landscape',
                'mountain lake',
                'lakes',
                'summer landscape',
                'autumn landscape',
                'autumn forest'
            )
            # Rejection keywords to guarantee zero humans, portraits, or amateur macro closeups
            $humanKeywords = @('woman', 'man', 'person', 'people', 'girl', 'boy', 'model', 'portrait', 'selfie', 'posing', 'couple', 'crowd', 'face', 'bikini', 'insect', 'bug', 'larva', 'worm', 'macro')

            # Multi-query parallel sampling: select multiple distinct categories
            # and fetch in parallel so wallpapers are a balanced, shuffled mix across themes
            $queryCount = [Math]::Min(8, $wallpaperQueries.Count)
            $chosenQueries = @($wallpaperQueries | Get-Random -Count $queryCount)
            $perQueryTarget = [Math]::Max(3, [Math]::Ceiling($pexFetchCount / $chosenQueries.Count))

            $clients = @()
            $tasks = @()
            foreach ($q in $chosenQueries) {
                $escQ = [System.Uri]::EscapeDataString($q)
                $rndPage = Get-Random -Minimum 1 -Maximum 4
                $qUri = "https://api.pexels.com/v1/search?query=$escQ&orientation=landscape&per_page=15&page=$rndPage"
                $c = New-Object System.Net.WebClient
                $c.Encoding = [System.Text.Encoding]::UTF8
                $c.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                $c.Headers.Add("Authorization", $PexelsKey.Trim())
                $clients += $c
                $tasks += [PSCustomObject]@{
                    Query  = $q
                    Client = $c
                    Task   = $c.DownloadStringTaskAsync($qUri)
                }
            }

            try {
                [void][System.Threading.Tasks.Task]::WaitAll(@($tasks | ForEach-Object { $_.Task }), 8000)
            }
            catch {}

            # Check for 401 Unauthorized across responses
            foreach ($t in $tasks) {
                if ($t.Task.IsFaulted) {
                    $err = $t.Task.Exception.ToString()
                    if ($err -match '401' -or $err -match 'Unauthorized') {
                        foreach ($c in $clients) { try { $c.Dispose() } catch {} }
                        return @{ Success = $false; Error = "Invalid Pexels API key (401 Unauthorized). Please check your key at pexels.com/api."; Images = @() }
                    }
                }
            }

            $categoryBuckets = @()
            $leftoverBucket = @()

            foreach ($t in $tasks) {
                $catPhotos = @()
                if ($t.Task.Status -eq 'RanToCompletion' -and $t.Task.Result) {
                    try {
                        $parsed = ConvertFrom-Json -InputObject $t.Task.Result
                        if ($parsed -and $parsed.photos) {
                            foreach ($p in $parsed.photos) {
                                if (-not $p.src) { continue }
                                $w = if ($p.width) { [int]$p.width } else { 0 }
                                $h = if ($p.height) { [int]$p.height } else { 0 }
                                if ($w -lt 1920 -or $h -lt 1080 -or $w -le $h) { continue }
                                $alt = if ($p.alt) { [string]$p.alt } else { '' }
                                $hasH = $false
                                foreach ($hk in $humanKeywords) {
                                    if ($alt -match "\b$hk\b") { $hasH = $true; break }
                                }
                                if ($hasH) { continue }
                                $catPhotos += $p
                            }
                        }
                    }
                    catch {}
                }

                $taken = @($catPhotos | Select-Object -First $perQueryTarget)
                $categoryBuckets += $taken
                $excess = @($catPhotos | Select-Object -Skip $perQueryTarget)
                if ($excess.Count -gt 0) { $leftoverBucket += $excess }
            }

            foreach ($c in $clients) {
                try { $c.Dispose() } catch {}
            }

            # Pool from category buckets, and top-up from leftover buffer if needed
            $pooled = @($categoryBuckets)
            if ($pooled.Count -lt $pexFetchCount -and $leftoverBucket.Count -gt 0) {
                $needed = $pexFetchCount - $pooled.Count
                $pooled += @($leftoverBucket | Select-Object -First $needed)
            }

            # If all multi-queries failed (e.g. timeout), attempt fallback single query
            if ($pooled.Count -eq 0) {
                $fallbackQueries = @('beautiful scenery', 'mountain landscape', 'lakes')
                foreach ($fq in $fallbackQueries) {
                    try {
                        $fEsc = [System.Uri]::EscapeDataString($fq)
                        $fallbackUri = "https://api.pexels.com/v1/search?query=$fEsc&orientation=landscape&per_page=50&page=1"
                        $pwc2 = New-Object System.Net.WebClient
                        $pwc2.Encoding = [System.Text.Encoding]::UTF8
                        $pwc2.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                        $pwc2.Headers.Add("Authorization", $PexelsKey.Trim())
                        $pjson = $pwc2.DownloadString($fallbackUri)
                        $pwc2.Dispose()
                        if ($pjson) {
                            $rawPhotos = @((ConvertFrom-Json -InputObject $pjson).photos)
                            foreach ($rp in $rawPhotos) {
                                if (-not $rp.src) { continue }
                                $w = if ($rp.width) { [int]$rp.width } else { 0 }
                                $h = if ($rp.height) { [int]$rp.height } else { 0 }
                                if ($w -lt 1920 -or $h -lt 1080 -or $w -le $h) { continue }
                                $alt = if ($rp.alt) { [string]$rp.alt } else { '' }
                                $hasH = $false
                                foreach ($hk in $humanKeywords) {
                                    if ($alt -match "\b$hk\b") { $hasH = $true; break }
                                }
                                if ($hasH) { continue }
                                $pooled += $rp
                            }
                            if ($pooled.Count -gt 0) { break }
                        }
                    }
                    catch {}
                }
            }

            # Thoroughly shuffle the pooled candidates across categories
            $filteredPhotos = if ($pooled.Count -gt 1) {
                @($pooled | Get-Random -Count $pooled.Count)
            }
            else {
                @($pooled)
            }

            $historyPath = Join-Path $CacheDir '_history.json'
            $historyMap = @{}
            if (Test-Path -LiteralPath $historyPath) {
                try {
                    $rawHistory = Get-Content -LiteralPath $historyPath -Raw -ErrorAction Stop
                    if ($rawHistory) {
                        $loadedArray = @(ConvertFrom-Json -InputObject $rawHistory)
                        $seenStampCounts = @{}
                        foreach ($h in $loadedArray) {
                            $stampKey = [string]$h.firstSeenUtc
                            $parsedOk = $false
                            $baseTime = [DateTime]::MinValue
                            if (-not [string]::IsNullOrWhiteSpace($stampKey)) {
                                try {
                                    $baseTime = [DateTime]::Parse($stampKey, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                    $parsedOk = $true
                                }
                                catch {}
                            }
                            if (-not $parsedOk) { $baseTime = [DateTime]::UtcNow; $stampKey = $baseTime.ToString('o') }
                            if ($seenStampCounts.ContainsKey($stampKey)) {
                                $bump = $seenStampCounts[$stampKey]
                                $seenStampCounts[$stampKey] = $bump + 1
                                $h.firstSeenUtc = $baseTime.AddMilliseconds(-1 * $bump).ToString('o')
                            }
                            else {
                                $seenStampCounts[$stampKey] = 1
                                $h.firstSeenUtc = $baseTime.ToString('o')
                            }
                            if ($h.urlbase) { $historyMap[[string]$h.urlbase] = $h }
                        }
                    }
                }
                catch {}
            }

            if ($filteredPhotos.Count -eq 0 -and $historyMap.Count -eq 0) {
                return @{ Success = $false; Error = "No wallpapers found or unable to connect to Pexels."; Images = @() }
            }

            $nowUtc = [DateTime]::UtcNow
            $newBatchIndex = 0
            foreach ($item in $filteredPhotos) {
                if (-not $item.id) { continue }
                $urlbase = "pexels_$($item.id)"
                $stamp = $nowUtc.AddMilliseconds(-1 * $newBatchIndex)
                $newBatchIndex++
                $firstSeen = $stamp.ToString('o')

                $fullUrl = if ($item.src.original) { [string]$item.src.original } elseif ($item.src.large2x) { [string]$item.src.large2x } else { [string]$item.src.large }
                $thumbUrl = if ($item.src.medium) { [string]$item.src.medium } else { [string]$item.src.small }
                $altDesc = if ($item.alt) { [string]$item.alt } else { '' }
                $photoTitle = if ($altDesc) {
                    $altDesc.Trim()
                }
                else {
                    'Nature Landscape'
                }
                $creator = if ($item.photographer) { "Photo by $([string]$item.photographer) on Pexels" } else { "Photo on Pexels" }

                $historyMap[$urlbase] = [PSCustomObject]@{
                    urlbase      = $urlbase
                    url          = $fullUrl
                    thumbUrl     = $thumbUrl
                    title        = $photoTitle
                    copyright    = $creator
                    photographer = [string]$item.photographer
                    resX         = [int]$item.width
                    resY         = [int]$item.height
                    fileSize     = 0
                    fileType     = 'image/jpeg'
                    firstSeenUtc = $firstSeen
                }
            }

            $cutoffUtc = $nowUtc.AddDays(-1 * [Math]::Abs($HistoryMaxDays))
            $candidateImages = @(
                $historyMap.Values | Where-Object {
                    $ok = $true
                    $seen = [DateTime]::MinValue
                    try {
                        $seen = [DateTime]::Parse(
                            [string]$_.firstSeenUtc,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind
                        )
                    }
                    catch { $ok = $false }
                    (-not $ok) -or ($seen.ToUniversalTime() -ge $cutoffUtc)
                } | Sort-Object -Property firstSeenUtc -Descending | Select-Object -First $pexShowCount
            )

            $urlBases = [string[]]($candidateImages | ForEach-Object { [string]$_.urlbase })

            try {
                $keepNames = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($ub in $urlBases) {
                    [void]$keepNames.Add(($ub -replace '[^a-zA-Z0-9]', '') + '_thumb.jpg')
                }
                Get-ChildItem -LiteralPath $CacheDir -Filter '*_thumb.jpg' -File -ErrorAction SilentlyContinue |
                Where-Object { -not $keepNames.Contains($_.Name) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            }
            catch {}

            if ($BatchQueue) {
                $batchSize = 8
                $allValidImages = @()
                for ($i = 0; $i -lt $candidateImages.Count; $i += $batchSize) {
                    if ($CancelToken -and $CancelToken.Cancelled) { break }
                    $chunkCount = [Math]::Min($batchSize, $candidateImages.Count - $i)
                    $chunkCandidates = @($candidateImages | Select-Object -Skip $i -First $chunkCount)

                    if ('BingWallpaper.FastDownloader' -as [type]) {
                        $chunkUrls = [string[]]($chunkCandidates | ForEach-Object { [string]$_.thumbUrl })
                        $chunkTargets = [string[]]($chunkCandidates | ForEach-Object {
                                $safe = $_.urlbase -replace '[^a-zA-Z0-9]', ''
                                Join-Path $CacheDir "${safe}_thumb.jpg"
                            })
                        [BingWallpaper.FastDownloader]::DownloadUrlsParallel($chunkUrls, $chunkTargets, 8)
                    }
                    else {
                        $wcChunk = New-Object System.Net.WebClient
                        $wcChunk.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                        foreach ($img in $chunkCandidates) {
                            $safe = $img.urlbase -replace '[^a-zA-Z0-9]', ''
                            $target = Join-Path $CacheDir "${safe}_thumb.jpg"
                            if (-not (Test-Path -LiteralPath $target) -and $img.thumbUrl) {
                                try { $wcChunk.DownloadFile($img.thumbUrl, $target) } catch {}
                            }
                        }
                        $wcChunk.Dispose()
                    }

                    if ($CancelToken -and $CancelToken.Cancelled) { break }

                    $validChunk = @($chunkCandidates | Where-Object {
                            $safe = $_.urlbase -replace '[^a-zA-Z0-9]', ''
                            $target = Join-Path $CacheDir "${safe}_thumb.jpg"
                            (Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -gt 0)
                        })

                    if ($validChunk.Count -gt 0) {
                        $chunkResult = @()
                        foreach ($img in $validChunk) {
                            $pAuthor = if ($img.photographer) { [string]$img.photographer }
                            elseif ($img.copyright -match '^Photo by (.+?) on Pexels') { $Matches[1] }
                            elseif ($img.copyright) { [string]$img.copyright }
                            else { '' }
                            $chunkResult += [PSCustomObject]@{
                                source       = 'Pexels'
                                urlbase      = [string]$img.urlbase
                                url          = [string]$img.url
                                title        = [string]$img.title
                                copyright    = [string]$img.copyright
                                photographer = $pAuthor
                                enddate      = ''
                                resX         = $img.resX
                                resY         = $img.resY
                                fileSize     = 0
                                fileType     = 'image/jpeg'
                            }
                        }
                        $allValidImages += $validChunk

                        $BatchQueue.Enqueue([PSCustomObject]@{
                                Type       = 'Batch'
                                Source     = 'Pexels'
                                BatchIndex = [int]($i / $batchSize)
                                Images     = $chunkResult
                                Total      = $candidateImages.Count
                                IsFirst    = ($i -eq 0)
                                IsLast     = (($i + $batchSize) -ge $candidateImages.Count)
                            })
                    }
                }

                if ($allValidImages.Count -eq 0 -and $candidateImages.Count -gt 0) {
                    $BatchQueue.Enqueue([PSCustomObject]@{
                            Type  = 'Error'
                            Error = "Unable to download Pexels wallpapers."
                        })
                    return @{ Success = $false; Error = "Unable to download Pexels wallpapers."; Images = @() }
                }

                try {
                    $allValidImages | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $historyPath -Encoding UTF8
                }
                catch {}

                $BatchQueue.Enqueue([PSCustomObject]@{
                        Type = 'Done'
                    })
                return @{ Success = $true; Error = $null; Images = @() }
            }

            if ('BingWallpaper.FastDownloader' -as [type]) {
                $thumbUrls = [string[]]($candidateImages | ForEach-Object { [string]$_.thumbUrl })
                $thumbTargets = [string[]]($candidateImages | ForEach-Object {
                        $safe = $_.urlbase -replace '[^a-zA-Z0-9]', ''
                        Join-Path $CacheDir "${safe}_thumb.jpg"
                    })
                [BingWallpaper.FastDownloader]::DownloadUrlsParallel($thumbUrls, $thumbTargets, 20)
            }
            else {
                $wc2 = New-Object System.Net.WebClient
                $wc2.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                foreach ($img in $candidateImages) {
                    $safe = $img.urlbase -replace '[^a-zA-Z0-9]', ''
                    $target = Join-Path $CacheDir "${safe}_thumb.jpg"
                    if (-not (Test-Path -LiteralPath $target) -and $img.thumbUrl) {
                        try { $wc2.DownloadFile($img.thumbUrl, $target) } catch {}
                    }
                }
                $wc2.Dispose()
            }

            $uniqueImages = @($candidateImages | Where-Object {
                    $safe = $_.urlbase -replace '[^a-zA-Z0-9]', ''
                    $target = Join-Path $CacheDir "${safe}_thumb.jpg"
                    (Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -gt 0)
                })

            if ($uniqueImages.Count -eq 0 -and $candidateImages.Count -gt 0) {
                return @{ Success = $false; Error = "Unable to download Pexels wallpapers."; Images = @() }
            }

            try {
                $uniqueImages | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $historyPath -Encoding UTF8
            }
            catch {}

            $resultImages = @()
            foreach ($img in $uniqueImages) {
                $pAuthor = if ($img.photographer) { [string]$img.photographer }
                elseif ($img.copyright -match '^Photo by (.+?) on Pexels') { $Matches[1] }
                elseif ($img.copyright) { [string]$img.copyright }
                else { '' }
                $resultImages += [PSCustomObject]@{
                    source       = 'Pexels'
                    urlbase      = [string]$img.urlbase
                    url          = [string]$img.url
                    title        = [string]$img.title
                    copyright    = [string]$img.copyright
                    photographer = $pAuthor
                    enddate      = ''
                    resX         = $img.resX
                    resY         = $img.resY
                    fileSize     = $img.fileSize
                    fileType     = [string]$img.fileType
                }
            }

            return @{ Success = $true; Error = $null; Images = $resultImages }
        }

        # BingWallpaper.FastDownloader was already compiled in-memory at
        # script startup and is visible to this runspace (same process,
        # same default AppDomain) - nothing to load here.
        $market = if ($Region -eq 'auto') { 'en-US' } else { $Region }
        $uri1 = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=$market"
        $uri2 = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=8&n=8&mkt=$market"

        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        $json1 = $null; $json2 = $null
        try { $json1 = $wc.DownloadString($uri1) } catch {}
        try { $json2 = $wc.DownloadString($uri2) } catch {}
        $wc.Dispose()

        $batch1 = if ($json1) { (ConvertFrom-Json -InputObject $json1).images } else { @() }
        $batch2 = if ($json2) { (ConvertFrom-Json -InputObject $json2).images } else { @() }

        $allImages = @()
        if ($batch1) { $allImages += $batch1 }
        if ($batch2) { $allImages += $batch2 }

        $items = @($allImages | Group-Object -Property urlbase | ForEach-Object { $_.Group[0] })

        # --- Load the persisted history (images we've already seen
        # in a previous session, within the last $HistoryMaxDays).
        # Same pattern as Spotlight: Bing's own archive endpoint only
        # ever exposes its trailing ~16 images (idx 0-15), so without
        # this the gallery resets to just those 16 every load and
        # anything Bing itself has rotated past is gone for good.
        # Merging into local history lets the gallery accumulate up
        # to $HistoryMaxDays worth of wallpapers, as long as the app
        # (or its scheduled task) runs at least once within Bing's
        # own ~16-day rotation window so nothing slips through. -----
        $historyPath = Join-Path $CacheDir '_history.json'
        $historyMap = @{}
        if (Test-Path -LiteralPath $historyPath) {
            try {
                $rawHistory = Get-Content -LiteralPath $historyPath -Raw -ErrorAction Stop
                if ($rawHistory) {
                    # Repair pass - see the matching comment in the
                    # Spotlight branch above. Bing's real per-image
                    # `enddate` is the primary sort key below so this
                    # mainly guards the firstSeenUtc fallback path,
                    # but it's cheap and keeps all three sources
                    # consistent. -------------------------------------
                    $loadedArray = @(ConvertFrom-Json -InputObject $rawHistory)
                    $seenStampCounts = @{}
                    foreach ($h in $loadedArray) {
                        $stampKey = [string]$h.firstSeenUtc
                        $parsedOk = $false
                        $baseTime = [DateTime]::MinValue
                        if (-not [string]::IsNullOrWhiteSpace($stampKey)) {
                            try {
                                $baseTime = [DateTime]::Parse($stampKey, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                $parsedOk = $true
                            }
                            catch {}
                        }
                        if (-not $parsedOk) { $baseTime = [DateTime]::UtcNow; $stampKey = $baseTime.ToString('o') }
                        if ($seenStampCounts.ContainsKey($stampKey)) {
                            $bump = $seenStampCounts[$stampKey]
                            $seenStampCounts[$stampKey] = $bump + 1
                            $h.firstSeenUtc = $baseTime.AddMilliseconds(-1 * $bump).ToString('o')
                        }
                        else {
                            $seenStampCounts[$stampKey] = 1
                            $h.firstSeenUtc = $baseTime.ToString('o')
                        }
                        if ($h.urlbase) { $historyMap[[string]$h.urlbase] = $h }
                    }
                }
            }
            catch {}
        }

        if ((-not $items -or $items.Count -eq 0) -and $historyMap.Count -eq 0) {
            return @{ Success = $false; Error = "Unable to connect to Bing."; Images = @() }
        }

        # --- Merge today's feed into the history. Existing entries
        # keep their original FirstSeenUtc (so they age out on
        # schedule) but get refreshed metadata/URLs. New entries get
        # a strictly-decreasing per-item stamp rather than one shared
        # $nowUtc for the whole batch - same reasoning as the
        # Spotlight branch above: a shared stamp creates ties that
        # fall back to $historyMap's arbitrary Hashtable enumeration
        # order, which is what produced the "random" ordering.
        # For Bing specifically this barely matters for TODAY's
        # single freshly-stamped batch, because the real fix below
        # is sorting by Bing's own per-image `enddate` (an actual
        # calendar date) instead of firstSeenUtc at all - but it
        # still keeps the fallback path correct. --------------------
        $nowUtc = [DateTime]::UtcNow
        $newBatchIndex = 0
        foreach ($item in $items) {
            if ([string]::IsNullOrWhiteSpace([string]$item.urlbase)) { continue }
            $urlbase = [string]$item.urlbase
            $firstSeen = if ($historyMap.ContainsKey($urlbase) -and $historyMap[$urlbase].firstSeenUtc) {
                [string]$historyMap[$urlbase].firstSeenUtc
            }
            else {
                $stamp = $nowUtc.AddMilliseconds(-1 * $newBatchIndex)
                $newBatchIndex++
                $stamp.ToString('o')
            }
            $historyMap[$urlbase] = [PSCustomObject]@{
                urlbase      = $urlbase
                url          = [string]$item.url
                title        = [string]$item.title
                copyright    = [string]$item.copyright
                enddate      = [string]$item.enddate
                firstSeenUtc = $firstSeen
            }
        }

        # --- Prune anything older than the retention window, then
        # cap how many we render/download this load (same reasoning
        # as Spotlight's cap above). ------------------------------
        $bingShowCount = 360
        $cutoffUtc = $nowUtc.AddDays(-1 * [Math]::Abs($HistoryMaxDays))
        $candidateImages = @(
            $historyMap.Values | Where-Object {
                $ok = $true
                $seen = [DateTime]::MinValue
                try {
                    $seen = [DateTime]::Parse(
                        [string]$_.firstSeenUtc,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind
                    )
                }
                catch { $ok = $false }
                (-not $ok) -or ($seen.ToUniversalTime() -ge $cutoffUtc)
            } | Sort-Object -Descending -Property @{
                # Bing gives every image a real calendar date
                # (enddate, format yyyyMMdd) - use THAT as the true
                # "latest first" ordering instead of firstSeenUtc,
                # which only reflects when this machine happened to
                # fetch it (irrelevant to, and less reliable than,
                # the wallpaper's actual date). Falls back to
                # firstSeenUtc only if enddate is missing/malformed.
                Expression = {
                    $d = [DateTime]::MinValue
                    $okDate = [DateTime]::TryParseExact(
                        [string]$_.enddate, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::None, [ref]$d
                    )
                    if ($okDate) { $d } else {
                        try { [DateTime]::Parse([string]$_.firstSeenUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) }
                        catch { [DateTime]::MinValue }
                    }
                }
            } | Select-Object -First $bingShowCount
        )

        $urlBases = [string[]]($candidateImages | ForEach-Object { [string]$_.urlbase })

        # Prune thumbnails that have aged out of the retention
        # window entirely (NOT just "not in Bing's current 16" -
        # that's what used to wipe everything older on every
        # refresh, same fix as Spotlight/Wallhaven).
        try {
            $keepNames = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($ub in $urlBases) {
                [void]$keepNames.Add(($ub -replace '[^a-zA-Z0-9]', '') + '_thumb.jpg')
            }
            Get-ChildItem -LiteralPath $CacheDir -Filter '*_thumb.jpg' -File -ErrorAction SilentlyContinue |
            Where-Object { -not $keepNames.Contains($_.Name) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        }
        catch {}

        # Only the thumbnails we don't already have on disk actually
        # hit the network (both downloaders skip an existing target),
        # so images carried over from history cost nothing here.
        if ('BingWallpaper.FastDownloader' -as [type]) {
            [BingWallpaper.FastDownloader]::DownloadThumbnailsParallel($urlBases, $CacheDir)
        }
        else {
            $wc2 = New-Object System.Net.WebClient
            $wc2.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            foreach ($ub in $urlBases) {
                $safe = $ub -replace '[^a-zA-Z0-9]', ''
                $target = Join-Path $CacheDir "${safe}_thumb.jpg"
                if (-not (Test-Path -LiteralPath $target)) {
                    try { $wc2.DownloadFile("https://www.bing.com${ub}_1920x1080.jpg&w=640&h=360&rs=1&c=4", $target) } catch {}
                }
            }
            $wc2.Dispose()
        }

        # --- Validate: only keep entries whose thumbnail actually
        # exists on disk with real content, and drop dead ones from
        # the persisted history too. ---------------------------------
        $uniqueImages = @($candidateImages | Where-Object {
                $safe = $_.urlbase -replace '[^a-zA-Z0-9]', ''
                $target = Join-Path $CacheDir "${safe}_thumb.jpg"
                (Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -gt 0)
            })

        if ($uniqueImages.Count -eq 0 -and $candidateImages.Count -gt 0) {
            return @{ Success = $false; Error = "Unable to connect to Bing."; Images = @() }
        }

        try {
            $uniqueImages | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $historyPath -Encoding UTF8
        }
        catch {}

        $resultImages = @()
        foreach ($img in $uniqueImages) {
            $resultImages += [PSCustomObject]@{
                urlbase   = [string]$img.urlbase
                url       = [string]$img.url
                title     = [string]$img.title
                copyright = [string]$img.copyright
                enddate   = [string]$img.enddate
            }
        }

        return @{ Success = $true; Error = $null; Images = $resultImages }
    }
    catch {
        return @{ Success = $false; Error = $_.Exception.Message; Images = @() }
    }
}
