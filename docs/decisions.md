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

### Admin ingress: Tailscale Services, no reverse proxy

**Decided and implemented.** An earlier revision of this entry sequenced this
as a deferred "Phase 5". That deferral is withdrawn — the reasoning is below,
including why deferring turned out to cost more than doing it.

**What existed.** Every admin UI was a plain-HTTP vhost at `<name>.lan` on a
single Caddy. Three mechanisms made that work: Caddy routed by `Host` header
to each backend's docker-DNS name; AdGuard Home answered `*.lan` with a
wildcard rewrite; and a Tailscale split-DNS rule sent `.lan` queries to
AdGuard. A fourth propped it up — Caddy could not bind the host's `:80`
(Unraid's GUI owns it), so it ran inside a `ts-caddy` sidecar's network
namespace to get a tailnet address of its own.

**Why it was replaced.**

*`auto_https off` forecloses Secure Context, which is not the same as
"unencrypted."* The original reasoning — Tailscale already provides
authenticated, encrypted transport, so TLS on top would only buy a private CA
to install on every device — is correct about *eavesdropping* and wrong about
*browser capability*. Browsers gate a widening set of APIs on Secure Context,
not on whether bytes are encrypted in transit. Actual Budget will not load
over plain HTTP at all (its SQLite engine needs `SharedArrayBuffer`), and it
forced a second, parallel ingress path — `tailscale serve` on the host — for
exactly one app. Service workers, WebCrypto's subtle API and WASM threads sit
behind the same gate. Actual was not an exception to the design; it was the
design's first bill arriving.

*The mechanism count grew without anyone choosing it.* Reaching a service had
five answers: Caddy vhosts, the Unraid GUI on host `:80`, `tailscale serve` on
host `:443`, raw `0.0.0.0` publishes, and loopback publishes for
`bootstrap.py`. Each was locally correct; they did not compose. The drift
showed — Seerr was published on `0.0.0.0:5055` *and* had a `seerr.lan` vhost.

**What replaced it.** Each exposed service is a Tailscale Service (`svc:<name>`)
advertised by the host's existing tailscaled. Each gets a TailVIP, a MagicDNS
name and a real auto-renewing certificate. This deletes Caddy, `ts-caddy`,
AdGuard, the Caddyfile, `write_caddy()`, `write_adguard()`, `CADDY_SERVICES`,
`CADDY_TAILNET_IP`, `TS_AUTHKEY` and the split-DNS console rule.

**Why Services rather than a Tailscale sidecar per container.** Both give every
service its own name and certificate. The deciding factor was blast radius in
the compose file. Under the sidecar model a backend joins its sidecar's netns
via `network_mode: service:ts-<name>`, which means it *loses its own*
`networks:` — so each sidecar has to replicate its backend's plane membership
(Radarr still needs to reach Prowlarr and SAB). That is a rewrite of every
service's internal networking, plus one container and one state directory each.
Services needs none of it: the host daemon already exists, and the loopback
publishes it proxies to were already there for `bootstrap.py`. The compose
change is a pure deletion.

Services also improves the emergency path. Caddy was a *container*, so Docker
trouble took every admin UI with it. The host daemon survives Docker entirely —
you lose backends, not the route to them.

The costs: Tailscale Services is in public beta, and service definitions plus
host approval live in the admin console rather than in this repo. The second is
mitigated by a huJSON serve-config file and by `autoApprovers` keyed on
`tag:server` in the ACL policy, both of which are versionable.

**Alternative considered: a real domain plus a wildcard certificate.**
`*.home.<domain>` via Cloudflare DNS-01 keeps a single Caddy and one cert, and
also solves Secure Context. Rejected *for now* because Caddy here performs no
middleware — it maps hostnames to ports, which MagicDNS does for free. The
domain becomes the better answer when any one of these fires:

1. A non-Tailscale person needs *routine* access to something. One-off sharing
   is covered by Tailscale Funnel without a domain.
2. Single sign-on across services is wanted. This is the big one, and it is
   also what brings a reverse proxy back — a proxy earns its place as a policy
   point, never as a naming layer.
3. Something external must call in: webhooks, OAuth redirect URIs.
4. Vendor independence — today the URLs contain `ts.net`.

None are true today. Buying the domain early is still cheap insurance: the
expensive part was never the registration, it is re-teaching every device and
person a new set of URLs. A domain does not replace Tailscale either; the
tailnet stays the transport for everything private.

**Plex is deliberately untouched by all of this.** It keeps its single
forwarded port, its own authentication and its own `*.plex.direct`
certificates. Proxying it would add a hop and break direct-connection
negotiation, and Funnel's relayed bandwidth is unsuitable for video.

**AdGuard was deleted rather than kept.** Its wildcard rewrite existed to serve
Caddy, and ad-blocking was configured but dormant — split DNS only routed
`*.lan` to it, so it filtered nothing. Keeping it would have meant adding a
loopback publish for its admin UI and pointing the tailnet's *global* DNS at a
container, making name resolution for every device depend on Docker being up —
the same class of mistake as putting the Unraid GUI behind Caddy. Network-wide
ad-blocking, if wanted later, is a clean standalone decision.

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
