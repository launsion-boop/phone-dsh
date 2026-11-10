#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Catalog-driven evaluation of the production Bot assembly.
#
# The catalog is validated against scripts/ci/bot-e2e/catalog.schema.json, the
# selected scenarios are normalized into a plan, and a macOS SwiftPM test drives
# the real BotRuntimeComposition on a real PhoneDSHHost with a packed Worker.
# Mock is the default upstream; --upstream real consumes the three PDSH_MODEL_*
# variables the caller already exported (this script never reads a credentials
# file and never echoes a key).
#
# Usage:
#   bash scripts/ci/bot-e2e/eval.sh --catalog <path> [--only id,...]
#       [--upstream mock|real] [--repeat N] [--results DIR] [--keep-bodies]
#
# Evidence: <results>/<id>/{report.json,transcript.jsonl,bot-events.jsonl,
# workspace.tar}; the batch gate is <results>/summary.{json,md}. A stale
# scenario directory is cleared before it is executed.
#
# Env: PDSH_DSH_CHECKOUT        pinned DSH checkout used to pack the Worker
#      PDSH_DSH_WWW / PDSH_DSH_IMAGE  prebuilt Worker bundle (skips the build)
#      PDSH_BOT_EVAL_BUILD_DIR  pack cache (default $TMPDIR/pdsh-bot-eval-build)
#      PDSH_BOT_EVAL_SCRATCH    SwiftPM scratch path
#      PDSH_BOT_EVAL_SPM_CACHE  SwiftPM shared cache path
#      PDSH_NODE                node binary (default: node on PATH)
#      PDSH_SCENARIO_KEEP_BODIES=1  write redacted model requests/responses
#      PDSH_MODEL_BASE_URL PDSH_MODEL_NAME PDSH_MODEL_API_KEY  real upstream only
#
# Exit codes: 0 gate PASS, 1 product/gate FAIL, 2 usage/catalog error,
#             3 NOT_RUN (missing assets/disk/upstream), 6 runner infrastructure.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PYTHON="${PYTHON:-python3}"
CATALOG=""
ONLY=""
UPSTREAM="mock"
REPEAT=1
RESULTS=""
KEEP_BODIES=0

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fail_usage() {
  echo "bot-eval: $*" >&2
  usage >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --catalog)
      [ "$#" -ge 2 ] || fail_usage "--catalog needs a path"
      CATALOG="$2"; shift 2 ;;
    --only)
      [ "$#" -ge 2 ] || fail_usage "--only needs a comma-separated id list"
      ONLY="$2"; shift 2 ;;
    --upstream)
      [ "$#" -ge 2 ] || fail_usage "--upstream needs mock|real"
      UPSTREAM="$2"; shift 2 ;;
    --repeat)
      [ "$#" -ge 2 ] || fail_usage "--repeat needs a positive integer"
      REPEAT="$2"; shift 2 ;;
    --results)
      [ "$#" -ge 2 ] || fail_usage "--results needs a directory"
      RESULTS="$2"; shift 2 ;;
    --keep-bodies) KEEP_BODIES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail_usage "unknown argument: $1" ;;
  esac
done

[ -n "$CATALOG" ] || fail_usage "--catalog is required"
case "$UPSTREAM" in mock|real) ;; *) fail_usage "--upstream must be mock or real" ;; esac
case "$REPEAT" in ''|*[!0-9]*) fail_usage "--repeat must be a positive integer" ;; esac
[ "$REPEAT" -ge 1 ] || fail_usage "--repeat must be at least 1"
[ -f "$CATALOG" ] || fail_usage "catalog not found: $CATALOG"
CATALOG="$(cd "$(dirname "$CATALOG")" && pwd)/$(basename "$CATALOG")"

BASE="${TMPDIR:-/tmp}"
BASE="${BASE%/}"
if [ -z "$RESULTS" ]; then
  RESULTS="$BASE/pdsh-bot-eval/run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
case "$RESULTS" in
  /*) ;;
  *) RESULTS="$(pwd)/$RESULTS" ;;
esac
mkdir -p "$RESULTS"
RESULTS="${RESULTS%/}"
rm -f "$RESULTS/summary.json" "$RESULTS/summary.md" "$RESULTS/gate.log" "$RESULTS/run-status.json"

SELFTEST=0
if "$PYTHON" - "$CATALOG" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if doc.get("selftest") is True else 1)
PY
then
  SELFTEST=1
fi

PLAN="$RESULTS/.plan.json"
PLAN_ARGS=(--catalog "$CATALOG" --results "$RESULTS" --plan-out "$PLAN"
           --repeat "$REPEAT" --upstream "$UPSTREAM")
if [ "$SELFTEST" -eq 1 ]; then PLAN_ARGS+=(--selftest); fi
if [ -n "$ONLY" ]; then PLAN_ARGS+=(--only "$ONLY"); fi
"$PYTHON" "$HERE/eval_catalog.py" plan "${PLAN_ARGS[@]}" || exit $?

if [ "$UPSTREAM" = "real" ]; then
  for name in PDSH_MODEL_BASE_URL PDSH_MODEL_NAME PDSH_MODEL_API_KEY; do
    if [ -z "${!name:-}" ]; then
      echo "bot-eval: --upstream real requires $name; run: eval \"\$(node scripts/ci/model-env.mjs)\"" >&2
      exit 2
    fi
  done
fi

not_run() {
  local reason="$1"
  "$PYTHON" - "$RESULTS" "$reason" <<'PY'
import json, sys, datetime
from pathlib import Path
result = Path(sys.argv[1])
result.mkdir(parents=True, exist_ok=True)
document = {
    "version": 1,
    "gate": "NOT_RUN",
    "reason": sys.argv[2],
    "at": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
}
(result / "run-status.json").write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
print("bot-eval: NOT_RUN: " + sys.argv[2])
PY
  exit 3
}

disk_available_gib() {
  df -g /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4}' || true
}

src_hash() {
  "$PYTHON" - "$ROOT/plugins" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
digest = hashlib.sha256()
skip = {"node_modules", ".build", "dist"}
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = sorted(name for name in dirnames if name not in skip)
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        digest.update(os.path.relpath(path, root).encode())
        digest.update(b"\0")
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
print(digest.hexdigest())
PY
}

checkout_sha() {
  git -C "$1" rev-parse HEAD 2>/dev/null || echo unknown
}

bundle_ready() {
  local www="$1" image="$2"
  [ -f "$www/worker-entry.js" ] && [ -f "$www/index.html" ] \
    && [ -f "$www/boot.js" ] && [ -f "$www/tool-worker-python.js" ] \
    && [ -f "$www/tool-worker.js" ] && [ -f "$image" ]
}

build_bundle() {
  local build="$1" checkout="$2" node="$3"
  local worker="$build/worker-entry" image="$build/image" www="$build/www"
  local prelude="$build/javascriptcore-prelude.js"
  mkdir -p "$build"
  echo "bot-eval: building the Worker entry through plugins/worker-entry/build.mjs"
  ( cd "$ROOT/plugins" && "$node" worker-entry/build.mjs --out "$worker" ) \
    > "$build/build-worker.log" 2>&1 \
    || { tail -40 "$build/build-worker.log" >&2; return 1; }
  local image_args=(scripts/pack-image.mjs --out "$image")
  if [ "${PDSH_BOT_EVAL_WITH_TOOLBOX:-0}" = "1" ]; then
    local python_dir jq_dir
    python_dir="$(bash "$ROOT/scripts/ci/python-artifacts.sh")" || return 1
    jq_dir="$(bash "$ROOT/scripts/ci/jq-artifacts.sh")" || return 1
    image_args+=(--python "$python_dir" --jq "$jq_dir")
  fi
  echo "bot-eval: building the Worker image through plugins/scripts/pack-image.mjs"
  ( cd "$ROOT/plugins" && PDSH_DSH_CHECKOUT="$checkout" "$node" "${image_args[@]}" ) \
    > "$build/build-image.log" 2>&1 \
    || { tail -40 "$build/build-image.log" >&2; return 1; }
  rm -rf "$www"
  mkdir -p "$www/lazy"
  # This prelude is the same JavaScriptCore platform shim scripts/ci/smoke.sh
  # installs before the Worker module graph evaluates; see that script for the
  # long explanation.
  cat > "$prelude" <<'PRELUDE'
// SPDX-License-Identifier: MIT
if (typeof Symbol.dispose === "undefined") {
  Object.defineProperty(Symbol, "dispose", {
    value: Symbol.for("xl.symbol.dispose"), configurable: true,
  });
}
if (typeof Symbol.asyncDispose === "undefined") {
  Object.defineProperty(Symbol, "asyncDispose", {
    value: Symbol.for("xl.symbol.asyncDispose"), configurable: true,
  });
}
if (typeof ReadableStream === "function"
    && typeof ReadableStream.prototype[Symbol.asyncIterator] !== "function") {
  ReadableStream.prototype[Symbol.asyncIterator] = function () {
    var reader = this.getReader();
    return {
      next: function () {
        return reader.read().then(function (result) {
          return result.done ? { done: true, value: undefined } : { done: false, value: result.value };
        });
      },
      return: function () {
        reader.cancel().catch(function () {});
        return Promise.resolve({ done: true, value: undefined });
      },
      throw: function (error) {
        reader.cancel(error).catch(function () {});
        return Promise.reject(error);
      },
    };
  };
}
PRELUDE
  cat "$prelude" "$worker/worker-entry.js" > "$www/worker-entry.js"
  cp "$worker/worker-entry.js.map" "$www/" 2>/dev/null || true
  cp "$worker/www/index.html" "$worker/www/boot.js" "$www/"
  cp "$worker/tool-worker-python.js" "$www/"
  cp "$worker/tool-worker-python.js.map" "$www/" 2>/dev/null || true
  cp "$worker/tool-worker.js" "$www/"
  cp "$worker/tool-worker.js.map" "$www/" 2>/dev/null || true
  cp "$worker/workflow-isolate.js" "$www/"
  cp "$image/image.tar.gz" "$www/"
  if [ -d "$image/lazy" ]; then cp -R "$image/lazy/." "$www/lazy/"; fi
  for extra in worker.js client.js manifest.json sizes.json; do
    if [ -f "$image/$extra" ]; then cp "$image/$extra" "$www/"; fi
  done
  ( cd "$ROOT/plugins" && "$node" scripts/verify-bundle.mjs --create \
      --image-out "$image" --out "$www" ) > "$build/verify.log" 2>&1 || {
    tail -30 "$build/verify.log" >&2
    return 1
  }
  local verify_args=(scripts/verify-bundle.mjs --bundle "$www" --image "$www/image.tar.gz"
                     --provenance "$www/phone-dsh-provenance.json")
  if [ "${PDSH_BOT_EVAL_WITH_TOOLBOX:-0}" = "1" ]; then
    verify_args+=(--python yes --jq yes)
  fi
  ( cd "$ROOT/plugins" && "$node" "${verify_args[@]}" ) > "$build/verify.log" 2>&1 || {
    tail -30 "$build/verify.log" >&2
    return 1
  }
  src_hash > "$build/.source-hash"
  checkout_sha "$checkout" > "$build/.checkout-sha"
}

resolve_bundle() {
  if [ -n "${PDSH_DSH_WWW:-}" ] || [ -n "${PDSH_DSH_IMAGE:-}" ]; then
    [ -n "${PDSH_DSH_WWW:-}" ] && [ -n "${PDSH_DSH_IMAGE:-}" ] \
      || fail_usage "set both PDSH_DSH_WWW and PDSH_DSH_IMAGE"
    bundle_ready "$PDSH_DSH_WWW" "$PDSH_DSH_IMAGE" \
      || not_run "supplied PDSH_DSH_WWW/PDSH_DSH_IMAGE are incomplete"
    WWW="$PDSH_DSH_WWW"
    IMAGE="$PDSH_DSH_IMAGE"
    echo "bot-eval: using prebuilt Worker bundle $WWW"
    return
  fi
  local build="${PDSH_BOT_EVAL_BUILD_DIR:-$BASE/pdsh-bot-eval-build}"
  local www="$build/www" image="$build/www/image.tar.gz"
  local checkout="${PDSH_DSH_CHECKOUT:-}"
  if [ -z "$checkout" ] && [ -f "$HOME/.config/phone-dsh/dsh-checkout" ]; then
    checkout="$(sed -n '1p' "$HOME/.config/phone-dsh/dsh-checkout" | tr -d '\r')"
  fi
  if [ -n "$checkout" ] && [ ! -d "$checkout" ]; then
    not_run "PDSH_DSH_CHECKOUT does not exist: $checkout"
  fi
  local current_hash="" current_sha=""
  if [ -n "$checkout" ]; then
    current_hash="$(src_hash)"
    current_sha="$(checkout_sha "$checkout")"
  fi
  if bundle_ready "$www" "$image" \
     && [ -f "$build/.source-hash" ] && [ -f "$build/.checkout-sha" ] \
     && [ "$(cat "$build/.source-hash")" = "$current_hash" ] \
     && [ "$(cat "$build/.checkout-sha")" = "$current_sha" ]; then
    WWW="$www"; IMAGE="$image"
    echo "bot-eval: reusing the Worker bundle $WWW"
    return
  fi
  if [ -z "$checkout" ]; then
    local candidate
    for candidate in "$ROOT/examples/probe-app/Bundle/worker" \
                     "$ROOT/examples/probe-app/Bundle/worker/web"; do
      if bundle_ready "$candidate" "$candidate/image.tar.gz"; then
        WWW="$candidate"
        IMAGE="$WWW/image.tar.gz"
        echo "bot-eval: using the checked-in ${candidate#"$ROOT"/} (no DSH checkout to rebuild)"
        return
      fi
    done
  fi
  [ -n "$checkout" ] || not_run "PDSH_DSH_CHECKOUT is not set and ~/.config/phone-dsh/dsh-checkout has no checkout; cannot pack the Worker"
  local node="${PDSH_NODE:-$(command -v node || true)}"
  [ -n "$node" ] || not_run "node is not on PATH (set PDSH_NODE)"
  [ -d "$ROOT/plugins/node_modules" ] || not_run "plugins/node_modules is absent; the Worker build needs it"
  echo "bot-eval: packing the Worker bundle under $build"
  build_bundle "$build" "$checkout" "$node" \
    || not_run "Worker bundle build failed (see $build/build-*.log)"
  WWW="$www"; IMAGE="$image"
}

if [ "$UPSTREAM" = "real" ]; then
  echo "bot-eval: upstream real (the key is inherited by the test process and is never printed)"
else
  echo "bot-eval: upstream mock (no model or credential is contacted)"
fi
echo "bot-eval: catalog $CATALOG"
echo "bot-eval: results $RESULTS"
echo "bot-eval: selected plan ${PLAN}"

RESOLVE_BUNDLE_LOG="$RESULTS/bundle.log"
# resolve_bundle prints progress and exits through not_run on failures.
if ! resolve_bundle > "$RESOLVE_BUNDLE_LOG" 2>&1; then
  cat "$RESOLVE_BUNDLE_LOG" >&2 || true
  not_run "could not resolve the Worker bundle"
fi
cat "$RESOLVE_BUNDLE_LOG"
mkdir -p "$WWW/lazy"

AVAILABLE="$(disk_available_gib)"
if [ -n "$AVAILABLE" ] && [ "$AVAILABLE" -lt 8 ]; then
  not_run "only ${AVAILABLE} GiB available; refusing to build (minimum 8 GiB)"
fi

SWIFT="${PDSH_SWIFT:-$(command -v swift || true)}"
[ -n "$SWIFT" ] || not_run "swift is not on PATH"
SPM_SCRATCH="${PDSH_BOT_EVAL_SCRATCH:-$BASE/pdsh-bot-eval-swift-build}"
SPM_CACHE="${PDSH_BOT_EVAL_SPM_CACHE:-}"
if [ -z "$SPM_CACHE" ]; then
  SPM_CACHE="$BASE/pdsh-bot-eval-spm-cache"
  if [ ! -d "$SPM_CACHE/repositories" ] \
     && [ -d "$HOME/Library/Caches/org.swift.swiftpm/repositories" ]; then
    echo "bot-eval: seeding the SwiftPM cache under $SPM_CACHE"
    rm -rf "$SPM_CACHE"
    mkdir -p "$SPM_CACHE"
    cp -R "$HOME/Library/Caches/org.swift.swiftpm/." "$SPM_CACHE/" 2>/dev/null \
      || rm -rf "$SPM_CACHE"
  fi
fi
SWIFT_ARGS=(test --disable-sandbox --scratch-path "$SPM_SCRATCH")
if [ -n "$SPM_CACHE" ] && [ -d "$SPM_CACHE/repositories" ]; then
  SWIFT_ARGS+=(--cache-path "$SPM_CACHE")
fi

export PDSH_BOT_EVAL_PLAN="$PLAN"
export PDSH_BOT_EVAL_RESULTS="$RESULTS"
export PDSH_BOT_EVAL_WWW="$WWW"
export PDSH_BOT_EVAL_IMAGE="$IMAGE"
if [ "$KEEP_BODIES" -eq 1 ]; then
  export PDSH_SCENARIO_KEEP_BODIES=1
fi

echo "bot-eval: running the macOS production-assembly test"
set +e
( cd "$HERE/harness" && "$SWIFT" "${SWIFT_ARGS[@]}" ) \
  > "$RESULTS/swift-test.log" 2>&1
SWIFT_STATUS=$?
set -e

set +e
"$PYTHON" "$HERE/eval_catalog.py" check --plan "$PLAN" --results "$RESULTS" \
  > "$RESULTS/gate.log" 2>&1
GATE_STATUS=$?
set -e
cat "$RESULTS/gate.log"

if [ "$SWIFT_STATUS" -ne 0 ]; then
  echo "bot-eval: the Swift runner failed (exit $SWIFT_STATUS); last 30 log lines:" >&2
  tail -30 "$RESULTS/swift-test.log" >&2 || true
  if [ "$GATE_STATUS" -eq 0 ]; then
    echo "bot-eval: refusing to accept a gate PASS from a failed test process" >&2
    exit 6
  fi
  exit 1
fi
if [ "$GATE_STATUS" -ne 0 ]; then
  echo "bot-eval: gate FAIL; see $RESULTS/summary.md and $RESULTS/gate.log" >&2
  exit 1
fi

echo "bot-eval: gate PASS"
echo "bot-eval: evidence $RESULTS/<scenario>/"
echo "bot-eval: summary $RESULTS/summary.md"
