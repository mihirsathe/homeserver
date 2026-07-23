# PR #12 — Pre-merge test plan

Comprehensive test plan for [#12](https://github.com/mihirsathe/homeserver/pull/12)
(Caddy reverse proxy + AdGuard split-DNS). Designed so every step is reversible
and a single appdata backup gives you a hard rollback even if something
corrupts an *arr DB.

This document is for use during PR review — once merged it should be deleted.

---

## Section 0 — Why this exists

PR #12 changes a lot at once (compose, configs, *arr DB state via `bootstrap.py`
reconciliation, Tailscale console settings). Pre-merge testing catches issues
without contaminating master, and the revert path takes you back to a
known-good state in ≤ 10 minutes if anything fails.

**The one trap to know about**: PR #12's bootstrap rewrites the `urlBase`
field on each *arr's SABnzbd download client (from `/sabnzbd` → `""`).
Master's older bootstrap won't re-rewrite it back, so a naive "checkout
master + re-run bootstrap" leaves the *arrs broken. The fix is the appdata
backup in Section 1 — restoring it puts the *arr DBs back to pre-test
state. **Skipping the backup makes the revert path much harder.**

---

## Section 1 — Pre-flight (before touching anything)

### 1.1 Capture the baseline
On the Unraid host, from `/mnt/user/appdata/homeserver/homeserver`:

```bash
# Branch + commit you're starting from (paste output somewhere safe)
git status
git log --oneline -5

# Container state
docker compose ps

# Per-service ping for later comparison
curl -fsS http://localhost:8080/sabnzbd/api?mode=version | head -c 100
curl -fsS http://localhost:7878/radarr/ping
curl -fsS http://localhost:8989/sonarr/ping
curl -fsS http://localhost:8686/lidarr/ping
curl -fsS http://localhost:9696/prowlarr/ping
```

All should return 200-style responses. If any are already broken, fix that
first — testing into a broken baseline gives noisy results.

### 1.2 Take a full appdata backup
This is the hard rollback. Without it, reverting *arr DB state requires
manual API surgery.

```bash
bash scripts/backup-appdata.sh
ls -lhrt /mnt/user/backups/appdata/ | tail -3
```

Confirm the new archive is there with a sensible size. Note the timestamp
— call it `BACKUP_TS`.

### 1.3 Snapshot Tailscale console state
The PR's apply step changes the Tailscale ACL and adds a split-DNS rule.
Both are admin-console-only, no API revert.

- **Screenshot** Tailscale → Access controls → ACL JSON (or copy the JSON to a local file).
- **Screenshot** Tailscale → DNS → Nameservers (will be empty or whatever you have).

### 1.4 Snapshot env files
```bash
cp .env .env.pre-pr12
cp generated.env generated.env.pre-pr12
```

These don't go into git (gitignored). They're your local restore point for
env state.

### 1.5 Sanity-check end-to-end before testing
Add a movie to Plex Watchlist → confirm the existing pipeline grabs it
within 2–3 min. If this is broken *before* the test, the test's e2e check
tells you nothing.

---

## Section 2 — Apply the PR (without merging)

### 2.1 Fetch and check out the PR branch locally
```bash
git fetch origin claude/caddy-adguard-tailscale-dns
git checkout claude/caddy-adguard-tailscale-dns
git log --oneline -3
# Top commit should be: "Caddy reverse proxy + AdGuard split-DNS for clean *.lan admin URLs"
```

### 2.2 Pre-pull the new images (so bcrypt seeding works first try)
```bash
docker compose --env-file .env.docker pull caddy adguard
```

If `caddy:2-alpine` isn't on disk before `generate-configs.py` runs,
AdGuard's admin password won't be bcrypt-seeded and you'll get a one-time
first-launch wizard at `http://adguard.lan/`. Not fatal, just an extra
click.

### 2.3 Add `TAILNET_HOST_IP` to `.env`
```bash
echo "TAILNET_HOST_IP=$(tailscale ip -4)" >> .env
grep TAILNET_HOST_IP .env
# Confirm it's a 100.x.x.x address.
```

### 2.4 Regenerate configs
```bash
python3 scripts/generate-configs.py --force-overwrite
```

Expected output: every config writer succeeds, including
`✓ configs/caddy/Caddyfile` and `✓ configs/adguard/AdGuardHome.yaml`.
Should also print one new line:
`Generated and saved to generated.env: ADGUARD_ADMIN_PASS`.

### 2.5 Validate the Caddyfile (manual sanity-check)
`update-stack.sh` does this automatically, but it's worth a one-off check
the first time:

```bash
docker run --rm -v "$(pwd)/configs/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
    caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
# Expect: "Valid configuration"
```

### 2.6 Bring the stack up
```bash
docker compose --env-file .env.docker up -d
docker compose ps
```

Watch for `(healthy)` on every service. AdGuard healthcheck has a 15s
start_period; everything should settle within ~60s. If any service goes
`(unhealthy)`, **stop here and go to Section 4 (Revert)** — don't run
bootstrap on a broken stack.

### 2.7 Run bootstrap (reconciles *arr DB state)
```bash
python3 scripts/bootstrap.py
```

Expected new output lines (compared to a normal run):
- `✓ Radarr: SABnzbd reconciled` (and same for Sonarr, Lidarr) — proves the
  urlBase update PUT succeeded
- `✓ Prowlarr: Radarr reconciled` (and Sonarr, Lidarr) — proves the
  prowlarrUrl update PUT succeeded

If you see `❌` or any `⚠ failed to reconcile`, **stop and go to Section 4.**

### 2.8 Apply Tailscale console changes
**These are the only manual steps. Both are reversible from the same console.**

1. **DNS** → Nameservers → "Add nameserver" → "Custom..." → enter the value
   of `TAILNET_HOST_IP` from step 2.3. Toggle "Restrict to domain" on, set
   domain to `lan`. Save.
2. **Access controls** → edit the ACL — bump the `tag:admin → tag:server`
   rule's port list to `["tag:server:80,32400,53"]` (was
   `[…,7878,8080,8181,…]` etc.). Save.

---

## Section 3 — Verification

Each test has a clear pass/fail. **Track which pass and which fail** —
you'll need this for the merge-or-revert decision.

### 3.1 DNS layer (prove split DNS works)
**From a tailnet device that is NOT the Unraid host** (your laptop/phone):

```bash
nslookup radarr.lan
# PASS: returns TAILNET_HOST_IP (the value you set in .env)
# FAIL: NXDOMAIN, timeout, or wrong IP

nslookup adguard.lan
# PASS: same answer
```

If FAIL: skip ahead to 3.10 (DNS troubleshooting block) and decide.

### 3.2 HTTP through Caddy (every backend reachable at root)
```bash
for svc in radarr sonarr lidarr prowlarr sab seerr bazarr tautulli profilarr adguard; do
  printf "%-12s " "$svc"
  curl -fsS -o /dev/null -w "%{http_code}\n" "http://${svc}.lan/"
done
```

PASS: all 200/302/401 (any 2xx/3xx is fine — backend is reachable).
FAIL: any 502/503/timeout.

### 3.3 *arr APIs at root (UrlBase strip succeeded)
```bash
curl -fsS http://radarr.lan/ping            # → "OK"
curl -fsS http://sonarr.lan/ping            # → "OK"
curl -fsS http://lidarr.lan/ping            # → "OK"
curl -fsS http://prowlarr.lan/ping          # → "OK"
curl -fsS "http://sab.lan/api?mode=version" # → JSON with "version"
```

FAIL: 404 anywhere means the urlbase strip didn't apply. Verify the config
files on the host:

```bash
grep -i 'urlbase' configs/radarr/config.xml configs/sonarr/config.xml configs/lidarr/config.xml configs/prowlarr/config.xml
# Expect <UrlBase></UrlBase> on every line
grep -i 'url_base' configs/sabnzbd/sabnzbd.ini
# Expect "url_base ="
```

### 3.4 In-app integration (validates bootstrap reconciliation)
**This is the most important test.** From a browser:

- [ ] **Radarr** → Settings → Download Clients → SABnzbd → **Test** → green ✓
- [ ] **Sonarr** → Settings → Download Clients → SABnzbd → Test → green ✓
- [ ] **Lidarr** → Settings → Download Clients → SABnzbd → Test → green ✓
- [ ] **Prowlarr** → Settings → Apps → Radarr → Test → green ✓
- [ ] **Prowlarr** → Settings → Apps → Sonarr → Test → green ✓
- [ ] **Prowlarr** → Settings → Apps → Lidarr → Test → green ✓
- [ ] **Bazarr** → Settings → Sonarr → Test → green ✓
- [ ] **Bazarr** → Settings → Radarr → Test → green ✓

Any red checkmark = bootstrap reconciliation didn't push the right field.
Diagnose with:
```bash
RKEY=$(grep ^RADARR_API_KEY generated.env | cut -d= -f2)
curl -s -H "X-Api-Key: $RKEY" http://localhost:7878/api/v3/downloadclient \
  | python3 -m json.tool | grep -E 'urlBase|host'
# Expect host=gluetun, urlBase=""
```

### 3.5 Backend port lockdown (security regression check)
**From a tailnet device that is NOT the Unraid host**:

```bash
for p in 6767 6868 7878 8080 8181 8686 8989 9696; do
  printf "%-5s " "$p"
  timeout 3 bash -c "</dev/tcp/<TAILNET_HOST_IP>/$p" 2>&1 | head -c 80
  echo
done
```

PASS: every line says `connection refused` or times out.
FAIL: any port answers — backend isn't actually loopback-bound. Inspect
with `sudo ss -tlnp | grep :<port>` on the host.

### 3.6 AdGuard admin UI
- [ ] `http://adguard.lan/` loads
- [ ] Login with `admin` + the value of
  `grep ^ADGUARD_ADMIN_PASS generated.env | cut -d= -f2` succeeds.
  (Or, if bcrypt fallback was triggered — see step 2.2 — the first-launch
  wizard runs instead. Set the password to whatever you want; Section 4
  revert doesn't touch AdGuard's admin user, just the container.)
- [ ] Filters → DNS rewrites — entry `*.lan → TAILNET_HOST_IP` is present.

### 3.7 Caddy itself
```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
# PASS: "Valid configuration"

docker logs caddy 2>&1 | grep -iE 'error|warn' | head
# PASS: empty (or just info-level startup lines)
```

### 3.8 Killswitch regression (validates VPN security property unchanged)
**Skip if you have downloads in flight you don't want to interrupt.**

```bash
docker exec sabnzbd curl -s https://am.i.mullvad.net/ip
# PASS: returns a Mullvad IP, not your home IP

docker stop gluetun
docker exec sabnzbd curl -m 5 https://example.com 2>&1 | tail
# PASS: times out / no route — kill-switch engaged

docker start gluetun
sleep 30
docker exec sabnzbd curl -s https://am.i.mullvad.net/ip
# PASS: Mullvad IP again, recovered
```

### 3.9 End-to-end (the real test)
Add a movie to Plex Watchlist on a family-member-tier account. Wait up to
5 minutes.

- [ ] Seerr → Requests shows the title within ~2 min
- [ ] Radarr → Activity → History shows "Grabbed" for it
- [ ] SAB → Queue / History shows the download
- [ ] Eventually: file lands in `/data/usenet/complete/movies/...` and is
  hardlinked into `/data/media/movies/...`
- [ ] Plex picks it up on next library scan

If any link in this chain breaks, that's the canonical "something is wrong"
signal — go to Section 4.

### 3.10 If DNS layer (3.1) failed
Most common failure. Diagnose before reverting:

```bash
docker compose ps adguard           # must be (healthy)
docker logs --tail 50 adguard       # any port-bind conflicts on :53?
sudo ss -tulnp | grep :53           # what's bound on the host?

# Direct-test AdGuard, bypassing Tailscale split DNS:
nslookup radarr.lan <TAILNET_HOST_IP>
# PASS: still returns TAILNET_HOST_IP — AdGuard works, Tailscale console rule is the issue
# FAIL: NXDOMAIN — AdGuard rewrite isn't loaded; check configs/adguard/AdGuardHome.yaml
```

If AdGuard works directly but split DNS doesn't, the Tailscale console rule
is misconfigured. Re-check step 2.8.1.

---

## Section 4 — Revert (if any required test failed)

Required tests = 3.1 through 3.5, plus 3.9. Tests 3.6, 3.7, 3.8 failing
alone don't necessarily warrant a full revert; you can fix in place.

If you're reverting:

### 4.1 Revert Tailscale console first
Do this first — blocks DNS so admin URLs go back to direct ports.

1. Tailscale admin → DNS → delete the `lan` restricted nameserver entry.
2. Tailscale admin → Access controls → restore the ACL ports list from your
   screenshot in step 1.3.

### 4.2 Stop the stack
```bash
cd /mnt/user/appdata/homeserver/homeserver
docker compose down
```

### 4.3 Switch back to master
```bash
git checkout master
git status
# Should be clean.
```

### 4.4 Restore env files
```bash
cp .env.pre-pr12 .env
cp generated.env.pre-pr12 generated.env
```

### 4.5 Restore appdata from the pre-test backup
This is the critical step that puts *arr DBs back to pre-test state.

```bash
bash scripts/restore-appdata.sh
# Pick the timestamp BACKUP_TS from step 1.2.
# Restore: all (or at minimum: radarr, sonarr, lidarr, prowlarr, bazarr).
```

### 4.6 Regenerate old-style configs
```bash
python3 scripts/generate-configs.py --force-overwrite
```

This rewrites `configs/*/*` to the old `UrlBase=/radarr` style, matching
master.

### 4.7 Bring the stack up
```bash
docker compose --env-file .env.docker up -d
docker compose ps
# Wait for all (healthy)
```

### 4.8 Verify revert via baseline checks from 1.1
```bash
curl -fsS http://localhost:8080/sabnzbd/api?mode=version | head -c 100
curl -fsS http://localhost:7878/radarr/ping
curl -fsS http://localhost:8989/sonarr/ping
curl -fsS http://localhost:8686/lidarr/ping
curl -fsS http://localhost:9696/prowlarr/ping
```

All should return what they did in step 1.1. End-to-end smoke test: add a
Plex Watchlist title, confirm it pipelines through within 5 min.

### 4.9 Clean up the test branch (optional)
```bash
git branch -D claude/caddy-adguard-tailscale-dns
rm -f .env.pre-pr12 generated.env.pre-pr12
```

The PR on GitHub stays open — fix issues, push more commits to the branch,
retest later.

---

## Section 5 — Merge (if everything passed)

```bash
# Still on the test branch, master is unchanged
git checkout master
# Merge the PR via GitHub UI (so the merge commit appears there), OR
# locally:
#   git merge --no-ff claude/caddy-adguard-tailscale-dns
#   git push origin master
```

Then on the box, just stay on master — your local config files are already
in the new shape from testing, the stack is already running the new
configuration. Optionally clean up:

```bash
rm -f .env.pre-pr12 generated.env.pre-pr12
git branch -d claude/caddy-adguard-tailscale-dns   # local only; GitHub keeps the merged branch
```

This document (`docs/PR12-test-plan.md`) can be deleted in a follow-up
commit since the PR is now merged.

The pre-test backup from step 1.2 stays in `/mnt/user/backups/appdata/`
until your normal retention prunes it — leave it there for at least a week
as a safety net.
