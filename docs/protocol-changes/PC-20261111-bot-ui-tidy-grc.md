# PC-20261111-bot-ui-tidy-grc

## 0. 摘要（机器可读）

```yaml
change: PC-20261111-bot-ui-tidy-grc
contracts: [P09, P25, P26, P27]
status: implemented
breaking: false
version_decision: 不新增协议版本；只改 UI 展示文案/折叠方式，不新增或修改任何 wire 字段、事件类型、schema 或持久化形状；zh-Hans 显示文案只在 tool-effects.phone.json overlay 中替换，上游 tool-effects.json 保持导出原样。
base: 45b2e4b87ad1d68780df3df9cf905ba3f8ec6a24
contract_revision: spec/ui/v1/pages/bot-info.md@21187f31+ui-grc; spec/ui/v1/pages/bot-chat.md@21187f31+ui-grc
```

## 1. 识别与角色

- 具体 trigger → 现况 → 期望：
  - **P09**（UI 页面契约）：`bot-info.md` 要求常设授权主行列出 `tool/operation/resource/scope/sessionId/createdAt/source` 原始字段；`bot-chat.md` 只写“按内容决定高度”，没有把卡片标题/摘要行数写死。现况是页面/卡片把内部 ID、digest、原始枚举和完整路径直接铺在主行，长文本无上限。期望：主行只显示人类可读摘要，完整路径/URL/sessionId 折叠到「详情」；卡片标题/摘要最多 2 行并提供展开。
  - **P25**（BotEventLog/effects）：`approval.requested` / `approval.decided` 事件已包含动作、effect label、decision、scope 和超时/过期状态；本变更只消费这些既有字段生成审批记录，不改事件形状。
  - **P26**（ToolSurface/approval copy）：`BotToolEffects`、`BotApprovalPatterns`、`BotEgressEffects` 的 zh 用户文案混用繁体。期望统一简体，不改 tool/effect 语义或 security 分类。
  - **P27**（BotRows/UserAction）：`BotSessionLogProjection` 的审批卡标题、状态标签和 401 提示混用繁体；只改显示文案与兼容解析，不改 row schema 或 action 语义。
- 协调者兼 contract owner／implementer／reviewer-integrator：本单元 `ui-grc`（单 worker）。
- Owning spec：`spec/ui/v1/pages/bot-info.md`、`spec/ui/v1/pages/bot-chat.md`；P25/P26/P27 的 schema 未改。P26 只在 `tool-effects.phone.json` 中按 identity 替换 21 条 `valid` + 2 条 `invalid` 的 zh 显示 label/detail（display-only），上游 `tool-effects.json` 为 HEAD 原样导出；`export-manifest.json` 只更新 overlay 的 sha256（上游哈希回到 HEAD 值）；事件、tool、effect、scope、security 语义均未改。
- 受影响 producer/consumer：iOS probe app（`examples/probe-app/PhoneDSHProbe/Bot/**`）与 `Sources/PhoneDSHBot/**` 的显示字符串；Android/HarmonyOS 无 Bot UI runtime，不涉及。

## 2. 契约 delta

只列改动；未变语义引用 owning clause。

| 项目 | Before → After／依据条款 |
| --- | --- |
| `bot-info.md` 常设授权主行字段 | Before：主行必须展示 tool、operation、resource、scope、sessionId、createdAt、source 原始值。After：主行展示人类可读操作类别、资源摘要、有效范围、来源、创建时间；tool/operation/完整 resource/sessionId 放折叠「详情」。不删除字段，只折叠。 |
| `bot-info.md` 审批记录摘要 | Before：只要求“参数摘要和实际决定”。After：摘要必须用户可读，禁止内部 ID、digest、原始枚举；实际决定区分允许一次/本次会话允许/总是允许/拒绝/已超时（视为拒绝）/已过期（视为拒绝）/已取消。 |
| `bot-chat.md` 卡片行数 | Before：“紧凑、按内容决定高度”。After：标题最多 2 行、摘要最多 2 行，超出有「展开/收起」；其余结构不变。 |
| P26 `tool-effects.phone.json` | Before：zh label/detail 为上游繁体导出。After：overlay 按 identity 替换对应 case 的显示字符串为简体（21 valid + 2 invalid），上游 `tool-effects.json` 不改；manifest 只更新 overlay 哈希，上游哈希保持 HEAD 值；tool、operation、resource、policy、known/isMcp 等字段不变。 |
| fields／encoding／number domain／limits／default／null | 无 wire 字段变化。 |
| capability／version／unknown field／unknown method／unknown enum | 无变化。显示层对未知枚举继续回退「其他」。 |
| correlation／sequence scope／ordering／terminal outcome | 无变化。 |
| error code／retryable／deadline／cancel／late response | 无变化。审批记录只新增展示既有 `status`/`timedOut` 的只读文案。 |
| idempotency／side effect unknown／ACK／durability／recovery | 无变化；撤销授权仍走 `BotGrantStore.revoke(id:)` 后重读。 |
| origin／auth／scope／path／redaction／backpressure | 无变化；完整路径/URL/sessionId 只在用户主动展开的详情中出现，审批摘要不显示密钥或完整敏感参数。 |
| 条款状态变化（target → implemented 等） | `bot-info.md`/`bot-chat.md` 仍是 target 页面契约，本变更只收紧展示要求，不声明 runtime 已完成。 |

自检：没有新增第二种表达、没有新字段/新枚举；没有收窄或放宽任何两端都读的 wire 消息；旧持久化数据无需迁移。

## 3. 兼容性与发布

| Producer → Consumer | 支援／拒绝方式及理由；对应测试 |
| --- | --- |
| old → new | 旧事件/旧 grant 数据继续按原字段读取；新的审批记录展示兼容缺少 `status`/`scope` 的旧 `approval.decided` 事件，回退“允许/拒绝”。 |
| new → old | 无 wire 变化；旧客户端看到的是同一份事件/数据。 |
| new → new | 无协议变化，仅显示映射。 |
| persisted old data → new／rollback | 不适用：没有 schema/持久化形状变化。`approvalRecords()` 从既有 `approval.requested`/`approval.decided` 事件生成视图，回滚只影响展示。 |

- 版本／adapter 决定：P09 页面展示收紧，不新增 version/adapter。
- 回滚限制：无；回滚 UI 代码即可恢复旧展示。
- `target`/`draft` 条款中，本次实现与仍保留的差异：Bot 页面在 simulator 上验证；真机后台/通知仍 NOT_RUN。

## 4. 分工与证据

- 独占路径：`examples/probe-app/PhoneDSHProbe/Bot/**`（本单元指定的授权/审批/卡片/夹具/截图页区段）、`Sources/PhoneDSHBot/{Routines,Authz,Rows,Proactive,Team,Avatar}` 的显示文案、`spec/ui/v1/pages/bot-info.md`、`spec/ui/v1/pages/bot-chat.md`、P26 `tool-effects.phone.json` 显示标签（上游 `tool-effects.json` 不动）、`scripts/ci/bot-ui/{capture.sh,CaptureUITests.swift}`、`scripts/ci/bot-e2e/app/Tests/BotProductionChecks.swift`。
- 共享 fixtures：无 wire fixture 变化；截图夹具 `BotFixtures.swift` 扩充 `infoApprovals` 与 `infoMemoryDocument`，显示值由生产映射函数产生。审批记录改为读取既有 `approval.requested` / `approval.decided` 事件；`BotProductionChecks` 同步改为构造这两个事件并断言结构化摘要。
- 各端真实测试：Swift `PhoneDSHBotTests`；iOS `xcodebuild` + `scripts/ci/bot-ui/capture.sh`（simulator）。
- Exact commands → 结果：
  - `swift build --disable-sandbox` → PASS
  - `swift test --disable-sandbox --filter PhoneDSHBotTests` → PASS（564 tests, 0 failures）
  - `python3 spec/ui/v1/tools/ui_check.py --root .` → PASS
  - `python3 -m unittest discover -s spec/ui/v1/tools -p 'test_*.py'` → PASS（201 tests）
  - `CI_PROTOCOL_BASE=$(git merge-base HEAD origin/main) bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS
  - `BOT_UI_SKIP_UI_TESTS=1 bash scripts/ci/bot-ui/capture.sh --appearance light|dark` → PASS（各 42 张截图；XCUITest NOT_RUN）
  - `xcodebuild test ... -only-testing:BotE2ETests/BotCompositionE2ETests/testProductionServicesChecks` → INCOMPLETE（编译通过；测试 runner 启动报 Pseudo Terminal Setup Error，未执行）
- 剩余风险：截图仅 iOS simulator；深色已截但未做真机/动态字体全量；记忆文档详情截图需要把 `BotMemoryDocumentView` 的访问级别从 `private` 放宽（`BotInfoPage.swift:1038` 之外的唯一一行改动，见报告）；release-side `check_golden.py --checkout` 未运行（没有私有 dsh-bot checkout；离线模式已验证 16 个 upstream 文件 digest 与 HEAD 一致、`tool-effects.json` 与 HEAD byte-identical）。P26 的 zh-Hans 映射只存在于 overlay，上游导出保持原样，下次导出不会覆盖 overlay。

## 5. 修订纪录

| revision | 由谁 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| `21187f31+ui-grc` | `ui-grc` | 首次冻结：收紧授权/审批展示与卡片行数，不涉及 wire | iOS Bot UI；Android/HarmonyOS 不适用 |
| `21187f31+ui-grc2` | `ui-grc` | 修正 round1 直接手改 upstream `tool-effects.json`：恢复 HEAD 原样，zh-Hans 改为 overlay 同 identity 替换；同步 README §8.1 与合并加载测试 | iOS Bot UI；Android/HarmonyOS 不适用 |
