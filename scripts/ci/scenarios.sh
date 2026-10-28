#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Catalog-driven, real-model scenario runs on the phone DSH stack (PLAN §8).
#
# Builds the Worker bundle and image exactly the way
# `scripts/ci/smoke.sh` does by invoking that script once per build
# cache (it is the G1 gate and the only place the bundle steps live), then
# executes the selected catalog scenarios. `--run-on macos` (the default) runs
# `swift test --filter '^PhoneDSHScenarioTests[.]PhoneDSHScenarioTests/'`; `--run-on sim` runs the same catalog
# inside the iOS Simulator through the probe project's
# `PhoneDSHScenarioSimTests` bundle, stages the inputs into the app container,
# and pulls the same `<results>/<id>/` evidence back. A `workspace_command`
# assertion needs a host process, so `--run-on sim` is two-phase: the simulator
# writes it as `pending_host` with report status `PENDING_HOST`, then this
# script evaluates it on the Mac against the pulled materialized workspace with
# the same shared implementation the macOS runner uses, rewrites report.json
# with the final status and `host_evaluated: true`, and makes the exit code
# follow that final status.
# `--upstream mock` needs no key; `--upstream real` requires the three
# PDSH_MODEL_* variables exported by `model-env.mjs` (the script never reads the
# credentials file itself and never echoes a key). On the simulator the key is
# passed only through the xcodebuild test-runner environment.
#
# Usage:
#   bash scripts/ci/scenarios.sh [--catalog PATH] [--results DIR]
#       [--only id1,id2] [--tag TAG] [--target macos|sim|both]
#       [--run-on macos|sim] [--destination '<xcodebuild destination>']
#       [--upstream mock|real]
#
# Results land in <results>/<id>/{report.json,transcript.jsonl,workspace.tar}
# (`<results>` defaults to $TMPDIR/pdsh-scenarios) with the same schema on both
# runners. The batch orchestrator starts one process per lane; this script runs
# one WKWebView test process at a time.
#
# Env: PDSH_DSH_CHECKOUT        pinned DSH checkout (else $HOME/.config/phone-dsh/dsh-checkout)
#      PDSH_DSH_WWW/PDSH_DSH_IMAGE  prebuilt bundle/image (skips the build cache)
#      PDSH_SCENARIO_BUILD_DIR  build cache (default $TMPDIR/pdsh-scenarios-build)
#      PDSH_SCENARIO_SIM_DIR    simulator build/staging dir (default
#                          $TMPDIR/pdsh-scenarios-sim)
#      PDSH_SIM_DEVICE          simulator name used when --destination is absent
#      PDSH_SCENARIO_SIM_TIMEOUT  simulator build+test deadline in seconds
#      PDSH_PYTHON_ARTIFACTS    python.wasm/python313.zip directory (default
#                          $TMPDIR/pdsh-python-wasi; built by build.sh)
#      PDSH_JQ_ARTIFACTS    jq.wasm/engine.json directory (default
#                          $TMPDIR/pdsh-jq-wasi; built by wasi-toolbox/jq/build.sh)
#      PDSH_SCENARIO_KEEP_BODIES=1  keep redacted model request/response bodies
#      PDSH_MODEL_BASE_URL PDSH_MODEL_NAME PDSH_MODEL_API_KEY  real upstream only

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BASE_DIR="${TMPDIR:-/tmp}"
BASE_DIR="${BASE_DIR%/}"
EXAMPLE="$ROOT/examples/probe-app"
# shellcheck source=../../examples/probe-app/scripts/sim-common.sh
source "$EXAMPLE/scripts/sim-common.sh"

CATALOG="$ROOT/scripts/ci/scenarios/catalog.json"
RESULTS="$BASE_DIR/pdsh-scenarios"
ONLY=""
TAG=""
TARGET=""
RUN_ON="macos"
DESTINATION=""
UPSTREAM="mock"

usage() {
  sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --catalog)
      [ "$#" -ge 2 ] || { echo "scenarios: --catalog needs a path" >&2; exit 2; }
      CATALOG="$2"; shift 2 ;;
    --results)
      [ "$#" -ge 2 ] || { echo "scenarios: --results needs a path" >&2; exit 2; }
      RESULTS="$2"; shift 2 ;;
    --only)
      [ "$#" -ge 2 ] || { echo "scenarios: --only needs a comma-separated id list" >&2; exit 2; }
      ONLY="$2"; shift 2 ;;
    --tag)
      [ "$#" -ge 2 ] || { echo "scenarios: --tag needs a tag" >&2; exit 2; }
      TAG="$2"; shift 2 ;;
    --target)
      [ "$#" -ge 2 ] || { echo "scenarios: --target needs macos|sim|both" >&2; exit 2; }
      TARGET="$2"; shift 2 ;;
    --run-on)
      [ "$#" -ge 2 ] || { echo "scenarios: --run-on needs macos|sim" >&2; exit 2; }
      RUN_ON="$2"; shift 2 ;;
    --destination)
      [ "$#" -ge 2 ] || { echo "scenarios: --destination needs an xcodebuild destination" >&2; exit 2; }
      DESTINATION="$2"; shift 2 ;;
    --upstream)
      [ "$#" -ge 2 ] || { echo "scenarios: --upstream needs real|mock" >&2; exit 2; }
      UPSTREAM="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "scenarios: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$RUN_ON" in
  macos|sim) ;;
  *) echo "scenarios: --run-on must be macos or sim (got '$RUN_ON')" >&2; exit 2 ;;
esac
# `--target` is the catalog filter, not the execution target. The macOS run
# keeps its historical default (`macos`); a simulator run keeps scenarios whose
# catalog target is `macos` too, because the runner now executes the same
# catalog on both platforms. `--target sim` still means "only simulator-specific
# scenarios" for a batch operator who wants that filter.
if [ -z "$TARGET" ]; then
  if [ "$RUN_ON" = "sim" ]; then TARGET="both"; else TARGET="macos"; fi
fi
case "$TARGET" in
  macos|sim|both) ;;
  *) echo "scenarios: --target must be macos, sim or both (got '$TARGET')" >&2; exit 2 ;;
esac
case "$UPSTREAM" in
  real|mock) ;;
  *) echo "scenarios: --upstream must be real or mock (got '$UPSTREAM')" >&2; exit 2 ;;
esac

case "$CATALOG" in
  /*) ;;
  *) CATALOG="$ROOT/$CATALOG" ;;
esac
# The self-test gate lives in its own small catalog (selftest.json) so it is
# never part of the real-model batch. When the default catalog is used and none
# of the requested ids are in it, fall back to selftest.json if it has them.
if [ "$CATALOG" = "$ROOT/scripts/ci/scenarios/catalog.json" ] && [ -n "$ONLY" ]; then
  SELFTEST="$ROOT/scripts/ci/scenarios/selftest.json"
  if [ -f "$SELFTEST" ]; then
    resolved="$(python3 - "$CATALOG" "$SELFTEST" "$ONLY" <<'PY'
import json
import sys

def ids(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return {item.get("id") for item in json.load(handle).get("scenarios", [])}
    except Exception:
        return set()

wanted = {item.strip() for item in sys.argv[3].split(",") if item.strip()}
if wanted - ids(sys.argv[1]) and not (wanted - ids(sys.argv[2])):
    print(sys.argv[2])
PY
)"
    if [ -n "$resolved" ]; then
      CATALOG="$resolved"
      echo "scenarios: catalog fallback for the requested ids: $CATALOG"
    fi
  fi
fi
if [ ! -f "$CATALOG" ]; then
  echo "scenarios: catalog not found: $CATALOG" >&2
  exit 2
fi

if [ "$UPSTREAM" = "real" ]; then
  for name in PDSH_MODEL_BASE_URL PDSH_MODEL_NAME PDSH_MODEL_API_KEY; do
    if [ -z "${!name:-}" ]; then
      echo "scenarios: --upstream real requires $name; run: eval \"\$(node scripts/ci/model-env.mjs)\"" >&2
      exit 2
    fi
  done
fi

RESULTS="${RESULTS%/}"
# The launcher chdirs to the package root before swift test, and the batch orchestrator
# passes a results directory relative to this invocation. Make it absolute so
# every process agrees on where the artifacts land.
case "$RESULTS" in
  /*) ;;
  *) RESULTS="$(pwd)/$RESULTS" ;;
esac
mkdir -p "$RESULTS"
echo "scenarios: repo $ROOT"
echo "scenarios: catalog $CATALOG"
echo "scenarios: results $RESULTS"
echo "scenarios: upstream $UPSTREAM target $TARGET"
if [ "$RUN_ON" != "macos" ]; then echo "scenarios: run-on $RUN_ON"; fi
if [ -n "$DESTINATION" ]; then echo "scenarios: destination $DESTINATION"; fi
if [ -n "$ONLY" ]; then echo "scenarios: only $ONLY"; fi
if [ -n "$TAG" ]; then echo "scenarios: tag $TAG"; fi

# 1. Resolve the pinned checkout (needed for node_modules and the build cache).
if [ -z "${PDSH_DSH_CHECKOUT:-}" ] && [ -f "$HOME/.config/phone-dsh/dsh-checkout" ]; then
  PDSH_DSH_CHECKOUT="$(sed -n '1p' "$HOME/.config/phone-dsh/dsh-checkout" | tr -d '\r')"
fi
if [ -z "${PDSH_DSH_CHECKOUT:-}" ] && [ -z "${PDSH_DSH_WWW:-}" ]; then
  echo "scenarios: SKIP: PDSH_DSH_CHECKOUT is not set and ~/.config/phone-dsh/dsh-checkout has no checkout path" >&2
  exit 2
fi
if [ -n "${PDSH_DSH_CHECKOUT:-}" ] && [ ! -d "$PDSH_DSH_CHECKOUT" ]; then
  echo "scenarios: PDSH_DSH_CHECKOUT does not exist: $PDSH_DSH_CHECKOUT" >&2
  exit 2
fi
export PDSH_DSH_CHECKOUT="${PDSH_DSH_CHECKOUT:-}"

# 2. Warm the plugin dependencies exactly as smoke.sh does.
PLUGIN_DIR="$ROOT/plugins"
LOCK="$PLUGIN_DIR/package-lock.json"
INSTALLED_LOCK="$PLUGIN_DIR/node_modules/.package-lock.json"
if [ ! -d "$PLUGIN_DIR/node_modules" ] || [ ! -f "$INSTALLED_LOCK" ] \
   || [ "$LOCK" -nt "$INSTALLED_LOCK" ]; then
  echo "scenarios: warming plugins/node_modules"
  ( cd "$PLUGIN_DIR" && npm install --no-audit --no-fund )
fi

# 3. Resolve the Worker bundle and image. A prebuilt pair wins. Otherwise the
#    build cache is produced once by smoke.sh (reused by every lane process).
BUILD_DIR="${PDSH_SCENARIO_BUILD_DIR:-$BASE_DIR/pdsh-scenarios-build}"
BUILD_DIR="${BUILD_DIR%/}"
case "$BUILD_DIR" in
  /*) ;;
  *) BUILD_DIR="$(pwd)/$BUILD_DIR" ;;
esac
# The cache lives under the build dir; never let a bad value point removals at
# a broad path.
case "$BUILD_DIR" in
  ""|"/"|"$HOME"|"$HOME/"|"$ROOT"|"$ROOT/")
    echo "scenarios: refusing unsafe build directory: '$BUILD_DIR'" >&2
    exit 2 ;;
esac
case "${PDSH_DSH_WWW:-}" in
  ""|/*) ;;
  *) PDSH_DSH_WWW="$(pwd)/$PDSH_DSH_WWW" ;;
esac
case "${PDSH_DSH_IMAGE:-}" in
  ""|/*) ;;
  *) PDSH_DSH_IMAGE="$(pwd)/$PDSH_DSH_IMAGE" ;;
esac
WWW="${PDSH_DSH_WWW:-$BUILD_DIR/www}"
IMAGE="${PDSH_DSH_IMAGE:-$WWW/image.tar.gz}"
STAMP="$BUILD_DIR/.stamp"
SOURCE_HASH_FILE="$BUILD_DIR/.source-hash"
PYTHON_STAMP="$BUILD_DIR/.python-hash"
JQ_STAMP="$BUILD_DIR/.jq-hash"
BUILD_LOCK="$BUILD_DIR/.lock"

python_artifacts_dir() {
  printf '%s\n' "${PDSH_PYTHON_ARTIFACTS:-${TMPDIR:-/tmp}/pdsh-python-wasi}"
}

# Digest of the CPython-on-WASI artifact pair the image carries. A rebuilt or
# replaced pair invalidates the image cache, because the packed image embeds
# those exact bytes; without this a stale cache would silently ship an image
# built before python was wired in.
python_artifacts_hash() {
  python3 - "$(python_artifacts_dir)/python.wasm" "$(python_artifacts_dir)/python313.zip" <<'PYHASH'
import hashlib
import sys

digest = hashlib.sha256()
for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
print(digest.hexdigest())
PYHASH
}

jq_artifacts_dir() {
  printf '%s\n' "${PDSH_JQ_ARTIFACTS:-${TMPDIR:-/tmp}/pdsh-jq-wasi}"
}

# Digest of the jq WASI engine. A rebuilt engine invalidates the image cache
# for the same reason as python: the image embeds those exact bytes.
jq_artifacts_hash() {
  python3 - "$(jq_artifacts_dir)/jq.wasm" "$(jq_artifacts_dir)/engine.json" <<'PYHASH'
import hashlib
import sys

digest = hashlib.sha256()
for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
print(digest.hexdigest())
PYHASH
}

bundle_is_valid() {
  [ -n "${PDSH_DSH_WWW:-}" ] && [ -n "${PDSH_DSH_IMAGE:-}" ] \
    && [ -f "$IMAGE" ] && [ -f "$WWW/worker-entry.js" ] \
    && [ -f "$WWW/tool-worker-python.js" ] \
    && [ -f "$WWW/tool-worker.js" ] \
    && [ -f "$WWW/index.html" ] && [ -f "$WWW/boot.js" ] \
    && [ -f "$WWW/web-boot.js" ]
}

plugin_source_hash() {
  python3 - "$PLUGIN_DIR" <<'PY'
import hashlib
import os
import sys

root = sys.argv[1]
digest = hashlib.sha256()
skip = {"node_modules", ".build", "dist"}
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = sorted(name for name in dirnames if name not in skip)
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        digest.update(os.path.relpath(path, root).encode("utf-8"))
        digest.update(b"\0")
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
print(digest.hexdigest())
PY
}

cache_is_fresh() {
  [ -f "$STAMP" ] && [ -f "$SOURCE_HASH_FILE" ] && [ -f "$PYTHON_STAMP" ] && [ -f "$JQ_STAMP" ] \
    && [ -f "$WWW/worker-entry.js" ] && [ -f "$WWW/tool-worker-python.js" ] && [ -f "$WWW/tool-worker.js" ] \
    && [ -f "$WWW/workflow-isolate.js" ] \
    && [ -f "$IMAGE" ] || return 1
  # Worktrees carry different mtimes for the same commit, so freshness is a
  # content hash over plugins (node_modules and build output excluded).
  local current
  current="$(plugin_source_hash 2>/dev/null || true)"
  [ -n "$current" ] && [ "$current" = "$(cat "$SOURCE_HASH_FILE" 2>/dev/null)" ] || return 1
  # The packed image embeds python.wasm/python313.zip, so the pair's digest is
  # part of the cache identity too.
  local python_current jq_current
  python_current="$(python_artifacts_hash 2>/dev/null || true)"
  jq_current="$(jq_artifacts_hash 2>/dev/null || true)"
  [ -n "$python_current" ] && [ "$python_current" = "$(cat "$PYTHON_STAMP" 2>/dev/null)" ] \
    && [ -n "$jq_current" ] && [ "$jq_current" = "$(cat "$JQ_STAMP" 2>/dev/null)" ] \
    && node "$PLUGIN_DIR/scripts/verify-bundle.mjs" \
      --bundle "$WWW" --image "$IMAGE" \
      --provenance "$WWW/phone-dsh-provenance.json" --python yes --jq yes >/dev/null 2>&1
}

acquire_build_lock() {
  local waited=0
  mkdir -p "$BUILD_DIR"
  while ! mkdir "$BUILD_LOCK" 2>/dev/null; do
    # Reclaim a lock whose owner is gone (a killed lane build).
    if [ -f "$BUILD_LOCK/pid" ]; then
      local holder
      holder="$(cat "$BUILD_LOCK/pid" 2>/dev/null || true)"
      if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
        rm -rf "$BUILD_LOCK"
        continue
      fi
    fi
    waited=$((waited + 1))
    if [ "$waited" -ge 2400 ]; then
      echo "scenarios: timed out waiting for the build lock $BUILD_LOCK" >&2
      return 1
    fi
    sleep 0.5
  done
  printf '%s\n' "$$" > "$BUILD_LOCK/pid"
}

release_build_lock() {
  rm -rf "$BUILD_LOCK"
}

if ! bundle_is_valid; then
  if [ -n "${PDSH_DSH_WWW:-}" ] || [ -n "${PDSH_DSH_IMAGE:-}" ]; then
    echo "scenarios: the supplied PDSH_DSH_WWW/PDSH_DSH_IMAGE are missing files or failed provenance verification" >&2
    echo "  PDSH_DSH_WWW=${PDSH_DSH_WWW:-<unset>}" >&2
    echo "  PDSH_DSH_IMAGE=${PDSH_DSH_IMAGE:-<unset>}" >&2
    exit 1
  fi
  acquire_build_lock
  trap release_build_lock EXIT
  if cache_is_fresh; then
    echo "scenarios: reusing the build cache $BUILD_DIR"
  else
    # The scenario batch runs python-category steps: resolve the CPython-on-WASI
    # pair first (cached; built through build.sh once) and hand it to smoke.sh,
    # so the packed image really carries python3 instead of only the library.
    PYTHON_DIR="$(bash "$HERE/python-artifacts.sh")"
    export PDSH_PYTHON_ARTIFACTS="$PYTHON_DIR"
    JQ_DIR="$(bash "$HERE/jq-artifacts.sh")"
    export PDSH_JQ_ARTIFACTS="$JQ_DIR"
    echo "scenarios: python artifacts $PYTHON_DIR"
    echo "scenarios: jq artifacts $JQ_DIR"
    echo "scenarios: building the Worker bundle and image through smoke.sh"
    if ! ( cd "$ROOT" && env -u PDSH_DSH_WWW -u PDSH_DSH_IMAGE \
           PDSH_SMOKE_DIR="$BUILD_DIR/smoke" \
           PDSH_PYTHON_ARTIFACTS="$PYTHON_DIR" \
           PDSH_JQ_ARTIFACTS="$JQ_DIR" \
           bash "$HERE/smoke.sh" ) > "$BUILD_DIR/build.log" 2>&1; then
      # smoke.sh owns the build steps (bundle, image, JSC prelude) and then
      # runs the macOS smoke as its own gate. The build outputs are complete
      # before that test starts, so a smoke-test failure must not stop the
      # scenario line: on a locked Mac console the macOS page is hidden and
      # the smoke cannot pass, while the simulator runner can. Only a genuinely
      # missing build output is fatal here; the selected runner's scenario
      # assertions are this script's gate.
      if [ -f "$BUILD_DIR/smoke/www/worker-entry.js" ] \
         && [ -f "$BUILD_DIR/smoke/www/boot.js" ] \
         && [ -f "$BUILD_DIR/smoke/www/index.html" ] \
         && [ -f "$BUILD_DIR/smoke/www/image.tar.gz" ]; then
        echo "scenarios: smoke.sh's build steps completed; its macOS smoke test failed"
        echo "scenarios: (see $BUILD_DIR/build.log) — reusing the built Worker assets"
      else
        echo "scenarios: the smoke.sh build failed; last 40 lines:" >&2
        tail -40 "$BUILD_DIR/build.log" >&2 || true
        exit 1
      fi
    fi
    rm -rf "$WWW"
    mkdir -p "$WWW"
    cp -R "$BUILD_DIR/smoke/www/." "$WWW/"
    touch "$STAMP"
    plugin_source_hash > "$SOURCE_HASH_FILE"
    python_artifacts_hash > "$PYTHON_STAMP"
    jq_artifacts_hash > "$JQ_STAMP"
  fi
  release_build_lock
  trap - EXIT
  WWW="$BUILD_DIR/www"
  IMAGE="$WWW/image.tar.gz"
fi

if [ ! -f "$IMAGE" ] || [ ! -f "$WWW/worker-entry.js" ] \
   || [ ! -f "$WWW/index.html" ] || [ ! -f "$WWW/boot.js" ]; then
  echo "scenarios: the Worker bundle or image is missing after the build" >&2
  echo "  PDSH_DSH_WWW=$WWW" >&2
  echo "  PDSH_DSH_IMAGE=$IMAGE" >&2
  exit 1
fi
mkdir -p "$WWW/lazy"
echo "scenarios: PDSH_DSH_WWW=$WWW"
echo "scenarios: PDSH_DSH_IMAGE=$IMAGE"
# The macOS runner resolves its bundle from the environment
# (`ScenarioEnvironment.resolve`). Export the resolved paths before either
# runner; the simulator ignores them and reads the app's Bundle/worker instead.
export PDSH_DSH_WWW="$WWW"
export PDSH_DSH_IMAGE="$IMAGE"

# 4. Run the selection on the chosen runner. Both runners write the same
#    `<results>/<id>/{report.json,transcript.jsonl,workspace.tar,host/}` tree;
#    the check below is shared so a simulator run has the same exit codes.
#
#    `--run-on sim` has two phases for `workspace_command`: the simulator test
#    process records the assertion as `pending_host` (it cannot spawn
#    /bin/bash), and the host phase below runs the same shared evaluator against
#    the pulled materialized workspace and rewrites report.json. The report
#    check therefore treats a PENDING_HOST report as not final.
selected_ids() {
  python3 - "$CATALOG" "$ONLY" "$TAG" "$TARGET" <<'PY'
import json
import sys

catalog_path, only, tag, target = sys.argv[1:5]
with open(catalog_path, encoding="utf-8") as handle:
    catalog = json.load(handle)
wanted = {item.strip() for item in only.split(",") if item.strip()}
for scenario in catalog.get("scenarios", []):
    scenario_id = scenario.get("id")
    if not scenario_id:
        continue
    if wanted and scenario_id not in wanted:
        continue
    if tag and tag not in (scenario.get("tags") or []):
        continue
    if target == "macos" and scenario.get("target") == "sim":
        continue
    if target == "sim" and scenario.get("target") == "macos":
        continue
    print(scenario_id)
PY
}

# 4a prelude. Evidence lifecycle (G2-FIX-72/110/123/128): every selected
# scenario's current attempt is archived before a rerun can overwrite it, the
# mutable current artifacts are cleared without touching history/, and after
# the run (and after the simulator host phase) the current report refreshes
# <results>/.capability-index.json, .git lost from a pulled tree is restored
# from workspace.tar, and the terminal evidence is verified. The Python module
# is pure stdlib and runs on Linux as well as macOS.
EVIDENCE_FIXTURES="$ROOT/scripts/ci/scenarios/fixtures"
EVIDENCE="$HERE/scenario_evidence.py"

archive_selected_evidence() { # <comma-separated selected ids>
  local ids="$1"
  [ -n "$ids" ] || return 0
  python3 "$EVIDENCE" archive --results "$RESULTS" --ids "$ids" --source "$RUN_ON"
}

clear_selected_evidence() { # <comma-separated selected ids>
  local ids="$1"
  [ -n "$ids" ] || return 0
  python3 "$EVIDENCE" clear-current --results "$RESULTS" --ids "$ids"
}

finalize_selected_evidence() { # <comma-separated selected ids>
  local ids="$1"
  [ -n "$ids" ] || return 0
  python3 "$EVIDENCE" finalize --results "$RESULTS" --ids "$ids" \
    --fixtures-root "$EVIDENCE_FIXTURES"
}

verify_selected_evidence() { # <comma-separated selected ids>
  local ids="$1"
  [ -n "$ids" ] || return 0
  python3 "$EVIDENCE" verify --results "$RESULTS" --ids "$ids" \
    --fixtures-root "$EVIDENCE_FIXTURES"
}

report_check() {
  # The batch gate lives in scenario_evidence.py so the structure and status
  # exit codes (4 = unusable report tree, 5 = scenario verdict, 6 = runner
  # INFRA) are testable with the rest of the evidence contract. A failed
  # verify returns 1, but the caller composes exit codes below so it cannot
  # mask a clearer report-check diagnostic.
  python3 "$EVIDENCE" report-check \
    --catalog "$CATALOG" \
    --results "$RESULTS" \
    --only "$ONLY" \
    --tag "$TAG" \
    --target "$TARGET"
}

# Compose one scenario run's exit status without hiding a real failure.
# ``runner_rc`` is the real test process (swift test/xcodebuild). ``staging_rc``
# is a pre-host evidence finalize failure on the simulator (or another staging
# step) and is deliberately not a test result. ``evidence_rc`` is the terminal
# finalize/verify result; ``report_rc`` is the shared report check.
#
# Runner-INFRA (6) is a classification of a failed slot-glue/XCTest run, so it
# must win over the generic non-zero test exit. The clearer report-check exits
# 4/5 replace only staging/evidence failures, never a real test exit. A
# report-check self-error (1) never hides any real failure.
scenario_exit_code() {
  local runner_rc="$1"
  local evidence_rc="$2"
  local report_rc="$3"
  local staging_rc="${4:-0}"
  if [ "$report_rc" -eq 6 ]; then
    printf '%s\n' 6
    return 0
  fi
  if [ "$runner_rc" -ne 0 ]; then
    printf '%s\n' "$runner_rc"
    return 0
  fi
  case "$report_rc" in
    4|5)
      printf '%s\n' "$report_rc"
      return 0
      ;;
  esac
  if [ "$evidence_rc" -ne 0 ]; then
    printf '%s\n' "$evidence_rc"
    return 0
  fi
  if [ "$staging_rc" -ne 0 ]; then
    printf '%s\n' "$staging_rc"
    return 0
  fi
  printf '%s\n' "$report_rc"
  return 0
}

# 4b prelude. Host phase for `--run-on sim`: the simulator test bundle cannot
# spawn /bin/bash, so a `workspace_command` assertion is written as
# `pending_host` / report status `PENDING_HOST` and this phase runs the one
# shared evaluator on the Mac against the pulled
# `<results>/<id>/host/materialized/workspace`. `workspace.tar` is the same
# tree archived before assertion evaluation; the materialized directory is the
# authoritative input. The evaluator is the Swift library entry the macOS
# runner also uses (`ScenarioWorkspaceCommand.evaluateOrDefer` via
# `ScenarioHostEvaluation`), invoked here through the `ScenarioHostEvaluationTests`
# XCTest shim because `Package.swift` (out of this task's scope) has no
# executable target for it. It rewrites report.json: assertion ok/detail/status,
# `host_evaluated`, `duration_ms`, top-level `host_evaluated`, and the final
# status by the same precedence as the macOS report writer.
host_finalize_workspace_commands() { # <comma-separated selected ids>
  local ids="$1"
  [ -n "$ids" ] || return 0
  # Only run the host phase when a selected report actually deferred an
  # assertion; a run without workspace_command writes final verdicts itself.
  local pending
  pending="$(python3 - "$RESULTS" "$ids" <<'PYPENDING'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
pending_ids = []
for scenario_id in (item for item in sys.argv[2].split(",") if item):
    report_path = root / scenario_id / "report.json"
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001 - a missing report fails report_check
        continue
    if any(assertion.get("status") == "pending_host"
           for assertion in report.get("assertions", [])):
        pending_ids.append(scenario_id)
print(",".join(pending_ids))
PYPENDING
)"
  if [ -z "$pending" ]; then
    echo "scenarios: host phase: no pending workspace_command assertions"
    return 0
  fi
  local log="$RESULTS/.host-evaluation-$$.log"
  local rc=0
  echo "scenarios: host phase: evaluating workspace_command assertions on macOS"
  (
    cd "$ROOT"
    env -u CFFIXED_USER_HOME \
      PDSH_SCENARIO_HOST_EVAL_RESULTS="$RESULTS" \
      PDSH_SCENARIO_HOST_EVAL_IDS="$pending" \
      swift test --disable-sandbox --filter ScenarioHostEvaluationTests
  ) > "$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "scenarios: host workspace_command evaluation failed (exit $rc); last 60 lines:" >&2
    tail -60 "$log" >&2 || true
    return "$rc"
  fi
  grep -E "scenario host evaluation:|Executed [0-9]+ test" "$log" | tail -3 || true
  return 0
}

# 4a. macOS path: unchanged `swift test` invocation and environment.
run_on_macos() {
  export PDSH_SCENARIO_ROOT="$ROOT"
  export PDSH_SCENARIO_CATALOG="$CATALOG"
  export PDSH_SCENARIO_RESULTS="$RESULTS"
  export PDSH_SCENARIO_ONLY="$ONLY"
  export PDSH_SCENARIO_TAG="$TAG"
  export PDSH_SCENARIO_TARGET="$TARGET"
  export PDSH_SCENARIO_UPSTREAM="$UPSTREAM"
  export PDSH_SCENARIO_FIXTURES="$ROOT/scripts/ci/scenarios/fixtures"
  export PDSH_SCENARIO_KEEP_BODIES="${PDSH_SCENARIO_KEEP_BODIES:-0}"

  local selected
  selected="$(selected_ids | paste -sd, -)"
  # Archive before `swift test` starts: ScenarioRun.prepareDirectories removes
  # its own report/transcript/workspace.tar/host tree on every run, so a rerun
  # must freeze the previous attempt first (G2-FIX-72/123).
  if [ -n "$selected" ]; then
    archive_selected_evidence "$selected" \
      || { echo "scenarios: cannot archive the previous attempt" >&2; return 1; }
    clear_selected_evidence "$selected" \
      || { echo "scenarios: cannot clear the previous current evidence" >&2; return 1; }
  fi

  RUN_LOG="$RESULTS/.scenarios-run-$$.log"
  cd "$ROOT"
  set +e
  # Match the exact runner class: broad PhoneDSHScenario also executes
  # unit/kill regressions against this batch upstream and contaminates it.
  swift test --disable-sandbox --filter '^PhoneDSHScenarioTests[.]PhoneDSHScenarioTests/' 2>&1 | tee "$RUN_LOG"
  rc=${PIPESTATUS[0]}
  set -e

  # Keep the runner rc separate from the terminal evidence rc. A scenario
  # verdict or malformed report is only clearer than an evidence failure, never
  # clearer than a build/test/xctest failure.
  local runner_rc="$rc"
  local evidence_rc=0
  if [ -n "$selected" ]; then
    finalize_selected_evidence "$selected" || evidence_rc=$?
    local verify_rc=0
    verify_selected_evidence "$selected" || verify_rc=$?
    if [ "$evidence_rc" -eq 0 ]; then
      evidence_rc="$verify_rc"
    fi
  fi

  # Unused scenario slots skip by design (the runner maps the selection onto a
  # fixed bank of static test cases, because SwiftPM's --filter ignores a
  # dynamic defaultTestSuite). The gate is that every expected scenario wrote a
  # report. Missing reports mean a selected scenario never ran (setup error or
  # crash).
  set +e
  report_check
  local rc_reports=$?
  set -e
  rc="$(scenario_exit_code "$runner_rc" "$evidence_rc" "$rc_reports")"

  if [ "$rc" -ne 0 ]; then
    echo "scenarios: FAILED (exit $rc); run log $RUN_LOG"
  else
    echo "scenarios: PASS"
  fi
  return "$rc"
}

# 4b. iOS Simulator path: build the probe project, stage catalog + fixtures +
#     config in the app container, run the same catalog as an XCTest bundle,
#     pull the per-scenario evidence into --results, and run the same check.
run_on_sim() {
  sim_require_tools || { echo "scenarios: simulator toolchain is incomplete" >&2; return 1; }
  local sim_out="${PDSH_SCENARIO_SIM_DIR:-$BASE_DIR/pdsh-scenarios-sim}"
  sim_out="${sim_out%/}"
  case "$sim_out" in
    /*) ;;
    *) sim_out="$(pwd)/$sim_out" ;;
  esac
  case "$sim_out" in
    ""|"/"|"$HOME"|"$HOME/"|"$ROOT"|"$ROOT/")
      echo "scenarios: refusing unsafe simulator build directory: '$sim_out'" >&2
      return 2 ;;
  esac
  local timeout="${PDSH_SCENARIO_SIM_TIMEOUT:-${PDSH_SIM_TIMEOUT:-3600}}"
  local derived="$sim_out/DerivedData"
  local package_cache="$sim_out/PackageCache"
  local xcode_home="$sim_out/xcode-home"
  local bundle="$sim_out/worker-bundle"
  local device_id=""
  local target_kind="simulator"
  local selection
  local xcode_destination="$DESTINATION"
  local selected
  selected="$(selected_ids | paste -sd, -)"

  mkdir -p "$sim_out" "$xcode_home" "$package_cache"
  echo "scenarios: simulator work dir $sim_out"

  # The same Worker assets the macOS run uses are copied into the probe app;
  # the installed app bundle is what the simulator test process reads.
  echo "scenarios: staging the Worker assets into the probe app"
  sim_prepare_worker_assets "$EXAMPLE" "$bundle" "$WWW" "$IMAGE" \
    || { echo "scenarios: cannot stage the Worker assets into the probe app" >&2; return 1; }

  if [ -n "$DESTINATION" ]; then
    case "$DESTINATION" in
      *Simulator*|*simulator*) target_kind="simulator" ;;
      *) target_kind="device" ;;
    esac
  fi

  if [ "$target_kind" = "simulator" ]; then
    selection="$(sim_resolve_destination "$DESTINATION")" || {
      echo "scenarios: cannot resolve the iOS Simulator destination" >&2
      return 1
    }
    device_id="${selection%%|*}"
    local rest="${selection#*|}"
    local sim_name="${rest%%|*}"
    if [ -z "$xcode_destination" ]; then
      xcode_destination="platform=iOS Simulator,id=$device_id"
    fi
    echo "scenarios: simulator $sim_name ($device_id), destination $xcode_destination"
  else
    echo "scenarios: physical-device destination $DESTINATION"
    case "$DESTINATION" in
      *id=*) device_id="${DESTINATION##*id=}"; device_id="${device_id%%,*}" ;;
      *name=*) device_id="${DESTINATION##*name=}"; device_id="${device_id%%,*}" ;;
    esac
    if [ -z "$device_id" ]; then
      echo "scenarios: a device destination must carry id=<udid> or name=<device>" >&2
      return 2
    fi
    if ! command -v xcrun >/dev/null 2>&1; then
      echo "scenarios: xcrun is required for a device run" >&2
      return 1
    fi
  fi

  local scheme="PhoneDSHScenarioSim"
  [ "$target_kind" = "device" ] && scheme="PhoneDSHScenarioDevice"
  sim_generate_project "$EXAMPLE" || return 1
  local common=(
    -project "$EXAMPLE/PhoneDSHProbe.xcodeproj"
    -destination "$xcode_destination"
    -derivedDataPath "$derived"
    -packageCachePath "$package_cache"
  )
  if [ "$target_kind" = "simulator" ]; then
    common+=(CODE_SIGNING_ALLOWED=NO)
  elif [ -n "${PDSH_DEVELOPMENT_TEAM:-}" ]; then
    common+=(DEVELOPMENT_TEAM="$PDSH_DEVELOPMENT_TEAM" -allowProvisioningUpdates -allowProvisioningDeviceRegistration)
  fi
  common+=(OTHER_SWIFT_FLAGS=-disable-sandbox)
  export CFFIXED_USER_HOME="$xcode_home"

  echo "scenarios: building the probe app and the scenario test bundle"
  if ! sim_run_with_timeout "$timeout" "xcodebuild build-for-testing" \
       xcodebuild build-for-testing -scheme "$scheme" "${common[@]}" \
       > "$sim_out/build.log" 2>&1; then
    echo "scenarios: xcodebuild build-for-testing failed; last 60 lines:" >&2
    tail -60 "$sim_out/build.log" >&2 || true
    return 1
  fi

  local products="$derived/Build/Products/Debug-iphonesimulator"
  if [ "$target_kind" = "device" ]; then
    products="$derived/Build/Products/Debug-iphoneos"
  fi
  local app="$products/${PDSH_PROBE_APP_PRODUCT:-PhoneDSHProbe}.app"
  local test_bundle="$products/PhoneDSHScenarioSimTests.xctest"
  if [ "$target_kind" = "device" ]; then
    # the device twin is hosted by the probe app and ships inside it
    test_bundle="$app/PlugIns/PhoneDSHScenarioDeviceTests.xctest"
  fi
  [ -d "$app" ] || { echo "scenarios: the probe app was not built at $app" >&2; return 1; }
  [ -d "$test_bundle" ] || { echo "scenarios: the scenario test bundle was not built at $test_bundle" >&2; return 1; }

  # Stage catalog + fixtures + config. The stage directory is the test input
  # root; the result tree it contains is pulled back after the run.
  local stage_root_host="$sim_out/staged"
  rm -rf "$stage_root_host"
  mkdir -p "$stage_root_host/fixtures" "$stage_root_host/results"
  cp "$CATALOG" "$stage_root_host/catalog.json"
  # Fixtures are staged with their deterministic git history already built by
  # the host: the simulator test process is sandboxed and cannot spawn `git`.
  # A staged fixture.json therefore omits the `git` block and its files/ tree
  # already contains `.git`; the shared engine copies it through the WAL like
  # any other payload file. The macOS runner keeps building the history inside
  # the test process (that path is unchanged).
  if [ -d "$ROOT/scripts/ci/scenarios/fixtures" ]; then
    python3 - "$ROOT/scripts/ci/scenarios/fixtures" \
      "$stage_root_host/fixtures" <<'PYFIXTURES' \
      || { echo "scenarios: cannot prepare the fixtures for the simulator" >&2; return 1; }
import json
import os
import shutil
import subprocess
import sys

source, destination = sys.argv[1:3]
os.makedirs(destination, exist_ok=True)


def git(args, cwd, identity=None):
    command = ["/usr/bin/git", "-C", cwd]
    if identity:
        command += ["-c", f"user.name={identity['name']}",
                    "-c", f"user.email={identity['email_user']}@{identity['email_host']}"]
    command += args
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


for name in sorted(os.listdir(source)):
    fixture = os.path.join(source, name)
    payload = os.path.join(fixture, "files")
    if not os.path.isdir(fixture) or not os.path.isdir(payload):
        continue
    target = os.path.join(destination, name)
    os.makedirs(target, exist_ok=True)
    shutil.copytree(payload, os.path.join(target, "files"), dirs_exist_ok=True)
    spec_path = os.path.join(fixture, "fixture.json")
    spec = {}
    if os.path.isfile(spec_path):
        with open(spec_path, encoding="utf-8") as handle:
            spec = json.load(handle)
    spec.setdefault("name", name)
    git_spec = spec.get("git")
    build_root = os.path.join(target, "files")
    if git_spec:
        branch = git_spec.get("branch") or "main"
        identity = git_spec.get("identity")
        git(["init", "--quiet", f"--initial-branch={branch}"], build_root)
        if identity:
            git(["config", "user.name", identity["name"]], build_root)
            git(["config", "user.email",
                 f"{identity['email_user']}@{identity['email_host']}"], build_root)
        builder = identity or {"name": "fixture builder",
                               "email_user": "fixture",
                               "email_host": "example.invalid"}
        parent = None
        for index, commit in enumerate(git_spec.get("commits", [])):
            files = commit.get("files") or []
            if not files:
                raise SystemExit(f"fixture {name}: commit {index} has no files")
            git(["add", "--"] + files, build_root)
            tree = git(["write-tree"], build_root)
            arguments = ["commit-tree", tree]
            if parent:
                arguments += ["-p", parent]
            arguments += ["-m", commit.get("message", "")]
            parent = git(arguments, build_root, builder)
            git(["update-ref", f"refs/heads/{branch}", parent], build_root)
        git(["symbolic-ref", "HEAD", f"refs/heads/{branch}"], build_root)
        status = git(["status", "--porcelain"], build_root)
        if status:
            raise SystemExit(f"fixture {name}: generated repository is not clean: {status}")
        spec.pop("git", None)
    with open(os.path.join(target, "fixture.json"), "w", encoding="utf-8") as handle:
        json.dump(spec, handle, indent=2, sort_keys=True)
        handle.write("\n")
PYFIXTURES
  fi
  python3 - "$stage_root_host/config.json" "$UPSTREAM" "$ONLY" "$TAG" "$TARGET" \
    "${PDSH_SCENARIO_KEEP_BODIES:-0}" <<'PY'
import json
import sys

path, upstream, only, tag, target, keep = sys.argv[1:7]
document = {
    "version": 1,
    "upstream": upstream,
    "only": [item.strip() for item in only.split(",") if item.strip()],
    "tag": tag,
    "target": target,
    "keep_bodies": keep == "1",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

  # Archive the previous attempt and remove only the mutable current
  # artifacts before the runner or the pull can overwrite them. `history/`
  # and the index survive the clear (G2-FIX-72/123).
  if [ -n "$selected" ]; then
    archive_selected_evidence "$selected" \
      || { echo "scenarios: cannot archive the previous attempt" >&2; return 1; }
    clear_selected_evidence "$selected" \
      || { echo "scenarios: cannot clear the previous current evidence" >&2; return 1; }
  fi

  if [ "$target_kind" = "simulator" ]; then
    local container
    xcrun simctl uninstall "$device_id" "$SIM_PROBE_BUNDLE_ID" 2>/dev/null || true
    xcrun simctl install "$device_id" "$app" \
      || { echo "scenarios: cannot install the probe app" >&2; return 1; }
    container="$(sim_app_container "$device_id")" \
      || { echo "scenarios: cannot resolve the probe app data container" >&2; return 1; }
    local stage="$container/Documents/pdsh-scenarios"
    sim_spawn "$device_id" /bin/rm -rf "$stage" 2>/dev/null || true
    sim_spawn "$device_id" /bin/mkdir -p "$stage/fixtures" "$stage/results" \
      || { echo "scenarios: cannot create the staged input directory" >&2; return 1; }
    cp "$stage_root_host/catalog.json" "$sim_out/catalog.json"
    cp "$stage_root_host/config.json" "$sim_out/config.json"
    sim_stage_file "$device_id" "$sim_out/catalog.json" "$stage/catalog.json" \
      || { echo "scenarios: cannot stage the catalog" >&2; return 1; }
    sim_stage_file "$device_id" "$sim_out/config.json" "$stage/config.json" \
      || { echo "scenarios: cannot stage the runner config" >&2; return 1; }
    if [ -d "$stage_root_host/fixtures" ] \
       && [ -n "$(ls -A "$stage_root_host/fixtures" 2>/dev/null)" ]; then
      sim_spawn "$device_id" /bin/cp -R "$stage_root_host/fixtures/." "$stage/fixtures/" \
        || { echo "scenarios: cannot stage the fixtures" >&2; return 1; }
    fi
    echo "scenarios: staged inputs in the app container (Documents/pdsh-scenarios)"

    # G2-FIX-65: arm the device-scoped WebContent watcher before the runner
    # starts. A webcontent_kill scenario writes <token>.request into
    # results/.webcontent-kill and waits for the watcher's <token>.result; the
    # watcher (the same implementation sim.sh uses) SIGKILLs the selected
    # simulator's WebContent process. Without the exported arming flag the
    # runner's capability matrix rejects the kind as runner-INFRA before the
    # scenario starts, so it can never be reported as a recovery failure.
    local watcher_pid=""
    local watch_dir="$stage/results/.webcontent-kill"
    if sim_spawn "$device_id" /bin/rm -rf "$watch_dir" 2>/dev/null \
       && sim_spawn "$device_id" /bin/mkdir -p "$watch_dir" 2>/dev/null; then
      (
        exec 3>&-
        exec bash "$HERE/webcontent-watch.sh" scenario --udid "$device_id" \
          --directory "$watch_dir"
      ) >> "$sim_out/webcontent-watch.log" 2>&1 &
      watcher_pid=$!
      echo "scenarios: device-scoped WebContent watcher armed (pid $watcher_pid)"
    else
      echo "scenarios: WARNING: the device-scoped WebContent watcher cannot be armed;" >&2
      echo "scenarios: webcontent_kill declarations are runner-INFRA for this run" >&2
    fi

    local test_log="$sim_out/xcodebuild-test.log"
    local test_rc=0
    echo "scenarios: running xcodebuild test -scheme PhoneDSHScenarioSim"
    (
      export TEST_RUNNER_PDSH_SCENARIO_ROOT="$stage"
      export TEST_RUNNER_PDSH_SIM_APP_BUNDLE="$app"
      if [ -n "$watcher_pid" ]; then
        export TEST_RUNNER_PDSH_SCENARIO_WEBCONTENT_WATCH=1
      fi
      if [ "$UPSTREAM" = "real" ]; then
        export TEST_RUNNER_PDSH_MODEL_BASE_URL="$PDSH_MODEL_BASE_URL"
        export TEST_RUNNER_PDSH_MODEL_NAME="$PDSH_MODEL_NAME"
        export TEST_RUNNER_PDSH_MODEL_API_KEY="$PDSH_MODEL_API_KEY"
      fi
      sim_run_with_timeout "$timeout" "xcodebuild test" \
        xcodebuild test-without-building -scheme PhoneDSHScenarioSim "${common[@]}"
    ) > "$test_log" 2>&1 || test_rc=$?
    if [ "$test_rc" -ne 0 ] \
       && grep -qE "Pseudo Terminal Setup Error|sandbox_apply: Operation not permitted|Failed to install or launch the test runner" "$test_log"; then
      echo "scenarios: xcodebuild cannot launch a test runner in this harness;"
      echo "scenarios: falling back to simctl spawn of the same XCTest bundle"
      local platform
      platform="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
      local agent="$platform/Developer/Library/Xcode/Agents/xctest"
      [ -x "$agent" ] || {
        echo "scenarios: the simulator xctest agent is missing" >&2
        if [ -n "$watcher_pid" ]; then
          kill "$watcher_pid" 2>/dev/null || true
          wait "$watcher_pid" 2>/dev/null || true
        fi
        return 1
      }
      test_rc=0
      (
        export SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$products:$platform/Developer/Library/Frameworks"
        export SIMCTL_CHILD_DYLD_LIBRARY_PATH="$products:$platform/Developer/usr/lib"
        export SIMCTL_CHILD_PDSH_SCENARIO_ROOT="$stage"
        export SIMCTL_CHILD_PDSH_SIM_APP_BUNDLE="$app"
        export SIMCTL_CHILD_OBJC_PRINT_DUPLICATE_CLASSES=NO
        if [ -n "$watcher_pid" ]; then
          export SIMCTL_CHILD_PDSH_SCENARIO_WEBCONTENT_WATCH=1
        fi
        if [ "$UPSTREAM" = "real" ]; then
          export SIMCTL_CHILD_PDSH_MODEL_BASE_URL="$PDSH_MODEL_BASE_URL"
          export SIMCTL_CHILD_PDSH_MODEL_NAME="$PDSH_MODEL_NAME"
          export SIMCTL_CHILD_PDSH_MODEL_API_KEY="$PDSH_MODEL_API_KEY"
        fi
        sim_run_with_timeout "$timeout" "simctl spawn xctest" \
          xcrun simctl spawn "$device_id" "$agent" "$test_bundle"
      ) > "$sim_out/xctest.log" 2>&1 || test_rc=$?
      grep -v '^objc\[' "$sim_out/xctest.log" > "$sim_out/xctest-filtered.log" 2>/dev/null || true
      if ! grep -qE "Executed [1-9][0-9]* tests?" "$sim_out/xctest.log"; then
        test_rc=$(( test_rc == 0 ? 3 : test_rc ))
      fi
    elif [ "$test_rc" -ne 0 ]; then
      echo "scenarios: xcodebuild test failed; last 80 lines:" >&2
      tail -80 "$test_log" >&2 || true
    fi

    # The suites are over; stop the watcher so it cannot answer a later run.
    if [ -n "$watcher_pid" ]; then
      kill "$watcher_pid" 2>/dev/null || true
      wait "$watcher_pid" 2>/dev/null || true
      watcher_pid=""
    fi

    # Pull each per-scenario directory back, replacing only that scenario's
    # evidence. Per-scenario replacement keeps a concurrent macOS lane's
    # artifacts from being merged into this run's report tree (two lanes may
    # share a --results directory). `cp` only reads the container; the results
    # directory is inside the worktree/temporary area.
    mkdir -p "$RESULTS"
    local pulled_any=0 scenario_dir scenario_name live_container
    if live_container="$(sim_app_container "$device_id" 2>/dev/null)" && [ -n "$live_container" ] \
       && [ "$live_container" != "$container" ]; then
      echo "scenarios: app data container moved to $live_container (the test run reinstalled the app)"
      container="$live_container"; stage="$container/Documents/pdsh-scenarios"
    fi
    if [ -d "$stage/results" ]; then
      for scenario_dir in "$stage/results"/*; do
        [ -d "$scenario_dir" ] || continue
        scenario_name="$(basename "$scenario_dir")"
        # Merge the pulled current evidence into the scenario directory; the
        # locally archived history/ must not be deleted by the pull.
        mkdir -p "$RESULTS/$scenario_name"
        cp -R "$scenario_dir/." "$RESULTS/$scenario_name/" 2>/dev/null || true
        pulled_any=1
      done
    fi
    if [ "$pulled_any" -eq 0 ]; then
      echo "scenarios: no simulator result directory was written (see $test_log)" >&2
      [ "$test_rc" -eq 0 ] && test_rc=4
    fi
  else
    # Physical iPhone: the same command shape, staged with devicectl. This
    # branch is NOT_VERIFIED in this repository (no device run); the runbook
    # documents signing and the manual checks.
    local stage_device="$sim_out/staged"
    xcrun devicectl device install app --device "$device_id" "$app" \
      || { echo "scenarios: cannot install the signed app on the device" >&2; return 1; }
    xcrun devicectl device copy to --device "$device_id" \
      --domain-type appDataContainer --domain-identifier "$SIM_PROBE_BUNDLE_ID" \
      --source "$stage_device" --destination "Documents/pdsh-scenarios" \
      --remove-existing-content true \
      || { echo "scenarios: cannot stage inputs on the device" >&2; return 1; }
    local test_rc=0
    (
      if [ "$UPSTREAM" = "real" ]; then
        export TEST_RUNNER_PDSH_MODEL_BASE_URL="$PDSH_MODEL_BASE_URL"
        export TEST_RUNNER_PDSH_MODEL_NAME="$PDSH_MODEL_NAME"
        export TEST_RUNNER_PDSH_MODEL_API_KEY="$PDSH_MODEL_API_KEY"
      fi
      sim_run_with_timeout "$timeout" "xcodebuild test (device)" \
        xcodebuild test-without-building -scheme "$scheme" "${common[@]}"
    ) > "$sim_out/xcodebuild-device-test.log" 2>&1 || test_rc=$?
    local pulled="$sim_out/device-results"
    rm -rf "$pulled"
    mkdir -p "$pulled"
    xcrun devicectl device copy from --device "$device_id" \
      --domain-type appDataContainer --domain-identifier "$SIM_PROBE_BUNDLE_ID" \
      --source "Documents/pdsh-scenarios/results" --destination "$pulled" \
      || echo "scenarios: WARNING: cannot pull results from the device" >&2
    if [ -d "$pulled/results" ]; then
      cp -R "$pulled/results/." "$RESULTS/" 2>/dev/null || true
    elif [ -d "$pulled" ]; then
      cp -R "$pulled/." "$RESULTS/" 2>/dev/null || true
    fi
    if [ "$test_rc" -ne 0 ]; then
      echo "scenarios: device test failed; see $sim_out/xcodebuild-device-test.log" >&2
    fi
  fi

  # Keep the real test exit separate from pre-host staging and from the
  # terminal evidence result. A failed provisional finalize is an evidence
  # failure (for example a malformed pulled report), not an xcodebuild/test
  # failure: it must not hide report-check 4/5, and only the real test exit may
  # outrank those clearer diagnostics.
  local runner_rc="$test_rc"
  local staging_rc=0
  local evidence_rc=0

  # Before the host phase runs any workspace_command, repair a pulled tree
  # that lost .git so the evaluated tree and workspace.tar are the same git
  # checkout (G2-FIX-110), and refresh the provisional index. This finalize
  # runs again after the host phase for the final status.
  if [ -n "$selected" ]; then
    local prepare_rc=0
    finalize_selected_evidence "$selected" || prepare_rc=$?
    staging_rc="$prepare_rc"
  fi

  # Two-phase workspace_command evaluation: the pulled reports carry
  # `pending_host` assertions (the simulator test process cannot spawn
  # /bin/bash). The host phase evaluates them against each selected scenario's
  # pulled materialized workspace, then rewrites report.json with the final
  # verdict and status. It runs for the simulator and the device pull alike; a
  # device run remains NOT_VERIFIED.
  if [ -n "$selected" ]; then
    local host_rc=0
    host_finalize_workspace_commands "$selected" || host_rc=$?
    if [ "$host_rc" -ne 0 ] && [ "$runner_rc" -eq 0 ]; then
      runner_rc=$host_rc
    fi
    # The host phase rewrote report.json, so the index and the attempt
    # snapshot are refreshed after it (G2-FIX-72/123), then the terminal
    # evidence is checked (G2-FIX-128).
    finalize_selected_evidence "$selected" || evidence_rc=$?
    local verify_rc=0
    verify_selected_evidence "$selected" || verify_rc=$?
    if [ "$evidence_rc" -eq 0 ]; then
      evidence_rc="$verify_rc"
    fi
  fi

  local rc
  set +e
  report_check
  local rc_reports=$?
  set -e
  rc="$(scenario_exit_code "$runner_rc" "$evidence_rc" "$rc_reports" "$staging_rc")"
  if [ "$rc" -ne 0 ]; then
    echo "scenarios: FAILED (exit $rc) on the iOS Simulator runner; log $sim_out/xcodebuild-test.log"
  else
    echo "scenarios: PASS"
  fi
  return "$rc"
}

set +e
if [ "$RUN_ON" = "sim" ]; then
  run_on_sim
else
  run_on_macos
fi
rc=$?
set -e
exit "$rc"
