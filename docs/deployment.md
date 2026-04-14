# Deployment

Full stack deploys in three commands after prerequisites are met. Total hands-on time: ~15 minutes.

---

## Prerequisites

Install these Unraid plugins before deploying (Community Applications → search by name):

1. **Compose Manager Plus** — Docker Compose support
2. **Nvidia-Driver** — reboot after installing
3. **nvidia-container-toolkit** — reboot after installing
4. **User Scripts** — for scheduled maintenance and fan control

Verify the GPU is visible before continuing:
```bash
docker run --rm --runtime=nvidia nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi
```

Array must be started and `/mnt/user/data` and `/mnt/user/appdata` shares must exist.

---

## Step 1 — Clone the repo onto the server

```bash
cd /mnt/user/appdata
git clone https://github.com/YOUR_USERNAME/homeserver-repo.git
cd homeserver-repo/homeserver
```

---

## Step 2 — Create your .env

```bash
cp .env.example .env
nano .env
```

Have ready before you start:
- Five UUIDs for API keys: `cat /proc/sys/kernel/random/uuid` (run five times)
- Usenet provider hostname, username, password
- NZBGeek and NZBPlanet API keys (from each site's account page)
- Cloudflare tunnel token (Zero Trust → Networks → Tunnels → your tunnel → Configure → Token)
- Server LAN IP (shown in Unraid UI, top-right corner)
- LAN subnet (`ip route | grep default` on any device on the network)

**Get your Plex claim token last** — it expires in 4 minutes:
`https://www.plex.tv/claim`

---

## Step 3 — Generate config files

```bash
python3 scripts/generate-configs.py
```

Reads `.env`, writes all app config files to `configs/`. Takes ~2 seconds. This pre-seeds each app's config so no setup wizard is required on first boot:

| App | Config written | What it pre-configures |
|-----|---------------|------------------------|
| SABnzbd | `sabnzbd.ini` | Skips setup wizard entirely |
| Radarr / Sonarr / Lidarr / Prowlarr | `config.xml` | API key, port, URL base, auth off |
| Bazarr | `config.ini` | Sonarr + Radarr connections pre-wired |
| Overseerr | `settings.json` | General settings pre-seeded |

---

## Step 4 — Create data directory structure

```bash
mkdir -p /mnt/user/data/{usenet/{incomplete,complete/{movies,tv,music}},media/{movies,tv,music}}
mkdir -p /mnt/user/appdata/plex-transcode
chown -R nobody:users /mnt/user/data/
```

---

## Step 5 — Register the stack with Compose Manager Plus

In the Unraid web UI:

1. Docker tab → scroll to bottom → Compose section
2. **Add Stack** → name it `media-stack`
3. The plugin detects `docker-compose.yml` in the directory
4. Set `.env` file path to `/mnt/user/appdata/homeserver-repo/homeserver/.env`
5. Enable **Autostart**
6. Click **Compose Up**

Or from the terminal:
```bash
docker compose -f /mnt/user/appdata/homeserver-repo/homeserver/docker-compose.yml \
  --env-file /mnt/user/appdata/homeserver-repo/homeserver/.env up -d
```

Wait ~60 seconds for all containers to initialise.

---

## Step 6 — Bootstrap: wire everything together

```bash
python3 scripts/bootstrap.py
```

This is idempotent — safe to re-run. It:
- Waits for all services to respond
- Sets root folders in Radarr, Sonarr, Lidarr
- Connects SABnzbd as download client in each *arr
- Enables hardlinks in media management settings
- Adds NZBGeek and NZBPlanet indexers to Prowlarr
- Connects Radarr, Sonarr, Lidarr to Prowlarr and triggers a full sync
- Creates Plex libraries (requires `PLEX_TOKEN` — see Step 7)

Note: `bootstrap.py` installs its Python dependencies (`requests`, `plexapi`) to `/tmp/bootstrap-deps` on every run. Unraid runs in RAM — pip-installed packages don't persist across reboots. This is intentional.

---

## Step 7 — Add Plex token and re-run bootstrap

After Plex first boots:

1. Open `http://YOUR_SERVER_IP:32400/web`
2. Sign in with your Plex account
3. Settings → General → scroll to bottom → click **Show** next to "Plex Media Server"
4. Copy the `X-Plex-Token` value
5. Add `PLEX_TOKEN=<your_token>` to `.env`
6. Re-run: `python3 scripts/bootstrap.py`

---

## Step 8 — Enable hardware transcoding in Plex (manual only)

This cannot be done via API. Requires Plex Pass.

Settings → Transcoder → **Use hardware acceleration when available** → select **NVIDIA GeForce RTX 3050** → Save

---

## Scheduled Maintenance (User Scripts)

Create these in Unraid: Settings → User Scripts → Add New Script.

### Fan control — runs at every array start

Required because the R640 ramps fans to full speed when it detects the non-Dell RTX 3050. This script suppresses that.

**Schedule:** At Startup of Array
```bash
#!/bin/bash
IDRAC_IP="YOUR_IDRAC_IP"
IDRAC_USER="YOUR_IDRAC_USER"
IDRAC_PASS="YOUR_IDRAC_PASS"
sleep 30
racadm -r $IDRAC_IP -u $IDRAC_USER -p $IDRAC_PASS set system.thermalsettings.ThirdPartyPCIFanResponse 0
racadm -r $IDRAC_IP -u $IDRAC_USER -p $IDRAC_PASS set system.thermalsettings.ThermalProfile 2
racadm -r $IDRAC_IP -u $IDRAC_USER -p $IDRAC_PASS set system.thermalsettings.FanSpeedOffset 255
```

If an iDRAC firmware update resets these settings, the per-slot LFM approach (`System.PCIESlotLFM.N.LFMMode 2`) is the fallback.

### Monthly stack update

**Schedule:** Monthly, 1st, 3am
```bash
#!/bin/bash
bash /mnt/user/appdata/homeserver-repo/homeserver/scripts/update-stack.sh
```

Note: `update-stack.sh` uses `/usr/bin/docker` explicitly (full path) because cron jobs on Unraid may not have the same `PATH` as an interactive shell.

---

## Rebuild From Scratch

1. Clone repo to `/mnt/user/appdata/homeserver-repo`
2. `cp .env.example .env` → fill in all values
3. `python3 scripts/generate-configs.py`
4. Create data directories (Step 4)
5. Register and start stack in Compose Manager Plus (Step 5)
6. `python3 scripts/bootstrap.py`
7. Add `PLEX_TOKEN` to `.env` → re-run bootstrap
8. Enable hardware transcoding in Plex UI (Step 8)
