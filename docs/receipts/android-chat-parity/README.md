# Android Chat family — iOS parity receipt (L1 lane)

Frame: `1206 × 2622 px @ 480 dpi` = **402 × 874 pt @ 3×** (`ScreenshotProfile.IOS_PARITY`,
owned by `UiMetrics`). Captured on a self-built AVD (`android-35`, port 5612) through
L0's shared harness `ScreenshotTestBase`; names come from `ParityStates.kt`.

Provenance of the device evidence: `git archive HEAD` + **only this lane's files**
(`ChatPage.kt`, `ChatRows.kt`, `surface/{ToolRow,Bubble,ApprovalCard,CodeBlock}.kt`,
`PdshNavHost.kt`+`PdshRoute.kt` Chat lines only) + L0's harness
(`ScreenshotTestBase`/`ScreenshotProfile`/`ScreenshotStore`/`ParityStates`) +
`UiMetrics.kt`. The shared working tree's in-flight files from other lanes are **not**
in the build.

## What this lane captured

| PNG | iOS baseline | Relation |
|---|---|---|
| `page-chat-assistant.png` | `ios-chat-assistant.png` | same content, same order |
| `page-chat-permission.png` | `ios-chat-permission.png` | same content |
| `page-chat-queued.png` | `ios-chat-queued.png` | same content |
| `page-chat-official.png` | `ios-chat-official.png` | same content (minus the scroll pill) |
| `surface-code-block.png` | `ios-code-block.png` | component swatch |
| `page-chat-route.png` | — | **routing receipt** (`PdshNavHost` + `PdshRoute.Chat`), not a parity state |

`page-chat-default/failed/long/draft` are captured by `ParityScreenshotTest` (L0) from
`ScreenshotSamples`; this lane's iOS-faithful samples for those four live in
`ChatParitySamples.kt` (`chatDefault()` / `chatFailed()` / `chatLong()` / `chatDraft()`)
and are ready to be swapped in.

## Measured geometry (pt, iOS side read off the PNGs)

| element | iOS | Android | verdict |
|---|---|---|---|
| permission card | 370 × 218, gap 16 | 370 × 219, gap 15 | **match** (Δ1) |
| permission CTA fill | `#2F5BFF` | `#2F5BFF` (`colors.ctaOverride`) | **exact** |
| card / bubble fill | `#F2F3F5` | `#F2F3F5` (`colors.selector`) | **exact** |
| disabled send fill | `#D7E0FF` | `#D7E0FF` | **exact** |
| send circle | 34 × 34 @ x345 | 34 × 34 @ x346 | Δ1 |
| `+` circle | 28 × 28 @ x30 | 28 × 28 @ x28 | Δ2 |
| user bubble (1 line) | 111 × 41 @ x275 | 109 × 41 @ x277 | Δ2 wide |
| user bubble (2 lines) | — | 45 tall | +4 vs iOS (see gaps) |
| code card | 370 × 96, radius 16, mono 15 | 370 × 134, radius 12, mono 12 | token gap |
| code chrome | `#E9E9ED` / `#F6F6F8` | `#E9E9ED` / `#F6F6F8` | **exact** |
| empty-state CTA | 338 × 50 @ x32 | 338 × 48 @ x32 | Δ2 (button token) |
| dock card | 370 × 93.7, bottom 818.7 | 370 × 94, bottom 837 | frame (no safe area) |

The vertical offset: the parity harness hides the system bars, so the Android frame has
no 59 pt status area and no 34 pt home-indicator inset. Page content therefore sits
~59 pt higher and bottom-anchored chrome ~21 pt lower than in the iOS PNGs. Compare
relative geometry, never absolute y.

## Known differences (with the reason)

1. **Mono type in the code card** — `typography.code` is 12 pt, the baseline measures
   15 pt; `radius.codeBlock` is 12 pt, the baseline 16 pt. Both are token values
   (`spec/ui/v1/tokens.json`), which this lane may not edit. Needs a token change.
2. **Syntax colouring** — the baseline paints `let` blue and string literals green; the
   token table has no syntax role, so the card draws one ink.
3. **User-bubble line pitch** — `geometry.bubbleLineSpacing` is 7 pt (21 pt pitch); the
   baseline measures 17.35 pt (a 2-line bubble is 64.7 pt there vs 66+ here). The
   assistant answer no longer adds it (measured 16.7 pt pitch = `typography.body`'s own
   line height).
4. **No hand glyph on the permission card**; iOS draws `hand.raised.fill` before
   “等待授权”. The Android icon set is an asset catalog this lane does not own.
5. **Header leading control** — the baseline's custom rounded-rect-with-rail glyph is
   drawn as `☰` (a text glyph); the ⋯ is `colors.accent` (`#3964FE`) while the baseline
   samples `#2F5BFF` (`colors.ctaOverride`, not in the composer/header token lists).
6. **Back-to-latest pill** — needs a drag gesture; the capture harness cannot scroll, so
   `ios-chat-official.png`'s pill has no Android counterpart in this set.
7. **Message actions** — baseline draws copy + share (assistant rows add like/dislike);
   Android draws the copy action only.
8. **`statusDotDiameter` colour** — `colors.success` is `#27865A`, the baseline dot
   samples `#0E9F6E` (token).
