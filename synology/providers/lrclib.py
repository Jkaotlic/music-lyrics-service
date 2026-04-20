"""LRCLib provider — port of windows/providers/lrclib.ps1 (Task 7)."""
from __future__ import annotations
import time
from typing import Optional, Dict, Any
from urllib.parse import quote

import requests


def get_lyrics(
    artist: str,
    track: str,
    album: str = "",
    duration: int = -1,
    *,
    base_url: str = "https://lrclib.net/api",
    rate_limit_ms: int = 200,
) -> Optional[Dict[str, Any]]:
    """Return {'text','is_synced','source','status_reason'} or None on miss."""

    def _sleep():
        time.sleep(rate_limit_ms / 1000.0)

    def _get(url: str) -> Optional[dict]:
        try:
            r = requests.get(url, timeout=15)
            _sleep()
            if r.status_code == 200:
                return r.json()
        except requests.RequestException:
            pass
        return None

    # Level 1: /api/get with duration
    if duration > 0:
        url = (
            f"{base_url}/get?artist_name={quote(artist)}"
            f"&track_name={quote(track)}&album_name={quote(album)}&duration={duration}"
        )
        r = _get(url)
        if r and r.get("syncedLyrics"):
            return {
                "text": r["syncedLyrics"],
                "is_synced": True,
                "source": "LRCLib",
                "status_reason": "get-strict",
            }

    # Level 2: /api/get without duration
    url = (
        f"{base_url}/get?artist_name={quote(artist)}"
        f"&track_name={quote(track)}&album_name={quote(album)}"
    )
    r = _get(url)
    if r and r.get("syncedLyrics"):
        return {
            "text": r["syncedLyrics"],
            "is_synced": True,
            "source": "LRCLib",
            "status_reason": "get-loose",
        }

    # Level 3: /api/search fuzzy
    url = f"{base_url}/search?artist_name={quote(artist)}&track_name={quote(track)}"
    results = _get(url)
    if isinstance(results, list) and results:
        synced = [x for x in results if x.get("syncedLyrics")]
        if synced:
            if duration > 0:
                synced.sort(key=lambda x: abs(int(x.get("duration", 0)) - duration))
            best = synced[0]
            return {
                "text": best["syncedLyrics"],
                "is_synced": True,
                "source": "LRCLib",
                "status_reason": "search-fuzzy",
            }
    return None
