# Release Android and HarmonyOS packages

Push a numeric tag such as `1.2.3` to `launsion-boop/phone-dsh` after the
[release workflow](../.github/workflows/mobile-release.yml) reaches that commit.
Use three decimal components without leading zeros. The major component can
reach 2098. The minor and patch components can each reach 999.

The Mac runner builds both apps with the tag as their version name. Both apps
use `1000000 + major * 1000000 + minor * 1000 + patch` as their version code.
GitHub Actions publishes the signed APK, signed HAP, and SHA-256 checksums
together at `ghcr.io/launsion-boop/phone-dsh:<tag>` after both builds pass.

## Set up the runner

Register a dedicated [macOS ARM64 runner](https://github.com/launsion-boop/phone-dsh/settings/actions/runners/new)
for the upstream repository with the custom label `phone-dsh-release`. Give the
runner a dedicated user or VM if the Mac hosts other services. Allow only
trusted users to create release tags and approve workflows from forks.

Install Node 24.9 or later with npm and pnpm, Python 3, JDK 17, and the Android
SDK with Platform 35, Build Tools 35.0.0, and NDK 28.2.13676358. Install
`cargo-ndk` and the Rust targets `aarch64-linux-android`,
`aarch64-unknown-linux-ohos`, and `wasm32-wasip1`.

Install Huawei's Command Line Tools with support for API 20 and the
`devecocli` executable. The script looks under
`$HOME/.local/share/phonedsh-harmony-tools` for `command-line-tools/` and
`devecocli`. For a different installation path, set `DEVECO_CLI_CLT_PATH` and
`DEVECO_CLI` in the repository's Actions variables.

## Configure signing

Add the signing secrets to the repository's `mobile-release` environment.

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64 of the Android release keystore |
| `PDSH_KEYSTORE_PASSWORD`, `PDSH_KEY_ALIAS`, `PDSH_KEY_PASSWORD` | Android keystore password, key alias, and key password |
| `HARMONY_KEYSTORE_BASE64` | Base64 of the HarmonyOS release `.p12` keystore |
| `HARMONY_CERT_BASE64` | Base64 of the HarmonyOS release `.cer` certificate |
| `HARMONY_PROFILE_BASE64` | Base64 of the HarmonyOS distribution `.p7b` profile for `com.phonedsh.app` |
| `HARMONY_STORE_PASSWORD`, `HARMONY_KEY_ALIAS`, `HARMONY_KEY_PASSWORD` | HarmonyOS keystore password, key alias, and key password |

The publish job uses the repository's `GITHUB_TOKEN` with `packages: write`.
After the first release, set the package visibility if you want anonymous
downloads.

## Download and verify a release

```sh
oras pull ghcr.io/launsion-boop/phone-dsh:1.2.3 --output release-bundle
(cd release-bundle && shasum -a 256 -c SHA256SUMS)
```

For a private package, authenticate to `ghcr.io` with package read access before
pulling. To retry a failed build or publish, rerun the failed job from the tag's
workflow run. Push a new version tag when the source changes.
