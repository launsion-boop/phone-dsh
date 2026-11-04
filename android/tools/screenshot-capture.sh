#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Capture (or verify) the PDSH Android pixel baselines on a real emulator, in three
# profiles:
#
#   gate          the 11 historical baselines, 1080x2400 px @ 420 dpi
#   ios-parity    the 27 named iOS states, 1206x2622 px @ 480 dpi = 402x874 pt @3x
#   android-only  Android states with no iOS counterpart, same frame as `gate`,
#                 their own baseline directory (screenshots/android-only/)
#
# What the gate profile CAN prove: from now on a UI change that moves pixels is
# caught by a diff (Android against its own previous commit). What it CANNOT
# prove: that Android matches the iOS baseline. The baseline is generated from the
# CURRENT Android implementation, so it is a regression gate, not a parity proof.
#
# What the ios-parity profile CAN prove: that Android renders the same 27 named
# states the iOS baseline publishes, in the same 402x874@3 frame, and that a given
# state does not drift between commits (the comparison is Android-against-Android
# inside the parity baseline directory). What it CANNOT prove: that Android and
# iOS look the same. CoreText and Android's Minikin/HarfBuzz rasterise glyphs
# differently, the two systems draw different chrome, and the copy is localised
# on each side. NO cross-platform pixel diff is run or implied by this script.
# The iOS/Android comparison is done by a human, per state, by the page lane that
# owns the state; the pixel threshold below is only ever used inside Android's own
# golden. `python3 android/tools/ui-parity-sheet.py` lays each pair side by side in
# docs/receipts/ui-parity-sheet/ so that review is looking at one image, not two.
#
# The state names are pinned by `ParityStates.kt` (27 entries, one per file in
# docs/receipts/ios-baseline-screens/) and the mapping is documented in
# android/tools/README.md. The 402 pt numbers are owned by
# android/lib/.../ui/UiMetrics.kt — this script reads them out of that file
# instead of re-typing them.
#
# The capture chain is instrumented Compose on a device:
#   `captureToImage()` -> PixelCopy of the real window region.
# It is NOT Robolectric: that pipeline had fake font metrics (the same text box
# measured 35 px at fontScale 1 and 2). The gate profile runs the font-scale probe
# at system font_scale 1.0 and 2.0 and refuses to write or approve a baseline when
# the rendered text does not grow. The parity profile reuses the same APK, device
# and capture call, so the proof is not repeated there (and its frame would not be
# a gate baseline); run `--profile gate` to re-prove the chain.
#
# Usage:
#   bash android/tools/screenshot-capture.sh                       # gate: capture, prove, compare
#   bash android/tools/screenshot-capture.sh --update              # gate: replace the 11 baselines
#   bash android/tools/screenshot-capture.sh --profile ios-parity  # parity: capture + compare
#   bash android/tools/screenshot-capture.sh --profile ios-parity --update
#   bash android/tools/screenshot-capture.sh --profile android-only # Android-only: capture + compare
#   bash android/tools/screenshot-capture.sh --profile android-only --update
#   bash android/tools/screenshot-capture.sh --profile all         # all three, gate first
#   bash android/tools/screenshot-capture.sh --profile ios-parity \
#     --states page-chat-default,page-settings-default             # a subset
#   bash android/tools/screenshot-capture.sh --no-build            # reuse the built test APK
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
GATE_BASELINE="$ROOT/android/lib/src/test/resources/screenshots"
PARITY_BASELINE="$GATE_BASELINE/ios-parity"
ANDROID_ONLY_BASELINE="$GATE_BASELINE/android-only"
APK="$ROOT/android/lib/build/outputs/apk/androidTest/debug/lib-debug-androidTest.apk"
TEST_PACKAGE="com.phonedsh.lib.test"
RUNNER="$TEST_PACKAGE/androidx.test.runner.AndroidJUnitRunner"
PROBE_CLASS="com.phonedsh.ui.screenshot.FontScaleProbeTest"
# The three gate suites, named explicitly: the APK also carries the parity suites
# (and any other lane's test class), and a profile run must not capture them.
# A new gate suite is added here at the same time as its `@Test`s.
GATE_CLASSES="com.phonedsh.ui.screenshot.PageScreenshotTest,\
com.phonedsh.ui.screenshot.SignatureSurfaceScreenshotTest,\
com.phonedsh.ui.screenshot.FontScaleProbeTest"
# The parity suites the `ios-parity` profile runs. Every state they write is
# `ParityStatus.CAPTURED` in ParityStates.kt; `check_parity_registry` fails the run
# when the device writes a name the registry does not call captured, so a PENDING
# page cannot be frozen by accident.
#
# `ChatParityScreenshotTest` cannot be added as a whole class. Besides its five
# parity captures it also writes `page-chat-route`, a routing receipt that is
# deliberately NOT a registered state (there is no iOS counterpart for "the router
# resolved the route"). A whole-class run makes the device write that PNG and the
# registry check then fails with "the device wrote PNGs no registry row calls
# captured" — which is why this suite was never wired in. The profile runs its
# five parity methods by name; the routing receipt stays an ad-hoc run:
#   adb shell am instrument -e class \
#     com.phonedsh.ui.screenshot.ChatParityScreenshotTest#chatRouteThroughNavHost ...
# Deliberately absent: `DeviceConnectorParityScreenshotTest` — its 3 androidOnly
# states have no iOS baseline and no parity PNG to compare.
CHAT_PARITY_CLASS="com.phonedsh.ui.screenshot.ChatParityScreenshotTest"
CHAT_PARITY_METHODS="pageChatAssistant pageChatOfficial pageChatQueued pageChatPermission surfaceCodeBlock"
PARITY_CLASSES="com.phonedsh.ui.screenshot.ParityScreenshotTest,\
com.phonedsh.ui.screenshot.SessionsParityScreenshotTest,\
com.phonedsh.ui.screenshot.ShellFilesParityScreenshotTest,\
$CHAT_PARITY_CLASS"
# The Android-only capture suites: pages/surfaces the iOS baseline does not cover.
# They run at the gate frame, but they write to android-only/ so the 11 historical
# gate baselines keep their count and their meaning.
ANDROID_ONLY_CLASSES="com.phonedsh.ui.screenshot.L13PagesScreenshotTest,\
com.phonedsh.ui.screenshot.L14BGroupPageScreenshotTest,\
com.phonedsh.ui.screenshot.L16ConfigurationPageScreenshotTest,\
com.phonedsh.ui.screenshot.L24ChatSubpagesScreenshotTest"
DEVICE_SCREENSHOTS="/sdcard/Android/data/$TEST_PACKAGE/files/pdsh-screenshots"
WORK="$ROOT/android/build/screenshots-work"
COMPARE="$TOOLS/test_screenshot_compare.py"
IOS_BASELINE_DIR="$ROOT/docs/receipts/ios-baseline-screens"
UI_METRICS="$ROOT/android/lib/src/main/kotlin/com/phonedsh/ui/UiMetrics.kt"

# The gate frame. It predates the 402 pt contract and must not move: the 11
# baselines in `screenshots/` were captured here. `ScreenshotProfile.GATE`
# declares the same numbers, and the test asserts the device matches, so a drift
# fails the run instead of writing a baseline nobody can compare.
GATE_WIDTH_PX=1080
GATE_HEIGHT_PX=2400
GATE_DPI=420
GATE_DENSITY=2.625
GATE_PT_DPR=2.625

FONT_SCALE=1.0
LOCALE="en-US"
API_LEVEL=35
PARITY_STATE_COUNT=27

BUILD=1
UPDATE=0
PROFILE_REQUEST="gate"
STATES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --update)    UPDATE=1 ;;
    --no-build)  BUILD=0 ;;
    --profile)
      shift
      [ $# -gt 0 ] || { echo "--profile needs a value" >&2; exit 2; }
      PROFILE_REQUEST="$1"
      ;;
    --profile=*) PROFILE_REQUEST="${1#--profile=}" ;;
    --states)
      shift
      [ $# -gt 0 ] || { echo "--states needs a value" >&2; exit 2; }
      STATES="$1"
      ;;
    --states=*)  STATES="${1#--states=}" ;;
    -h|--help)
      header_lines="$(grep -n '^set -euo pipefail' "${BASH_SOURCE[0]}" | head -1 | cut -d: -f1)"
      sed -n "3,$((header_lines - 1))p" "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$PROFILE_REQUEST" in
  gate|ios-parity|android-only|all) ;;
  *) echo "--profile must be gate, ios-parity, android-only or all (got '$PROFILE_REQUEST')" >&2; exit 2 ;;
esac
if [ -n "$STATES" ] && [ "$PROFILE_REQUEST" != "ios-parity" ]; then
  echo "--states only applies to the ios-parity profile" >&2
  exit 2
fi

say() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "${ANDROID_HOME:-}" ] || die "no ANDROID_HOME and android/local.properties has no sdk.dir"
export ANDROID_HOME JAVA_HOME
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
command -v adb >/dev/null 2>&1 || die "adb not found under $ANDROID_HOME"
command -v python3 >/dev/null 2>&1 || die "python3 is required for the comparison"
[ -f "$COMPARE" ] || die "missing comparator: $COMPARE"
[ -d "$GATE_BASELINE" ] || die "missing baseline directory: $GATE_BASELINE"
[ -f "$UI_METRICS" ] || die "missing the parity metric owner: $UI_METRICS"

# ---------------------------------------------------------------- UiMetrics
# The 402 pt frame is defined once, in Kotlin. Read it; never re-type it.
say "read the 402 pt contract from UiMetrics.kt"
UI_METRIC_VALUES="$(python3 - "$UI_METRICS" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
definitions = {}
order = []
for line in source.splitlines():
    match = re.match(r"^\s*public const val ([A-Z0-9_]+): Int =\s*(.+)$", line)
    if not match:
        continue
    name, expr = match.group(1), match.group(2).split("//")[0].strip()
    definitions[name] = expr
    order.append(name)
values = {}
for _ in range(len(order) + 1):
    for name in order:
        if name in values:
            continue
        try:
            value = eval(definitions[name], {"__builtins__": {}}, dict(values))  # noqa: S307
        except Exception:
            continue
        if not isinstance(value, int):
            raise SystemExit(f"UiMetrics.{name} is not an Int: {definitions[name]}")
        values[name] = value
missing = [name for name in order if name not in values]
if missing:
    raise SystemExit(f"cannot evaluate UiMetrics constants: {missing}")
needed = [
    "BASELINE_WIDTH_PX",
    "BASELINE_HEIGHT_PX",
    "BASELINE_DENSITY_DPI",
    "BASELINE_WIDTH_PT",
    "BASELINE_HEIGHT_PT",
    "BASELINE_DPR",
    "HEADER_HEIGHT_PT",
    "COMPOSER_WIDTH_PT",
    "COMPOSER_HEIGHT_PT",
    "CONTENT_COLUMN_WIDTH_PT",
    "TOOL_ROW_HEIGHT_PT",
    "FLOW_GAP_PT",
    "FLOW_GAP_RESPONSE_PT",
]
for name in needed:
    if name not in values:
        raise SystemExit(f"UiMetrics.kt does not define {name}")
    print(f"{name}={values[name]}")
PY
)" || die "could not read the viewport contract from UiMetrics.kt"
eval "$UI_METRIC_VALUES"
[ "$BASELINE_WIDTH_PX" = "$((BASELINE_WIDTH_PT * BASELINE_DPR))" ] \
  || die "UiMetrics: BASELINE_WIDTH_PX != BASELINE_WIDTH_PT x BASELINE_DPR"
[ "$BASELINE_HEIGHT_PX" = "$((BASELINE_HEIGHT_PT * BASELINE_DPR))" ] \
  || die "UiMetrics: BASELINE_HEIGHT_PX != BASELINE_HEIGHT_PT x BASELINE_DPR"
[ "$BASELINE_DENSITY_DPI" = "$((160 * BASELINE_DPR))" ] \
  || die "UiMetrics: BASELINE_DENSITY_DPI != 160 x BASELINE_DPR"
printf '  402 pt contract  %sx%s pt @ %sx = %sx%s px @ %s dpi\n' \
  "$BASELINE_WIDTH_PT" "$BASELINE_HEIGHT_PT" "$BASELINE_DPR" \
  "$BASELINE_WIDTH_PX" "$BASELINE_HEIGHT_PX" "$BASELINE_DENSITY_DPI"
printf '  shared metrics   header %s / composer %sx%s / content %s / tool row %s / flow %s-%s\n' \
  "$HEADER_HEIGHT_PT" "$COMPOSER_WIDTH_PT" "$COMPOSER_HEIGHT_PT" \
  "$CONTENT_COLUMN_WIDTH_PT" "$TOOL_ROW_HEIGHT_PT" "$FLOW_GAP_PT" "$FLOW_GAP_RESPONSE_PT"

# ---------------------------------------------------------------- profiles
PROFILES=()
case "$PROFILE_REQUEST" in
  all)        PROFILES=(gate ios-parity android-only) ;;
  *)          PROFILES=("$PROFILE_REQUEST") ;;
esac

profile_value() {
  case "$1:$2" in
    gate:width|android-only:width)    echo "$GATE_WIDTH_PX" ;;
    gate:height|android-only:height)  echo "$GATE_HEIGHT_PX" ;;
    gate:dpi|android-only:dpi)        echo "$GATE_DPI" ;;
    gate:density|android-only:density) echo "$GATE_DENSITY" ;;
    gate:title)    echo "11 historical baselines at 1080x2400 px @ 420 dpi" ;;
    gate:baseline) echo "$GATE_BASELINE" ;;
    android-only:title)    echo "Android-only baselines at 1080x2400 px @ 420 dpi (no iOS counterpart)" ;;
    android-only:baseline) echo "$ANDROID_ONLY_BASELINE" ;;
    ios-parity:width)    echo "$BASELINE_WIDTH_PX" ;;
    ios-parity:height)   echo "$BASELINE_HEIGHT_PX" ;;
    ios-parity:dpi)      echo "$BASELINE_DENSITY_DPI" ;;
    ios-parity:density)  echo "$BASELINE_DPR.0" ;;
    ios-parity:title)    echo "27 iOS state names at 402x874 pt @ 3x" ;;
    ios-parity:baseline) echo "$PARITY_BASELINE" ;;
    *) die "internal: no value for $1:$2" ;;
  esac
}

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

adb_dev shell settings put system font_scale "$FONT_SCALE"
# System animations are the one flake no fixed density removes.
adb_dev shell settings put global window_animation_scale 0 >/dev/null
adb_dev shell settings put global transition_animation_scale 0 >/dev/null
adb_dev shell settings put global animator_duration_scale 0 >/dev/null
adb_dev shell svc power stayon true >/dev/null

EFFECTIVE_FONT_SCALE="$(adb_dev shell settings get system font_scale | tr -d '\r')"
[ "$EFFECTIVE_FONT_SCALE" = "$FONT_SCALE" ] || die "font_scale is $EFFECTIVE_FONT_SCALE, expected $FONT_SCALE"

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

# ---------------------------------------------------------------- parity states
# `page-chat-draft` -> `pageChatDraft`: the JUnit method that captures it.
state_test_method() {
  python3 - "$1" <<'PY'
import sys

parts = sys.argv[1].split("-")
print(parts[0] + "".join(part.capitalize() for part in parts[1:]))
PY
}

# Which suite owns each CAPTURED parity state. `--states` names a registry state,
# but the capture lives in one of several classes, so the mapping belongs here.
# It is only used by `--states`; a full ios-parity run executes PARITY_CLASSES.
# Update this table when a state flips to CAPTURED (the run then fails loudly if
# `--states <it>` has no owner instead of silently capturing nothing).
parity_owner_class() {
  case "$1" in
    page-chat-default|page-chat-failed|page-chat-long|page-chat-draft)
      echo "ParityScreenshotTest" ;;
    page-chat-assistant|page-chat-official|page-chat-queued|page-chat-permission|\
surface-code-block)
      echo "ChatParityScreenshotTest" ;;
    page-settings-default|page-settings-model|page-settings-search|page-settings-network|\
page-settings-plugins|page-settings-about|page-settings-runtime)
      echo "ParityScreenshotTest" ;;
    page-sessions-default|page-sessions-empty|page-sessions-error|page-sessions-many|\
page-sessions-nothing|page-sessions-ungrouped|page-sessions-schedules)
      echo "SessionsParityScreenshotTest" ;;
    page-workspace-folders|page-files|page-shell)
      echo "ShellFilesParityScreenshotTest" ;;
    *) return 1 ;;
  esac
}

# `-e class` accepts both `Class` and `Class#method` entries. Expand the suite that
# has to stay method-scoped; every other suite runs whole. Kept as a function so the
# expansion cannot drift from CHAT_PARITY_METHODS.
parity_instrument_classes() {
  local classes="$1" out="" class method
  local -a entries methods
  IFS=',' read -r -a entries <<<"$classes"
  for class in "${entries[@]}"; do
    if [ "$class" = "$CHAT_PARITY_CLASS" ]; then
      read -r -a methods <<<"$CHAT_PARITY_METHODS"
      for method in "${methods[@]}"; do
        out="${out:+$out,}$class#$method"
      done
    else
      out="${out:+$out,}$class"
    fi
  done
  printf '%s\n' "$out"
}

# "captured <owner>" / "pending <owner>" for one Android state name, or nothing
# when the checked-in registry does not know it. Read-only: it explains a refusal.
parity_registry_status() {
  local registry="$PARITY_BASELINE/parity-registry.txt" state="$1"
  [ -f "$registry" ] || return 0
  awk -F'|' -v name="$state" '$2 == name { print $4 " (owner: " $5 ", screen: " $6 ")"; exit }' "$registry"
}

state_class_filter() {
  local selected="$1" methods="" state method class status
  IFS=',' read -r -a requested <<<"$selected"
  for state in "${requested[@]}"; do
    [ -n "$state" ] || continue
    case "$state" in
      *[!a-z0-9-]*) die "invalid state name '$state' (lowercase, digits and '-' only)" ;;
    esac
    method="$(state_test_method "$state")"
    if ! class="$(parity_owner_class "$state")"; then
      status="$(parity_registry_status "$state")"
      if [ -n "$status" ]; then
        die "state '$state' is registered '$status'; only a CAPTURED state has a
baseline, so it cannot be selected here. A PENDING state is captured ad hoc by
its lane (am instrument -e class <class>) and never baked into a baseline."
      fi
      die "state '$state' has no wired capture suite. Wired: page-chat-{default,assistant,official,
failed,queued,long,draft,permission}, surface-code-block, page-sessions-*, page-settings-*,
page-shell, page-files, page-workspace-folders."
    fi
    case ",$PARITY_CLASSES," in
      *",com.phonedsh.ui.screenshot.$class,"*) ;;
      *) die "internal: $state maps to $class, which the ios-parity profile does not run" ;;
    esac
    methods="${methods:+$methods,}com.phonedsh.ui.screenshot.$class#$method"
  done
  [ -n "$methods" ] || die "--states was empty"
  printf '%s\n' "$methods"
}

check_parity_registry() {
  local registry="$1" capture_dir="$2" require_all="$3"
  python3 - "$registry" "$capture_dir" "$IOS_BASELINE_DIR" "$PARITY_STATE_COUNT" "$require_all" <<'PY'
import pathlib
import sys

registry_path, capture_dir, ios_dir, expected, require_all = sys.argv[1:6]
expected = int(expected)
lines = pathlib.Path(registry_path).read_text(encoding="utf-8").splitlines()
rows = [line.split("|") for line in lines if line.strip()]
if not rows:
    raise SystemExit("FAIL: the parity registry is empty")
bad = [row for row in rows if len(row) != 7]
if bad:
    raise SystemExit(
        "FAIL: malformed registry rows (expected 7 fields: "
        f"category|android|ios|status|owner|screen|note): {bad[:3]}"
    )

categories = {row[0] for row in rows}
unknown = categories - {"parity", "androidOnly"}
if unknown:
    raise SystemExit(f"FAIL: unknown registry categories {sorted(unknown)}")

parity = [row for row in rows if row[0] == "parity"]
android_only = [row for row in rows if row[0] == "androidOnly"]

# --- parity: the cross-platform contract. Exact, and anchored to the iOS files.
if len(parity) != expected:
    raise SystemExit(
        f"FAIL: registry has {len(parity)} parity states, the iOS baseline publishes {expected}"
    )
parity_android = [row[1] for row in parity]
parity_ios = [row[2] for row in parity]
if len(set(parity_android)) != len(parity):
    raise SystemExit("FAIL: duplicate Android capture names in the parity category")
if len(set(parity_ios)) != len(parity):
    raise SystemExit("FAIL: duplicate iOS files in the parity category")
ios_files = {path.stem for path in pathlib.Path(ios_dir).glob("*.png")}
missing_on_disk = sorted(set(parity_ios) - ios_files)
if missing_on_disk:
    raise SystemExit(f"FAIL: registry names iOS files that do not exist: {missing_on_disk}")
unregistered = sorted(ios_files - set(parity_ios))
if unregistered:
    raise SystemExit(f"FAIL: the iOS baseline has states the registry does not name: {unregistered}")

# --- androidOnly: free count, structural rules only.
android_only_names = [row[1] for row in android_only]
if len(set(android_only_names)) != len(android_only_names):
    raise SystemExit("FAIL: duplicate Android capture names in the androidOnly category")
for row in android_only:
    name, ios, owner, note = row[1], row[2], row[4], row[6]
    if ios != "none":
        raise SystemExit(
            f"FAIL: {name} is androidOnly but names an iOS file {ios!r} (expected 'none')"
        )
    if not note.startswith("no iOS baseline:"):
        raise SystemExit(f"FAIL: {name} has no 'no iOS baseline:' reason: {note!r}")
    if not owner.strip():
        raise SystemExit(f"FAIL: {name} has no owner")
both = set(parity_android) & set(android_only_names)
if both:
    raise SystemExit(f"FAIL: names in both categories: {sorted(both)}")

# --- the registry must own every PNG the device wrote.
#
# One direction is strict: a PNG with no `captured` row would be a state nobody
# registered, and the name would never be comparable to an iOS file. The other
# direction is a report, not a failure: the registry is shared by several suites
# (`ParityScreenshotTest` plus a page lane's own class once it is wired in), and a
# single instrumentation pass — or a `--states` subset — legitimately writes fewer
# PNGs than the registry has `captured` rows for. The list below says which ones,
# so a missing capture is visible instead of implied.
captured = {row[1] for row in rows if row[3] == "captured"}
on_device = {path.stem for path in pathlib.Path(capture_dir).glob("*.png")} - {"fontscale-probe"}
unregistered_pngs = on_device - captured
if unregistered_pngs:
    raise SystemExit(
        "FAIL: the device wrote PNGs no registry row calls captured: "
        f"{sorted(unregistered_pngs)}"
    )
not_in_this_pass = sorted(captured - on_device)
if require_all == "1" and not_in_this_pass:
    raise SystemExit(
        "FAIL: a full ios-parity run must write every captured state, but this pass did not "
        f"write: {not_in_this_pass}. A suite in PARITY_CLASSES did not run — a wrong "
        "class#method filter fails here instead of silently freezing 21 of 26 baselines."
    )

pending = [row for row in parity if row[3] == "pending"]
print(
    f"  registry: {len(parity)} parity states ({len(parity) - len(pending)} captured) + "
    f"{len(android_only)} androidOnly states "
    f"({sum(1 for row in android_only if row[3] == 'captured')} captured)"
)
print(f"  this pass wrote {len(on_device)} PNGs at the 402 pt frame")
if not_in_this_pass:
    print(
        f"  claimed captured but not written by this pass ({len(not_in_this_pass)}): "
        + ", ".join(not_in_this_pass)
    )
for row in pending:
    print(f"    pending {row[1]:<28} <- {row[2]:<32} owner: {row[4]}")
PY
}

# ---------------------------------------------------------------- run profiles
for PROFILE in "${PROFILES[@]}"; do
  WIDTH="$(profile_value "$PROFILE" width)"
  HEIGHT="$(profile_value "$PROFILE" height)"
  DPI="$(profile_value "$PROFILE" dpi)"
  DENSITY="$(profile_value "$PROFILE" density)"
  TITLE="$(profile_value "$PROFILE" title)"
  BASELINE="$(profile_value "$PROFILE" baseline)"
  PULLED="$WORK/$PROFILE/fs-1.0"

  say "profile $PROFILE: $TITLE"
  adb_dev shell wm size "${WIDTH}x${HEIGHT}" >/dev/null
  adb_dev shell wm density "$DPI" >/dev/null
  sleep 1

  EFFECTIVE_SIZE="$(adb_dev shell wm size | tail -1 | sed 's/.*: //' | tr -d '\r')"
  EFFECTIVE_DENSITY="$(adb_dev shell wm density | tail -1 | sed 's/.*: //' | tr -d '\r')"
  [ "$EFFECTIVE_SIZE" = "${WIDTH}x${HEIGHT}" ] || die "wm size is $EFFECTIVE_SIZE, expected ${WIDTH}x${HEIGHT}"
  [ "$EFFECTIVE_DENSITY" = "$DPI" ] || die "wm density is $EFFECTIVE_DENSITY, expected $DPI"

  if [ "$PROFILE" = "gate" ]; then
    FONT_NOTE="gate proof run: 2.0, restored afterwards"
  else
    FONT_NOTE="pinned; the font-scale proof runs with --profile gate"
  fi

  cat <<EOF
  serial        $SERIAL
  sdk           $SDK
  profile       $PROFILE
  display       ${WIDTH}x${HEIGHT} px
  density       ${DPI} dpi ($DENSITY)
  font scale    ${FONT_SCALE} ($FONT_NOTE)
  locale        $CURRENT_LOCALE
  theme         light (PdshTheme(darkTheme = false), no action bar)
  backdrop      #FFFFFF (harness condition; colors.background is unmeasured)
  system bars   hidden (immersive)
  clock         virtual, frozen at +1000 ms
  animations    window/transition/animator scale = 0
EOF

  rm -rf "$WORK/$PROFILE"
  case "$PROFILE" in
    gate)
      say "capture 11 baselines at fontScale $FONT_SCALE (profile gate)"
      run_instrumentation "gate" -e pdsh.screenshot.profile gate -e class "$GATE_CLASSES"
      ;;
    ios-parity)
      # Always scope to a class list: `am instrument` without `-e class` runs
      # every test in the APK, and the gate suites refuse the parity frame (loudly).
      PARITY_CLASSES_RUN="$(parity_instrument_classes "$PARITY_CLASSES")"
      if [ -n "$STATES" ]; then
        PARITY_CLASSES_RUN="$(state_class_filter "$STATES")"
        echo "  states requested: $STATES"
      fi
      say "capture the CAPTURED parity states at fontScale $FONT_SCALE (profile ios-parity)"
      run_instrumentation "ios-parity" \
        -e pdsh.screenshot.profile ios-parity -e class "$PARITY_CLASSES_RUN"
      ;;
    android-only)
      say "capture the Android-only baselines at fontScale $FONT_SCALE (profile android-only)"
      run_instrumentation "android-only" \
        -e pdsh.screenshot.profile android-only -e class "$ANDROID_ONLY_CLASSES"
      ;;
  esac
  adb_dev shell ls "$DEVICE_SCREENSHOTS/$PROFILE/fs-1.0" >/dev/null 2>&1 \
    || die "the device wrote no captures to $DEVICE_SCREENSHOTS/$PROFILE/fs-1.0"
  # The target must exist first: `adb pull <dir> <missing path>` copies the
  # *contents* into that path instead of creating `<path>/fs-1.0`.
  mkdir -p "$WORK/$PROFILE"
  adb_dev pull "$DEVICE_SCREENSHOTS/$PROFILE/fs-1.0" "$WORK/$PROFILE" >/dev/null

  if [ "$PROFILE" = "gate" ]; then
    # ------------------------------------------------------------ font proof
    say "font scale proof (system font_scale 1.0 vs 2.0, same probe)"
    adb_dev shell settings put system font_scale 2.0
    sleep 1
    adb_dev shell rm -rf "$DEVICE_SCREENSHOTS/$PROFILE/fs-2.0"
    run_instrumentation "2.0" -e pdsh.screenshot.profile gate -e class "$PROBE_CLASS"
    adb_dev pull "$DEVICE_SCREENSHOTS/$PROFILE/fs-2.0" "$WORK/$PROFILE" >/dev/null
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

    M1="$WORK/$PROFILE/fs-1.0/metrics.txt"
    M2="$WORK/$PROFILE/fs-2.0/metrics.txt"
    [ -f "$M1" ] || die "missing $M1"
    [ -f "$M2" ] || die "missing $M2"
    BOX1="$(metric_value "$M1" fontscale-probe textBoxHeightPx)"
    BOX2="$(metric_value "$M2" fontscale-probe textBoxHeightPx)"
    FS1="$(metric_value "$M1" fontscale-probe fontScale)"
    FS2="$(metric_value "$M2" fontscale-probe fontScale)"
    INK1="$(python3 "$COMPARE" ink --image "$WORK/$PROFILE/fs-1.0/fontscale-probe.png" | sed -n 's/.*ink_height=\([0-9]*\).*/\1/p')"
    INK2="$(python3 "$COMPARE" ink --image "$WORK/$PROFILE/fs-2.0/fontscale-probe.png" | sed -n 's/.*ink_height=\([0-9]*\).*/\1/p')"
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
  elif [ "$PROFILE" = "ios-parity" ]; then
    # ---------------------------------------------------------- registry check
    say "verify the 27-state registry against the iOS baseline directory"
    [ -f "$PULLED/parity-registry.txt" ] || die "the device did not write parity-registry.txt"
    if [ -n "$STATES" ]; then REGISTRY_REQUIRE_ALL=0; else REGISTRY_REQUIRE_ALL=1; fi
    check_parity_registry "$PULLED/parity-registry.txt" "$PULLED" "$REGISTRY_REQUIRE_ALL" \
      || die "the parity registry does not match the iOS baseline"
    # The parity frame is asserted per capture by the harness; assert it again from
    # the pulled metrics, so a baseline cannot be written from a mis-set display.
    grep -q "profile=ios-parity width=${BASELINE_WIDTH_PX} height=${BASELINE_HEIGHT_PX} dpi=${BASELINE_DENSITY_DPI}" \
      "$PULLED/metrics.txt" \
      || die "the pulled metrics do not carry the ${BASELINE_WIDTH_PX}x${BASELINE_HEIGHT_PX} @ ${BASELINE_DENSITY_DPI}dpi frame"
    if [ -n "$STATES" ]; then
      # A --states run must write exactly the states it named: a wrong
      # class#method mapping would otherwise capture nothing and still "pass".
      IFS=',' read -r -a requested_states <<<"$STATES"
      expected_pngs=0
      for state in "${requested_states[@]}"; do
        [ -n "$state" ] || continue
        expected_pngs=$((expected_pngs + 1))
        [ -f "$PULLED/$state.png" ] \
          || die "--states '$state' wrote no '$state.png'; the class#method mapping is wrong"
      done
      written_pngs="$(find "$PULLED" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
      [ "$written_pngs" = "$expected_pngs" ] \
        || die "--states wrote $written_pngs PNGs, expected $expected_pngs"
      echo "  states verified: $written_pngs/$expected_pngs requested PNGs written"
    fi
  else
    # android-only: the gate frame, its own receipt (no iOS counterpart to check).
    grep -q "profile=android-only width=$GATE_WIDTH_PX height=$GATE_HEIGHT_PX dpi=$GATE_DPI" \
      "$PULLED/metrics.txt" \
      || die "the pulled metrics do not carry the android-only ${GATE_WIDTH_PX}x${GATE_HEIGHT_PX} @ ${GATE_DPI}dpi frame"
    echo "  android-only captures: $(find "$PULLED" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ') PNGs at ${GATE_WIDTH_PX}x${GATE_HEIGHT_PX} @ ${GATE_DPI}dpi"
  fi

  # ---------------------------------------------------------------- compare
  say "compare (profile $PROFILE)"
  mkdir -p "$WORK/$PROFILE/diff"
  if [ "$UPDATE" = "1" ]; then
    mkdir -p "$BASELINE"
    if [ "$PROFILE" = "ios-parity" ] && [ -f "$BASELINE/parity-registry.txt" ]; then
      # The registry is the contract: an update may add a state, never drop one
      # silently. (A suite that published only the 27 parity rows once cost the
      # androidOnly rows; the host would have read "0 androidOnly states".)
      python3 - "$BASELINE/parity-registry.txt" "$PULLED/parity-registry.txt" <<'PYREG'
import sys

def names(path):
    return {
        line.split("|")[1]
        for line in open(path, encoding="utf-8").read().splitlines()
        if line.strip()
    }

old, new = names(sys.argv[1]), names(sys.argv[2])
lost = sorted(old - new)
if lost:
    raise SystemExit(
        "FAIL: the new registry drops states the baselines already registered: "
        f"{lost}. Add them back (a PENDING state is still registered); delete the "
        "old registry by hand only if the iOS baseline set really changed."
    )
print(f"  registry: {len(old)} -> {len(new)} states, nothing dropped")
PYREG
    fi
    cp "$PULLED/"*.png "$BASELINE/"
    if [ -n "$STATES" ]; then
      # A --states pass rewrote only a subset; replacing the conditions receipt
      # with 3 of its 21 lines would describe less than the directory holds.
      echo "  metrics.txt left as-is: a --states pass does not own the full receipt"
    else
      cp "$PULLED/metrics.txt" "$BASELINE/metrics.txt"
      chmod 644 "$BASELINE/metrics.txt"
    fi
    # adb pull keeps the device's 0600 mode; repository files are 0644.
    chmod 644 "$BASELINE"/*.png
    if [ -f "$PULLED/parity-registry.txt" ]; then
      cp "$PULLED/parity-registry.txt" "$BASELINE/parity-registry.txt"
      chmod 644 "$BASELINE/parity-registry.txt"
    fi
    echo "baselines updated ($PROFILE): $(ls "$BASELINE"/*.png | wc -l | tr -d ' ') PNGs in ${BASELINE#"$ROOT/"}/"
  else
    [ -d "$BASELINE" ] || die "no $PROFILE baseline directory at ${BASELINE#"$ROOT/"} (run with --update first)"
    COMPARE_BASELINE="$BASELINE"
    if [ -n "$STATES" ]; then
      # The pass wrote only the requested states, so compare exactly those. The
      # full baseline would otherwise report the other states as "missing
      # capture" (extra captures are still an error, so the subset cannot drift).
      COMPARE_BASELINE="$WORK/$PROFILE/subset-baseline"
      rm -rf "$COMPARE_BASELINE"
      mkdir -p "$COMPARE_BASELINE"
      IFS=',' read -r -a requested_states <<<"$STATES"
      for state in "${requested_states[@]}"; do
        [ -n "$state" ] || continue
        [ -f "$BASELINE/$state.png" ] \
          || die "no baseline for '$state' at ${BASELINE#"$ROOT/"}/$state.png (run --update first)"
        cp "$BASELINE/$state.png" "$COMPARE_BASELINE/$state.png"
      done
      echo "  subset compare: $(find "$COMPARE_BASELINE" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ') requested baselines"
    fi
    set +e
    python3 "$COMPARE" compare \
      --baseline "$COMPARE_BASELINE" \
      --actual "$PULLED" \
      --diff-dir "$WORK/$PROFILE/diff" \
      --summary "$WORK/$PROFILE/compare.txt"
    COMPARE_STATUS=$?
    set -e
    [ "$COMPARE_STATUS" = "0" ] || die "pixel regression detected; see android/build/screenshots-work/$PROFILE/diff/"
  fi
done

if [ "$PDSH_SHOT_KEEP" != "1" ]; then
  rm -rf "$WORK"/gate/fs-1.0 "$WORK"/gate/fs-2.0 "$WORK"/gate/diff
  rm -rf "$WORK"/ios-parity/fs-1.0 "$WORK"/ios-parity/diff
  rm -rf "$WORK"/android-only/fs-1.0 "$WORK"/android-only/diff
fi

# ---------------------------------------------------------------- receipt
say "done"
cat <<'EOF'
Proven (gate): a UI change that moves pixels is caught by this baseline, and the
capture chain renders real glyph metrics (font-scale probe).
Proven (ios-parity): Android renders the registered iOS state names whose lane has
frozen them, in the official 402x874@3 frame; each captured state is compared
against Android's own previous capture, and the registry check refuses a PNG whose
row is not `captured` (so a PENDING page cannot be frozen by accident).
Proven (android-only): the Android-only pages/surfaces do not drift between
commits either; they are a self-regression baseline with no iOS counterpart, and
they are kept out of the 11 historical gate baselines on purpose.
NOT proven: that Android matches the iOS baseline. The gate baseline is generated
from the current Android implementation, and the parity capture is a same-frame
capture, not a pixel-parity proof: CoreText and Minikin/HarfBuzz rasterise
differently and the two systems draw different chrome. Do not diff iOS against
Android pixel by pixel; compare the two PNGs by eye, state by state.
NOT proven (android-only): any cross-platform claim at all — those states were
never in the iOS baseline set.
EOF
