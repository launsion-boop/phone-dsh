#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Run one command with the PDSH Android toolchain resolved from the *current*
# environment, then exec it from android/.
#
# Why a wrapper: the fleet runs each Gradle task in an isolated shell. Ignored
# files such as android/local.properties, ~/.gradle and another worker's SDK are
# not shared, so a Gradle command that happens to work in one shell cannot be
# assumed to work in the next. This wrapper derives every path from what is
# visible *now* and fails with an actionable message instead of inheriting a
# stale machine setting.
#
# Usage (from the repository root, or anywhere):
#   bash android/tools/with-android-toolchain.sh ./gradlew --version --no-daemon
#   bash android/tools/with-android-toolchain.sh ./gradlew :lib:testDebugUnitTest
#
# Resolution order (first usable value wins):
#   JAVA_HOME       PDSH_JAVA_HOME, then caller JAVA_HOME, then
#                   $PDSH_TOOLCHAIN_DIR/jdk-17, then <bootstrap default>/jdk-17
#   ANDROID_HOME    PDSH_ANDROID_HOME, then caller ANDROID_HOME, then the
#                   android/local.properties sdk.dir, then
#                   $PDSH_TOOLCHAIN_DIR/android-sdk, then the bootstrap default
#   GRADLE_USER_HOME
#                   PDSH_GRADLE_USER_HOME, then caller GRADLE_USER_HOME, then
#                   $XDG_CACHE_HOME/pdsh/gradle, then $HOME/pdsh/gradle
#
# macOS works with caller-supplied JAVA_HOME/ANDROID_HOME (or local.properties);
# this script only resolves paths and exports environment variables, so it has
# no Linux-only assumption. It never sources local.properties or any other
# untrusted file; keys are read with sed.
#
# JAVA_TOOL_OPTIONS gains -Duser.home=<writable home> so Robolectric's SDK/Java
# writes go to a writable home instead of a read-only container default. HOME is
# preferred, then XDG_CACHE_HOME, then the resolved Gradle home. Existing options
# are preserved. The wrapper never installs anything: run
# android/tools/bootstrap-android-toolchain.sh first (or pass explicit paths).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
ANDROID_DIR="$REPO_ROOT/android"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$(pwd)" "$1" ;;
  esac
}

trim_trailing_slash() {
  local value="$1"
  while [ "$value" != "/" ] && [ "${value%/}" != "$value" ]; do
    value="${value%/}"
  done
  printf '%s\n' "$value"
}

default_toolchain_dir() {
  if [ -n "${PDSH_TOOLCHAIN_DIR:-}" ]; then
    abs_path "$PDSH_TOOLCHAIN_DIR"
  elif [ -n "${XDG_CACHE_HOME:-}" ]; then
    printf '%s/pdsh/android\n' "$(abs_path "$XDG_CACHE_HOME")"
  elif [ -n "${HOME:-}" ]; then
    printf '%s/toolchains/pdsh-android\n' "$(abs_path "$HOME")"
  else
    die "no toolchain root: set PDSH_TOOLCHAIN_DIR, XDG_CACHE_HOME or HOME"
  fi
}

java_major() {
  "$1/bin/java" -version 2>&1 | sed -nE 's/.*version "([0-9]+)([.+-].*)?"?.*/\1/p' | sed -n '1p'
}

javac_major() {
  "$1/bin/javac" -version 2>&1 | sed -nE 's/^javac ([0-9]+)([.+-].*)?$/\1/p' | sed -n '1p'
}

jdk_is_17() {
  local jdk_root="$1"
  [ -x "$jdk_root/bin/java" ] && [ -x "$jdk_root/bin/javac" ] || return 1
  [ "$(java_major "$jdk_root" || true)" = "17" ] || return 1
  [ "$(javac_major "$jdk_root" || true)" = "17" ] || return 1
}

read_local_property() {
  local key="$1"
  local file="$ANDROID_DIR/local.properties"
  [ -f "$file" ] || return 1
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$file" | sed -n '1p'
}

TOOLCHAIN_DIR="$(trim_trailing_slash "$(default_toolchain_dir)")"

JAVA_HOME_RESOLVED=""
if [ -n "${PDSH_JAVA_HOME:-}" ]; then
  candidate="$(trim_trailing_slash "$(abs_path "$PDSH_JAVA_HOME")")"
  if ! jdk_is_17 "$candidate"; then
    die "PDSH_JAVA_HOME is not a consistent JDK 17: $candidate"
  fi
  JAVA_HOME_RESOLVED="$candidate"
else
  for candidate in "${JAVA_HOME:-}" "$TOOLCHAIN_DIR/jdk-17"; do
    [ -n "$candidate" ] || continue
    candidate="$(trim_trailing_slash "$(abs_path "$candidate")")"
    if jdk_is_17 "$candidate"; then
      JAVA_HOME_RESOLVED="$candidate"
      break
    fi
  done
fi
if [ -z "$JAVA_HOME_RESOLVED" ]; then
  printf 'ERROR: no consistent JDK 17 found.\n' >&2
  printf 'Checked PDSH_JAVA_HOME=%s JAVA_HOME=%s and %s/jdk-17.\n' \
    "${PDSH_JAVA_HOME:-<unset>}" "${JAVA_HOME:-<unset>}" "$TOOLCHAIN_DIR" >&2
  printf 'Run: bash android/tools/bootstrap-android-toolchain.sh\n' >&2
  exit 2
fi

SDK_DIR=""
if [ -n "${PDSH_ANDROID_HOME:-}" ]; then
  candidate="$(trim_trailing_slash "$(abs_path "$PDSH_ANDROID_HOME")")"
  if [ -x "$candidate/platform-tools/adb" ] || [ -d "$candidate/platforms" ]; then
    SDK_DIR="$candidate"
  else
    die "PDSH_ANDROID_HOME is not an Android SDK: $candidate"
  fi
else
  for candidate in "${ANDROID_HOME:-}" "$(read_local_property sdk.dir || true)" "$TOOLCHAIN_DIR/android-sdk"; do
    [ -n "$candidate" ] || continue
    candidate="$(trim_trailing_slash "$(abs_path "$candidate")")"
    if [ -x "$candidate/platform-tools/adb" ] || [ -d "$candidate/platforms" ]; then
      SDK_DIR="$candidate"
      break
    fi
  done
fi
if [ -z "$SDK_DIR" ]; then
  printf 'ERROR: no Android SDK found.\n' >&2
  printf 'Checked PDSH_ANDROID_HOME, ANDROID_HOME, android/local.properties sdk.dir and %s/android-sdk.\n' "$TOOLCHAIN_DIR" >&2
  printf 'Run: bash android/tools/bootstrap-android-toolchain.sh\n' >&2
  exit 2
fi

if [ -n "${PDSH_GRADLE_USER_HOME:-}" ]; then
  GRADLE_USER_HOME_RESOLVED="$(abs_path "$PDSH_GRADLE_USER_HOME")"
elif [ -n "${GRADLE_USER_HOME:-}" ]; then
  GRADLE_USER_HOME_RESOLVED="$(abs_path "$GRADLE_USER_HOME")"
elif [ -n "${XDG_CACHE_HOME:-}" ]; then
  GRADLE_USER_HOME_RESOLVED="$(abs_path "$XDG_CACHE_HOME")/pdsh/gradle"
elif [ -n "${HOME:-}" ]; then
  GRADLE_USER_HOME_RESOLVED="$(abs_path "$HOME")/pdsh/gradle"
else
  die "no writable Gradle home: set GRADLE_USER_HOME, XDG_CACHE_HOME or HOME"
fi
mkdir -p "$GRADLE_USER_HOME_RESOLVED" || die "cannot create GRADLE_USER_HOME=$GRADLE_USER_HOME_RESOLVED"
[ -w "$GRADLE_USER_HOME_RESOLVED" ] || die "GRADLE_USER_HOME is not writable: $GRADLE_USER_HOME_RESOLVED"

if [ "$#" -eq 0 ]; then
  die "usage: bash android/tools/with-android-toolchain.sh <command> [args...]"
fi

export JAVA_HOME="$JAVA_HOME_RESOLVED"
export ANDROID_HOME="$SDK_DIR"
export ANDROID_SDK_ROOT="$SDK_DIR"
export GRADLE_USER_HOME="$GRADLE_USER_HOME_RESOLVED"
# -Duser.home keeps Robolectric and any tool that writes under user.home inside
# the current writable HOME. Preserve options the caller already needed.
if [ -n "${HOME:-}" ]; then
  JAVA_USER_HOME="$(abs_path "$HOME")"
elif [ -n "${XDG_CACHE_HOME:-}" ]; then
  JAVA_USER_HOME="$(abs_path "$XDG_CACHE_HOME")"
else
  JAVA_USER_HOME="$GRADLE_USER_HOME_RESOLVED"
fi
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Duser.home=$JAVA_USER_HOME"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"

printf 'toolchain: JAVA_HOME=%s ANDROID_HOME=%s GRADLE_USER_HOME=%s\n' \
  "$JAVA_HOME" "$ANDROID_HOME" "$GRADLE_USER_HOME" >&2

cd "$ANDROID_DIR"
exec "$@"
