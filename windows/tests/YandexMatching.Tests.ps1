# tests\YandexMatching.Tests.ps1 - Pester 3.4 syntax
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\..\providers\yandex.ps1"

# Scope vars tests depend on (same defaults as config.ps1)
$script:YandexMatchDurationTolerance = 3
$script:YandexMatchLevenshteinMax = 3

# Build Cyrillic strings dynamically to keep this source pure ASCII (PS 5.1
# on RU locale mis-parses UTF-8-without-BOM cyrillic literals).
function script:_Cyr { param([int[]]$Points) $s=''; foreach($p in $Points){$s+=[char]$p}; return $s }

Describe 'Test-YandexTrackMatches' {
    It 'matches when artist, title and duration close' {
        $needle = @{ Artist = 'Земфира'; Track = 'Искала'; Duration = 241 }
        $candidate = @{
            artists = @(@{ name = 'Земфира' })
            title = 'Искала'
            durationMs = 240000
        }
        Test-YandexTrackMatches -Needle $needle -Candidate $candidate | Should Be $true
    }

    It 'rejects when duration differs by more than tolerance' {
        $needle = @{ Artist = 'Земфира'; Track = 'Искала'; Duration = 241 }
        $candidate = @{
            artists = @(@{ name = 'Земфира' })
            title = 'Искала'
            durationMs = 260000
        }
        Test-YandexTrackMatches -Needle $needle -Candidate $candidate | Should Be $false
    }

    It 'rejects when artist Levenshtein exceeds threshold' {
        $needle = @{ Artist = 'Beatles'; Track = 'Help'; Duration = 140 }
        $candidate = @{
            artists = @(@{ name = 'Completely Different Artist' })
            title = 'Help'
            durationMs = 140000
        }
        Test-YandexTrackMatches -Needle $needle -Candidate $candidate | Should Be $false
    }

    It 'tolerates "The" prefix in artist name' {
        $needle = @{ Artist = 'Beatles'; Track = 'Help'; Duration = 140 }
        $candidate = @{
            artists = @(@{ name = 'The Beatles' })
            title = 'Help'
            durationMs = 140000
        }
        Test-YandexTrackMatches -Needle $needle -Candidate $candidate | Should Be $true
    }

    It 'tolerates "(Remastered)" suffix in title' {
        $needle = @{ Artist = 'Queen'; Track = 'Bohemian Rhapsody'; Duration = 354 }
        $candidate = @{
            artists = @(@{ name = 'Queen' })
            title = 'Bohemian Rhapsody (Remastered 2011)'
            durationMs = 354000
        }
        Test-YandexTrackMatches -Needle $needle -Candidate $candidate | Should Be $true
    }

    It 'returns false for null candidate' {
        $needle = @{ Artist = 'Queen'; Track = 'Help'; Duration = 140 }
        Test-YandexTrackMatches -Needle $needle -Candidate $null | Should Be $false
    }

    It 'tolerates missing duration (Duration=-1)' {
        $needle = @{ Artist = 'Queen'; Track = 'Help'; Duration = -1 }
        $candidate = @{
            artists = @(@{ name = 'Queen' })
            title = 'Help'
            durationMs = 140000
        }
        Test-YandexTrackMatches -Needle $needle -Candidate $candidate | Should Be $true
    }
}

Describe 'Test-YandexTrackMatches - cross-alphabet regression' {
    BeforeEach {
        $script:YandexMatchDurationTolerance = 30
        $script:YandexMatchLevenshteinMax = 4
    }
    AfterEach {
        $script:YandexMatchDurationTolerance = 3
        $script:YandexMatchLevenshteinMax = 3
    }

    It 'matches Latin needle against Cyrillic candidate via transliteration' {
        # Zemfira -> Zemfira; candidate artist = cyrillic "Земфира"
        $zemfira = script:_Cyr @(0x0417,0x0435,0x043C,0x0444,0x0438,0x0440,0x0430)
        $iskala  = script:_Cyr @(0x0418,0x0421,0x041A,0x0410,0x041B,0x0410)
        $needle = @{ Artist = 'Zemfira'; Track = 'Iskala'; Duration = 214 }
        $candidate = @{
            artists = @(@{ name = $zemfira })
            title = $iskala
            durationMs = 214000
        }
        Test-YandexTrackMatches -Needle $needle -Candidate $candidate | Should Be $true
    }

    It 'matches [AMATORY] (whole-string brackets) against plain Amatory' {
        $needle = @{ Artist = 'Amatory'; Track = '1%'; Duration = 216 }
        $candidate = @{
            artists = @(@{ name = '[AMATORY]' })
            title = '1 %'
            durationMs = 216000
        }
        Test-YandexTrackMatches -Needle $needle -Candidate $candidate | Should Be $true
    }

    It 'matches Latin title against Cyrillic candidate title' {
        # Latin "Vydyhai" vs Cyrillic "Выдыхай"
        $cyrTitle = script:_Cyr @(0x0412,0x044B,0x0434,0x044B,0x0445,0x0430,0x0439)
        $needle = @{ Artist = 'Noize MC'; Track = 'Vydyhai'; Duration = 193 }
        $candidate = @{
            artists = @(@{ name = 'Noize MC' })
            title = $cyrTitle
            durationMs = 193000
        }
        Test-YandexTrackMatches -Needle $needle -Candidate $candidate | Should Be $true
    }
}

Describe 'Get-LevenshteinDistance' {
    It 'returns 0 for identical strings' {
        Get-LevenshteinDistance 'hello' 'hello' | Should Be 0
    }
    It 'returns 1 for one-char difference' {
        Get-LevenshteinDistance 'hello' 'hallo' | Should Be 1
    }
    It 'handles empty first string' {
        Get-LevenshteinDistance '' 'abc' | Should Be 3
    }
    It 'handles empty second string' {
        Get-LevenshteinDistance 'abc' '' | Should Be 3
    }
    It 'handles both empty' {
        Get-LevenshteinDistance '' '' | Should Be 0
    }
    It 'is case-sensitive (caller normalizes)' {
        Get-LevenshteinDistance 'Hello' 'hello' | Should Be 1
    }
}
