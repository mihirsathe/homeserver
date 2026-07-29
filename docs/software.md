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

All admin UIs are reached at `https://<name>.<tailnet>.ts.net/` as
**Tailscale Services**. Each service is advertised by the host's own
tailscaled — the daemon the Unraid Tailscale plugin already runs — and gets
its own TailVIP, its own MagicDNS name, and its own publicly-trusted,
auto-renewing certificate. MagicDNS puts the tailnet domain in most clients'
search path, so bare `https://radarr/` usually resolves too.

Backend ports bind `127.0.0.1:` only. Those loopback publishes do double duty:
they are `bootstrap.py`'s probe target *and* the backend that
`tailscale serve` proxies to. Plex is the one publicly-forwarded service and
is not fronted by anything.

**There is no reverse proxy.** Caddy, its `ts-caddy` sidecar, AdGuard Home,
the Caddyfile generator and the Tailscale split-DNS rule were all removed.
Caddy performed no middleware — no auth, no rate limiting, no shared policy —
so its entire job was mapping hostnames to ports, which MagicDNS does for free
and with a real certificate. That certificate also retires a bug the old
design had no answer for: browsers gate an expanding set of APIs behind
Secure Context, and Actual Budget simply will not load over plain HTTP.

The Unraid GUI remains the emergency path, and now the *only* thing on host
`:80`. `http://<server-name>/` on the LAN and `http://<host tailnet IP>/` over
Tailscale have no Docker dependency, so they keep working with the array
stopped. On Unraid, stopping the array stops Docker — which is exactly why the
GUI must never sit behind anything containerised.

| Container | Image | Admin URL (Tailscale Service) | Backend port (loopback) | Role |
|-----------|-------|-----------|-------------------------|------|
| gluetun | `qmcgaw/gluetun` | — | 8080, 9696 (loopback) | Mullvad WireGuard egress + kill-switch for SAB + Prowlarr |
| sabnzbd | `hotio/sabnzbd` | `svc:sab` | (in gluetun's netns) | Usenet downloader |
| prowlarr | `hotio/prowlarr` | `svc:prowlarr` | (in gluetun's netns) | Indexer manager |
| radarr | `hotio/radarr` | `svc:radarr` | 7878 (loopback) | Movie automation |
| sonarr | `hotio/sonarr` | `svc:sonarr` | 8989 (loopback) | TV automation |
| lidarr | `hotio/lidarr` | `svc:lidarr` | 8686 (loopback) | Music automation |
| plex | `plexinc/pms-docker` | — (direct on `:32400`) | 32400 (PUBLIC) | Media server + GPU transcode (only public service; fronted by nothing) |
| seerr | `ghcr.io/seerr-team/seerr` | `svc:seerr` | 5055 | Content request portal (Overseerr+Jellyseerr successor) |
| bazarr | `hotio/bazarr` | `svc:bazarr` | 6767 (loopback) | Subtitle automation |
| tautulli | `hotio/tautulli` | `svc:tautulli` | 8181 (loopback) | Plex analytics, stream history, notifications |
| profilarr | `santiagosayshey/profilarr` | `svc:profilarr` | 6868 (loopback) | Quality-profile + custom-format manager for Radarr/Sonarr. GUI-driven, subscribes to curated databases (Dictionarry DB, TRaSH Guides), diff-preview before sync. |
| ollama | `ollama/ollama` | — (no ingress by design) | 11434 (loopback) | Local LLM inference. Second-priority tenant of the RTX 3050; reachable only from the `ai` network and the host. |

### Networks

Four bridge networks carve the stack into blast-radius zones so a compromised container can't trivially pivot across planes:

| Network | Members | Purpose |
|---------|---------|---------|
| `downloaders` | `gluetun`, `sabnzbd` (netns), `prowlarr` (netns), `radarr`, `sonarr`, `lidarr` | VPN'd egress and the *arr apps that talk to SAB + Prowlarr. `sabnzbd` and `prowlarr` use `network_mode: "service:gluetun"` — they share Gluetun's network namespace, so their UIs are published by Gluetun and their outbound traffic dies if the tunnel drops (`FIREWALL=on` kill-switch). |
| `automation` | `radarr`, `sonarr`, `lidarr`, `bazarr`, `profilarr` | *arr ↔ Bazarr traffic + Profilarr's API-driven quality-profile sync to Radarr/Sonarr. Keeps internal automation off the downloaders plane. |
| `frontend` | `plex`, `seerr`, `tautulli`, `bazarr` | User-facing services. Plex and Seerr sit here; neither needs to see SAB/Prowlarr directly. |
| `ai` | `ollama`, *(your AI-consuming containers)* | Local inference. Isolated from the media planes — nothing here needs the *arrs or the downloaders, and since Ollama has no auth of its own, membership of this network *is* the access control. `caddy` is deliberately absent, which is why Ollama has no `*.lan` hostname. |

Networks are defined inline in the Compose file rather than `external: true` — Unraid's Docker service restarts on every boot and externally-created networks would need a separate User Script to recreate.

---

## Local AI

Ollama runs on the same RTX 3050 that Plex transcodes on. **Plex always wins.** The whole design follows from one number: the card has **6 GB of VRAM**.

NVENC and NVDEC are dedicated ASIC blocks on the die, so inference does not steal shader time from the encoder — the resource these two workloads actually contend for is VRAM capacity. Everything below caps Ollama's footprint so a transcode always has room to allocate.

### How the GPU is shared

Two mechanisms, both pure configuration. There is no scheduler, no daemon, and nothing watching Plex.

| Mechanism | What it does |
|-----------|--------------|
| `OLLAMA_GPU_OVERHEAD` | Hard VRAM reservation (default 2 GiB) that Ollama never allocates into. This is what guarantees Plex can start a transcode. If a model doesn't fit in what's left, Ollama spills layers to CPU instead of OOMing the card — the failure mode is "slower", not "Plex can't transcode". |
| `OLLAMA_KEEP_ALIVE` | Ollama's built-in eviction. A model unloads after this much idle time (default 60s here; upstream default is 5m). Local AI use on this box is bursty, so most of the time nothing is resident at all. |

Supporting knobs bound the footprint so the reservation above is meaningful: `OLLAMA_MAX_LOADED_MODELS=1` and `OLLAMA_NUM_PARALLEL=1` mean "how much VRAM is Ollama using" has one predictable answer instead of scaling with concurrent callers, and `OLLAMA_CONTEXT_LENGTH` plus a q8_0 KV cache keep the cache from outgrowing the weights.

### The gap, and why it's accepted

`keep_alive` is an **idle timer, not a response to GPU pressure** — it does not know Plex exists. If a transcode starts ten seconds after an inference, Ollama holds its VRAM for the rest of the window.

The reservation covers that: Plex still gets its 2 GiB and the transcode starts normally. It only becomes a real problem if Plex needs *more* than the reservation at that exact moment — roughly two or more concurrent 4K HDR tone-mapping transcodes — in which case the extra sessions fall back to CPU transcoding rather than failing.

For this household that's the far tail, and the fixes are one-line: raise `OLLAMA_GPU_OVERHEAD_BYTES`, shorten `OLLAMA_KEEP_ALIVE`, or run a smaller model. An earlier revision of this design added a daemon that polled Plex and evicted models within a second of a transcode starting; it was dropped as too much machinery for the case it covered. [decisions.md](decisions.md#local-ai-on-the-transcode-gpu) records that trade in full, in case the tail ever stops being the tail.

### Model sizing

Budget roughly **3.5–4 GB** for weights plus KV cache — 6 GB minus the 2 GiB reservation. Models that fit comfortably:

| Model | Size | Use |
|-------|------|-----|
| `llama3.2:3b` | ~2.0 GB | General chat/summarisation — the default recommendation |
| `qwen3:4b` | ~2.6 GB | Stronger reasoning, still fits alongside a transcode |
| `nomic-embed-text` | ~0.3 GB | Embeddings for search/RAG |
| `llama3.1:8b-q4_K_M` | ~4.9 GB | Does not fit — will run partly on CPU |

Nothing is pre-pulled:

```bash
docker exec ollama ollama pull llama3.2:3b
docker exec ollama ollama list
docker exec ollama ollama rm <model>     # blobs live on the cache pool
```

### Reaching it

| From | Endpoint |
|------|----------|
| Another container on the stack | `http://ollama:11434` (join the `ai` network) |
| The Unraid host | `http://127.0.0.1:11434` |
| The tailnet | **Not reachable.** Ollama has no `*.lan` hostname — Caddy is not on the `ai` network. |
| The LAN or the internet | **Not reachable.** Nothing binds `0.0.0.0`, and the router still forwards only 32400. |

Ollama also serves an OpenAI-compatible API at `/v1`, so most SDKs work unmodified against `http://ollama:11434/v1` with a placeholder API key.

### Adding an AI-consuming container

**Access is opt-in.** Nothing reaches Ollama by default — not Radarr, not Plex, not anything else in the stack. Every existing container lives on `downloaders` / `automation` / `frontend`; Ollama is alone on `ai`. A container has to join `ai` explicitly, which is a one-line change either way.

**If it's a service in this Compose file** — there's a commented template directly below the `ollama` service:

```yaml
  some-ai-app:
    image: example/some-ai-app:latest
    networks:
      - ai
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - OPENAI_BASE_URL=http://ollama:11434/v1
      - OPENAI_API_KEY=unused
```

**If it's an Unraid template container** (installed from Community Applications, not in this Compose file) — Docker tab → the container → Edit → **Network Type** → `ai`, then Apply. Set its Ollama URL to `http://ollama:11434`.

That works because the network is declared with `name: ai` in `docker-compose.yml` rather than taking Compose's default project prefix (`homeserver_ai`). The short, stable name is deliberate: it's what makes the network selectable from the Unraid UI and joinable by `docker run --network ai`, so template containers are first-class consumers rather than a special case. The network has to exist first — bring the stack up once before the dropdown will list it.

Either way, verify from the consumer's own point of view rather than the host's:

```bash
docker exec <container> curl -fsS http://ollama:11434/api/tags
```

If that returns `NXDOMAIN` or hangs, the container isn't on `ai`. Note that `localhost:11434` will never work from inside a consumer — that's the container's own loopback, not Ollama's.

If the app has an admin UI, add a row to `CADDY_SERVICES` in `generate-configs.py` and re-run it for `<name>.lan` routing — that publishes the *app's* UI to the tailnet, not Ollama's API.

**Ollama has no authentication and no read-only mode**, so anything on the `ai` network can also delete models and occupy the GPU. Network membership is the access control, which is exactly why access is opt-in rather than stack-wide: the media containers — especially the internet-facing downloaders — have no reason to be trusted with the model store. Models re-pull in minutes so the blast radius is small, but think before adding something to this network.

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
│   └── ollama/                       ← LLM model blobs (multi-GB — EXCLUDE from Appdata Backup)
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
