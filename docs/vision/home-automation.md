# Phase 5 — Home Automation

*Goal: Run Home Assistant on a separate, redundant platform independent of the Unraid media server. Build a Thread-first smart home with Matter as the application layer.*

---

## Why Not Run Home Assistant on Unraid?

Home automation has fundamentally different uptime requirements than media serving. When Plex is down for maintenance, nobody's life is affected. When Home Assistant goes down: automations stop, lights don't respond, the thermostat loses its schedule, door locks lose smart features. A media server restart is an inconvenience; a home automation restart at 2am when motion-triggered lights are your path to the bathroom is a safety issue.

HAOS (Home Assistant Operating System) — the recommended deployment — runs as a full VM with its own supervisor, add-on ecosystem, and update mechanism. Proxmox VE is purpose-built for running VMs with high availability and is the standard recommendation for production HAOS deployments. The separation also means Unraid can be rebooted, updated, or rebuilt without any impact on home automation.

---

## Hardware — Proxmox Mini PC Cluster

Two low-power mini PCs provide a high-availability cluster with live migration. For Thread: ensure USB 2.0 ports are available (not only USB 3.0). USB 3.0 ports generate significant 2.4GHz interference degrading Thread and Zigbee radio performance. Alternatively, use a quality USB 2.0 extension cable (1–2m) to physically separate the radio from the USB 3.0 controller. The HA Connect ZBT-2 is designed as a freestanding antenna to mitigate this.

| Option | CPU | RAM | Storage | Est. Cost |
|--------|-----|-----|---------|-----------|
| Intel NUC 13 Pro | i5-1340P (12c) | 32–64GB SO-DIMM | 500GB–1TB NVMe | $350–500 ea. |
| Beelink SER5/SER7 | Ryzen 5/7 (6–8c) | 16–32GB DDR4/5 | 500GB NVMe | $250–400 ea. |
| Intel N100 mini PC | N100 (4c) | 16GB DDR5 | 256–512GB NVMe | $120–180 ea. |

The N100 is compelling: 6–10W idle, two of them consume less power than a single light bulb while providing full Proxmox HA clustering. Sufficient for HAOS + Thread border router. Step up to i5/Ryzen if you plan to run additional VMs (monitoring, Node-RED, secondary DNS) on the same cluster.

---

## Proxmox HA Architecture

Proxmox HA requires a minimum of three nodes for quorum (the cluster needs a majority online to make VM placement decisions). With two mini PCs, the third quorum vote comes from a **Corosync QDevice** running on the Unraid server — a lightweight daemon that participates in quorum voting but does not host VMs.

### Cluster Topology

- **Node 1 (Mini PC A)**: Primary — runs HAOS VM, OpenThread Border Router, AdGuard primary
- **Node 2 (Mini PC B)**: Secondary — standby for HA failover, secondary DNS, secondary OTBR
- **QDevice (Unraid)**: Tiebreaker quorum vote, NFS shared storage provider

If Node 1 fails, Proxmox HA automatically restarts the HAOS VM on Node 2 within 30–60 seconds. Automations resume with minimal disruption.

Shared storage: NFS share from Unraid mounted on both Proxmox nodes (VM disks and ISOs live here). The tradeoff is that Proxmox HA depends on Unraid for storage — but since the QDevice also runs there, this dependency already exists. For full independence a Ceph cluster (3+ nodes) eliminates the dependency but adds significant complexity.

### Thread Radio and VM Migration

When the HAOS VM migrates between nodes, the USB radio stays physically attached to the original host. Two approaches:

**(a) Recommended**: Attach a Thread radio to each Proxmox node and run an OTBR container on each host. Thread's multi-border-router design means both coexist on the same network automatically. Thread devices remain reachable via the surviving OTBR during the failover window.

**(b) Avoid**: ser2net to expose a remote radio over the network. The OTBR documentation warns against running timing-sensitive RCP protocols over IP — stale routes can leave devices unreachable for up to 30 minutes.

---

## Thread-First Protocol Strategy

Thread is the transport layer; Matter is the application layer. This is the correct architectural framing:

- **Thread** handles mesh networking: self-healing, low-power, IPv6-native (6LoWPAN), 2.4GHz 802.15.4
- **Matter** handles device interoperability: unified command set, cross-ecosystem, no cloud dependency, encrypted

Together they eliminate proprietary hubs, vendor-specific bridges, and cloud-dependent device control.

### Why Thread over Zigbee and Z-Wave

| Advantage | Detail |
|-----------|--------|
| IPv6-native | Thread devices get real IP addresses and communicate directly with your network. No protocol translation, no proprietary gateway. Every Thread device is a first-class IP citizen. |
| Multi-border-router resilience | Unlike Zigbee (single coordinator = single point of failure), Thread supports multiple border routers simultaneously. 2–3 OTBRs across the house provide coverage and redundancy with zero configuration. |
| Self-healing mesh | Every mains-powered Thread device acts as a Router, extending the mesh. Dynamically reroutes around failures. |
| Matter ecosystem | Matter 1.5 (early 2026) covers lights, switches, sensors, thermostats, locks, blinds, cameras, and energy management. Every major manufacturer ships Matter-over-Thread devices. |
| No cloud dependency | Matter-over-Thread devices communicate locally. Automations work without internet. |
| Thread 1.4 credential sharing | New border routers certified after January 2026 must support Thread 1.4, standardizing credential exchange. New border routers automatically join the existing network instead of creating parallel meshes. |

### Where Zigbee Still Has a Role

Thread-first does not mean Thread-only. Some categories — cheap sensors, certain IKEA products, some Aqara accessories — are still Zigbee-only or have better Zigbee implementations. Practical approach: buy Matter-over-Thread for every new device that supports it, maintain a Zigbee network for legacy devices and niche products.

Use two dedicated USB radios — one for Thread (OTBR) and one for Zigbee (ZHA or Zigbee2MQTT). Nabu Casa's multiprotocol firmware (Zigbee + Thread on one radio) remains experimental and is not recommended for production.

### Z-Wave — Skip for New Builds

Z-Wave's 900MHz gives superior wall penetration and has a decades-deep device catalog. For a greenfield install in 2026, it adds a third radio, a third protocol stack, and a shrinking ecosystem as manufacturers migrate to Matter. Unless you have specific Z-Wave devices you won't replace, skip it and invest the complexity budget into a robust Thread + Zigbee setup.

---

## Thread Network Architecture

### Border Router Placement

Deploy minimum two OTBRs, ideally three. Each OTBR is a Thread radio (USB dongle) connected to a host running the OTBR software.

- **OTBR 1**: HA Connect ZBT-2 in Proxmox Node 1, running the OTBR add-on inside HAOS. Primary border router — the one HA uses to commission new devices.
- **OTBR 2**: Second ZBT-2 in Proxmox Node 2, running a standalone OTBR Docker container. If Node 1 fails, Thread devices remain reachable while the HAOS VM migrates.
- **OTBR 3 (optional)**: Consumer Thread border router (Apple TV 4K, Google Nest Hub 2nd gen, or Nanoleaf bulb) in a distant part of the house. Extends mesh coverage and provides a third redundancy point. With Thread 1.4 credential sharing, it joins the existing network automatically.

This multi-OTBR topology is the decisive architectural advantage over Zigbee. Even during a Proxmox failover event (30–60 seconds), the Thread mesh continues operating through the surviving border routers.

### Thread and VLANs

The OTBR bridges between the Thread mesh (802.15.4) and the IP network. It must be on the same VLAN/subnet as Home Assistant for mDNS service discovery to work. Place both OTBR hosts and the HAOS VM on VLAN 30 (IoT/Smart Home).

**IPv6 consideration**: Thread is IPv6-native. The OTBR creates an off-mesh routable IPv6 prefix and advertises routes so Thread devices can be reached from the LAN. Ensure IPv6 is enabled on VLAN 30 and that the UniFi gateway allows IPv6 multicast and Router Advertisements on that VLAN. Many Thread connectivity issues trace back to IPv6 being disabled or multicast being blocked.

### Thread Mesh Scaling

Every mains-powered Thread device (smart plugs, bulbs, in-wall switches) acts as a Thread Router, extending the mesh. Battery-powered devices (motion sensors, contact sensors) operate as Sleepy End Devices (SEDs) that wake periodically to check in with their parent Router.

The mesh builds itself naturally as you add devices. Key consideration: distribute mains-powered devices evenly — they form the backbone. A few smart plugs or in-wall switches in every room ensures strong Router density. Thread 1.4's improved power management means SED battery life approaches Zigbee's best-in-class (2+ years on a coin cell for simple sensors).

---

## Matter Device Commissioning Flow

Adding a Matter-over-Thread device to Home Assistant:

1. Scan the device's QR code using the Home Assistant Companion app
2. Companion app uses BLE for the initial commissioning handshake
3. App transfers Thread network credentials to the device (credentials come from HAOS via OTBR)
4. Device joins the Thread mesh and becomes reachable via the OTBR's IPv6 bridge
5. Home Assistant discovers the device via mDNS, Matter integration auto-configures it
6. Device is now locally controlled — no cloud, no internet required

For **multi-admin** (same device from HA + Apple Home + Google Home): commission to Home Assistant first, then use HA's Matter dashboard to open a commissioning window for secondary ecosystems. Matter's multi-fabric support lets a single device respond to commands from multiple controllers.

---

## Recommended Matter-over-Thread Devices

### Lighting Strategy: Switches vs. Bulbs

**Use smart switches on the vast majority of circuits.** A smart switch controls the power circuit — on/off/dim. Smart switches: can't be accidentally power-cycled at the wall, act as always-on Thread Routers strengthening the mesh, work with any dumb bulb, guests can use them without instruction.

**Use smart bulbs only where you specifically want RGB or tunable color** — accent lamps, bedroom nightstands, media room bias lighting. Home Assistant coordinates them: switches and bulbs are independent Thread devices, HA ties them together with automations (e.g., when the living room switch turns on, set accent bulbs to warm white at 50%).

### Thread Switches

Every mains-powered switch is a Full Thread Device acting as a Thread Router.

| Switch | Type | Thread Router | Key Features | Est. Price |
|--------|------|:-------------:|--------------|:----------:|
| Inovelli White Series 2-1 | Dimmer + On/Off | Yes (SiLabs MG24) | Multi-tap scenes, RGB notification LED bar, energy monitoring, neutral or no-neutral, 3-way | ~$50 |
| Eve Light Switch (Matter) | On/Off | Yes (FTD) | Capacitive touch, 3-way compatible, neutral required | ~$40 |
| Eve Dimmer Switch (Matter) | Dimmer | Yes (FTD) | Smooth dimming, single-pole, neutral required | ~$45 |
| Aqara H2 Switch | On/Off (1 or 2 gang) | Yes (Thread/Zigbee) | Dual protocol, 1 or 2 channel, compact | ~$30–40 |

The **Inovelli White Series** is the standout: multi-tap scene control (up to 7 scenes per switch via single/double/triple taps and holds) makes it a powerful automation trigger beyond lighting. The RGB LED bar can be programmed as a visual indicator (red when alarm is armed, orange pulse when garage door is open). Budget for Inovelli on high-traffic switches and Eve/Aqara for secondary circuits.

### Thread Smart Bulbs (RGB/Tunable Only)

| Bulb | Color | Thread Router | Notes | Est. Price |
|------|-------|:-------------:|-------|:----------:|
| Nanoleaf Essentials A19 (Matter) | RGBCW 16M | Yes (also border router) | Doubles as a Thread border router, wide color temp, good dimming curve | ~$20 |
| Aqara LED Bulb T2 | RGBCW | Yes (Thread + Zigbee) | Dual protocol, 1100 lumens, 2700–6500K | ~$18 |
| AiDot MuJoy A19 (Matter) | RGBCW 16M | Yes (FTD) | Budget option, solid performance | ~$12 |
| Yeelight Thread A19 | RGBCW 1300 lm | Yes (FTD) | Bright, 5-channel RGBCW | ~$15–20 |
| IKEA Dirigera bulbs | Tunable or RGBCW | Yes (FTD) | Budget-friendly, Matter-capable | ~$10–15 |

The Nanoleaf Essentials is particularly notable — it acts not just as a Thread Router but as a full Thread Border Router.

### Other Device Categories

| Category | Recommended | Notes |
|----------|-------------|-------|
| Smart plugs | Eve Energy, Nanoleaf Essentials, Tapo P125M | Place strategically to fill mesh gaps |
| Motion sensors | Eve Motion, Aqara Motion Sensor P2 | Battery SED, ~2yr coin cell |
| Contact sensors | Eve Door & Window, Aqara Door Sensor P2 | Battery SED, ~2yr coin cell |
| Temperature/humidity | Eve Weather, Eve Room | Compact, battery or USB-C |
| Smart locks | Yale Assure Lock 2, Schlage Encode Plus | Test Thread range to lock location before committing |
| Thermostat | ecobee Smart Thermostat Premium | Matter-over-WiFi (not Thread) — acceptable exception |
| Blinds/shades | Eve MotionBlinds, IKEA Fyrtur | Matter-over-Thread, battery |

Note: some categories (thermostats, cameras, energy monitors) use Matter-over-WiFi. This is fine — Matter works over both transports and integrates identically in HA via the Matter integration.

---

## ESPHome on Thread — Custom Devices on Your Mesh

ESPHome supports building Matter-over-Thread devices on ESP32-C6 and ESP32-H2 chips (both include 802.15.4 radios). Custom sensors, controllers, and actuators that join your Thread mesh as first-class Matter devices — no cloud, no bridge, no custom integration code.

ESP32-H2/C6 boards cost $4–8 each. Example use cases: per-room multi-sensor boards (temperature, humidity, light level, air quality); water leak detectors under every sink; garage door controller with tilt sensor; mailbox sensor. All appear in Home Assistant automatically via Matter.

Battery-powered ESPHome Thread devices are still maturing but work for low-duty-cycle sensors.

---

## Home Assistant Integration Ecosystem

| Integration | Purpose |
|-------------|---------|
| Matter | Primary device control path for all Matter devices (Thread and WiFi) |
| Thread | Visualizes the Thread mesh — node roles, link quality, topology. Invaluable for debugging |
| OpenThread Border Router add-on | Runs OTBR inside HAOS, manages radio, exposes REST API |
| Zigbee Home Automation (ZHA) | Legacy Zigbee devices on second USB radio |
| UniFi | Network device monitoring, WiFi-based presence detection |
| Frigate | AI-powered camera object detection |
| Plex | Triggers automations based on media playback (dim lights for movie) |
| ESPHome | Custom firmware on ESP32 devices, Matter-over-Thread support |
| MQTT (Mosquitto) | Message bus for Frigate, ESPHome WiFi devices, other integrations |
| Node-RED | Visual flow-based automation for complex multi-step logic |

---

## Automation Philosophy

The best home automation is invisible. The goal is not a house you control from your phone — it is a house that anticipates and responds without being asked. High-value automations to implement first:

- **Presence-based lighting**: Motion sensors in hallways, bathrooms, closets trigger lights automatically. Turns off after no motion for a configurable period. Eliminates the most common household complaint.
- **Circadian lighting**: Color temperature shifts throughout the day — cool and bright in the morning, warm and dim in the evening. Requires tunable-white bulbs.
- **Arrival/departure**: WiFi presence detection (UniFi integration) or phone GPS (Companion app) triggers routines — entryway lights on arrival after dark, thermostat to away mode when everyone leaves.
- **Media-aware lighting**: Plex integration detects movie start → dim living room. Pause → 30%. Stop → restore.
- **Security posture**: Last person leaves → lock all smart locks, close garage, arm cameras for person detection alerts.
- **Climate intelligence**: Thermostat schedule adjusts based on actual occupancy. Open window sensors pause HVAC.

Start with three to five automations that solve real daily friction. Resist the urge to automate everything at once. Each automation should pass the partner test: would a non-technical person living in the house consider this helpful rather than annoying? If no, reconsider.
