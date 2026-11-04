#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Demo acceptance #5: kill the WebView renderer process and prove the engine
# rebuilds and recovers on the same loopback origin.
#
# What it proves (emulator only -- a real device may differ):
#   renderer gone -> WebView destroyed (live=0) -> Recovering
#                 -> new WebView (live=1) -> reload -> Recovering -> Running
#                 -> new channel -> new HELLO
# What it does NOT prove: anything about a physical device, and nothing about
# process death of the app itself (that is the kill matrix, a different gate).
#
# Requires a rooted adbd (`adb root`) to kill an isolated renderer process.
#
# Usage: bash android/tools/inject-renderer-death.sh [--wait-s N]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$(sed -n 's/^sdk\.dir=//p' "$ROOT/android/local.properties" 2>/dev/null | head -1)}"
[ -n "$ANDROID_HOME" ] || { echo "ERROR: set ANDROID_HOME or android/local.properties sdk.dir" >&2; exit 2; }
export PATH="$ANDROID_HOME/platform-tools:$PATH"

PACKAGE="${PDSH_PACKAGE:-com.phonedsh.app}"
WAIT_S=8
while [ $# -gt 0 ]; do
  case "$1" in
    --wait-s) WAIT_S="${2:?}"; shift 2 ;;
    -h|--help) sed -n '3,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
artifacts="$ROOT/android/build/demo-artifacts"
mkdir -p "$artifacts"

# Pin every adb call to one device: two emulators are commonly attached here, and a
# bare `adb` then fails with "more than one device/emulator".
if [ -z "${SERIAL:-}" ]; then
  SERIAL="$(adb devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')"
fi
[ -n "${SERIAL:-}" ] || die "no attached emulator"
export ANDROID_SERIAL="$SERIAL"
adb() { command adb -s "$SERIAL" "$@"; }
echo "device: $SERIAL"

echo "== root adbd (needed to kill an isolated renderer)"
adb root >/dev/null 2>&1 || true
adb wait-for-device

app_pid="$(adb shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' || true)"
[ -n "$app_pid" ] || die "$PACKAGE is not running; run android/tools/run-demo.sh first"
echo "app pid: $app_pid"

# The renderer is the newest `sandboxed_process0`; older ones belong to earlier
# launches and killing them proves nothing.
renderer_pid="$(adb shell ps -A -o PID,NAME 2>/dev/null \
  | grep sandboxed_process0 | awk '{print $1}' | sort -n | tail -1 | tr -d '\r')"
[ -n "$renderer_pid" ] || die "no WebView renderer process found; is the page loaded?"
echo "renderer pid: $renderer_pid"

adb logcat -c
echo "== kill -9 $renderer_pid"
adb shell kill -9 "$renderer_pid" >/dev/null 2>&1 || die "kill failed"
sleep "$WAIT_S"

log="$artifacts/renderer-death.logcat.txt"
adb logcat -d > "$log"
adb exec-out screencap -p > "$artifacts/screenshot-after-renderer-death.png" 2>/dev/null || true

echo "== transitions"
grep -E "renderer gone|webview destroyed|-> Recovering|Recovering -> Running|recovered:|channel channel-[0-9]+: open" "$log" | tail -12 || true

fail=0
check() {
  if grep -qE "$2" "$log"; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s\n' "$1"
    fail=1
  fi
}
check "renderer death observed"        "renderer gone:.*destroying and rebuilding"
check "old WebView destroyed (live=0)" "webview destroyed \(live=0"
check "entered Recovering"             "state: .* -> Recovering"
check "new WebView created (live=1)"   "webview created on the UI thread \(live=1"
check "returned to Running"            "Recovering -> Running"
# The channel number keeps growing across recoveries (channel-2, channel-3, ...),
# so match the shape, not a literal: logcat was cleared right before the kill, so
# any channel opening in this log is the post-recovery one.
check "channel reopened"               "channel channel-[0-9]+: open \(live=1"
check "HELLO after recovery"           "handshake: proto=1"

echo "artifacts: $log"
[ "$fail" = "0" ] || die "renderer-death acceptance failed"
echo "== renderer-death acceptance PASSED (emulator evidence only)"
