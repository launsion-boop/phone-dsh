#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build the complete DSH Web frontend for the phone app bundle.
#
# The DSH checkout is a read-only reference: this script verifies it with
# plugins/scripts/dsh-checkout.mjs, clones it into a temporary directory outside
# that tree, checks out the verified commit, installs with an explicit pnpm
# store, and builds @deepseek-ai/dsh-web-frontend there. Nothing in the source
# checkout is written.
#
# The default source is the canonical plugins/dsh-pin.json commit. A release
# that packs a different, already-built DSH checkout must name the same source
# with the paired --commit/--version options, exactly as pack-image's
# --checkout-sha/--checkout-version pair does. The pair never skips
# verification: HEAD, clean tree, built runtime/packer artifacts, and the
# installation version must all match. dsh-pin.json is not modified.
#
# Output (default examples/probe-app/Bundle/worker/web):
#   index.html          apps/web/dist/index.html plus the earliest boot script
#                       (an iOS 17.0 Promise.withResolvers polyfill and the
#                       boot-readiness gate) and the web-boot.js tag injected
#                       before the Vite entry
#   assets/**, ...      the rest of apps/web/dist verbatim
#   web-build.json      actual commit/version, clean/build verification facts,
#                       the canonical pin values, build command, entry path and
#                       sha256
#
# Vite's `base: './'` keeps every asset reference relative, so the page served
# at /static/web/index.html resolves them under /static/web/assets/*.
#
# Usage:
#   bash scripts/ci/build-web-dist.sh [--check] [--out DIR] [--source DIR]
#        [--commit SHA --version VERSION] [--store DIR]
#
# Options:
#   --check        build and validate in a temporary directory; write nothing
#                  under examples/probe-app
#   --out DIR      output directory (default examples/probe-app/Bundle/worker/web)
#   --source DIR   DSH checkout (default PDSH_WEB_SOURCE, PDSH_DSH_CHECKOUT,
#                  ~/.config/phone-dsh/dsh-checkout, then /dsh-reference when it
#                  is a checkout)
#   --commit SHA   controlled checkout override; full 40-character lowercase
#                  commit. Must be supplied with --version and must be the
#                  checkout HEAD. Default: plugins/dsh-pin.json commit.
#   --version V    controlled installation version for the same override; must
#                  match the checkout's apps/cli/package.json. Default:
#                  plugins/dsh-pin.json version.
#   --store DIR    pnpm store (default PDSH_PNPM_STORE; root uses the shared
#                  /root/.local/share/pnpm/store, a non-root user uses
#                  ${TMPDIR:-/tmp}/phone-dsh-pnpm-store). Always pass an
#                  explicit writable --store /tmp/... on a non-root Mac.
#
# The build is deliberately the client-only slice of DSH's artifact graph:
# host declarations + Typert outputs, client declarations + bundles, then the
# Vite web build. It does not build the desktop bundle or the native addon,
# neither of which the Web page uses.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PIN_FILE="$ROOT/plugins/dsh-pin.json"
VERIFIER="$ROOT/plugins/scripts/dsh-checkout.mjs"
DEFAULT_OUT="$ROOT/examples/probe-app/Bundle/worker/web"

CHECK=0
OUT="$DEFAULT_OUT"
FINAL_OUT=""
SOURCE="${PDSH_WEB_SOURCE:-${PDSH_DSH_CHECKOUT:-}}"
SOURCE_SET=0
COMMIT=""
VERSION=""
COMMIT_SET=0
VERSION_SET=0
if [ -n "${PDSH_PNPM_STORE:-}" ]; then
  STORE="$PDSH_PNPM_STORE"
elif [ "$(id -u)" -eq 0 ]; then
  STORE=/root/.local/share/pnpm/store
else
  # pnpm 11 otherwise creates a checkout-local store; a non-root Mac user
  # cannot write /root/. Use a per-user temporary store unless --store wins.
  STORE="${TMPDIR:-/tmp}/phone-dsh-pnpm-store"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --check)   CHECK=1; shift ;;
    --out)     OUT="${2:-}"; shift 2 ;;
    --source)  SOURCE="${2:-}"; SOURCE_SET=1; shift 2 ;;
    --source=*) SOURCE="${1#*=}"; SOURCE_SET=1; shift ;;
    --commit)  COMMIT="${2:-}"; COMMIT_SET=1; shift 2 ;;
    --commit=*) COMMIT="${1#*=}"; COMMIT_SET=1; shift ;;
    --version) VERSION="${2:-}"; VERSION_SET=1; shift 2 ;;
    --version=*) VERSION="${1#*=}"; VERSION_SET=1; shift ;;
    --store)   STORE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,58p' "$0"; exit 0 ;;
    *) echo "build-web-dist: unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() {
  echo "build-web-dist: $*" >&2
  exit 1
}

for tool in git node pnpm; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed"
done

# The client compiler graph is large. Give the build a heap limit above Node's
# small-cgroup default so `tsc -b tsconfig.host.json` is not killed halfway.
case "${NODE_OPTIONS:-}" in
  *max-old-space-size*) ;;
  *) export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=${PDSH_WEB_NODE_HEAP_MB:-6144}" ;;
esac
[ -f "$PIN_FILE" ] || fail "missing $PIN_FILE"
[ -f "$VERIFIER" ] || fail "missing $VERIFIER"

# An explicitly supplied option is not the same as an omitted one. Reject an
# empty value instead of silently falling back to the canonical pin or the
# environment; only a completely absent pair uses the default.
if [ "$SOURCE_SET" -eq 1 ] && [ -z "$SOURCE" ]; then
  fail "--source must not be empty"
fi
if [ "$COMMIT_SET" -eq 1 ] && [ -z "$COMMIT" ]; then
  fail "--commit must not be empty"
fi
if [ "$VERSION_SET" -eq 1 ] && [ -z "$VERSION" ]; then
  fail "--version must not be empty"
fi
# A controlled override is a pair, never a lone SHA or a lone version. If
# either option was provided, both must be.
if [ "$COMMIT_SET" -ne "$VERSION_SET" ]; then
  fail "--commit and --version must be supplied together"
fi
if [ "$COMMIT_SET" -eq 1 ]; then
  [ "${#COMMIT}" -eq 40 ] || fail "--commit must be a full 40-character lowercase hex sha"
  case "$COMMIT" in
    *[!0-9a-f]*) fail "--commit must be a full 40-character lowercase hex sha" ;;
  esac
fi
[ -n "$STORE" ] || fail "pnpm store path must not be empty"

if [ -z "$SOURCE" ] && [ -f "$HOME/.config/phone-dsh/dsh-checkout" ]; then
  SOURCE="$(sed -n '1p' "$HOME/.config/phone-dsh/dsh-checkout" | tr -d '\r')"
fi
if [ -z "$SOURCE" ] && [ -d /dsh-reference/.git ]; then
  SOURCE=/dsh-reference
fi
[ -n "$SOURCE" ] || fail "no DSH checkout: set PDSH_WEB_SOURCE, PDSH_DSH_CHECKOUT or --source"
[ -d "$SOURCE" ] || fail "DSH checkout not found: $SOURCE"
git -C "$SOURCE" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "not a git checkout: $SOURCE"
SOURCE_REAL="$(cd "$SOURCE" && pwd -P)"
ROOT_REAL="$(cd "$ROOT" && pwd -P)"

# Resolve through the nearest existing parent without creating anything. This
# runs before the first mkdir so a rejected path cannot leave a directory (or
# worse, let the later output reset delete) inside the repository or checkout.
resolve_path() {
  node -e '
    const fs = require("node:fs")
    const path = require("node:path")
    let target = path.resolve(process.argv[1])
    const tail = []
    while (!fs.existsSync(target)) {
      const parent = path.dirname(target)
      if (parent === target) break
      tail.unshift(path.basename(target))
      target = parent
    }
    let real = target
    try { real = fs.realpathSync(target) } catch {}
    process.stdout.write(path.join(real, ...tail))
  ' "$1"
}

# The store is a build input, not an output, so it may live under a temporary
# directory. It still may not be the filesystem root, the repository, or the
# source checkout; resolving first also catches a symlink to any of those.
STORE_REAL="$(resolve_path "$STORE")" || fail "cannot resolve pnpm store path: $STORE"
case "$STORE_REAL" in
  "/"|"$ROOT_REAL"|"$ROOT_REAL"/*|"$SOURCE_REAL"|"$SOURCE_REAL"/*)
    fail "refusing to use $STORE as the pnpm store; choose a path outside the repository and the source checkout" ;;
esac
STORE="$STORE_REAL"

if [ "$CHECK" -eq 0 ]; then
  [ -n "$OUT" ] || fail "--out must not be empty"
  FINAL_OUT="$(resolve_path "$OUT")" || fail "cannot resolve output path: $OUT"
  if [ -e "$FINAL_OUT" ] && [ ! -d "$FINAL_OUT" ]; then
    fail "output path is not a directory: $OUT"
  fi
  # Replacing any of these would delete the root filesystem, the repository, or
  # the checkout the build reads. A symlink is checked by its resolved target.
  case "$FINAL_OUT" in
    "/"|"$ROOT_REAL"|"$SOURCE_REAL"|"$SOURCE_REAL"/*)
      fail "refusing to write to $OUT: it is the filesystem root, the repository root, or inside the source checkout" ;;
  esac
  # An ancestor of either tree is not textually inside it but replacing it
  # would still delete that tree.
  case "$ROOT_REAL" in
    "$FINAL_OUT"/*) fail "refusing to write to $OUT: it contains the repository" ;;
  esac
  case "$SOURCE_REAL" in
    "$FINAL_OUT"/*) fail "refusing to write to $OUT: it contains the source checkout" ;;
  esac
  OUT="$FINAL_OUT"
fi

# Verify through the one checkout verifier the image packer uses. The default
# pin is read by that verifier; an override replaces only the expected
# commit/version and still requires a clean, built checkout.
VERIFY_ARGS=(--print-json)
if [ "$COMMIT_SET" -eq 1 ]; then
  VERIFY_ARGS+=(--commit "$COMMIT" --version "$VERSION")
fi
VERIFY_JSON="$(PDSH_DSH_CHECKOUT="$SOURCE_REAL" node "$VERIFIER" "${VERIFY_ARGS[@]}")" \
  || fail "checkout verification failed for $SOURCE_REAL"
FACTS="$(printf '%s' "$VERIFY_JSON" | node -e '
  const fs = require("node:fs")
  let facts
  try {
    facts = JSON.parse(fs.readFileSync(0, "utf8"))
  } catch (reason) {
    console.error(`build-web-dist: cannot parse checkout facts: ${reason.message}`)
    process.exit(1)
  }
  if (typeof facts.head !== "string" || !/^[0-9a-f]{40}$/.test(facts.head)) {
    console.error("build-web-dist: checkout facts have no verified HEAD")
    process.exit(1)
  }
  if (typeof facts.version !== "string" || facts.version === "") {
    console.error("build-web-dist: checkout names no apps/cli version; a version check is required")
    process.exit(1)
  }
  if (typeof facts.pin?.commit !== "string" || typeof facts.pin?.version !== "string") {
    console.error("build-web-dist: checkout facts have no expected pin")
    process.exit(1)
  }
  if (typeof facts.canonicalPin?.commit !== "string" || typeof facts.canonicalPin?.version !== "string") {
    console.error("build-web-dist: checkout facts have no canonical pin")
    process.exit(1)
  }
  process.stdout.write([
    facts.head,
    facts.version,
    facts.canonicalPin.commit,
    facts.canonicalPin.version,
  ].join("\n") + "\n")
')" || fail "checkout verification returned incomplete facts"
VERIFIED_COMMIT="$(printf '%s\n' "$FACTS" | sed -n '1p')"
VERIFIED_VERSION="$(printf '%s\n' "$FACTS" | sed -n '2p')"
PIN_COMMIT="$(printf '%s\n' "$FACTS" | sed -n '3p')"
PIN_VERSION="$(printf '%s\n' "$FACTS" | sed -n '4p')"
[ -n "$VERIFIED_COMMIT" ] && [ -n "$VERIFIED_VERSION" ] \
  || fail "checkout verification returned an empty commit or version"
[ "$VERIFIED_COMMIT" = "$(git -C "$SOURCE_REAL" rev-parse HEAD)" ] \
  || fail "source checkout changed during verification: $SOURCE_REAL"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pdsh-web-dist.XXXXXX")"
OUT_STAGE=""
OUT_OLD=""
cleanup() {
  # Restore a previous output if the process stopped between the two renames.
  if [ -n "$OUT_OLD" ] && [ ! -e "$FINAL_OUT" ]; then
    mv "$OUT_OLD" "$FINAL_OUT" 2>/dev/null || true
    OUT_OLD=""
  fi
  rm -rf "$TMP" "$OUT_STAGE" "$OUT_OLD"
}
trap cleanup EXIT

SRC="$TMP/src"
# `--shared` copies only the refs/objects alternates, never writes into the
# source tree. `--no-checkout` keeps the clone fast; checkout is the verified
# commit from the controlled pair (or the canonical pin by default).
if ! git clone --quiet --shared --no-checkout "$SOURCE_REAL" "$SRC"; then
  fail "cannot clone $SOURCE_REAL into the temporary build tree"
fi
if ! git -C "$SRC" cat-file -e "$VERIFIED_COMMIT^{commit}" 2>/dev/null; then
  fail "verified commit $VERIFIED_COMMIT is not available in the temporary clone"
fi
if ! git -C "$SRC" checkout --quiet --detach "$VERIFIED_COMMIT"; then
  fail "cannot check out verified commit $VERIFIED_COMMIT in the temporary build tree"
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$VERIFIED_COMMIT" ] \
  || fail "temporary tree is not at $VERIFIED_COMMIT"

if [ "$CHECK" -eq 1 ]; then
  OUT="$TMP/out"
  mkdir -p "$OUT"
else
  # Build beside the destination and swap only after the full page and its
  # record validate, so a failed build never truncates an existing dist.
  OUT_PARENT_REAL="$(dirname "$FINAL_OUT")"
  mkdir -p "$OUT_PARENT_REAL"
  OUT_STAGE="$(mktemp -d "$OUT_PARENT_REAL/.web-dist-stage.XXXXXX")"
  OUT="$OUT_STAGE"
fi

# The store is explicit: pnpm 11 otherwise creates a checkout-local store.
mkdir -p "$STORE" 2>/dev/null \
  || fail "cannot create pnpm store $STORE; pass --store <writable-dir> or set PDSH_PNPM_STORE"
[ -w "$STORE" ] \
  || fail "pnpm store is not writable: $STORE; pass --store /tmp/<dir> or set PDSH_PNPM_STORE"
# The build runs inside the temporary clone, so a relative --store would point
# at a different directory there. Record and use the resolved absolute path.
STORE="$(cd "$STORE" && pwd -P)"

BUILD_COMMAND="pnpm install --frozen-lockfile --prefer-offline --store-dir $STORE"
BUILD_COMMAND="$BUILD_COMMAND && pnpm exec tsc -b tsconfig.host.json"
BUILD_COMMAND="$BUILD_COMMAND && pnpm exec tsdown --config-loader native --env.DSH_BUILD_FACE host"
BUILD_COMMAND="$BUILD_COMMAND && pnpm exec tsc -b tsconfig.client.json"
BUILD_COMMAND="$BUILD_COMMAND && pnpm exec tsdown --config-loader native --env.DSH_BUILD_FACE client"
BUILD_COMMAND="$BUILD_COMMAND && pnpm run build:web"

run_step() {
  local label="$1"
  shift
  echo "build-web-dist: $label"
  if ! ( cd "$SRC" && "$@" ) >>"$TMP/build.log" 2>&1; then
    echo "build-web-dist: $label failed; last 80 lines:" >&2
    tail -80 "$TMP/build.log" >&2 || true
    fail "$label failed"
  fi
}

echo "build-web-dist: installing $VERIFIED_VERSION dependencies from commit $VERIFIED_COMMIT (store $STORE)"
run_step "pnpm install" pnpm install --frozen-lockfile --prefer-offline --store-dir "$STORE"
run_step "host declarations" pnpm exec tsc -b tsconfig.host.json
run_step "host bundle" pnpm exec tsdown --config-loader native --env.DSH_BUILD_FACE host
run_step "client declarations" pnpm exec tsc -b tsconfig.client.json
run_step "client bundle" pnpm exec tsdown --config-loader native --env.DSH_BUILD_FACE client
run_step "web frontend" pnpm run build:web

DIST="$SRC/apps/web/dist"
[ -f "$DIST/index.html" ] || fail "web build did not emit apps/web/dist/index.html"
[ -d "$DIST/assets" ] || fail "web build did not emit apps/web/dist/assets"

# "Verbatim" means the dist's file tree and bytes, before the two boot tags.
find "$OUT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -R "$DIST/." "$OUT/"

INDEX="$OUT/index.html"
# Keep the Node snippets in temp files written by a top-level here-document.
# Bash 3.2 (macOS /bin/bash) mis-parses a here-document nested inside a command
# substitution when the body contains quotes, reporting an EOF before the
# closing `)`. Writing the file first leaves the substitution with only a plain
# command, so the same snippet runs under bash 3.2 and newer.
cat >"$TMP/inject-web-boot.cjs" <<'NODE'
const { existsSync, readFileSync, writeFileSync } = require('node:fs')
const { dirname, join } = require('node:path')
const index = process.argv[2]
const html = readFileSync(index, 'utf8')
const entry = /<script\b(?=[^>]*\btype=["']module["'])(?=[^>]*\bsrc=["']\.\/(assets\/[^"']+)["'])[^>]*>\s*<\/script>/i.exec(html)
if (entry === null) throw new Error('vite build has no ./assets module entry in index.html')
// The deployment target is iOS 17.0, but Safari only ships
// Promise.withResolvers in 17.4. Both this readiness gate and the DSH client
// chunks call it, so the earliest classic script installs a feature-detected
// polyfill before web-boot.js or any module bundle can run. The gate itself is
// created without `??=` so this script keeps working on older WebKit too.
const bootReady = [
  '<script>(function () {',
  '  if (typeof Promise.withResolvers !== "function") {',
  '    Promise.withResolvers = function () {',
  '      var resolve, reject;',
  '      var promise = new Promise(function (resolvePromise, rejectPromise) {',
  '        resolve = resolvePromise;',
  '        reject = rejectPromise;',
  '      });',
  '      return { promise: promise, resolve: resolve, reject: reject };',
  '    };',
  '  }',
  '  if (globalThis.__DSH_BOOT_READY__ === undefined) {',
  '    globalThis.__DSH_BOOT_READY__ = Promise.withResolvers();',
  '  }',
  '})();</script>',
].join('\n')
const injected = [
  bootReady,
  '<script type="module" src="./web-boot.js"></script>',
  '',
].join('\n')
const out = html.slice(0, entry.index) + injected + html.slice(entry.index)
// Vite base './' is the contract: no root-relative asset or source URL may
// survive, or the page at /static/web/index.html would request /assets/*.
for (const match of out.matchAll(/(?:src|href)=["'](\/(?:assets|src)\/[^"']*)["']/gi)) {
  throw new Error(`vite build emitted root-relative asset ${match[1]}`)
}
for (const match of out.matchAll(/(?:src|href)=["']\.\/(assets\/[^"']+)["']/gi)) {
  if (!existsSync(join(dirname(index), match[1]))) {
    throw new Error(`vite build references missing ${match[1]}`)
  }
}
writeFileSync(index, out)
process.stdout.write(entry[1])
NODE
ENTRY_REL="$(node "$TMP/inject-web-boot.cjs" "$INDEX")" \
  || fail "cannot inject the Web boot tags into index.html"

[ -n "$ENTRY_REL" ] || fail "cannot determine the Vite entry"
[ -f "$OUT/$ENTRY_REL" ] || fail "Vite entry is missing: $ENTRY_REL"

sha256_file() {
  node -e '
    const crypto = require("node:crypto")
    const fs = require("node:fs")
    process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))
  ' "$1"
}

ENTRY_SHA="$(sha256_file "$OUT/$ENTRY_REL")"
INDEX_SHA="$(sha256_file "$INDEX")"
WEB_VERSION="$(node -e '
  const version = require(process.argv[1]).version
  if (typeof version !== "string" || version === "") process.exit(1)
  process.stdout.write(version)
' "$SRC/apps/web/package.json")" || fail "apps/web/package.json names no version"

cat >"$TMP/write-web-build.cjs" <<'NODE'
const fs = require('node:fs')
const [file, commit, packageVersion, dshVersion, pinCommit, pinVersion,
  command, entry, entrySha, indexSha] = process.argv.slice(2)
const record = {
  source: 'apps/web/dist',
  package: '@deepseek-ai/dsh-web-frontend',
  version: packageVersion,
  // The installation version is the one pack-image records as dsh_version;
  // consumers compare these two fields for same-source staging.
  dsh_version: dshVersion,
  commit,
  dsh_pin_commit: pinCommit,
  dsh_pin_version: pinVersion,
  dsh_checkout_overridden: commit !== pinCommit || dshVersion !== pinVersion,
  command,
  entry,
  entry_sha256: entrySha,
  index: 'index.html',
  index_sha256: indexSha,
  vite_base: './',
  generated_at: new Date().toISOString(),
}
fs.writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`)
NODE
node "$TMP/write-web-build.cjs" "$OUT/web-build.json" "$VERIFIED_COMMIT" \
  "$WEB_VERSION" "$VERIFIED_VERSION" "$PIN_COMMIT" "$PIN_VERSION" \
  "$BUILD_COMMAND" "$ENTRY_REL" "$ENTRY_SHA" "$INDEX_SHA" \
  || fail "cannot write $OUT/web-build.json"

if [ "$CHECK" -eq 0 ]; then
  # Both directories are in the destination's parent, so the swap is a pair of
  # same-filesystem renames. Keep the old dist until the new one is in place.
  if [ -e "$FINAL_OUT" ]; then
    OUT_OLD="$(mktemp -d "$OUT_PARENT_REAL/.web-dist-old.XXXXXX")"
    rmdir "$OUT_OLD"
    mv "$FINAL_OUT" "$OUT_OLD"
  fi
  if ! mv "$OUT_STAGE" "$FINAL_OUT"; then
    if [ -n "$OUT_OLD" ]; then
      mv "$OUT_OLD" "$FINAL_OUT"
      OUT_OLD=""
    fi
    fail "cannot replace $FINAL_OUT with the built Web dist"
  fi
  OUT_STAGE=""
  if [ -n "$OUT_OLD" ]; then
    rm -rf "$OUT_OLD"
    OUT_OLD=""
  fi
  OUT="$FINAL_OUT"
fi

FILE_COUNT="$(find "$OUT" -type f | wc -l | tr -d ' ')"
SIZE="$(du -sh "$OUT" | awk '{print $1}')"
echo "build-web-dist: wrote $OUT ($FILE_COUNT files, $SIZE)"
echo "build-web-dist: commit $VERIFIED_COMMIT ($VERIFIED_VERSION), entry $ENTRY_REL sha256 $ENTRY_SHA"
if [ "$VERIFIED_COMMIT" != "$PIN_COMMIT" ] || [ "$VERIFIED_VERSION" != "$PIN_VERSION" ]; then
  echo "build-web-dist: controlled override from canonical pin $PIN_VERSION $PIN_COMMIT"
fi
if [ "$CHECK" -eq 1 ]; then
  echo "build-web-dist: check ok (temporary output discarded)"
fi
