#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Fetch the pinned Termux proot payload into generated jniLibs.
#
# The binaries are third-party assets and are NOT committed:
#
#   proot              GPL-2.0-or-later   Termux proot 5.1.107.102 (aarch64)
#   loader             GPL-2.0-or-later   same .deb (libexec/proot/loader)
#   libtalloc          LGPL-3.0-or-later  Termux libtalloc 2.5.0 (aarch64)
#   libandroid-shmem   BSD-3-Clause       Termux libandroid-shmem 0.7 (aarch64)
#
# Their source, versions, SHA-256 values and the one DT_NEEDED patch are recorded
# in the repository NOTICE. The Ubuntu Base rootfs is a separate, runtime
# download (Android/UbuntuRootfsStore.kt), not part of this output.
#
# jniLibs requires the `lib*.so` spelling, and proot's DT_NEEDED names
# `libtalloc.so.2`; the two names cannot both be satisfied by a file named
# `libtalloc.so`. The patch rewrites the 15-byte string `libtalloc.so.2\0` to the
# equal-length `libtalloc.so\0\0\0` in place (no ELF offsets move) and the result
# must hash to the pinned patched SHA. `patchelf` is not required.
#
# Usage:
#   android/tools/fetch-termux-proot.sh            # download if missing, then emit
#   android/tools/fetch-termux-proot.sh --check    # verify existing output only
#   android/tools/fetch-termux-proot.sh --force    # re-download and re-emit
#   android/tools/fetch-termux-proot.sh --out DIR  # alternate jniLibs root
#
# The Gradle task `package<Variant>ProotAssets` consumes
# android/app/build/generated/termux-proot/jniLibs and fails loudly when this
# script has not run. Nothing here is needed by a host JVM unit test.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
OUT_DEFAULT="$ROOT/android/app/build/generated/termux-proot/jniLibs"
WORK_DEFAULT="$ROOT/android/app/build/generated/termux-proot/work"
MANIFEST_DEFAULT="$ROOT/android/app/build/generated/termux-proot/proot-assets.json"

OUT="$OUT_DEFAULT"
WORK="$WORK_DEFAULT"
MANIFEST="$MANIFEST_DEFAULT"
MODE="emit"

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --force) MODE="force"; shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --work) WORK="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

PROOT_DEB_URL="https://packages.termux.dev/apt/termux-main/pool/main/p/proot/proot_5.1.107.102_aarch64.deb"
PROOT_DEB_SHA="10a394b585c2fc2b2c8502544f4e5f1be581dc8bfff79e8ba62f16207423e030"
TALLOC_DEB_URL="https://packages.termux.dev/apt/termux-main/pool/main/libt/libtalloc/libtalloc_2.5.0_aarch64.deb"
TALLOC_DEB_SHA="556591f43bb773ad8777e1a29522640866a55f95dab71914418b94a8c58ad5a7"
SHMEM_DEB_URL="https://packages.termux.dev/apt/termux-main/pool/main/liba/libandroid-shmem/libandroid-shmem_0.7_aarch64.deb"
SHMEM_DEB_SHA="0da3a24d558b93c92bcf8d611e0826a99ff96e396b148e6cdf33b47c47c57ff6"

PROOT_RAW_SHA="3621937c1c5a98d0d39ca599af573a6bc15128690606d535e8b05da00cec4f41"
PROOT_PATCHED_SHA="aad737c5b546ee7471f133be90ef20f765aa98a303522557ceed3dff76605085"
LOADER_SHA="1da54355333cca3fb6ee10e3b82a24df24fb230c99241ce83809bf9e240609b5"
TALLOC_SHA="742b438c4d09e276985a61d44164c9de207b6d8cc268f3018cb3001961bcb309"
SHMEM_SHA="84475798e07c8174dbbfaec70a827fdb02f19ffa69a589380c13e7507fd0e731"

say() { printf '[proot-assets] %s\n' "$*"; }
die() { printf '[proot-assets] ERROR: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 is required (stdlib only)"
command -v curl >/dev/null 2>&1 || die "curl is required"

# A file whose sha256 is $2 is already the pinned artifact.
hash_matches() {
  [ -f "$1" ] || return 1
  local actual
  actual="$(python3 - "$1" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())
PY
)"
  [ "$actual" = "$2" ]
}

# HTTPS-only download with retries and a hard timeout.
fetch() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname -- "$dest")"
  local temporary="$dest.part"
  rm -f "$temporary"
  curl --fail --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 300 \
    --output "$temporary" "$url" || die "download failed: $url"
  mv -f "$temporary" "$dest"
}

ensure_deb() {
  local url="$1" sha="$2" dest="$3"
  if hash_matches "$dest" "$sha"; then
    say "cached $(basename -- "$dest")"
    return
  fi
  say "downloading $(basename -- "$dest")"
  fetch "$url" "$dest"
  hash_matches "$dest" "$sha" || die "sha256 mismatch for $(basename -- "$dest")"
}

# `--check` never downloads; it validates exactly what the APK would package.
if [ "$MODE" = "check" ]; then
  python3 - "$OUT" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
expected = {
    'libproot.so': 'aad737c5b546ee7471f133be90ef20f765aa98a303522557ceed3dff76605085',
    'libproot_loader.so': '1da54355333cca3fb6ee10e3b82a24df24fb230c99241ce83809bf9e240609b5',
    'libtalloc.so': '742b438c4d09e276985a61d44164c9de207b6d8cc268f3018cb3001961bcb309',
    'libandroid-shmem.so': '84475798e07c8174dbbfaec70a827fdb02f19ffa69a589380c13e7507fd0e731',
}
problems = []
for name, sha in expected.items():
    path = out / 'arm64-v8a' / name
    if not path.is_file():
        problems.append(f'missing {path}')
        continue
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != sha:
        problems.append(f'{path}: sha256 {actual} != {sha}')
if problems:
    print('[proot-assets] FAIL: run android/tools/fetch-termux-proot.sh')
    for problem in problems:
        print(f'  - {problem}')
    sys.exit(1)
print(f'[proot-assets] PASS: 4 pinned binaries under {out / "arm64-v8a"}')
PY
  exit $?
fi

mkdir -p "$WORK" "$OUT/arm64-v8a"
DEB_DIR="$WORK/debs"
mkdir -p "$DEB_DIR"

if [ "$MODE" = "force" ]; then
  rm -f "$DEB_DIR"/*.deb
  rm -rf "$WORK/extracted"
fi

ensure_deb "$PROOT_DEB_URL" "$PROOT_DEB_SHA" "$DEB_DIR/proot_5.1.107.102_aarch64.deb"
ensure_deb "$TALLOC_DEB_URL" "$TALLOC_DEB_SHA" "$DEB_DIR/libtalloc_2.5.0_aarch64.deb"
ensure_deb "$SHMEM_DEB_URL" "$SHMEM_DEB_SHA" "$DEB_DIR/libandroid-shmem_0.7_aarch64.deb"

# Extract exactly four members. The deb is an ar archive; Python's stdlib reads
# both it and the xz-compressed data tar without external `ar`/`tar`, which keeps
# the macOS and Linux build hosts on the same path.
python3 - "$DEB_DIR" "$WORK/extracted" <<'PY'
import hashlib, pathlib, sys, tarfile
deb_dir = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)

PREFIX = 'data/data/com.termux/files/usr/'
WANTED = {
    PREFIX + 'bin/proot': 'proot.raw',
    PREFIX + 'libexec/proot/loader': 'loader',
    PREFIX + 'lib/libtalloc.so.2.5.0': 'libtalloc.so.2.5.0',
    PREFIX + 'lib/libandroid-shmem.so': 'libandroid-shmem.so',
}

def ar_members(data):
    if not data.startswith(b'!<arch>\n'):
        raise SystemExit('not an ar archive')
    index = 8
    while index + 60 <= len(data):
        header = data[index:index + 60]
        name = header[0:16].decode('ascii', 'replace').strip()
        size_text = header[48:58].decode('ascii').strip()
        try:
            size = int(size_text)
        except ValueError:
            raise SystemExit(f'bad ar member size: {size_text!r}')
        body = data[index + 60:index + 60 + size]
        if len(body) != size:
            raise SystemExit(f'truncated ar member {name!r}')
        yield name.rstrip('/'), body
        index += 60 + size + (size % 2)

for deb in sorted(deb_dir.glob('*.deb')):
    found = set()
    for name, body in ar_members(deb.read_bytes()):
        if name != 'data.tar.xz':
            continue
        import io
        with tarfile.open(fileobj=io.BytesIO(body), mode='r:xz') as archive:
            for member in archive:
                target = WANTED.get(member.name.lstrip('./'))
                if target is None:
                    continue
                if not member.isfile():
                    raise SystemExit(f'{member.name} is not a regular file')
                source = archive.extractfile(member)
                if source is None:
                    raise SystemExit(f'{member.name} has no data')
                (out / target).write_bytes(source.read())
                found.add(target)
    if not found:
        raise SystemExit(f'no wanted payload in {deb.name}')
missing = set(WANTED.values()) - {p.name for p in out.iterdir()}
if missing:
    raise SystemExit('missing Termux payload: ' + ', '.join(sorted(missing)))
PY

python3 - "$WORK/extracted/proot.raw" "$WORK/extracted/proot.patched" "$PROOT_RAW_SHA" "$PROOT_PATCHED_SHA" <<'PY'
import hashlib, pathlib, sys
source, target, raw_sha, patched_sha = sys.argv[1:5]
data = pathlib.Path(source).read_bytes()
if hashlib.sha256(data).hexdigest() != raw_sha:
    raise SystemExit('raw proot does not match its pinned sha256')
old = b'libtalloc.so.2\x00'
new = b'libtalloc.so\x00\x00\x00'
if data.count(old) != 1:
    raise SystemExit('proot does not carry exactly one libtalloc.so.2 DT_NEEDED string')
patched = data.replace(old, new)
if len(patched) != len(data):
    raise SystemExit('the DT_NEEDED patch changed the file length')
pathlib.Path(target).write_bytes(patched)
actual = hashlib.sha256(patched).hexdigest()
if actual != patched_sha:
    raise SystemExit(f'patched proot sha256 {actual} != pinned {patched_sha}')
print('[proot-assets] DT_NEEDED patch: libtalloc.so.2 -> libtalloc.so (in place)')
PY

python3 - "$WORK/extracted" "$OUT/arm64-v8a" "$MANIFEST" <<'PY'
import hashlib, json, pathlib, shutil, sys
work = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
manifest = pathlib.Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
expected = {
    'libproot.so': ('proot.patched', 'aad737c5b546ee7471f133be90ef20f765aa98a303522557ceed3dff76605085'),
    'libproot_loader.so': ('loader', '1da54355333cca3fb6ee10e3b82a24df24fb230c99241ce83809bf9e240609b5'),
    'libtalloc.so': ('libtalloc.so.2.5.0', '742b438c4d09e276985a61d44164c9de207b6d8cc268f3018cb3001961bcb309'),
    'libandroid-shmem.so': ('libandroid-shmem.so', '84475798e07c8174dbbfaec70a827fdb02f19ffa69a589380c13e7507fd0e731'),
}
for name, (source, sha) in expected.items():
    source_path = work / source
    data = source_path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != sha:
        raise SystemExit(f'{source}: sha256 {actual} != pinned {sha}')
    target = out / name
    target.write_bytes(data)
    target.chmod(0o755)
record = {
    'schema': 1,
    'source': 'Termux packages (aarch64)',
    'assets': [
        {
            'file': name,
            'package': 'proot_5.1.107.102_aarch64.deb' if name.startswith('libproot')
                else ('libtalloc_2.5.0_aarch64.deb' if name == 'libtalloc.so' else 'libandroid-shmem_0.7_aarch64.deb'),
            'sha256': sha,
        }
        for name, (_, sha) in expected.items()
    ],
    'patch': {
        'file': 'libproot.so',
        'operation': 'in-place DT_NEEDED string rewrite',
        'from': 'libtalloc.so.2',
        'to': 'libtalloc.so',
        'reason': 'jniLibs requires the lib*.so spelling and both DT_NEEDED names cannot coexist',
        'result_sha256': expected['libproot.so'][1],
    },
}
manifest.parent.mkdir(parents=True, exist_ok=True)
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n', encoding='utf-8')
print(f'[proot-assets] wrote 4 binaries to {out}')
print(f'[proot-assets] wrote {manifest}')
PY

say "done. Rebuild the APK so mergeDebugJniLibFolders picks up the generated jniLibs."
