#!/usr/bin/env python3
"""Detect and repair cp1251-encoded Vorbis Comment tags in FLAC files.

Vorbis Comments (and therefore FLAC tags) must be UTF-8 per spec. Windows-based
taggers on Russian/CJK locales sometimes write cp1251/gbk bytes instead, which
looks fine in locale-aware viewers but appears as mojibake everywhere else
(Navidrome, Amperfy, web browsers). This tool detects and repairs them in place,
with a per-file backup for safe rollback.

Usage:
    python3 fix_cp1251_tags.py --library-root /volume1/music
    python3 fix_cp1251_tags.py --library-root /volume1/music --dry-run
    python3 fix_cp1251_tags.py --library-root /volume1/music --encoding cp1251

The --encoding flag lets you pick a different legacy encoding (e.g. cp1252, gbk).
Default is cp1251 (Russian Windows).

Detection logic:
  1. Export tags via metaflac --export-tags-to
  2. If bytes are pure ASCII: skip (no encoding concern)
  3. If bytes decode as valid UTF-8: skip (already correct)
  4. Otherwise: treat as cp1251, decode, rewrite each tag as UTF-8

Requires: metaflac (from `flac` package: apt install flac / ipkg install flac,
or use inside an existing beets docker container which bundles flac).
"""
from __future__ import annotations
import argparse
import datetime
import logging
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def is_ascii_only(data: bytes) -> bool:
    return all(b < 0x80 for b in data)


def is_valid_utf8(data: bytes) -> bool:
    try:
        data.decode("utf-8", errors="strict")
        return True
    except UnicodeDecodeError:
        return False


def export_tags(metaflac: str, path: Path) -> bytes:
    """Return raw tag export bytes from metaflac."""
    fd, tmp = tempfile.mkstemp(suffix=".tags")
    os.close(fd)
    try:
        subprocess.run(
            [metaflac, f"--export-tags-to={tmp}", str(path)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return Path(tmp).read_bytes()
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def parse_tag_lines(text: str) -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []
    for line in text.splitlines():
        if "=" not in line:
            continue
        name, value = line.split("=", 1)
        name = name.strip()
        if not name:
            continue
        pairs.append((name, value))
    return pairs


def repair(path: Path, metaflac: str, backup_root: Path, library_root: Path,
           legacy_encoding: str, dry_run: bool, log: logging.Logger) -> str:
    """Returns one of: 'skipped_ascii','skipped_utf8','fixed','dry_fixed','error'."""
    data = export_tags(metaflac, path)
    if not data:
        return "skipped_ascii"  # no tags at all — treat as inert
    if is_ascii_only(data):
        return "skipped_ascii"
    if is_valid_utf8(data):
        return "skipped_utf8"

    try:
        text = data.decode(legacy_encoding)
    except UnicodeDecodeError as e:
        log.warning("ERR decode %s: %s", path, e)
        return "error"

    pairs = parse_tag_lines(text)
    if not pairs:
        log.warning("ERR no parseable tags: %s", path)
        return "error"

    title = next((v for n, v in pairs if n.upper() == "TITLE"), "")
    if dry_run:
        log.info("DRY fix: %s  (title='%s')", path, title)
        return "dry_fixed"

    rel = path.relative_to(library_root)
    backup_path = backup_root / rel
    backup_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, backup_path)

    # Remove all existing vorbis comments, then set fresh pairs as UTF-8.
    # metaflac accepts UTF-8 argv on modern systems.
    subprocess.run([metaflac, "--remove-all-tags", str(path)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for name, value in pairs:
        subprocess.run([metaflac, f"--set-tag={name}={value}", str(path)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    log.info("FIX: %s -> title='%s'", path.name, title)
    return "fixed"


def main() -> int:
    ap = argparse.ArgumentParser(description="Repair cp1251-mis-encoded FLAC vorbis tags in place")
    ap.add_argument("--library-root", required=True, help="Root dir to walk recursively")
    ap.add_argument("--metaflac", default="metaflac", help="Path to metaflac binary (default: search PATH)")
    ap.add_argument("--encoding", default="cp1251",
                    help="Legacy encoding to decode mis-encoded tags (default: cp1251)")
    ap.add_argument("--dry-run", action="store_true", help="Report what would change, don't modify files")
    ap.add_argument("--backup-root", default=None,
                    help="Backup dir (default: <library-root>/.fix-cp1251-backup-<ts>)")
    ap.add_argument("--log-file", default=None, help="Log file path (default: stdout only)")
    args = ap.parse_args()

    library_root = Path(args.library_root).resolve()
    if not library_root.is_dir():
        print(f"library-root not a directory: {library_root}", file=sys.stderr)
        return 2

    ts = datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
    backup_root = Path(args.backup_root) if args.backup_root else library_root.parent / f".fix-cp1251-backup-{ts}"
    if not args.dry_run:
        backup_root.mkdir(parents=True, exist_ok=True)

    handlers: list[logging.Handler] = [logging.StreamHandler()]
    if args.log_file:
        handlers.append(logging.FileHandler(args.log_file, encoding="utf-8"))
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(message)s",
        datefmt="%H:%M:%S",
        handlers=handlers,
    )
    log = logging.getLogger("fix")

    log.info("library_root=%s backup_root=%s encoding=%s dry_run=%s",
             library_root, backup_root, args.encoding, args.dry_run)

    # Resolve metaflac
    metaflac = shutil.which(args.metaflac) or args.metaflac
    if not shutil.which(metaflac) and not os.path.isfile(metaflac):
        log.error("metaflac not found: %s  (apt install flac, or use beets docker image)", metaflac)
        return 3

    stats = {"scanned": 0, "fixed": 0, "dry_fixed": 0,
             "skipped_utf8": 0, "skipped_ascii": 0, "errors": 0}

    for path in library_root.rglob("*.flac"):
        if not path.is_file():
            continue
        stats["scanned"] += 1
        try:
            r = repair(path, metaflac, backup_root, library_root,
                       args.encoding, args.dry_run, log)
            stats[r] = stats.get(r, 0) + 1
        except subprocess.CalledProcessError as e:
            stats["errors"] += 1
            log.warning("ERR metaflac on %s: %s", path, e)
        except Exception as e:
            stats["errors"] += 1
            log.warning("ERR on %s: %s", path, e)

    log.info("done: %s", stats)
    if not args.dry_run:
        log.info("backup dir: %s", backup_root)
    return 0 if stats["errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
