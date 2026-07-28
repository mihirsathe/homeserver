# Decisions

Why things are the way they are. Read before changing something you haven't touched recently.

---

## Software Architecture

### Unraid over TrueNAS / SnapRAID

Mixed drive sizes (16 TB parity, 8 TB data) and the ability to add single drives without rebuilding. TrueNAS/ZFS requires matched VDEV sizes. Unraid's parity model is uniquely suited to this hardware.

### BOSS card for boot

More reliable than a USB flash drive (cheap NAND, physical wear prone to failure). RAID1-mirrored M.2 SATA in a dedicated slot — doesn't consume a riser slot, survives one M.2 failure without downtime.

### Docker Compose over native Unraid templates

Config-as-code. The entire stack is one file that can be version-controlled, diff'd, and reproduced from scratch. Unraid's native template system stores config in opaque XML on the boot USB.

### hotio images (except Plex)

Consistent `PUID`/`PGID`/`UMASK` pattern across all containers, lean builds. Plex uses `plexinc/pms-docker` because only the official image supports `PLEX_PREFERENCE_*` env vars and the nvidia runtime properly.

### Plex port-forward + Tailscale admin plane (no Cloudflare)

One port open on the router — **TCP 32400 → Plex** — and nothing else. Plex ships its own wildcard TLS (`*.plex.direct`, provisioned per-server by Plex Inc.), so there's no cert to manage and no reverse proxy in the path. Native Plex clients negotiate direct-connect via `app.plex.tv`, so a public URL like `plex.yourdomain.com` buys nothing.

Cloudflare Tunnel was considered and rejected:

- Cloudflare's Service-Specific Terms §2.8 bar streaming video on free/pro plans; Plex through Tunnel is an enforceable ToS violation.
- `plex.tv` already publishes the server's WAN IP for direct-connect regardless of what's in front of it — the tunnel doesn't hide the origin.
- Third-party SaaS (account phish, pipeline compromise, Access-policy misconfig) becomes a single point of failure for all external access.

Admin services (*arr, SAB, Prowlarr, Seerr, Bazarr, Tautulli, Unraid webUI) are reachable only via **Tailscale**. Admin devices join the tailnet, tag themselves `tag:admin`, and ACLs allow `tag:admin → tag:server` on the specific admin ports. Tailscale SSH replaces standalone SSH on the Unraid host. The admin plane is not reachable from the public internet at all.

### Prowlarr over Jackett

Same Servarr team as Radarr/Sonarr, native API integration that auto-syncs indexers to all apps, actively developed. Jackett is effectively in maintenance mode.

### SABnzbd over NZBGet

Actively developed, better UI, better category handling. NZBGet development has significantly slowed. CPU headroom is not the constraint on this hardware.

### SAB incomplete on cache-only share, complete on array

`usenet-incomplete` is a cache-only Unraid share; `data/usenet/complete` lives on the array. Active downloads, par2 repair, and unrar thrash the incomplete dir — doing that on spinning 8 TB disks is 10–20× slower than SSD, and Unraid's `shareUseCache=yes` on the main data share only helps until mover moves things off. `shareUseCache=only` on the incomplete share guarantees mover never touches it.

Completed files move cross-filesystem from SSD → array exactly once, then live alongside `data/media` (same array filesystem) where hardlinks from the *arr apps work normally. The only cost is one extra copy per download; the saving is the whole unpack/repair cycle.

### Profilarr for quality profiles + custom formats

Radarr and Sonarr ship with generic quality rules. Out of the box they grab the first release that clears a size/resolution filter — no scoring for release-group pedigree, HDR/DV handling, x265 cost, REMUX vs WEB-DL preference, etc.

Two tools cover this gap:
- **Recyclarr** — a headless CLI that pulls [TRaSH Guides](https://trash-guides.info/) YAML templates and pushes them to the *arrs via API. Single data source (TRaSH), YAML-declarative, no UI.
- **Profilarr** — a web app from the [Dictionarry-Hub](https://github.com/Dictionarry-Hub/profilarr) project that subscribes to one or more curated databases (its own Dictionarry DB, TRaSH, others), previews diffs in a GUI, and syncs selected profiles/formats to the *arrs.

The stack uses Profilarr. The deciding factors: the GUI gives a diff preview before each sync instead of pushing blind, Profilarr can blend multiple curated sources (not just TRaSH) if the Dictionarry DB keeps ahead of a particular format, and it cleanly handles a future 4K-vs-1080p split if one is ever added. Cost: Profilarr is not declarative — its subscription state lives in a SQLite DB configured through the web UI, which makes it the one piece of the stack that isn't fully bootstrap-scripted. The initial setup step is documented in [deployment.md](deployment.md) and the appdata directory is covered by the weekly Appdata Backup so the state survives a rebuild.

Do **not** run Profilarr alongside Recyclarr: they will overwrite each other's scores on every sync cycle.

### Seerr over Overseerr

Overseerr's upstream is unmaintained (last release 2023). **Seerr** is the actively-developed successor that merges the Overseerr and Jellyseerr lineages into one codebase. Its settings schema is a compatible superset of Overseerr's, so config artefacts and migration paths line up if we ever had to go back. New deployments take Seerr from day one — there is no Overseerr stage to migrate out of.

Seerr's image runs as the `node` user (UID 1000) by default and doesn't read `PUID`/`PGID`, but Docker's `user:` directive overrides it cleanly — the stack runs Seerr as `${PUID}:${PGID}` (99:100, Unraid's `nobody:users`) so its appdata ownership matches every other container. `init: true` is set in compose to reap Node's zombie children. No post-boot `chown` is required; `generate-configs.py` creates `/mnt/user/appdata/seerr` owned by `nobody:users` before first start.

### Plex Watchlist auto-request as the family interface

Seerr's web UI is an admin tool, not a family-facing portal. Family members already have the Plex app; they use its built-in "Add to Watchlist" button. Seerr polls the Plex Watchlist API every two minutes and auto-submits matching entries as Radarr / Sonarr requests (the admin grants `AUTO_REQUEST` permission per user in Seerr). This removes the need to publish any request portal on the public internet — one less service to expose, one less auth boundary, one less public URL to keep family members from forgetting. 4K requests still require manual approval in Seerr by design.

### Gluetun (Mullvad WireGuard) in front of SAB + Prowlarr

SSL over Usenet encrypts **content**, not metadata. The ISP still sees a sustained multi-MB/s TLS flow to a Usenet provider's ASN on port 563, and the provider's SNI is plaintext in the TLS ClientHello. Usenet providers keep connection logs regardless.

`Gluetun` with Mullvad WireGuard (`FIREWALL=on` kill-switch) replaces the home-WAN egress for SAB and Prowlarr only: `network_mode: "service:gluetun"` puts them inside Gluetun's network namespace, so their outbound traffic has to go through the VPN or nowhere. The kill-switch blocks the "VPN drops → traffic leaks" failure mode. Mullvad accepts Monero and doesn't require identifying information for an account.

This reverses an earlier position in this file that called Gluetun "unnecessary for Usenet (already SSL-encrypted)." That framing conflated confidentiality with traffic analysis; both matter here.

### Local AI on the transcode GPU

Running Ollama on the same RTX 3050 that Plex transcodes on means picking a policy for a shared, non-partitionable resource. The policy is: **Plex always wins, and the contention is about VRAM, not compute.**

NVENC and NVDEC are dedicated ASIC blocks on the die. A CUDA inference workload doesn't steal encoder time from them; what it *does* steal is VRAM capacity, and the card has 6 GB. So every mechanism in the design caps Ollama's memory footprint rather than trying to schedule GPU compute.

**Static reservation is the primary mechanism, not preemption.** `OLLAMA_GPU_OVERHEAD` reserves 1.5 GiB that Ollama will never allocate into. It needs no daemon, survives every other component failing, and — critically — degrades gracefully: a model that doesn't fit in the remaining ~4.5 GB gets its overflow layers placed on CPU rather than OOMing the card. With a 3–4B model at ~2.5 GB and a 4K HDR transcode at ~1 GB, the common case has no conflict at all. Preemption exists for the tail (a 7B model plus three simultaneous 4K streams), which is why it's allowed to be a best-effort, 5-second-granularity poll loop instead of something that has to be exactly right.

**Why poll Plex instead of watching `nvidia-smi`.** Device-level NVENC session counters are unreliable on GeForce parts, and they only tell you the encoder is already running. Plex's session list is authoritative, distinguishes a real re-encode from a Direct Play or Direct Stream (neither touches the encoder), and is the same API Tautulli already reads. The cost is a dependency on `PLEX_TOKEN`.

**The arbiter fails open, deliberately.** No token, Plex unreachable, or a malformed response means no hold and Ollama keeps serving. Failing closed would mean an expired Plex token silently bricks local AI for every container on the stack — in order to protect against a contention case the static reservation already covers. A stale hold from an unclean stop is cleared at startup and released on SIGTERM, because nothing else on the stack would ever remove that file.

**Why a gate container instead of exposing Ollama directly.** Ollama has no authentication and no read-only mode: reaching `:11434` means being able to delete every model on the box. It also has no notion of "don't use the GPU right now." Both gaps are closed by fencing the engine onto a private network with no published port and putting a small Caddy in front, which 403s the model-management endpoints and 503s inference while the hold file exists. Using Caddy's `file` matcher for the hold means the arbiter and the gate need no control socket, no shared secret, and no way to authenticate to each other — one creates a file, the other stats it. The gate mounts the directory read-only.

**Consumers get the gate, not the engine.** If containers could reach Ollama directly they could load a model mid-transcode and the arbitration would be advisory. So the engine's DNS name doesn't exist on the consumer network at all, and a container that guesses `http://ollama:11434` gets NXDOMAIN — a loud failure rather than a silent bypass.

**Tailnet-only, matching every other admin service.** `ollama.lan` goes through Caddy like the *arrs; nothing binds `0.0.0.0` and the router still forwards only 32400. Ollama is not exposed to the LAN. That's a deliberate match to the existing trust model (tailnet membership is the boundary), not a technical constraint — publishing on the LAN would be a one-line change if the trust model ever changed.

**Considered and rejected: a CPU-only fallback instance.** A second, GPU-less Ollama that the gate routes to during a hold would degrade instead of 503ing, and the dual Xeon 6146s (24c/48t) would manage roughly 15–20 tok/s on a 3B model. It was dropped because it doubles the Ollama surface area and adds a second 8 GB memory ceiling on a box where [32 GB RAM is already the documented constraint](hardware.md#compute--dell-poweredge-r640) — to buy availability during a window that the static reservation makes rare and that hysteresis already keeps short. Worth revisiting after a RAM upgrade.

**q8_0 KV cache is on by default.** KV cache VRAM scales linearly with context length and can exceed the weights themselves at 16K context on a 6 GB card. Quantising it to q8_0 halves that for a quality difference that isn't measurable at 3–8B. It requires flash attention, which is enabled unconditionally. `OLLAMA_KV_CACHE_TYPE=f16` in `.env` opts back out.

### Single parity (for now)

Four 8 TB drives is a modest start. Single parity is appropriate. Dual parity becomes more valuable as drive count and total data grow. Upgrade: add a second 16 TB drive as Parity 2 when convenient.

---

## Compose Conventions

### Absolute paths everywhere

The stack is started by a User Script (`media_stack_up`) at array boot. Scripts invoked by Unraid's User Scripts plugin do not get a guaranteed working directory, so every volume mount uses its full `/mnt/user/...` path rather than relying on a relative `./configs/` resolving correctly.

### Networks defined in Compose, not `external: true`

Unraid restarts Docker on every boot. External networks would need to be recreated by a User Script before the array starts every time. Letting Compose own the networks is simpler — they're created on `compose up` and survive as long as the stack exists.

---

## Rack / Hardware

### Direct-to-router over a managed switch (for now)

The R640 connects straight to the home router via 1GbE. A managed switch is documented as a future upgrade (below) rather than a current component — one port on the home router is enough for a single-host stack, and the X710 10GbE SFP+ ports on the R640 daughter card aren't saturated by any current workload. Upgrading to a managed switch only becomes worthwhile when a second host or multi-gig client transfers enter the picture.

### No PDU

The UPS has enough outlets for the current device count (R640, MD1400). A PDU adds cost and complexity for no benefit at this scale.

### No patch panel

Two runs (R640 NIC + iDRAC) — direct patch cables are cleaner than terminating to a panel. A panel makes sense at 8+ runs, which only applies to the future networking rack.

### UPS at the bottom

Heaviest component in the rack. Low center of gravity improves physical stability.

### Thermal breaks (U9, U11)

Vented blanks between the R640 and MD1400, and above the R640. The R640 intakes from the front and exhausts out the rear — thermal breaks prevent exhaust from preheating adjacent equipment intakes.

---

## Expansion Paths

### Near-term, low effort

| Upgrade | Benefit |
|---------|---------|
| Add Parity 2 (16 TB) | Survive 2 simultaneous drive failures |
| Add RAM (e.g. 4× 32 GB → 128 GB) | Headroom under heavy concurrent load |
| Fill MD1400 bays 6–12 | Up to 7 more drives (max 16 TB each, constrained by parity disk size) |

### Medium-term

| Upgrade | Benefit | Notes |
|---------|---------|-------|
| Second Usenet provider (different backbone) | Better completion on older/obscure content | ~$5–10 block account |
| Additional NZB indexers (DrunkenSlug, NZBFinder) | More search coverage | $10–15/yr each |
| Replace R640 bays 1–8 with NVMe | Faster scratch storage, more appdata headroom | May need NVMe backplane adapter |

### Longer-term

| Upgrade | Benefit | Notes |
|---------|---------|-------|
| GPU upgrade to RTX 4000 series | AV1 encode + more VRAM for 6+ 4K streams, and enough headroom that Ollama and Plex stop competing for VRAM at all | Must be LP form factor. At 12–16 GB the GPU hold becomes vestigial — raise `OLLAMA_GPU_OVERHEAD_BYTES` and leave the arbiter running as cheap insurance |
| CPU-fallback Ollama instance | Local AI degrades to CPU during a transcode instead of returning 503 | Needs the RAM upgrade first — see "Local AI on the transcode GPU" above |
| RAM to 128 GB+ | Comfortable headroom for everything | DDR4 RDIMM, verify DIMM config for 6146 dual-socket |
| Second MD1400 | 12 more drive bays via daisy-chain | LSI 9300-8e supports it; drops into U5–6 |
| Managed switch + 10G LAN | Saturate X710 SFP+; dedicated networking rack; VLAN segregation | Candidate: **Ubiquiti USW-Pro-Max-16** (12×1GbE + 4×2.5GbE + 2×10G SFP+, fanless, UniFi-managed) — SFP+ #1 → R640 X710, SFP+ #2 → uplink to networking rack. Alternatives considered: USW-Enterprise-8-PoE (bundled PoE is wasted here), MikroTik CRS310-8G+2S+IN ($50 cheaper but loses UniFi integration), USW-Flex-2.5G-8 (only one SFP+, can't do both 10G server and 10G uplink simultaneously). |

### Architectural changes (if needs change significantly)

| Change | Why you'd do it | Tradeoff |
|--------|----------------|---------|
| Plex → Jellyfin | Eliminate Plex account + data collection | Less polished clients, no Plex Pass features |
| Add Ansible on top of Compose | Full server config-as-code including Unraid settings | Significant complexity for a single server |
| Add a second VPN exit or wire *arr through the tunnel too | Reduce traffic-analysis surface further | Breaks *arr → SAB container-to-container routing; unnecessary once SAB + Prowlarr are VPN'd |
