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
   - Parity: 6TB HDD · Disk 1–4: 6TB HDDs · Cache: both 480GB SSDs
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
   - `media_stack_update` → Monthly (2nd, 3am — custom cron `0 3 2 * *`; the 1st is the parity check)
   - `media_stack_backup` → Weekly (Sunday, 5am — custom cron `0 5 * * 0`, an hour after the Appdata Backup plugin's 4am run so it never races the archive being written)
   - `fan_control` → At Startup of Array *(only if you ran `setup-fan-control.sh`)*

---

## Step 3 — Network setup

Two pieces of network plumbing must exist before the stack comes up: a Tailscale tailnet for admin access, and a single router port-forward for Plex.

### 3a — Tailscale

**One node joins the tailnet: the Unraid host itself.** There is no sidecar and
no reverse proxy. Every admin UI is published as a *Tailscale Service* —
`svc:radarr`, `svc:sonarr`, … — advertised by the host's own tailscaled, each
with its own TailVIP, MagicDNS name and auto-renewing certificate.

1. Create a tailnet at [login.tailscale.com](https://login.tailscale.com/) if you don't already have one.
2. **Enable HTTPS certificates**: admin console → **DNS** → enable MagicDNS,
   then enable HTTPS. Certificates cannot be issued without this, and every
   admin URL depends on them.
3. In the admin console → **Access controls**, add tags, an ACL, and an
   auto-approver so service advertisements from the host are accepted without
   a manual click each time:
   ```json
   {
     "tagOwners": {
       "tag:server": ["your-email@example.com"],
       "tag:admin":  ["your-email@example.com"]
     },
     "acls": [
       { "action": "accept",
         "src": ["tag:admin"],
         "dst": ["tag:server:443,32400"] }
     ],
     "ssh": [
       { "action": "accept",
         "src": ["tag:admin"], "dst": ["tag:server"], "users": ["root"] }
     ]
   }
   ```
   Note the destination port is now `443`, not `80,32400,53` — services are
   HTTPS, and `53` is gone with AdGuard.
4. From the Unraid terminal:
   ```bash
   tailscale up --ssh --advertise-tags=tag:server
   ```
   Open the auth URL, sign in, confirm the tags. The host now has a stable
   MagicDNS name.
5. Install Tailscale on every admin device (laptop, phone). In the admin
   console, edit each device → add `tag:admin`.

**No auth key is needed.** The old `TS_AUTHKEY` existed solely to log the
`ts-caddy` sidecar in; with the sidecar gone, the host daemon is already
authenticated and nothing else joins the tailnet.

**There is no split-DNS rule and no `*.lan` domain.** MagicDNS resolves service
names directly, and on most platforms it puts the tailnet domain in the DNS
search path, so bare `https://radarr/` works as well as the fully-qualified
name.

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

### 5a — Start the stack

There is no sidecar to bring up first and no address to learn — that whole
dance existed to discover `CADDY_TAILNET_IP` for AdGuard's wildcard, and both
are gone. Start everything in one go.

### 5b — Verify containers are healthy

Before running, grab a fresh claim token from `https://plex.tv/claim` and paste it into `.env` as `PLEX_CLAIM` — it expires in 4 minutes, so do this immediately before the command below.

```bash
docker compose --env-file .env.docker up -d
```

`.env.docker` is the merged file (`.env` + `generated.env`) that `generate-configs.py` writes — using it as a single env-file avoids `--env-file` precedence quirks that can blank out `${STACK_DIR}` and break every config bind mount.

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

**Hardware transcoding requires an active Plex Pass subscription.** `bootstrap.py` turns NVENC/NVDEC on via Plex's `/:/prefs` API, but Plex ignores the setting at playback without a Pass account. If you see CPU transcoding after bootstrap despite the RTX 3050 being visible (`docker exec plex nvidia-smi`), check in this order: (1) `bootstrap.py` printed `✓ Plex: applied N server preferences`, (2) Settings → Transcoder shows hardware acceleration ticked, (3) the account has Plex Pass. Before this was fixed the answer was almost always (1) — the preferences were set by environment variables the image ignores.

Finally, open **Seerr** at `https://seerr.<tailnet>.ts.net/`, sign in with your Plex account, and finish its first-run flow by hand — Seerr is the one service `bootstrap.py` does not wire:

- **Settings → Services**: add Radarr (hostname `radarr`, port `7878`) and Sonarr (hostname `sonarr`, port `8989`) with their API keys from `.env.docker`, and leave **Base URL empty** — the *arrs serve at root. A wrong Base URL is the quiet failure here: the *arrs answer any unknown path with their web page as HTTP 200, so it stays invisible until a request fails. `verify-stack.sh` (**Seerr wiring**) proves the finished link.
- **Settings → Users**: for every family member, edit user → grant **Auto-Request**. That's what turns a Plex Watchlist addition into an automatic Radarr/Sonarr request. (This one is per-Plex-user and has no API equivalent.)

Tautulli's first-run wizard is pre-seeded by `bootstrap.py` — just open `https://tautulli.<tailnet>.ts.net/` and it's already bound to the Plex server with full history access.

### Profilarr first-run

Profilarr is the one stack component that isn't fully scripted — its subscription state lives in a SQLite DB configured via the web UI. Open `https://profilarr.<tailnet>.ts.net/` and:

1. **Add sync targets** — Settings → Instances → Add: Radarr (`http://radarr:7878`, API key from `generated.env` → `RADARR_API_KEY`) and Sonarr (`http://sonarr:8989`, `SONARR_API_KEY`). The `automation` Docker network lets Profilarr reach both by service name. Note: these are *internal* container-to-container URLs, not the `svc:radarr` form — Tailscale Services front the tailnet side only and sit nowhere between containers on the same docker network.
2. **Link a database** — Databases → Add. The Dictionarry DB is the default curated source; TRaSH Guides can be linked alongside it. Do not also run Recyclarr against these *arrs — they will fight.
3. **Select profiles and custom formats**, review the diff preview, and sync. Subsequent syncs are initiated from the same UI whenever upstream updates.

Profilarr's `/config` is covered by the weekly Appdata Backup, so the subscriptions and selections survive a rebuild.

### Local AI first-run

Ollama starts with an empty model store. Pull a model from the Unraid terminal:

```bash
docker exec ollama ollama pull llama3.2:3b
docker exec ollama ollama list
```

Keep models under ~4 GB so they coexist with a Plex transcode on the 6 GB card; [software.md](software.md#model-sizing) has sizing guidance.

Verify it works:

```bash
# From the host
curl -s http://127.0.0.1:11434/api/generate \
     -d '{"model":"llama3.2:3b","prompt":"say hi","stream":false}'

# From a container on the `ai` network — this is how consumers reach it
docker run --rm --network ai curlimages/curl -s http://ollama:11434/api/tags
```

**Exclude the model store from backups.** Appdata Backup → Settings → add `/mnt/user/appdata/ollama` to the exclusion list. Model blobs are multi-GB and re-pullable in minutes; including them grows every weekly archive by tens of GB for no recovery value.

**Attaching an AI app.** Nothing reaches Ollama by default — access is opt-in per container. For a service in this Compose file, add `ai` to its `networks:` list. For a container installed from Community Applications, Docker tab → Edit → **Network Type** → `ai` (the network appears in that dropdown once the stack has been up once, because it's declared `name: ai` rather than taking Compose's project prefix). Point the app at `http://ollama:11434`, and verify from inside it:

```bash
docker exec <container> curl -fsS http://ollama:11434/api/tags
```

Note that Ollama has **no authentication** — anything on the `ai` network can also delete models. That network is isolated from the media planes and nothing outside the host can reach it (no Tailscale Service, no `0.0.0.0` bind), but it's why access is opt-in rather than stack-wide.

### Nextcloud first-run

> **Status (2026-08-29): deployed** — all four containers are up and Nextcloud reports installed (v33), with appdata correctly owned by uid 33/70. Remaining: `svc:nextcloud` is not yet published (`scripts/sync-tailscale-services.py`), and `BACKUP_NEXTCLOUD_REMOTE` is still unset — **do not put real files in until the offsite target exists.**

Nextcloud installs itself — there is no wizard. `generate-configs.py` generated the
database, Redis and admin passwords into `generated.env`, and the container consumed them
on first start.

```bash
grep ^NEXTCLOUD_ADMIN_PASSWORD= generated.env
```

Log in at `https://nextcloud.<tailnet>.ts.net/` as `admin` (or whatever
`NEXTCLOUD_ADMIN_USER` is set to) once Step 6.5 has published `svc:nextcloud`.

**Then check Administration settings → Overview.** Nextcloud's own security-and-setup
warnings are the fastest way to confirm the reverse-proxy plumbing is right, and four
specific results are what you want:

| Expected | What it proves |
|----------|----------------|
| No "untrusted domain" — the page loads at all | `NEXTCLOUD_TRUSTED_DOMAINS` matched the Service name |
| No reverse-proxy / `X-Forwarded-For` warning | `TRUSTED_PROXIES` is right, so rate limiting sees real client IPs |
| No `.well-known` CalDAV/CardDAV warning | The image's Apache rules are intact — calendar and contacts will work |
| No "background jobs have not run" | `nextcloud-cron` is alive. Allow one 15-minute cycle before judging this |

If the page renders as `http://` links or mixed-content-blocks, that is `OVERWRITEPROTOCOL`
— see [troubleshooting.md](troubleshooting.md).

**Set the offsite backup target before you put real files in it.** `BACKUP_NEXTCLOUD_REMOTE`
in `.env` is the *only* backup these files get; the Appdata Backup plugin covers
`/mnt/user/appdata` and Nextcloud's user files are not in it.

```bash
rclone config                                   # if you have not already
# .env:  BACKUP_NEXTCLOUD_REMOTE=b2:my-bucket/nextcloud
bash scripts/backup-appdata.sh                  # run once by hand to prove it works
docker exec -u www-data nextcloud php occ status # maintenance: false — the trap cleared it
```

Finally, install the desktop and mobile clients and point them at
`https://nextcloud.<tailnet>.ts.net`. They need Tailscale running on that device to sync —
that is the accepted cost of not publishing it.

---

## Step 6.5 — Publish the Tailscale Services

This replaces what used to be split-DNS + Caddy vhosts + an AdGuard wildcard.

Each admin UI becomes a Tailscale Service advertised by the host's tailscaled,
pointing at the loopback port the container already publishes. Those loopback
publishes are not debug leftovers — they are the serve backends.

### Define the services in the admin console first

A Tailscale Service is an object that must exist in the tailnet before a host
can advertise it. Admin console → **Services** → create one per admin UI, named
for the service (`radarr` → `svc:radarr`). If the page is missing from the
sidebar, look under **Settings → Feature previews**; Services is in public beta.

Skipping this does not produce a useful error. The host reports that admin
approval is required, and the console shows nothing to approve — because the
object the advertisement would attach to does not exist.

### Then do one service

The syntax is worth confirming on a single service before batching the rest:

```bash
tailscale serve --service=svc:radarr --bg 127.0.0.1:7878
tailscale serve status
```

Then open `https://radarr.<tailnet>.ts.net/` from a tagged admin device. A
padlock with no warning means the certificate provisioned correctly — that is
the whole point of the change, so do not move on until you see it.

### Then the rest

| Service | Backend |
|---------|---------|
| `svc:radarr` | `127.0.0.1:7878` |
| `svc:sonarr` | `127.0.0.1:8989` |
| `svc:lidarr` | `127.0.0.1:8686` |
| `svc:prowlarr` | `127.0.0.1:9696` (via gluetun) |
| `svc:sab` | `127.0.0.1:8080` (via gluetun) |
| `svc:bazarr` | `127.0.0.1:6767` |
| `svc:seerr` | `127.0.0.1:5055` |
| `svc:tautulli` | `127.0.0.1:8181` |
| `svc:profilarr` | `127.0.0.1:6868` |
| `svc:actual` | `127.0.0.1:5006` |
| `svc:coach` | `127.0.0.1:8000` |
| `svc:nextcloud` | `127.0.0.1:8081` |

`svc:nextcloud` is the one entry whose *name* matters beyond routing: it has to match the
trusted domain Nextcloud baked in at install time. Rename it and Nextcloud answers
`400 untrusted domain` — the route works, the app refuses. See
[troubleshooting.md](troubleshooting.md).

Plex is deliberately absent — it keeps its own port, its own auth and its own
`*.plex.direct` certificates. Ollama is absent too: it has no authentication,
so its access control is membership of the `ai` network, and nothing on the
tailnet has a reason to reach it.

### If a service says "needs configuration" or never goes active

Host approval is the usual cause, and it is expected: auto-approval is not
configured, because `autoApprovers` is documented for `routes` and `exitNode`
and a `services` key is not something this repo has verified. Approve the host in
admin console → **Services** → select the service → **Service hosts** →
**Approve**.

Tailscale Services is in public beta and the daemon has a known issue where it
does not always pick up an approval that arrives after the advertisement. If a
service is approved in the console but still inactive:

> ⚠️ **Never run this over a Tailscale SSH session.** `tailscale down` drops the
> tunnel your shell is running through, the shell dies before `tailscale up`
> executes, and the machine is left off the tailnet with no remote way back in.
> If your only route to the box is Tailscale, you will need someone physically
> on the LAN to recover it. Run it from the **Unraid web terminal over the
> LAN**, from **iDRAC's virtual console**, or from a **LAN SSH session** — and
> use `;` rather than `&&` so `up` still fires if the shell is killed mid-command.

**Try the cheap fix first**, which touches nothing and cannot disconnect you —
re-issue the advertisement after approving the host:

```bash
tailscale serve --service=svc:<name> --bg 127.0.0.1:<port>
```

Only if that fails, and only from a non-Tailscale console:

```bash
tailscale down ; tailscale up --ssh --advertise-tags=tag:server
```

### The Unraid GUI stays off all of this on purpose

The GUI keeps the host's `:80` and is never fronted by anything. On Unraid,
**stopping the array stops Docker** — Docker's data root is a directory on
the cache pool at `/var/lib/docker` — so any admin path that depends on a container is
unavailable in exactly the situations where you most need a way in. The GUI at
`http://<server-name>/` and Tailscale SSH are the two paths that survive
everything, which is why neither is behind a proxy or a container.

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
4. Grab a claim token from `https://plex.tv/claim`, paste into `.env` as `PLEX_CLAIM`, then immediately: `docker compose --env-file .env.docker up -d`
5. `python3 scripts/bootstrap.py`
