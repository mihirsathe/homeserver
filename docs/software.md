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

All admin UIs are reached at `http://<name>.lan/` through Caddy on `:80`.
Backend ports bind `127.0.0.1:` only — they exist for `bootstrap.py` and
host-side debugging, never direct LAN/Tailscale access. Plex bypasses
Caddy and is the one publicly-forwarded service.

| Container | Image | Admin URL | Backend port (loopback) | Role |
|-----------|-------|-----------|-------------------------|------|
| caddy | `caddy:2-alpine` | — | `:80` (LAN/Tailscale ingress) | Reverse proxy: Host-header routes `<name>.lan` → each backend |
| adguard | `adguard/adguardhome` | adguard.lan | `:53/udp+tcp` (Tailscale split-DNS resolver) | Wildcard `*.lan → TAILNET_HOST_IP`; tailnet-wide ad-blocking freebie |
| gluetun | `qmcgaw/gluetun` | — | 8080, 9696 (loopback) | Mullvad WireGuard egress + kill-switch for SAB + Prowlarr |
| sabnzbd | `hotio/sabnzbd` | sab.lan | (in gluetun's netns) | Usenet downloader |
| prowlarr | `hotio/prowlarr` | prowlarr.lan | (in gluetun's netns) | Indexer manager |
| radarr | `hotio/radarr` | radarr.lan | 7878 (loopback) | Movie automation |
| sonarr | `hotio/sonarr` | sonarr.lan | 8989 (loopback) | TV automation |
| lidarr | `hotio/lidarr` | lidarr.lan | 8686 (loopback) | Music automation |
| plex | `plexinc/pms-docker` | direct on `:32400` | 32400 (PUBLIC) | Media server + GPU transcode (only public service; bypasses Caddy) |
| seerr | `ghcr.io/seerr-team/seerr` | seerr.lan | 5055 | Content request portal (Overseerr+Jellyseerr successor) |
| bazarr | `hotio/bazarr` | bazarr.lan | 6767 (loopback) | Subtitle automation |
| tautulli | `hotio/tautulli` | tautulli.lan | 8181 (loopback) | Plex analytics, stream history, notifications |
| profilarr | `santiagosayshey/profilarr` | profilarr.lan | 6868 (loopback) | Quality-profile + custom-format manager for Radarr/Sonarr. GUI-driven, subscribes to curated databases (Dictionarry DB, TRaSH Guides), diff-preview before sync. |
| ollama | `ollama/ollama` | — (via gate) | — (no published port) | Local LLM inference engine. Second-priority tenant of the RTX 3050. |
| ollama-gate | `caddy:2-alpine` | ollama.lan | 11434 (loopback) | Policy layer in front of Ollama: blocks model management over the network, 503s inference while Plex is transcoding. |
| gpu-arbiter | `python:3.12-alpine` | — | — | Watches Plex sessions; preempts Ollama's VRAM when a transcode starts. |

### Networks

Five bridge networks carve the stack into blast-radius zones so a compromised container can't trivially pivot across planes:

| Network | Members | Purpose |
|---------|---------|---------|
| `downloaders` | `gluetun`, `sabnzbd` (netns), `prowlarr` (netns), `radarr`, `sonarr`, `lidarr` | VPN'd egress and the *arr apps that talk to SAB + Prowlarr. `sabnzbd` and `prowlarr` use `network_mode: "service:gluetun"` — they share Gluetun's network namespace, so their UIs are published by Gluetun and their outbound traffic dies if the tunnel drops (`FIREWALL=on` kill-switch). |
| `automation` | `radarr`, `sonarr`, `lidarr`, `bazarr`, `profilarr` | *arr ↔ Bazarr traffic + Profilarr's API-driven quality-profile sync to Radarr/Sonarr. Keeps internal automation off the downloaders plane. |
| `frontend` | `plex`, `seerr`, `tautulli`, `bazarr`, `gpu-arbiter` | User-facing services. Plex and Seerr sit here; neither needs to see SAB/Prowlarr directly. `gpu-arbiter` joins read-only, to poll Plex's session list. |
| `ai` | `ollama-gate`, `caddy`, *(your AI-consuming containers)* | The local-inference consumer plane. The Ollama engine is deliberately **not** here — everything reaches it through `ollama-gate`, so no consumer can route around the GPU arbitration. |
| `ai_backend` | `ollama`, `ollama-gate`, `gpu-arbiter` | The engine plane. Only the gate (to proxy) and the arbiter (to evict models while the gate is turning everyone else away) are members. |

Networks are defined inline in the Compose file rather than `external: true` — Unraid's Docker service restarts on every boot and externally-created networks would need a separate User Script to recreate.

---

## Local AI

Ollama runs on the same RTX 3050 that Plex transcodes on. **Plex always wins.** The whole design follows from one number: the card has **6 GB of VRAM**.

NVENC and NVDEC are dedicated ASIC blocks on the die, so inference does not steal shader time from the encoder — the resource these two workloads actually contend for is VRAM capacity. Every mechanism below is about capping Ollama's footprint so a transcode always has room to allocate.

### How the GPU is shared

Four layers, ordered by how quickly they act. The first three are static and always in force; only the fourth needs a running daemon.

| # | Mechanism | Acts | What it does |
|---|-----------|------|--------------|
| 1 | `OLLAMA_GPU_OVERHEAD` | always | Hard VRAM reservation (default 1.5 GiB) that Ollama will never allocate into. If a model doesn't fit in what's left, Ollama spills layers to CPU instead of OOMing the card — the failure mode is "slower", not "broken". |
| 2 | `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_CONTEXT_LENGTH`, q8_0 KV cache | always | Bounds the footprint of whatever *is* loaded, so "how much VRAM is Ollama using" has one predictable answer instead of scaling with concurrent callers. |
| 3 | `OLLAMA_KEEP_ALIVE=60s` | ~60 s idle | Idle models evict themselves without anything watching. |
| 4 | `gpu-arbiter` + `ollama-gate` | ~5 s | Active preemption when Plex actually starts encoding. |

Layer 4 is the interesting one. `gpu-arbiter` polls Plex's `/status/sessions` every 5 seconds and counts sessions with `videoDecision="transcode"` — Direct Play and Direct Stream never touch the encoder, and audio-only transcodes are a CPU job, so neither counts. On the first real video transcode it:

1. **Creates a hold file** that `ollama-gate` matches on. Caddy's `file` matcher stats it per request; while it exists, every endpoint that could pull a model onto the GPU answers `503` + `Retry-After: 15`. This is the part that matters — it stops the *next* request from re-loading a model behind the arbiter's back.
2. **Evicts what's already resident** (`POST /api/generate` with `keep_alive: 0`), freeing the VRAM in about a second.

The hold releases 60 seconds after the last transcode disappears. That delay is hysteresis: without it, a binge would flap the hold open and closed between every episode.

**In the normal case there is no conflict at all.** A 3–4B model at ~2.5 GB plus a 4K HDR tone-mapping transcode at ~1 GB coexist comfortably on a 6 GB card. Preemption is the safety valve for the tail — someone loaded a 7B and three 4K streams started at once.

**The arbiter fails open.** No Plex token, Plex unreachable, or a malformed response means no hold, and Ollama keeps serving. Layers 1–3 still protect Plex, so failing closed would only mean a dead Plex token silently bricks local AI for the whole stack. See [decisions.md](decisions.md#local-ai-on-the-transcode-gpu).

### Model sizing

Budget roughly **4 GB** for weights plus KV cache — that's 6 GB minus the 1.5 GiB reservation, minus a little slack. Models that fit comfortably:

| Model | Size | Use |
|-------|------|-----|
| `llama3.2:3b` | ~2.0 GB | General chat/summarisation — the default recommendation |
| `qwen3:4b` | ~2.6 GB | Stronger reasoning, still fits with a transcode running |
| `nomic-embed-text` | ~0.3 GB | Embeddings for search/RAG |
| `llama3.1:8b-q4_K_M` | ~4.9 GB | Fits *only* when nothing is transcoding; will spill to CPU under a hold |

Nothing is pre-pulled. Models are fetched from the host, because the gate blocks model management over the network:

```bash
docker exec ollama ollama pull llama3.2:3b
docker exec ollama ollama list
```

### Reaching it

| From | Endpoint |
|------|----------|
| Another container on the stack | `http://ollama-gate:11434` (join the `ai` network) |
| A tailnet device | `http://ollama.lan/` |
| The Unraid host | `http://127.0.0.1:11434` |
| The LAN or the internet | **Not reachable.** Nothing binds `0.0.0.0`, and the router still forwards only 32400. |

Ollama also serves an OpenAI-compatible API at `/v1`, so most SDKs work unmodified against `http://ollama-gate:11434/v1` with a placeholder API key.

### Why the names look backwards

`ollama` is the engine; `ollama-gate` is what you connect to. Ollama has no authentication and no read-only mode — whoever can reach `:11434` can also delete every model on the box. So the engine is fenced onto `ai_backend` with no published port, and the gate sits in front on `ai` enforcing two rules:

- **`403`** on `/api/pull`, `/push`, `/create`, `/delete`, `/copy` — model management is a host operation, never a network one. A compromised consumer container can't wipe the model store.
- **`503`** on the inference endpoints while the hold is in effect.

Metadata reads (`/api/tags`, `/api/ps`, `/api/show`, `/v1/models`) pass through at all times, holds included — listing models costs no VRAM.

A container that reaches for `http://ollama:11434` out of habit gets NXDOMAIN, a loud failure, rather than silently bypassing the arbitration.

### Adding an AI-consuming container

Join the `ai` network and point at the gate. There's a commented template in `docker-compose.yml` next to `ollama-gate`:

```yaml
  some-ai-app:
    image: example/some-ai-app:latest
    networks:
      - ai
    environment:
      - OLLAMA_BASE_URL=http://ollama-gate:11434
      - OPENAI_BASE_URL=http://ollama-gate:11434/v1
      - OPENAI_API_KEY=unused
```

Treat `503` as "retry after `Retry-After`", not as a hard error — it means Plex is mid-transcode. If the app has an admin UI, add a row to `CADDY_SERVICES` in `generate-configs.py` and re-run it to get `<name>.lan` routing.

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
│   ├── profilarr/                    ← SQLite DB (subscribed databases + selected profiles)
│   ├── ollama/                       ← LLM model blobs (multi-GB — EXCLUDE from Appdata Backup)
│   └── ollama-gate/                  ← GPU hold flag written by gpu-arbiter
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

The *arr stack, SABnzbd, Prowlarr, Seerr, Bazarr, Tautulli, the Ollama API, and the Unraid webUI are reachable only from devices on the tailnet. No public URL, no Cloudflare Access, no reverse proxy. Admin devices install Tailscale, tag themselves `tag:admin`, and Tailscale ACLs restrict `tag:admin → tag:server` to the specific admin ports. The server runs `tailscale up --ssh` so SSH also rides the tailnet.

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
