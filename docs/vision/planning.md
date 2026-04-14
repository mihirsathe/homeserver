# Planning

Budget, timeline, risk register, and future horizons.

---

## Budget

### Phase-by-Phase Estimates

| Phase | Key Purchases | Est. Cost | Priority |
|-------|--------------|-----------|----------|
| 1 — Harden | 16TB drive, RAM, backup drive | $400–550 | **Critical** |
| 2 — Network | UDM-Pro, switch, 2–3 APs, patch panel | $1,100–1,600 | High |
| 3 — Power | UPS (rack-mount), PDU | $500–900 | **Critical** |
| 4 — Wiring | Cat6A cable, keystones, plates, conduit, tools | $500–900 | High |
| 5 — Proxmox HA | 2× mini PCs, RAM, USB radios | $400–900 | Medium |
| 6 — Cameras | 4–6 PoE cameras, mounts | $300–600 | Medium |
| 7 — Personal Cloud | Software only + B2 subscription | $50–100/yr | Low |
| 8 — Media Upgrades | GPU, drives, indexers | $400–800 | Low |
| Rack + Accessories | 12–18U rack, rails, shelves, PDUs | $200–500 | Medium |

**Full build-out: $3,900–$6,850** in hardware plus ~$100–200/year ongoing (cloud backup, Usenet providers, indexers, domain, Plex Pass). Spread across 8 phases over months or years.

**Critical investment (Phases 1 + 3 only): $900–1,450.** Do these first.

### Recommended Purchase Order

1. **UPS** — protects all existing hardware immediately
2. **Dual parity + RAM** — data protection and headroom
3. **Cloud backup** — offsite protection, minimal cost
4. **Network stack** — enables everything that follows
5. **Structured wiring** — ideally during any renovation
6. **Proxmox + HA** — once you have devices to automate
7. **Cameras** — requires network and wiring in place
8. **Personal cloud + media upgrades** — quality of life

---

## Implementation Timeline

Assuming a weekend-warrior pace (a few hours per weekend):

| Timeframe | Phase | Key Milestones |
|-----------|-------|----------------|
| Month 1 | Phase 1 + 3 | UPS installed, dual parity syncing, RAM upgraded, cloud backup live |
| Month 2–3 | Phase 2 | UniFi gateway + switch installed, VLANs configured, APs deployed |
| Month 3–5 | Phase 4 | Cat6A pulled to all rooms, patch panel terminated and labeled |
| Month 5–6 | Phase 5 | Proxmox cluster operational, Home Assistant running, first automations |
| Month 6–8 | Phase 6 | Cameras mounted, Frigate configured, AI detection tuned |
| Month 8–12 | Phase 7–8 | Cloud services deployed, media upgraded, monitoring finalized |

These are rough targets, not commitments. **The system is useful at every intermediate state.**

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Single drive failure | Medium | Low (dual parity) | SMART monitoring, spare drive on hand |
| Double drive failure during rebuild | Very Low | Critical | Dual parity eliminates this risk |
| UPS battery degradation | Certain (2–3yr) | Medium | Monitor battery health, replace on schedule |
| Tailscale control-plane outage | Low | Medium | LAN + Plex port-forward unaffected; direct SSH via LAN as fallback |
| ISP outage | Medium | Low (local services OK) | LTE failover if desired |
| iDRAC firmware update breaks fan control | Medium | Low (noise only) | Pin iDRAC firmware version, test updates first |
| Unraid USB license failure | Low | High | Flash Backup after every config change; contact Limetech |
| Power surge beyond UPS capacity | Very Low | Critical | Whole-house surge protector at panel |
| Scope creep / hobby overwhelm | High | Medium | Stick to phases, only deploy what you use, take breaks |

The last item is not a joke. Home lab projects tend to expand beyond what one person can maintain. The antidote: only deploy services you actively use, automate maintenance wherever possible, and accept that "good enough and running" beats "perfect but unmaintained."

---

## Future Horizons

Beyond the eight core phases — natural evolution paths once the infrastructure is mature.

### Local AI and Machine Learning

With the RTX 3050 (or a future 4060/4070): Frigate object detection (planned), Immich face/scene recognition, local LLM inference via Ollama, voice control via Whisper speech-to-text in Home Assistant, document OCR for Paperless-ngx. As models shrink, more becomes practical on consumer GPUs.

### Solar + Battery Integration

A solar system with battery backup integrates naturally with Home Assistant. Monitor production and battery state of charge, shift high-power tasks (parity checks, library scans) to peak solar hours, make intelligent decisions about what to keep running during grid outages.

### Second Server Node

If the R640 is outgrown: a second compute node for dedicated transcoding, local AI inference, or a full Proxmox node with Ceph. The MD1400 can be re-shared or a second DAS added. The rack infrastructure supports expansion with no changes.

### Jellyfin Migration

If Plex's data practices become unacceptable: Jellyfin is a drop-in replacement — fully open-source, no account required, no data collection, hardware transcoding supported. The media library, *arr automation stack, and SABnzbd all remain unchanged.

### Thread Network Evolution

Thread 1.4 is the current baseline (mandatory for new certifications since January 2026). Future revisions will bring expanded device categories, improved SED power management, and better large-network performance. The home network becomes a live testbed for protocol evolution — a direct feedback loop between professional work and home infrastructure.

### Full Infrastructure as Code

With Ansible, the entire system — Unraid settings, Docker stack, Proxmox config, UniFi firewall rules, Home Assistant automations — could be defined in version-controlled code. The ultimate disaster recovery: check out the repo, run the playbook, everything rebuilds. Also the most complex option. Save this for when the system is stable and you're looking for a project.
