#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Interactive fixture for an iPhone radio test, never a production peripheral.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
bridge="$root/.build/link-host/task-bridge"
if [[ ! -x "$bridge" ]]; then
  bash "$root/firmware/tests/run.sh"
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/pdsh-radio.XXXXXXXX")"
app="$work/PDSHRadio.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>PDSHRadio</string><key>CFBundleIdentifier</key><string>dev.phonedsh.radio-test</string><key>CFBundleName</key><string>PDSH Radio Test</string><key>CFBundlePackageType</key><string>APPL</string><key>NSBluetoothAlwaysUsageDescription</key><string>Test the phoneDSH Bluetooth connection.</string><key>NSBluetoothPeripheralUsageDescription</key><string>Test the phoneDSH Bluetooth connection.</string><key>LSUIElement</key><true/></dict></plist>
PLIST
clang -c "$root/firmware/components/pdsh_link_wire/pdsh_link_wire.c" -I"$root/firmware/components/pdsh_link_wire/include" -o "$work/pdsh_link_wire.o"
swiftc "$root/firmware/tests/macos_radio_peer.swift" -import-objc-header "$root/firmware/components/pdsh_link_wire/include/pdsh_link_wire.h" "$work/pdsh_link_wire.o" -o "$app/Contents/MacOS/PDSHRadio"
codesign --force --sign - "$app"
printf 'Test-only peer: %s\n' "$app"
exec env PDSH_TEST_BRIDGE="$bridge" "$app/Contents/MacOS/PDSHRadio"
