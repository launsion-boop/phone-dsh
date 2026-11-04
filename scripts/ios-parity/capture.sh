#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Capture the native session screens used by the PR 22 HomeSpec parity review.
# Run it on a 430pt-wide simulator to match the design canvas.
#
# This is NOT an official-DSH golden: the app is the iOS implementation. It
# gives a reproducible before/after set for the same preview and viewport.
#
# Usage:
#   scripts/ios-parity/capture.sh [udid] [preview]
#
# The app must already be built for the simulator. The script picks the newest
# Debug-iphonesimulator/PhoneDSHProbe.app from DerivedData.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UDID="${1:-4AAA363B-7B29-4415-9303-C692640BCF77}"
PREVIEW="${2:-sample}"
OUT="$ROOT/docs/receipts/ios-session-audit/screens/current"

APP="$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/PhoneDSHProbe-*/Build/Products/Debug-iphonesimulator/PhoneDSHProbe.app 2>/dev/null | head -1 || true)"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "PhoneDSHProbe.app not found; build the app for the simulator first." >&2
  exit 1
fi

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1 || true
xcrun simctl ui "$UDID" content_size large >/dev/null 2>&1 || true
xcrun simctl status_bar "$UDID" override \
  --time "09:41" --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4 >/dev/null 2>&1 || true

xcrun simctl terminate "$UDID" dev.phone-dsh.probe >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

SIMCTL_CHILD_PDSH_DEBUG_FORCE_NATIVE=1 \
  xcrun simctl launch "$UDID" dev.phone-dsh.probe -uiPreview "$PREVIEW" >/dev/null

sleep 6
mkdir -p "$OUT"
xcrun simctl io "$UDID" screenshot "$OUT/$PREVIEW-chat.png" >/dev/null
echo "wrote $OUT/$PREVIEW-chat.png"
