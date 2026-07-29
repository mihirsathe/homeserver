# Hardware

## Rack

**15U, 4-post, full-depth (30"+).** Compute-only rack in the garage. Networking is handled by the home router — the R640 connects directly via 1GbE. A managed switch + dedicated networking rack is a future upgrade (see [decisions.md#expansion-paths](decisions.md#expansion-paths)).

### Layout

| U | Device | Notes |
|---|--------|-------|
| 15 | Vented blank | Reserved for future managed switch |
| 14 | Vented blank | |
| 13 | Vented blank | |
| 12 | Vented blank | |
| 11 | Vented blank | Thermal break above R640 |
| 10 | Dell PowerEdge R640 | Sliding rails |
| 9 | Vented blank | Thermal break between R640 and DAS |
| 7–8 | Dell MD1400 DAS | 12-bay · 4×8TB data + 1×16TB parity |
| 5–6 | Vented blanks | Reserved for second MD1400 (daisy-chain) |
| 3–4 | UPS (2U) | APC Smart-UPS X SMX1500RM2U · 1500 VA / 1200 W · pure sine |
| 1–2 | Vented blanks | Reserved for UPS battery expansion |

UPS is at the bottom because it's the heaviest component — keeps center of gravity low. Pure sine wave is required; the R640's Platinum-rated PSUs expect clean power and may refuse simulated sine wave on battery.

Vented blanks at U9 and U11 are thermal breaks, not filler. The R640 intakes from the front and exhausts out the rear — these prevent exhaust from preheating adjacent equipment intakes.

U5–6 are reserved for a second MD1400. The MD1400 supports daisy-chaining via its dual EMM modules; a second unit would connect with a short SFF-8644 jumper and no other hardware needs to move.

No PDU (UPS has enough outlets), no patch panel (only 3–4 runs — a panel makes sense at 8+).

### Cabling

| Connection | Cable | Speed |
|------------|-------|-------|
| R640 → Home router | Cat6A | 1 Gbps · shared LOM (LAN + iDRAC on one cable) |
| R640 → MD1400 | SFF-8644 SAS | 12 Gbps |
| UPS → R640 (×2 PSU) | IEC C13/C14 | — |
| UPS → MD1400 (×2 PSU) | IEC C13/C14 | — |
| UPS → R640 (data) | USB Type A→B (shipped with UPS) | — |

The X710 10GbE SFP+ ports on the daughter card are installed but unused; they become useful once a managed switch is added.

---

## Compute — Dell PowerEdge R640

| Component | Spec | Notes |
|-----------|------|-------|
| CPU | 2× Intel Xeon Gold 6146 | 12c/24t each · 3.2–4.2 GHz · no iGPU |
| RAM | 32 GB DDR4 ECC RDIMM | 6-channel · expandable to 768 GB across 24 DIMM slots |
| GPU | Yeston RTX 3050 LP 6G | Ampere GA107 · Riser 2 (CPU2 slot) |
| Storage controller | PERC H730P Mini | HBA/passthrough mode — individual drives visible to OS |
| Network | X710 10GbE SFP+ + I350 1GbE | Daughter card, rear panel |
| Remote management | iDRAC 9 | Dedicated management port, own IP on LAN |
| TPM | TPM 2.0 | Installed — enables Unraid TPM-based licensing |
| Form factor | 1U rack | Dell sliding rails installed |
| Power | 2× 1100W Platinum PSU | Both connected, redundant |

**RAM is the current constraint.** At 32 GB, heavy simultaneous workloads (many active transcodes + downloads + metadata scanning) can feel tight. Adding RAM is the single highest-ROI upgrade.

---

## Boot Storage — BOSS Card

| Item | Detail |
|------|--------|
| Card | Dell BOSS-S1 |
| Drives | 2× 240 GB M.2 SATA (mirrored) |
| Role | Unraid OS — ZFS mirror |
| Slot | Dedicated BOSS slot (not a riser slot) |

More reliable than a USB flash drive (cheap NAND, physical wear). RAID1-mirrored, survives one M.2 failure without downtime, and doesn't consume a riser slot.

---

## Cache Pool — Internal Bays 1–2

| Item | Detail |
|------|--------|
| Drives | 2× 480 GB SATA SSD (enterprise refurb) |
| Controller | PERC H730P (HBA mode) |
| Role | Unraid cache pool — BTRFS RAID1 |
| Contains | `/mnt/user/appdata` (all Docker configs), Docker images |
| SMART data | **Not available** — PERC HBA mode limitation |

Use iDRAC's storage view or the PERC's own interface to check internal SSD health. SMART passthrough is not available for drives behind the PERC in HBA mode.

---

## Storage — Dell MD1400 DAS

| Item | Detail |
|------|--------|
| Enclosure | Dell PowerVault MD1400 · 2U · 12× 3.5" bays |
| Redundancy | Dual EMM · dual PSU |
| Interface | 12 Gb SAS via LSI 9300-8e HBA (external SFF-8644) |
| HBA | LSI 9300-8e · Riser 1 Slot 1 (CPU1 side) · IT mode |
| SMART data | Full SMART passthrough via LSI IT-mode HBA |

### Drive Assignments

| Bay | Drive | Role | Usable |
|-----|-------|------|--------|
| MD1400 Bay 1 | 16 TB HDD | Parity | — |
| MD1400 Bay 2 | 8 TB HDD | Data disk 1 | 8 TB |
| MD1400 Bay 3 | 8 TB HDD | Data disk 2 | 8 TB |
| MD1400 Bay 4 | 8 TB HDD | Data disk 3 | 8 TB |
| MD1400 Bay 5 | 8 TB HDD | Data disk 4 | 8 TB |
| MD1400 Bays 6–12 | Empty | Available | up to 7 more drives |
| R640 Bays 3–10 | Empty | Available | internal SSD/NVMe |
| R640 Bay 1 | 480 GB SSD | Cache pool 1 | — |
| R640 Bay 2 | 480 GB SSD | Cache pool 2 | — |
| BOSS slot 1 | 240 GB M.2 | Boot mirror | — |
| BOSS slot 2 | 240 GB M.2 | Boot mirror | — |

**Total usable array: 32 TB** (single parity, 4×8 TB)

**Expansion headroom:** 7 more drives in the MD1400. Parity disk must always be the largest disk — adding a drive larger than 16 TB without first upgrading parity leaves the new drive unprotected. Full upgrade path (dual parity, daisy-chained second MD1400, etc.) lives in [decisions.md#expansion-paths](decisions.md#expansion-paths).

---

## GPU — RTX 3050 LP 6G (Ampere GA107)

| Codec | Encode (NVENC) | Decode (NVDEC) |
|-------|:--------------:|:--------------:|
| H.264 / AVC | ✓ | ✓ |
| H.265 / HEVC 8-bit | ✓ | ✓ |
| H.265 / HEVC 10-bit | ✓ | ✓ |
| AV1 | ✗ | ✓ |
| VP9 | ✗ | ✓ |

- Concurrent NVENC encode sessions: **12** on the stock NVIDIA driver, per [NVIDIA's published NVENC compatibility matrix](https://docs.nvidia.com/video-technologies/video-codec-sdk/nvenc-application-note/index.html). 7th-generation NVENC.
- NVDEC decode is **unlimited** — multi-stream hardware decode works as expected, including AV1 8/10-bit.
- AV1 encode requires RTX 4000 series (Ada Lovelace) or newer.

**Practical impact:** the session cap is effectively a non-issue for this household — hitting 12 concurrent hardware-encoded streams implies 13+ simultaneous transcoding viewers on one Plex server, which we will never see. Direct Play and Direct Stream (remux only, no re-encode) are uncapped regardless. For Plex transcoding the AV1 *encode* limitation doesn't matter — Plex always encodes output to H.264 or HEVC.

### VRAM budget — the real constraint

The 6 GB frame buffer, not the encoder session cap, is what limits this card. Plex shares it with Ollama (see [software.md](software.md#local-ai)), and the split is a static reservation — there is no scheduler and nothing arbitrating between them at runtime.

| Consumer | Typical VRAM |
|----------|--------------|
| Plex · 1080p → 720p H.264 NVENC session | ~200–400 MB |
| Plex · 4K HDR with tone-mapping | ~800 MB – 1 GB |
| Ollama · 3B model, q4, 4K context, q8_0 KV | ~2.5 GB |
| Ollama · 8B model, q4_K_M | ~4.9 GB |
| **Reserved for Plex** (`OLLAMA_GPU_OVERHEAD`) | **2 GiB** |

Ollama is capped at 6 GB minus the reservation, so a model larger than roughly 4 GB gets its overflow layers placed on the CPU instead of failing. NVENC and NVDEC are separate ASIC blocks, so inference never competes with the encoder for shader time — only for memory.

---

## What This Rack Does NOT Include

These belong in the future networking rack or later phases:

- UniFi gateway/router
- Main PoE switch (USW-Pro-24-PoE or similar)
- Patch panel for structured wiring
- Wireless access points
- Proxmox mini PCs (home automation)
- Security camera NVR storage
- Dedicated LLM inference node — small models (≤4 GB) already run on the R640's RTX 3050 alongside Plex transcoding; a separate node only becomes necessary for models that don't fit in 6 GB of VRAM
