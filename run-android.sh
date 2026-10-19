#!/usr/bin/env bash
# Runs the end-to-end UI tests on an Android emulator: the same Maestro flows
# run.sh runs on iOS, against the same kind of throwaway stack on this Mac:
#   Postgres   a private cluster in a temp folder (Postgres.app's binaries)
#   llm        a stand-in AI model with scripted answers (../test-web/fake-llm)
#   api        the backend, built from ../customer-data
#   app        a release build of ../website, pointed at that backend (the
#              emulator reaches it on its own localhost, through `adb reverse`)
# The emulator records its screen to videos/android/<test name>.webm while each
# flow runs. The ports differ from run.sh's, so both can run at the same time.
#
#   ./run-android.sh                 build the app, run every flow, stop the stack
#   ./run-android.sh --no-build      reuse the last app build
#   ./run-android.sh --device Pixel_9
#                                    emulator to use (AVD name; default: the
#                                    running emulator, else the first AVD)
#   ./run-android.sh 04 assistant    only flows whose file name contains one of these
#   ./run-android.sh --up            start the stack and install the app, then wait
#                                    (for writing flows: `maestro test flows/03-….yaml`
#                                    with the -e values printed); Ctrl+C stops it
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WEBSITE="$ROOT/website"
APP_ID=com.mustard.app
DB_PORT="${E2E_DB_PORT:-18291}"
API_PORT="${E2E_API_PORT:-18290}"
LLM_PORT="${E2E_LLM_PORT:-18292}"
BUILT_APK="$WEBSITE/android/app/build/outputs/apk/release/app-release.apk"
# The runner's own copy, so --no-build never picks up an app built for another server.
APK="$HERE/.generated/android/mustard-e2e.apk"
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

for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
  if [ -n "$sdk" ] && [ -d "$sdk/platform-tools" ]; then export ANDROID_HOME="$sdk"; break; fi
done
[ -d "${ANDROID_HOME:-}/platform-tools" ] || fail "Android SDK not found. Install Android Studio or set ANDROID_HOME."
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
[ -x "$MAESTRO" ] || fail "Maestro not found. Install it: https://docs.maestro.dev/getting-started/installing-maestro"
PGBIN="$(dirname "$(command -v initdb 2>/dev/null || echo /Applications/Postgres.app/Contents/Versions/latest/bin/initdb)")"
[ -x "$PGBIN/initdb" ] || fail "Postgres binaries (initdb, pg_ctl) not found. Install Postgres.app or Homebrew postgresql."
for port in "$DB_PORT" "$API_PORT" "$LLM_PORT"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    fail "Port $port is in use (set E2E_DB_PORT / E2E_API_PORT / E2E_LLM_PORT)."
  fi
done

# ---------- The app ----------

if [ "$BUILD" = 1 ] || [ ! -f "$APK" ]; then
  step "Building the app (release) for http://localhost:$API_PORT"
  (cd "$WEBSITE" && EXPO_PUBLIC_API_URL="http://localhost:$API_PORT" npm run --silent android:build) \
    || fail "The app didn't build."
  mkdir -p "$(dirname "$APK")"
  cp "$BUILT_APK" "$APK"
fi

# ---------- The stack ----------

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mustard-android-e2e.XXXXXX")"
PIDS=()
SERIAL=
cleanup() {
  [ -n "$SERIAL" ] && adb -s "$SERIAL" reverse --remove "tcp:$API_PORT" >/dev/null 2>&1 || true
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

step "Preparing the emulator"
# The serial (emulator-5554) of a running emulator: the one showing the AVD
# named $1, or the first one when no name is given.
running_emulator() {
  local serial
  for serial in $(adb devices | awk '$1 ~ /^emulator-/ && $2 == "device" { print $1 }'); do
    if [ -z "$1" ] || [ "$(adb -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r')" = "$1" ]; then
      echo "$serial"
      return
    fi
  done
}
SERIAL="$(running_emulator "$DEVICE")"
if [ -z "$SERIAL" ]; then
  avd="${DEVICE:-$(emulator -list-avds 2>/dev/null | grep -v '^INFO' | head -1 || true)}"
  [ -n "$avd" ] || fail "No Android emulator set up. Create one in Android Studio's Device Manager."
  emulator -list-avds 2>/dev/null | grep -qx "$avd" || fail "No Android emulator named \"$avd\" (see \`emulator -list-avds\`)."
  echo "Booting $avd"
  nohup emulator -avd "$avd" >"$TMP/emulator.log" 2>&1 &
  for _ in $(seq 1 120); do
    SERIAL="$(running_emulator "$avd")"
    [ -n "$SERIAL" ] && break
    sleep 1
  done
  [ -n "$SERIAL" ] || { tail -20 "$TMP/emulator.log"; fail "The emulator didn't start."; }
fi
# Booted, and past the placeholder home screen Android shows first.
resumed() { adb -s "$SERIAL" shell dumpsys activity activities 2>/dev/null | grep -m1 ResumedActivity || true; }
until [ "$(adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] &&
  [ -n "$(resumed)" ] && [[ "$(resumed)" != *FallbackHome* ]]; do
  sleep 1
done
adb -s "$SERIAL" reverse "tcp:$API_PORT" "tcp:$API_PORT" >/dev/null
adb -s "$SERIAL" uninstall "$APP_ID" >/dev/null 2>&1 || true
adb -s "$SERIAL" install "$APK" >"$TMP/install.log" 2>&1 || { cat "$TMP/install.log"; fail "Couldn't install the app."; }
echo "Device: $(adb -s "$SERIAL" emu avd name | head -1 | tr -d '\r') ($SERIAL), Android $(adb -s "$SERIAL" shell getprop ro.build.version.release | tr -d '\r')"

# ---------- The flows ----------

EMAIL="e2e-$(openssl rand -hex 4)@example.test"
PASSWORD="$(openssl rand -hex 12)"

if [ "$MODE" = up ]; then
  step "Up"
  echo "Backend http://localhost:$API_PORT, device $SERIAL. Run flows with:"
  echo "  maestro --device $SERIAL test -e EMAIL=$EMAIL -e PASSWORD=<see .generated/android/account.env> flows/<flow>.yaml"
  mkdir -p "$HERE/.generated/android"
  printf 'EMAIL=%s\nPASSWORD=%s\nSERIAL=%s\n' "$EMAIL" "$PASSWORD" "$SERIAL" > "$HERE/.generated/android/account.env"
  echo "Ctrl+C stops the stack."
  # Waiting on a background sleep lets Ctrl+C (or kill) stop the stack at once.
  while true; do sleep 3600 & wait $!; done
fi

mkdir -p "$HERE/videos/android" "$HERE/reports/android"
rm -f "$HERE/videos/android/"*.webm

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
  video="$HERE/videos/android/$(printf '%s' "$name" | tr '/\\:*?"<>|' '---------').webm"
  step "$name"

  # The emulator records its own screen (adb's screenrecord stops after 3 minutes).
  # Its console splits arguments at spaces, so record to a plain path and move it.
  rm -f "$TMP/recording.webm"
  adb -s "$SERIAL" emu screenrecord start --time-limit 1800 "$TMP/recording.webm" >/dev/null

  status=0
  "$MAESTRO" --device "$SERIAL" test \
    -e EMAIL="$EMAIL" -e PASSWORD="$PASSWORD" \
    --test-output-dir "$HERE/reports/android/$(basename "$flow" .yaml)" \
    "$flow" || status=$?

  sleep 1
  adb -s "$SERIAL" emu screenrecord stop >/dev/null
  # The emulator finishes writing the file a moment after it's told to stop.
  size=-1
  for _ in $(seq 1 30); do
    sleep 1
    now="$(stat -f %z "$TMP/recording.webm" 2>/dev/null || stat -c %s "$TMP/recording.webm" 2>/dev/null || echo 0)"
    [ "$now" -gt 0 ] && [ "$now" = "$size" ] && break
    size="$now"
  done
  mv "$TMP/recording.webm" "$video" 2>/dev/null || echo "No screen recording for this flow."

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
  echo "Failed: ${failed[*]} (screenshots and logs in reports/android/)"
  echo "--- backend log (last 20 lines)"
  tail -20 "$TMP/api.log"
fi
echo "Videos:"
ls -1 "$HERE/videos/android"
[ ${#failed[@]} -eq 0 ]
