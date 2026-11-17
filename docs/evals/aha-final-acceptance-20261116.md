# aha iOS 20261116 — 最终验收 receipt

状态：**LOCAL CANDIDATE（repeat=2 筛查通过；repeat=3 发布级 FAIL）**。产品代码 SHA 冻结为
`fd90d9f2deeee483b4cca79a76e1eab41d53d883`（分支 `aha/integration-20261116`）；
本文件是 docs-only 追加，不改变产品代码。root 已独立逐 Git blob 核对
`/private/tmp/aha-final-fd` 与 `fd90d9f2d` 的 Sources/Bot App/plugins/spec/bot-e2e-eval/Package
共 2028 个 tracked 文件零差异（`root-final-source-verification.json`）。

## 1. 最终固定证据

| 项 | 值 |
| --- | --- |
| 产品 SHA | `fd90d9f2deeee483b4cca79a76e1eab41d53d883` |
| 分支 | `aha/integration-20261116` |
| 完整评测（筛查） | **9/9 场景 real repeat=2 PASS**（筛查级：repeat=2 < 本仓要求的 3），engine exit 0；逐 run 见 [`aha-20261116-receipt.json`](aha-20261116-receipt.json) |
| 发布级评测（repeat=3） | **overall FAIL**：candidate `3eb41ae1a344298e4b00475430874fac05419c3a`，9 场景 real repeat=3；6 PASS、AHA-DISCOVER 3/3 FAIL、AHA-COMPACT-REUSE scorer FAIL、AHA-CONTINUOUS r3 assertion FAIL；逐 run 见 [`aha-20261116-repeat3-receipt.json`](aha-20261116-repeat3-receipt.json)（E harness，未改 assertion） |
| aha-report sha256 | `2f82a4111435456a434d4cf584126b5b11f43e9789e56b35a28d0e81a8fab142` |
| summary sha256 | `962954384793d01fa183e109e4de70215aaed2550b813bcbcf8564b2a50301ea` |
| worker image sha256 | `deafb5d3f3b9322eba15569f6d2ec3c044d870e56f6960acb6263ad3123437c7` |
| catalog / dims | `127e5f…` / `32bc48…`（同 SHA 两侧一致） |
| 场景（筛查） | DISCOVER、COMPACT-REUSE、FRESHNESS、SOURCE、INJECTION、BOUNDARY、ERASURE、SILENCE、CONTINUOUS 各 2/2 PASS；**不得据此关闭评论 #6**（repeat=3 已出现 DISCOVER FAIL、COMPACT-REUSE scorer FAIL、CONTINUOUS r3 FAIL） |
| iOS App 模型测试 | `BotChatModelTests` **24/24 PASS**（专用 sim `8022E547…`，DerivedData `/tmp/aha-ios-dd`；未碰 booted 设备） |
| H-01 评分器 | fail-closed（旧 real2 `--engine-exit 1` 现 FAIL）；50 tests PASS |
| 受影响 Swift | 174/0；M 全量 Bot 882/0；ERASURE 保守机制 6/6；selftest 18/18 |
| 工作树 / 范围 | 干净；65 files 全在 Bot 模块/适配层/评测设施/spec-bot/docs，无 DSH 源码/pin/官方页面/Android/HarmonyOS/Package 文件 |

## 1.1 repeat=3 发布级结果（E harness，candidate `3eb41ae1a`）

命令：`bash scripts/evals/bot-aha/run.sh --upstream real --repeat 3`（同 catalog/dimensions，
assertion 未改；Bundle 为 candidate 旧 Bundle/worker，不含 R decision-context 插件，materials 不作机制结论）。
逐 run/失败 assertion：`/tmp/e-k-aha3/E-K-REPORT.{md,json}`；脱敏机器收据见
[`aha-20261116-repeat3-receipt.json`](aha-20261116-repeat3-receipt.json)。

| 场景 | engine | aha | 逐 run | 失败 |
| --- | --- | --- | --- | --- |
| AHA-DISCOVER | FAIL | FAIL | FAIL/FAIL/FAIL | 三次缺 `OWNER: 林`；r1/r2 另缺 risk 标题 |
| AHA-COMPACT-REUSE | PASS | FAIL | PASS/PASS/PASS | 独立 scorer `stored_with_provenance`：`agent/playbook/weekly.md: no evidence reference` |
| AHA-CONTINUOUS | FAIL | FAIL | PASS/PASS/FAIL | r3 `event_count conversation.assistant_message` = 2，期望 1 |
| FRESHNESS/SOURCE/INJECTION/BOUNDARY/ERASURE/SILENCE | PASS | PASS | 各 3/3 PASS | — |

- **CONTINUOUS r3 的定性**（证据见 receipt 的 `k_analysis`）：不是重复接纳。r3 的第一个 assistant 文本在
  首条用户消息后 +0.97s（tool 调用前的叙述），更正消息只在 +9.04s 出现一次，第二个 assistant 文本
  +9.95s 是 steer 后的最终答复；两次 `conversation.turn_started` 与 r1/r2 相同，model request 数相同。
  这是真实模型“先叙述再调工具”的波动撞上“统计每条 assistant 文本”的断言；不应标成 admission 重复。
- **COMPACT-REUSE 的定性**：engine 全过、独立 scorer 判 provenance 失败，是候选的真实溯源结果，
  不能拿 engine PASS 掩盖。
- **DISCOVER**：repeat=3 仍失败，说明旧 repeat=2 的 9/9 不能作为机制完成或评论 #6 的关闭依据。

## 2. 本轮真正落地的通用机制

- **Admission（Bot 主 chat）**：发送始终可用、立即回显；补充/纠正在回合 accepted 后走官方 DSH
  `mode:"steer"` 进**同一** turn；pre-accept 有界缓冲（16）、turn end/stop/rebind 回退、同 requestId
  幂等；signal-driven、取消只 resume 一次；无队列 UI；普通文本**不自动 deny** pending approval；
  Task/routine 不取 admission order（非用户消息），无跨会话阻塞声明。
- **Memory 证据**：可选 `review`（verified 必须非模型依据 + refs≥1 且宿主逐条解析，是写入时核验断言，
  非宿主认证）；Read/Recall 派生 `evidence_status`（一次批量解析、不持久化、抹除后 null、
  `source_version` 恒 null）；`restore` 继承 evidence/trust/source/review；`memory-review-invalid`。
- **Identity approval**：runtime/gateway 时钟域归属修复，未放宽授权（generation/session/name/digest/
  command 检查不变）。
- **ERASURE**：恢复原保守 distinctiveness（token ≥8 且含 `_`/数字）；Unicode 分隔符 + 完整 identifier
  （`_`/`.`/`-` 不拆）；ASCII↔非 ASCII 通用边界；负例 `meeting plan A`/`meeting client B`、
  `QUOKKA_AHA_9D2`/`QUOKKA_OTHER_ID` 不互删。
- **Prompt 产物一致性**：markdown 为 source-of-truth，`sync-bot-persona.mjs` 生成/校验 profile，
  `--check` fail-closed 接 `prompt:check` 与 pack；r8 撤回后机制保留，global 基线不变。

## 3. r8 撤回

r8（一条 R1/R2 终点提示）在**修复后的提示链**上做了有效 A/B：treatment 真实 system/message
命中 r8、control 0。逐 run 结果（`/tmp/aha-7242-{control,treatment}-results`，机器收据
[`aha-20261116-receipt.json`](aha-20261116-receipt.json)）：control **PASS、FAIL**，
treatment **FAIL、PASS**，两臂 `expectation_met=false`；INJECTION treatment **PASS、PASS**。
**无可测增益 → 已撤回**（markdown+profile 移除，change record `withdrawn`）。
更正（PR #187 评论）：本文件此前写“control 1/2 FAIL、treatment 0/2 FAIL”，与逐 run 产物不符；
变更单 §4.1 此前写“两臂各 2/2 FAIL”，同样不符。以上面的逐 run 结果为准。
旧 r9 A/B（r8 未进 Worker，两臂 0/2）标 invalid，不作为无增益依据。
该 A/B 只有 repeat=2，低于本仓评测文档要求的 repeat>=3；因此它是筛查证据，不是发布级证明。
并且同一 candidate 的 repeat=3 单臂 DISCOVER **3/3 FAIL**（§1.1），所以“r8 无增益”的撤回结论保持，
但 DISCOVER 机制本身在发布级重复下仍未通过；两臂 repeat=3 A/B 未跑，不得据此升级任何增益结论。

## 4. 已知 FAIL / NOT_RUN（不阻塞本地候选，PR 必须记录）

**基线既有 FAIL（本 diff 未改相关文件，非本变更引入）**
- `phone-p0-conformance`：stale iOS page contracts（`ChatPage.swift` 零 diff）。
- `phone-hygiene`：base 既有（`CloudVoice`/`TonoAccount`/`Tests/*`），本 diff 无新增命中。
- `spec/ui/v1/bot/tools/check_bot_ui.py`：`header.waiting.plural` 旧 source-location drift（文件零 diff）。

**本轮 repeat=3 的发布级 FAIL（E harness，candidate `3eb41ae1a`）**
- AHA-DISCOVER 3/3 FAIL（缺 `OWNER: 林`；r1/r2 缺 risk 标题）。
- AHA-COMPACT-REUSE：engine 3/3 PASS，独立 scorer `stored_with_provenance` FAIL（`agent/playbook/weekly.md`
  无 evidence 引用）。
- AHA-CONTINUOUS r3：`event_count conversation.assistant_message` = 2（期望 1）；证据表明是模型在 tool
  调用前的叙述，不是重复接纳（详见 §1.1 与 repeat3 receipt 的 `k_analysis`）。
以上任一未解决前，candidate 不能标“发布级通过”。

**NOT_RUN**
- 真机、掉电/重启、后台驻留、通知、弱网、`would` 两周线上指标、maintainer 真实批次、
  Android/HarmonyOS 对齐、r8 两臂 repeat=3。
- Worker 重建：最终树在 Worker 可见的 `plugins/profile` 与 `plugins/bot-runtime/prompts` 上相对 base
  零 diff，**不适用**（未把未跑写 PASS）。

**已明确 gap（不冒充底层完成）**
- `workspace 当前规范发现`没有宿主接缝；DISCOVER 的 PASS 是 r9 修正测量、无 r8 的结果，不等于机制完成。
- `review.refs` 无派生失效视图：`review` 按契约是写入时断言，非当前认证；如需“当前有效”另立 delta。

## 5. 签收

- Q 的签收（`q-review-delta.md`）只覆盖 **repeat=2 的筛查候选**（当时 DISCOVER 在修正测量下 PASS）。
- **发布级 repeat=3 已 FAIL**（§1.1）：DISCOVER 3/3 FAIL、COMPACT-REUSE scorer FAIL、CONTINUOUS r3
  assertion FAIL。因此本文件不再支持“可发布候选/发布级通过”的表述；是否接受剩余风险由 root 决定，
  不能由本 receipt 或旧 9/9 自证。
- root：从 `aha/integration-20261116` @ 产品 SHA `fd90d9f2d` 发 Draft PR；本 receipt 为 docs-only 追加。
