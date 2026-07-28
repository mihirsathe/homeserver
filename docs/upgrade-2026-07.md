# Upgrade Runbook — catching a first-setup box up to `master`

Everything the server needs to go from "whatever was deployed at first setup" to
current `master` (`fb50978`), in one supervised session over SSH.

**Read Section 2 before you type anything in Section 3.** The upgrade itself is
low-risk for *media* — nothing in it writes to `/mnt/user/data`. The two things
that can actually bite you are (a) `generate-configs.py --force-overwrite`
discarding UI-side edits to seven bind-mounted config files, and (b) an image
pull migrating the *arr / Plex databases forward, which is one-way. Both are
covered below.

| | |
|---|---|
| **Target commit** | `fb50978` — `master` as of 2026-07-28 |
| **Expected duration** | ~45 min hands-on, plus image-pull time |
| **Requires** | SSH to the Unraid host (Tailscale SSH), a browser for the Tailscale admin console |
| **Hard rollback** | appdata backup taken in Section 2.3 + image digests recorded in 2.9 |

---

## Section 1 — What changed

### 1.1 Find out where you actually are

Run this first; everything else keys off the answer.

```bash
cd /mnt/user/appdata/homeserver
git log -1 --format='%h  %ci  %s'
git status --porcelain          # expect empty — see 2.1 if not
```

Map the short hash against this table. Everything **below** your line is what
you're missing.

| Commit | Merged | What landed |
|--------|--------|-------------|
| `7f1d39f` | PR #1 | `setup-unraid.sh` uses native `plugin install`, unified plugin loop |
| `bda0d86` | PR #2 | **Compose switched to a single `--env-file .env.docker`** |
| `b3af3a7` | PR #3 | Config file perms/ownership, Seerr seed removed, SAB download-client field name + host |
| `05730d3` | PR #4 | `bootstrap.py` uses `/api/v1` for Lidarr |
| `1bf1516` | PR #5 | Lidarr root-folder POST needs the full payload |
| `ce6abc4` | PR #6 | Plex library creation needs BCP-47 (`en-US`) |
| `061d248` | PR #7 | `AuthenticationMethod=None` on the *arrs |
| `1f81d1e` | PR #8 | Seerr dual-homed onto `automation` |
| `c1cad27` | PR #9 | Prowlarr indexer schema matched on `name`, not `definitionName` |
| `56020e9` | PR #10 | `removeCompletedDownloads=False` on each *arr's SAB client |
| `41fb166` | PR #13 | Prowlarr pushes TV/audio categories to Sonarr/Lidarr, not movie categories |
| `fb50978` | PR #12 | **Caddy + AdGuard, UrlBase strip, loopback port binds** ← target |

If your hash isn't in the table, you're on an intermediate commit inside one of
those PRs — treat it as "at or before" the merge commit listed above it.

### 1.2 The big one — PR #12 (Caddy + AdGuard split-DNS)

This is the only change that alters how you *reach* the stack, and the only one
with a manual step outside the box.

**Before:** every admin UI published on `0.0.0.0:<port>`, reachable at
`http://<lan-ip>:7878/radarr`, `:8989/sonarr`, `:8080/sabnzbd`, and so on.

**After:**

- Two new containers: **`caddy`** (binds host **`:81`**, reverse-proxies by Host
  header) and **`adguard`** (binds host **`:53`** TCP+UDP, answers `*.lan` with
  your tailnet IP). Admin URLs are therefore `http://radarr.lan:81/`. Caddy
  listens on `:80` *inside* its container; only the host publish is 81, so the
  Caddyfile carries no port and needs no change if you move it.
- Every admin backend port rebinds from `0.0.0.0:<port>` → **`127.0.0.1:<port>`**.
  They become unreachable from the LAN and from Tailscale — only Caddy is.
  Plex (`32400`) and Seerr (`5055`) stay published on all interfaces.
- **UrlBases stripped everywhere.** `<UrlBase></UrlBase>` on all four *arrs,
  `url_base =` in `sabnzbd.ini`, `base_url =` in Bazarr — apps now serve at root.
  Healthchecks in compose drop the prefix to match. SAB's `host_whitelist` gains
  `sab.lan`, without which every proxied request 403s.
- `bootstrap.py` gains `reconcile_fields()`, which **rewrites the `urlBase` field
  on each *arr's existing SABnzbd download client** (`/sabnzbd` → `""`) and
  Prowlarr's `prowlarrUrl` on each app connection. This mutates the *arr SQLite
  DBs — it is the one step in the upgrade that is not trivially reversible, and
  the reason Section 2.3's backup is not optional.
- New env var **`TAILNET_HOST_IP`**; new generated secret **`ADGUARD_ADMIN_PASS`**.
- `update-stack.sh` gains a pre-flight `caddy validate` on the Caddyfile, so it
  now **refuses to run if `configs/caddy/Caddyfile` doesn't exist**. Run
  `generate-configs.py` before you ever run `update-stack.sh` again.

Two console changes on tailscale.com are required — they're in Section 3.6.

### 1.3 Everything else (PRs #1–#10, #13)

All of these are already-merged correctness fixes. If your deployed commit
predates them, running `generate-configs.py` + `bootstrap.py` in Section 3
applies every one of them in a single pass — they're all idempotent and
converge on the same end state. Nothing here needs a separate step.

The notable behavioural ones: the *arrs stop prompting for a login
(`AuthenticationMethod=None`, PR #7), Radarr/Sonarr/Lidarr's "set to remove
completed downloads" health warning clears (PR #10), Prowlarr actually gets its
two indexers (PR #9 — before this fix Prowlarr synced an *empty* indexer set, so
grabs silently never happened), and Sonarr/Lidarr start receiving TV/audio
categories instead of movie categories (PR #13).

### 1.4 Not in scope

`docs/PR12-test-plan.md` is now obsolete. It was written for pre-merge testing;
its Section 4 revert path ("check out master") points at what is now the *new*
state, so following it today would do the opposite of what it says. Ignore it —
this document supersedes it.

---

## Section 2 — Pre-flight safety checks

Run every one of these before Section 3. Each is read-only. Copy the outputs
somewhere on your Mac — several are the "before" half of a before/after
comparison you'll want later.

### 2.0 What this upgrade can and cannot touch

Worth internalising so you know what you're actually protecting:

| Path | Touched? |
|------|----------|
| `/mnt/user/data/media/**` | **No.** No compose mount changes, no script writes here. |
| `/mnt/user/data/usenet/complete/**` | **No.** |
| `/mnt/user/usenet-incomplete/**` | **No** — but in-flight downloads are interrupted by the container restart in 3.5. |
| `/mnt/user/appdata/<service>/` | **Yes, indirectly** — containers restart, and newer images may migrate their DBs forward (one-way). |
| `/mnt/user/appdata/homeserver/homeserver/configs/**` | **Yes, directly** — regenerated. This is the clobber risk. See 2.4. |
| `.env` / `generated.env` / `.env.docker` | Appended to, never truncated. Both are gitignored so `git pull` can't touch them. |

### 2.1 Working tree is clean and the repo is where you think it is

```bash
cd /mnt/user/appdata/homeserver
git remote -v                    # expect github.com/mihirsathe/homeserver
git status --porcelain           # expect NO output
git stash list                   # expect empty
```

`configs/`, `.env`, `generated.env`, `.env.docker` are all gitignored, so a
clean tree here means `git pull` cannot overwrite anything you care about.

**If `git status` shows modified tracked files**, someone hand-edited a script
or the compose file on the box. Capture the diff before you pull — the pull will
either conflict or the changes will need re-applying:

```bash
git diff > /boot/local-edits-$(date +%F).patch
```

### 2.2 The env files exist and are populated — this is the single biggest risk

Every API key in the stack lives in `generated.env`. If it's missing or
truncated, `generate-configs.py` cheerfully generates **new** keys, rewrites
every config with them, and every service silently disconnects from every other
service. Verify before touching anything:

```bash
cd /mnt/user/appdata/homeserver/homeserver
ls -la .env generated.env .env.docker

# All seven of these must print a non-empty value.
for k in SABNZBD_API_KEY RADARR_API_KEY SONARR_API_KEY LIDARR_API_KEY \
         PROWLARR_API_KEY TAUTULLI_API_KEY STACK_DIR; do
  printf '%-20s %s\n' "$k" "$(grep "^$k=" generated.env | cut -d= -f2- | head -c 8)…"
done
```

`STACK_DIR` must be exactly `/mnt/user/appdata/homeserver/homeserver`. A blank
or wrong value makes every `${STACK_DIR}` bind mount resolve to a bogus path,
and Docker will silently create an empty *directory* where a config *file*
should be.

Then take a copy that survives anything:

```bash
mkdir -p /boot/homeserver-preupgrade
cp -a .env generated.env .env.docker /boot/homeserver-preupgrade/
ls -la /boot/homeserver-preupgrade/
```

`/boot` is the USB flash drive — it survives an array stop, an appdata wipe, and
a full Docker reset. Take a Flash Backup afterwards (Main → Flash → Flash Backup)
and you have an off-server copy too.

### 2.3 A restorable appdata backup exists

This is the hard rollback for the *arr DB mutations in Section 3.7. Do not skip it.

```bash
ls -lhrt /mnt/user/backups/appdata/ | tail -5
```

You want an archive from the last day or so, with a plausible size. If the
Appdata Backup plugin has never actually run — likely, on a box that's never
been maintained — that listing will be empty or stale. In that case take one by
hand. The *arr and SAB databases are what matter and they're small; Plex's
appdata is mostly regenerable metadata/thumbnail cache, so back up its database
directory only:

```bash
cd /mnt/user/appdata/homeserver/homeserver
docker compose --env-file .env.docker stop     # quiesce so SQLite isn't mid-write

mkdir -p /mnt/user/backups/appdata
tar -czf "/mnt/user/backups/appdata/pre-upgrade-$(date +%F-%H%M).tar.gz" \
    -C /mnt/user/appdata \
    radarr sonarr lidarr prowlarr bazarr tautulli sabnzbd seerr profilarr \
    "plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases"

docker compose --env-file .env.docker up -d
```

Then **prove the archive is readable** — an unverified backup is not a backup:

```bash
BK=$(ls -t /mnt/user/backups/appdata/pre-upgrade-*.tar.gz | head -1)
echo "$BK"
tar -tzf "$BK" | wc -l           # expect thousands of entries, not 0
tar -tzf "$BK" | grep -c 'radarr/radarr.db'   # expect 1
ls -lh "$BK"
```

Note the filename. Call it `$BK` for the rest of this document.

### 2.4 Snapshot the generated configs — the real clobber risk

`generate-configs.py --force-overwrite` rewrites these nine files from templates.
Seven of them are bind-mounted single files that the *applications themselves
write back to*, so anything you changed in a web UI since first setup lives here
and will be lost:

| File | What you lose if it's overwritten |
|------|-----------------------------------|
| `configs/sabnzbd/sabnzbd.ini` | **High risk.** SAB stores essentially all state here — extra servers, custom categories, bandwidth caps, scheduler, post-processing scripts. |
| `configs/bazarr/config.ini` | **High risk.** Subtitle provider accounts and credentials, language profiles, scoring. |
| `configs/tautulli/config.ini` | **Medium.** Notification agents, newsletter config, `pms_token`. Watch *history* lives in appdata SQLite and survives. |
| `configs/{radarr,sonarr,lidarr,prowlarr}/config.xml` | **Low.** Only bind address, port, API key, auth method, UrlBase. Everything else is in the SQLite DB. Safe as long as 2.2 passed. |
| `configs/caddy/Caddyfile`, `configs/adguard/AdGuardHome.yaml` | None — they don't exist yet on your box. |

Snapshot them, then diff after regeneration so you can consciously re-apply anything:

```bash
cd /mnt/user/appdata/homeserver/homeserver
cp -a configs "/boot/homeserver-preupgrade/configs-$(date +%F)"
du -sh /boot/homeserver-preupgrade/configs-*

# Record what SAB thinks its servers and categories are, in readable form
grep -A15 '^\[servers\]'    configs/sabnzbd/sabnzbd.ini
grep -A30 '^\[categories\]' configs/sabnzbd/sabnzbd.ini
```

### 2.5 Port 81 is free

Caddy publishes on host **`:81`**, deliberately leaving `:80` to Unraid's own
web GUI — the GUI is the most dependable way onto the box and it stays exactly
where it is. Confirm 81 is actually free:

```bash
ss -tlnp | grep -w ':81' || echo "port 81 free"
ss -tlnp | grep -w ':80'   # expect nginx — Unraid's GUI, leave it alone
```

- **81 free** → nothing to do.
- **81 taken** → set `CADDY_HTTP_PORT` in `.env` to something that isn't
  (`8088`, `8010`, …) before Section 3.5, and use that port everywhere this
  document says `:81`, including the Tailscale ACL in 3.6:

  ```bash
  echo "CADDY_HTTP_PORT=8088" >> .env
  ```

Nothing needs to change in the Caddyfile — Caddy listens on `:80` inside the
container regardless, and strips the port from the `Host` header before matching
its site blocks, so `Host: radarr.lan:8088` still routes to the `http://radarr.lan`
block.

### 2.6 Port 53 is free

AdGuard binds `0.0.0.0:53` on TCP and UDP.

```bash
ss -tulnp | grep -w ':53' || echo "port 53 free"
```

Unraid doesn't bind 53 on a stock install. The realistic conflict is **libvirt's
dnsmasq**, which appears when the VM service is enabled and binds
`192.168.122.1:53`. A bind to `192.168.122.1:53` blocks a bind to `0.0.0.0:53`,
so AdGuard will fail. If you see dnsmasq there and don't use VMs: Settings → VM
Manager → Enable VMs → No. If you do use VMs, don't deploy AdGuard until you've
picked a different approach (bind AdGuard to the tailnet IP only, or run the
resolver off-box).

### 2.7 Free space — appdata and per-disk

```bash
df -h /mnt/user/appdata /mnt/user/data

# Per-disk, because the user-share total hides an imbalanced array (see 1.4)
df -h /mnt/disk* | awk 'NR==1 || /\/mnt\/disk/'
```

- `update-stack.sh` **hard-fails** below **5 GB free on appdata**. Caddy and
  AdGuard images are small (~50 MB combined), but a months-behind pull of Plex +
  four *arrs + SAB will want several GB.
- A single `/mnt/disk*` at or near zero won't stop this upgrade, but it will
  ENOSPC *arr imports independently of it. Worth knowing before you start so you
  don't misattribute the failure.

### 2.8 Current state, captured for comparison

```bash
cd /mnt/user/appdata/homeserver/homeserver
docker compose --env-file .env.docker ps

# Resolved compose config — the "before" side of the mount diff in 3.4
docker compose --env-file .env.docker config > /boot/homeserver-preupgrade/compose-before.yml
grep -E '^\s+(-|source:|target:).*(/mnt/user/data|/mnt/user/appdata)' \
     /boot/homeserver-preupgrade/compose-before.yml | sort -u
```

Per-service liveness, using the **old** UrlBase-prefixed paths (these are what
should work *now*; after the upgrade the same endpoints move to root):

```bash
curl -fsS 'http://localhost:8080/sabnzbd/api?mode=version'; echo
for p in 7878:radarr 8989:sonarr 8686:lidarr 9696:prowlarr; do
  printf '%-10s ' "${p#*:}"
  curl -fsS "http://localhost:${p%%:*}/${p#*:}/ping" || echo FAIL
  echo
done
```

If any of these are already failing, **stop and fix that first**. Upgrading into
a broken baseline makes every post-upgrade failure ambiguous.

### 2.9 Record image digests — the rollback for the image pull

Pulling months of updates migrates the *arr and Plex databases forward, and
those migrations are **one-way**. A newer Sonarr will not open its DB again
after you downgrade. Record exactly what's running so you can pin back to it:

```bash
docker ps --format '{{.Names}}' | while read -r c; do
  printf '%-12s %s\n' "$c" \
    "$(docker inspect --format '{{index .Config.Image}} {{index .RepoDigests 0}}' \
        "$(docker inspect --format '{{.Image}}' "$c")" 2>/dev/null \
      || docker inspect --format '{{.Config.Image}}' "$c")"
done | tee /boot/homeserver-preupgrade/image-digests.txt
```

To roll a service back later: `docker pull <repo>@sha256:<digest>`, then
`docker tag <repo>@sha256:<digest> <repo>:<tag>`, then
`docker compose --env-file .env.docker up -d <service>`. **Restore that
service's appdata from `$BK` in the same operation** — the image rollback alone
won't undo a DB migration.

### 2.10 The array-start User Script points at the right env-file

This file lives on `/boot`, not in git, so `git pull` will never fix it. If it
predates PR #2 the stack comes back wrong after every reboot.

```bash
grep -n 'env-file' /boot/config/plugins/user.scripts/scripts/media_stack_up/script
```

Expect `docker compose --env-file .env.docker up -d`. If you see
`--env-file .env --env-file generated.env`, fix it in Section 3.8.

### 2.11 Know your fallbacks

```bash
tailscale status | head -5
tailscale ip -4                  # note this — it's TAILNET_HOST_IP
```

**Tailscale does not go down during this upgrade.** Nothing here touches the
daemon, and it runs on the Unraid host, not in a container — `docker compose
down` doesn't affect it. What *does* change is a gap in the middle of Section 3:
after 3.5 the admin ports are loopback-only, and `*.lan` doesn't resolve until
the DNS rule in 3.6 lands. During that window the admin UIs have no working URL
from your Mac. SSH is unaffected throughout.

Keeping one SSH session open is a convenience, not a lifeline — from the host,
`localhost:<port>` reaches every backend no matter how broken Caddy or DNS is.
The one thing worth being deliberate about is the **ACL edit in 3.6 step 2**:
a malformed ACL blocks *new* connections, so it is genuinely nicer to already
be sitting in a shell when you save it. Tailscale SSH is governed by the `ssh`
block, not the `acls` port list, so editing the port list can't revoke SSH —
but deleting the wrong stanza can.

Ordered fallbacks if something does go wrong:

1. **Existing SSH session** — `localhost:<port>` for everything.
2. **New SSH over Tailscale** — unaffected by the ACL port list.
3. **Unraid web GUI on `http://<lan-ip>/`** — still on `:80`, which is exactly
   why Caddy was moved to `:81`. Works from the LAN with no Tailscale at all,
   and gives you a terminal.
4. **iDRAC / physical console** — if the network is entirely gone.

Realistically you have to break three independent things before you're locked
out, and this upgrade touches none of them.

### Pre-flight checklist

- [ ] 2.1 `git status` clean, remote correct
- [ ] 2.2 All API keys present; `STACK_DIR` correct; env files copied to `/boot`
- [ ] 2.3 Appdata backup exists **and `tar -tzf` lists its contents**
- [ ] 2.4 `configs/` snapshotted to `/boot`; SAB servers/categories recorded
- [ ] 2.5 Port 80 free (or Unraid GUI moved off it)
- [ ] 2.6 Port 53 free (or VM-manager dnsmasq dealt with)
- [ ] 2.7 ≥5 GB free on appdata; no individual array disk near zero
- [ ] 2.8 `compose ps`, resolved config, and per-service pings captured
- [ ] 2.9 Image digests written to `/boot`
- [ ] 2.10 `media_stack_up` env-file checked
- [ ] 2.11 Tailscale up; tailnet IP noted; SSH session held open

---

## Section 3 — The upgrade

From your Mac:

```bash
ssh root@mediaserver              # or: ssh root@<tailnet-name>.ts.net
cd /mnt/user/appdata/homeserver
```

### 3.1 Pull the repo

```bash
git fetch origin master
git log --oneline HEAD..origin/master        # exactly what you're about to apply
git merge --ff-only origin/master
git log -1 --format='%h %s'                  # expect fb50978
```

`--ff-only` refuses to create a merge commit — if it fails, the working tree
diverged and you should resolve that (see 2.1) rather than force it.

### 3.2 Add `TAILNET_HOST_IP` to `.env`

```bash
cd homeserver
grep -q '^TAILNET_HOST_IP=' .env || echo "TAILNET_HOST_IP=$(tailscale ip -4)" >> .env
grep '^TAILNET_HOST_IP=' .env                # expect a 100.x.x.x address
```

If it's blank or wrong, AdGuard's wildcard rewrite gets a `0.0.0.0` placeholder
and nothing on the tailnet will resolve `*.lan`.

### 3.3 Pre-pull the two new images

Do this **before** regenerating configs. `generate-configs.py` shells out to
`caddy:2-alpine`'s `caddy hash-password` to bcrypt the AdGuard admin password;
if the image isn't on disk it degrades to AdGuard's first-launch wizard instead.

```bash
docker compose --env-file .env.docker pull caddy adguard
mkdir -p /mnt/user/appdata/adguard/work /mnt/user/appdata/caddy
```

### 3.4 Regenerate configs — the careful way

**First pass, no force.** Existing files are preserved and new templates land
alongside as `.new`, so you get a diff instead of a surprise:

```bash
python3 scripts/generate-configs.py
```

It'll print `! existing file preserved; new template at <name>.new` for each
conflict and list them again at the end. Review every one:

```bash
for f in configs/*/*.new; do
  echo "=========== ${f%.new} ==========="
  diff -u "${f%.new}" "$f" || true
done
```

You're looking for changes you *don't* recognise from Section 1.2 — a SAB server
block that differs from what you recorded in 2.4, Bazarr providers disappearing,
a category you added by hand. Note anything you'll need to re-apply.

**Second pass, force.** Now apply the templates for real:

```bash
python3 scripts/generate-configs.py --force-overwrite
rm -f configs/*/*.new
```

Verify the strip actually took, and that no API key changed:

```bash
grep -h -i 'urlbase' configs/{radarr,sonarr,lidarr,prowlarr}/config.xml
# expect: <UrlBase></UrlBase>  ×4

grep -E '^(url_base|host_whitelist)' configs/sabnzbd/sabnzbd.ini
# expect: url_base =            and sab.lan present in host_whitelist

grep -c '<ApiKey>' configs/radarr/config.xml
diff <(grep '^RADARR_API_KEY' /boot/homeserver-preupgrade/generated.env) \
     <(grep '^RADARR_API_KEY' generated.env) && echo "API key unchanged ✓"

grep '^ADGUARD_ADMIN_PASS' generated.env      # new — this is your AdGuard login
```

Confirm no mount changed shape:

```bash
docker compose --env-file .env.docker config > /tmp/compose-after.yml
diff <(grep -E '^\s+(-|source:|target:).*(/mnt/user/data|/mnt/user/appdata)' \
        /boot/homeserver-preupgrade/compose-before.yml | sort -u) \
     <(grep -E '^\s+(-|source:|target:).*(/mnt/user/data|/mnt/user/appdata)' \
        /tmp/compose-after.yml | sort -u)
```

Expected additions only: `adguard`'s two paths and `caddy`'s two. **Any change
to a `/mnt/user/data` line is a stop-and-investigate.**

Validate the Caddyfile before it can take down ingress:

```bash
docker run --rm -v "$PWD/configs/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
    caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
# expect: "Valid configuration"
```

### 3.5 Bring the stack up

```bash
docker compose --env-file .env.docker up -d
docker compose --env-file .env.docker ps
```

This recreates containers with the new port bindings and starts `caddy` and
`adguard`. It does **not** pull new images for existing services — their tags
are already on disk. That's deliberate: config changes and image changes stay
separately attributable.

Wait ~60s, then confirm every service is `(healthy)`. If `caddy` or `adguard`
is not running, it's almost certainly a port bind — go back to 2.5 / 2.6:

```bash
docker logs caddy --tail 30
docker logs adguard --tail 30
```

Prove Caddy routes correctly **from the host, without needing DNS yet**:

```bash
for s in radarr sonarr lidarr prowlarr sab seerr bazarr tautulli profilarr adguard; do
  printf '%-11s ' "$s"
  curl -sS -o /dev/null -w '%{http_code}\n' -H "Host: ${s}.lan" http://localhost:81/
done
```

Any 2xx/3xx/401 is a pass — the backend answered. A `502`/`503` means Caddy
can't reach that backend; a connection refused means Caddy isn't listening.

Also confirm you didn't disturb the Unraid GUI — it should still be on `:80`:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost/   # Unraid, not Caddy
```

### 3.6 Tailscale admin console

Two changes at [login.tailscale.com](https://login.tailscale.com/). **Screenshot
both pages before editing** — neither has an API-driven undo.

1. **DNS → Nameservers → Add nameserver → Custom** → enter your
   `TAILNET_HOST_IP`. Toggle **Restrict to domain** on, set the domain to `lan`.
   Save.
2. **Access controls** → change the `tag:admin → tag:server` destination port
   list to `["tag:server:81,32400,53"]`, replacing the old per-service port list.
   Save.

Do #1 first and verify it before doing #2 — #2 is what actually removes your
direct-port fallback. Leave the `ssh` stanza in the ACL alone; it's what governs
Tailscale SSH and it is not affected by the port list.

If you set a custom `CADDY_HTTP_PORT` in 2.5, use that number instead of `81`.

From your **Mac** (not the server):

```bash
nslookup radarr.lan            # expect your TAILNET_HOST_IP
curl -I http://radarr.lan:81/   # expect 200/302 from Caddy
curl -I http://<lan-ip>/        # Unraid GUI, still on :80, untouched
```

### 3.7 Bootstrap — reconciles the *arr databases

```bash
cd /mnt/user/appdata/homeserver/homeserver
python3 scripts/bootstrap.py
```

Expect these lines specifically — they're the proof the `urlBase` and
`prowlarrUrl` rewrites landed in the *arr DBs:

```
✓ Radarr: SABnzbd reconciled          (and Sonarr, Lidarr)
✓ Prowlarr: Radarr reconciled         (and Sonarr, Lidarr)
```

If you're coming from before PR #9 you'll also see NZBGeek and NZBPlanet get
added for the first time. Run it a second time — everything should report
`already connected` / `already added` / `already set`. It is idempotent by
design; a second run that still says "reconciled" means a PUT isn't sticking.

Any `⚠ failed to reconcile` → stop, and go to Section 5.

### 3.8 Fix the array-start User Script if 2.10 flagged it

```bash
sed -i 's|docker compose --env-file .env --env-file generated.env|docker compose --env-file .env.docker|' \
    /boot/config/plugins/user.scripts/scripts/media_stack_up/script
grep -n 'env-file' /boot/config/plugins/user.scripts/scripts/media_stack_up/script
```

### 3.9 Now — and only now — update the images

Config upgrade verified? Then take the image updates as a separate, second
change, so anything that breaks is unambiguously attributable to the pull.

```bash
bash scripts/update-stack.sh --dry-run     # prints the image list, changes nothing
bash scripts/update-stack.sh
```

The script pre-flights the Caddyfile and the 5 GB appdata floor, pulls,
redeploys, waits up to 300s for every service to report healthy, and only prunes
dangling images if that gate passes — so a bad release keeps its old layers on
disk for a rollback. Output is teed to `/var/log/homeserver-update.log`.

Expect this to take a while and expect Plex and the *arrs to sit in
`(starting)` for several minutes on first boot while they migrate their
databases. That migration is the one-way step from 2.9.

---

## Section 4 — Post-upgrade verification

### 4.1 Everything is healthy

```bash
cd /mnt/user/appdata/homeserver/homeserver
docker compose --env-file .env.docker ps
# 13 services, all "running", all "(healthy)" — the 11 you had, plus caddy + adguard
```

### 4.2 Endpoints answer at root

From the Mac:

```bash
for s in radarr sonarr lidarr prowlarr sab seerr bazarr tautulli profilarr adguard; do
  printf '%-11s ' "$s"
  curl -fsS -o /dev/null -w '%{http_code}\n' "http://${s}.lan:81/" || echo FAIL
done

curl -fsS http://radarr.lan:81/ping             # OK
curl -fsS 'http://sab.lan:81/api?mode=version'  # JSON with a version field
```

### 4.3 Backend ports are actually locked down

From the **Mac**, against the tailnet IP — every one should refuse or time out:

```bash
for p in 6767 6868 7878 8080 8181 8686 8989 9696; do
  printf '%-5s ' "$p"
  nc -z -w3 <TAILNET_HOST_IP> "$p" && echo "OPEN — investigate" || echo "closed ✓"
done
```

```bash
nc -z -w3 <TAILNET_HOST_IP> 81 && echo "81 open ✓ (Caddy)"
nc -z -w3 <TAILNET_HOST_IP> 80 && echo "80 open ✓ (Unraid GUI, unchanged)"
```

`81` (Caddy), `80` (Unraid GUI), `5055` (Seerr) and `32400` (Plex) staying open
is expected and correct.

### 4.4 In-app integration — this is the one that matters

The reconciliation in 3.7 is only proven by the apps themselves. In a browser:

- [ ] Radarr → Settings → Download Clients → SABnzbd → **Test** → green
- [ ] Sonarr → same → green
- [ ] Lidarr → same → green
- [ ] Prowlarr → Settings → Apps → Radarr / Sonarr / Lidarr → **Test** → all green
- [ ] Prowlarr → Indexers → NZBGeek and NZBPlanet both present and enabled
- [ ] Bazarr → Settings → Sonarr / Radarr → **Test** → green
- [ ] Radarr / Sonarr / Lidarr → System → Status → no red indexer alert, no orange
      "remove completed downloads" warning

A red test here diagnoses like this:

```bash
RKEY=$(grep ^RADARR_API_KEY generated.env | cut -d= -f2)
curl -s -H "X-Api-Key: $RKEY" http://localhost:7878/api/v3/downloadclient \
  | python3 -m json.tool | grep -E '"name"|urlBase|"host"'
# expect host=gluetun, urlBase=""
```

### 4.5 Media is intact and hardlinks still work

```bash
# Counts should match what they were before — nothing here was touched
find /mnt/user/data/media/movies -maxdepth 1 -mindepth 1 -type d | wc -l
find /mnt/user/data/media/tv     -maxdepth 1 -mindepth 1 -type d | wc -l
find /mnt/user/data/media/music  -maxdepth 1 -mindepth 1 -type d | wc -l

# Link count > 1 on imported files = hardlinks intact, no double-storage
find /mnt/user/data/media/movies -type f -name '*.mkv' -printf '%n %p\n' 2>/dev/null | head -5
```

In Plex: each library still shows its full item count, and playback works.

### 4.6 Kill-switch regression

Skip if you have downloads in flight you'd rather not interrupt.

```bash
docker exec sabnzbd curl -s https://am.i.mullvad.net/ip    # a Mullvad IP, not yours
docker stop gluetun
docker exec sabnzbd curl -m 5 https://example.com          # must time out
docker start gluetun; sleep 30
docker exec sabnzbd curl -s https://am.i.mullvad.net/ip    # Mullvad IP again
```

### 4.7 End-to-end

Add a movie to a Plex Watchlist on a family-tier account:

- [ ] Seerr → Requests shows it within ~2 min
- [ ] Radarr → Activity → History shows "Grabbed"
- [ ] SAB → Queue/History shows the download
- [ ] File lands in `/data/usenet/complete/movies/…` and hardlinks into `/data/media/movies/…`
- [ ] Plex picks it up on the next scan

### 4.8 Reboot persistence

The real test of 3.8. When convenient:

```bash
# Stop the array from the Unraid GUI and restart it, then:
docker compose --env-file .env.docker ps      # everything back up, healthy
curl -fsS http://radarr.lan:81/ping              # from the Mac
```

---

## Section 5 — Rollback

Work backwards from whichever step failed. Anything above the failure point
stays applied.

### 5.1 Tailscale console (do this first if you got past 3.6)

DNS → delete the `lan` restricted nameserver. Access controls → restore the port
list from your screenshot. This is what puts direct `<lan-ip>:<port>` access
back.

### 5.2 Stop the stack

```bash
cd /mnt/user/appdata/homeserver/homeserver
docker compose --env-file .env.docker down
```

### 5.3 Go back to the old commit

```bash
git checkout <the hash you recorded in 1.1>
```

### 5.4 Restore env and configs

```bash
cp -a /boot/homeserver-preupgrade/.env \
      /boot/homeserver-preupgrade/generated.env \
      /boot/homeserver-preupgrade/.env.docker .
rm -rf configs
cp -a /boot/homeserver-preupgrade/configs-* ./configs
```

### 5.5 Restore appdata — required if 3.7 ran

This is the only way to undo the *arr DB rewrites.

```bash
bash scripts/restore-appdata.sh
# Select $BK from 2.3. Restore: all — or at minimum
# radarr sonarr lidarr prowlarr bazarr
```

The script moves the current appdata aside as `<service>.pre-restore-<ts>`
rather than deleting it, so this step is itself reversible.

If you took the manual tarball in 2.3 instead of using the plugin:

```bash
docker compose --env-file .env.docker down
tar -xzf "$BK" -C /mnt/user/appdata
chown -R nobody:users /mnt/user/appdata/{radarr,sonarr,lidarr,prowlarr,bazarr,tautulli,sabnzbd,seerr,profilarr}
```

### 5.6 Restore images — only if 3.9 ran

```bash
cat /boot/homeserver-preupgrade/image-digests.txt
docker pull <repo>@sha256:<digest>
docker tag  <repo>@sha256:<digest> <repo>:<tag>
```

Restore that service's appdata from `$BK` in the same operation — a newer *arr
or Plex will have migrated its DB, and the old binary can't read it.

### 5.7 Bring it back and verify against 2.8

```bash
docker compose --env-file .env.docker up -d
curl -fsS 'http://localhost:8080/sabnzbd/api?mode=version'
for p in 7878:radarr 8989:sonarr 8686:lidarr 9696:prowlarr; do
  curl -fsS "http://localhost:${p%%:*}/${p#*:}/ping"; echo
done
```

These are the old UrlBase-prefixed paths from 2.8 — they should answer exactly
as they did before you started.

---

## Appendix — after it's done

Keep `/boot/homeserver-preupgrade/` and the 2.3 backup for at least a week.

Then confirm the scheduled maintenance that has presumably never fired is
actually configured — Settings → User Scripts:

| Script | Schedule |
|--------|----------|
| `media_stack_up` | At Startup of Array |
| `media_stack_update` | Monthly (1st, 3am) |
| `media_stack_backup` | Weekly (Sunday, 4am, after Appdata Backup) |

And Settings → Appdata Backup: verify it has a destination of
`/mnt/user/backups/appdata` and a weekly schedule. `backup-appdata.sh` hard-fails
if the newest archive is more than 26h old, which is exactly the signal you want
if the plugin quietly stopped running.
