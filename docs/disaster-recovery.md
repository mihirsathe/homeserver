# Disaster Recovery

What to do when something breaks. Ordered from most-common to least-common.

Before reaching for any of the procedures below, confirm the failure mode:

- `docker compose ps` — which containers are up? which report `unhealthy`?
- Unraid dashboard (Main tab) — is any drive flagged? parity valid?
- `df -h /mnt/user/data /mnt/user/appdata` — is anything full?

---

## Single array drive failure

**Symptom**: Unraid dashboard shows a drive as disabled or red. Data is still served (parity reconstructs on read), but writes are degraded.

**Recovery**:

1. Identify the failed drive by serial number in Main → Array Devices.
2. Stop the array (Main → Stop). Containers must come down first if any are writing to the array — check with `docker compose ps`, expect `restart: unless-stopped` to bring them back after.
3. Physically replace the disk. Label it with its bay number before pulling so you don't swap the wrong slot.
4. Start the array → Unraid offers to rebuild onto the new disk from parity.
5. Rebuild runs at ~100 MB/s → roughly **8 hours per TB** for an 8 TB drive (~64 h). Array remains usable during rebuild; I/O is slower because every read reconstructs from parity.
6. After rebuild completes, SMART-monitor the new drive for a week — infant mortality is real.

**What you lose**: nothing, assuming no second drive fails during the rebuild window.

**Mitigation for next time**: dual parity (see [decisions.md#expansion-paths](decisions.md#expansion-paths)) turns the single-drive window into a two-drive window.

---

## Parity drive failure

Less impactful than a data disk failure — no data loss risk, just a window of no protection.

1. Replace the disk physically (must be ≥ size of largest data disk; ours is 16 TB).
2. Main → Unraid detects the missing parity → assign the new drive as Parity.
3. Start the array → parity sync begins. ~30–45 h for 16 TB. Data is served normally during sync.

During the sync window, a data disk failure is unrecoverable. Try not to do heavy writes during this period.

---

## Appdata corruption (single service)

**Symptom**: a service won't start, crash-loops, or returns 500s forever; logs show DB corruption, missing files, or schema errors. Other services are fine.

**Recovery**:

```bash
bash /mnt/user/appdata/homeserver/homeserver/scripts/restore-appdata.sh
```

Pick the most recent good backup from the listed archives, select the one corrupted service (don't restore "all" unless you need to). The script stashes the current appdata as `<service>.pre-restore-<timestamp>` before overwriting, so you can revert with one `mv` if the restore itself causes new problems.

**What you lose**: everything configured in that service since the last backup (up to ~7 days with weekly schedule). API keys in `generated.env` are unchanged, so Prowlarr sync will re-establish connections automatically.

---

## Plex database corruption

Specific enough to warrant its own entry, because Plex's DB grows to 50–200 GB and a full restore is slow.

**First try Plex's own repair** (much faster than a restore):

1. Stop the container: `docker compose stop plex`.
2. Back up `/mnt/user/appdata/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases/` out of caution.
3. Follow Plex's [DB repair docs](https://support.plex.tv/articles/repair-a-corrupted-database/) — runs `sqlite3` over the blobs.
4. `docker compose start plex`.

**If repair fails**, restore from backup via `restore-appdata.sh`. Plex's own backup lives inside `appdata/plex/`, so the CA Appdata Backup archive already covers it. The restore invalidates watch history / play state since the last backup.

**Last resort**: delete the DB entirely and let Plex rebuild from metadata. Slow (hours on a large library) and loses all watch history, collections, and custom posters.

---

## Cache pool fill

**Symptom**: writes to `/mnt/user/appdata` (Docker, Plex DB, active downloads) start failing. `docker compose ps` shows containers restarting.

This is the most common real incident on this stack — the 480 GB cache pool is tight if Plex's DB grows unchecked and downloads queue up.

**Triage**:
```bash
du -sh /mnt/user/appdata/*/ | sort -hr | head
du -sh /mnt/user/data/usenet/incomplete/
```

Common culprits:
- **Plex transcode dir** (`appdata/plex-transcode/`) — should be empty; if not, Plex crashed mid-transcode. Safe to `rm -rf` contents while Plex is running.
- **Stuck SAB download** in `usenet/incomplete/` that's >20 GB and hasn't moved in days.
- **Plex DB bloat** — `Plug-in Support/Databases/com.plexapp.plugins.library.db` grows forever without pruning. Plex has a "Optimize Database" tool under Settings → Troubleshooting.
- **Docker image sprawl** — run `docker image prune -f` (the monthly update-stack.sh does this, but only if the health gate passed).

**Emergency**: Unraid Mover can be invoked manually (`mover start`) to flush cache → array. Only moves files from shares where cache is `yes`, not `only` (appdata is `only`, so this doesn't help for appdata itself — but can buy you breathing room on other shares).

**Prevention**: [operations.md](operations.md#monitoring--alerting) documents the 75% warning threshold. Set it.

---

## Total array loss

Worst case: multiple drive failures without dual parity, catastrophic controller failure, fire.

Media data — if no offsite copy — is gone. For this stack, the library is large and re-rippable, so the disaster plan is:

1. Parity + data: accept the loss, rebuild the array with fresh drives.
2. Appdata: restore from the most recent archive. If local backups are also gone, pull from `BACKUP_REMOTE` via `rclone copy ...`.
3. Re-run the deployment flow in [deployment.md](deployment.md). `generate-configs.py` is idempotent; API keys in the restored `generated.env` are preserved.
4. Plex library: re-scan the (rebuilt) media dirs. Watch history + collections come back via the restored Plex appdata.

**The lesson** this plan is built around: appdata backups **must** go offsite. The media can be re-sourced; the carefully-tuned `*arr` config and Plex DB cannot.

---

## Cloudflare tunnel down

**Symptom**: external URLs (`plex.yourdomain.com`, `request.yourdomain.com`) return 530 / 502. LAN access works fine.

1. Check container: `docker compose ps cloudflared` — should be `running`.
2. Check logs: `docker logs cloudflared --tail 50`. Usual culprits: tunnel token rotated, Cloudflare outage, temporary network issue at the ISP.
3. Cloudflare dashboard → Zero Trust → Networks → Tunnels — is the tunnel status "Healthy"?
4. If token was rotated, update `.env` `CLOUDFLARE_TUNNEL_TOKEN` and `docker compose up -d cloudflared`.

Cloudflare-side outages (rare) resolve without intervention — there is no workaround except waiting or temporarily opening a port on the router (don't).
