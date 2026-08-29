# CLAUDE.md — Home Server Repo

Self-hosted **platform** on Dell PowerEdge R640 + MD1400 DAS, running Unraid Pro. Docker Compose-based. Its tenants — media automation, local LLM inference, personal finance, and a chess webapp — are peers; media is the oldest, not the privileged one. One open router port (TCP 32400 → Plex); every other service is a Tailscale Service (`svc:<name>`) with its own MagicDNS name and certificate, advertised by the host's tailscaled. No reverse proxy. SAB + Prowlarr egress through Gluetun (Mullvad WireGuard) with kill-switch. Ollama shares the transcode GPU with Plex, capped by a static VRAM reservation so Plex always has room.

Also hosts a `finance` plane: Actual Budget with LLM transaction categorization via the in-stack Ollama on the `ai` plane. Makes no outbound internet calls; bank import is deliberately manual (OFX/QFX). Actual needs a Secure Context (`SharedArrayBuffer`), which every service here has — it is fronted by `svc:actual` like every other UI, not by anything special. It was the forcing function for dropping the plain-HTTP ingress; see decisions.md.

And a `cloud` plane: Nextcloud (files, calendar, contacts) with PostgreSQL and Redis, published as `svc:nextcloud`. The plane is closed — nothing else joins it, and neither the database nor the cache publishes a port. It breaks two stack conventions on purpose (container-owned uids, `/mnt/cache` binds — both under Key Conventions below), and it holds the **first data on this box that cannot be re-sourced**, which is why it has its own offsite backup rather than relying on the Appdata Backup plugin. Chosen over Nextcloud AIO, OpenCloud and Seafile; decisions.md records why, so the question doesn't get reopened annually. **Deployed 2026-08-29** (containers up, Nextcloud installed, uids 33/70 verified); `svc:nextcloud` publication and `BACKUP_NEXTCLOUD_REMOTE` are the remaining steps — no real files until the offsite target is set.

---

## Docs

| Doc | Contents |
|-----|----------|
| [docs/hardware.md](docs/hardware.md) | Rack layout, compute, storage, GPU specs |
| [docs/software.md](docs/software.md) | OS, plugins, Docker stack, folder structure, external access, Usenet |
| [docs/deployment.md](docs/deployment.md) | Step-by-step deployment and scheduled maintenance setup |
| [docs/upgrade-2026-07.md](docs/upgrade-2026-07.md) | The live run: catch-up to `master`, ingress move to Tailscale Services, and landing all four tenants in one sitting — with gates and rollback |
| [docs/operations.md](docs/operations.md) | Maintenance schedule, diagnostics, monitoring, secret rotation |
| [docs/disaster-recovery.md](docs/disaster-recovery.md) | Recovery procedures: drive loss, appdata corruption, cache fill, Tailscale/Gluetun outages |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom-driven decision tree for the common breakages |
| [docs/decisions.md](docs/decisions.md) | Why things are the way they are + expansion paths |

---

## Repo Layout

```
CLAUDE.md
docs/                          ← reference documentation
homeserver/
├── docker-compose.yml         ← edit this for stack changes
├── .env.example               ← copy to .env, fill in, never commit .env
└── scripts/
    ├── generate-configs.py    ← run before first boot
    ├── bootstrap.py           ← run once after first boot
    ├── setup-unraid.sh        ← Unraid-specific setup (plugins, shares, folder structure)
    ├── setup-fan-control.sh   ← opt-in iDRAC fan control (run only if needed)
    ├── sync-tailscale-services.py ← create/advertise/approve every svc: (idempotent)
    ├── verify-stack.sh        ← one-command health check (read-only, re-runnable)
    ├── dedupe-hardlinks.py    ← find copied-not-hardlinked media, relink it (dry-run default)
    ├── update-stack.sh        ← monthly image-pull + redeploy + health gate
    ├── backup-appdata.sh      ← weekly backup verification + optional offsite copy
    └── restore-appdata.sh     ← interactive restore helper
```

---

## Key Conventions

- **Absolute paths** in `docker-compose.yml` — the stack is started by a User Script at array boot whose working directory is not guaranteed
- **Every container in the *media* path mounts `/mnt/user/data` at `/data`** — required for hardlinks to work. The non-media tenants deliberately do not: `actual_server` and `coach` rebind `/data` to their own appdata, and Nextcloud's files live on a separate share entirely, so the internet-facing downloaders have no path to them
- **Networks defined in Compose, not `external: true`** — Docker restarts on every Unraid boot
- **Never commit `.env`** — use `.env.example` as the template
- **No Compose Manager plugin** — Unraid ships `docker compose`; we run it from `media_stack_up` User Script instead
- **The Nextcloud plane runs as its images' own users, not `nobody:users`** — `www-data` (33) and `postgres` (70). Every `user: 99:100` pin elsewhere exists because that image ships no `USER` directive; these two drop privileges themselves and *break* if pinned (Nextcloud's entrypoint needs root to chown its volumes and bind `:80`; Postgres can't create its socket as an arbitrary uid). Corollary: **never run Unraid's Tools → New Permissions** with Nextcloud deployed — it chowns everything to `nobody:users` and breaks both. `verify-stack.sh` asserts uid 33/70 positively so this is caught, not ignored.
- **Nextcloud's appdata binds `/mnt/cache/appdata/...`, not `/mnt/user/appdata/...`** — the only departure from the absolute-`/mnt/user` rule. `/mnt/user` is FUSE, and serving one Nextcloud page stats thousands of PHP files. Safe *only* because the appdata share is `shareUseCache=only`, so both paths are the same files; `generate-configs.py` and `verify-stack.sh` both assert that. Don't "tidy" these back.
- **Local-AI consumers join the `ai` network and use `http://ollama:11434`** — access is opt-in — a container has to join it explicitly. Today `actual-ai` and `coach` are the only members besides Ollama itself. Ollama has no auth, so network membership is the access control. The network is declared `name: ai` (not the Compose-prefixed default) so Unraid-template containers can join it from the Docker tab. Ollama is deliberately advertised as no Tailscale Service, so nothing on the tailnet can reach it — it has no authentication, and reaching `:11434` means being able to delete every model on the box.

---

## Files on the Server

| File | Server path |
|------|-------------|
| docker-compose.yml | `/mnt/user/appdata/homeserver/homeserver/` |
| App configs | `/mnt/user/appdata/<container-name>/` |
| Downloads in-flight | `/mnt/user/usenet-incomplete/` (cache-only share, SSD) |
| Actual Budget data | `/mnt/user/appdata/actual/` (SQLite — snapshot with container stopped) |
| Nextcloud app + config | `/mnt/cache/appdata/nextcloud/` (owned by www-data 33 — see Key Conventions) |
| Nextcloud database | `/mnt/cache/appdata/nextcloud-db/` — cluster at `<major>/docker/` inside it (Postgres 18+ layout), owned by postgres 70 |
| Nextcloud db dumps | `/mnt/cache/appdata/nextcloud-dump/` (weekly `pg_dump` from backup-appdata.sh) |
| Nextcloud user files | `/mnt/user/nextcloud/` — own share, array-direct, SMB off. **NOT covered by Appdata Backup**; `BACKUP_NEXTCLOUD_REMOTE` is the only copy |
| Downloads complete | `/mnt/user/data/usenet/complete/{movies,tv,music}/` |
| Media library | `/mnt/user/data/media/{movies,tv,music}/` |
| Plex database | `/mnt/user/appdata/plex/` |
| Ollama models | `/mnt/user/appdata/ollama/` (exclude from Appdata Backup — re-pullable) |
