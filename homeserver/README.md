# homeserver

Self-hosted media automation on Unraid. Usenet → SABnzbd → Radarr/Sonarr/Lidarr → Plex, with Overseerr for family requests and Cloudflare Tunnel for remote access.

No open router ports. No UI wizards — every app's config is pre-seeded before first boot.

---

## Quick Deploy

```bash
cp .env.example .env                                       # fill in credentials
python3 scripts/generate-configs.py                        # interactive — prompts for anything missing
docker compose --env-file .env --env-file generated.env up -d
python3 scripts/bootstrap.py                               # wire everything together
```

Full walkthrough: [docs/deployment.md](../docs/deployment.md)

---

## Docs

- [Hardware](../docs/hardware.md) — rack, compute, storage, GPU
- [Software](../docs/software.md) — OS, Docker stack, external access, Usenet
- [Deployment](../docs/deployment.md) — step-by-step setup
- [Operations](../docs/operations.md) — maintenance, diagnostics, known issues
- [Decisions](../docs/decisions.md) — design rationale and expansion paths
