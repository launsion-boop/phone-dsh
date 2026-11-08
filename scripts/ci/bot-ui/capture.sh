#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
OUT="$ROOT/scripts/ci/bot-ui/artifacts"
APPEARANCES="light,dark"
DEVICE_ID="${BOT_UI_DEVICE_ID:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --appearance)
            [ $# -ge 2 ] || { echo "--appearance needs light,dark" >&2; exit 2; }
            APPEARANCES="$2"
            shift 2
            ;;
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
            echo "usage: bash scripts/ci/bot-ui/capture.sh --appearance light,dark [--out DIR] [--device UDID]"
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

case ",$APPEARANCES," in
    *",light,dark,"*|*",dark,light,"*|*",light,"*|*",dark,"*) ;;
    *) echo "--appearance accepts only light,dark" >&2; exit 2 ;;
esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/phonedsh-bot-ui.XXXXXX")
CREATED_DEVICE=0
cleanup() {
    if [ "$CREATED_DEVICE" = 1 ] && [ -n "$DEVICE_ID" ]; then
        xcrun simctl shutdown "$DEVICE_ID" >/dev/null 2>&1 || true
        xcrun simctl delete "$DEVICE_ID" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

mkdir -p "$WORK/Sources" "$WORK/UITests" "$OUT"
ln -s "$ROOT/examples/probe-app/PhoneDSHProbe/Bot" "$WORK/Sources/Bot"
for file in NativeParityTokens.swift HomeSpec.swift NativeChatPreferences.swift; do
    ln -s "$ROOT/examples/probe-app/PhoneDSHProbe/$file" "$WORK/Sources/$file"
done
ln -s "$ROOT/scripts/ci/bot-ui/CaptureApp.swift" "$WORK/Sources/CaptureApp.swift"
ln -s "$ROOT/scripts/ci/bot-ui/CaptureUITests.swift" "$WORK/UITests/CaptureUITests.swift"

cat >"$WORK/project.yml" <<'YAML'
# SPDX-License-Identifier: MIT
name: PhoneDSHBotUICapture
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
targets:
  PhoneDSHBotUICapture:
    type: application
    platform: iOS
    sources:
      - path: Sources
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.phone-dsh.bot-ui.capture
        PRODUCT_NAME: PhoneDSHBotUICapture
  PhoneDSHBotUICaptureUITests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - path: UITests
    dependencies:
      - target: PhoneDSHBotUICapture
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.phone-dsh.bot-ui.capture.uitests
        PRODUCT_NAME: PhoneDSHBotUICaptureUITests
        TEST_TARGET_NAME: PhoneDSHBotUICapture
schemes:
  PhoneDSHBotUICapture:
    build:
      targets:
        PhoneDSHBotUICapture: all
        PhoneDSHBotUICaptureUITests: [test]
    test:
      config: Debug
      targets:
        - PhoneDSHBotUICaptureUITests
    run:
      config: Debug
YAML

xcodegen generate --quiet --spec "$WORK/project.yml" --project "$WORK" --project-root "$WORK"

if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID=$(xcrun simctl create "PhoneDSH Bot WP9 UI" "iPhone 17 Pro")
    CREATED_DEVICE=1
fi

xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE_ID" -b

DESTINATION="platform=iOS Simulator,id=$DEVICE_ID"
PROJECT="$WORK/PhoneDSHBotUICapture.xcodeproj"
DERIVED="$WORK/DerivedData"

xcodebuild -project "$PROJECT" -scheme PhoneDSHBotUICapture \
    -configuration Debug -destination "$DESTINATION" -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO build | tee "$OUT/build.log"

rm -rf "$OUT/BotUI.xcresult"
xcodebuild -project "$PROJECT" -scheme PhoneDSHBotUICapture \
    -configuration Debug -destination "$DESTINATION" -derivedDataPath "$DERIVED" \
    -resultBundlePath "$OUT/BotUI.xcresult" CODE_SIGNING_ALLOWED=NO test | tee "$OUT/ui-tests.log"

APP="$DERIVED/Build/Products/Debug-iphonesimulator/PhoneDSHBotUICapture.app"
[ -d "$APP" ] || { echo "capture app missing at expected build output" >&2; exit 1; }
xcrun simctl install "$DEVICE_ID" "$APP"

CASES="chat question steps task attachment document progress checklist link approval automation error denial overflow failClosed info infoEmpty infoError infoLong"
APPEARANCE_LIST=$(echo "$APPEARANCES" | tr ',' ' ')
CHECKED=0
for APPEARANCE in $APPEARANCE_LIST; do
    mkdir -p "$OUT/$APPEARANCE"
    xcrun simctl ui "$DEVICE_ID" appearance "$APPEARANCE"
    for CASE in $CASES; do
        xcrun simctl terminate "$DEVICE_ID" dev.phone-dsh.bot-ui.capture >/dev/null 2>&1 || true
        xcrun simctl launch "$DEVICE_ID" dev.phone-dsh.bot-ui.capture \
            -BotUIFixture "$CASE" -BotUIAppearance "$APPEARANCE" \
            -BotUICardGolden "$ROOT/spec/bot/v1/golden/card-payload.json" \
            -BotUIRowGolden "$ROOT/spec/bot/v1/golden/row-protocol.json" >/dev/null
        sleep 2
        if [ "$CHECKED" = 0 ]; then
            CONTAINER=$(xcrun simctl get_app_container "$DEVICE_ID" dev.phone-dsh.bot-ui.capture data)
            python3 - "$CONTAINER/Documents/bot-ui-checks.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
if result.get("status") != "PASS":
    raise SystemExit(f"Bot UI conformance checks failed: {result}")
print("Bot UI conformance checks: PASS (" + ", ".join(result.get("checks", [])) + ")")
PY
            CHECKED=1
        fi
        xcrun simctl io "$DEVICE_ID" screenshot "$OUT/$APPEARANCE/$CASE.png" >/dev/null
        [ -s "$OUT/$APPEARANCE/$CASE.png" ] || { echo "empty screenshot: $APPEARANCE/$CASE" >&2; exit 1; }
        echo "captured $APPEARANCE/$CASE.png"
    done
done

python3 - "$OUT" "$APPEARANCES" "$DEVICE_ID" <<'PY'
import json
import os
import sys
out, appearances, device = sys.argv[1:]
cases = "chat question steps task attachment document progress checklist link approval automation error denial overflow failClosed info infoEmpty infoError infoLong".split()
shots = []
for appearance in appearances.split(","):
    for case in cases:
        path = os.path.join(out, appearance, case + ".png")
        shots.append({"appearance": appearance, "case": case, "path": os.path.relpath(path, out), "bytes": os.path.getsize(path)})
result = {
    "status": "PASS",
    "evidence": "iOS Simulator; XCUIApplication interaction tests and simctl screen captures",
    "deviceID": device,
    "conformance": "PASS",
    "interactions": "PASS",
    "screenshots": shots,
}
with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as handle:
    json.dump(result, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
print(f"Bot UI capture: PASS ({len(shots)} screenshots; manifest at {out}/manifest.json)")
PY
