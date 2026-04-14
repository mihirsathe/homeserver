# Diagram drafts

**Not linked from nav.** Four candidate diagrams for the doc site. Pick which to keep; rejected drafts and this file get deleted afterward.

Destination notes for each diagram appear above it; change if a different home makes more sense.

---

## 1. Physical topology (candidate: top of `hardware.md`)

Rack contents + every cable that leaves the rack. Zooms out one level from the rack-layout table further down the page.

```mermaid
flowchart LR
    subgraph rack["15U Rack — Garage"]
        direction TB
        R640["Dell R640<br/>Server · U10"]
        MD["Dell MD1400<br/>DAS · U7–8"]
        UPS["APC UPS<br/>U3–4"]
    end
    Router["Home Router"]

    R640 -->|"Cat6A · 1 Gbps · LAN"| Router
    R640 -->|"Cat6A · 1 Gbps · iDRAC"| Router
    R640 ==>|"SFF-8644 SAS · 12 Gbps"| MD
    UPS -.->|"IEC C13/C14 · ×2 PSU"| R640
    UPS -.->|"IEC C13/C14 · ×2 PSU"| MD
```

---

## 2. Storage pool layout (candidate: `hardware.md` storage section)

How physical drives map to Unraid's logical shares.

```mermaid
flowchart LR
    subgraph md["MD1400 DAS — 12 bays"]
        P["Parity · 16 TB"]
        D1["Data · 8 TB"]
        D2["Data · 8 TB"]
        D3["Data · 8 TB"]
        D4["Data · 8 TB"]
        E["7 bays empty"]
    end
    subgraph r640["R640 internal — 8 bays"]
        C1["Cache SSD · 480 GB"]
        C2["Cache SSD · 480 GB"]
        BOSS["BOSS M.2 mirror · boot"]
    end

    D1 --> ARR
    D2 --> ARR
    D3 --> ARR
    D4 --> ARR
    P -.->|"parity<br/>protects"| ARR
    ARR["Unraid array<br/>32 TB usable"] --> DATA[("/mnt/user/data/")]

    C1 --> POOL
    C2 --> POOL
    POOL["Cache pool<br/>mirror"] --> APP[("/mnt/user/appdata/")]
```

---

## 3. Docker stack + media-request flow (candidate: `software.md`)

Services, volumes, and the life of a content request from click to stream.

```mermaid
flowchart LR
    viewer["Viewer"]
    seerr["Seerr"]
    subgraph arr["*arr services"]
        direction TB
        radarr["Radarr"]
        sonarr["Sonarr"]
        lidarr["Lidarr"]
    end
    prow["Prowlarr"]
    sab["SABnzbd"]
    usenet[("Usenet provider")]
    plex["Plex"]
    inc[("/data/usenet/")]
    media[("/data/media/")]

    viewer -->|"1 · request"| seerr
    seerr -->|"2 · push"| arr
    arr -->|"3 · search"| prow
    arr -->|"4 · queue NZB"| sab
    sab <-->|"5 · download"| usenet
    sab --> inc
    inc -->|"6 · hardlink import"| media
    media --> plex
    plex -->|"7 · stream"| viewer
```

---

## 4. External access: Plex port-forward + Tailscale admin plane (candidate: `software.md` external-access section)

Illustrates the one-port-open property — Plex is forwarded directly on TCP 32400; every other service is reachable only over the tailnet.

```mermaid
flowchart LR
    client["Remote Plex client<br/>(phone, laptop)"]
    admin["Admin device<br/>(on tailnet)"]
    subgraph home["Home network"]
        router["Home router<br/>·· only TCP 32400 open ··"]
        tailscale["Tailscale<br/>subnet router"]
        subgraph stack["Docker medianet"]
            plex["Plex"]
            seerr["Seerr"]
            arr["*arr · SAB · Prowlarr"]
        end
    end

    client -->|"TCP 32400<br/>(app.plex.tv direct-connect)"| router
    router --> plex
    admin -. "WireGuard<br/>(outbound-initiated)" .-> tailscale
    tailscale --> seerr
    tailscale --> arr
    router -.-|"inbound: only 32400"| client
```
