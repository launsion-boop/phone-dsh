# iOS × 官方 DSH Session 基线扫描

一个**静态**扫描器，用来回答两个问题：

1. 官方 shipped session 页面有哪些 chat node / toolview / slot / projection / 组件 metric？
2. 01–08 的审计报告和当前 iOS 实现，有没有漏掉官方 surface？

它**不运行**官方 Web，也不渲染 iOS；只读源码/CSS。适合在官方 pin 变化、或 iOS chat 代码改动后复跑，作为“审计/实现有没有漂移”的体检。

## iOS 基线用哪个脚本

iOS 的 402pt 基线分两层，不要手截图：

```bash
# 1) 官方 DSH 真机 Web UI 参照（9 个状态）
scripts/ios-parity/golden/capture-official.sh

# 2) iOS 原生自检截图
scripts/ios-parity/capture.sh <simulator-udid> sample
```

官方 golden 会启动真实 `dsh web`、用 Chrome DevTools Protocol 在 402×874@3 下截图，
并把 hero / auth / chat / tool / question / plan / subagent 的 manifest 一起写出来。
详见 [golden/README.md](golden/README.md)。

## Android 对齐建议

Android 不要手工截图对 iOS；用同一个 402×874@3 口径跑脚本，再把两边同名状态并排审：

```bash
# Android 截图（Android 仓自己的工具）
android/tools/screenshot-capture.sh

# 阈值比较（每个 Android 状态内部先过自己的 golden）
python3 android/tools/test_screenshot_compare.py compare \
  --baseline <android-golden-dir> \
  --actual <android-capture-dir>
```

跨平台不要直接做逐像素 diff：CoreText 与 Android 字体栅格不同，必然有抗锯齿差异。
Android 对齐 iOS 基线时使用同一套状态名、同一 402×874@3 视口、同一组 layout metrics
（header 50、composer 370×98、内容列 338、tool row 24、flow 6/12）；
像素阈值只在 Android 自己的 golden 内使用。

## 用法

```bash
cd /Users/leilangsheng/Desktop/TonoTeam/phone-dsh
python3 scripts/ios-parity/audit.py
```

默认：

- 官方：`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness`
- iOS：脚本所在仓库根
- 输出：`docs/receipts/ios-session-audit/parity/`

覆盖默认值：

```bash
python3 scripts/ios-parity/audit.py \
  --official /path/to/deepseek-harness \
  --ios /path/to/phone-dsh \
  --out docs/receipts/ios-session-audit/parity
```

退出码始终为 0（缺口是数据，不是构建失败）。需要脚本失败时，另行 grep `summary.json`。

## 输出

| 文件 | 内容 |
|---|---|
| `coverage.md` | 人读报告：缺口、官方 surface 清单、slot 贡献者、组件 metrics、iOS 探针 |
| `summary.json` | 计数、审计缺口、同义词覆盖、iOS generic toolviews |
| `official-tokens.json` | 解析后的 light/dark token（`var()` 递归展开、`calc(px)` 求值） |
| `official-components.json` | 23 个 session surface 的 base/variant 声明（light/dark 解析值） |
| `official-inventory.json` | chat node kinds、toolview keys、slots、projections、contributions、view tabs |
| `ios-inventory.json` | iOS ChatItem.Kind、tool variants、titles、theme、关键源码探针 |
| `comparison.json` | 上述两边的逐项对照 |

## 读报告的顺序

1. `coverage.md` §1：**审计缺口**（可见 surface 没被报告按名字/同义词覆盖）。
2. §1.0.1：**同义词覆盖**——脚本认为覆盖了，但需要人工确认是不是真的。
3. §2.3.1：**slot 贡献者**——官方到底在 header/dock 里塞了哪些控件。
4. §2.3.2：**view tabs**——例如 `chat` / `trajectory`。
5. §3：**组件 metrics**——改 iOS 前先对这里。
6. §4：**iOS 探针**——当前 Swift 常量，和 §3 对不上就是偏差。

## 当前基线（2026-11-01）

- 官方：`7be5505b0b` / `0.2.1-rc.2`
- 20 个 chat node kind、54 个 toolview key、35 个 slot 注册点、29 个 projection key、23 个 surface
- 405 light token / 193 dark token
- iOS：12 个 `ChatItem.Kind`、7 个 tool variant、42/54 toolview 走 generic
- 审计缺口：0 / 0 / 0 / 0；同义词覆盖：16 个 slot + 1 个 projection
- 人工复核后新增：`conversation.view`（对话/轨迹 tab）、header `agent-preset`/`job-list`/`schedule-catalog`/`open-in-app`/`session-log-download`/`sidebar-right corner`（见 `09-scanner-gaps.md`）

## 已知局限

- **静态**：不判断 402pt 下是否溢出/换行，不替代 golden 截图。
- **slot 识别**：正则 `register({ ... name: 'conversation...' })` 窗口，动态/别名注册可能漏。
- **projection 分类**：`PROJECTION_CLASS` 是人工表；未知 key 落 `internal`，不报警。
- **iOS 探针**：源码常量，不是实际渲染尺寸。
- **官方像素值**：CSS 解析，不是截图实测；`ios-chat-official.png` 不是官方页，不能当基线。

## 维护

- 官方新增 chat node / toolview / slot / projection：脚本会自动扫到；如果落进 `unknown`，补 `SLOT_CLASS` / `PROJECTION_CLASS`。
- 官方 UI 新增可见 surface：在 `SURFACES` 加 CSS 文件/class，在 `ios-inventory` 加对应探针。
- 改了 iOS `NativeToolCallModel` 的专用工具：更新 `IOS_SPECIAL_TOOLS`。
- 改了审计报告命名：`report_names()` 默认 `0[1-8]-*.md`；如果新增轴，改这里。
