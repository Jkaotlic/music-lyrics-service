# music-lyrics-service

Synced lyrics fetcher for Navidrome/Subsonic music libraries. Queries **LRCLib** and **Yandex.Music** for time-stamped LRC lyrics, writes `.lrc` sidecar files, and embeds the lyrics directly into FLAC tags — enabling line-level highlighting in Navidrome 0.61+.

## What it does

The service continuously scans your music library for audio files without a matching `.lrc` sidecar. For each track it reads title/artist/album/duration via ffprobe, then queries providers in order:

1. **LRCLib** — open, free, no auth required. Three-level fallback: strict duration match → loose match → fuzzy search.
2. **Yandex.Music** — requires an OAuth token and an optional Plus subscription. Best source for Russian-language tracks with full synced lyrics.

Provider results are compared: a synced (timestamped) result always wins over plain lyrics. When both providers return plain, the first wins. Lyrics are written as `.lrc` sidecars. After each scan, `embed-lyrics.ps1` embeds the LRC content into the FLAC `LYRICS` vorbis tag so Navidrome can parse it without reading the sidecar file.

## Architecture

```
Music Library (FLAC / MP3 / OGG / ...)
        |
        v
lrclib-service.ps1   (service loop, 300s interval)
        |
        +-- ffprobe --> title / artist / album / duration
        |
        +-- Invoke-LyricsProvider-LRCLib  (providers/lrclib.ps1)
        |        |
        |        +-- https://lrclib.net/api
        |
        +-- Invoke-LyricsProvider-Yandex  (providers/yandex.ps1)
                 |
                 +-- https://api.music.yandex.net  (HMAC-SHA256 signed)
        |
        v
     .lrc sidecar written next to audio file
        |
        v
embed-lyrics.ps1  (triggered after scan)
        |
        +-- metaflac --set-tag-from-file=LYRICS=...
        |
        v
  LYRICS vorbis tag  -->  Navidrome line-level highlighting
```

## Repo layout

```
music-lyrics-service/
├── windows/            PowerShell implementation (Windows + NSSM service)
│   ├── lrclib-service.ps1     Main service loop
│   ├── embed-lyrics.ps1       FLAC tag embedder (metaflac)
│   ├── config.ps1             User-editable settings
│   ├── providers/
│   │   ├── lrclib.ps1         LRCLib provider
│   │   └── yandex.ps1         Yandex.Music provider (HMAC auth)
│   ├── tests/                 Pester 3/5 test suite
│   └── README.md
├── synology/           Python port (planned v1.1)
│   └── README.md
├── .gitignore
├── LICENSE
└── README.md           (this file)
```

## Variants

| Variant    | Language    | Runtime  | Install method    | Docs                    |
|------------|-------------|----------|-------------------|-------------------------|
| Windows    | PowerShell  | NSSM     | Continuous loop   | [windows/README.md](windows/README.md) |
| Synology   | Python      | DSM Task | Cron / Scheduler  | [synology/README.md](synology/README.md) |

## Requirements

- Navidrome 0.61+ (or any Subsonic server that parses embedded LRC for line highlighting)
- `ffprobe` — ships with Navidrome, or install via ffmpeg
- `metaflac` — for FLAC tag embedding (`winget install xiph.flac` on Windows)
- Optional: Yandex.Music account with OAuth token for Russian-language tracks

## License

MIT — see [LICENSE](LICENSE).

## Credits

- [LRCLib](https://lrclib.net) — free, open synced lyrics API
- [MarshalX/yandex-music-api](https://github.com/MarshalX/yandex-music-api) — HMAC signing scheme reference
