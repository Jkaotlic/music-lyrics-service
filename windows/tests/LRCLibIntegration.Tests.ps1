$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\..\providers\lrclib.ps1"

$script:LRCLibRateLimitMs = 200
$script:LRCLibBaseUrl = 'https://lrclib.net/api'

Describe 'Invoke-LyricsProvider-LRCLib integration' -Tag 'Integration' {
    It 'finds synced lyrics for The Beatles - Drive My Car' {
        $r = Invoke-LyricsProvider-LRCLib -Artist 'The Beatles' -Track 'Drive My Car' -Album 'Rubber Soul' -Duration 147
        $r | Should Not BeNullOrEmpty
        $r.IsSynced | Should Be $true
        $r.Source | Should Be 'LRCLib'
        $r.Text | Should Match '^\[\d+:\d+'
    }

    It 'finds synced lyrics for Queen - Bohemian Rhapsody' {
        $r = Invoke-LyricsProvider-LRCLib -Artist 'Queen' -Track 'Bohemian Rhapsody' -Album 'A Night at the Opera' -Duration 354
        $r | Should Not BeNullOrEmpty
        $r.IsSynced | Should Be $true
        $r.Source | Should Be 'LRCLib'
    }

    It 'returns null for clearly fake track' {
        $r = Invoke-LyricsProvider-LRCLib -Artist 'xxzzyy-noexist-artist-12345' -Track 'qqpprr-fake-title-67890' -Album 'Nothing' -Duration 180
        $r | Should BeNullOrEmpty
    }

    It 'does not throw or return get-strict when duration is wrong' {
        # Wrong duration forces fallback path. API may return synced via loose/search,
        # or nothing at all (both are legitimate). The only contract: no exception,
        # and if something is returned it must not be from the strict path.
        $r = $null
        { $r = Invoke-LyricsProvider-LRCLib -Artist 'Queen' -Track 'Bohemian Rhapsody' -Album 'A Night at the Opera' -Duration 999 } | Should Not Throw
        if ($r) { $r.StatusReason | Should Not Be 'get-strict' }
    }

    It 'handles duration=-1 (no duration in tags)' {
        $r = Invoke-LyricsProvider-LRCLib -Artist 'The Beatles' -Track 'Drive My Car' -Album 'Rubber Soul' -Duration -1
        $r | Should Not BeNullOrEmpty
        $r.IsSynced | Should Be $true
    }
}
