#!/usr/bin/env python3
"""
Diagram #3 — Docker stack + media-request flow.

Scoped to the request-to-stream path. Bazarr, Tautulli, and Recyclarr are part
of the stack but sit outside this flow (subs, analytics, profile sync) and are
omitted for legibility; see docs/software.md for the full container list.

Renders to docs/assets/docker-stack.png.

Setup once:
    pip install diagrams
    # Graphviz must be on PATH (dot -V)

Icons:
    docs/assets/diagrams/icons/ contains:
        plex.png radarr.png sonarr.png lidarr.png prowlarr.png sabnzbd.png
            (from homarr-labs/dashboard-icons)
        seerr.svg mullvad.svg   (seerr-team/seerr + Wikimedia Commons)
    Graphviz renders SVG and PNG interchangeably.
    (Usenet provider + Gluetun fall back to generic Internet / Router icons
    if no dedicated glyph is available.)

Render:
    cd docs/assets/diagrams && python docker-stack.py
"""
from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.custom import Custom
from diagrams.generic.network import Router
from diagrams.generic.storage import Storage
from diagrams.onprem.client import Users
from diagrams.onprem.network import Internet

ICONS = Path(__file__).parent / "icons"


def ico(name: str) -> str:
    for ext in ("svg", "png"):
        p = ICONS / f"{name}.{ext}"
        if p.exists():
            return str(p)
    raise FileNotFoundError(f"icon not found: {name}.(svg|png) in {ICONS}")


graph_attr = {
    "bgcolor": "white",
    "fontname": "Inter, Helvetica, Arial",
    "fontsize": "18",
    "labelloc": "t",
    "pad": "0.5",
    "nodesep": "0.55",
    "ranksep": "1.0",
    "splines": "spline",
}
node_attr = {
    "fontsize": "12",
    "fontname": "Inter, Helvetica, Arial",
    "fontcolor": "#0f172a",
}
edge_attr = {
    "fontsize": "10",
    "fontname": "Inter, Helvetica, Arial",
    "color": "#64748b",
    "fontcolor": "#475569",
}
cluster_attr = {
    "fontname": "Inter, Helvetica, Arial",
    "fontsize": "11",
    "fontcolor": "#334155",
    "bgcolor": "#f8fafc",
    "pencolor": "#cbd5e1",
    "style": "rounded",
    "margin": "16",
}

with Diagram(
    "Docker Stack · Media Request Flow",
    filename="../docker-stack",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    viewer = Users("Viewer")
    usenet = Internet("Usenet Provider")
    mullvad = Custom("Mullvad\nWireGuard", ico("mullvad"))

    with Cluster("Home Server · Docker Compose (downloaders + automation + frontend)",
                 graph_attr=cluster_attr):
        seerr = Custom("Seerr", ico("seerr"))
        prowlarr = Custom("Prowlarr", ico("prowlarr"))
        sab = Custom("SABnzbd", ico("sabnzbd"))
        gluetun = Router("Gluetun\n(kill-switch)")
        plex = Custom("Plex", ico("plex"))

        with Cluster("*arr Automation", graph_attr=cluster_attr):
            radarr = Custom("Radarr", ico("radarr"))
            sonarr = Custom("Sonarr", ico("sonarr"))
            lidarr = Custom("Lidarr", ico("lidarr"))
            arr = [radarr, sonarr, lidarr]

        with Cluster("Shared /data Volume", graph_attr=cluster_attr):
            incoming = Storage("/data/usenet")
            library = Storage("/data/media")

    viewer >> Edge(label="1 · Watchlist add") >> seerr
    seerr >> Edge(label="2 · Push") >> arr
    arr >> Edge(label="3 · Search") >> prowlarr
    prowlarr >> Edge(label="indexer HTTPS",
                     style="dashed", color="#b45309", fontcolor="#78350f") >> gluetun
    arr >> Edge(label="4 · Queue NZB") >> sab
    sab >> Edge(label="5 · NNTPS 563",
                style="dashed", color="#b45309", fontcolor="#78350f") >> gluetun
    gluetun >> Edge(label="VPN egress (Mullvad WG)",
                    style="dashed", color="#b45309") >> mullvad
    mullvad >> Edge(style="dashed", color="#b45309") >> usenet
    sab >> Edge(style="dotted", color="#94a3b8") >> incoming
    incoming >> Edge(label="6 · Hardlink Import", color="#1d4ed8", fontcolor="#1e3a8a") >> library
    library >> Edge(style="dotted", color="#94a3b8") >> plex
    plex >> Edge(label="7 · Stream", color="#6d28d9", fontcolor="#4c1d95") >> viewer
