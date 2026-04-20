# Yandex.Music lyrics provider. Pure-function helpers first; API calls added in Task 8.

function Get-LevenshteinDistance {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)][AllowEmptyString()][string]$s,
        [Parameter(Position=1)][AllowEmptyString()][string]$t
    )
    if ([string]::IsNullOrEmpty($s)) { return $t.Length }
    if ([string]::IsNullOrEmpty($t)) { return $s.Length }

    $n = $s.Length
    $m = $t.Length
    $d = New-Object 'int[,]' ($n+1), ($m+1)

    for ($i = 0; $i -le $n; $i++) { $d[$i, 0] = $i }
    for ($j = 0; $j -le $m; $j++) { $d[0, $j] = $j }

    for ($i = 1; $i -le $n; $i++) {
        for ($j = 1; $j -le $m; $j++) {
            $im1 = $i - 1
            $jm1 = $j - 1
            $cost = if ($s[$im1] -ceq $t[$jm1]) { 0 } else { 1 }
            $deleteCost = $d[$im1, $j] + 1
            $insertCost = $d[$i, $jm1] + 1
            $replaceCost = $d[$im1, $jm1] + $cost
            $d[$i, $j] = [Math]::Min([Math]::Min($deleteCost, $insertCost), $replaceCost)
        }
    }
    return $d[$n, $m]
}

function Normalize-TrackTitle {
    [CmdletBinding()]
    param([string]$Title)
    # Strip trailing bracketed suffixes like "(Remastered 2011)", "[Bonus Track]", "(Live)"
    $clean = $Title -replace '\s*[\(\[].*?[\)\]]\s*$'
    return $clean.Trim().ToLowerInvariant()
}

function Normalize-ArtistName {
    [CmdletBinding()]
    param([string]$Artist)
    # Strip leading "The " for tolerance: "Beatles" ≈ "The Beatles"
    $clean = $Artist -ireplace '^\s*the\s+'
    return $clean.Trim().ToLowerInvariant()
}

function Test-YandexTrackMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Needle,
        $Candidate
    )

    if ($null -eq $Candidate) { return $false }

    # Duration tolerance check (skip when Duration = -1, i.e. tag not available)
    if ($Needle.Duration -gt 0) {
        $candidateSeconds = [int]($Candidate.durationMs / 1000)
        $diff = [Math]::Abs($candidateSeconds - $Needle.Duration)
        if ($diff -gt $script:YandexMatchDurationTolerance) { return $false }
    }

    $needleArtist = Normalize-ArtistName $Needle.Artist
    $candidateArtist = Normalize-ArtistName ($Candidate.artists[0].name)
    if ((Get-LevenshteinDistance $needleArtist $candidateArtist) -gt $script:YandexMatchLevenshteinMax) {
        return $false
    }

    $needleTitle = Normalize-TrackTitle $Needle.Track
    $candidateTitle = Normalize-TrackTitle $Candidate.title
    if ((Get-LevenshteinDistance $needleTitle $candidateTitle) -gt $script:YandexMatchLevenshteinMax) {
        return $false
    }

    return $true
}

function New-YandexHmacSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [Parameter(Mandatory)][long]$TimeStamp,
        [Parameter(Mandatory)][string]$Secret
    )
    $message = "$TrackId$TimeStamp"
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($Secret)
        $bytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($message))
        return [Convert]::ToBase64String($bytes)
    } finally {
        $hmac.Dispose()
    }
}

# ========================================================================
# Yandex API functions (Task 8)
# ========================================================================

function Get-YandexToken {
    [CmdletBinding()]
    param()
    if (-not (Test-Path $script:YandexTokenPath)) {
        throw "Yandex token not found at $script:YandexTokenPath"
    }
    $raw = Get-Content $script:YandexTokenPath -Raw -ErrorAction Stop
    return $raw.Trim()
}

function Get-YandexApiHeaders {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Token)
    return @{
        'Authorization' = "OAuth $Token"
        'User-Agent' = $script:YandexUserAgent
        'Accept' = 'application/json'
        'X-Yandex-Music-Client' = $script:YandexClientHeader
    }
}

function Set-YandexAuthFailedFlag {
    [CmdletBinding()]
    param([string]$Reason)
    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Reason"
    Add-Content -Path $script:YandexAuthFailedFlag -Value $line -Encoding UTF8
}

function Set-YandexSignatureFailedFlag {
    [CmdletBinding()]
    param([string]$Reason)
    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Reason"
    Add-Content -Path $script:YandexSignatureFailedFlag -Value $line -Encoding UTF8
}

function Search-YandexTrack {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Artist,
        [Parameter(Mandatory)][string]$Track,
        [int]$Duration = -1,
        [Parameter(Mandatory)][string]$Token
    )
    $query = "$Artist $Track"
    $uri = "https://api.music.yandex.net/search?type=track&page=0&text=$([Uri]::EscapeDataString($query))"
    $headers = Get-YandexApiHeaders -Token $Token

    try {
        $r = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        Start-Sleep -Milliseconds $script:YandexRateLimitMs
    } catch {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 401) { Set-YandexAuthFailedFlag "Search 401" }
        throw
    }

    if (-not $r.result -or -not $r.result.tracks -or -not $r.result.tracks.results) { return $null }

    $needle = @{ Artist = $Artist; Track = $Track; Duration = $Duration }
    $matches = @($r.result.tracks.results | Where-Object {
        Test-YandexTrackMatches -Needle $needle -Candidate $_
    })
    if ($matches.Count -eq 0) { return $null }

    if ($Duration -gt 0) {
        $best = $matches | Sort-Object { [Math]::Abs([int]($_.durationMs / 1000) - $Duration) } | Select-Object -First 1
    } else {
        $best = $matches[0]
    }
    return $best
}

function Get-YandexSyncLyrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [Parameter(Mandatory)][string]$Token
    )
    $headers = Get-YandexApiHeaders -Token $Token

    # timeStamp MUST be Unix SECONDS (not ms). Verified Task 3.
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $sign = New-YandexHmacSignature -TrackId $TrackId -TimeStamp $ts -Secret $script:YandexHmacSecret

    $uri = "https://api.music.yandex.net/tracks/$TrackId/lyrics?" +
           "format=LRC&" +
           "timeStamp=$ts&" +
           "sign=$([Uri]::EscapeDataString($sign))"
    try {
        $lyr = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        Start-Sleep -Milliseconds $script:YandexRateLimitMs
    } catch {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 401) { Set-YandexAuthFailedFlag "Lyrics 401" }
        if ($code -eq 403) { Set-YandexSignatureFailedFlag "Lyrics 403 - possible HMAC scheme change" }
        if ($code -eq 404) { return $null }   # no lyrics for this track
        throw
    }

    if (-not $lyr.result -or -not $lyr.result.downloadUrl) { return $null }

    $raw = Invoke-WebRequest -Uri $lyr.result.downloadUrl -UseBasicParsing -TimeoutSec 15
    Start-Sleep -Milliseconds $script:YandexRateLimitMs

    $text = [System.Text.Encoding]::UTF8.GetString($raw.Content).TrimEnd()
    # LRC must start with a timestamp line
    if ($text -notmatch '^\s*\[\d+:\d+') { return $null }
    return $text
}

function Invoke-LyricsProvider-Yandex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Artist,
        [Parameter(Mandatory)][string]$Track,
        [string]$Album = '',
        [int]$Duration = -1
    )

    try {
        $token = Get-YandexToken
    } catch {
        Write-Warning "Yandex token unavailable: $_"
        return $null
    }

    # Circuit-break if auth flag is fresh (< 1h old)
    if (Test-Path $script:YandexAuthFailedFlag) {
        $age = (Get-Date) - (Get-Item $script:YandexAuthFailedFlag).LastWriteTime
        if ($age.TotalMinutes -lt 60) {
            return $null
        }
    }

    $attempt = 0
    while ($attempt -lt 3) {
        try {
            $trackMatch = Search-YandexTrack -Artist $Artist -Track $Track -Duration $Duration -Token $token
            if (-not $trackMatch) { return $null }

            $lrc = Get-YandexSyncLyrics -TrackId $trackMatch.id -Token $token
            if (-not $lrc) { return $null }

            return @{
                Text = $lrc
                IsSynced = $true
                Source = 'Yandex'
                StatusReason = 'yandex-match'
            }
        } catch {
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }

            if ($code -eq 429) {
                $attempt++
                $backoff = [int][Math]::Pow(2, $attempt)
                Write-Warning "Yandex 429 - backoff ${backoff}s (attempt $attempt/3)"
                Start-Sleep -Seconds $backoff
                continue
            }
            if ($code -eq 401) {
                return $null
            }
            if ($code -ge 500) {
                $attempt++
                Start-Sleep -Seconds 5
                continue
            }
            Write-Warning "Yandex provider error ($code): $($_.Exception.Message)"
            return $null
        }
    }
    return $null
}
