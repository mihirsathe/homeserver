# Live-run Runbook — first-setup box to full platform, in one sitting

Everything the server needs to go from "whatever was deployed at first setup"
to current `master` (`fb50978`) **plus the ingress rework and all three new
tenants**, in one supervised session over SSH.

**This is not phased across days.** The four changes land as a stack of PRs
merged in order — ingress (this branch), then Ollama (#17), then finance
(#16), then chess (#15). Ollama precedes the other two because both are now
its consumers. Each PR extends the relevant sections below, so when all four
are merged this runbook is complete and linear.

**There is exactly one genuinely one-way step:** Section 3.7's `bootstrap.py`
reconcile plus 3.9's image pull. Everything before it is reversible from the
Section 2.3 backup; everything after it depends on it having gone green. Do
not start the new tenants until Section 4 passes.

**Read Section 2 before you type anything in Section 3.** The upgrade itself is
low-risk for *media* — nothing in it writes to `/mnt/user/data`. The two things
that can actually bite you are (a) `generate-configs.py --force-overwrite`
discarding UI-side edits to seven bind-mounted config files, and (b) an image
pull migrating the *arr / Plex databases forward, which is one-way. Both are
covered below.

| | |
|---|---|
| **Target** | `master` (`fb50978`) + ingress rework + Ollama + finance + chess |
| **Expected duration** | ~2 h hands-on, plus image-pull and model-pull time |
| **Requires** | SSH to the Unraid host (Tailscale SSH), a browser logged into the Tailscale admin console, and the inputs listed in Section 0 |
| **Hard rollback** | appdata backup taken in Section 2.3 + image digests recorded in 2.9 |

---

## Section 0 — Everything you need in hand before we start

The point of this section is that **nothing on this list gets discovered
mid-run**. Gather it all first; the run is a paste-back loop over SSH and
stopping to hunt for a token is how a two-hour session becomes a five-hour one.

### Have these before typing anything

| # | What | Where to get it | Used in |
|---|------|-----------------|---------|
| 1 | A browser logged into the **Tailscale admin console** | [login.tailscale.com](https://login.tailscale.com/) | 3.2 |
| 2 | **`TAILNET_NAME`** — your MagicDNS domain, no leading dot | `tailscale status` on the host, or console → DNS → Tailnet name | 3.4 |
| 3 | SSH to the host | `ssh root@<server>` — Tailscale SSH, no password | all |
| 4 | Confirmation `.env` is still populated | 2.2 checks this for you | 2.2 |

### One shell setting, before anything else

```bash
git config --global core.pager cat
```

`git log` pipes through `less` by default, and Unraid's web terminal cannot
drive a full-screen pager — the session appears to hang or garble. `git status`
is unaffected, which makes this confusing when you hit it. Every git command
below also passes `--no-pager` so the runbook works without this setting, but
setting it once is simpler.

Prefer **SSH from your Mac** over the Unraid web terminal regardless: it pastes
multi-line blocks reliably and you can copy output back out.

### Ollama needs nothing from you

No API key, no account, no token. `ollama pull` fetches from
`registry.ollama.ai` over the `ai` bridge, which is deliberately not
`internal: true` for exactly that reason. Budget bandwidth and ~2.5 GB of disk
for `llama3.2:3b`, not attention.

### Actual Budget: two values, both created *during* the run

These cannot be gathered in advance — they do not exist yet. Flagged so the
pause is expected rather than a surprise:

| What | When it exists | How you get it |
|------|----------------|----------------|
| **`ACTUAL_PASSWORD`** | You choose it on the first visit to `svc:actual` | Pick it now, write it down, set it at 4.6b |
| **`ACTUAL_BUDGET_ID`** | Only after you create a budget file | Actual → Settings → **Show advanced settings** → **Sync ID** |

Leave both blank in `.env` until then. `actual-ai` will not work without the
Sync ID, and — this is the trap — it will not *complain* either.

**Bank import is deliberately manual (OFX/QFX).** No credentials, no
aggregator, no outbound calls. Nothing to gather.

### Chess coach: a credential for the private repo — get this first

`coach` is the one service built from source, and
[mihirsathe/chess-coach](https://github.com/mihirsathe/chess-coach) is
**private**, so the server needs its own read access. No PR covers this; it is
the most likely thing to stall the run.

**Use a deploy key, not a PAT** — scoped to this one repo, read-only, and it
cannot be replayed against the rest of your account.

Generate it on the server **before** the run:

```bash
mkdir -p /mnt/user/appdata/chess-coach
ssh-keygen -t ed25519 -N "" -C "chess-coach deploy" \
    -f /mnt/user/appdata/chess-coach/deploy_key
chmod 600 /mnt/user/appdata/chess-coach/deploy_key
cat /mnt/user/appdata/chess-coach/deploy_key.pub
```

Paste that public key into GitHub → the repo → **Settings → Deploy keys → Add
deploy key**. Leave "Allow write access" **unchecked**.

Then **verify it authenticates before the run**, so a credential problem
surfaces now rather than at Section 7a:

```bash
ssh -i /mnt/user/appdata/chess-coach/deploy_key -o IdentitiesOnly=yes -T git@github.com
```

Expect `Hi mihirsathe/chess-coach! You've successfully authenticated, but
GitHub does not provide shell access.` The "no shell access" half is normal.
Note it greets you by **repository**, not by username — that is the deploy key
being correctly scoped. A key that greeted you by username would be one that
could reach every repo you own, which is the thing this avoids.

Pass `-i` to `ssh` directly here. Setting `GIT_SSH_COMMAND` does **not** work
for a bare `ssh` invocation — that variable is read by `git`, not by `ssh`, so
ssh would fall back to the default keys in `~/.ssh/` and fail with
`Permission denied (publickey)` even though the deploy key is registered
correctly. The `GIT_SSH_COMMAND` form in Section 7 is right, because there it
is `git clone` consuming it.

`IdentitiesOnly=yes` matters too: without it ssh offers every key it can find
before this one, and GitHub can cut the connection off after too many
attempts — which also presents as a bad key.

If it fails:

| Symptom | Cause |
|---------|-------|
| `No such file or directory` | The key was generated on your Mac, not the server. |
| Offers the key, still denied | GitHub doesn't have it — usually `deploy_key` pasted instead of `deploy_key.pub`, or it landed in account-wide **Settings → SSH keys** rather than the repo's **Deploy keys**. |
| `Key is already in use` when adding | GitHub refuses one deploy key on two repos. Generate a separate key. |
| Times out before any auth | Outbound port 22 is blocked. Use `ssh -p 443 git@ssh.github.com` and add `-p 443` plus that host to `GIT_SSH_COMMAND` in Section 7. |

**Why `/mnt/user/appdata` and not `/root/.ssh`:** Unraid's root filesystem is
RAM-backed and rebuilt from the USB stick on every boot. A key in `/root/.ssh`
survives until the next reboot and then silently disappears, taking your
ability to update `coach` with it. On the array it persists.

**Leave this directory root-owned.** `setup-unraid.sh` chowns only
`/mnt/user/appdata/chess-coach/**data**` — never the parent — because the
parent also holds this key and the repo checkout. OpenSSH refuses a private key
owned by another user (`bad ownership or modes`), so a recursive
`chown -R nobody:users /mnt/user/appdata/chess-coach` silently breaks every
future `git pull` for coach updates. `data/` is the only path bind-mounted into
the container, so it is the only path that needs to change hands.

Optional, fine to leave blank:

| Variable | What it buys |
|----------|--------------|
| `LICHESS_TOKEN` | Publishing annotated studies back to Lichess (scope `study:write`). Game sync works without it via the public API. |

**No LLM API key is involved anywhere in this run.** Coach's inference backend
is pinned to the in-stack Ollama in `docker-compose.yml` and is not overridable
from `.env`. There is no hosted provider configured, no fallback, and no
credential to set — the only key this whole stack takes for AI is none.

### You will NOT be asked for these

They existed for the old ingress and are gone: **`TS_AUTHKEY`**,
**`CADDY_TAILNET_IP`**, **`CADDY_TS_HOSTNAME`**, **AdGuard's admin password**.
If a doc still asks for one, it is stale.

### Only if something has gone wrong

| What | When |
|------|------|
| **Plex claim token** ([plex.tv/claim](https://plex.tv/claim), 4-minute expiry) | Only if Plex's appdata is lost. Not expected — the existing server identity persists. |
| **Unraid root password** | Only if Tailscale SSH fails and you need the web terminal. |

### The one-way step, stated plainly

Sections 5–7 (Ollama, finance, chess) come after the gate and are additive and
reversible. Everything before **3.7** (`bootstrap.py`) is reversible from the
Section 2.3 backup. `bootstrap.py` rewrites the *arr databases and **3.9** migrates them
forward with new images. After that, rollback means restoring appdata, not
re-running a script. Section 4 is the gate between the two halves — do not
start it late at night.

### Access, throughout

The Unraid GUI on host `:80` and Tailscale SSH are untouched by every step
below. On Unraid, stopping the array stops Docker, so those two are
deliberately the only paths that never depend on a container. If you ever feel
lost, they are the way back in.

---

## Section 1 — What changed

### 1.1 Find out where you actually are

Run this first; everything else keys off the answer.

```bash
cd /mnt/user/appdata/homeserver
git --no-pager log -1 --format='%h  %ci  %s'
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
| `fb50978` | PR #12 | **Caddy + AdGuard, UrlBase strip, loopback port binds** — current `master` |
| *this branch* | — | Caddy/AdGuard/`ts-caddy` **deleted**; admin ingress becomes Tailscale Services — see 1.5 |

If your hash isn't in the table, you're on an intermediate commit inside one of
those PRs — treat it as "at or before" the merge commit listed above it.

### 1.2 The big one — PR #12 (Caddy + AdGuard) is being *deleted*, not deployed

Your box never ran PR #12, and it never will. That PR built the `*.lan` ingress
— a Caddy reverse proxy, an AdGuard wildcard rewrite, a `ts-caddy` sidecar and
a Tailscale split-DNS rule. It merged to `master` months ago and sat undeployed.

This change removes all of it. That is a stroke of luck rather than wasted
work: because the box never deployed it, you are not migrating away from a
running ingress — you are going from *no* ingress directly to the final one.
There is no cutover window and no old URLs to retire.

Two things follow that matter for this run:

- **The generated Caddyfile on `master` is invalid.** Verified against a real
  caddy 2.8.4 binary: the one-liner site form lexed `common;` as the import's
  argument and the adapter rejected the *entire* file with
  `File to import not found: common;`. Caddy refuses to start and
  `update-stack.sh`'s pre-flight aborts, so `master` is undeployable as-is.
  It is moot here — the file and its generator are deleted — but it explains
  why deploying `master` first and then migrating was never an option.
- **Nothing on the box depends on `*.lan`.** No bookmarks to retrain, no DNS
  state to unwind. The split-DNS console rule was never created.

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

### 1.4 Obsolete docs

`docs/PR12-test-plan.md` and `docs/rollout-2026-07.md` are deleted by this
change. The first tested the Caddy/AdGuard ingress that is now removed, and its
revert path pointed at what is now the *new* state — following it today would
do the opposite of what it says. The second phased this work across days, which
the single-sitting decision supersedes. Their surviving technical findings are
folded into 1.2, 1.6 and Section 2.

### 1.5 The ingress on this branch — Tailscale Services

Admin ingress is a Tailscale Service per UI (`svc:radarr`, `svc:sonarr`, …),
advertised by the host's **existing** tailscaled — the daemon the Unraid
Tailscale plugin already runs. Each gets a TailVIP, a MagicDNS name, and a
publicly-trusted auto-renewing certificate.

```
tailnet device → https://radarr.<tailnet>.ts.net → host tailscaled
               → 127.0.0.1:7878 → radarr
```

Three consequences worth internalising before the run:

1. **Every loopback publish is load-bearing.** They were already there for
   `bootstrap.py`'s probes; they are now also the serve backends. Do not
   "tidy them up."
2. **No new containers.** The alternative — a Tailscale sidecar per service —
   would have forced every backend into its sidecar's netns via
   `network_mode:`, which strips its own `networks:` and means each sidecar
   must replicate its backend's plane membership. Services needs none of that.
   The compose change is a pure deletion.
3. **The client must support `--service`.** Verified on this box: tailscale
   1.96.2 has it. Services is in public beta.

### 1.6 The other three tenants land in the same sitting

An earlier revision of this runbook treated the finance plane as out of scope
and phased the work across days. That is superseded: Ollama, finance and chess
land in this run, as a stack of PRs merged in order — ingress, then Ollama,
then finance, then chess. Ollama has to precede the other two because both are
now its consumers.

The integration bugs that only became visible with all four in view are fixed
in their respective PRs, not here. Recorded so they are not rediscovered:

- `actual-ai` and `coach` both reached Ollama on the wrong network. Each PR
  was individually correct and jointly broken — `coach`'s own comment claimed
  Ollama was on `frontend`, which was true when written and false after
  Ollama landed on its own `ai` plane. Both fail *silently*: `actual-ai` logs
  and retries forever by design.
- `/mnt/user/appdata/ollama` was never created or chowned, but Ollama runs as
  `99:100` — Docker would have created it root-owned and every model pull
  would have failed.
- `OLLAMA_MODEL` was `llama3.1:8b` (~5 GB at q4). Behind the 2 GiB
  reservation on a 6 GB card that silently spills layers to CPU. Pinned to
  `llama3.2:3b`.
- Memory *ceilings* summed to 31.25 GB on a 32 GB box. Ollama's 8 G was the
  least load-bearing and is now 4 G, bringing the total to 26.75 GB. Ceilings
  are not reservations, and every one of these tenants is bursty or
  schedulable, so this was never as alarming as the raw sum looks — but it had
  no headroom for error.

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
git --no-pager diff > /boot/local-edits-$(date +%F).patch
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

### 2.2b Appdata ownership — the silent crash-looper

```bash
find /mnt/user/appdata -maxdepth 3 -type d ! -user nobody -printf '%u:%g  %p\n' 2>/dev/null
docker ps --filter health=unhealthy --format '{{.Names}}'
```

**Walk three levels, not one.** A top-level directory can be `nobody:users`
while a directory *inside* it is root-owned, and that is enough to break the
app. This is not hypothetical — it is exactly how Bazarr was found dead on this
box: `/mnt/user/appdata/bazarr` was correctly owned, `/mnt/user/appdata/bazarr/config`
was not, and a one-level check reported everything fine.

A `root:root` entry means Docker created that path before anything chowned it,
and the container — which runs as `${PUID}:${PGID}` — cannot write to it.

**Two root-owned paths are expected and must stay that way:**

| Path | Why |
|------|-----|
| `/mnt/user/appdata/homeserver` | The git repo. Not a bind mount. |
| `/mnt/user/appdata/chess-coach` and `.../repo` | Holds the GitHub deploy key and the checkout. OpenSSH refuses a key owned by another user. Only `chess-coach/data` is bind-mounted and only it should be `nobody:users`. |

Anything else in that output is a bug.

This does **not** reliably show up as a stopped container. Images built on s6
(the hotio family) keep the supervisor running while the actual application
crash-loops behind it, so `docker ps` reports `Up 5 days` for a service that
has never once served a request. The tell is a `PermissionError` in the logs:

```bash
docker logs <name> --tail 20
```

Fix and restart just that service:

```bash
chown -R nobody:users /mnt/user/appdata/<name>
docker restart <name>
```

Do this **before** the backup in 2.3 — there is no point capturing a broken
state as your rollback target.

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

docker compose --env-file .env.docker start
```

**`start`, not `up -d`, and this matters.** At this point the compose file on
disk is still the old one, which defines `caddy` and `adguard` — services that
are *not* running on a box frozen at its first-setup state. `up -d` reconciles
the running set against the file and would **create** them: Caddy would fail
immediately on the invalid Caddyfile, and AdGuard would claim host port 53. You
would be debugging the ingress you are about to delete, in the middle of taking
a backup.

`start` restarts exactly the containers that were stopped and creates nothing.
Use it for every stop/start pair until Section 3.5 puts the new compose file in
place; after that, `up -d` is correct and intended.

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
| `configs/caddy/Caddyfile`, `configs/adguard/AdGuardHome.yaml` | None — they never existed on your box, and this change deletes their generators. |

Snapshot them, then diff after regeneration so you can consciously re-apply anything:

```bash
cd /mnt/user/appdata/homeserver/homeserver
cp -a configs "/boot/homeserver-preupgrade/configs-$(date +%F)"
du -sh /boot/homeserver-preupgrade/configs-*

# Record what SAB thinks its servers and categories are, in readable form
grep -A15 '^\[servers\]'    configs/sabnzbd/sabnzbd.ini
grep -A30 '^\[categories\]' configs/sabnzbd/sabnzbd.ini
```

### 2.5 No new host ports are claimed

Nothing new binds a host port. Ingress is the host's tailscaled on `:443`,
which is already running — so the port map after this change is *smaller* than
before, not larger.

| What | Binds | Reachable at |
|------|-------|--------------|
| Unraid GUI | host `:80` | `http://<server-name>/`, `http://<host tailnet IP>/` |
| Plex | host `:32400` | LAN, and the internet via the router forward |
| Every admin UI | `127.0.0.1:<port>` only | `https://<name>.<tailnet>.ts.net/` via tailscaled |

`:53` is not used by anything in this stack any more — AdGuard is deleted, so
the old dnsmasq/VM-Manager conflict check no longer applies. If you previously
disabled VM Manager solely to free `:53`, you can turn it back on.

### 2.7 Free space — appdata and per-disk

```bash
df -h /mnt/user/appdata /mnt/user/data

# Per-disk, because the user-share total hides an imbalanced array (see 1.4)
df -h /mnt/disk* | awk 'NR==1 || /\/mnt\/disk/'
```

- `update-stack.sh` **hard-fails** below **5 GB free on appdata**. This change
  adds no images at all (it only deletes), but a months-behind pull of Plex +
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
`localhost:<port>` reaches every backend no matter what ingress is doing. This is the fallback, and it is the same loopback publish `tailscale serve` proxies to — so if a service URL breaks, the backend is still one SSH port-forward away.
The one thing worth being deliberate about is the **ACL edit in 3.6 step 2**:
a malformed ACL blocks *new* connections, so it is genuinely nicer to already
be sitting in a shell when you save it. Tailscale SSH is governed by the `ssh`
block, not the `acls` port list, so editing the port list can't revoke SSH —
but deleting the wrong stanza can.

Ordered fallbacks if something does go wrong:

1. **Existing SSH session** — `localhost:<port>` for everything.
2. **New SSH over Tailscale** — unaffected by the ACL port list.
3. **Unraid web GUI on `http://<lan-ip>/` or `http://DellBox/`** — still on
   `:80`, untouched by this upgrade, and Docker-independent. Works from the LAN
   with no Tailscale at all, works with the array stopped, and gives you a
   terminal.
4. **iDRAC / physical console** — if the network is entirely gone.

Realistically you have to break three independent things before you're locked
out, and this upgrade touches none of them.

### Pre-flight checklist

- [ ] 2.1 `git status` clean, remote correct
- [ ] 2.2 All API keys present; `STACK_DIR` correct; env files copied to `/boot`
- [ ] 2.3 Appdata backup exists **and `tar -tzf` lists its contents**
- [ ] 2.4 `configs/` snapshotted to `/boot`; SAB servers/categories recorded
- [ ] 2.5 Host port map understood; Unraid keeps :80
- [ ] 2.6 Port 53 free (or VM-manager dnsmasq dealt with)
- [ ] 2.7 ≥5 GB free on appdata; no individual array disk near zero
- [ ] 2.8 `compose ps`, resolved config, and per-service pings captured
- [ ] 2.9 Image digests written to `/boot`
- [ ] 2.10 `media_stack_up` env-file checked
- [ ] 2.11 Tailscale up; tailnet IP noted; fallback path confirmed
- [ ] 3.3 prerequisite: a reusable, NON-ephemeral `tag:server` auth key in hand

---

## Section 3 — The upgrade

From your Mac:

```bash
ssh root@mediaserver              # or: ssh root@<tailnet-name>.ts.net
cd /mnt/user/appdata/homeserver
```

### 3.1 Pull the repo

**Do not merge the pull requests before the run.** The changes ship as a stack
of four PRs, and `master` does not contain them yet — deliberately. The box
checks out the tip of the stack, the run validates it on real hardware, and the
PRs are merged *afterwards*. If the run turns up a problem, `master` was never
touched and there is nothing to revert.

```bash
git fetch origin
git checkout add-chess-coach          # tip of the stack: contains all four changes
git --no-pager log --oneline -6
```

`add-chess-coach` sits on top of finance, which sits on Ollama, which sits on
the ingress branch — so checking it out gets all four in one step, in the order
they are meant to apply.

Confirm you got what you expect before going further:

```bash
grep -cE '^  (caddy|ts-caddy|adguard):' docker-compose.yml   # expect 0
grep -cE '^  (ollama|actual_server|actual-ai|coach):' docker-compose.yml  # expect 4
```

`0` and `4`. If you see anything else, the checkout didn't land — stop rather
than improvising.

**After the run succeeds**, merge the PRs in stack order (#18 → #17 → #16 →
#15) and return the box to `master`:

```bash
git checkout master && git pull --ff-only origin master
```

That is a no-op in content terms — merging the stack produces a tree identical
to the branch tip, verified — so it is purely bookkeeping to get the box back
on a normal branch.

### 3.2 Tailscale console prep — do this before touching the stack

Three console changes, all in the browser, none of which can be scripted from
the box. Doing them now means nothing is discovered mid-run.

1. **DNS → enable MagicDNS, then enable HTTPS.** Certificates cannot be issued
   without both, and every admin URL depends on them.
2. **Access controls** → confirm `tag:admin` can reach `tag:server` on **443**.
   If your policy uses a `grants` block with `"ip": ["*"]`, that already covers
   it and there is nothing to change. If it enumerates ports (e.g.
   `tag:server:80,32400,53`), add `443` — services are HTTPS, and `53` went
   away with AdGuard.

   **Auto-approval is deliberately not configured here.** `autoApprovers` is
   documented for `routes` and `exitNode`; a `services` key is referenced in
   Tailscale's Services material but its schema is not something this runbook
   verifies, and an unrecognised key can be accepted silently while doing
   nothing — which is worse than not setting it, because you would trust it.
   Approving service hosts by hand is nine clicks, once. Do that instead
   (§3.6), and revisit if Tailscale documents the key.
3. **Confirm the host still carries `tag:server`** — Machines → the Unraid
   host. Everything below assumes it does.

**No auth key is needed.** The old `TS_AUTHKEY` existed only to log the
`ts-caddy` sidecar in. There is no sidecar; the host daemon is already
authenticated.

### 3.3 Confirm the client supports Services

```bash
tailscale version
tailscale serve --help 2>&1 | grep -- '--service'
```

Needs to print a `--service` flag. Verified on 1.96.2. If it is missing, the
Unraid Tailscale plugin is too old — stop here and update the plugin rather
than improvising, because everything downstream assumes this works.

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
# expect: url_base =            and the serve hostname in host_whitelist

grep -c '<ApiKey>' configs/radarr/config.xml
diff <(grep '^RADARR_API_KEY' /boot/homeserver-preupgrade/generated.env) \
     <(grep '^RADARR_API_KEY' generated.env) && echo "API key unchanged ✓"

```

Confirm no mount changed shape:

```bash
docker compose --env-file .env.docker config > /tmp/compose-after.yml
diff <(grep -E '^\s+(-|source:|target:).*(/mnt/user/data|/mnt/user/appdata)' \
        /boot/homeserver-preupgrade/compose-before.yml | sort -u) \
     <(grep -E '^\s+(-|source:|target:).*(/mnt/user/data|/mnt/user/appdata)' \
        /tmp/compose-after.yml | sort -u)
```

Expected **removals** only: `adguard`'s two paths and `caddy`'s two. **Any other change
to a `/mnt/user/data` line is a stop-and-investigate.**

### 3.5 Bring the stack up

```bash
docker compose --env-file .env.docker up -d
docker compose --env-file .env.docker ps
```

This recreates containers with the new port bindings and **removes** `caddy`,
`ts-caddy` and `adguard`. It does not pull new images for existing services —
their tags are unchanged, and the image update is deliberately held back to 3.9
so it lands after the bootstrap gate.

Wait ~60s, then confirm every remaining service is `(healthy)`:

```bash
docker compose --env-file .env.docker ps
```

Expect 11 services. `caddy`, `ts-caddy` and `adguard` should be *gone*, not
unhealthy — if they are still listed, compose is reading a stale file.

Prove every backend answers on its loopback port before wiring ingress to it:

```bash
for p in 7878 8989 8686 9696 8080 6767 5055 8181 6868; do
  printf '%s -> ' "$p"
  curl -fsS -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$p/" || echo FAIL
done
```

Any 2xx/3xx/401 is a pass — the backend answered. This is the gate for 3.6:
`tailscale serve` can only be as healthy as what it proxies to.

### 3.6 Publish the Tailscale Services

Console prep already happened in 3.2, so this is the box side only.

**Define each service in the admin console first.** This is not optional and
not inferable from the CLI: a Tailscale Service is an object that must exist in
the tailnet before any host can advertise it. Advertise first and the host
reports *"approval from an admin is required"* while the console shows nothing
at all to approve — there is no object for the pending advertisement to attach
to, and it looks like a broken advertisement rather than a missing definition.

Admin console → **Services** → create one per admin UI, named for the service
(`radarr` becomes `svc:radarr`). If the Services page is absent from the
sidebar, check **Settings → Feature previews** — Services is in public beta.

**Then advertise one and prove the certificate**, because the certificate is
the whole point of the change:

```bash
tailscale serve --service=svc:radarr --bg 127.0.0.1:7878
```

Note that `tailscale serve status` will report `No serve config`. That is
correct and not a failure: service proxies are tracked separately from ordinary
serve entries and do not appear in that listing.

Approve the host: admin console → Services → `svc:radarr` → **Service hosts** →
Approve.

Open `https://radarr.<tailnet>.ts.net/` from a tagged admin device. **Gate: a
padlock with no warning.** Do not proceed until you see it — if the cert is
wrong, every remaining service will be wrong the same way.

Then the rest:

```bash
tailscale serve --service=svc:sonarr    --bg 127.0.0.1:8989
tailscale serve --service=svc:lidarr    --bg 127.0.0.1:8686
tailscale serve --service=svc:prowlarr  --bg 127.0.0.1:9696
tailscale serve --service=svc:sab       --bg 127.0.0.1:8080
tailscale serve --service=svc:bazarr    --bg 127.0.0.1:6767
tailscale serve --service=svc:seerr     --bg 127.0.0.1:5055
tailscale serve --service=svc:tautulli  --bg 127.0.0.1:8181
tailscale serve --service=svc:profilarr --bg 127.0.0.1:6868
```

Plex is deliberately absent — own port, own auth, own `*.plex.direct` certs.

**If a service advertises but never goes active**, it is host approval —
expected, since auto-approval is deliberately not configured (see 3.2).
Approve in admin console → Services → the service → Service hosts. Services is in public
beta and the daemon does not reliably pick up an approval that arrives after
the advertisement, so if console and daemon disagree:

```bash
tailscale down && tailscale up --ssh --advertise-tags=tag:server
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

Any `⚠ failed to reconcile` → stop, and go to Section 9.

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

The script pre-flights the 5 GB appdata floor, pulls,
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
# 11 services, all "running", all "(healthy)". No caddy, no ts-caddy, no
# adguard — those are deleted, not missing.
```

### 4.2 Endpoints answer at root

From the Mac:

```bash
for s in radarr sonarr lidarr prowlarr sab seerr bazarr tautulli profilarr; do
  printf '%s -> ' "$s"
  curl -fsS -o /dev/null -w '%{http_code}\n' "https://${s}.<tailnet>.ts.net/" || echo FAIL
done
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
nc -z -w3 <TAILNET_HOST_IP>  80 && echo "host :80 open ✓ (Unraid GUI, unchanged)"
nc -z -w3 <host tailnet IP> 443 && echo "tailscaled :443 open ✓ (admin ingress)"
```

On the **host's** tailnet IP, `80` (Unraid GUI), `443` (Tailscale Services)
and `32400` (Plex) staying open is expected and correct. Seerr's `5055` should
now be loopback-only. On the removed **ts-caddy**
node, only `80`.

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

### 4.8 The emergency path still works

The whole point of keeping the GUI off any proxy. Verify all of these, because
this is the path you need precisely when everything else is broken.

```bash
curl -I http://<server-name>/            # Unraid GUI on the LAN
curl -I http://<host tailnet IP>/        # Unraid GUI over Tailscale
ssh root@<server> true                   # Tailscale SSH
```

Then prove they are genuinely independent of Docker and of ingress — stop the
whole stack and re-check:

```bash
docker compose --env-file .env.docker down
curl -I http://<host tailnet IP>/        # must still answer
ssh root@<server> true                   # must still work
docker compose --env-file .env.docker up -d
```

There is no longer any "recreate the sidecar, then restart the proxy" caveat
to remember — that operational footgun died with `ts-caddy`. Ingress is the
host daemon, which is not part of the compose lifecycle at all.

### 4.9 Reboot persistence

The real test of 3.8. When convenient:

```bash
# Stop the array from the Unraid GUI and restart it, then:
docker compose --env-file .env.docker ps      # everything back up, healthy
curl -fsS http://radarr.lan/ping              # from the Mac
```

---

## Section 5 — Ollama

Only start this once Section 4 is green. Ollama is additive and reversible —
it touches no existing service — but there is no reason to debug two things at
once.

### 5a Bring it up

```bash
cd /mnt/user/appdata/homeserver/homeserver
docker compose --env-file .env.docker up -d ollama
docker compose --env-file .env.docker ps ollama
```

**Gate:** `(healthy)`. First start unpacks CUDA libraries before the API
answers, so allow the 60s `start_period` — "starting" is not a failure yet.

### 5b Confirm it actually got the GPU

```bash
docker exec ollama nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv
```

**Gate:** the RTX 3050 is listed. If this fails, the container is running
CPU-only — everything below still "works" but at unusable speed, and the
failure is silent otherwise.

### 5c Pull the model

```bash
docker exec ollama ollama pull llama3.2:3b
docker exec ollama ollama list
```

**Gate:** `llama3.2:3b` listed at ~2 GB.

**If this fails with a permission error**, the appdata bind is root-owned —
that is the bug this branch fixes in `setup-unraid.sh`, but an existing
directory won't be fixed retroactively:

```bash
chown -R nobody:users /mnt/user/appdata/ollama
docker compose --env-file .env.docker restart ollama
```

### 5d Prove inference works and VRAM comes back

```bash
docker exec ollama ollama run llama3.2:3b "Reply with exactly: ok" --verbose 2>&1 | tail -20
nvidia-smi --query-gpu=memory.used --format=csv    # model resident
sleep 90
nvidia-smi --query-gpu=memory.used --format=csv    # should have dropped
```

**Gate:** a coherent reply, and VRAM use falls after ~90s. That second half is
`OLLAMA_KEEP_ALIVE=60s` doing its job — it is what keeps Plex's headroom
available, so it is worth seeing once rather than trusting.

### 5e Confirm Plex still has room

```bash
nvidia-smi --query-gpu=memory.total,memory.used,memory.free --format=csv
```

**Gate:** with a model resident, free VRAM should still be ≥ 2 GiB — that is
`OLLAMA_GPU_OVERHEAD` holding the reservation. If it isn't, stop and raise
`OLLAMA_GPU_OVERHEAD_BYTES` before going further; every later tenant assumes
this reservation holds.

**Ollama gets no Tailscale Service.** It has no authentication, so reaching
`:11434` means being able to delete every model on the box. Network membership
is the access control. Do not "just add a service to test it."

---

## Section 6 — Finance plane

Requires Section 5 green: `actual-ai` reaches Ollama over the `ai` plane.

### 6a Bring up the server only

```bash
docker compose --env-file .env.docker up -d actual_server
docker compose --env-file .env.docker ps actual_server
```

**Gate:** `(healthy)`.

### 6b Publish it and set the password

```bash
tailscale serve --service=svc:actual --bg 127.0.0.1:5006
```

Open `https://actual.<tailnet>.ts.net/` and set the server password.

**Gate — and this one is the whole reason the ingress changed:** Actual must
*load*, not just respond. Its SQLite engine needs `SharedArrayBuffer`, which
browsers gate behind Secure Context. A padlock means the certificate is real
and the app will work. Plain HTTP would fail here even though the bytes were
already encrypted by Tailscale.

Put the password in `.env` as `ACTUAL_PASSWORD`.

### 6c Create a budget, then read the Sync ID

In the Actual UI: create a budget file. Then **Settings → Show advanced
settings → Sync ID**. Copy it into `.env` as `ACTUAL_BUDGET_ID`.

Then regenerate the merged env file and start the worker:

```bash
python3 scripts/generate-configs.py
docker compose --env-file .env.docker up -d actual-ai
```

### 6d Verify — you must read the logs

```bash
docker compose --env-file .env.docker logs actual-ai --tail 50
```

**`actual-ai` has no healthcheck.** `docker compose ps` shows "running" whether
it is working or silently failing every cycle, so the logs are the only signal.

**Gate:** the log shows it connected to Actual, connected to Ollama, and ran a
classification pass. `FEATURES` includes `classifyOnStartup`, so a run happens
immediately rather than waiting for the 4-hourly cron.

**If it logs connection errors to Ollama**, it is on the wrong network — the
exact bug this branch fixes. Confirm:

```bash
docker inspect actual-ai --format '{{json .NetworkSettings.Networks}}' | python3 -m json.tool | grep -E '"(ai|finance)"'
docker exec actual-ai wget -qO- http://ollama:11434/api/tags || echo "CANNOT REACH OLLAMA"
```

Both `ai` and `finance` must be present.

### 6e Leave dryRun on

`FEATURES=["dryRun", "classifyOnStartup"]` means it logs proposed categories
without touching the budget. **Leave it on for several runs.** Read what it
proposes first; an LLM confidently miscategorising months of transactions is
tedious to unpick, and the whole point of the tag pair (`#actual-ai` /
`#actual-ai-miss`) is that you can filter and audit before trusting it.

---

## Section 7 — Chess coach

Requires Section 5 green (Ollama is `coach`'s LLM backend) and the deploy key from
Section 0 already registered on GitHub.

### 7a Clone the private repo

```bash
export GIT_SSH_COMMAND="ssh -i /mnt/user/appdata/chess-coach/deploy_key -o IdentitiesOnly=yes"
git clone git@github.com:mihirsathe/chess-coach.git \
    /mnt/user/appdata/chess-coach/repo
```

**Gate:** the clone completes. `Permission denied (publickey)` means the deploy
key isn't registered or `GIT_SSH_COMMAND` isn't exported in *this* shell.

### 7b Build

```bash
cd /mnt/user/appdata/homeserver/homeserver
docker compose --env-file .env.docker build coach
```

This compiles Stockfish and is the slowest single step in the run — several
minutes, and it is CPU-bound on all 24 cores. Expect the box to get loud.

### 7c Start it

```bash
docker compose --env-file .env.docker up -d coach
docker compose --env-file .env.docker ps coach
```

**Gate:** `(healthy)`.

**If it restart-loops with a permissions error**, the data bind is root-owned:

```bash
chown -R nobody:users /mnt/user/appdata/chess-coach
docker compose --env-file .env.docker restart coach
```

### 7d Publish it

```bash
tailscale serve --service=svc:coach --bg 127.0.0.1:8000
```

**Gate:** `https://coach.<tailnet>.ts.net/` loads.

### 7e Verify it reaches Ollama — the silent one

```bash
docker inspect coach --format '{{json .NetworkSettings.Networks}}' | python3 -m json.tool | grep -E '"(ai|frontend)"'
docker exec coach python -c "import urllib.request;print(urllib.request.urlopen('http://ollama:11434/api/tags').status)"
```

**Gate:** both networks present, and `200`.

This check exists because the failure is invisible from the UI. If `coach`
can't reach Ollama it falls back to facts-only template reports, which look
exactly like a working facts-only run — no error, no warning, just narrative
reports that never appear. There is no hosted fallback to silently pick up the
slack either, which is the point: if Ollama is unreachable you get template
reports, not an outbound API call. Generate one report and
confirm it has prose in it, not only move lists.

### 7f Know how updates work

`update-stack.sh` will **never** update `coach`. It is a `build:` service with
no `image:`, so the monthly image pull skips it entirely and always will.
Updating is manual:

```bash
export GIT_SSH_COMMAND="ssh -i /mnt/user/appdata/chess-coach/deploy_key -o IdentitiesOnly=yes"
cd /mnt/user/appdata/chess-coach/repo && git pull
cd /mnt/user/appdata/homeserver/homeserver
docker compose --env-file .env.docker build coach
docker compose --env-file .env.docker up -d coach
```

### 7g GPU note

`coach` requests the nvidia runtime for lc0 + Maia, which is **phase 2** and
not active at first deploy. Stockfish is CPU-only. So at this point three
containers hold a GPU claim but only Plex and Ollama actually allocate VRAM —
worth knowing before reading `nvidia-smi` and being alarmed by the process list.

---

## Section 9 — Rollback

Work backwards from whichever step failed. Anything above the failure point
stays applied.

### 9.1 Withdraw the services (do this first if you got past 3.6)

```bash
tailscale serve reset
```

That clears every advertisement in one call. The services themselves can be
deleted in the admin console afterwards; leaving them defined but unadvertised
is harmless. Nothing about this touches the host's tailnet membership, so SSH
and the Unraid GUI stay up throughout — which is what makes rollback safe.

### 9.2 Stop the stack

```bash
cd /mnt/user/appdata/homeserver/homeserver
docker compose --env-file .env.docker down
```

### 9.3 Go back to the old commit

```bash
git checkout <the hash you recorded in 1.1>
```

### 9.4 Restore env and configs

```bash
cp -a /boot/homeserver-preupgrade/.env \
      /boot/homeserver-preupgrade/generated.env \
      /boot/homeserver-preupgrade/.env.docker .
rm -rf configs
cp -a /boot/homeserver-preupgrade/configs-* ./configs
```

### 9.5 Restore appdata — required if 3.7 ran

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

### 9.6 Restore images — only if 3.9 ran

```bash
cat /boot/homeserver-preupgrade/image-digests.txt
docker pull <repo>@sha256:<digest>
docker tag  <repo>@sha256:<digest> <repo>:<tag>
```

Restore that service's appdata from `$BK` in the same operation — a newer *arr
or Plex will have migrated its DB, and the old binary can't read it.

### 9.7 Bring it back and verify against 2.8

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
