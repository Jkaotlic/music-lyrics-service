# Synology / xpenology Lyrics Pipeline

Python port of the Windows PowerShell lyrics pipeline.
Scans a music library, fetches synced LRC lyrics from LRCLib and Yandex Music,
writes `.lrc` sidecar files, and embeds lyrics into audio tags via mutagen.

---

## Runtime Options

Choose one of the following Python environments on your Synology NAS:

### (a) Beets Docker container (recommended if already running)
The `lscr.io/linuxserver/beets` image ships Python 3 with `mutagen` and `requests` pre-installed.
Mount the lyrics-pipeline directory and run the script inside the container.

### (b) Dedicated python:3-slim container
```bash
docker run --rm \
  -v /volume1/docker/lyrics-pipeline:/pipeline \
  -v /volumeUSB1/usbshare/Music:/music \
  python:3-slim \
  bash -c "pip install mutagen requests && python /pipeline/lrclib_pipeline.py --config /pipeline/config.ini"
```

### (c) System Python on DSM
If Python 3 is installed via the Synology Package Center or Entware:
```bash
pip3 install mutagen requests
python3 /volume1/docker/lyrics-pipeline/lrclib_pipeline.py --config /volume1/docker/lyrics-pipeline/config.ini
```

---

## Install Steps

1. **Clone or copy** the `synology/` folder to your NAS, e.g.:
   ```bash
   mkdir -p /volume1/docker/lyrics-pipeline
   cp lrclib_pipeline.py providers/ tests/ /volume1/docker/lyrics-pipeline/
   ```

2. **Copy and edit config**:
   ```bash
   cp config.ini.example /volume1/docker/lyrics-pipeline/config.ini
   nano /volume1/docker/lyrics-pipeline/config.ini
   ```
   Set `library_root` to your music folder (e.g. `/volumeUSB1/usbshare/Music`).

3. **Obtain Yandex OAuth token** (if using Yandex provider):
   - Use [yandex-music-token](https://github.com/MarshalX/yandex-music-api) or any compatible tool.
   - Write the bare token string to `yandex.token`:
     ```bash
     echo 'y0_AgAA...' > /volume1/docker/lyrics-pipeline/yandex.token
     chmod 600 /volume1/docker/lyrics-pipeline/yandex.token
     ```

4. **Install dependencies** (if not using Docker):
   ```bash
   pip3 install mutagen requests
   ```

5. **Schedule the task** (see Scheduling section below).

---

## Running Manually

```bash
# Normal run
python3 lrclib_pipeline.py --config config.ini

# Dry run — shows what would happen, no files written
python3 lrclib_pipeline.py --config config.ini --dry-run

# Override library root
python3 lrclib_pipeline.py --config config.ini --walk /path/to/music

# Force re-fetch even if .lrc exists
python3 lrclib_pipeline.py --config config.ini --force

# Process a single file
python3 lrclib_pipeline.py --config config.ini --file /path/to/track.flac
```

---

## Scheduling

### DSM Task Scheduler (recommended)

Use the included `task-scheduler.task.example`:

1. Find the next free task id:
   ```bash
   ls /usr/syno/etc/synoschedule.d/root/ | sort -n | tail -1
   # e.g. returns 6, so next id is 7
   ```
2. Install and activate:
   ```bash
   sudo cp task-scheduler.task.example /usr/syno/etc/synoschedule.d/root/7.task
   sudo synoschedtask --rebuild
   sudo synoschedtask --restart
   ```

The default schedule runs every 4 hours between midnight and 23:00, every day.

### cron (alternative)
Add to `/etc/crontab` or DSM user crontab:
```
0 */4 * * * root python3 /volume1/docker/lyrics-pipeline/lrclib_pipeline.py --config /volume1/docker/lyrics-pipeline/config.ini >> /volume1/docker/lyrics-pipeline/cron.log 2>&1
```

---

## Troubleshooting

**Token expiry (Yandex 401)**
- The pipeline writes a timestamp to `yandex.auth.failed` and circuit-breaks for 1 hour.
- Renew the token and delete the flag file:
  ```bash
  rm /volume1/docker/lyrics-pipeline/yandex.auth.failed
  ```

**Signature failures (403)**
- Written to `yandex.signature.failed`. Indicates HMAC mismatch — usually a clock drift issue.
- Check NAS system time and NTP sync.

**No lyrics found for many tracks**
- Enable debug logging by editing the pipeline source or adding `--dry-run` to inspect NONE entries.
- LRCLib has wider coverage for Western artists; Yandex is better for Russian-language music.

**Python version mismatch**
- Requires Python 3.10+. Check: `python3 --version`
- On older DSM, install a newer Python via Entware: `opkg install python3`

**State file / re-scanning**
- Delete `pipeline.state` to force a full rescan, or use `--force`.

---

## Differences from Windows Variant

| Feature | Windows (PowerShell) | Synology (Python) |
|---|---|---|
| Scheduling | Continuous loop with `Start-Sleep` | DSM Task Scheduler / cron (no daemon) |
| Incremental scan | Service loop tracks processed files | mtime-based state file (`pipeline.state`) |
| Tag embedding | `metaflac`, `id3v2`, external tools | `mutagen` (pure Python, no external deps) |
| Config | `config.ps1` (dot-sourced) | `config.ini` (standard INI) |
| Token storage | Windows Credential Manager | Plain file (chmod 600) |
| Runtime | PowerShell 5.1+ | Python 3.10+ |
