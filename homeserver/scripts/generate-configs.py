#!/usr/bin/env python3
"""
generate-configs.py
===================
Reads .env and writes every app config file to the configs/ directory.
Run ONCE before starting the stack. Re-run whenever you change .env.

On Unraid: run from the terminal as root (which is the default shell).
  cd /mnt/user/appdata/media-stack
  python3 scripts/generate-configs.py

What it writes (all under /mnt/user/appdata/media-stack/configs/):
  sabnzbd/sabnzbd.ini     — full SABnzbd config, skips setup wizard
  radarr/config.xml       — port, API key, url base, auth disabled
  sonarr/config.xml       — same
  lidarr/config.xml       — same
  prowlarr/config.xml     — same
  overseerr/settings.json — general settings, API key pre-seeded
  bazarr/config.ini       — Sonarr + Radarr connection details

NOTE: Python packages are NOT persistent on Unraid across reboots.
This script uses only stdlib — no pip dependencies.
"""

import os
import sys
import json
import uuid
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths — all absolute for Unraid compatibility
# ---------------------------------------------------------------------------
STACK_DIR = Path("/mnt/user/appdata/media-stack")
ENV_FILE  = STACK_DIR / ".env"
CONFIGS   = STACK_DIR / "configs"

# ---------------------------------------------------------------------------
# .env loader
# ---------------------------------------------------------------------------
def load_env(path: Path) -> dict:
    if not path.exists():
        print(f"ERROR: {path} not found.")
        print("Copy .env.example to .env and fill in every value.")
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
# sabnzbd.ini
# ---------------------------------------------------------------------------
def write_sabnzbd(env: dict):
    dest = CONFIGS / "sabnzbd"
    dest.mkdir(parents=True, exist_ok=True)

    api_key  = require(env, "SABNZBD_API_KEY")
    domain   = require(env, "DOMAIN")
    host     = require(env, "USENET_HOST")
    port     = get(env, "USENET_PORT", "563")
    ssl      = get(env, "USENET_SSL", "1")
    user     = require(env, "USENET_USER")
    password = require(env, "USENET_PASS")
    conns    = get(env, "USENET_CONNECTIONS", "20")

    fill_host  = get(env, "USENET_FILL_HOST")
    fill_user  = get(env, "USENET_FILL_USER")
    fill_pass  = get(env, "USENET_FILL_PASS")
    fill_conns = get(env, "USENET_FILL_CONNECTIONS", "10")

    fill_block = ""
    if fill_host and fill_user and fill_pass:
        fill_block = f"""
    [[server2]]
    displayname = Fill Server
    host = {fill_host}
    port = 563
    ssl = 1
    ssl_verify = 2
    username = {fill_user}
    password = {fill_pass}
    connections = {fill_conns}
    priority = 1
    retention = 0
    timeout = 60
    required = 0
    optional = 1
    enabled = 1"""

    content = f"""[misc]
host = 0.0.0.0
port = 8080
url_base = /sabnzbd
# host_whitelist blocks requests from hostnames not listed here.
# This WILL break access through the Cloudflare tunnel unless your
# manage.yourdomain.com is present. Add more comma-separated entries as needed.
host_whitelist = localhost,sabnzbd,mediaserver.local,manage.{domain}
api_key = {api_key}
nzo_ids = {api_key}
wizard_step = 10
language = en
cherryhost = 0.0.0.0
cherryport = 8080
download_dir = /data/usenet/incomplete
complete_dir = /data/usenet/complete
log_dir = /config/logs
admin_dir = /config/admin
# 0 = unlimited. Set to your connection speed in KB/s to cap usage.
# 100Mbps=12500  250Mbps=31250  500Mbps=62500  1Gbps=125000
bandwidth_max = 0
bandwidth_perc = 100
direct_unpack = 1
pause_on_post_processing = 0
enable_par_cleanup = 1
cleanup_list = .nfo, .sfv, .jpg, .png, .nzb
fail_on_fail = 0
history_retention = 30
history_limit = 200
dupl_priority = -100
check_new_rel = 0
enable_broadcast = 0
keep_awake = 1
send_group = 0

[notifications]
ntf_enable = 0

[servers]

    [[server1]]
    displayname = Primary Provider
    host = {host}
    port = {port}
    ssl = {ssl}
    ssl_verify = 2
    username = {user}
    password = {password}
    connections = {conns}
    priority = 0
    retention = 0
    timeout = 60
    required = 0
    optional = 0
    enabled = 1
{fill_block}

[categories]

    [[movies]]
    name = movies
    dir = movies
    pp = 3
    script = None
    req_completion_rate = 100.0
    priority = -100
    newzbin =

    [[tv]]
    name = tv
    dir = tv
    pp = 3
    script = None
    req_completion_rate = 100.0
    priority = -100
    newzbin =

    [[music]]
    name = music
    dir = music
    pp = 3
    script = None
    req_completion_rate = 100.0
    priority = -100
    newzbin =

    [[*]]
    name = *
    dir =
    pp = 3
    script = None
    priority = -100
    req_completion_rate = 100.0
    newzbin =
"""
    (dest / "sabnzbd.ini").write_text(content)
    print("  ✓ configs/sabnzbd/sabnzbd.ini")

# ---------------------------------------------------------------------------
# *arr config.xml (Radarr, Sonarr, Lidarr, Prowlarr share this schema)
# ---------------------------------------------------------------------------
def write_arr_config(name: str, port: int, api_key: str, url_base: str):
    dest = CONFIGS / name
    dest.mkdir(parents=True, exist_ok=True)

    content = f"""<Config>
  <BindAddress>*</BindAddress>
  <Port>{port}</Port>
  <SslPort>{port + 1000}</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>{api_key}</ApiKey>
  <AuthenticationMethod>None</AuthenticationMethod>
  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
  <Branch>main</Branch>
  <LogLevel>info</LogLevel>
  <UrlBase>{url_base}</UrlBase>
  <UpdateMechanism>Docker</UpdateMechanism>
</Config>
"""
    (dest / "config.xml").write_text(content)
    print(f"  ✓ configs/{name}/config.xml")

# ---------------------------------------------------------------------------
# overseerr settings.json
# ---------------------------------------------------------------------------
def write_overseerr(env: dict):
    dest = CONFIGS / "overseerr"
    dest.mkdir(parents=True, exist_ok=True)

    domain = require(env, "DOMAIN")
    lan_ip = require(env, "PLEX_LAN_IP")

    settings = {
        "apiKey": uuid.uuid4().hex,
        "main": {
            "apiKey": uuid.uuid4().hex,
            "applicationTitle": "Media Requests",
            "applicationUrl": f"https://request.{domain}",
            "trustProxy": True,
            "hideAvailable": False,
            "localLogin": True,
            "newPlexLogin": True,
            "defaultPermissions": 32,
            "defaultQuotas": {
                "movie": {"quotaLimit": 0, "quotaDays": 7},
                "tv":    {"quotaLimit": 0, "quotaDays": 7}
            },
            "partialRequestsEnabled": True,
            "locale": "en"
        },
        "plex": {
            "name": get(env, "PLEX_SERVER_NAME", "Home Media Server"),
            "ip": lan_ip,
            "port": 32400,
            "useSsl": False,
            "libraries": []
        },
        "tautulli": None,
        "radarr": [],
        "sonarr": [],
        "public": {"initialized": False},
        "notifications": {
            "agents": {
                "email":      {"enabled": False, "types": 0, "options": {}},
                "discord":    {"enabled": False, "types": 0, "options": {}},
                "slack":      {"enabled": False, "types": 0, "options": {}},
                "telegram":   {"enabled": False, "types": 0, "options": {}},
                "pushbullet": {"enabled": False, "types": 0, "options": {}},
                "pushover":   {"enabled": False, "types": 0, "options": {}},
                "lunasea":    {"enabled": False, "types": 0, "options": {}},
                "gotify":     {"enabled": False, "types": 0, "options": {}},
                "ntfy":       {"enabled": False, "types": 0, "options": {}},
                "webpush":    {"enabled": False, "types": 0, "options": {}}
            }
        },
        "jobs": {}
    }

    (dest / "settings.json").write_text(json.dumps(settings, indent=2))
    print("  ✓ configs/overseerr/settings.json")

# ---------------------------------------------------------------------------
# bazarr config.ini
# ---------------------------------------------------------------------------
def write_bazarr(env: dict):
    dest = CONFIGS / "bazarr"
    dest.mkdir(parents=True, exist_ok=True)

    radarr_key = require(env, "RADARR_API_KEY")
    sonarr_key = require(env, "SONARR_API_KEY")
    tz         = get(env, "TZ", "UTC")

    content = f"""[general]
ip = 0.0.0.0
port = 6767
base_url = /bazarr
launch_browser = False
update_upgrade = False
timezone = {tz}

[auth]
type = None

[sonarr]
ip = sonarr
port = 8989
base_url = /sonarr
ssl = False
apikey = {sonarr_key}
full_update = Weekly
full_update_day = 6
full_update_hour = 4
enabled = True

[radarr]
ip = radarr
port = 7878
base_url = /radarr
ssl = False
apikey = {radarr_key}
full_update = Weekly
full_update_day = 6
full_update_hour = 4
enabled = True

[subliminal]
hearing_impaired_subtitles = False
single_language = False

[opensubtitles]
enabled = False
username =
password =

[languages]
single = False
subtitles_languages = ['en']
enabled_codecs = ['utf-8']
"""
    (dest / "config.ini").write_text(content)
    print("  ✓ configs/bazarr/config.ini")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    print(f"Loading .env from {ENV_FILE}\n")
    env = load_env(ENV_FILE)

    # Validate all required keys up front so failures are obvious
    required = [
        "TZ", "DOMAIN", "PLEX_LAN_IP", "PLEX_LAN_SUBNET",
        "SABNZBD_API_KEY", "RADARR_API_KEY", "SONARR_API_KEY",
        "LIDARR_API_KEY", "PROWLARR_API_KEY",
        "USENET_HOST", "USENET_USER", "USENET_PASS",
        "NZBGEEK_API_KEY", "NZBPLANET_API_KEY",
        "CLOUDFLARE_TUNNEL_TOKEN",
    ]
    missing = [k for k in required if not env.get(k, "").strip()]
    if missing:
        print("ERROR: These required .env values are not set:")
        for k in missing:
            print(f"  {k}")
        sys.exit(1)

    print("Writing config files...\n")
    write_sabnzbd(env)
    write_arr_config("radarr",   7878, require(env, "RADARR_API_KEY"),  "/radarr")
    write_arr_config("sonarr",   8989, require(env, "SONARR_API_KEY"),  "/sonarr")
    write_arr_config("lidarr",   8686, require(env, "LIDARR_API_KEY"),  "/lidarr")
    write_arr_config("prowlarr", 9696, require(env, "PROWLARR_API_KEY"),"/prowlarr")
    write_overseerr(env)
    write_bazarr(env)

    print("""
Done. All config files written to /mnt/user/appdata/media-stack/configs/

Next steps:
  1. Start the stack in Compose Manager Plus (or: docker compose up -d)
  2. Wait ~60s for all containers to initialise
  3. python3 /mnt/user/appdata/media-stack/scripts/bootstrap.py
""")

if __name__ == "__main__":
    main()
