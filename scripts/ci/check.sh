#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# phone-dsh CI gate — shared by local runs and GitHub Actions.
#
#   bash scripts/ci/check.sh                       # run every stage
#   bash scripts/ci/check.sh --only firmware-host,license
#   bash scripts/ci/check.sh --list
#
# Each stage reports PASS / FAIL / SKIP; the script exits non-zero if any
# stage FAILs. See scripts/ci/README.md for the environment knobs.
#
# Compatible with bash 3.2 (macOS /bin/bash) and newer.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FW="$ROOT/firmware"
SDK="$ROOT"
IOS_APP="$ROOT/examples/ios-reference-app"

PYTHON=${PYTHON:-python3}
CI_TMP=${CI_TMP:-${TMPDIR:-/tmp}}
CI_TMP=${CI_TMP%/}/phone-dsh-ci
IDF_VERSION_WANT=${CI_IDF_VERSION:-5.5.2}
IOS_RUNTIME=${CI_IOS_RUNTIME:-26.5}

if [ -z "${PDSH_DSH_CHECKOUT:-}" ] && [ -f "$HOME/.config/phone-dsh/dsh-checkout" ]; then
    PDSH_DSH_CHECKOUT=$(head -n1 "$HOME/.config/phone-dsh/dsh-checkout" | tr -d '\r')
fi
if [ -n "${PDSH_DSH_CHECKOUT:-}" ]; then
    export PDSH_DSH_CHECKOUT
fi

STAGES="phone-spec phone-plugins phone-image phone-sdk phone-no-dsh-patch phone-hygiene phone-license phone-modules phone-gate-contracts phone-xcode-resolve"

stage_desc() {
    case "$1" in
        phone-spec)            echo "spec/v1 golden vectors and schemas (SKIP if absent)" ;;
        phone-plugins)         echo "plugins npm run typecheck + npm test (SKIP without node_modules)" ;;
        phone-image)           echo "plugins pack-image.mjs against the pinned DSH checkout (SKIP without node_modules or checkout)" ;;
        phone-sdk)             echo "swift test over the module unit-test targets and PhoneDSH unit classes (SKIP without PhoneWire)" ;;
        phone-no-dsh-patch)    echo "no @deepseek-ai patches or vendored DSH definitions; dsh-pin.json" ;;
        phone-hygiene)         echo "public-repo hygiene scan of the phone-DSH roots" ;;
        phone-license)         echo "SPDX MIT headers and plugins package licenses" ;;
        phone-modules)         echo "Package.swift dependency map of the 8 phone-DSH modules (SKIP without PhoneWire)" ;;
        phone-gate-contracts)  echo "Python regressions for scenario batch/evidence and gate contracts" ;;
        phone-xcode-resolve)   echo "xcodegen + Xcode package resolution of examples/probe-app (no simulator; SKIP if XcodeGen is absent)" ;;
        *)                     return 1 ;;
    esac
}

usage() {
    cat <<EOF
usage: bash scripts/ci/check.sh [--only stage[,stage...]] [--list] [-h]

stages (run in this order):
EOF
    for s in $STAGES; do printf '  %-22s %s\n' "$s" "$(stage_desc "$s")"; done
    cat <<EOF

environment:
  CI_SKIP_IDF=1          skip both firmware-build-* stages
  IDF_PATH / CI_IDF_EXPORT  ESP-IDF location / explicit export.sh to source
  CI_IOS_RUNTIME         iOS simulator runtime version (default 26.5)
  CI_IOS_SIMULATOR       simulator name to use (default: first available iPhone)
  CI_IOS_SCHEME          Xcode scheme (default: first scheme of the project)
  CI_SIZE_BUDGET_ARGS    extra args appended to each size_budget.py call
  CI_ALLOW_WARNINGS=1    do not fail firmware builds on compiler warnings

phone-DSH stages:
  The phone-* checkers live in scripts/ci/ and each accepts --root DIR.
EOF
}

# ---------------------------------------------------------------- arguments
ONLY=""
ONLY_SET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list) for s in $STAGES; do printf '%-22s %s\n' "$s" "$(stage_desc "$s")"; done; exit 0 ;;
        --only) [ $# -ge 2 ] || { echo "--only needs a value" >&2; exit 2; }; ONLY="$2"; ONLY_SET=1; shift 2 ;;
        --only=*) ONLY="${1#--only=}"; ONLY_SET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

SELECTED="$STAGES"
if [ "$ONLY_SET" = 1 ]; then
    req=$(echo "$ONLY" | tr ',' ' ')
    [ -n "$(echo "$req" | tr -d '[:space:]')" ] || { echo "--only needs at least one stage" >&2; exit 2; }
    for r in $req; do
        stage_desc "$r" >/dev/null || { echo "unknown stage: $r (see --list)" >&2; exit 2; }
    done
    SELECTED=""
    for s in $STAGES; do   # keep canonical order (builds before size-budget)
        for r in $req; do [ "$s" = "$r" ] && SELECTED="$SELECTED $s"; done
    done
    [ -n "$(echo "$SELECTED" | tr -d '[:space:]')" ] || { echo "--only selected no stages" >&2; exit 2; }
fi

# ---------------------------------------------------------------- helpers
SKIP_FILE="$CI_TMP/skip-reason.$$"
mkdir -p "$CI_TMP"

log()  { echo "[ci] $*"; }
# Stages run in a subshell, so warnings go through a file the runner collects.
WARN_FILE="$CI_TMP/warn.$$"
warn() { echo "[ci] WARN: $*"; printf '\n  WARN  %s' "$*" >> "$WARN_FILE"; }
# A stage function calls `skip "reason"` and returns; the runner turns it into SKIP.
skip() { echo "$*" > "$SKIP_FILE"; return 77; }

# Locate an ESP-IDF export script and source it (only inside a stage subshell).

# firmware_build <board> <Kconfig symbol> <require-overlay:0|1>

# ---------------------------------------------------------------- stages


# Print "name|udid" of the simulator to use.



stage_phone_spec() {
    spec="$ROOT/spec/v1"
    [ -d "$spec" ] || { skip "spec/v1 not present"; return; }
    [ -f "$spec/tools/spec_golden.py" ] || { skip "spec/v1/tools/spec_golden.py not present"; return; }
    ( cd "$ROOT" && "$PYTHON" spec/v1/tools/spec_golden.py )
}

stage_phone_plugins() {
    [ -d "$ROOT/plugins" ] || { skip "plugins not present"; return; }
    [ -d "$ROOT/plugins/node_modules" ] || { skip "plugins/node_modules not installed"; return; }
    command -v npm >/dev/null 2>&1 || { echo "npm not found"; return 1; }
    ( cd "$ROOT/plugins" && npm run typecheck && npm test )
}

stage_phone_image() {
    [ -d "$ROOT/plugins/node_modules" ] || { skip "plugins/node_modules not installed"; return; }
    command -v node >/dev/null 2>&1 || { echo "node not found"; return 1; }
    checkout="${PDSH_DSH_CHECKOUT:-}"
    if [ -z "$checkout" ] && [ -f "$HOME/.config/phone-dsh/dsh-checkout" ]; then checkout=$(head -n1 "$HOME/.config/phone-dsh/dsh-checkout"); fi
    [ -n "$checkout" ] || { skip "no pinned DSH checkout: set PDSH_DSH_CHECKOUT or write its path to ~/.config/phone-dsh/dsh-checkout"; return; }
    [ -d "$checkout" ] || { echo "DSH checkout not found: $checkout"; return 1; }
    out="$CI_TMP/phone-image-$$"
    mkdir -p "$out"
    # The Worker image must actually pack: every staged plugin resolvable, every export face lowered.
    ( cd "$ROOT/plugins" && PDSH_DSH_CHECKOUT="$checkout" node scripts/pack-image.mjs --out "$out" ) || return 1
    for f in image.tar.gz worker.js client.js manifest.json sizes.json; do
        [ -s "$out/$f" ] || { echo "pack-image left $f missing or empty in $out"; return 1; }
    done
    log "image written to $out ($(du -sh "$out" | cut -f1))"
}

stage_phone_sdk() {
    [ -d "$SDK/Sources/PhoneDSHWire" ] || { skip "Sources/PhoneDSHWire not present"; return; }
    command -v swift >/dev/null 2>&1 || { echo "swift toolchain not found"; return 1; }
    sdk_log="$CI_TMP/phone-sdk.log"
    # Unit-test classes live in targets named after their module (PhoneDSH*Tests) or in the PhoneDSH* targets; the
    # latter mix plain unit tests with runner entry points that need scenarios.sh / sim.sh (PhoneDSHScenarioTests.PhoneDSHScenarioTests,
    # the smoke/probe/kill suites), so they are listed by class here. A new unit-test class in a PhoneDSH* target must either be
    # named PhoneDSH* or be added to this filter, otherwise no gate executes it.
    sdk_filter='PhoneDSH(Wire|Log|Loopback|Gateway|Controller|Engine|Harness|Shell|AgentCore)Tests|PhoneDSHTests|PhoneDSHScenario[A-Z][A-Za-z]*Tests|PhoneDSHScenarioTestsSelectionGuard|PhoneDSHScenarioLibraryContractTests|ScenarioHostEvaluationTests|ScenarioRepositoryRootTests|ScenarioEvidenceArtifactTests|ScenarioDetailTruncationTests|PhoneDSHScenarioTestsBudgetInjection|PhoneDSHScenarioTestsWebContentKill|PhoneDSHScenarioTestsPerturbationCapabilities|ZPhoneDSHAbortStopDurabilityHostTests'
    recovery_probe='PhoneDSHTests.BigFileBudgetTests/testHostReplayMemoryPeakForSixtyFourMiBFileIsBounded'
    ( cd "$SDK" && swift test --disable-automatic-resolution --filter "$sdk_filter" --skip "$recovery_probe" ) 2>&1 | tee "$sdk_log"
    rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || { echo "swift test failed (rc=$rc)"; return 1; }
    executed=$(grep -Eo 'Executed [0-9]+ tests?' "$sdk_log" | awk '{print $2}' | sort -n | tail -1)
    [ -n "$executed" ] || { echo "no XCTest 'Executed N tests' line in $sdk_log"; return 1; }
    [ "$executed" -gt 0 ] || { echo "swift test --filter matched 0 tests"; return 1; }
    log "executed $executed test(s)"
    recovery_log="$CI_TMP/phone-sdk-recovery-release.log"
    # Measure the shipping artifact, not debug-code overhead. The same test
    # retains its original memory and wall-clock budgets; it is never skipped.
    ( cd "$SDK" && swift test -c release --filter "$recovery_probe" ) 2>&1 | tee "$recovery_log"
    rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || { echo "swift release recovery test failed (rc=$rc)"; return 1; }
    grep -Eq 'Executed 1 test,' "$recovery_log" || { echo "release recovery probe did not execute"; return 1; }
    log "release recovery probe passed with its original budgets"
}

stage_phone_no_dsh_patch() {
    "$PYTHON" "$ROOT/scripts/ci/no_dsh_patch.py" --root "$ROOT"
}

stage_phone_hygiene() {
    "$PYTHON" "$ROOT/scripts/ci/hygiene.py" --root "$ROOT"
}

stage_phone_license() {
    "$PYTHON" "$ROOT/scripts/ci/license.py" --root "$ROOT"
}

stage_phone_modules() {
    [ -d "$SDK/Sources/PhoneDSHWire" ] || { skip "Sources/PhoneDSHWire not present"; return; }
    "$PYTHON" "$ROOT/scripts/ci/modules.py" --root "$ROOT"
}

stage_phone_gate_contracts() {
    # Stages run without `set -e`: each command must carry its own status.
    "$PYTHON" "$ROOT/scripts/ci/scenario_evidence_test.py" || return 1
    "$PYTHON" "$ROOT/scripts/ci/scenario_batch_test.py" || return 1
    "$PYTHON" "$ROOT/scripts/ci/gates_test.py" || return 1
    "$PYTHON" "$ROOT/scripts/ci/selftest.py" || return 1
}

# G2-FIX-22: Xcode's package resolver rejects a test target that depends on
# another test target even though the SwiftPM command line accepts that graph,
# so `swift test` passing is not enough for the probe project. This stage
# regenerates the project and resolves its package graph without booting a
# simulator; it is fast enough for every task gate that touches
# Package.swift, Tests/PhoneDSH* or examples/probe-app/**.
stage_phone_xcode_resolve() {
    [ -f "$ROOT/examples/probe-app/project.yml" ] \
        || { skip "examples/probe-app/project.yml not present"; return; }
    command -v xcodegen >/dev/null 2>&1 \
        || { skip "xcodegen is not installed"; return; }
    command -v xcodebuild >/dev/null 2>&1 \
        || { skip "xcodebuild is not installed"; return; }
    OUT="${CI_TMP%/}/pdsh-xcode-resolve" \
        bash "$ROOT/scripts/ci/xcode-resolve.sh" --root "$ROOT"
}

# ---------------------------------------------------------------- runner
RESULTS=""
FAILED=0
SKIPPED=0
WARNINGS=""
for s in $SELECTED; do
    fn="stage_$(echo "$s" | tr '-' '_')"
    echo
    echo "================================================================"
    echo "== stage: $s — $(stage_desc "$s")"
    echo "================================================================"
    rm -f "$SKIP_FILE"
    t0=$(date +%s)
    # Subshell: stages that source ESP-IDF must not leak their environment.
    ( set -o pipefail; "$fn" )
    rc=$?
    dt=$(( $(date +%s) - t0 ))
    if [ $rc = 77 ] && [ -f "$SKIP_FILE" ]; then
        st=SKIP; why=$(cat "$SKIP_FILE"); SKIPPED=1
    elif [ $rc = 0 ]; then
        st=PASS; why=""
    else
        st=FAIL; why="exit $rc"; FAILED=1
    fi
    # Pick up WARN lines emitted inside the subshell.
    [ -f "$WARN_FILE" ] && { WARNINGS="$WARNINGS
$(cat "$WARN_FILE")"; rm -f "$WARN_FILE"; }
    echo "== $st: $s (${dt}s)${why:+ — $why}"
    RESULTS="$RESULTS
$(printf '  %-5s %-22s %5ss  %s' "$st" "$s" "$dt" "$why")"
done
rm -f "$SKIP_FILE"

echo
echo "================================================================"
echo "== summary"
echo "$RESULTS" | sed '/^$/d'
[ -n "$WARNINGS" ] && echo "$WARNINGS" | sed '/^$/d'
if [ $FAILED != 0 ]; then
    echo "== CI GATE: FAIL"
    exit 1
elif [ $SKIPPED != 0 ]; then
    echo "== CI GATE: INCOMPLETE (optional stages skipped; not a release PASS)"
    exit 2
else
    echo "== CI GATE: PASS"
    exit 0
fi
