# iOS → Android visual diff (screenshots only)

Companion to `VISUAL.md`. Structural differences are **not** repeated here — the
machine list is `spec/ui/v1/tools/page_structure_check.py --strict` (152 items
after the 2026-11-01 contract refresh; it was 174 against the stale contracts).
This file lists what a human sees when the two PNG sets are put side by side.

* iOS: `docs/receipts/ios-baseline-screens/*.png`, 1206 × 2622 @3×, status bar
  included (59 pt), light, zh_CN, content size large, **re-shot 2026-11-01 at
  `86a39aac`** (post-PR-#13; the settings shot is now the five-tab sheet).
* Android: `android/lib/src/test/resources/screenshots/*.png`, 1080 × 2400 at
  420 dpi (density 2.625 → 411 × 914 dp), **no status bar in the capture** (the
  app draws edge-to-edge from y≈15 dp), locale en-US, theme light.
* Units: iOS pt vs Android dp. They are close enough to compare numerically
  (1 pt ≈ 1 dp) *except* for the status-bar offset, which shifts every vertical
  coordinate by ~59 pt / 0 pt.
* Android typography is in sp with `fontScale=1.0` (receipt:
  `screenshots/metrics.txt`), so sp values are directly comparable to pt.

The Android PNG set is **older than the iOS set**: `page-settings.png` still
renders the pre-PR-#13 flat index (模型 / 搜索 / 平台差异 with a battery banner)
while `SettingsPage.kt` has already been rewritten as the five-tab sheet, and
`page-sessions.png` still shows 会话列表 with inline 重命名/删除. Neither Android
screenshot may be diffed against the new `ios-settings.png` / `ios-sessions-*.png`
until the Android captures are re-run; the structural gap is on the machine list,
and below I only record the *type/rhythm tokens* that will still differ after
those structures align. `files` has no Android baseline at all.

## 1. Chat input dock — the largest visible difference

| property | iOS (`ios-chat-assistant.png`, `ios-chat-draft.png`) | Android (`surface-composer.png`, `page-chat.png`) |
|---|---|---|
| shape | **two-row card**, 369.7 × 93.7 pt collapsed | **single-row pill**, 48 dp tall |
| radius | **22 pt** (corner arc), not a pill | **24 dp = height/2** (full pill) |
| rows | input port + a 32 pt control row | input only; no control row |
| controls | `+` 28 pt circle, access-mode shield+chevron, model menu, send | **none** — only the send circle |
| send | 34 pt circle, bottom-right (center y 794.8 inside a 94 pt card) | 34 dp circle, **vertically centered** (y 20.6–54.1 in a 12.2–60.2 dp card) |
| send fill | disabled `#D7E0FF` (measured); enabled accent `#2F5BFF` | `#2F5BFF` in both baselines (no disabled state shown) |
| placeholder | “发消息或创建任务, / 调用指令, @ 文件或对话”, 17 pt, left 35.7 pt | baselines show a **draft** (“确认一下像素阈值的理由”), not a placeholder; no command/attachment hint |
| below the card | optional **13 pt stats row** (gauge/tok/context) starting 8 pt under the card, left 29.3 | permanent **12 sp counter** “12.4k / 200k” under the field, left 16.8 |
| border/shadow | 0.33 pt `#EEEFF1` + very soft shadow | 1 dp visible grey outline, no shadow |
| input typography | 17 pt, 24 pt line pitch, max port 336 pt (card 393.7 pt) | **visibly smaller**: CJK advance ≈11.9 dp/char and glyph ≈8.8 dp (≈12–14 sp), vs iOS 17 pt; single-line field in the baseline |

The dock is the one place where Android is visibly **smaller and emptier**: the
iOS card is twice as tall and carries three controls Android does not have.

## 2. Chat header

| property | iOS | Android |
|---|---|---|
| title | “新会话” **17 pt semibold, centered** (x 201) | “像素基线复盘” **≈22 sp bold, left-aligned** at x 45.7 after the icon |
| leading control | custom 22.7 × 17.7 pt sidebar glyph, 2.5 pt stroke, at x 20.3 | 3-bar hamburger, 22 × 9 dp at x 22.9 |
| status | 8 pt green dot **+ “运行中” 13 pt** (`#66666B`) + blue ellipsis (3.4 pt dots) | 8 dp dot **only** (no status text) + grey `…` |
| bar height | 44 pt below a 59 pt status area | ≈48 dp total, no status bar in capture |
| background | `#FFFFFF`, no hairline | `#FFFFFF`, no hairline |

## 3. User bubble

| property | iOS | Android (`surface-bubble.png`, `page-chat.png`) |
|---|---|---|
| fill | `#F2F3F5` | `#F2F3F5` (same) |
| radius | **20 pt for a 40.7 pt one-line bubble = height/2** | ≈24 dp; 2-line bubble ≈51 dp high → ≈height/2 as well |
| padding | 13.3 pt sides, 15 pt top/bottom | ≈16 dp sides |
| text | 17 pt `#000000`, right-aligned to 385.7 | 17 sp, right edge 361.5 in a 411 dp frame → 16 dp margin (matches) |

Bubble colour/radius/margin match closely; the iOS padding is ~2–3 pt tighter.

## 4. Tool row

| property | iOS (`ios-chat-assistant.png`) | Android (`surface-tool-row.png`) |
|---|---|---|
| row line | “工具调用 · Read · Package.swift”, **15 pt** `#66666B`, sparkle glyph at x 17, **no chevron** | “screenshot-capture ok · 10 张”, **≈16 sp** (glyph 11.8 dp) grey, **chevron.down at the far right** |
| expanded body | code block chrome `#F2F3F5`, radius 16 pt, 15 pt mono / 20.7 pt pitch | code box radius 16 dp, grey header strip + mono 15 sp, pitch ≈21 dp |
| wording | Chinese prefix “工具调用 · ” + tool name + argument | raw tool name + status word (“ok”) |

Both use a sparkle/terminal-adjacent icon and a mono expansion; Android's row is
about 1 sp larger and adds a disclosure chevron the iOS collapsed row does not show.

## 5. Failed turn (fail-loud)

| property | iOS (`ios-chat-failed.png`) | Android (`surface-fail-loud-banner.png`, `page-chat-banner.png`) |
|---|---|---|
| position | **inline under the failed bubble**, right-aligned to x 383, y 650–661 | **top of the transcript**, full-width row (y 53.7–64.8 dp) |
| type | 13 pt | ≈17 sp |
| colour | red `#C34437` “没发出去” + `#66666B` “ · 示例：这次回合失败了。” | orange “回合失败” + `#5F6368` message |
| actions | none rendered in this preview (retry only for real retryable IDs) | text actions “重试” / “关闭” on a second row |

## 6. Permission / approval card

| property | iOS (`ios-chat-default.png`, `ios-chat-permission.png`) | Android (`surface-approval-card.png`) |
|---|---|---|
| frame | 369.7 × **189 pt** | 327.6 × **221.3 dp** (crop) |
| radius | **12 pt** | ≈20 dp |
| fill | `#F2F3F5` | `#F2F3F5` (same) |
| header | `hand.raised.fill` 22 pt + “**等待授权**” **20 pt semibold** | no icon, “**需要授权**” **≈20 sp semibold** (glyph 15.6 dp) |
| body | 17 pt `#000000` | 17 sp grey `#5F6368` |
| primary button | 341.7 × **47.7 pt**, radius **12 pt**, `#2F5BFF`, 17 pt semibold white | 299.4 × **48 dp**, radius ≈20 dp, `#2F5BFF` |
| deny | 17 pt `#66666B`, text-only, centered | 17 sp `#5F6368`, centered |
| vertical rhythm | title/body/button/deny with 14/11.7/25.7 pt gaps | larger card because body is 2 lines, padding ≈19 dp |

Radius (12 vs ~20) and the missing icon are the eye-catching differences; button
height and colour already match.

## 7. Settings page — tokens only (structure is on the machine list)

| token | iOS (`ios-settings.png`) | Android (`page-settings.png`) |
|---|---|---|
| section header | **13 pt regular `#66666B`**, no chevron, x 32.7 | **≈16 sp**, grey, **chevron before the label** (collapsible group), x 16 |
| row label | **17 pt `#000000`**, 44 pt rows | ≈17 sp; row pitch ≈50 dp (text bands 224 → 274 dp) |
| row value | **15 pt `#66666B`** | ≈15 sp |
| row rhythm | 44 pt, hairline 0.33 pt `#DDDCE2` inset 16–385.7 | ≈50 dp, no visible hairline in the capture |
| switch | **63 × 29 pt**, track `#2F5BFF` | M3 switch (baseline not shown in this capture) |
| banner | none | orange 16 sp banner “电池优化未豁免…” at 53.7 dp |

## 8. Sessions page — tokens only

| token | iOS (`ios-sessions-default.png`) | Android (`page-sessions.png`) |
|---|---|---|
| search | **369.7 × 40 pt capsule**, white fill + soft shadow (no visible border), 20 pt icon, 17 pt placeholder | a bare **≈13 sp** “搜索会话” text line (glyph 9.1 dp; no field, no icon) |
| title row | “会话” **17 pt semibold** | “会话列表” **≈22 sp bold** left, with back chevron |
| row pitch | **56 pt** | **56.7 dp** (separators 146.7 / 203.4 / 260.2 / 317.0 dp) — matches |
| row title | 17 pt + 22 pt `message` icon + 13 pt time | **≈13 sp** (glyph 9.1 dp) + coloured status dot + inline 重命名/删除 actions |
| section grouping | workspace header 17 pt bold + “· 20 个会话” 15 pt | none in this baseline |
| CTA | 370 × 50 pt, radius 12, `#2F5BFF`, 17 pt semibold | “新建会话” is a plain 17 sp blue text link in the top bar |

## 9. Not comparable / missing

| Android baseline | why no diff |
|---|---|
| `files` | **no Android screenshot** for the files page |
| `fontscale-probe.png` | not a page; Android font-scale probe (text box 52 px @1.0 → 99 px @2.0). iOS was captured at the default `large` content size only, so no cross-platform statement can be made |
| `page-chat.png` thinking row | iOS thinking/reasoning row did not render in the captured iOS states (`chat.official` transcript is blank at HEAD), so there is no iOS counterpart to diff |
| `surface-approval-card` retry/second card | iOS `chat.permission` shows two static cards; Android shows one card with a longer body. Body copy differs but that is content, not chrome |

## Top three, eyeball-first

1. **The input dock**: iOS is a 370 × 94 pt two-row card (radius 22) with
   `+ / shield / model / send` and a command-hint placeholder; Android is a
   48 dp single-row pill with only a send circle and a token counter. Nothing
   else in the app looks this different at a glance.
2. **The chat header**: iOS centers a 17 pt title over a custom sidebar glyph,
   and prints the host status as dot **+ text** (“运行中”) with a blue ellipsis;
   Android left-aligns a ~22 sp burger title and shows only the dot.
3. **List rhythm and type scale**: iOS rows are 44 pt with 17 pt labels and
   13 pt grey section headers, separated by 0.33 pt `#DDDCE2` hairlines; the
   Android baselines use ≈50–57 dp rows and ~16 sp chevron group headers.
   Even after the structural gaps close (they are on the machine list), these
   tokens will keep the two screens reading as different products.
