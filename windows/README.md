# Windows — PowerShell service

Runs as a Windows service via NSSM, polling your music library every 5 minutes and fetching synced lyrics from LRCLib + Yandex.Music.

## Prerequisites

| Tool | Install |
|------|---------|
| PowerShell 5.1+ | Built-in on Windows 10/11 |
| NSSM | https://nssm.cc or `choco install nssm` |
| metaflac | `winget install xiph.flac` |
| ffprobe | Ships with Navidrome, or `winget install Gyan.FFmpeg` |

## Installation

### 1. Clone or download

```
git clone https://github.com/Jkaotlic/music-lyrics-service.git
```

Place the `windows/` folder under a stable directory, e.g.:
```
C:\Tools\music-lyrics-service\windows\
```

### 2. Edit config.ps1

Open `config.ps1` and set your library root:

```powershell
$script:LibraryRoot = 'D:\Music\Library'  # <- change this
```

All paths for logs and flag files are resolved relative to `config.ps1` automatically.

### 3. Obtain Yandex OAuth token (optional)

If you want Yandex.Music lyrics (best for Russian tracks), you need a Yandex OAuth token:

1. Open: `https://oauth.yandex.ru/authorize?response_type=token&client_id=23cabbbdc6cd418abb4b39c32c41195d`
2. Approve access.
3. Copy the `access_token` from the redirect URL.
4. Save it to `yandex.token` next to `config.ps1`:

```
echo YOUR_TOKEN > C:\Tools\music-lyrics-service\windows\yandex.token
```

5. Restrict access to SYSTEM only:

```
icacls C:\Tools\music-lyrics-service\windows\yandex.token /inheritance:r /grant:r "SYSTEM:(R)"
```

Without `yandex.token`, the service runs in LRCLib-only mode.

### 4. Dry-run test

```powershell
powershell -ExecutionPolicy Bypass -File lrclib-service.ps1 -DryRun -OneShot
```

Expected output: scan log lines with `DRY [...]` prefix, no files written.

### 5. Install as Windows service

```batch
nssm install music-lyrics-service powershell.exe
nssm set music-lyrics-service AppParameters "-ExecutionPolicy Bypass -File C:\Tools\music-lyrics-service\windows\lrclib-service.ps1"
nssm set music-lyrics-service AppDirectory C:\Tools\music-lyrics-service\windows
nssm set music-lyrics-service Start SERVICE_AUTO_START
nssm set music-lyrics-service AppStdout C:\Tools\music-lyrics-service\windows\nssm-stdout.log
nssm set music-lyrics-service AppStderr C:\Tools\music-lyrics-service\windows\nssm-stderr.log
nssm start music-lyrics-service
```

### 6. Verify in Navidrome

Open any FLAC track in Navidrome — if synced lyrics were found, you should see the lyrics panel with line-level highlighting during playback.

## Running tests

```powershell
# Pester 5 (recommended)
Invoke-Pester -Path tests -Output Detailed

# Pester 3 (legacy)
Invoke-Pester tests
```

Integration tests (`-Tag Integration`) call live APIs and require network + a valid `yandex.token`. Unit tests run offline.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `NuGet provider required` prompt on first Pester install | Run: `Install-PackageProvider -Name NuGet -Force` |
| Pester 3 vs 5 mismatch | `Install-Module Pester -Force -SkipPublisherCheck` |
| `yandex.auth.failed` circuit-breaker active | Delete the flag file; check that `yandex.token` is valid |
| `yandex.signature.failed` | HMAC scheme may have changed upstream; open an issue |
| No lyrics for FLAC in Navidrome | Run `embed-lyrics.ps1` manually and check the log |
| Service not starting | Check `nssm-stderr.log`; verify ffprobe is on PATH |
