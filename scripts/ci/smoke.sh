#!/bin/bash
# SPDX-License-Identifier: MIT
#
# macOS end-to-end smoke for the phone DSH host (PLAN W2-SMOKE, G1 rehearsal).
#
# Builds the Worker entry bundle (plugins/worker-entry/build.mjs) and the
# packed Worker image (plugins/scripts/pack-image.mjs) into
# $TMPDIR/pdsh-smoke, assembles the static bundle the loopback origin serves, and
# runs `swift test --filter PhoneDSHSmoke` with PDSH_DSH_WWW / PDSH_DSH_IMAGE
# exported. The test uses a real WKWebView and a scripted model upstream; no
# network model is contacted.
#
# The pinned DSH checkout is resolved from PDSH_DSH_CHECKOUT or the single line of
# $HOME/.config/phone-dsh/dsh-checkout. The script skips ONLY when that checkout
# cannot be resolved; a missing build output is a failure.
#
# Usage: bash scripts/ci/smoke.sh
# Env:   PDSH_DSH_CHECKOUT   pinned DSH checkout (else the per-machine file)
#        PDSH_DSH_WWW        prebuilt static bundle directory (optional)
#        PDSH_DSH_IMAGE      prebuilt image.tar.gz (optional)
#        PDSH_PYTHON_ARTIFACTS  python.wasm/python313.zip directory (optional;
#                          default $TMPDIR/pdsh-python-wasi, built by build.sh)
#        PDSH_JQ_ARTIFACTS   jq.wasm/engine.json directory (optional; default
#                          $TMPDIR/pdsh-jq-wasi, built by wasi-toolbox/jq/build.sh)
#        PDSH_SMOKE_DIR      output directory (default $TMPDIR/pdsh-smoke)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SMOKE_DIR="${PDSH_SMOKE_DIR:-${TMPDIR:-/tmp}/pdsh-smoke}"
SMOKE_DIR="${SMOKE_DIR%/}"
SMOKE_LOG="$SMOKE_DIR/smoke.log"
REPORT="$SMOKE_DIR/smoke-report.json"
mkdir -p "$SMOKE_DIR"
: > "$SMOKE_LOG"

# Capture this run in smoke.log and replay it to the original stdout when the
# script exits. A process-substitution tee would let the caller read smoke.log
# before its last lines flushed; an explicit redirect plus EXIT trap keeps the
# log complete by the time the exit status is observed.
exec 3>&1
exec > "$SMOKE_LOG" 2>&1
finish() {
  local status=$?
  trap - EXIT
  cat "$SMOKE_LOG" >&3 2>/dev/null || true
  exit "$status"
}
trap finish EXIT

echo "smoke: repo $ROOT"
echo "smoke: output $SMOKE_DIR"

# 1. Resolve the pinned checkout. This is the only permitted skip.
if [ -z "${PDSH_DSH_CHECKOUT:-}" ] && [ -f "$HOME/.config/phone-dsh/dsh-checkout" ]; then
  PDSH_DSH_CHECKOUT="$(sed -n '1p' "$HOME/.config/phone-dsh/dsh-checkout" | tr -d '\r')"
fi
if [ -z "${PDSH_DSH_CHECKOUT:-}" ] || [ ! -d "$PDSH_DSH_CHECKOUT" ]; then
  echo "SKIP: PDSH_DSH_CHECKOUT is not set and ~/.config/phone-dsh/dsh-checkout has no checkout path"
  exit 0
fi
export PDSH_DSH_CHECKOUT

# 2. Warm the plugin dependencies: pack-image/bundle need esbuild and
#    typescript from plugins/node_modules.
PLUGIN_DIR="$ROOT/plugins"
LOCK="$PLUGIN_DIR/package-lock.json"
INSTALLED_LOCK="$PLUGIN_DIR/node_modules/.package-lock.json"
if [ ! -d "$PLUGIN_DIR/node_modules" ] || [ ! -f "$INSTALLED_LOCK" ] \
   || [ "$LOCK" -nt "$INSTALLED_LOCK" ]; then
  echo "smoke: warming plugins/node_modules"
  ( cd "$PLUGIN_DIR" && npm install --no-audit --no-fund )
fi

# 3. Build the Worker bundle and image unless both prebuilt outputs are usable.
WORKER_OUT="$SMOKE_DIR/worker-entry"
IMAGE_OUT="$SMOKE_DIR/image"
BUNDLE_DIR="$SMOKE_DIR/www"
if [ -n "${PDSH_DSH_WWW:-}" ] || [ -n "${PDSH_DSH_IMAGE:-}" ]; then
  if [ -z "${PDSH_DSH_WWW:-}" ] || [ -z "${PDSH_DSH_IMAGE:-}" ] \
     || [ ! -f "$PDSH_DSH_IMAGE" ] \
     || [ ! -f "$PDSH_DSH_WWW/worker-entry.js" ] \
     || [ ! -f "$PDSH_DSH_WWW/tool-worker-python.js" ] \
     || [ ! -f "$PDSH_DSH_WWW/tool-worker.js" ] \
     || [ ! -f "$PDSH_DSH_WWW/index.html" ] \
     || [ ! -f "$PDSH_DSH_WWW/boot.js" ]; then
    echo "smoke: FAILED: supplied PDSH_DSH_WWW/PDSH_DSH_IMAGE are incomplete" >&2
    exit 1
  fi
  BUNDLE_DIR="$PDSH_DSH_WWW"
  echo "smoke: using prebuilt PDSH_DSH_WWW=$PDSH_DSH_WWW PDSH_DSH_IMAGE=$PDSH_DSH_IMAGE"
else
  echo "smoke: building the Worker entry bundle"
  node "$PLUGIN_DIR/worker-entry/build.mjs" --out "$WORKER_OUT"
  # W7 python: the scenario batch runs python-category steps, so the image and
  # the static bundle must carry the CPython-on-WASI runtime. build.sh is
  # cached; the helper reuses an existing pair and only builds it once.
  echo "smoke: resolving the CPython-on-WASI artifacts"
  PYTHON_DIR="$(bash "$HERE/python-artifacts.sh")"
  echo "smoke: python artifacts $PYTHON_DIR"
  # The jq engine is a build product too; the default shipping image must carry
  # it, otherwise the shell falls back to the fail-loud shim.
  echo "smoke: resolving the jq WASI engine"
  JQ_DIR="$(bash "$HERE/jq-artifacts.sh")"
  echo "smoke: jq artifacts $JQ_DIR"
  echo "smoke: building the Worker image"
  ( cd "$PLUGIN_DIR" && node "$PLUGIN_DIR/scripts/pack-image.mjs" --out "$IMAGE_OUT" --python "$PYTHON_DIR" --jq "$JQ_DIR" )
  rm -rf "$BUNDLE_DIR"
  mkdir -p "$BUNDLE_DIR/lazy"
  printf '%s\n' \
    "lazy overlay shards are written by plugins/scripts/pack-image.mjs." \
    > "$BUNDLE_DIR/lazy/README.txt"
  # JavaScriptCore (the engine WKWebView embeds) is missing two platform
  # features DSH 0.2.1 relies on:
  #   * the explicit-resource-management symbols used by lowered
  #     `using` / `await using` (`TypeError: Symbol.dispose is not defined`
  #     at session creation);
  #   * async iteration over `ReadableStream`, which the DeepSeek adapter uses
  #     to read SSE (`for await (const frame of events)`), so every model
  #     request fails as TRANSPORT.
  # Both must exist before the entry's module graph evaluates, so prepend the
  # definitions to the built Worker bundle. This is a harness-side shim for a
  # production gap: the W1-ENTRY worker entry must install the same definitions
  # before DSH boots.
  cat > "$SMOKE_DIR/javascriptcore-prelude.js" <<'PRELUDE'
// SPDX-License-Identifier: MIT
// Smoke compatibility prelude for JavaScriptCore platform gaps.
// See scripts/ci/smoke.sh.
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
          return result.done
            ? { done: true, value: undefined }
            : { done: false, value: result.value };
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
  cat "$SMOKE_DIR/javascriptcore-prelude.js" "$WORKER_OUT/worker-entry.js" \
    > "$BUNDLE_DIR/worker-entry.js"
  cp "$WORKER_OUT/worker-entry.js.map" "$BUNDLE_DIR/" 2>/dev/null || true
  cp "$WORKER_OUT/www/index.html" "$WORKER_OUT/www/boot.js" "$BUNDLE_DIR/"
  # Both tool workers must sit beside worker-entry.js: the python runtime
  # spawns tool-worker-python.js, and the generic WASI/jq toolbox spawns
  # tool-worker.js. Without them the toolbox registers tools that can never
  # start a worker.
  cp "$WORKER_OUT/tool-worker-python.js" "$BUNDLE_DIR/"
  cp "$WORKER_OUT/tool-worker-python.js.map" "$BUNDLE_DIR/" 2>/dev/null || true
  cp "$WORKER_OUT/tool-worker.js" "$BUNDLE_DIR/"
  cp "$WORKER_OUT/tool-worker.js.map" "$BUNDLE_DIR/" 2>/dev/null || true
  cp "$WORKER_OUT/workflow-isolate.js" "$BUNDLE_DIR/"
  cp "$IMAGE_OUT/image.tar.gz" "$BUNDLE_DIR/"
  if [ -d "$IMAGE_OUT/lazy" ]; then
    cp -R "$IMAGE_OUT/lazy/." "$BUNDLE_DIR/lazy/"
  fi
  for extra in worker.js client.js manifest.json sizes.json; do
    if [ -f "$IMAGE_OUT/$extra" ]; then
      cp "$IMAGE_OUT/$extra" "$BUNDLE_DIR/"
    fi
  done
  node "$PLUGIN_DIR/scripts/verify-bundle.mjs" --create \
    --image-out "$IMAGE_OUT" \
    --out "$BUNDLE_DIR"
  PDSH_DSH_WWW="$BUNDLE_DIR"
  PDSH_DSH_IMAGE="$BUNDLE_DIR/image.tar.gz"
fi

# 4. Validate the exported paths. A build that produced nothing is a failure,
#    not a silent pass.
if [ ! -f "$PDSH_DSH_IMAGE" ] || [ ! -f "$PDSH_DSH_WWW/worker-entry.js" ] \
   || [ ! -f "$PDSH_DSH_WWW/tool-worker-python.js" ] \
   || [ ! -f "$PDSH_DSH_WWW/tool-worker.js" ] \
   || [ ! -f "$PDSH_DSH_WWW/index.html" ] || [ ! -f "$PDSH_DSH_WWW/boot.js" ]; then
  echo "smoke: FAILED: the Worker bundle or image is missing after the build"
  echo "  PDSH_DSH_WWW=${PDSH_DSH_WWW:-<unset>}"
  echo "  PDSH_DSH_IMAGE=${PDSH_DSH_IMAGE:-<unset>}"
  exit 1
fi
node "$PLUGIN_DIR/scripts/verify-bundle.mjs" \
  --bundle "$PDSH_DSH_WWW" \
  --image "$PDSH_DSH_IMAGE" \
  --provenance "$PDSH_DSH_WWW/phone-dsh-provenance.json" \
  --python yes --jq yes
mkdir -p "$PDSH_DSH_WWW/lazy"
export PDSH_DSH_WWW PDSH_DSH_IMAGE
export PDSH_SMOKE_DIR="$SMOKE_DIR"
echo "smoke: PDSH_DSH_WWW=$PDSH_DSH_WWW"
echo "smoke: PDSH_DSH_IMAGE=$PDSH_DSH_IMAGE"

# 5. Run the test target. `swift test` builds every test target; the filter
#    selects the one end-to-end smoke test. SwiftPM's own sandbox-exec layer is
#    disabled: the swarm/CI harness already runs inside a file sandbox where a
#    nested sandbox_apply is not permitted, and the smoke compiles only this
#    repository's sources against the pinned checkout.
cd "$ROOT"
set +e
swift test --disable-sandbox --filter PhoneDSHSmoke
rc=$?
set -e

if grep -q "skipped" "$SMOKE_LOG" 2>/dev/null; then
  echo "smoke: FAILED: the test skipped; an end-to-end pass is required"
  rc=$(( rc == 0 ? 3 : rc ))
fi

if [ "$rc" -ne 0 ]; then
  echo "smoke: FAILED (exit $rc)"
  if [ -f "$REPORT" ]; then
    echo "smoke: report $REPORT"
    python3 - "$REPORT" <<'PY' || true
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        report = json.load(handle)
except Exception as error:  # noqa: BLE001 - diagnostics only
    print(f"smoke: cannot read the report: {error}")
    raise SystemExit(0)

if report.get("failure"):
    print(f"smoke: failure: {report['failure']}")
print("smoke: last 50 console lines:")
for line in report.get("console_last_50", []):
    print(f"  {line}")
failures = report.get("not_implemented_fail", [])
if failures:
    print(f"smoke: notImplementedFail lines ({len(failures)}):")
    for line in failures:
        print(f"  {line}")
PY
  else
    echo "smoke: no smoke-report.json was written"
  fi
else
  echo "smoke: PASS"
  if [ -f "$REPORT" ]; then
    echo "smoke: report $REPORT"
  fi
fi
exit "$rc"
