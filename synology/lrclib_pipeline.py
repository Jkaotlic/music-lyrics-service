"""Entry point — port of lrclib-service.ps1 main loop + embed-lyrics.ps1 combined."""
import argparse
import configparser
import importlib
import logging
import os
import sys
import time
from pathlib import Path
from typing import Optional

from mutagen import File as MutagenFile
from mutagen.flac import FLAC
from mutagen.id3 import ID3, USLT
from mutagen.mp4 import MP4


def parse_args():
    p = argparse.ArgumentParser(description="Lyrics pipeline for Synology DSM")
    p.add_argument("--config", default="config.ini", help="Path to config.ini")
    p.add_argument("--walk", metavar="DIR", help="Override config library_root")
    p.add_argument("--file", metavar="PATH", help="Process a single audio file (skips scan)")
    p.add_argument("--dry-run", action="store_true", help="Don't write .lrc or tags")
    p.add_argument("--force", action="store_true", help="Ignore existing .lrc, re-fetch")
    return p.parse_args()


def load_config(path: str) -> configparser.ConfigParser:
    cfg = configparser.ConfigParser()
    cfg.read(path, encoding="utf-8")
    return cfg


def extract_tags(path: Path) -> Optional[dict]:
    """Return {'artist','title','album','duration'} or None."""
    try:
        audio = MutagenFile(str(path))
        if audio is None:
            return None
        tags = audio.tags or {}

        def t(name):
            v = tags.get(name) or tags.get(name.upper())
            if isinstance(v, list) and v:
                return str(v[0])
            return str(v) if v else ""

        artist = t("artist") or t("ARTIST")
        title = t("title") or t("TITLE")
        album = t("album") or t("ALBUM") or ""
        duration = int(audio.info.length) if hasattr(audio, "info") and audio.info else -1
        if not artist or not title:
            return None
        return {
            "artist": artist.strip(),
            "title": title.strip(),
            "album": album.strip(),
            "duration": duration,
        }
    except Exception:
        return None


def load_providers(names):
    providers = []
    for name in names:
        try:
            mod = importlib.import_module(f"providers.{name.lower()}")
            providers.append((name, mod))
        except ImportError as e:
            logging.warning("Provider %s failed to import: %s", name, e)
    return providers


def embed_lyrics(path: Path, lrc_text: str, logger: logging.Logger, dry_run: bool) -> None:
    """Write lrc_text to the audio file's lyrics tag. LRC format as-is for Navidrome."""
    ext = path.suffix.lower()
    if dry_run:
        logger.info("DRY embed: %s (%s)", path.name, ext)
        return
    try:
        if ext == ".flac":
            f = FLAC(str(path))
            existing = (f.get("LYRICS") or [""])[0]
            if existing.strip() == lrc_text.strip():
                return
            f["LYRICS"] = lrc_text
            f.save()
        elif ext == ".mp3":
            try:
                id3 = ID3(str(path))
            except Exception:
                id3 = ID3()
            id3.delall("USLT")
            id3.add(USLT(encoding=3, lang="eng", desc="", text=lrc_text))
            id3.save(str(path), v2_version=3)
        elif ext in (".m4a", ".mp4"):
            f = MP4(str(path))
            f["\xa9lyr"] = lrc_text
            f.save()
        # other formats: no embed
    except Exception as e:
        logger.warning("Embed failed for %s: %s", path.name, e)


def process_file(
    path: Path,
    providers,
    logger: logging.Logger,
    dry_run: bool,
    force: bool,
    cfg: configparser.ConfigParser,
) -> str:
    lrc_path = path.with_suffix(".lrc")
    if lrc_path.exists() and not force:
        return "skip"

    info = extract_tags(path)
    if info is None:
        logger.info("NOTAG: %s", path)
        return "notag"

    best = None
    for name, mod in providers:
        try:
            kwargs = {}
            if name.lower() == "lrclib":
                sec = cfg["lrclib"] if "lrclib" in cfg else {}
                kwargs = {
                    "base_url": sec.get("base_url", "https://lrclib.net/api"),
                    "rate_limit_ms": int(sec.get("rate_limit_ms", 200)),
                }
            elif name.lower() == "yandex":
                kwargs = {"cfg": dict(cfg["yandex"])} if "yandex" in cfg else {"cfg": {}}
            result = mod.get_lyrics(
                info["artist"], info["title"], info["album"], info["duration"], **kwargs
            )
        except Exception as e:
            logger.warning(
                "PROVIDER_ERR [%s] %s - %s: %s", name, info["artist"], info["title"], e
            )
            continue
        if result and result.get("is_synced"):
            best = result
            break
        if result and best is None:
            best = result

    if best and best.get("text"):
        source = f"{best['source']}:{best['status_reason']}"
        lines = best["text"].count("\n") + 1
        if dry_run:
            logger.info(
                "DRY [%s] '%s - %s' would-write %dL -> %s",
                source, info["artist"], info["title"], lines, lrc_path,
            )
            return "ok"
        lrc_path.write_text(best["text"].replace("\r\n", "\n"), encoding="utf-8", newline="\n")
        embed_lyrics(path, best["text"], logger, dry_run)
        logger.info(
            "OK [%dL] (%s): '%s - %s' [%s] -> %s",
            lines, source, info["artist"], info["title"], info["album"], lrc_path,
        )
        return "ok"
    else:
        logger.info(
            "NONE: '%s - %s' [%s] %ds",
            info["artist"], info["title"], info["album"], info["duration"],
        )
        return "none"


def scan_library(
    root: Path,
    extensions: set,
    providers,
    logger: logging.Logger,
    dry_run: bool,
    force: bool,
    cfg: configparser.ConfigParser,
    state_path: Path,
) -> dict:
    last_mtime = 0.0
    if state_path.exists() and not force:
        try:
            last_mtime = float(state_path.read_text().strip())
        except Exception:
            last_mtime = 0.0
    new_max_mtime = last_mtime
    stats = {"ok": 0, "none": 0, "notag": 0, "skip": 0, "err": 0}
    logger.info("Scan start: root=%s state-mtime=%.0f", root, last_mtime)

    for p in root.rglob("*"):
        if not p.is_file() or p.suffix.lower() not in extensions:
            continue
        mtime = p.stat().st_mtime
        if mtime <= last_mtime and not force:
            continue
        if mtime > new_max_mtime:
            new_max_mtime = mtime
        try:
            r = process_file(p, providers, logger, dry_run, force, cfg)
            stats[r] = stats.get(r, 0) + 1
        except Exception as e:
            stats["err"] += 1
            logger.warning("ERR on %s: %s", p, e)

    if not dry_run and new_max_mtime > last_mtime:
        state_path.write_text(f"{new_max_mtime}\n", encoding="utf-8")
    logger.info("Scan done: %s", stats)
    return stats


def main():
    args = parse_args()
    cfg = load_config(args.config)
    if "pipeline" not in cfg:
        print(f"Bad config: {args.config}", file=sys.stderr)
        sys.exit(2)

    pipeline = cfg["pipeline"]
    library_root = Path(args.walk or pipeline.get("library_root", "./music"))
    extensions = {e.strip() for e in pipeline.get("extensions", ".flac,.mp3,.m4a").split(",")}
    state_path = Path(pipeline.get("state_path", "pipeline.state"))
    log_path = Path(pipeline.get("log_path", "pipeline.log"))
    provider_names = [
        p.strip() for p in pipeline.get("providers", "lrclib").split(",") if p.strip()
    ]

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=[
            logging.FileHandler(str(log_path), encoding="utf-8"),
            logging.StreamHandler(),
        ],
    )
    logger = logging.getLogger("pipeline")
    if args.dry_run:
        logger.info("DRY-RUN mode enabled - no files written")

    providers = load_providers(provider_names)
    if not providers:
        logger.error("No providers loaded, aborting")
        sys.exit(3)

    if args.file:
        process_file(Path(args.file), providers, logger, args.dry_run, args.force, cfg)
        return

    scan_library(library_root, extensions, providers, logger, args.dry_run, args.force, cfg, state_path)


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).parent))
    main()
