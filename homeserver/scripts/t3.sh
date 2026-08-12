check_indexers() {
    local name=$1 port=$2 ver=$3 key json level
    key=stub
    if [[ -z "$key" ]]; then
        warn "$name: no API key in $(basename "$ENV_FILE") — skipping"
        return
    fi
    json=$(cat "$2")
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


echo "--- live shape: sonarr disabled + empty ---"
check_indexers radarr fixture_good.json v3
check_indexers sonarr fixture_empty.json v3
echo "--- sonarr disabled, hand-managed indexer (must be OK) ---"
check_indexers sonarr fixture_direct.json v3
echo "--- unknown level (prowlarr unreachable) ---"
APP_LEVELS=""
check_indexers sonarr fixture_bad.json v3
echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
