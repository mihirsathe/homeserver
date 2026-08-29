# Vision — Overview

*Living document — brainstorming and ideation. Last updated: April 2026.*

The long-term plan is to evolve the R640-based media server into a resilient, enterprise-grade home infrastructure platform. The end state is a 12–18U rack containing compute, networking, storage, and power systems providing:

- Automated media acquisition and streaming via Plex — the current system, refined and hardened
- Redundant home automation via Home Assistant on a Proxmox HA cluster, with uptime as the primary design constraint
- Full Ubiquiti UniFi network stack — managed switches, APs, security gateway — with VLAN segmentation
- IP security cameras with local NVR recording and AI object detection via Frigate — no cloud dependency
- Personal cloud services: file sync, photo management, passwords, ad-blocking DNS, VPN — all self-hosted
- Whole-home Cat6A structured wiring, centralized patch panel, PoE for cameras and APs
- Resilience to internet outages (local services continue), power outages (UPS + graceful shutdown), and hardware failures (dual parity, Proxmox HA)

> **Design philosophy:** Server-grade reliability with consumer-grade simplicity. Every system should be rebuildable from code, monitorable from a single dashboard, and operable by one person without specialized training.

The plan is eight sequential phases ordered by dependency and impact. Each phase is independently executable — there is no deadline, and the system is useful at every intermediate state.

---

## Phase Sequence

| Phase | Focus | Priority | Status |
|-------|-------|----------|--------|
| [1 — Harden](phases.md#phase-1--harden-the-media-server) | Dual parity, RAM, backups, notifications | **Critical** | Tailscale admin plane deployed (basic ACLs pending); rest outstanding |
| [2 — Network](phases.md#phase-2--network-infrastructure) | UniFi stack, VLANs, DNS sinkhole | High | Future |
| [3 — Power](phases.md#phase-3--power-resilience) | UPS, automated shutdown | **Critical** | APC Smart-UPS + apcupsd shipped (see [hardware.md](../hardware.md#rack) + [deployment.md](../deployment.md)); remaining sizing/NUT-client items below |
| [4 — Wiring](phases.md#phase-4--structured-wiring) | Cat6A to every room, patch panel | High | Future |
| [5 — Home Automation](home-automation.md) | Proxmox HA, Home Assistant, Thread/Matter | Medium | Future |
| [6 — Cameras](phases.md#phase-6--security-cameras) | Frigate NVR, PoE cameras, AI detection | Medium | Future |
| [7 — Personal Cloud](phases.md#phase-7--personal-cloud) | Nextcloud, Immich, Vaultwarden | Low | **Nextcloud deployed**; the rest future (Tailscale already in use — not a Phase-7 item) |
| [8 — Media Upgrades](phases.md#phase-8--advanced-media-upgrades) | GPU, array expansion, indexers | Low | Future |

---

## Current State

### What exists today

Dell PowerEdge R640 running Unraid Pro, connected to an MD1400 DAS. The software stack is fully containerized in Docker Compose: Radarr, Sonarr, Lidarr, SABnzbd, Prowlarr, Bazarr, Plex (GPU transcode via RTX 3050), Seerr. External access: one router port-forward (TCP 32400 → Plex); all admin plane reachable only through Tailscale. Dual Xeon Gold 6146, 32GB ECC RAM, 24TB usable array (single parity), 480GB SSD cache pool (BTRFS RAID1). Rebuildable from scratch in under an hour.

### Strengths

- Enterprise hardware with massive headroom (RAM, drives, PCIe slots)
- Infrastructure-as-code — entire stack reproducible from a single Compose file
- Tailscale admin plane + single Plex port-forward — minimal attack surface, no third-party CDN dependency
- GPU transcoding — RTX 3050 supports 12 concurrent NVENC sessions
- MD1400 — 12 hot-swap bays, room for 7 more drives and a second DAS via daisy-chain

### Current gaps

| Gap | Severity | Phase |
|-----|----------|-------|
| No off-system backup — single catastrophic event = total data loss | **Critical** | 1 |
| Consumer-grade networking — no VLANs, no PoE, no segmentation | High | 2 |
| Single parity — one drive failure during rebuild = total array loss | High | 1 |
| 32GB RAM — constrained under concurrent transcodes + downloads | Medium | 1 |
| No home automation, cameras, or structured wiring | — | 5–6 |

UPS is in place (APC Smart-UPS X SMX1500RM2U + apcupsd) — the cache-pool-corruption risk from power loss is mitigated. Sizing headroom for the full future rack is still a Phase-3 item.
