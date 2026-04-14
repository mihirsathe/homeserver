# Phases 1–4 and 6–8

See [Home Automation](home-automation.md) for the full Phase 5 detail.

---

## Phase 1 — Harden the Media Server

*Goal: Make the existing system resilient to common failure modes before adding complexity. Nothing new gets built until the foundation is solid.*

### 1.1 Add Dual Parity

Purchase a second 16TB drive (matching or exceeding the existing parity disk) and assign it as Parity 2 in Unraid. The array can then survive two simultaneous drive failures. Parity sync takes ~18–24 hours for 16TB; the array remains accessible during the process at reduced performance.

Cost: ~$250–300 (Exos, Ultrastar, or IronWolf Pro). **Single highest-value investment for data protection.**

### 1.2 Upgrade RAM to 128GB

Optimal config for the R640 dual Xeon Gold 6146: 4× 32GB DDR4-2666 ECC RDIMMs (two per socket, populating the first two channels). Leaves 20 slots free for future expansion. Used server-pull DDR4 ECC RDIMMs: ~$25–40/stick, so 128GB total ≈ $100–160.

Headroom gained: Plex metadata operations, concurrent transcoding, SABnzbd par2 repair, future containers.

### 1.3 Implement Off-System Backups

| Tier | What | How |
|------|------|-----|
| 1 — Local redundancy | CA Appdata Backup (weekly to array), BTRFS RAID1 cache pool, BOSS card mirror | Already exists |
| 2 — External local | USB 3.0 external drive (4–8TB) via Unassigned Devices plugin, rsync via User Script weekly | Store in different room or fireproof enclosure; rotate two drives monthly |
| 3 — Cloud offsite | rclone → Backblaze B2 ($6/TB/month). For ~50–100GB of appdata, cost is under $1/month. Focus on irreplaceable data: Plex watch history, Docker configs, HA config, personal files. Not the media library. | |

### 1.4 Enable Unraid Notifications

Configure Unraid's notification system for: drive errors, SMART warnings, parity check results, array status changes, Docker container health. At minimum: email + one push service (Pushover, Discord). Know immediately when something needs attention.

### 1.5 Harden Cloudflare Tunnel

- Verify admin-only routes (`manage.yourdomain.com/*`) are restricted to your email only
- Session durations: 7-day family, 24-hour admin
- Enable Cloudflare WAF rules on the tunnel
- Consider TOTP authenticator as second factor (Cloudflare Access supports it alongside OTP email)

---

## Phase 2 — Network Infrastructure

*Goal: Replace consumer networking with a managed, segmented, PoE-capable network supporting cameras, APs, IoT devices, and VLANs — all from a single pane of glass.*

### 2.1 Why Ubiquiti UniFi

Enterprise features (VLANs, PoE, centralized management, IDS/IPS) at prosumer pricing, with a polished UI that doesn't require networking certification. Entire stack managed from a single UniFi Network application.

### 2.2 Recommended Equipment

| Device | Model | Role | Est. Cost |
|--------|-------|------|-----------|
| Gateway/Router | UniFi Dream Machine Pro or Gateway Max | Firewall, routing, IDS/IPS, VPN server, UniFi controller | $350–380 |
| Core Switch | USW-Pro-24-PoE or USW-Enterprise-24-PoE | 24-port managed, 400W PoE+ | $500–700 |
| Patch Panel | 24-port Cat6A keystone | Structured wiring terminates here | $40–60 |
| AP (primary) | U7 Pro (WiFi 7) | Primary living area | $180 |
| AP (secondary) | U7 Pro or U6 Lite | Bedrooms / distant areas | $100–180 ea. |
| AP (outdoor) | U7 Outdoor | Yard / garage | $180 |

### 2.3 VLAN Architecture

Default-deny between VLANs. No VLAN can talk to another unless explicitly permitted.

| VLAN | Name | Purpose | Subnet | Internet |
|------|------|---------|--------|----------|
| 1 | Management | Network gear, iDRAC, switch mgmt | 10.0.1.0/24 | Limited |
| 10 | Trusted | Personal computers, phones, tablets | 10.0.10.0/24 | Full |
| 20 | Media | Plex, media server services | 10.0.20.0/24 | Full |
| 30 | IoT / Smart Home | Smart bulbs, sensors, HA devices | 10.0.30.0/24 | Restricted |
| 40 | Cameras | IP cameras — no internet | 10.0.40.0/24 | None |
| 50 | Guest | Guest WiFi — internet only | 10.0.50.0/24 | Throttled |

Key firewall exceptions: Trusted → Media (Plex access), IoT → Home Assistant, all VLANs → DNS servers. Camera VLAN is fully isolated — cameras talk to Frigate and nothing else.

### 2.4 UniFi Controller Placement

- **UDM-Pro**: controller is built in (simplest)
- **Gateway Max**: run controller as Docker container on Unraid initially; migrate to Proxmox VM once Phase 5 is complete (most resilient)

### 2.5 DNS — AdGuard Home or Pi-hole

Deploy a DNS sinkhole as a Docker container on Unraid. Blocks ads and trackers at DNS level for every device on the network. Once Proxmox is available, run a redundant pair (primary on Proxmox, secondary on Unraid) so DNS survives if either goes down. UniFi DHCP hands out both IPs.

---

## Phase 3 — Power Resilience

*Goal: Survive power outages gracefully — no data corruption, no service interruption for short outages, clean automated shutdown for extended outages.*

### 3.1 UPS Sizing

Full rack power budget at build-out:

| Device | Typical Draw | Peak Draw |
|--------|-------------|-----------|
| R640 (dual Xeon + GPU) | 250–350W | 500W |
| MD1400 DAS | 100–150W | 200W |
| Proxmox mini PCs (×2) | 30–60W | 90W |
| UniFi gateway | 20–30W | 40W |
| UniFi PoE switch | 30–50W | 60W |
| PoE devices (APs + cameras) | 60–120W | 160W |
| **Total** | **490–760W** | **~1,050W** |

For 800W typical draw and 15–20 minutes runtime: 1500VA/900W minimum, 2200VA preferred.

**Recommended units (pure sine wave only — R640 Platinum PSUs expect clean power):**
- APC Smart-UPS SMT1500RM2U — rack 2U, pure sine, network card slot, excellent apcupsd integration (~$500–700 refurb)
- APC Smart-UPS SMT2200RM2U — higher capacity, same form factor (~$600–900 refurb)
- CyberPower OR1500LCDRM1U — budget option but simulated sine wave; may cause PSU issues under battery

### 3.2 Automated Shutdown

Install apcupsd or NUT (Network UPS Tools) plugin on Unraid. Trigger shutdown when battery reaches 20% or runtime drops below 5 minutes.

Shutdown sequence: (1) send notification → (2) stop Docker containers gracefully → (3) stop Unraid array → (4) power off.

For Proxmox nodes: run NUT in server/client mode. Unraid is the NUT server; Proxmox nodes run NUT clients that trigger their own shutdowns.

### 3.3 Redundant Internet (Optional)

LTE/5G modem (T-Mobile Home Internet, ~$50/month) as failover WAN on the UniFi gateway (native dual-WAN). Keeps Cloudflare Tunnel connected and remote access working during ISP outages.

Critical principle: **local services must always work without internet.** Home Assistant, Plex for local clients, and cameras should never depend on the WAN.

---

## Phase 4 — Structured Wiring

*Goal: Wire every room, camera location, and AP location with Cat6A. All runs terminate at a central patch panel.*

### 4.1 Cable Selection

Cat6A: 10GbE at up to 100m, PoE++ (802.3bt, 90W) capable. Use shielded (STP) near electrical wiring; unshielded (UTP) is fine for most residential runs. Plenum-rated in HVAC spaces; riser-rated (CMR) in-wall.

### 4.2 Recommended Drops

| Location | Drops | Purpose |
|----------|-------|---------|
| Living room / media center | 2–4 | Smart TV, streaming device, console |
| Home office / desk | 2–4 | Desktop, dock, VoIP |
| Each bedroom | 1–2 | Smart TV, device |
| Kitchen | 1–2 | Smart display, PoE speaker |
| Garage | 1–2 | Camera, workshop PC |
| Each exterior camera location | 1 each | PoE camera (run before drywall) |
| Each AP location (ceiling) | 1 each | PoE access point |
| Front door | 1 | PoE doorbell / intercom |

Typical 3-bedroom house with 4 camera locations and 3 APs: 25–35 runs. At ~100ft/run: 3–4 boxes of Cat6A (~$150–250/box).

### 4.3 Termination

All runs terminate at a 24-port keystone patch panel. Label every cable at both ends during installation — the single most important step, most often skipped. Room end: Cat6A keystone wall plates with low-voltage mounting brackets.

### 4.4 AP Placement

Ceiling-mounted, centrally located per floor. Each AP needs one Cat6A drop — powered by PoE, no electrical outlet needed. For a typical single-story home: two indoor APs plus one outdoor AP.

---

## Phase 6 — Security Cameras

*Goal: IP cameras with local recording, no cloud subscriptions, AI object detection, integrated with Home Assistant.*

### 6.1 Camera Selection

Recommendation: third-party ONVIF/RTSP cameras + Frigate NVR. No vendor lock-in, AI detection via the RTX 3050, mix camera brands freely.

| Brand | Model | Notes |
|-------|-------|-------|
| Reolink | RLC-810A (4K PoE, ~$50–60) | Native RTSP, no cloud required |
| Reolink | RLC-812A (4K with spotlight) | Good for driveway/entry |
| Amcrest | IP8M-T2669EW (4K turret, ~$70–80) | Solid ONVIF/RTSP, reliable firmware |
| Dahua/Hikvision | various | Professional image quality — use on isolated camera VLAN |

### 6.2 Frigate NVR

Open-source NVR running as a Docker container on Unraid. Provides real-time AI object detection (person, car, dog, package) via TensorRT on the RTX 3050. Records only when objects of interest are detected — dramatically less storage than continuous recording. Communicates with Home Assistant via MQTT.

Resources for 4–8 cameras: ~2–4GB RAM, 1–2 CPU cores (or GPU NVDEC for stream decoding), GPU for inference.

Storage: 500GB–2TB on the array for 30–90 day retention of event clips. Continuous recording requires ~50–100GB/day/camera.

### 6.3 Camera Placement

- **Front door**: visitors and deliveries; consider 180° lens
- **Driveway**: vehicle arrivals/departures; license plate recognition possible
- **Backyard/side gates**: spotlight cameras deter and illuminate
- **Garage interior**: monitors high-value items, detects open door
- **Indoor (optional)**: common areas only, with household consent

---

## Phase 7 — Personal Cloud

*Goal: Replace cloud subscriptions with self-hosted alternatives.*

### 7.1 Service Catalog

| Service | Replaces | Container | Notes |
|---------|----------|-----------|-------|
| Nextcloud | Google/iCloud Drive | `nextcloud` | File sync, calendar, contacts, collaborative editing |
| Immich | Google/iCloud Photos | `immich` | Auto backup, face recognition, GPU ML inference |
| Vaultwarden | 1Password/LastPass | `vaultwarden` | Bitwarden-compatible, lightweight |
| AdGuard Home | — | `adguardhome` | Network-wide ad/tracker blocking |
| Tailscale | VPN services | `tailscale` | WireGuard mesh VPN, subnet router |
| Paperless-ngx | Filing cabinet | `paperless-ngx` | Document OCR + search |
| Mealie | Recipe bookmarks | `mealie` | Recipes + meal planning |
| Uptime Kuma | Pingdom | `uptime-kuma` | Service monitoring + alerts |
| Homepage | Bookmarks | `homepage` | Dashboard for all services |
| Gitea/Forgejo | GitHub (private) | `gitea` | Self-hosted Git |
| Audiobookshelf | Audible | `audiobookshelf` | Audiobook + podcast server |

### 7.2 Key Services

**Nextcloud**: deploy with PostgreSQL + Redis. Store data on array. Expose via Cloudflare Tunnel or Tailscale. Budget 2–4GB RAM.

**Immich**: store photo library on array, back up to Backblaze B2 — personal photos are irreplaceable. Can use the RTX 3050 for faster ML inference.

**Tailscale**: install on phone, laptop, and as a subnet router container on Unraid. Full access to every internal service as if physically at home. Free for personal use up to 100 devices. Complements Cloudflare Tunnel rather than replacing it.

---

## Phase 8 — Advanced Media Upgrades

*Goal: Revisit the media server for performance upgrades once the foundation is solid.*

### 8.1 GPU Upgrade — RTX 4060 LP

An RTX 4060 LP brings AV1 hardware encoding, 8GB VRAM (vs 6GB), and improved NVENC quality. Useful for library re-encoding and concurrent Frigate + Plex transcode workloads. Medium priority — the 3050 is not a bottleneck today.

### 8.2 Expand the Array

The 16TB parity supports data drives up to 16TB each. Maximum configuration: 2× parity + 10× data = up to 160TB usable. Filling all MD1400 bays with 16TB drives costs ~$2,500–3,000 at current pricing.

### 8.3 10GbE Client Networking

The R640 already has the X710 10GbE SFP+. To use it client-side: add a 10GbE NIC to a workstation and a direct DAC cable or a 10GbE switch. The USW-Enterprise-24-PoE includes 10G SFP+ uplinks.

### 8.4 Usenet Expansion

- **Second provider**: block account on a different backbone (~$10–20/TB), configured as secondary in SABnzbd. Improves completion rates on older/obscure content.
- **Additional indexers**: DrunkenSlug and NZBFinder beyond NZBGeek and NZBPlanet. $10–15/year each. Prowlarr auto-syncs to all *arr apps.
