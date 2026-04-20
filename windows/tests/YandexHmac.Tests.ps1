# tests\YandexHmac.Tests.ps1 - Pester 3.4 syntax
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\..\providers\yandex.ps1"

$script:TestSecret = 'test-secret-key-12345'

Describe 'New-YandexHmacSignature' {
    It 'produces deterministic base64 output for same inputs' {
        $s1 = New-YandexHmacSignature -TrackId '64797' -TimeStamp 1745138400 -Secret $script:TestSecret
        $s2 = New-YandexHmacSignature -TrackId '64797' -TimeStamp 1745138400 -Secret $script:TestSecret
        $s1 | Should Be $s2
    }

    It 'produces valid base64 string' {
        $s = New-YandexHmacSignature -TrackId '64797' -TimeStamp 1745138400 -Secret $script:TestSecret
        { [Convert]::FromBase64String($s) } | Should Not Throw
    }

    It 'produces HMAC-SHA256-sized output (32 bytes = 44 base64 chars)' {
        $s = New-YandexHmacSignature -TrackId '64797' -TimeStamp 1745138400 -Secret $script:TestSecret
        $s.Length | Should Be 44
        ([Convert]::FromBase64String($s)).Length | Should Be 32
    }

    It 'signature changes when trackId changes' {
        $s1 = New-YandexHmacSignature -TrackId '64797' -TimeStamp 1745138400 -Secret $script:TestSecret
        $s2 = New-YandexHmacSignature -TrackId '64798' -TimeStamp 1745138400 -Secret $script:TestSecret
        $s1 | Should Not Be $s2
    }

    It 'signature changes when timestamp changes' {
        $s1 = New-YandexHmacSignature -TrackId '64797' -TimeStamp 1745138400 -Secret $script:TestSecret
        $s2 = New-YandexHmacSignature -TrackId '64797' -TimeStamp 1745138401 -Secret $script:TestSecret
        $s1 | Should Not Be $s2
    }

    It 'matches known-good reference vector' {
        $expected = 'GqGHjEosjMgWwTqxMiPeyu2ps8XghzpZ0cmz7EIyFuk='
        $actual = New-YandexHmacSignature -TrackId '64797' -TimeStamp 1745138400 -Secret $script:TestSecret
        $actual | Should Be $expected
    }

    It 'differs for the verified Yandex secret' {
        $withTest = New-YandexHmacSignature -TrackId '64797' -TimeStamp 1745138400 -Secret $script:TestSecret
        $withReal = New-YandexHmacSignature -TrackId '64797' -TimeStamp 1745138400 -Secret 'p93jhgh689SBReK6ghtw62'
        $withTest | Should Not Be $withReal
    }
}
