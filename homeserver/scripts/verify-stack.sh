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
# `PASS=$((PASS+1))`, NOT `((PASS++))`. Post-increment evaluates to the value
# BEFORE the increment, so `((PASS++))` exits 1 while the counter is still 0 —
# and the function inherits that status. Every `check && ok ... || bad ...`
# chain in this file would then run BOTH arms on its first call, printing a ✓
# and a ✗ for the same condition and inflating FAIL. It fires exactly when the
# run is otherwise clean, which is the worst possible time.
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Strip inline comments before quotes. .env.example ships
# `TAILNET_NAME=        # FILL IN — e.g. tail1a2b3.ts.net`, and filling that in
# in place leaves the comment on the line. Both Python parsers in this repo do
# `split("#")[0]`; this one did not, so it produced a hostname with the comment
# glued on and every hostname-dependent check failed on a healthy stack.
TAILNET=$(grep -h '^TAILNET_NAME=' "$STACK_DIR/.env" 2>/dev/null \
          | head -1 | cut -d= -f2- | cut -d'#' -f1 | tr -d ' "'"'")

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

EXPECTED="gluetun sabnzbd prowlarr radarr sonarr lidarr bazarr plex seerr tautulli profilarr ollama actual_server actual-ai coach nextcloud nextcloud-db nextcloud-redis nextcloud-cron"
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
check_port actual 5006; check_port coach 8000; check_port nextcloud 8081

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
#
# All of that applies ONLY to an *arr whose Prowlarr connection is sync-enabled.
# Disabling one app's sync is a supported way to hand-manage that *arr's
# indexers, and a hand-managed indexer is SUPPOSED to point straight at the
# indexer rather than at a Prowlarr proxy URL. Reporting that as a fault turns
# a deliberate configuration into a false alarm — so the sync level is read
# first and decides how the list is judged.
akey() { grep -h "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d ' "'"'"; }

PKEY=$(akey PROWLARR_API_KEY)

# name -> syncLevel, one line each. Empty if Prowlarr is unreachable, which
# degrades every app below to "unknown" and suppresses the verdicts rather
# than inventing them.
APP_LEVELS=$(curl -fsS --max-time 8 -H "X-Api-Key: $PKEY" \
    "http://127.0.0.1:9696/api/v1/applications" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    for a in json.load(sys.stdin):
        print(str(a.get("name","")).lower(), a.get("syncLevel"))
except Exception: pass' 2>/dev/null)

check_indexers() {
    local name=$1 port=$2 ver=$3 key json level
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
    level=$(awk -v n="$name" '$1==n {print $2}' <<< "$APP_LEVELS")
    # The classifier is a quoted heredoc and takes its inputs through the
    # environment: it contains both quote characters, and inlining it as
    # python3 -c '...' lets the shell eat them silently rather than error —
    # you get a report with the quotes missing and no hint why.
    local report
    report=$(IX_JSON="$json" IX_NAME="$name" IX_LEVEL="$level" python3 - <<'PY'
import json, os

name = os.environ["IX_NAME"]
level = os.environ.get("IX_LEVEL", "").strip()
root = "http://gluetun:9696/"
try:
    ixs = json.loads(os.environ["IX_JSON"])
except Exception:
    print(f"WARN|{name}: indexer list was not JSON")
    raise SystemExit

if not level:
    print(f"WARN|{name}: Prowlarr sync level unknown (Prowlarr unreachable, or "
          "no app connection) — indexer URLs not judged")
    raise SystemExit

if level == "disabled":
    # Hand-managed by choice. Prowlarr excludes disabled apps from
    # SyncEnabled(), so it neither adds nor removes here; a direct indexer URL
    # is correct and an empty list is a setup gap, not a wiring fault.
    if ixs:
        print(f"OK|{name}: {len(ixs)} indexer(s), Prowlarr sync disabled "
              "(hand-managed — URLs intentionally not proxied)")
    else:
        print(f"WARN|{name}: no indexers, and Prowlarr sync is disabled for it "
              "— it cannot search until indexers are added by hand")
    raise SystemExit

if not ixs:
    print(f"WARN|{name}: no indexers despite sync '{level}' — check Prowlarr → "
          "Settings → Apps → Test, and category overlap with the indexer's caps")
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
    # No "delete these" advice: the forced sync already removes what Prowlarr
    # owns, so a survivor is either hand-added or proof Prowlarr cannot reach
    # this app. Deleting it loses a working indexer or fixes nothing.
    print(f"BAD|{name}: {len(bad)}/{len(ixs)} indexer(s) will fail with the "
          f"'doctype' XML error — test Prowlarr → Settings → Apps → {name}")
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
sec "Seerr wiring"

# Seerr's Radarr/Sonarr connections are entered in its UI and live in its own
# settings.json — the one cross-service link in this stack that no script
# generates or reconciles, so *arr-side changes strand it silently. The
# UrlBase strip did exactly that: Seerr kept calling /radarr, the *arr
# answered with its SPA page as HTTP 200 (not a 404 — the frontend catch-all
# serves index.html for any unknown path), and every request died with
# `radarrTags.find is not a function` while containers, ports and healthchecks
# all stayed green. Seerr's own Test button does go red on this (HTML breaks
# its JSON parse) — but only when someone presses it.
#
# So ask Seerr itself rather than probing the *arrs: /api/v1/service/<app>/<id>
# makes Seerr fetch that server's quality profiles through its stored
# hostname/port/baseUrl/key — the same hop a request submission uses. Then
# assert the stored default profile ids still exist server-side: a profile
# deleted or re-created in the *arr keeps Test green but fails every submit.
SEERR_SETTINGS="/mnt/user/appdata/seerr/settings.json"
if ! docker inspect seerr >/dev/null 2>&1; then
    warn "seerr not deployed — request wiring not checked"
elif [[ ! -r "$SEERR_SETTINGS" ]]; then
    warn "seerr deployed but no readable settings.json — first-run setup not done?"
else
    # app|serverId|name|storedBaseUrl|defaultProfileIds — one line per server.
    seerr_servers=$(python3 - "$SEERR_SETTINGS" <<'PY' 2>/dev/null
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
for app in ("radarr", "sonarr"):
    for srv in s.get(app) or []:
        ids = [srv.get("activeProfileId")]
        if app == "sonarr":
            ids.append(srv.get("activeAnimeProfileId"))
        idlist = ",".join(str(i) for i in dict.fromkeys(ids) if i is not None)
        print(f'{app}|{srv.get("id")}|{srv.get("name") or app}|{srv.get("baseUrl") or ""}|{idlist}')
PY
)
    SEERR_KEY=$(python3 - "$SEERR_SETTINGS" <<'PY' 2>/dev/null
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("main", {}).get("apiKey", ""))
except Exception:
    pass
PY
)
    if [[ -z "$seerr_servers" ]]; then
        warn "seerr has no radarr/sonarr connections configured — Watchlist requests have nowhere to go"
    elif [[ -z "$SEERR_KEY" ]]; then
        warn "could not read seerr's api key from settings.json — wiring not checked"
    else
        while IFS='|' read -r app sid sname sbase sprofiles; do
            [[ -z "$app" ]] && continue
            resp=$(curl -fsS --max-time 10 -H "X-Api-Key: $SEERR_KEY" \
                "http://127.0.0.1:5055/api/v1/service/$app/$sid" 2>/dev/null)
            # Same quoted-heredoc/env-input pattern as the indexer classifier,
            # for the same reason: inlining JSON into -c '...' lets the shell
            # eat quotes silently.
            report=$(SW_RESP="$resp" SW_APP="$app" SW_NAME="$sname" \
                     SW_BASE="$sbase" SW_WANT="$sprofiles" python3 - <<'PY'
import json, os

app, name = os.environ["SW_APP"], os.environ["SW_NAME"]
base, want = os.environ["SW_BASE"], os.environ["SW_WANT"]
# A stored base URL is the prime suspect: the *arrs serve at root, so any
# prefix is a pre-Tailscale-Services leftover and gets exactly the HTML-as-200
# failure described above.
hint = (f" — stored Base URL '{base}' predates the UrlBase strip; blank it in "
        "Seerr → Settings → Services" if base
        else " — hostname/port/key stale? Seerr → Settings → Services → Test")
try:
    profiles = json.loads(os.environ["SW_RESP"]).get("profiles") or []
except Exception:
    profiles = None
if profiles is None:
    print(f"BAD|seerr cannot fetch quality profiles from {name}{hint}")
elif not profiles:
    print(f"BAD|seerr reaches {name} but sees ZERO quality profiles{hint}")
else:
    have = {str(p.get("id")) for p in profiles}
    missing = [w for w in want.split(",") if w and w not in have]
    if missing:
        print(f"BAD|{name}: seerr's default profile id(s) {','.join(missing)} "
              f"no longer exist in {app} (deleted/re-created?) — submits will "
              "fail; re-pick in Seerr → Settings → Services")
    else:
        print(f"OK|seerr sees {len(profiles)} quality profiles from {name}; "
              "its defaults exist")
PY
)
            # Herestring, not a pipe: counters must increment in this shell.
            while IFS='|' read -r verdict msg; do
                case "$verdict" in
                    OK)   ok   "$msg" ;;
                    BAD)  bad  "$msg" ;;
                    WARN) warn "$msg" ;;
                esac
            done <<< "$report"
        done <<< "$seerr_servers"
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
    # .Self.Tags specifically. Grepping the whole document also matches
    # .Peer[*].Tags, so on any tailnet with a second tag:server machine — which
    # the ACL actively invites — this passed while THIS host was untagged, and
    # an untagged host is what makes every ACL rule and Service approval
    # silently not apply.
    if tailscale status --json 2>/dev/null | python3 -c \
        'import json,sys; sys.exit(0 if "tag:server" in ((json.load(sys.stdin).get("Self") or {}).get("Tags") or []) else 1)' 2>/dev/null; then
        ok "host carries tag:server"
    else
        bad "host missing tag:server — ACL and Service approvals key off it"
    fi

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
            for s in radarr sonarr lidarr prowlarr sab bazarr seerr tautulli profilarr actual coach nextcloud; do
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

    # Assert the RESERVATION IS CONFIGURED, and report free VRAM as information.
    #
    # The old check was `memory.free >= 2048`, which inverts what it claims to
    # test: memory.free counts VRAM nobody has allocated, and Plex's own NVENC
    # sessions consume it. A box with a model resident and two 4K transcodes
    # running — the reservation working exactly as designed — reported "Plex's
    # reservation is not holding" and failed the run. OLLAMA_GPU_OVERHEAD
    # constrains what OLLAMA may allocate; it says nothing about total free.
    # (It also broke outright on a second GPU: two lines of nvidia-smi output
    # into `[[ -ge ]]` is a syntax error, which fell through to `bad`.)
    overhead=$(docker exec ollama printenv OLLAMA_GPU_OVERHEAD 2>/dev/null | tr -dc '0-9')
    if [[ -n "$overhead" ]]; then
        ok "OLLAMA_GPU_OVERHEAD is $(( overhead / 1024 / 1024 )) MiB — Plex's reservation is enforced"
    else
        bad "OLLAMA_GPU_OVERHEAD unset in the ollama container — nothing reserves VRAM for Plex"
    fi
    free=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1)
    [[ -n "$free" ]] && printf '    (GPU currently %s MiB free — informational; low is normal under load)\n' "$free"

else
    warn "ollama not deployed"
fi

# ---------------------------------------------------------------------------
sec "Cloud plane"

if docker inspect nextcloud >/dev/null 2>&1; then
    # The /mnt/cache binds are only safe while every appdata file lives on the
    # cache pool. If someone gives the share a secondary storage tier, files
    # can also land on the array, /mnt/cache/appdata/X and /mnt/user/appdata/X
    # stop being the same files, and a speedup becomes split-brain. This is
    # the check that catches it — it develops silently, months later.
    cachecfg=$(grep -h '^shareUseCache=' /boot/config/shares/appdata.cfg 2>/dev/null | cut -d= -f2 | tr -d ' \r"'"'")
    if [[ -z "$cachecfg" ]]; then
        warn "cannot read appdata share config — verify shareUseCache=only by hand"
    elif [[ "$cachecfg" == "only" ]]; then
        ok "appdata is cache-only (the /mnt/cache nextcloud binds are safe)"
    else
        bad "appdata shareUseCache=$cachecfg, expected 'only' — /mnt/cache and /mnt/user can now DIVERGE"
    fi

    # Ownership, asserted rather than assumed. Unraid's Tools -> New
    # Permissions chowns everything to nobody:users, which breaks both of
    # these — and leaves the containers looking fine until they restart.
    if [[ -d /mnt/user/appdata/nextcloud ]]; then
        got=$(stat -c %u /mnt/user/appdata/nextcloud 2>/dev/null)
        [[ "$got" == "33" ]] \
            && ok "appdata/nextcloud owned by www-data (33)" \
            || bad "appdata/nextcloud owned by uid $got, expected 33 (New Permissions run?)"
    fi
    # Postgres 18 keeps its cluster at <bind>/<major>/docker, not at the bind
    # root — the bind is /var/lib/postgresql, one level above PGDATA. The bind
    # root itself stays root-owned (docker creates it; the entrypoint only
    # chowns PGDATA), so asserting on it would fail on a perfectly good install.
    # Globbed rather than hardcoding 18 so a major upgrade doesn't silently
    # turn this check off.
    for pgdata in /mnt/user/appdata/nextcloud-db/*/docker; do
        [[ -d "$pgdata" ]] || continue
        got=$(stat -c %u "$pgdata" 2>/dev/null)
        [[ "$got" == "70" ]] \
            && ok "$(basename "$(dirname "$pgdata")")/docker cluster owned by postgres (70)" \
            || bad "postgres cluster owned by uid $got, expected 70 (New Permissions run?)"
    done

    occ() { docker exec -u www-data nextcloud php occ "$@" 2>/dev/null; }

    # One round trip, read twice. `occ status` is one of the few commands that
    # still answers while Nextcloud is in maintenance mode, which is exactly
    # the state we most need it to report on.
    ncstatus=$(occ status)
    if echo "$ncstatus" | grep -q 'installed: true'; then
        ok "nextcloud installed"
        echo "$ncstatus" | grep -q 'maintenance: false' \
            && ok "nextcloud not in maintenance mode" \
            || bad "nextcloud is in MAINTENANCE MODE — a backup run left it there? (occ maintenance:mode --off)"
    else
        bad "nextcloud reports not installed"
    fi

    if [[ -n "$TAILNET" ]]; then
        # NOTE the wording: this does NOT produce a 400. Nextcloud's
        # TrustedDomainHelper returns true unconditionally when `overwritehost`
        # is set — "overwritehost is always trusted" is upstream's own comment —
        # and OVERWRITEHOST is set here, so the untrusted-domain gate in
        # base.php is unreachable. The real symptom of a mismatch is subtler and
        # worse: pages serve, but absolute URLs and redirects point at the stale
        # hostname. Worth asserting for exactly that reason; just don't expect
        # a clean error to announce it.
        occ config:system:get trusted_domains | grep -q "nextcloud.$TAILNET" \
            && ok "trusted_domains includes nextcloud.$TAILNET" \
            || bad "trusted_domains missing nextcloud.$TAILNET — links/redirects will point at the wrong host"
    fi

    # The cron container has no healthcheck by design (crond is idle between fires, and
    # pgrep is not guaranteed present). This is the signal that actually
    # matters: did a background job run recently. /cron.sh runs busybox crond, firing every 5 min.
    last=$(occ config:app:get core lastcron | tr -d '[:space:]')
    if [[ -n "$last" && "$last" =~ ^[0-9]+$ ]]; then
        age=$(( ( $(date +%s) - last ) / 60 ))
        [[ "$age" -le 30 ]] \
            && ok "nextcloud background jobs ran ${age}m ago" \
            || bad "nextcloud background jobs last ran ${age}m ago — is nextcloud-cron running?"
    else
        warn "could not read nextcloud lastcron (fresh install?)"
    fi

    docker exec nextcloud-db pg_isready -U nextcloud -d nextcloud >/dev/null 2>&1 \
        && ok "nextcloud-db accepting connections" \
        || bad "nextcloud-db not accepting connections"

    # Plane isolation, asserted from docker's own state rather than by trying
    # to open a socket from inside another container. A connection test needs
    # a binary in the *other* image (bash/nc/curl), and when that binary is
    # missing the test fails in the direction that looks like a pass — which
    # is how seerr and profilarr ran for months with healthchecks that could
    # never succeed. Network membership is the invariant anyway.
    for c in nextcloud nextcloud-db nextcloud-redis nextcloud-cron; do
        docker inspect "$c" >/dev/null 2>&1 || continue
        nets=$(docker inspect "$c" -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')
        [[ "$(echo "$nets" | tr -s ' ' | sed 's/ $//')" == "cloud" ]] \
            && ok "$c is on cloud only" \
            || bad "$c is on: $nets — the cloud plane must be closed"
    done

    # The user files are NOT in appdata, so the Appdata Backup plugin never
    # sees them. This is the only warning anyone gets.
    #
    # The assertion itself is free; only the size is not. `du -sh` here walks a
    # share that may hold a migrated cloud library — hundreds of GB and a lot
    # of inodes — through the shfs FUSE layer, so it is gated behind --quick
    # along with the hardlink and VPN-egress checks. This script is only useful
    # if it stays cheap enough to actually re-run.
    if [[ -d /mnt/user/nextcloud ]]; then
        if grep -qsE '^BACKUP_NEXTCLOUD_REMOTE=[^"'\''[:space:]]' "$STACK_DIR/.env"; then
            ok "nextcloud user files have an offsite target configured"
        else
            warn "nextcloud user files have NO offsite backup (BACKUP_NEXTCLOUD_REMOTE unset) — nothing else covers them"
        fi
        if [[ $QUICK -eq 0 ]]; then
            ncsize=$(du -sh /mnt/user/nextcloud 2>/dev/null | cut -f1)
            [[ -n "$ncsize" ]] && ok "nextcloud user files: $ncsize"
        fi
    fi

    latest_dump=$(ls -t /mnt/cache/appdata/nextcloud-dump/*.sql.gz 2>/dev/null | head -1)
    if [[ -n "$latest_dump" ]]; then
        dage=$(( ( $(date +%s) - $(stat -c %Y "$latest_dump") ) / 86400 ))
        [[ "$dage" -le 8 ]] \
            && ok "nextcloud db dump is ${dage}d old" \
            || warn "newest nextcloud db dump is ${dage}d old"
    else
        warn "no nextcloud db dump found (backup-appdata.sh not run yet?)"
    fi
else
    warn "nextcloud not deployed"
fi

# ---------------------------------------------------------------------------
sec "Data safety"

own_bad=0
for d in /mnt/user/appdata/*/; do
    [[ -d "$d" ]] || continue
    case "$d" in
        # The git repo. Not a bind mount.
        */homeserver/) continue ;;
        # chess-coach's PARENT must stay root-owned (it holds the GitHub deploy
        # key; OpenSSH refuses a key owned by another user) but chess-coach/data
        # is the bind mount and MUST be nobody:users — coach runs as 99:100 on a
        # plain python-slim image with no chown-at-start entrypoint. Skipping
        # the whole tree left the one path that can actually break unchecked, so
        # it is asserted explicitly below instead.
        */chess-coach/) continue ;;
        # The Nextcloud plane is legitimately NOT nobody:users — its images drop
        # to www-data and postgres themselves. Asserted positively in the Cloud
        # plane section, because "not nobody" is correct for these but "anything
        # at all" is not.
        */nextcloud/|*/nextcloud-db/|*/nextcloud-dump/) continue ;;
        # plexinc/pms-docker runs its entrypoint as root by design and manages
        # ownership internally via PLEX_UID/PLEX_GID, so root-owned paths here
        # are correct rather than broken. `docker inspect plex` shows an empty
        # .Config.User, which is the tell.
        */plex/) continue ;;
        # tools holds the gh CLI binary and gh-config/hosts.yml (GitHub token); re-linked into
        # the RAM rootfs at boot by restore_tools User Script, so must remain root-owned.
        */tools/) continue ;;
        # claudecoach is a separate project; repo/.venv, repo/.hypothesis, repo/.pytest_cache are
        # root-owned from uv run pytest as root on the host, but the container runs as 99:100.
        */claudecoach/) continue ;;
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

# The one path inside chess-coach that must be nobody:users. Its parent is
# skipped above (deploy key), so without this the container's most likely
# failure — a root-owned data dir, which is what Docker creates if
# setup-unraid.sh never ran — is invisible to this script.
if [[ -d /mnt/user/appdata/chess-coach/data ]]; then
    cdo=$(stat -c %U /mnt/user/appdata/chess-coach/data 2>/dev/null)
    [[ "$cdo" == "nobody" ]] \
        && ok "chess-coach/data owned by nobody (coach runs as 99:100)" \
        || bad "chess-coach/data owned by $cdo, expected nobody — coach's SQLite writes will fail"
fi

# Mover damage on the PHYSICAL disks. Unraid's mover recreates directory trees
# on the array as ROOT when it migrates in-flight media off the cache, and the
# shfs (FUSE) view masks it: /mnt/user/data/X can stat as nobody:users while
# the copy on one /mnt/diskN underneath is root-owned — and a disk copy is
# what the *arrs actually write through, so imports die with "permission
# denied" while every /mnt/user path looks fine. (Bit this box 2026-08;
# cleaned 2026-08-11.) So check the disks directly, never the FUSE view.
# Directories are where the damage lands (the mover creates them as root; file
# ownership survives the move), so it is dirs at bounded depth — the same
# budget as the appdata check above — plus everything under complete/, which
# at steady state is empty.
if ! ls -d /mnt/disk[0-9]*/data >/dev/null 2>&1; then
    warn "no /mnt/disk*/data mounted — physical-disk ownership not checked"
else
    mover_bad=$( { find /mnt/disk[0-9]*/data/media -maxdepth 3 -type d \
                        \( ! -uid 99 -o ! -gid 100 \) 2>/dev/null
                   find /mnt/disk[0-9]*/data/usenet/complete -maxdepth 4 \
                        \( ! -uid 99 -o ! -gid 100 \) 2>/dev/null; } | sort -u)
    if [[ -z "$mover_bad" ]]; then
        ok "physical-disk media ownership clean (all 99:100 — no mover damage)"
    else
        mover_n=$(wc -l <<<"$mover_bad")
        # Herestring loop, not a pipe: bad() must count in THIS shell.
        while IFS= read -r p; do
            bad "not 99:100 on-disk (mover damage — imports will EACCES): $p"
        done <<<"$(head -10 <<<"$mover_bad")"
        [[ $mover_n -gt 10 ]] && bad "+$((mover_n-10)) more paths under /mnt/disk*/data not owned by 99:100"
    fi
fi

# -maxdepth 2 and all three extensions, matching backup-appdata.sh's own
# search. The Appdata Backup plugin writes DATED SUBDIRECTORIES containing the
# tarball, so a depth-1 `*.tar.gz` glob matched nothing on a real install: this
# reported "no appdata backup found" forever, and since WARN never fails the
# run, the staleness gate below never executed once. A stopped backup plugin is
# precisely what this exists to catch.
latest=$(find /mnt/user/backups/appdata -maxdepth 2 \
              \( -name '*.tar.gz' -o -name '*.tar.zst' -o -name '*.tar' \) \
              -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
if [[ -n "$latest" ]]; then
    age=$(( ( $(date +%s) - $(stat -c %Y "$latest") ) / 86400 ))
    [[ "$age" -le 14 ]] \
        && ok "backup $(basename "$latest") is ${age}d old" \
        || warn "newest backup is ${age}d old"
else
    warn "no appdata backup found in /mnt/user/backups/appdata/"
fi

# Hardlinking is only POSSIBLE while downloads and library live on ONE mount:
# every media-path container must bind the whole share, /mnt/user/data, at
# /data (Key Conventions). Split binds (…/usenet:/downloads + …/media:/media)
# look identical in every app's UI and silently force each import to copy.
# This is the capability half of the hardlink check; the evidence half is
# below, behind --quick. Cheap and ungated — docker inspect answers from
# memory, no media tree is touched.
hl_split=""; hl_seen=0
for c in sabnzbd radarr sonarr lidarr; do
    docker inspect "$c" >/dev/null 2>&1 || continue
    hl_seen=$((hl_seen+1))
    src=$(docker inspect "$c" -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
    [[ "$src" == "/mnt/user/data" ]] || hl_split+="$c(${src:-no /data mount}) "
done
if [[ $hl_seen -eq 0 ]]; then
    warn "no media containers deployed — hardlink capability not checked"
elif [[ -z "$hl_split" ]]; then
    ok "media containers mount /mnt/user/data whole at /data (hardlinks possible)"
else
    bad "split /data binds — these containers CANNOT hardlink, imports copy: $hl_split"
fi

if [[ $QUICK -eq 0 ]]; then
    # Hardlink health, judged on evidence instead of absence.
    #
    # The old check warned whenever no link-count-2 media existed. But the
    # *arrs remove completed downloads after import, so at steady state the
    # library file is the ONLY directory entry left and every link count is
    # legitimately 1 — the warning fired on every healthy run, forever, and a
    # warning that always fires trains the reader to skim past the section.
    #
    # Copying leaves a different fingerprint. An import that hardlinks gives
    # the completed file link count 2 until cleanup removes it; an import that
    # COPIED leaves the completed file at link count 1 with a same-name,
    # same-size twin in the library — the exact pairing dedupe-hardlinks.py
    # repairs (and the same >8M size floor it uses, which also skips the
    # .nfo/.par2 crumbs that legitimately never get imported). Only files past
    # a grace period count — younger ones are simply downloads in flight — and
    # the expensive library index is built only when there is something to
    # pair against, so at steady state this stays one cheap find over an
    # empty tree.
    stale=$(find /mnt/user/data/usenet/complete -type f -links 1 -size +8M \
                 -mmin +120 -printf '%s|%f\n' 2>/dev/null | sort -u)
    if [[ -z "$stale" ]]; then
        ok "hardlinks: steady state — nothing pending import past the 2h grace period"
    else
        libidx=$(find /mnt/user/data/media -type f -size +8M -printf '%s|%f\n' 2>/dev/null | sort -u)
        copied=$(comm -12 <(printf '%s\n' "$stale") <(printf '%s\n' "$libidx"))
        if [[ -n "$copied" ]]; then
            ncop=$(wc -l <<<"$copied")
            warn "$ncop completed file(s) were COPIED into the library, not hardlinked — check copyUsingHardlinks in the *arrs, then dedupe-hardlinks.py:"
            while IFS='|' read -r _ f; do
                printf '  \033[36m·\033[0m %s\n' "$f"
            done <<<"$(head -5 <<<"$copied")"
            [[ $ncop -gt 5 ]] && printf '  \033[36m·\033[0m +%d more\n' $((ncop-5))
        else
            nstale=$(wc -l <<<"$stale")
            warn "$nstale file(s) in complete/ older than 2h with no library twin — imports may be stuck (check the *arr Activity queues)"
        fi
    fi

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
