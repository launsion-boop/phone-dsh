#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Resolve a reproducible Rust toolchain for an isolated Android test shell.
#
# Usage:
#   bash android/tools/with-rust-toolchain.sh --check
#   bash android/tools/with-rust-toolchain.sh --install
#   bash android/tools/with-rust-toolchain.sh cargo build --locked --manifest-path shell/Cargo.toml -p pdsh-jni
#
# Workspace MSRV is 1.85, but the Cargo.lock-resolved graph was built and
# inspected with Rust 1.99.1. Pin that validated release as the minimum lane
# toolchain. A newer valid caller toolchain is reused. Installation is scoped to
# the caller's XDG cache or HOME; explicit RUSTUP_HOME/CARGO_HOME remain honored.
# The bootstrap executable is downloaded
# only from static.rust-lang.org and checked against its pinned official digest.

set -euo pipefail

readonly RUST_VERSION="1.99.1"
readonly RUSTUP_VERSION="1.28.2"
readonly RUST_CHANNEL_MANIFEST_SHA256="fb152be80975c194aa5fc684b2aec3a6e14e2b855efe2faa4e5f8ae6e590f463"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly MIN_VERSION="1.99.1"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

version_ge() {
  local actual="$1" required="$2"
  awk -v a="$actual" -v b="$required" 'BEGIN {
    split(a, x, "."); split(b, y, ".");
    for (i=1; i<=3; i++) { if ((x[i]+0) > (y[i]+0)) exit 0; if ((x[i]+0) < (y[i]+0)) exit 1; }
    exit 0
  }'
}

host_triple() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os:$arch" in
    Linux:x86_64) printf '%s\n' x86_64-unknown-linux-gnu ;;
    Linux:aarch64|Linux:arm64) printf '%s\n' aarch64-unknown-linux-gnu ;;
    Darwin:x86_64) printf '%s\n' x86_64-apple-darwin ;;
    Darwin:arm64|Darwin:aarch64) printf '%s\n' aarch64-apple-darwin ;;
    *) die "unsupported Rust bootstrap host: $os/$arch" ;;
  esac
}

installer_sha256() {
  case "$1" in
    x86_64-unknown-linux-gnu) printf '%s\n' 20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c ;;
    aarch64-unknown-linux-gnu) printf '%s\n' e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c ;;
    x86_64-apple-darwin) printf '%s\n' 9c331076f62b4d0edeae63d9d1c9442d5fe39b37b05025ec8d41c5ed35486496 ;;
    aarch64-apple-darwin) printf '%s\n' 20ef5516c31b1ac2290084199ba77dbbcaa1406c45c1d978ca68558ef5964ef5 ;;
    *) die "no pinned rustup-init digest for host $1" ;;
  esac
}

sha256_file() {
  # macOS ships shasum; minimal Linux images often ship only sha256sum. Probe
  # the executable instead of relying on a pipeline's exit status: a missing
  # shasum would otherwise make the `awk` stage succeed with an empty digest.
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die 'need shasum or sha256sum to verify pinned Rust downloads'
  fi
}

rustup_home_resolve() {
  if [[ -n "${RUSTUP_HOME:-}" ]]; then printf '%s\n' "$RUSTUP_HOME"
  elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then printf '%s/pdsh/rustup\n' "${XDG_CACHE_HOME%/}"
  elif [[ -n "${HOME:-}" ]]; then printf '%s/.rustup\n' "${HOME%/}"
  else die 'set XDG_CACHE_HOME or HOME to a writable location'; fi
}

cargo_home_resolve() {
  if [[ -n "${CARGO_HOME:-}" ]]; then printf '%s\n' "$CARGO_HOME"
  elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then printf '%s/pdsh/cargo\n' "${XDG_CACHE_HOME%/}"
  elif [[ -n "${HOME:-}" ]]; then printf '%s/.cargo\n' "${HOME%/}"
  else die 'set XDG_CACHE_HOME or HOME to a writable location'; fi
}

configure_cache() {
  # Resolve install/cache homes only after testing the caller in its original
  # environment. Redirecting RUSTUP_HOME first breaks valid rustup shims.
  export RUSTUP_HOME="$(rustup_home_resolve)" CARGO_HOME="$(cargo_home_resolve)"
  export PATH="$CARGO_HOME/bin:$PATH"
}

current_adequate() {
  command -v rustc >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1 || return 1
  local rv cv
  rv="$(rustc --version | awk '{print $2}')" || return 1
  cv="$(cargo --version | awk '{print $2}')" || return 1
  version_ge "$rv" "$MIN_VERSION" && version_ge "$cv" "$MIN_VERSION"
}

install_pinned() {
  local triple sha tmp installer manifest manifest_sha
  triple="$(host_triple)"; sha="$(installer_sha256 "$triple")"
  mkdir -p "$CARGO_HOME/bin" "$RUSTUP_HOME" || die 'cannot create Rust toolchain cache directories'
  [[ -w "$CARGO_HOME" && -w "$RUSTUP_HOME" ]] || die "Rust cache is not writable (CARGO_HOME=$CARGO_HOME RUSTUP_HOME=$RUSTUP_HOME)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/pdsh-rustup.XXXXXX")" || die 'cannot create temporary installer directory'
  trap 'rm -rf "$tmp"' EXIT
  installer="$tmp/rustup-init"
  manifest="$tmp/channel-rust-$RUST_VERSION.toml"
  curl --fail --location --silent --show-error --max-time 60 --max-filesize 20000000 \
    --output "$manifest" "https://static.rust-lang.org/dist/channel-rust-$RUST_VERSION.toml" \
    || die "failed to download pinned Rust channel manifest $RUST_VERSION"
  manifest_sha="$(sha256_file "$manifest")"
  [[ "$manifest_sha" == "$RUST_CHANNEL_MANIFEST_SHA256" ]] \
    || die "Rust $RUST_VERSION channel manifest checksum mismatch: expected $RUST_CHANNEL_MANIFEST_SHA256 got $manifest_sha"
  local url="https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/$triple/rustup-init"
  curl --fail --location --silent --show-error --max-time 60 --max-filesize 30000000 \
    --output "$installer" "$url" || die "failed to download pinned rustup-init $RUSTUP_VERSION for $triple"
  local actual
  actual="$(sha256_file "$installer")"
  [[ "$actual" == "$sha" ]] || die "rustup-init checksum mismatch for $triple: expected $sha got $actual"
  chmod 700 "$installer"
  # rustup-init 1.28.2 has no --no-self-update option (the installer does not
  # update itself); passing it aborts before any toolchain is installed. The
  # rustup CLI subcommand below does support the flag.
  # The verified manifest and actual install must have the same official owner.
  export RUSTUP_DIST_SERVER="https://static.rust-lang.org"
  export RUSTUP_UPDATE_ROOT="https://static.rust-lang.org/rustup"
  RUSTUP_INIT_SKIP_PATH_CHECK=yes "$installer" -y --no-modify-path --profile minimal --default-toolchain none \
    --default-host "$triple" || die "rustup could not install Rust $RUST_VERSION"
  "$CARGO_HOME/bin/rustup" toolchain install "$RUST_VERSION" --profile minimal --no-self-update || die "Rust $RUST_VERSION installation failed"
  # Select the pin only for this wrapper process; do not rewrite a user's
  # unrelated rustup default toolchain.
  export RUSTUP_TOOLCHAIN="$RUST_VERSION"
  trap - EXIT
  rm -rf "$tmp"
}

mode="run"
if [[ "${1:-}" == "--check" ]]; then mode=check; shift
elif [[ "${1:-}" == "--install" ]]; then mode=install; shift
fi

# A valid caller toolchain keeps its own homes, selected toolchain and PATH.
# Otherwise try the task-local cache before considering an install.
if ! current_adequate; then configure_cache; fi

if [[ "$mode" == check ]]; then
  if current_adequate; then
    printf 'Rust toolchain OK: rustc %s; cargo %s (minimum %s)\n' "$(rustc --version | awk '{print $2}')" "$(cargo --version | awk '{print $2}')" "$MIN_VERSION"
    exit 0
  fi
  die "Rust >= $MIN_VERSION not found; run android/tools/with-rust-toolchain.sh --install"
fi

if [[ "$mode" == install ]]; then
  current_adequate || install_pinned
  exec rustc --version
fi

if ! current_adequate; then install_pinned; fi
current_adequate || die "installed Rust does not satisfy >= $MIN_VERSION"
[[ $# -gt 0 ]] || die 'usage: with-rust-toolchain.sh [--check|--install] <command> [args...]'
printf 'Rust: rustc %s; cargo %s; CARGO_HOME=%s RUSTUP_HOME=%s\n' "$(rustc --version | awk '{print $2}')" "$(cargo --version | awk '{print $2}')" "${CARGO_HOME:-caller default}" "${RUSTUP_HOME:-caller default}" >&2
cd "$REPO_ROOT"
exec "$@"
