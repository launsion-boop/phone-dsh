#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/.build/BLEFixture.app"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/examples/ble-standard-device/Info.plist" "$APP/Contents/Info.plist"
swiftc "$ROOT/examples/ble-standard-device/main.swift" -o "$APP/Contents/MacOS/BLEFixture"
codesign --force --sign - "$APP"
echo "Built $APP; run Contents/MacOS/BLEFixture inside it to advertise."
