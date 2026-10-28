#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Resolve the jq WASI artifact the Worker image carries.
#
# The bytes are a build product (`plugins/wasi-toolbox/jq/build.sh`) and are
# never committed. An existing verified directory is reused; otherwise the
# pinned engine is built and probed. The directory path goes to stdout; all
# progress stays on stderr.
#
# Env: PDSH_JQ_ARTIFACTS  artifact directory (default $TMPDIR/pdsh-jq-wasi)
#
# Usage: bash scripts/ci/jq-artifacts.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${PDSH_JQ_ARTIFACTS:-${TMPDIR:-/tmp}/pdsh-jq-wasi}"
OUT="${OUT%/}"
BUILD="$ROOT/plugins/wasi-toolbox/jq/build.sh"

# Reuse is only safe after build.sh's own verifier has checked the current
# source fingerprint, both reports, the wasm hash/bytes and the real probe.
# File presence alone would hand smoke/scenarios yesterday's engine after a
# source edit (the packer would reject it later, but only after needless work).
if [ -e "$OUT/jq.wasm" ] || [ -e "$OUT/engine.json" ] || [ -e "$OUT/sizes.json" ]; then
  if bash "$BUILD" --out "$OUT" --check >&2; then
    ( cd "$OUT" && pwd -P )
    exit 0
  fi
  echo "jq artifacts: existing artifact under $OUT is stale or inconsistent; rebuilding" >&2
fi

echo "jq artifacts: building jq.wasm under $OUT" >&2
bash "$BUILD" --out "$OUT" >&2
for file in jq.wasm engine.json sizes.json; do
  [ -s "$OUT/$file" ] || {
    echo "jq artifacts: build.sh reported success but $OUT/$file is missing or empty" >&2
    exit 1
  }
done
( cd "$OUT" && pwd -P )
