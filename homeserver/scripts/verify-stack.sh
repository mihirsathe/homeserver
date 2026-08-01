#!/bin/bash
# Verify the whole stack in one pass.
#
# Written for two moments: the end of a deploy, and any time something feels
# off months later. The runbook's checks are spread across several sections,
# which means they get run once and never again — this is the same checks as
# one command, so re-running is cheap enough to actually happen.
#
#   bash scripts/verify-stack.sh          # everything
#   bash scripts/verify-stack.sh --quick  # skip the slow media/VPN checks
#
# Exit 0 = all pass, 1 = at least one FAIL. WARN never fails the run: it marks
# things that are expected to be absent mid-deploy (a tenant not yet stood up)
# rather than things that are broken.
#
# Read-only throughout. Nothing here writes, restarts or reconfigures anything,
# so it is always safe to run — including while you are debugging.

set -uo pipefail

STACK_DIR="/mnt/user/appdata/homeserver/homeserver"
ENV_FILE="$STACK_DIR/.env.docker"
QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; ((PASS++)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; ((FAIL++)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; ((WARN++)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

TAILNET=$(grep -h '^TAILNET_NAME=' "$STACK_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d ' "'"'")

# ---------------------------------------------------------------------------
sec "Host"

if mdcmd status 2>/dev/null | grep -q '^mdState=STARTED'; then
    ok "array STARTED"
else
    # On Unraid, stopping the array stops Docker (docker.img is loop-mounted
    # from a pool). Every container check below is meaningless if this fails.
    bad "array NOT started — Docker is down, everything below is moot"
fi

docker info >/dev/null 2>&1 && ok "docker responding" || bad "docker not responding"

# docker.img is a fixed-size loop-mounted vDisk, entirely separate from the
# array — appdata having hundreds of GB free tells you nothing about it. When
# it fills, running containers' writes start failing with no obvious cause, and
# builds die with "no space left on device" while df on /mnt/user looks fine.
dfree=$(df -BM --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "$dfree" ]]; then
    if   [[ "$dfree" -lt 2048 ]]; then bad  "docker.img only ${dfree}MiB free — container writes will start failing"
    elif [[ "$dfree" -lt 5120 ]]; then warn "docker.img ${dfree}MiB free — tight; a large image pull or build will fail"
    else ok "docker.img ${dfree}MiB free"
    fi
fi

# ---------------------------------------------------------------------------
sec "Containers"

EXPECTED="gluetun sabnzbd prowlarr radarr sonarr lidarr bazarr plex seerr tautulli profilarr ollama actual_server actual-ai coach"
for c in $EXPECTED; do
    state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)
    if [[ -z "$state" ]]; then
        warn "$c not deployed"
        continue
    fi
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null)
    if [[ "$state" != "running" ]]; then
        bad "$c is $state"
    elif [[ "$health" == "unhealthy" ]]; then
        bad "$c running but UNHEALTHY"
    elif [[ "$health" == "starting" ]]; then
        warn "$c still starting"
    else
        ok "$c running${health:+ ($health)}"
    fi
done

# Services that ship no healthcheck are invisible to the loop above: docker
# reports them running whether or not they work. actual-ai is the one that
# matters — it logs and retries forever by design, so a misconfigured instance
# is indistinguishable from a working one without reading the log.
if docker inspect actual-ai >/dev/null 2>&1; then
    if docker logs actual-ai --tail 200 2>&1 | grep -qiE 'error|econnrefused|failed'; then
        warn "actual-ai has errors in its log (it has no healthcheck — read it)"
    else
        ok "actual-ai log clean"
    fi
fi

# ---------------------------------------------------------------------------
sec "Backends on loopback"

# These publishes do double duty: bootstrap.py probes them, and tailscale serve
# proxies to them. A 404 here means UrlBase is set and the app is serving under
# a path prefix — which makes its Tailscale Service 404 too.
check_port() {
    local name=$1 port=$2
    code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/" 2>/dev/null)
    case "$code" in
        2*|3*|401) ok "$name :$port -> $code" ;;
        404)       bad "$name :$port -> 404 (UrlBase still set? will 404 via its Service too)" ;;
        ""|000)    warn "$name :$port not answering (not deployed?)" ;;
        *)         bad "$name :$port -> $code" ;;
    esac
}
check_port radarr 7878; check_port sonarr 8989; check_port lidarr 8686
check_port prowlarr 9696; check_port sab 8080; check_port bazarr 6767
check_port seerr 5055; check_port tautulli 8181; check_port profilarr 6868
check_port actual 5006; check_port coach 8000

# ---------------------------------------------------------------------------
sec "Indexer wiring"

# Prowlarr syncs each indexer into the *arrs as a Newznab entry pointing back
# at itself: `{prowlarrUrl}/{prowlarr indexer id}/` + apiPath `/api`. When that
# URL stops matching Prowlarr's `/{id}/api` route the request falls through to
# Prowlarr's SPA and the *arr is handed a web page where XML was expected:
#
#   Unable to connect to indexer: 'doctype' is an unexpected token.
#   The expected token is 'DOCTYPE'. Line 1, position 3.
#
# Nothing else here would catch it. The containers are healthy, the ports
# answer, and Prowlarr's own indexer Test stays green — that tests
# Prowlarr→indexer, a different hop from the one that is broken.
akey() { grep -h "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d ' "'"'"; }

PKEY=$(akey PROWLARR_API_KEY)

check_indexers() {
    local name=$1 port=$2 ver=$3 key json
    key=$(akey "$(echo "$name" | tr '[:lower:]' '[:upper:]')_API_KEY")
    if [[ -z "$key" ]]; then
        warn "$name: no API key in $(basename "$ENV_FILE") — skipping"
        return
    fi
    json=$(curl -fsS --max-time 8 -H "X-Api-Key: $key" \
        "http://127.0.0.1:$port/api/$ver/indexer" 2>/dev/null)
    if [[ -z "$json" ]]; then
        warn "$name: could not read indexer list (not deployed?)"
        return
    fi
    # The classifier is a quoted heredoc and takes its inputs through the
    # environment: it contains both quote characters, and inlining it as
    # python3 -c '...' lets the shell eat them silently rather than error —
    # you get a report with the quotes missing and no hint why.
    local report
    report=$(IX_JSON="$json" IX_NAME="$name" python3 - <<'PY'
import json, os

name = os.environ["IX_NAME"]
root = "http://gluetun:9696/"
try:
    ixs = json.loads(os.environ["IX_JSON"])
except Exception:
    print(f"WARN|{name}: indexer list was not JSON")
    raise SystemExit
if not ixs:
    print(f"WARN|{name}: no indexers — Prowlarr has synced nothing")
    raise SystemExit
bad = []
for ix in ixs:
    url = next((f.get("value") for f in ix.get("fields", [])
                if f.get("name") == "baseUrl"), "") or ""
    # Everything after the Prowlarr root must be exactly "<id>/". A leftover
    # UrlBase makes it "prowlarr/<id>/", which misses the newznab route.
    tail = url[len(root):] if url.startswith(root) else None
    if tail is None or not tail.rstrip("/").isdigit():
        bad.append((ix.get("name", "?"), url or "(unset)"))
for ixname, url in bad:
    print(f"BAD|{name}: indexer '{ixname}' -> {url} (not a Prowlarr proxy URL)")
if bad:
    print(f"BAD|{name}: {len(bad)}/{len(ixs)} indexer(s) will fail with the "
          f"'doctype' XML error — delete them in {name}, then re-run bootstrap.py")
else:
    print(f"OK|{name}: {len(ixs)} indexer(s), all proxied by Prowlarr")
PY
)
    # Herestring, not a pipe: the ok/bad/warn counters must increment in this
    # shell, not in a subshell that exits and discards them.
    while IFS='|' read -r verdict msg; do
        case "$verdict" in
            OK)   ok   "$msg" ;;
            BAD)  bad  "$msg" ;;
            WARN) warn "$msg" ;;
        esac
    done <<< "$report"
}

check_indexers radarr 7878 v3
check_indexers sonarr 8989 v3
check_indexers lidarr 8686 v1

# End-to-end proof on one indexer: issue the exact caps request an *arr makes,
# through Prowlarr's newznab route, and confirm XML comes back rather than a
# page. Loopback rather than the gluetun alias only because this runs on the
# host; it is the same route and the same handler.
if [[ -n "$PKEY" ]]; then
    ixid=$(curl -fsS --max-time 8 -H "X-Api-Key: $PKEY" \
        "http://127.0.0.1:9696/api/v1/indexer" 2>/dev/null \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin)[0]["id"])
except Exception: pass' 2>/dev/null)
    if [[ -z "$ixid" ]]; then
        warn "prowlarr: no indexers configured — nothing to probe"
    else
        head=$(curl -fsS --max-time 15 \
            "http://127.0.0.1:9696/$ixid/api?t=caps&apikey=$PKEY" 2>/dev/null \
            | head -c 200)
        case "$head" in
            # Prowlarr returns the indexer's caps document, or proxies the
            # indexer's own error XML. Either is XML, which is the point.
            '<?xml'*|'<caps'*|'<error'*) ok "prowlarr: /$ixid/api?t=caps returns XML" ;;
            '') warn "prowlarr: caps probe returned nothing (Mullvad down? see gluetun)" ;;
            *)  bad "prowlarr: /$ixid/api?t=caps returned non-XML — this is the *arr 'doctype' error at its source" ;;
        esac
    fi
fi

# ---------------------------------------------------------------------------
sec "Ingress"

if ! command -v tailscale >/dev/null 2>&1; then
    bad "tailscale not on PATH"
elif ! tailscale status >/dev/null 2>&1; then
    bad "tailscaled not connected — admin ingress is down (Unraid GUI + LAN SSH still work)"
else
    ok "tailscaled connected"
    tags=$(tailscale status --json 2>/dev/null | tr ',' '\n' | grep -c 'tag:server')
    [[ "$tags" -gt 0 ]] && ok "host carries tag:server" || bad "host missing tag:server — ACL and approvals key off it"

    if [[ -n "$TAILNET" ]]; then
        # A node generally cannot reach the TailVIP of a service it advertises
        # itself, so curling these URLs from here reports "unreachable" for
        # every service even when all of them work perfectly from any other
        # tailnet device. That produced 11 permanent false warnings and taught
        # the reader to skim the section, which is worse than not checking.
        #
        # What IS verifiable from the advertising host is that tailscaled holds
        # a proxy mapping for each service. Reachability and certificate
        # validity have to be checked from a different device.
        serve_json=$(tailscale serve status --json 2>/dev/null)
        if grep -q 'svc:' <<<"$serve_json"; then
            # The CLI does surface service proxies here, so per-service state
            # is meaningful.
            for s in radarr sonarr lidarr prowlarr sab bazarr seerr tautulli profilarr actual coach; do
                if grep -q "svc:$s" <<<"$serve_json"; then
                    ok "svc:$s advertised by this host"
                else
                    warn "svc:$s not advertised here (python3 scripts/sync-tailscale-services.py)"
                fi
            done
        else
            # `tailscale serve status` reports "No serve config" even when
            # service proxies are advertised and working — they are tracked
            # separately from ordinary serve entries. Reporting eleven warnings
            # from that silence would be inventing a problem, so say what is
            # actually known and point at the tool that can answer properly.
            printf '  \033[36m·\033[0m %s\n' \
                "serve CLI does not expose service proxies on this version — not a fault"
            printf '  \033[36m·\033[0m %s\n' \
                "authoritative check: python3 scripts/sync-tailscale-services.py"
        fi
        printf '  \033[36m·\033[0m %s\n' \
            "URLs + certs must be checked from ANOTHER tailnet device:  https://radarr.$TAILNET/"
    else
        warn "TAILNET_NAME unset in .env — skipping Service URL checks"
    fi
fi

# ---------------------------------------------------------------------------
sec "Exposure"

# The whole trust model in one assertion: exactly one thing is public.
pub=$(docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' | grep -oE '0\.0\.0\.0:[0-9]+' | cut -d: -f2 | sort -u)
if [[ -z "$pub" ]]; then
    warn "no containers running — cannot check exposure"
elif [[ "$pub" == "32400" ]]; then
    ok "only Plex (32400) binds 0.0.0.0"
else
    bad "unexpected public binds: $(echo "$pub" | tr '\n' ' ')— expected only 32400"
fi

# ---------------------------------------------------------------------------
sec "AI plane"

if docker inspect ollama >/dev/null 2>&1; then
    docker exec ollama nvidia-smi -L >/dev/null 2>&1 \
        && ok "ollama sees the GPU" \
        || bad "ollama has NO GPU — runs on CPU, silently, at unusable speed"

    docker exec ollama ollama list 2>/dev/null | grep -q ':' \
        && ok "ollama has at least one model" \
        || warn "ollama has no models (docker exec ollama ollama pull llama3.2:3b)"

    # Both consumers must be ON the ai network. Each PR was individually
    # correct and jointly broken here, and both failure modes are silent.
    for c in actual-ai coach; do
        if docker inspect "$c" >/dev/null 2>&1; then
            docker inspect "$c" -f '{{json .NetworkSettings.Networks}}' | grep -q '"ai"' \
                && ok "$c is on the ai network" \
                || bad "$c NOT on ai — cannot reach ollama, fails silently"
        fi
    done

    free=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null)
    if [[ -n "$free" ]]; then
        # OLLAMA_GPU_OVERHEAD reserves 2 GiB so a transcode can always start.
        [[ "$free" -ge 2048 ]] \
            && ok "GPU has ${free} MiB free (>= 2 GiB reserved for Plex)" \
            || bad "only ${free} MiB free — Plex's reservation is not holding"
    fi
else
    warn "ollama not deployed"
fi

# ---------------------------------------------------------------------------
sec "Data safety"

own_bad=0
for d in /mnt/user/appdata/*/; do
    [[ -d "$d" ]] || continue
    case "$d" in
        */homeserver/|*/chess-coach/) continue ;;   # git repo; deploy key + checkout
        # plexinc/pms-docker runs its entrypoint as root by design and manages
        # ownership internally via PLEX_UID/PLEX_GID, so root-owned paths here
        # are correct rather than broken. `docker inspect plex` shows an empty
        # .Config.User, which is the tell.
        */plex/) continue ;;
    esac
    # Directories only, three levels deep. A correctly-owned parent can hide a
    # root-owned child — exactly how Bazarr was found crash-looping behind s6
    # while docker reported it Up. Do not drop `-type d`: single files under
    # appdata are usually bind-mount TARGETS that docker creates as root and
    # the compose file then shadows, so their host-side ownership is irrelevant
    # and reporting it is pure noise.
    badown=$(find "$d" -maxdepth 2 -type d ! -user nobody 2>/dev/null | head -3)
    if [[ -n "$badown" ]]; then
        bad "root-owned under $(basename "$d"): $(echo "$badown" | tr '\n' ' ')"
        own_bad=1
    fi
done
[[ $own_bad -eq 0 ]] && ok "appdata ownership clean (3 levels deep)" || true

latest=$(ls -t /mnt/user/backups/appdata/*.tar.gz 2>/dev/null | head -1)
if [[ -n "$latest" ]]; then
    age=$(( ( $(date +%s) - $(stat -c %Y "$latest") ) / 86400 ))
    [[ "$age" -le 14 ]] \
        && ok "backup $(basename "$latest") is ${age}d old" \
        || warn "newest backup is ${age}d old"
else
    warn "no appdata backup found in /mnt/user/backups/appdata/"
fi

if [[ $QUICK -eq 0 ]]; then
    # Link count > 1 means the *arr import hardlinked instead of copying.
    # If this breaks, the array silently fills at double rate.
    linked=$(find /mnt/user/data/media -type f -links +1 2>/dev/null | head -1)
    [[ -n "$linked" ]] \
        && ok "hardlinks intact (found linked media)" \
        || warn "no hardlinked media found — imports may be copying"

    # The kill-switch: SAB egresses through Mullvad or not at all.
    vpn_ip=$(docker exec gluetun wget -qO- -T 8 https://ipinfo.io/ip 2>/dev/null | tr -d '\r\n')
    home_ip=$(curl -fsS --max-time 8 https://ipinfo.io/ip 2>/dev/null | tr -d '\r\n')
    if [[ -n "$vpn_ip" && -n "$home_ip" ]]; then
        [[ "$vpn_ip" != "$home_ip" ]] \
            && ok "gluetun egress $vpn_ip differs from home IP (kill-switch path OK)" \
            || bad "gluetun egress EQUALS home IP — VPN is not carrying downloader traffic"
    else
        warn "could not compare gluetun vs home egress IP"
    fi
fi

# ---------------------------------------------------------------------------
sec "Emergency path"

# Deliberately last, and deliberately not behind anything: this is what you
# need working when everything above is broken.
curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1/" 2>/dev/null \
    && ok "Unraid GUI answering on host :80 (Docker-independent)" \
    || bad "Unraid GUI NOT answering on :80 — this is the emergency path"

docker ps --format '{{.Ports}}' 2>/dev/null | grep -q '0\.0\.0\.0:80->' \
    && bad "a container has taken host :80 — the GUI must keep it" \
    || ok "nothing containerised is on host :80"

# ---------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed, %d warnings\033[0m\n' "$PASS" "$FAIL" "$WARN"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
