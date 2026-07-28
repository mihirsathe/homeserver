# Integration Brief — working state

Scratch document for the in-flight integration effort. **Delete once the work
lands.** Not in the site nav; this is working state, not reference documentation.

Written to survive context compaction: a fresh session should be able to pick up
from this file alone.

---

## 1. What we're doing

The server ran as a media stack for a few months. It is now becoming a
**general-purpose self-hosted platform** whose first tenants happen to be media,
local LLM inference, personal finance, and a personal chess webapp.

Two gaps are being closed at once:

- **Repo↔server drift.** The box is frozen at first-setup. Every PR since —
  bootstrap fixes, arr auth, the whole Caddy/AdGuard ingress layer — was merged
  but never deployed. That's why the invalid Caddyfile went unnoticed for months.
- **Four parallel changes.** Ollama, finance, chess, and the ingress rework were
  each built in separate agent sessions without the others in view. Nobody
  producing them holds the whole picture.

## 2. Goals, in the owner's terms

1. **One shot, live.** Not phased across days. Owner will be at a browser logged
   into the server; we walk through it together in one sitting. An earlier
   phased plan (`rollout-2026-07.md`) is **superseded** on this point — its
   technical findings still stand, its Phase 1/2/3/4 sequencing does not.
2. **All tenants are equal first-class citizens.** Media is not privileged.
   Finance, AI and chess are peers, not bolt-ons. This has teeth — see §5.
3. **Deep review before execution.** Explicitly requested, and to be re-run
   immediately before the live session because other agents keep pushing.
4. **Data safety is the top constraint.** Cold backup first. Stopping the array
   is acceptable. Nothing may clobber `/mnt/user/data` or appdata.
5. **Access safety is second.** The Unraid GUI must stay reachable at its normal
   URL, independent of Docker — it is the emergency path. Owner pushed back
   twice on anything that weakened it; that pushback was correct.
6. **Ergonomics are not optional.** Clean hostnames, no port suffixes.
7. **Comprehensibility.** Reasoning gets written down (`decisions.md`),
   including the rejected options.

## 3. Where the PRs are

Repo: `mihirsathe/homeserver`. All four branch from `master` = `fb50978`
(unchanged since 2026-07-23; nothing has been merged).

```bash
git fetch --all --prune
```

| PR | Branch | Adds |
|----|--------|------|
| — | `claude/homeserver-upgrade-deployment-tj4vgf` | **ours** — catch-up runbook, ingress rework, Caddyfile fix, docs |
| #15 | `add-chess-coach` | `coach` service, `coach.lan`, GPU (phase 2), local build from a private repo |
| #16 | `feat/finance-plane` | `actual_server` + `actual-ai`, `finance` plane, `tailscale serve` for HTTPS |
| #17 | `claude/ollama-plex-gpu-sharing-7mjmd0` | `ollama` on an `ai` plane, loopback-only, plus an independent Caddyfile fix |

**These branches move.** Re-fetch and re-read diffs at the start of the review;
do not trust SHAs or PR descriptions recorded here.

SHAs as of this writing (2026-07-28, for drift detection only):
`ours e37dd66` · `#15 e6d9b52` · `#16 5f593b2` · `#17 2cdbdc5`

**Read diffs, not PR bodies.** Both #16 and #17 have already shipped
descriptions that didn't match their diffs. #17 has been redesigned twice —
an earlier revision had an `ollama-gate` Caddy proxy, a `gpu-arbiter` daemon and
an `ai_backend` network, all since removed. Both descriptions appear accurate as
of now, but verify rather than assume.

## 4. GPU and capacity — the owner's framing, which is better than mine

Three services request the nvidia runtime on one **RTX 3050, 6 GB**: `plex`
(NVENC), `ollama`, `coach` (lc0/Maia, its phase 2 — not at first deploy).

The contended resource is **VRAM, not compute** — NVENC/NVDEC are dedicated ASIC
blocks, so inference never steals encoder time.

Critically: **only Plex is bursty, and even transcoding is rare.** The other two
are not merely intermittent, they're *schedulable* — `actual-ai` runs a 4-hourly
cron, `coach`'s deep passes are pinned to 1–7am, and Ollama evicts its model
after 60s idle. So the design should lean on **scheduling the controllable
tenants out of prime viewing hours**, with PR #17's 2 GiB `OLLAMA_GPU_OVERHEAD`
reservation covering accidental overlap. Do *not* frame this as a continuous
contention problem needing headroom — earlier drafts did and it was wrong.

Model sizing follows from the reservation: 2 GiB reserved on a 6 GB card leaves
~4 GB, so `llama3.2:3b` (~2.5 GB) fits and `llama3.1:8b` (~5 GB at q4) silently
spills layers to CPU. The finance install runbook says 8b; it should say 3b.

RAM: memory *limits* summed to **31.2 GB on a 32 GB box** at last measurement
(Plex 8 + Ollama 8 + coach 6). Limits are ceilings, not reservations, and given
the burstiness above this is less alarming than it looks — but re-measure, and
Ollama's 8 G ceiling is the first to trim.

## 5. "First-class citizens" has architectural teeth

The current design says otherwise in ways worth fixing as part of this work:

- Network planes are named in media vocabulary: `frontend`, `automation`,
  `downloaders`.
- `CLAUDE.md` opens with "media automation stack."
- **Three tenants, three ingress patterns**: finance invented its own via
  `tailscale serve`, Ollama has no ingress at all, chess slots into the media
  `frontend` behind Caddy. A platform would have one pattern all tenants use.

This is an argument for pulling the **Tailscale-native ingress** work
(`decisions.md` → "Admin ingress", currently sketched as a deferred Phase 5)
into this change rather than deferring it: give every service its own tailnet
node and real cert, and finance stops being an exception. **Open question for
the review — raise it, don't assume it.**

## 6. Verified findings that must not be lost

- **The generated Caddyfile on `master` is invalid.** Verified against a real
  caddy 2.8.4 binary: `File to import not found: common;`. The Caddyfile grammar
  has no statement separator, so `{ import common; reverse_proxy x:1 }` rejects
  the *entire* file. Caddy refuses to start; `update-stack.sh` pre-flight
  aborts. Fixed on our branch **and** independently in PR #17 (block form, one
  directive per line). `master` is undeployable without it.
- **Unraid's web GUI owns host `:80`** and must keep it. Caddy therefore runs in
  a `ts-caddy` Tailscale sidecar's netns and binds `:80` on that node's own
  tailnet IP, publishing nothing on the host. `unraid.lan` exists as a
  convenience alias only — never the guaranteed path.
- **On Unraid, stopping the array stops Docker** (`docker.img` is loop-mounted
  from a pool at `/var/lib/docker`). Not true of generic Linux. This is why the
  GUI must not sit behind Caddy.
- **`actual-ai` can't reach Ollama as written.** PR #16 predates #17 and assumes
  an external Ollama; `actual-ai` lands on `finance` alone. Needs `ai` added to
  its networks and `OLLAMA_URL=http://ollama:11434/api`. Fails silently — it
  logs and retries forever by design.
- **`actual-ai` has no healthcheck**, so `update-stack.sh`'s gate only checks
  that it's running. Read its logs after deploy.
- **PR #15 clones a private repo onto the server** — needs a deploy key or PAT
  on the box, which the PR doesn't cover.
- **`update-stack.sh` will never update `coach`** — it's a `build:` service with
  no `image:`, so the monthly pull skips it. Updates are `git pull` + rebuild.
- **PR #17's `ai` network is declared `name: ai`** (no compose project prefix)
  deliberately, so Unraid-template containers can join it. Load-bearing.

## 7. Execution format

**I cannot reach the server from this session.** The live run is a paste-back
loop: I give a command, the owner runs it and pastes output, I read it and give
the next. SSH from the Mac is easier to copy from than the Unraid web terminal.

The one thing that stays sequenced inside the single sitting: the `*arr` DB
rewrite (`bootstrap.py` reconcile) plus the image pull is the only genuinely
one-way step. It needs a green check before the new services land on top — a
gate within the session, not a separate day.

## 8. State of our branch

`claude/homeserver-upgrade-deployment-tj4vgf`, clean and pushed. Contains:

- `docs/upgrade-2026-07.md` — catch-up runbook (safety checks, deploy, verify,
  rollback). Section 2's pre-flight checks are still exactly right and should be
  reused verbatim.
- `docs/rollout-2026-07.md` — sequencing. **Phasing superseded by the
  single-shot decision**; its measured conflicts, capacity figures and
  integration gaps remain valid but need re-measuring.
- `docs/decisions.md` — ingress architecture entry + Tailscale-native direction.
- Compose: `ts-caddy` sidecar, Caddy off host ports, `unraid.lan` route.
- `generate-configs.py`: Caddyfile block-form fix, `caddy_services()`,
  `CADDY_TAILNET_IP` for AdGuard's wildcard, `TS_AUTHKEY` prompt.

## 9. What the deep review must produce

1. Fresh fetch; re-read all four diffs; re-verify every PR claim against its diff.
2. A **real four-way merge** with conflicts resolved by judgment, not
   mechanically — then compose parse, Caddyfile validate against a real binary,
   full port/network/volume/GPU/RAM map of the result.
3. A verdict on §5: does the merged compose treat the tenants as peers, and
   should the Tailscale-native ingress land now?
4. One consolidated command sequence for the live run, with its gates and its
   single one-way checkpoint.
5. Explicit list of everything that needs owner input mid-run (auth keys, Plex
   token, Actual budget Sync ID, private-repo credentials, Tailscale console
   changes) so none of it is discovered live.

**Do not start until the owner says go** — other agents are still pushing to
these PRs.
