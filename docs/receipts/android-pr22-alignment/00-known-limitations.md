# Android PR22 alignment — known limitations (00)

Status: **AUDIT COMPLETE — CANDIDATE UNACCEPTED**
Scope: prepared Fleet tree at `aa2e1aa` (candidate changes pinned in `9f09ef1`), PR14
`8c2eeab7b29728ebd0a54b71b5deaab07e5ac6eb`, PR22
`edd687463cd24b9c969914a13fa1da268df016fe`, shared main
`45de1121ee8b6df4323609ae45e66caa0d0fe29a`.
Date: 2026-11-02. Host: Linux (Debian 12), not a Mac, no Android device attached.

This file is the honest NOT_RUN list. A green JVM test or a source anchor is not a
substitute for any row below, and nothing here accepts the candidate.

## 1. Apple / Xcode checks — NOT_RUN

The audit host is Linux, so no Apple toolchain exists and no Swift build/test was
attempted. The pinned iOS sources are read-only authority, not a build input.

| check | status | exact command the Mac owner must run |
|---|---|---|
| PR22 Swift build/tests | NOT_RUN | `cd examples/probe-app && xcodebuild -scheme PhoneDSHProbe -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' test` |
| PR22 430x932 reference capture | NOT_RUN | `bash android/tools/ios-baseline-capture.sh` (Mac-side, after reviewing the script's destination) |
| iPhone hardware screenshot | NOT_RUN | manual capture on iPhone 14 Pro Max, 430x932pt @3, light/dark states listed in `00-baseline-audit.md` |
| Cross-platform pixel comparison | NOT_RUN | not implied by this audit; Android is compared only to its own accepted Android baseline |

The owner clarification says the Mac owner will independently capture PR22 on an
iPhone 14 Pro Max (430x932@3) and validate the installed Android app after export.
Linux workers must not claim that verification.

## 2. Android emulator / installed app — NOT_RUN

No emulator, AVD, or hardware device is available on this host. The JVM suites can
compile and execute the UI state/page logic, but they cannot exercise:

- first install / first launch / provider onboarding on a real device;
- IME open/closed, hardware keyboard, back gesture, system bars and edge-to-edge;
- native modal alerts, share sheet, SAF import/cancel, preview playback;
- notification permission, background keep-alive, process death/restore;
- 430x932pt screenshots of the installed app.

Exact commands retained for the Mac/device owner:

```bash
cd android
./gradlew :app:assembleDebug --no-daemon
./gradlew :lib:assembleDebugAndroidTest --no-daemon
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am instrument -w -e class com.phonedsh.probe.ui.page.NativeModalInteractionDeviceTest \
  com.phonedsh.probe.test/androidx.test.runner.AndroidJUnitRunner
bash tools/screenshot-capture.sh --profile ios-parity
```

`tools/screenshot-capture.sh` still describes the old 402pt frame. It cannot be
used as PR22 430x932 evidence until the frame constants change; see the 402/430
gap in `00-baseline-audit.md`.

## 3. Real provider / credentials — NOT_RUN

No production credential, API key, host SSH key or Git token was used. No real
third-party provider was contacted. Model-flow tests must use labelled scripted
upstreams only (for example `android/tools/scripted-model-upstream.py`), and that
is the only model path this audit exercised.

Provider get-models, test-connection and save are therefore **NOT_RUN against a
real service**. The source-level defect (no get-models/advanced settings) is in
`00-baseline-audit.md`; it is not a claim that the endpoint is broken.

## 4. Build/runtime artefacts — NOT_RUN or PARTIAL

- `:app:assembleDebug` with the real Worker bundle and Android JNI `.so`:
  NOT_RUN. The root app build needs the gitignored Worker bundle and a built
  `libpdsh_jni.so`; this audit did not fabricate empty stubs.
- `:lib:assembleDebugAndroidTest`: NOT_RUN (same reason; the JVM suite is the
  executable evidence collected here).
- Native host tests via `cargo build -p pdsh-jni`: NOT_RUN; no Android NDK
  toolchain was provisioned in this audit.
- Pinned plugins `npm ci` / `npm run typecheck`: NOT_RUN; this audit did not
  change plugin sources.

## 4b. JVM suite actually executed — 776 tests, 5 failed

The real UI-only JVM suite was executed after installing the toolchain:

```bash
cd android
JAVA_TOOL_OPTIONS=-Duser.home=<task-local-home> \
  ./gradlew --configure-on-demand -Ppdsh.uiCoreOnly=true :lib:testDebugUnitTest \
  --no-daemon --max-workers=2 --console=plain
```

Result: **776 tests, 5 failed, 771 passed** (`BUILD FAILED in 2m10s`). The five
failures are named with class/line in `00-baseline-audit.md` §3.4 (D9-D13); they
are contract/test defects, not acceptance. The exact required command *without*
`--configure-on-demand` also fails at configuration because `:app` needs the
absent Worker bundle; that is recorded in the audit, not hidden by this rerun.

Two environment problems were hit and fixed before those numbers were real:

- a first equivalent run reported 506 failures, all caused by Robolectric trying
  to create its download lock in the read-only container home directory;
- the `android-all-instrumented` jar was pre-populated from a public Maven mirror
  because the default download was throttled on this host.

Neither workaround is a product test; they only let the product assertions run.
The suite is still NOT a device/installed-App test.

## 5. Toolchain actually provisioned (environment evidence)

The checks that did run used a task-local toolchain, never a system package
install (the host root filesystem is read-only for apt):

| component | evidence |
|---|---|
| OpenJDK | Microsoft OpenJDK `17.0.21.0.2` (Temurin-compatible), unpacked under a task-local toolchain directory outside the repo; `java -version` exits 0 |
| Android SDK | command-line tools `11076708`; `platforms;android-35`, `build-tools;35.0.0`, `platform-tools` installed under a task-local Android SDK directory outside the repo; AGP also auto-installed `build-tools;34.0.0` during the first configuration; `sdkmanager --licenses` accepted |
| Gradle | wrapper `8.13`; distribution fetched from the Tencent mirror because `services.gradle.org` was throttled on this host; `GRADLE_USER_HOME` points at a task-local directory outside the repo |
| Python | system `python3`; spec/UI tools are stdlib-only |

This is environment evidence, not a product test. A missing toolchain is never
reported as a passing UI test.

## 6. CI-workflow deletion policy

The maintainer deleted `.github` (`8ee772b`). This audit did not restore, create
or edit any workflow. No CI workflow is part of the candidate bundle. The policy
stays: **do not restore deleted CI workflows**.

## 7. Evidence that is history, not proof

The prepared tree contains old Android parity receipts and screenshot baselines
(`docs/receipts/android-chat-parity`, `docs/receipts/ui-parity-sheet`, the 402pt
capture manifest and PNGs). They predate the PR22 430x932 design and the current
candidate. They are history:

- they do not prove the new baseline compiles or passes;
- they do not prove installed-App parity;
- they must not be relabelled as PR22 acceptance;
- Android screenshot regressions compare Android to an accepted **Android**
  baseline; cross-platform pixel equality is not implied.

## 8. What would still need acceptance

1. Engineering review of every `partial`/`missing` row in
   `docs/design/android-pr22-source-map.json`.
2. Fixes in the owning lanes (home routing, HomeDrawer, grouped settings,
   provider get-models, design tokens, spec refresh, jobs wiring).
3. Real JVM suites green on the integrated tree, including the app tests once
   the Worker bundle/JNI exist.
4. Mac-owned PR22 reference capture and installed-Android 430x932 validation.
5. A candidate-bound independent review and the serial integration decision.

Until then the only correct status is **UNACCEPTED**.
