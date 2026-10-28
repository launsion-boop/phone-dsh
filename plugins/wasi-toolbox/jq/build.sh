#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build the jq-compatible WASI executable the Worker toolbox serves.
#
# The engine is the repository's own `pdsh-jaq-wasm` crate over the MIT
# jaq-core/jaq-std/jaq-json libraries already pinned in `shell/Cargo.lock`.
# Artifacts are build products and are never committed: the packer stages
# `jq.wasm` from this output under `bin/jq` in the image.
#
#   bash plugins/wasi-toolbox/jq/build.sh --check
#       Verify the default artifact, building it when missing or stale.
#   bash plugins/wasi-toolbox/jq/build.sh --out DIR
#       Build into an explicit directory (outside the repository).
#
# The build gate runs the produced module through `verify.mjs`, which executes
# the real input-family paths; a file that merely has the right name and magic
# cannot pass.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd -P)"
out="${PDSH_JQ_ARTIFACTS:-${TMPDIR:-/tmp}/pdsh-jq-wasi}"
cache="${PDSH_JQ_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/pdsh-jq-wasi}"
check_only=0
out_explicit=0

usage() {
  sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'jq build: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) check_only=1 ;;
    --out) out="${2:?--out needs a directory}"; out_explicit=1; shift ;;
    --cache) cache="${2:?--cache needs a directory}"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# Verification only needs node. A valid artifact must stay reusable on a
# machine without a Rust toolchain, so cargo/rustup are required only once we
# have decided to (re)build.
command -v node >/dev/null 2>&1 || die "node is required for the artifact verification"

require_build_toolchain() {
  command -v cargo >/dev/null 2>&1 || {
    if [ -x "$HOME/.cargo/bin/cargo" ]; then
      export PATH="$HOME/.cargo/bin:$PATH"
    else
      die "cargo is required to build or rebuild the jq artifact; install the Rust stable toolchain and rerun"
    fi
  }
  if command -v rustup >/dev/null 2>&1; then
    if ! rustup target list --installed 2>/dev/null | grep -qx 'wasm32-wasip1'; then
      printf 'jq build: installing the wasm32-wasip1 Rust target\n' >&2
      rustup target add wasm32-wasip1
    fi
  fi
}

out_parent="$(dirname "$out")"
mkdir -p "$out_parent"
out_real="$(cd "$out_parent" && pwd -P)/$(basename "$out")"
case "$out_real/" in
  "$root"/*) die "--out must be outside the repository (artifacts are never committed): $out_real" ;;
esac
mkdir -p "$out" "$cache"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    node -e "const c=require('node:crypto'),f=require('node:fs');process.stdout.write(c.createHash('sha256').update(f.readFileSync(process.argv[1])).digest('hex'))" "$1"
  fi
}

probe() {
  node --no-warnings "$here/verify.mjs" --wasm "$out/jq.wasm" >/dev/null
}

source_report() {
  node --no-warnings "$here/source-fingerprint.ts" --root "$root"
}

source_fingerprint() {
  node --no-warnings "$here/source-fingerprint.ts" --root "$root" --fingerprint
}

toolchain_identity() {
  printf '%s; %s; target wasm32-wasip1' "$(rustc --version)" "$(cargo --version)"
}

# Verify the bytes, both build reports and the source identity against *this*
# checkout. A wasm with a matching self-digest but a stale source fingerprint
# is not reusable: that is exactly the old artifact-after-source-edit defect.
verify_existing() {
  [ -s "$out/jq.wasm" ] || return 1
  [ -s "$out/sizes.json" ] || return 1
  [ -s "$out/engine.json" ] || return 1
  node --no-warnings --input-type=module - "$root" "$out" "${1:-}" <<'NODE' || return 1
import { readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
const [root, out, expected] = process.argv.slice(2)
const helper = pathToFileURL(join(root, 'plugins/wasi-toolbox/jq/source-fingerprint.ts')).href
const { jqSourceReport, JQ_SOURCE_ALGORITHM } = await import(helper)
const wasm = readFileSync(join(out, 'jq.wasm'))
const sizes = JSON.parse(readFileSync(join(out, 'sizes.json'), 'utf8'))
const engine = JSON.parse(readFileSync(join(out, 'engine.json'), 'utf8'))
const actual = createHash('sha256').update(wasm).digest('hex')
const current = expected === '' ? jqSourceReport(root) : { algorithm: JQ_SOURCE_ALGORITHM, fingerprint: expected }
const fail = message => { process.stderr.write(`jq build: ${message}\n`); process.exit(1) }
if (sizes.jqWasm?.sha256 !== actual) fail(`${out}/sizes.json does not describe the wasm bytes`)
if (sizes.jqWasm?.bytes !== wasm.byteLength) fail(`${out}/sizes.json records the wrong wasm size`)
if (sizes.source?.algorithm !== JQ_SOURCE_ALGORITHM || sizes.source?.fingerprint !== current.fingerprint) {
  fail(`${out}/sizes.json source fingerprint does not match this checkout`)
}
if (engine.source?.algorithm !== JQ_SOURCE_ALGORITHM || engine.source?.fingerprint !== current.fingerprint) {
  fail(`${out}/engine.json source fingerprint does not match this checkout`)
}
if (engine.wasm?.sha256 !== actual) fail(`${out}/engine.json does not describe the wasm bytes`)
if (engine.wasm?.bytes !== wasm.byteLength) fail(`${out}/engine.json records the wrong wasm size`)
const engineName = engine.engine
const sizesEngine = sizes.engine
if (typeof engineName !== 'string' || engineName.trim() === '') {
  fail(`${out}/engine.json has no engine identity`)
}
if (typeof sizesEngine !== 'string' || sizesEngine.trim() === '') {
  fail(`${out}/sizes.json has no engine identity`)
}
if (sizesEngine !== engineName) {
  fail(`${out}/sizes.json and engine.json name different engines`)
}
if (typeof sizes.toolchain !== 'string' || sizes.toolchain === '') fail(`${out}/sizes.json has no toolchain record`)
NODE
  probe
}

fingerprint="$(source_fingerprint)"
if [ "$check_only" -eq 1 ] && verify_existing "$fingerprint"; then
  printf 'jq build: existing artifact verified (%s bytes, source %s)\n' \
    "$(wc -c < "$out/jq.wasm" | tr -d ' ')" "$fingerprint" >&2
  exit 0
fi

if [ "$check_only" -eq 1 ] && [ "$out_explicit" -eq 1 ]; then
  die "existing artifact in $out failed verification (source or bytes are stale); rebuild with build.sh --out $out"
fi

# Everything above is verification-only. Do not demand a Rust toolchain until
# this point: `--check` on a valid artifact must succeed on a machine that has
# no cargo (the prebuilt-artifact configuration used by CI and reviewers).
require_build_toolchain
printf 'jq build: building pdsh-jaq-wasm for wasm32-wasip1 (source %s)\n' "$fingerprint" >&2
toolchain="$(toolchain_identity)"
CARGO_TARGET_DIR="$cache/target" cargo build \
  --manifest-path "$root/shell/Cargo.toml" \
  -p pdsh-jaq-wasm \
  --target wasm32-wasip1 \
  --release \
  --locked
wasm="$cache/target/wasm32-wasip1/release/pdsh-jq.wasm"
[ -s "$wasm" ] || die "cargo reported success but $wasm is missing"
after="$(source_fingerprint)"
[ "$after" = "$fingerprint" ] || die "the jq sources changed during the build (${fingerprint} -> ${after}); rerun"

rm -f "$out/sizes.json" "$out/engine.json" "$out/.jq.wasm.tmp"
cp "$wasm" "$out/.jq.wasm.tmp"
mv -f "$out/.jq.wasm.tmp" "$out/jq.wasm"
node --no-warnings "$here/verify.mjs" \
  --wasm "$out/jq.wasm" \
  --source-fingerprint "$fingerprint" \
  --toolchain "$toolchain" \
  --report "$out/.engine.json.tmp" >/dev/null
mv -f "$out/.engine.json.tmp" "$out/engine.json"
node - "$out" "$(sha256_of "$out/jq.wasm")" "$(wc -c < "$out/jq.wasm" | tr -d ' ')" \
  "$fingerprint" "$(source_report)" "$toolchain" <<'NODE'
const fs = require('node:fs')
const path = require('node:path')
const [out, sha, bytes, fingerprint, sourceJson, toolchain] = process.argv.slice(2)
const source = JSON.parse(sourceJson)
const engine = JSON.parse(fs.readFileSync(path.join(out, 'engine.json'), 'utf8'))
const report = {
  format: 2,
  engine: engine.engine,
  source: {
    algorithm: source.algorithm,
    fingerprint,
    files: source.files,
  },
  jqWasm: { bytes: Number(bytes), sha256: sha },
  toolchain,
}
const target = path.join(out, '.sizes.json.tmp')
fs.writeFileSync(target, `${JSON.stringify(report, null, 2)}\n`)
fs.renameSync(target, path.join(out, 'sizes.json'))
NODE
# Re-run the full verifier against the reports just written. The build must
# never publish a pair that its own --check would reject.
verify_existing "$fingerprint" || die "freshly built artifact failed verification"
printf 'jq build: %s jq.wasm (%s bytes, source %s)\n' \
  "$out" "$(wc -c < "$out/jq.wasm" | tr -d ' ')" "$fingerprint" >&2
