# LRCLib provider - 3-level lookup: strict get -> loose get -> fuzzy search.

function Invoke-LrclibJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$TimeoutSec = 15
    )
    # CRITICAL: in PS 5.1, Invoke-RestMethod decodes the response body using
    # ISO-8859-1 / Latin-1 whenever Content-Type does not include an explicit
    # charset. LRCLib sends "Content-Type: application/json" with no charset,
    # so Cyrillic (and any non-Latin text) gets decoded 1:1 as Latin-1 chars
    # (U+0080..U+00FF). When those chars are then re-serialized as UTF-8 (to
    # write the .lrc file or embed into a tag), each byte becomes two bytes
    # of UTF-8 mojibake. This function forces a UTF-8 read of the raw byte
    # stream before JSON parsing so Cyrillic round-trips intact.
    $resp = Invoke-WebRequest -Uri $Uri -UseBasicParsing -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
    $bytes = if ($resp.RawContentStream -and $resp.RawContentStream.Length -gt 0) {
        $null = $resp.RawContentStream.Seek(0, [System.IO.SeekOrigin]::Begin)
        $resp.RawContentStream.ToArray()
    } elseif ($resp.Content -is [byte[]]) {
        $resp.Content
    } else {
        # Fall back: PS already decoded Content into a (mangled) string using
        # the default codepage. Undo that by re-encoding as ISO-8859-1 to
        # recover the original wire bytes, then decode those as UTF-8.
        [System.Text.Encoding]::GetEncoding('iso-8859-1').GetBytes([string]$resp.Content)
    }
    return ([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
}

function Invoke-LyricsProvider-LRCLib {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Artist,
        [Parameter(Mandatory)][string]$Track,
        [string]$Album = '',
        [int]$Duration = -1
    )

    $baseUrl = if ($script:LRCLibBaseUrl) { $script:LRCLibBaseUrl } else { 'https://lrclib.net/api' }
    $rateMs  = if ($script:LRCLibRateLimitMs) { $script:LRCLibRateLimitMs } else { 200 }

    $esc = { param($s) [uri]::EscapeDataString("$s") }

    # Level 1: /api/get with duration (strict)
    if ($Duration -gt 0) {
        $uri = "$baseUrl/get?artist_name=$(& $esc $Artist)&track_name=$(& $esc $Track)&album_name=$(& $esc $Album)&duration=$Duration"
        try {
            $r = Invoke-LrclibJson -Uri $uri -TimeoutSec 15
            Start-Sleep -Milliseconds $rateMs
            if ($r.syncedLyrics) {
                return @{ Text = $r.syncedLyrics; IsSynced = $true; Source = 'LRCLib'; StatusReason = 'get-strict' }
            }
        } catch {}
    }

    # Level 2: /api/get without duration (loose)
    $uri = "$baseUrl/get?artist_name=$(& $esc $Artist)&track_name=$(& $esc $Track)&album_name=$(& $esc $Album)"
    try {
        $r = Invoke-LrclibJson -Uri $uri -TimeoutSec 15
        Start-Sleep -Milliseconds $rateMs
        if ($r.syncedLyrics) {
            return @{ Text = $r.syncedLyrics; IsSynced = $true; Source = 'LRCLib'; StatusReason = 'get-loose' }
        }
    } catch {}

    # Level 3: /api/search fuzzy
    $uri = "$baseUrl/search?artist_name=$(& $esc $Artist)&track_name=$(& $esc $Track)"
    try {
        $results = Invoke-LrclibJson -Uri $uri -TimeoutSec 15
        Start-Sleep -Milliseconds $rateMs
        $arr = @($results)
        if ($arr.Count -eq 0) { return $null }
        $synced = @($arr | Where-Object { $_.syncedLyrics })
        if ($synced.Count -gt 0) {
            $best = $synced | Sort-Object {
                if ($Duration -gt 0) { [math]::Abs([double]$_.duration - $Duration) } else { 0 }
            } | Select-Object -First 1
            return @{ Text = $best.syncedLyrics; IsSynced = $true; Source = 'LRCLib'; StatusReason = 'search-fuzzy' }
        }
    } catch {}

    return $null
}
