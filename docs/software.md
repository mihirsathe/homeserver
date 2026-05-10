# Software

## Operating System

| Item | Detail |
|------|--------|
| OS | Unraid Pro (lifetime license) |
| License tier | Pro — unlimited attached devices |
| Boot method | BOSS card (ZFS mirror, internal) |
| License anchor | USB flash drive (permanent, rear port) |
| Web UI | `http://mediaserver.local` or server IP |

---

## Unraid Plugins

| Plugin | Purpose |
|--------|---------|
| Community Applications | App store |
| Nvidia-Driver | RTX 3050 kernel driver; bundles nvidia-container-toolkit |
| Fix Common Problems | Config scanning and alerts |
| Appdata Backup | Weekly Docker config backup (Commifreak's fork; replaces the deprecated ca.backup2) |
| User Scripts | Scheduled scripts (stack boot, updates, backups, optional fan control) |
| Unassigned Devices | External drive mounting |
| Dynamix File Integrity | File checksum / silent corruption detection |
| Tailscale | Admin-plane mesh VPN — only path to *arr / SAB / Seerr / Unraid webUI |

`docker compose` is built into Unraid — no plugin needed. The stack is brought up at array start by the `media_stack_up` User Script that `setup-unraid.sh` writes.

---

## Docker Stack

All containers defined in `homeserver/docker-compose.yml` (deployed to `/mnt/user/appdata/homeserver/homeserver/` on the server).

All admin services are reached at `http://<name>.${HOSTNAME_SUFFIX}/` (default
suffix `lan`) through Caddy on `:80`. Backend ports are loopback-only on the
host (`127.0.0.1:*`) — they exist for `bootstrap.py` and host-side debugging.
Plex is the exception: it bypasses Caddy and is the one publicly-forwarded
service.

| Container | Image | Admin URL | Backend port (loopback) | Role |
|-----------|-------|-----------|-------------------------|------|
| caddy | `caddy:2-alpine` | — | `:80` (LAN/Tailscale ingress) | Reverse proxy: Host-header routes `<name>.lan` to each backend |
| gluetun | `qmcgaw/gluetun` | — | 8080, 9696 (loopback) | Mullvad WireGuard egress + kill-switch for SAB + Prowlarr |
| sabnzbd | `hotio/sabnzbd` | sab.lan | (in gluetun's netns) | Usenet downloader |
| prowlarr | `hotio/prowlarr` | prowlarr.lan | (in gluetun's netns) | Indexer manager |
| radarr | `hotio/radarr` | radarr.lan | 7878 (loopback) | Movie automation |
| sonarr | `hotio/sonarr` | sonarr.lan | 8989 (loopback) | TV automation |
| lidarr | `hotio/lidarr` | lidarr.lan | 8686 (loopback) | Music automation |
| plex | `plexinc/pms-docker` | direct on `:32400` | 32400 (PUBLIC) | Media server + GPU transcode (the one public service; bypasses Caddy) |
| seerr | `ghcr.io/seerr-team/seerr` | seerr.lan | 5055 (loopback) | Content request portal (Overseerr+Jellyseerr successor) |
| bazarr | `hotio/bazarr` | bazarr.lan | 6767 (loopback) | Subtitle automation |
| tautulli | `hotio/tautulli` | tautulli.lan | 8181 (loopback) | Plex analytics, stream history, notifications |
| profilarr | `santiagosayshey/profilarr` | profilarr.lan | 6868 (loopback) | Quality-profile + custom-format manager for Radarr/Sonarr. GUI-driven, subscribes to curated databases (Dictionarry DB, TRaSH Guides), diff-preview before sync. |

### Networks

Three bridge networks carve the stack into blast-radius zones so a compromised container can't trivially pivot across planes:

| Network | Members | Purpose |
|---------|---------|---------|
| `downloaders` | `gluetun`, `sabnzbd` (netns), `prowlarr` (netns), `radarr`, `sonarr`, `lidarr` | VPN'd egress and the *arr apps that talk to SAB + Prowlarr. `sabnzbd` and `prowlarr` use `network_mode: "service:gluetun"` — they share Gluetun's network namespace, so their UIs are published by Gluetun and their outbound traffic dies if the tunnel drops (`FIREWALL=on` kill-switch). |
| `automation` | `radarr`, `sonarr`, `lidarr`, `bazarr`, `profilarr` | *arr ↔ Bazarr traffic + Profilarr's API-driven quality-profile sync to Radarr/Sonarr. Keeps internal automation off the downloaders plane. |
| `frontend` | `plex`, `seerr`, `tautulli`, `bazarr` | User-facing services. Plex and Seerr sit here; neither needs to see SAB/Prowlarr directly. |

Networks are defined inline in the Compose file rather than `external: true` — Unraid's Docker service restarts on every boot and externally-created networks would need a separate User Script to recreate.

### Folder Structure on Server

```
/mnt/user/
├── appdata/                          ← cache pool (SSD), shareUseCache=only
│   ├── homeserver/                   ← docker-compose.yml, .env, scripts
│   ├── plex/                         ← Plex database + metadata (can grow 50–200 GB)
│   ├── plex-transcode/               ← active transcode temp (purged on restart)
│   ├── sabnzbd/
│   ├── radarr/
│   ├── sonarr/
│   ├── lidarr/
│   ├── prowlarr/
│   ├── gluetun/
│   ├── seerr/
│   ├── bazarr/
│   ├── tautulli/
│   └── profilarr/                    ← SQLite DB (subscribed databases + selected profiles)
├── usenet-incomplete/                ← cache pool (SSD), shareUseCache=only
│                                        SABnzbd active downloads + par2/unrar
└── data/                             ← spinning array, shareUseCache=yes
    ├── usenet/
    │   └── complete/
    │       ├── movies/               ← post-download, pre-import
    │       ├── tv/
    │       └── music/
    └── media/
        ├── movies/                   ← Radarr final library (what Plex sees)
        ├── tv/                       ← Sonarr final library
        └── music/                    ← Lidarr final library
```

All containers mount `/mnt/user/data` at `/data` inside the container. This shared mount path is what makes hardlinks work — SABnzbd's completed download (in `/data/usenet/complete/`) and Radarr's imported file (in `/data/media/`) occupy the same disk blocks, making every import an instant rename instead of a copy. Both sides are on the array, same filesystem — hardlinks cross directories, not filesystems.

`usenet-incomplete/` is a separate cache-only share, bind-mounted into SAB at `/incomplete`. Active downloads, par2 repair, and unrar all hammer this path, so it lives on SSD where those operations are 10–20× faster than on spinning disks. `shareUseCache=only` means mover never migrates these files to the array. When a download completes, SAB moves the assembled file from `/incomplete` (SSD) to `/data/usenet/complete/` (array) — a one-time cross-filesystem copy. From there, hardlinks to `/data/media/` work normally.

---

## External Access

One port is open on the router. **TCP 32400 → Plex** is the only public ingress; everything else is admin-plane and reachable only through Tailscale.

### Plex — the public service

Plex is forwarded directly on TCP 32400. The router port-forward goes to the server's LAN IP; Plex's own wildcard TLS (`*.plex.direct`, issued by Plex) terminates the connection and Plex's native clients negotiate direct-connect via `app.plex.tv`. Cloudflare is not involved — streaming video through a Cloudflare free/pro tunnel violates their Service-Specific Terms §2.8, and the WAN IP is already published to `plex.tv` regardless, so a tunnel buys nothing. Family members use the Plex app; no custom subdomain, no user-facing URL.

Plex-account 2FA is mandatory on every shared account. Relay is toggled off (`PLEX_PREFERENCE_RelayEnabled=0`), but the claim itself still publishes the WAN IP to plex.tv — this is intrinsic to Plex's architecture and not something the port-forward changes.

### Everything else — Tailscale

The *arr stack, SABnzbd, Prowlarr, Seerr, Bazarr, Tautulli, and the Unraid webUI are reachable only from devices on the tailnet. No public URL, no Cloudflare Access, no reverse proxy. Admin devices install Tailscale, tag themselves `tag:admin`, and Tailscale ACLs restrict `tag:admin → tag:server` to the specific admin ports. The server runs `tailscale up --ssh` so SSH also rides the tailnet.

### Family request flow (no public request portal)

Family uses the Plex app they already have:

1. Search a title in Plex → tap "Add to Watchlist".
2. Seerr polls Plex's Watchlist API every ~2 minutes.
3. Matching Watchlist entries auto-submit as Radarr / Sonarr requests (admin grants the `AUTO_REQUEST` permission in Seerr per user).
4. The title downloads and appears in the library.

No-one other than the admin ever needs to touch Seerr directly. Seerr's web UI exists as an admin tool (managing requests, tuning quality profiles, granting permissions) on the tailnet.

---

## Usenet Setup

SABnzbd and Prowlarr ride through **Gluetun** (Mullvad WireGuard) via `network_mode: "service:gluetun"`. Gluetun's `FIREWALL=on` kill-switch means if the VPN tunnel drops, SAB + Prowlarr lose all network connectivity until it reconnects — there is no path for their traffic to ever reach the internet on the home WAN IP. SSL alone isn't sufficient: it encrypts payload content but not the fact of the connection, the destination SNI in the TLS handshake, or the peer ASN visible to the ISP.

Register Usenet and indexer accounts **from a Mullvad exit IP** — easiest via the Mullvad app on a laptop/phone before the stack is up. Once the provider has logged a home-IP session on an account, that association can't be undone. Monero is preferred for payment where the provider accepts it.

### Providers

| Type | Role |
|------|------|
| Primary provider | All downloads · SSL port 563 · 20–50 connections |
| Fill/backup provider | Different backbone · lower priority · 5–10 connections |

### Indexers

Managed in Prowlarr, auto-synced to all apps.

| Indexer | Cost | Notes |
|---------|------|-------|
| NZBGeek | ~$12/yr | Excellent API reliability, community-curated |
| NZBPlanet | ~$10/yr | Large index, good API hit allowance |

### Download Flow

```
Plex Watchlist addition (family)
    → Seerr (polls Plex every 5 min, auto-submits request)
    → Radarr / Sonarr / Lidarr
    → Prowlarr (searches all indexers, via Gluetun)
    → SABnzbd (downloads NZB over Mullvad VPN on port 563)
    → Radarr / Sonarr hardlinks file to media library
    → Plex library updated
    → Available to stream
```
