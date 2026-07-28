# Rollout Plan — four changes, one box, July 2026

Sequencing for landing everything currently in flight on a server that is still
running its first-setup deployment. Companion to
[upgrade-2026-07.md](upgrade-2026-07.md), which is the detailed runbook for
Phase 1.

**The governing rule: one phase at a time, each with its own verification gate.**
The end state is ~20 services across seven network planes. Two phases contain
one-way steps (database migrations, an `*arr` DB rewrite), so "just roll back"
isn't free, and if two changes are in flight when something breaks you can't
tell which caused it.

---

## What's in flight

| Phase | Change | Branch / PR | Hard dependency |
|---|--------|-------------|-----------------|
| 1 | Catch-up to `master` + ingress rework | `claude/homeserver-upgrade-deployment-tj4vgf` | none |
| 2 | Ollama + GPU arbitration | PR #17 `claude/ollama-plex-gpu-sharing-7mjmd0` | Phase 1 |
| 3 | Finance plane (Actual Budget) | PR #16 `feat/finance-plane` | **Phase 2** — see below |
| 4 | Chess coach (`coach.lan`) | PR #15 `add-chess-coach` | Phase 1; git credentials on the box |

---

## Read this first: the generated Caddyfile was invalid

Independently confirmed against a real `caddy` 2.8.4 binary before writing this
plan. The Caddyfile that `generate-configs.py` produced on `master` fails to
adapt:

```
Error: adapting config using caddyfile: File to import not found: common;, at Caddyfile:10
```

The Caddyfile grammar has no statement separator, so
`{ import common; reverse_proxy radarr:7878 }` lexes `common;` as the import's
argument and **the whole file is rejected** — every admin site, not just one.
Caddy would refuse to start and `update-stack.sh`'s pre-flight would abort.

PR #17 found this and fixes it. **Phase 1 now carries the same fix** (block
form, one directive per line, verified `Valid configuration` on 2.8.4) so that
Phase 1 is deployable on its own rather than depending on an unmerged PR. The
two fixes overlap and will conflict — resolution recipe in Phase 2 below.

The practical consequence: **do not deploy `master` as it stands today.** Admin
ingress does not work on it, for two independent reasons (this, plus Caddy
colliding with Unraid's `:80`). Phase 1 fixes both.

---

## Merge conflicts — measured, not guessed

Trial-merged every branch locally against Phase 1:

| Merge | Conflicts |
|-------|-----------|
| Phase 1 ← PR #15 | **none** |
| Phase 1 ← PR #16 | **none** |
| Phase 1 ← PR #17 | `generate-configs.py`, `docker-compose.yml`, `docs/software.md` |
| PR #15 ← PR #16 | `.env.example`, `setup-unraid.sh` — both purely additive, keep both sides |

Only PR #17 genuinely interacts with Phase 1, because both touch Caddy. One of
those conflicts needs real thought rather than "keep both" — see Phase 2.

---

## The two things neither PR knows about the other

These are the actual integration work. Both are small, and both are silent
failures if missed.

### 1. `actual-ai` can't reach Ollama as PR #16 is written

PR #16 predates PR #17 and assumes Ollama is **external**: `OLLAMA_URL` is a
`.env` value pointing off-stack, and `actual-ai` joins only the `finance`
network. PR #17 puts Ollama on this box behind a gate on a new `ai` network,
and deliberately gives the engine **no DNS name** on the consumer plane so
nothing can route around the arbitration.

So after both land, `actual-ai` must:

```yaml
    networks:
      - finance
      - ai              # <-- add; without it ollama-gate does not resolve
```

with `OLLAMA_URL=http://ollama-gate:11434/api` in `.env` — the gate, not the
engine, and keeping PR #16's required `/api` suffix.

Symptom if missed: `actual-ai` logs connection failures and retries forever
without crash-looping, which is PR #16's intended graceful degradation and
therefore looks like nothing is wrong.

### 2. The two runbooks disagree on model size

The finance install runbook says `ollama pull llama3.1:8b`. PR #17's sizing
guidance is a **3B** model (~2.5 GB), which coexists with a 4K transcode on a
6 GB card; it treats a 7B+ model as the tail case that needs active preemption.

An 8B model at q4 is ~5 GB. It will work — PR #17's `OLLAMA_GPU_OVERHEAD`
reservation makes the failure mode "spills layers to CPU, gets slower" rather
than "OOMs the card" — but it means the arbiter's preemption path is load-
bearing during Plex transcodes instead of being a safety valve. Start with
`llama3.2:3b`, and only move up if categorization quality is actually
insufficient.

Also: with PR #17 in place, **model pulls are a host operation**. The gate
returns 403 on `/api/pull`, so the finance runbook's `ollama pull` becomes:

```bash
docker exec ollama ollama pull llama3.2:3b
```

---

## GPU: three tenants, one 6 GB card

PR #17 resolves what would otherwise be this rollout's biggest risk, so the
work here is verification rather than design. Its key insight is that the
contended resource is **VRAM, not compute** — NVENC/NVDEC are dedicated ASIC
blocks, so inference never steals encoder time from Plex.

| Tenant | Appetite | Arrives |
|--------|----------|---------|
| Plex NVENC | ~1 GB for a 4K HDR transcode | Phase 1 (already live) |
| Ollama | ~2.5 GB at 3B, ~5 GB at 8B | Phase 2 |
| `coach` — lc0 / Maia | small nets (~100–200 MB) | Phase 4, and only at *its* phase 2 — not at first deploy |

The static layers (`OLLAMA_GPU_OVERHEAD`, `MAX_LOADED_MODELS=1`, `KEEP_ALIVE=60s`)
cover the common case with no conflict at all. Verify on hardware per
`docs/pre-deploy-testing.md` §6d once Phase 2 is up.

RAM is the softer constraint: memory *limits* across the fully-merged stack sum
to roughly **25 GB on a 32 GB box**. Limits are ceilings, not reservations, so
this is not an overcommit failure — but Plex (8 G) + coach (6 G) + SAB (2 G)
concurrently is 16 G before Unraid itself, page cache, and Ollama's host-side
footprint. Watch it after Phase 4, which is when coach's 6 G arrives.

---

## Phase 0 — Maintenance window and backup

Array spin-down is fine, so take the cold backup — it's the cleanest available,
because nothing is mid-write.

1. Work through [upgrade-2026-07.md](upgrade-2026-07.md) Section 2 in full. Do
   not skip 2.2 (env files → `/boot`) or 2.3 (**verified** appdata backup).
   Phase 1 rewrites `*arr` database rows and its image pull migrates databases
   forward one-way; this backup is the only rollback for both.
2. Stop the array for the backup, then restart it. On Unraid this stops Docker
   too (`docker.img` is loop-mounted from a pool), so the whole stack is down
   for the duration — which is exactly why the snapshot is clean.

Phases 1–4 all run with the array up. It never needs stopping again.

---

## Phase 1 — Catch-up + ingress rework

Follow [upgrade-2026-07.md](upgrade-2026-07.md) Sections 3 and 4 end to end.

Foundation, and not reorderable: every later phase's `*.lan` hostname depends
on Caddy working, and on `master` today it does not.

**Gate:** runbook Section 4 passes — all services healthy, every `*.lan`
answers, `*arr` ↔ SAB ↔ Prowlarr tests green in-app, `http://DellBox/Main`
still works, and 4.8's emergency-path check (stop Caddy, confirm the GUI
survives) passes. Confirm end-to-end media flow before continuing; this is the
one phase that touches the pipeline you already depend on.

---

## Phase 2 — Ollama + GPU arbitration (PR #17)

Goes before finance because finance consumes it, and next to Phase 1 because
both touch Caddy while that context is fresh.

**Merge resolution — the one that needs thought.** Three files conflict:

- **`generate-configs.py`** (2 hunks). Both branches fix the Caddyfile bug;
  PR #17's version is a superset (it adds `CADDY_STREAMING` and a
  `flush_interval -1` branch for Ollama's ndjson). Take **PR #17's loop body**,
  and keep **Phase 1's `caddy_services()` function** — then change PR #17's
  `for name, … in CADDY_SERVICES.items()` to `caddy_services(env).items()` so
  `unraid.lan` survives. The two additions are adjacent, not competing.
- **`docker-compose.yml`** — network-plane comments merge by keeping both. The
  real one is the `caddy` service: PR #17 adds `ai` to `caddy.networks`, but
  Phase 1 gives Caddy `network_mode: service:ts-caddy` and **no `networks:` of
  its own**. Those are incompatible as written. Correct resolution: **add `ai`
  to `ts-caddy`'s network list**, not Caddy's. Caddy inherits it through the
  shared namespace, which is exactly how it already reaches the other three
  planes.
- **`docs/software.md`** — one hunk, prose and table rows. Keep both.

Then:

```bash
git merge --no-ff origin/claude/ollama-plex-gpu-sharing-7mjmd0
#   → resolve as above
python3 scripts/generate-configs.py --force-overwrite
docker run --rm -v "$PWD/configs/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
    caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile   # expect "Valid configuration"
docker compose --env-file .env.docker up -d
docker exec ollama ollama pull llama3.2:3b
```

Note `bootstrap.py` in PR #17 recreates `gpu-arbiter` after writing
`PLEX_TOKEN` — Compose resolves env at create time, so a plain restart would
keep the empty value. If you bootstrapped in Phase 1, the token is already in
`generated.env` and the arbiter picks it up on first create.

Also exclude `/mnt/user/appdata/ollama` from Appdata Backup before the next
weekly run — model blobs are multi-GB and re-pullable, and would otherwise
inflate every archive.

**Gate:** `http://ollama.lan/api/tags` lists the model from the Mac;
`curl -X POST http://ollama.lan/api/pull` returns 403; start a Plex transcode
and confirm the hold engages and VRAM drops (`docs/pre-deploy-testing.md` §6d);
confirm `docker exec <any consumer> getent hosts ollama` returns nothing.

---

## Phase 3 — Finance plane (PR #16)

Merges clean against Phase 1. Follow the finance install runbook, with three
amendments from the integration findings above:

1. Its prerequisite "an Ollama server, anywhere" is satisfied by Phase 2 — set
   `OLLAMA_URL=http://ollama-gate:11434/api`, and **add `ai` to `actual-ai`'s
   networks** in `docker-compose.yml`.
2. Its `ollama pull llama3.1:8b` becomes `docker exec ollama ollama pull
   llama3.2:3b` (host operation; smaller model — see above).
3. `git merge origin/feat/finance-plane` will conflict with Phase 4's branch
   later in `.env.example` and `setup-unraid.sh` if you reorder these; in this
   order it's clean.

**Console prerequisite:** HTTPS Certificates enabled for the tailnet (admin
console → DNS), or `tailscale serve` can't provision Actual's cert.

**Never run `tailscale serve --http=80` on the host node.** It would shadow the
Unraid GUI on the tailnet — the emergency path Phase 1 exists to protect. The
default `:443` is free and correct; Unraid's SSL is off.

**Gate:** the finance runbook's step 6 is the real one and it's explicitly
flagged as untested — Actual's UI must fully load over
`https://<node>.<tailnet>.ts.net` with `window.isSecureContext === true` and
`typeof SharedArrayBuffer === "function"`. If `tailscale serve` strips Actual's
COOP/COEP headers, that runbook's fallback (Actual terminating its own TLS via
`tailscale cert`) is the documented path — and note it reintroduces the 90-day
renewal script the current design removed.

Leave `dryRun` on for several runs, then check **More → Rules** after the first
live run: it's undocumented whether Actual's Category Learning distinguishes
your UI edits from `actual-ai`'s API writes, and if it doesn't, wrong guesses
become permanent rules.

---

## Phase 4 — Chess coach (PR #15)

Last: it's the heaviest (6 G limit, ~30-minute first-boot backfill at 16
threads), the least finished (its own docs deliberately deferred), and the only
one whose GPU use is still a future phase. Landing it into an already-arbitrated
card is the right order.

**Prerequisite the PR doesn't cover:** `chess-coach` is a *private* repo and the
bring-up clones it onto the server. `git clone https://github.com/…` will fail
or hang on a headless Unraid box. Sort out a deploy key or a PAT first.

```bash
git merge --no-ff origin/add-chess-coach        # clean against Phase 1
#   → if Phase 3 already landed: keep both sides in .env.example + setup-unraid.sh
git clone <authenticated-url> /mnt/user/appdata/chess-coach/repo
bash scripts/setup-unraid.sh                     # idempotent; creates + chowns the data dir
python3 scripts/generate-configs.py --force-overwrite
docker compose --env-file .env.docker build coach
docker compose --env-file .env.docker up -d coach
```

**`update-stack.sh` will not update this service** — it's a `build:` service
with no `image:`, so the monthly pull skips it. Updates are `git pull` in the
checkout plus a rebuild: a standing manual task, not automation.

**Gate:** `http://coach.lan` loads from the Mac; coach settles after the
backfill; Plex still transcodes on GPU during it.

---

## Phase 5 — Tailscale-native ingress (sketch, after the rollout)

Not part of this rollout. Recorded here so the reasoning doesn't go stale — the
full argument is in [decisions.md](decisions.md#admin-ingress-lan-behind-caddy-today-tailscale-native-next).

The short version: each exposed service gets its own Tailscale node instead of a
Caddy vhost, which deletes Caddy, AdGuard, the Caddyfile generator, the
split-DNS rule and the wildcard rewrite, and gives every service a real
certificate so Secure Context stops being a special case.

**This is a deletion, and it migrates one service at a time.** Both paths work
simultaneously during the transition, so there is no cutover moment and no
rollback cliff. Migrate the least important service first.

Per service:

1. Add a `ts-<name>` sidecar (same shape as `ts-caddy`: reusable non-ephemeral
   auth key, `TS_ACCEPT_DNS=false`, state on appdata, `tag:server`).
2. Move the service to `network_mode: "service:ts-<name>"` and drop its
   `networks:` and loopback `ports:`. The sidecar carries the networks the
   service used to hold.
3. `tailscale serve --bg http://127.0.0.1:<port>` inside that node.
4. Verify `https://<name>.<tailnet>.ts.net` and bare `http://<name>/`.
5. Only then remove its row from `CADDY_SERVICES` and re-run
   `generate-configs.py --force-overwrite`.

When the last row is gone: drop `caddy`, `ts-caddy` and `adguard` from compose,
delete `write_caddy` / `write_adguard` / `CADDY_SERVICES` / `caddy_services()`,
drop the Caddyfile pre-flight from `update-stack.sh`, remove `TAILNET_HOST_IP`
and `CADDY_TAILNET_IP` from `.env`, and delete the split-DNS nameserver rule
from the Tailscale console.

Three things need deciding as part of it, not after:

- **`bootstrap.py` talks to `localhost:<port>`**, which is the only reason eight
  loopback publishes exist. Either keep those publishes (harmless — loopback is
  not reachable from anywhere) or run bootstrap as a container on the
  `automation` + `downloaders` networks and address services by name. The second
  is cleaner and removes the last host-port coupling.
- **Plex and Seerr stay as they are.** Plex is deliberately public on `:32400`
  and bypasses all of this. Seerr is family-facing; it can take a sidecar or
  keep its publish, but it should not keep *both* a publish and a vhost, which
  is the current inconsistency.
- **`ollama-gate` stays.** It enforces policy (403 / 503), not naming. It sits
  behind its own sidecar like anything else.

Cheap fixes worth doing before Phase 5, independent of it:

- Seerr → `127.0.0.1:5055` (it already has `seerr.lan`; the `0.0.0.0` publish is
  leftover).
- Collapse `finance` into `ai` — `actual-ai` has to join `ai` anyway for Ollama,
  so a separate two-member plane may not be earning its keep.

---

## Rollback posture per phase

| Phase | Reversible? |
|-------|-------------|
| 1 | **Hardest.** Image pull migrates DBs one-way; bootstrap rewrites `*arr` rows. Recovery is the Phase 0 backup — runbook Section 5. |
| 2 | Easy. Stop `ollama`/`ollama-gate`/`gpu-arbiter`, revert the merge, regenerate configs. Models re-pull. Note the arbiter fails open by design, so removing it degrades to the static VRAM reservation rather than breaking Plex. |
| 3 | Easy. Stop both containers, `tailscale serve reset`, revert. Budget data is in `/mnt/user/appdata/actual` and reconstructible from bank OFX exports. |
| 4 | Easy. Stop and remove `coach`, revert the merge. Nothing else references it. |

---

## Open item

`/Users/mihirsathe/Documents/finances/selfhost/` — `categories.md` and
`SETUP.md` are referenced by the finance runbook (steps 8 and 10) and live on
the Mac, outside this repo. Nothing in this plan depends on them, but step 8's
"build the category structure **before** the first import" is load-bearing for
categorization quality, so have them open when you get to Phase 3.
