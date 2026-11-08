#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Reproducible, idempotent JDK 17 + Android SDK 35 + Gradle 8.13 bootstrap.
#
# Everything is installed below the *current writable home* (or XDG cache),
# never below the checkout and never in a repository-parent "task-writable"
# directory. An explicit PDSH_TOOLCHAIN_DIR may point anywhere the caller can
# write; that is how tests and the Mac owner use a scratch directory.
#
# Usage:
#   bash android/tools/bootstrap-android-toolchain.sh          # install/repair
#   bash android/tools/bootstrap-android-toolchain.sh --check  # verify only
#
# Environment:
#   PDSH_TOOLCHAIN_DIR  install root (default: $XDG_CACHE_HOME/pdsh/android when
#                       XDG_CACHE_HOME is set, otherwise
#                       $HOME/toolchains/pdsh-android)
#   ANDROID_HOME        existing SDK root; packages are installed/read there
#   PDSH_JAVA_HOME      explicit JDK 17 home (must be a consistent JDK 17)
#   JAVA_HOME           reused only when java and javac are both 17
#   PDSH_LOCAL_PROPERTIES
#                       install-mode output (default: <checkout>/android/local.properties)
#   PDSH_CURL           downloader executable (default: curl)
#   PDSH_JDK_URL / PDSH_JDK_SHA256
#                       pinned JDK archive override (override both together)
#   PDSH_CMDLINE_TOOLS_URL / PDSH_CMDLINE_TOOLS_SHA1
#                       pinned command-line-tools archive override
#   PDSH_GRADLE_URL / PDSH_GRADLE_SHA256
#                       pinned Gradle archive override (override both together)
#   PDSH_GRADLE_FALLBACK_URLS
#                       space-separated transport mirrors, accepted only when the
#                       pinned SHA-256 matches (empty disables)
#   PDSH_GRADLE_USER_HOME
#                       Gradle cache root override (first in the same precedence
#                       chain the wrapper uses)
#   PDSH_GRADLE_PRIMARY_TIMEOUT
#                       single-attempt window for the official Gradle endpoint
#                       before a checksum-verified mirror is tried (default 30)
#   PDSH_CONNECT_TIMEOUT / PDSH_DOWNLOAD_TIMEOUT
#                       finite curl limits in seconds (defaults 20 / 1800)
#
# Install and check are deliberately separate commands:
#   * install   downloads verified archives, accepts SDK licences
#               non-interactively and writes android/local.properties only after
#               every package verifies;
#   * --check   downloads nothing, installs nothing and writes no file. It
#               verifies java/javac are both 17, the SDK packages are present,
#               the committed Gradle wrapper is pinned to 8.13 + its SHA-256,
#               and prints every resolved path.
#
# Installer stdout/stderr is never redirected to /dev/null. A download,
# checksum, extraction, licence or package failure prints the exact command and
# its exit code, removes a partial download and exits with that code.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
ANDROID_DIR="$REPO_ROOT/android"

# Pinned toolchain. The versions, URLs and hashes are data, not machine paths;
# update all three together and rerun the tests.
JDK_VERSION="17.0.21+3"
GRADLE_VERSION="8.13"
# SHA-256 of https://downloads.gradle.org/distributions/gradle-8.13-bin.zip
# (the official endpoint's published .sha256 value).
GRADLE_SHA256="20f1b1176237254a6fc204d8434196fa11a4cfb387567519c61556e8710aed78"
GRADLE_DIST_NAME="gradle-${GRADLE_VERSION}-bin.zip"
GRADLE_URL="${PDSH_GRADLE_URL:-https://downloads.gradle.org/distributions/$GRADLE_DIST_NAME}"
GRADLE_DOWNLOAD_SHA256="${PDSH_GRADLE_SHA256:-$GRADLE_SHA256}"
# downloads.gradle.org redirects to GitHub release assets in this environment
# and that hop stalls. The fallbacks below serve the same bytes from public
# Gradle mirrors and are accepted ONLY after the pinned official SHA-256
# verifies, so no unverified mirror can enter the build. Set the variable empty
# to disable fallbacks (tests that inject their own URL do this).
if [ -n "${PDSH_GRADLE_FALLBACK_URLS+x}" ]; then
  GRADLE_FALLBACK_URLS="$PDSH_GRADLE_FALLBACK_URLS"
elif [ -n "${PDSH_GRADLE_URL:-}" ]; then
  GRADLE_FALLBACK_URLS=""
else
  GRADLE_FALLBACK_URLS="https://mirrors.huaweicloud.com/gradle/$GRADLE_DIST_NAME https://mirrors.cloud.tencent.com/gradle/$GRADLE_DIST_NAME"
fi
GRADLE_DIST_BASENAME="${GRADLE_DIST_NAME%.zip}"

MODE=install
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    -h | --help)
      sed -n '3,50p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

say() { printf '%s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() {
  local message="$1"
  local code="${2:-1}"
  printf 'ERROR: %s\n' "$message" >&2
  exit "$code"
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

# Default install root: current writable cache/home, never the checkout parent.
if [ -n "${PDSH_TOOLCHAIN_DIR:-}" ]; then
  TOOLCHAIN_DIR="$(abs_path "$PDSH_TOOLCHAIN_DIR")"
elif [ -n "${XDG_CACHE_HOME:-}" ]; then
  TOOLCHAIN_DIR="$(abs_path "$XDG_CACHE_HOME")/pdsh/android"
elif [ -n "${HOME:-}" ]; then
  TOOLCHAIN_DIR="$(abs_path "$HOME")/toolchains/pdsh-android"
else
  die "no writable install root: set PDSH_TOOLCHAIN_DIR, XDG_CACHE_HOME or HOME"
fi
TOOLCHAIN_DIR="$(trim_trailing_slash "$TOOLCHAIN_DIR")"

if [ -n "${ANDROID_HOME:-}" ]; then
  SDK_DIR="$(trim_trailing_slash "$(abs_path "$ANDROID_HOME")")"
else
  SDK_DIR="$TOOLCHAIN_DIR/android-sdk"
fi
LOCAL_PROPERTIES="$(trim_trailing_slash "$(abs_path "${PDSH_LOCAL_PROPERTIES:-$ANDROID_DIR/local.properties}")")"
if [ -n "${PDSH_GRADLE_USER_HOME:-}" ]; then
  GRADLE_USER_HOME_RESOLVED="$(trim_trailing_slash "$(abs_path "$PDSH_GRADLE_USER_HOME")")"
elif [ -n "${GRADLE_USER_HOME:-}" ]; then
  GRADLE_USER_HOME_RESOLVED="$(trim_trailing_slash "$(abs_path "$GRADLE_USER_HOME")")"
elif [ -n "${XDG_CACHE_HOME:-}" ]; then
  GRADLE_USER_HOME_RESOLVED="$(trim_trailing_slash "$(abs_path "$XDG_CACHE_HOME")")/pdsh/gradle"
elif [ -n "${HOME:-}" ]; then
  GRADLE_USER_HOME_RESOLVED="$(trim_trailing_slash "$(abs_path "$HOME")")/pdsh/gradle"
else
  die "no writable Gradle home: set PDSH_GRADLE_USER_HOME, GRADLE_USER_HOME, XDG_CACHE_HOME or HOME"
fi
SDKMANAGER="$SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
DOWNLOADS="$TOOLCHAIN_DIR/downloads"
GRADLE_DIST="$DOWNLOADS/$GRADLE_DIST_NAME"
CURL="${PDSH_CURL:-curl}"
CONNECT_TIMEOUT="${PDSH_CONNECT_TIMEOUT:-20}"
DOWNLOAD_TIMEOUT="${PDSH_DOWNLOAD_TIMEOUT:-1800}"
PLATFORM_PACKAGE="${PDSH_PLATFORM:-platforms;android-35}"
BUILD_TOOLS_PACKAGE="${PDSH_BUILD_TOOLS:-build-tools;35.0.0}"
PLATFORM_DIR_NAME="${PLATFORM_PACKAGE#platforms;}"
BUILD_TOOLS_DIR_NAME="${BUILD_TOOLS_PACKAGE#build-tools;}"
SDK_PACKAGES=("platform-tools" "$PLATFORM_PACKAGE" "$BUILD_TOOLS_PACKAGE")
JAVA_HOME_RESOLVED=""

case "$(uname -s)" in
  Linux) HOST_OS=linux ;;
  Darwin) HOST_OS=mac ;;
  *) die "unsupported host OS: $(uname -s) (the wrapper script still works with caller-supplied paths)" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) HOST_ARCH=x64 ;;
  aarch64 | arm64) HOST_ARCH=aarch64 ;;
  *) die "unsupported host architecture: $(uname -m)" ;;
esac

# Pinned Azul Zulu 17 archives. The Adoptium API's "latest" and release
# downloads redirect through GitHub, which stalled in the fleet host; Azul's
# official CDN serves the same OpenJDK 17 JDK directly. Version, URL and
# SHA-256 are one triple from Azul's metadata API (sha256_hash per package).
case "$HOST_OS/$HOST_ARCH" in
  linux/x64)
    JDK_URL_DEFAULT="https://cdn.azul.com/zulu/bin/zulu17.70.113-ca-jdk17.0.21.0.3-linux_x64.tar.gz"
    JDK_SHA256_DEFAULT="81946095839140100ebff36ff52007676e260bbe482675dbc04772595ed94390"
    ;;
  linux/aarch64)
    JDK_URL_DEFAULT="https://cdn.azul.com/zulu/bin/zulu17.70.113-ca-jdk17.0.21.0.3-linux_aarch64.tar.gz"
    JDK_SHA256_DEFAULT="8a32c57a101b29fb2e31dd935709517d2a1117d4e696f13ff5035c665ac1d034"
    ;;
  mac/x64)
    JDK_URL_DEFAULT="https://cdn.azul.com/zulu/bin/zulu17.70.113-ca-jdk17.0.21.0.3-macosx_x64.tar.gz"
    JDK_SHA256_DEFAULT="6de9a31bd21c09b787781ce90d5791168b522c2213571d742141e610b81ff7fd"
    ;;
  mac/aarch64)
    JDK_URL_DEFAULT="https://cdn.azul.com/zulu/bin/zulu17.70.113-ca-jdk17.0.21.0.3-macosx_aarch64.tar.gz"
    JDK_SHA256_DEFAULT="f4a4d641d4441f480939176208f333aa9403e0a68d27e87245cec98cc994f943"
    ;;
esac
JDK_URL="${PDSH_JDK_URL:-$JDK_URL_DEFAULT}"
JDK_SHA256="${PDSH_JDK_SHA256:-$JDK_SHA256_DEFAULT}"

# Google's command-line tools. Android publishes no linux-aarch64 archive.
case "$HOST_OS/$HOST_ARCH" in
  linux/x64)
    CMDLINE_TOOLS_URL_DEFAULT="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
    CMDLINE_TOOLS_SHA1_DEFAULT="d313adb7aedccf6cf0cfca51ec180f0059f5f8f8"
    ;;
  linux/aarch64)
    die "Android command-line tools have no official linux-aarch64 archive; run the bootstrap on linux-x64 or supply a preinstalled ANDROID_HOME"
    ;;
  mac/x64)
    CMDLINE_TOOLS_URL_DEFAULT="https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip"
    CMDLINE_TOOLS_SHA1_DEFAULT="37fb7dd41005b3b4ca6ea48ac27074b6fc4e3236"
    ;;
  mac/aarch64)
    CMDLINE_TOOLS_URL_DEFAULT="https://dl.google.com/android/repository/commandlinetools-mac_arm64-16111833_latest.zip"
    CMDLINE_TOOLS_SHA1_DEFAULT="ad03dc49bfacfd52c110b14104ea548b8a07e830"
    ;;
esac
CMDLINE_TOOLS_URL="${PDSH_CMDLINE_TOOLS_URL:-$CMDLINE_TOOLS_URL_DEFAULT}"
CMDLINE_TOOLS_SHA1="${PDSH_CMDLINE_TOOLS_SHA1:-$CMDLINE_TOOLS_SHA1_DEFAULT}"

java_major() {
  "$1/bin/java" -version 2>&1 | sed -nE 's/.*version "([0-9]+)([.+-].*)?"?.*/\1/p' | sed -n '1p'
}

javac_major() {
  "$1/bin/javac" -version 2>&1 | sed -nE 's/^javac ([0-9]+)([.+-].*)?$/\1/p' | sed -n '1p'
}

java_version() { "$1/bin/java" -version 2>&1 | sed -n '1p'; }
javac_version() { "$1/bin/javac" -version 2>&1 | sed -n '1p'; }

jdk_problem() {
  local jdk_root="$1"
  local java_v=""
  local javac_v=""
  if [ ! -x "$jdk_root/bin/java" ] || [ ! -x "$jdk_root/bin/javac" ]; then
    printf 'missing java and/or javac under %s/bin\n' "$jdk_root"
    return 0
  fi
  java_v="$(java_major "$jdk_root" || true)"
  javac_v="$(javac_major "$jdk_root" || true)"
  if [ "$java_v" != "17" ] || [ "$javac_v" != "17" ]; then
    printf 'java=%s javac=%s (both must be 17)\n' "${java_v:-unknown}" "${javac_v:-unknown}"
    return 0
  fi
  return 1
}

is_jdk17() { ! jdk_problem "$1" >/dev/null 2>&1; }

# Resolve the JDK used by install/check. An explicitly supplied PDSH_JAVA_HOME
# must be valid; an inherited JAVA_HOME is reused only when it is a consistent
# JDK 17 and is otherwise ignored (never modified) so install can provision its
# own copy. A java-11/javac-17 mix is therefore never accepted.
resolve_jdk() {
  if [ -n "${PDSH_JAVA_HOME:-}" ]; then
    PDSH_JAVA_HOME="$(trim_trailing_slash "$(abs_path "$PDSH_JAVA_HOME")")"
    if ! is_jdk17 "$PDSH_JAVA_HOME"; then
      die "PDSH_JAVA_HOME is not a consistent JDK 17: $PDSH_JAVA_HOME ($(jdk_problem "$PDSH_JAVA_HOME"))"
    fi
    printf '%s\n' "$PDSH_JAVA_HOME"
    return
  fi
  if [ -n "${JAVA_HOME:-}" ]; then
    local inherited
    inherited="$(trim_trailing_slash "$(abs_path "$JAVA_HOME")")"
    if is_jdk17 "$inherited"; then
      printf '%s\n' "$inherited"
      return
    fi
    warn "JAVA_HOME is not a consistent JDK 17 ($inherited: $(jdk_problem "$inherited")); installing a pinned JDK 17 under $TOOLCHAIN_DIR"
  fi
  printf '%s\n' "$TOOLCHAIN_DIR/jdk-17"
}

hash_file() {
  local file="$1"
  local algorithm="$2"
  case "$algorithm" in
    sha256)
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
      elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
      else
        die "no SHA-256 tool found (need sha256sum or shasum)"
      fi
      ;;
    sha1)
      if command -v sha1sum >/dev/null 2>&1; then
        sha1sum "$file" | awk '{print $1}'
      elif command -v shasum >/dev/null 2>&1; then
        shasum -a 1 "$file" | awk '{print $1}'
      else
        die "no SHA-1 tool found (need sha1sum or shasum)"
      fi
      ;;
    *) die "unknown hash algorithm: $algorithm" ;;
  esac
}

verify_download() {
  local file="$1"
  local algorithm="$2"
  local expected="$3"
  local actual
  actual="$(hash_file "$file" "$algorithm")"
  [ "$actual" = "$expected" ]
}

# Download once, verify, and leave only a complete archive behind. A partial
# `.part` file is removed on every failure path; a cached archive is re-hashed so
# a corrupted cache cannot be mistaken for a successful install.
download_verified() {
  local url="$1"
  local destination="$2"
  local algorithm="$3"
  local expected="$4"
  local timeout="${5:-$DOWNLOAD_TIMEOUT}"
  local retries="${6:-3}"
  local part="$destination.part"
  local rc=0

  mkdir -p "$(dirname -- "$destination")"
  if [ -s "$destination" ]; then
    if verify_download "$destination" "$algorithm" "$expected"; then
      say "reusing verified download: $destination"
      return
    fi
    warn "cached download failed $algorithm verification; removing $destination"
    rm -f -- "$destination"
  fi

  rm -f -- "$part"
  say "+ $CURL --fail --location --retry $retries --retry-delay 2 --retry-all-errors --connect-timeout $CONNECT_TIMEOUT --max-time $timeout --output $part $url"
  set +e
  "$CURL" --fail --location \
    --retry "$retries" --retry-delay 2 --retry-all-errors \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$timeout" \
    --output "$part" "$url"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$part"
    die "download failed (exit $rc): $CURL ... --output $part $url" "$rc"
  fi
  if ! verify_download "$part" "$algorithm" "$expected"; then
    local actual
    actual="$(hash_file "$part" "$algorithm")"
    rm -f -- "$part"
    die "checksum mismatch for $url: expected $algorithm $expected, got $actual"
  fi
  mv -- "$part" "$destination"
  ok "downloaded and verified $destination"
}

install_jdk() {
  local destination="$1"
  local archive="$DOWNLOADS/zulu17-jdk-${HOST_ARCH}-${HOST_OS}-${JDK_VERSION}.tar.gz"
  local extract_dir
  local source_root

  if is_jdk17 "$destination"; then
    ok "JDK 17 already present: $destination"
    return
  fi

  if [ -e "$destination" ]; then
    case "$destination" in
      "$TOOLCHAIN_DIR"/*) ;;
      *) die "refusing to replace a JDK outside PDSH_TOOLCHAIN_DIR: $destination" ;;
    esac
    warn "removing incomplete JDK at $destination ($(jdk_problem "$destination" || true))"
    rm -rf -- "$destination"
  fi

  mkdir -p "$TOOLCHAIN_DIR"
  download_verified "$JDK_URL" "$archive" sha256 "$JDK_SHA256"

  extract_dir="$(mktemp -d "$TOOLCHAIN_DIR/.jdk-extract.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$extract_dir'" EXIT
  say "+ tar -xzf $archive -C $extract_dir"
  tar -xzf "$archive" -C "$extract_dir"
  source_root="$(find "$extract_dir" -maxdepth 7 -type f -path '*/bin/javac' -print -quit)"
  [ -n "$source_root" ] || die "JDK archive contains no bin/javac: $archive"
  source_root="${source_root%/bin/javac}"
  mv -- "$source_root" "$destination"
  rm -rf -- "$extract_dir"
  trap - EXIT

  is_jdk17 "$destination" || die "installed JDK is not a consistent JDK 17: $destination ($(jdk_problem "$destination"))"
  ok "installed JDK 17 at $destination ($(javac_version "$destination"))"
}

install_cmdline_tools() {
  local archive="$DOWNLOADS/commandlinetools-${HOST_OS}-${HOST_ARCH}.zip"
  local extract_dir
  local source_root

  if [ -x "$SDKMANAGER" ]; then
    ok "Android command-line tools already present: $SDKMANAGER"
    return
  fi

  mkdir -p "$SDK_DIR"
  download_verified "$CMDLINE_TOOLS_URL" "$archive" sha1 "$CMDLINE_TOOLS_SHA1"

  extract_dir="$(mktemp -d "$TOOLCHAIN_DIR/.sdk-extract.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$extract_dir'" EXIT
  say "+ unzip -q $archive -d $extract_dir"
  unzip -q "$archive" -d "$extract_dir"
  source_root="$extract_dir/cmdline-tools"
  [ -f "$source_root/bin/sdkmanager" ] || die "command-line tools archive has no cmdline-tools/bin/sdkmanager: $archive"

  if [ -e "$SDK_DIR/cmdline-tools/latest" ]; then
    warn "removing incomplete command-line tools at $SDK_DIR/cmdline-tools/latest"
    rm -rf -- "$SDK_DIR/cmdline-tools/latest"
  fi
  mkdir -p "$SDK_DIR/cmdline-tools"
  mv -- "$source_root" "$SDK_DIR/cmdline-tools/latest"
  rm -rf -- "$extract_dir"
  trap - EXIT
  chmod +x "$SDKMANAGER"
  [ -x "$SDKMANAGER" ] || die "sdkmanager is not executable after extraction: $SDKMANAGER"
  ok "installed Android command-line tools at $SDKMANAGER"
}

accept_licenses() {
  local rc=0
  say "+ yes | $SDKMANAGER --sdk_root=$SDK_DIR --licenses"
  # `yes` gets SIGPIPE once sdkmanager has read enough; that is expected. The
  # installer's own status is PIPESTATUS[1] and its stdout/stderr stay visible.
  set +e
  set +o pipefail
  yes | "$SDKMANAGER" "--sdk_root=$SDK_DIR" --licenses
  rc=${PIPESTATUS[1]}
  set -o pipefail
  set -e
  if [ "$rc" -ne 0 ]; then
    die "licence acceptance failed (exit $rc): yes | $SDKMANAGER --sdk_root=$SDK_DIR --licenses" "$rc"
  fi
  ok "Android SDK licences accepted"
}

install_packages() {
  local rc=0
  say "+ $SDKMANAGER --sdk_root=$SDK_DIR ${SDK_PACKAGES[*]}"
  set +e
  "$SDKMANAGER" "--sdk_root=$SDK_DIR" "${SDK_PACKAGES[@]}"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    die "package installation failed (exit $rc): $SDKMANAGER --sdk_root=$SDK_DIR ${SDK_PACKAGES[*]}" "$rc"
  fi
}

list_installed() (
  local listing="$1"
  local mirror ok=0 rc capture_rc mirror_rc last_byte
  mirror="$(mktemp "${TMPDIR:-/tmp}/pdsh-sdkmanager-mirror.XXXXXX")" || { rm -f -- "$listing"; die "cannot create sdkmanager capture"; }
  # Remove both captures on failure or interruption; the caller owns listing
  # only after successful capture and comparison.
  trap 'rm -f -- "$mirror"; if [ "$ok" != 1 ]; then rm -f -- "$listing"; fi' EXIT
  say "+ $SDKMANAGER --sdk_root=$SDK_DIR --list_installed"
  set +e
  "$SDKMANAGER" "--sdk_root=$SDK_DIR" --list_installed | tee "$listing" | tee "$mirror"
  local -a statuses=("${PIPESTATUS[@]}")
  rc=${statuses[0]}; capture_rc=${statuses[1]}; mirror_rc=${statuses[2]}
  set -e
  # Separate our machine-readable status lines even if stdout has no LF.
  last_byte="$(tail -c 1 "$mirror" | od -An -tu1 | tr -d '[:space:]')"
  if [ -n "$last_byte" ] && [ "$last_byte" != 10 ]; then printf '\n'; fi
  if [ "$rc" -ne 0 ]; then
    die "sdkmanager --list_installed failed (exit $rc): $SDKMANAGER --sdk_root=$SDK_DIR --list_installed" "$rc"
  fi
  if [ "$capture_rc" -ne 0 ] || [ "$mirror_rc" -ne 0 ]; then
    die "sdkmanager output capture failed (exit $capture_rc/$mirror_rc)"
  fi
  if ! cmp -s -- "$listing" "$mirror"; then
    die "sdkmanager output captures differ"
  fi
  ok=1
)

verify_packages() {
  local listing="$1"
  local package
  local failures=0
  local last_byte
  last_byte="$(tail -c 1 "$listing" | od -An -tu1 | tr -d '[:space:]')"
  for package in "${SDK_PACKAGES[@]}"; do
    # P23: parse only version-bearing rows of the installed section from
    # stdout. The external producer uses either slash or semicolon IDs.
    if LC_ALL=C awk -v package="$package" -v last_byte="$last_byte" \
      -v platform="$PLATFORM_PACKAGE" -v build="$BUILD_TOOLS_PACKAGE" '
      BEGIN {
        slash = package; gsub(/;/, "/", slash)
        platform_slash = platform; gsub(/;/, "/", platform_slash)
        build_slash = build; gsub(/;/, "/", build_slash)
        if (last_byte == "13") invalid = 1
      }
      {
        row = $0
        sub(/\r$/, "", row)
        if (index(row, "\r")) invalid = 1
        sub(/^[[:space:]]+/, "", row)
        sub(/[[:space:]]+$/, "", row)
        if (row == "Installed packages:") { if (section) invalid = 1; section = 1; next }
        # Unknown section headings are not producer diagnostics and cannot
        # establish where installed rows begin, on either side of the header.
        if (!section) { if (row ~ /:$/) invalid = 1; next }
        if (row == "") next
        if (row ~ /^[-|[:space:]]+$/) {
          if (index(row, "-") && index(row, "|")) next
          invalid = 1; next
        }
        if (row ~ /^Path[[:space:]]*\|[[:space:]]*Version[[:space:]]*\|[[:space:]]*Description([[:space:]]*\||$)/) next
        count = split(row, fields, /[[:space:]|]+/)
        if (fields[1] !~ /^[A-Za-z0-9_.;\/-]+$/) { invalid = 1; next }
        numeric = fields[2] ~ /^[0-9][A-Za-z0-9._+-]*$/
        unknown = fields[2] == "unknown" && fields[3] == "->" && fields[4] ~ /^[0-9][A-Za-z0-9._+-]*$/
        required = fields[1] == "platform-tools" || fields[1] == platform || fields[1] == platform_slash || fields[1] == build || fields[1] == build_slash
        if ((!numeric && !unknown) || (unknown && required)) { invalid = 1; next }
        if (numeric && (fields[1] == package || fields[1] == slash)) found = 1
      }
      END { exit !(section && !invalid && found) }
    ' "$listing"; then
      printf 'PACKAGE %s=installed\n' "$package"
    else
      printf 'PACKAGE %s=MISSING\n' "$package"
      failures=$((failures + 1))
    fi
  done
  [ -d "$SDK_DIR/platforms/$PLATFORM_DIR_NAME" ] || {
    printf 'PACKAGE %s=directory-missing (%s)\n' "$PLATFORM_PACKAGE" "$SDK_DIR/platforms/$PLATFORM_DIR_NAME"
    failures=$((failures + 1))
  }
  [ -d "$SDK_DIR/build-tools/$BUILD_TOOLS_DIR_NAME" ] || {
    printf 'PACKAGE %s=directory-missing (%s)\n' "$BUILD_TOOLS_PACKAGE" "$SDK_DIR/build-tools/$BUILD_TOOLS_DIR_NAME"
    failures=$((failures + 1))
  }
  [ -x "$SDK_DIR/platform-tools/adb" ] || {
    printf 'PACKAGE platform-tools=adb-missing (%s)\n' "$SDK_DIR/platform-tools/adb"
    failures=$((failures + 1))
  }
  return "$failures"
}

write_local_properties() {
  local directory temporary
  directory="$(dirname -- "$LOCAL_PROPERTIES")"
  mkdir -p "$directory"
  temporary="$(mktemp "$LOCAL_PROPERTIES.XXXXXX")"
  # Keep every non-sdk property (custom keys, machine settings); replace only
  # sdk.dir, and write nothing until the whole install verified.
  if [ -f "$LOCAL_PROPERTIES" ]; then
    grep -v -E '^[[:space:]]*sdk\.dir[[:space:]]*=' "$LOCAL_PROPERTIES" >"$temporary" || true
  fi
  printf 'sdk.dir=%s\n' "$SDK_DIR" >>"$temporary"
  if [ -f "$LOCAL_PROPERTIES" ] && cmp -s "$temporary" "$LOCAL_PROPERTIES"; then
    rm -f -- "$temporary"
    ok "local.properties already points at $SDK_DIR"
    return
  fi
  mv -- "$temporary" "$LOCAL_PROPERTIES"
  ok "wrote $LOCAL_PROPERTIES (sdk.dir=$SDK_DIR)"
}

check_gradle_wrapper() {
  local wrapper="$ANDROID_DIR/gradle/wrapper/gradle-wrapper.properties"
  local url=""
  local sha=""
  local problems=0
  if [ ! -f "$wrapper" ]; then
    warn "Gradle wrapper properties missing: $wrapper"
    return 1
  fi
  url="$(sed -nE 's/^distributionUrl=(.*)$/\1/p' "$wrapper" | sed 's/\\:/:/g' | sed -n '1p')"
  sha="$(sed -nE 's/^distributionSha256Sum=(.*)$/\1/p' "$wrapper" | sed -n '1p')"
  case "$url" in
    "https://downloads.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip") ;;
    *)
      warn "Gradle wrapper is not pinned to Gradle $GRADLE_VERSION at downloads.gradle.org: ${url:-absent}"
      problems=$((problems + 1))
      ;;
  esac
  if [ "$sha" != "$GRADLE_SHA256" ]; then
    warn "Gradle wrapper SHA-256 is not the pinned value: ${sha:-absent}"
    problems=$((problems + 1))
  fi
  if [ "$problems" -ne 0 ]; then
    return 1
  fi
  printf 'GRADLE_WRAPPER=gradle-%s (%s verified)\n' "$GRADLE_VERSION" "$GRADLE_SHA256"
  return 0
}

print_paths() {
  say "MODE=$MODE"
  say "PDSH_TOOLCHAIN_DIR=$TOOLCHAIN_DIR"
  say "JAVA_HOME=$JAVA_HOME_RESOLVED"
  say "ANDROID_HOME=$SDK_DIR"
  say "SDKMANAGER=$SDKMANAGER"
  say "LOCAL_PROPERTIES=$LOCAL_PROPERTIES"
  say "GRADLE_DIST=$GRADLE_DIST"
  say "GRADLE_USER_HOME=$GRADLE_USER_HOME_RESOLVED"
}

check_toolchain() {
  local failures=0
  local listing
  JAVA_HOME_RESOLVED="$(resolve_jdk)"
  print_paths
  say "MODE=check (no install, no download, no local.properties write)"

  if is_jdk17 "$JAVA_HOME_RESOLVED"; then
    say "JAVA=$(java_version "$JAVA_HOME_RESOLVED")"
    say "JAVAC=$(javac_version "$JAVA_HOME_RESOLVED")"
    ok "java and javac are both JDK 17"
  else
    say "JAVA=MISSING_OR_MISMATCHED"
    say "JAVAC=MISSING_OR_MISMATCHED"
    warn "not a consistent JDK 17 at $JAVA_HOME_RESOLVED: $(jdk_problem "$JAVA_HOME_RESOLVED")"
    failures=$((failures + 1))
  fi

  if check_gradle_wrapper; then
    :
  else
    failures=$((failures + 1))
  fi

  if [ -f "$GRADLE_DIST" ]; then
    if verify_download "$GRADLE_DIST" sha256 "$GRADLE_DOWNLOAD_SHA256"; then
      say "GRADLE_DIST_STATE=verified"
    else
      say "GRADLE_DIST_STATE=checksum-mismatch"
      failures=$((failures + 1))
    fi
  else
    say "GRADLE_DIST_STATE=not-downloaded (the committed wrapper fetches and verifies it on first use)"
  fi

  if [ ! -x "$SDKMANAGER" ]; then
    say "SDKMANAGER=MISSING"
    failures=$((failures + 1))
  elif [ "$failures" -eq 0 ]; then
    export JAVA_HOME="$JAVA_HOME_RESOLVED"
    export PATH="$JAVA_HOME/bin:$PATH"
    listing="$(mktemp "${TMPDIR:-/tmp}/pdsh-sdkmanager-list.XXXXXX")"
    if list_installed "$listing"; then
      if ! verify_packages "$listing"; then
        failures=$((failures + 1))
      fi
    else
      # Preserve the external command's failure code as the previous adapter
      # did, while retaining the subprocess cleanup on failure.
      local listing_rc=$?
      rm -f -- "$listing"
      exit "$listing_rc"
    fi
    rm -f -- "$listing"
  else
    say "PACKAGE check=SKIPPED (JDK 17 or wrapper pin missing)"
    failures=$((failures + 1))
  fi

  if [ -f "$LOCAL_PROPERTIES" ]; then
    local sdk_dir_line
    sdk_dir_line="$(sed -nE 's/^[[:space:]]*sdk\.dir[[:space:]]*=(.*)$/\1/p' "$LOCAL_PROPERTIES" | sed -n '1p')"
    say "LOCAL_PROPERTIES_SDK=${sdk_dir_line:-unset}"
  else
    say "LOCAL_PROPERTIES_SDK=unset"
  fi

  if [ "$failures" -ne 0 ]; then
    die "toolchain check failed: $failures problem(s); run bash android/tools/bootstrap-android-toolchain.sh"
  fi
  ok "toolchain check passed"
}

download_gradle() {
  local url
  local rc=0
  set +e
  # The official endpoint 307s to GitHub. Give that hop a bounded window before
  # trying a checksum-verified mirror; a stalled GitHub connection must not burn
  # the full download budget.
  ( download_verified "$GRADLE_URL" "$GRADLE_DIST" sha256 "$GRADLE_DOWNLOAD_SHA256" "${PDSH_GRADLE_PRIMARY_TIMEOUT:-30}" 0 )
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    return
  fi
  for url in $GRADLE_FALLBACK_URLS; do
    [ -n "$url" ] || continue
    warn "Gradle download failed from the primary endpoint (exit $rc); trying verified fallback: $url"
    set +e
    ( download_verified "$url" "$GRADLE_DIST" sha256 "$GRADLE_DOWNLOAD_SHA256" )
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      return
    fi
  done
  die "all Gradle download attempts failed (last exit $rc); no unverified archive was accepted" "$rc"
}

# Pre-seed the committed wrapper's own cache with the already-verified archive.
# The wrapper still owns the distribution URL and SHA-256; this only avoids a
# second GitHub fetch on the first build. The cache directory name is Gradle's
# documented wrapper layout (MD5 of the distribution URL, base36). When Python
# is unavailable the seed is skipped and the wrapper downloads normally.
seed_gradle_wrapper_cache() {
  local wrapper="$ANDROID_DIR/gradle/wrapper/gradle-wrapper.properties"
  local wrapper_url=""
  local hash=""
  local directory=""
  local extracted=""
  local launcher=""
  [ -f "$GRADLE_DIST" ] || return
  [ -f "$wrapper" ] || return
  wrapper_url="$(sed -nE 's/^distributionUrl=(.*)$/\1/p' "$wrapper" | sed 's/\\:/:/g' | sed -n '1p')"
  [ -n "$wrapper_url" ] || return
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; the committed wrapper will download Gradle on first use"
    return
  fi
  hash="$(python3 - "$wrapper_url" <<'PYHASH'
import hashlib
import sys

url = sys.argv[1]
value = int.from_bytes(hashlib.md5(url.encode("utf-8")).digest(), "big")
digits = "0123456789abcdefghijklmnopqrstuvwxyz"
out = ""
while value:
    value, remainder = divmod(value, 36)
    out = digits[remainder] + out
sys.stdout.write(out or "0")
PYHASH
)" || return
  directory="$GRADLE_USER_HOME_RESOLVED/wrapper/dists/$GRADLE_DIST_BASENAME/$hash"
  extracted="$directory/gradle-$GRADLE_VERSION"
  launcher="$extracted/lib/gradle-launcher-$GRADLE_VERSION.jar"
  mkdir -p "$directory"
  if [ ! -f "$directory/$GRADLE_DIST_NAME" ] || ! cmp -s "$GRADLE_DIST" "$directory/$GRADLE_DIST_NAME"; then
    cp -- "$GRADLE_DIST" "$directory/$GRADLE_DIST_NAME"
  fi
  if [ -d "$extracted" ] && { [ ! -x "$extracted/bin/gradle" ] || [ ! -s "$launcher" ]; }; then
    warn "removing incomplete extracted Gradle at $extracted"
    rm -rf -- "$extracted"
    rm -f -- "$directory/$GRADLE_DIST_NAME.ok"
  fi
  if [ ! -d "$extracted" ]; then
    rm -rf -- "$extracted"
    rm -f -- "$directory/$GRADLE_DIST_NAME.ok"
    unzip -q "$GRADLE_DIST" -d "$directory" || die "failed to unpack Gradle into $directory"
  fi
  [ -x "$extracted/bin/gradle" ] || die "Gradle seed has no executable bin/gradle: $extracted"
  [ -s "$launcher" ] || die "Gradle seed has no gradle-launcher-$GRADLE_VERSION.jar: $extracted"
  : > "$directory/$GRADLE_DIST_NAME.ok"
  ok "seeded Gradle wrapper cache: $directory"
}

install_toolchain() {
  mkdir -p "$TOOLCHAIN_DIR"
  [ -w "$TOOLCHAIN_DIR" ] || die "install root is not writable: $TOOLCHAIN_DIR"
  JAVA_HOME_RESOLVED="$(resolve_jdk)"
  print_paths

  install_jdk "$JAVA_HOME_RESOLVED"
  install_cmdline_tools
  export JAVA_HOME="$JAVA_HOME_RESOLVED"
  export PATH="$JAVA_HOME/bin:$SDK_DIR/platform-tools:$PATH"

  accept_licenses
  install_packages

  local listing
  local verify_rc=0
  listing="$(mktemp "${TMPDIR:-/tmp}/pdsh-sdkmanager-list.XXXXXX")"
  list_installed "$listing"
  set +e
  verify_packages "$listing"
  verify_rc=$?
  set -e
  rm -f -- "$listing"
  if [ "$verify_rc" -ne 0 ]; then
    die "Android SDK package verification failed for $verify_rc package(s)"
  fi

  is_jdk17 "$JAVA_HOME_RESOLVED" || die "java/javac are not a consistent JDK 17: $JAVA_HOME_RESOLVED"

  # The same archive the committed wrapper downloads, cached and verified here
  # so the pin is exercised by install too (the wrapper remains the only thing
  # that puts Gradle on the classpath).
  download_gradle
  check_gradle_wrapper || die "committed Gradle wrapper is not pinned to $GRADLE_VERSION/$GRADLE_SHA256"
  seed_gradle_wrapper_cache

  write_local_properties
  ok "Android toolchain ready (JDK: $JAVA_HOME_RESOLVED; SDK: $SDK_DIR; Gradle: $GRADLE_VERSION)"
}

if [ "$MODE" = check ]; then
  check_toolchain
else
  install_toolchain
fi
