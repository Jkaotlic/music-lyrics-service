# LRCLib provider - extracted from lrclib-service.ps1 Get-SyncedLyrics (Task 7 refactor).

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
            $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15 -ErrorAction Stop
            Start-Sleep -Milliseconds $rateMs
            if ($r.syncedLyrics) {
                return @{ Text = $r.syncedLyrics; IsSynced = $true; Source = 'LRCLib'; StatusReason = 'get-strict' }
            }
        } catch {}
    }

    # Level 2: /api/get without duration (loose)
    $uri = "$baseUrl/get?artist_name=$(& $esc $Artist)&track_name=$(& $esc $Track)&album_name=$(& $esc $Album)"
    try {
        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15 -ErrorAction Stop
        Start-Sleep -Milliseconds $rateMs
        if ($r.syncedLyrics) {
            return @{ Text = $r.syncedLyrics; IsSynced = $true; Source = 'LRCLib'; StatusReason = 'get-loose' }
        }
    } catch {}

    # Level 3: /api/search fuzzy
    $uri = "$baseUrl/search?artist_name=$(& $esc $Artist)&track_name=$(& $esc $Track)"
    try {
        $results = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15 -ErrorAction Stop
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
