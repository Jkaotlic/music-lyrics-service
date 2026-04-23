param(
    [string]$LibraryPath = 'G:\Music\Library',
    [string]$LogFile = 'C:\Tools\lrclib-service\embed-lyrics.log'
)

$ErrorActionPreference = 'Continue'
function Log { param([string]$msg); $l = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg; Add-Content -LiteralPath $LogFile -Value $l -Encoding UTF8; Write-Host $l }

$metaflac = (Get-Command metaflac.exe -ErrorAction SilentlyContinue).Source
if (-not $metaflac) { Write-Error "metaflac not found"; exit 2 }

Log "=== embed-lyrics v7 (LRC-aware, -LiteralPath safe) metaflac=$metaflac ==="

$flacFiles = Get-ChildItem -LiteralPath $LibraryPath -Recurse -File -Filter '*.flac' -ErrorAction SilentlyContinue
$stats = @{ embedded = 0; skipped = 0; noLrc = 0; err = 0; mp3skip = 0 }

foreach ($f in $flacFiles) {
    $lrcPath = [System.IO.Path]::ChangeExtension($f.FullName, '.lrc')
    # -LiteralPath: prevent [ ] in filenames from being treated as glob patterns.
    if (-not (Test-Path -LiteralPath $lrcPath)) { $stats.noLrc++; continue }

    # Read fresh .lrc content first; it is the source of truth
    $lrcRaw = [System.IO.File]::ReadAllText($lrcPath, [System.Text.UTF8Encoding]::new($false)).Trim()
    if ($lrcRaw.Length -lt 10) { $stats.skipped++; continue }

    # Read existing LYRICS tag (metaflac prints lines like "LYRICS=<value>")
    $existingRaw = & $metaflac --show-tag=LYRICS $f.FullName 2>$null
    $existingValue = if ($existingRaw) { ($existingRaw -join "`n") -replace '^LYRICS=', '' } else { '' }

    $desiredIsSynced  = $lrcRaw       -match '^\s*\[\d+:\d+'
    $existingIsSynced = $existingValue -match '^\s*\[\d+:\d+'

    if ($existingValue) {
        $normExisting = ($existingValue -replace "`r", '').Trim()
        $normDesired  = ($lrcRaw        -replace "`r", '').Trim()

        if ($normExisting -eq $normDesired) {
            $stats.skipped++; continue
        }

        if ($desiredIsSynced -and -not $existingIsSynced) {
            Log "UPGRADE plain->synced: $($f.Name)"
            & $metaflac --remove-tag=LYRICS $f.FullName 2>$null | Out-Null
        } elseif ($normExisting -ne $normDesired) {
            Log "REFRESH diverged tag: $($f.Name)"
            & $metaflac --remove-tag=LYRICS $f.FullName 2>$null | Out-Null
        }
        # After --remove-tag, the subsequent --set-tag-from-file writes fresh
    }

    # Write lyrics to a temp file for --set-tag-from-file
    $tmpTag = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmpTag, $lrcRaw, [System.Text.UTF8Encoding]::new($false))

    try {
        & $metaflac --set-tag-from-file="LYRICS=$tmpTag" $f.FullName 2>$null
        if ($LASTEXITCODE -eq 0) {
            $stats.embedded++
            if ($stats.embedded % 25 -eq 0) { Log "Progress: embedded=$($stats.embedded)" }
        } else {
            $stats.err++
            Log "METAFLAC_ERR: $($f.Name) exit=$LASTEXITCODE"
        }
    } catch {
        $stats.err++
        Log "ERR: $($f.Name) $($_.Exception.Message)"
    }
    Remove-Item -LiteralPath $tmpTag -Force -ErrorAction SilentlyContinue
}

Log "=== embed-lyrics v7 done: embedded=$($stats.embedded) skipped=$($stats.skipped) noLrc=$($stats.noLrc) err=$($stats.err) ==="
