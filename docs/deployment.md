# Deployment

Full stack deploys in a handful of commands after initial Unraid setup. Total hands-on time: ~15 minutes.

---

## Step 1 — Unraid setup

Run this from the Unraid terminal immediately after first boot:

```bash
bash <(curl -s https://raw.githubusercontent.com/mihirsathe/homeserver/master/homeserver/scripts/setup-unraid.sh)
```

Or if you've already cloned the repo:
```bash
bash /mnt/user/appdata/homeserver/homeserver/scripts/setup-unraid.sh
```

The script handles plugins, Docker settings, share settings, folder structure, and creates the `media_stack_update` + `media_stack_backup` User Scripts. When it finishes it prints the remaining manual steps.

Fan control is **not** provisioned by default — non-Dell GPUs sometimes make iDRAC over-spin the chassis fans, but whether that's actually an issue depends on your exact hardware. If the fans are loud after the GPU is installed, run `setup-fan-control.sh` separately. See [operations.md](operations.md#fan-noise-with-third-party-gpu).

---

## Step 2 — Manual steps that require human judgment

1. **Assign array disks** — verify drive serial numbers before assigning (Main tab)
   - Parity: 16TB HDD · Disk 1–4: 8TB HDDs · Cache: both 480GB SSDs
2. **Plug in UPS data cable** (skip if UPS is not yet physically installed — safe to add later) — USB-B end → UPS, USB-A end → any rear R640 USB port. `setup-unraid.sh` has already written `/boot/config/plugins/dynamix/ups.cfg` with `SERVICE=enable`, `CABLE=usb`, `BATTERYLEVEL=20`, `MINUTES=5`. After the step-4 reboot, verify with `apcaccess status` — expect `STATUS : ONLINE` and a non-zero `BCHARGE` / `TIMELEFT`.
3. **Start array and format** — Main → Start → check format boxes → Format
4. **Reboot** — activates Nvidia-Driver (container toolkit is bundled, no second reboot)
5. **Verify GPU**:
   ```bash
   nvidia-smi
   docker run --rm --runtime=nvidia nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi
   ```
   If the container test fails: Apps → "nvidia container toolkit" → Install → restart Docker (Settings → Docker → toggle)
6. **Set User Script schedules** — Settings → User Scripts:
   - `media_stack_update` → Monthly (1st, 3am)
   - `media_stack_backup` → Weekly (Sunday, 4am, after CA Appdata Backup)
   - `fan_control` → At Startup of Array *(only if you ran `setup-fan-control.sh`)*

---

## Step 3 — Clone and configure

```bash
git clone https://github.com/mihirsathe/homeserver /mnt/user/appdata/homeserver
cd /mnt/user/appdata/homeserver/homeserver
cp .env.example .env
python3 scripts/generate-configs.py
```

`generate-configs.py` is interactive — prompts for any credentials not yet in `.env`, generates API keys, writes all app config files, and creates the data directory structure.

---

## Step 4 — Start the stack

Before running, grab a fresh claim token from `https://plex.tv/claim` and paste it into `.env` as `PLEX_CLAIM` — it expires in 4 minutes, so do this immediately before the command below.

```bash
docker compose --env-file .env --env-file generated.env up -d
```

Plex uses the claim token on first start to link the server to your account, then ignores it. `restart: unless-stopped` means containers restart automatically on all subsequent reboots. This command runs once, ever.

Wait ~60 seconds for all containers to initialise.

---

## Step 5 — Bootstrap

```bash
python3 scripts/bootstrap.py
```

Waits for all services, wires the stack together via API, and creates Plex libraries. Prompts for a Plex token from Plex Web → Settings → General → Show.

**Hardware transcoding requires an active Plex Pass subscription.** The compose file and bootstrap flow pre-configure NVENC/NVDEC, but Plex refuses to enable them without a Pass account. If you see CPU transcoding after bootstrap despite the RTX 3050 being visible (`docker exec plex nvidia-smi`), the Plex account is almost certainly missing Pass.

Finally, open Tautulli at `http://<server-ip>:8181` and complete its one-time wizard — point it at the Plex server (same LAN IP, port 32400) and paste the token from the previous step.

---

## Rebuild From Scratch

1. `git clone https://github.com/mihirsathe/homeserver /mnt/user/appdata/homeserver`
2. `cd /mnt/user/appdata/homeserver/homeserver && cp .env.example .env`
3. `python3 scripts/generate-configs.py`
4. Grab a claim token from `https://plex.tv/claim`, paste into `.env` as `PLEX_CLAIM`, then immediately: `docker compose --env-file .env --env-file generated.env up -d`
5. `python3 scripts/bootstrap.py`
