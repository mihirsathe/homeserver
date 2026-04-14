# Architecture

Network topology, storage strategy, backup/DR, security posture, and rack layout for the full build-out.

---

## Network Topology

All traffic flows through the UniFi managed switch. Every device connects back via Cat6A in a star topology. Centralized management, easy troubleshooting, per-port VLAN assignment.

### Key Traffic Flows

| Flow | Path |
|------|------|
| Plex streaming | Client (VLAN 10) → Switch → R640 (VLAN 20) — permitted by firewall rule |
| Camera to Frigate | Camera (VLAN 40) → Switch → R640 Frigate (VLAN 40) — same VLAN |
| Home Assistant to IoT | HA VM (VLAN 30) → Switch → IoT device (VLAN 30) — same VLAN |
| External Plex | Internet → Router port-forward (TCP 32400) → R640 (VLAN 20) — only public ingress |
| Admin / remote | Phone or laptop → Tailscale → R640 subnet router → internal services (*arr, SAB, Unraid UI) |

### DNS Architecture

Run dual DNS: primary AdGuard on Proxmox, secondary on Unraid. Both sync blocklists. DHCP hands out both IPs.

Configure **split-horizon DNS** so LAN clients resolve local hostnames (e.g., `plex.home.arpa` → `10.0.20.x`) directly rather than hairpinning through the WAN. Keeps LAN Plex traffic off the uplink and shaves latency on large streams.

---

## Storage Tiers

| Tier | Media | Location | Role |
|------|-------|----------|------|
| Hot / Cache | 2× 480GB SSD (BTRFS RAID1) | R640 bays 1–2 | Docker configs, databases, transcode scratch |
| Warm / Array | 4× 8TB + 1× 16TB parity (expandable to 10+2) | MD1400 | Media, downloads, cameras, file storage |
| NVMe / Proxmox | 256GB–1TB NVMe per mini PC | Proxmox nodes | HA VM storage, Home Assistant database |
| Cold / Backup | 8TB external USB | R640 USB 3.0 | Weekly config + data backup |
| Offsite / Cloud | Backblaze B2 (rclone, encrypted) | Cloud | Irreplaceable data: photos, documents, configs |

### Data Classification

| Class | What | Backup target |
|-------|------|---------------|
| Irreplaceable | Personal photos, documents, HA config/history, password vault, Plex watch history | Must be backed up offsite |
| Costly to replace | Docker configs, automation scripts, Unraid flash backup, SSL certs | Local + offsite |
| Replaceable with effort | Media library (re-downloadable), camera recordings | Local backup or accept risk |
| Ephemeral | Transcode scratch, download intermediates | No backup needed |

### Shared Storage for Proxmox HA

Both Proxmox nodes need shared storage for VM migration. Simplest: NFS share from Unraid mounted on both nodes. VM disks and ISOs live there. Tradeoff: Proxmox HA depends on Unraid being online. Acceptable since the QDevice (quorum) also runs on Unraid — the dependency already exists.

---

## Backup and Disaster Recovery

### Backup Matrix

| Data | Local Backup | Offsite | Frequency | Retention |
|------|-------------|---------|-----------|-----------|
| Unraid appdata | Appdata Backup plugin → array + USB drive | rclone → B2 | Weekly | 4wk / 12wk |
| Plex database | Included above | Included above | Weekly | 4wk / 12wk |
| Home Assistant | HA snapshots → NFS on Unraid | rclone → B2 | Daily | 7d / 30d |
| Vaultwarden | Encrypted export → array | rclone → B2 (double-encrypted) | Daily | 30d / 90d |
| Immich / Photos | On array (dual parity) | rclone → B2 (full library) | Real-time | Indefinite |
| Nextcloud files | On array | rclone → B2 (selective) | Real-time | Versioned 90d |
| Unraid USB flash | Flash Backup → array | Manual to cloud | After changes | 3 versions |
| Media library | Parity-protected | Not backed up | N/A | N/A |

### Disaster Recovery Scenarios

**Single drive failure**: With dual parity, a non-event. Replace the drive, rebuild from parity. Array remains accessible during rebuild (~12–24 hours for 16TB).

**Cache pool failure (both SSDs)**: Unlikely with BTRFS RAID1 but devastating — all Docker configs lost. Recovery: restore from most recent Appdata Backup archive (written to the array). Downtime: 1–2 hours.

**Total R640 hardware failure**: Media server down but Home Assistant continues on Proxmox. Recovery: new hardware, install Unraid, restore USB flash, deploy Compose stack, restore appdata from USB/cloud backup, re-mount MD1400 (drives retain data independently). Downtime: 4–8 hours with hardware on hand.

**Total site loss (fire, flood)**: All local hardware destroyed. Irreplaceable data (photos, documents, passwords) survives via Backblaze B2. Media library lost but replaceable. Recovery: days to weeks.

---

## Security Posture

### Network

- Exactly one open port on the router — TCP 32400 → Plex. All admin access via Tailscale (outbound-initiated, no inbound port)
- VLAN segmentation: IoT cannot reach management, cameras have no internet
- UniFi gateway IDS/IPS for WAN traffic inspection
- DNS sinkhole blocks malware and phishing domains network-wide
- Guest WiFi fully isolated — internet only, no LAN access

### Authentication

- Tailscale (WireGuard) with SSO + device posture checks for all admin access; ACLs restrict `tag:admin → tag:server` to named ports
- Plex-account 2FA mandatory on every shared account (the one public service)
- Vaultwarden for strong unique passwords everywhere
- Two-factor authentication on all supporting services

### Data

- All Usenet traffic over SSL — ISP cannot inspect
- Cloud backups encrypted with rclone crypt before upload
- Camera footage stored locally — no cloud camera service
- Plex data collection minimized (playback data, crash reports disabled)

### Physical

- Server rack in locked location
- iDRAC on isolated management VLAN (VLAN 1)
- USB license anchor physically secured
- UPS prevents power-based data corruption

---

## Physical Rack Layout

### Rack Selection

Target: 12–18U, 4-post, full-depth (30"+ — required for R640 and MD1400). Open frame with adjustable rails is most flexible. Enclosed adds dust protection and noise dampening but requires active ventilation.

### Proposed Layout (Bottom to Top)

| Position | Device | Notes |
|----------|--------|-------|
| U1–2 | UPS (APC SMT1500RM2U) | Heavy — always at bottom |
| U3–4 | MD1400 DAS | Full-depth, rear SAS cable management |
| U5 | R640 Media Server | Full-depth, sliding rails |
| U6 | Cable management panel | Organize patch cables |
| U7 | Patch panel (24-port Cat6A) | All home runs terminate here |
| U8 | UniFi PoE Switch | Directly below patch panel |
| U9 | Shelf — Proxmox mini PCs | Velcro-mounted, ventilated |
| U10 | UniFi Gateway | Or rack shelf for Gateway Max |
| U11–12 | Spare / expansion | Second UPS, additional switch |

### Power Distribution

Two rack-mount PDUs (one per UPS output circuit), each feeding one PSU of each dual-PSU device. One PDU can fail and nothing goes down. Single-PSU devices connect to the more reliable PDU.

### Cable Management

Velcro (not zip ties) for all bundles. Vertical cable channels on both rack sides. Power on one side, data on the other. Label every cable at both ends. Short patch cables (0.5–1m) between patch panel and switch.
