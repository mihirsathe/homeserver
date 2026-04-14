# Home Server

Self-hosted media automation stack on a Dell PowerEdge R640 + MD1400 DAS, running Unraid Pro.

Usenet → SABnzbd → Radarr/Sonarr/Lidarr → Plex, with Overseerr for family requests and Cloudflare Tunnel for external access. No open router ports. Every app pre-configured before first boot — no UI wizards.

---

## Sections

| | |
|---|---|
| [Hardware](hardware.md) | Rack layout, compute node, storage, GPU transcoding specs |
| [Software](software.md) | OS, Unraid plugins, Docker stack, folder structure, external access, Usenet |
| [Deployment](deployment.md) | Step-by-step setup from a fresh Unraid install |
| [Operations](operations.md) | Maintenance schedule, diagnostics commands, known limitations |
| [Decisions](decisions.md) | Why things are the way they are, and expansion paths |
| [Vision](vision/index.md) | Long-term infrastructure roadmap — 8 phases from media server to full home platform |

---

## At a Glance

| Component | Detail |
|-----------|--------|
| Compute | Dell PowerEdge R640 · 2× Xeon Gold 6146 · 32 GB ECC RAM |
| GPU | MSI RTX 3050 LP 6G · 8 concurrent NVENC sessions |
| Storage | Dell MD1400 DAS · 32 TB usable (4×8 TB + 16 TB parity) |
| OS | Unraid Pro (lifetime) · BOSS card boot |
| Stack | 9 Docker containers · defined in one Compose file |
| Access | Cloudflare Tunnel · zero open router ports |
| Rebuild time | ~15 minutes from scratch |
