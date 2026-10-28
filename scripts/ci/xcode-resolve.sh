#!/bin/bash
# SPDX-License-Identifier: MIT
#
# phone-dsh phone DSH — fast Xcode package-resolution gate for the iOS probe
# project (G2-FIX-22).
#
# Why this stage exists: Xcode's package resolver rejects a test target that
# depends on another test target, while the SwiftPM command line accepts that
# package graph. A change that `swift test` passes can therefore stop
# `scripts/ci/sim.sh` at `xcodebuild build-for-testing` before any suite
# runs. This stage asks Xcode to resolve the probe project's package graph on
# every phone change, without booting a simulator, so the structural defect is
# caught in the task that introduces it instead of in the next simulator run.
#
# It first states the rejected edge directly: `package_graph.py` asks SwiftPM
# for the manifest-only target graph and fails on any test-target-to-test-target
# dependency, so the defect fails fast and deterministically even when the
# Xcode/package cache is cold. It then runs the same XcodeGen step as `sim.sh`
# and `xcodebuild -resolvePackageDependencies` for the `PhoneDSHSim` scheme,
# which remains the authoritative proof that Xcode accepts the graph. A
# test-target-to-test-target dependency, a missing package product or a broken
# manifest fails here.
#
# Usage: bash scripts/ci/xcode-resolve.sh [--root DIR]
# Env:   OUT                     output/caches dir (default
#                                 ${CI_TMP:-${TMPDIR:-/tmp}}/pdsh-xcode-resolve)
#        PDSH_XCODE_RESOLVE_TIMEOUT  overall timeout in seconds (default 300)
#
# No simulator is booted and no test runs. The generated `.xcodeproj` is
# gitignored, exactly as in `sim.sh`.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TIMEOUT="${PDSH_XCODE_RESOLVE_TIMEOUT:-300}"

while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "xcode-resolve: --root needs a value" >&2; exit 2; }; ROOT="$2"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "xcode-resolve: unknown argument: $1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$ROOT" && pwd)"
EXAMPLE="$ROOT/examples/probe-app"
OUT="${OUT:-${CI_TMP:-${TMPDIR:-/tmp}}/pdsh-xcode-resolve}"

if [ ! -f "$EXAMPLE/project.yml" ]; then
  echo "xcode-resolve: SKIP: examples/probe-app/project.yml is absent"
  exit 0
fi
for tool in xcodegen xcodebuild; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "xcode-resolve: FAIL: $tool is not installed" >&2
    exit 1
  fi
done
PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "xcode-resolve: FAIL: $PYTHON is not installed" >&2
  exit 1
fi

# Fast, deterministic form of the same invariant the Xcode resolver checks:
# no test target may depend on another test target. This needs only the
# manifest, so it fails before XcodeGen or the package checkout.
mkdir -p "$OUT" "$OUT/xcode-home" "$OUT/package-cache"
LOG="$OUT/xcode-resolve.log"
: > "$LOG"
PACKAGE_GRAPH="$OUT/package-graph.json"
echo "xcode-resolve: checking the package graph for test-target dependencies"
if ! ( cd "$ROOT" && swift package dump-package --disable-sandbox ) \
    >"$PACKAGE_GRAPH" 2>"$OUT/package-graph.err"; then
  echo "xcode-resolve: FAIL: swift package dump-package failed" >&2
  tail -20 "$OUT/package-graph.err" >&2
  exit 1
fi
if ! "$PYTHON" "$HERE/package_graph.py" --manifest "$PACKAGE_GRAPH"; then
  echo "xcode-resolve: FAIL: Package.swift has a test-target-to-test-target dependency" >&2
  exit 1
fi

# CFFIXED_USER_HOME keeps SwiftPM's manifest cache inside OUT (a CI account
# may not be able to write its own home); the package cache is reused across
# runs so the stage stays fast. Neither is inside the repository.
CFFIXED_USER_HOME="$OUT/xcode-home"
export CFFIXED_USER_HOME

echo "xcode-resolve: generating the probe project"
WORKER_BUNDLE="$EXAMPLE/Bundle/worker"
CREATED_WORKER_BUNDLE=0
if [ ! -d "$WORKER_BUNDLE" ]; then
  mkdir -p "$WORKER_BUNDLE"
  CREATED_WORKER_BUNDLE=1
fi
cleanup_generated_worker_dir() {
  if [ "$CREATED_WORKER_BUNDLE" = 1 ]; then
    rmdir "$WORKER_BUNDLE" 2>/dev/null || true
    rmdir "$(dirname "$WORKER_BUNDLE")" 2>/dev/null || true
  fi
}
trap cleanup_generated_worker_dir EXIT
( cd "$EXAMPLE" && xcodegen generate ) >>"$LOG" 2>&1 || {
  echo "xcode-resolve: FAIL: xcodegen generate failed" >&2
  tail -40 "$LOG" >&2
  exit 1
}

# `run_with_timeout` returns the command's status; the watchdog writes a
# distinguishable line into the log if it fires.
run_with_timeout() {
  local seconds="$1"
  local label="$2"
  shift 2
  "$@" &
  local pid=$!
  (
    local waited=0
    while [ "$waited" -lt "$seconds" ]; do
      kill -0 "$pid" 2>/dev/null || exit 0
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "xcode-resolve: timeout: $label exceeded ${seconds}s; terminating pid $pid" >>"$LOG"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 5
      kill -KILL "$pid" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  local watchdog=$!
  local rc=0
  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

echo "xcode-resolve: resolving the PhoneDSHSim package graph"
RC=0
run_with_timeout "$TIMEOUT" "xcodebuild -resolvePackageDependencies" \
  xcodebuild -resolvePackageDependencies \
    -project "$EXAMPLE/PhoneDSHProbe.xcodeproj" \
    -scheme PhoneDSHSim \
    -derivedDataPath "$OUT/DerivedData" \
    -packageCachePath "$OUT/package-cache" \
    CODE_SIGNING_ALLOWED=NO >>"$LOG" 2>&1 || RC=$?

if [ "$RC" -ne 0 ]; then
  echo "xcode-resolve: FAIL: Xcode could not resolve the probe package graph" >&2
  tail -60 "$LOG" >&2
  exit "$RC"
fi

echo "xcode-resolve: PASS (PhoneDSHSim package graph resolved; no simulator booted)"
