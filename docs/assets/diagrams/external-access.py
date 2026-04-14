#!/usr/bin/env python3
"""
Diagram #4 — External access boundary
(Plex port-forward in; Tailscale admin plane; Usenet via Gluetun/Mullvad out).

Renders to docs/assets/external-access.png.

Setup once:
    pip install diagrams
    # Graphviz must be on PATH (dot -V)

Icons:
    docs/assets/diagrams/icons/ contains:
        plex.png tautulli.png sabnzbd.png prowlarr.png     (from homarr-labs/dashboard-icons)
        seerr.svg                                          (seerr-team/seerr logo_full.svg)
        tailscale.svg mullvad.svg                          (Wikimedia Commons)
    Graphviz renders SVG and PNG interchangeably.
    (Usenet + indexers use mingrammer's generic Internet icon.)

Render:
    cd docs/assets/diagrams && python external-access.py
"""
from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.custom import Custom
from diagrams.generic.device import Mobile
from diagrams.generic.network import Router
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
    "label": "Home Network · Only TCP 32400 Open",
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
    "External Access · Port-forward + Tailscale Boundary",
    filename="../external-access",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    plex_client = Users("Remote Plex Client\n(Phone · Laptop)")
    admin = Mobile("Admin Device\n(on tailnet)")

    usenet = Internet("Usenet Provider")
    indexers = Internet("Indexers")
    mullvad = Custom("Mullvad\nWireGuard", ico("mullvad"))

    with Cluster("", graph_attr=home_cluster_attr):
        router = Router("Home Router\n(port-forward 32400)")
        tailscale = Custom("Tailscale\n(subnet router)", ico("tailscale"))

        with Cluster("Public Service", graph_attr=stack_cluster_attr):
            plex = Custom("Plex", ico("plex"))

        with Cluster("Admin-Only · Tailnet-Reachable", graph_attr=stack_cluster_attr):
            seerr = Custom("Seerr", ico("seerr"))
            tautulli = Custom("Tautulli", ico("tautulli"))
            admin_svcs = [seerr, tautulli]

        with Cluster("VPN-Egress Only · via Gluetun", graph_attr=stack_cluster_attr):
            sab = Custom("SABnzbd", ico("sabnzbd"))
            prowlarr = Custom("Prowlarr", ico("prowlarr"))

    # Inbound Plex: exactly one port-forward, direct-connect terminates at Plex
    plex_client >> Edge(label="TCP 32400", color="#1d4ed8", fontcolor="#1e3a8a") >> router
    router >> Edge(color="#1d4ed8") >> plex

    # Admin inbound: WireGuard mesh, outbound-initiated from both sides via Tailscale coordination
    admin >> Edge(
        label="WireGuard\n(outbound-initiated)",
        style="dashed",
        color="#6d28d9",
        fontcolor="#4c1d95",
    ) >> tailscale
    tailscale >> Edge(color="#94a3b8") >> admin_svcs

    # Outbound downloader egress forced through Mullvad WireGuard (Gluetun kill-switch)
    sab >> Edge(label="via Gluetun", style="dashed", color="#b45309", fontcolor="#78350f") >> mullvad
    prowlarr >> Edge(label="via Gluetun", style="dashed", color="#b45309", fontcolor="#78350f") >> mullvad
    mullvad >> Edge(label="NNTP 563 TLS", style="dashed", color="#b45309") >> usenet
    mullvad >> Edge(label="HTTPS", style="dashed", color="#b45309") >> indexers
