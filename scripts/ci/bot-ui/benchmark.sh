#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# BotFish renderer benchmark. Builds the capture app (DEBUG) and runs
# `BotFishBenchmark` in the simulator; no UI tests are involved.
#
# usage: bash scripts/ci/bot-ui/benchmark.sh [--out DIR] [--device UDID]
#
# The measured entry point is `BotFishEngine.advance`, i.e. the same call the
# SwiftUI TimelineView makes once per animation frame.

set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
OUT="${BOT_UI_BENCH_OUT:-/tmp/fishperf-bench}"
DEVICE_ID="${BOT_UI_DEVICE_ID:-}"
DERIVED="${BOT_UI_BENCH_DERIVED:-/tmp/fishperf-dd}"
PKG_CACHE="${BOT_UI_BENCH_PKG_CACHE:-/tmp/fishperf-pkgcache}"

while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            [ $# -ge 2 ] || { echo "--out needs a directory" >&2; exit 2; }
            OUT="$2"
            shift 2
            ;;
        --device)
            [ $# -ge 2 ] || { echo "--device needs a simulator UDID" >&2; exit 2; }
            DEVICE_ID="$2"
            shift 2
            ;;
        -h|--help)
            echo "usage: bash scripts/ci/bot-ui/benchmark.sh [--out DIR] [--device UDID]"
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

for tool in xcodegen xcodebuild xcrun python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 2; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/phonedsh-bot-ui-bench.XXXXXX")
CREATED_DEVICE=0
cleanup() {
    if [ "$CREATED_DEVICE" = 1 ] && [ -n "$DEVICE_ID" ]; then
        xcrun simctl shutdown "$DEVICE_ID" >/dev/null 2>&1 || true
        xcrun simctl delete "$DEVICE_ID" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

mkdir -p "$WORK/Sources" "$OUT" "$PKG_CACHE" "$WORK/home"
cp -R "$ROOT/examples/probe-app/PhoneDSHProbe/Bot" "$WORK/Sources/Bot"
cp -R "$ROOT/examples/probe-app/BotFish" "$WORK/BotFish"
REL_ROOT=$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$ROOT" "$WORK")
for file in NativeParityTokens.swift HomeSpec.swift NativeChatPreferences.swift HeaderActionPill.swift; do
    if [ -f "$ROOT/examples/probe-app/PhoneDSHProbe/$file" ]; then
        cp "$ROOT/examples/probe-app/PhoneDSHProbe/$file" "$WORK/Sources/$file"
    fi
done
cp "$ROOT/scripts/ci/bot-ui/CaptureDependencies.swift" "$WORK/Sources/CaptureDependencies.swift"
cp "$ROOT/scripts/ci/bot-ui/CaptureApp.swift" "$WORK/Sources/CaptureApp.swift"
cp "$ROOT/scripts/ci/bot-ui/BotFishBench.swift" "$WORK/Sources/BotFishBench.swift"

cat >"$WORK/project.yml" <<YAML
# SPDX-License-Identifier: MIT
name: PhoneDSHBotUIBench
options:
  bundleIdPrefix: dev.phone-dsh.bot-ui
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "5.0"
    IPHONEOS_DEPLOYMENT_TARGET: "17.0"
    TARGETED_DEVICE_FAMILY: "1"
    CODE_SIGNING_ALLOWED: NO
    GENERATE_INFOPLIST_FILE: YES
    INFOPLIST_KEY_UILaunchScreen_Generation: YES
packages:
  PhoneDSH:
    path: $REL_ROOT
targets:
  PhoneDSHBotUIBench:
    type: application
    platform: iOS
    sources:
      - path: Sources
        excludes:
          - "Bot/BotProductionPage.swift"
          - "Bot/BotProductionServices.swift"
          - "Bot/BotProductionUIAdapters.swift"
          - "Bot/BotRuntimeComposition.swift"
          - "Bot/BotRuntimeEffects.swift"
      - path: BotFish
        type: folder
        buildPhase: resources
    dependencies:
      - package: PhoneDSH
        product: PhoneDSHAgentCore
      - package: PhoneDSH
        product: PhoneDSHBot
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.phone-dsh.bot-ui.capture
        PRODUCT_NAME: PhoneDSHBotUIBench
schemes:
  PhoneDSHBotUIBench:
    build:
      targets:
        PhoneDSHBotUIBench: all
    run:
      config: Debug
YAML

xcodegen generate --quiet --spec "$WORK/project.yml" --project "$WORK" --project-root "$WORK"

if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID=$(xcrun simctl create "PhoneDSH Bot Fish Bench" "iPhone 17 Pro")
    CREATED_DEVICE=1
fi
xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null

PROJECT="$WORK/PhoneDSHBotUIBench.xcodeproj"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/PhoneDSHBotUIBench.app"
if ! CFFIXED_USER_HOME="$WORK/home" HOME="$WORK/home" \
    xcodebuild -project "$PROJECT" -scheme PhoneDSHBotUIBench \
        -configuration Debug -destination "platform=iOS Simulator,id=$DEVICE_ID" \
        -derivedDataPath "$DERIVED" \
        -clonedSourcePackagesDirPath "$DERIVED/SourcePackages" \
        -packageCachePath "$PKG_CACHE" \
        CODE_SIGNING_ALLOWED=NO \
        OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' build > "$OUT/build.log" 2>&1; then
    tail -40 "$OUT/build.log" >&2
    echo "benchmark build FAILED (log: $OUT/build.log)" >&2
    exit 1
fi
[ -d "$APP" ] || { echo "benchmark app missing at $APP" >&2; exit 1; }

xcrun simctl install "$DEVICE_ID" "$APP"
xcrun simctl terminate "$DEVICE_ID" dev.phone-dsh.bot-ui.capture >/dev/null 2>&1 || true
CONTAINER=$(xcrun simctl get_app_container "$DEVICE_ID" dev.phone-dsh.bot-ui.capture data)
STARTED=$(python3 -c 'import time; print(time.time())')
xcrun simctl launch "$DEVICE_ID" dev.phone-dsh.bot-ui.capture \
    -BotFishBench -BotFishBenchMarker "$STARTED" \
    -BotUIFixture empty -BotUIAppearance light >/dev/null

RESULT="$CONTAINER/Documents/bot-fish-bench.json"
READY=0
for _ in $(seq 1 480); do
    if [ -s "$RESULT" ] && python3 - "$RESULT" "$STARTED" <<'PY'
import json
import sys
try:
    result = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(1)
if str(result.get("marker", "")) != str(sys.argv[2]):
    raise SystemExit(1)
PY
    then
        READY=1
        break
    fi
    python3 -c 'import time; time.sleep(0.25)'
done
if [ "$READY" != 1 ]; then
    echo "benchmark produced no matching result at $RESULT" >&2
    exit 1
fi
cp "$RESULT" "$OUT/bot-fish-bench.json"
python3 - "$OUT/bot-fish-bench.json" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
print(f"BotFish benchmark {result['status']} "
      f"({result['platform']}, {result['device']} {result['systemVersion']}, "
      f"{result['framesPerConfiguration']} frames/config)")
print(f"{'config':<16}{'mean ms/frame':>15}{'render ms/frame':>18}{'frames/s':>11}")
for item in result["configurations"]:
    print(f"{item['name']:<16}{item['meanFrameMs']:>15.3f}"
          f"{item['renderOnlyMeanFrameMs']:>18.3f}{item['framesPerSecond']:>11.1f}")
PY
echo "wrote $OUT/bot-fish-bench.json"
