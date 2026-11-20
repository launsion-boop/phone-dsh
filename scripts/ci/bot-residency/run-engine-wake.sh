#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Engine-first-launch wake measurement (plan §2.4): one command on the caller's
# Mac + iPhone. It extends the WP1 BotResidencySpike app and the same analyzer;
# it is not a second harness. Exit: 0 PASS, 1 FAIL, 2 usage error, 3 NOT_RUN.
#
# Simulator runs exercise the harness but are never device evidence: the app
# stamps deviceClass=simulator and analyze.py keeps every scenario NOT_RUN.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SPEC_DIR="$HERE/app"
BUNDLE_ID="dev.phone-dsh.bot-residency-spike"
DEVICE=""
SIMULATOR=""
TEAM=""
RUN_ID="engine-wake-$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUT=""
SCENARIOS="push-cold-start,push-parked-resume,bgprocessing-cold-start,board-wake-cold-start,lan-resident,lan-suspended"
ITERATIONS=5
LAN_HOST=""
POLL_SECONDS=1
TIMEOUT_SECONDS=3600
SKIP_BUILD=0

usage() {
  cat <<'EOF'
Usage:
  bash scripts/ci/bot-residency/run-engine-wake.sh \
    --development-team <team-id> [options]

Options:
  --device <devicectl identifier>  Select one available physical iOS device.
  --simulator <name-or-udid>       Harness-only run; every verdict is NOT_RUN.
  --development-team <team-id>     Apple signing team (automatic signing).
  --bundle-id <bundle-id>          Default dev.phone-dsh.bot-residency-spike.
  --run-id <run-id>                Evidence/workspace namespace (default unique).
  --output-dir <path>              Default $TMPDIR/phonedsh-engine-wake/<run-id>.
  --scenarios <csv>                Default: all six scenarios.
  --iterations <n>                 Attempts per push/BGTask/board scenario (default 5).
  --lan-host <device-LAN-IP>       Required for meaningful LAN probe evidence.
  --poll-seconds <seconds>         Device polling interval, minimum 0.25 (default 1).
  --timeout-seconds <seconds>      Overall wait for external triggers (default 3600).
  --skip-build                     Reuse the app already installed on the device.

Scenarios (fixed ids, see docs/perf/engine-wake/README.md):
  push-cold-start, push-parked-resume, bgprocessing-cold-start,
  board-wake-cold-start, lan-resident, lan-suspended.

The Worker bundle must already be staged at examples/probe-app/Bundle/worker
using the repository's standard copy-bundle-assets.sh flow. The script never
invents an APNs push or a BLE board wake on a physical device: it prints the
exact action and waits. Simulator mode injects content-available pushes with
`xcrun simctl push` only to exercise the harness.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --device|--simulator|--development-team|--bundle-id|--run-id|--output-dir|--scenarios|--iterations|--lan-host|--poll-seconds|--timeout-seconds)
      [ "$#" -ge 2 ] || { echo "run-engine-wake: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --device) DEVICE="$2" ;;
        --simulator) SIMULATOR="$2" ;;
        --development-team) TEAM="$2" ;;
        --bundle-id) BUNDLE_ID="$2" ;;
        --run-id) RUN_ID="$2" ;;
        --output-dir) OUT="$2" ;;
        --scenarios) SCENARIOS="$2" ;;
        --iterations) ITERATIONS="$2" ;;
        --lan-host) LAN_HOST="$2" ;;
        --poll-seconds) POLL_SECONDS="$2" ;;
        --timeout-seconds) TIMEOUT_SECONDS="$2" ;;
      esac
      shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "run-engine-wake: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$DEVICE" ] && [ -n "$SIMULATOR" ] \
  && { echo "run-engine-wake: pass exactly one of --device or --simulator" >&2; exit 2; }
[ -n "$DEVICE" ] || [ -n "$SIMULATOR" ] \
  || { echo "run-engine-wake: pass --device or --simulator" >&2; exit 2; }
case "$ITERATIONS" in (*[!0-9]*|'') echo "run-engine-wake: iterations must be a positive integer" >&2; exit 2 ;; esac
case "$TIMEOUT_SECONDS" in (*[!0-9]*|'') echo "run-engine-wake: timeout must be a positive integer" >&2; exit 2 ;; esac
[[ "$RUN_ID" =~ ^[a-zA-Z0-9-]{1,80}$ ]] || { echo "run-engine-wake: invalid run id" >&2; exit 2; }
[[ "$BUNDLE_ID" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "run-engine-wake: invalid bundle id" >&2; exit 2; }
[ "$ITERATIONS" -gt 0 ] && [ "$ITERATIONS" -le 50 ] || { echo "run-engine-wake: iterations outside 1...50" >&2; exit 2; }
python3 - "$POLL_SECONDS" <<'PY' || exit 2
import sys
if float(sys.argv[1]) < 0.25:
    raise SystemExit(2)
PY

if [ -z "$OUT" ]; then
  OUT="${TMPDIR:-/tmp}/phonedsh-engine-wake/$RUN_ID"
fi
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
  echo "run-engine-wake: output directory is not empty: $OUT" >&2
  exit 2
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
APP_PID=""
PLATFORM="device"
[ -n "$SIMULATOR" ] && PLATFORM="simulator"

not_run() {
  local reason="$1"
  python3 "$HERE/analyze.py" --engine-wake --output-dir "$OUT" \
    --write-not-run --reason "$reason" >/dev/null 2>&1 || true
  echo "== ENGINE WAKE: NOT_RUN =="
  echo "$reason"
  echo "evidence: $OUT/summary.json"
  exit 3
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "$APP_PID" ] && [ "$PLATFORM" = "device" ]; then
    xcrun devicectl device process terminate --device "$DEVICE" --pid "$APP_PID" \
      >/dev/null 2>&1 || true
  fi
  if [ "$PLATFORM" = "simulator" ]; then
    xcrun simctl terminate "$SIMULATOR" "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command in xcodebuild xcrun xcodegen python3; do
  command -v "$command" >/dev/null 2>&1 || not_run "$command is unavailable"
done

WORKER="$ROOT/examples/probe-app/Bundle/worker"
missing=0
for file in index.html boot.js worker-entry.js image.tar.gz; do
  [ -s "$WORKER/$file" ] || missing=1
done
[ -d "$WORKER/lazy" ] || missing=1
[ "$missing" -eq 0 ] || not_run "Worker assets are not staged at examples/probe-app/Bundle/worker; run the standard copy-bundle-assets.sh flow first"

if [ "$PLATFORM" = "device" ]; then
  xcrun devicectl list devices --json-output "$OUT/devices.raw.json" \
    --log-output "$OUT/devices.log" >/dev/null 2>&1 \
    || not_run "devicectl could not enumerate physical devices; see $OUT/devices.log"
  selection="$(python3 - "$OUT/devices.raw.json" "$OUT/device-discovery.json" "$DEVICE" <<'PY'
import json
import sys

source, destination, requested = sys.argv[1:]
document = json.load(open(source, encoding="utf-8"))
devices = document.get("result", {}).get("devices", [])
sanitized = []
available = []
for device in devices:
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    row = {
        "identifier": device.get("identifier"),
        "udid": hardware.get("udid"),
        "deviceType": hardware.get("deviceType"),
        "marketingName": hardware.get("marketingName"),
        "productType": hardware.get("productType"),
        "osVersionNumber": properties.get("osVersionNumber"),
        "osBuildUpdate": properties.get("osBuildUpdate"),
        "reality": hardware.get("reality"),
        "pairingState": connection.get("pairingState"),
        "tunnelState": connection.get("tunnelState"),
    }
    sanitized.append(row)
    if (row["reality"] == "physical" and row["pairingState"] == "paired"
            and row["tunnelState"] in {"available", "connected"}):
        available.append(row)
json.dump({"devices": sanitized}, open(destination, "w", encoding="utf-8"), indent=2, sort_keys=True)
if requested:
    matches = [row for row in available if requested in {row["identifier"], row["udid"]}]
else:
    matches = available
matches.sort(key=lambda row: (0 if row["deviceType"] == "iPhone" else 1, row["productType"] or ""))
if len(matches) == 1:
    row = matches[0]
    device = dict(row)
    device["deviceClass"] = "physical"
    json.dump(device, open(destination.replace("device-discovery.json", "device.json"), "w", encoding="utf-8"), indent=2, sort_keys=True)
    print(f"{row['identifier']}|{row.get('udid') or row['identifier']}")
elif len(matches) > 1:
    print("MULTIPLE", file=sys.stderr)
    raise SystemExit(4)
else:
    print("NONE", file=sys.stderr)
    raise SystemExit(3)
PY
  )"
  selection_rc=$?
  if [ "$selection_rc" -eq 4 ]; then
    not_run "multiple available physical devices match; pass --device explicitly"
  fi
  if [ "$selection_rc" -ne 0 ] || [ -z "$selection" ]; then
    not_run "no available paired physical iOS device (paired but unavailable devices do not count)"
  fi
  DEVICE="${selection%%|*}"
  XCODE_DEVICE="${selection#*|}"
  DESTINATION="platform=iOS,id=$XCODE_DEVICE"
  PRODUCT_DIR="Debug-iphoneos"
  DRIVER_PLATFORM=(--platform device --device "$DEVICE")
  if [ -z "$LAN_HOST" ] && [[ "$SCENARIOS" == *lan-* ]]; then
    echo "run-engine-wake: warning: --lan-host is not set; the LAN scenarios will be NOT_RUN" >&2
  fi
else
  SIMULATOR_UDID="$(xcrun simctl list devices --json | python3 -c '
import json, sys
wanted = sys.argv[1]
document = json.load(sys.stdin)
for runtime, devices in document.get("devices", {}).items():
    for device in devices:
        if device.get("name") == wanted or device.get("udid") == wanted:
            if device.get("isAvailable", True):
                print(device.get("udid"))
                raise SystemExit(0)
raise SystemExit(1)
' "$SIMULATOR")" || not_run "no available simulator named $SIMULATOR"
  [ -n "$SIMULATOR_UDID" ] || not_run "no available simulator named $SIMULATOR"
  DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"
  PRODUCT_DIR="Debug-iphonesimulator"
  DRIVER_PLATFORM=(--platform simulator --simulator-udid "$SIMULATOR_UDID")
  if [ -z "$LAN_HOST" ] && [[ "$SCENARIOS" == *lan-* ]]; then
    LAN_HOST="127.0.0.1"
  fi
  python3 - "$OUT/device.json" "$SIMULATOR_UDID" "$SIMULATOR" <<'PY'
import json, sys
destination, udid, name = sys.argv[1:]
json.dump({"udid": udid, "marketingName": name, "deviceClass": "simulator",
           "reality": "simulator"}, open(destination, "w", encoding="utf-8"),
          indent=2, sort_keys=True)
PY
fi

if [ "$SKIP_BUILD" -eq 0 ]; then
  GENERATED="$SPEC_DIR/Generated"
  mkdir -p "$GENERATED/Bundle/worker"
  rm -rf "$GENERATED/Bundle/worker"
  cp -R "$WORKER" "$GENERATED/Bundle/worker" \
    || not_run "could not stage the Worker folder reference in the spike project"
  xcodegen generate --spec "$SPEC_DIR/project.yml" > "$OUT/xcodegen.log" 2>&1 \
    || not_run "xcodegen failed; see $OUT/xcodegen.log"
  build=(xcodebuild -project "$SPEC_DIR/BotResidencySpike.xcodeproj"
    -scheme BotResidencySpike -configuration Debug
    -destination "$DESTINATION"
    -derivedDataPath "$OUT/DerivedData"
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
    CODE_SIGN_STYLE=Automatic
    build)
  if [ -n "$TEAM" ]; then
    build+=(DEVELOPMENT_TEAM="$TEAM")
  fi
  "${build[@]}" > "$OUT/xcodebuild.log" 2>&1 \
    || not_run "build/signing failed; pass --development-team or inspect $OUT/xcodebuild.log"
fi

APP="$OUT/DerivedData/Build/Products/$PRODUCT_DIR/BotResidencySpike.app"
[ -d "$APP" ] || not_run "the spike app was not produced (looked for $APP)"
LAUNCH_ARGS=(--mode engine-wake --run-id "$RUN_ID" --scenarios "$SCENARIOS"
  --iterations "$ITERATIONS" --lan-port 0)

launch_pid() {
  python3 - "$OUT/launch.json" <<'PY'
import json
import sys

document = json.load(open(sys.argv[1], encoding="utf-8"))
answer = []

def walk(value, key=""):
    if isinstance(value, dict):
        for name, child in value.items():
            walk(child, name)
    elif isinstance(value, list):
        for child in value:
            walk(child, key)
    else:
        normalized = key.replace("_", "").lower()
        if normalized in {"pid", "processid", "processidentifier"}:
            answer.append(value)

walk(document)
print(next((str(value) for value in answer if str(value).isdigit() and int(value) > 0), ""))
PY
}

pull_armed_state() {
  rm -rf "$OUT/armed"
  mkdir -p "$OUT/armed"
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "Documents/BotResidencySpike/$RUN_ID/engine-wake-state.json" \
    --destination "$OUT/armed" \
    --json-output "$OUT/armed-copy.json" --log-output "$OUT/armed-copy.log" \
    >/dev/null 2>&1
}

if [ "$PLATFORM" = "device" ]; then
  xcrun devicectl device install app --device "$DEVICE" "$APP" \
    --json-output "$OUT/install.json" --log-output "$OUT/install.log" >/dev/null 2>&1 \
    || not_run "devicectl could not install the spike app; see $OUT/install.log"
  ARM_FIRST=0
  case ",$SCENARIOS," in
    *,push-cold-start,*|*,bgprocessing-cold-start,*) ARM_FIRST=1 ;;
  esac
  if [ "$ARM_FIRST" -eq 1 ]; then
    # Register for push and persist the configuration, then kill the process so
    # the push / BGTask can produce a genuinely cold launch. A force-quit by the
    # user disables background relaunch; this is a process termination, and the
    # evidence still records whether the process was already running.
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
      --json-output "$OUT/launch.json" --log-output "$OUT/launch.log" \
      "$BUNDLE_ID" "${LAUNCH_ARGS[@]}" --arm-only >/dev/null 2>&1 \
      || not_run "devicectl could not launch the spike app; see $OUT/launch.log"
    APP_PID="$(launch_pid)"
    armed=0
    for _ in $(seq 1 30); do
      sleep 1
      pull_armed_state
      if python3 - "$OUT/armed" <<'PY'
import json, sys
from pathlib import Path
matches = list(Path(sys.argv[1]).rglob("engine-wake-state.json"))
if not matches:
    raise SystemExit(1)
try:
    state = json.loads(matches[0].read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if state.get("phase") == "armed" else 1)
PY
      then
        armed=1
        break
      fi
    done
    if [ "$armed" -eq 1 ]; then
      python3 - "$OUT/armed" <<'PY'
import json, sys
from pathlib import Path
matches = list(Path(sys.argv[1]).rglob("engine-wake-state.json"))
state = json.loads(matches[0].read_text(encoding="utf-8"))
print(f"run-engine-wake: armed; device token={state.get('deviceToken') or 'pending'}")
PY
    else
      echo "run-engine-wake: warning: did not observe the armed state; continuing" >&2
    fi
    xcrun devicectl device process terminate --device "$DEVICE" --pid "$APP_PID" \
      >/dev/null 2>&1 || true
    APP_PID=""
    echo "run-engine-wake: process terminated; send the content-available push now"
    echo "run-engine-wake: follow the ACTION REQUIRED lines printed below"
  else
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
      --json-output "$OUT/launch.json" --log-output "$OUT/launch.log" \
      "$BUNDLE_ID" "${LAUNCH_ARGS[@]}" >/dev/null 2>&1 \
      || not_run "devicectl could not launch the spike app; see $OUT/launch.log"
    APP_PID="$(launch_pid)"
    echo "run-engine-wake: app launched on $DEVICE; follow the printed actions"
  fi
else
  xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
  xcrun simctl install "$SIMULATOR_UDID" "$APP" \
    || not_run "simctl could not install the spike app"
  xcrun simctl launch --terminate-running-process "$SIMULATOR_UDID" "$BUNDLE_ID" \
    "${LAUNCH_ARGS[@]}" > "$OUT/launch.log" 2>&1 \
    || not_run "simctl could not launch the spike app; see $OUT/launch.log"
  echo "run-engine-wake: simulator run; every verdict will be NOT_RUN (not device evidence)"
fi

driver_args=(--mode engine-wake "${DRIVER_PLATFORM[@]}" --bundle-id "$BUNDLE_ID"
  --run-id "$RUN_ID" --output-dir "$OUT" --timeout-seconds "$TIMEOUT_SECONDS"
  --poll-seconds "$POLL_SECONDS")
if [ -n "$LAN_HOST" ]; then
  driver_args+=(--lan-host "$LAN_HOST")
fi
python3 "$HERE/device_driver.py" "${driver_args[@]}"
driver_rc=$?

set +e
if [ "$driver_rc" -ne 0 ]; then
  python3 "$HERE/analyze.py" --engine-wake --output-dir "$OUT" \
    --thresholds "$ROOT/spec/host/v1/golden/engine-launch.json" \
    --acquisition-error "device driver exited $driver_rc; inspect host-report.json"
else
  python3 "$HERE/analyze.py" --engine-wake --output-dir "$OUT" \
    --thresholds "$ROOT/spec/host/v1/golden/engine-launch.json"
fi
analyze_rc=$?
set -e

python3 - "$OUT/summary.json" <<'PY'
import json
import sys
summary = json.load(open(sys.argv[1], encoding="utf-8"))
print(f"== ENGINE WAKE: {summary['status']} ({summary['conclusion']}) ==")
for scenario in summary.get("scenarios", []):
    p50 = scenario.get("p50Ms")
    p95 = scenario.get("p95Ms")
    latency = "" if p50 is None else f" p50={p50}ms p95={p95}ms n={scenario['samples']}"
    print(f"{scenario['status']:7} {scenario['id']}: {scenario['reason']}{latency}")
suggestions = summary.get("suggestions") or {}
if suggestions:
    print("suggested minLeaseForColdBootMs: "
          f"{suggestions.get('minLeaseForColdBootMs')}")
    print("suggested minLeaseForResumeMs: "
          f"{suggestions.get('minLeaseForResumeMs')}")
    print(f"formula: {suggestions.get('formula')}")
print(f"evidence: {sys.argv[1]}")
PY
exit "$analyze_rc"
