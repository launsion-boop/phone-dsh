<!-- SPDX-License-Identifier: MIT -->

# PC-20261112-bot-erasure-replay — 抹除后的记忆回放墓碑与信息页独立加载

```yaml
change: PC-20261112-bot-erasure-replay
contracts: [P25, P26, P09]
status: implemented
breaking: false
version_decision: "P26/P25 行为补充，无新字段、事件类型、错误码或 schemaVersion：墓碑沿用既有 `$erased`/`$erasureCommitSeq` 载荷；erasure 范围按既有 path/scope 选择；信息页只改文案与加载隔离。旧数据仍可回放；旧读者遇到的 `non-contiguous` 是本次修复的缺陷，不保留兼容分支。"
base: 3e62bea5
contract_revision: spec/bot/v2/README.md@erasure-replay-v1 + spec/bot/v1/README.md@erasure-replay-v1 + spec/ui/v1/pages/bot-info.md@info-load-v1
```

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 联调报告 `sim-int-2-20261112.md` §1/§4/§6 #1/#2/#8：
  - 抹除 `agent/` 根后，`SQLiteBotMemoryDocumentStore` 重放报
    `non-contiguous document version`（`BotMemoryFactStoreError.corrupted`），信息页记忆/例行任务/
    审批记录/常设授权四个入口全部“读取失败”，`RecallMemory` 拿不到 `tool_result`。
  - 根因有两层：(a) 抹除的“唯一标记副本”扫描把**其他记忆文档**的版本事件也清掉了，幸存文档
    出现版本空洞；(b) 回放把载荷已清空的版本事件当成“从未发生”，下一版本因此被误判为损坏。
    另有一个共享快照把任一投影的抛错放大成四个入口全失败，且页面直接显示
    `error.localizedDescription`。
  - 期望：墓碑不报损坏；抹除只清目标路径/scope 的记忆版本，其他记忆文档存活；四个入口独立
    加载；工具错误返回人话结果；页面错误文案不出现类型名/错误码/英文原文，原始错误只进诊断日志。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `erase-mem`
  （worktree `dsh-work/erase-mem`、分支 `bot/erasure-memory`）兼任四角色；先改 P25/P26/P09
  owning 文件与共享向量，再实现 Swift 宿主与 App 页面。
- **Owning contract / fixtures.** P25：`spec/bot/v1/README.md` §4.6；P26：
  `spec/bot/v2/README.md` §§1.1、1.8、`golden/memory-erasure.json`；P09：
  `spec/ui/v1/pages/bot-info.md`。
- **受影响 producer / consumer.** Swift 宿主 `Sources/PhoneDSHBot/Memory/**`、
  `Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift`；App
  `examples/probe-app/PhoneDSHProbe/Bot/{BotInfoPage,BotProductionServices,BotProductionUIAdapters}.swift`；
  spec checkers `spec/bot/v2/tools/validate_vectors.py`。Android/HarmonyOS 无 Bot runtime，不跟。

## 2. 契约 delta（先冻结）

| 项目 | Before → After／依据 |
| --- | --- |
| 墓碑回放 | 载荷清空的 `memory.document_written`/`deleted` 没有 path/version，回放对下一存活版本的前向跳号报 `corrupted` → **墓碑跳过缺失版本**：不合成历史版本、不复活、不注入/检索；同版本冲突/乱序仍是损坏。 |
| 抹除选择 | 唯一标记扫描对所有事件生效，可能清掉其他记忆文档的版本事件 → 该规则只作用于**非记忆文档事件**；`memory.document_*`/`memory.written`/`memory.forgotten` 只按目标 path/scope 选择；其他记忆文档即使正文含相同标记也必须存活。 |
| `erasure.memoryVersions` | 只列目标路径版本 → 仍是目标路径版本，但现在不会再有“未列入却清掉的记忆版本”；其他记忆文档不进入该列表也不被清除。 |
| 信息页加载 | 一个快照 `try` 全部投影，一处抛错四个入口全失败 → 四个入口独立 catch，各自保留成功数据并只标记自己的失败；原始错误进 `chat-status.log`（`bot-info projection=…`）。 |
| 信息页文案 | `BotInfoPage.refresh` 直接拼 `error.localizedDescription`，出现类型名/`error 4`/英文 → 固定人话“暂时读不出来，请稍后重试。”；`BotInfoSnapshot` 增加 per-entry 失败文案，常设授权使用独立 `grantsState`。 |
| `RecallMemory` 失败 | 存储抛错走到通用 `execution_failed` + 原始错误串 → 返回工具错误 `memory_unavailable` 和人话消息，保证回合拿到 `tool_result`。 |

自检：没有新事件类型、wire 字段、版本号或错误码；`erasure` 仍是既有 additive durable 事件；
`record://`、序号域、幂等和路径/scope 规则不变。只收紧“不得误删其他记忆文档”和“墓碑不是损坏”
两个语义。

## 3. 兼容性

| Producer → Consumer | 处理 |
| --- | --- |
| 旧数据（已误删版本）→ 新回放 | 前向跳号按墓碑跳过，幸存文档和 live 内容可读；被误删的历史版本不复活。这是修复目标。 |
| 新抹除 → 旧 reader | 旧 reader 仍会在幸存文档前向跳号时报 `corrupted`；回滚不会造成数据损坏，但会重现旧缺陷。版本决定记录为兼容性行为修复，需要新宿主。 |
| 新 → 新 | 抹除只清目标 path/scope 的版本；墓碑语义由 `golden/memory-erasure.json` 与 Swift 真实 SQLite 回归覆盖。 |
| 信息页 | 快照字段只增可选 per-entry 文案，旧调用方默认 nil/loaded；页面状态拆分不改变 durable 数据或 accessibility id。 |
| Worker/DSH | 无变更；抹除仍由宿主执行。 |

## 4. 共享向量与校验

- `spec/bot/v2/golden/memory-erasure.json` 新增
  `agent-scope-keeps-shared-user-document-with-matching-text`：目标 `agent/` 文档正文里的唯一标记
  出现在一个共享 `user/INDEX.md` 版本和一个对话副本中；期望只清目标文档事件和对话副本，
  `user/INDEX.md` 存活。
- `spec/bot/v2/tools/validate_vectors.py` 的参考实现继续冻结 scope、路径、版本计数和幸存路径。
- Swift `MemoryErasureTests` 用真实 `SQLiteDomainStore`/`SQLiteBotMemoryDocumentStore` 驱动：
  - 抹除后重开数据库，不报 `corrupted`，共享文档所有版本存活，INDEX 可重建并继续写；
  - 对“历史数据中单个版本载荷已清空”的日志，重开数据库后按墓碑回放并可继续写下一版本。
- `BotMCPMemoryFailureTests` 用真实 MCP runtime + 冲突事件驱动 `RecallMemory`，断言返回
  `memory_unavailable` 且文本不含 `corrupted`/类型名。
- `BotWorkerRecoverySchedulerTests` 覆盖 manual park/start 后 phase==ready、ready 门释放和失败态。

## 5. 实现与失败路径

- **存储。** `SQLiteBotMemoryDocumentStore.applyWritten/applyDeleted` 接受前向版本跳号（墓碑
  缺失版本）；`erasePhysical` 的标记扫描跳过记忆文档事件。真正的同版本冲突/后向版本继续
  `corrupted`，不降级。
- **工具。** `BotMCPRuntime.recallMemory` 捕获记忆读取失败，返回
  `.failure("memory_unavailable", "记忆暂时读不出来，请稍后重试。")`；不等待、不挂回合。
- **信息页。** `BotProductionInfoService.load()` 对 memory/routines/approvals/grants 分别 catch，
  `BotInfoSnapshot` 携带 per-entry 文案；`BotInfoModel` 新增 `grantsState`，四个页面各读自己的
  状态。`BotInfoPage.refresh` 的兜底 catch 只写诊断日志并显示固定人话。
- **失败路径。** 单入口失败保留其他入口数据；`BotInfoEntryLabel` 对失败入口显示“读取失败”而不是
  0；`BotGrantStore.revoke` 失败仍不本地移除。

## 6. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| erasure-replay-v1 | erase-mem contract owner | 联调 P0：抹除后墓碑回放、误删其他记忆文档、信息页全挂与文案 | Swift 宿主、iOS App、spec checkers |
| info-load-v1 | erase-mem contract owner | 四个数据入口独立加载、人话错误 | iOS App、spec checkers |
