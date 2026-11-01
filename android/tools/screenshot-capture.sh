#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Capture (or verify) the PDSH Android pixel baselines on a real emulator.
#
# What this baseline CAN prove: from now on a UI change that moves pixels is
# caught by a diff. What it CANNOT prove: that Android matches the iOS baseline.
# The baseline is generated from the CURRENT Android implementation, so it is a
# regression gate, not a parity proof.
#
# The capture chain is instrumented Compose on a device:
#   `captureToImage()` -> PixelCopy of the real window region.
# It is NOT Robolectric: that pipeline had fake font metrics (the same text box
# measured 35 px at fontScale 1 and 2). This script runs the font-scale probe at
# system font_scale 1.0 and 2.0 and refuses to write or approve a baseline when
# the rendered text does not grow.
#
# Usage:
#   bash android/tools/screenshot-capture.sh            # capture, prove, compare
#   bash android/tools/screenshot-capture.sh --update   # capture, prove, replace baselines
#   bash android/tools/screenshot-capture.sh --no-build # reuse the built test APK
#
# Environment:
#   ANDROID_HOME    (default: android/local.properties sdk.dir)
#   JAVA_HOME       (default: derived from `java` on PATH)
#   ANDROID_SERIAL  (default: the first attached emulator)
#   PDSH_SHOT_KEEP  (default: 0; 1 keeps the pulled captures in android/build/screenshots)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$(sed -n 's/^sdk\.dir=//p' "$ROOT/android/local.properties" 2>/dev/null | head -1)}"
if [ -z "${JAVA_HOME:-}" ] && command -v java >/dev/null 2>&1; then
  JAVA_HOME="$(cd "$(dirname "$(command -v java)")/.." && pwd)"
fi
PDSH_SHOT_KEEP="${PDSH_SHOT_KEEP:-0}"

TOOLS="$ROOT/android/tools"
BASELINE="$ROOT/android/lib/src/test/resources/screenshots"
APK="$ROOT/android/lib/build/outputs/apk/androidTest/debug/lib-debug-androidTest.apk"
TEST_PACKAGE="com.phonedsh.lib.test"
RUNNER="$TEST_PACKAGE/androidx.test.runner.AndroidJUnitRunner"
PROBE_CLASS="com.phonedsh.ui.screenshot.FontScaleProbeTest"
DEVICE_SCREENSHOTS="/sdcard/Android/data/$TEST_PACKAGE/files/pdsh-screenshots"
WORK="$ROOT/android/build/screenshots-work"
COMPARE="$TOOLS/test_screenshot_compare.py"

# The fixed capture conditions. A baseline captured under anything else is not
# comparable, so the script sets and then asserts every one of them.
WIDTH=1080
HEIGHT=2400
DPI=420
FONT_SCALE=1.0
LOCALE="en-US"
API_LEVEL=35

BUILD=1
UPDATE=0
for arg in "$@"; do
  case "$arg" in
    --update)    UPDATE=1 ;;
    --no-build)  BUILD=0 ;;
    -h|--help)   sed -n '3,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "${ANDROID_HOME:-}" ] || die "no ANDROID_HOME and android/local.properties has no sdk.dir"
export ANDROID_HOME JAVA_HOME
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
command -v adb >/dev/null 2>&1 || die "adb not found under $ANDROID_HOME"
command -v python3 >/dev/null 2>&1 || die "python3 is required for the comparison"
[ -f "$COMPARE" ] || die "missing comparator: $COMPARE"
[ -d "$BASELINE" ] || die "missing baseline directory: $BASELINE"

# ---------------------------------------------------------------- device
say "device"
if [ -z "${SERIAL:-}" ]; then
  SERIAL="${ANDROID_SERIAL:-}"
fi
if [ -z "${SERIAL:-}" ]; then
  SERIAL="$(adb devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')"
fi
[ -n "${SERIAL:-}" ] || die "no emulator attached (start one, or set ANDROID_SERIAL)"
export ANDROID_SERIAL="$SERIAL"
adb_dev() { command adb -s "$SERIAL" "$@"; }
adb_dev wait-for-device
BOOTED="$(adb_dev shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
[ "$BOOTED" = "1" ] || die "$SERIAL is attached but not booted"
echo "using device: $SERIAL (API $(adb_dev shell getprop ro.build.version.sdk | tr -d '\r'))"

SDK="$(adb_dev shell getprop ro.build.version.sdk | tr -d '\r')"
[ "$SDK" = "$API_LEVEL" ] || die "baselines are pinned to API $API_LEVEL, this device is API $SDK.
Run on the pinned AVD (pdsh35) or regenerate the baselines for the new image."
CURRENT_LOCALE="$(adb_dev shell getprop persist.sys.locale | tr -d '\r')"
[ -n "$CURRENT_LOCALE" ] || CURRENT_LOCALE="$(adb_dev shell getprop ro.product.locale | tr -d '\r')"
[ "$CURRENT_LOCALE" = "$LOCALE" ] || die "baselines are pinned to locale $LOCALE, this device is '$CURRENT_LOCALE'.
Changing the locale needs root + a reboot; run on a fresh $LOCALE emulator instead."

# Screen must be awake: a dozing device renders no frames and PixelCopy would
# capture a stale/blank surface.
WAKE="$(adb_dev shell dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -1)"
if [ "$WAKE" != "Awake" ]; then
  adb_dev shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb_dev shell wm dismiss-keyguard >/dev/null 2>&1 || true
  sleep 1
  WAKE="$(adb_dev shell dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -1)"
  [ "$WAKE" = "Awake" ] || die "the device is not awake (mWakefulness=$WAKE); wake the emulator and retry"
fi

# ---------------------------------------------------------------- fixed conditions
say "pin fixed conditions"
STAY_ON_WAS="$(adb_dev shell dumpsys power 2>/dev/null | sed -n 's/.*mStayOn=\(true\|false\).*/\1/p' | head -1)"
STAY_ON_WAS="${STAY_ON_WAS:-false}"
FONT_SCALE_WAS="$(adb_dev shell settings get system font_scale | tr -d '\r')"
[ "$FONT_SCALE_WAS" != "null" ] || FONT_SCALE_WAS="$FONT_SCALE"
WIN_ANIM_WAS="$(adb_dev shell settings get global window_animation_scale | tr -d '\r')"
TRANS_ANIM_WAS="$(adb_dev shell settings get global transition_animation_scale | tr -d '\r')"
ANIM_WAS="$(adb_dev shell settings get global animator_duration_scale | tr -d '\r')"

cleanup() {
  # Restore whatever this script changed, even when a capture fails.
  adb_dev shell settings put system font_scale "$FONT_SCALE_WAS" >/dev/null 2>&1 || true
  adb_dev shell settings put global window_animation_scale "${WIN_ANIM_WAS:-1}" >/dev/null 2>&1 || true
  adb_dev shell settings put global transition_animation_scale "${TRANS_ANIM_WAS:-1}" >/dev/null 2>&1 || true
  adb_dev shell settings put global animator_duration_scale "${ANIM_WAS:-1}" >/dev/null 2>&1 || true
  adb_dev shell svc power stayon "${STAY_ON_WAS:-false}" >/dev/null 2>&1 || true
  adb_dev shell wm size reset >/dev/null 2>&1 || true
  adb_dev shell wm density reset >/dev/null 2>&1 || true
}
trap cleanup EXIT

adb_dev shell wm size "${WIDTH}x${HEIGHT}" >/dev/null
adb_dev shell wm density "$DPI" >/dev/null
adb_dev shell settings put system font_scale "$FONT_SCALE"
# System animations are the one flake no fixed density removes.
adb_dev shell settings put global window_animation_scale 0 >/dev/null
adb_dev shell settings put global transition_animation_scale 0 >/dev/null
adb_dev shell settings put global animator_duration_scale 0 >/dev/null
adb_dev shell svc power stayon true >/dev/null
sleep 1

EFFECTIVE_SIZE="$(adb_dev shell wm size | tail -1 | sed 's/.*: //' | tr -d '\r')"
EFFECTIVE_DENSITY="$(adb_dev shell wm density | tail -1 | sed 's/.*: //' | tr -d '\r')"
EFFECTIVE_FONT_SCALE="$(adb_dev shell settings get system font_scale | tr -d '\r')"
[ "$EFFECTIVE_SIZE" = "${WIDTH}x${HEIGHT}" ] || die "wm size is $EFFECTIVE_SIZE, expected ${WIDTH}x${HEIGHT}"
[ "$EFFECTIVE_DENSITY" = "$DPI" ] || die "wm density is $EFFECTIVE_DENSITY, expected $DPI"
[ "$EFFECTIVE_FONT_SCALE" = "$FONT_SCALE" ] || die "font_scale is $EFFECTIVE_FONT_SCALE, expected $FONT_SCALE"

cat <<EOF
  serial        $SERIAL
  sdk           $SDK
  display       ${WIDTH}x${HEIGHT} px
  density       ${DPI} dpi (2.625)
  font scale    ${FONT_SCALE} (proof run: 2.0, restored afterwards)
  locale        $CURRENT_LOCALE
  theme         light (PdshTheme(darkTheme = false), no action bar)
  backdrop      #FFFFFF (harness condition; colors.background is unmeasured)
  system bars   hidden (immersive)
  clock         virtual, frozen at +1000 ms
  animations    window/transition/animator scale = 0
EOF

# ---------------------------------------------------------------- build + install
say "build :lib androidTest APK"
mkdir -p "$WORK"
if [ "$BUILD" = "1" ]; then
  # The Gradle log is kept for triage; only a one-line receipt goes to stdout.
  if ! ( cd "$ROOT/android" && ./gradlew :lib:assembleDebugAndroidTest --console=plain ) \
      >"$WORK/gradle.log" 2>&1; then
    tail -40 "$WORK/gradle.log" >&2
    die "the androidTest APK did not build (full log: ${WORK#"$ROOT/"}/gradle.log)"
  fi
  grep -E "^BUILD SUCCESSFUL" "$WORK/gradle.log" | tail -1
fi
[ -f "$APK" ] || die "no test APK at $APK (drop --no-build)"
echo "test apk: ${APK#"$ROOT/"}"

say "install test APK"
adb_dev install -r -t "$APK" >/dev/null
adb_dev shell pm clear "$TEST_PACKAGE" >/dev/null 2>&1 || true
adb_dev shell rm -rf "$DEVICE_SCREENSHOTS"

run_instrumentation() {
  local label="$1"
  shift
  local out="$WORK/instrument-${label}.txt"
  set +e
  adb_dev shell am instrument -w -r "$@" "$RUNNER" >"$out" 2>&1
  local status=$?
  set -e
  if [ "$status" != "0" ] || ! grep -q "INSTRUMENTATION_CODE: -1" "$out"; then
    tail -40 "$out" >&2
    die "instrumentation '$label' failed (full log: ${out#"$ROOT/"})"
  fi
  if grep -q "FAILURES!!!" "$out"; then
    grep -A 20 "FAILURES!!!" "$out" >&2 || true
    die "instrumentation '$label' reported FAILURES!!! (full log: ${out#"$ROOT/"})"
  fi
  grep -q "OK (" "$out" || die "instrumentation '$label' did not report OK (${out#"$ROOT/"})"
  printf '  %s\n' "$(grep -m 1 "OK (" "$out" | tr -d '\r')"
}

# ---------------------------------------------------------------- capture at 1.0
say "capture 11 baselines at fontScale $FONT_SCALE"
rm -rf "$WORK/fs-1.0" "$WORK/fs-2.0" "$WORK/diff"
run_instrumentation "full"
adb_dev pull "$DEVICE_SCREENSHOTS/fs-1.0" "$WORK/" >/dev/null

# ---------------------------------------------------------------- font-scale proof
say "font scale proof (system font_scale 1.0 vs 2.0, same probe)"
adb_dev shell settings put system font_scale 2.0
sleep 1
adb_dev shell rm -rf "$DEVICE_SCREENSHOTS/fs-2.0"
run_instrumentation "2.0" -e class "$PROBE_CLASS"
adb_dev pull "$DEVICE_SCREENSHOTS/fs-2.0" "$WORK/" >/dev/null
adb_dev shell settings put system font_scale "$FONT_SCALE"

metric_value() {
  # metrics.txt is one line per capture: "name=... key=value ..."
  awk -v wanted_name="$2" -v wanted_key="$3" '
    {
      name = ""
      for (i = 1; i <= NF; i++) {
        split($i, pair, "=")
        if (pair[1] == "name") name = pair[2]
        if (name == wanted_name && pair[1] == wanted_key) print pair[2]
      }
    }' "$1"
}

M1="$WORK/fs-1.0/metrics.txt"
M2="$WORK/fs-2.0/metrics.txt"
[ -f "$M1" ] || die "missing $M1"
[ -f "$M2" ] || die "missing $M2"
BOX1="$(metric_value "$M1" fontscale-probe textBoxHeightPx)"
BOX2="$(metric_value "$M2" fontscale-probe textBoxHeightPx)"
FS1="$(metric_value "$M1" fontscale-probe fontScale)"
FS2="$(metric_value "$M2" fontscale-probe fontScale)"
INK1="$(python3 "$COMPARE" ink --image "$WORK/fs-1.0/fontscale-probe.png" | sed -n 's/.*ink_height=\([0-9]*\).*/\1/p')"
INK2="$(python3 "$COMPARE" ink --image "$WORK/fs-2.0/fontscale-probe.png" | sed -n 's/.*ink_height=\([0-9]*\).*/\1/p')"
[ -n "$BOX1" ] && [ -n "$BOX2" ] && [ -n "$INK1" ] && [ -n "$INK2" ] \
  || die "could not read the probe measurements (text box '$BOX1'/'$BOX2', ink '$INK1'/'$INK2')"

printf '  fontScale %s: text box %s px, raster ink height %s px\n' "$FS1" "$BOX1" "$INK1"
printf '  fontScale %s: text box %s px, raster ink height %s px\n' "$FS2" "$BOX2" "$INK2"
python3 - "$FS1" "$FS2" "$BOX1" "$BOX2" "$INK1" "$INK2" <<'PYMATH'
import sys

fs1, fs2, box1, box2, ink1, ink2 = sys.argv[1:7]
box1, box2, ink1, ink2 = float(box1), float(box2), int(ink1), int(ink2)
assert fs1 and fs2, "the probe did not record a font scale"
if fs1 == fs2:
    raise SystemExit(
        f"FAIL: both runs saw fontScale {fs1}; the font-scale toggle did not reach the app"
    )
if box2 <= box1 or ink2 <= ink1:
    raise SystemExit(
        "FAIL: the same text did not grow with fontScale "
        f"(box {box1} -> {box2}, ink {ink1} -> {ink2}); this renderer is fake"
    )
if box2 < 1.5 * box1 or ink2 < 1.5 * ink1:
    raise SystemExit(
        "FAIL: text grew, but not like real metrics "
        f"(box x{box2 / box1:.2f}, ink x{ink2 / ink1:.2f}); expected >= x1.5"
    )
print(
    f"  OK: real glyph metrics (text box x{box2 / box1:.2f}, "
    f"raster ink x{ink2 / ink1:.2f}); a fake renderer would print the same "
    f"number twice."
)
PYMATH

# ---------------------------------------------------------------- compare
say "compare"
mkdir -p "$WORK/diff"
if [ "$UPDATE" = "1" ]; then
  mkdir -p "$BASELINE"
  cp "$WORK/fs-1.0/"*.png "$BASELINE/"
  cp "$WORK/fs-1.0/metrics.txt" "$BASELINE/metrics.txt"
  # adb pull keeps the device's 0600 mode; repository files are 0644.
  chmod 644 "$BASELINE"/*.png "$BASELINE/metrics.txt"
  echo "baselines updated: $(ls "$BASELINE"/*.png | wc -l | tr -d ' ') PNGs in android/lib/src/test/resources/screenshots/"
else
  set +e
  python3 "$COMPARE" compare \
    --baseline "$BASELINE" \
    --actual "$WORK/fs-1.0" \
    --diff-dir "$WORK/diff" \
    --summary "$WORK/compare.txt"
  COMPARE_STATUS=$?
  set -e
  [ "$COMPARE_STATUS" = "0" ] || die "pixel regression detected; see android/build/screenshots-work/diff/"
fi

if [ "$PDSH_SHOT_KEEP" != "1" ]; then
  rm -rf "$WORK/fs-1.0" "$WORK/fs-2.0" "$WORK/diff"
fi

# ---------------------------------------------------------------- receipt
say "done"
cat <<'EOF'
Proven: a UI change that moves pixels is caught by this baseline.
NOT proven: that Android matches the iOS baseline. The baseline is generated
from the current Android implementation, so it is a regression gate, not a
parity proof.
EOF
