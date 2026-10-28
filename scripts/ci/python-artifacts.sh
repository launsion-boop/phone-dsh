#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Resolve the CPython-on-WASI artifacts the Worker image carries.
#
# The image needs `python.wasm` and `python313.zip` from
# `plugins/wasi-toolbox/python/build.sh`; the bytes are build products and
# are never committed. This helper returns the one directory both names live
# in, building them through build.sh when they are not there yet:
#
#   * an existing pair is reused as-is (the build cache; scenarios.sh reuses
#     the image cache keyed on the artifact digests);
#   * a missing pair is produced by `build.sh --out <dir>`, which downloads
#     the pinned CPython/WASI SDK archives into its own cache and is safe to
#     interrupt and rerun.
#
# The directory path goes to stdout so callers can do
# `dir="$(bash scripts/ci/python-artifacts.sh)"`; every progress or error
# line goes to stderr.
#
# Env: PDSH_PYTHON_ARTIFACTS  artifact directory (default $TMPDIR/pdsh-python-wasi)
#
# Usage: bash scripts/ci/python-artifacts.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${PDSH_PYTHON_ARTIFACTS:-${TMPDIR:-/tmp}/pdsh-python-wasi}"
OUT="${OUT%/}"

have_artifacts() {
  [ -s "$OUT/python.wasm" ] && [ -s "$OUT/python313.zip" ]
}

# Callers run from other working directories, so print one absolute path.
print_out() {
  ( cd "$OUT" && pwd -P )
}

if have_artifacts; then
  print_out
  exit 0
fi

echo "python artifacts: building python.wasm/python313.zip under $OUT" >&2
if ! bash "$ROOT/plugins/wasi-toolbox/python/build.sh" --out "$OUT" >&2; then
  echo "python artifacts: build.sh failed; fix its output above and rerun" >&2
  exit 1
fi

if ! have_artifacts; then
  echo "python artifacts: build.sh reported success but $OUT/python.wasm or $OUT/python313.zip is missing" >&2
  exit 1
fi

print_out
