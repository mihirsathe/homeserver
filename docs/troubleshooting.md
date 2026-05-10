# Troubleshooting

Symptom-driven decision tree for the ~10 most common ways this stack breaks. For hardware-replacement-level failures see [disaster-recovery.md](disaster-recovery.md).

---

## A content request doesn't download

**Check in this order:**

1. **Did the Watchlist add reach Seerr?**
   - Seerr polls Plex Watchlist every ~2 minutes (`plex-watchlist-sync` job). Expect up to a 2-minute lag between a family member tapping "Add to Watchlist" and Seerr submitting a request.
   - Seerr → Requests should show the title as "Pending" or "Approved". If it never appears, the user probably doesn't have the **Auto-Request** permission — Seerr → Settings → Users → edit user → grant Auto-Request.

2. **Does Seerr show it as "Approved"?**
   - If pending — the user lacks auto-approve, or it's a 4K request (4K always requires manual approval by design).
   - If failed — Seerr → Issues tab shows why.

3. **Did Radarr/Sonarr see the request?**
   - Open Radarr/Sonarr → Activity → Queue. If nothing there, Seerr didn't push it.
   - Check Seerr's connection to Radarr: Settings → Services → Radarr → Test. A green checkmark means the API key is correct.
   - Re-run `python3 scripts/bootstrap.py` — it's idempotent and re-establishes the Seerr → Radarr link.

4. **Is the *arr searching?**
   - Radarr → Movies → click the movie → Manual Search. If "No results", Prowlarr isn't returning anything.
   - Prowlarr → Indexers → Test All. Expect green checkmarks. If red — indexer API key wrong, account expired, or indexer temporarily down.
   - Prowlarr egresses through Gluetun; if the Mullvad tunnel is down, Prowlarr has no internet at all. See "Gluetun kill-switch engaged" below.

5. **Is SABnzbd getting NZBs?**
   - SAB → Queue. If empty, the *arr never pushed one. If stuck, check Status tab for stalled servers.
   - SAB → Status → Connections — does it show active connections to your Usenet provider? If not, either the Mullvad tunnel is down (see next section) or the `USENET_*` credentials in `.env` are wrong.

6. **Post-download import failure**
   - Radarr → Activity → History → look for import errors. Usually "No files found in release" (something unzipped weirdly) or permission issues.
   - Hardlink failures: see next section.

---

## Imports cost double disk space (hardlinks broken)

**Symptom**: Radarr successfully imports, but `/mnt/user/data/media/movies/X.mkv` AND `/mnt/user/data/usenet/complete/movies/X.mkv` exist as separate full-size files. `du -sh` shows roughly 2× the expected library size.

Cause is always one of two things:

1. **Source and destination are on different mounts.** Hardlinks can't cross mountpoints. In this stack, both `usenet/` and `media/` live under `/mnt/user/data`, which all containers mount at `/data` — so this should never fail *unless* someone changed the compose mount structure.
   - Verify: `docker exec radarr stat -f /data/usenet/complete/movies /data/media/movies` — `Block size` and `Total blocks` fields should match.

2. **Hardlinks tunable is disabled in Unraid.** Global Share Settings → Tunable (support Hard Links) must be enabled. `setup-unraid.sh` sets this automatically via `shareHardLinks=yes` in `/boot/config/share.cfg`, but a UI toggle or an Unraid upgrade can undo it.
   - Fix: Unraid UI → Settings → Global Share Settings → Tunable (support Hard Links) → Yes → Apply. Re-try an import.

**Also verify at the app level:** Radarr/Sonarr → Settings → Media Management → "Use Hardlinks instead of Copy" must be on. `bootstrap.py` sets this (`copyUsingHardlinks: true`). If off, toggle it and re-import an existing file to prove it stuck.

---

## Plex isn't using hardware transcoding

**Check in order:**

1. **Plex Pass active?** Hardware transcoding requires Plex Pass. Without it, the toggle appears but is ignored at runtime. Plex Web → Settings → Server → Plex Pass.

2. **GPU visible inside the container?**
   ```bash
   docker exec plex nvidia-smi
   ```
   Should show the RTX 3050. If `command not found` or "NVIDIA-SMI has failed", the Nvidia-Driver + nvidia-container-toolkit plugins on Unraid haven't installed correctly. Re-install, reboot, repeat the test.

3. **Transcoder set to NVENC?** Plex Web → Settings → Transcoder → "Use hardware acceleration when available" checked, and the GPU device selected. Plex remembers this per-server; it must be set via the UI (no API).

4. **Actually observe a transcode**:
   ```bash
   watch -n 2 'docker exec plex nvidia-smi'
   ```
   During an active transcode, `Volatile GPU-Util` should be 20–80% and the Plex process appears in the GPU process list. If not, Plex is software transcoding — confirm by checking Plex Web → Status → Now Playing and looking for "(hw)" on the transcode line.

5. **Hit the session cap?** Only relevant in theory — the 3050 allows **12** concurrent NVENC sessions ([NVIDIA matrix](https://docs.nvidia.com/video-technologies/video-codec-sdk/nvenc-application-note/index.html)). If this is ever the answer you have a scaling problem, not a config problem.

---

## Cache pool fills or nearly full

See [disaster-recovery.md#cache-pool-fill](disaster-recovery.md#cache-pool-fill) for the triage script. Shortest fix for an emergency:

```bash
# Anything orphaned in the Plex transcode dir (should always be empty at rest):
rm -rf /mnt/user/appdata/plex-transcode/*

# Prune dangling Docker images:
docker image prune -f

# Stuck SAB downloads in incomplete that haven't moved in days:
ls -lah /mnt/user/usenet-incomplete/
# (manually remove anything you're sure is stuck)
```

---

## Admin UIs unreachable over Tailscale

LAN still works; `mediaserver.<tailnet>.ts.net` doesn't.

1. On the admin device: `tailscale status` — is the device itself connected? If not, Tailscale app → sign in again.
2. Check the Unraid host is still on the tailnet: from the Unraid terminal, `tailscale status` — should show `mediaserver` as `active`. If not: `tailscale up --ssh --advertise-tags=tag:server` and re-auth via the printed URL.
3. Tailscale admin console → Machines — confirm the host isn't expired / tagged off. If a key expired, re-run the `tailscale up` command above.
4. ACL sanity: console → Access controls — confirm `tag:admin → tag:server` still permits the port you're trying to hit.

Plex (port 32400) doesn't ride Tailscale — it's the only service on the router port-forward. If Plex is the one that's down, check router port-forward config and that the Plex container is healthy (`docker compose ps plex`).

---

## Gluetun kill-switch engaged (SAB / Prowlarr offline)

SAB UI doesn't load, Prowlarr UI doesn't load — `http://sab.lan/` and `http://prowlarr.lan/` return 502/504 from Caddy or hang. `docker compose ps` shows `gluetun` as `unhealthy` or `restarting`.

This is the kill-switch doing its job: Mullvad dropped, and `FIREWALL=on` has blocked all egress for every container sharing Gluetun's netns (SAB, Prowlarr) until the tunnel comes back up. **Do not disable the kill-switch to work around this** — that reverts the whole threat-model assumption.

1. `docker logs gluetun --tail 50` — look for WireGuard handshake failures or DNS resolution errors.
2. Verify `VPN_PRIVATE_KEY`, `VPN_ADDRESS`, `VPN_CITY` in `.env` match a current Mullvad WireGuard config. Mullvad occasionally revokes keys; regenerate via the account page if needed.
3. `docker compose up -d gluetun` — forces a clean reconnect.
4. If Mullvad itself is having an incident (rare but not unprecedented), SAB / Prowlarr will stay offline until it recovers. That's intended behavior — nothing in this stack should ever egress on the home WAN IP for Usenet / indexer traffic.

---

## A container keeps restarting

**Diagnose**:
```bash
docker compose ps                       # which one?
docker compose logs --tail 100 <name>   # why?
```

Common patterns:

- **Config file permission denied** — `configs/<service>/*.{ini,xml,json}` is mode 0600 and the container's PUID/PGID can't read it. Either the bind-mount is pointed at a world-readable path (expected: mode 0600 is still readable *by the owner*, which is `nobody:users` / PUID 99:100) or ownership is wrong. Check with `stat /mnt/user/appdata/homeserver/homeserver/configs/<service>/*`.

- **Port conflict** — some other process (host-side) is on the mapped port. `ss -tlnp | grep :<port>` on the host. Almost always a stale container; `docker ps -a | grep <name>` to find and remove it.

- **OOM kill** — `docker inspect <name> --format '{{.State.OOMKilled}}'` returns `true` means the memory limit (see compose `deploy.resources.limits`) is too tight. Either genuine memory leak in the app, or the limit was set too low for this deployment's load.

- **Healthcheck failing on startup** — `docker inspect <name> --format '{{json .State.Health}}'` shows last exit code and stdout. If the check is timing out, consider bumping `start_period:` in compose for that service (the service works but takes longer than expected to come up).

---

## After an update, a service is broken

`update-stack.sh` runs a post-update health gate — if it fails, prune is skipped so previous image layers are still on disk. To roll back:

```bash
# Find the old image layer
docker images | grep <service>

# Re-tag it as :release (or whatever the compose tag is)
docker tag <service>:<old-id> <original-image>:release

# Bring the stack back up on the retagged image
docker compose up -d <service>
```

Then pin that service's tag to a specific version in `docker-compose.yml` until upstream fixes whatever broke.

---

## bootstrap.py fails "did not come up within 180s"

A service's healthcheck isn't passing or port isn't bound. `wait_for` reports the last error — `connection refused` means the container's HTTP server hasn't started yet; `HTTP 5xx` means it started but is broken; `timeout` means the network path is broken.

1. `docker compose ps` — is the service `healthy`? If it says `starting` for >5 minutes, something's wrong with that service specifically. `docker compose logs <service>` for specifics.
2. On Unraid, `bootstrap.py`'s pip deps install to `/tmp/bootstrap-deps`, which is cleared on reboot. That's fine (the script reinstalls on each run), but if the reboot happened mid-run you may have a partial install. Re-run from scratch.

---

## I changed `.env` and nothing picked it up

`.env` is read by two layers:

- **`generate-configs.py`** reads `.env` at run time, writes per-service config files, and regenerates `.env.docker` (the merged `.env` + `generated.env` that Compose actually consumes). If you changed anything that's baked into a config (Usenet password, API key, URL base), or anything Compose substitutes in (TZ, `PLEX_LAN_IP`, VPN key), you must re-run it.
- **Docker Compose** reads `.env.docker` at `docker compose up`. After re-running `generate-configs.py`, follow up with `docker compose --env-file .env.docker up -d`.

Rule of thumb: any `.env` change that matters needs both `python3 scripts/generate-configs.py` and `docker compose --env-file .env.docker up -d` to fully propagate.
