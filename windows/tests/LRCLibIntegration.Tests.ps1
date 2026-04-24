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

    It 'decodes Cyrillic lyrics as UTF-8 (no Latin-1 double-encoding)' {
        # Regression test for the PS 5.1 Invoke-RestMethod bug where response
        # bodies without charset get decoded as ISO-8859-1. LRCLib sends
        # "application/json" with no charset, so Russian tracks were returning
        # double-encoded mojibake (codepoints U+0080..U+00FF instead of proper
        # Cyrillic U+0400..U+04FF). The fix in Invoke-LrclibJson forces a
        # raw-byte UTF-8 decode.
        $zemfira = ''
        foreach ($cp in @(0x0417,0x0435,0x043C,0x0444,0x0438,0x0440,0x0430)) { $zemfira += [char]$cp }
        $iskala = ''
        foreach ($cp in @(0x0418,0x0441,0x043A,0x0430,0x043B,0x0430)) { $iskala += [char]$cp }
        $r = Invoke-LyricsProvider-LRCLib -Artist $zemfira -Track $iskala -Duration -1
        if ($r) {
            # If LRCLib returned a hit, ensure there are NO Latin-1-range codepoints
            $latin1Count = 0
            foreach ($c in $r.Text.ToCharArray()) {
                $cp = [int]$c
                if ($cp -ge 0x0080 -and $cp -le 0x00FF) { $latin1Count++ }
            }
            $latin1Count | Should Be 0
            # And that there ARE proper Cyrillic codepoints
            $cyrillicCount = 0
            foreach ($c in $r.Text.ToCharArray()) {
                $cp = [int]$c
                if ($cp -ge 0x0400 -and $cp -le 0x04FF) { $cyrillicCount++ }
            }
            $cyrillicCount | Should BeGreaterThan 0
        }
        # If LRCLib legitimately has no hit, the test passes (no regression to detect)
    }
}
