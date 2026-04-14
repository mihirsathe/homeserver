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
| Compose Manager Plus | Docker Compose support |
| Nvidia-Driver | RTX 3050 kernel driver |
| nvidia-container-toolkit | GPU access for Docker containers |
| Fix Common Problems | Config scanning and alerts |
| CA Appdata Backup/Restore | Weekly Docker config backup |
| User Scripts | Scheduled scripts (fan control, updates) |
| Unassigned Devices | External drive mounting |
| Dynamix File Integrity | File checksum / silent corruption detection |

---

## Docker Stack

All containers defined in `homeserver/docker-compose.yml` (deployed to `/mnt/user/appdata/media-stack/` on the server).

| Container | Image | Port | Role |
|-----------|-------|------|------|
| cloudflared | `cloudflare/cloudflared` | — | Outbound-only Cloudflare tunnel |
| sabnzbd | `hotio/sabnzbd` | 8080 | Usenet downloader |
| prowlarr | `hotio/prowlarr` | 9696 | Indexer manager |
| radarr | `hotio/radarr` | 7878 | Movie automation |
| sonarr | `hotio/sonarr` | 8989 | TV automation |
| lidarr | `hotio/lidarr` | 8686 | Music automation |
| plex | `plexinc/pms-docker` | 32400 | Media server + GPU transcode |
| overseerr | `hotio/overseerr` | 5055 | Content request portal |
| bazarr | `hotio/bazarr` | 6767 | Subtitle automation |

### Networks

Two Docker networks, both defined in the Compose file (not `external: true` — see [decisions.md](decisions.md)):

- `medianet` — all containers; internal communication by container name
- `cloudflared` — cloudflared + plex + overseerr only (public-facing services)

### Folder Structure on Server

```
/mnt/user/
├── appdata/                          ← cache pool (SSD)
│   ├── media-stack/                  ← docker-compose.yml, .env, scripts
│   ├── plex/                         ← Plex database + metadata (can grow 50–200 GB)
│   ├── plex-transcode/               ← active transcode temp (purged on restart)
│   ├── sabnzbd/
│   ├── radarr/
│   ├── sonarr/
│   ├── lidarr/
│   ├── prowlarr/
│   ├── overseerr/
│   └── bazarr/
└── data/                             ← spinning array
    ├── usenet/
    │   ├── incomplete/               ← SABnzbd active downloads
    │   └── complete/
    │       ├── movies/               ← post-download, pre-import
    │       ├── tv/
    │       └── music/
    └── media/
        ├── movies/                   ← Radarr final library (what Plex sees)
        ├── tv/                       ← Sonarr final library
        └── music/                    ← Lidarr final library
```

All containers mount `/mnt/user/data` at `/data` inside the container. This shared mount path is what makes hardlinks work — SABnzbd's completed download and Radarr's imported file occupy the same disk blocks, making every import an instant rename instead of a copy.

---

## External Access

No ports are open on the router. Cloudflare Tunnel creates an outbound-only encrypted connection from the server to Cloudflare's edge. The server's home IP is never exposed.

### Domains and Subdomains

| URL | Service | Who can access |
|-----|---------|----------------|
| `plex.yourdomain.com` | Plex Media Server | Family |
| `request.yourdomain.com` | Overseerr | Family |
| `manage.yourdomain.com/radarr` | Radarr | Admin only |
| `manage.yourdomain.com/sonarr` | Sonarr | Admin only |
| `manage.yourdomain.com/prowlarr` | Prowlarr | Admin only |
| `manage.yourdomain.com/sabnzbd` | SABnzbd | Admin only |
| `manage.yourdomain.com/lidarr` | Lidarr | Admin only |
| `manage.yourdomain.com/bazarr` | Bazarr | Admin only |

### Authentication

All external access goes through **Cloudflare Zero Trust** — OTP login code sent to approved email addresses.

- **Family group** — approved email list; 7-day session
- **Admin group** — your email only; 24-hour session
- Internal management apps (SABnzbd, *arr stack) not exposed to family — admin only via `manage.*`

---

## Usenet Setup

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
Overseerr request
    → Radarr / Sonarr / Lidarr
    → Prowlarr (searches all indexers)
    → SABnzbd (downloads NZB over SSL)
    → Radarr / Sonarr hardlinks file to media library
    → Plex library updated
    → Available to stream
```
