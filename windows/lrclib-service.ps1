param(
    [string]$LibraryPath = 'G:\Music\Library',
    [int]$ScanInterval = 300,
    [string]$LogFile = 'C:\Tools\lrclib-service\lrclib.log',
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
    $todo = @()
    foreach ($f in $audioFiles) {
        $lrc = [System.IO.Path]::ChangeExtension($f.FullName, '.lrc')
        if (-not (Test-Path -LiteralPath $lrc)) { $todo += $f }
    }
    Log "Scan start: total=$($audioFiles.Count)  todo=$($todo.Count)"

    $stats = @{ ok = 0; none = 0; notag = 0; skip = 0; err = 0 }
    $i = 0
    foreach ($f in $todo) {
        $i++
        try {
            $r = Invoke-Track $f.FullName
            if ($stats.ContainsKey($r)) { $stats[$r] += 1 }
        } catch {
            $stats.err += 1
            Log "ERR on $($f.FullName): $($_.Exception.Message)"
        }
        Start-Sleep -Milliseconds 200  # rate limit 5 req/s
        if ($i % 50 -eq 0) { Log "Progress: $i / $($todo.Count)" }
    }
    Log "Scan done: ok=$($stats.ok) none=$($stats.none) notag=$($stats.notag) err=$($stats.err)"
    return $stats
}

if ($OneShot) {
    $s = Invoke-LibraryScan
    Log "OneShot complete"
    exit 0
}

# Service mode
while ($true) {
    try {
        $scanResult = Invoke-LibraryScan
        # Auto-embed lyrics into FLAC files after each scan
        if ($scanResult.ok -gt 0 -and -not $DryRun) {
            Log "Triggering embed-lyrics for $($scanResult.ok) new .lrc files..."
            & powershell -ExecutionPolicy Bypass -File 'C:\Tools\lrclib-service\embed-lyrics.ps1' 2>$null
        } elseif ($scanResult.ok -gt 0 -and $DryRun) {
            Log "DRY: would trigger embed-lyrics for $($scanResult.ok) new .lrc files"
        }
    }
    catch { Log "Fatal scan error: $($_.Exception.Message)" }
    Start-Sleep -Seconds $ScanInterval
}
