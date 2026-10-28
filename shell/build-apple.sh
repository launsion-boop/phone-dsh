#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build the pdsh-shell read-only accelerators for Apple platforms.
#
#   bash build-apple.sh           # iOS device, iOS simulator and macOS slices,
#                                 # then dist/PDSHShell.xcframework
#   bash build-apple.sh --check   # only the macOS slice (fast CI gate)
#
# The Rust toolchain and the three targets are provided by rustup:
#   rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
#
# The C ABI crate (`pdsh-ffi`) links the tracked production registry in
# `pdsh-all`; no source is generated or copied. The C entry points and the
# request/callback layout are declared by `include/xzshell.h`. The produced
# static library is `libpdsh_ffi.a`, and the XCFramework carries the header and
# module map for the Swift `PDSHShell` module.

set -euo pipefail

cd "$(dirname "$0")"
ROOT=$(pwd -P)
export PATH="$HOME/.cargo/bin:$PATH"

# Match Package.swift, independently of the SDK installed on the build host.
# cc-rs also compiles tree-sitter C parsers: without these deployment targets
# their object files inherit the current SDK minimum and cannot ship with the
# SDK's advertised macOS 14 / iOS 17 support.
export MACOSX_DEPLOYMENT_TARGET=14.0
export IPHONEOS_DEPLOYMENT_TARGET=17.0


CHECK=0
case "${1:-}" in
    --check) CHECK=1 ;;
    "") ;;
    *)
        echo "usage: bash build-apple.sh [--check]" >&2
        exit 2
        ;;
esac

if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found; install the Rust stable toolchain with rustup" >&2
    exit 1
fi

TARGETS=(aarch64-apple-darwin)
if [ "$CHECK" -eq 0 ]; then
    TARGETS+=(aarch64-apple-ios aarch64-apple-ios-sim)
fi

if command -v rustup >/dev/null 2>&1; then
    INSTALLED=$(rustup target list --installed)
    for target in "${TARGETS[@]}"; do
        if ! printf '%s\n' "$INSTALLED" | grep -qx "$target"; then
            echo "error: rust target $target is not installed" >&2
            echo "       run: rustup target add $target" >&2
            exit 1
        fi
    done
fi

# Build the tracked crate directly. This compiles the same `pdsh-ffi` source
# the tests cover, with `pdsh-all` linked as a normal path dependency. The
# workspace lock keeps the dependency versions reproducible.
for target in "${TARGETS[@]}"; do
    echo "==> cargo build -p pdsh-ffi --release --target $target"
    cargo build --manifest-path "$ROOT/Cargo.toml" -p pdsh-ffi --release \
        --locked --target "$target" --target-dir "$ROOT/target"
done

LIB="$ROOT/target/aarch64-apple-darwin/release/libpdsh_ffi.a"
if [ "$CHECK" -eq 1 ]; then
    if [ ! -f "$LIB" ]; then
        echo "error: expected static library at $LIB" >&2
        exit 1
    fi
    echo "check ok: macOS slice built at $LIB"
    exit 0
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild is required to create the xcframework" >&2
    exit 1
fi

OUT="$ROOT/dist/PDSHShell.xcframework"
case "$OUT" in
    "$ROOT"/dist/*) ;;
    *)
        echo "error: refusing to remove output outside $ROOT/dist" >&2
        exit 1
        ;;
esac
if [ -e "$OUT" ]; then
    rm -rf "$OUT"
fi
mkdir -p "$ROOT/dist"

xcodebuild -create-xcframework \
    -library "$ROOT/target/aarch64-apple-ios/release/libpdsh_ffi.a" -headers "$ROOT/include" \
    -library "$ROOT/target/aarch64-apple-ios-sim/release/libpdsh_ffi.a" -headers "$ROOT/include" \
    -library "$ROOT/target/aarch64-apple-darwin/release/libpdsh_ffi.a" -headers "$ROOT/include" \
    -output "$OUT"

echo "created $OUT"
