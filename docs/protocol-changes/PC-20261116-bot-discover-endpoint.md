<!-- SPDX-License-Identifier: MIT -->

# PC-20261116-bot-discover-endpoint — R1/R2 终点提示（真实 DISCOVER 失败）

## 0. 摘要（機器可讀）

```yaml
change: PC-20261116-bot-discover-endpoint
contracts: [P26]
status: withdrawn
breaking: false
version_decision: no wire/schema change. One endpoint-style instruction added to the Bot-only zh/en system prompts (plugins/bot-runtime/prompts/*); the Worker image must be repacked for the prompt to take effect. DSH official workbench/kernel untouched.
base: 908d582b9ee91886ba197bebd54b863c8093cced
contract_revision: freeze commit on aha/integration-20261116 (SHA in CONTRACT-FREEZE.md)
```

## 1. 触发与证据（先定位机制）

真实模型 AHA-DISCOVER（候选 combined，repeat=2）失败。取证 `/tmp/aha-target-cand/AHA-DISCOVER`：

- `bot-events.jsonl` 无任何 `report-guide` 读取；实际工具为 `UpdateMemory`/`UpdateRoutine`/`bash`/`write`。
- 两轮产物 `weekly-*.md` 用默认格式（`## 本周完成/风险/下周计划` 之外的标题），没有 `OWNER: 林`，
  风险段标题也不是规范要求的 `## 风险`；第二轮还先建了“周五自动生成”的 routine。
- 结论：**未读取当前规范 → 直接按默认格式起草/定例程**（不是“读了未采用”，也不是基座/环境问题）。
  因此只补一条 R1/R2 终点，不补多步流程、分类或自动检索 framework。

## 2. 契约 delta（只 Bot prompt）

在 Bot 专属 system prompt（zh + en）的“例行任务与交付”节末尾各加**一段**（逐字）：

中文：

> 接手一件持续要做的事，或要交付给别人时，先找并采用工作区里当前生效的规范、模板或先例；
> 以交付物本身符合它、接收方可直接使用为完成标准；不凭默认格式先定例程，也不在回复里复述代替成品。

English：

> When you take on an ongoing responsibility or deliver something to someone, first find and follow the
> current guideline, template, or precedent that already exists in the workspace. Treat the deliverable
> itself conforming to it, and the recipient being able to use it directly, as the completion bar. Do not
> lock in routines or drafts from a default format, and do not substitute a chat recap for the artifact.

这是终点式约束（R1/R2），不是步骤清单、分类或检索框架；不改 DSH 官方 prompt/工作台/内核，不改工具面。

## 3. 兼容与发布

| Producer → Consumer | 说明 |
| --- | --- |
| 旧 Worker image → 新 App | prompt 文本随 image；不重建 image 时行为不变（旧提示），无 wire 兼容问题 |
| 新 image → 旧 App | 同一 Bot prompt 路径；无 schema/字段变化 |
| 回滚 | 删掉该段并重打包即可；无持久化迁移 |

- 必须重建 Worker image/bundle 后才能在 App 生效；`phone-image`/`phone-bundle-fresh` 或 E 的 eval 打包
  需带该改动。
- 只 iOS；Android/HarmonyOS 不改、不声称对齐。

## 4. 分工与证据

- **R（唯一写者）**：`plugins/bot-runtime/prompts/system-prompt.zh-CN.md`、
  `plugins/bot-runtime/prompts/system-prompt.md`，只加上述两段；不改其他 prompt 文本、工具面、schema。
  若 `check-prompt.mjs` 需要 hash/清单一并更新，按脚本要求最小改。
- **E（独立）**：同一 `AHA-DISCOVER` catalog（不改断言/不放宽）做**有/无该提示两臂**真实模型
  `--repeat 2`；另跑 `AHA-INJECTION` 确认不因提示退步（注入安全仍是硬条件）。两臂必须各自重建
  Worker image 并记录 image sha、report sha；只有“有提示”臂 DISCOVER 通过且 INJECTION 不退步才保留，
  否则回退该提示并记录。
- **Q**：只审该 prompt delta + A/B 证据与用词。

## 4.1 有效 A/B 与撤回（2026-11-16）

提示链修复后（source-of-truth → profile → pack fail-closed），treatment 真实 Bot system/message
命中 r8 中文 1 次，control 0 次；同 r9 catalog `AHA-DISCOVER --upstream real --repeat 2`：
control FAIL 2/2、treatment FAIL 2/2（treatment 未更好），treatment `AHA-INJECTION` PASS 2/2。
**无可测增益 → 撤回 r8**（markdown 段落 + 生成 profile 一并移除，`sync --check` 仍 PASS）。
英文 increment 从未生成（profile 只 zh）；该缺口随撤回消失。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| r1 | C | 真实 DISCOVER 失败证据（未读取规范→默认格式定例程）；按 R1/R2 只补一条终点 | R、E、Q |
| r2 | C | 旧 r9 A/B 无效（r8 未进入 Worker）；修提示链后有效 A/B control 2/2 FAIL、treatment 2/2 FAIL、INJECTION PASS，无增益 → **withdrawn** | R、E、Q |
