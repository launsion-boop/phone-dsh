#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build and run the real probe app's XCUITest geometry exporter on a simulator,
# then copy the JSON exports into build/parity/ios.
#
# This is a convenience wrapper around the exact command in docs/parity/bench.md.
# It does not edit app sources: the test file is already in the UI-test target
# directory, and project.yml's `sources: PhoneDSHDeviceUITests` picks it up.
#
# Usage:
#   bash scripts/parity/run_ios_export.sh [--device UDID] [--out DIR]
#
# Blockers are reported, never skipped: no xcodebuild, no xcodegen, no simulator,
# or a failed build exits non-zero with the xcodebuild tail.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$ROOT/examples/probe-app"
OUT="$ROOT/build/parity/ios"
DEVICE_ID="${PDSH_PARITY_IOS_DEVICE:-}"
DERIVED="${PDSH_PARITY_IOS_DERIVED:-/tmp/pdsh-parity-derived}"
while [ $# -gt 0 ]; do
  case "$1" in
    --device) [ $# -ge 2 ] || { echo "--device needs a UDID" >&2; exit 2; }; DEVICE_ID="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || { echo "--out needs a directory" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for tool in xcodebuild xcodegen xcrun python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "NOT_RUN: missing required tool: $tool" >&2
    exit 2
  }
done

if [ -z "$DEVICE_ID" ]; then
  DEVICE_ID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
sys.exit(1)
')" || {
    echo "NOT_RUN: no available iPhone simulator" >&2
    exit 2
  }
fi

echo "parity ios: device $DEVICE_ID"
xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null

# project.yml names Bundle/worker as a folder resource. The real bundle is
# produced by copy-bundle-assets.sh and is gitignored; an empty directory keeps
# xcodegen and the build valid for a geometry-only run.
mkdir -p "$PROBE/Bundle/worker"

(
  cd "$PROBE"
  xcodegen generate
)

FIXTURES_JSON="$(python3 - "$ROOT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
fixtures = [json.loads(path.read_text(encoding="utf-8"))
            for path in sorted((root / "scripts/parity/fixtures").glob("*.json"))]
json.dump(fixtures, sys.stdout, ensure_ascii=False, separators=(",", ":"))
PY
)"

LOG="$(mktemp "${TMPDIR:-/tmp}/pdsh-parity-ios.XXXXXX.log")"
trap 'rm -f "$LOG"' EXIT

set +e
(
  cd "$PROBE"
  TEST_RUNNER_PDSH_PARITY_FIXTURES_JSON="$FIXTURES_JSON" \
  xcodebuild test \
    -project PhoneDSHProbe.xcodeproj \
    -scheme PhoneDSHDeviceUI \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED" \
    -only-testing:PhoneDSHDeviceUITests/ParityGeometryExportUITests/testExportAllParityFixtures \
    CODE_SIGNING_ALLOWED=NO \
    OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' 2>&1 | tee "$LOG"
)
STATUS=$?
set -e

if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: xcodebuild test exited $STATUS; tail:" >&2
  tail -80 "$LOG" >&2
  exit "$STATUS"
fi

RELATIVE_OUT="$(sed -n 's/^PDSH_PARITY_IOS_OUT=//p' "$LOG" | tail -1)"
if [ -z "$RELATIVE_OUT" ]; then
  echo "FAIL: the test did not print PDSH_PARITY_IOS_OUT" >&2
  tail -80 "$LOG" >&2
  exit 1
fi
mkdir -p "$OUT"
# PDSH_PARITY_IOS_OUT may be a simulator path under the host's
# Library/Developer/CoreSimulator tree; both are readable from the host.
cp "$RELATIVE_OUT"/*.json "$OUT"/
echo "parity ios: exports in $OUT"
ls -1 "$OUT"
