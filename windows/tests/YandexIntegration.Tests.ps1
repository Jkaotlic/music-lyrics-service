$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\..\config.ps1"
. "$here\..\providers\yandex.ps1"

Describe 'Invoke-LyricsProvider-Yandex integration' -Tag 'Integration' {
    BeforeEach {
        # Clear auth circuit-breaker between tests so mocked-401 test does not bleed through
        if (Test-Path $script:YandexAuthFailedFlag) { Remove-Item $script:YandexAuthFailedFlag -Force }
        if (Test-Path $script:YandexSignatureFailedFlag) { Remove-Item $script:YandexSignatureFailedFlag -Force }
    }

    AfterEach {
        # CRITICAL: tests write to real runtime flag paths; running service also reads them.
        # Without this cleanup the circuit-breaker test leaks and silently disables Yandex
        # for the production service until the flag naturally ages past 1h.
        if (Test-Path $script:YandexAuthFailedFlag) { Remove-Item $script:YandexAuthFailedFlag -Force }
        if (Test-Path $script:YandexSignatureFailedFlag) { Remove-Item $script:YandexSignatureFailedFlag -Force }
    }

    It 'finds synced lyrics for Zemfira - Iskala' {
        $r = Invoke-LyricsProvider-Yandex -Artist 'Земфира' -Track 'Искала' -Album 'Вендетта' -Duration 214
        $r | Should Not BeNullOrEmpty
        $r.IsSynced | Should Be $true
        $r.Source | Should Be 'Yandex'
        $r.Text | Should Match '^\[\d+:\d+'
    }

    It 'returns null for clearly fake artist/track' {
        $r = Invoke-LyricsProvider-Yandex -Artist 'zzxxqqww-nonexistent-7777' -Track 'qqwweeee-fake-888888' -Duration 180
        $r | Should BeNullOrEmpty
    }

    It 'handles missing duration' {
        $r = Invoke-LyricsProvider-Yandex -Artist 'Земфира' -Track 'Искала' -Album '' -Duration -1
        # Either null (matcher rejects) or valid synced -- any non-throw is OK
        if ($r) {
            $r.IsSynced | Should Be $true
            $r.Source | Should Be 'Yandex'
        }
    }

    It 'respects yandex.auth.failed circuit-breaker' {
        # Fresh-touch the flag file and ensure the provider skips without calling network
        Set-Content -Path $script:YandexAuthFailedFlag -Value 'test-flag-for-circuit-breaker' -Encoding UTF8
        (Get-Item $script:YandexAuthFailedFlag).LastWriteTime = Get-Date
        $r = Invoke-LyricsProvider-Yandex -Artist 'Земфира' -Track 'Искала' -Duration 214
        $r | Should BeNullOrEmpty
    }
}
