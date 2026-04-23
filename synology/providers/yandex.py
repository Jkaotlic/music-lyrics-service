"""Yandex Music provider — port of windows/providers/yandex.ps1."""
from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import os
import re
import time
from datetime import datetime, timezone
from typing import Any, Dict, Optional

import requests

logger = logging.getLogger("pipeline.yandex")

_YANDEX_API_BASE = "https://api.music.yandex.net"


# ---------------------------------------------------------------------------
# String utilities (port of PS normalize / levenshtein helpers)
# ---------------------------------------------------------------------------

def _levenshtein(a: str, b: str) -> int:
    """Iterative DP Levenshtein distance."""
    if a == b:
        return 0
    la, lb = len(a), len(b)
    if la == 0:
        return lb
    if lb == 0:
        return la
    prev = list(range(lb + 1))
    for i in range(1, la + 1):
        curr = [i] + [0] * lb
        for j in range(1, lb + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            curr[j] = min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
        prev = curr
    return prev[lb]


def _normalize_for_match(s: str) -> str:
    """
    Aggressive fuzzy-match normalization. Mirrors windows/providers/yandex.ps1
    Normalize-ForMatch so Python and PowerShell produce identical keys.

    Stays robust to:
      - Whole-string brackets: "[AMATORY]" -> "amatory" (Yandex band names)
      - Trailing parenthetical: "Song (Remastered 2011)" -> "song"
      - Leading "The ": "The Beatles" -> "beatles"
      - Spaced punctuation: "1 %" -> "1"
    """
    if not s:
        return ""
    s = s.lower()
    # Drop leading "the "
    s = re.sub(r"^\s*the\s+", "", s)
    # Strip a trailing parenthetical/bracketed suffix, but only if real content
    # precedes it — so "[AMATORY]" (whole-string bracket) is preserved, while
    # "Bohemian Rhapsody (Remastered 2011)" -> "Bohemian Rhapsody".
    s = re.sub(r"^(.+?)\s*[\(\[\{][^\)\]\}]{1,60}[\)\]\}]\s*$", r"\1", s)
    # Strip remaining bracket characters (keeps contents).
    s = re.sub(r"[\[\]\(\)\{\}]", " ", s)
    # Python 3 \w is Unicode-aware, so Cyrillic letters survive here.
    s = re.sub(r"[^\w]+", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s


# ---------------------------------------------------------------------------
# Cyrillic -> Latin transliteration. Enables fuzzy matching a Latin-tagged
# file ("Zemfira") against a Cyrillic Yandex artist ("Земфира"). The map is
# built from Unicode codepoints to keep the source ASCII-safe.
# ---------------------------------------------------------------------------

_CYR_MAP: Optional[Dict[str, str]] = None


def _get_cyr_map() -> Dict[str, str]:
    global _CYR_MAP
    if _CYR_MAP is not None:
        return _CYR_MAP
    latin = [
        "a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "y",
        "k", "l", "m", "n", "o", "p", "r", "s", "t", "u", "f",
        "kh", "ts", "ch", "sh", "shch", "", "y", "", "e", "yu", "ya",
    ]
    # a..ya with yo inserted after ye (Cyrillic small letters block)
    points = [
        0x0430, 0x0431, 0x0432, 0x0433, 0x0434, 0x0435, 0x0451,
        0x0436, 0x0437, 0x0438, 0x0439, 0x043A, 0x043B, 0x043C,
        0x043D, 0x043E, 0x043F, 0x0440, 0x0441, 0x0442, 0x0443,
        0x0444, 0x0445, 0x0446, 0x0447, 0x0448, 0x0449, 0x044A,
        0x044B, 0x044C, 0x044D, 0x044E, 0x044F,
    ]
    _CYR_MAP = {chr(p): latin[i] for i, p in enumerate(points)}
    return _CYR_MAP


def _translit(s: str) -> str:
    if not s:
        return ""
    m = _get_cyr_map()
    return "".join(m.get(c, c) for c in s.lower())


def _fuzzy_equal(a: str, b: str, lev_max: int) -> bool:
    """Equal after direct Levenshtein, or after cross-alphabet transliteration."""
    if a == b:
        return True
    if _levenshtein(a, b) <= lev_max:
        return True
    ta, tb = _translit(a), _translit(b)
    if ta == tb:
        return True
    if _levenshtein(ta, tb) <= lev_max:
        return True
    return False


# Backwards-compatible aliases (older tests import these).
def _normalize_title(s: str) -> str:
    return _normalize_for_match(s)


def _normalize_artist(s: str) -> str:
    # Still take only primary artist (before comma/&) before full normalization
    s = re.sub(r"[,&].*", "", s)
    return _normalize_for_match(s)


def _track_matches(
    needle_artist: str,
    needle_title: str,
    needle_duration: int,
    candidate: Dict[str, Any],
    duration_tol: int = 30,
    lev_max: int = 4,
) -> bool:
    """Return True if candidate dict matches the needle within tolerances."""
    if needle_duration > 0:
        cand_dur = int(candidate.get("durationMs", 0)) // 1000
        if abs(cand_dur - needle_duration) > duration_tol:
            return False

    cand_artists = candidate.get("artists", [])
    if cand_artists:
        cand_artist_str = cand_artists[0].get("name", "")
    else:
        cand_artist_str = candidate.get("artist", "")
    if not _fuzzy_equal(_normalize_artist(needle_artist), _normalize_artist(cand_artist_str), lev_max):
        return False

    cand_title = candidate.get("title", "")
    if not _fuzzy_equal(_normalize_title(needle_title), _normalize_title(cand_title), lev_max):
        return False

    return True


# ---------------------------------------------------------------------------
# HMAC signature (port of New-YandexHmacSignature in PS)
# ---------------------------------------------------------------------------

def _hmac_signature(track_id: str, timestamp_sec: int, secret: str) -> str:
    """HMAC-SHA256 of '{trackId}{timestamp}' keyed by secret, base64-encoded."""
    message = f"{track_id}{timestamp_sec}".encode("utf-8")
    key = secret.encode("utf-8")
    sig = hmac.new(key, message, hashlib.sha256).digest()
    return base64.b64encode(sig).decode("ascii")


# ---------------------------------------------------------------------------
# Token / config helpers
# ---------------------------------------------------------------------------

def _get_token(path: str) -> str:
    """Read OAuth token from file (stripped)."""
    with open(path, encoding="utf-8") as f:
        return f.read().strip()


def _api_headers(token: str, user_agent: str, client_header: str) -> Dict[str, str]:
    return {
        "Authorization": f"OAuth {token}",
        "User-Agent": user_agent,
        "X-Yandex-Music-Client": client_header,
        "Accept": "application/json",
    }


# ---------------------------------------------------------------------------
# Circuit-breaker flag helpers
# ---------------------------------------------------------------------------

def _flag_age_seconds(path: str) -> float:
    """Return age in seconds of flag file, or infinity if not present."""
    try:
        mtime = os.path.getmtime(path)
        return time.time() - mtime
    except OSError:
        return float("inf")


def _touch_flag(path: str, reason: str) -> None:
    """Append a timestamped line to a flag file."""
    ts = datetime.now(timezone.utc).isoformat()
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"{ts} {reason}\n")
    except OSError as e:
        logger.warning("Could not write flag %s: %s", path, e)


# ---------------------------------------------------------------------------
# API calls
# ---------------------------------------------------------------------------

def _search_track(
    artist: str,
    track: str,
    duration: int,
    token: str,
    cfg: Dict[str, str],
) -> Optional[Dict[str, Any]]:
    """Search Yandex for track, return best matching track dict or None."""
    user_agent = cfg.get("user_agent", "Yandex-Music-Windows/5.00")
    client_header = cfg.get("client_header", "YandexMusicAndroid/24023621")
    rate_limit_ms = int(cfg.get("rate_limit_ms", 200))
    # Bumped from 3s to 30s: Russian/original masters vs Yandex remasters often
    # differ by 10-30s from silence/fade edits.
    duration_tol = int(cfg.get("match_duration_tolerance", 30))
    # Bumped from 3 to 4: transliteration fallback handles cross-alphabet cases,
    # so a slightly looser Levenshtein is safe.
    lev_max = int(cfg.get("match_levenshtein_max", 4))

    headers = _api_headers(token, user_agent, client_header)
    query = f"{artist} {track}"
    url = f"{_YANDEX_API_BASE}/search"
    params = {"text": query, "type": "track", "page": 0}

    try:
        r = requests.get(url, headers=headers, params=params, timeout=15)
        time.sleep(rate_limit_ms / 1000.0)
        if r.status_code != 200:
            return None
        data = r.json()
    except requests.RequestException as e:
        logger.warning("Yandex search request failed: %s", e)
        return None

    tracks = (
        data.get("result", {})
        .get("tracks", {})
        .get("results", [])
    )
    for candidate in tracks:
        if _track_matches(artist, track, duration, candidate, duration_tol, lev_max):
            return candidate
    return None


def _get_sync_lyrics(
    track_id: str,
    token: str,
    cfg: Dict[str, str],
) -> Optional[str]:
    """
    Fetch synced lyrics for a track_id from Yandex.
    Returns LRC-format text or None.
    timeStamp in the API request is Unix SECONDS.
    """
    user_agent = cfg.get("user_agent", "Yandex-Music-Windows/5.00")
    client_header = cfg.get("client_header", "YandexMusicAndroid/24023621")
    hmac_secret = cfg.get("hmac_secret", "p93jhgh689SBReK6ghtw62")
    rate_limit_ms = int(cfg.get("rate_limit_ms", 200))

    timestamp_sec = int(time.time())
    signature = _hmac_signature(track_id, timestamp_sec, hmac_secret)

    headers = _api_headers(token, user_agent, client_header)
    url = f"{_YANDEX_API_BASE}/tracks/{track_id}/lyrics"
    params = {
        "timeStamp": timestamp_sec,
        "sign": signature,
        "format": "LRC",
    }

    try:
        r = requests.get(url, headers=headers, params=params, timeout=15)
        time.sleep(rate_limit_ms / 1000.0)
    except requests.RequestException as e:
        logger.warning("Yandex lyrics request failed for %s: %s", track_id, e)
        return None

    if r.status_code == 200:
        data = r.json()
        lrc_url = data.get("result", {}).get("downloadUrl")
        if not lrc_url:
            return None
        # Second request: download actual LRC content
        try:
            r2 = requests.get(lrc_url, timeout=15)
            time.sleep(rate_limit_ms / 1000.0)
            if r2.status_code == 200:
                return r2.text
        except requests.RequestException as e:
            logger.warning("Yandex LRC download failed: %s", e)
        return None

    return None


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

def get_lyrics(
    artist: str,
    track: str,
    album: str = "",
    duration: int = -1,
    *,
    cfg: Dict[str, str],
) -> Optional[Dict[str, Any]]:
    """
    Orchestrator with circuit-breaker on auth_failed_flag (< 1h old),
    3 retries with exponential backoff on 429, touch signature_failed_flag on 403.

    Returns {'text','is_synced','source','status_reason'} or None.
    """
    auth_flag = cfg.get("auth_failed_flag", "")
    sig_flag = cfg.get("signature_failed_flag", "")
    token_path = cfg.get("token_path", "")

    # Circuit-breaker: skip if auth failed recently (< 1h)
    if auth_flag and _flag_age_seconds(auth_flag) < 3600:
        logger.debug("Yandex: auth circuit-breaker active, skipping")
        return None

    # Load token
    try:
        token = _get_token(token_path)
    except OSError as e:
        logger.warning("Yandex: cannot read token from %s: %s", token_path, e)
        return None

    # Search with retry on 429
    found_track = None
    for attempt in range(3):
        try:
            found_track = _search_track(artist, track, duration, token, cfg)
            break
        except requests.exceptions.HTTPError as e:
            if hasattr(e, "response") and e.response is not None and e.response.status_code == 429:
                wait = 2 ** attempt
                logger.info("Yandex: 429 rate limit, backing off %ds", wait)
                time.sleep(wait)
            else:
                break

    if found_track is None:
        return None

    track_id = str(found_track.get("id", ""))
    if not track_id:
        return None

    # Fetch lyrics with retry on 429
    user_agent = cfg.get("user_agent", "Yandex-Music-Windows/5.00")
    client_header = cfg.get("client_header", "YandexMusicAndroid/24023621")
    hmac_secret = cfg.get("hmac_secret", "p93jhgh689SBReK6ghtw62")
    rate_limit_ms = int(cfg.get("rate_limit_ms", 200))

    lrc_text = None
    for attempt in range(3):
        timestamp_sec = int(time.time())
        signature = _hmac_signature(track_id, timestamp_sec, hmac_secret)
        headers = _api_headers(token, user_agent, client_header)
        url = f"{_YANDEX_API_BASE}/tracks/{track_id}/lyrics"
        params = {
            "timeStamp": timestamp_sec,
            "sign": signature,
            "format": "LRC",
        }

        try:
            r = requests.get(url, headers=headers, params=params, timeout=15)
            time.sleep(rate_limit_ms / 1000.0)
        except requests.RequestException as e:
            logger.warning("Yandex: lyrics request error on attempt %d: %s", attempt, e)
            break

        if r.status_code == 200:
            data = r.json()
            lrc_url = data.get("result", {}).get("downloadUrl")
            if lrc_url:
                try:
                    r2 = requests.get(lrc_url, timeout=15)
                    time.sleep(rate_limit_ms / 1000.0)
                    if r2.status_code == 200:
                        lrc_text = r2.text
                except requests.RequestException:
                    pass
            break

        elif r.status_code == 401:
            logger.warning("Yandex: 401 Unauthorized — touching auth flag")
            if auth_flag:
                _touch_flag(auth_flag, "401 Unauthorized")
            return None

        elif r.status_code == 403:
            logger.warning("Yandex: 403 Forbidden — touching signature flag")
            if sig_flag:
                _touch_flag(sig_flag, "403 Forbidden")
            return None

        elif r.status_code == 404:
            return None

        elif r.status_code == 429:
            wait = 2 ** attempt
            logger.info("Yandex: 429 on lyrics, backing off %ds", wait)
            time.sleep(wait)

        else:
            logger.warning("Yandex: unexpected status %d for track %s", r.status_code, track_id)
            break

    if not lrc_text:
        return None

    # Check if lyrics are truly synced (contain LRC timestamps)
    is_synced = bool(re.search(r"\[\d+:\d+\.\d+\]", lrc_text))

    return {
        "text": lrc_text,
        "is_synced": is_synced,
        "source": "Yandex",
        "status_reason": "synced" if is_synced else "plain",
    }
