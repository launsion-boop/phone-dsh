#!/bin/bash
# SPDX-License-Identifier: MIT
# A dedicated physical iPhone + already-provisioned ESP32 gate. Does not erase or flash.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${PDSH_BLE_FIXTURE_IP:?Set the Mac private IPv4 address approved by the firmware}"
: "${PDSH_BLE_SERIAL_PORT:?Set the ESP32 USB serial port}"
: "${PDSH_BLE_DEVICE_MAC:?Set the pinned ESP32 MAC address}"
: "${PDSH_BLE_IPHONE_UDID:?Set the connected iPhone UDID}"
ESP_PYTHON="${PDSH_ESP_PYTHON:-python3}"
OUT="${OUT:-$ROOT/.build/ble-hardware-$(date +%Y%m%d-%H%M%S)}"
DERIVED="${DERIVED_DATA:-$ROOT/.build/ble-hardware-derived}"
mkdir -p "$OUT"
"$ESP_PYTHON" - "$PDSH_BLE_SERIAL_PORT" "$PDSH_BLE_DEVICE_MAC" <<'PY'
import sys
from serial.tools import list_ports
ports=[p for p in list_ports.comports() if p.device==sys.argv[1]]
assert ports and (ports[0].serial_number or '').lower().replace(':','')==sys.argv[2].lower().replace(':',''), 'ESP32 serial identity mismatch'
PY
"$ESP_PYTHON" "$ROOT/scripts/testing/ble-hardware-fixture.py" \
  --bind "$PDSH_BLE_FIXTURE_IP" --serial-port "$PDSH_BLE_SERIAL_PORT" \
  --device-mac "$PDSH_BLE_DEVICE_MAC" --out "$OUT" > "$OUT/fixture.log" 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true' EXIT
PDSH_WITH_SHELL=1 xcodegen generate --spec "$ROOT/examples/probe-app/project.yml" > "$OUT/generate.log"
PDSH_WITH_SHELL=1 xcodebuild -project "$ROOT/examples/probe-app/PhoneDSHProbe.xcodeproj" \
  -scheme PhoneDSHBLEHardware -configuration Debug -destination "id=$PDSH_BLE_IPHONE_UDID" \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates -disableAutomaticPackageResolution \
  -skipPackageUpdates build-for-testing > "$OUT/build.log" 2>&1
RUN_FILE="$(python3 - "$DERIVED/Build/Products" <<'PY'
from pathlib import Path
import sys
files=list(Path(sys.argv[1]).glob('PhoneDSHBLEHardware_iphoneos*.xctestrun'))
assert files, 'Hardware xctestrun missing'
print(max(files,key=lambda p:p.stat().st_mtime))
PY
)"
python3 "$ROOT/scripts/testing/prepare-ble-hardware-run.py" \
  --xctestrun "$RUN_FILE" --authority "$PDSH_BLE_FIXTURE_IP:18767" \
  --token-file "$OUT/fixture-token" --output "$(dirname "$RUN_FILE")/PhoneDSHBLEHardware_live.xctestrun"
"$ESP_PYTHON" -m esptool --chip esp32s3 --port "$PDSH_BLE_SERIAL_PORT" \
  --after watchdog-reset read-mac > "$OUT/reset.log" 2>&1
STATUS=0
xcodebuild test-without-building -xctestrun "$(dirname "$RUN_FILE")/PhoneDSHBLEHardware_live.xctestrun" \
  -destination "id=$PDSH_BLE_IPHONE_UDID" -resultBundlePath "$OUT/Hardware.xcresult" > "$OUT/test.log" 2>&1 || STATUS=$?
xcrun xcresulttool export attachments --path "$OUT/Hardware.xcresult" --output-path "$OUT/attachments" > "$OUT/export.log" 2>&1 || true
printf 'Hardware gate exit=%s; artifacts: %s\n' "$STATUS" "$OUT"
exit "$STATUS"
