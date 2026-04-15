# Deployment

Full stack deploys in a handful of commands after initial Unraid setup. Total hands-on time: ~15 minutes.

---

## Step 1 — Unraid setup

Run this from the Unraid terminal immediately after first boot — the array isn't started yet, so `/mnt/user/appdata` doesn't exist and there's nowhere to clone the repo yet. `setup-unraid.sh` bootstraps the shares and folder structure that make the later clone possible:

```bash
bash <(curl -s https://raw.githubusercontent.com/mihirsathe/homeserver/master/homeserver/scripts/setup-unraid.sh)
```

The script handles plugins, Docker settings, share settings, folder structure, and creates the `media_stack_update` + `media_stack_backup` User Scripts. When it finishes it prints the remaining manual steps.

Fan control is **not** provisioned by default — non-Dell GPUs sometimes make iDRAC over-spin the chassis fans, but whether that's actually an issue depends on your exact hardware. If the fans are loud after the GPU is installed, run `setup-fan-control.sh` separately. See [operations.md](operations.md#fan-noise-with-third-party-gpu).

---

## Step 2 — Manual steps that require human judgment

1. **Assign array disks** — verify drive serial numbers before assigning (Main tab)
   - Parity: 16TB HDD · Disk 1–4: 8TB HDDs · Cache: both 480GB SSDs
2. **Plug in UPS data cable** (skip if UPS is not yet physically installed — safe to add later) — USB-B end → UPS, USB-A end → any rear R640 USB port. `setup-unraid.sh` has already written `/boot/config/plugins/dynamix/ups.cfg` with `SERVICE=enable`, `CABLE=usb`, `BATTERYLEVEL=20`, `MINUTES=5`. After the reboot in sub-step 4 below, verify with `apcaccess status` — expect `STATUS : ONLINE` and a non-zero `BCHARGE` / `TIMELEFT`.
3. **Start array and format** — Main → Start → check format boxes → Format
4. **Reboot** — activates Nvidia-Driver (container toolkit is bundled, no second reboot)
5. **Verify GPU and container toolkit**:
   ```bash
   nvidia-smi
   docker run --rm --runtime=nvidia nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi
   nvidia-ctk --version   # must be >= 1.16.2 (closes CVE-2024-0132)
   ```
   If the container test fails: Apps → "nvidia container toolkit" → Install → restart Docker (Settings → Docker → toggle).
6. **Set User Script schedules** — Settings → User Scripts:
   - `media_stack_up` → At Startup of Array
   - `media_stack_update` → Monthly (1st, 3am)
   - `media_stack_backup` → Weekly (Sunday, 4am, after Appdata Backup)
   - `fan_control` → At Startup of Array *(only if you ran `setup-fan-control.sh`)*

---

## Step 3 — Network setup

Two pieces of network plumbing must exist before the stack comes up: a Tailscale tailnet for admin access, and a single router port-forward for Plex.

### 3a — Tailscale

1. Create a tailnet at [login.tailscale.com](https://login.tailscale.com/) if you don't already have one.
2. In the admin console → **Access controls**, add tags and an ACL roughly like:
   ```json
   {
     "tagOwners": {
       "tag:server": ["your-email@example.com"],
       "tag:admin":  ["your-email@example.com"]
     },
     "acls": [
       { "action": "accept",
         "src": ["tag:admin"],
         "dst": ["tag:server:80,443,5055,6767,7878,8080,8181,8686,8989,9696"] }
     ],
     "ssh": [
       { "action": "accept",
         "src": ["tag:admin"], "dst": ["tag:server"], "users": ["root"] }
     ]
   }
   ```
3. From the Unraid terminal:
   ```bash
   tailscale up --ssh --advertise-tags=tag:server
   ```
   Open the auth URL, sign in, confirm the tags. The Unraid host now has a stable `mediaserver.<tailnet>.ts.net` hostname (MagicDNS).
4. Install Tailscale on every admin device (laptop, phone). In the admin console, edit each device → add `tag:admin`.

After this, the *arr/SAB/Seerr/Unraid webUIs are reachable only from tagged admin devices.

### 3b — Router port-forward for Plex

On your home router:

- **TCP 32400** → `<server LAN IP>:32400`

That is the only forwarding rule. No UDP. No other ports. Everything else rides the tailnet.

### 3c — Mullvad account

1. Buy a Mullvad account at [mullvad.net](https://mullvad.net/) (Monero preferred). You'll receive a 16-digit account number — no email, no identifying info.
2. Mullvad account page → **WireGuard configuration** → generate and download a `.conf`.
3. Open the `.conf`. From `[Interface]`, copy `PrivateKey` and `Address` into `.env` as `VPN_PRIVATE_KEY` and `VPN_ADDRESS`. Set `VPN_CITY` to the city in the config filename (e.g., `Amsterdam`).

---

## Step 4 — Clone and configure

```bash
git clone https://github.com/mihirsathe/homeserver /mnt/user/appdata/homeserver
cd /mnt/user/appdata/homeserver/homeserver
cp .env.example .env
python3 scripts/generate-configs.py
```

`generate-configs.py` is interactive — prompts for any credentials not yet in `.env` (timezone, LAN IP, Mullvad keys, Usenet creds, indexer API keys), generates service API keys, writes all app config files, and creates the data directory structure.

> **Register Usenet and indexer accounts over Mullvad, not your home WAN.** Easiest path: install the Mullvad app on your laptop/phone, connect to any Mullvad exit, then sign up for the Usenet provider and indexers in a normal browser and save the credentials/API keys. Paste them into `.env` when `generate-configs.py` prompts. Once the provider has logged a home-IP connection against an account, that association can't be undone — do this before the stack is up, not after.

---

## Step 5 — Start the stack

Before running, grab a fresh claim token from `https://plex.tv/claim` and paste it into `.env` as `PLEX_CLAIM` — it expires in 4 minutes, so do this immediately before the command below.

```bash
docker compose --env-file .env --env-file generated.env up -d
```

Plex uses the claim token on first start to link the server to your account, then ignores it. `restart: unless-stopped` means containers restart automatically on all subsequent reboots. This command runs once, ever.

Wait ~60 seconds for all containers to initialise. Before proceeding, verify Gluetun's kill-switch works:

```bash
docker exec sabnzbd curl -s https://ifconfig.me        # should print a Mullvad exit IP
docker stop gluetun
docker exec sabnzbd curl -m 5 https://example.com      # should time out (kill-switch engaged)
docker start gluetun
```

---

## Step 6 — Bootstrap

```bash
python3 scripts/bootstrap.py
```

Waits for all services, wires the stack together via API, and creates Plex libraries. Prompts for a Plex token from Plex Web → Settings → General → Show.

**Hardware transcoding requires an active Plex Pass subscription.** The compose file and bootstrap flow pre-configure NVENC/NVDEC, but Plex refuses to enable them without a Pass account. If you see CPU transcoding after bootstrap despite the RTX 3050 being visible (`docker exec plex nvidia-smi`), the Plex account is almost certainly missing Pass.

Finally, open **Seerr** at `http://<server-ip>:5055`, sign in with your Plex account, and for every family member: Settings → Users → edit user → grant **Auto-Request**. That's what turns a Plex Watchlist addition into an automatic Radarr/Sonarr request. (This one is per-Plex-user and has no API equivalent.)

Tautulli's first-run wizard is pre-seeded by `bootstrap.py` — just open `http://<server-ip>:8181` and it's already bound to the Plex server with full history access.

### Profilarr first-run

Profilarr is the one stack component that isn't fully scripted — its subscription state lives in a SQLite DB configured via the web UI. Open `http://<server-ip>:6868` and:

1. **Add sync targets** — Settings → Instances → Add: Radarr (`http://radarr:7878/radarr`, API key from `generated.env` → `RADARR_API_KEY`) and Sonarr (`http://sonarr:8989/sonarr`, `SONARR_API_KEY`). The `automation` Docker network lets Profilarr reach both by service name.
2. **Link a database** — Databases → Add. The Dictionarry DB is the default curated source; TRaSH Guides can be linked alongside it. Do not also run Recyclarr against these *arrs — they will fight.
3. **Select profiles and custom formats**, review the diff preview, and sync. Subsequent syncs are initiated from the same UI whenever upstream updates.

Profilarr's `/config` is covered by the weekly Appdata Backup, so the subscriptions and selections survive a rebuild.

---

## Step 7 — Post-deploy hardening

1. **Unraid** → Settings → Management Access → disable Telnet and SSH password auth. Use Tailscale SSH (`tailscale up --ssh` from Step 3a) instead.
2. **Plex** → plex.tv → Account → Sign-in & Security → enable 2FA. Repeat for every account your library is shared with; this is not optional.
3. **iDRAC** → once the server has been stable for a few days, disable iDRAC entirely from the iDRAC webUI (Network → disable NIC) or next boot via Lifecycle Controller. Re-enable from BIOS F2 if ever needed.

---

## Rebuild From Scratch

1. `git clone https://github.com/mihirsathe/homeserver /mnt/user/appdata/homeserver`
2. `cd /mnt/user/appdata/homeserver/homeserver && cp .env.example .env`
3. `python3 scripts/generate-configs.py`
4. Grab a claim token from `https://plex.tv/claim`, paste into `.env` as `PLEX_CLAIM`, then immediately: `docker compose --env-file .env --env-file generated.env up -d`
5. `python3 scripts/bootstrap.py`
