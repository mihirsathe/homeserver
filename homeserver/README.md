# homeserver

Self-hosted media automation on Unraid. Usenet → SABnzbd → Radarr/Sonarr → Plex, with Seerr auto-requesting from Plex Watchlist. SAB + Prowlarr egress through Gluetun (Mullvad WireGuard) with kill-switch.

One open router port (TCP 32400 → Plex); all admin UIs reachable only via Tailscale. No UI wizards — every app's config is pre-seeded before first boot.

---

## Quick Deploy

```bash
cp .env.example .env                                       # fill in credentials
python3 scripts/generate-configs.py                        # interactive — prompts for anything missing
docker compose --env-file .env.docker up -d                # .env.docker = .env + generated.env, written above
python3 scripts/bootstrap.py                               # wire everything together
```

Full walkthrough: [docs/deployment.md](../docs/deployment.md)

---

## Docs

- [Hardware](../docs/hardware.md) — rack, compute, storage, GPU
- [Software](../docs/software.md) — OS, Docker stack, external access, Usenet
- [Deployment](../docs/deployment.md) — step-by-step setup
- [Operations](../docs/operations.md) — maintenance, diagnostics, monitoring, secret rotation
- [Disaster recovery](../docs/disaster-recovery.md) — drive / appdata / cache / tunnel failure recovery
- [Troubleshooting](../docs/troubleshooting.md) — symptom-driven decision tree
- [Decisions](../docs/decisions.md) — design rationale and expansion paths
