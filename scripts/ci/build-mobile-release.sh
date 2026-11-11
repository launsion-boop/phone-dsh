#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
umask 077

die() {
  printf 'build-mobile-release: %s\n' "$*" >&2
  exit 1
}

tag="${1:-}"
if [[ ! "$tag" =~ ^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]]; then
  die 'expected a numeric x.y.z tag without leading zeros (major <= 2098, minor and patch <= 999)'
fi
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
[ "$major" -le 2098 ] || die "major version exceeds 2098: $tag"
version_code=$((1000000 + major * 1000000 + minor * 1000 + patch))

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
root="$PWD"
tag_commit="$(git rev-parse --verify "refs/tags/$tag^{commit}")"
[ "$(git rev-parse HEAD)" = "$tag_commit" ] || die "HEAD does not match tag $tag"

export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.2.13676358"
export DEVECO_CLI_CLT_PATH="${DEVECO_CLI_CLT_PATH:-$HOME/.local/share/phonedsh-harmony-tools/command-line-tools}"
export DEVECO_CLI="${DEVECO_CLI:-$HOME/.local/share/phonedsh-harmony-tools/devecocli}"
export PATH="$JAVA_HOME/bin:$PATH"

apksigner="$ANDROID_HOME/build-tools/35.0.0/apksigner"
hap_signer="$DEVECO_CLI_CLT_PATH/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
[ -x "$JAVA_HOME/bin/javac" ] || die 'set JAVA_HOME to a JDK 17 installation'
[ -d "$ANDROID_NDK_HOME" ] || die 'install Android NDK 28.2.13676358'
[ -x "$apksigner" ] || die 'install Android Build Tools 35.0.0'
[ -x "$DEVECO_CLI" ] && [ -f "$hap_signer" ] || die 'configure the DevEco CLI and Command Line Tools'
for tool in node npm pnpm cargo python3; do
  command -v "$tool" >/dev/null || die "$tool is missing from PATH"
done
cargo ndk --version

signing_variables=(
  ANDROID_KEYSTORE_BASE64 PDSH_KEYSTORE_PASSWORD PDSH_KEY_ALIAS PDSH_KEY_PASSWORD
  HARMONY_KEYSTORE_BASE64 HARMONY_CERT_BASE64 HARMONY_PROFILE_BASE64
  HARMONY_STORE_PASSWORD HARMONY_KEY_ALIAS HARMONY_KEY_PASSWORD
)
for name in "${signing_variables[@]}"; do
  [ -n "${!name:-}" ] || die "missing signing secret $name"
done
# Keep signing values out of the Worker build and dependency installers.
export -n "${signing_variables[@]}"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pdsh-mobile-release.XXXXXX")"
app_manifest="$root/harmony/AppScope/app.json5"
cleanup() {
  if [ -f "$work/app.json5" ]; then
    cp -p "$work/app.json5" "$app_manifest"
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

output="$root/release-output"
rm -rf "$output"
stage="$work/release-output"
mkdir "$stage"

export PDSH_DSH_CHECKOUT="$work/dsh"
dsh_repo="$(node -p 'require("./plugins/dsh-pin.json").repo')"
dsh_commit="$(node -p 'require("./plugins/dsh-pin.json").commit')"
pnpm_store="$work/pnpm-store"
git init --quiet "$PDSH_DSH_CHECKOUT"
git -C "$PDSH_DSH_CHECKOUT" fetch --quiet --depth=1 "$dsh_repo" "$dsh_commit"
git -C "$PDSH_DSH_CHECKOUT" checkout --quiet --detach FETCH_HEAD
(
  cd "$PDSH_DSH_CHECKOUT"
  export CI=true LEFTHOOK=0
  pnpm install --frozen-lockfile --store-dir "$pnpm_store"
  pnpm build
)
node plugins/scripts/dsh-checkout.mjs --verify
(cd plugins && npm ci --no-audit --no-fund)
bash scripts/ci/build-web-dist.sh --source "$PDSH_DSH_CHECKOUT" --store "$pnpm_store"
bash examples/probe-app/scripts/copy-bundle-assets.sh --checkout "$PDSH_DSH_CHECKOUT" --force

(cd shell && cargo ndk -t arm64-v8a build --locked -p pdsh-jni)
bash android/tools/fetch-termux-proot.sh
printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 -D > "$work/android.keystore"
PDSH_KEYSTORE_FILE="$work/android.keystore" \
PDSH_KEYSTORE_PASSWORD="$PDSH_KEYSTORE_PASSWORD" \
PDSH_KEY_ALIAS="$PDSH_KEY_ALIAS" \
PDSH_KEY_PASSWORD="$PDSH_KEY_PASSWORD" \
  bash android/tools/with-android-toolchain.sh ./gradlew --no-daemon \
    -Ppdsh.versionName="$tag" -Ppdsh.versionCode="$version_code" \
    -Ppdsh.requireReleaseSigning=true :app:assembleRelease
rm -f "$work/android.keystore"
apk="android/app/build/outputs/apk/release/app-release.apk"
"$apksigner" verify "$apk"
python3 scripts/ci/check-android-16k.py --root "$root" --apk "$apk"

cp -p "$app_manifest" "$work/app.json5"
node --input-type=module - "$app_manifest" "$tag" "$version_code" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs'
const [file, versionName, versionCode] = process.argv.slice(2)
const manifest = JSON.parse(readFileSync(file, 'utf8'))
manifest.app.versionName = versionName
manifest.app.versionCode = Number(versionCode)
writeFileSync(file, JSON.stringify(manifest, null, 2) + '\n')
NODE
bash harmony/tools/build.sh --build-mode release

printf '%s' "$HARMONY_KEYSTORE_BASE64" | base64 -D > "$work/harmony.p12"
printf '%s' "$HARMONY_CERT_BASE64" | base64 -D > "$work/harmony.cer"
printf '%s' "$HARMONY_PROFILE_BASE64" | base64 -D > "$work/harmony.p7b"
apk_name="phonedsh-android-$tag.apk"
hap_name="phonedsh-harmony-$tag.hap"
unsigned_hap="harmony/entry/build/default/outputs/default/entry-default-unsigned.hap"
"$JAVA_HOME/bin/java" -jar "$hap_signer" sign-app \
  -mode localSign -signAlg SHA256withECDSA -keyAlias "$HARMONY_KEY_ALIAS" \
  -keystoreFile "$work/harmony.p12" -keystorePwd "$HARMONY_STORE_PASSWORD" \
  -keyPwd "$HARMONY_KEY_PASSWORD" -appCertFile "$work/harmony.cer" \
  -profileFile "$work/harmony.p7b" -inFile "$unsigned_hap" -outFile "$stage/$hap_name"
"$JAVA_HOME/bin/java" -jar "$hap_signer" verify-app -inFile "$stage/$hap_name" \
  -outCertChain "$work/verified.cer" -outProfile "$work/verified.p7b"
test -s "$work/verified.cer" && test -s "$work/verified.p7b" \
  || die 'HAP verification did not export the certificate and profile'

cp "$apk" "$stage/$apk_name"
(cd "$stage" && shasum -a 256 "$apk_name" "$hap_name" > SHA256SUMS)
mv "$stage" "$output"
