# CLAUDE.md — Home Media Server Repo

Self-hosted media automation stack on Dell PowerEdge R640 + MD1400 DAS, running Unraid Pro. Docker Compose-based, zero open router ports (Cloudflare Tunnel).

---

## Docs

| Doc | Contents |
|-----|----------|
| [docs/hardware.md](docs/hardware.md) | Rack layout, compute, storage, GPU specs |
| [docs/software.md](docs/software.md) | OS, plugins, Docker stack, folder structure, external access, Usenet |
| [docs/deployment.md](docs/deployment.md) | Step-by-step deployment and scheduled maintenance setup |
| [docs/operations.md](docs/operations.md) | Maintenance schedule, diagnostics, monitoring, secret rotation |
| [docs/disaster-recovery.md](docs/disaster-recovery.md) | Recovery procedures: drive loss, appdata corruption, cache fill, tunnel down |
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
    ├── update-stack.sh        ← monthly image-pull + redeploy + health gate
    ├── backup-appdata.sh      ← weekly backup verification + optional offsite copy
    └── restore-appdata.sh     ← interactive restore helper
```

---

## Key Conventions

- **Absolute paths** in `docker-compose.yml` — Compose Manager Plus runs from `/boot`, relative paths break
- **All containers mount `/mnt/user/data` at `/data`** — required for hardlinks to work
- **Networks defined in Compose, not `external: true`** — Docker restarts on every Unraid boot
- **Never commit `.env`** — use `.env.example` as the template

---

## Files on the Server

| File | Server path |
|------|-------------|
| docker-compose.yml | `/mnt/user/appdata/homeserver/homeserver/` |
| App configs | `/mnt/user/appdata/<container-name>/` |
| Downloads in-flight | `/mnt/user/data/usenet/incomplete/` |
| Downloads complete | `/mnt/user/data/usenet/complete/{movies,tv,music}/` |
| Media library | `/mnt/user/data/media/{movies,tv,music}/` |
| Plex database | `/mnt/user/appdata/plex/` |
