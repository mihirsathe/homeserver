#!/usr/bin/env python3
"""Reconcile this host's Tailscale Services with the desired set.

Admin ingress is one Tailscale Service per admin UI, advertised by the host's
own tailscaled. Standing one up has three parts, and this script does all
three so none of them is a console click:

  1. The service OBJECT must exist in the tailnet   -> PUT via the API
  2. This host must ADVERTISE it                    -> `tailscale serve`
  3. An admin must APPROVE this host for it         -> POST via the API

Miss step 1 and step 2 reports "approval from an admin is required" while the
admin console shows nothing to approve — there is no object for the pending
advertisement to attach to, and no error text points at the real cause.

Idempotent by design, like bootstrap.py. The API uses PUT rather than POST for
creation, so re-running reconciles rather than duplicating; re-advertising an
existing serve mapping is a no-op; and approval is checked before it is set.
Run it as often as you like.

    python3 scripts/sync-tailscale-services.py            # reconcile
    python3 scripts/sync-tailscale-services.py --dry-run  # show, change nothing
    python3 scripts/sync-tailscale-services.py --prune    # also delete strays

Requires TAILNET_NAME and TS_API_KEY in .env. Stdlib only — no pip install, so
this works on a box where nothing has been bootstrapped yet.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_ROOT = "https://api.tailscale.com/api/v2"

STACK_DIR = Path(__file__).resolve().parent.parent
ENV_FILES = [STACK_DIR / ".env", STACK_DIR / "generated.env"]

# The single source of truth for "which admin UI is published, and what does it
# proxy to". Adding a service is one row here plus a re-run.
#
# The port is the LOOPBACK publish from docker-compose.yml. Those publishes are
# load-bearing twice over: bootstrap.py probes them, and tailscale serve
# proxies to them. Do not "tidy them up" out of the compose file.
#
# sab and prowlarr point at gluetun's published ports because both share
# gluetun's network namespace and have no host port of their own.
#
# nextcloud is the one service where the NAME here is load-bearing beyond
# routing: it has to match the trusted domain baked in at install time
# (NEXTCLOUD_TRUSTED_DOMAINS in docker-compose.yml, built from TAILNET_NAME).
# Rename it and Nextcloud answers 400 "untrusted domain" — the route works,
# the app refuses. Fix with `occ config:system:set trusted_domains`, not by
# reverting the rename.
#
# Deliberately absent:
#   plex   — own auth, own *.plex.direct certs, own forwarded port. Proxying it
#            adds a hop and breaks direct-connection negotiation.
#   ollama — no authentication of any kind. Reaching :11434 means being able to
#            delete every model on the box, so its access control is membership
#            of the `ai` docker network. Publishing it would hand an
#            unauthenticated API to every tagged device on the tailnet.
SERVICES: dict[str, int] = {
    "radarr":    7878,
    "sonarr":    8989,
    "prowlarr":  9696,   # via gluetun
    "sab":       8080,   # via gluetun
    "bazarr":    6767,
    "seerr":     5055,
    "tautulli":  8181,
    "profilarr": 6868,
    "actual":    5006,
    "coach":     8000,
    "nextcloud": 8081,
}

# Services are tagged so the existing ACL grant (tag:admin -> tag:server)
# covers them without a second rule.
SERVICE_TAG = "tag:server"


# --------------------------------------------------------------------------
# env
# --------------------------------------------------------------------------

def load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    for path in ENV_FILES:
        if not path.exists():
            continue
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            # strip trailing inline comments, then quotes
            v = v.split("#", 1)[0].strip().strip('"').strip("'")
            if v:
                env[k.strip()] = v
    return env


# --------------------------------------------------------------------------
# api
# --------------------------------------------------------------------------

class Api:
    def __init__(self, tailnet: str, token: str):
        self.tailnet = tailnet
        self.token = token

    def _call(self, method: str, path: str, body: dict | None = None):
        url = f"{API_ROOT}/tailnet/{urllib.parse.quote(self.tailnet)}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        if data:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read().decode()
                return json.loads(raw) if raw.strip() else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:400]
            raise RuntimeError(f"{method} {path} -> {e.code} {e.reason}: {detail}") from None
        except urllib.error.URLError as e:
            raise RuntimeError(f"{method} {path} -> cannot reach API: {e.reason}") from None

    # Service objects. PUT is create-or-update, which is what makes this safe
    # to re-run; there is no separate create call to guard against.
    def list_services(self):
        return self._call("GET", "/services")

    def put_service(self, name: str, ports: list[str], comment: str):
        # `addrs` is deliberately omitted so Tailscale assigns the TailVIPs.
        # Pinning them here would mean hand-picking unused addresses and
        # keeping them unique forever, for no benefit.
        return self._call("PUT", f"/services/{urllib.parse.quote(name)}", {
            "name": name,
            "comment": comment,
            "ports": ports,
            "tags": [SERVICE_TAG],
        })

    def delete_service(self, name: str):
        return self._call("DELETE", f"/services/{urllib.parse.quote(name)}")

    # Host approval.
    def service_devices(self, name: str):
        return self._call("GET", f"/services/{urllib.parse.quote(name)}/devices")

    def is_approved(self, name: str, device_id: str) -> bool:
        # Read back rather than trusting the POST. An approval that silently
        # did not take looks identical to one that did, and the cost of being
        # wrong here is a service that is "green" in this output and dead in a
        # browser.
        try:
            r = self._call(
                "GET",
                f"/services/{urllib.parse.quote(name)}/device/{urllib.parse.quote(device_id)}/approved",
            )
        except RuntimeError:
            return False
        if isinstance(r, bool):
            return r
        if isinstance(r, dict):
            return bool(r.get("approved", False))
        return False

    def approve(self, name: str, device_id: str):
        return self._call(
            "POST",
            f"/services/{urllib.parse.quote(name)}/device/{urllib.parse.quote(device_id)}/approved",
            {"approved": True},
        )


# --------------------------------------------------------------------------
# host side
# --------------------------------------------------------------------------

def ts(*args: str) -> tuple[int, str]:
    p = subprocess.run(["tailscale", *args], capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def self_hostname() -> str:
    rc, out = ts("status", "--json")
    if rc != 0:
        raise RuntimeError(f"tailscale status failed: {out}")
    return json.loads(out)["Self"]["HostName"]


def advertise(name: str, port: int, dry: bool) -> str:
    """Point svc:<name> at 127.0.0.1:<port> on this host."""
    if dry:
        return "would advertise"
    rc, out = ts("serve", f"--service=svc:{name}", "--bg", f"127.0.0.1:{port}")
    if rc != 0:
        raise RuntimeError(f"tailscale serve failed for {name}: {out}")
    return "advertised"


# --------------------------------------------------------------------------

def normalise(name: str) -> str:
    return name if name.startswith("svc:") else f"svc:{name}"


def _walk(obj):
    """Yield every dict anywhere in a nested JSON structure.

    The API's list/collection responses are not documented here, and guessing
    a single shape is what broke the first two versions of this script: an
    unparsed list produced an empty "already exists" set, every service was
    re-PUT as an update, and the API rejected all eleven for missing addrs.
    Walking the structure works whether the payload is a bare list, is wrapped
    in {"services": [...]} or {"devices": [...]}, or gains another envelope
    later.
    """
    if isinstance(obj, dict):
        yield obj
        for v in obj.values():
            yield from _walk(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _walk(v)


def extract_service_names(raw) -> set[str]:
    names = set()
    for d in _walk(raw):
        n = d.get("name") or d.get("serviceName")
        if isinstance(n, str) and (n.startswith("svc:") or n in SERVICES):
            names.add(normalise(n))
    return names


ID_KEYS = ("id", "nodeId", "nodeID", "deviceId", "deviceID", "machineId")


def extract_device_id(raw, host: str) -> str | None:
    """Find this host's device id in a service's device list.

    Matches on the hostname appearing anywhere in the entry, because the field
    may be hostname, name, or an FQDN, and comparing one guessed key is how
    the previous version reported "NOT advertised" for services the console
    showed as online.
    """
    host_l = host.lower()
    for d in _walk(raw):
        if not any(k in d for k in ID_KEYS):
            continue
        if host_l in json.dumps(d).lower():
            for k in ID_KEYS:
                v = d.get(k)
                if isinstance(v, str) and v:
                    return v
    # Only one device advertises these services on this tailnet, so a single
    # unambiguous entry is this host even if the name did not match.
    candidates = [d for d in _walk(raw) if any(k in d for k in ID_KEYS)]
    if len(candidates) == 1:
        for k in ID_KEYS:
            v = candidates[0].get(k)
            if isinstance(v, str) and v:
                return v
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would change, touch nothing")
    ap.add_argument("--prune", action="store_true",
                    help="delete tailnet services not in SERVICES (destructive)")
    ap.add_argument("--debug", action="store_true",
                    help="dump raw API responses (for when a shape changes again)")
    args = ap.parse_args()

    env = load_env()
    tailnet, token = env.get("TAILNET_NAME", ""), env.get("TS_API_KEY", "")

    if not tailnet or not token:
        print("ERROR: TAILNET_NAME and TS_API_KEY must both be set in .env\n", file=sys.stderr)
        print("  TAILNET_NAME  `tailscale status`, or admin console -> DNS -> Tailnet name", file=sys.stderr)
        print("  TS_API_KEY    admin console -> Settings -> Keys -> API access token.", file=sys.stderr)
        print("                Prefer an OAuth client: access tokens expire (90 days),", file=sys.stderr)
        print("                which breaks a rebuild-from-scratch long after you have", file=sys.stderr)
        print("                forgotten this file exists.", file=sys.stderr)
        return 1

    api = Api(tailnet, token)
    host = self_hostname()
    print(f"Tailnet: {tailnet}   Host: {host}"
          f"{'   [DRY RUN]' if args.dry_run else ''}\n")

    try:
        existing_raw = api.list_services()
    except RuntimeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    existing = extract_service_names(existing_raw)
    if args.debug:
        print("DEBUG GET /services ->", json.dumps(existing_raw)[:800], "\n")
    print(f"  {len(existing)} service object(s) already defined\n")

    failures = 0

    for name, port in SERVICES.items():
        svc = normalise(name)
        print(f"  {svc:<18} -> 127.0.0.1:{port}")

        # 1. object
        try:
            if svc in existing:
                print("      object      already exists")
            elif args.dry_run:
                print("      object      would create")
            else:
                api.put_service(svc, ["tcp:443"], f"{name} admin UI")
                print("      object      created")
        except RuntimeError as e:
            # "addrs must contain 2 elements" is only ever returned when the
            # service already exists — updating requires its assigned TailVIPs,
            # which we deliberately never pin. Treat it as proof of existence
            # rather than an error, so a stale `existing` set cannot turn a
            # perfectly healthy tailnet into eleven red lines.
            if "addrs must contain" in str(e):
                print("      object      already exists")
            else:
                print(f"      object      FAILED: {e}")
                failures += 1
                continue

        # 2. advertisement
        try:
            print(f"      advertise   {advertise(name, port, args.dry_run)}")
        except RuntimeError as e:
            print(f"      advertise   FAILED: {e}")
            failures += 1
            continue

        if args.dry_run:
            print("      approve     would approve this host")
            continue

        # 3. approval. The advertisement takes a moment to reach the control
        # plane, so the device list is polled rather than read once.
        device_id = None
        for _ in range(10):
            try:
                devs = api.service_devices(svc)
            except RuntimeError:
                devs = None
            if args.debug and devs is not None:
                print("      DEBUG devices ->", json.dumps(devs)[:600])
            device_id = extract_device_id(devs, host) if devs is not None else None
            if device_id:
                break
            time.sleep(2)

        if not device_id:
            print("      approve     host not listed yet — re-run in a moment")
            failures += 1
            continue

        try:
            if api.is_approved(svc, device_id):
                print(f"      approve     already approved ({device_id})")
            else:
                api.approve(svc, device_id)
                # Approval is not always readable back immediately after the
                # POST, so poll rather than assume either outcome.
                confirmed = False
                for _ in range(5):
                    if api.is_approved(svc, device_id):
                        confirmed = True
                        break
                    time.sleep(2)
                if confirmed:
                    print(f"      approve     approved + verified ({device_id})")
                else:
                    print(f"      approve     POSTed but NOT confirmed — re-run to check")
                    failures += 1
        except RuntimeError as e:
            print(f"      approve     FAILED: {e}")
            failures += 1

    if args.prune:
        strays = existing - {normalise(n) for n in SERVICES}
        for svc in sorted(strays):
            if args.dry_run:
                print(f"\n  {svc:<18} would DELETE (not in SERVICES)")
            else:
                api.delete_service(svc)
                print(f"\n  {svc:<18} DELETED (not in SERVICES)")

    # Final pass. Everything above reports what this run *did*; this reports
    # what is actually true now, which is the only thing worth trusting.
    print("\nVerifying actual state:")
    live = 0
    for name in SERVICES:
        svc = normalise(name)
        try:
            devs = api.service_devices(svc)
        except RuntimeError as e:
            print(f"  {svc:<18} could not read: {e}")
            continue
        did = extract_device_id(devs, host)
        if not did:
            print(f"  {svc:<18} NOT advertised by {host}")
            continue
        if api.is_approved(svc, did):
            print(f"  {svc:<18} advertised + approved")
            live += 1
        else:
            print(f"  {svc:<18} advertised, NOT approved")

    print(f"\n{live}/{len(SERVICES)} services live.")
    if failures:
        print(f"{failures} step(s) reported a problem. Nothing here is destructive — fix and re-run.")
        return 1
    if live < len(SERVICES):
        print("Some services are not live yet. Re-running is safe and usually resolves it —")
        print("advertisements take a moment to reach the control plane.")
        return 1

    print("All services reconciled.\n")
    print(f"  https://<name>.{tailnet}/   e.g. https://radarr.{tailnet}/")
    print("  MagicDNS usually puts the tailnet domain in the DNS search path,")
    print("  so bare https://radarr/ resolves too.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
