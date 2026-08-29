# Operations

## After a Reboot

Nothing. The stack is fully self-recovering:

- **Docker** starts automatically when the Unraid array starts
- **Containers** restart automatically via `restart: unless-stopped` — no `docker compose up` needed
- **Gluetun** re-establishes the Mullvad tunnel within seconds; SAB + Prowlarr only come back once the tunnel is up (kill-switch)
- **Tailscale** reconnects to the tailnet automatically — admin URLs resume working without intervention
- **Fan control** User Script (if you ran `setup-fan-control.sh`) re-applies thermal settings at array start

The only thing that doesn't auto-recover is a Plex claim token — expected, since it's single-use. `bootstrap.py` blanks it out after the first successful claim.

---

## Maintenance Schedule

| Task | Frequency | How |
|------|-----------|-----|
| Container image updates | Monthly (2nd, 3am — the 1st belongs to the parity check) | `update-stack.sh` via User Scripts — patch releases only for Nextcloud/Postgres, which are major-pinned |
| Nextcloud / Postgres major upgrade | Deliberate, never scheduled | See [Nextcloud major upgrades](#nextcloud-major-upgrades) below |
| Verify the Nextcloud offsite copy | Quarterly | `rclone ls $BACKUP_NEXTCLOUD_REMOTE \| tail` — an unverified backup of irreplaceable files is not a backup |
| Parity check | Monthly (1st, 3am) | Scheduled in Unraid |
| Appdata backup | Weekly (Sunday, 4am) | Appdata Backup plugin; `media_stack_backup` verifies + offsites it at 5am |
| Mover (cache → array) | Hourly, on the hour | Unraid built-in schedule — the reason `usenet-incomplete` must stay `cache=only` |
| USB flash backup | After any Unraid config change | Main → Flash → Flash Backup |
| Verify fan control persisted | After any iDRAC firmware update | Check fans aren't at 100% |
| Prune unused Ollama models | Quarterly | `docker exec ollama ollama list`, then `ollama rm <model>` — model blobs sit on the 480 GB cache pool |
| SMART check (cache SSDs) | Quarterly | iDRAC storage view or PERC UI (SMART not available via Unraid) |
| SMART check (MD1400 drives) | Automatic | Unraid dashboard alerts — verify alerts are configured |
| UPS self-test / battery health | Quarterly | `apcaccess status` for a quick read; `apctest` walks an interactive battery/calibration test |

> The Nextcloud maintenance rows are live as of 2026-08-29 (plane deployed); the quarterly offsite-verify row stays moot until `BACKUP_NEXTCLOUD_REMOTE` is set.

### Backup knobs (`.env`)

The weekly flow is two stages: the **Appdata Backup plugin** writes the archive to `/mnt/user/backups/appdata/` (Sunday 4:00), then the **`media_stack_backup`** User Script runs `scripts/backup-appdata.sh` (Sunday 5:00), which verifies a recent archive exists, records a SHA-256 checksum, copies offsite, and prunes — logging to `/var/log/homeserver/backup.log`. Three optional `.env` values steer it (script defaults apply if unset):

| Knob | Default | What it does |
|------|---------|--------------|
| `BACKUP_REMOTE` | empty (**currently unset** — local-only) | rclone target for the newest appdata archive; each run copies the archive's directory to `$BACKUP_REMOTE/<timestamp>`. Empty means the offsite copy is skipped and logged as such. |
| `BACKUP_NEXTCLOUD_REMOTE` | empty | rclone target for `/mnt/user/nextcloud` user files (plus the weekly `pg_dump` to `$BACKUP_NEXTCLOUD_REMOTE/db`). This is the **only** copy of the user files — the Appdata Backup plugin never sees them. The script runs this leg first and never exits early on its account, so a failed plugin backup can't silently take the personal-file copy down with it (and vice versa). |
| `BACKUP_LOCAL_RETENTION_DAYS` | `14` | Local archives (and their checksums) older than this are pruned at the end of each run. |

Both remote knobs require `rclone` on the host; if a remote is set but rclone is missing, the script warns and skips rather than failing the run.

---

## Diagnostics

```bash
# Is everything running?
cd /mnt/user/appdata/homeserver/homeserver && docker compose --env-file .env.docker ps

# Is GPU visible inside Plex?
docker exec plex nvidia-smi

# Watch GPU during a transcode
watch -n 2 'docker exec plex nvidia-smi'

# Who is holding VRAM right now (Plex transcode vs Ollama model)?
docker exec ollama nvidia-smi --query-gpu=memory.used,memory.total --format=csv

# Is Ollama holding a model in VRAM? (size_vram > 0 means yes; empty = idle,
# already unloaded by OLLAMA_KEEP_ALIVE)
curl -s http://127.0.0.1:11434/api/ps

# Force Ollama to hand the GPU back right now, without waiting out keep_alive
curl -s http://127.0.0.1:11434/api/generate -d '{"model":"llama3.2:3b","keep_alive":0}'

# Local AI end-to-end (expect a completion)
curl -s http://127.0.0.1:11434/api/generate \
     -d '{"model":"llama3.2:3b","prompt":"say hi","stream":false}'

# How much cache pool the model store is eating
du -sh /mnt/user/appdata/ollama

# Check Gluetun tunnel health (Mullvad WireGuard)
docker logs gluetun --tail 20

# Verify SAB is egressing through Mullvad (should print a Mullvad exit IP, not your home IP)
docker exec sabnzbd curl -s https://ifconfig.me

# Check Tailscale status (admin-plane mesh)
tailscale status

# View logs for a specific container
docker compose logs -f radarr

# Are hardlinks working? (link count > 1 = hardlinks exist)
ls -la /mnt/user/data/media/movies/ | head -10

# Check disk usage
df -h /mnt/user/data /mnt/user/appdata

# Restart a single container without touching others
docker compose restart radarr

# --- Nextcloud ---------------------------------------------------------
# occ must run as www-data; the image runs Apache as that user.
docker exec -u www-data nextcloud php occ status
docker exec -u www-data nextcloud php occ config:system:get trusted_domains

# Did the cron container actually run? (unix timestamp; crond fires cron.php every 5 min)
docker exec -u www-data nextcloud php occ config:app:get core lastcron

# Files on disk that Nextcloud doesn't know about — the fix after any
# out-of-band write into /mnt/user/nextcloud
docker exec -u www-data nextcloud php occ files:scan --all

# Stuck in maintenance mode (a backup run that died before its trap fired)
docker exec -u www-data nextcloud php occ maintenance:mode --off

# How much the user files and the previews are eating
du -sh /mnt/user/nextcloud
du -sh /mnt/user/nextcloud/appdata_*/preview 2>/dev/null

# Database size and liveness
docker exec nextcloud-db psql -U nextcloud -d nextcloud -c "\l+ nextcloud"
```

---

## Known Limitations

### SMART unavailable for cache pool SSDs

The PERC H730P in HBA mode does not pass SMART data through to Unraid. The two 480 GB SSDs in R640 bays 1–2 show "SMART unavailable" in the Unraid dashboard. Drives in the MD1400 via the LSI 9300-8e have full SMART.

Workaround: use iDRAC's storage view or the PERC's own interface to check internal SSD health quarterly.

### Fan noise with third-party GPU

The R640 *may* ramp fans to full speed when it detects a non-Dell PCIe card (the RTX 3050). Whether it actually does depends on the specific card and iDRAC firmware revision — some users see it, some don't. This repo does **not** set up fan control by default.

**Diagnose first.** Log into iDRAC → Sensors → Fans and check RPMs. Third-party PCIe default is ~100% duty cycle. Normal idle is ~20–30%.

**If fans are loud**, run:

```bash
bash /mnt/user/appdata/homeserver/homeserver/scripts/setup-fan-control.sh
```

This prompts for iDRAC credentials, writes them to a 0600 file on `/boot`, and provisions a User Script that re-applies `ThirdPartyPCIFanResponse=0` and a sensible fan offset at each array start. Enable it as `fan_control` in Settings → User Scripts.

If an iDRAC firmware update resets the setting, re-apply by re-running the User Script manually.

### No AV1 encoding

The RTX 3050 is Ampere (GA107) — it can decode AV1 but not encode it. AV1 encode requires Ada Lovelace (RTX 4000+). For Plex transcoding this doesn't matter: Plex always encodes output to H.264 or HEVC. Only relevant if ever re-encoding the library to AV1 for size savings.

### Plex Pass required for hardware transcoding

NVENC/NVDEC acceleration requires an active Plex Pass subscription. Without it, Plex falls back to CPU transcoding (the Xeon 6146 handles moderate loads but will spike under multiple 4K streams).

### Single parity

The array uses single parity (one 6 TB disk). Protects against one drive failure at a time. Two simultaneous failures, or a failure during a parity rebuild, means data loss. Upgrade path is documented once in [decisions.md#expansion-paths](decisions.md#expansion-paths).

### 32 GB RAM — and memory ceilings now sum to 30.75 GB of it

At current RAM, heavy simultaneous workloads (many active transcodes + downloads + metadata scanning) can feel constrained. The Xeon Gold 6146 dual-socket platform supports up to 768 GB (24× DIMM slots). Adding RAM is the single highest-ROI upgrade.

The Nextcloud plane took the stack's declared `deploy.resources.limits.memory` total from
26.75 GB to **30.75 GB**. Ceilings are limits, not reservations, and every tenant here is
bursty or schedulable — nothing reserves what it declares — but this is tighter than the
31.25 GB that was previously flagged as having no headroom for error, so it is written down
rather than absorbed silently.

Escalation ladder if the box starts swapping or the OOM killer appears in `dmesg`, cheapest
first:

1. **Plex 8G → 6G.** Far above its realistic peak (a few hundred MB per transcode session
   plus database cache). The least load-bearing 2 GB on the box, by the same reasoning that
   already took Ollama from 8G to 4G.
2. **Nextcloud 2G → 1.5G and cron 768M → 512M.** Costs preview-generation throughput.
3. **RAM to 128 GB.** [vision/phases.md](vision/phases.md) §1.2 — 4× 32 GB DDR4-2666 ECC
   RDIMM, roughly $100–160 used, and the answer that makes this table stop mattering.

### Nextcloud sync needs Tailscale running on the device

Nextcloud is a Tailscale Service like everything else, so a phone or laptop only syncs while
it is on the tailnet. Google Drive did not ask that. It is the accepted cost of not
publishing the service, and it is the one user-facing regression in replacing a cloud
provider with this box. [decisions.md](decisions.md) records what would change the answer.

### Nextcloud previews live on the array, not the cache pool

Preview generation reads and writes `/mnt/user/nextcloud/appdata_*/preview`, which is on
spinning disks, so first-time thumbnailing of a large photo import is slow. This is
deliberate: previews are the one thing in a Nextcloud data directory that grows without
bound, and cache-pool fill is the most common real incident on this stack. They are also
excluded from the offsite copy, being regenerable.

### Nextcloud major upgrades

`nextcloud:33-apache` and `postgres:18-alpine` are pinned, so `update-stack.sh` can only
ever pull patch releases. That is intentional — both upgrades are one-way, and an
unattended 3 a.m. job is the wrong place for a one-way migration.

To move majors, do it deliberately and one at a time (Nextcloud refuses to skip):

```bash
bash scripts/backup-appdata.sh          # dump first — this is the rollback
# edit docker-compose.yml: nextcloud:33-apache -> nextcloud:34-apache (BOTH services)
docker compose --env-file .env.docker pull nextcloud nextcloud-cron
docker compose --env-file .env.docker up -d nextcloud nextcloud-cron
docker compose --env-file .env.docker logs -f nextcloud    # watch `occ upgrade` run
docker exec -u www-data nextcloud php occ status
```

Both `nextcloud` and `nextcloud-cron` use the image — bump them together or the cron
container runs a mismatched `cron.php` against an upgraded database.

Postgres is the harder one: a major bump needs `pg_upgrade` or a dump-and-restore, because
the new server will not open the old data directory. The dump from `backup-appdata.sh` is
exactly what a restore-into-a-new-major needs.

Watch for one interaction: `update-stack.sh` waits 300s for services to report healthy. A
Nextcloud patch upgrade runs `occ upgrade` at start, and on a large instance that can
exceed the window — the script then reports failure and skips the image prune, which is the
safe direction but reads alarmingly. Check `docker logs nextcloud` before assuming a
broken release.

### Local AI is capped by 6 GB of VRAM, and yields to Plex

Ollama is the second-priority tenant of the RTX 3050. Two consequences worth knowing before debugging something as "broken":

- **Models much over ~4 GB spill layers to CPU** and run several times slower, because 2 GiB of VRAM is reserved for Plex and never handed to Ollama. This is deliberate — it's what guarantees a transcode can always start. Sizing guidance is in [software.md](software.md#model-sizing); the reservation is tunable via `OLLAMA_GPU_OVERHEAD_BYTES`.
- **Ollama does not react to Plex starting a transcode.** `OLLAMA_KEEP_ALIVE` is an idle timer, so a model loaded seconds before playback keeps its VRAM for the rest of that minute. The reservation covers it in every normal case; the exception is two or more concurrent 4K HDR tone-mapping transcodes, where the extra sessions fall back to CPU. If that shows up in practice, raise the reservation or shorten keep-alive — see [decisions.md](decisions.md#local-ai-on-the-transcode-gpu) for the preemption design that was considered and set aside.

Both go away with a larger GPU; see [decisions.md#expansion-paths](decisions.md#expansion-paths).

### Plex data collection

Plex requires an account and phones home for relay coordination, metadata, and licensing. Optionally disabled in server config: playback data, crash reports, push notifications, relay service. Account-level ad tracking and watch history sharing must be opted out at plex.tv manually. If full no-phone-home operation is ever needed, Jellyfin is a drop-in replacement in the Compose file.

---

## Monitoring & Alerting

No dedicated metrics stack — the goal is low operational cost, not an observability platform. What we rely on:

| Signal | Source | How to wire an alert |
|--------|--------|----------------------|
| Drive health (MD1400 HDDs) | Unraid SMART | Settings → Notifications → enable SMART warnings; pick an agent (see below) |
| Array parity errors | Unraid | Same notification settings; alert on parity check completion with errors > 0 |
| Cache pool fill | Unraid | Settings → Disk Settings → warning/critical threshold (set 75% / 90%) |
| UPS on battery / low battery | apcupsd events | Unraid's notification agent forwards apcupsd events (ONBATT, OFFBATT, LOWBATT, COMMLOST) once `SERVICE=enable` is set in `ups.cfg` |
| Container liveness | Docker healthchecks | `docker compose ps` shows `unhealthy` within ~90s of a crash. Fix Common Problems plugin surfaces unhealthy containers on the dashboard |
| Update-stack failures | update-stack.sh log | Configure User Scripts email-on-failure on the `media_stack_update` job |
| Gluetun tunnel down (SAB/Prowlarr offline) | `docker logs gluetun` | Container healthcheck flips to `unhealthy`; Fix Common Problems surfaces it. SAB + Prowlarr will stay unreachable until Mullvad reconnects (that's the kill-switch doing its job) |
| Tailscale offline | `tailscale status` from an admin device | If admin URLs stop resolving, check tailnet membership in the Tailscale admin console |
| Stream activity / client issues | Tautulli | Tautulli → Settings → Notification Agents — email, Discord, Telegram, etc. |
| Ollama model store growth | `du -sh /mnt/user/appdata/ollama` | Counts against the same cache-pool threshold as everything else in appdata; the 75% warning covers it |

**Unraid notification agent**: CA Notification Agent plugin gives email / Pushover / Discord delivery of Unraid events. Configure it once and the SMART/parity/cache alerts above route through it.

**Practical threshold**: the cache pool filling is the single most common thing that breaks this stack. 480 GB SSDs fill faster than you'd expect once Plex's DB grows and a few weeks of downloads queue up. Set the warning at 75%.

---

## Secret Rotation

### Usenet password
1. Change the password on the provider's site.
2. Edit `.env`: update `USENET_PASS`.
3. `python3 scripts/generate-configs.py` — regenerates `sabnzbd.ini` with the new password.
4. `docker compose restart sabnzbd`.

### Service API keys (*arr, SABnzbd, Prowlarr, Tautulli)
API keys live in `generated.env` and are embedded in the per-service config files written by `generate-configs.py`. To rotate:
1. Remove the key from `generated.env` (e.g. delete the `RADARR_API_KEY=` line).
2. `python3 scripts/generate-configs.py` — re-rolls it.
3. `docker compose up -d` — the service reads the new key from its regenerated config.xml on restart.
4. `python3 scripts/bootstrap.py` — reconnects Prowlarr/Seerr/Bazarr/Tautulli with the new key.

### Mullvad WireGuard key
Rotate if the key is suspected-compromised, or periodically as hygiene.
1. Mullvad account page → **WireGuard configuration** → revoke the old key → generate a new `.conf`.
2. Edit `.env`: replace `VPN_PRIVATE_KEY` and `VPN_ADDRESS` with the new values. Update `VPN_CITY` if the exit city changed.
3. `docker compose up -d gluetun` — Gluetun re-establishes the tunnel with the new key; SAB + Prowlarr briefly lose connectivity then resume.
4. Verify: `docker exec sabnzbd curl -s https://ifconfig.me` should show the new Mullvad exit IP.

### Tailscale auth
Tailscale sessions renew automatically. To force-rotate (e.g. after losing a device):
1. Tailscale admin console → Machines → remove the lost device.
2. On any still-trusted admin device, visit the admin console → Machines → ensure tags are correct.
3. Re-auth the Unraid host if its key was revoked: `tailscale up --ssh --advertise-tags=tag:server` — open the URL it prints to reconfirm.

### Plex token
Plex tokens don't expire on their own but rotate if you sign out on all devices. To refresh:
1. Sign in to Plex Web, Settings → General → Show the token.
2. Delete `PLEX_TOKEN=...` from `generated.env`.
3. `python3 scripts/bootstrap.py` — prompts for the new token (hidden input via `getpass`).

### Nextcloud passwords
All three live in `generated.env`. They are *not* interchangeable — the admin password is a
Nextcloud account, the other two are service credentials that the app reads at start.

**Admin password** — change it in the Nextcloud web UI (top-right → Settings → Security),
then update `NEXTCLOUD_ADMIN_PASSWORD` in `generated.env` to match. The env var is only
consumed at install time, so the UI is authoritative once installed; keeping the file in
sync is for your benefit, not the container's.

**Database / Redis passwords** — these are shared secrets between two containers, so they
have to change together:
1. Delete the line from `generated.env` (`NEXTCLOUD_DB_PASSWORD` or `NEXTCLOUD_REDIS_PASSWORD`).
2. `python3 scripts/generate-configs.py` — re-rolls it and rewrites `.env.docker`.
3. For Redis: `docker compose --env-file .env.docker up -d nextcloud-redis nextcloud nextcloud-cron`. Redis holds no persistent state, so it just restarts with the new password.
4. For Postgres: the password is stored *in the database*, so re-rolling the env var alone
   locks Nextcloud out. Change it in Postgres first, then re-roll:
   ```bash
   docker exec nextcloud-db psql -U nextcloud -d nextcloud -c "ALTER USER nextcloud WITH PASSWORD '<new>';"
   ```
   `-U nextcloud`, not `-u postgres`: `POSTGRES_USER=nextcloud`, so initdb created
   only the `nextcloud` superuser role. Connecting as `postgres` fails with
   `role "postgres" does not exist` — and if you then re-roll the env var anyway,
   you have locked Nextcloud out of a database whose password never changed.
   Then put `<new>` in `generated.env` by hand and `up -d nextcloud nextcloud-cron`.

### iDRAC password (only if `setup-fan-control.sh` was run)
1. Update via the iDRAC Web UI.
2. `rm /boot/config/plugins/user.scripts/scripts/fan_control/.env`
3. Re-run `setup-fan-control.sh`.
