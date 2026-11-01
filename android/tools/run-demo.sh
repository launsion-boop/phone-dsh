#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# One command from a clean checkout to a demo screenshot:
#   build -> install -> launch -> collect logcat and a screenshot.
#
# What it does NOT do: prove anything about a physical device. Emulator evidence
# is emulator evidence; the receipt this script writes says so.
#
# Usage:
#   bash android/tools/run-demo.sh              # build, install, launch, capture
#   bash android/tools/run-demo.sh --no-build   # reuse the existing APK
#   bash android/tools/run-demo.sh --cold       # wipe app data before launching
#
# Environment:
#   ANDROID_HOME  (default /opt/homebrew/share/android-commandlinetools on this host)
#   JAVA_HOME     (default /opt/homebrew/opt/openjdk@21 on this host)
#   PDSH_AVD      (default pdsh35)
#   PDSH_WAIT_S   (default 25) seconds to let the app settle before capturing

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# No machine-local path is hard-coded here: the SDK comes from the environment or
# from android/local.properties (the gitignored machine-local file), and the JDK is
# derived from whichever `java` is on PATH. That keeps this script portable.
ANDROID_HOME="${ANDROID_HOME:-$(sed -n 's/^sdk\.dir=//p' "$ROOT/android/local.properties" 2>/dev/null | head -1)}"
if [ -z "${JAVA_HOME:-}" ] && command -v java >/dev/null 2>&1; then
  JAVA_HOME="$(cd "$(dirname "$(command -v java)")/.." && pwd)"
fi
PDSH_AVD="${PDSH_AVD:-pdsh35}"
PDSH_WAIT_S="${PDSH_WAIT_S:-25}"
PACKAGE="com.phonedsh.probe"
ARTIFACTS="$ROOT/android/build/demo-artifacts"

BUILD=1
COLD=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --cold)     COLD=1 ;;
    -h|--help)  sed -n '3,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

export ANDROID_HOME JAVA_HOME
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

say() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "${ANDROID_HOME:-}" ] || die "no ANDROID_HOME and android/local.properties has no sdk.dir"
command -v adb >/dev/null 2>&1 || die "adb not found under $ANDROID_HOME"
[ -x "$ANDROID_HOME/emulator/emulator" ] || die "emulator not found under $ANDROID_HOME"

# ---------------------------------------------------------------- emulator
say "emulator"
# Pin every later adb call to one device. With two emulators attached, a bare `adb`
# fails with "more than one device/emulator", and before that it silently targeted
# whichever one happened to be first. ANDROID_SERIAL from the caller wins; otherwise
# take the first attached emulator.
if [ -z "${SERIAL:-}" ]; then
  SERIAL="${ANDROID_SERIAL:-}"
fi
if [ -z "${SERIAL:-}" ]; then
  SERIAL="$(adb devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')"
fi
[ -n "${SERIAL:-}" ] && export ANDROID_SERIAL="$SERIAL"
adb() { command adb ${SERIAL:+-s "$SERIAL"} "$@"; }

if adb devices | grep -q "emulator-.*device$"; then
  echo "using device: ${SERIAL:-none}"
else
  "$ANDROID_HOME/emulator/emulator" -avd "$PDSH_AVD" \
      -no-window -no-audio -no-boot-anim -no-snapshot \
      -gpu swiftshader_indirect >"$ROOT/android/build/emulator.log" 2>&1 &
  echo "booting $PDSH_AVD (log: android/build/emulator.log)"
  adb wait-for-device
  for _ in $(seq 1 60); do
    [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 2
  done
  [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] \
    || die "emulator did not finish booting"
fi
echo "device: $(adb shell getprop ro.product.cpu.abi | tr -d '\r'), SDK $(adb shell getprop ro.build.version.sdk | tr -d '\r')"

# ---------------------------------------------------------------- build
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
if [ "$BUILD" = "1" ]; then
  say "build :app"
  ( cd "$ROOT/android" && ./gradlew :app:assembleDebug --no-daemon --console=plain )
fi
[ -f "$APK" ] || die "no APK at $APK (run without --no-build)"

# ---------------------------------------------------------------- install
say "install"
adb install -r -t "$APK"
if [ "$COLD" = "1" ]; then
  adb shell pm clear "$PACKAGE" >/dev/null
  echo "app data cleared"
fi

# ---------------------------------------------------------------- launch
say "launch"
adb logcat -c
# `monkey` aborts on a headless AVD (SYS_KEYS has no physical keys: exit 251 for
# every package, Settings included), so launch through the resolver instead.
LAUNCH_COMPONENT="$(adb shell cmd package resolve-activity --brief "$PACKAGE" 2>/dev/null \
  | tr -d '\r' | tail -1)"
[ -n "$LAUNCH_COMPONENT" ] || die "could not resolve the launcher activity of $PACKAGE"
adb shell am start -W -n "$LAUNCH_COMPONENT" >/dev/null \
  || die "could not launch $LAUNCH_COMPONENT"
echo "waiting ${PDSH_WAIT_S}s for the engine to settle"
sleep "$PDSH_WAIT_S"

# ---------------------------------------------------------------- capture
say "capture"
mkdir -p "$ARTIFACTS"
adb logcat -d > "$ARTIFACTS/logcat.txt"
adb exec-out screencap -p > "$ARTIFACTS/screenshot.png"
adb shell dumpsys activity activities > "$ARTIFACTS/activities.txt" 2>/dev/null || true

echo "artifacts:"
ls -1 "$ARTIFACTS"
say "engine log lines"
grep -E "PDSH|phonedsh|EngineState|HELLO|renderer" "$ARTIFACTS/logcat.txt" | tail -30 || echo "(no matching lines yet)"

say "done"
echo "screenshot: $ARTIFACTS/screenshot.png"
