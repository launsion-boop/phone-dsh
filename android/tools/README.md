# Android capture tools: three profiles, one frame contract

## Rust-backed host JVM tests

The workspace manifest declares Rust 1.85, but the lockfile-resolved workspace
was built and checked with Rust 1.99.1. Isolated Fleet test shells can start
with no Rust on `PATH`, so run native work through the pinned bootstrap wrapper:

```sh
bash android/tools/with-rust-toolchain.sh --check
bash android/tools/with-rust-toolchain.sh cargo build --locked --manifest-path shell/Cargo.toml -p pdsh-jni
bash android/tools/with-rust-toolchain.sh cargo test --locked --manifest-path shell/Cargo.toml -p pdsh-jni
```

The wrapper reuses a caller toolchain at least 1.99.1, otherwise installs pinned
1.99.1 only after checking the official channel manifest SHA-256
(`fb152be80975c194aa5fc684b2aec3a6e14e2b855efe2faa4e5f8ae6e590f463`) and
the platform-specific rustup-init 1.28.2 SHA-256 published by the official Rust
distribution host. The manifest is
[`channel-rust-1.99.1.toml`](https://static.rust-lang.org/dist/channel-rust-1.99.1.toml).
It keeps rustup and cargo
state under `RUSTUP_HOME` / `CARGO_HOME`, `XDG_CACHE_HOME`, or `HOME`; set the
cache variables to writable locations in isolated shells. `--check` never
installs or downloads. The normal command mode installs only when required and
then execs the requested command. Cargo commands use `--locked` so they do not
rewrite the repository lockfile.

Both `:app` and `:testkit` JVM test tasks stage the actual host artifact from
`shell/target/debug` into that module's generated test directory and set the
test JVM library path there. If the real artifact is missing, Gradle fails with
the wrapper command needed to build it. Android APK JNI packaging remains on
its existing Android-target `.so` input.

`android/tools/screenshot-capture.sh` captures Android pixels on a real emulator
in one of three **profiles**. The profile decides the frame and the baseline
directory; the capture chain (instrumented Compose → `captureToImage()` →
PixelCopy → PNG) is the same for all three.

| profile | frame | baselines | state names |
|---|---|---|---|
| `gate` | 1080 × 2400 px @ 420 dpi (411 × 914 dp) | `android/lib/src/test/resources/screenshots/` (11 PNGs) | `page-*`, `surface-*`, `fontscale-probe` |
| `ios-parity` | **1206 × 2622 px @ 480 dpi = 402 × 874 pt @ 3×** | `android/lib/src/test/resources/screenshots/ios-parity/` | the CAPTURED iOS state names (below) |
| `android-only` | same frame as `gate` | `android/lib/src/test/resources/screenshots/android-only/` (22 PNGs) | `l13-*`, `l14-*`, `l16-*`, `l24-*` |

The 402 pt frame is not a number this script owns: it is read out of
[`UiMetrics.kt`](../lib/src/main/kotlin/com/phonedsh/ui/UiMetrics.kt) at run time
(`BASELINE_WIDTH_PX`, `BASELINE_HEIGHT_PX`, `BASELINE_DENSITY_DPI`, …), so the
emulator display and the harness assertion cannot drift apart. To change the
frame, change `UiMetrics.kt`.

> **PR22 authority note.** The prepared PR22 baseline is **430 × 932 pt**. The
> capture profiles below still describe Android's historical **402 × 874 @3**
> frame; the capture harness and the token/spec work are separate packages.
> Until those land, treat a 402-frame capture as Android's own regression
> baseline, not as PR22 parity evidence. This bootstrap package does not change
> a pixel profile or claim a cross-platform visual comparison.

## Prerequisites: writable-HOME JDK 17 + Android SDK 35 + Gradle 8.13

The Gradle tree needs JDK 17 (both `java` and `javac`), Android SDK platform 35 /
build-tools 35.0.0 / platform-tools / cmdline-tools, and Gradle 8.13 through the
committed wrapper. `bootstrap-android-toolchain.sh` provisions them below the
*current writable HOME or XDG cache*, never in a shared machine service and
never in a directory derived from the checkout's parent:

```bash
# Install/repair. Idempotent: an existing consistent JDK 17 and command-line
# tools are reused, SDK licences are accepted non-interactively, and every
# installer's stdout/stderr stays visible.
bash android/tools/bootstrap-android-toolchain.sh

# Verify only. This downloads nothing, installs nothing and writes no file:
# java/javac must both be 17, sdkmanager must list platform-tools, platform 35
# and build-tools 35.0.0, and the committed wrapper must pin Gradle 8.13 + its
# SHA-256. It prints every resolved path.
bash android/tools/bootstrap-android-toolchain.sh --check
```

The default install root is `$XDG_CACHE_HOME/pdsh/android` when
`XDG_CACHE_HOME` is set, otherwise `$HOME/toolchains/pdsh-android`. The JDK
lands in `jdk-17/`, the SDK in `android-sdk/`, and verified archives in
`downloads/`. `--check` prints the exact paths on the current host. Overrides:

| variable | effect |
|---|---|
| `PDSH_TOOLCHAIN_DIR` | explicit install root (must be writable; tests use a temp dir) |
| `ANDROID_HOME` | use/install packages in an existing SDK root instead of `android-sdk/` |
| `PDSH_JAVA_HOME` | use an explicit JDK 17; a java-11/javac-17 mix fails |
| `JAVA_HOME` | reused only when java and javac are both 17; never modified |
| `PDSH_LOCAL_PROPERTIES` | install-mode output (default: `android/local.properties`) |
| `PDSH_JDK_URL`, `PDSH_JDK_SHA256` | pinned JDK archive override (both together) |
| `PDSH_CMDLINE_TOOLS_URL`, `PDSH_CMDLINE_TOOLS_SHA1` | pinned cmdline-tools override |
| `PDSH_GRADLE_URL`, `PDSH_GRADLE_SHA256` | pinned Gradle archive override (tests only) |
| `PDSH_GRADLE_FALLBACK_URLS` | transport mirrors tried only after the pinned SHA-256 matches; empty disables |
| `PDSH_GRADLE_USER_HOME` | Gradle cache root; precedence over `GRADLE_USER_HOME`, `XDG_CACHE_HOME`, `HOME` |
| `PDSH_GRADLE_PRIMARY_TIMEOUT` | single-attempt window for the official Gradle endpoint before a verified mirror (default 30 s) |
| `PDSH_CONNECT_TIMEOUT`, `PDSH_DOWNLOAD_TIMEOUT` | finite curl limits, default 20 s / 1800 s |
| `PDSH_CURL` | downloader executable override (tests supply a fake curl) |

Pins: Azul Zulu `17.0.21+3` (direct official CDN; SHA-256 per host from Azul's
metadata API), Google command-line tools `11076708` (SHA-1 from Google's
repository metadata), and Gradle `8.13`
from `https://downloads.gradle.org/distributions/gradle-8.13-bin.zip`
(SHA-256 `20f1b1176237254a6fc204d8434196fa11a4cfb387567519c61556e8710aed78`).
The wrapper uses that official endpoint rather than `services.gradle.org`
(which redirects to GitHub and has stalled in this environment), keeps the
same version, and verifies `distributionSha256Sum` before unpacking. In this
environment `downloads.gradle.org` also 307-redirects to GitHub release assets;
install therefore tries it first with a single bounded attempt (`--retry 0`,
default 30 s) and then the same archive name from public Gradle mirrors
(`mirrors.huaweicloud.com`, `mirrors.cloud.tencent.com`) **only after the
official SHA-256 verifies**, so a mirror cannot change the bytes. Fallback
attempts keep curl retries. Install then pre-seeds the committed wrapper cache
with the verified archive, avoiding a second GitHub fetch.

Install mode writes `android/local.properties` (gitignored) with
`sdk.dir=<resolved SDK>`, preserving unrelated keys, and only after every
package verifies. A download, checksum, extraction, licence or package failure
prints the exact command and its exit code, removes a `.part` download and exits
with that code. `--check` is a separate mode and performs no download.

### Running Gradle through the wrapper

Each isolated Gradle task must resolve its own environment; do not assume a
previous worker's ignored `local.properties`, `~/.gradle` or `HOME` is visible.
Use:

```bash
bash android/tools/with-android-toolchain.sh ./gradlew --version --no-daemon
bash android/tools/with-android-toolchain.sh ./gradlew :lib:testDebugUnitTest --no-daemon
```

The wrapper and bootstrap resolve the same Gradle cache:
`PDSH_GRADLE_USER_HOME` → `GRADLE_USER_HOME` → `XDG_CACHE_HOME/pdsh/gradle` →
`$HOME/pdsh/gradle`. The wrapper resolves `JAVA_HOME`, `ANDROID_HOME` and that
writable cache from the current environment (caller-supplied paths first, then
`android/local.properties`, then the bootstrap default), sets
`JAVA_TOOL_OPTIONS=-Duser.home=$HOME` for Robolectric, and execs the command
from `android/`. It never sources `local.properties`; keys are read with `sed`.
It works on macOS with caller-supplied `JAVA_HOME`/`ANDROID_HOME`.

```bash
# Equivalent explicit environment if you prefer not to use the wrapper:
export JAVA_HOME="$HOME/toolchains/pdsh-android/jdk-17"
export ANDROID_HOME="$HOME/toolchains/pdsh-android/android-sdk"
export GRADLE_USER_HOME="${XDG_CACHE_HOME:-$HOME}/pdsh/gradle"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
```

Required commands for this package (installation and verification stay
separate):

```bash
bash android/tools/bootstrap-android-toolchain.sh
bash android/tools/bootstrap-android-toolchain.sh --check
bash android/tools/with-android-toolchain.sh ./gradlew --version --no-daemon
python3 android/tools/structure_check.py --root .
python3 -m unittest discover -s android/tools -p 'test_*.py'
```

`test_bootstrap_android_toolchain.py` executes the real script in temporary
directories. Only the external downloader (a fake `curl` serving local fixture
archives) and the extracted fake `sdkmanager` are stubs; no test contacts the
network or installs into the real toolchain. Coverage: HOME/XDG default and
override resolution, `--check` output and its no-install guarantee,
`local.properties` generation and key preservation, idempotency, visible
installer stdout, checksum rejection, partial-download cleanup, and
download/licence/package exit-code propagation, including rejection of a
java-11/javac-17 mix.

The absolute-path structural check is not blanket-exempt for tool tests: fixtures
build machine paths from parts or temporary directories, and only embedded
shebang lines are skipped. `android/local.properties` is the sole machine-local
file exemption (it is gitignored).

### Maven consumer expectation

`:lib` is consumed by `:lib-consumer-test` as the published coordinate
`com.phonedsh:lib:0.1.0` from `android/build/repo`
(`./gradlew publishLocalRepository`), not as a file dependency on
`lib-release.aar`. A file dependency carries no POM/`api` closure and used to
fail R8 with missing sibling classes. A real consumer adds the same coordinate
and does not copy the AAR by hand.

## Which suites each profile runs

The APK carries every test class, so each profile passes an explicit `-e class`
list and can only capture its own suites.

| profile | suites | why these |
|---|---|---|
| `gate` | `PageScreenshotTest`, `SignatureSurfaceScreenshotTest`, `FontScaleProbeTest` | the 11 historical baselines, byte-comparable since before the parity work |
| `ios-parity` | `ParityScreenshotTest`, `SessionsParityScreenshotTest`, `ShellFilesParityScreenshotTest` | every state they write is `CAPTURED` in `ParityStates.kt` |
| `android-only` | `L13PagesScreenshotTest`, `L14BGroupPageScreenshotTest`, `L16ConfigurationPageScreenshotTest`, `L24ChatSubpagesScreenshotTest` | pages/surfaces the iOS baseline does not cover; self-regression only |

Two parity suites stay **out** of the script on purpose, because every state they
capture is still `PENDING`:

* `ChatParityScreenshotTest` — `page-chat-{assistant,official,queued,permission}`,
  `surface-code-block`;
* `DeviceConnectorParityScreenshotTest` — the three `androidOnly` device states.

They still run ad hoc (`am instrument -e class <class>`), and the registry check
is what keeps them out: `check_parity_registry` fails the run if the device writes
a PNG whose registry row is not `captured`, so a half-finished page cannot be
frozen into a baseline by accident. `L4NavWiringTest` and `PreviewSurfaceDeviceTest`
are behaviour suites (no `capture()` call) and are not part of any pixel profile.

## What the ios-parity capture proves — and what it does not

**能证明 / can prove:**

* Android renders the same 27 **named states** the iOS baseline publishes
  (`docs/receipts/ios-baseline-screens/*.png`), in the same `402 × 874 @3` frame
  the official golden uses (`capture.official.manifest.json` → `viewport 402×874`,
  `deviceScaleFactor 3`, `expectedPng 1206×2622`).
* A given state **does not drift between commits**: the capture is compared
  against Android's own previous capture of that state with the stated threshold
  in [`test_screenshot_compare.py`](test_screenshot_compare.py).
* The registry is complete: 27 registry entries ↔ 27 iOS files, checked on every
  parity run (`check_parity_registry` in the script).

**不能证明 / cannot prove:**

* That Android and iOS look the same. **No cross-platform pixel diff is run.**
  CoreText and Android's Minikin/HarfBuzz rasterise glyphs differently, the two
  systems draw different chrome, and the copy is localised on each side. Two PNGs
  of the same state are meant to be **compared by eye**, by the page lane that
  owns the state.
* That a state's *content* matches iOS. Several Android states still use the
  existing gate samples (see the "content" column below); the state name says
  "capture the same kind of screen", the page lane says "the same screen".

## The 402 pt shared metrics (iOS PR #13)

`UiMetrics.kt` is the single owner: `header 50`, `composer 370 × 98`,
`content 338`, `tool row 24`, `flow 6/12`. They are the **official UI's**
numbers, not the numbers the Android UI draws with — the drawing values live in
`spec/ui/v1/tokens.json` and mirror the iOS app (whose header is 44 pt). A parity
review measures a screenshot against `UiMetrics`; a rendering change edits the
token spec. Both layers are documented in the `UiMetrics.kt` KDoc, with the
per-number source.

## The 27 named states

Every state is registered in
[`ParityStates.kt`](../lib/src/androidTest/kotlin/com/phonedsh/ui/screenshot/ParityStates.kt).
The Android capture name is the PNG file name; the mapping rule is:

```
ios-chat-<state>       -> page-chat-<state>
ios-sessions-<state>   -> page-sessions-<state>
ios-settings-<page>    -> page-settings-<page>     (ios-settings -> page-settings-default)
ios-workspace-folders  -> page-workspace-folders
ios-files              -> page-files
ios-shell              -> page-shell
ios-code-block         -> surface-code-block       (a component swatch, not a page)
ios-environment-home   -> env-home                 (not an app page)
```

The prefix is the capture kind (`page-` whole screen, `surface-` component
swatch, `env-` environment proof); the rest is the iOS state id with `ios-`
removed. The two `-default` suffixes exist because `page-settings.png` and
`page-chat.png` are already gate baselines.

| # | iOS file | Android capture | screen | owner | status | note |
|---|---|---|---|---|---|---|
| 1 | `ios-chat-default` | `page-chat-default` | ChatPage | Chat lane | **captured** | settled turn (user + thinking + one folded tool run + assistant) over READY; iOS sample also carries a pending permission card, which needs a PendingSlot sample |
| 2 | `ios-chat-assistant` | `page-chat-assistant` | ChatPage | Chat lane | pending | engine-not-started empty state + one bubble + tool row + code block; needs a sample that puts a code block inside the transcript |
| 3 | `ios-chat-official` | `page-chat-official` | ChatPage | Chat lane | pending | the iOS shot exists to evidence a bug (blank transcript); decide whether Android captures the fixed state or the same bug before registering pixels |
| 4 | `ios-chat-failed` | `page-chat-failed` | ChatPage | Chat lane | **captured** | FAILED phase + retryable fail-loud banner; iOS draws a red 'not sent' line under the last bubble, so the failure chrome is not the same component |
| 5 | `ios-chat-queued` | `page-chat-queued` | ChatPage | Chat lane | pending | queued bubble badge + queued strip; queue dock geometry is the chat lane's |
| 6 | `ios-chat-long` | `page-chat-long` | ChatPage | Chat lane | **captured** | 6 long turns; only the first viewport is in frame (the harness captures no scroll position), so this is a density state, not a scrolled-to-bottom state |
| 7 | `ios-chat-draft` | `page-chat-draft` | ChatPage | Chat lane | **captured** | 5000-character draft over the engine-not-started empty state; composer at its declared max height |
| 8 | `ios-chat-permission` | `page-chat-permission` | ChatPage | Chat lane | pending | two permission cards; needs `PendingSlot` samples and the pending-card fold state |
| 9 | `ios-sessions-default` | `page-sessions-default` | SessionsPage | Sessions lane | **captured** | 0 sessions, 0 folders, engine off: the drawer's big empty block. iOS spells this state in a container that hides the 会话 section label; Android always renders it, so this capture equals page-sessions-nothing |
| 10 | `ios-sessions-many` | `page-sessions-many` | SessionsPage | Sessions lane | **captured** | 40 sessions dealt across 2 folders (20 each) from the baseline's own preview generator |
| 11 | `ios-sessions-empty` | `page-sessions-empty` | SessionsPage | Sessions lane | **captured** | 0 sessions, 2 folders, engine off: each folder renders its 还没有会话 block |
| 12 | `ios-sessions-nothing` | `page-sessions-nothing` | SessionsPage | Sessions lane | **captured** | 0 sessions, 0 folders: the true empty state, identical to page-sessions-default on Android |
| 13 | `ios-sessions-ungrouped` | `page-sessions-ungrouped` | SessionsPage | Sessions lane | **captured** | 3 sessions and no folder, so the ungrouped rows sit under the new-session row |
| 14 | `ios-sessions-error` | `page-sessions-error` | SessionsPage | Sessions lane | **captured** | one folder, two rows, and the host's 读不到会话 failure line with 重试 |
| 15 | `ios-sessions-schedules` | `page-sessions-schedules` | NativeAutomationPage | Sessions lane | **captured** | NativeAutomationPage.kt is not owned by the sessions lane, so this capture reports the page as it stands: a FAILED read renders the error instead of the empty block + error pair |
| 16 | `ios-settings` | `page-settings-default` | SettingsPage | Settings lane | **captured** | settings index with representative facts; iOS groups by 工具 / 关于, Android by the mirrored row model |
| 17 | `ios-settings-model` | `page-settings-model` | ModelProviderSettingsPage | Settings lane | **captured** | provider list with one selected service whose key is unreadable; the Android page renders 服务 / 说明 groups (the iOS shot is 服务 / 生效方式 with icon action rows) |
| 18 | `ios-settings-search` | `page-settings-search` | WebSearchSettingsPage | Settings lane | **captured** | 沿用模型服务 selected + a second backend without a key; the Android page lists the toggle and backend rows, the iOS shot is a 哪一份搜索 / 什么时候生效 form |
| 19 | `ios-settings-network` | `page-settings-network` | EgressAllowListPage | Settings lane | **captured** | allow-all off + the baseline 15 hosts in file order; Android renders 规则语法 and the add/restore actions the iOS shot does not show in frame |
| 20 | `ios-settings-plugins` | `page-settings-plugins` | NativeConfigurationPage | Settings lane | **captured** | two built-in groups + three permission presets; the iOS shot is the 插件 page with glass capsule buttons and plugin rows, Android contract calls for 内置插件设置 |
| 21 | `ios-settings-about` | `page-settings-about` | AboutPage | Settings lane | **captured** | preview-only on BOTH platforms (no route reaches it); captured from the page directly. Android adds 系统 / 更多 groups the iOS shot does not have |
| 22 | `ios-settings-runtime` | `page-settings-runtime` | RuntimeDetailsPage | Settings lane | **captured** | engine stopped (状态 已停止 in the shot); Android contract adds 本次运行 / 内存 / 电源 / 前台服务 sections that stay unrendered while nothing is measured |
| 23 | `ios-workspace-folders` | `page-workspace-folders` | WorkspaceFoldersPage | Shell/Files lane | **captured** | empty list + accent CTA captured; Android has no 34 pt large-title token (the heading is 17 pt headline) and no glass toolbar button |
| 24 | `ios-files` | `page-files` | FilesPage | Shell/Files lane | **captured** | empty workspace captured (grey capsule search + two-line card); Android has no 34 pt large-title token and the host reports no file listing, so the running app shows the waiting state instead of this sample |
| 25 | `ios-shell` | `page-shell` | PDSHShellPage (body) / ToolsPage.kt (reducer) | Shell/Files lane | **captured** | grouped-card body landed and is routed (设置 → 命令); rows are 44 dp and type is 14/13 sp against the baseline's 51.3 pt rows / 17 pt labels |
| 26 | `ios-code-block` | `surface-code-block` | DSSCodeBlock swatch | Chat lane | pending | the code block is not a standalone surface in :lib (it renders inside the tool detail card), so a swatch entry point has to exist before it can be captured |
| 27 | `ios-environment-home` | `env-home` | Android launcher | L0 capture (adb screencap) | pending | environment proof, not an app page: capture with `adb exec-out screencap -p`, which the Compose harness cannot do |

Status legend: `captured` means the PNG is in `screenshots/ios-parity/` after an
`ios-parity` run (the suite that writes it is in `PARITY_CLASSES`); `pending`
means the page lane has to freeze the page before it is worth a baseline, and the
script refuses to write it.

**Current pass: 21 of 27 captured, 6 pending.** The six are the four
`page-chat-*` states plus `surface-code-block` (Chat lane, in
`ChatParityScreenshotTest`, still PENDING) and `env-home` (an `adb screencap`,
not a Compose capture). The three `androidOnly` device states are PENDING too and
stay ad hoc.

## Two categories, one registry file

`ParityStates.kt` emits one file, `parity-registry.txt`, with a category column:

| category | rules the capture script enforces |
|---|---|
| `parity` | **exactly 27** rows; every `iosFile` exists in `docs/receipts/ios-baseline-screens/`; the iOS directory has no unregistered state; names and iOS files are unique |
| `androidOnly` | count is free; `iosFile` is `none`; the note must open with `no iOS baseline:`; owner non-empty; no name collides with a `parity` name |

The 27 invariant therefore still holds, and an Android state with no iOS
counterpart has a legitimate place instead of being forced into a table where it
would fail a gate it does not belong to. Both categories share one line format
(`category|android|ios|status|owner|screen|note`) so one pull parses both.

One check is strict in both directions: **every PNG the device wrote must be a
`captured` row** (an unregistered PNG would be a state nobody can map to iOS).
The other direction is reported, not failed — a `--states` subset, or a pass that
only ran one suite, legitimately writes fewer PNGs than the registry claims. The
script prints the difference.

## The `android-only` profile (L13/L14/L16/L24)

`--profile android-only` is a **baseline set, not a cross-platform claim**: the
pages and surfaces below have no iOS counterpart, so they get a pixel regression
gate of their own instead of being pushed into the 27-state table (or into the 11
historical gate baselines, whose count and meaning must not move).

| suite | PNGs |
|---|---|
| `L13PagesScreenshotTest` | `l13-chat-preferences`, `l13-settings-document`, `l13-shortcuts` |
| `L14BGroupPageScreenshotTest` | `l14-phone-permissions-unread`, `l14-phone-permissions-statuses`, `l14-phone-permissions-limited`, `l14-phone-permissions-confirm`, `l14-agent-presets-unread`, `l14-agent-presets-two`, `l14-plugin-inventory-unread`, `l14-plugin-inventory-expanded` |
| `L16ConfigurationPageScreenshotTest` | `l16-configuration-ready`, `l16-configuration-about`, `l16-configuration-permission`, `l16-configuration-add-notice` |
| `L24ChatSubpagesScreenshotTest` | `l24-chat-jobs-unread`, `l24-chat-jobs-rows`, `l24-chat-schedules-unread`, `l24-chat-schedules-rows`, `l24-chat-command-result-unread`, `l24-chat-command-result-success`, `l24-chat-command-result-failure` |

22 PNGs, captured at the gate frame (1080 × 2400 @ 420 dpi) in
`screenshots/android-only/`. `l14-phone-permissions-confirm` is the one
full-screen capture (`uiAutomation.takeScreenshot()`): a dialog is its own window,
so `captureToImage()` of the page frame would not contain it — and it is the one
PNG with no line in `metrics.txt`.

> **Naming collision, made explicit:** the `android-only` *profile* holds these 22
> L-suite PNGs. The registry's `androidOnly` *category* is something else — the
> three PENDING device-connector states in the next section. They are not in this
> profile (their frame is the parity one) and they are not captured yet.

## Android-only registry states (device connector)

| Android capture | screen | owner | status | why there is no iOS baseline |
|---|---|---|---|---|
| `page-device-connection` | NativeDeviceConnectionPage | Device connector lane (L5) | **pending** | no iOS baseline: the iOS 27-state baseline has no device-connector page (the connector is an Android-local seam), so there is nothing to lay it next to |
| `page-device-session` | NativeDeviceSessionPage | Device connector lane (L5) | **pending** | no iOS baseline: reading a remote session transcript is not in the iOS baseline set; the state is ours to define |
| `page-session-artifacts` | SessionArtifactsPage | Device connector lane (L5) | **pending** | no iOS baseline: the artifacts list is an Android-only surface, so it is a self-regression baseline with no cross-platform counterpart |

They are captured at the same frame and compared against Android's own previous
capture, exactly like a parity state; only the "lay it next to the iOS PNG" step
does not exist, because there is nothing to lay it next to.

## Fixed conditions of the parity frame

Set and then asserted by the script / harness (`FixedConditions` +
`ScreenshotProfile`); a device that does not match fails the first capture
instead of writing a baseline nobody can compare.

| condition | value | note |
|---|---|---|
| viewport | `wm size 1206x2622`, `wm density 480` | 402 × 874 pt @ 3×; identical to the official golden and the iOS baseline |
| font scale | `1.0` | i.e. the iOS "large" default content size |
| locale | `en-US`, asserted | **divergence:** the iOS baseline is `zh_CN`; changing an Android emulator's locale needs root + a reboot. The copy rendered is Chinese either way (`UiStrings` is the baseline's language). |
| theme | light, no action bar | `PdshTheme(darkTheme = false)`, test-only `NoActionBar` theme |
| backdrop | `#FFFFFF` | harness condition; `colors.background` is `tier: unmeasured` |
| window chrome | system bars hidden | the iOS shots show the 09:41 status bar; Android captures none |
| clock | virtual, frozen at +1000 ms | no blinking cursor, no shimmer phase |
| animations | window/transition/animator scale 0 | plus the Compose clock |
| device | API 35, `-no-window`, `-gpu swiftshader_indirect` | same rasteriser for every run |

All three profiles share one emulator AVD; the script re-pins `wm size`/`wm density`
between profiles and restores everything on exit.

## Usage

```bash
# everything that has a baseline, gate first (gate -> ios-parity -> android-only)
bash android/tools/screenshot-capture.sh --profile all

# 402 pt parity captures of the 21 CAPTURED states, compared against Android's
# own previous captures
bash android/tools/screenshot-capture.sh --profile ios-parity

# first time (or after a reviewed layout change): write the parity baselines
bash android/tools/screenshot-capture.sh --profile ios-parity --update

# a subset; the state is routed to the suite that owns it
bash android/tools/screenshot-capture.sh --profile ios-parity \
  --states page-chat-default,page-sessions-empty,page-shell

# the Android-only self-regression set
bash android/tools/screenshot-capture.sh --profile android-only

# the 11 historical gate baselines, unchanged
bash android/tools/screenshot-capture.sh --profile gate
```

Captures land on the device at
`/sdcard/Android/data/com.phonedsh.lib.test/files/pdsh-screenshots/<profile>/fs-<scale>/`
and are pulled to `android/build/screenshots-work/<profile>/fs-1.0/`.
`PDSH_SHOT_KEEP=1` keeps them after the run.

### Adding a state the registry already names

1. Add a sample to
   [`ScreenshotSamples.kt`](../lib/src/androidTest/kotlin/com/phonedsh/ui/screenshot/ScreenshotSamples.kt)
   that renders the state (pure, deterministic: no clock, no host, no locale).
2. Flip the entry in `ParityStates.kt` to `CAPTURED` and add one `@Test` to the
   suite that owns the page (`ParityScreenshotTest` for chat/settings,
   `SessionsParityScreenshotTest` for sessions, `ShellFilesParityScreenshotTest`
   for shell/files, or a new suite added to `PARITY_CLASSES`).
3. If the state lives in a new suite, add that suite to `PARITY_CLASSES` **and**
   add the state to `parity_owner_class()` in the script (that table routes
   `--states`; a missing entry fails loudly instead of capturing nothing).
4. `bash android/tools/screenshot-capture.sh --profile ios-parity --update`, then
   review the new PNG against `docs/receipts/ios-baseline-screens/`.
5. Never `--update` while another lane is still editing the page: the baseline
   would freeze that lane's in-flight pixels as the truth. Wait for a green
   `:lib:assembleDebugAndroidTest` and a quiet working tree first.

A `PENDING` entry with no `@Test` is deliberate: the registry is the contract
with the iOS side, the `@Test` list is what Android can honestly render today.

## Capture receipt (the run that produced these baselines)

```bash
# emulator: a private AVD created for this run, android-35, headless, swiftshader
emulator -avd pdsh-l34 -port 5664 -no-window -no-audio -no-boot-anim \
  -no-snapshot -gpu swiftshader_indirect -wipe-data
avdmanager delete avd -n pdsh-l34          # after the run

# gate: 7 of 11 baselines were stale (page lanes had landed since the last update)
ANDROID_SERIAL=emulator-5664 bash android/tools/screenshot-capture.sh --profile gate
#   RESULT=fail images=11 failed=7
#   FAIL page-chat-banner 14.4573% / page-chat 13.7639% / page-sessions 3.8738%
#   FAIL page-settings 42.7976% / surface-bubble 6.6120% / surface-composer 7.5828%
#   FAIL surface-tool-row 0.8891%

ANDROID_SERIAL=emulator-5664 bash android/tools/screenshot-capture.sh --profile gate --update
#   baselines updated (gate): 11 PNGs
ANDROID_SERIAL=emulator-5664 bash android/tools/screenshot-capture.sh --profile gate
#   RESULT=pass images=11 failed=0          (font proof: box 52 -> 99 px, ink 36 -> 65 px)

ANDROID_SERIAL=emulator-5664 bash android/tools/screenshot-capture.sh --profile ios-parity --update
#   OK (23 tests): 21 captures + registryIsComplete + the sessions router check
#   registry: 27 parity states (21 captured) + 3 androidOnly states (0 captured)
#   baselines updated (ios-parity): 21 PNGs
ANDROID_SERIAL=emulator-5664 bash android/tools/screenshot-capture.sh --profile ios-parity
#   RESULT=pass images=21 failed=0

ANDROID_SERIAL=emulator-5664 bash android/tools/screenshot-capture.sh --profile android-only --update
#   OK (26 tests) -> 22 PNGs
ANDROID_SERIAL=emulator-5664 bash android/tools/screenshot-capture.sh --profile android-only
#   RESULT=pass images=22 failed=0

# one-shot proof, after the last page change landed and the APK was rebuilt
ANDROID_SERIAL=emulator-5664 bash android/tools/screenshot-capture.sh --profile all
#   gate 11/11, ios-parity 21/21, android-only 22/22 = 54/54 pass
```

**Provenance.** `git HEAD` was `86a39aac` (the commit the iOS baseline was
re-shot at). The working tree is the lanes' landed changes on top of it; before
the final `--profile all` the tree was quiet for 180 s and the androidTest APK
was rebuilt from it. A SHA-1 fingerprint of every `*.kt` under
`android/lib/src/main` + `android/lib/src/androidTest` (excluding the preview
lane's `surface/preview/**`, which no pixel profile captures) was identical
before and after the run, so no lane moved a captured pixel mid-run. The last
non-preview edit (`WorkspaceFoldersPage.kt`, 19:55:27) was included in the 20:00
APK that produced the passing run.

**Registry fix found by this run.** `SessionsParityScreenshotTest` and
`ShellFilesParityScreenshotTest` used to publish only `ParityState.entries`, so
whichever suite ran last decided the registry contents and the `androidOnly`
section disappeared (the host then read "0 androidOnly states"). All three parity
suites now publish through `captureRegistryLines()` (both categories), and an
`--update` refuses to drop a name the previous registry had.

**What is still pending (6 of 27 parity states).** `page-chat-assistant`,
`page-chat-official`, `page-chat-queued`, `page-chat-permission`,
`surface-code-block` (Chat lane, `ChatParityScreenshotTest`) and `env-home` (an
`adb screencap`, not a Compose capture). Their registry status is `PENDING`, so
they have no baseline and the script will not write one. The three `androidOnly`
device states are `PENDING` for the same reason (`DeviceConnectorParityScreenshotTest`).

**No pixel semantics changed in the pending states:** `page-files` is still
captured (empty workspace) — the deleted `FilePreviewPage` was a *route target*
inside the Files lane, not the Files state itself; `ShellFilesParityScreenshotTest`
asserts 手机工作区 / 搜索文件 / 还没有文件 before capturing. What did change is
that `page-sessions-default` is now owned by the Sessions lane
(`sessionsNothing()`, the registry's "0 sessions, 0 folders" note); the older
`ParityScreenshotTest#pageSessionsDefault` capture (`sessionsState()`, 2 sessions)
was retired so two suites cannot write one PNG.

## Comparison threshold (unchanged)

`test_screenshot_compare.py`: a pixel differs when any RGBA channel moves by more
than 2/255; an image fails above 0.1 % differing pixels; a size mismatch always
fails. The rationale lives in
[`androidTest/README.md`](../lib/src/androidTest/README.md). It is used **only**
inside Android's own golden — never between Android and iOS.

## The product-flow acceptance run (`acceptance/`)

`bash android/tools/acceptance/run-product-flow.sh` drives the seven product
steps a person performs — save a key in 设置 → 模型服务 → 编辑 → 保存, create a
session, get a streamed answer, pick a CSV into the workspace, have the model
process it, preview/share the artifact, and survive a force-stop — and prints
one `PASS/FAIL 步骤N:` line per step, writing `acceptance-report.md` under
`$TMPDIR/pdsh-acceptance/`. Each step also runs alone (`--step 3`), and every
assertion reads evidence rather than the tap: the provider record and key
ciphertext on the device, `uiautomator dump` samples that show the answer text
growing while it streams, the file the App kept inside `materialized/workspace`
with the fixture's byte count, the amount total the fixture computed from the
tool result, the system chooser in front after 分享, and a different `pidof`
after the cold start. The model is the fixture in
`acceptance/fixtures/scripted-acceptance-upstream.py` (a script, not an
inference call) and `acceptance/fixtures/orders.csv` is the demo input; the
run's device is the dedicated AVD on port 5738 and the key it types is generated
per run, so no credential is ever written to this tree. A red step is the
deliverable: the line names the assertion, the measured value and the logcat
line that explains it.

### Ordinary filesystem permissions in isolated root test containers

`with-owner-fs-permissions.py <command> ...` preserves a normal caller unchanged.
When Fleet runs as Linux UID0, it drops only the current process tree's
`CAP_DAC_OVERRIDE`/`CAP_DAC_READ_SEARCH`, execs, and proves a private chmod-0500
directory rejects writes before running the original command. It never changes
the image, shared service, file ownership, or test assertions. This addresses the
observed root-only EchoJobAdapter permission-fixture mismatch; it is a test
environment adapter, not production filesystem policy. A failed capability or
permission proof exits2; no test is skipped. Each isolated stage uses it directly:

```sh
python3 android/tools/with-owner-fs-permissions.py bash android/tools/with-android-toolchain.sh ./gradlew :dsh:testDebugUnitTest --no-daemon --max-workers=2
```
