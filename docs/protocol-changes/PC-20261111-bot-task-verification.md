<!-- SPDX-License-Identifier: MIT -->

# Task 交付终态与独立只读验证（P25/P26/P27/P09）

```yaml
change: PC-20261111-bot-task-verification
contracts: [P25, P26, P27, P09]
status: implemented
breaking: false
version_decision: Additive P26 revision. New optional Task fields, a new `verifier` principal kind with a fixed read-only preset, one durable `verification.reported` payload shape, and a task-row `verification` object. No existing field, event type, sequence domain or error code changes meaning. Old producers omit the new fields; old readers of new events require the `verifier` enum value, so the documented rollback is "do not downgrade after a verifier event is written".
base: bcc4f5256
contract_revision: spec/bot/v1/README.md@task-verification-v1 + spec/bot/v2/README.md@routine-verification-v1
```

Protocol impact: P25, P26, P27, P09; P06: none — the verifier is a Bot session inside the existing AgentCore/DSH turn path; no host event or harness envelope changed; P16: none — the profile patch only adds agent preset rows and mounts the existing plugin, no Worker URL/env/init field changed; P13: none — no plugin Remote method changed; P19: none — the verifier uses the existing `phone record search|read` envelope and adds no tool. P09 is the existing Task card gaining a verification line; the UI authority spec (`spec/ui/v1/pages/bot-chat.md`) is updated, with no new page or source.

> **更正（2026-11-12）：** 本记录 §2 表格里的“`tools.restrict({allow:[]})` 隐藏全部继承全局工具”
> 是不可实现的实现描述：安装在共享 preset 作用域的空 allow-list 会连同 preset 自己挂载的
> `read/grep/glob/bash` 一起从子 Agent 视角隐藏，产生空工具面。现行实现改为在 `agent/created`
> 时把策略 allow-list 装到该 Agent 自己的作用域；条款见
> [PC-20261112-restricted-session-surface](PC-20261112-restricted-session-surface.md)。

## 1. 识别与角色

- **Trigger → 现况 → 期望.** §3.6 要求 Task 的交付物是终态：Task 参数明确完成条件、目的、约束、预算；
  异步 Task / 带完成条件的 routine 结束后由一个只读 verifier 在独立上下文里重新检查产物，输出
  `passed | failed | uncertain` 和 `record://` 依据；父对话的结束唤醒呈现 verifier 的结论，而不是子会话
  自述；验证预算不超过任务预算的 30%。现况是 `Task` 只接收自由 prompt，异步结束唤醒直接拼子会话文本，
  没有独立验证、没有 `verifier` principal，Task 行也不显示验证结论。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `s2-s3v`
  （分支 `s2/s3-verifier`）兼任，按 AGENTS.md §3.1 先冻结本单与 owning spec/schema/golden，再实现
  Swift、Worker 插件、UI 与评测端；最终报告给出 base/head 与逐条验证结果。
- **Owning contract / schema / fixtures.** P26：
  [spec/bot/v1/README.md](../../spec/bot/v1/README.md) §2.8、§4.1、§8.1；
  [spec/bot/v2/README.md](../../spec/bot/v2/README.md) §2.2；
  `spec/bot/v1/{verifier-output,verification-report}.schema.json`；
  `spec/bot/v1/golden/verification.phone.json`、`event-envelope.phone.json`、`turn-origin.phone.json`；
  `spec/bot/v1/export-manifest.json`、`spec/bot/v1/tools/validate_vectors.py`、
  `spec/tools/bot/check_golden.py`。P25 仍拥有 durable 事件信封；P27 仍拥有 Task 行形状。
- **受影响的 producer / consumer.** Swift 宿主：`Sources/PhoneDSHBot/MCP/BotDSHRemoteRuntime.swift`
  （Task 运行、verifier 会话、routine 验证）、`BotMCPRuntime.swift`、`BotMCPTypes.swift`、
  `BotVerification.swift`、`BotToolCatalog.swift`、`Sources/PhoneDSHBot/Gateway/BotTokenRegistry.swift`、
  `Sources/PhoneDSHBot/Journal/BotEventEnvelopeCodec.swift`、
  `Sources/PhoneDSHBot/Rows/BotSessionLogProjection.swift`；Worker：
  `plugins/lifecycle-gate/src/{verifier-scope,verifier-guard}.ts`、
  `plugins/bot-runtime/src/volatile-context.ts`、`plugins/profile/phone.worker.cordis.patch.yml`；
  UI：`examples/probe-app/PhoneDSHProbe/Bot/BotCardView.swift`；评测：`scripts/ci/bot-e2e/**`。
  Android/HarmonyOS 无 Bot runtime，不需要跟进。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| Task 参数 | 无 → `completion`（1–4,000）、`purpose`（≤2,000）、`constraints`（≤8 × 500）、`budget{max_duration_ms?: 1,000–300,000}`（记录并派生 verifier 预算；省略取 `timeout_ms`）；全部可选，省略保持旧行为。`completion` 非空才可验证。 |
| 验证强度 | 无 → 同步 Task 不验证；`async:true` 且 `completion` 非空的 Task 在 `completed` 后验证一次；`completion_criteria` 非空的 routine 在 `succeeded` 后验证一次。failed/stopped/interrupted 不验证。 |
| verifier preset | 无 → `pdsh-verifier`：`read`、`grep`、`glob`、只读 `bash`（含 `phone record search|read`）；`tools.restrict({allow:[]})` 隐藏全部继承全局工具，guard 拒绝白名单外调用和非只读 bash；另有一个以创建头 `agentPreset=pdsh-verifier` 为准的全局 guard 后备。无写、无出站、无消息、无 Task、无记忆。 |
| principal kind | chat/task/routine/team/proactive/watchdog/ipc → 新增 `verifier`。verifier 会话由宿主签发并认领自己的会话 token，`BotSessionKind.verifier` 与 DSH 创建头 `agentPreset=pdsh-verifier` 固定其权限。 |
| 输入 | 无 → 完成条件 + 目的 + 约束 + 做事会话的规范 `record://session/<id>#<seq>` 引用；全局 volatile 上下文（variant/persona/memory/automation）对 verifier 会话不注入。做事会话最后一段自述不进入 verifier 输入。 |
| 输出 | 无 → 恰好一个 JSON 对象 `{verdict,summary,refs,unverified}`。`summary` 1–2,000；`refs` 1–8 条规范引用；`unverified` ≤20 × 500；`passed` 要求 `unverified=[]`。 |
| 宿主校验 | 无 → 格式、规范引用、存在性和本 Bot 范围全部校验。任一失败/超时/预算耗尽/引用无效 → `uncertain`，`output` 分别记 `invalid|budget_exceeded|unavailable`；非 `valid` 的宿主失败路径允许 `refs: []`，但不得伪造引用。 |
| 预算 | 无 → `limitMs = floor(任务预算 × 0.30)`；超过即 `uncertain`，`budget.exceeded=true`。比例固定，不通过参数放宽。 |
| durable 事件 | `verification.reported` 已在 P25 enum 中但无 payload 语义 → 现在冻结 payload：`verificationId, subjectKind(task|routine), subjectId, subjectSessionId, task_id|routine_id, runId?, title, status, verification{verdict,summary,refs,unverified,budget,output}, createdAt`。只在实际启动 verifier 后写；verifier 会话无法创建时没有 verifier 凭证，不伪造事件，结论进 Task/Routine 记录与结束事件。 |
| Task 结果 | 无 → `Task`/`AwaitTask`/durable 记录携带同一个 `verification` 对象；已 settled 的 Task 不因验证回到运行态。 |
| 唤醒文本 | 子会话自述片段 → verifier 的 verdict/summary/refs/unverified/budget；失败或不确定时带“如实告诉用户、不得说成完成”的硬指令。 |
| Task 行 | 只有任务状态/步骤 → 同一 `cardType:"task"` 行增加 `verification`：通过/未通过/不确定、摘要、依据条数；不新增卡型。 |
| routine 结果 | 只有执行文本 → 非 `passed` 时交付文本以“验证未通过/验证不确定：…”开头，安静运行不再保持 `[quiet]`。 |

自检（`spec/README.md` §5.1）：新增字段全部可选且有缺省；没有第二种引用/事件/错误表达；新增 principal
kind 与 Task 参数只由本 owner 扩大，旧 producer 不受影响。`verification.reported` 的 type 名在冻结 v1 中
已存在，本次只冻结 payload 并登记 `verifier` 值，属于 additive P26 修订。存在的兼容限制是旧二进制对
`principal.kind` 的封闭校验不认 `verifier`，回滚限制见 §3。

## 3. 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 旧 Task 记录没有 `completion/purpose/constraints/budget/verification`：`PersistedBotTask` 以可选字段解码，恢复为“无完成条件、不验证”，`AwaitTask` 结果不带 verification。旧 routine 的 `completion_criteria` 为空，不验证。 |
| new → old | 新字段是可选属性，旧 MCP 客户端忽略；`Task` 工具 schema 仍是 open object，未知参数不影响旧宿主。新 `verification.reported` 事件的 `principal.kind="verifier"` 对旧二进制是未知值：旧 App 的 `BotEventEnvelopeCodec` 会拒绝该行。部署顺序要求宿主/App 先升级；一旦写入 verifier 事件，不支持回滚到不认该值的旧二进制（数据不删除，升级后可读）。 |
| new → new | Swift 宿主产出规范引用并校验；`verification.phone.json` 同时驱动 Python、Swift、TS 测试；verifier preset 与 principal kind 都来自同一冻结值。 |
| persisted old data → new／rollback | SQLite schema 不变；只增加可选 `persistedTask` 字段和新的 event payload。新代码读取旧记录不验证；回滚后旧代码忽略 `persistedTask` 新字段，但可能遇到含 `verifier` principal 的事件（见 new → old）。 |

- 版本决定：P25 事件信封仍 `schemaVersion=1`，`verification.reported` type 已存在；`principal.kind` enum
  加值，不升 wire 版本。P26 不新增工具名/错误码/引用格式。P27 只扩展现有 task 行 body 的可选字段。
- bundle／image 顺序：Worker profile 新增 preset、lifecycle-gate 新增 export，必须与 Swift 宿主一起发布。
  旧 Worker 不认识 `pdsh-verifier` 时 `session/create` 会失败，宿主把验证结论记 `uncertain`（`output:"unavailable"`），
  不会把未验证的 Task 说成通过。
- `target`／draft 差异：真实模型场景与设备端到端不由本单声称；mock 自检见 §4。

## 4. 共享向量与校验

- `verification.phone.json`：verifier 工具白名单（`read/grep/glob/bash`，隐藏继承全局工具）、只读 bash
  允许/拒绝命令、3 个有效输出、8 个无效输出（含 `passed` 但 `unverified` 非空、非规范引用、额外成员）、
  5 个有效预算（含 54,000 ms 上限、恰好等于上限、超过 1 ms）、2 个无效预算、3 个有效事件报告
  （task/routine/宿主不可用且 `refs: []`）、5 个无效事件报告（含 `output:"valid"` 但无引用、
  非 `valid` 却不是 `uncertain` 的语义负例）；Python 校验器与 Swift/TS 测试读同一批 fixtures。
- `event-envelope.phone.json` 追加 `verification.reported`（`principal.kind="verifier"`）有效事件；
  `turn-origin.phone.json` 不新增前缀：verifier 回合沿用既有隐藏 `task-turn:` 前缀，principal
  kind 才是独立的 `verifier`。
- 校验命令见 §5；Python 通过不替代 Swift/Worker 运行时 conformance。

## 5. 实现与证据

本轮实际运行（工作区；未提交，HEAD 仍为 `bcc4f5256`）：

| 命令 | 结果 |
| --- | --- |
| `swift test --disable-sandbox --filter 'PhoneDSHBotTests|PhoneDSHGatewayTests'` | PASS，701 tests / 0 failures |
| `cd plugins && npm run typecheck` | PASS |
| `node scripts/run-tests.mjs "tests/bot-*.test.ts" "tests/verifier-scope.test.ts" "tests/device-task-isolation.test.ts" "tests/lifecycle-push.test.ts"` | PASS，106 tests / 105 pass / 1 skip / 0 fail |
| `python3 spec/bot/v1/tools/validate_vectors.py` | PASS（v1 并调用 v2；verification 3 valid / 8 invalid outputs，5/2 budgets，3/5 reports，5 mutation checks） |
| `python3 spec/bot/v2/tools/validate_vectors.py` | PASS |
| `python3 spec/tools/bot/check_golden.py --root .` | PASS（29 files，16 upstream，13 overlays） |
| `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-bot-eval-catalog` | PASS（spec 95 files + 237 tests；cross-tree 8/8 invariants + 87 tests；catalog 24 tests，selftest 12，product 9） |
| `node plugins/worker-entry/build.mjs --out examples/probe-app/Bundle/worker` + `PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2 node plugins/scripts/pack-image.mjs --out examples/probe-app/Bundle/worker` | PASS |
| `bash scripts/ci/check.sh --only phone-bundle-fresh,phone-license` | PASS（6 fresh，license） |
| `PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2 bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/catalog.json --only BOT-E06 --upstream mock --results /tmp/s3v-eval-e06-final2` | PASS |
| `PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2 bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/catalog.json --only BOT-E09 --upstream mock --results /tmp/s3v-eval-e09-final3` | PASS；durable `verification.reported{subjectKind:"task", principal.kind:"verifier", verdict:"failed", output:"valid", refs:["record://event/20"]}`，`REPORT.md` 不存在 |
| `PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2 bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/selftest.json --results /tmp/s3v-eval-selftest-final2` | PASS，12/12 |
| `HOME=/tmp/s3v-home CFFIXED_USER_HOME=/tmp/s3v-home TMPDIR=/tmp/s3v-tmp xcodebuild -project PhoneDSHProbe.xcodeproj -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/s3v-dd-final -clonedSourcePackagesDirPath /tmp/s3v-spm -packageCachePath /tmp/s3v-spm-cache -disableAutomaticPackageResolution -skipPackageUpdates build CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'` | PASS，`BUILD SUCCEEDED` |

未运行/未验证：真实模型 E06/E09（只跑了 mock）、真机、Android/HarmonyOS（无 Bot runtime）。
额外的完整 `bash scripts/ci/check.sh --only phone-plugins`（`npm test` 全量）在 30 分钟窗口内未完成，
已中止并记为 INCOMPLETE；本单只把上面的定向 `tests/bot-*`／verifier／device／lifecycle 测试算作
plugin 端证据。
沙箱说明：外层 DSH 沙箱阻止 `~/Library/Caches/org.swift.swiftpm` 写入和 Xcode 对宏插件执行的
`sandbox-exec`；因此 App 编译把 `HOME`/`CFFIXED_USER_HOME` 指到 `/tmp`，复用已 clone 的包，并给
`OTHER_SWIFT_FLAGS` 加 `-disable-sandbox`。这是本轮环境绕行，不是产品行为或新契约。

## 6. 剩余风险

- 旧二进制对 `principal.kind="verifier"` 的封闭校验会拒绝新事件；回滚限制已写在 §3。
- verifier 的 `phone record read` 依赖 DSH session log 的物化时机；宿主额外提供同会话的
  `record://event/<commitSeq>`，但若事件尚未落盘，verifier 仍可能判 `uncertain`（这是允许的
  失败方向，不会假通过）。
- 只读 bash 是保守正列表，不是完整 shell 语义；未知命令一律拒绝，verifier 可用 `read`/`grep`
  替代。`git` 只放行读取子命令，但 git 的 external diff/textconv 助手不在本白名单的建模范围内；
  升级为正式安全声明前需要独立审查。verifier 会话创建失败时宿主不伪造 verifier 事件，结论写在
  Task/Routine 记录和结束事件里（Task 行仍显示），这是刻意选择的诚实方向。
- 全局 volatile 上下文对 verifier 会话不注入，但 verifier preset 的 persona 仍是系统提示的一
  部分；这不是做事会话的输入，也不含记忆。

## 7. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| task-verification-v1 | s2-s3v contract owner | 初始冻结（P25/P26/P27/P09） | Swift 宿主、Worker plugins、iOS UI、eval |
| task-verification-v2 | s2-int integrator | 与 S3m/S2/S6 合并后只剩实现整理：verifier 与 maintainer 共用 `restricted-session`/`restricted-guard`，旧 `verifier-guard` 删除；delta、向量与语义不变 | Swift 宿主、Worker plugins、spec、eval |
