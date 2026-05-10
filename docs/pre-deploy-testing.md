# Pre-Deploy Test Plan

*One-shot artifact. Not linked from nav. Delete after the real server is up.*

---

## Context

You have an Ubuntu LTS desktop with an NVIDIA GPU. Before racking the R640 you can exercise **everything in this repo that is not Unraid-plugin-specific or hardware-specific** — which turns out to be most of it:

| Tested here | Needs the real server |
|-------------|-----------------------|
| docker-compose.yml end-to-end | Unraid OS + plugins (CA Backup, Fix Common Problems, Nvidia-Driver plugin, User Scripts, Tailscale) |
| NVIDIA + NVENC passthrough to Plex | PERC H730P HBA mode + SMART passthrough |
| Inter-container DNS on `downloaders` / `frontend` / `automation` | MD1400 SAS enumeration, BOSS ZFS mirror, parity rebuild behaviour |
| Hardlink behaviour across `/data` | `/mnt/user/...` as a real Unraid share (we fake it with a bindmount) |
| generate-configs.py + bootstrap.py | iDRAC / fan control (setup-fan-control.sh) |
| backup-appdata.sh + restore-appdata.sh | setup-unraid.sh (plugin install/config) |
| update-stack.sh (incl. health gate + rollback) | |
| Gluetun + Mullvad WireGuard kill-switch behaviour | |
| Profilarr UI reachability on :6868 and auth to Radarr/Sonarr | Tailscale mesh VPN to the live tailnet |
| Diagram rendering (SVG + mingrammer PNG) | |
| Zensical doc site build | |

**Philosophy:** if a step here succeeds, the same command on the R640 should succeed. The Unraid layer underneath is just a Docker host.

---

## 0 · Ubuntu prep

```bash
# Docker Engine + Compose plugin (official Docker repo, not apt's ancient docker.io)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
newgrp docker

# NVIDIA container toolkit (assumes the proprietary driver is already installed + nvidia-smi works)
distribution=$(. /etc/os-release && echo "$ID$VERSION_ID")
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Everything else
sudo apt install -y python3-pip python3-venv graphviz shellcheck yamllint jq ffmpeg rclone

# Repo
git clone https://github.com/<you>/homeserver ~/homeserver
cd ~/homeserver
```

**Exit criteria**

```bash
docker run --rm --runtime=nvidia --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

must show the GPU. If it doesn't, stop here — none of the Plex tests will work.

---

## 1 · Static analysis (no runtime)

Catch obvious breakage before spending time on container startup.

```bash
cd ~/homeserver

# YAML + compose schema + env-var substitution
(cd homeserver && cp .env.example .env.test && docker compose --env-file .env.test config > /dev/null && rm .env.test)

# Shell scripts
shellcheck homeserver/scripts/*.sh

# Python scripts: syntax-only check
python3 -m py_compile homeserver/scripts/generate-configs.py homeserver/scripts/bootstrap.py

# Help output — catches argparse breakage
python3 homeserver/scripts/generate-configs.py --help
python3 homeserver/scripts/bootstrap.py --help

# YAML style (advisory; some warnings expected)
yamllint homeserver/docker-compose.yml || true
```

**Exit criteria** — `docker compose config` exits 0 and emits a fully-resolved compose document. Shellcheck exits 0 (or you triage each warning and decide to ignore). Both `--help` invocations print usage without traceback.

---

## 2 · Diagrams

### 2a · SVG diagrams (visual review only)

Open [docs/assets/rack.svg](assets/rack.svg) and [docs/assets/storage.svg](assets/storage.svg) in a browser. Confirm:

- Rack: 15U scale reads left-edge; cable endpoints touch the chassis, not the rack frame; BOSS-S1 card visible as 2 grey M.2 blocks inside the U10 R640; LAN + iDRAC on one cable; Cat6A/SFF-8644/C13 labels legible.
- Storage: single Dell R640 box contains both the 8-bay front strip AND the BOSS M.2 pair as subsections; three pool boxes align pixel-perfect with their physical sources; share pills render in monospace.

### 2b · Mingrammer diagrams (render + review)

```bash
pip install --user diagrams
cd docs/assets/diagrams
python3 docker-stack.py
python3 external-access.py
ls -l ../docker-stack.png ../external-access.png
```

Open both PNGs. Confirm:

- **docker-stack.png**: Viewer → Seerr → *arr cluster → Prowlarr / SABnzbd → Gluetun → (dashed) Usenet. `/data/usenet` → `/data/media` hardlink arrow. Plex → Viewer stream arrow. All product logos render (plex, radarr, sonarr, lidarr, prowlarr, sabnzbd, gluetun, bazarr, tautulli; Seerr, Profilarr + Usenet may fall back to a generic icon).
- **external-access.png**: single open port (TCP 32400 → Plex) on the router. Tailscale mesh reaches `tag:server` with all admin UIs behind it. Gluetun has a dashed outbound arrow to Mullvad; SAB and Prowlarr share Gluetun's netns. Home WAN IP is explicitly annotated as published to `plex.tv` for direct-connect.

If the mingrammer output has layout weirdness, tweak `ranksep`/`nodesep` in the graph_attr dict at the top of each script.

---

## 3 · Doc site build (Zensical)

```bash
pip install --user zensical
zensical build
python3 -m http.server --directory site 8000
```

Open `http://localhost:8000` and click through every page. Confirm:

- Left nav lists all pages including `disaster-recovery.md` and `troubleshooting.md`.
- Mermaid blocks in `docs/diagrams-drafts.md` and any other pages render as SVG (not as code blocks).
- `rack.svg`, `storage.svg`, and the two mingrammer PNGs load on their host pages.
- Internal links (`decisions.md#expansion-paths`, `operations.md#fan-noise...`) resolve.
- Dark/light mode toggle, if the theme supports it, renders diagrams correctly in both.

**Stop the server with Ctrl-C.** Known issue: Zensical will emit a warning for any `.md` that isn't in `nav` but is otherwise valid — expected for `pre-deploy-testing.md` (this file) and `diagrams-drafts.md`.

---

## 4 · Stack sandbox setup

The compose file hardcodes `/mnt/user/...` paths. On Ubuntu we fake that share with a bindmount-friendly tree and override `PUID`/`PGID` to match your Ubuntu user.

```bash
# Fake Unraid share root. usenet-incomplete is its own share on the real server
# (cache-only); here it's just another directory under /mnt/user.
sudo mkdir -p /mnt/user/{appdata,usenet-incomplete,data/{usenet/complete/{movies,tv,music},media/{movies,tv,music}},backups/appdata}
sudo chown -R "$USER:$USER" /mnt/user

# Point STACK_DIR at the repo checkout instead of /mnt/user/appdata/homeserver
export STACK_DIR="$HOME/homeserver/homeserver"
```

Fill out `.env` with sandbox-safe values:

```bash
cd ~/homeserver/homeserver
cp .env.example .env
```

| Var | Sandbox value | Why |
|-----|---------------|-----|
| `PUID` / `PGID` | `$(id -u)` / `$(id -g)` | Match your Ubuntu user; the hotio images drop privileges |
| `TZ` | your timezone | |
| `VPN_PRIVATE_KEY` / `VPN_ADDRESS` | real Mullvad WireGuard values | Gluetun crashes on stubs and takes SAB + Prowlarr down with it |
| `VPN_CITY` | `Amsterdam` (or nearest to your provider) | |
| `USENET_*` | real trial account or leave blank | SAB starts either way; connection will fail cleanly if stubbed |
| `NZBGEEK_API_KEY`, `NZBPLANET_API_KEY` | real keys OR `TEST_KEY_PLACEHOLDER` | Prowlarr indexer add will 401 on stubs — that's fine |
| `PLEX_LAN_IP` | your Ubuntu host IP (`ip -4 a`) | |
| `PLEX_LAN_SUBNET` | e.g. `192.168.1.0/24` | |
| `PLEX_CLAIM` | fresh token from https://plex.tv/claim | Grab right before `docker compose up` |

Then generate the config files:

```bash
python3 scripts/generate-configs.py
```

**Exit criteria** — `/mnt/user/appdata/` subdirs populated (`sabnzbd/`, `prowlarr/`, `radarr/`, `sonarr/`, `lidarr/`, `seerr/`, `profilarr/`, `tautulli/`, `bazarr/`, `gluetun/`), `generated.env` exists. `/mnt/user/data/` and `/mnt/user/usenet-incomplete/` are present.

---

## 5 · Stack up

```bash
cd ~/homeserver/homeserver
docker compose --env-file .env.docker up -d
watch -n 2 'docker compose ps'
```

Wait until every service reaches `(healthy)`. Allow up to 3 minutes — Plex healthcheck has a 120s start_period, and Gluetun may restart once while the Mullvad handshake lands.

**Per-service sanity**

All backend ports are bound to host loopback (`127.0.0.1:`) — direct probes
must run *on the Unraid host*, not from a tailnet device. UrlBases are
stripped so each app serves at root.

```bash
curl -fsS http://localhost:8080/api?mode=version
curl -fsS http://localhost:9696/ping
curl -fsS http://localhost:7878/ping
curl -fsS http://localhost:8989/ping
curl -fsS http://localhost:8686/ping
curl -fsS http://localhost:5055/api/v1/status | jq .
curl -fsS http://localhost:8181/status
curl -fsS http://localhost:6767/
curl -fsS http://localhost:32400/identity | head -c 200
```

**Through Caddy** (from any device with the `docs/CADDY_HOSTS.txt` entries
pasted into `/etc/hosts`)

```bash
for svc in radarr sonarr lidarr prowlarr sab seerr bazarr tautulli profilarr; do
  printf "%-12s " "$svc"
  curl -fsS -o /dev/null -w "%{http_code}\n" "http://${svc}.lan/"
done
```

**Inter-container DNS** (across the `downloaders` / `automation` / `frontend` networks)

```bash
# radarr shares `downloaders` with gluetun (which owns SAB's netns —
# 'sabnzbd' as a docker DNS name does not resolve, only 'gluetun' does).
docker exec radarr curl -fsS http://gluetun:8080/api?mode=version

# seerr shares `frontend` with plex
docker exec seerr wget -qO- http://plex:32400/identity | head -c 200
```

If these fail: check `docker network inspect downloaders automation frontend` and `docker compose logs <svc>`.

---

## 6 · GPU + NVENC

### 6a · GPU visible to Plex

```bash
docker exec plex nvidia-smi
```

Expected: RTX 3050 listed, drivers match host, no errors. Your desktop GPU substitutes here — the real R640 will show the 3050 specifically.

### 6b · Transcode probe

Seed a deliberately-transcode-requiring file (high-bitrate source, client will need to downconvert):

```bash
# ~30s 1080p test clip with complexity that forces a transcode at 4M target
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=60 -f lavfi -i sine=frequency=440:duration=30 \
  -t 30 -c:v libx264 -preset veryfast -b:v 20M -c:a aac /mnt/user/data/media/movies/Test/test.mp4
```

In Plex Web, add `/data/media` as a Movies library (it's already mounted as read-only). Wait for scan, play the clip, **force a lower quality** (e.g. 2 Mbps 720p) in the client.

Watch encode activity on the host:

```bash
nvidia-smi dmon -s u
```

Expected — `enc` column rises above 0 during playback, returns to 0 on stop. Plex log line should contain `(hw)`:

```bash
docker logs plex 2>&1 | grep -i 'transcode\|nvenc' | tail
```

### 6c · Concurrent session stress (optional)

Open 6-10 playback sessions from different clients / devtools tabs, each forced to transcode. The RTX 3050 is rated for 12 concurrent NVENC sessions — you should see all 10 encode simultaneously with no "insufficient resources" errors from NVENC.

---

## 7 · Hardlink behaviour across `/data`

The whole reason every container mounts `/mnt/user/data` at `/data`: SAB's completed download and Radarr's imported file need to occupy the same disk blocks. Verify directly:

```bash
# Drop a file in usenet/complete/
echo "hello" > /mnt/user/data/usenet/complete/movies/test.txt

# Hardlink it into media/ from *inside* the radarr container
docker exec radarr ln /data/usenet/complete/movies/test.txt /data/media/movies/test.txt

# Check link count (should be 2) and confirm same inode
stat -c 'inode=%i links=%h  %n' /mnt/user/data/usenet/complete/movies/test.txt /mnt/user/data/media/movies/test.txt
```

Expected: same inode, `links=2`. If `links=1`, the mount layout is wrong — likely two separate bindmounts instead of one `/data` bindmount.

---

## 8 · External access (Plex port-forward + Tailscale admin plane)

Two properties to verify: (a) Plex is reachable from outside on exactly one port, and (b) the admin plane is reachable only via Tailscale.

**(a) Plex port-forward.** From a phone on LTE (no home WiFi):

```bash
# identity endpoint should respond over the router's WAN IP
curl -fsS https://<wan-ip>:32400/identity | head -c 200
```

Expected: a `MediaContainer` XML identity blob. If it times out, the router port-forward 32400 → R640 LAN IP isn't in place (or the ISP is blocking inbound 32400).

**(b) Tailscale admin plane.** On an admin device on the tailnet (and *only* on the tailnet), with `docs/CADDY_HOSTS.txt` entries pasted into `/etc/hosts`:

```bash
# Each admin UI should respond through Caddy on :80
curl -fsS http://radarr.lan/ping
curl -fsS http://sonarr.lan/ping
curl -fsS http://prowlarr.lan/ping
curl -fsS http://sab.lan/api?mode=version
curl -fsS http://seerr.lan/api/v1/status | jq .
```

All should succeed. Then drop off the tailnet (`tailscale down` or disable the client) and repeat — every one should fail. That's the point: admin services are tailnet-only.

**Boundary property check** — backend ports must NOT be externally reachable. From a tailnet device that is *not* the Unraid host:

```bash
# Direct backend ports must time out / refuse — only :80 (Caddy) and :32400 (Plex) listen on a non-loopback interface.
for p in 5055 6767 6868 7878 8080 8181 8686 8989 9696; do
  printf "%-5s " "$p"
  timeout 3 bash -c "</dev/tcp/<unraid-tailnet-ip>/$p" 2>&1 | head -c 60
  echo
done
# Expect every line to say "Connection refused" or hang+timeout.
```

On the Unraid host itself:

```bash
# Only :80 and :32400 should be bound to non-loopback addresses.
sudo ss -tlnp | grep -v 127.0.0.1
```

Expect to see `:80` (caddy) and `:32400` (plex) on `0.0.0.0` or `*`; everything else should be either absent or bound to `127.0.0.1`. Tailscale's socket appears too; its listener binds to the tailnet interface.

---

## 9 · Bootstrap

Once stack is healthy and you've obtained `PLEX_TOKEN` (Plex Web → Settings → Account → show token, or parse from `Preferences.xml`):

```bash
python3 scripts/bootstrap.py
```

Expected post-run state, checked via each app's API:

```bash
# Radarr has a root folder at /data/media/movies and SABnzbd as a download client
curl -fsS -H "X-Api-Key: $(grep RADARR_API_KEY generated.env | cut -d= -f2)" \
  http://localhost:7878/api/v3/rootfolder | jq '.[].path'
curl -fsS -H "X-Api-Key: $(grep RADARR_API_KEY generated.env | cut -d= -f2)" \
  http://localhost:7878/api/v3/downloadclient | jq '.[] | {name, host}'

# Prowlarr has the two indexers (will show connection errors with stub API keys — expected)
curl -fsS -H "X-Api-Key: $(grep PROWLARR_API_KEY generated.env | cut -d= -f2)" \
  http://localhost:9696/api/v1/indexer | jq '.[].name'

# Plex has Movies/TV/Music libraries
curl -fsS "http://localhost:32400/library/sections?X-Plex-Token=$(grep PLEX_TOKEN generated.env | cut -d= -f2)" \
  | grep -oE 'title="[^"]+"'
```

Re-run `bootstrap.py` — it must be idempotent (no duplicate indexers, no duplicate download clients, no duplicate libraries).

---

## 10 · Backup + restore

The Appdata Backup plugin doesn't exist on Ubuntu. Fake its output to exercise the wrapper:

```bash
STAMP=$(date -u +%Y-%m-%d)
mkdir -p /mnt/user/backups/appdata/"$STAMP"
tar czf /mnt/user/backups/appdata/"$STAMP"/CA_backup.tar.gz -C /mnt/user/appdata .

bash scripts/backup-appdata.sh
```

Expected behaviour:

- Writes a checksum file under `/mnt/user/backups/appdata/.checksums/`.
- Prunes directories older than `BACKUP_LOCAL_RETENTION_DAYS` (stub an old one to verify: `mkdir /mnt/user/backups/appdata/2000-01-01 && touch -d '2000-01-01' /mnt/user/backups/appdata/2000-01-01`).
- rclone copy runs only if `BACKUP_REMOTE` is set; stub with a local rclone remote (`rclone config` → new remote → `alias` → `/tmp/rclone-test`) for a round-trip test.
- Logs to `/var/log/homeserver/backup.log` — tail it.

Then exercise restore:

```bash
bash scripts/restore-appdata.sh
```

Follow the interactive prompt, target a scratch directory (`/tmp/restore-target`), confirm the tarball extracts cleanly.

---

## 11 · update-stack.sh

Dry run first — no mutations:

```bash
bash scripts/update-stack.sh --dry-run
```

Expected output: lock acquired, disk-space check passes (`MIN_FREE_MB=5120`), planned `docker compose pull` + `up -d` listed, no actual execution. Log at `/var/log/homeserver-update.log`.

Then real run:

```bash
bash scripts/update-stack.sh
```

Watch behaviour:

- Pulls latest `:release` images for all hotio services and `:public` for Plex.
- Re-runs `docker compose up -d` → recreates only services whose image digest changed.
- **Health gate:** waits for all services to return to `(healthy)`. If any fails, the script aborts and logs the unhealthy container's log tail.
- No duplicate locks: run a second copy in another terminal — it should exit immediately with "already in progress".

Simulate a rollback path: pin one image to a broken tag (`sabnzbd: image: ghcr.io/hotio/sabnzbd:does-not-exist`), re-run update, confirm the failure is caught and the script exits non-zero.

---

## 12 · Teardown

```bash
cd ~/homeserver/homeserver
docker compose --env-file .env.docker down -v
docker volume prune -f
sudo rm -rf /mnt/user  # destroys the sandbox; do not run on the real Unraid box
```

---

## What you explicitly cannot test here

| Area | Why not |
|------|---------|
| Unraid plugin install (`setup-unraid.sh`) | Invokes `/usr/local/emhttp/plugins/...` — Unraid-only paths |
| BOSS ZFS boot mirror | Unraid's boot is USB + ZFS via their custom `diskload` — no equivalent on Ubuntu |
| PERC H730P HBA mode SMART passthrough | Requires the actual card + drivers |
| MD1400 SAS enumeration | Requires the LSI 9300-8e HBA + SFF-8644 + real DAS |
| Parity rebuild | Requires Unraid's driver + actual parity disk |
| iDRAC + fan control (`setup-fan-control.sh`) | R640 BMC only |
| Tailscale ACLs under real admin load | Partial — can configure ACLs locally but cannot emulate multi-device SSO posture without real Tailscale users |
| Plex Pass features (HW transcoding gating) | Requires a real Plex Pass on the claimed server |
| AV1 encode absence on RTX 3050 | Untestable positive, testable negative: try and fail |

---

## Findings log

Keep a running list as you execute. One line per test, one of `PASS` / `FAIL` / `SKIP` / `PARTIAL`, plus a note if non-trivial.

```
[ ] 0  Ubuntu prep
[ ] 1  Static analysis
[ ] 2a SVG visual
[ ] 2b Mingrammer render
[ ] 3  Zensical build
[ ] 4  Sandbox setup
[ ] 5  Stack up + per-service + DNS
[ ] 6a GPU visible to Plex
[ ] 6b NVENC transcode
[ ] 6c Concurrent transcode stress
[ ] 7  Hardlink across /data
[ ] 8  External access: Plex port-forward + Tailscale admin plane
[ ] 9  Bootstrap idempotency
[ ] 10 Backup + restore round-trip
[ ] 11 update-stack dry-run + live + rollback
[ ] 12 Teardown
```
