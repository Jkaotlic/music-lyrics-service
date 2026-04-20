# Synology DSM / xpenology — coming in v1.1

Python port for Synology DSM and xpenology is planned for **v1.1**.

It will provide the same provider contract (LRCLib + Yandex.Music), use **mutagen** for FLAC tag writes, and install as a DSM Task Scheduler job — no Docker or root access required.

Subscribe to releases on this repo to get notified when it ships.

## Planned features

- Same LRCLib + Yandex.Music providers as the Windows variant
- `mutagen` for embedded FLAC LYRICS tag (replaces metaflac)
- DSM Task Scheduler integration (`.task` file format for DSM 7.3+)
- Single `config.py` for library path, provider order, rate limits
- Pure Python 3 — no pip dependencies beyond `mutagen` and `requests`
