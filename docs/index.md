# Home Server

Self-hosted media automation stack on a Dell PowerEdge R640 + MD1400 DAS, running Unraid Pro.

Usenet → SABnzbd → Radarr/Sonarr/Lidarr → Plex, with Seerr auto-requesting from Plex Watchlist. Plex port-forwarded (TCP 32400); all admin UIs reachable only via Tailscale. SAB + Prowlarr egress through Gluetun (Mullvad WireGuard) with kill-switch. Most apps are pre-configured before first boot; two manual post-deploy clicks remain: granting per-user Auto-Request in Seerr (tied to each family member's Plex SSO identity, no API equivalent), and the first-run flow in Profilarr to pick quality-profile databases and select formats.

---

## Sections

| | |
|---|---|
| [Hardware](hardware.md) | Rack layout, compute node, storage, GPU transcoding specs |
| [Software](software.md) | OS, Unraid plugins, Docker stack, folder structure, external access, Usenet |
| [Deployment](deployment.md) | Step-by-step setup from a fresh Unraid install |
| [Upgrade Runbook](upgrade-2026-07.md) | The live run: catching a first-setup box up to current `master`, moving ingress to Tailscale Services, and landing the four in-flight tenants in one sitting |
| [Operations](operations.md) | Maintenance schedule, diagnostics commands, known limitations |
| [Sources](sources.md) | Every image, plugin, package, and driver — where it comes from |
| [Decisions](decisions.md) | Why things are the way they are, and expansion paths |
| [Vision](vision/index.md) | Long-term infrastructure roadmap — 8 phases from media server to full home platform |

---

## At a Glance

| Component | Detail |
|-----------|--------|
| Compute | Dell PowerEdge R640 · 2× Xeon Gold 6146 · 32 GB ECC RAM |
| GPU | Yeston RTX 3050 LP 6G · 12 concurrent NVENC sessions |
| Storage | Dell MD1400 DAS · 32 TB usable (4×8 TB + 16 TB parity) |
| OS | Unraid Pro (lifetime) · BOSS card boot |
| Stack | 11 Docker containers · defined in one Compose file |
| Access | One router port (TCP 32400 → Plex) · admin via Tailscale · SAB/Prowlarr via Mullvad |
| Rebuild time | ~15 minutes from scratch |
