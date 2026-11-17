#!/bin/bash
# SPDX-License-Identifier: MIT
#
# aha multi-turn evaluation layer over the existing production-assembly
# runner. It does not boot a second Bot: it calls
# scripts/ci/bot-e2e/eval.sh with the aha catalog, keeps reply bodies for
# independent scoring, then runs score.py over the evidence.
#
# Usage:
#   bash scripts/evals/bot-aha/run.sh [--upstream mock|real] [--only id,...]
#       [--repeat N] [--results DIR]
#
# Real model:
#   eval "$(node scripts/ci/model-env.mjs)"
#   bash scripts/evals/bot-aha/run.sh --upstream real
#
# Exit codes: 0 aha gate PASS, 1 FAIL, 3 NOT_RUN (missing prerequisites or
# mock upstream), 2 usage error. The engine's own summary remains the
# artifact for its assertions; aha-report.{json,md} is the independent aha
# score and never upgrades mock/NOT_RUN into PASS.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CATALOG="$HERE/aha_catalog.json"
DIMENSIONS="$HERE/aha_dimensions.json"
UPSTREAM="mock"
ONLY=""
REPEAT=1
RESULTS=""

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fail_usage() {
  echo "aha-eval: $*" >&2
  usage >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --upstream)
      [ "$#" -ge 2 ] || fail_usage "--upstream needs mock|real"
      UPSTREAM="$2"; shift 2 ;;
    --only)
      [ "$#" -ge 2 ] || fail_usage "--only needs a comma-separated id list"
      ONLY="$2"; shift 2 ;;
    --repeat)
      [ "$#" -ge 2 ] || fail_usage "--repeat needs a positive integer"
      REPEAT="$2"; shift 2 ;;
    --results)
      [ "$#" -ge 2 ] || fail_usage "--results needs a directory"
      RESULTS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail_usage "unknown argument: $1" ;;
  esac
done

case "$UPSTREAM" in mock|real) ;; *) fail_usage "--upstream must be mock or real" ;; esac
case "$REPEAT" in ''|*[!0-9]*) fail_usage "--repeat must be a positive integer" ;; esac
[ "$REPEAT" -ge 1 ] || fail_usage "--repeat must be at least 1"
[ -f "$CATALOG" ] || fail_usage "catalog not found: $CATALOG"

if [ -z "$RESULTS" ]; then
  RESULTS="${TMPDIR:-/tmp}/pdsh-aha-eval/run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
case "$RESULTS" in
  /*) ;;
  *) RESULTS="$(pwd)/$RESULTS" ;;
esac
mkdir -p "$RESULTS"

echo "aha-eval: upstream $UPSTREAM"
echo "aha-eval: catalog $CATALOG"
echo "aha-eval: results $RESULTS"

# Write the run marker before the engine starts. score.py refuses evidence that
# predates this marker (a reused results directory must not contribute stale
# reports from an earlier selection) and binds --only to the actual plan.
python3 - "$RESULTS/aha-run.json" "$CATALOG" "$DIMENSIONS" "$UPSTREAM" "$REPEAT" "$ONLY" <<'PY'
import datetime
import hashlib
import json
import sys
from pathlib import Path

marker, catalog, dimensions, upstream, repeat, only = sys.argv[1:7]


def digest(path: str) -> str:
    value = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            value.update(chunk)
    return value.hexdigest()


document = {
    "schema_version": 1,
    "started_at": datetime.datetime.now(datetime.timezone.utc)
        .isoformat().replace("+00:00", "Z"),
    "catalog_sha256": digest(catalog),
    "dimensions_sha256": digest(dimensions),
    "upstream": upstream,
    "repeat": int(repeat),
    "only": [item for item in only.split(",") if item],
}
Path(marker).write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

# The engine resolves a pinned DSH checkout through this variable (or the
# user-level phone-dsh config). Keep it read-only: the packer only reads it.
if [ -z "${PDSH_DSH_CHECKOUT:-}" ] && [ -f "$HOME/.config/phone-dsh/dsh-checkout" ]; then
  export PDSH_DSH_CHECKOUT="$(sed -n '1p' "$HOME/.config/phone-dsh/dsh-checkout" | tr -d '\r')"
fi

if [ "$UPSTREAM" = "real" ]; then
  missing=""
  for name in PDSH_MODEL_BASE_URL PDSH_MODEL_NAME PDSH_MODEL_API_KEY; do
    if [ -z "${!name:-}" ]; then missing="$missing $name"; fi
  done
  if [ -n "$missing" ]; then
    echo "aha-eval: NOT_RUN: real upstream requires$missing" >&2
    echo "aha-eval: run: eval \"\$(node scripts/ci/model-env.mjs)\" first" >&2
    exit 3
  fi
fi

ENGINE_ARGS=(--catalog "$CATALOG" --upstream "$UPSTREAM" --repeat "$REPEAT"
             --results "$RESULTS" --keep-bodies)
if [ -n "$ONLY" ]; then ENGINE_ARGS+=(--only "$ONLY"); fi

echo "aha-eval: delegating to scripts/ci/bot-e2e/eval.sh (same production assembly)"
bash "$ROOT/scripts/ci/bot-e2e/eval.sh" "${ENGINE_ARGS[@]}"
ENGINE_EXIT=$?
echo "aha-eval: engine exit $ENGINE_EXIT"

python3 "$HERE/score.py" \
  --results "$RESULTS" \
  --catalog "$CATALOG" \
  --dimensions "$DIMENSIONS" \
  --out "$RESULTS" \
  --upstream "$UPSTREAM" \
  --only "$ONLY" \
  --engine-exit "$ENGINE_EXIT"
SCORE_EXIT=$?

echo "aha-eval: aha report $RESULTS/aha-report.md"
exit "$SCORE_EXIT"
