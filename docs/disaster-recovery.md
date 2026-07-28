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

**If repair fails**, restore from backup via `restore-appdata.sh`. Plex's own backup lives inside `appdata/plex/`, so the Appdata Backup archive already covers it. The restore invalidates watch history / play state since the last backup.

**Last resort**: delete the DB entirely and let Plex rebuild from metadata. Slow (hours on a large library) and loses all watch history, collections, and custom posters.

---

## Cache pool fill

**Symptom**: writes to `/mnt/user/appdata` (Docker, Plex DB, active downloads) start failing. `docker compose ps` shows containers restarting.

This is the most common real incident on this stack — the 480 GB cache pool is tight if Plex's DB grows unchecked and downloads queue up.

**Triage**:
```bash
du -sh /mnt/user/appdata/*/ | sort -hr | head
du -sh /mnt/user/usenet-incomplete/
```

Common culprits:
- **Plex transcode dir** (`appdata/plex-transcode/`) — should be empty; if not, Plex crashed mid-transcode. Safe to `rm -rf` contents while Plex is running.
- **Stuck SAB download** in `usenet-incomplete/` that's >20 GB and hasn't moved in days. This share is `cache=only`, so every stuck download eats cache-pool space directly.
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

## Tailscale admin plane down

**Symptom**: `mediaserver.<tailnet>.ts.net` doesn't resolve or times out from admin devices. Plex (router port-forward) still works; LAN access still works.

1. From an admin device: `tailscale status` — is the device itself connected to the tailnet? If not, open the Tailscale app, sign in again.
2. From the Unraid terminal (LAN or physical console): `tailscale status` — should list the host as `active`. If not: `tailscale up --ssh --advertise-tags=tag:server` and re-auth via the printed URL.
3. Tailscale admin console → Machines — confirm the host's key hasn't expired and `tag:server` is still applied. Tailscale expires keys periodically unless key-expiry is disabled per-machine.
4. Check ACLs: console → Access controls — the `tag:admin → tag:server` rule must still permit the port you're trying to reach.

Tailscale-side outages (rare) resolve without intervention. During an outage you can still reach the server from the LAN; there is no fallback path from outside the home network until the tailnet recovers (by design — that's the whole point of not publishing the admin UIs).

---

## Gluetun tunnel down (SAB + Prowlarr offline)

**Symptom**: SAB UI (`sab.lan`) and Prowlarr UI (`prowlarr.lan`) return 502/504 from Caddy or hang. `docker compose ps` shows `gluetun` `unhealthy`. Radarr/Sonarr can't queue new grabs.

This is the kill-switch: Mullvad dropped, `FIREWALL=on` is blocking all egress from containers sharing Gluetun's netns. **Never disable the kill-switch to unstick this** — that's the whole point of the setup.

1. `docker logs gluetun --tail 50` — expect WireGuard handshake failures, DNS errors, or a revoked-key message.
2. Verify `VPN_PRIVATE_KEY` / `VPN_ADDRESS` / `VPN_CITY` in `.env` match a current Mullvad WireGuard config. Regenerate on the Mullvad account page if the key was revoked.
3. `docker compose up -d gluetun` — forces a clean reconnect. SAB + Prowlarr come back once the tunnel handshakes.
4. Verify egress: `docker exec sabnzbd curl -s https://ifconfig.me` — must be a Mullvad exit IP, never your home WAN IP.

Mullvad-side outages (rare) resolve without intervention. SAB/Prowlarr stay offline until the provider is back — that's intended.

---

## AdGuard / Caddy down — admin URLs stop resolving

**Symptom**: `radarr.lan`, `sonarr.lan`, etc. don't resolve or 502 from
admin devices. Plex (port 32400) and SSH still work. The stack itself is
running — the admin ingress layer broke.

Two failure modes; check both quickly via `docker compose ps`:

1. **AdGuard `(unhealthy)` or stopped** → DNS layer broken; `*.lan`
   resolution fails everywhere on the tailnet.
2. **Caddy `(unhealthy)` or stopped** → DNS still resolves to
   `TAILNET_HOST_IP` but :80 doesn't answer or doesn't proxy.

**Fallback path (works regardless of AdGuard/Caddy state)** — every
backend is still bound to host loopback. From an SSH session on the host:

```bash
# Direct API hits while admin ingress is broken:
curl http://localhost:7878/ping             # radarr
curl http://localhost:8989/ping             # sonarr
curl 'http://localhost:8080/api?mode=version'  # sab
# etc.
```

For UI access during an outage, you can also bypass DNS by sending the
Host header to the host directly from any tailnet device:

```bash
curl -H "Host: radarr.lan" http://<TAILNET_HOST_IP>:81/ping
```

**Recovery**:

```bash
docker compose restart adguard caddy
```

If AdGuard's config got corrupted, restore from appdata backup
([Appdata corruption (single service)](#appdata-corruption-single-service))
or regenerate from the templated YAML:

```bash
python3 scripts/generate-configs.py --force-overwrite
docker compose restart adguard
```

The YAML is templated from `CADDY_SERVICES` in `generate-configs.py`, so
re-running the generator always rebuilds a known-good config.

---

## Seerr down / Watchlist still queues

**Symptom**: Seerr UI unreachable, but family members keep adding titles to Plex Watchlist. Nothing downloads.

Seerr is the bridge between Plex Watchlist and Radarr/Sonarr. If Seerr is down, Watchlist additions accumulate on Plex's side (no data loss) but nothing moves to the *arrs. Once Seerr comes back, the next `plex-watchlist-sync` job (runs every ~2 min) picks them all up at once.

1. `docker compose ps seerr` — restart if needed: `docker compose restart seerr`.
2. Check logs for DB corruption: `docker logs seerr --tail 100`. If corrupt, restore from appdata backup per [Appdata corruption (single service)](#appdata-corruption-single-service).
3. Family can keep adding titles to the Watchlist during the outage; backlog clears automatically on recovery.
