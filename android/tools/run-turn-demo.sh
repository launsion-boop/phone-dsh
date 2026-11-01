#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# One command from a clean checkout to ONE complete turn on a device:
#   prompt -> scripted model -> `phone info` tool call -> host exec -> tool
#   result -> final answer, with the turn's host events in logcat.
#
# What it runs: `:testkit:connectedDebugAndroidTest` filtered to
# `TurnOverChannelInstrumentedTest`. That test boots the real prebuilt worker in
# a real WebView, drives the real ordered channel (`API_REQ` -> `/api`), executes
# `phone info` through the real host exec lane, and lets the worker's model
# request reach a scripted upstream through the real `:net` gateway.
#
# The model is a SCRIPT: `testkit/.../upstream/ScriptedModelUpstream.kt` answers
# the first request with a tool call and the second (which carries the tool
# result) with a final text. This script cannot and does not claim a model ran.
#
# Evidence: emulator evidence is emulator evidence. The receipt this script
# prints says so.
#
# Usage:
#   bash android/tools/run-turn-demo.sh              # run the turn test
#   bash android/tools/run-turn-demo.sh --no-build   # reuse the built APKs
#
# Environment:
#   ANDROID_HOME  (default from android/local.properties on this host)
#   JAVA_HOME     (derived from `java` on PATH when unset)
#   ANDROID_SERIAL / SERIAL  pin one device (default: first emulator)
#   PDSH_AVD      (default pdsh35) default AVD when no emulator is attached

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$(sed -n 's/^sdk\.dir=//p' "$ROOT/android/local.properties" 2>/dev/null | head -1)}"
if [ -z "${JAVA_HOME:-}" ] && command -v java >/dev/null 2>&1; then
  JAVA_HOME="$(cd "$(dirname "$(command -v java)")/.." && pwd)"
fi
PDSH_AVD="${PDSH_AVD:-pdsh35}"
ARTIFACTS="$ROOT/android/build/turn-demo-artifacts"

BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    -h|--help)  sed -n '3,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

export ANDROID_HOME JAVA_HOME
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

say() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "${ANDROID_HOME:-}" ] || die "no ANDROID_HOME and android/local.properties has no sdk.dir"
command -v adb >/dev/null 2>&1 || die "adb not found under $ANDROID_HOME"

# ---------------------------------------------------------------- device
say "device"
if [ -z "${SERIAL:-}" ]; then SERIAL="${ANDROID_SERIAL:-}"; fi
if [ -z "${SERIAL:-}" ]; then
  SERIAL="$(adb devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')"
fi
if [ -z "${SERIAL:-}" ]; then
  [ -x "$ANDROID_HOME/emulator/emulator" ] || die "no device and no emulator binary"
  "$ANDROID_HOME/emulator/emulator" -avd "$PDSH_AVD" \
      -no-window -no-audio -no-boot-anim -no-snapshot \
      -gpu swiftshader_indirect >"$ROOT/android/build/turn-emulator.log" 2>&1 &
  echo "booting $PDSH_AVD (log: android/build/turn-emulator.log)"
  adb wait-for-device
  for _ in $(seq 1 60); do
    [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 2
  done
  SERIAL="$(adb devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')"
fi
[ -n "${SERIAL:-}" ] || die "could not pin a device"
export ANDROID_SERIAL="$SERIAL"
adb() { command adb ${SERIAL:+-s "$SERIAL"} "$@"; }
echo "device: $SERIAL ($(adb shell getprop ro.product.cpu.abi | tr -d '\r'), SDK $(adb shell getprop ro.build.version.sdk | tr -d '\r'))"

# ---------------------------------------------------------------- build
if [ "$BUILD" = "1" ]; then
  say "build :testkit test APK"
  ( cd "$ROOT/android" && ./gradlew :testkit:assembleDebugAndroidTest --no-daemon --console=plain )
fi

# ---------------------------------------------------------------- run
say "run TurnOverChannelInstrumentedTest"
mkdir -p "$ARTIFACTS"
adb logcat -c
set +e
( cd "$ROOT/android" && ./gradlew :testkit:connectedDebugAndroidTest \
    -Pandroid.injected.devices="$SERIAL" \
    -Pandroid.testInstrumentationRunnerArguments.class=com.phonedsh.testkit.turn.TurnOverChannelInstrumentedTest \
    --no-daemon --console=plain ) 2>&1 | tee "$ARTIFACTS/gradle.log" | tail -25
TURN_STATUS=${PIPESTATUS[0]}
set -e

adb logcat -d > "$ARTIFACTS/logcat.txt" 2>/dev/null || true

say "host event sequence (PDSHTurn)"
grep -E "PDSHTurn: (host event|tool_call|tool_result|turn_ended|session/|upstream=|exec results|VFS trace|host ready)" \
  "$ARTIFACTS/logcat.txt" || echo "(no PDSHTurn lines)"

say "frame sequence (host<->worker)"
grep -E "PDSHTurn: frame (host->worker|worker->host)" "$ARTIFACTS/logcat.txt" \
  | sed -E 's/^.*PDSHTurn: //' | sort -u | head -40 || true

say "worker->host / host->worker API + EXEC frames only"
grep -E "PDSHTurn: frame .* (API_REQ|API_RES|API_END|API_ABORT|EXEC_REQ|EXEC_EVT|HELLO) " "$ARTIFACTS/logcat.txt" \
  | sed -E 's/^.*PDSHTurn: //' | head -40 || true

say "receipt"
echo "device: $SERIAL (emulator; not a physical device)"
echo "turn test exit: $TURN_STATUS"
echo "artifacts: $ARTIFACTS"
echo "the model was scripted (testkit ScriptedModelUpstream), not a real model"
exit "$TURN_STATUS"
