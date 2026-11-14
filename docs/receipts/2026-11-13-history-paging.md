# 2026-11-13 历史消息自动分页回执

<!-- SPDX-License-Identifier: MIT -->

Base: `06a80094e` + local device fixes
Device: iPhone Air (iPhone18,4), iOS 27.0

## 1. Bot transcript

- 初始只取 50 条（`historyPageSize`），eager 栈只渲染最近 40 条（`eagerRowLimit`）。
- 删除了「向上加载历史」「显示更早的消息」两个需要点击的按钮；顶部改为一个被动 sentinel。
- sentinel 进入视口时：
  - 还有已加载但未渲染的行：自动把渲染窗口增大 40；
  - 还有运行时历史：自动请求下一页 50 条；
  - 加载后把原来的第一条行 `scrollTo(anchor: .top)`，避免 prepend 时跳位。
- 一次只处理一个顶部到达；120ms 后释放调度锁，下一次滚到顶部再加载。未一次性加载全部。

## 2. DSH page（手机与 PC session）

- 顶部「加载更早消息」按钮删除，改为被动 sentinel；每页仍为 60 条。
- `loadEarlierTranscript` 同时覆盖：
  - 手机 Worker 的 `session/page`；
  - PC/远程 viewed session 的 `session/page`；
  - 只读 projection 的 `SessionProjectionReader.page`。
- 自动加载时保留原首行 anchor；加载后 30ms 再 scrollTo，等 LazyVStack 挂载新页面。
- `transcriptHasMore` 变 false 时释放调度锁。

## 3. PC projection 性能

`SessionProjectionReader.page` 原来每次先 `allRecords`（解析整个 JSONL）再过滤。现在：

- `recordsBefore` 用 `Data(contentsOf:options:.mappedIfSafe)` 从文件尾部逐行向前扫描；
- 只解码 `seq < beforeSeq` 的至多 `maxRecords` 条，再 reverse 成时间顺序；
- 只多读一条以判断 `hasMore`；
- 长 PC session 上滑不再每次全文件 parse。

## 4. 验证

| 项目 | 结果 |
| --- | --- |
| `SessionProjectionReaderTests.testLatestPageAndBackwardPaging` | **PASS**（新旧 page 语义一致） |
| `xcodebuild build -scheme PhoneDSH`（模拟器） | **PASS** |
| `xcodebuild build`（`PDSH_WITH_XZSHELL=1`, generic iOS） | **PASS** |
| 真机安装/启动 | **PASS**（`dev.phone-dsh.probe`） |
| Bot UI capture（22 XCUITest + 61 screenshots） | 以本轮 capture 日志为准 |
| DSH 真机长历史连续上滑 | **NOT_VERIFIED**，需真机感受加载时机与位置保持 |

## 5. 已知

- `SessionProjectionReaderTests` 的 `testListsBothLayoutsAndSummarizes` / `testTornFinalLineAndCorruptLineAreIgnored` 在基线上也失败（用 `git show HEAD` 原始文件复跑确认）；它们不经过本次 `page` 路径。
- 如果历史一页不足以填满视口，sentinel 可能只再加载一页；继续上滑会继续加载，不会一次拉全。
