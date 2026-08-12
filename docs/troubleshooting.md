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

## `'doctype' is an unexpected token` on an *arr indexer

**Symptom**: Sonarr/Radarr/Lidarr → Settings → Indexers → Test fails with

```
Unable to connect to indexer: 'doctype' is an unexpected token.
The expected token is 'DOCTYPE'. Line 1, position 3.
```

**This is not a connectivity failure.** It is .NET's XML parser being handed an
HTML page. Something answered on the other end — it just answered with a web
page where the *arr expected Newznab XML. "Unable to connect" is the *arr
mislabelling a parse error, and it sends people to check networking that is
already fine.

Prowlarr syncs each indexer into the *arrs as a Newznab entry pointing back at
Prowlarr itself — `http://gluetun:9696/<prowlarr indexer id>/` with API path
`/api`. So the *arr fetches `http://gluetun:9696/<id>/api?t=caps`. If that
misses Prowlarr's `/{id}/api` route, the request falls through to Prowlarr's
web UI and the *arr gets that page's HTML.

Note **Prowlarr's own indexer Test stays green** the whole time. That tests
Prowlarr → indexer. The broken hop is *arr → Prowlarr, which nothing tests
until you hit this.

### Which of the three is it

Run on the host, from `/mnt/user/appdata/homeserver/homeserver`:

```bash
# 1. What URL is the *arr actually calling? (sonarr shown; 7878/v3 radarr, 8686/v1 lidarr)
SKEY=$(grep ^SONARR_API_KEY .env.docker | cut -d= -f2)
curl -s -H "X-Api-Key: $SKEY" http://localhost:8989/api/v3/indexer \
  | python3 -c 'import json,sys
for i in json.load(sys.stdin):
    u=next((f["value"] for f in i["fields"] if f["name"]=="baseUrl"),"")
    print(i["name"].ljust(35), u)'

# 2. Which indexer ids does Prowlarr actually have?
PKEY=$(grep ^PROWLARR_API_KEY .env.docker | cut -d= -f2)
curl -s -H "X-Api-Key: $PKEY" http://localhost:9696/api/v1/indexer \
  | python3 -c 'import json,sys; print([(i["id"],i["name"]) for i in json.load(sys.stdin)])'

# 3. Replay the exact request the *arr makes (substitute the id from step 1)
curl -s "http://localhost:9696/<id>/api?t=caps&apikey=$PKEY" | head -c 300
```

**Check the sync level first**, because it changes what all of this means:

```bash
curl -s -H "X-Api-Key: $PKEY" http://localhost:9696/api/v1/applications \
  | python3 -c 'import json,sys
for a in json.load(sys.stdin): print(a["name"], a.get("syncLevel"))'
```

If the app is `disabled`, **none of the table below applies**. Prowlarr excludes
disabled apps from `SyncEnabled()`, so it will never add or remove indexers
there — that *arr is hand-managed, its indexers are supposed to point straight
at the indexer, and an empty list means nothing is set up rather than something
is broken. Skip to the last section.

| What you see | Cause | Fix |
|---|---|---|
| Step 1 URL contains `/prowlarr/` | **Stale UrlBase.** Definition was synced before the Tailscale Services migration, when these apps served under a path prefix. | Re-run `bootstrap.py` (below). |
| Step 1 id is missing from step 2's list | **Orphan.** The indexer was deleted and re-added in Prowlarr, so it came back with a new id — including when re-adding is how its categories got fixed. | Re-run `bootstrap.py`. The forced sync removes these itself. One that survives means Prowlarr could not reach that *arr — test the app connection; **do not delete it by hand**. |
| Step 3 returns XML, but the *arr still fails | The *arr's stored definition disagrees with Prowlarr. | Re-run `bootstrap.py`. |
| Step 3 returns an HTML page from the **indexer's** site | Account expired, API key wrong, rate limited, or a Cloudflare interstitial — Prowlarr proxies the body through verbatim. | Prowlarr → Indexers → Test. Fix at the indexer, not here. |

### The fix, for a sync-enabled app

```bash
python3 scripts/bootstrap.py
```

It issues a **forced** `ApplicationIndexerSync`, which is what re-pushes
definitions Prowlarr otherwise considers unchanged — from Prowlarr's side
nothing about the indexer *has* changed when what moved is `prowlarrUrl` or
`syncCategories`, so an unforced sync skips it. The script then reports each
*arr's indexer URLs so you can see the result rather than assume it.

> **That command deletes as well as adds.** `ApplicationService.cs:125` is
> `SyncIndexers(enabledApps, indexers, true, ForceSync)` against the signature
> `(applications, indexers, removeRemote = false, forceSync = false)` — so
> `removeRemote` is **true**. Prowlarr adopts indexers it finds in the *arr that
> were "setup manually in the app" into its mapping table, then removes any
> whose mapped Prowlarr indexer no longer exists. Hand-added indexers in a
> sync-**enabled** *arr can be deleted by it. Apps with sync disabled are never
> touched, which is what makes disabling the sync the safe way to hand-manage
> one *arr.

Recovery if indexers were lost this way: Sonarr writes weekly backups to
`/mnt/user/appdata/sonarr/Backups/scheduled/`. Read one without a destructive
restore —

```bash
mkdir -p /tmp/peek && cd /tmp/peek
unzip -o /mnt/user/appdata/sonarr/Backups/scheduled/<newest>.zip >/dev/null
python3 - <<'PY'
import sqlite3, json, glob
cur = sqlite3.connect(glob.glob("**/sonarr.db", recursive=True)[0]).execute("SELECT * FROM Indexers")
cols = [d[0] for d in cur.description]
for row in cur:
    r = dict(zip(cols, row))
    print(r.get("Name"), "|", r.get("Implementation"))
    print("   ", r.get("Settings"))
PY
```

— then re-create what it shows in the UI.

> Before this was fixed, `bootstrap.py` posted to `/api/v1/applications/sync` —
> not a Prowlarr endpoint, and never one. It 404'd on every run, the status was
> never checked, and it printed `✓ Prowlarr: indexer sync triggered` regardless.
> If you are debugging a stack that predates that fix, that success line means
> nothing.

`bash scripts/verify-stack.sh` checks all of this on every run.

---

## Prowlarr keeps resetting an *arr's indexer categories

**Symptom**: you set an indexer's categories in Sonarr (or Radarr/Lidarr), and
some time later they are back to a narrower set — often a single top-level
category. It looks like Prowlarr is "unchecking the TV category".

It is doing exactly that, and it is two separate mechanisms compounding.

**1. `bootstrap.py` used to overwrite your selection.** `add_app()` reconciled
`syncCategories` on every run, forcing Prowlarr's per-app category list back to
the one hardcoded in the script. That `PUT` raises `ProviderUpdatedEvent`, which
triggers a sync, which rewrites the *arr. Fixed: `syncCategories` is now set
**only when the connection is first created** and never reconciled afterwards —
it is your choice, not the script's. `prowlarrUrl`, `baseUrl` and `apiKey` are
still reconciled, because those track `docker-compose.yml`.

**2. Prowlarr narrows to the intersection.** `Sonarr.cs:272` sets the synced
indexer's `categories` field to `SupportedCategories(app.SyncCategories)` — the
intersection of the app's list with what that indexer *advertises in its caps*.
`IndexerCapabilitiesCategories.cs:131` walks top-level categories **and their
subcategories**, so the comparison is against the flattened tree. A category you
select that the indexer does not advertise is silently dropped; selecting more
of them does not widen anything.

To see the real ceiling, walk `subCategories` — a flat read of `categories`
shows only the parents (`1000`, `2000`, `5000`…) and badly understates it:

```bash
PKEY=$(grep ^PROWLARR_API_KEY .env.docker | cut -d= -f2)
curl -s -H "X-Api-Key: $PKEY" http://localhost:9696/api/v1/indexer \
  | python3 -c 'import json,sys
def walk(cs):
    for c in cs or []:
        yield c["id"]
        yield from walk(c.get("subCategories"))
WANT={"Sonarr":{5000,5010,5020,5030,5040,5045,5050,5060,5070,5080},
      "Radarr":{2000,2010,2020,2030,2040,2045,2050,2060},
      "Lidarr":{3000,3010,3020,3030,3040}}
for i in json.load(sys.stdin):
    ids={c for c in walk((i.get("capabilities") or {}).get("categories")) if c<100000}
    print(i["name"], "advertises:", sorted(ids))
    for app,want in WANT.items():
        print("   ->", app, "would receive:", sorted(ids & want) or "NOTHING - will not sync")'
```

Categories at `100000+` are Prowlarr's indexer-specific namespace and never
intersect a standard list, so they are filtered out above. If an app's row says
`NOTHING`, that indexer is skipped for that app entirely — `AddIndexer` returns
early when the intersection is empty.

**If you want an *arr's indexers under your own control**, set its Prowlarr
connection to **Sync Level: Disabled** (Prowlarr → Settings → Apps). Prowlarr
then neither adds, updates, nor removes indexers there, and `bootstrap.py`
leaves the connection alone and reports the disabled state on each run rather
than treating the empty/direct indexer list as a fault. Add the indexers
directly in that *arr instead.

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

`https://radarr.<tailnet>.ts.net/` doesn't load from a tailnet device.
There is no DNS layer and no proxy layer to bisect any more — a service either
resolves and serves, or its advertisement isn't active.

```bash
tailscale serve status          # is svc:radarr advertised and active?
tailscale status                # is this host still on the tailnet?
curl -fsS http://127.0.0.1:7878/ping   # is the backend itself alive?
```

Work the three in that order; they isolate cleanly.

1. **Backend dead** (`curl` to loopback fails) → the container is the problem,
   not ingress. `docker compose ps radarr` / `docker compose logs radarr`.
2. **Backend fine, service not listed by `tailscale serve status`** → the
   advertisement was lost. Re-issue it:
   ```bash
   tailscale serve --service=svc:radarr --bg 127.0.0.1:7878
   ```
3. **Advertised but inactive** → host approval. Check admin console →
   **Services** → the service → **Service hosts**. Approve if pending. Services
   is in public beta and the daemon does not always pick up an approval that
   lands after the advertisement. Re-issue the advertisement first — this is
   safe from any shell and cannot disconnect you:
   ```bash
   tailscale serve --service=svc:<name> --bg 127.0.0.1:<port>
   ```
   Only if that fails, restart the daemon — and **never over a Tailscale SSH
   session**. `tailscale down` drops the tunnel your shell runs through, so the
   shell dies before `up` executes and the box is left off the tailnet with no
   remote way back in. Use the Unraid web terminal over the LAN, iDRAC's
   virtual console, or a LAN SSH session:
   ```bash
   tailscale down ; tailscale up --ssh --advertise-tags=tag:server
   ```
4. **Certificate warning in the browser** → MagicDNS or HTTPS is disabled at
   the tailnet level. Admin console → **DNS** → both must be on.

**The Unraid GUI is unaffected by all of the above.** `http://<server-name>/`
and Tailscale SSH do not depend on Docker or on any service advertisement — if
those are down too, the problem is the host or the tailnet, not ingress.

Plex (port 32400) is fronted by nothing — it's the only service on the router port-forward. If Plex is the one that's down, check router port-forward config and that the Plex container is healthy (`docker compose ps plex`).

---

## Gluetun kill-switch engaged (SAB / Prowlarr offline)

SAB UI doesn't load, Prowlarr UI doesn't load — `https://sab.<tailnet>.ts.net/` and `https://prowlarr.<tailnet>.ts.net/` hang or refuse. `docker compose ps` shows `gluetun` as `unhealthy` or `restarting`.

This is the kill-switch doing its job: Mullvad dropped, and gluetun's firewall has blocked all egress for every container sharing Gluetun's netns (SAB, Prowlarr) until the tunnel comes back up. **Do not disable the kill-switch to work around this** — that reverts the whole threat-model assumption.

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

## Ollama is slow, or a model won't fit

1. **Is it running on the GPU at all?** `curl -s http://127.0.0.1:11434/api/ps` — `size_vram: 0` means Ollama placed the model entirely on CPU. An empty list just means nothing is loaded right now, which is normal after 60s idle.
2. **The model is too big.** 2 GiB of the 6 GB card is reserved for Plex, leaving ~4 GB. Anything bigger spills layers to CPU — correct behaviour, since the alternative is a transcode that can't allocate. Use a smaller model ([software.md](software.md#model-sizing)), or lower `OLLAMA_GPU_OVERHEAD_BYTES` if you're willing to give Plex less headroom.
3. **Context length is eating the VRAM.** KV cache scales linearly with `OLLAMA_CONTEXT_LENGTH`; at 16K it can exceed the weights. Drop back to 4096.
4. **First request after an idle period is slow.** Expected — `OLLAMA_KEEP_ALIVE=60s` unloaded the model and it re-loads from SSD. One slow request, then normal.

`.env` changes here need `docker compose --env-file .env.docker up -d` to take effect (Compose resolves environment at container-create time, so `restart` alone won't do it).

---

## Plex fell back to CPU transcoding while a model was loaded

Ollama has no awareness of Plex — `OLLAMA_KEEP_ALIVE` is an idle timer, not a response to GPU pressure. The 2 GiB reservation is what guarantees Plex can allocate, so this only happens when Plex needs *more* than the reservation at that moment: realistically two or more concurrent 4K HDR tone-mapping transcodes.

Confirm it's actually VRAM and not the usual suspects:

```bash
docker exec ollama nvidia-smi --query-gpu=memory.used,memory.total --format=csv
curl -s http://127.0.0.1:11434/api/ps    # is a model resident?
```

If VRAM is near the 6 GB ceiling with a model resident, in increasing order of cost:

1. Raise `OLLAMA_GPU_OVERHEAD_BYTES` (e.g. `3221225472` for 3 GiB) and `docker compose --env-file .env.docker up -d ollama`.
2. Shorten `OLLAMA_KEEP_ALIVE` so the window of exposure is smaller.
3. Run a smaller model.
4. Unload on demand: `curl -s http://127.0.0.1:11434/api/generate -d '{"model":"<model>","keep_alive":0}'`.

If VRAM is *not* the problem, this is the ordinary "Plex isn't using hardware transcoding" path above — check Plex Pass first.

[decisions.md](decisions.md#local-ai-on-the-transcode-gpu) documents the Plex-polling preemption daemon that was built for this case and set aside, if it ever becomes worth reviving.

---

## A container can't reach Ollama

Ollama listens only on the `ai` network and host loopback. It is deliberately advertised as no Tailscale Service, so there is no hostname for it at all.

```bash
# From the host
curl -s http://127.0.0.1:11434/api/tags

# From the consumer container — must be on the `ai` network
docker inspect -f '{{json .NetworkSettings.Networks}}' <container> | tr ',' '\n' | grep -o '"[a-z_]*"' | head
```

Expect `ai` in that list. This is the normal cause — access is opt-in, and **no container is on `ai` by default**. Fix depends on where the container is defined:

- **A service in `docker-compose.yml`** — add `ai` to its `networks:` list, then `docker compose --env-file .env.docker up -d <service>`.
- **An Unraid template container** — Docker tab → Edit → **Network Type** → `ai` → Apply. If `ai` isn't in the dropdown, the stack has never been up; start it once so Compose creates the network.

Then confirm from inside the consumer, not from the host:

```bash
docker exec <container> curl -fsS http://ollama:11434/api/tags
```

Use `http://ollama:11434` — not `localhost:11434` (that's the consumer's own loopback), and not the host LAN IP (nothing is bound there).

---

## Nextcloud links point at the wrong hostname (and why you won't see a 400)

Nextcloud has a `trusted_domains` list and normally answers `400 You are accessing the
server from an untrusted domain` for anything not on it — the same failure mode as
SABnzbd's `host_whitelist`, which is why `TAILNET_NAME` is a required value in `.env`.

**This deployment never shows that error, and expecting it will send you the wrong way.**
Nextcloud's `TrustedDomainHelper` returns "trusted" unconditionally when `overwritehost`
is set — *"overwritehost is always trusted"* is upstream's own comment — and
`OVERWRITEHOST` is set in `docker-compose.yml` because TLS terminates at tailscaled. So
the untrusted-domain gate is unreachable and `trusted_domains` is never consulted at
request time.

What a mismatch actually looks like: pages load fine, but absolute URLs, share links,
redirects and CalDAV/CardDAV endpoints all point at whatever `OVERWRITEHOST` says. Rename
`svc:nextcloud` without updating it and the browser gets a 200 followed by a redirect to a
name that no longer resolves. Quieter than a 400, and easier to misread as a DNS problem.

`verify-stack.sh` asserts `trusted_domains` directly in its Cloud plane section for exactly
this reason — the ingress probe cannot distinguish good from bad here.

```bash
docker exec -u www-data nextcloud php occ config:system:get trusted_domains
```

Expect `nextcloud.<tailnet>.ts.net` and `nextcloud`. If they're missing or wrong:

```bash
docker exec -u www-data nextcloud php occ config:system:set trusted_domains 0 --value=nextcloud.<tailnet>.ts.net
docker exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=nextcloud
```

**Editing `NEXTCLOUD_TRUSTED_DOMAINS` in `docker-compose.yml` will not fix an existing
install.** The image applies that variable only during the initial unattended install; it
is written into `config.php` and never re-read. Fix it with `occ`, and update the Compose
value too so a rebuild-from-scratch is correct.

The other cause is a renamed Tailscale Service. `svc:nextcloud` has to match the trusted
domain — if you renamed it, either rename it back or add the new name with `occ`.

---

## Nextcloud loads but links are `http://`, or the browser blocks mixed content

TLS terminates at tailscaled, so the container sees a plain-HTTP request and generates
`http://` URLs unless told otherwise. The page is served over HTTPS, so the browser then
blocks its own assets.

```bash
docker exec nextcloud printenv | grep -E 'OVERWRITE|TRUSTED_PROXIES'
```

Expect `OVERWRITEPROTOCOL=https`, `OVERWRITEHOST` and `OVERWRITECLIURL` set to the Service
FQDN, and `TRUSTED_PROXIES=172.16.0.0/12`. Unlike the trusted domains, these *are* read
from the environment on every start, so fixing them is:

```bash
docker compose --env-file .env.docker up -d nextcloud
```

Same class of problem as Actual's `SharedArrayBufferMissing`: the transport was never the
issue, the origin scheme is. Nothing in this stack injects headers in front of Nextcloud —
`tailscale serve` terminates TLS and forwards — so if these three are right, look at the
browser cache before looking anywhere else.

---

## Files are on disk but Nextcloud doesn't show them

Nextcloud keeps a file index in its database. Anything written into
`/mnt/user/nextcloud` without going through Nextcloud — an rclone restore, a manual copy,
a `mv` — is invisible until the index catches up.

```bash
docker exec -u www-data nextcloud php occ files:scan --all
```

This is also the required last step of any user-file restore
([disaster-recovery.md](disaster-recovery.md)).

The share has SMB export off specifically to make this hard to do by accident. If you
turned it back on, this is the cost.

---

## Nextcloud broke right after running Unraid's New Permissions

**This is the most likely way a working Nextcloud gets broken months from now.** Tools →
New Permissions chowns everything to `nobody:users`. Nextcloud runs as `www-data` (33) and
Postgres as `postgres` (70), so both lose access to their own data.

```bash
bash scripts/verify-stack.sh     # Cloud plane section names the wrong uid
```

Fix:

```bash
cd /mnt/user/appdata/homeserver/homeserver
docker compose --env-file .env.docker stop nextcloud nextcloud-cron nextcloud-db
chown -R 33:33 /mnt/cache/appdata/nextcloud /mnt/user/nextcloud
chown -R 70:70 /mnt/cache/appdata/nextcloud-db/*/docker
docker compose --env-file .env.docker up -d nextcloud-db nextcloud nextcloud-redis nextcloud-cron
```

Do not "fix" these to `nobody:users` — that is the bug, not the cure. See
[decisions.md](decisions.md) for why this plane is the one exception to the stack's
ownership convention.

---

## Nextcloud says background jobs have not run

The admin overview flags this when `cron.php` hasn't run recently. `nextcloud-cron` has no
healthcheck by design — it's a sleep loop, so "is the process alive" proves nothing — and
the real signal is in Nextcloud's own state:

```bash
docker exec -u www-data nextcloud php occ config:app:get core lastcron   # unix timestamp
docker logs nextcloud-cron --tail 30
```

`/cron.sh` runs busybox crond with a `*/5` crontab, so anything under ~30 minutes old is healthy;
`verify-stack.sh` asserts exactly that. If the timestamp is stale, the usual causes are the
container being stopped, or an image-version mismatch after a partial major upgrade —
`nextcloud` and `nextcloud-cron` must run the same tag.

```bash
docker compose --env-file .env.docker up -d nextcloud-cron
```

---

## I changed `.env` and nothing picked it up

`.env` is read by two layers:

- **`generate-configs.py`** reads `.env` at run time, writes per-service config files, and regenerates `.env.docker` (the merged `.env` + `generated.env` that Compose actually consumes). If you changed anything that's baked into a config (Usenet password, API key, URL base), or anything Compose substitutes in (TZ, `PLEX_LAN_IP`, VPN key), you must re-run it.
- **Docker Compose** reads `.env.docker` at `docker compose up`. After re-running `generate-configs.py`, follow up with `docker compose --env-file .env.docker up -d`.

Rule of thumb: any `.env` change that matters needs both `python3 scripts/generate-configs.py` and `docker compose --env-file .env.docker up -d` to fully propagate.
