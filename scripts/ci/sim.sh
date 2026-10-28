#!/bin/bash
# SPDX-License-Identifier: MIT
#
# phone-dsh phone DSH, iOS Simulator gate (PLAN W3-SIM, G0 + G1 rehearsal).
#
# Boots (or reuses) the iPhone 17 Pro simulator, builds the packed Worker
# assets and the probe app, installs the app, runs the hostless
# `PhoneDSHSimTests` target with `xcodebuild test -scheme PhoneDSHSim`, pulls
# the four JSON reports from the app container's Documents/pdsh-reports, and
# prints one PASS/FAIL/INFO table. Any FAIL row (gating or informational), a
# missing report or a test process failure exits non-zero.
#
# The suites are:
#   * probe-report.json — the W3-PROBES suite via ProbeKit (G0);
#   * smoke-report.json — one real model tool call, WAL/materialized/journal/
#     step-machine assertions, one planned restart and a resumed session (G1);
#   * kill-report.json — worker-terminate and WebContent-restart kills over the
#     four timings, with the W3-KILL acked/VFS/reconcile assertions (G1).
#
# The real WebContent kill has one handshake: the smoke suite writes the ready
# marker while its real WKWebView is alive, the watcher SIGKILLs this
# simulator's WebContent, and the suite then gates recovery of the same
# Session and a completed follow-up turn. The watcher only signals WebContent
# pids that belong to this simulator (found by the process environment's
# SIMULATOR_UDID, never by name alone).
#
# Every row says `environment: "ios-simulator"`. This is simulator evidence,
# never device evidence: iOS/WebKit behaviour on an iPhone remains
# NOT_VERIFIED until a device run records its own report.
#
# Usage: bash scripts/ci/sim.sh
# Env:   PDSH_DSH_CHECKOUT   pinned DSH checkout (else the per-machine file)
#        PDSH_DSH_SOURCE_COMMIT / PDSH_DSH_SOURCE_VERSION
#                           explicit controlled checkout HEAD + apps/cli version;
#                           supplied as a pair, never edits plugins/dsh-pin.json
#        PDSH_DSH_WWW        prebuilt static Worker bundle (optional)
#        PDSH_DSH_IMAGE      prebuilt image.tar.gz (optional)
#        PDSH_WEB_DIST       prebuilt complete Web page (optional)
#        OUT               output directory (default ${TMPDIR:-/tmp}/pdsh-sim)
#        PDSH_SIM_TIMEOUT    overall build/test timeout in seconds (default 1800)
#
# The pinned checkout is never modified. Worker assets are built into the
# app's `Bundle/worker/` through the documented copy script, exactly as a
# device build does. Before and after that copy, `web-build.json`, `sizes.json`
# and `probe-bundle.json` are checked against the canonical
# `plugins/dsh-pin.json` pair *and* the source selected for this run; a stale
# prebuilt Web dist cannot be stamped with a newer pin. The same canonical and
# selected pairs are passed to the XCTest runner, so the in-test audit uses CI
# inputs rather than trusting the inspected bundle's own expected fields.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
EXAMPLE="$ROOT/examples/probe-app"
PIN_FILE="$ROOT/plugins/dsh-pin.json"
# One copy of the simulator flow (device selection, project generation, Worker
# asset staging, install and container lookup) is shared with
# `scripts/ci/scenarios.sh --run-on sim`.
# shellcheck source=../../examples/probe-app/scripts/sim-common.sh
source "$EXAMPLE/scripts/sim-common.sh"
BUNDLE_ID="dev.phone-dsh.probe"
DEVICE_NAME="${PDSH_SIM_DEVICE:-iPhone 17 Pro}"
OUT="${OUT:-${TMPDIR:-/tmp}/pdsh-sim}"
OUT="${OUT%/}"
TIMEOUT="${PDSH_SIM_TIMEOUT:-1800}"
LOG="$OUT/sim.log"
DERIVED="$OUT/DerivedData"
PACKAGE_CACHE="$OUT/PackageCache"
XCODE_HOME="$OUT/xcode-home"
BUNDLE="$OUT/worker-bundle"
REPORT_DIR=""
# Real WebContent kill handshake (smoke INFO evidence; the smoke suite itself
# gates recovery): the report-container paths and the background watcher scoped
# to the selected simulator.
REAL_KILL_EXPECT=""
REAL_KILL_READY=""
REAL_KILL_RESULT=""
REAL_KILL_WATCHER_PID=""

mkdir -p "$OUT" "$XCODE_HOME" "$PACKAGE_CACHE"
: > "$LOG"

# Replay the log tail to the caller on exit: the full log stays on disk, and a
# small tail cannot fill the caller's pipe during a long xcodebuild run.
# The log fd is opened with O_APPEND: diagnostics are appended with
# `tail/cat ... >> "$LOG"` below, and a non-append fd 1 would keep a stale
# offset and overwrite those appended xcodebuild/fallback lines.
exec 3>&1
exec >> "$LOG" 2>&1
finish() {
  local status=$?
  trap - EXIT
  if [ -n "${REAL_KILL_WATCHER_PID:-}" ]; then
    kill "$REAL_KILL_WATCHER_PID" 2>/dev/null || true
    wait "$REAL_KILL_WATCHER_PID" 2>/dev/null || true
  fi
  tail -n 200 "$LOG" >&3 2>/dev/null || true
  exit "$status"
}
trap finish EXIT

log() { echo "sim: $*"; }
fail() { echo "sim: FAILED: $*"; exit 1; }

sim_require_tools || fail "the simulator flow requires xcrun, xcodebuild, xcodegen and python3"

# Runs a command with an overall wall-clock deadline through the shared helper
# so the CI pipeline's exit codes and log lines stay identical.
run_with_timeout() {
  sim_run_with_timeout "$@"
}

# Read the canonical pin once. It is an input to both the asset audit and the
# XCTest runner; a controlled build records it beside the selected pair.
PIN_VALUES="$(python3 -c '
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        pin = json.load(handle)
except Exception as error:
    print(f"cannot read pin {sys.argv[1]}: {error}", file=sys.stderr)
    raise SystemExit(1)
commit = pin.get("commit")
version = pin.get("version")
if not isinstance(commit, str) or not commit or not isinstance(version, str) or not version:
    print(f"{sys.argv[1]} has no commit/version", file=sys.stderr)
    raise SystemExit(1)
print(commit)
print(version)
' "$PIN_FILE")" || fail "cannot read the canonical DSH pin from $PIN_FILE"
PIN_COMMIT="$(printf '%s\n' "$PIN_VALUES" | sed -n '1p')"
PIN_VERSION="$(printf '%s\n' "$PIN_VALUES" | sed -n '2p')"

# A controlled source selection is a commit/version pair supplied by the
# caller (for example the already-verified c63e checkout). It never rewrites
# plugins/dsh-pin.json: the canonical pin above stays recorded and audited.
SOURCE_COMMIT="${PDSH_DSH_SOURCE_COMMIT:-}"
SOURCE_VERSION="${PDSH_DSH_SOURCE_VERSION:-}"
if [ -n "$SOURCE_COMMIT" ] || [ -n "$SOURCE_VERSION" ]; then
  [ -n "$SOURCE_COMMIT" ] && [ -n "$SOURCE_VERSION" ] \
    || fail "PDSH_DSH_SOURCE_COMMIT and PDSH_DSH_SOURCE_VERSION must be supplied together"
  case "$SOURCE_COMMIT" in
    *[!0-9a-f]*|'') fail "PDSH_DSH_SOURCE_COMMIT must be a full 40-character lowercase hex sha" ;;
  esac
  [ "${#SOURCE_COMMIT}" -eq 40 ] \
    || fail "PDSH_DSH_SOURCE_COMMIT must be a full 40-character lowercase hex sha"
  [ -n "$SOURCE_VERSION" ] || fail "PDSH_DSH_SOURCE_VERSION must not be empty"
fi
# The shared asset audit receives both sides as explicit inputs. They are not
# read back from the Web/image records being inspected.
export PDSH_SIM_AUDIT_CANONICAL_COMMIT="$PIN_COMMIT"
export PDSH_SIM_AUDIT_CANONICAL_VERSION="$PIN_VERSION"
if [ -n "$SOURCE_COMMIT" ]; then
  export PDSH_SIM_AUDIT_EXPECTED_COMMIT="$SOURCE_COMMIT"
  export PDSH_SIM_AUDIT_EXPECTED_VERSION="$SOURCE_VERSION"
  log "controlled source $SOURCE_COMMIT ($SOURCE_VERSION); canonical pin $PIN_COMMIT ($PIN_VERSION)"
else
  unset PDSH_SIM_AUDIT_EXPECTED_COMMIT PDSH_SIM_AUDIT_EXPECTED_VERSION
  log "canonical source $PIN_COMMIT ($PIN_VERSION)"
fi

# The same pairs reach the actual XCTest process. xcodebuild forwards
# TEST_RUNNER_*; the simctl fallback below exports the bare name through
# SIMCTL_CHILD_. Never put a credential in these variables.
export TEST_RUNNER_PDSH_DSH_CANONICAL_COMMIT="$PIN_COMMIT"
export TEST_RUNNER_PDSH_DSH_CANONICAL_VERSION="$PIN_VERSION"
if [ -n "$SOURCE_COMMIT" ]; then
  export TEST_RUNNER_PDSH_DSH_SOURCE_COMMIT="$SOURCE_COMMIT"
  export TEST_RUNNER_PDSH_DSH_SOURCE_VERSION="$SOURCE_VERSION"
else
  unset TEST_RUNNER_PDSH_DSH_SOURCE_COMMIT TEST_RUNNER_PDSH_DSH_SOURCE_VERSION
fi

# Build the complete Web page with the selected pair when one is explicit.
build_web_dist() {
  if [ -n "$SOURCE_COMMIT" ]; then
    run_with_timeout "$TIMEOUT" "build-web-dist" \
      bash "$HERE/build-web-dist.sh" \
      --commit "$SOURCE_COMMIT" --version "$SOURCE_VERSION"
  else
    run_with_timeout "$TIMEOUT" "build-web-dist" \
      bash "$HERE/build-web-dist.sh"
  fi
}

log "repo $ROOT"
log "output $OUT"

# The report table and gate live in sim_gate.py so the "any FAIL row exits
# non-zero" path has a reproducible self-test. Run it on every invocation with
# synthetic reports, including a non-gating FAIL row.
GATE_SELFTEST="$(python3 "$HERE/sim_gate.py" --selftest)" \
  || fail "the report gate self-test failed"
log "report gate self-test: $GATE_SELFTEST"

# 1. Resolve the pinned DSH checkout. Only the asset build needs it; a
#    prebuilt PDSH_DSH_WWW / PDSH_DSH_IMAGE run can proceed without it.
if [ -z "${PDSH_DSH_CHECKOUT:-}" ] && [ -f "$HOME/.config/phone-dsh/dsh-checkout" ]; then
  PDSH_DSH_CHECKOUT="$(sed -n '1p' "$HOME/.config/phone-dsh/dsh-checkout" | tr -d '\r')"
fi
if [ -n "${PDSH_DSH_CHECKOUT:-}" ] && [ -d "${PDSH_DSH_CHECKOUT:-}" ]; then
  export PDSH_DSH_CHECKOUT
  log "checkout $PDSH_DSH_CHECKOUT"
else
  log "checkout not resolved; a prebuilt PDSH_DSH_WWW/PDSH_DSH_IMAGE is required"
fi

# When the checkout is available, prove the selected pair really is its HEAD
# and apps/cli version before accepting it as the expected source. The full
# build path still runs the checkout verifier (clean tree + built artifacts).
if [ -n "$SOURCE_COMMIT" ] && [ -n "${PDSH_DSH_CHECKOUT:-}" ] \
   && [ -d "${PDSH_DSH_CHECKOUT:-}" ]; then
  CHECKOUT_HEAD="$(git -C "$PDSH_DSH_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"
  [ "$CHECKOUT_HEAD" = "$SOURCE_COMMIT" ] \
    || fail "PDSH_DSH_CHECKOUT HEAD ${CHECKOUT_HEAD:-<unknown>} does not match PDSH_DSH_SOURCE_COMMIT $SOURCE_COMMIT"
  CHECKOUT_VERSION="$(node -e '
    const version = require(process.argv[1]).version
    if (typeof version === "string" && version !== "") process.stdout.write(version)
  ' "$PDSH_DSH_CHECKOUT/apps/cli/package.json" 2>/dev/null || true)"
  if [ -n "$CHECKOUT_VERSION" ] && [ "$CHECKOUT_VERSION" != "$SOURCE_VERSION" ]; then
    fail "PDSH_DSH_CHECKOUT version $CHECKOUT_VERSION does not match PDSH_DSH_SOURCE_VERSION $SOURCE_VERSION"
  fi
fi

# 2. Warm plugins dependencies when the asset build needs esbuild/typescript.
if [ -z "${PDSH_DSH_IMAGE:-}" ] || [ -z "${PDSH_DSH_WWW:-}" ]; then
  PLUGIN_DIR="$ROOT/plugins"
  if [ -z "${PDSH_DSH_CHECKOUT:-}" ] || [ ! -d "$PDSH_DSH_CHECKOUT" ]; then
    fail "PDSH_DSH_CHECKOUT is not set and ~/.config/phone-dsh/dsh-checkout has no checkout path"
  fi
  LOCK="$PLUGIN_DIR/package-lock.json"
  INSTALLED_LOCK="$PLUGIN_DIR/node_modules/.package-lock.json"
  if [ ! -d "$PLUGIN_DIR/node_modules" ] || [ ! -f "$INSTALLED_LOCK" ] \
     || [ "$LOCK" -nt "$INSTALLED_LOCK" ]; then
    log "warming plugins/node_modules"
    ( cd "$PLUGIN_DIR" && npm install --no-audit --no-fund )
  fi
fi

# 3. Ensure the complete DSH Web page is staged and audited against the
#    canonical pin and the selected source. The page and Worker image come from
#    the same-source asset owner (`scripts/ci/build-web-dist.sh` +
#    `pack-image.mjs`); a prebuilt `PDSH_DSH_WWW/web` is reused only when its
#    own `web-build.json` names that pair and its recorded hashes match its
#    bytes. The copy step must never stamp the canonical pin onto an older
#    prebuilt page, so every source that will be used is checked *before* the
#    copy and the staged bundle is checked again in 3c.
WEB_PAGE="$EXAMPLE/Bundle/worker/web/index.html"
PREBUILT_WEB_PAGE="${PDSH_DSH_WWW:-}/web/index.html"
USE_PREBUILT=0
if [ -n "${PDSH_DSH_WWW:-}" ] && [ -n "${PDSH_DSH_IMAGE:-}" ] \
   && [ -f "$PDSH_DSH_IMAGE" ] \
   && [ -f "$PDSH_DSH_WWW/worker-entry.js" ] \
   && [ -f "$PDSH_DSH_WWW/index.html" ] \
   && [ -f "$PDSH_DSH_WWW/boot.js" ] \
   && [ -f "$PDSH_DSH_WWW/web-boot.js" ] \
   && [ -f "$PDSH_DSH_WWW/tool-worker-python.js" ] \
   && [ -f "$PDSH_DSH_WWW/workflow-isolate.js" ]; then
  USE_PREBUILT=1
fi

# A prebuilt page that will actually be staged is audited before the copy.
if [ "$USE_PREBUILT" -eq 1 ] && [ -f "$PREBUILT_WEB_PAGE" ]; then
  sim_verify_web_dist "$PDSH_DSH_WWW/web" "$PIN_FILE" "prebuilt PDSH_DSH_WWW/web" \
    || fail "the prebuilt Web dist is missing or names a different source than the selected DSH input; rebuild it with scripts/ci/build-web-dist.sh"
fi
if [ -n "${PDSH_WEB_DIST:-}" ] && [ -f "$PDSH_WEB_DIST/index.html" ]; then
  sim_verify_web_dist "$PDSH_WEB_DIST" "$PIN_FILE" "PDSH_WEB_DIST" \
    || fail "PDSH_WEB_DIST is missing or names a different source than the selected DSH input"
fi
if [ "$USE_PREBUILT" -eq 1 ]; then
  PREBUILT_IMAGE_DIR="$(cd "$(dirname "$PDSH_DSH_IMAGE")" && pwd)"
  sim_verify_image_metadata "$PREBUILT_IMAGE_DIR" "$PIN_FILE" \
    "prebuilt PDSH_DSH_IMAGE" "$PDSH_DSH_IMAGE" \
    || fail "the prebuilt Worker image is missing sizes.json or names a different source than the selected DSH input"
fi

# The staged page is used when the prebuilt/env page does not provide one.
if [ "$USE_PREBUILT" -eq 0 ] || [ ! -f "$PREBUILT_WEB_PAGE" ]; then
  if [ -z "${PDSH_WEB_DIST:-}" ] || [ ! -f "$PDSH_WEB_DIST/index.html" ]; then
    if [ -f "$WEB_PAGE" ]; then
      if ! sim_verify_web_dist "$EXAMPLE/Bundle/worker/web" "$PIN_FILE" \
           "Bundle/worker/web"; then
        if [ -n "${PDSH_DSH_CHECKOUT:-}" ] && [ -d "${PDSH_DSH_CHECKOUT:-}" ]; then
          log "Bundle/worker/web is stale or has no source record; rebuilding from the selected DSH input"
          build_web_dist || fail "build-web-dist.sh failed (see $LOG)"
          sim_verify_web_dist "$EXAMPLE/Bundle/worker/web" "$PIN_FILE" \
            "rebuilt Bundle/worker/web" \
            || fail "the freshly built Bundle/worker/web does not match the selected DSH input"
        else
          fail "Bundle/worker/web is stale or has no source record and PDSH_DSH_CHECKOUT is unresolved; run scripts/ci/build-web-dist.sh"
        fi
      fi
    elif [ -n "${PDSH_DSH_CHECKOUT:-}" ] && [ -d "${PDSH_DSH_CHECKOUT:-}" ]; then
      log "bundle/worker/web is missing; building the complete DSH Web page"
      build_web_dist || fail "build-web-dist.sh failed (see $LOG)"
      sim_verify_web_dist "$EXAMPLE/Bundle/worker/web" "$PIN_FILE" \
        "rebuilt Bundle/worker/web" \
        || fail "the freshly built Bundle/worker/web does not match the selected DSH input"
    else
      fail "Bundle/worker/web/index.html is missing and PDSH_DSH_CHECKOUT is unresolved; run scripts/ci/build-web-dist.sh"
    fi
  fi
fi

# 3b. Build the Worker bundle + image (unless both prebuilt outputs are given)
#    and copy them into the app's Bundle/worker through the documented step.
#    `copy-bundle-assets.sh` runs the same build commands and JavaScriptCore
#    prelude as `scripts/ci/smoke.sh`; this script reuses that step
#    instead of duplicating it.
if [ "$USE_PREBUILT" -eq 1 ]; then
  log "using prebuilt PDSH_DSH_WWW=$PDSH_DSH_WWW PDSH_DSH_IMAGE=$PDSH_DSH_IMAGE"
else
  log "building the Worker entry bundle and image via copy-bundle-assets.sh"
fi
sim_prepare_worker_assets "$EXAMPLE" "$BUNDLE" \
  "${PDSH_DSH_WWW:-}" "${PDSH_DSH_IMAGE:-}" || fail "cannot stage the Worker assets"

# 3c. Audit what was actually staged: web-build.json, sizes.json,
#    probe-bundle.json, the page hashes and the image byte count must all
#    agree with the canonical pin *and* the selected source. This catches a
#    copy step that preserved an older page, synthesized its record, or
#    silently fell back to the canonical pin for a controlled run.
sim_verify_worker_metadata "$EXAMPLE/Bundle/worker" "$PIN_FILE" \
  "staged Bundle/worker" \
  || fail "the staged Bundle/worker is not the same-source image/Web pair required by the selected DSH input"

# 4. Pick the booted iPhone 17 Pro simulator (or boot one). The UDID is used
#    for spawn/get_app_container; `booted` is ambiguous when several simulators
#    are booted at once, so it is only used when it resolves to this device.
SIMULATOR="$(sim_resolve_device "$DEVICE_NAME")" \
  || fail "no available iOS Simulator named $DEVICE_NAME"
UDID="${SIMULATOR%%|*}"
REST="${SIMULATOR#*|}"
SIM_NAME="${REST%%|*}"
REST="${REST#*|}"
RUNTIME="${REST%%|*}"
STATE="${REST##*|}"
log "simulator $SIM_NAME ($UDID), runtime $RUNTIME, state $STATE"

# 5. Generate and build the Xcode project. CFFIXED_USER_HOME keeps SwiftPM's
#    manifest cache inside $OUT (the CI harness may not allow writes to the
#    runner's home); -disable-sandbox stops SwiftPM/the macro plugin server from
#    nesting a second sandbox inside the harness sandbox.
log "generating the Xcode project"
sim_generate_project "$EXAMPLE"
DESTINATION="platform=iOS Simulator,name=$DEVICE_NAME"
export CFFIXED_USER_HOME="$XCODE_HOME"
COMMON=(
  -project "$EXAMPLE/PhoneDSHProbe.xcodeproj"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED"
  -packageCachePath "$PACKAGE_CACHE"
  CODE_SIGNING_ALLOWED=NO
  OTHER_SWIFT_FLAGS=-disable-sandbox
)
log "building the app and test bundle (build-for-testing)"
if ! run_with_timeout "$TIMEOUT" "xcodebuild build-for-testing" \
     xcodebuild build-for-testing -scheme PhoneDSHSim "${COMMON[@]}"; then
  fail "xcodebuild build-for-testing failed (see $LOG)"
fi

PRODUCTS="$DERIVED/Build/Products/Debug-iphonesimulator"
APP_NAME="PhoneDSHProbe"
APP="$PRODUCTS/$APP_NAME.app"
TEST_BUNDLE="$PRODUCTS/PhoneDSHSimTests.xctest"
# An app-hosted test bundle (the project hosts the suites in the probe app so
# they can run on a physical device) is built inside the host app.
[ -d "$TEST_BUNDLE" ] || TEST_BUNDLE="$APP/PlugIns/PhoneDSHSimTests.xctest"
[ -d "$APP" ] || fail "the probe app was not built at $APP"
[ -d "$TEST_BUNDLE" ] || fail "the test bundle was not built at $TEST_BUNDLE"

# 6. Install the app: its bundle is what the smoke test loads (the same
#    Bundle/worker a device build serves) and its data container receives the
#    reports. Uninstall first so a stale data container cannot shadow the new
#    one or contribute old reports.
log "installing $BUNDLE_ID"
CONTAINER="$(sim_install_probe_app "$UDID" "$APP")" \
  || fail "cannot install the probe app or resolve its data container"
log "reports container (udid $UDID): $CONTAINER"
REPORT_DIR="$CONTAINER/Documents/pdsh-reports"

# Clear stale reports so a crash cannot leave an old PASS table behind. The
# app container is outside this shell's writable sandbox, so container writes
# go through the selected simulator's launchd (the tests read the same files
# from inside the container).
xcrun simctl spawn "$UDID" /bin/rm -rf "$REPORT_DIR" 2>/dev/null || true

# 6b. Real WebContent kill handshakes.
#
# The hostless test process cannot signal the WebEngine's WebContent itself.
# Before the suites start this script records the WebContent pids that already
# belong to the selected simulator and starts two watchers. Each watcher
# follows the app's current data container (bundle id) and writes its own
# `expect-*-kill` marker there, so an xcodebuild reinstall that migrates the
# container cannot strand the expectation in the old path. The smoke suite
# creates `real-kill-ready.json` at the end of its run (INFO evidence), while
# the smoke suite creates `real-kill-ready.json` after its first-turn evidence
# passes. The watcher then SIGKILLs the simulator's WebContent pid(s) and writes
# the result file; the suite gates recovery of the same Session and a follow-up
# turn from that real kill.
#
# Every pid is selected three times: its command must contain the simulator
# runtime path (`CoreSimulator`) and the WebKit WebContent executable path, and
# its environment must contain `SIMULATOR_UDID=<selected udid>`. The simulator
# runtime lets `simctl spawn /bin/ps` see the host process table, but host
# processes (Safari, another simulator, another user app) carry neither the
# CoreSimulator runtime path nor this simulator's UDID, so they are never
# matched. Pids already alive before the suites are excluded, which keeps the
# attempts on the WebContent this test run created.
REAL_KILL_EXPECT="$REPORT_DIR/expect-real-kill"
REAL_KILL_READY="$REPORT_DIR/real-kill-ready.json"
REAL_KILL_RESULT="$REPORT_DIR/real-kill-result.json"
REAL_KILL_PREFLIGHT="unavailable (xcrun simctl spawn is not usable here)"

# The pid selection, the expectation marker and the SIGKILL handshake live in
# webcontent-watch.sh; the scenario runner uses the same script in its scenario
# mode. This file starts the watchers and records their results.
container_remove() {
  xcrun simctl spawn "$UDID" /bin/rm -f "$@" 2>/dev/null || true
}

if xcrun simctl spawn "$UDID" /bin/ps -A -o pid= >/dev/null 2>&1; then
  REAL_KILL_PREFLIGHT="available (device-scoped; attempted while the smoke WebContent is live)"
  # The watchers own the expectation marker and create it in the directory they
  # resolve on every poll. `xcodebuild test` may reinstall the app and migrate
  # its data container after this point; a marker written here would be left in
  # the old container and the suites would silently skip the real kill.
  if xcrun simctl spawn "$UDID" /bin/mkdir -p "$REPORT_DIR" 2>/dev/null; then
    (
      exec 3>&-
      exec bash "$HERE/webcontent-watch.sh" smoke --udid "$UDID" \
        --directory "$REPORT_DIR" --bundle-id "$BUNDLE_ID"
    ) &
    REAL_KILL_WATCHER_PID=$!
  else
    REAL_KILL_PREFLIGHT="unavailable (cannot create the report directory in the app container)"
    log "real WebContent kill handshake: unavailable (cannot create the report directory)"
  fi
fi
log "real WebContent kill preflight: $REAL_KILL_PREFLIGHT"
# 7. Run the contract command:
#      xcodebuild test -scheme PhoneDSHSim \
#        -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
#        CODE_SIGNING_ALLOWED=NO
#    If the harness forbids the pseudo-terminal the test runner needs, fall
#    back to the same XCTest bundle launched through `simctl spawn` (still the
#    built app container, same suites, same reports).
TEST_LOG="$OUT/xcodebuild-test.log"
TEST_RC=0
log "running xcodebuild test -scheme PhoneDSHSim"
run_with_timeout "$TIMEOUT" "xcodebuild test" \
  xcodebuild test -scheme PhoneDSHSim "${COMMON[@]}" > "$TEST_LOG" 2>&1 || TEST_RC=$?
if [ "$TEST_RC" -eq 0 ]; then
  tail -n 50 "$TEST_LOG" >> "$LOG" 2>/dev/null || true
elif grep -qE "Pseudo Terminal Setup Error|sandbox_apply: Operation not permitted|Failed to install or launch the test runner" "$TEST_LOG"; then
  log "xcodebuild test cannot launch a test runner in this harness (pty/sandbox);"
  log "falling back to simctl spawn of the same XCTest bundle"
  PLATFORM="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
  XCTEST_AGENT="$PLATFORM/Developer/Library/Xcode/Agents/xctest"
  [ -x "$XCTEST_AGENT" ] || fail "the simulator xctest agent is missing at $XCTEST_AGENT"
  TEST_RC=0
  SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$PRODUCTS:$PLATFORM/Developer/Library/Frameworks" \
  SIMCTL_CHILD_DYLD_LIBRARY_PATH="$PRODUCTS:$PLATFORM/Developer/usr/lib" \
  SIMCTL_CHILD_PDSH_SIM_REAL_KILL="$REAL_KILL_PREFLIGHT" \
  SIMCTL_CHILD_PDSH_DSH_CANONICAL_COMMIT="$PIN_COMMIT" \
  SIMCTL_CHILD_PDSH_DSH_CANONICAL_VERSION="$PIN_VERSION" \
  SIMCTL_CHILD_PDSH_DSH_SOURCE_COMMIT="${SOURCE_COMMIT:-}" \
  SIMCTL_CHILD_PDSH_DSH_SOURCE_VERSION="${SOURCE_VERSION:-}" \
  SIMCTL_CHILD_OBJC_PRINT_DUPLICATE_CLASSES=NO \
    xcrun simctl spawn "$UDID" "$XCTEST_AGENT" "$TEST_BUNDLE" \
    > "$OUT/xctest.log" 2>&1 || TEST_RC=$?
  # The ObjC runtime repeats a duplicate-class warning for every class the
  # static test executable and an embedded module both define; filter that
  # noise from the readable log but keep the raw log on disk.
  grep -v '^objc\[' "$OUT/xctest.log" > "$OUT/xctest-filtered.log" 2>/dev/null || true
  cat "$OUT/xctest-filtered.log" >> "$LOG" 2>/dev/null || true
  if ! grep -qE "Executed [1-9][0-9]* tests?" "$OUT/xctest.log"; then
    TEST_RC=$(( TEST_RC == 0 ? 3 : TEST_RC ))
  fi
else
  log "xcodebuild test failed; see $TEST_LOG"
  tail -n 100 "$TEST_LOG" >> "$LOG" 2>/dev/null || true
fi

# A hosted test run (`xcodebuild test` with the suites hosted in the probe app)
# reinstalls the app, and iOS may migrate its data container to a new path.
# Re-resolve the container before reading reports or handshake results.
if NEW_CONTAINER="$(sim_app_container "$UDID" 2>/dev/null)" && [ -n "$NEW_CONTAINER" ] \
   && [ "$NEW_CONTAINER" != "$CONTAINER" ]; then
  log "app data container moved to $NEW_CONTAINER (the test run reinstalled the app)"
  CONTAINER="$NEW_CONTAINER"
  REPORT_DIR="$CONTAINER/Documents/pdsh-reports"
  REAL_KILL_EXPECT="$REPORT_DIR/expect-real-kill"
  REAL_KILL_READY="$REPORT_DIR/real-kill-ready.json"
  REAL_KILL_RESULT="$REPORT_DIR/real-kill-result.json"
fi

# The suites are over: stop the real-kill watcher so it cannot write a result
# after this point, then read the smoke handshake outcome (INFO row; the smoke
# suite itself gates recovery).
if [ -n "$REAL_KILL_WATCHER_PID" ]; then
  kill "$REAL_KILL_WATCHER_PID" 2>/dev/null || true
  wait "$REAL_KILL_WATCHER_PID" 2>/dev/null || true
  REAL_KILL_WATCHER_PID=""
fi
REAL_KILL_STATUS="unavailable: the smoke suite did not reach the real-kill handshake"
if [ -f "$REAL_KILL_RESULT" ]; then
  REAL_KILL_STATUS="$(python3 - "$REAL_KILL_RESULT" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        document = json.load(handle)
    print(document.get("status", "unavailable: the result has no status"))
except Exception:
    print("unavailable: the real-kill result is not readable")
PY
)"
fi
# Drop the handshake markers from the container (the results were already read;
# reports are untouched). The next run uninstalls the app anyway.
container_remove "$REAL_KILL_EXPECT" "$REAL_KILL_READY"

# 8. Pull the reports. Every suite writes into the app container; the fallback
#    for an older run (or a hostless runner without the app installed) is the
#    test process's own Documents directory.
rm -f "$OUT/probe-report.json" "$OUT/smoke-report.json" "$OUT/kill-report.json"
PULLED=0
if [ -d "$REPORT_DIR" ]; then
  for name in probe-report.json smoke-report.json kill-report.json; do
    if [ -f "$REPORT_DIR/$name" ]; then
      cp "$REPORT_DIR/$name" "$OUT/$name"
      PULLED=$(( PULLED + 1 ))
    fi
  done
fi
if [ "$PULLED" -lt 4 ]; then
  RUNNER_HOME="$(xcrun simctl getenv "$UDID" HOME 2>/dev/null || true)"
  if [ -n "$RUNNER_HOME" ] && [ -d "$RUNNER_HOME/Documents/pdsh-reports" ]; then
    for name in probe-report.json smoke-report.json kill-report.json; do
      if [ ! -f "$OUT/$name" ] && [ -f "$RUNNER_HOME/Documents/pdsh-reports/$name" ]; then
        cp "$RUNNER_HOME/Documents/pdsh-reports/$name" "$OUT/$name"
        PULLED=$(( PULLED + 1 ))
      fi
    done
  fi
fi
[ "$PULLED" -eq 3 ] || fail "only $PULLED/3 reports were written (see $LOG)"

# 9. Record the real WebContent kill attempt on the kill suite's INFO row. The
#    attempt itself happened in step 6b while the smoke suite's real WKWebView
#    was alive; this step only stamps the already-measured outcome. It never
#    turns into a gating row: this is evidence that the attempt was made, not a
#    measured device kill.
log "real WebContent kill: $REAL_KILL_STATUS"
# The native surface is now the only automated process-kill coverage: a run
# where the watcher could not SIGKILL this simulator's WebContent must not
# report PASS, even though the attempt row itself stays INFO.
KILL_ATTEMPT_RC=0
case "$REAL_KILL_STATUS" in
  attempted:*) ;;
  *)
    KILL_ATTEMPT_RC=4
    log "FAILED: the native smoke suite did not get a real WebContent SIGKILL"
    ;;
esac
python3 - "$OUT/kill-report.json" "$REAL_KILL_STATUS" <<'PY' || true
import json, sys
path, status = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)
except Exception:
    raise SystemExit(0)
for row in document.get("rows", []):
    if row.get("probe") == "kill.real-webcontent-kill":
        row.setdefault("metrics", {})["attempt"] = status
        row["detail"] = ("real WebContent kill is attempted only by the shell "
                         "script, scoped to the selected simulator's WebContent "
                         "while the smoke host was live; this row records that "
                         "attempt, not a device measurement")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

# 10. Print the row table and gate. `sim_gate.py` exits non-zero on any FAIL
#     row (gating or informational), a missing suite report, a suite that did
#     not finish, a report environment other than ios-simulator, or an
#     unreadable report. Its --selftest run at the top of this script feeds a
#     synthetic non-gating FAIL row through the same gate; the outcome is
#     repeated here so the end of the gate log carries that evidence.
log "report gate self-test: $GATE_SELFTEST"
python3 "$HERE/sim_gate.py" "$OUT"

if [ "$TEST_RC" -ne 0 ]; then
  log "the test process exited $TEST_RC"
  echo "--- last 50 lines of the xcodebuild/xctest log ---"
  tail -50 "$LOG" || true
  exit "$TEST_RC"
fi
if [ "$KILL_ATTEMPT_RC" -ne 0 ]; then
  log "the real WebContent kill was not attempted (see above)"
  exit "$KILL_ATTEMPT_RC"
fi
log "reports: $OUT/probe-report.json $OUT/smoke-report.json $OUT/kill-report.json"
log "PASS"
