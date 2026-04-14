#!/usr/bin/env python3
"""
Diagram #4 — External access boundary (Cloudflare Tunnel in; Usenet/indexers out).

Renders to docs/assets/external-access.png.

Setup once:
    pip install diagrams
    # Graphviz must be on PATH (dot -V)

Icons:
    Place PNGs in docs/assets/diagrams/icons/ named:
        plex.png overseerr.png tautulli.png sabnzbd.png prowlarr.png
        cloudflared.png cloudflare.png usenet.png
    Source: https://github.com/walkxcode/dashboard-icons/tree/main/png

Render:
    cd docs/assets/diagrams && python external-access.py
"""
from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.custom import Custom
from diagrams.generic.network import Router
from diagrams.onprem.client import Users

ICONS = Path(__file__).parent / "icons"


def ico(name: str) -> str:
    return str(ICONS / f"{name}.png")


graph_attr = {
    "bgcolor": "white",
    "fontname": "Inter, Helvetica, Arial",
    "fontsize": "18",
    "labelloc": "t",
    "pad": "0.5",
    "nodesep": "0.5",
    "ranksep": "1.1",
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
home_cluster_attr = {
    "fontname": "Inter, Helvetica, Arial",
    "fontsize": "12",
    "fontcolor": "#334155",
    "bgcolor": "#f1f5f9",
    "pencolor": "#94a3b8",
    "style": "dashed,rounded",
    "margin": "20",
    "label": "Home Network · No Inbound Ports",
}
stack_cluster_attr = {
    "fontname": "Inter, Helvetica, Arial",
    "fontsize": "11",
    "fontcolor": "#334155",
    "bgcolor": "#ffffff",
    "pencolor": "#cbd5e1",
    "style": "rounded",
    "margin": "16",
}

with Diagram(
    "External Access · Cloudflare Tunnel Boundary",
    filename="../external-access",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    client = Users("Remote Client\n(Phone · Laptop)")
    cf_edge = Custom("Cloudflare Edge", ico("cloudflare"))

    usenet = Custom("Usenet Provider", ico("usenet"))
    indexers = Custom("Indexers", ico("prowlarr"))

    with Cluster("", graph_attr=home_cluster_attr):
        router = Router("Home Router")
        cloudflared = Custom("cloudflared", ico("cloudflared"))

        with Cluster("Family-Facing", graph_attr=stack_cluster_attr):
            plex = Custom("Plex", ico("plex"))
            overseerr = Custom("Overseerr", ico("overseerr"))
            tautulli = Custom("Tautulli", ico("tautulli"))
            family = [plex, overseerr, tautulli]

        with Cluster("Admin-Only", graph_attr=stack_cluster_attr):
            sab = Custom("SABnzbd", ico("sabnzbd"))
            prowlarr = Custom("Prowlarr", ico("prowlarr"))

    # Inbound: HTTPS → Cloudflare → outbound tunnel → cloudflared → services
    client >> Edge(label="HTTPS", color="#1d4ed8", fontcolor="#1e3a8a") >> cf_edge
    cloudflared >> Edge(
        label="Outbound Tunnel (Persistent)",
        style="dashed",
        color="#6d28d9",
        fontcolor="#4c1d95",
    ) >> cf_edge
    cf_edge >> Edge(style="dotted", color="#94a3b8") >> cloudflared
    cloudflared >> Edge(color="#94a3b8") >> family

    # Router is bystander — nothing passes through it for tunnel traffic
    router >> Edge(label="No Inbound", style="dashed", color="#b91c1c", fontcolor="#7f1d1d") >> cf_edge

    # Outbound: NNTP + HTTPS to external services
    sab >> Edge(label="NNTP 563 TLS", style="dashed", color="#b45309", fontcolor="#78350f") >> usenet
    prowlarr >> Edge(label="HTTPS", style="dashed", color="#b45309", fontcolor="#78350f") >> indexers
