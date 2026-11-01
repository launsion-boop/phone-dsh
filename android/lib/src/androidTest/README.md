# Pixel regression baselines (Y1 lane)

## What this proves — and what it does not

**能 / can prove:** 从今以后 UI 改动导致的视觉回归会被抓住（像素 diff）。
From now on, a UI change that moves pixels is caught by a pixel diff.

**不能 / cannot prove:** 证明与 iOS 基线视觉一致。基线由**当前 Android 实现**生成，所以它是「防回归」而不是「parity 证明」。
It does **not** prove visual parity with the iOS baseline. The baselines are
generated from the **current Android implementation**, so this suite is a
regression gate, not a parity proof.

Both sentences must stay in this file and in every report about the baselines.
Removing the second one would turn an anti-regression tool into a false parity
claim.

## The chain: instrumented Compose on a real emulator

`android/lib/src/androidTest/` hosts real `androidTest`s. Each capture is:

```
createAndroidComposeRule<ScreenshotActivity>()
  -> fixed 1080x2400 window (bars hidden, white harness backdrop)
  -> setContent { PdshTheme(darkTheme = false) { <surface or page> } }
  -> virtual clock frozen at +1000 ms
  -> onNodeWithTag(frame).captureToImage()   // PixelCopy of the real window
  -> Bitmap.compress(PNG) into the app's external files dir
  -> adb pull
```

Why this chain is real and the rejected one was not:

* `captureToImage()` completes through `WindowCapture` → `PixelCopy.request`
  (`ui-test-android` 1.7.6). The bitmap is the emulator's actual composited
  window: real Minikin/HarfBuzz text layout, the system font, the platform
  `fontScale` multiplier, real AA and real rounded-corner rasterisation.
* Robolectric (the rejected pipeline) measured text with fake metrics: the same
  text box was **35 px at `fontScale` 1 and 35 px at `fontScale` 2**. It could
  not catch a type-scale or line-height regression at all.
* The counter-experiment is `FontScaleProbeTest`: one body-style line, one
  window, run twice with the **system** `font_scale` setting. Measured on the
  pinned emulator:

  | system font_scale | text box (`boundsInRoot.height`) | raster ink height in the PNG |
  | --- | --- | --- |
  | 1.0 | 52 px | 36 px |
  | 2.0 | 99 px | 65 px |

  If those two rows were equal, the chain would be fake. `screenshot-capture.sh`
  asserts both values grow by at least 1.5x before it will compare or update a
  baseline.

## Fixed capture conditions

A baseline captured under anything else is not comparable, so
`android/tools/screenshot-capture.sh` sets **and then asserts** every row:

| condition | value |
| --- | --- |
| device | the pinned AVD (`pdsh35`), API 35, arm64 |
| display | 1080 x 2400 px (`wm size`) |
| density | 420 dpi / density 2.625 (`wm density`) |
| font scale | 1.0 for baselines; 2.0 only for the probe proof run, restored afterwards |
| locale | `en-US` (asserted; changing it needs a reboot, so a wrong locale fails fast) |
| theme | light: `PdshTheme(darkTheme = false)`, test-only `NoActionBar` theme |
| window chrome | system bars hidden (immersive), no action bar |
| backdrop | `#FFFFFF` harness window background. `colors.background` is tier: *unmeasured*; white is a capture condition, never a product token |
| animations | window/transition/animator scales 0; Compose test clock `autoAdvance = false`, frozen at +1000 ms |
| screen | awake (`mWakefulness=Awake`) and `stayon true` for the run |

Device size/density overrides and the font scale are restored by an `EXIT`
trap, even when a capture fails.

## Baselines

`android/lib/src/test/resources/screenshots/` — 11 PNGs plus `metrics.txt`
(one line per capture: dimensions, dpi, density, fontScale, scaledDensity,
locale, theme, and the probe's text box height).

| file | coverage |
| --- | --- |
| `surface-bubble.png` | signature surface `bubble` (user bubble: fill + radius + body) |
| `surface-tool-row.png` | `toolRow` expanded, with the terminal detail card |
| `surface-thinking-pill.png` | `thinkingPill` settled (non-streaming) summary row |
| `surface-approval-card.png` | `approvalCard` pending permission (primary + secondary) |
| `surface-composer.png` | `composer` SEND with a draft and the stat pill |
| `surface-fail-loud-banner.png` | `failLoudBanner` TURN with retry + dismiss |
| `page-chat.png` | `ChatPage` full page: header, user/thinking/tool/assistant rows, dock |
| `page-chat-banner.png` | `ChatPage` with the fail-loud banner (FAILED phase) |
| `page-sessions.png` | `SessionsPage` full page: search, four statuses, actions |
| `page-settings.png` | `SettingsPage` full page: two groups + platform facts + note |
| `fontscale-probe.png` | the font-scale proof line (the file the 1.0/2.0 comparison uses) |

Surface captures use fixed dp frames (360 dp wide; heights 120–360 dp), so the
pixel grid never changes shape. Page captures use the whole 1080 x 2400 display.

Names are stable: `surface-<surface>.png`, `page-<page>.png`, plus the probe.
The comparator fails on a **missing** or **extra** PNG instead of silently
shrinking the gate.

## Comparison rule (stated, not implied)

Implemented in `android/tools/test_screenshot_compare.py`:

* a pixel is different when **any RGBA channel** differs by **more than 2/255**;
* an image fails when the differing pixels are **more than 0.1 %** of its pixels;
* a size mismatch is always a failure (the fixed conditions or the layout size
  changed, so the images are not comparable).

Why those numbers:

* **2/255 channel:** PNG is lossless, and two captures of the same build on the
  same emulator were **byte-identical** (0 differing pixels across all 11
  images). The tolerance is defensive headroom for rasteriser dithering across
  emulator boots, not permission to drift. It is also below the smallest gap
  between two declared colour tokens in `spec/ui/v1/tokens.json`, so a token
  colour edit always registers.
* **0.1 %:** on the smallest frame (945 x 315) that is **297 px**; on a full page
  (1080 x 2400) it is **2592 px**. A single moved glyph (hundreds of ink pixels),
  a shifted 1 px card border (~1800 px perimeter), or a 1 px padding change
  exceeds it, while page-level captures stay coarse enough that a single
  antialiased fringe does not flap. Pages are the coarse net; the six surface
  captures are the fine one.

Diff images are written to `android/build/screenshots-work/diff/` on failure
(red = differing pixel, faint grey = baseline layout).

## Run

```bash
# JAVA_HOME: JDK 21; ANDROID_HOME: the Android SDK (platform-tools on PATH);
# ANDROID_SERIAL: the pinned emulator. The script itself derives the SDK from
# android/local.properties when ANDROID_HOME is unset.
bash android/tools/screenshot-capture.sh           # capture + font-scale proof + compare
bash android/tools/screenshot-capture.sh --update  # replace the baselines (only after review)
```

`--update` still runs the font-scale proof first: a fake renderer cannot bless a
baseline. `--no-build` reuses the androidTest APK. `PDSH_SHOT_KEEP=1` keeps the
pulled captures under `android/build/screenshots-work/`.

The script uses only `:lib:assembleDebugAndroidTest`, installs the self-
instrumenting test APK `com.phonedsh.lib.test`, and runs the runner through
`am instrument` (Gradle uninstalls the test APK after `connectedAndroidTest`,
which would delete the captures before they can be pulled).

## Coverage gaps (explicit)

* **The five new pages and the app navigation are not covered.** Another lane is
  landing them in `:app`/`:lib` at the same time; capturing a half-written
  screen would freeze the wrong pixels. `ChatPage`, `SessionsPage`,
  `SettingsPage` are the three pages that already existed. Add a `@Test` per new
  page to `PageScreenshotTest` once that lane lands, then `--update` and review
  the new PNGs.
* **Streaming states are excluded on purpose.** The thinking pill is captured
  settled (`streaming = false`): the shimmer is an infinite animation whose
  phase would depend on real frame scheduling. The pill's geometry, ink and dot
  are covered; the sweep animation is not.
* **Text fields are captured unfocused**, so no blinking cursor is in the frame.
* **The font-scale probe only measures height, not full type-scale behaviour**
  at 1.3/1.5/1.8. 1.0 vs 2.0 is the falsification test for the chain, not a
  typography matrix.
* **This is one emulator image.** A different API level has a different system
  font and different insets; the baselines are pinned to API 35 (asserted).
* **Nothing here compares against iOS.** See the top of this file.
