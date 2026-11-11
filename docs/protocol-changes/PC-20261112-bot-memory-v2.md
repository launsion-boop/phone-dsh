<!-- SPDX-License-Identifier: MIT -->

# PC-20261112-bot-memory-v2 — 记忆从 fact 改为 agent 组织的文档树

## 0. 摘要（机器可读）

```yaml
change: PC-20261112-bot-memory-v2
contracts: [P25, P26, P27, P09, P16]
status: frozen
breaking: true
version_decision: v2 记忆整体替换 v1 fact 形状；旧 memory.written/memory.forgotten 事件保留只读，由一次性迁移渲染为文档事件。没有双写或兼容 fallback。
base: b0886f472
contract_revision: spec/bot/v2/README.md@PC-20261112-bot-memory-v2
```

## 1. 识别与角色

- Trigger → 现状 → 期望：
  - 记忆数据模型：单行 fact，固定 `profile|log|note` tier，注入截断 → 带路径的 Markdown 文档树，
    只有 `user/` 和 `agent/` 两个根，根下由 agent 组织；每回合只注入两个根的 `INDEX.md`。
  - 写入口：`UpdateMemory` 只 write/forget 精确文本 → `UpdateMemory` 对路径 write/append/replace/
    move/delete/restore，每次都带 `expected_version` 和可选 `evidence`。
  - 读入口：没有列举/读正文 → 新增 `ReadMemory` 读文档或列目录；`RecallMemory` 返回路径、片段、
    引用，去掉 `importance`。
  - 单一作者：Task/routine 可直接写 agent/user → 只能写 `agent/inbox/<自己的 sessionId>/`。
  - 注入：旧 fact 拼接后截断 → 只注入两份 `INDEX.md`，每份硬上限 1,500 scalar，超限拒绝写入。
  - UI：fact tier/scope 列表 → 两个根的文档树，可查看文档/版本/evidence，保留 forget/erase。
- 协调者兼 contract owner / implementers / reviewer：本单元 coordinator 同时承担三角色；
  P26 契约在 `spec/bot/v2`，P25 durable event 形状在 `spec/bot/v1/event-envelope.schema.json`
  的 durable type 列表（未知类型规则不变），P27 只声明 none，P09 改 `bot-info` 页面契约，
  P16 只改 `plugins/profile` 的 persona 文本。
- Owning spec/schema/fixtures：`spec/bot/v2/README.md` §1 与
  `spec/bot/v2/{memory-document,memory-write-request,memory-write-result,memory-read-result,memory-recall,memory-injection,memory-legacy-fact}.schema.json`；
  golden `spec/bot/v2/golden/memory-*.json`；工具增量在 `spec/bot/v1/golden/tool-catalog.phone.json`
  与 `tool-effects.phone.json`；UI 在 `spec/ui/v1/pages/bot-info.md`。
- 受影响 producer/consumer：Swift 宿主（`Sources/PhoneDSHBot/{Memory,MCP}`）、Worker persona
  （`plugins/bot-runtime/prompts/**`、`plugins/profile/**`）、iOS Bot 信息页
  （`examples/probe-app/PhoneDSHProbe/Bot/**`）；Android/HarmonyOS 没有 Bot runtime，不实现。
  dsh-bot 上游不再拥有 v2 记忆。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| 数据模型 | fact（`tier`/`scope`/`importance`/…）→ Markdown 文档 `{path,scope,content,version,updated_at_ms,author,evidence,trust}`；`spec/bot/v2/README.md` §1.1 |
| durable event | 新增 `memory.document_written`、`memory.document_deleted`；旧 `memory.written`/`memory.forgotten` 保留为只读迁移输入。事件仍是 P25 envelope，data 是完整新版本 |
| 版本 | 每路径从 1 单调递增；删除也占一个版本；所有写入带 `expected_version`，不匹配 `memory-version-conflict` |
| 工具 | `UpdateMemory` action/参数替换；新增 `ReadMemory`；`RecallMemory` 输出 hit 替换（无 importance/tier/fact_id） |
| 权限 | `chat` 可写两个根；`task`/`routine`/`team`/`proactive`/`watchdog` 只能写自己的 `agent/inbox/<sessionId>/`；`user/` 需 user-turn + user evidence |
| 索引 | `user/INDEX.md`、`agent/INDEX.md`；每份 >1,500 scalar 拒绝写入 `memory-index-too-long`；注入不截断、总量 4,000 |
| 迁移 | 旧 fact 按 scope 进对应根，`profile`/`note`/`log` 映射路径，生成初始索引；幂等可重放，不丢文本 |
| 工具目录 | `ReadMemory` 进入 phone overlay（P0 增量），上游 `tool-catalog.json`/`tool-effects.json` 与 schema enum 不变 |
| UI | Bot 信息页记忆区从 fact 列表改为两个根的文档树，能看文档、版本、evidence；forget/erase 语义不变 |
| 条款状态 | v2 §1 从上游移交形状改为 phoneDSH 自有形状；仍为 `target`，真机模型 E2E 不在本单元 |

自检：没有第二套 envelope、别名字段或错误码；未知字段仍按 owning boundary 的 fail-closed
规则；事件从旧到新可回放；`INDEX.md` 上限是写入错误而非注入截断。

## 3. 兼容性

| Producer → Consumer | 处理 |
| --- | --- |
| old → new | 旧 `memory.written`/`memory.forgotten` 事件仍可解码，迁移器把它们渲染为文档事件；旧 App 的新事件类型不会被当成必需事件（P25 未知 durable 规则） |
| new → old | 旧 App 不认识 `memory.document_*`，但事件 envelope 仍合法；旧 App 的 v1 工具/注入不再由新 App 使用。不得把新文档事件喂给旧 fact 读取器 |
| new → new | `memory.document_written` 的 `expected_version` + replay 顺序保证同一版本只有一个作者；重复 eventId 不重复应用 |
| persisted old data → new | 打开同一 SQLite 库时，迁移在首次记忆访问时按 Bot 补齐文档；迁移幂等，重复运行不追加事件；旧事件不删除、不改写 |
| rollback | 回滚到只懂 fact 的 App 会忽略文档事件，旧 fact 仍在事件库中，因此可重新走 v1 读取；但 v2 写入在新 App 回滚后不可见。需要保留旧库备份 |

版本决定：v2 记忆形状是 breaking，但只在 v2 边界内替换，不引入版本字段或双写；旧事件作为
持久数据兼容入口保留到 S6 物理抹除设计。

## 4. 分工与证据

- 独占路径：`spec/bot/v2/**`、`spec/bot/v1/{tool-catalog,tool-effects}*`、`docs/protocol-changes/**`、
  `Sources/PhoneDSHBot/{Memory,MCP}/**`（仅记忆工具/注入/目录）、`plugins/bot-runtime/**`（persona
  记忆段）、`plugins/profile/**`（personaPrefix）、`examples/probe-app/PhoneDSHProbe/Bot/**`、
  `spec/ui/v1/pages/bot-info.md`、对应测试、`scripts/ci/bot-e2e/selftest.json` 与夹具。
- 共享 fixtures：`memory-document`、`memory-write`、`memory-read`、`memory-recall`、
  `memory-injection`、`memory-migration`、`memory-legacy-fact`；正例、反例、版本冲突、索引超限、
  跨 Bot 不可见、inbox 提交和迁移样例都在 `golden/`。
- 各端真实测试：Swift `Tests/PhoneDSHBotTests/Memory/**` 与 MCP 记忆测试驱动真实 store/codec；
  Python `spec/bot/v2/tools/validate_vectors.py` 是参考解析器；Worker persona 测试验证
  `ReadMemory` 被教到；UI 截图与 info 交互测试验证文档树。
- 命令 → 结果见交接报告；未验证：真实模型 E2E、Android/HarmonyOS 实现、S6 物理抹除。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| PC-20261112-bot-memory-v2 | coordinator | S2 总方案 §3.3/§3.4；fact→文档树 | Swift、Worker persona、iOS UI、spec checkers |
