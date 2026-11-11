<!-- SPDX-License-Identifier: MIT -->

# Bot 原始记录引用、观察信封与记忆证据（P19/P25/P26）

```yaml
change: PC-20261111-bot-record-observation
contracts: [P19, P25, P26]
status: implemented
breaking: false
version_decision: Additive contract revision. Two new record reference shapes, a system-generated observation envelope, a read-only `phone record` command family, one additive durable event type and one optional `UpdateMemory.evidence` field are added. No existing field, enum value, error code, sequence domain or persistent shape changes meaning. Old readers keep working: the event type is additive under P25's unknown-durable rule and old `UpdateMemory` writes without evidence remain valid for agent scope; a user/profile write without evidence is rejected more strictly (the intended S1 rule).
base: 82ae59dc5593d0ab20fdee29f1cb37eaf3826eea
contract_revision: spec/bot/v1/README.md@record-observation-v1 + spec/bot/v2/README.md@memory-evidence-v1
```

Protocol impact: P19, P25, P26; P12: none — 只给 `PDSHShellProvider` 增加 host 侧 `phone record` 分派和注入会话参数，不改 FFI／`shell/include`／`Package.swift`；P09: none — App 只接线新服务，不改页面／投影；P27: none — 行、行批、用户动作、投影 schema/golden 未改；P16: none — Worker profile 与启动契约未改；P03: none — exec-bridge/journal frame 未改，`phone record` 只借用既有的 `PDSH_TOOL_CALL_SESSION` env 成员。

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 总方案 S1 要求（1）DSH session log 与 `bot_events` 有统一可引用、
  可解析的 `record://`；（2）agent 经既有 `phone` 命令桥只读检索／读取自己的记录；（3）压缩摘要
  替换的区间仍可回查原文；（4）外部来源进入上下文时带系统信封；（5）脱敏留痕；（6）记忆写入带
  evidence，信任由引用推导。现况是：两处记录没有统一引用，Bot 工具面没有历史查询，压缩后只能
  看到摘要，外部内容只有秘密脱敏，记忆信任只看会话类型。期望：上述六项都有冻结契约、共享向量和
  Swift/Worker 两端实现，且不放开 `/dsh/home/sessions` 的 EACCES 规则、不新增 MCP 工具 schema。
- **Coordinator / contract owner / implementer / reviewer-integrator.** 本单元 `s2-s1`（分支
  `s2/s1-records`）兼任 contract owner 与 implementer，按 AGENTS.md §3.1 先冻结本变更单与
  owning spec/schema/golden，再实现两端；最终报告给出 base/head 与逐条验证结果。
- **Owning contract / schema / fixtures.** P26：
  [spec/bot/v1/README.md](../../spec/bot/v1/README.md) §§4.2–4.5、[v2/README.md](../../spec/bot/v2/README.md) §1.1；
  `spec/bot/v1/{record-reference,observation-envelope,record-query}.schema.json`；
  `spec/bot/v1/golden/{record-reference,observation-envelope,record-query}.phone.json`；
  既有 `event-envelope.schema.json`／`golden/event-envelope.phone.json`（P25）；
  既有 `v2/memory-fact.schema.json`／`golden/memory-fact.json`；
  `spec/bot/v1/{tools/validate_vectors.py,tools/check_golden.py,export-manifest.json}`、
  `spec/bot/v2/tools/validate_vectors.py`。P19 仍拥有 `phone.<tool>` 的调用词汇和成功／失败 envelope；
  本变更只新增 `record.search`／`record.read` 两个名字，不改 Rust `pdsh-phone`、不改 envelope 形状。
- **受影响 producer / consumer.** Swift 宿主：`Sources/PhoneDSHBot/{Journal,MCP,Memory,Rows,Wake}`、
  `Sources/PhoneDSHShell/PDSHShellProvider.swift`（`phone record` 分派；不进入 Rust 执行器）；
  Worker：`plugins/bot-runtime/src/redact.ts`（信封＋脱敏标记）、`plugins/shell-ext/src/bridge.ts`
  （把 tool-call session 作为 out-of-band 字段交给 `phone record`）；
  prompts：`plugins/bot-runtime/prompts/**`（记录查询与压缩回查的说明）；
  App：`examples/probe-app/**` 只接线。Android 与 HarmonyOS 没有 Bot runtime，不需要跟进。

## 2. 契约 delta

| 项目 | Before → After／依据条款 |
| --- | --- |
| 统一引用 | 无 → `record://session/<sessionId>#<seq>` 与 `record://event/<commitSeq>`。解析器只规范化两端 ASCII 空白、scheme／authority 大小写和十进制前导零；session id 大小写敏感、拒绝 `.`/`..`；十进制上限 `2^53-1`；event 从 1 开始。非法形态不猜测、不别名。 |
| 检索／读取 | 无 → `phone record search <词> [--since …] [--session …]`、`phone record read <引用> [--around N]`。调用者身份只来自宿主对已认领 DSH session 的解析；`--session` 只是过滤。范围是该 Bot 自己的会话与事件；数据源是宿主的物化 session log 与 SQLite `bot_events`。 |
| 结果形状 | 复用 P19 `{ok,tool,egress,scope,data|error}`；新增 `scope:"bot"`、`record.search`／`record.read`，成功 `egress:false`。单次输出 ≤256 KiB，search ≤20 hit，read ≤21 行，`--around` 0…20。 |
| 压缩回查 | 无 → 被 `surfaceOp.replace` 替换的原始行仍可 `read`；replace 事件返回 `replacedRange`，被替换行返回 `shadowedBy`。`search` 也命中被替换行。agent 的提示写进 Bot persona（见 §5）。 |
| 观察信封 | 外部结果只有秘密脱敏 → `tools/post-execute` 给网页／外部 MCP／设备／设备任务／子代理／其他 Bot／附件加 `<observation source=… origin=… at=… owner=… ref=…>…</observation>`。属性顺序与转义固定；正文中的信封标记转义为 `\u003c`。bash 与宿主 Bot 工具不加。模型写出的同样文本不获得信任。 |
| 脱敏留痕 | 无 → 每次脱敏在最后一个文本块追加 `[pdsh-redaction rules=<rule>:<count>,…]`；宿主在记录 `conversation.tool_result` 后追加一条 `redaction.applied` durable 事件，含规则名、次数和 `record://`，不含原文。P25 enum 追加该类型。 |
| 记忆 trust | `source.kind` 决定 trust（`user-turn → user`，其他 `assistant`） → `UpdateMemory.write` 可带 0–8 条 `evidence`；宿主校验引用存在且属于本 Bot，按引用指向的结构推导 `user`／`observation`／`assistant`。`user` scope／`profile` tier 必须同时满足回合来源与至少一条用户消息引用，取更严的一方。 |
| fact 形状 | `memory-fact.schema.json` 无 evidence → 可选 `evidence: [record://…]`（≤8，规范化）。`source` 保留，`trust` 改用三值语义；迁移/导入的旧 trust 值照旧可读。 |
| 命令桥身份 | `ubuntu` 已有 out-of-band session，`phone` 没有 → 仅当 `args[0] == "record"` 时，shell 把 `currentToolCall().sessionId` 写入既有 `PDSH_TOOL_CALL_SESSION`；宿主删除任何 shell 自报值。其他 `phone` 子命令不加 session，行为不变。 |

自检（`spec/README.md` §5.1）：没有新增第二种引用格式、没有第二个 envelope、没有新增 MCP 工具 schema、
没有放宽 `memory-source-boundary`、没有改动任何既有序号域；新 event type 是 additive 且旧读者按
P25 未知 durable 事件规则工作；唯一的收紧是「用户范围／profile 必须带用户消息引用」，正是 S1 的
目标行为。

## 3. 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new | 旧 session log／`bot_events` 没有新字段：引用按 seq／commitSeq 直接可读；旧事实没有 `evidence`，`trust` 照旧；旧 `UpdateMemory` 没有 evidence 的 user/profile 写入现在被拒绝（这是本变更的收紧，客户端升级后需按新工具描述补引用）。 |
| new → old | 新引用／信封只是文本内容，旧读者忽略；`redaction.applied` 对旧读者是未知 durable 事件，按 P25 的 `ignorable`／已知类型契约处理——本变更把它登记进 enum，旧二进制若没有该枚举只会在读取层按既有未知事件策略处理，不会改变既有事件。旧 App 不认 `evidence` 字段时按 `additionalProperties:true` 忽略，事实仍可读。 |
| new → new | Swift host 产出规范化引用；Worker 信封引用来自当前 session 的 `tool/call` seq；记忆证据由同一解析器校验。共享 golden 同时驱动 Python、Swift 与 Worker 测试。 |
| persisted old data → new／rollback | SQLite schema 不变；只新增可选 fact 字段和一种 durable 事件。回滚到旧 App：旧代码忽略 evidence／redaction 事件；旧代码写 user/profile 仍按旧来源规则，可能接受本版本拒绝的写入（回滚的已知宽松差异，记录在报告）。 |

- 版本决定：不升任何 schema 版本，不新增 wire 版本；引用是新的文本命名空间，事件是 P25 additive
  durable type，`UpdateMemory` 只加可选属性。
- bundle／image 顺序：Worker 插件与 Swift 宿主需一起发布；`phone record` 在旧宿主上会得到
  `unclaimed_session`／unknown tool，不会静默返回别的 Bot 数据。没有数据库迁移。
- `target`／`draft` 差异：条款仍为 `target`，真实模型场景与设备端到端不由本单声称。

## 4. 共享向量与校验

- `record-reference.phone.json`：8 个有效（含 0、前导零、大小写、空白、JSON safe 上限）与 24 个
  非法形态，覆盖 syntax／session-id／authority／decimal／range；Python 参考解析器逐条比对 canonical。
- `observation-envelope.phone.json`：7 个有效编码／解码（web、connector、device、subagent、attachment、
  tool、正文转义）、7 个非法头部、5 个解码失败；编码器与解码器互为逆操作，正文 marker 转义单独断言。
- `record-query.phone.json`：5 个成功结果、4 个失败结果、`compactionRecall` 真实 DSH 事件 fixture
  （原行 seq 3 被 seq 20 的 replace 3…9 遮蔽但仍可读）；Swift `BotRecordServiceTests` 用同一 fixture
  驱动真实服务。
- `memory-fact.json` 的 `evidenceCases`：9 个推导有效、4 个引用无效、5 个边界组合（user／observation／
  assistant × scope／tier × source kind），3 个 mutation。
- `event-envelope.phone.json` 追加 `redaction.applied` 有效事件；`tool-catalog.phone.json` 追加
  `UpdateMemory.evidence` 属性 delta。
- 校验命令：`python3 spec/bot/v1/tools/validate_vectors.py`（内部调用 v2）与
  `python3 spec/tools/bot/check_golden.py --root .`。Python 通过不替代运行时 conformance。

## 5. 实现分工（本单元）

| 端 | 路径 | 说明 |
| --- | --- | --- |
| 契约 | `spec/bot/{v1,v2}/**`、`docs/protocol-changes/PC-20261111-bot-record-observation.md` | 本单与向量 |
| Swift 记录 | `Sources/PhoneDSHBot/Journal/BotRecordReference.swift`、`BotRecordService.swift`、`BotObservationEnvelope.swift` | 引用解析、信封编解码、检索/读取、证据推导 |
| Swift 宿主 | `Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift`、`BotDSHRemoteRuntime.swift`、`Sources/PhoneDSHBot/Memory/BotMemory.swift`、`BotMemoryFact.swift`、`Sources/PhoneDSHBot/Wake/WakeInbox.swift` | evidence 校验与 trust、redaction.applied、held 归属 |
| Worker | `plugins/bot-runtime/src/redact.ts`、`plugins/shell-ext/src/bridge.ts` | 信封＋脱敏标记；`phone record` 会话注入 |
| 接线 | `Sources/PhoneDSHShell/PDSHShellProvider.swift`、`examples/probe-app/**` | `phone record` 分派、App 装配只接线 |
| prompts | `plugins/bot-runtime/prompts/**` | 记录查询、压缩回查、evidence 的简短说明 |
| 自检 | `scripts/ci/bot-e2e/selftest.json`、夹具 | 引用读取新增 mock 场景 |

agent 侧「压缩后怎么知道去查」采用 **persona 说明**（不选在压缩摘要旁注入）：Bot 的常驻 prompt 写明
压缩摘要替换的区间仍可回查，给出 `phone record search`／`read --around` 的用法；`read` 在 replace
事件上返回 `replacedRange`，在被替换行上返回 `shadowedBy`。这样不依赖 DSH 上游的压缩实现细节，
也不改 session log。

## 6. 兼容与失败路径

- 未认领／撤销 session：`unclaimed_session`，不执行检索。
- `--session` 不属于调用者 Bot：`session_out_of_scope`，不返回任何片段。
- 引用不存在、格式非法、seq 越界：`unknown_record`／`invalid_reference`。
- 证据任一引用无效：整条记忆写入失败，不降级、不忽略。
- 信封引用无法确定：不加信封；不得写假引用。
- 脱敏事件写入失败：工具结果本身已落记录，事件追加失败由既有 durable 事件错误路径处理，不伪称已留痕。

## 7. 实测记录

环境：worktree `s2-s1`，分支 `s2/s1-records`，base `82ae59dc5`；DSH 只读 checkout
`/private/tmp/dsh-0.2.2`；Node 24.9。没有使用真实模型，没有读取凭据。

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| v1 向量 | `python3 spec/bot/v1/tools/validate_vectors.py` | PASS：turn-origin 9/32、mcp-egress 17/25、record-reference 8 有效／24 非法、observation-envelope 7 有效／7 非法／5 解码失败、record-query 5/4；26 个 mutation；内部调用 v2 也 PASS。 |
| golden 清单 | `python3 spec/tools/bot/check_golden.py --root .` | PASS：26 files / 16 upstream / 10 overlays。 |
| Swift Bot | `swift test --disable-sandbox --filter PhoneDSHBotTests` | PASS：452 tests / 0 failures（含 `BotRecordReferenceTests`、`BotRecordServiceTests`、`MemoryEvidenceTests`、`redaction.applied` 事件测试）。 |
| Swift Shell | `swift test --disable-sandbox --filter PhoneDSHShellTests` | PASS：13 tests / 0 failures（含 3 个 `phone record` 分派测试）。 |
| plugins typecheck | `cd plugins && npm run typecheck` | PASS。 |
| plugins Bot tests | `cd plugins && node scripts/run-tests.mjs "tests/bot-*.test.ts"` | PASS：85 tests / 82 pass / 1 skip / 2 todo / 0 fail。 |
| shell-ext 新测试 | `cd plugins && node scripts/run-tests.mjs "tests/shell-ext-bridge.test.ts"` | PASS：11/11，含 `phone record` 可信会话。 |
| 协议 CI | `CI_PROTOCOL_BASE=82ae59dc5 bash scripts/ci/check.sh --only phone-spec,phone-cross-tree,phone-license,phone-bot-eval-catalog` | PASS：phone-spec 13s、phone-cross-tree 16s、phone-license 0s、phone-bot-eval-catalog 0s（最终复跑）。 |
| bundle | 重建 `worker-entry/build.mjs` + `pack-image.mjs` 后 `phone-bundle-fresh,phone-license` | PASS：6 fresh，license PASS。 |
| eval 自检 | `PDSH_DSH_CHECKOUT=/private/tmp/dsh-0.2.2 bash scripts/ci/bot-e2e/eval.sh --catalog scripts/ci/bot-e2e/selftest.json --upstream mock` | PASS：11/11 场景（含 `BOT-SELFTEST-RECORD`）。 |
| App 编译 | `xcodebuild -scheme PhoneDSHProbe -destination 'platform=iOS Simulator,id=7140630D-…' ONLY_ACTIVE_ARCH=YES OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' build` | PASS。直接 `xcodebuild` 会被外层沙箱拒绝 `sandbox-exec`（macro plugin server），加 `-Xfrontend -disable-sandbox` 后构建成功；这不是产品配置变更。 |
| Xcode 包图 | `bash scripts/ci/check.sh --only phone-xcode-resolve` | PASS：21 个 test target，无非法的 test-target 依赖。 |
| 全量 plugins gate | `bash scripts/ci/check.sh --only phone-plugins` | INCOMPLETE：日志到 1561 行后 10 分钟无新输出，主动取消；任务要求的 typecheck、`tests/bot-*.test.ts` 和 `tests/shell-ext-bridge.test.ts` 已分别 PASS，不把取消写成 PASS。 |
| hygiene | `bash scripts/ci/check.sh --only phone-hygiene` | FAIL：339 条基线 finding（如 `spec/v1/tono-account.md` 的 `tonoai`），其中 `plugins/bot-runtime/src/redact.ts:17` 的 `-----BEGIN` 是本次未改动的既有私钥正则。没有新增 allowlist 或放宽规则。 |

实现边界（如实登记，不是未发现的问题）：

- held 块里的其他 Bot 消息、设备任务结果、子代理结果由 v2 的结构行和转义标记来源/归属，不经过
  `tools/post-execute`，因此不套 XML 观察信封；这也避免在没有稳定引用时伪造 `record://`。子代理的
  **Task 工具结果**仍由 `tools/post-execute` 正常加信封。
- `BOT-SELFTEST-RECORD` 在现有 eval harness 里验证的是同一套 compaction/reference fixture 的可读性
  （fixture 由 `record-query.phone.json` 的 `compactionRecall` 生成）；eval harness 没有装配原生
  `phone` accelerator，所以不能在该场景里直接调用 `phone record`。真实服务的检索/读取由
  `BotRecordServiceTests` 用同一 fixture 和真实 SQLite/session log 驱动。
- `UpdateMemory` 的 evidence 服务由 App/Bot composition 注入；没有注入 record resolver 的内部测试
  helper 仍可走旧路径，但生产 composition 总是注入。

## 8. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| record-observation-v1 | s2-s1 contract owner | 总方案 S1 冻结引用、观察信封、记录查询、脱敏留痕与证据信任 | Swift、Worker、App、spec registry |
