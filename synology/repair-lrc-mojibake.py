"""
Repair .lrc files that were corrupted by the PS 5.1 Invoke-RestMethod Latin-1
double-encoding bug. Detection: any character in the Latin-1-private-use
range (U+0080..U+00FF) that is not a common printable marker indicates
double-encoded Cyrillic / Japanese / any non-Latin text. Repair: read as
UTF-8, re-encode to Latin-1 bytes (the original wire bytes), decode those as
UTF-8 to recover the real text.

Strictly reversible when the original was the Latin-1 double-encoding bug.
Leaves alone anything that decodes cleanly into real characters.
"""
from __future__ import annotations
import argparse
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")


def looks_double_encoded(text: str) -> bool:
    """
    Heuristic: a text is double-encoded if it contains codepoints in the
    Latin-1 extended block (U+0080..U+00FF) that real lyrics never use.
    A clean Cyrillic track has all non-ASCII chars in U+0400..U+04FF; a clean
    Japanese track in U+3000..U+9FFF; etc. Latin-1 upper half (0x80..0xFF)
    is essentially never in real music lyrics, so its presence is a strong
    signal of double-encoding.
    """
    hits = 0
    for ch in text:
        cp = ord(ch)
        if 0x0080 <= cp <= 0x00FF:
            hits += 1
            if hits >= 3:
                return True
    return False


def repair(text: str) -> str | None:
    """Return repaired text or None if repair fails."""
    try:
        raw = text.encode("latin-1")
        return raw.decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--library", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    root = Path(args.library)
    if not root.is_dir():
        print(f"library not found: {root}", file=sys.stderr)
        return 2

    lrc_files = [p for p in root.rglob("*.lrc") if p.is_file()]
    print(f"=== repair-lrc scan: {len(lrc_files)} .lrc files ===")

    stats = {"ok": 0, "repaired": 0, "unreadable": 0, "bad_after_repair": 0}
    for lrc in lrc_files:
        try:
            text = lrc.read_text(encoding="utf-8")
        except UnicodeDecodeError as e:
            stats["unreadable"] += 1
            print(f"UNREADABLE: {lrc.name}: {e}")
            continue
        if not looks_double_encoded(text):
            stats["ok"] += 1
            if args.verbose:
                print(f"OK: {lrc.name}")
            continue
        fixed = repair(text)
        if fixed is None or looks_double_encoded(fixed):
            stats["bad_after_repair"] += 1
            print(f"BAD_AFTER_REPAIR: {lrc.name}")
            continue
        if args.dry_run:
            stats["repaired"] += 1
            # Show first non-ASCII of before/after so a human can eyeball it
            before = next((ch for ch in text if ord(ch) > 127), "")
            after = next((ch for ch in fixed if ord(ch) > 127), "")
            print(f"DRY repair: {lrc.name}  first_nonascii '{before}' (U+{ord(before):04X}) -> '{after}' (U+{ord(after):04X})")
            continue
        # Write back with explicit LF line endings (what the original writer used)
        lrc.write_text(fixed.replace("\r\n", "\n"), encoding="utf-8", newline="\n")
        stats["repaired"] += 1
        print(f"REPAIRED: {lrc.name}")

    print(f"=== repair-lrc done: {stats} ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
