# C:\Tools\lrclib-service\config.ps1
#
# lrclib-service configuration. Dot-sourced from lrclib-service.ps1 at startup.
# If this file is missing, service falls back to legacy mode (LRCLib only).

# Provider order. First with IsSynced=true wins (early-stop).
# If nothing returns synced, best plain is kept.
$script:LyricsProviders = @('LRCLib', 'Yandex')

# --- Yandex.Music ---
$script:YandexTokenPath = 'C:\Tools\lrclib-service\yandex.token'
$script:YandexRateLimitMs = 200
# Duration tolerance in seconds. Russian/original masters and Yandex remasters
# often differ by 15-30s due to silence/fade edits; bumped from 15 to 30.
$script:YandexMatchDurationTolerance = 30
# Levenshtein threshold for fuzzy artist/title match. After transliteration
# fallback is added, 4 is safe (still rejects clearly different tracks).
$script:YandexMatchLevenshteinMax = 4
$script:YandexUserAgent = 'Yandex-Music-Windows/5.00'
# VERIFIED 2026-04-20 (Task 3, hmac-notes.md commit 30a4a07):
$script:YandexHmacSecret = 'p93jhgh689SBReK6ghtw62'
# REQUIRED Android client header - without it API returns 403 even with valid signature
$script:YandexClientHeader = 'YandexMusicAndroid/24023621'
# CRITICAL: timeStamp in signature is Unix SECONDS (not milliseconds!)

# --- LRCLib ---
$script:LRCLibRateLimitMs = 200
$script:LRCLibBaseUrl = 'https://lrclib.net/api'

# --- Common ---
$script:LibraryRoot = 'G:\Music\Library'
$script:ScanIntervalSec = 300
$script:LogPath = 'C:\Tools\lrclib-service\lrclib.log'

# --- Error-handling flag files ---
$script:YandexAuthFailedFlag = 'C:\Tools\lrclib-service\yandex.auth.failed'
$script:YandexSignatureFailedFlag = 'C:\Tools\lrclib-service\yandex.signature.failed'
