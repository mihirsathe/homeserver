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

### Admin ingress: `*.lan` behind Caddy today, Tailscale-native next

This was never recorded when it was built, so both halves go here: what the
current design is, and why it's being unwound.

**What exists.** Every admin UI is a plain-HTTP vhost at `<name>.lan` on a
single Caddy, reached over the tailnet. Three pieces make that work: Caddy
routes by `Host` header to each backend's docker-DNS name; AdGuard Home answers
`*.lan` with a wildcard rewrite; and a Tailscale split-DNS rule restricted to
the `lan` domain sends those queries to AdGuard. Backends bind `127.0.0.1` only,
so Caddy is the sole ingress. Caddy itself runs inside a `ts-caddy` sidecar's
network namespace, giving it a tailnet address of its own — because the Unraid
web GUI owns the host's `:80` and must keep it, being the one admin surface that
survives Docker being down.

Two costs surfaced only after the pieces were assembled.

**`auto_https off` forecloses Secure Context, which is not the same as
"unencrypted."** The original reasoning — Tailscale already provides
authenticated, encrypted transport, so TLS on top would only buy a private CA to
install on every device — is correct about *eavesdropping* and wrong about
*browser capability*. Browsers gate a widening set of APIs on Secure Context,
not on whether the bytes are encrypted in transit. Actual Budget is the first
service here that simply will not load over plain HTTP (its SQLite engine needs
`SharedArrayBuffer`), and it required building a second, parallel ingress path —
`tailscale serve` on the host node — for exactly one app. Service workers,
WebCrypto's subtle API and WASM threads sit behind the same gate. Actual is not
an exception to the design; it is the design's first bill arriving.

**The mechanism count grew without anyone choosing it.** Reaching a service now
has five different answers: Caddy vhosts, the Unraid GUI on host `:80`,
`tailscale serve` on host `:443`, raw `0.0.0.0` publishes (Plex, Seerr,
AdGuard), and eight loopback publishes that exist only so `bootstrap.py` can
talk to `localhost:<port>` from the host. Each was locally correct. They do not
compose, and the drift shows: Seerr is published on `0.0.0.0:5055` *and* has a
`seerr.lan` vhost.

**Direction: give each exposed service its own Tailscale node and delete the
middle layer.** The repository already proves both halves independently —
`ts-caddy` proves the sidecar pattern, and the finance plane proves
`tailscale serve` provisions free, auto-renewing, publicly-trusted certificates
for a node's MagicDNS name. Generalising that removes Caddy, AdGuard, the
Caddyfile generator, `CADDY_SERVICES`, the split-DNS console rule, the wildcard
rewrite, and `CADDY_TAILNET_IP` bookkeeping. Every service gets a real
certificate, so Secure Context stops being a special case. ACLs become
per-service (`tag:admin → tag:radarr:443`) instead of one blunt port list. Host
port contention stops existing. Ergonomics likely improve rather than regress:
MagicDNS puts the tailnet domain in the client search path on most platforms, so
bare `http://radarr/` resolves — shorter than `radarr.lan`.

The cost is one sidecar container per exposed service (~30 MB each, noise
against 32 GB), a reusable auth key, a state directory per sidecar, and one
tailnet device each against the plan's cap.

**Alternative considered: a real domain plus a wildcard certificate.**
`*.home.<domain>` via Cloudflare DNS-01 keeps a single Caddy and a single cert,
and also solves Secure Context. Rejected for this box because Caddy here
performs no middleware — no auth, no rate limiting, nothing shared. It is doing
hostname-to-port mapping, which MagicDNS does for free. The domain approach
becomes the better answer if a genuine central policy point is ever wanted, and
it is the right choice for anyone not already all-in on Tailscale.

**Nothing in the stack needs a reverse proxy for its own sake.** An earlier
draft of this entry expected `ollama-gate` — a policy-enforcing Caddy in front
of the inference engine — to survive as the one proxy that earned its keep. That
service was removed from PR #17 before merge; Ollama is loopback-only on a
private bridge, so network membership is its access control. With it gone,
Caddy's entire remaining job here is hostname-to-port mapping, which is exactly
the job MagicDNS does for free. If a genuine policy point is ever wanted — auth,
rate limiting, shared middleware — that is the argument for reintroducing a
proxy, and it should be made on those terms rather than inherited from naming.

**Not yet.** Four changes are in flight against a deployment still running its
first-setup state; re-architecting ingress mid-rollout means re-testing
everything at once. It is also a deletion, and deletions migrate incrementally —
a sidecar can be stood up for one service and verified while its Caddy vhost
still works, so the two paths coexist during the transition. Sequenced as
Phase 5 in [rollout-2026-07.md](rollout-2026-07.md).

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
| GPU upgrade to RTX 4000 series | AV1 encode + more VRAM for 6+ 4K streams | Must be LP form factor |
| RAM to 128 GB+ | Comfortable headroom for everything | DDR4 RDIMM, verify DIMM config for 6146 dual-socket |
| Second MD1400 | 12 more drive bays via daisy-chain | LSI 9300-8e supports it; drops into U5–6 |
| Managed switch + 10G LAN | Saturate X710 SFP+; dedicated networking rack; VLAN segregation | Candidate: **Ubiquiti USW-Pro-Max-16** (12×1GbE + 4×2.5GbE + 2×10G SFP+, fanless, UniFi-managed) — SFP+ #1 → R640 X710, SFP+ #2 → uplink to networking rack. Alternatives considered: USW-Enterprise-8-PoE (bundled PoE is wasted here), MikroTik CRS310-8G+2S+IN ($50 cheaper but loses UniFi integration), USW-Flex-2.5G-8 (only one SFP+, can't do both 10G server and 10G uplink simultaneously). |

### Architectural changes (if needs change significantly)

| Change | Why you'd do it | Tradeoff |
|--------|----------------|---------|
| Plex → Jellyfin | Eliminate Plex account + data collection | Less polished clients, no Plex Pass features |
| Add Ansible on top of Compose | Full server config-as-code including Unraid settings | Significant complexity for a single server |
| Add a second VPN exit or wire *arr through the tunnel too | Reduce traffic-analysis surface further | Breaks *arr → SAB container-to-container routing; unnecessary once SAB + Prowlarr are VPN'd |
