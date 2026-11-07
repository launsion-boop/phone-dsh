#!/bin/bash
# SPDX-License-Identifier: MIT
#
# WP1 physical-device WebContent residency spike.
# Exit: 0 PASS, 1 FAIL, 2 usage error, 3 NOT_RUN.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SPEC_DIR="$HERE/app"
DURATION=7200
EVENTS=10
KILLS=3
DEVICE=""
TEAM=""
BUNDLE_ID="dev.phone-dsh.bot-residency-spike"
SEED="$(date +%s)"
RUN_ID="run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUT=""
POLL_SECONDS=2

usage() {
  cat <<'EOF'
Usage:
  bash scripts/ci/bot-residency/run-device.sh \
    --duration-seconds 7200 --events 10 --kill-webcontent 3 [options]

Options:
  --device <devicectl identifier>  Select one available physical iOS device.
  --development-team <team-id>     Apple signing team (automatic signing).
  --bundle-id <bundle-id>          Default dev.phone-dsh.bot-residency-spike.
  --seed <uint64>                  Reproduce event/kill offsets (default current epoch).
  --run-id <run-id>                Evidence/workspace namespace (default unique).
  --output-dir <path>              Default $TMPDIR/phonedsh-bot-residency/<run-id>.
  --poll-seconds <seconds>         Device polling interval, minimum 0.25 (default 2).

The Worker bundle must already be staged at examples/probe-app/Bundle/worker
using the repository's standard copy-bundle-assets.sh flow. This script never
uses a simulator as device evidence and never replaces SIGKILL with a restart API.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --duration-seconds|--events|--kill-webcontent|--device|--development-team|--bundle-id|--seed|--run-id|--output-dir|--poll-seconds)
      [ "$#" -ge 2 ] || { echo "run-device: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --duration-seconds) DURATION="$2" ;;
        --events) EVENTS="$2" ;;
        --kill-webcontent) KILLS="$2" ;;
        --device) DEVICE="$2" ;;
        --development-team) TEAM="$2" ;;
        --bundle-id) BUNDLE_ID="$2" ;;
        --seed) SEED="$2" ;;
        --run-id) RUN_ID="$2" ;;
        --output-dir) OUT="$2" ;;
        --poll-seconds) POLL_SECONDS="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "run-device: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$DURATION" in (*[!0-9]*|'') echo "run-device: duration must be a positive integer" >&2; exit 2 ;; esac
case "$EVENTS" in (*[!0-9]*|'') echo "run-device: events must be a positive integer" >&2; exit 2 ;; esac
case "$KILLS" in (*[!0-9]*|'') echo "run-device: kill count must be a nonnegative integer" >&2; exit 2 ;; esac
case "$SEED" in (*[!0-9]*|'') echo "run-device: seed must be a nonnegative integer" >&2; exit 2 ;; esac
[[ "$RUN_ID" =~ ^[a-zA-Z0-9-]{1,80}$ ]] || { echo "run-device: invalid run id" >&2; exit 2; }
[[ "$BUNDLE_ID" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "run-device: invalid bundle id" >&2; exit 2; }
[ "$DURATION" -gt 0 ] && [ "$EVENTS" -gt 0 ] && [ "$EVENTS" -le 1000 ] && [ "$KILLS" -le 100 ] \
  || { echo "run-device: value outside probe bounds" >&2; exit 2; }
python3 - "$POLL_SECONDS" <<'PY' || exit 2
import sys
value = float(sys.argv[1])
if value < 0.25:
    raise SystemExit(2)
PY

if [ -z "$OUT" ]; then
  OUT="${TMPDIR:-/tmp}/phonedsh-bot-residency/$RUN_ID"
fi
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
  echo "run-device: output directory is not empty: $OUT" >&2
  exit 2
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
APP_PID=""

not_run() {
  local reason="$1"
  python3 "$HERE/analyze.py" --output-dir "$OUT" --write-not-run --reason "$reason" >/dev/null 2>&1 || true
  echo "== BOT RESIDENCY: NOT_RUN =="
  echo "$reason"
  echo "evidence: $OUT/summary.json"
  exit 3
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "$APP_PID" ]; then
    xcrun devicectl device process terminate --device "$DEVICE" --pid "$APP_PID" \
      >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command in xcodebuild xcrun xcodegen python3; do
  command -v "$command" >/dev/null 2>&1 || not_run "$command is unavailable"
done

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
    json.dump(row, open(destination.replace("device-discovery.json", "device.json"), "w", encoding="utf-8"), indent=2, sort_keys=True)
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

WORKER="$ROOT/examples/probe-app/Bundle/worker"
missing=0
for file in index.html boot.js worker-entry.js image.tar.gz; do
  [ -s "$WORKER/$file" ] || missing=1
done
[ -d "$WORKER/lazy" ] || missing=1
if [ "$missing" -ne 0 ]; then
  not_run "Worker assets are not staged at examples/probe-app/Bundle/worker; run the standard copy-bundle-assets.sh flow first"
fi

GENERATED="$SPEC_DIR/Generated"
mkdir -p "$GENERATED/Bundle/worker"
rm -rf "$GENERATED/Bundle/worker"
cp -R "$WORKER" "$GENERATED/Bundle/worker" \
  || not_run "could not stage the Worker folder reference in the spike project"

xcodegen generate --spec "$SPEC_DIR/project.yml" > "$OUT/xcodegen.log" 2>&1 \
  || not_run "xcodegen failed; see $OUT/xcodegen.log"

build=(xcodebuild -project "$SPEC_DIR/BotResidencySpike.xcodeproj"
  -scheme BotResidencySpike -configuration Debug
  -destination "platform=iOS,id=$XCODE_DEVICE"
  -derivedDataPath "$OUT/DerivedData"
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
  CODE_SIGN_STYLE=Automatic
  build)
if [ -n "$TEAM" ]; then
  build+=(DEVELOPMENT_TEAM="$TEAM")
fi
"${build[@]}" > "$OUT/xcodebuild.log" 2>&1 \
  || not_run "device build/signing failed; pass --development-team or inspect $OUT/xcodebuild.log"

APP="$OUT/DerivedData/Build/Products/Debug-iphoneos/BotResidencySpike.app"
[ -d "$APP" ] || not_run "the signed spike app was not produced"

xcrun devicectl device install app --device "$DEVICE" "$APP" \
  --json-output "$OUT/install.json" --log-output "$OUT/install.log" >/dev/null 2>&1 \
  || not_run "devicectl could not install the spike app; see $OUT/install.log"

xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
  --json-output "$OUT/launch.json" --log-output "$OUT/launch.log" \
  "$BUNDLE_ID" \
  --run-id "$RUN_ID" --duration-seconds "$DURATION" \
  --events "$EVENTS" --kill-webcontent "$KILLS" --seed "$SEED" \
  >/dev/null 2>&1 || not_run "devicectl could not launch the spike app; see $OUT/launch.log"

APP_PID="$(python3 - "$OUT/launch.json" <<'PY'
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
)"

echo "run-device: app launched; lock when the app says Ready"
echo "run-device: evidence $OUT"
timeout_seconds=$((DURATION + 1800))
python3 "$HERE/device_driver.py" --device "$DEVICE" --bundle-id "$BUNDLE_ID" \
  --run-id "$RUN_ID" --output-dir "$OUT" --duration-seconds "$DURATION" \
  --kill-webcontent "$KILLS" --timeout-seconds "$timeout_seconds" \
  --poll-seconds "$POLL_SECONDS"
driver_rc=$?

set +e
if [ "$driver_rc" -ne 0 ]; then
  python3 "$HERE/analyze.py" --output-dir "$OUT" \
    --acquisition-error "device driver exited $driver_rc; inspect host-report.json"
else
  python3 "$HERE/analyze.py" --output-dir "$OUT"
fi
analyze_rc=$?
set -e

for request in "$OUT"/ccr-*.txt; do
  [ -f "$request" ] || continue
  echo ""
  cat "$request"
done
python3 - "$OUT/summary.json" <<'PY'
import json
import sys
summary = json.load(open(sys.argv[1], encoding="utf-8"))
print(f"== BOT RESIDENCY: {summary['status']} ({summary['conclusion']}) ==")
for check in summary.get("checks", []):
    print(f"{'PASS' if check['passed'] else 'FAIL'} {check['name']}: {check['detail']}")
print(f"evidence: {sys.argv[1]}")
PY
exit "$analyze_rc"
