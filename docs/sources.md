# Sources

Every package, image, plugin, and driver used in this stack — where it comes from and who maintains it.

---

## Docker Images

All pulled at deploy time via `docker compose pull`. Pinned to `latest` and updated monthly by `update-stack.sh`.

| Container | Image | Registry | Maintainer |
|-----------|-------|----------|------------|
| cloudflared | `cloudflare/cloudflared` | Docker Hub | Cloudflare (official) |
| sabnzbd | `ghcr.io/hotio/sabnzbd` | GitHub Container Registry | hotio |
| prowlarr | `ghcr.io/hotio/prowlarr` | GitHub Container Registry | hotio |
| radarr | `ghcr.io/hotio/radarr` | GitHub Container Registry | hotio |
| sonarr | `ghcr.io/hotio/sonarr` | GitHub Container Registry | hotio |
| lidarr | `ghcr.io/hotio/lidarr` | GitHub Container Registry | hotio |
| plex | `plexinc/pms-docker` | Docker Hub | Plex Inc. (official) |
| overseerr | `ghcr.io/hotio/overseerr` | GitHub Container Registry | hotio |
| bazarr | `ghcr.io/hotio/bazarr` | GitHub Container Registry | hotio |

**hotio** (`ghcr.io/hotio`) is the de facto standard for *arr app images — tightly maintained, consistent `PUID`/`PGID`/`UMASK` environment model, fast to release updates. Source: [hotio.dev](https://hotio.dev).

**plexinc/pms-docker** is the official Plex image; used instead of a hotio Plex image because the official image's `PLEX_PREFERENCE_*` environment variable mechanism is how hardware transcoding preferences are pre-configured at first boot.

---

## Unraid Plugins

Installed via `installplg` in `setup-unraid.sh`. All sourced from their maintainers' public GitHub repositories.

| Plugin | GitHub | Maintainer |
|--------|--------|------------|
| Community Applications | [Squidly271/community.applications](https://github.com/Squidly271/community.applications) | Squidly271 |
| Fix Common Problems | [Squidly271/Fix-Common-Problems](https://github.com/Squidly271/Fix-Common-Problems) | Squidly271 |
| CA Appdata Backup | [Squidly271/ca.backup2](https://github.com/Squidly271/ca.backup2) | Squidly271 |
| User Scripts | [Squidly271/user.scripts](https://github.com/Squidly271/user.scripts) | Squidly271 |
| Unassigned Devices | [dlandon/unassigned.devices](https://github.com/dlandon/unassigned.devices) | dlandon |
| Compose Manager Plus | [mstrhakr/compose_plugin](https://github.com/mstrhakr/compose_plugin) | mstrhakr |
| Nvidia-Driver | [unraid/unraid-nvidia-driver](https://github.com/unraid/unraid-nvidia-driver) | Limetech (Unraid) |
| Dynamix File Integrity | [bergware/dynamix](https://github.com/bergware/dynamix) | bergware |

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
| `requests` | [pypi.org/project/requests](https://pypi.org/project/requests) | HTTP calls to *arr and Overseerr APIs |
| `plexapi` | [pypi.org/project/PlexAPI](https://pypi.org/project/PlexAPI) | Create Plex libraries, trigger scans |

`generate-configs.py` uses only Python stdlib (no pip dependencies).

---

## System Tools

Present on Unraid by default or installed as part of the driver plugin.

| Tool | Source | Used for |
|------|--------|----------|
| `docker` / `docker compose` | [Unraid built-in](https://docs.unraid.net/unraid-os/manual/docker-management/) | Container runtime |
| `racadm` | [Dell RACADM](https://www.dell.com/support/kbdoc/en-us/000178114) — bundled in iDRAC firmware, accessed remotely | Fan control via iDRAC |
| `nvidia-smi` | Nvidia — installed by ich777 plugin | GPU status and verification |
| `git` | [Unraid built-in](https://docs.unraid.net/unraid-os/manual/) | Cloning this repo |
| `python3` | Unraid built-in | Running setup scripts |
