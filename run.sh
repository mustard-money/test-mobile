#!/usr/bin/env bash
# Runs the end-to-end UI tests on an iOS simulator through Xcode 27's Device Hub,
# against a throwaway stack on this Mac:
#   Postgres   a private cluster in a temp folder (Postgres.app's binaries)
#   llm        a stand-in AI model with scripted answers (../test-web/fake-llm)
#   api        the backend, built from ../customer-data
#   app        a Release simulator build of ../website, pointed at that backend
# Each flow in flows/ is a Maestro test; devicectl records the device's screen
# to videos/<test name>.mp4 while it runs.
#
#   ./run.sh                    build the app, run every flow, stop the stack
#   ./run.sh --no-build         reuse the last app build
#   ./run.sh --device "iPhone 17 Pro"
#                               simulator to use (name or UDID; default: the
#                               booted iPhone, else the newest available one)
#   ./run.sh 04 assistant       only flows whose file name contains one of these
#   ./run.sh --up               start the stack and install the app, then wait
#                               (for writing flows: `maestro test flows/03-….yaml`
#                               with the -e values printed); Ctrl+C stops it
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WEBSITE="$ROOT/website"
BUNDLE_ID=com.mustard.app
DB_PORT="${E2E_DB_PORT:-18191}"
API_PORT="${E2E_API_PORT:-18190}"
LLM_PORT="${E2E_LLM_PORT:-18192}"
BUILD_DIR=ios/build-e2e
APP="$WEBSITE/$BUILD_DIR/Build/Products/Release-iphonesimulator/Mustard.app"
MAESTRO="${MAESTRO:-$(command -v maestro || echo "$HOME/.maestro/bin/maestro")}"
export MAESTRO_CLI_NO_ANALYTICS=1 MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true

MODE=test
BUILD=1
DEVICE=
FILTERS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --up) MODE=up ;;
    --no-build) BUILD=0 ;;
    --device) DEVICE="$2"; shift ;;
    -h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) FILTERS+=("$1") ;;
  esac
  shift
done

step() { printf '\n\033[1;33m▸ %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- Prerequisites ----------

[[ "$(xcodebuild -version 2>/dev/null || true)" == Xcode* ]] || fail "Xcode isn't installed."
xcrun --find devicectl >/dev/null 2>&1 || fail "devicectl not found; select Xcode 27 with xcode-select."
[ -x "$MAESTRO" ] || fail "Maestro not found. Install it: https://docs.maestro.dev/getting-started/installing-maestro"
PGBIN="$(dirname "$(command -v initdb 2>/dev/null || echo /Applications/Postgres.app/Contents/Versions/latest/bin/initdb)")"
[ -x "$PGBIN/initdb" ] || fail "Postgres binaries (initdb, pg_ctl) not found. Install Postgres.app or Homebrew postgresql."
for port in "$DB_PORT" "$API_PORT" "$LLM_PORT"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    fail "Port $port is in use (set E2E_DB_PORT / E2E_API_PORT / E2E_LLM_PORT)."
  fi
done

# ---------- The app ----------

if [ "$BUILD" = 1 ] || [ ! -d "$APP" ]; then
  step "Building the app (Release, simulator) for http://localhost:$API_PORT"
  (cd "$WEBSITE" && EXPO_PUBLIC_API_URL="http://localhost:$API_PORT" IOS_BUILD_DIR="$BUILD_DIR" \
    npm run --silent ios:build) || fail "The app didn't build."
fi
[ -d "$APP" ] || fail "No app at $APP."

# ---------- The stack ----------

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mustard-mobile-e2e.XXXXXX")"
PIDS=()
cleanup() {
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  [ -d "$TMP/pg" ] && "$PGBIN/pg_ctl" -D "$TMP/pg" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

step "Starting Postgres, the stand-in model and the backend"
"$PGBIN/initdb" -D "$TMP/pg" -U mustard --auth=trust >"$TMP/initdb.log" 2>&1 || { cat "$TMP/initdb.log"; fail "initdb failed."; }
"$PGBIN/pg_ctl" -D "$TMP/pg" -l "$TMP/postgres.log" -w \
  -o "-p $DB_PORT -k $TMP -c listen_addresses=127.0.0.1 -c fsync=off" start >/dev/null
"$PGBIN/createdb" -h 127.0.0.1 -p "$DB_PORT" -U mustard mustard

HOST=127.0.0.1 PORT="$LLM_PORT" python3 "$ROOT/test-web/fake-llm/server.py" >"$TMP/llm.log" 2>&1 &
PIDS+=($!)

(cd "$ROOT/customer-data" && go build -o "$TMP/server" .) || fail "The backend didn't build."
DATABASE_URL="postgres://mustard@127.0.0.1:$DB_PORT/mustard?sslmode=disable" \
  PORT="$API_PORT" \
  LLM_PROVIDER=openai LLM_BASE_URL="http://127.0.0.1:$LLM_PORT/v1" LLM_MODEL=stand-in \
  "$TMP/server" >"$TMP/api.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$API_PORT/api/v1/auth/me" || true)"
  [ "$code" = 401 ] && break
  sleep 0.5
done
[ "${code:-}" = 401 ] || { tail -20 "$TMP/api.log"; fail "The backend didn't start."; }

# ---------- The device ----------

step "Preparing the simulator in Device Hub"
UDID="$(python3 - "$DEVICE" <<'EOF'
import json, re, subprocess, sys
wanted = sys.argv[1]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
phones = []
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    version = tuple(int(n) for n in re.findall(r"\d+", runtime.split("iOS")[-1]))
    for d in devices:
        if d["name"].startswith("iPhone"):
            phones.append((d["state"] == "Booted", version, d["name"], d["udid"]))
if wanted:
    match = [p for p in phones if wanted in (p[2], p[3])]
    phones = sorted(match, reverse=True)
else:
    phones.sort(reverse=True)  # booted first, then the newest iOS
print(phones[0][3] if phones else "")
EOF
)"
[ -n "$UDID" ] || fail "No iPhone simulator${DEVICE:+ named \"$DEVICE\"}. Add one in Device Hub."
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
# Show the device in Device Hub (Xcode 27's replacement for Simulator.app).
open "devices://device/open?id=$UDID" 2>/dev/null || open -a DeviceHub 2>/dev/null || true
xcrun devicectl device uninstall app --device "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun devicectl device install app --device "$UDID" "$APP" >"$TMP/install.log" 2>&1 \
  || { cat "$TMP/install.log"; fail "Couldn't install the app."; }
echo "Device: $(xcrun simctl list devices | grep "$UDID" | sed 's/^ *//')"

# Prints "value x,y" for the AutoFill switch on the open Settings page: its
# value (1 = on) and the point of the switch at the right end of its row.
autofill_switch() {
  "$MAESTRO" --device "$UDID" hierarchy 2>/dev/null | python3 -c '
import json, re, sys
def walk(node):
    attrs = node.get("attributes", {})
    if attrs.get("resource-id") == "AutoFillToggle":
        x1, y1, x2, y2 = map(int, re.findall(r"\d+", attrs["bounds"]))
        print(attrs.get("value"), f"{x2 - 30},{(y1 + y2) // 2}")
        sys.exit()
    for child in node.get("children", []):
        walk(child)
walk(json.load(sys.stdin))'
}

# Password AutoFill covers the sign-up form with prompts that aren't part of
# the app (see setup/ios-autofill-off.yaml), so turn it off on the simulator.
autofill_off() {
  "$MAESTRO" --device "$UDID" test "$HERE/setup/ios-autofill-off.yaml" >"$TMP/setup.log" 2>&1 \
    || { cat "$TMP/setup.log"; fail "Couldn't open the AutoFill settings."; }
  read -r value point <<<"$(autofill_switch)"
  if [ "$value" = 1 ]; then
    "$MAESTRO" --device "$UDID" test -e POINT="$point" "$HERE/setup/tap-point.yaml" >>"$TMP/setup.log" 2>&1
    read -r value point <<<"$(autofill_switch)"
  fi
  [ "$value" = 0 ] || fail "Couldn't turn off password AutoFill (Settings > General > AutoFill & Passwords)."
  xcrun simctl terminate "$UDID" com.apple.Preferences 2>/dev/null || true
  echo "Password AutoFill: off"
}
autofill_off

# ---------- The flows ----------

EMAIL="e2e-$(openssl rand -hex 4)@example.test"
PASSWORD="$(openssl rand -hex 12)"

if [ "$MODE" = up ]; then
  step "Up"
  echo "Backend http://localhost:$API_PORT, device $UDID. Run flows with:"
  echo "  maestro --device $UDID test -e EMAIL=$EMAIL -e PASSWORD=<see .generated/account.env> flows/<flow>.yaml"
  mkdir -p "$HERE/.generated"
  printf 'EMAIL=%s\nPASSWORD=%s\nUDID=%s\n' "$EMAIL" "$PASSWORD" "$UDID" > "$HERE/.generated/account.env"
  echo "Ctrl+C stops the stack."
  # Waiting on a background sleep lets Ctrl+C (or kill) stop the stack at once.
  while true; do sleep 3600 & wait $!; done
fi

mkdir -p "$HERE/videos" "$HERE/reports"
rm -f "$HERE/videos/"*.mp4

# Job control, so the screen recorder runs in its own process group and stops
# on SIGINT (like Ctrl+C), which is how devicectl finishes writing the video.
set -m

flows=()
for flow in "$HERE"/flows/*.yaml; do
  if [ ${#FILTERS[@]} -gt 0 ]; then
    keep=0
    for f in "${FILTERS[@]}"; do [[ "$(basename "$flow")" == *"$f"* ]] && keep=1; done
    [ "$keep" = 1 ] || continue
  fi
  flows+=("$flow")
done
[ ${#flows[@]} -gt 0 ] || fail "No flows match: ${FILTERS[*]}"

passed=0
failed=()
for flow in "${flows[@]}"; do
  name="$(sed -n 's/^name: *//p' "$flow" | head -1 | sed 's/^"\(.*\)"$/\1/')"
  name="${name:-$(basename "$flow" .yaml)}"
  video="$HERE/videos/$(printf '%s' "$name" | tr '/\\:*?"<>|' '---------').mp4"
  step "$name"

  xcrun devicectl device capture screen-record --device "$UDID" --destination "$video" \
    --quiet >"$TMP/record.log" 2>&1 &
  recorder=$!
  sleep 1

  status=0
  "$MAESTRO" --device "$UDID" test \
    -e EMAIL="$EMAIL" -e PASSWORD="$PASSWORD" \
    --test-output-dir "$HERE/reports/$(basename "$flow" .yaml)" \
    "$flow" || status=$?

  sleep 1
  kill -INT "$recorder" 2>/dev/null || true
  wait "$recorder" 2>/dev/null || true

  if [ "$status" = 0 ]; then
    passed=$((passed + 1))
  else
    failed+=("$name")
    # Later flows build on this one's data, so stop here.
    break
  fi
done

step "Results"
echo "Passed: $passed of ${#flows[@]}"
if [ ${#failed[@]} -gt 0 ]; then
  echo "Failed: ${failed[*]} (screenshots and logs in reports/)"
  echo "--- backend log (last 20 lines)"
  tail -20 "$TMP/api.log"
fi
echo "Videos:"
ls -1 "$HERE/videos"
[ ${#failed[@]} -eq 0 ]
