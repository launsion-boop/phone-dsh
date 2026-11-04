#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# One command from a clean checkout to ONE complete turn started by the APP:
#   app launch (env base URL) -> XL_DSH_READY -> tap "跑一轮" -> the App's own
#   `/api` lane -> scripted model -> `phone info` -> host exec -> turn_ended.
#
# The model is a SCRIPT: android/tools/scripted-model-upstream.py answers the
# first request with a tool call and the request carrying the tool result with a
# final text. This script cannot and does not claim that a model ran.
#
# The App reaches the host machine's upstream through `adb reverse`: the device's
# 127.0.0.1:<port> is tunneled to this host's 127.0.0.1:<port>. The injected
# value travels only through the engine's `env` page parameter, never as a query
# parameter of its own and never into a log line.
#
# Usage:
#   bash android/tools/run-app-turn.sh              # build, install, run
#   bash android/tools/run-app-turn.sh --no-build   # reuse the existing APK
#
# Environment:
#   ANDROID_HOME  (default from android/local.properties on this host)
#   JAVA_HOME     (derived from `java` on PATH when unset)
#   ANDROID_SERIAL / SERIAL  pin one device (default: first emulator)
#   PDSH_AVD      (default pdsh35) default AVD when no emulator is attached

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$(sed -n 's/^sdk\.dir=//p' "$ROOT/android/local.properties" 2>/dev/null | head -1)}"
if [ -z "${JAVA_HOME:-}" ] && command -v java >/dev/null 2>&1; then
  JAVA_HOME="$(cd "$(dirname "$(command -v java)")/.." && pwd)"
fi
PDSH_AVD="${PDSH_AVD:-pdsh35}"
PACKAGE="${PDSH_PACKAGE:-com.phonedsh.app}"
ARTIFACTS="$ROOT/android/build/app-turn-artifacts"
PROMPT="Run phone info and tell me what it says."

BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    -h|--help)  sed -n '3,27p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

export ANDROID_HOME JAVA_HOME
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

say() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "${ANDROID_HOME:-}" ] || die "no ANDROID_HOME and android/local.properties has no sdk.dir"
command -v adb >/dev/null 2>&1 || die "adb not found under $ANDROID_HOME"
command -v python3 >/dev/null 2>&1 || die "python3 is required for the scripted upstream"

# ---------------------------------------------------------------- device
say "device"
if [ -z "${SERIAL:-}" ]; then SERIAL="${ANDROID_SERIAL:-}"; fi
if [ -z "${SERIAL:-}" ]; then
  SERIAL="$(adb devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')"
fi
if [ -z "${SERIAL:-}" ]; then
  "$ANDROID_HOME/emulator/emulator" -avd "$PDSH_AVD" \
      -no-window -no-audio -no-boot-anim -no-snapshot \
      -gpu swiftshader_indirect >"$ROOT/android/build/app-turn-emulator.log" 2>&1 &
  echo "booting $PDSH_AVD (log: android/build/app-turn-emulator.log)"
  adb wait-for-device
  for _ in $(seq 1 60); do
    [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 2
  done
  SERIAL="$(adb devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')"
fi
[ -n "${SERIAL:-}" ] || die "could not pin a device"
export ANDROID_SERIAL="$SERIAL"
adb() { command adb ${SERIAL:+-s "$SERIAL"} "$@"; }
echo "device: $SERIAL ($(adb shell getprop ro.product.cpu.abi | tr -d '\r'), SDK $(adb shell getprop ro.build.version.release | tr -d '\r'))"

mkdir -p "$ARTIFACTS"

# ---------------------------------------------------------------- build
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
if [ "$BUILD" = "1" ]; then
  say "build :app"
  ( cd "$ROOT/android" && ./gradlew :app:assembleDebug --no-daemon --console=plain )
fi
[ -f "$APK" ] || die "no APK at $APK (run without --no-build)"

# ---------------------------------------------------------------- upstream
say "scripted upstream"
python3 "$ROOT/android/tools/scripted-model-upstream.py" --port 0 \
  >"$ARTIFACTS/upstream.log" 2>&1 &
UPSTREAM_PID=$!
PORT=""
for _ in $(seq 1 50); do
  PORT="$(awk '/^LISTENING /{print $2; exit}' "$ARTIFACTS/upstream.log" 2>/dev/null || true)"
  [ -n "$PORT" ] && break
  sleep 0.1
done
[ -n "$PORT" ] || die "the scripted upstream did not print a port (see $ARTIFACTS/upstream.log)"
BASE_URL="http://127.0.0.1:$PORT"
echo "upstream: $BASE_URL (scripted, host process $UPSTREAM_PID)"
echo "adb reverse tcp:$PORT -> host tcp:$PORT"
adb reverse "tcp:$PORT" "tcp:$PORT" >/dev/null

cleanup() {
  [ -n "${UPSTREAM_PID:-}" ] && kill "$UPSTREAM_PID" 2>/dev/null || true
  [ -n "${PORT:-}" ] && adb reverse --remove "tcp:$PORT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------- install
say "install"
adb install -r -t "$APK" >/dev/null

# ---------------------------------------------------------------- launch
say "launch with the env base URL"
COMPONENT="$(adb shell cmd package resolve-activity --brief "$PACKAGE" 2>/dev/null \
  | tr -d '\r' | tail -1)"
[ -n "$COMPONENT" ] || die "could not resolve the launcher activity of $PACKAGE"
adb shell am force-stop "$PACKAGE" >/dev/null
adb logcat -c
# `pdsh.model.proxy false` is not optional here: the scripted upstream is a test
# fixture, and a mounted model edge would inject whatever real key the device
# happens to hold into it. The fixture must never see a production credential.
adb shell am start -W -n "$COMPONENT" \
  --es pdsh.deepseek.baseUrl "$BASE_URL" \
  --es pdsh.egress.origin "$BASE_URL" \
  --es pdsh.prompt "\"$PROMPT\"" \
  --ez pdsh.egress.probe true \
  --ez pdsh.model.proxy false \
  --ez pdsh.face.probe true >/dev/null
# `pdsh.face.probe`: the launch face is the product home now (L62), so a driver
# that types into 「跑一轮」 has to ask for the probe face. Without it this script
# waits on a session list that never shows the button.

wait_for() {
  local pattern="$1" deadline="$2" label="$3"
  local end=$((SECONDS + deadline))
  while [ "$SECONDS" -lt "$end" ]; do
    if adb logcat -d -s PDSHAppTurn 2>/dev/null | grep -q "$pattern"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

say "wait for the Worker's ready announcement"
if ! wait_for "APP_WORKER_READY" 240 "ready"; then
  adb logcat -d >"$ARTIFACTS/logcat.txt" 2>/dev/null || true
  tail -20 "$ARTIFACTS/logcat.txt" || true
  die "the Worker never announced XL_DSH_READY (see $ARTIFACTS/logcat.txt)"
fi
echo "worker announced XL_DSH_READY"

# ---------------------------------------------------------------- tap
say 'tap the App button "跑一轮"'
UI_DUMP="$ARTIFACTS/ui.xml"
adb shell uiautomator dump /sdcard/pdsh-app-turn.xml >/dev/null 2>&1 || true
adb pull /sdcard/pdsh-app-turn.xml "$UI_DUMP" >/dev/null 2>&1 || true
TAP="$(python3 - "$UI_DUMP" <<'PY'
import sys
import xml.etree.ElementTree as ET
path = sys.argv[1]
try:
    root = ET.parse(path).getroot()
except Exception:
    print("")
    raise SystemExit
candidates = []
for node in root.iter("node"):
    text = (node.get("text") or "").strip()
    desc = (node.get("content-desc") or "").strip()
    if text == "跑一轮" or desc == "跑一轮":
        candidates.insert(0, node)
    elif "跑一轮" in text or "跑一轮" in desc:
        candidates.append(node)
for node in candidates:
    bounds = node.get("bounds") or ""
    try:
        left_top, right_bottom = bounds.split("][")
        left, top = left_top.lstrip("[").split(",")
        right, bottom = right_bottom.rstrip("]").split(",")
        print(f"{(int(left) + int(right)) // 2} {(int(top) + int(bottom)) // 2}")
    except Exception:
        print("")
    break
PY
)"
[ -n "$TAP" ] || die "the UI has no visible 跑一轮 node (dump: $UI_DUMP)"
echo "tap at $TAP"
adb shell input tap $TAP
adb logcat -d -s PDSHAppTurn | grep "APP_TURN_BUTTON" >/dev/null \
  || echo "warning: no APP_TURN_BUTTON line yet (the tap may have missed)"

# ---------------------------------------------------------------- turn
say "wait for APP_TURN_OK"
if ! wait_for "APP_TURN_OK" 300 "turn"; then
  adb logcat -d >"$ARTIFACTS/logcat.txt" 2>/dev/null || true
  grep -E "PDSHAppTurn|PDSHHost: api:|PDSHHost: channel" "$ARTIFACTS/logcat.txt" | tail -40 || true
  die "the App did not report APP_TURN_OK (see $ARTIFACTS/logcat.txt)"
fi

# Watch one durability window for the missing JOURNAL lane's restart behaviour.
say "watch 45s for the journal lane's durability restart"
sleep 45
adb logcat -d >"$ARTIFACTS/logcat.txt" 2>/dev/null || true

say "app turn: host events (PDSHAppTurn)"
grep -E "PDSHAppTurn: host event:" "$ARTIFACTS/logcat.txt" | sed -E 's/^.*PDSHAppTurn: //' || true

say "app turn: /api frames (PDSHHost)"
grep -E "PDSHHost: api:" "$ARTIFACTS/logcat.txt" | sed -E 's/^.*PDSHHost: //' || true

say "channel opens and journal-related lines"
grep -E "PDSHHost: channel (open|closed)" "$ARTIFACTS/logcat.txt" | sed -E 's/^.*PDSHHost: //' || true
grep -iE "journal|durability|ring_timeout|restarting the connection|channel closed" \
  "$ARTIFACTS/logcat.txt" | tail -16 || true

# ---------------------------------------------------------------- assert
say "assertions"
STATUS=0
assert_contains() {
  if grep -q "$1" "$ARTIFACTS/logcat.txt"; then
    echo "PASS $2"
  else
    echo "FAIL $2"
    STATUS=1
  fi
}
assert_contains "PDSHAppTurn: host event: kind=turn_started" "turn_started event"
assert_contains "PDSHAppTurn: host event: kind=tool_call" "tool_call event"
assert_contains "PDSHAppTurn: host event: kind=tool_result" "tool_result event"
assert_contains "PDSHAppTurn: host event: kind=turn_ended" "turn_ended event"
assert_contains "PDSHAppTurn: host event: kind=turn_ended .* reason=completed" "turn_ended(reason=completed)"
assert_contains "PDSHAppTurn: APP_TURN_OK" "App reported completion"
assert_contains "PDSHHost: api: API_REQ" "host sent API_REQ frames"
assert_contains "PDSHHost: api: API_RES" "host received API_RES frames"
assert_contains "PDSHHost: api: API_END" "host received API_END frames"
assert_contains "PDSHAppTurn: APP_EGRESS_OK status=200" "App /v1/http allowed the exact origin"
assert_contains "PDSHAppTurn: APP_EGRESS_DENIED status=403" "App /v1/http denied an unlisted origin"
# The order is part of the claim, not just the presence.
ORDER="$(grep -E "PDSHAppTurn: host event: kind=(turn_started|tool_call|tool_result|turn_ended)" \
  "$ARTIFACTS/logcat.txt" | sed -E 's/^.*kind=([a-z_]+).*/\1/' | tr '\n' ' ')"
case "$ORDER" in
  "turn_started tool_call tool_result turn_ended "*) echo "PASS event order: $ORDER" ;;
  *) echo "FAIL event order: ${ORDER:-<none>}"; STATUS=1 ;;
esac

CHANNEL_OPENS="$(grep -c "PDSHHost: channel open" "$ARTIFACTS/logcat.txt" || true)"
DURABILITY_TIMEOUTS="$(grep -c "durability ack wait timed out" "$ARTIFACTS/logcat.txt" || true)"
RESTART_LINES="$(grep -c "restarting the connection" "$ARTIFACTS/logcat.txt" || true)"
echo "channel connections this run: $CHANNEL_OPENS"
echo "durability timeouts this run: $DURABILITY_TIMEOUTS (restarting lines: $RESTART_LINES)"
if [ "$CHANNEL_OPENS" -gt 1 ] || [ "$DURABILITY_TIMEOUTS" -gt 0 ]; then
  echo "journal observation: the Worker hit the missing JOURNAL lane's 30 s durability wait and restarted the channel"
else
  echo "journal observation: no durability timeout or channel reopen was observed inside the 45s watch"
fi

say "receipt"
echo "device: $SERIAL (emulator; not a physical device)"
echo "model: SCRIPTED (android/tools/scripted-model-upstream.py); no inference ran"
echo "base URL: injected through pageParams[\"env\"] only (host:127.0.0.1:$PORT)"
echo "prompt: $PROMPT"
echo "artifacts: $ARTIFACTS"
echo "upstream requests:"
grep -E "MODEL_REQ|MODEL_OK" "$ARTIFACTS/upstream.log" || true
exit "$STATUS"
