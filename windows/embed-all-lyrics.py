#!/usr/bin/env python3
"""
embed-all-lyrics: unified FLAC/MP3/M4A lyrics-embedder.

For every audio file in --library that has an adjacent .lrc sidecar,
write that .lrc content (as LRC-format with [mm:ss.xx] timestamps) into
the file's native lyrics tag so Navidrome WebUI renders them synced
("karaoke") instead of static:

  - FLAC  -> LYRICS vorbis comment
  - MP3   -> USLT ID3v2 frame
  - M4A   -> \\xa9lyr atom

Skips when existing tag already equals .lrc content (idempotent).

Replaces the FLAC-only PowerShell embed-lyrics.ps1 v7 with a single
cross-format implementation backed by mutagen (also used by the Synology
port and decluttarr, so the Homeserver+xpenology+dev codebase converges).
"""
from __future__ import annotations
import argparse
import logging
import sys
from pathlib import Path

# Force UTF-8 for stdout/stderr so Cyrillic filenames/tags don't blow up the
# logger on RU-locale Windows (Python inherits cp1251 by default here, same
# family of bug as [Console]::OutputEncoding on PS 5.1).
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

from mutagen.flac import FLAC
from mutagen.id3 import ID3, ID3NoHeaderError, USLT
from mutagen.mp4 import MP4


def embed_flac(path: Path, text: str) -> str:
    f = FLAC(str(path))
    existing = (f.get("LYRICS") or [""])[0]
    if existing.strip() == text.strip():
        return "skipped"
    f["LYRICS"] = text
    f.save()
    return "embedded"


def embed_mp3(path: Path, text: str) -> str:
    try:
        id3 = ID3(str(path))
    except ID3NoHeaderError:
        id3 = ID3()
    frames = id3.getall("USLT")
    existing = frames[0].text if frames else ""
    if existing.strip() == text.strip():
        return "skipped"
    id3.delall("USLT")
    id3.add(USLT(encoding=3, lang="eng", desc="", text=text))
    # v2_version=3 = ID3v2.3 (more broadly compatible than 2.4)
    id3.save(str(path), v2_version=3)
    return "embedded"


def embed_mp4(path: Path, text: str) -> str:
    f = MP4(str(path))
    raw = f.get("\xa9lyr", [""])
    existing = raw[0] if raw else ""
    if existing.strip() == text.strip():
        return "skipped"
    f["\xa9lyr"] = text
    f.save()
    return "embedded"


HANDLERS = {
    ".flac": embed_flac,
    ".mp3":  embed_mp3,
    ".m4a":  embed_mp4,
    ".mp4":  embed_mp4,
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else None)
    ap.add_argument("--library", required=True, help="Music library root")
    ap.add_argument("--log", default=None, help="Also append to this log file")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--verbose", action="store_true", help="Log every SKIP as well")
    args = ap.parse_args()

    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    if args.log:
        handlers.append(logging.FileHandler(args.log, encoding="utf-8"))
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=handlers,
    )
    log = logging.getLogger("embed")

    root = Path(args.library)
    if not root.is_dir():
        log.error("library root not found: %s", root)
        return 2

    stats = {"embedded": 0, "skipped": 0, "err": 0, "unsupported": 0, "noLrc": 0, "emptyLrc": 0}
    audio = [p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in HANDLERS]
    log.info("=== embed-all-lyrics start: %d audio files, dry_run=%s ===", len(audio), args.dry_run)

    for path in audio:
        lrc = path.with_suffix(".lrc")
        if not lrc.exists():
            stats["noLrc"] += 1
            continue
        try:
            text = lrc.read_text(encoding="utf-8").rstrip()
        except OSError as e:
            stats["err"] += 1
            log.warning("READ_ERR: %s: %s", path.name, e)
            continue
        if len(text) < 10:
            stats["emptyLrc"] += 1
            continue

        ext = path.suffix.lower()
        handler = HANDLERS.get(ext)
        if handler is None:
            stats["unsupported"] += 1
            continue

        if args.dry_run:
            log.info("DRY would-embed %s: %s", ext, path.name)
            stats["embedded"] += 1
            continue

        try:
            result = handler(path, text)
            if result == "embedded":
                stats["embedded"] += 1
                log.info("EMBED %s: %s", ext, path.name)
                if stats["embedded"] % 25 == 0:
                    log.info("Progress: embedded=%d", stats["embedded"])
            else:
                stats["skipped"] += 1
                if args.verbose:
                    log.info("SKIP %s: %s (tag already matches)", ext, path.name)
        except Exception as e:
            stats["err"] += 1
            log.warning("EMBED_ERR %s: %s: %s", ext, path.name, e)

    log.info("=== embed-all-lyrics done: %s ===", stats)
    return 0


if __name__ == "__main__":
    sys.exit(main())
