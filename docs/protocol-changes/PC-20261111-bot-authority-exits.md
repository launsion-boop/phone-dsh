# routine／Task／CreateTeammate 的授权出口（P26/P27/P09）

```yaml
change: PC-20261111-bot-authority-exits
contracts: [P26, P27, P09]
status: implemented
breaking: false
version_decision: Additive routine fields and a host-only Task authorization envelope. No new wire version, error code, alias or second envelope. Old routine rows decode without the new fields; old Task records decode without `authorization`; the new fields are ignored by readers that do not know them.
base: 0bbe253f6
contract_revision: spec/bot/v1/routine.schema.json@routine-authority-v2 + spec/bot/v1/golden/authority.phone.json + spec/bot/v1/README.md@PC-20261111-bot-egress-approval@3
```

Protocol impact: P26 — additive `Routine.creator/completion_criteria/constraints`, Task authorization subset and CreateTeammate author audit; P27 — Bot 信息页新增三个宿主服务型用户动作（撤销常设 Grant、取消运行中 routine、对账），不改 row/user-action schema；P09 — `spec/ui/v1/pages/bot-info.md` 只增条目与动作，不改页面框架

## 1. 識別與角色

- **Trigger → 現況 → 期望.** 现状里 routine 没有设立者、完成条件和约束；任何隐藏回合、routine、Task 或 `agent:` 回合都能新建或放宽 routine。Task 接受 `allowed_write_directories`（工具描述写着 ENFORCED），但 Swift 宿主从不读取它，子会话也能继续派 Task。`CreateTeammate` 由模型自动放行且不记录作者。Bot 信息页没有撤销常设 Grant、取消运行中 routine、处理 `needs-reconciliation` 的入口。期望：routine 记录设立者/完成条件/约束，非用户回合的创建与放宽走现有审批卡；Task 的授权子集真正生效；UI 有叫停与撤权出口。
- **Coordinator / contract owner / implementer:** 本单元 `s2-s4b` 依 AGENTS.md §3 完成 P26/P27/P09 增量。
- **Affected ends:** Swift `Sources/PhoneDSHBot/{Routines,Team,MCP}`、App `examples/probe-app/PhoneDSHProbe/Bot/**`。Worker/Android/Kotlin/Rust 不消费这些字段；`authority.phone.json` 是手机专属向量。
- **Upstream reference:** dsh-bot `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6`；新增字段只存在于手机覆盖文件，不修改上游 `routine` 导出或 schema 的既有必填集合。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| `routine.schema.json` | 新增可选 `creator`（`rpcId`/`turnId`/`sessionId`/`origin`/`authorization`/`approvalID`）、`completion_criteria`、`constraints`（各 ≤2,000 字符）。既有必填字段不变；无 creator 的旧数据仍合法。 |
| routine 权威 | `creator.authorization` 取 `user-turn` 或 `user-confirmed`；`user-confirmed` 必须带审批卡 `approvalID`。创建与“放宽”（更频繁排程、interrupt、urgent、resume）在无用户消息来源的回合先请求审批；删除/暂停/读取/不改这三项的更新不请求。 |
| Task 授权 | Task 结果与 `AwaitTask` 增加 `authorization` 对象：`workspaceRoot`、`allowedWriteDirectories`、`canWriteOutsideWorkspace`、`canNetworkWrite`、`canDelegateTasks`。本修订后两者恒 false。`allowed_write_directories` 解析为绝对目录并写入 task session 的 principal capabilities。 |
| Task 执行门禁 | Task 子会话的 `write`/`edit` 路径、可识别的 `bash` 写入目标必须落在 `task.write-dir:*` 内；再次调用 `Task` 需要 `task.delegate`。网络写不在结构审批里按命令效果判断：宿主 `/v1/http` 出口在归属到 Task 会话后检查 `task.network-write`，缺失即 403 `task_network_write_denied` 且不出卡（见 egress-approval@3）。越界在出审批卡前拒绝。 |
| CreateTeammate | 非用户来源回合先出审批卡；创建后写 `ui.system_event{event:"teammate.created"}`，带 `author`（rpcId/turnId/origin/authorization/approvalID）。 |
| UI | `spec/ui/v1/pages/bot-info.md` 只增：常设授权列表/撤销、运行中 routine 的取消、`needs-reconciliation` 的确认完成/重试。P27 row/user-action schema 不变，因为这三项走宿主服务而不是 durable 行动作。 |
| Fixtures | 新 phone-only `golden/authority.phone.json`（routine creators/changes、task authorization subsets、teammate authors，含负例和 mutation 自检）；无同名上游文件。 |

Self-check（`spec/README.md` §5.1）：没有第二套 routine 字段、没有把 `record://` 与 `rpcId` 并存为两个字段、没有新增宿主能力“提高子会话权限”的 Task 参数；`allowed_write_directories` 的语义由 `authority.phone.json` 和真实 Swift `BotTaskAuthorization.resolve` 共同驱动；旧数据按可选字段解码。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 旧 routine 行没有 creator/completion/constraints 时按 `nil`/空字符串解码；旧 `persistedTask` 没有 authorization 时按工作区根授权恢复。 |
| new → old | 旧 reader 忽略 routine 的新增可选字段；旧 `AwaitTask` 不解析 `authorization` 也仍得到原 task 字段。旧 App 回滚后不读取新 UI 入口，不删除任何持久数据。 |
| new → new | Task 授权在 `start` 前规范化并持久化，重启恢复同一子集；Task 结果与 `AwaitTask` 返回同一对象。routine 的 provider/consumer 使用同一 `RoutineCreator` 与审批表。 |
| persisted old data → new／rollback | 无 schema 版本提升、无迁移；新增字段是 optional。 |

- 版本／adapter 决定：P26 的 routine 数据面 additive；Task authorization 是宿主内部 durable 记录和既有 tool result 的附加对象，不新增 wire 协议。不改 `tool-catalog.json`（上游导出）；`UpdateRoutine` 的模型可见 schema 暴露留待能修改 catalog 代码的后续修订。

## 4. 驗證

- `python3 spec/bot/v1/tools/validate_vectors.py` → PASS（authority 5 creators / 8 changes / 5 task subsets / 19 mutation；整合后 mcp-egress 39 valid / 46 invalid / 22 mutation）。
- `python3 spec/tools/bot/check_golden.py --root .` → PASS（32 files, 22 upstream, 10 overlays）。
- `swift test --disable-sandbox --filter 'PhoneDSHBotTests|PhoneDSHGatewayTests|PhoneDSHLoopbackTests|BotMCPEgressCredentialInjectionTests|MCPEgressPolicyTests'` → PASS（777 tests，0 failures；含 RoutineAuthorityTests、RoutineCancelTests、BotTaskAuthorizationTests、BotTeammateAuthorityTests、BotAuthorityGoldenTests，以及整合新增的 Task 出口门禁与 routine/egress 卡片隔离测试）。
- `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS（`s2-s4` 整合重跑；`phone-p0-conformance` 本次未运行，s4b 原记录为既有 page-structure 7 处 FAIL）。
- `python3 spec/ui/v1/tools/ui_check.py --root .` → PASS；`python3 -m unittest spec.ui.v1.tools.test_ui_check` → PASS（49 tests；s4b 原记录）。
- `bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/selftest.json --upstream mock` → gate PASS（10/10；整合重跑）。
- plugins `tests/bot-*.test.ts` → 89 tests / 88 pass / 1 skipped / 0 fail（`node scripts/run-tests.mjs "tests/bot-*.test.ts"`；整合重跑）。
- App 编译 → `** BUILD SUCCEEDED **`（整合重跑）。
- UI 截图：`bash scripts/ci/bot-ui/capture.sh --appearance light,dark --out /tmp/s2-s4b-shots` → PASS（76 screenshots；conformance PASS；XCUITest 因沙箱 Pseudo Terminal 错误用 `BOT_UI_SKIP_UI_TESTS=1` 记为 NOT_RUN）。新增 `light|dark/infoGrants.png`、`infoRoutines.png`、`infoReconcile.png` 展示撤销授权、取消运行和对账入口（s4b 原记录，整合未重跑截图）。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| `routine-authority-v1` | `s2-s4b` | 冻结 routine 设立者/完成条件/约束、非用户回合审批、Task 授权子集与 CreateTeammate 作者。 | Swift、App；Worker/Android/Rust 无 consumer 变更 |
| `routine-authority-v2` | `s2-s4` 整合 owner | S4a 删除 `curl-post`/`network-egress` 后，Task 网络写门禁改由宿主出口 `task_network_write_denied` 落实；Task 结构审批只保留路径/委派检查。 | Swift、App、spec；Worker/Android/Rust 无 consumer 变更 |
