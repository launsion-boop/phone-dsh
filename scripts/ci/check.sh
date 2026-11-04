#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# phone-dsh CI gate — shared by local runs and GitHub Actions.
#
#   bash scripts/ci/check.sh                       # run every stage
#   bash scripts/ci/check.sh --only firmware-host,license
#   bash scripts/ci/check.sh --list
#
# Each stage reports PASS / FAIL / SKIP; the script exits non-zero if any
# stage FAILs. The environment knobs are listed by --help.
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

STAGES="phone-spec phone-p0-conformance phone-cross-tree phone-rust-tests phone-compat phone-plugins phone-bundle-fresh phone-image phone-sdk phone-no-dsh-patch phone-hygiene phone-license phone-modules phone-gate-contracts phone-android-structure phone-android-tests phone-android-release phone-xcode-resolve"

stage_desc() {
    case "$1" in
        phone-spec)            echo "spec/v1 --full golden vectors, schemas and the spec tool unit tests" ;;
        phone-p0-conformance)  echo "Android-port P0 contract trees: catalog, bridge, gateway, trajectory, fixtures, host, platform, ui, page structure" ;;
        phone-cross-tree)      echo "spec/tools/cross_check.py: 8 cross-tree invariants + registry build/check + schema diff + mutation tests" ;;
        phone-rust-tests)      echo "cargo test -p pdsh-wire -p pdsh-wal (SKIP without cargo; aggregate INCOMPLETE)" ;;
        phone-compat)          echo "M99 build-time compatibility gate over the shared TypeScript (PDSH_NODE or node)" ;;
        phone-plugins)         echo "plugins npm run typecheck + npm test (SKIP without node_modules)" ;;
        phone-bundle-fresh)    echo "the worker bundle in examples/probe-app/Bundle/worker is not older than the plugin sources it is built from (FAIL names artifact vs source vs rebuild command; SKIP when the gitignored bundle is absent)" ;;
        phone-image)           echo "plugins pack-image.mjs against the pinned DSH checkout (SKIP without node_modules or checkout)" ;;
        phone-sdk)             echo "swift test over the module unit-test targets and PhoneDSH unit classes (SKIP without PhoneWire)" ;;
        phone-no-dsh-patch)    echo "no @deepseek-ai patches or vendored DSH definitions; dsh-pin.json" ;;
        phone-hygiene)         echo "public-repo hygiene scan of the phone-DSH roots" ;;
        phone-license)         echo "SPDX MIT headers and plugins package licenses" ;;
        phone-modules)         echo "Package.swift dependency map of the 8 phone-DSH modules (SKIP without PhoneWire)" ;;
        phone-gate-contracts)  echo "Python regressions for scenario batch/evidence and gate contracts" ;;
        phone-android-structure) echo "android/tools structure_check (11 checks, incl. nested-comments and the two 16 KB page-alignment gates) + its tool unit tests + the packaged-APK 16 KB gate's mutation suite" ;;
        phone-android-tests)   echo "cargo build -p pdsh-jni, then every test-bearing Gradle module's JVM tests; 0 tests counted = FAIL" ;;
        phone-rust-tests)      echo "cargo test --workspace over shell/: the host read policy, the WAL planner and the accelerators; the JVM suite exercises them through JNI, but the authoritative policy tests live only here" ;;
        phone-android-release) echo "the published com.phonedsh:lib:0.1.0 coordinate (8 artifacts + POM api closure) + the consumer probe resolved from it by coordinate, then assembleRelease + 16 KB proof of the arm64-v8a libpdsh_jni.so and of the .so packaged in the APK (the AAR/publication half never SKIPs; the APK half SKIPs without the gitignored worker bundle/NDK product)" ;;
        phone-xcode-resolve)   echo "xcodegen + Xcode package resolution of examples/probe-app (no simulator; SKIP if XcodeGen is absent)" ;;
        *)                     return 1 ;;
    esac
}

usage() {
    cat <<EOF
usage: bash scripts/ci/check.sh [--only stage[,stage...]] [--list] [-h]

stages (run in this order):
EOF
    for s in $STAGES; do printf '  %-26s %s\n' "$s" "$(stage_desc "$s")"; done
    cat <<EOF

environment:
  CI_SKIP_IDF=1          skip both firmware-build-* stages
  IDF_PATH / CI_IDF_EXPORT  ESP-IDF location / explicit export.sh to source
  CI_IOS_RUNTIME         iOS simulator runtime version (default 26.5)
  CI_IOS_SIMULATOR       simulator name to use (default: first available iPhone)
  CI_IOS_SCHEME          Xcode scheme (default: first scheme of the project)
  CI_SIZE_BUDGET_ARGS    extra args appended to each size_budget.py call
  CI_ALLOW_WARNINGS=1    do not fail firmware builds on compiler warnings

android stages:
  JAVA_HOME              JDK 17+ used by ./gradlew (CI: 21; absent = SKIP, not pass)
  CI_GRADLE_ARGS         extra arguments for ./gradlew (CI sets --no-daemon)
  CI_GRADLE_OFFLINE=1    add --offline to ./gradlew (only after a warm cache)
  CI_ANDROID_SO          arm64-v8a .so inspected by phone-android-release
                         (default shell/target/aarch64-linux-android/debug/libpdsh_jni.so)
  The JVM module list is derived from android/settings.gradle.kts: a module with
  src/test sources is tested, a module without them is not silently counted.

phone-DSH stages:
  CI_PROTOCOL_BASE       schema-diff comparison ref (default: origin/main; must exist locally)
  The phone-* checkers live in scripts/ci/ and each accepts --root DIR.
EOF
}

# ---------------------------------------------------------------- arguments
ONLY=""
ONLY_SET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list) for s in $STAGES; do printf '%-26s %s\n' "$s" "$(stage_desc "$s")"; done; exit 0 ;;
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
    # --full makes the WAL, exec, handoff and budgets documents, the manifest
    # schema and the WAL vectors mandatory. The plain mode passed while
    # budgets.md had drifted away from the token list, so the weaker form is
    # not the gate any more.
    ( cd "$ROOT" && "$PYTHON" spec/v1/tools/spec_golden.py --full ) || return 1
    # The specification's own mutation tests never ran in CI before the Android
    # port; a golden checker that is never mutated is a checker nobody trusts.
    ( cd "$ROOT" && "$PYTHON" -m unittest discover -s spec/v1/tools -p 'test_*.py' )
}

stage_phone_p0_conformance() {
    # The contract trees the Kotlin host reads instead of translating Swift.
    # Each checker is mandatory: a missing checker is a failure, not a skip,
    # because a specification tree without a gate rots into prose.
    for pair in \
        "spec/v1/tools/catalog_check.py|catalog" \
        "spec/v1/tools/bridge_check.py|bridge" \
        "spec/v1/tools/gateway_check.py|gateway" \
        "spec/v1/tools/fixture_check.py|fixtures" \
        "spec/host/v1/tools/host_check.py|host" \
        "spec/platform/tools/platform_check.py|platform" \
        "spec/ui/v1/tools/ui_check.py|ui"
    do
        script="${pair%%|*}"
        name="${pair##*|}"
        [ -f "$ROOT/$script" ] || { echo "missing $name checker: $script"; return 1; }
        ( cd "$ROOT" && "$PYTHON" "$script" --root "$ROOT" ) || return 1
    done
    "$PYTHON" "$ROOT/spec/v1/tools/trajectory_norm.py" --check-golden --root "$ROOT"
    # The page-structure contract (`spec/ui/v1/pages`): every contract is checked
    # against the Android screen it names, and the checker's own mutation tests run
    # next to it. CI runs the known-divergence ratchet (the Android lane has not
    # aligned every page yet); `--strict` prints the full remaining workload.
    page_checker="$ROOT/spec/ui/v1/tools/page_structure_check.py"
    [ -f "$page_checker" ] || { echo "missing page-structure checker: spec/ui/v1/tools/page_structure_check.py"; return 1; }
    ( cd "$ROOT" && "$PYTHON" "$page_checker" --root "$ROOT" \
        --baseline spec/ui/v1/pages/_baseline.json ) || return 1
    ( cd "$ROOT" && "$PYTHON" -m unittest discover -s spec/ui/v1/tools \
        -p 'test_page_structure_check.py' ) || return 1
}

stage_phone_cross_tree() {
    # The eight invariants that only hold across two trees (spec/v1 <-> spec/host,
    # spec/platform <-> host/UI, spec/ui/v1 README <-> tokens.json, ...).  Each tree
    # already has its own checker in phone-p0-conformance; this stage is the seam.
    # A checker nobody runs is prose, and a checker that is always red is noise:
    # so the rc must be 0 and the tool's own mutation tests run next to it.
    #
    # SKIP is only for a checkout that cannot answer the question (no spec/ or a
    # contract tree missing): that reports SKIP 77, never PASS.  A missing tool
    # with every tree present is a failure, like any missing checker above.
    [ -d "$ROOT/spec" ] || { skip "spec/ not present"; return; }
    for tree in spec/v1 spec/host/v1 spec/platform spec/ui/v1; do
        [ -d "$ROOT/$tree" ] || { skip "cross-tree gate needs $tree (not present in this checkout)"; return; }
    done
    [ -f "$ROOT/spec/tools/cross_check.py" ] || { echo "missing checker: spec/tools/cross_check.py"; return 1; }
    ( cd "$ROOT" && "$PYTHON" spec/tools/cross_check.py --root "$ROOT" ) || return 1
    [ -f "$ROOT/spec/tools/registry_build.py" ] || { echo "missing registry builder"; return 1; }
    ( cd "$ROOT" && "$PYTHON" spec/tools/registry_build.py --root "$ROOT" --check ) || return 1
    [ -f "$ROOT/spec/tools/registry_check.py" ] || { echo "missing registry checker"; return 1; }
    ( cd "$ROOT" && "$PYTHON" spec/tools/registry_check.py --root "$ROOT" ) || return 1
    [ -f "$ROOT/spec/tools/schema_diff.py" ] || { echo "missing schema diff checker"; return 1; }
    ( cd "$ROOT" && "$PYTHON" spec/tools/schema_diff.py --root "$ROOT" --base "${CI_PROTOCOL_BASE:-origin/main}" ) || return 1
    # The mutation tests that keep the checker honest (each invariant has a
    # passing fixture and a mutation that must turn it red).
    ( cd "$ROOT" && "$PYTHON" -m unittest discover -s spec/tools -p 'test_*.py' )
}

stage_phone_rust_tests() {
    command -v cargo >/dev/null 2>&1 || { skip "cargo not found: Rust wire/WAL tests were not run"; return; }
    [ -f "$ROOT/shell/Cargo.toml" ] || { echo "missing shell/Cargo.toml"; return 1; }
    ( cd "$ROOT/shell" && cargo test -p pdsh-wire -p pdsh-wal )
}

stage_phone_compat() {
    node_bin="${PDSH_NODE:-}"
    if [ -z "$node_bin" ]; then
        node_bin=$(command -v node || true)
    fi
    [ -n "$node_bin" ] || { skip "node not found: set PDSH_NODE or put node on PATH"; return; }
    [ -f "$ROOT/plugins/scripts/compat-gate.mjs" ] || { echo "missing plugins/scripts/compat-gate.mjs"; return 1; }
    "$node_bin" "$ROOT/plugins/scripts/compat-gate.mjs" --root "$ROOT/plugins"
}

stage_phone_plugins() {
    [ -d "$ROOT/plugins" ] || { skip "plugins not present"; return; }
    [ -d "$ROOT/plugins/node_modules" ] || { skip "plugins/node_modules not installed"; return; }
    command -v npm >/dev/null 2>&1 || { echo "npm not found"; return 1; }
    # Two suites need the pinned DSH checkout (the mux/timer tests read the real
    # runtime, and the shell corpus resolves its sources there). Resolve it the
    # same way the image stage and the repo do, so a correct tree is not reported
    # as broken just because the shell that ran the gate had not exported it.
    checkout="${PDSH_DSH_CHECKOUT:-}"
    if [ -z "$checkout" ] && [ -f "$HOME/.config/phone-dsh/dsh-checkout" ]; then checkout=$(head -n1 "$HOME/.config/phone-dsh/dsh-checkout"); fi
    ( cd "$ROOT/plugins" && PDSH_DSH_CHECKOUT="$checkout" npm run typecheck && PDSH_DSH_CHECKOUT="$checkout" npm test )
}

stage_phone_bundle_fresh() {
    # The App boots three separately built artifacts (worker-entry.js,
    # tool-worker-python.js, image.tar.gz). A source edit without a rebuild
    # leaves it running the previous bytes while every other stage is green;
    # that happened four times before this gate existed. The check is one node
    # process, needs no network and no checkout, and SKIPs (not PASSes) when the
    # gitignored bundle is absent.
    node_bin="${PDSH_NODE:-}"
    if [ -z "$node_bin" ]; then
        node_bin=$(command -v node || true)
    fi
    [ -n "$node_bin" ] || { skip "node not found: set PDSH_NODE or put node on PATH"; return; }
    [ -f "$ROOT/plugins/scripts/check-bundle-freshness.mjs" ] || { echo "missing plugins/scripts/check-bundle-freshness.mjs"; return 1; }
    "$node_bin" "$ROOT/plugins/scripts/check-bundle-freshness.mjs" --root "$ROOT"
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
    ( cd "$SDK" && swift test --filter "$sdk_filter" ) 2>&1 | tee "$sdk_log"
    rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || { echo "swift test failed (rc=$rc)"; return 1; }
    executed=$(grep -Eo 'Executed [0-9]+ tests?' "$sdk_log" | awk '{print $2}' | sort -n | tail -1)
    [ -n "$executed" ] || { echo "no XCTest 'Executed N tests' line in $sdk_log"; return 1; }
    [ "$executed" -gt 0 ] || { echo "swift test --filter matched 0 tests"; return 1; }
    log "executed $executed test(s)"
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
    "$PYTHON" "$ROOT/scripts/ci/test_protocol_impact.py" || return 1
    "$PYTHON" "$ROOT/scripts/ci/test_rust_stage.py" || return 1
    "$PYTHON" "$ROOT/scripts/ci/selftest.py" || return 1
}

# ------------------------------------------------------------- android helpers

# Return 0 when a JDK >= 17 is available, 77 (SKIP) when there is none, 1 when
# the one found is too old. AGP 8.7 refuses to run below 17, and a test stage
# that silently skips because `java` is missing must never look like a pass.
android_require_jdk() {
    java_bin=""
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
        java_bin="$JAVA_HOME/bin/java"
    elif command -v java >/dev/null 2>&1; then
        java_bin=$(command -v java)
    fi
    if [ -z "$java_bin" ]; then
        skip "no JDK found: export JAVA_HOME to a JDK 17+ (CI uses 21); AGP 8.7 cannot run on older JVMs"
        return 77
    fi
    jv=$("$java_bin" -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\)[^"]*".*/\1/p' | head -n 1)
    if [ -z "$jv" ]; then
        skip "no working JDK: '$java_bin -version' printed no version; export JAVA_HOME to a JDK 17+"
        return 77
    fi
    if [ "$jv" -lt 17 ]; then
        echo "JDK $jv at $java_bin is too old: AGP 8.7 needs JDK 17+ (CI uses 21)"
        return 1
    fi
    return 0
}

# Print `:module` for every Gradle module that has JVM test sources. The set is
# derived from android/settings.gradle.kts and disk instead of a hard-coded
# 12/13-name list, so a module added or removed by a parallel lane is followed
# automatically. :app and :shell have no src/test today, so they contribute no
# tests and are not asked for a `test` task.
android_test_modules() {
    settings="$ROOT/android/settings.gradle.kts"
    [ -f "$settings" ] || { echo "missing android/settings.gradle.kts" >&2; return 1; }
    out=""
    for name in $(sed -n 's/^[[:space:]]*include(":\([^"]*\)").*/\1/p' "$settings"); do
        dir="$ROOT/android/$name/src/test"
        [ -d "$dir" ] || continue
        count=$(find "$dir" -type f \( -name '*.kt' -o -name '*.java' \) 2>/dev/null | wc -l | tr -d '[:space:]')
        [ "${count:-0}" -gt 0 ] || continue
        out="$out :$name"
    done
    echo "$out"
}

# ------------------------------------------------------------ android stages

# The structure gate is deliberately split from the JVM suite: it needs only
# Python 3.9+ stdlib (no JDK, no SDK, no network), so it stays runnable on the
# smallest host and is the first thing a broken module tree trips.
stage_phone_android_structure() {
    checker="$ROOT/android/tools/structure_check.py"
    [ -f "$checker" ] || { echo "missing android/tools/structure_check.py"; return 1; }
    ( cd "$ROOT" && "$PYTHON" "$checker" --root . ) || return 1

    # Discovery must see both mutation suites: structure_check.py's own and
    # check-native-alignment.py's (the 16 KB page proof). A discover that
    # collects zero tests is a failure below, never a pass.
    for t in test_structure_check.py test_check_native_alignment.py; do
        [ -f "$ROOT/android/tools/$t" ] || { echo "missing android/tools/$t"; return 1; }
    done
    log_file="$CI_TMP/phone-android-structure-$$.log"
    ( cd "$ROOT" && "$PYTHON" -m unittest discover -s android/tools -p 'test_*.py' -v ) 2>&1 | tee "$log_file"
    rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || { echo "android/tools unit tests failed (rc=$rc)"; return 1; }
    ran=$(sed -n 's/^Ran \([0-9][0-9]*\) tests*.*/\1/p' "$log_file" | tail -n 1)
    [ -n "$ran" ] || { echo "unittest printed no 'Ran N tests' line; the tool tests did not run"; return 1; }
    [ "$ran" -gt 0 ] || { echo "unittest collected 0 tests from android/tools; that is not a pass"; return 1; }
    log "unittest executed $ran tool test(s)"

    # The packaged-APK half of the 16 KB proof has its own mutation suite. It
    # needs no APK (the fixtures are written to a temp dir), so it runs here
    # instead of behind the release stage's worker-bundle/NDK skip: a gate whose
    # red path is never exercised is a gate nobody should trust.
    for t in check-android-16k.py test_check_android_16k.py; do
        [ -f "$ROOT/scripts/ci/$t" ] || { echo "missing scripts/ci/$t"; return 1; }
    done
    ( cd "$ROOT" && "$PYTHON" -m unittest discover -s scripts/ci -p 'test_check_android_16k.py' ) || {
        echo "the packaged-APK 16 KB gate's mutation suite failed: the gate no longer goes red"
        return 1
    }
}

# The JVM suite. :core, :dsh and :testkit drive the Rust codec through JNI and
# their build scripts fail with "missing .../libpdsh_jni.*; build it first with:
# The authoritative read policy, the WAL planner and the accelerators are Rust.
# `phone-android-tests` builds `pdsh-jni` and exercises them through JNI, but the
# policy tests that prove a host accelerator cannot see an internal root live
# only in `shell/` — and nothing else runs them. The 2026-11-01 audit found the
# fix for "rg and jaq leak DSH-internal state" guarded by tests that no stage ran:
# a regression there would leave every gate green while the device leaked bytes.

# cd shell && cargo build -p pdsh-jni". Build the host library first, then run
# every test-bearing module and refuse an aggregate count of 0.
stage_phone_android_tests() {
    modules=$(android_test_modules) || { echo "cannot derive the Gradle test module list"; return 1; }
    if [ -z "$(echo "$modules" | tr -d '[:space:]')" ]; then
        echo "no Gradle module under android/ has src/test sources; refusing to report an empty suite as PASS"
        return 1
    fi
    gradle_tasks=""
    for module in $modules; do gradle_tasks="$gradle_tasks $module:test"; done

    command -v cargo >/dev/null 2>&1 \
        || { skip "cargo not found: the JVM suite needs the host pdsh-jni library (cd shell && cargo build -p pdsh-jni)"; return; }
    ( cd "$ROOT/shell" && cargo build -p pdsh-jni ) || {
        echo "cargo build -p pdsh-jni failed; :core/:dsh/:testkit cannot load the Rust codec"
        echo "  cd shell && cargo build -p pdsh-jni"
        return 1
    }
    so_dir="$ROOT/shell/target/debug"
    if [ ! -f "$so_dir/libpdsh_jni.so" ] && [ ! -f "$so_dir/libpdsh_jni.dylib" ]; then
        echo "cargo build -p pdsh-jni left no host library in $so_dir (wanted libpdsh_jni.so or .dylib)"
        echo "  cd shell && cargo build -p pdsh-jni"
        return 1
    fi

    android_require_jdk
    rc=$?
    [ "$rc" = 0 ] || return "$rc"

    gradle_args="--configure-on-demand --console=plain"
    [ "${CI_GRADLE_OFFLINE:-0}" = 1 ] && gradle_args="$gradle_args --offline"
    # --configure-on-demand is load-bearing, not a speed flag: :app's build
    # script checks for the ~65 MB gitignored worker bundle and the arm64-v8a
    # .so at configuration time, so a plain root `./gradlew test` cannot run in
    # a clean CI checkout. This stage configures only the requested modules.
    if ! ( cd "$ROOT/android" && bash ./gradlew $gradle_args ${CI_GRADLE_ARGS:-} $gradle_tasks ); then
        echo
        echo "JVM tests failed. If Gradle reported a missing libpdsh_jni library, run:"
        echo "  cd shell && cargo build -p pdsh-jni"
        return 1
    fi

    count_log="$CI_TMP/phone-android-tests-$$.log"
    "$ROOT/android/tools/test-count.sh" $modules 2>&1 | tee "$count_log"
    rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || { echo "test-count.sh reported failing tests or no results (rc=$rc)"; return 1; }
    total=$(sed -n 's/^TOTAL *\([0-9][0-9]*\) tests.*/\1/p' "$count_log" | tail -n 1)
    [ -n "$total" ] || { echo "test-count.sh printed no TOTAL line; cannot prove the suite ran"; return 1; }
    [ "$total" -gt 0 ] || {
        echo "0 tests executed. An empty suite is a FAILURE, not a pass:"
        echo "  the Gradle run produced no test XML, or every module reported 'no results'."
        return 1
    }
    log "JVM suite executed $total test(s) across $(echo $modules | wc -w | tr -d ' ') module(s)"
}

# The release stage. This is the single release entry: android-release in
# .github/workflows/android.yml calls this stage, so the local command and the CI
# command stay identical.
#
# ---- the AAR runs first, before every SKIP ---------------------------------
# The deliverable is `:lib`'s AAR (plan §176: the composition-root app consumes
# the AAR; `:app` is the vehicle that proves it). Its proof must not sit behind
# the APK's inputs: the arm64-v8a .so and the ~65 MB worker bundle gate
# `:app:assembleRelease` and are both gitignored, so on a clean host this stage
# SKIPs before it builds anything. `:lib:assembleRelease` and the consumer probe
# need neither — only the JDK and a warm Gradle cache — so they run first.
#
# The consequence is deliberate: a broken or unconsumable AAR is a FAIL here, not
# a SKIP. If the AAR proof lived after the skips, the artifact could stay
# unbuildable for as long as the worker bundle stayed missing, while the stage
# still reported "SKIP (not a release PASS)" and nobody looked.
#
# The probe is the half that asks the real question: it compiles against
# `lib-release.aar` as a *file* (never project(":lib")), so it sees no variant
# attributes and none of :lib's transitive `api` edges; its debug build proves
# the compile surface, and its release build runs R8 with the POM closure
# supplied by hand, which is what exercises the AAR's consumer-rules.pro.
# See docs/design/android-aar-consumer-api-2026-11-02.md.
stage_phone_android_release() {
    [ -f "$ROOT/android/gradlew" ] || { echo "missing android/gradlew (committed wrapper)"; return 1; }

    # ---- the deliverable: the published coordinates, and a consumer that
    #      resolves them the way an external app would ----
    android_require_jdk
    rc=$?
    [ "$rc" = 0 ] || return "$rc"

    gradle_args="--configure-on-demand --console=plain"
    [ "${CI_GRADLE_OFFLINE:-0}" = 1 ] && gradle_args="$gradle_args --offline"
    # `publishLocalRepository` is the eight `com.phonedsh` artifacts into
    # android/build/repo. The consumer probe resolves `com.phonedsh:lib:0.1.0`
    # from there through its POM — no file dependency, no hand-supplied sibling
    # list — so the publication has to exist before it builds. A real consumer
    # publishes once and then only consumes; this stage does both because the
    # deliverable *is* the pair (artifact + the proof someone else can use it).
    ( cd "$ROOT/android" && bash ./gradlew $gradle_args ${CI_GRADLE_ARGS:-} \
        :publishLocalRepository :lib-consumer-test:assembleDebug :lib-consumer-test:assembleRelease ) || {
        echo "the published artifacts or the consumer probe built against them did not build:"
        echo "  cd android && ./gradlew :publishLocalRepository :lib-consumer-test:assembleDebug :lib-consumer-test:assembleRelease"
        return 1
    }

    # The publication is the fix for L63's finding (a bare AAR left R8 with 44
    # missing classes because a file dependency has no POM). "The consumer built"
    # alone would not protect that: the probe could pass again on a hand-supplied
    # closure. So assert the POM itself carries the split it must carry —
    # `api` -> compile, `implementation` -> runtime, and the Compose BOM as an
    # import — and that all eight artifacts really exist.
    repo="$ROOT/android/build/repo"
    if ! publish_summary=$("$PYTHON" - "$repo" <<'PY'
import pathlib
import re
import sys

repo = pathlib.Path(sys.argv[1])
version = "0.1.0"
# artifact -> binary extension. Five AAR (Android libraries), three JAR (JVM).
required = {
    "lib": "aar",
    "dsh": "aar",
    "domain": "aar",
    "controller": "aar",
    "shell": "aar",
    "core": "jar",
    "net": "jar",
    "platform": "jar",
}
problems = []
for artifact, extension in required.items():
    base = repo / "com" / "phonedsh" / artifact / version
    pom = base / "{}-{}.pom".format(artifact, version)
    binary = base / "{}-{}.{}".format(artifact, version, extension)
    if not pom.is_file():
        problems.append("missing {} (publishLocalRepository did not write it)".format(pom.relative_to(repo)))
    if not binary.is_file():
        problems.append("missing {} ({})".format(binary.relative_to(repo), extension))
if problems:
    sys.exit("; ".join(problems[:6]))

pom = (repo / "com" / "phonedsh" / "lib" / version / "lib-{}.pom".format(version)).read_text()

def scope_of(sibling):
    match = re.search(
        r"<artifactId>{}</artifactId>\s*<version>{}</version>\s*<scope>(\w+)</scope>".format(
            re.escape(sibling), re.escape(version)
        ),
        pom,
    )
    return match.group(1) if match else None

# :lib's `api` edges: the seven siblings on its closure arrive through these.
for sibling in ("dsh", "domain", "platform"):
    if scope_of(sibling) != "compile":
        problems.append(
            "lib POM: com.phonedsh:{} is {} scope, not compile — an `api` edge "
            "did not reach the POM".format(sibling, scope_of(sibling) or "absent")
        )
# :dsh is the facade and it is `api`, so its own api edges must be compile too.
dsh_pom = (repo / "com" / "phonedsh" / "dsh" / version / "dsh-{}.pom".format(version)).read_text()
for sibling in ("core", "net", "controller", "shell", "platform"):
    if not re.search(
        r"<artifactId>{}</artifactId>\s*<version>{}</version>\s*<scope>compile</scope>".format(
            re.escape(sibling), re.escape(version)
        ),
        dsh_pom,
    ):
        problems.append("dsh POM: com.phonedsh:{} is not compile scope".format(sibling))

# `implementation` must NOT be on the consumer's compile surface.
core_ktx = re.search(r"<artifactId>core-ktx</artifactId>.*?<scope>(\w+)</scope>", pom, re.S)
if core_ktx and core_ktx.group(1) != "runtime":
    problems.append("lib POM: core-ktx is {} scope, so an `implementation` edge leaked into the compile surface".format(core_ktx.group(1)))

# :lib's Compose dependencies are declared without a version (the BOM owns it),
# so a POM that loses the BOM import is unresolvable, not merely imprecise.
if "<scope>import</scope>" not in pom or "<artifactId>compose-bom</artifactId>" not in pom:
    problems.append("lib POM: the Compose BOM is not imported; :lib's versionless Compose dependencies cannot resolve")

if problems:
    sys.exit("; ".join(problems[:6]))
print(
    "publication: 8 com.phonedsh:{} artifacts, :lib POM carries the api closure "
    "(compile) and the Compose BOM import".format(version)
)
PY
    ); then
        return 1
    fi
    log "$publish_summary"

    # Existence is not the assertion: the AAR must carry the documented consumer
    # entry points and the R8 rules that make it survivable in a minified app.
    # A rename, an accidental `internal`, or a dropped consumerProguardFiles
    # would all leave a non-empty zip behind, so "non-empty" alone would be a
    # gate that passes while the artifact stops being consumable.
    aar="$ROOT/android/lib/build/outputs/aar/lib-release.aar"
    [ -s "$aar" ] || {
        echo "assembleRelease wrote no non-empty AAR at android/lib/build/outputs/aar/lib-release.aar"
        return 1
    }
    if ! aar_summary=$("$PYTHON" - "$aar" <<'PY'
import os
import sys
import zipfile

aar = sys.argv[1]
required = (
    "com/phonedsh/ui/nav/PdshNavHostKt.class",
    "com/phonedsh/ui/nav/PdshNavFacts.class",
    "com/phonedsh/ui/nav/PdshNavState.class",
    "com/phonedsh/ui/nav/PdshRoute.class",
    "com/phonedsh/ui/theme/UiThemeKt.class",
)
with zipfile.ZipFile(aar) as archive:
    names = archive.namelist()
    for member in ("classes.jar", "AndroidManifest.xml", "proguard.txt"):
        if member not in names:
            sys.exit("%s: the AAR has no %s; it is not a usable deliverable" % (aar, member))
    rules = archive.read("proguard.txt").decode("utf-8", "replace")
    with archive.open("classes.jar") as raw:
        classes = [n for n in zipfile.ZipFile(raw).namelist() if n.endswith(".class")]
missing = [name for name in required if name not in classes]
if missing:
    sys.exit(
        "%s: classes.jar is missing the documented consumer entry point(s): %s"
        % (aar, ", ".join(missing))
    )
if "-keepclasseswithmembernames class com.phonedsh.wire.NativeWire" not in rules:
    sys.exit(
        "%s: the packaged consumer rules no longer keep the JNI symbol names; "
        "a minifying consumer gets UnsatisfiedLinkError on the first native call" % aar
    )
print(
    "AAR: %d bytes, %d classes, %d/5 consumer entry points, consumer rules packaged"
    % (os.path.getsize(aar), len(classes), len(required))
)
PY
    ); then
        return 1
    fi
    log "$aar_summary"

    consumer_apk=""
    for candidate in "$ROOT"/android/lib-consumer-test/build/outputs/apk/debug/*.apk; do
        [ -f "$candidate" ] || continue
        consumer_apk="$candidate"
        break
    done
    [ -n "$consumer_apk" ] || {
        echo "the consumer probe built no debug APK under android/lib-consumer-test/build/outputs/apk/debug/"
        echo "  the AAR may exist while nothing in the tree consumes it; that is the failure this probe exists for"
        return 1
    }
    log "consumer probe packaged ${consumer_apk#"$ROOT"/} against com.phonedsh:lib:0.1.0 (Maven coordinate, no file dependency)"

    # ---- the demo APK: needs the NDK product and the worker bundle ----
    so="${CI_ANDROID_SO:-$ROOT/shell/target/aarch64-linux-android/debug/libpdsh_jni.so}"
    if [ ! -f "$so" ]; then
        skip "the AAR deliverable and its consumer probe PASSED, but the APK half cannot run: arm64-v8a libpdsh_jni.so absent: $so. Build it with: cd shell && cargo ndk -t arm64-v8a build -p pdsh-jni (needs the NDK)"
        return
    fi
    "$PYTHON" "$ROOT/android/tools/check-native-alignment.py" "$so"
    align_rc=$?
    case "$align_rc" in
        0) ;;
        2) skip "check-native-alignment skipped: $so disappeared"; return ;;
        *) echo "check-native-alignment FAILED: the release APK would not load on Android 15+ 16 KB-page devices"; return 1 ;;
    esac

    bundle="$ROOT/examples/probe-app/Bundle/worker"
    if [ ! -d "$bundle" ]; then
        skip "the AAR deliverable and its consumer probe PASSED and 16 KB alignment PASSED, but assembleRelease cannot run: the gitignored ~65 MB worker bundle is missing. Generate it with: bash examples/probe-app/scripts/copy-bundle-assets.sh (pinned DSH checkout + network)"
        return
    fi

    ( cd "$ROOT/android" && bash ./gradlew $gradle_args ${CI_GRADLE_ARGS:-} :app:assembleRelease ) || return 1
    log "assembleRelease wrote android/app/build/outputs/apk/release/"

    # The APK holds the only bytes that ship: `PackagePdshJni` copied and
    # llvm-stripped the cargo artifact, and AGP chose the zip entry's
    # compression and offset. The check above reads shell/target/, so it cannot
    # see a strip step that rewrote the program headers, a deflated entry or a
    # 4 KB-aligned offset. This one can.
    apk=""
    for candidate in "$ROOT"/android/app/build/outputs/apk/release/*.apk; do
        [ -f "$candidate" ] || continue
        apk="$candidate"
        break
    done
    [ -n "$apk" ] || { echo "assembleRelease succeeded but wrote no APK under android/app/build/outputs/apk/release/"; return 1; }
    "$PYTHON" "$ROOT/scripts/ci/check-android-16k.py" --root "$ROOT" --apk "$apk" || {
        echo "the packaged .so is not 16 KB-page ready: Android 15+ 16 KB-page devices would reject it"
        return 1
    }
    log "16 KB alignment proven on the packaged APK: ${apk#"$ROOT"/}"
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
