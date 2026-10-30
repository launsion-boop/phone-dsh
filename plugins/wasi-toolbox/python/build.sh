#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build CPython's own wasm32-wasi port for the DSH phone WASI toolbox.
#
# The script downloads the pinned CPython source tarball and the pinned WASI
# SDK release, records/validates both sha256 digests from `lockfile.json`, then
# follows CPython's Tools/wasm cross-build recipe (a native build Python plus a
# `wasm32-unknown-wasi` cross build) and emits:
#
#   <out>/python.wasm        CPython 3.13 interpreter for wasm32-wasi
#   <out>/python313.zip      standard library, mounted read-only by runtime.ts
#   <out>/sizes.json         measured artifact sizes and sha256 digests
#   <out>/compression.json   zlib/bz2/lzma + tarfile w:gz probe report
#
# zlib, bzip2 and liblzma are cross-built from pinned sources first and linked
# into python.wasm as built-in extension modules, so `import zlib, bz2, lzma`
# and `tarfile.open(name, "w:gz")` work inside the Worker. Every produced
# interpreter is run through `verify-compression.mjs`; a build that misses a
# compression module fails here instead of shipping a Python that raises
# ModuleNotFoundError at the first `.gz` file.
#
# The spec gate is `build.sh --check && npm test`, and build products never
# enter the repository. `--check` on the *default* output directory therefore
# does not stop at a missing or stale pair: it rebuilds that managed directory
# from the pinned sources and probes the result before exiting 0, so the gate
# can never be green while the compression regression tests have no verified
# interpreter (a pre-fix pair is replaced, not skipped). An explicit `--out`
# is a caller-owned directory, so `--check --out DIR` only verifies it and
# fails loudly when it is stale (used by the regression tests and by release
# callers that stage an existing artifact). A build that cannot provide
# zlib/_bz2/_lzma still fails loudly in both modes.
#
# Artifacts are never committed: the default output directory is under
# $TMPDIR, and an --out directory inside this repository is refused.
#
#   bash wasi-toolbox/python/build.sh --check          # ensure + probe the default artifact (builds it when missing/stale)
#   bash wasi-toolbox/python/build.sh                  # build into $TMPDIR
#   bash wasi-toolbox/python/build.sh --out DIR --jobs 8
#
# Existing downloads/SDK/source trees can be reused with --cache,
# --sdk-archive, --source-archive, --wasi-sdk or --source, which also makes the
# script usable on a machine where github.com is only reachable through a
# mirror.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lock="$here/lockfile.json"
repo_root="$(cd "$here/../../.." && pwd -P)"

cache="${PDSH_PYTHON_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/pdsh-python-wasi}"
cache_explicit=0
if [ -n "${PDSH_PYTHON_CACHE:-}" ]; then cache_explicit=1; fi
out="${TMPDIR:-/tmp}/pdsh-python-wasi"
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
check_only=0
out_explicit=0
sdk_dir="${WASI_SDK_PATH:-}"
source_dir=""
source_archive=""
sdk_archive=""

usage() {
  sed -n '3,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --check                 verify tools and pinned inputs; on the default output
                          directory, rebuild it when the pair is missing or
                          stale and probe the result (the spec gate must not
                          pass unverified). With an explicit --out, only probe
                          that caller-owned directory and fail loud when stale.
  --out DIR               artifact directory (default: $TMPDIR/pdsh-python-wasi)
  --cache DIR             download/extract cache (default: ~/.cache/pdsh-python-wasi;
                          falls back to $TMPDIR/pdsh-python-cache when not writable)
  --jobs N                parallel make jobs (default: CPU count)
  --wasi-sdk DIR          use an already extracted WASI SDK instead of downloading
  --source DIR            use an already extracted CPython source tree
  --source-archive FILE   reuse a downloaded CPython .tar.xz
  --sdk-archive FILE      reuse a downloaded WASI SDK .tar.gz
  --help                  this text
EOF
}

die() {
  printf 'python build: %s\n' "$*" >&2
  exit 1
}

say() {
  printf 'python build: %s\n' "$*"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) check_only=1 ;;
    --out) out="${2:?--out needs a directory}"; out_explicit=1; shift ;;
    --cache) cache="${2:?--cache needs a directory}"; shift ;;
    --jobs) jobs="${2:?--jobs needs a number}"; shift ;;
    --wasi-sdk) sdk_dir="${2:?--wasi-sdk needs a directory}"; shift ;;
    --source) source_dir="${2:?--source needs a directory}"; shift ;;
    --source-archive) source_archive="${2:?--source-archive needs a file}"; shift ;;
    --sdk-archive) sdk_archive="${2:?--sdk-archive needs a file}"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

case "$jobs" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$jobs" -ge 1 ] || die "--jobs must be a positive integer"

# A restricted CI sandbox may allow $TMPDIR but not $HOME. Only the implicit
# cache falls back; an explicit PDSH_PYTHON_CACHE that cannot be created fails
# loudly instead of silently using another directory.
if [ "$cache_explicit" -eq 0 ] && ! mkdir -p "$cache" 2>/dev/null; then
  fallback_cache="${TMPDIR:-/tmp}/pdsh-python-cache"
  say "cache $cache is not writable; using $fallback_cache"
  cache="$fallback_cache"
fi

have() {
  command -v "$1" >/dev/null 2>&1
}

sha256_of() {
  if have sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif have python3; then
    python3 - "$1" <<'PY'
import hashlib, sys
digest = hashlib.sha256()
with open(sys.argv[1], 'rb') as handle:
    for chunk in iter(lambda: handle.read(1 << 20), b''):
        digest.update(chunk)
print(digest.hexdigest())
PY
  else
    die "no sha256 tool (need sha256sum, shasum or python3)"
  fi
}

lock_value() {
  python3 - "$lock" "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    value = json.load(handle)
for key in sys.argv[2].split('.'):
    value = value[key]
print(value)
PY
}

[ -f "$lock" ] || die "missing lockfile: $lock"
have python3 || die "python3 is required to read $lock"

cpython_version="$(lock_value cpython.version)"
cpython_url="$(lock_value cpython.url)"
cpython_sha="$(lock_value cpython.sha256)"
sdk_version="$(lock_value wasiSdk.version)"
sdk_release="$(lock_value wasiSdk.release)"

# The compression sources are pinned like the interpreter: the interpreter
# cannot import zlib/_bz2/_lzma unless these static libraries are linked in.
zlib_version="$(lock_value compression.zlib.version)"
zlib_url="$(lock_value compression.zlib.url)"
zlib_sha="$(lock_value compression.zlib.sha256)"
zlib_dir="$(lock_value compression.zlib.dir)"
zlib_license="$(lock_value compression.zlib.license)"
bzip2_version="$(lock_value compression.bzip2.version)"
bzip2_url="$(lock_value compression.bzip2.url)"
bzip2_sha="$(lock_value compression.bzip2.sha256)"
bzip2_dir="$(lock_value compression.bzip2.dir)"
bzip2_license="$(lock_value compression.bzip2.license)"
pdsh_version="$(lock_value compression.xz.version)"
pdsh_url="$(lock_value compression.xz.url)"
pdsh_sha="$(lock_value compression.xz.sha256)"
pdsh_dir="$(lock_value compression.xz.dir)"
pdsh_license="$(lock_value compression.xz.license)"
deps_dir="$cache/deps/wasm32-wasi"

host_os="$(uname -s)"
host_arch="$(uname -m)"
case "$host_os:$host_arch" in
  Darwin:arm64) sdk_key="arm64-darwin" ;;
  Darwin:x86_64) sdk_key="x86_64-darwin" ;;
  *) sdk_key="" ;;
esac
if [ -n "$sdk_key" ]; then
  sdk_asset="$(lock_value "wasiSdk.assets.$sdk_key.name")"
  sdk_url="$(lock_value "wasiSdk.assets.$sdk_key.url")"
  sdk_sha="$(lock_value "wasiSdk.assets.$sdk_key.sha256")"
else
  sdk_asset=""
  sdk_url=""
  sdk_sha=""
fi

tar_name="Python-$cpython_version.tar.xz"
source_archive="${source_archive:-$cache/downloads/$tar_name}"
if [ -z "$sdk_archive" ] && [ -n "$sdk_asset" ]; then
  sdk_archive="$cache/downloads/$sdk_asset"
fi
zlib_archive="$cache/downloads/zlib-$zlib_version.tar.gz"
bzip2_archive="$cache/downloads/bzip2-$bzip2_version.tar.gz"
pdsh_archive="$cache/downloads/xz-$pdsh_version.tar.gz"

python3 - "$lock" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)
if not data.get('cpython', {}).get('version', '').startswith('3.13.'):
    raise SystemExit('lockfile: cpython.version must be a 3.13.x release')
for key in ('url', 'sha256'):
    if not data['cpython'].get(key):
        raise SystemExit(f'lockfile: cpython.{key} is missing')
if not data.get('wasiSdk', {}).get('version'):
    raise SystemExit('lockfile: wasiSdk.version is missing')
compression = data.get('compression')
if not isinstance(compression, dict):
    raise SystemExit('lockfile: compression is missing; python.wasm needs zlib, bz2 and lzma')
for name in ('zlib', 'bzip2', 'xz'):
    entry = compression.get(name)
    if not isinstance(entry, dict):
        raise SystemExit(f'lockfile: compression.{name} is missing')
    for key in ('version', 'url', 'sha256', 'dir', 'license'):
        if not entry.get(key):
            raise SystemExit(f'lockfile: compression.{name}.{key} is missing')
    if len(entry['sha256']) != 64:
        raise SystemExit(f'lockfile: compression.{name}.sha256 must be 64 hex characters')
PY

printf 'python build: CPython %s\n' "$cpython_version"
printf '  source : %s\n' "$cpython_url"
printf '  sha256 : %s\n' "$cpython_sha"
printf 'python build: WASI SDK %s (%s)\n' "$sdk_version" "$sdk_release"
if [ -n "$sdk_asset" ]; then
  printf '  asset  : %s\n' "$sdk_asset"
  printf '  url    : %s\n' "$sdk_url"
  printf '  sha256 : %s\n' "$sdk_sha"
else
  printf '  asset  : no pinned asset for %s/%s; pass --wasi-sdk\n' "$host_os" "$host_arch"
fi
printf 'python build: compression modules zlib, bz2, lzma (required in python.wasm)\n'
printf '  zlib   %-8s %-14s %s\n' "$zlib_version" "$zlib_license" "$zlib_url"
printf '  bzip2  %-8s %-14s %s\n' "$bzip2_version" "$bzip2_license" "$bzip2_url"
printf '  xz     %-8s %-14s %s\n' "$pdsh_version" "$pdsh_license" "$pdsh_url"
printf 'python build: cache %s\n' "$cache"
printf 'python build: deps  %s\n' "$deps_dir"
printf 'python build: out   %s\n' "$out"
printf 'python build: jobs  %s\n' "$jobs"

missing_tools=0
for tool in bash make python3 curl tar node; do
  if have "$tool"; then
    printf '  tool %-10s ok\n' "$tool"
  else
    printf '  tool %-10s MISSING\n' "$tool"
    missing_tools=1
  fi
done
if have sha256sum || have shasum; then
  printf '  tool %-10s ok\n' "sha256"
else
  printf '  tool %-10s MISSING (sha256sum or shasum)\n' "sha256"
  missing_tools=1
fi

if [ -n "$source_dir" ]; then
  [ -f "$source_dir/configure" ] || die "--source does not look like a CPython tree: $source_dir"
  printf '  source tree    : reuse %s\n' "$source_dir"
elif [ -f "$source_archive" ]; then
  printf '  source archive : cached %s\n' "$source_archive"
else
  printf '  source archive : would download %s\n' "$cpython_url"
fi
if [ -n "$sdk_dir" ]; then
  [ -x "$sdk_dir/bin/clang" ] || die "--wasi-sdk has no bin/clang: $sdk_dir"
  printf '  wasi sdk       : reuse %s\n' "$sdk_dir"
elif [ -n "$sdk_archive" ] && [ -f "$sdk_archive" ]; then
  printf '  wasi sdk       : cached %s\n' "$sdk_archive"
elif [ -n "$sdk_url" ]; then
  printf '  wasi sdk       : would download %s\n' "$sdk_url"
else
  printf '  wasi sdk       : would need --wasi-sdk on this host\n'
fi
if [ -f "$out/python.wasm" ]; then
  printf '  existing       : %s (%s bytes)\n' "$out/python.wasm" "$(wc -c < "$out/python.wasm" | tr -d ' ')"
fi
printf '  compression    : zlib %s, bzip2 %s, liblzma %s\n' "$zlib_version" "$bzip2_version" "$pdsh_version"
for archive in "$zlib_archive" "$bzip2_archive" "$pdsh_archive"; do
  if [ -f "$archive" ]; then
    printf '  cached         : %s\n' "$archive"
  else
    printf '  would download : %s\n' "$archive"
  fi
done

cat <<EOF
python build: planned steps
  1. verify sha256 of the CPython source archive ($cpython_sha)
  2. cross-build zlib $zlib_version, bzip2 $bzip2_version and liblzma $pdsh_version
     as wasm32-wasi static libraries under $deps_dir
  3. extract CPython under $cache/src and build the native build Python
       cd "$cache/src/Python-$cpython_version/builddir/build"
       ../../configure -C && make -s -j $jobs all
  4. cross-build with the WASI SDK, pointing configure at the compression
     libraries and failing if zlib, _bz2 or _lzma is not detected
       cd "$cache/src/Python-$cpython_version/builddir/wasi"
       CPPFLAGS=-I$deps_dir/include LDFLAGS=-L$deps_dir/lib \\
         CONFIG_SITE=.../Tools/wasm/config.site-wasm32-wasi \\
         .../Tools/wasm/wasi-env .../configure -C \\
         --host=wasm32-unknown-wasi --build=\$(.../config.guess) \\
         --with-build-python=../build/python.exe
       make -s -j $jobs all
  5. copy builddir/wasi/python.wasm to $out/python.wasm
  6. zip Lib/ plus build/lib.wasi-wasm32-<major.minor>/ (test suites and GUI
     packages excluded) as $out/python313.zip with ZIP_STORED entries; the zip
     must carry tarfile.py, gzip.py, bz2.py, lzma.py and the zipfile package
  7. run verify-compression.mjs against the produced runtime: import zlib, bz2,
     lzma, a tarfile w:gz write/read roundtrip and a host-side gunzip must pass
  8. write $out/compression.json and $out/sizes.json with the probe report,
     artifact bytes and sha256
EOF

if [ "$missing_tools" -ne 0 ]; then
  die "required tools are missing; install them and rerun --check"
fi

# Probe an existing pair in --out. This is the gate that stops a stale
# pre-compression artifact (built before zlib/_bz2/_lzma were linked in) from
# being packed into an image just because build.sh was not run again. For the
# managed default directory it also requires the reports a verified build
# writes: a pair without them has no provenance, and python-artifacts.ts treats
# exactly such a pair as unverified, so accepting it here would let --check
# pass while `npm test` had nothing to run.
probe_existing_artifact() {
  wasm="$out/python.wasm"
  zip="$out/python313.zip"
  [ -f "$wasm" ] || die "incomplete artifact: $wasm is missing (rebuild with build.sh --out $out)"
  [ -f "$zip" ] || die "incomplete artifact: $zip is missing (rebuild with build.sh --out $out)"
  # The managed default directory is the spec gate's output; require the
  # reports a verified build writes so `--check` and python-artifacts.ts agree
  # on what "verified" means. An explicit --out may be a caller-staged pair,
  # so it is judged by the capability probe (and by sizes.json when present).
  if [ "$out_explicit" -eq 0 ]; then
    [ -f "$out/sizes.json" ] || die "$out/sizes.json is missing; the pair has no verified build report (rebuild with build.sh --out $out)"
    [ -f "$out/compression.json" ] || die "$out/compression.json is missing; the pair predates the zlib/bz2/lzma build or was copied without its report (rebuild with build.sh --out $out)"
  fi
  say "probing the existing runtime for zlib, bz2, lzma and tarfile w:gz"
  if ! NODE_NO_WARNINGS=1 node "$here/verify-compression.mjs" --wasm "$wasm" --stdlib "$zip"; then
    die "existing artifact $wasm lacks the compression standard library; rebuild with build.sh --out $out"
  fi
  if [ -f "$out/sizes.json" ]; then
    python3 - "$out/sizes.json" "$(sha256_of "$wasm")" "$(sha256_of "$zip")" <<'PY'
import json, sys
path, actual_wasm, actual_zip = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding='utf-8') as handle:
    report = json.load(handle)
recorded = report.get('pythonWasm', {}).get('sha256')
if recorded != actual_wasm:
    raise SystemExit(f'{path}: pythonWasm.sha256 is {recorded}, but python.wasm is {actual_wasm}; rebuild the artifact')
recorded = report.get('pythonStdlibZip', {}).get('sha256')
if recorded != actual_zip:
    raise SystemExit(f'{path}: pythonStdlibZip.sha256 is {recorded}, but python313.zip is {actual_zip}; rebuild the artifact')
compression = report.get('compression')
if not isinstance(compression, dict):
    raise SystemExit(f'{path}: no compression record; the artifact predates the zlib/bz2/lzma build, rebuild it')
modules = sorted(compression.get('modules') or [])
if modules != ['bz2', 'lzma', 'zlib']:
    raise SystemExit(f'{path}: compression.modules is {modules}, expected bz2/lzma/zlib; rebuild the artifact')
if compression.get('tarfileGzip') is not True:
    raise SystemExit(f'{path}: compression.tarfileGzip is not true; rebuild the artifact')
PY
  fi
}

# node --test runs files in separate processes. Serialize probes as well as
# builds: an unlocked reader can otherwise observe a pair while another build
# is replacing it and report a transient, empty compression probe failure.
mkdir -p "$cache"
build_lock="$cache/.build.lock"
build_lock_owned=0
release_build_lock() {
  if [ "$build_lock_owned" -eq 1 ]; then
    rm -f "$build_lock/pid"
    rmdir "$build_lock" 2>/dev/null || true
  fi
}
trap release_build_lock EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

lock_wait_announced=0
while ! mkdir "$build_lock" 2>/dev/null; do
  if [ "$lock_wait_announced" -eq 0 ]; then
    say "waiting for another build using $cache"
    lock_wait_announced=1
  fi
  lock_pid="$(cat "$build_lock/pid" 2>/dev/null || true)"
  case "$lock_pid" in
    ''|*[!0-9]*) ;;
    *)
      if ! kill -0 "$lock_pid" 2>/dev/null; then
        # Do not remove a lock that changed owners after the liveness check.
        if [ "$(cat "$build_lock/pid" 2>/dev/null || true)" = "$lock_pid" ]; then
          rm -f "$build_lock/pid"
          rmdir "$build_lock" 2>/dev/null || true
        fi
      fi
      ;;
  esac
  sleep 1
done
printf '%s\n' "$$" > "$build_lock/pid"
build_lock_owned=1

if [ "$check_only" -eq 1 ]; then
  if [ -e "$out/python.wasm" ] || [ -e "$out/python313.zip" ]; then
    # A probe/report failure in the managed default directory is not a reason
    # to leave the gate red: rebuild the pair from the pinned sources and probe
    # the new one. A caller-owned explicit --out is never overwritten.
    if ( probe_existing_artifact ); then
      say "existing artifact: compression capabilities verified"
      say "--check: no download and no build performed"
      exit 0
    fi
    if [ "$out_explicit" -eq 1 ]; then
      die "existing artifact in $out failed verification; rebuild with build.sh --out $out"
    fi
    say "the default artifact in $out is missing, stale or unverified; rebuilding it"
    say "so the spec gate cannot pass while the compression tests have no verified interpreter"
  elif [ "$out_explicit" -eq 1 ]; then
    say "existing artifact: none under $out yet; compression capability is NOT verified"
    say "build and probe one with: bash $0 --out $out"
    say "do not pack a python artifact from a directory that has not passed this check"
    say "--check: no download and no build performed"
    exit 0
  else
    say "existing artifact: none under $out yet; building and probing one"
    say "so the spec gate cannot pass while the compression tests have no verified interpreter"
  fi
  # Fall through to the build; its final verify-compression.mjs probe is the
  # same assertion, and assert_compression_modules still fails loudly when
  # configure cannot provide zlib/_bz2/_lzma.
  say "--check: the default artifact needs a build; downloads and builds may run"
fi

out_parent="$(dirname "$out")"
mkdir -p "$out_parent"
out_real="$(cd "$out_parent" && pwd -P)/$(basename "$out")"
case "$out_real/" in
  "$repo_root"/*) die "--out must be outside the repository (artifacts are never committed): $out_real" ;;
esac
mkdir -p "$out" "$cache/downloads" "$cache/src"

fetch() {
  url="$1"
  target="$2"
  expected="$3"
  if [ -f "$target" ]; then
    actual="$(sha256_of "$target")"
    if [ "$actual" = "$expected" ]; then
      say "using cached $(basename "$target")"
      return 0
    fi
    say "cached $(basename "$target") has sha256 $actual, expected $expected; re-downloading"
    rm -f "$target"
  fi
  say "downloading $url"
  tmp="$target.part"
  rm -f "$tmp"
  curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url" || {
    rm -f "$tmp"
    die "download failed: $url"
  }
  actual="$(sha256_of "$tmp")"
  [ "$actual" = "$expected" ] || {
    rm -f "$tmp"
    die "sha256 mismatch for $(basename "$target"): got $actual, expected $expected"
  }
  mv "$tmp" "$target"
}

extract_top() {
  archive="$1"
  destination="$2"
  expected_top="$3"
  if [ -d "$destination/$expected_top" ]; then
    return 0
  fi
  say "extracting $(basename "$archive")"
  mkdir -p "$destination"
  tar -xf "$archive" -C "$destination"
  [ -d "$destination/$expected_top" ] || die "unexpected archive layout: $destination/$expected_top is missing"
}

# Cross-compile one compression library with the pinned WASI SDK. The
# interpreter links these archives statically, so the modules exist inside
# python.wasm without any dynamic loading.
wasm_cc() {
  "$sdk_dir/bin/clang" "--sysroot=$sdk_dir/share/wasi-sysroot" "$@"
}

wasm_ar() {
  "$sdk_dir/bin/llvm-ar" "$@"
}

build_zlib() {
  src="$1"
  say "cross-building zlib $zlib_version (${zlib_license})"
  (
    cd "$src"
    rm -f ./*.o ./libz.a
    for object in adler32 crc32 deflate infback inffast inflate inftrees trees zutil \
                  compress uncompr gzclose gzlib gzread gzwrite; do
      wasm_cc -O2 -DHAVE_UNISTD_H -I. -c "$object.c" -o "$object.o"
    done
    wasm_ar rcs libz.a ./*.o
    cp zlib.h zconf.h "$deps_dir/include/"
    cp libz.a "$deps_dir/lib/libz.a"
  ) || die "building zlib failed; python.wasm would have no zlib module"
}

build_bzip2() {
  src="$1"
  say "cross-building bzip2 $bzip2_version (${bzip2_license})"
  (
    cd "$src"
    rm -f ./*.o ./libbz2.a
    for object in blocksort huffman crctable randtable compress decompress bzlib; do
      wasm_cc -O2 -D_FILE_OFFSET_BITS=64 -I. -c "$object.c" -o "$object.o"
    done
    wasm_ar rcs libbz2.a ./*.o
    cp bzlib.h "$deps_dir/include/"
    cp libbz2.a "$deps_dir/lib/libbz2.a"
  ) || die "building bzip2 failed; python.wasm would have no _bz2 module"
}

build_lzma() {
  src="$1"
  say "cross-building liblzma $pdsh_version (${pdsh_license}; command line tools disabled)"
  (
    cd "$src"
    [ -f configure ] || die "the liblzma source archive has no configure script"
    ./configure \
      --host=wasm32-unknown-wasi \
      --build="$("$src/build-aux/config.guess")" \
      --prefix="$deps_dir" \
      --disable-shared --enable-static \
      --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
      --disable-scripts --disable-doc --disable-nls --disable-threads \
      CC="$sdk_dir/bin/clang --sysroot=$sdk_dir/share/wasi-sysroot" \
      AR="$sdk_dir/bin/llvm-ar" RANLIB="$sdk_dir/bin/ranlib" \
      CFLAGS="-O2" >"$cache/liblzma-configure.log" 2>&1 \
      || die "configuring liblzma failed: see $cache/liblzma-configure.log"
    make -s -j "$jobs" || die "building liblzma failed; python.wasm would have no _lzma module"
    make -s install || die "installing liblzma failed"
  )
}

ensure_compression_deps() {
  mkdir -p "$deps_dir/include" "$deps_dir/lib"
  if [ ! -f "$deps_dir/lib/libz.a" ]; then
    fetch "$zlib_url" "$zlib_archive" "$zlib_sha"
    extract_top "$zlib_archive" "$cache/src" "$zlib_dir"
    build_zlib "$cache/src/$zlib_dir"
  else
    say "using cached zlib build ($deps_dir/lib/libz.a)"
  fi
  if [ ! -f "$deps_dir/lib/libbz2.a" ]; then
    fetch "$bzip2_url" "$bzip2_archive" "$bzip2_sha"
    extract_top "$bzip2_archive" "$cache/src" "$bzip2_dir"
    build_bzip2 "$cache/src/$bzip2_dir"
  else
    say "using cached bzip2 build ($deps_dir/lib/libbz2.a)"
  fi
  if [ ! -f "$deps_dir/lib/liblzma.a" ]; then
    fetch "$pdsh_url" "$pdsh_archive" "$pdsh_sha"
    extract_top "$pdsh_archive" "$cache/src" "$pdsh_dir"
    build_lzma "$cache/src/$pdsh_dir"
  else
    say "using cached liblzma build ($deps_dir/lib/liblzma.a)"
  fi
  for library in libz.a libbz2.a liblzma.a; do
    [ -f "$deps_dir/lib/$library" ] || die "compression library $library was not produced under $deps_dir/lib"
  done
  for header in zlib.h bzlib.h lzma.h; do
    [ -f "$deps_dir/include/$header" ] || die "compression header $header was not produced under $deps_dir/include"
  done
}

# After configure, the generated Modules/Setup.stdlib lists exactly the
# extension modules that will be linked into python.wasm. A missing line means
# CPython did not find the library, and the interpreter would raise
# ModuleNotFoundError at the first import. Fail here, not at runtime.
assert_compression_modules() {
  for entry in "zlib zlibmodule.c" "_bz2 _bz2module.c" "_lzma _lzmamodule.c"; do
    set -- $entry
    grep -Eq "^$1[[:space:]]+$2$" "$wasi_build/Modules/Setup.stdlib" || {
      grep -E 'checking for stdlib extension module (zlib|_bz2|_lzma)' "$wasi_build/configure.log" >&2 || true
      die "configure did not detect the $1 extension module; refusing to build a Python without compression support (contract gap: record it instead of shipping a silent gap)"
    }
  done
  say "configure detected zlib, _bz2 and _lzma; linking them into python.wasm"
}

if [ -z "$sdk_dir" ]; then
  [ -n "$sdk_asset" ] || die "no pinned WASI SDK asset for $host_os/$host_arch; pass --wasi-sdk"
  [ -n "$sdk_archive" ] || die "no WASI SDK archive for $host_os/$host_arch; pass --wasi-sdk or --sdk-archive"
  if [ ! -f "$sdk_archive" ]; then
    [ -n "$sdk_url" ] || die "no download URL for this host; pass --sdk-archive"
    fetch "$sdk_url" "$sdk_archive" "$sdk_sha"
  else
    actual="$(sha256_of "$sdk_archive")"
    [ "$actual" = "$sdk_sha" ] || die "sha256 mismatch for $sdk_archive: got $actual, expected $sdk_sha"
  fi
  extract_top "$sdk_archive" "$cache/wasi-sdk" "${sdk_asset%.tar.gz}"
  sdk_dir="$cache/wasi-sdk/${sdk_asset%.tar.gz}"
fi

if [ -z "$source_dir" ]; then
  if [ ! -f "$source_archive" ]; then
    fetch "$cpython_url" "$source_archive" "$cpython_sha"
  else
    actual="$(sha256_of "$source_archive")"
    [ "$actual" = "$cpython_sha" ] || die "sha256 mismatch for $source_archive: got $actual, expected $cpython_sha"
  fi
  extract_top "$source_archive" "$cache/src" "Python-$cpython_version"
  source_dir="$cache/src/Python-$cpython_version"
fi

[ -x "$sdk_dir/bin/clang" ] || die "WASI SDK at $sdk_dir has no executable bin/clang"
[ -f "$source_dir/configure" ] || die "source tree at $source_dir has no configure"
[ -x "$source_dir/Tools/wasm/wasi-env" ] || die "source tree has no executable Tools/wasm/wasi-env"

say "building the native build Python"
build_dir="$source_dir/builddir/build"
if [ ! -x "$build_dir/python.exe" ] && [ ! -x "$build_dir/python" ]; then
  mkdir -p "$build_dir"
  (
    cd "$build_dir"
    # The build Python only supports the cross-build; host OpenSSL modules are
    # optional and can mismatch the runner's headers and dynamic libraries.
    ac_cv_working_openssl_ssl=no \
    ac_cv_working_openssl_hashlib=no \
      ../../configure -C
    make -s -j "$jobs" all
  )
fi
if [ -x "$build_dir/python.exe" ]; then
  build_python="$build_dir/python.exe"
elif [ -x "$build_dir/python" ]; then
  build_python="$build_dir/python"
else
  die "native build Python was not produced in $build_dir"
fi
pyver="$("$build_python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

ensure_compression_deps

say "cross-building CPython for wasm32-unknown-wasi (Python $pyver) with zlib, bz2 and lzma"
wasi_build="$source_dir/builddir/wasi"
mkdir -p "$wasi_build"
# config.cache remembers the previous "zlib not found" answers of a build made
# before the compression libraries existed; drop it so configure checks again.
rm -f "$wasi_build/config.cache"
(
  cd "$wasi_build"
  CPPFLAGS="-I$deps_dir/include" \
  LDFLAGS="-L$deps_dir/lib" \
  CONFIG_SITE="$source_dir/Tools/wasm/config.site-wasm32-wasi" \
  WASI_SDK_PATH="$sdk_dir" \
  "$source_dir/Tools/wasm/wasi-env" "$source_dir/configure" -C \
    --host=wasm32-unknown-wasi \
    --build="$("$source_dir/config.guess")" \
    --with-build-python="../build/$(basename "$build_python")" 2>&1 | tee "$wasi_build/configure.log"
  make -s -j "$jobs" all
)
assert_compression_modules

wasm="$wasi_build/python.wasm"
stdlib_dir="$wasi_build/build/lib.wasi-wasm32-$pyver"
[ -f "$wasm" ] || die "cross build did not produce $wasm"
[ -d "$stdlib_dir" ] || die "cross build did not produce $stdlib_dir"

say "copying python.wasm to $out"
# Drop the old provenance first and publish the pair/report files with a
# rename: a reader (or a failed build) must never see a stale sizes.json or
# compression.json stamped onto a half-written artifact.
rm -f "$out/compression.json" "$out/sizes.json"
cp "$wasm" "$out/.python.wasm.tmp"
mv -f "$out/.python.wasm.tmp" "$out/python.wasm"

say "packing the standard library"
staged_zip="$out/.python313.zip.tmp"
python3 - "$source_dir" "$pyver" "$staged_zip" <<'PY'
import pathlib
import sys
import zipfile

source = pathlib.Path(sys.argv[1])
pyver = sys.argv[2]
target = pathlib.Path(sys.argv[3])
lib = source / 'Lib'
build_lib = source / 'builddir' / 'wasi' / 'build' / f'lib.wasi-wasm32-{pyver}'
# Test suites and the GUI/IDE subprojects are not part of a headless toolbox
# stdlib and would add megabytes without adding importable functionality.
excluded_top = {
    'idlelib', 'ensurepip', 'lib2to3', 'site-packages', 'test', 'tests',
    'tkinter', 'turtledemo',
}

def entries():
    for base in (lib, build_lib):
        if not base.is_dir():
            continue
        for path in sorted(base.rglob('*')):
            if not path.is_file():
                continue
            rel = path.relative_to(base)
            if rel.parts and rel.parts[0] in excluded_top:
                continue
            if '__pycache__' in rel.parts:
                continue
            yield path, rel.as_posix()

count = 0
uncompressed = 0
names = set()
# ZIP_STORED keeps every import allocation local and avoids paying deflate for
# a read-only archive; zlib is now linked into the interpreter, but zipimport
# still serves the stored entries directly.
with zipfile.ZipFile(target, 'w', zipfile.ZIP_STORED) as archive:
    for path, name in entries():
        archive.write(path, name)
        count += 1
        uncompressed += path.stat().st_size
        names.add(name)
# The compression extension modules are linked into python.wasm; these are the
# pure-Python wrappers around them, and a zip without them would break
# tarfile/gzip/bz2/lzma even if the interpreter was built correctly.
required = {'tarfile.py', 'gzip.py', 'bz2.py', 'lzma.py', 'zipfile/__init__.py'}
missing = sorted(required - names)
if missing:
    raise SystemExit(f'the zipped standard library is missing {missing}; refusing to publish it')
print(
    f'{count} files, {target.stat().st_size} bytes stored '
    f'({uncompressed} bytes uncompressed); compression wrappers present'
)
PY
mv -f "$staged_zip" "$out/python313.zip"

say "probing the produced runtime for zlib, bz2, lzma and tarfile w:gz"
if ! NODE_NO_WARNINGS=1 node "$here/verify-compression.mjs" \
  --wasm "$out/python.wasm" --stdlib "$out/python313.zip" \
  --report "$out/.compression.json.tmp"; then
  rm -f "$out/.compression.json.tmp"
  die "the produced python.wasm does not provide zlib, bz2, lzma and tarfile w:gz; refusing to publish it"
fi

wasm_bytes="$(wc -c < "$out/python.wasm" | tr -d ' ')"
zip_bytes="$(wc -c < "$out/python313.zip" | tr -d ' ')"
wasm_sha="$(sha256_of "$out/python.wasm")"
zip_sha="$(sha256_of "$out/python313.zip")"
total_bytes=$((wasm_bytes + zip_bytes))

python3 - "$out/.sizes.json.tmp" "$cpython_version" "$sdk_version" "$wasm_bytes" "$wasm_sha" \
  "$zip_bytes" "$zip_sha" "$total_bytes" "$out/.compression.json.tmp" \
  "$zlib_version" "$bzip2_version" "$pdsh_version" \
  "$zlib_license" "$bzip2_license" "$pdsh_license" <<'PY'
import json
import sys

(target, cpython, sdk, wasm_bytes, wasm_sha, zip_bytes, zip_sha, total,
 compression_path, zlib_version, bzip2_version, pdsh_version,
 zlib_license, bzip2_license, pdsh_license) = sys.argv[1:]
with open(compression_path, encoding='utf-8') as handle:
    compression = json.load(handle)
report = {
    'format': 1,
    'cpython': cpython,
    'wasiSdk': sdk,
    'pythonWasm': {'bytes': int(wasm_bytes), 'sha256': wasm_sha},
    'pythonStdlibZip': {
        'bytes': int(zip_bytes),
        'sha256': zip_sha,
        'compression': 'stored',
        'excludes': ['test', 'tests', 'idlelib', 'ensurepip', 'lib2to3', 'tkinter', 'turtledemo'],
        'carries': ['tarfile.py', 'gzip.py', 'bz2.py', 'lzma.py', 'zipfile/__init__.py'],
    },
    'compression': {
        **compression,
        'libraries': {
            'zlib': {'version': zlib_version, 'license': zlib_license},
            'bzip2': {'version': bzip2_version, 'license': bzip2_license},
            'xz': {'version': pdsh_version, 'license': pdsh_license},
        },
    },
    'totalBytes': int(total),
}
with open(target, 'w', encoding='utf-8') as handle:
    json.dump(report, handle, indent=2, sort_keys=True)
    handle.write('\n')
PY
mv -f "$out/.compression.json.tmp" "$out/compression.json"
mv -f "$out/.sizes.json.tmp" "$out/sizes.json"

say "done"
printf '  python.wasm      %s bytes  sha256 %s\n' "$wasm_bytes" "$wasm_sha"
printf '  python313.zip    %s bytes  sha256 %s\n' "$zip_bytes" "$zip_sha"
printf '  total            %s bytes\n' "$total_bytes"
printf '  compression      zlib %s, bz2 and lzma roundtrips plus tarfile w:gz verified\n' "$zlib_version"
printf '  reports          %s\n' "$out/sizes.json"
printf '                   %s\n' "$out/compression.json"
