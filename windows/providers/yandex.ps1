# C:\Tools\lrclib-service\providers\yandex.ps1
# Yandex.Music lyrics provider with Cyrillic-aware fuzzy matching.

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

# ----------------------------------------------------------------------------
# Normalization: strip brackets, punctuation, diacritics. Keeps Unicode letters
# (including Cyrillic) and digits. Used before Levenshtein so matches are robust
# to "[AMATORY]" vs "Amatory", "1 %" vs "1%", "Song (Remastered 2011)" vs "Song".
# ----------------------------------------------------------------------------
function Normalize-ForMatch {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $s = $Value.ToLowerInvariant()
    # Drop leading "The " for tolerance ("Beatles" ~ "The Beatles")
    $s = $s -replace '^\s*the\s+', ''
    # Strip a TRAILING parenthetical/bracketed suffix (Remastered 2011, Live,
    # feat. X, Bonus Track, etc.) - but only if there is real content before
    # it. Guarded so that whole-string brackets like "[AMATORY]" are NOT
    # wiped away - those are band names that must be preserved.
    $s = $s -replace '^(.+?)\s*[\(\[\{][^\)\]\}]{1,60}[\)\]\}]\s*$', '$1'
    # Strip any remaining bracket characters but keep their contents
    # ("[AMATORY]" -> " AMATORY " -> "amatory" after collapse).
    $s = $s -replace '[\[\]\(\)\{\}]', ' '
    # Replace any non-letter / non-digit with space. \p{L} matches Unicode
    # letters including Cyrillic; \p{N} matches digits.
    $s = $s -replace '[^\p{L}\p{N}]+', ' '
    $s = ($s -replace '\s+', ' ').Trim()
    return $s
}

# ----------------------------------------------------------------------------
# Transliteration map Cyrillic -> Latin (GOST-ish). Built dynamically from Unicode
# codepoints so the SCRIPT source stays pure ASCII - this avoids the PS 5.1
# "UTF-8 without BOM => cp1251 parse => broken string literal" footgun (see
# feedback_ps51_utf8_console.md / feedback_powershell_ascii_only.md).
# ----------------------------------------------------------------------------
$script:__TranslitMap = $null
function Get-TranslitMap {
    if ($null -ne $script:__TranslitMap) { return $script:__TranslitMap }
    # a b v g d e e zh z i y k l m n o p r s t u f kh ts ch sh shch '' y '' e yu ya
    $latin = @('a','b','v','g','d','e','e','zh','z','i','y','k','l','m','n','o','p','r','s','t','u','f','kh','ts','ch','sh','shch','','y','','e','yu','ya')
    # U+0430..U+044F = a..ya lowercase Cyrillic block, with U+0451 = yo inserted after ye
    $cyrPoints = @(0x0430,0x0431,0x0432,0x0433,0x0434,0x0435,0x0451,0x0436,0x0437,0x0438,0x0439,0x043A,0x043B,0x043C,0x043D,0x043E,0x043F,0x0440,0x0441,0x0442,0x0443,0x0444,0x0445,0x0446,0x0447,0x0448,0x0449,0x044A,0x044B,0x044C,0x044D,0x044E,0x044F)
    $m = @{}
    for ($i = 0; $i -lt $cyrPoints.Length; $i++) {
        $m[[char]$cyrPoints[$i]] = $latin[$i]
    }
    $script:__TranslitMap = $m
    return $m
}

function ConvertTo-Translit {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $lower = $Value.ToLowerInvariant()
    $map = Get-TranslitMap
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $lower.ToCharArray()) {
        if ($map.ContainsKey($c)) { [void]$sb.Append($map[$c]) }
        else { [void]$sb.Append($c) }
    }
    return $sb.ToString()
}

# ----------------------------------------------------------------------------
# Fuzzy equality: direct Levenshtein first, then transliterated comparison so
# a Latin needle (e.g. "Zemfira") matches a Cyrillic candidate returned by Yandex
# local FLAC tag is Latin but Yandex indexes the artist in Cyrillic).
# ----------------------------------------------------------------------------
function Test-FuzzyEqual {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$A,
        [AllowEmptyString()][string]$B
    )
    if ($A -eq $B) { return $true }
    $max = if ($script:YandexMatchLevenshteinMax) { $script:YandexMatchLevenshteinMax } else { 4 }
    if ((Get-LevenshteinDistance $A $B) -le $max) { return $true }
    $ta = ConvertTo-Translit $A
    $tb = ConvertTo-Translit $B
    if ($ta -eq $tb) { return $true }
    if ((Get-LevenshteinDistance $ta $tb) -le $max) { return $true }
    return $false
}

# Backwards-compat aliases (old names used by tests).
function Normalize-TrackTitle  { param([string]$Title)  return (Normalize-ForMatch $Title) }
function Normalize-ArtistName  { param([string]$Artist) return (Normalize-ForMatch $Artist) }

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

    $nArtist = Normalize-ForMatch $Needle.Artist
    $cArtist = Normalize-ForMatch ($Candidate.artists[0].name)
    if (-not (Test-FuzzyEqual $nArtist $cArtist)) { return $false }

    $nTitle = Normalize-ForMatch $Needle.Track
    $cTitle = Normalize-ForMatch $Candidate.title
    if (-not (Test-FuzzyEqual $nTitle $cTitle)) { return $false }

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
    if (-not (Test-Path -LiteralPath $script:YandexTokenPath)) {
        throw "Yandex token not found at $script:YandexTokenPath"
    }
    $raw = Get-Content -LiteralPath $script:YandexTokenPath -Raw -ErrorAction Stop
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
    Add-Content -LiteralPath $script:YandexAuthFailedFlag -Value $line -Encoding UTF8
}

function Set-YandexSignatureFailedFlag {
    [CmdletBinding()]
    param([string]$Reason)
    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Reason"
    Add-Content -LiteralPath $script:YandexSignatureFailedFlag -Value $line -Encoding UTF8
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
    # NOTE: local variable name deliberately avoids $matches (an automatic PS
    # variable populated by -match/-like operators, which can clash here).
    $hits = @($r.result.tracks.results | Where-Object {
        Test-YandexTrackMatches -Needle $needle -Candidate $_
    })
    if ($hits.Count -eq 0) { return $null }

    if ($Duration -gt 0) {
        $best = $hits | Sort-Object { [Math]::Abs([int]($_.durationMs / 1000) - $Duration) } | Select-Object -First 1
    } else {
        $best = $hits[0]
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
    if (Test-Path -LiteralPath $script:YandexAuthFailedFlag) {
        $age = (Get-Date) - (Get-Item -LiteralPath $script:YandexAuthFailedFlag).LastWriteTime
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
