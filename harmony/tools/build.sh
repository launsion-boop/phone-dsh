#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
HARMONY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_ROOT="${DEVECO_CLI_CLT_PATH:?Set DEVECO_CLI_CLT_PATH to the official Command Line Tools root}"
CLI="${DEVECO_CLI:-devecocli}"
NDK="$TOOLS_ROOT/sdk/default/openharmony/native"
LLVM="$NDK/llvm/bin"
TASK_BIN="$(mktemp -d)"
trap 'rm -rf "$TASK_BIN"' EXIT
cat > "$TASK_BIN/ohos-linker" <<EOF2
#!/bin/sh
exec "$LLVM/clang" --target=aarch64-linux-ohos --sysroot="$NDK/sysroot" "\$@"
EOF2
chmod +x "$TASK_BIN/ohos-linker"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$TASK_BIN/ohos-linker"
export CC_aarch64_unknown_linux_ohos="$LLVM/clang"
export AR_aarch64_unknown_linux_ohos="$LLVM/llvm-ar"
export CFLAGS_aarch64_unknown_linux_ohos="--target=aarch64-linux-ohos --sysroot=$NDK/sysroot"
export RUSTFLAGS="${RUSTFLAGS:-} -C relocation-model=pic"
node "$HARMONY_ROOT/tools/stage-runtime.mjs"
cargo build --manifest-path "$HARMONY_ROOT/host-rust/Cargo.toml" --target aarch64-unknown-linux-ohos --release
cd "$HARMONY_ROOT"
"$CLI" check arkts
"$CLI" build "$@"
