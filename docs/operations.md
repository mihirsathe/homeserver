# Operations

## After a Reboot

Nothing. The stack is fully self-recovering:

- **Docker** starts automatically when the Unraid array starts
- **Containers** restart automatically via `restart: unless-stopped` — no `docker compose up` needed
- **Cloudflare tunnel** reconnects within seconds
- **Fan control** User Script runs at array start and re-applies thermal settings

The only thing that doesn't auto-recover is a Plex claim token becoming stale, which is only relevant on the very first boot. Once Plex is claimed, it stays claimed.

---

## Maintenance Schedule

| Task | Frequency | How |
|------|-----------|-----|
| Container image updates | Monthly (1st, 3am) | `update-stack.sh` via User Scripts |
| Parity check | Monthly (1st, 3am) | Scheduled in Unraid |
| Appdata backup | Weekly (Sunday, 4am) | CA Appdata Backup plugin |
| USB flash backup | After any Unraid config change | Main → Flash → Flash Backup |
| Verify fan control persisted | After any iDRAC firmware update | Check fans aren't at 100% |
| SMART check (cache SSDs) | Quarterly | iDRAC storage view or PERC UI (SMART not available via Unraid) |
| SMART check (MD1400 drives) | Automatic | Unraid dashboard alerts — verify alerts are configured |

---

## Diagnostics

```bash
# Is everything running?
cd /mnt/user/appdata/homeserver/homeserver && docker compose --env-file .env --env-file generated.env ps

# Is GPU visible inside Plex?
docker exec plex nvidia-smi

# Watch GPU during a transcode
watch -n 2 'docker exec plex nvidia-smi'

# Check Cloudflare tunnel health
docker logs cloudflared --tail 20

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

The R640 ramps fans to full speed when it detects a non-Dell PCIe card (the RTX 3050). The fan control User Script suppresses this at every array start. If fans are loud after a reboot, the script didn't run — check User Scripts in the Unraid UI.

If an iDRAC firmware update resets the setting, re-apply manually:
```bash
racadm -r IDRAC_IP -u USER -p PASS set system.thermalsettings.ThirdPartyPCIFanResponse 0
racadm -r IDRAC_IP -u USER -p PASS set system.thermalsettings.ThermalProfile 2
```

### No AV1 encoding

The RTX 3050 is Ampere (GA107) — it can decode AV1 but not encode it. AV1 encode requires Ada Lovelace (RTX 4000+). For Plex transcoding this doesn't matter: Plex always encodes output to H.264 or HEVC. Only relevant if ever re-encoding the library to AV1 for size savings.

### Plex Pass required for hardware transcoding

NVENC/NVDEC acceleration requires an active Plex Pass subscription. Without it, Plex falls back to CPU transcoding (the Xeon 6146 handles moderate loads but will spike under multiple 4K streams).

### Single parity

The array uses single parity (one 16 TB disk). Protects against one drive failure at a time. Two simultaneous failures, or a failure during a parity rebuild, means data loss. To upgrade: add a second 16 TB drive as Parity 2 — the MD1400 has room and Unraid supports dual parity.

### 32 GB RAM

At current RAM, heavy simultaneous workloads (many active transcodes + downloads + metadata scanning) can feel constrained. The Xeon Gold 6146 dual-socket platform supports up to 768 GB (24× DIMM slots). Adding RAM is the single highest-ROI upgrade.

### Plex data collection

Plex requires an account and phones home for relay coordination, metadata, and licensing. Optionally disabled in server config: playback data, crash reports, push notifications, relay service. Account-level ad tracking and watch history sharing must be opted out at plex.tv manually. If full no-phone-home operation is ever needed, Jellyfin is a drop-in replacement in the Compose file.
