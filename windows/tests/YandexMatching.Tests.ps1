# tests\YandexMatching.Tests.ps1 — Pester 3.4 syntax
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\..\providers\yandex.ps1"

# Scope vars tests depend on (same defaults as config.ps1)
$script:YandexMatchDurationTolerance = 3
$script:YandexMatchLevenshteinMax = 3

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
