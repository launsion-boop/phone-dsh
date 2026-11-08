#!/bin/bash
# SPDX-License-Identifier: MIT
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SIMULATOR=0
SCENARIO="conversation-card-approval-routine-held"
RUN_ID="run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUT="${TMPDIR:-/tmp}/phonedsh-bot-e2e/$RUN_ID"

usage() {
  cat <<'EOF'
Usage: bash scripts/ci/bot-e2e/run.sh --simulator --scenario conversation-card-approval-routine-held
       bash scripts/ci/bot-e2e/run.sh --simulator --scenario ledger

The scripted upstream runs first. --simulator then runs the same sources in an
isolated iOS Simulator test bundle. No real model, external account, physical
device, or WP1 residency result is inferred from these runs.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --simulator) SIMULATOR=1; shift ;;
    --scenario)
      [ "$#" -ge 2 ] || { echo "bot-e2e: --scenario needs a value" >&2; exit 2; }
      SCENARIO="$2"; shift 2 ;;
    --output-dir)
      [ "$#" -ge 2 ] || { echo "bot-e2e: --output-dir needs a value" >&2; exit 2; }
      OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "bot-e2e: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$SCENARIO" in
  conversation-card-approval-routine-held|ledger|production-composition) ;;
  *) echo "bot-e2e: unsupported scenario $SCENARIO" >&2; exit 2 ;;
esac
mkdir -p "$OUT"

write_result() {
  local status="$1" simulator_status="$2" reason="$3"
  python3 - "$OUT/result.json" "$status" "$simulator_status" "$SCENARIO" "$reason" <<'PY'
import json
import sys
path, status, simulator, scenario, reason = sys.argv[1:]
json.dump({
    "status": status,
    "scenario": scenario,
    "scriptedUpstream": "$SCRIPTED_UPSTREAM",
    "simulator": simulator,
    "realModel": "NOT_RUN",
    "externalAccounts": "NOT_RUN",
    "physicalDevice": "NOT_RUN",
    "wp1Residency": "NOT_RUN",
    "detail": reason,
}, open(path, "w"), indent=2, sort_keys=True)
PY
}

not_run() {
  local reason="$1"
  write_result "NOT_RUN" "NOT_RUN" "$reason"
  echo "== BOT E2E: NOT_RUN =="
  echo "$reason"
  echo "evidence: $OUT/result.json"
  exit 3
}

fail() {
  local reason="$1"
  write_result "FAIL" "FAIL" "$reason"
  echo "== BOT E2E: FAIL =="
  echo "$reason"
  echo "evidence: $OUT/result.json"
  exit 1
}

SCRIPTED_UPSTREAM=PASS
if [ "$SCENARIO" = "ledger" ]; then
  SIMULATOR_TEST='BotDSHRemoteRuntimeTests/testRealTurnWritesEveryUsageFieldToSQLiteLedger'
  swift test --filter "$SIMULATOR_TEST" \
    > "$OUT/scripted-upstream.log" 2>&1 || fail "scripted ledger test failed; see $OUT/scripted-upstream.log"
elif [ "$SCENARIO" = "production-composition" ]; then
  SIMULATOR_TEST='BotCompositionE2ETests/testProductionCompositionUsesRealHostAndWorker'
  SCRIPTED_UPSTREAM=NOT_RUN
else
  SIMULATOR_TEST='BotConversationE2ETests/testConversationCardApprovalRoutineAndHeldDelivery'
  swift test --filter BotConversationE2ETests \
    > "$OUT/scripted-upstream.log" 2>&1 || fail "scripted conversation E2E failed; see $OUT/scripted-upstream.log"
fi

if [ "$SIMULATOR" -ne 1 ]; then
  write_result "PASS" "NOT_RUN" "simulator was not requested"
  echo "== BOT E2E: PASS (scripted upstream only) =="
  exit 0
fi

for command in xcodegen xcodebuild xcrun python3; do
  command -v "$command" >/dev/null 2>&1 || not_run "$command is unavailable"
done

xcrun simctl list devices available -j > "$OUT/devices.json" 2>&1 \
  || not_run "could not enumerate iOS Simulators"
UDID="$(python3 - "$OUT/devices.json" <<'PY'
import json
import sys
try:
    document = json.load(open(sys.argv[1], encoding="utf-8"))
    for runtime, devices in document.get("devices", {}).items():
        if "iOS" not in runtime:
            continue
        for device in devices:
            if device.get("isAvailable") and "iPhone" in device.get("name", ""):
                print(device["udid"])
                raise SystemExit(0)
except Exception:
    pass
PY
)"
[ -n "$UDID" ] || not_run "no available iPhone Simulator"

xcodegen generate --spec "$HERE/app/project.yml" > "$OUT/xcodegen.log" 2>&1 \
  || fail "xcodegen failed; see $OUT/xcodegen.log"

xcodebuild test \
  -project "$HERE/app/BotE2E.xcodeproj" \
  -scheme BotE2EApp \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$OUT/DerivedData" \
  -only-testing:"BotE2ETests/$SIMULATOR_TEST" \
  > "$OUT/simulator.log" 2>&1 \
  || fail "iOS Simulator test failed; see $OUT/simulator.log"

write_result "PASS" "PASS" "scripted upstream and isolated iOS Simulator test bundle passed; no real model was used"
echo "== BOT E2E: PASS =="
echo "simulator: $UDID"
echo "evidence: $OUT/result.json"
