# config.ps1
#
# Configuration for music-lyrics-service. Dot-sourced from lrclib-service.ps1 at startup.
# If this file is missing, service falls back to legacy mode (LRCLib only).

# Provider order. First with IsSynced=true wins (early-stop).
# If nothing returns synced - best plain is kept.
$script:LyricsProviders = @('LRCLib', 'Yandex')

# --- Paths (resolved relative to this config file) ---
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:YandexTokenPath           = Join-Path $scriptRoot 'yandex.token'
$script:LogPath                   = Join-Path $scriptRoot 'lrclib.log'
$script:YandexAuthFailedFlag      = Join-Path $scriptRoot 'yandex.auth.failed'
$script:YandexSignatureFailedFlag = Join-Path $scriptRoot 'yandex.signature.failed'

# --- Library root ---
# CHANGE THIS to your music library path, or pass -LibraryPath to lrclib-service.ps1
$script:LibraryRoot = 'G:\Music\Library'

# --- Yandex.Music ---
$script:YandexRateLimitMs = 200
$script:YandexMatchDurationTolerance = 3  # seconds
$script:YandexMatchLevenshteinMax = 3
$script:YandexUserAgent = 'Yandex-Music-Windows/5.00'
# VERIFIED 2026-04-20: public HMAC secret documented at MarshalX/yandex-music-api
$script:YandexHmacSecret = 'p93jhgh689SBReK6ghtw62'
# REQUIRED Android client header - without it API returns 403 even with valid signature
$script:YandexClientHeader = 'YandexMusicAndroid/24023621'
# CRITICAL: timeStamp in signature is Unix SECONDS (not milliseconds!)

# --- LRCLib ---
$script:LRCLibRateLimitMs = 200
$script:LRCLibBaseUrl = 'https://lrclib.net/api'

# --- Common ---
$script:ScanIntervalSec = 300
