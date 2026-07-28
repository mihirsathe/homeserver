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

`radarr.lan` (or any `*.lan`) doesn't load from a tailnet device. Two
distinct failure modes — DNS or HTTP — diagnose separately.

**First, narrow the layer:**

```bash
nslookup radarr.lan        # DNS layer
curl -v http://radarr.lan/ # HTTP layer
```

If `nslookup` fails or returns the wrong IP, it's a DNS problem (most
common). If it returns `<TAILNET_HOST_IP>` but `curl` hangs, it's
network/Caddy.

### DNS layer

1. On the admin device: `tailscale status` — is the device itself connected? If not, Tailscale app → sign in again.
2. Tailscale admin console → DNS — verify "Restrict to domain `lan`" is set with `<TAILNET_HOST_IP>` as the nameserver. (Per Step 6.5 of `deployment.md`.)
3. From the Unraid host: `docker compose ps adguard` — must be `(healthy)`. If not: `docker compose logs adguard` — look for port-bind conflicts on `:53`.
4. Direct-test AdGuard from a tailnet device: `nslookup radarr.lan <TAILNET_HOST_IP>` — should answer with the same IP regardless of the device's normal DNS.
5. AdGuard UI → `http://adguard.lan/` (or `http://<TAILNET_HOST_IP>:80/` via Caddy) → Filters → DNS rewrites — verify `*.lan → <TAILNET_HOST_IP>` is present. If missing, re-run `python3 scripts/generate-configs.py --force-overwrite` and `docker restart adguard`.

### HTTP / Caddy layer

1. From the Unraid host: `docker compose ps caddy` — must be `(healthy)`.
2. `docker compose logs caddy` — look for upstream connection errors (`dial tcp ...`).
3. ACL sanity: Tailscale console → Access controls — confirm `tag:admin → tag:server:80` is permitted.
4. Direct hit Caddy on the tailnet IP with a Host header to bypass DNS:
   ```bash
   curl -v -H "Host: radarr.lan" http://<TAILNET_HOST_IP>:80/ping
   ```
   If this works but `radarr.lan` doesn't, the problem is purely DNS.

Plex (port 32400) doesn't ride Caddy or AdGuard — it's the only service on the router port-forward. If Plex is the one that's down, check router port-forward config and that the Plex container is healthy (`docker compose ps plex`).

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

## Local AI returns 503

`ollama-gate` returns `503` with `Retry-After: 15` on the inference endpoints when the GPU has been yielded to Plex. Most of the time this is the system working correctly.

```bash
# Is a hold in effect, and why?
ls -l /mnt/user/appdata/ollama-gate/hold 2>/dev/null && echo HELD || echo free
docker logs gpu-arbiter --tail 20
```

**If Plex is transcoding**: expected. The hold clears ~60s after the last video transcode ends. If a client treats this as a hard error rather than retrying, fix the client — `Retry-After` is there for exactly this.

**If Plex is NOT transcoding and the hold is stuck**, the arbiter is wedged or was killed uncleanly. It clears stale holds at startup and releases on SIGTERM, so a restart fixes it:

```bash
docker compose --env-file .env.docker restart gpu-arbiter
```

If that doesn't clear it, the arbiter isn't running at all (nothing else ever removes the file). `docker compose ps gpu-arbiter` — an `unhealthy` status means its heartbeat went stale. As an immediate unblock, `rm /mnt/user/appdata/ollama-gate/hold`; then fix the arbiter, because until it's back Plex has no active preemption (the static VRAM reservation still protects it).

**If you get 503 on a request that isn't inference**, check the path — only `/api/generate`, `/api/chat`, `/api/embed`, `/api/embeddings` and the `/v1` completion endpoints are held. `/api/tags` and `/api/ps` stay available throughout; if those 503 too, something else is wrong.

---

## Local AI returns 403 on `ollama pull`

By design. Model management is blocked over the network — a consumer container that gets popped shouldn't be able to delete the model store. Pull from the host instead:

```bash
docker exec ollama ollama pull llama3.2:3b
```

The same applies to `/api/push`, `/api/create`, `/api/delete`, and `/api/copy`.

---

## Ollama is slow, or a model won't fit

1. **Is it running on the GPU at all?** `curl -s http://127.0.0.1:11434/api/ps` — `size_vram: 0` means Ollama placed the model entirely on CPU.
2. **The model is too big.** 1.5 GiB of the 6 GB card is reserved for Plex, leaving ~4.5 GB. Anything bigger spills layers to CPU, which is correct behaviour (better slow than an OOM that breaks a transcode). Use a smaller model — see [software.md](software.md#model-sizing) — or lower `OLLAMA_GPU_OVERHEAD_BYTES` in `.env` if you're willing to give Plex less headroom.
3. **Context length is eating the VRAM.** KV cache scales linearly with `OLLAMA_CONTEXT_LENGTH`; at 16K it can exceed the weights. Drop it back to 4096.
4. **A transcode just ended and the model was evicted.** The first request after a hold re-loads from disk — one slow request, then normal.

Any `.env` change here needs `python3 scripts/generate-configs.py && docker compose --env-file .env.docker up -d`.

---

## `gpu-arbiter` logs "PLEX_TOKEN is empty"

The arbiter can't see Plex sessions, so the GPU hold will never engage. Plex is still protected by the static VRAM reservation, but preemption is off.

`PLEX_TOKEN` is written to `generated.env` by `bootstrap.py`. Compose resolves environment values at container-*create* time, so a plain `restart` keeps the old empty value — the container has to be recreated:

```bash
python3 scripts/bootstrap.py                              # if the token was never obtained
docker compose --env-file .env.docker up -d gpu-arbiter   # recreate with the token
docker logs gpu-arbiter --tail 5                          # expect "plex_token=set"
```

A `401` in the log instead means the token is stale — rotate it per [operations.md](operations.md#plex-token).

---

## I changed `.env` and nothing picked it up

`.env` is read by two layers:

- **`generate-configs.py`** reads `.env` at run time, writes per-service config files, and regenerates `.env.docker` (the merged `.env` + `generated.env` that Compose actually consumes). If you changed anything that's baked into a config (Usenet password, API key, URL base), or anything Compose substitutes in (TZ, `PLEX_LAN_IP`, VPN key), you must re-run it.
- **Docker Compose** reads `.env.docker` at `docker compose up`. After re-running `generate-configs.py`, follow up with `docker compose --env-file .env.docker up -d`.

Rule of thumb: any `.env` change that matters needs both `python3 scripts/generate-configs.py` and `docker compose --env-file .env.docker up -d` to fully propagate.
