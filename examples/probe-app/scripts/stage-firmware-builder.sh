#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Stages the firmware builder pack (WebAssembly toolchain + prebuilt SDK pack)
# into Bundle/firmware-builder and verifies it against its own manifest.
#   scripts/stage-firmware-builder.sh /path/to/pack        # local directory
#   scripts/stage-firmware-builder.sh host:path/to/pack    # anything rsync accepts
set -euo pipefail
src=${1:?usage: stage-firmware-builder.sh <pack directory or rsync source>}
dest="$(cd "$(dirname "$0")/.." && pwd)/Bundle/firmware-builder"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
rsync -a "${src%/}/" "$tmp/"
python3 - "$tmp" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
manifest = json.load(open(os.path.join(root, "manifest.json")))
required = ["cc1.wasm", "as.wasm", "ar.wasm", "ld.wasm", "sdk.bin", "project.bin"]
for name in required:
    entry = manifest["files"].get(name)
    if entry is None: sys.exit(f"manifest.json does not list {name}")
    data = open(os.path.join(root, name), "rb").read()
    if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
        sys.exit(f"{name} does not match manifest.json")
print(f"pack ok: {manifest.get('project')} ({manifest.get('target')}), {sum(manifest['files'][n]['bytes'] for n in required)} bytes")
PY
for name in cc1.wasm as.wasm ar.wasm ld.wasm sdk.bin project.bin manifest.json; do cp "$tmp/$name" "$dest/$name"; done
echo "staged into $dest"
