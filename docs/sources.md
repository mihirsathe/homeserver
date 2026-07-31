# Sources

Every package, image, plugin, and driver used in this stack — where it comes from and who maintains it.

---

## Docker Images

All pulled at deploy time via `docker compose pull` and refreshed monthly by `update-stack.sh`. Each maintainer's stable rolling tag is used — hotio publishes `:release`, Plex publishes `:public`, the rest track `:latest`.

| Container | Image | Tag | Registry | Maintainer |
|-----------|-------|-----|----------|------------|
| caddy | `caddy` | `:2-alpine` | Docker Hub | Caddy authors (official) |
| adguard | `adguard/adguardhome` | `:latest` | Docker Hub | AdGuard (official) |
| gluetun | `qmcgaw/gluetun` | `:latest` | Docker Hub | qdm12 (community, widely used) |
| sabnzbd | `ghcr.io/hotio/sabnzbd` | `:release` | GitHub Container Registry | hotio |
| prowlarr | `ghcr.io/hotio/prowlarr` | `:release` | GitHub Container Registry | hotio |
| radarr | `ghcr.io/hotio/radarr` | `:release` | GitHub Container Registry | hotio |
| sonarr | `ghcr.io/hotio/sonarr` | `:release` | GitHub Container Registry | hotio |
| lidarr | `ghcr.io/hotio/lidarr` | `:release` | GitHub Container Registry | hotio |
| plex | `plexinc/pms-docker` | `:public` | Docker Hub | Plex Inc. (official) |
| seerr | `ghcr.io/seerr-team/seerr` | `:latest` | GitHub Container Registry | seerr-team (Overseerr + Jellyseerr successor) |
| bazarr | `ghcr.io/hotio/bazarr` | `:release` | GitHub Container Registry | hotio |
| tautulli | `ghcr.io/hotio/tautulli` | `:release` | GitHub Container Registry | hotio |
| profilarr | `santiagosayshey/profilarr` | `:latest` | Docker Hub | Santiago ([GitHub org Dictionarry-Hub](https://github.com/Dictionarry-Hub/profilarr) · [Docker Hub](https://hub.docker.com/r/santiagosayshey/profilarr)) |
| ollama | `ollama/ollama` | `:latest` | Docker Hub | Ollama Inc. (official) |

**hotio** (`ghcr.io/hotio`) is the de facto standard for *arr app images — tightly maintained, consistent `PUID`/`PGID`/`UMASK` environment model, fast to release updates. Source: [hotio.dev](https://hotio.dev).

**santiagosayshey/profilarr** is the upstream-blessed image for Profilarr — despite the personal-looking Docker Hub namespace, Santiago is the maintainer of the Dictionarry-Hub GitHub org and the image is linked directly from the official README. There is no `ghcr.io/dictionarry-hub` mirror; Docker Hub is the canonical distribution.

**`ollama/ollama`** is the upstream official image, run unmodified — the GPU-sharing behaviour is entirely environment variables in `docker-compose.yml`, so there is no custom image or sidecar to keep patched.

**plexinc/pms-docker** is the official Plex image, used instead of a hotio Plex image because it handles `PLEX_CLAIM`, `ADVERTISE_IP`/`ALLOWED_NETWORKS` and the nvidia runtime properly. It does **not** support a `PLEX_PREFERENCE_*` mechanism — that claim was wrong, and hardware-transcoding preferences are set by `bootstrap.py` over the `/:/prefs` API.

---

## Unraid Plugins

Installed via `installplg` in `setup-unraid.sh`. All but two come straight from the official Unraid GitHub org; the exceptions are called out below.

| Plugin | GitHub | Maintainer |
|--------|--------|------------|
| Community Applications | [unraid/community.applications](https://github.com/unraid/community.applications) | Limetech (Unraid) |
| Fix Common Problems | [unraid/fix.common.problems](https://github.com/unraid/fix.common.problems) | Limetech (Unraid) |
| Unassigned Devices | [unraid/unassigned.devices](https://github.com/unraid/unassigned.devices) | Limetech (Unraid) |
| Nvidia-Driver | [unraid/unraid-nvidia-driver](https://github.com/unraid/unraid-nvidia-driver) | Limetech (Unraid) |
| Dynamix File Integrity | [unraid/dynamix](https://github.com/unraid/dynamix) | Limetech (Unraid) |
| Tailscale | [unraid/unraid-tailscale](https://github.com/unraid/unraid-tailscale) | Limetech (Unraid) |
| User Scripts | [Squidly271/user.scripts](https://github.com/Squidly271/user.scripts) | Squidly271 (community) |
| Appdata Backup | [Commifreak/unraid-appdata.backup](https://github.com/Commifreak/unraid-appdata.backup) | Commifreak (community) |

**User Scripts** remains on Squidly271's account (the author of CA, who handed that repo to Unraid in 2024 but has kept User Scripts under his own account). Still actively maintained as of mid-2025.

**Appdata Backup** replaces the deprecated `ca.backup2` (deprecated at Unraid 6.12). Commifreak's fork is the forum-recommended successor.

**No Docker Compose plugin.** Unraid ships `docker compose` in the base OS. `setup-unraid.sh` installs a User Script (`media_stack_up`) that runs `docker compose up -d` at array start — this is the role Compose Manager Plus would otherwise play, without the extra plugin dependency.

### Nvidia driver chain

The plugin was originally community-maintained by ich777 and has since moved to the official `unraid/` GitHub org under Limetech. The install script does three separate things:

| Component | Downloaded from | Notes |
|-----------|----------------|-------|
| Nvidia driver (`.run`) | `us.download.nvidia.com` (official Nvidia) | Unmodified proprietary binary |
| nvidia-container-toolkit | `github.com/unraid/nvidia-container-toolkit` | Unraid's build of Nvidia's open-source toolkit |
| libnvidia-container | `github.com/unraid/libnvidia-container` | Unraid's build of Nvidia's open-source library |

The container toolkit and libnvidia-container are **Unraid-maintained forks** of official open-source Nvidia projects — not third-party code, but also not direct Nvidia downloads. Both source repos are public and auditable. Versions are pinned in a `versions.json` manifest in the plugin repo.

**Why not install manually?** Unraid runs in RAM — anything you install outside the plugin system is wiped on reboot. The plugin handles re-loading the kernel module and re-linking the Docker runtime on every boot. There is no meaningful "manual" alternative on Unraid.

---

## Python Packages

Installed at runtime by `bootstrap.py` into `/tmp/bootstrap-deps`. Not persisted across reboots (Unraid runs in RAM). Python itself is pre-installed on Unraid.

| Package | PyPI | Purpose |
|---------|------|---------|
| `requests` | [pypi.org/project/requests](https://pypi.org/project/requests) | HTTP calls to *arr and Seerr APIs |
| `plexapi` | [pypi.org/project/PlexAPI](https://pypi.org/project/PlexAPI) | Create Plex libraries, trigger scans |

`generate-configs.py` uses only Python stdlib (no pip dependencies).

---

## System Tools

Present on Unraid by default or installed as part of the driver plugin.

| Tool | Source | Used for |
|------|--------|----------|
| `docker` / `docker compose` | [Unraid built-in](https://docs.unraid.net/unraid-os/manual/docker-management/) | Container runtime |
| `racadm` | [Dell RACADM](https://www.dell.com/support/kbdoc/en-us/000178114) — bundled in iDRAC firmware, accessed remotely | Fan control via iDRAC |
| `nvidia-smi` | Nvidia — bundled with Unraid's Nvidia-Driver plugin (`unraid/unraid-nvidia-driver`) | GPU status and verification |
| `git` | [Unraid built-in](https://docs.unraid.net/unraid-os/manual/) | Cloning this repo |
| `python3` | Unraid built-in | Running setup scripts |
