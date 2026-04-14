#!/usr/bin/env python3
"""
bootstrap.py
============
Wires the stack together via API after first boot.
Run ONCE after the stack is up. Safe to re-run (idempotent).

On Unraid: pip-installed packages do NOT persist across reboots because
Unraid runs in RAM. This script installs its dependencies inline at the
start of every run so it always works regardless of reboot history.

Usage:
  python3 /mnt/user/appdata/media-stack/scripts/bootstrap.py

What it does:
  Radarr   — root folder, SABnzbd download client, hardlinks enabled
  Sonarr   — same
  Lidarr   — same
  Prowlarr — NZBGeek + NZBPlanet indexers, connects all three *arr apps, syncs
  Plex     — creates Movies / TV Shows / Music libraries, triggers scan
"""

import subprocess
import sys
import os

# ---------------------------------------------------------------------------
# Inline dependency installation
# Unraid does not persist pip packages across reboots.
# We install to /tmp so we don't litter the system.
# ---------------------------------------------------------------------------
def ensure_deps():
    import importlib
    missing = []
    for pkg, import_name in [("requests", "requests"), ("plexapi", "plexapi")]:
        try:
            importlib.import_module(import_name)
        except ImportError:
            missing.append(pkg)

    if missing:
        print(f"Installing missing packages: {', '.join(missing)}")
        subprocess.check_call([
            sys.executable, "-m", "pip", "install",
            "--quiet", "--target", "/tmp/bootstrap-deps",
            *missing
        ])
        sys.path.insert(0, "/tmp/bootstrap-deps")
        print("Done.\n")

ensure_deps()

import json
import time
import requests
from pathlib import Path

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
STACK_DIR = Path("/mnt/user/appdata/media-stack")
ENV_FILE  = STACK_DIR / ".env"

def load_env(path: Path) -> dict:
    if not path.exists():
        print(f"ERROR: {path} not found")
        sys.exit(1)
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, _, val = line.partition("=")
                val = val.split("#")[0].strip()
                env[key.strip()] = val
    return env

def require(env: dict, key: str) -> str:
    val = env.get(key, "").strip()
    if not val:
        print(f"ERROR: {key} is not set in .env")
        sys.exit(1)
    return val

def get(env: dict, key: str, default: str = "") -> str:
    return env.get(key, "").strip() or default

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
def arr_get(base: str, key: str, path: str):
    r = requests.get(f"{base}{path}", headers={"X-Api-Key": key}, timeout=15)
    r.raise_for_status()
    return r.json()

def arr_post(base: str, key: str, path: str, body: dict):
    r = requests.post(
        f"{base}{path}", json=body,
        headers={"X-Api-Key": key, "Content-Type": "application/json"},
        timeout=15
    )
    r.raise_for_status()
    return r.json()

def arr_put(base: str, key: str, path: str, body: dict):
    r = requests.put(
        f"{base}{path}", json=body,
        headers={"X-Api-Key": key, "Content-Type": "application/json"},
        timeout=15
    )
    r.raise_for_status()
    return r.json()

def already_exists(base: str, key: str, list_path: str, name_field: str, name: str) -> bool:
    try:
        items = arr_get(base, key, list_path)
        return any(str(i.get(name_field, "")).lower() == name.lower() for i in items)
    except Exception:
        return False

def wait_for(url: str, label: str, timeout: int = 120):
    print(f"  Waiting for {label}...", end="", flush=True)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if requests.get(url, timeout=5).status_code < 500:
                print(" ready")
                return
        except Exception:
            pass
        print(".", end="", flush=True)
        time.sleep(3)
    print(f"\nERROR: {label} did not come up within {timeout}s")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Configure an *arr app: root folder + SABnzbd client + media management
# ---------------------------------------------------------------------------
def configure_arr(label: str, base: str, key: str, root_folder: str,
                  sabnzbd_category: str, sabnzbd_key: str, extra_mm: dict = None):

    # Root folder
    existing_roots = arr_get(base, key, "/api/v3/rootfolder")
    if any(f["path"] == root_folder for f in existing_roots):
        print(f"  ✓ {label}: root folder already set")
    else:
        arr_post(base, key, "/api/v3/rootfolder", {"path": root_folder})
        print(f"  ✓ {label}: root folder → {root_folder}")

    # SABnzbd download client
    if already_exists(base, key, "/api/v3/downloadclient", "name", "SABnzbd"):
        print(f"  ✓ {label}: SABnzbd already connected")
    else:
        arr_post(base, key, "/api/v3/downloadclient", {
            "enable": True,
            "protocol": "usenet",
            "priority": 1,
            "name": "SABnzbd",
            "fields": [
                {"name": "host",         "value": "sabnzbd"},
                {"name": "port",         "value": 8080},
                {"name": "apiKey",       "value": sabnzbd_key},
                {"name": "urlBase",      "value": "/sabnzbd"},
                {"name": "categories",   "value": sabnzbd_category},
                {"name": "useSsl",       "value": False},
            ],
            "implementationName": "SABnzbd",
            "implementation": "Sabnzbd",
            "configContract": "SabnzbdSettings",
            "tags": []
        })
        print(f"  ✓ {label}: SABnzbd download client added (category: {sabnzbd_category})")

    # Media management: enable hardlinks, import extra files
    try:
        current = arr_get(base, key, "/api/v3/config/mediamanagement")
        updated = {**current,
                   "copyUsingHardlinks": True,
                   "deleteEmptyFolders": True,
                   "importExtraFiles": True,
                   **(extra_mm or {})}
        arr_put(base, key, "/api/v3/config/mediamanagement", updated)
        print(f"  ✓ {label}: hardlinks enabled")
    except Exception as e:
        print(f"  ⚠ {label}: media management update failed: {e}")

# ---------------------------------------------------------------------------
# Configure Prowlarr: add indexers, connect arr apps, sync
# ---------------------------------------------------------------------------
def configure_prowlarr(base: str, key: str, env: dict):

    def add_indexer(name: str, defn: str, api_key_value: str):
        if already_exists(base, key, "/api/v1/indexer", "name", name):
            print(f"  ✓ Prowlarr: {name} already added")
            return
        try:
            schemas = arr_get(base, key, "/api/v1/indexer/schema")
        except Exception as e:
            print(f"  ⚠ Prowlarr: could not fetch schemas: {e}")
            return
        schema = next(
            (s for s in schemas if s.get("definitionName", "").lower() == defn.lower()),
            None
        )
        if not schema:
            print(f"  ⚠ Prowlarr: schema not found for '{defn}' — check indexer name")
            return
        for field in schema.get("fields", []):
            if field.get("name") == "apiKey":
                field["value"] = api_key_value
        schema["name"] = name
        schema["enable"] = True
        schema["appProfileId"] = 1
        try:
            arr_post(base, key, "/api/v1/indexer", schema)
            print(f"  ✓ Prowlarr: {name} added")
        except Exception as e:
            print(f"  ⚠ Prowlarr: failed to add {name}: {e}")

    def add_app(name: str, app_url: str, app_key: str, impl: str, contract: str):
        if already_exists(base, key, "/api/v1/applications", "name", name):
            print(f"  ✓ Prowlarr: {name} already connected")
            return
        try:
            arr_post(base, key, "/api/v1/applications", {
                "name": name,
                "syncLevel": "fullSync",
                "fields": [
                    {"name": "prowlarrUrl", "value": "http://prowlarr:9696/prowlarr"},
                    {"name": "baseUrl",     "value": app_url},
                    {"name": "apiKey",      "value": app_key},
                    {"name": "syncCategories",
                     "value": [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060]},
                ],
                "implementationName": name,
                "implementation": impl,
                "configContract": contract,
                "tags": []
            })
            print(f"  ✓ Prowlarr: {name} connected")
        except Exception as e:
            print(f"  ⚠ Prowlarr: failed to connect {name}: {e}")

    add_indexer("NZBGeek",   "nzbgeek",   require(env, "NZBGEEK_API_KEY"))
    add_indexer("NZBPlanet", "nzbplanet", require(env, "NZBPLANET_API_KEY"))

    add_app("Radarr", "http://radarr:7878/radarr",
            require(env, "RADARR_API_KEY"),   "Radarr", "RadarrSettings")
    add_app("Sonarr", "http://sonarr:8989/sonarr",
            require(env, "SONARR_API_KEY"),   "Sonarr", "SonarrSettings")
    add_app("Lidarr", "http://lidarr:8686/lidarr",
            require(env, "LIDARR_API_KEY"),   "Lidarr", "LidarrSettings")

    # Trigger sync
    try:
        requests.post(f"{base}/api/v1/applications/sync",
                      headers={"X-Api-Key": key}, timeout=15)
        print("  ✓ Prowlarr: indexer sync triggered")
    except Exception as e:
        print(f"  ⚠ Prowlarr: sync trigger failed: {e}")

# ---------------------------------------------------------------------------
# Configure Plex: create libraries, trigger scan
# ---------------------------------------------------------------------------
def configure_plex(token: str, lan_ip: str):
    try:
        from plexapi.server import PlexServer
        from plexapi.exceptions import BadRequest
    except ImportError:
        print("  ⚠ Plex: plexapi import failed after install — try re-running")
        return

    try:
        plex = PlexServer(f"http://{lan_ip}:32400", token)
    except Exception as e:
        print(f"  ⚠ Plex: could not connect: {e}")
        print("    Check PLEX_LAN_IP and PLEX_TOKEN in .env")
        return

    existing = {s.title for s in plex.library.sections()}

    for name, ltype, path, agent, scanner in [
        ("Movies",   "movie",  "/data/media/movies", "tv.plex.agents.movie",  "Plex Movie"),
        ("TV Shows", "show",   "/data/media/tv",      "tv.plex.agents.series", "Plex TV Series"),
        ("Music",    "artist", "/data/media/music",   "tv.plex.agents.music",  "Plex Music"),
    ]:
        if name in existing:
            print(f"  ✓ Plex: '{name}' already exists")
            continue
        try:
            plex.library.add(name=name, type=ltype, agent=agent,
                             scanner=scanner, location=path, language="en")
            print(f"  ✓ Plex: created library '{name}'")
        except BadRequest as e:
            print(f"  ⚠ Plex: could not create '{name}': {e}")

    for section in plex.library.sections():
        section.update()
    print("  ✓ Plex: library scan triggered")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    env = load_env(ENV_FILE)
    lan_ip = require(env, "PLEX_LAN_IP")
    sabnzbd_key = require(env, "SABNZBD_API_KEY")

    SERVICES = {
        "radarr":   (f"http://localhost:7878/radarr",   require(env, "RADARR_API_KEY")),
        "sonarr":   (f"http://localhost:8989/sonarr",   require(env, "SONARR_API_KEY")),
        "lidarr":   (f"http://localhost:8686/lidarr",   require(env, "LIDARR_API_KEY")),
        "prowlarr": (f"http://localhost:9696/prowlarr", require(env, "PROWLARR_API_KEY")),
    }

    print("\n=== Waiting for services ===\n")
    for name, (url, key) in SERVICES.items():
        wait_for(f"{url}/api/v3/system/status", name)
    wait_for(f"http://localhost:5055", "overseerr")

    print("\n=== Radarr ===\n")
    url, key = SERVICES["radarr"]
    configure_arr("Radarr", url, key, "/data/media/movies", "movies", sabnzbd_key)

    print("\n=== Sonarr ===\n")
    url, key = SERVICES["sonarr"]
    configure_arr("Sonarr", url, key, "/data/media/tv", "tv", sabnzbd_key,
                  extra_mm={"createEmptySeriesFolders": False})

    print("\n=== Lidarr ===\n")
    url, key = SERVICES["lidarr"]
    configure_arr("Lidarr", url, key, "/data/media/music", "music", sabnzbd_key)

    print("\n=== Prowlarr ===\n")
    url, key = SERVICES["prowlarr"]
    configure_prowlarr(url, key, env)

    print("\n=== Plex ===\n")
    plex_token = get(env, "PLEX_TOKEN")
    if not plex_token:
        print("  ⚠ PLEX_TOKEN not set — skipping library creation")
        print("  To create libraries:")
        print("    1. Open http://{lan_ip}:32400/web")
        print("    2. Settings → General → scroll to bottom → Show")
        print("    3. Copy the X-Plex-Token value")
        print("    4. Add PLEX_TOKEN=<value> to .env")
        print("    5. Re-run this script")
    else:
        configure_plex(plex_token, lan_ip)

    print("\n=== Done ===\n")
    print("Stack is fully configured. Access points:")
    print(f"  SABnzbd:   http://{lan_ip}:8080/sabnzbd")
    print(f"  Prowlarr:  http://{lan_ip}:9696/prowlarr")
    print(f"  Radarr:    http://{lan_ip}:7878/radarr")
    print(f"  Sonarr:    http://{lan_ip}:8989/sonarr")
    print(f"  Lidarr:    http://{lan_ip}:8686/lidarr")
    print(f"  Plex:      http://{lan_ip}:32400/web")
    print(f"  Overseerr: http://{lan_ip}:5055")
    print()
    print("One remaining manual step:")
    print("  Plex → Settings → Transcoder → Use hardware acceleration when available")
    print("  Select: NVIDIA GeForce RTX 3050")
    print("  (requires Plex Pass — cannot be set via API)")

if __name__ == "__main__":
    main()
