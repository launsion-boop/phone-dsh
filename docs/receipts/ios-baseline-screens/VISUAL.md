# iOS visual spec — measured from the P1 screenshots

Every number here was measured from the PNGs in this directory, not read from
Swift source. Method: 1206 × 2622 px screenshots at 3× → divide pixel
coordinates by 3 to get points; text sizes come from glyph bounding boxes
(CJK glyph height ≈ 0.9 × font size, Latin cap height ≈ 0.7 × font size), row
geometry from separator/edge scans, radii from fitted corner arcs. Values are
rounded to 0.5 pt; a "≈" means the edge is antialiased or the fill is within
2–3 levels of white and the fit is less certain.

Shots used as evidence are named inline, e.g. `ios-chat-draft.png`.

> Preview harness artifact: the blue-grey ✕ circle at the top-left of most
> shots is the DEBUG cover's close button, **not page UI**. Do not measure it.
> `ios-chat-default.png` (route `sample`, no cover) has none.

## 0. Global tokens observed

| role | measured value | where |
|---|---|---|
| page background | `#FFFFFF` pure white | chat, sessions, files, settings (all) |
| primary ink | `#000000` | chat title, settings row labels, body text |
| secondary ink | `#66666B` | settings values / group headers, chat status text, stats row |
| disabled ink | `#C5C5C7` (chevron), `#D9D9DB` (disabled 新建会话) | settings chevrons, sessions |
| hairline / separator | `#DDDCE2`, 0.33 pt (1 px @3×) | settings rows, sessions rows |
| composer border | `#EEEFF1`, 0.33 pt | chat input card |
| card / bubble fill | `#F2F3F5` | user bubble, permission card, tool/code chrome |
| input surface | `#FFFFFF` | composer card |
| search surface (files) | `#EFEFF0` | files search field |
| accent | `#2F5BFF` (not system blue) | CTA buttons, picker value, ellipsis, send (enabled) |
| accent 40 % | `#D7E0FF` | disabled send circle |
| success | `#1AA475` | chat status dot |
| danger | `#C34437` | failed-turn label |
| body type | 17 pt regular, SF Pro / PingFang SC | bubbles, settings labels, titles |
| section header (settings) | 13 pt regular | 工具 / 关于 |
| section header (sessions) | 17 pt bold | 会话 |
| large page title | 34 pt bold | 模型服务 / 工作文件夹 / 手机工作区 / 工作区 |
| mono | 15 pt, line pitch 20.7 pt | code block |

## 1. ChatPage

References: `ios-chat-default.png` (clean header + running host),
`ios-chat-assistant.png` (host down), `ios-chat-draft.png` (max composer),
`ios-chat-permission.png`, `ios-chat-failed.png`, `ios-chat-queued.png`,
`ios-chat-official.png` (stats row + back-to-latest pill).

### 1.1 Header (44 pt bar under the 59 pt status area)

| element | measurement |
|---|---|
| bar height | **44 pt** content below the 59 pt status area; no bottom hairline, background `#FFFFFF` |
| title | “新会话”, **17 pt semibold**, `#000000`, centered at x = 201 pt; glyph box y 76.7–91.7 |
| sidebar control | 22.7 × 17.7 pt glyph at x 20.3, y 75–92.7; custom rounded-rect with a left rail and three small lines, black ~2.5 pt stroke — not the SF Symbol `sidebar.left` |
| status | 8 pt dot `#1AA475` at x 288–295.7, y 80–87.7 + text “运行中” **13 pt** `#66666B` (glyph 9.3 pt tall) 5 pt after the dot, baseline ending x 332 |
| overflow | three 3.4 pt dots, `#2F5BFF`, 18 × 3.4 pt box at x 355–373, y 82.3–85.7 |
| host-down state | same slot: grey `#C5C5C7` dot + “未启动” (see assistant shot) |

The title is **centered in the bar**, the status group sits right of centre and
the ellipsis is flush right (right inset ≈ 29 pt for the glyph cluster).

### 1.2 Pending-permission strip

`ios-chat-default.png`: one 44 pt row between the header and the card.
`exclamationmark.circle` 15 pt `#66666B` at x 17, text “还有 1 个待确认”
**13 pt** `#66666B` at x 30, `chevron.down` at x 379.7–384. Row text baseline
y 113.3–125.

### 1.3 Permission card

| property | value |
|---|---|
| frame | x 16–385.7 (**369.7 pt** wide), y 140.3–329.3 (**189 pt** tall) |
| fill / radius | `#F2F3F5`, corner radius **12 pt** |
| title row | `hand.raised.fill` ~22 pt at x 30; “等待授权” **20 pt semibold**, `#000000`, glyph x 53–124.7, y 156–174 |
| body | “要跑一条命令,可以吗?” **17 pt**, `#000000`, x 30.7, y 188–202.3 |
| primary button | x 30–371.7 (**341.7 × 47.7 pt**), radius **12 pt**, fill `#2F5BFF`, label “允许一次” 17 pt semibold white, vertically centered |
| deny | “拒绝” **17 pt** `#66666B`, centered at x 200.5, glyph y 287–300 — no fill, no border |
| inner insets | content leading 14 pt from the card edge; title-to-body gap ≈ 14 pt; body-to-button gap ≈ 11.7 pt; button-to-deny ≈ 25.7 pt |

`ios-chat-permission.png` shows two such cards stacked with 8 pt gap; the card
is the same geometry.

### 1.4 Transcript rows

| row | measurement |
|---|---|
| user bubble | fill `#F2F3F5`, **radius 20 pt = height/2** (capsule for one line), text 17 pt `#000000`, padding **13.3 pt** left/right and **15 pt** top/bottom; one-line bubble 40.7 pt tall, right-aligned to x 385.7 |
| assistant text | no bubble, 17 pt `#000000`, full-width text column, line pitch ≈ 24 pt |
| tool row | 15 pt `#66666B`: 4-point sparkle glyph at x 17, “工具调用 · Read · Package.swift”, 44 pt row; no chevron when collapsed |
| queued label | “已排队” **13 pt** `#66666B`, **left-aligned at x 17** under the right-aligned bubble (not under the bubble's left edge) |
| failed line | right-aligned to x 383, y 650–661: “没发出去” `#C34437` + “ · 示例：这次回合失败了。” `#66666B`, **13 pt**; no retry button in this preview state |
| code block | `#F2F3F5` chrome, 16 pt radius, header strip 26 pt with “swift” 13 pt `#66666B` + copy icon; code 15 pt mono, 20.7 pt line pitch |
| back-to-latest pill | capsule 94 × 30 pt centered at x 200.3, y 651.7–681.7; near-white glass fill, 0.5 pt border, `arrow.down` + “回到最新” **17 pt** `#2F5BFF`; 23 pt above the composer card |

### 1.5 Input dock (chat) — the detailed section

All measurements from `ios-chat-assistant.png` (collapsed), `ios-chat-draft.png`
(max height) and `ios-chat-official.png` (stats row). The dock is **not a single
pill**: it is a 370 pt-wide elevated card with an input port, a full control
row, and an optional stats line underneath.

#### Card geometry

| property | collapsed | expanded (5000-char draft) |
|---|---|---|
| outer frame | x **16–385.7** (369.7 pt wide) | same |
| top / bottom | y **725.0 → 818.7** | y **425.0 → 818.7** |
| height | **93.7 pt** | **393.7 pt** |
| corner radius | **22 pt** (fitted arc) | 22 pt |
| fill | `#FFFFFF` | `#FFFFFF` |
| border | 0.33 pt `#EEEFF1` (1 px @3×) | same |
| shadow | black ≈6 % opacity, blur ≈12 pt, y≈3 pt — a barely visible halo, no hard drop shadow | same |
| horizontal insets | 16 pt to each screen edge | same |

With the stats row present the whole dock lifts by **20 pt**: card y
**705.0–798.7** (same 93.7 pt height) and the stats glyphs sit at y 814–828
(`ios-chat-official.png`).

#### Input port

| property | value |
|---|---|
| placeholder text | **“发消息或创建任务, / 调用指令, @ 文件或对话”** — full-width comma after 任务, then “ / 调用指令, @ 文件或对话”; single line, truncates, never wraps |
| placeholder type | 17 pt regular, sampled core `#ACB1B7` (light grey; antialiased glyphs never reach the token colour) |
| placeholder origin | x **35.7 pt**, glyph y 739.0–752.7 (card top + 14.3) |
| text origin | x **35.7 pt**, first line glyph top y 439.3 in the expanded state (card top + 14.3) |
| line pitch | **24 pt** (17 pt font + 7 pt line spacing), measured across 14 wrapped lines in `ios-chat-draft.png` |
| port height | min **36 pt** / max **336 pt** (expanded card 393.7 = 4 + 336 + 10 + 32 + 12) |
| scroll | the port scrolls internally after 336 pt; the card stops growing |
| caret colour | accent `#2F5BFF` (visible in focus-dependent shots; not captured focused) |

#### Control row (inside the card, below the input port)

Row frame: height **32 pt**, top padding **10 pt**, bottom padding **12 pt**,
leading **14 pt**, trailing reserved **40 pt** for the send circle. Items are
vertically centered.

| control | measurement |
|---|---|
| `+` button | **28 pt** circle, fill `#F8F8F9`, `plus` glyph 14 pt `#66666B`, center x ≈ 46, circle box x 30–63 with antialias/shadow |
| access-mode menu | `lock.shield` outline **17 pt** `#66666B` + `chevron.down` 8 pt; shield at x ≈ 73–90, chevron x ≈ 96–103; no capsule fill (bare glyphs) |
| model menu | right side, before send: host-down state “模型” **15 pt** `#66666B` + chevron (glyph box x 300–337.7); host-up state “deepseek-flash High” **17 pt `#000000`** (glyph box x 233.3–338) + chevron; ~6 pt gap to the send circle |
| send | **34 pt** circle, box x 345–378.7, y 778–811.7 (center 361.8, 794.8); fill **`#D7E0FF` when disabled**; `arrow.up` 15 pt bold white; whole control has a 44 pt hit frame with 2 pt trailing/2 pt bottom inset. Enabled fill is the accent `#2F5BFF` (same accent measured on the permission CTA), but an enabled send was **not capturable** in this preview build |
| stop | **not captured.** Stop only appears while a turn is running (`model.turnRunning`); no `-uiPreview` route starts a turn. The view code draws a 34 pt circle `#66666B` with `stop.fill` 13 pt white, and a 24 pt variant when a submit is also possible; this is *not* screenshot-measured, so treat it as unverified |
| busy spinner | not captured (turn-running only) |

#### Stats row (optional, below the card)

`ios-chat-official.png`: glyph box y **814–828**, left-aligned at x **29.3** (≈30), **13 pt**
`#66666B`, with 13 pt outline glyphs between groups:

```
(gauge) 5 轮 17 步  ·  54 tok/s  (cylinder) 1.0M tok  ·  缓命中 75%  (ring) 10%
```

Groups are separated by a middot with 8 pt side padding; icons are
`gauge.with.dots.needle.33percent`, `cylinder`, `circle` (outline, not filled).
Not present in the assistant/draft/default states (empty session stats).

#### Queue strip / attachments / command menus

* **Queue strip**: design intends a “排队中 N 条” header (12 pt) + 28 pt-high
  queued rows (13 pt, 8 pt radius, `#F6F6F8`). In the only queued preview
  (`ios-chat-queued.png`) the strip **did not render**; only the per-message
  “已排队” label appeared. Treat the strip as unmeasured.
* **Attachment strip / file-import notice / slash-command menu / @-reference
  menu / goal bar**: all require interaction (picker, typing `/` or `@`, a
  running goal). None was reachable from `-uiPreview`; this receipt has no
  screenshot of them and no measurements for them.

#### What state each dock shot shows

| shot | port height | port content | controls | send |
|---|---|---|---|---|
| `ios-chat-default.png` | 93.7 pt | placeholder | +, shield, “deepseek-flash High”, send | disabled `#D7E0FF` |
| `ios-chat-assistant.png` | 93.7 pt | placeholder | +, shield, “模型”, send | disabled `#D7E0FF` |
| `ios-chat-failed.png` | 93.7 pt | placeholder | +, shield, “模型”, send | disabled |
| `ios-chat-permission.png` | 93.7 pt | placeholder | +, shield, “模型”, send | disabled |
| `ios-chat-draft.png` | **393.7 pt** | 5000-char draft, 14 wrapped lines, port scrolled to bottom | +, shield, “模型”, send | disabled |
| `ios-chat-official.png` | 93.7 pt | placeholder | +, shield, “模型”, send | disabled; stats row present |
| `ios-chat-long.png` | 393.7 pt | 5000-char draft over a long thread | +, shield, “模型”, send | disabled |

## 2. SettingsPage (`ios-settings.png`)

| property | measurement |
|---|---|
| chrome | inline nav title “设置” **17 pt semibold** centered at y 76.7–91.7; glass “完成” capsule top-left (17 pt `#2F5BFF` label in a ≈44 pt Liquid-Glass circle); pure white page, **no grouped card backgrounds** |
| background | `#FFFFFF`; the standard inset-grouped grey is hidden, layers are made by spacing + hairlines only |
| first row top | 150.7 pt (≈47.7 pt below the nav bar) |
| row | height **44 pt**; label **17 pt** `#000000` at x **16.7**; value **15 pt** `#66666B`, right edge ≈350 pt when a chevron is present (chevron at x 360.7–367.3, 6.7 × 11.3 pt, `#C5C5C7`) |
| hairline | `#DDDCE2`, **1 px (0.33 pt)**, inset **16 → 385.7 pt** (369.7 pt long) |
| section header | “工具” / “关于”, **13 pt regular**, `#66666B`, **no uppercase transform**, x **32.7** (16 pt card inset + 16 pt header inset), glyph height 11 pt; header glyph top sits at y 397.3 (工具) / 665.0 (关于); the next row's label starts 36 pt below that (工具 397.3 → 433.3), and the header's glyph bottom is 10.7 pt above the next 44 pt row's top edge |
| toggle row | “后台运行” 17 pt label + **63 × 29 pt** iOS 26 switch (track `#2F5BFF`, white thumb 26 pt) at x 309–371.7, y 337–364.7. **Anomaly:** this row is only **34 pt** tall (separator at 326.7 → 360.7) while text rows are 44 pt, so the 29 pt switch hangs ~4 pt over the hairline and the line is visible *through* the switch's lower edge |
| picker row | “发送消息时” 17 pt + value “排到下一轮” **17 pt `#2F5BFF`** + `chevron.up.chevron.down` 16 pt, right edge 367.7 |
| footer | none in this state (footer text only for warnings/saves) |
| groups | ① no title: 权限 / 写之前 / 模型服务 / MCP / 后台运行 ② 工具: 网页搜索 / 网络访问 / 插件与模型 / 命令 / 发送消息时 ③ 关于: 版本 / 开源许可 / 导出诊断 |
| absent | no 开发者 row, no 探针工具, no MCP server count (0 → “未配置”) |

Row pitch is exactly 44 pt (132 px): separators at 194.7, 238.7, 282.7, 326.7,
462.3, 506.3, 550.3, 594.3, 730.0, 774.0 pt.

### 2.1 Subpages

| page / shot | measured headline geometry |
|---|---|
| `ios-settings-model.png` | large title “模型服务” **34 pt bold**, glyph y 125.7–155, x 17.7; section headers “服务”/“生效方式” **20 pt**, `#66666B` (glyph 181–195.7); service name 17 pt semibold + “默认” 12 pt blue on `#E8EDFF` capsule; URL 15 pt `#66666B`; “读不到密钥” 13 pt orange `#C77700`; checkmark `checkmark.circle.fill` 22 pt `#2F5BFF` at x 360; action rows “添加模型服务”/“编辑默认服务” 17 pt `#2F5BFF` with `plus.circle` / `slider.horizontal.3`; 0.33 pt `#DDDCE2` separators inset 16 |
| `ios-settings-search.png` | large title 34 pt (125.7–155); first section header 20 pt at 181–195.7; form rows 17 pt with 13 pt notes; accent-blue status text |
| `ios-settings-network.png` | **inline** nav title “网络访问” 17 pt centered (79.3–88.3); “允许连任何网站” 17 pt + **63 × 29 pt** switch (off: track `#E9E9EA`); note 13 pt `#66666B` at x 46; group header “地址” **17 pt bold grey** (glyph 246–260.3) with right value “15 个地址” 15 pt; domain rows 17 pt, ~56 pt pitch, separators 16 → 385.7 |
| `ios-settings-plugins.png` (NativeConfigurationPage) | large title “插件” 34 pt (125.7–155); description 13 pt; a row of **three glass capsule buttons** (插件说明 / 刷新 / 添加插件, blue ~15 pt labels, ~37 pt tall); orange 15 pt host-off warning; “内置插件设置” **20 pt** `#66666B` header; rows = 22 pt leading icon + 17 pt title + 13 pt subtitle, 0.33 pt separators inset 16–385.7; “网页搜索与抓取” row carries a trailing chevron; 完成 glass pill top-right (not top-left like Settings) |
| `ios-settings-runtime.png` | large title 34 pt; label 17 pt + secondary 15 pt rows at 44 pt pitch; status dot pattern reused |
| `ios-settings-about.png` | **no large title**: inline nav title “关于”, rows 17 pt at 170–184.7 and a 13 pt footer at 223.7–235 |
| `ios-sessions-schedules.png` (NativeAutomationPage) | large title “定时任务” 34 pt (125.7–155); 新建 glass pill top-right; empty state title 17 pt semibold + 15 pt subtitle + **370 × 50 pt radius-12 `#2F5BFF` CTA**; “需要处理” **20 pt** grey header; with the host off the baseline prints a **raw English error** (“The operation couldn't be completed. (ProbeKit.ProbeHostError error 3.)”) in red 15 pt — a real baseline defect, not a capture artifact |
| `ios-shell.png` (PDSHShellPage) | no large title; dense rows 17 pt at 128.7/175/227.3/279.7 pt, secondary 13 pt `#66666B` |
| `ios-code-block.png` | code block swatch: mono 15 pt, line pitch 20.7 pt, `#F2F3F5` chrome, 16 pt radius |

## 3. SessionsPage (`ios-sessions-default.png`, `ios-sessions-many.png`)

| property | measurement |
|---|---|
| search field | x 16–385.7, y 108.7–148.3 → **369.7 × 40 pt**, **capsule radius 20 pt**, fill `#FFFFFF` with **no visible fill/border difference** — the capsule is defined by a very soft shadow and a faint `#FAFAFA` edge (sampled); `magnifyingglass` 20 pt `#66666B` at x 33.3; placeholder “搜索会话” **17 pt**, sampled core `#727272`; text left x 56.7 |
| section title “会话” | **17 pt semibold**, `#000000`, x 16.3, glyph y 206.7–221.7 |
| 新建会话 row | height 44 pt; `plus` icon 18 pt + “新建会话” **17 pt**; both **disabled grey `#D9D9DB`**; hairline under it 16 → 304 pt |
| helper line | “先启动本地引擎,才能新建会话。” **13 pt** `#66666B`, x 16.7, y 310.3–323 |
| group header | `chevron.down` 13 pt + workspace name **17 pt bold** `#000000` + “· 20 个会话” **15 pt** `#66666B`; trailing `ellipsis`; glyph y 359.3–373 |
| session row | pitch **56 pt**; `message` outline icon **22 pt** `#66666B` at x 24.3; title **17 pt** `#000000` at x 52; time **13 pt** `#66666B` at x 52; row 1 title glyph y 405–420, time 427.3–437.7 |
| row separators | `#DDDCE2`, 0.33 pt, **x 16 → 303.7 pt** (the list is laid out for the 320 pt drawer even in the 402 pt preview frame) |
| empty state | “还没有工作文件夹” **17 pt semibold** centered, glyph y 283.3–293; “选一个文件夹,会话和文件都放在里面。” **15 pt** `#66666B`, y 293.3–306.3; CTA **370 × 50 pt**, radius **12 pt**, `#2F5BFF`, label 17 pt semibold white, y 348.7–398.3 |
| empty variants | `sessions.empty` / `nothing` show the same CTA with different copy; `sessions.error` replaces the list with one error line + trailing 重试 |
| background | `#FFFFFF`; no card grouping |

## 4. FilesPage (`ios-files.png`)

| property | measurement |
|---|---|
| large title | “手机工作区” **34 pt bold**, x **17.7**, glyph y **125.7–155** — no nav bar, the title scrolls with content |
| search field | x 16–385.7, y 169–212.7 → **369.7 × 43.7 pt**, **radius 16 pt** (not a capsule), fill **`#EFEFF0`**, no border; `magnifyingglass` 20 pt `#66666B` at x 30; “搜索文件” **17 pt**, sampled core `#848488` |
| empty state | “还没有文件” **17 pt semibold** centered, glyph y 269.7–283; “智能体做的文件会出现在这里。” **15 pt** `#66666B`, y 283.3–306.3 |
| top-right action | blue-glass disc ≈50 pt including its halo at x 328.3–383, y 56.3–106.3 (the visible disc is ≈44 pt) with `cube` outline 20 pt `#2F5BFF`; sits in the safe-area corner |
| background | `#FFFFFF`; no separators, no cards |

## 5. Unmeasured / unverified

These are deliberately **not** in the spec because no screenshot exists:

* chat stop button, busy spinner, enabled send button, focused keyboard state;
* attachment strip, file-import notice, slash-command menu, @-reference menu,
  goal bar, queue strip (did not render in the queued preview);
* permission-card destination states (allowed/denied), long-press menus;
* MCP settings/editor, native workbench, export sheet, Web surface;
* the six unreachable pages (see `REACHABILITY.md`).
