param(
    [string]$LibraryPath = 'G:\Music\Library',
    [int]$ScanInterval = 300,
    [string]$LogFile = 'C:\Tools\lrclib-service\lrclib.log',
    # Negative cache: tracks that no provider has lyrics for. Without it every
    # scan cycle re-queries every hopeless track - 364 misses x 288 cycles/day
    # was ~105k pointless requests to lrclib.net per day and a 105 MB log.
    [string]$MissCachePath = 'C:\Tools\lrclib-service\misses.json',
    [int]$MissTtlDays = 14,
    [int]$MaxLogSizeMB = 10,
    [switch]$OneShot,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

# Force UTF-8 for external process I/O. ffprobe emits UTF-8 JSON; PS 5.1 default
# on RU locale is cp1251, which silently mangles Cyrillic tags mid-pipeline and
# breaks Yandex artist/title matching for every non-Latin track.
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

# Dot-source config (optional) and providers
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot 'config.ps1'
if (Test-Path -LiteralPath $configPath) {
    . $configPath
    Write-Host "Loaded config from $configPath"
} else {
    Write-Host "No config.ps1 found, running in legacy mode (LRCLib only)"
    $script:LyricsProviders = @('LRCLib')
}
foreach ($provName in $script:LyricsProviders) {
    $pfile = Join-Path $scriptRoot "providers\$($provName.ToLower()).ps1"
    if (Test-Path -LiteralPath $pfile) {
        . $pfile
        Write-Host "Loaded provider: $provName"
    } else {
        Write-Warning "Provider file missing: $pfile (skipping $provName)"
    }
}

# --- Locate ffprobe ---
$ffprobe = $null
$candidates = @(
    'C:\Program Files\Navidrome\ffprobe.exe',
    'C:\Tools\lrclib-service\ffprobe.exe',
    'C:\ffmpeg\bin\ffprobe.exe',
    'C:\Users\user\AppData\Local\Microsoft\WinGet\Links\ffprobe.exe'
)
foreach ($p in $candidates) {
    if (Test-Path -LiteralPath $p) { $ffprobe = $p; break }
}
if (-not $ffprobe) {
    $gc = Get-Command ffprobe.exe -ErrorAction SilentlyContinue
    if ($gc) { $ffprobe = $gc.Source }
}
if (-not $ffprobe) { Write-Error "ffprobe not found in any known location"; exit 2 }

# --- Logging ---
$logDir = Split-Path $LogFile -Parent
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Log {
    param([string]$msg)
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
    # Rotate. This service logs one line per track per cycle; unrotated it reached
    # 105 MB. Keep a single .old generation.
    try {
        $fi = Get-Item -LiteralPath $LogFile -ErrorAction Stop
        if ($fi.Length -gt ($MaxLogSizeMB * 1MB)) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
        }
    } catch {}
}

# --- Negative cache -------------------------------------------------------
# Key: "<path>|<length>|<mtime ticks>". Any change to the file (retag, replace)
# changes the key, so the track is retried automatically.
function Get-MissKey {
    param($fileInfo)
    return "{0}|{1}|{2}" -f $fileInfo.FullName, $fileInfo.Length, $fileInfo.LastWriteTimeUtc.Ticks
}

function Import-MissCache {
    if (-not (Test-Path -LiteralPath $MissCachePath)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $MissCachePath -Raw -ErrorAction Stop
        if (-not $raw) { return @{} }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch {
        Log "MISSCACHE: unreadable ($($_.Exception.Message)), starting empty"
        return @{}
    }
}

function Export-MissCache {
    param([hashtable]$cache)
    try {
        $tmp = "$MissCachePath.tmp"
        ($cache | ConvertTo-Json -Depth 3 -Compress) | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $MissCachePath -Force
    } catch {
        Log "MISSCACHE: save failed - $($_.Exception.Message)"
    }
}

Log "=== lrclib-service start  library='$LibraryPath'  interval=${ScanInterval}s  ffprobe='$ffprobe' ==="
if ($DryRun) { Log "DRY-RUN mode enabled - no files written, no embed triggered" }

# --- Tag extraction via ffprobe JSON ---
function Get-TrackInfo {
    param([string]$audioPath)
    $raw = & $ffprobe -v quiet -print_format json -show_format $audioPath 2>$null
    if (-not $raw) { return $null }
    try { $json = $raw | ConvertFrom-Json } catch { return $null }
    if (-not $json.format -or -not $json.format.tags) { return $null }

    $tags = $json.format.tags
    $title = $null; $artist = $null; $album = ''
    foreach ($p in $tags.PSObject.Properties) {
        switch -regex ($p.Name.ToLower()) {
            '^title$'    { if (-not $title)  { $title  = $p.Value } }
            '^artist$'   { if (-not $artist) { $artist = $p.Value } }
            '^album$'    { if (-not $album)  { $album  = $p.Value } }
        }
    }

    if (-not $title -or -not $artist) { return $null }
    $dur = 0
    if ($json.format.duration) { $dur = [int][math]::Round([double]$json.format.duration) }
    return [pscustomobject]@{
        Title = "$title".Trim()
        Artist = "$artist".Trim()
        Album = "$album".Trim()
        Duration = $dur
    }
}

# --- Process one audio file ---
function Invoke-Track {
    param([string]$audioPath)
    $lrcPath = [System.IO.Path]::ChangeExtension($audioPath, '.lrc')
    # NOTE: -LiteralPath is REQUIRED. Without it, paths containing [ ] are
    # interpreted as PowerShell glob patterns (character classes), causing
    # Test-Path to return $false for files like "14 - [ost] dreamseeker.lrc"
    # even when they exist, resulting in infinite re-processing loops.
    if (Test-Path -LiteralPath $lrcPath) { return 'skip' }

    $info = Get-TrackInfo $audioPath
    if (-not $info) {
        Log "NOTAG: $audioPath"
        return 'notag'
    }

    # Provider loop - first IsSynced wins
    $best = $null
    foreach ($providerName in $script:LyricsProviders) {
        $funcName = "Invoke-LyricsProvider-$providerName"
        if (-not (Get-Command $funcName -ErrorAction SilentlyContinue)) {
            continue
        }
        try {
            $result = & $funcName -Artist $info.Artist -Track $info.Title -Album $info.Album -Duration $info.Duration
        } catch {
            Log "PROVIDER_ERR [$providerName] '$($info.Artist) - $($info.Title)': $($_.Exception.Message)"
            continue
        }
        if ($result -and $result.IsSynced) {
            $best = $result
            break
        }
        if ($result -and -not $best) {
            $best = $result
        }
    }
    $lyrics = if ($best) { $best.Text } else { $null }
    $source = if ($best) { "$($best.Source):$($best.StatusReason)" } else { 'none' }
    if ($lyrics) {
        $lines = ($lyrics -split "`n").Count
        if ($DryRun) {
            Log ("DRY [{0}] '{1} - {2}' would-write {3}L -> {4}" -f $source, $info.Artist, $info.Title, $lines, $lrcPath)
            return 'ok'
        }
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($lyrics.Replace("`r`n","`n"))
        [System.IO.File]::WriteAllBytes($lrcPath, $bytes)
        Log ("OK [{0}L] ({1}): '{2} - {3}' [{4}] -> {5}" -f $lines, $source, $info.Artist, $info.Title, $info.Album, $lrcPath)
        return 'ok'
    } else {
        if ($DryRun) {
            Log ("DRY-NONE '{0} - {1}' [{2}] {3}s" -f $info.Artist, $info.Title, $info.Album, $info.Duration)
        } else {
            Log ("NONE: '{0} - {1}' [{2}] {3}s" -f $info.Artist, $info.Title, $info.Album, $info.Duration)
        }
        return 'none'
    }
}

# --- Full library scan ---
function Invoke-LibraryScan {
    $extensions = @('.mp3','.flac','.m4a','.ogg','.opus','.wav','.aac')
    $audioFiles = Get-ChildItem -LiteralPath $LibraryPath -Recurse -File -ErrorAction SilentlyContinue |
                  Where-Object { $extensions -contains $_.Extension.ToLower() }
    $missCache = Import-MissCache
    $now = Get-Date
    $ttl = New-TimeSpan -Days $MissTtlDays

    $todo = @()
    $cached = 0
    foreach ($f in $audioFiles) {
        $lrc = [System.IO.Path]::ChangeExtension($f.FullName, '.lrc')
        if (Test-Path -LiteralPath $lrc) { continue }

        $key = Get-MissKey $f
        if ($missCache.ContainsKey($key)) {
            # [datetime]::TryParse needs [ref] to an already-typed datetime variable;
            # passing [ref]$null fails overload resolution on PS 5.1. Parse in a
            # try/catch instead - simpler and version-proof.
            $seen = $null
            try { $seen = [datetime]::Parse([string]$missCache[$key], [System.Globalization.CultureInfo]::InvariantCulture) } catch { $seen = $null }
            if ($seen -and (($now - $seen) -lt $ttl)) {
                $cached++
                continue
            }
        }
        $todo += $f
    }
    Log "Scan start: total=$($audioFiles.Count)  todo=$($todo.Count)  suppressed_by_cache=$cached"

    $stats = @{ ok = 0; none = 0; notag = 0; skip = 0; err = 0 }
    $i = 0
    $cacheDirty = $false
    foreach ($f in $todo) {
        $i++
        $key = Get-MissKey $f
        try {
            $r = Invoke-Track $f.FullName
            if ($stats.ContainsKey($r)) { $stats[$r] += 1 }
            if ($r -eq 'none' -or $r -eq 'notag') {
                $missCache[$key] = $now.ToString('o')
                $cacheDirty = $true
            } elseif ($r -eq 'ok' -and $missCache.ContainsKey($key)) {
                $missCache.Remove($key)
                $cacheDirty = $true
            }
        } catch {
            $stats.err += 1
            Log "ERR on $($f.FullName): $($_.Exception.Message)"
        }
        Start-Sleep -Milliseconds 200  # rate limit 5 req/s
        if ($i % 50 -eq 0) { Log "Progress: $i / $($todo.Count)" }
    }

    # Drop entries whose file no longer exists, so the cache cannot grow forever.
    $live = @{}
    foreach ($f in $audioFiles) { $live[(Get-MissKey $f)] = $true }
    foreach ($k in @($missCache.Keys)) {
        if (-not $live.ContainsKey($k)) { $missCache.Remove($k); $cacheDirty = $true }
    }
    if ($cacheDirty -and -not $DryRun) { Export-MissCache $missCache }

    Log "Scan done: ok=$($stats.ok) none=$($stats.none) notag=$($stats.notag) err=$($stats.err) cache_entries=$($missCache.Count)"
    return $stats
}

if ($OneShot) {
    $s = Invoke-LibraryScan
    Log "OneShot complete"
    exit 0
}

# --- Embedder helper ---
# Prefer the unified Python embedder (FLAC + MP3 + M4A, mutagen-based). Falls
# back to the legacy PS metaflac embedder if the venv is missing - useful for
# bootstrapping before the first provisioning run.
$script:PyEmbedder = 'C:\Tools\lrclib-service\.venv\Scripts\python.exe'
$script:PyEmbedScript = 'C:\Tools\lrclib-service\embed-all-lyrics.py'
$script:PsEmbedScript = 'C:\Tools\lrclib-service\embed-lyrics.ps1'
$script:EmbedLogPath = 'C:\Tools\lrclib-service\embed-all.log'

function Invoke-EmbedPass {
    param([string]$LibraryPath)
    if ((Test-Path -LiteralPath $script:PyEmbedder) -and (Test-Path -LiteralPath $script:PyEmbedScript)) {
        & $script:PyEmbedder $script:PyEmbedScript --library $LibraryPath --log $script:EmbedLogPath 2>$null
    } elseif (Test-Path -LiteralPath $script:PsEmbedScript) {
        & powershell -ExecutionPolicy Bypass -File $script:PsEmbedScript 2>$null
    } else {
        Log "No embedder available (Python venv and PS fallback both missing)"
    }
}

# Service mode
while ($true) {
    try {
        $scanResult = Invoke-LibraryScan
        # Always run embed pass - it is idempotent (mutagen skips files whose tag
        # already matches the .lrc), AND this catches the case where Lidarr /
        # decluttarr re-imports a file and silently strips its USLT / LYRICS
        # tag. Gating only on ok>0 would miss those re-imports because no new
        # .lrc sidecar was created.
        if (-not $DryRun) {
            Log "Triggering embed pass (scan ok=$($scanResult.ok) none=$($scanResult.none))..."
            Invoke-EmbedPass -LibraryPath $LibraryPath
        } else {
            Log "DRY: would trigger embed pass after scan"
        }
    }
    catch { Log "Fatal scan error: $($_.Exception.Message)" }
    Start-Sleep -Seconds $ScanInterval
}
