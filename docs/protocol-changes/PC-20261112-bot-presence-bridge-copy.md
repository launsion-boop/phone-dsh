<!-- SPDX-License-Identifier: MIT -->

# 在场区连接状态改为用户可读文案（P09）

```yaml
change: PC-20261112-bot-presence-bridge-copy
contracts: [P09]
status: implemented
breaking: false
version_decision: Presentation-only. No event, field, schema, route or persisted value changes. `BotBridgeDiagnostic` keeps `atMilliseconds`, `code` and `sessionId`; only the info page's derived copy and label change. The raw code moves to the diagnostic log.
base: b3ed58d1
contract_revision: spec/ui/v1/pages/bot-info.md@int-fixes5-1
```

Protocol impact: P09 — the presence bridge line's user-visible copy contract. P26: none — `BotBridgeDiagnostic` records the same time/code/session and is still cleared by a successful registration. P03/P02: none — no persistence or journal change.

## 1. 识别与角色

- **Trigger.** 最终验收 final-2 的 `infoPresence.png` 显示「最近一次身份登记失败：unauthorized · 11月11日」：英文内部词 `unauthorized`、内部概念「身份登记」都直达用户；时间只有月日，没有年份上下文。
- **Owner / implementer / reviewer.** 本单元 `int-fixes5`；P09 契约与 Swift 页面实现、截图夹具在同一 revision 修改；未 commit/push。
- **Producer / consumer.** `BotMCPRuntime.lastBridgeError()` 产生 `BotBridgeDiagnostic`（时间、错误码、session id），`BotProductionInfoService` 读取，`BotInfoSnapshot.production` 通过 `BotUIFormat.bridgeFailure(atMilliseconds:)` 生成一行文案，`BotPresenceSection` 只渲染。错误码由适配器写入 `chat-status.log`。
- **Fixtures.** `BotFixtures.infoPresence` 用同一个 `BotUIFormat.bridgeFailure` 生成文案；`CaptureUITests.testInfoPresenceBridgeStatusIsHuman` 断言。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| 行标签 | 「桥状态」→「连接状态」（用户能看懂的说法；accessibility id `bot.info.presence.bridge` 不变）。 |
| 文案 | `最近一次身份登记失败：<code> · <M月d日>` → `最近一次与 App 的连接校验失败 · <本地时间>`；时间由 `BotUIFormat.dateTime` 生成（今天/月日/带年份）。 |
| 错误码 | 不再进入用户可见文本；`BotBridgeDiagnostic.code` 原样写宿主诊断日志（`bot-info bridge-failure code=…`）。session id / token / 参数 / 请求体仍不显示。 |
| 真实性 | 页面不推断「已恢复」，也不把失败写成成功；宿主成功登记后清除诊断，页面不缓存旧错误。无错误时仍不显示该行，也不显示「正常」占位。 |

自检：没有新增 wire 字段、错误码或持久化格式；`BotBridgeDiagnostic` 的形状不变；只改派生文案与诊断日志。

## 3. 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| new App → old data | 旧 `BotBridgeDiagnostic` 只有时间/错误码/session，新文案只用时间；错误码进日志。 |
| old App → new runtime | 旧 App 仍读同一 `BotBridgeDiagnostic`，显示旧文案；运行时字段不变。 |
| new App → new runtime | 新文案；成功登记仍清除记录。 |

## 4. 验证

见 worktree 根目录 `int-fixes5-20261112.md`。
