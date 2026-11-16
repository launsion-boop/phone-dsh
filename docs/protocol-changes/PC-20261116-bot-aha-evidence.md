<!-- SPDX-License-Identifier: MIT -->

# PC-20261116-bot-aha-evidence — memory review state and per-evidence observation time

## 0. 摘要（機器可讀）

```yaml
change: PC-20261116-bot-aha-evidence
contracts: [P26]
status: frozen
breaking: false
version_decision: no wire/schema version bump. `review` is an optional additive member of the existing memory document version, write request and read/recall output; `evidence_status` is a host-derived read/recall output member and is never persisted. New producers are iOS-only in this round; old strict schema validators are NOT claimed to accept the new payload (see §3).
base: 908d582b9ee91886ba197bebd54b863c8093cced
contract_revision: spec/bot/v2 @ aha/integration-20261116 freeze commit (SHA published in CONTRACT-FREEZE.md)
```

## 1. 識別與角色

- **Trigger → 現況 → 期望。**
  (a) 记忆文档版本只有聚合 `trust`（回答「谁说的」），没有任何「核对到什么程度」的字段；
  (b) `BotRecordService.resolveEvidence` 验证每条引用后只返回聚合 trust + 规范化引用，丢弃每条记录的
  自身时间，`ReadMemory`／`RecallMemory` 因此只有文档写入时间；
  (c) 没有可表达「来源无版本 = unknown」的位置；
  (d) 抹除某条被引用记录后，幸存文档的 `evidence` 仍原样回显一条不可解析引用，读取面没有失效表达；
  (e) 现有 `restore`／maintainer 回滚只从历史版本取 `content`，新版本 `evidence` 取请求值（回滚请求不传），
  实际会写出 `evidence=[]` 且 `trust` 回退到默认——加新字段前就是缺陷，会连证据链一起丢。
  期望：写入时可记录**有可解析依据**的核验断言（模型断言，不是宿主事实认证）；读取/召回按一次批量解析
  派生逐条观察时间与来源版本（未知显式 null）；抹除后派生状态自然失效；`restore` 继承元数据。
- **Coordinator / contract owner：** C。**Implementer：** M（`Sources/PhoneDSHBot/Memory/**`、
  `Sources/PhoneDSHBot/Journal/BotRecordService.swift`、`BotRecordReference.swift`、
  **`Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift`（全文件）**、`Tests/PhoneDSHBotTests/{Memory,Journal}/**`）。
  **Code-contract 文本：** `Sources/PhoneDSHBot/MCP/BotToolCatalog.swift` 的 memory 工具 description 由 C
  冻结（§4.3），R 只照抄落地。**Reviewer：** Q（独立只读）。
- **Owning spec / schema / fixtures：** `spec/bot/v2/README.md` §1.2、§1.5.1、§5；
  `spec/bot/v2/memory-{document,write-request,write-result,read-result,recall}.schema.json`；
  `spec/bot/v2/golden/memory-{document,write,read,recall}.json`；
  `spec/bot/v2/tools/validate_vectors.py`。
- **受影響 producer／consumer：** iOS Swift `Sources/PhoneDSHBot`（P26）；Python reference validator
  （`phone-spec`）。**Android `android/bot` 已有 partial 记忆移植源码，但本轮不实现、不测试、不验收对齐，
  对齐延期**；HarmonyOS 同理不改。Worker 不改：`evidence_status`／`review` 都在 MCP 工具结果里，Worker
  原样转给模型。

## 2. 契約 delta

| 項目 | Before → After／依據條款 |
| --- | --- |
| memory document version | 无核验字段 → 新增可选 `review` 对象 `{state, basis, method?, at_ms?, refs?}`；缺省 = 没有记录核对判断；§1.5.1 |
| `review.state` | 无 → `verified`／`unverified`／`disputed`（关闭 enum，未知值拒绝） |
| `review.basis` | 无 → `user-statement`／`observation`／`record-recheck`／`model-inference`（关闭 enum） |
| `verified` 的宿主校验 | 无 → basis 不得是 `model-inference`；**`refs` 至少 1 条**，每条按 §1.5 解析存在、属本 Bot、未抹除；否则 `memory-review-invalid`，整条写入失败。`method`（≤200 scalar）与 `at_ms` 是写入者自述，宿主不据此认证，不是硬性条件 |
| `disputed` 的宿主校验 | 无 → `refs` ≥ 1（冲突双方都要能指认）；否则 `memory-review-invalid` |
| `unverified` | 无 → `basis` 必填；可带 `refs` 说明查过哪些记录，但不得被当作已核对 |
| 语义定位 | 无 → `review` 是**模型写入时的核验断言 + 可解析依据**，不是宿主对结论真实性的认证；引用可解析不证明结论成立，独立评测另行检验（§4.4） |
| write request | 无 `review` → 可选；`refs` 额外接受保留值 `current-user-turn`（只限真实用户回合；隐藏/held/agent/routine/Task/maintainer 拒绝） |
| write result | 错误码集合无 review 项 → 新增 `memory-review-invalid`（形状、状态/依据组合、引用解析共用这一个码） |
| read/recall output | 只返回 `evidence` 引用 → 另带宿主派生的 `evidence_status`：与 `evidence` 同序一一对应，`{ref, observed_at_ms, source_version}`；`observed_at_ms` 取原始记录自身时间，取不到（含已抹除）为 `null`；`source_version` 本版一律 `null` |
| 派生方式 | 无 → **一次读取/召回调用内一次批量解析（共享 resolver snapshot）**，不新增 `memory.evidence_invalidated` 事件流、不持久化 `evidence_status`、不为每条命中重扫事件库 |
| restore／回滚 | `.restore` 只取 content，evidence 取请求值（实际为空）、trust 回退 → `restore` **继承**被恢复版本的 `evidence`／`trust`／`source`／`review`，模型不得注入或清空；被恢复版本缺字段时保持缺失 |
| 时效语义 | 文档 `updated_at_ms` 曾被当作唯一时间 → 明确它是记忆写入时间，不是来源观察时间；多个 evidence 各有观察时间 |
| 抹除语义 | 幸存文档回显不可解析引用 → 派生 `evidence_status` 对应项变 `null`；不改 `evidence` 数组、不改版本、不复活内容；不新增事件类型 |
| 条款状态 | iOS Swift 实现 + 共享向量后为 `implemented`（单元层）；Android `not started`（延期，不声称对齐）；真机/真实模型另记 |

**自檢（spec/README.md §5.1）：** 没有新增第二个 trust 表达（`trust` 不动，`review` 回答另一个问题，
并避免与 v1 `verification.reported`（Task 独立验证）同名）；新成员可选且定义缺省；没有收紧闭包消息的
既有合法输入；两个新 enum 都是关闭值域且规定未知值拒绝；没有删除或重用既有名称/编号；`evidence` 形状不变。

## 3. 相容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old data → new reader | 旧版本缺 `review`：读成「没有记录核对判断」，不合成 `verified`；缺 `evidence_status` 的旧文档在读取时由 resolver 现场派生，取不到时间即 `null`。向量：`memory-document.valid` 的旧形状、`memory-read` 旧文档用例 |
| new data → 同一 App 的旧 Swift decoder | Swift 合成 `Decodable` 只取声明键，未知成员被忽略：旧 decoder 能照常 replay，只是看不到 `review`；旧 writer 重写文档时该成员丢失。**这是同一 App 内的降级，不是跨版本混部** |
| new data → 旧**严格 schema** reader | `memory-document`／`memory-read-result`／`memory-recall` 都是 `additionalProperties:false`：**旧严格校验器会拒绝含新成员的载荷**。本仓内没有这样的运行时 consumer（Python 校验器与 golden 同批更新；Android `android/bot` 是 partial、本轮不验收）；**不声称 schema 层面旧 reader 兼容**。若将来出现独立严格 reader，必须升级版本或按本变更单协商，不能假设 optional=可接受 |
| new → new | 新 writer 写 `review`；new reader 回放同一版本；`evidence_status` 每次由 `BotRecordService` 批量重新解析，抹除/撤权后变 `null` |
| rollback（App 回滚） | 旧 writer 可读旧/新事件（忽略新成员），重写时丢 `review`；`evidence_status` 本来就是派生值。回滚后 aha 字段不可见但不报错；不得把回滚后的状态当作仍在核验 |

- **版本／adapter 決定：** 不升 `schemaVersion`（v2 目录没有 wire 版本号）；新增成员可选，属
  spec/README §5.1 规则 2 的可加字段。**发布边界：只有 iOS 这一端产出新成员，本轮不做混部**；
  Android 侧即使有 partial 源码也不消费本字段，对齐另开变更单。
- **更新順序與回滾限制：** spec/golden 先冻结，Swift 跟随；Worker 不改。旧 App 回滚后新字段丢失，
  不影响记忆读写；不允许把回滚或旧数据当「已验证」证据。
- **`target`／`draft` 差異：** 整份 v2 目录仍是 `target`；本变更只把 §1.5.1 的 iOS Swift 实现与共享
  向量落地，不改变 whole-directory 状态。

## 4. 分工與證據

### 4.1 獨占路徑

- M：`Sources/PhoneDSHBot/Memory/**`、`Sources/PhoneDSHBot/Journal/BotRecordService.swift`、
  `Sources/PhoneDSHBot/Journal/BotRecordReference.swift`、
  **`Sources/PhoneDSHBot/MCP/BotMCPRuntime.swift`（全文件）**、
  `Tests/PhoneDSHBotTests/Memory/**`、`Tests/PhoneDSHBotTests/Journal/**`（evidence 相关）。
- R：按 §4.3 冻结文字落 `Sources/PhoneDSHBot/MCP/BotToolCatalog.swift` 的 memory 工具 description
  （C 写死文本，R 只照抄）；不改 `BotMCPRuntime.swift`。R 的检索 hook 只在 E 复现具体失败后另行冻结，
  本轮不预置。
- C：`spec/**`、`docs/protocol-changes/**`。Q：只读。

### 4.2 共享 fixtures

`spec/bot/v2/golden/memory-{document,write,read,recall}.json`：
- 正例：`verified` + `record-recheck` refs、`verified` + `current-user-turn`、`verified` refs-only（无
  method/at_ms 也可，因为 refs 才是硬条件）、`disputed` 双方引用、`unverified` + `model-inference`。
- 反例：verified + model-inference、verified 只有 method/at_ms 没有 refs、disputed 无 refs、
  未知 state/basis、多余成员、refs 超限、畸形引用、引用不存在、跨 Bot 引用、隐藏回合的
  `current-user-turn`、`evidence_status` 计数/顺序/时间不一致。
- 读取/召回：`observed_at_ms` 来自原记录、`source_version` 显式 `null`、不可解析为 `null`。

### 4.3 凍結的 code-contract 文字（R 落 BotToolCatalog）

- `UpdateMemory` description 末尾追加（r2）：
  「可选 `review` 记录这次写入核对到什么程度，它是你的核验断言、不是系统认证：`verified` 必须给
  `basis`（不能是 `model-inference`）且 `refs` 至少一条可解析的真实记录；`disputed` 要在 `refs` 里
  给出冲突双方；没有核对就用 `unverified` + `basis:"model-inference"`，不要自称 verified。
  `method`/`at_ms` 是可选的说明，宿主不会据此认证。」
- **r3 出处提示（回应真实基线 AHA-COMPACT-REUSE 的 `evidence: []` 硬失败）**：在同一 description
  的**最末尾**再追加一句，不得改写上面的 r2 文字：
  「内容只要来自某条会话记录、工具结果或用户原话，就带至少一条 `evidence`（`record://` 或
  `current-user-turn`）；只有自己的推断才可以不带引用，并在正文里写明是推断。
  没有出处的记忆在评测里算溯源失败。」
  这是工具契约文字（不是 R1–R4 行为原则、不新增字段），A/B 由 E 在真实模型上验证；若无可测增益，
  由 C 在下一次 revision 撤回。
- `ReadMemory` description 末尾追加：
  「返回的 `evidence_status` 与 `evidence` 同序，给出每条原始记录的 `observed_at_ms`；`null` 表示
  记录取不到或没有时间，`review` 缺省表示没有记录核对判断，`source_version` 本版一律 `null`，
  不要用文档版本冒充来源版本。」
- `RecallMemory` description 末尾追加：同 `ReadMemory` 的 `evidence_status` 一句。
- 注入块（`BotMemoryInjector`）**不改**：不新增每回合提示，符合「无失败证据不加提示词」。

### 4.4 各端真實測試與命令

- Swift 单元（M 新增/改）：`review` JSON 往返与缺省兼容、verified/disputed/unverified 正反例、
  `current-user-turn` 解析、foreign/erased ref 拒绝、read/recall 的 `evidence_status` 顺序与 `null`
  语义、`updated_at_ms` 不被当来源时间、**restore 继承 evidence/trust/source/review**、
  抹除后派生状态为 `null`。命令：`swift test --filter 'Memory*Tests|BotRecord*Tests|BotSessionErasurePlannerTests'`。
- Spec：`python3 spec/bot/v2/tools/validate_vectors.py`；
  `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`（后台跑，保留日志）。
- 真实产品路径（E，独立）：`scripts/ci/bot-e2e/eval.sh` mock/real；报告必须标 `upstream`。
  **独立评测必须检验「引用可解析」是否真的支持结论**，不能拿字段可解析当模型核对通过。

### 4.5 剩餘風險／後續

- 来源版本在本版一律 unknown；等 session 行或观察信封出现可核验版本时再填，不提前加字段。
- `evidence_status` 依赖重新解析原始记录；会话日志被抹除/归档后该条变 `null`，属于预期显示语义。
- 基线既有 FAIL：`BotRuntimeMultiplexingTests.testWakeWithHeldMessagesOpensOnlyOneIdleTurnAndCarriesTheBlock`
  （held 块尾部换行），与记忆无关，但会污染「全绿」声明，集成时如实记录。
- Android/HarmonyOS 本轮不实现、不测试、不验收；真机、掉电、后台驻留、真实模型 E2E 只在真正执行时记 PASS。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| r1 | C | 初始冻结（PLAN §2–3；`resolveEvidence` 丢弃逐条时间、文档无核验字段） | M、R、E |
| r2 | C | 按 M 审计与主审查：字段改名 `review`（避免与 v1 `verification.reported` 同名）；`verified` 必须 `refs≥1` 且宿主逐条解析，method/at_ms 降为自述；`evidence_status` 明确为一次批量解析的派生视图、不新增事件流；补 `restore` 继承元数据；兼容矩阵明确旧严格 reader 会拒绝、发布仅 iOS | M、R、E、Q |
| r3 | C | 真实基线 AHA-COMPACT-REUSE：复用正确但 `evidence: []` 硬失败 → 冻结最小出处提示（工具 description 末句），不新增自动检索 hook；由 E 做真实模型 A/B，无增益则撤回 | M、R、E、Q |
