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
| Container image updates | Monthly (1st, 3am) | `update-stack.sh` via User Scripts |
| Parity check | Monthly (1st, 3am) | Scheduled in Unraid |
| Appdata backup | Weekly (Sunday, 4am) | Appdata Backup plugin |
| USB flash backup | After any Unraid config change | Main → Flash → Flash Backup |
| Re-seed disk folder structure | After adding any disk to the array | Run `scripts/seed-share-structure.sh` (see decisions.md § "Unraid allocator per-path pinning") |
| Verify fan control persisted | After any iDRAC firmware update | Check fans aren't at 100% |
| SMART check (cache SSDs) | Quarterly | iDRAC storage view or PERC UI (SMART not available via Unraid) |
| SMART check (MD1400 drives) | Automatic | Unraid dashboard alerts — verify alerts are configured |
| UPS self-test / battery health | Quarterly | `apcaccess status` for a quick read; `apctest` walks an interactive battery/calibration test |

---

## Diagnostics

```bash
# Is everything running?
cd /mnt/user/appdata/homeserver/homeserver && docker compose --env-file .env.docker ps

# Is GPU visible inside Plex?
docker exec plex nvidia-smi

# Watch GPU during a transcode
watch -n 2 'docker exec plex nvidia-smi'

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

The array uses single parity (one 16 TB disk). Protects against one drive failure at a time. Two simultaneous failures, or a failure during a parity rebuild, means data loss. Upgrade path is documented once in [decisions.md#expansion-paths](decisions.md#expansion-paths).

### 32 GB RAM

At current RAM, heavy simultaneous workloads (many active transcodes + downloads + metadata scanning) can feel constrained. The Xeon Gold 6146 dual-socket platform supports up to 768 GB (24× DIMM slots). Adding RAM is the single highest-ROI upgrade.

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

### iDRAC password (only if `setup-fan-control.sh` was run)
1. Update via the iDRAC Web UI.
2. `rm /boot/config/plugins/user.scripts/scripts/fan_control/.env`
3. Re-run `setup-fan-control.sh`.
