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
        for s in radarr sonarr lidarr prowlarr sab bazarr seerr tautulli profilarr actual coach; do
            # --max-time keeps an unadvertised service from stalling the run.
            # No -k: an invalid cert must fail, since the certificate is the
            # entire reason this ingress design was chosen.
            code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 8 "https://$s.$TAILNET/" 2>/dev/null)
            case "$code" in
                2*|3*|401) ok "https://$s.$TAILNET -> $code (cert valid)" ;;
                ""|000)    warn "https://$s.$TAILNET unreachable (not published, or cert invalid)" ;;
                *)         bad "https://$s.$TAILNET -> $code" ;;
            esac
        done
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
