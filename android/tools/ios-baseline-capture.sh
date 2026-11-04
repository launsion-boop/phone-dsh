#!/bin/bash
# SPDX-License-Identifier: MIT
#
# iOS baseline screenshot capture for the P1 visual lane.
#
# Runs the REAL SwiftUI probe app on a pinned simulator and writes one PNG per
# page/state into docs/receipts/ios-baseline-screens/. The route is the app's
# own DEBUG router (`-uiPreview <name>`, NativeShell.swift), so no taps and no
# XCUITest are involved:
#
#   xcrun simctl install   <udid> <app>
#   SIMCTL_CHILD_PDSH_DEBUG_FORCE_NATIVE=1 \
#     xcrun simctl launch  <udid> dev.phone-dsh.probe -uiPreview settings
#   xcrun simctl io        <udid> screenshot ios-settings.png
#
# Every shot starts from a FRESH install. `-uiPreview` writes drafts to
# UserDefaults and the chat host keeps a Documents/chat-host workspace; without
# the uninstall a 5000-character draft leaks from chat.draft into later shots
# (observed: chat.official showed chat.draft's text). The uninstall removes
# both, so each launch is deterministic.
#
# Fixed conditions (asserted below; also written to conditions.txt):
#   iPhone 16 Pro · iOS 26.5 (23F77) · 402x874 pt @3x (1206x2622 px)
#   light appearance · content size large · locale zh_CN (zh-Hans-CN)
#   status bar 09:41, wifi 3 bars, cellular 4 bars, battery 100% charged
#   Debug build · one app window · device preferredColorScheme(.light)
#
# Two build modes
# ---------------
#   (default)            build examples/probe-app as it is in the worktree.
#                        At HEAD (2026-10-31) this FAILS: ProbeKit/Office/
#                        OfficePresenter.swift:84 reads
#                        ChatHostConfiguration.defaultOfficeInteractionTimeout,
#                        which was deleted from ChatHostConfiguration.swift the
#                        same day. The script prints that error and exits 1; it
#                        does not patch anything.
#   --capture-copy       build a throwaway copy in $TMPDIR with ONLY that one
#                        constant added (60s; it bounds an Office picker/share
#                        deadline and no captured view reads it). The UI sources
#                        are byte-identical to HEAD; the copy is never written
#                        back into examples/**. The screenshots in
#                        docs/receipts/ios-baseline-screens/ were produced with
#                        this mode and INDEX.md says so at the top.
#
# Usage:
#   bash android/tools/ios-baseline-capture.sh                 # strict HEAD
#   bash android/tools/ios-baseline-capture.sh --capture-copy  # documented shim
#   PDSH_CAPTURE_OUT=/tmp/shots bash android/tools/ios-baseline-capture.sh --capture-copy
#   PDSH_CAPTURE_DEVICE_NAME="PDSH PR14 Latest iOS Baseline" bash android/tools/ios-baseline-capture.sh
#
# Writes only docs/receipts/ios-baseline-screens/** (or PDSH_CAPTURE_OUT) plus
# ephemeral files under ${TMPDIR:-/tmp}. Does not touch Android sources, the
# probe app, Sources/, spec/ or scripts/.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${PDSH_CAPTURE_OUT:-$ROOT/docs/receipts/ios-baseline-screens}"
BUILD_ROOT="${PDSH_CAPTURE_BUILD:-${TMPDIR:-/tmp}/pdsh-ios-baseline}"
PROJECT="$ROOT/examples/probe-app/PhoneDSHProbe.xcodeproj"
SCHEME="PhoneDSHProbe"
BUNDLE_ID="dev.phone-dsh.probe"
DEVICE_NAME="PDSH iOS Baseline iPhone 16 Pro"
DEVICE_NAME="${PDSH_CAPTURE_DEVICE_NAME:-$DEVICE_NAME}"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
RUNTIME="${PDSH_IOS_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}"
MODE="head"

for arg in "$@"; do
  case "$arg" in
    --capture-copy) MODE="copy" ;;
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT" "$BUILD_ROOT"

# --- 1. toolchain / runtime ---------------------------------------------------
/usr/bin/xcodebuild -version >/dev/null || die "xcodebuild not available"
if ! /usr/bin/xcrun simctl list runtimes | grep -q "$RUNTIME"; then
  RUNTIME=$(/usr/bin/xcrun simctl list runtimes | awk -F' - ' '/iOS/ {r=$2; gsub(/^ +| +$/, "", r)} END {print r}')
  [ -n "$RUNTIME" ] || die "no iOS simulator runtime installed"
  say "requested runtime missing; falling back to $RUNTIME"
fi

# --- 2. device ----------------------------------------------------------------
UDID=$(/usr/bin/xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
for runtime, devices in data["devices"].items():
    for device in devices:
        if device["name"] == name:
            print(device["udid"])
            raise SystemExit
' "$DEVICE_NAME")
if [ -z "${UDID:-}" ]; then
  UDID=$(/usr/bin/xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME")
  say "created device $DEVICE_NAME ($UDID)"
else
  say "reusing device $DEVICE_NAME ($UDID)"
fi

/usr/bin/xcrun simctl boot "$UDID" 2>/dev/null || true
/usr/bin/xcrun simctl bootstatus "$UDID" -b >/dev/null
/usr/bin/xcrun simctl ui "$UDID" appearance light >/dev/null
/usr/bin/xcrun simctl ui "$UDID" content_size large >/dev/null
/usr/bin/xcrun simctl status_bar "$UDID" override \
  --time "09:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged \
  --batteryLevel 100 --operatorName "" >/dev/null

# --- 3. build -----------------------------------------------------------------
if [ "$MODE" = "copy" ]; then
  MIRROR="$BUILD_ROOT/mirror"
  rm -rf "$MIRROR"
  mkdir -p "$MIRROR/examples"
  rsync -a --exclude '.build' --exclude 'scenario-evidence' \
    "$ROOT/examples/probe-app" "$MIRROR/examples/"
  ln -s "$ROOT/Package.swift" "$MIRROR/Package.swift"
  ln -s "$ROOT/Sources" "$MIRROR/Sources"
  ln -s "$ROOT/Tests" "$MIRROR/Tests"
  ln -s "$ROOT/shell" "$MIRROR/shell"
  python3 - "$MIRROR/examples/probe-app/ProbeKit/ChatHostConfiguration.swift" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
needle = "    public static let defaultBootTimeout: TimeInterval = 240\n"
shim = (
    "\n    /// Capture-only shim (P1 screenshots). HEAD removed this constant on\n"
    "    /// 2026-10-31 while OfficePresenter.swift:84 still reads it. 60s bounds an\n"
    "    /// Office picker/share deadline; no captured view reads this value.\n"
    "    public static let defaultOfficeInteractionTimeout: TimeInterval = 60\n"
)
if "defaultOfficeInteractionTimeout" not in text:
    if text.count(needle) != 1:
        raise SystemExit("could not locate ChatHostConfiguration.defaultBootTimeout")
    path.write_text(text.replace(needle, needle + shim))
PY
  PROJECT="$MIRROR/examples/probe-app/PhoneDSHProbe.xcodeproj"
  say "capture-copy: $MIRROR (+1 constant, UI sources byte-identical to HEAD)"
fi

DERIVED="$BUILD_ROOT/DerivedData"
say "building $SCHEME (Debug, iphonesimulator, no signing)…"
if ! /usr/bin/xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED" build CODE_SIGNING_ALLOWED=NO \
  > "$BUILD_ROOT/build.log" 2>&1; then
  say ""
  say "BUILD FAILED — the baseline does not compile in this worktree."
  grep -n "error:" "$BUILD_ROOT/build.log" | head -20 >&2 || true
  if grep -q "defaultOfficeInteractionTimeout" "$BUILD_ROOT/build.log"; then
    say ""
    say "Known HEAD break (2026-10-31):"
    say "  examples/probe-app/ProbeKit/Office/OfficePresenter.swift:84:"
    say "  type 'ChatHostConfiguration' has no member 'defaultOfficeInteractionTimeout'"
    say "Re-run with --capture-copy for the documented one-constant shim, or fix"
    say "ChatHostConfiguration.swift at the source."
  fi
  exit 1
fi
APP="$DERIVED/Build/Products/Debug-iphonesimulator/PhoneDSHProbe.app"
[ -d "$APP" ] || die "build succeeded but $APP is missing"

# --- 4. capture ---------------------------------------------------------------
shoot() {
  local name="$1" preview="$2" delay="${3:-3}"
  /usr/bin/xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  /usr/bin/xcrun simctl install "$UDID" "$APP" >/dev/null
  SIMCTL_CHILD_PDSH_DEBUG_FORCE_NATIVE=1 \
    /usr/bin/xcrun simctl launch "$UDID" "$BUNDLE_ID" -uiPreview "$preview" >/dev/null
  sleep "$delay"
  /usr/bin/xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1
  printf '  %-30s %-18s -> %s.png\n' "$name" "$preview" "$name"
}

say "capturing (fresh install per shot)…"
# name | -uiPreview value | settle seconds (heavy transcripts need 6)
while IFS='|' read -r name preview delay; do
  [ -n "$name" ] || continue
  shoot "$name" "$preview" "$delay"
done <<'LIST'
ios-chat-default|sample|6
ios-chat-assistant|chat.assistant|4
ios-chat-official|chat.official|6
ios-chat-failed|chat.failed|4
ios-chat-queued|chat.queued|4
ios-chat-long|chat.long|6
ios-chat-draft|chat.draft|4
ios-chat-permission|chat.permission|4
ios-sessions-default|sessions|3
ios-sessions-many|sessions.many|3
ios-sessions-empty|sessions.empty|3
ios-sessions-nothing|sessions.nothing|3
ios-sessions-ungrouped|sessions.ungrouped|3
ios-sessions-error|sessions.error|3
ios-settings|settings|3
ios-settings-model|settings.model|3
ios-settings-search|settings.search|3
ios-settings-network|settings.network|3
ios-settings-plugins|settings.plugins|3
ios-settings-about|settings.about|3
ios-settings-runtime|settings.runtime|3
ios-sessions-schedules|sessions.schedules|3
ios-workspace-folders|workspace|3
ios-files|workspace.files|3
ios-shell|configuration|3
ios-code-block|code.block|3
LIST

# --- 5. conditions receipt -----------------------------------------------------
CONDITIONS="$OUT/conditions.txt"
{
  echo "# iOS baseline capture conditions"
  echo "captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "device_name=$DEVICE_NAME"
  echo "device_udid=$UDID"
  echo "device_type=$DEVICE_TYPE"
  echo "runtime=$RUNTIME"
  echo "xcode=$(/usr/bin/xcodebuild -version | tr '\n' ' ')"
  echo "app_bundle_id=$BUNDLE_ID"
  echo "build_configuration=Debug"
  echo "build_mode=$MODE (copy adds defaultOfficeInteractionTimeout=60 because HEAD does not compile)"
  sips -g pixelWidth -g pixelHeight "$OUT/ios-chat-default.png" 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print "screen_px=" w "x" h}'
  echo "screen_pt=402x874"
  echo "scale=3"
  echo "appearance=$(/usr/bin/xcrun simctl ui "$UDID" appearance)"
  echo "content_size=$(/usr/bin/xcrun simctl ui "$UDID" content_size 2>/dev/null || echo unknown)"
  echo "locale=$(/usr/bin/xcrun simctl spawn "$UDID" defaults read NSGlobalDomain AppleLocale 2>/dev/null || echo unknown)"
  echo "status_bar_time=09:41 (simctl status_bar override)"
  /usr/bin/xcrun simctl status_bar "$UDID" list 2>/dev/null | sed 's/^/status_bar_/'
} > "$CONDITIONS"
say "wrote $CONDITIONS"

# --- 6. coverage / reachability note -------------------------------------------
cat <<'NOTE'

Captured pages (user-reachable at HEAD): chat, sessions, files, settings,
model-provider-settings, web-search-settings, egress-allow-list,
native-configuration, runtime-details, native-automation, workspace-folders,
pdsh-shell.

No route at HEAD (audited in docs/receipts/ios-baseline-screens/REACHABILITY.md):
  background, probes, task-screen, memory  -> only from DevelopmentToolsPage,
      which developerGroup/developerSection never mount in SettingsPage.body
  session-activity                         -> showActivity is declared and its
      .sheet is attached, but nothing ever sets it true
  daily-brief                              -> zero call sites for DailyBriefPage
The review xmark circle at the top-left of most previews is the DEBUG cover's
close button, not page UI. ios-chat-default (route "sample") is the root shell,
so it has no xmark.
NOTE
