# Decisions

Why things are the way they are. Read before changing something you haven't touched recently.

---

## Software Architecture

### Unraid over TrueNAS / SnapRAID

Mixed drive sizes (16 TB parity, 8 TB data) and the ability to add single drives without rebuilding. TrueNAS/ZFS requires matched VDEV sizes. Unraid's parity model is uniquely suited to this hardware.

### BOSS card for boot

More reliable than a USB flash drive (cheap NAND, physical wear prone to failure). RAID1-mirrored M.2 SATA in a dedicated slot — doesn't consume a riser slot, survives one M.2 failure without downtime.

### Docker Compose over native Unraid templates

Config-as-code. The entire stack is one file that can be version-controlled, diff'd, and reproduced from scratch. Unraid's native template system stores config in opaque XML on the boot USB.

### hotio images (except Plex)

Consistent `PUID`/`PGID`/`UMASK` pattern across all containers, lean builds. Plex uses `plexinc/pms-docker` because only the official image supports `PLEX_PREFERENCE_*` env vars and the nvidia runtime properly.

### Cloudflare Tunnel over a reverse proxy

No open ports on the router. Home IP never exposed. Cloudflare handles DDoS protection and SSL termination automatically. The tradeoff — Cloudflare sees the traffic — is acceptable for a family media server.

### Prowlarr over Jackett

Same Servarr team as Radarr/Sonarr, native API integration that auto-syncs indexers to all apps, actively developed. Jackett is effectively in maintenance mode.

### SABnzbd over NZBGet

Actively developed, better UI, better category handling. NZBGet development has significantly slowed. CPU headroom is not the constraint on this hardware.

### Single parity (for now)

Four 8 TB drives is a modest start. Single parity is appropriate. Dual parity becomes more valuable as drive count and total data grow. Upgrade: add a second 16 TB drive as Parity 2 when convenient.

---

## Compose Conventions

### Absolute paths everywhere

Compose Manager Plus on Unraid runs `docker compose` with a working directory of `/boot/config/plugins/...`. Relative `./configs/` paths would resolve to the wrong location. Every volume mount uses its full `/mnt/user/...` path.

### Networks defined in Compose, not `external: true`

Unraid restarts Docker on every boot. External networks would need to be recreated by a User Script before the array starts every time. Letting Compose own the networks is simpler — they're created on `compose up` and survive as long as the stack exists.

---

## Rack / Hardware

### Switch — USW-Pro-Max-16 over alternatives

Two SFP+ ports needed simultaneously (10G to server + 10G uplink to networking rack). Staying in the UniFi ecosystem is worth the delta on a long build-out timeline. See full rationale in [hardware.md](hardware.md#switch--ubiquiti-usw-pro-max-16).

### No PDU

The UPS has enough outlets for the current device count (R640, MD1400, switch). A PDU adds cost and complexity for no benefit at this scale.

### No patch panel

Three to four devices — direct patch cables are cleaner than terminating to a panel. A panel makes sense at 8+ runs, which only applies to the future networking rack.

### UPS at the bottom

Heaviest component in the rack. Low center of gravity improves physical stability.

### Thermal breaks (U9, U11)

Vented blanks between the R640 and MD1400, and above the R640. The R640 intakes from the front and exhausts out the rear — thermal breaks prevent exhaust from preheating adjacent equipment intakes.

---

## Expansion Paths

### Near-term, low effort

| Upgrade | Benefit |
|---------|---------|
| Add Parity 2 (16 TB) | Survive 2 simultaneous drive failures |
| Add RAM (e.g. 4× 32 GB → 128 GB) | Headroom under heavy concurrent load |
| Fill MD1400 bays 6–12 | Up to 7 more drives (max 16 TB each, constrained by parity disk size) |

### Medium-term

| Upgrade | Benefit | Notes |
|---------|---------|-------|
| Second Usenet provider (different backbone) | Better completion on older/obscure content | ~$5–10 block account |
| Additional NZB indexers (DrunkenSlug, NZBFinder) | More search coverage | $10–15/yr each |
| Replace R640 bays 1–8 with NVMe | Faster scratch storage, more appdata headroom | May need NVMe backplane adapter |

### Longer-term

| Upgrade | Benefit | Notes |
|---------|---------|-------|
| GPU upgrade to RTX 4000 series | AV1 encode + more VRAM for 6+ 4K streams | Must be LP form factor |
| RAM to 128 GB+ | Comfortable headroom for everything | DDR4 RDIMM, verify DIMM config for 6146 dual-socket |
| Second MD1400 | 12 more drive bays via daisy-chain | LSI 9300-8e supports it; drops into U5–6 |
| 10GbE switch to client devices | Multi-gigabit transfers where clients support it | X710 on R640 already has SFP+ |

### Architectural changes (if needs change significantly)

| Change | Why you'd do it | Tradeoff |
|--------|----------------|---------|
| Plex → Jellyfin | Eliminate Plex account + data collection | Less polished clients, no Plex Pass features |
| Add Ansible on top of Compose | Full server config-as-code including Unraid settings | Significant complexity for a single server |
| Add Gluetun VPN container | Route SABnzbd through VPN | Unnecessary for Usenet (already SSL-encrypted); useful if adding torrents |
| Add Tailscale alongside Cloudflare | Zero-install personal remote access | Complementary, not competing |
