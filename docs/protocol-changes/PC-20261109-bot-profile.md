# Bot 资料契约：头像颜色／发型与 agents-index（P26）

```yaml
change: PC-20261109-bot-profile
contracts: [P26]
status: frozen
breaking: false
version_decision: Additive P26 contract files and a new public PhoneDSHBot Profile module. No existing P25/P27 field, enum, golden or API changes; dsh-bot record schema 3 and runtime-settings version 1 are adopted as-is, so old files stay readable and old readers ignore the new module.
base: b0d246c21621462e804cc087e93d85e0a12267d4
contract_revision: spec/bot/v1/bot-profile.schema.json@bot-profile-v1 + spec/bot/v1/golden/bot-profile.json@bf4075b
```

Protocol impact: P26; P25: none — `spec/tools/bot/export-vectors.mjs` 与 `spec/bot/v1/export-manifest.json` 只新增 bot-profile 批次，P25 event-envelope、event log、effects 与 dshbot-pin 不变；P27: none — 本单只代 attachments 在 `export-manifest.json`／`spec/README.md` P27 行登记既有 bot-attachments golden，不新增或修改 row、row batch、user action、row projection 语义；P09: none — 本轮不修改任何 UI 文件或页面契约。

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 手机端头像只有一套蓝色长发素材；桌面 DSH bot 的 Bot 记录已有 `fish_color`／`fish_hairstyle`（各 15／4 种，`null` 表示按 ID 自动）。期望：手机端按同一个 `agents-index.json` 记录格式读写每个 Bot 的资料，并按同一 FNV-1a 种子算法解析自动外观；本轮只对齐格式和接口，不做桌面与手机之间的实际数据传输。
- **Coordinator / contract owner / implementer / reviewer-integrator:** profile 单元（本工作树）依 AGENTS.md §3 产出冻结与实作证据。Owning contract：P26 Bot profile，`spec/bot/v1/bot-profile.schema.json` 与 `golden/bot-profile.json`。
- **Affected ends:** `Sources/PhoneDSHBot/Profile`（Swift producer/consumer）与 `Tests/PhoneDSHBotTests/Profile`（真实实现读 golden）。`bot-page` 与 `fish-renderer` 只消费冻结的 `BotFishColor`／`BotFishHairstyle`／`BotFishAppearance`／`BotProfileStore`；不修改本契约文件。dsh-bot 是上游数据来源，不因本变更打补丁。
- **Base / head:** `b0d246c21621462e804cc087e93d85e0a12267d4` / 本单元 candidate commit（hash 见交接消息）。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| P26 profile schema | 新增 `bot-profile.schema.json`：冻结 golden 向量形状（source、recordSchemaVersion、colors、colorOrderMain、hairstyles、normalizeFishColor、normalizeFishHairstyle、seed），并以 `$defs` 记录 `agents-index.json` 的 record／index 与 `runtime-settings.json` 形状。 |
| Color／hairstyle order | dsh-bot `COLORS` 的 15 个 id+hex 与 `HAIRSTYLES` 的 4 个 id 原样冻结；顺序即种子取模顺序。`BotFishColor.allCases`／`BotFishHairstyle.allCases` 必须保持该顺序。 |
| Normalizer | `null`、`""`、`"auto"` → `nil`；其余 `lowercased()` 后必须在表内，否则 `nil`；不 trim（`" blue"` → `nil`）。不抛错。 |
| Seed | FNV-1a 32（`2166136261`、`&* 16777619`）；颜色 `hash(seed) % 15`，发型 `hash(seed + ":hair") % 4`。Swift 按 `unicodeScalars` 迭代，但每个标量只取 UTF-16 首单元；astral 字符（`🐟`）因此贡献高代理项。种子取 `id`，空时取 `name`，再空取 `"fish"`；显式字段逐项优先。 |
| Record | `agents-index.json` = `{"schemaVersion":3,"agents":[record…]}`；record = `schema:3, id, name, fish_color, fish_hairstyle, name_explicit, created_at, updated_at`（毫秒）。`fish_color`／`fish_hairstyle` 写 `null` 表示自动。 |
| Main pointer | `runtime-settings.json` = `{"version":1,"mainAgentId":"<id>"|null,"updatedAt":<ms>}`；主 Bot 是指针，不是 record 字段。 |
| Unknown fields | index 顶层、每个 record、settings 顶层与 record 的未知键都保留；已知键由 store 覆写，未知键原样回写。 |
| Bootstrap | 无 `main` record 时创建：name = `legacyName ?? "大肥鱼"`，`name_explicit = (legacyName != nil)`，显式 `blue`／`long`，并设 `mainAgentId = "main"`；已存在则原样返回。 |
| Patch | `BotProfilePatch` 三态：`nil` 不改；`.some(value)` 写入；`.some(nil)` 改回自动。 |
| Durability | 原子写（同目录临时文件 + `replaceItemAt`／`moveItem`），文件与目录 `completeUntilFirstUserAuthentication`、文件 `0600`、目录 `0700`。缺失文件视为空。损坏／不可解析文件先移到 `<原文件名>.corrupt-<ms>`，再按空索引处理；若无法移动则拒绝写入，绝不覆盖原文件。 |
| Errors | 读失败不抛给 UI（返回空／`nil` 并记录 `lastIssue`）；写入与空 id 抛 `BotProfileStoreError`。 |

Self-check（`spec/README.md` §5.1）：没有新增第二种 envelope 或别名；新契约文件是 additive，旧 dsh-bot 记录可读；新字段都有缺省／未知值规则；没有删除、改名或重用任何名称或编号。`fish_color` 的 `null` 语义与上游一致，不复用旧 `avatar_color` 字段。

## 3. 相容性与发佈

| Producer → Consumer | 支援／拒绝方式及理由；对应测试 |
| --- | --- |
| old → new | 旧 dsh-bot `agents-index.json`（schema 3）直接读取；缺少可选字段时 name 空串、时间 0／回退 created_at、未知颜色／发型按 `nil`（自动）。旧 `runtime-settings.json` 无 `mainAgentId` 时返回 `nil`，App 可按下层默认 `"main"`。`BotProfileStoreTests` 覆盖手工旧文档。 |
| new → old | 新文件仍是 schema 3／version 1；没有新增必填字段。旧 dsh-bot 读到 `fish_color`／`fish_hairstyle` 的已知值或 `null` 即可，未知顶层／record 字段被保留。 |
| new → new | `upsert` 与 `setMainBotID` 的原子替换保证单文件不半写；同一 `directory` 的多个 actor 实例按文件最新状态读取。测试覆盖 patch 三态、未知字段往返与主指针。 |
| persisted old data → new／rollback | 不迁移、不改文件版本；回滚到没有 Profile 的 App 时 index／settings 仍是 dsh-bot 原格式，不会被删除。没有需要回滚的 durable 序号或 side effect。 |

- 版本／adapter 决定：直接采用 dsh-bot record schema 3 与 runtime-settings version 1；不新增手机专用版本字段。以后引入 schema 4 时按 P26 新 revision 处理，不能在本轮预留分叉。
- `target` 条款中仍保留的差异：本轮不实现桌面↔手机的 profile 传输、多 Bot UI 或自动外观切换；`BotFishAppearance.autoColor`／`autoHairstyle` 已保留模型语义，UI 由 `bot-page` 决定是否暴露（本轮只编辑显式值）。

## 4. 分工与证据

- **独占路径（profile 单元）：** `Sources/PhoneDSHBot/Profile/**`、`Tests/PhoneDSHBotTests/Profile/**`、`spec/bot/v1/bot-profile.schema.json`、`spec/bot/v1/golden/bot-profile.json`、`spec/bot/v1/export-manifest.json`、`spec/tools/bot/export-vectors.mjs`、`spec/README.md`、本变更单。`spec/bot/v1/tools/validate_vectors.py` 不在本单元路径内；本 golden 由 Swift 真实实现读取，schema 用仓库现有 `spec/v1/tools/spec_golden.py` 的验证器单独核对（见 §6）。
- **共享 fixtures：** `spec/bot/v1/golden/bot-profile.json`（正例；含 13 个颜色规范化、11 个发型规范化、10 个种子含 astral `🐟bot`）。`BotProfileStoreTests` 另外构造旧文档、未知字段、损坏文件与主指针 fixtures，不写入仓库。
- **代 attachments 登记（lead 指派）：** `spec/bot/v1/export-manifest.json` 新增 `bot-attachments.json`（alphabetical，approval-patterns 与 bot-profile 之间）；`spec/README.md` P27 的 golden 清单改为 `spec/bot/v1/golden/{bot-attachments,row-projection,row-protocol}.json`，§4 同一清单。`bot-attachments.json` 与 user-action schema 本体由 attachments 单元拥有，未在本隔离工作树中出现；合入后 registry glob 与 manifest 同时闭合。
- **消费端契约：** `bot-page` 使用 `BotProfileStore(directory: Application Support/PhoneDSHBot)`、`bootstrapMainIfNeeded(legacyName:)`、`upsert(id:patch:)`、`mainBotID()`、`BotFishAppearance.resolve(_:)`；`fish-renderer` 使用 `BotFishColor.hex`、`BotFishHairstyle.rawValue`、`BotFishAppearance`。签名见本单元提交的 public API，未改冻结形状。
- **Exact commands → result：** 见 §6；容器无 Swift 时 `swift test` 记 `NOT_RUN`。

## 5. 修订纪录

| revision | 由谁 | 原因（含收到的 CONTRACT CHANGE REQUEST） | 通知了哪些端 |
| --- | --- | --- | --- |
| `bot-profile-v1`（本冻结） | profile（contract owner） | 首次冻结 P26 Bot profile 向量与 Swift store；对齐 dsh-bot `bf4075b`，不新增 wire 版本。 | bot-page、fish-renderer、lead |

## 6. 实测记录

实作于 base `b0d246c21621462e804cc087e93d85e0a12267d4`；本单元以 candidate commit 交接（hash 见交接消息，避免变更单记录自身 hash 后 amend 失效）。

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| Bot profile schema | `python3 -`（读取 `spec/bot/v1/bot-profile.schema.json` 与 golden，调用 `spec/v1/tools/spec_golden.validate_json`） | PASS |
| Bot vectors（既有批次） | `python3 spec/bot/v1/tools/validate_vectors.py` | PASS（schemas, positive vectors, negative vectors）；该脚本不在本单元路径，未加入 bot-profile 批次，见 §4 |
| Registry rebuild | `python3 spec/tools/registry_build.py --root . --write` 后 `--check` | PASS，registry.json byte-identical |
| Registry check | `python3 spec/tools/registry_check.py --root .` | PASS，27 contracts、458 path/glob references |
| Export block | 临时 Node harness（伪造 dsh-bot 的 `agents/model.cjs`／`fish/model.js`，复制本单的导出块） | PASS，输出与 golden byte-for-byte 一致；真实 dsh-bot checkout 导出 NOT_RUN |
| Exporter syntax | `node --check spec/tools/bot/export-vectors.mjs` | PASS |
| Swift tests | `swift test --filter PhoneDSHBotTests.BotProfile` | NOT_RUN（容器无 `swift`） |
| Cross-tree CI | `CI_PROTOCOL_BASE=b0d246c21621462e804cc087e93d85e0a12267d4 bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` | PASS（phone-spec 16s／235 tests；phone-cross-tree 29s／87 tests、8/8 invariants、190/190 golden、0 breaking） |
| P0 conformance（额外） | `CI_PROTOCOL_BASE=b0d246c21621462e804cc087e93d85e0a12267d4 bash scripts/ci/check.sh --only phone-p0-conformance` | FAIL：`page-structure` 报 12 处 baseline 外差异（既有 GAP-33；本单未改任何 UI 文件）；其余 checker 通过。另在 base `b0d246c2` 的干净 worktree 重跑同一 page-structure 检查，同样 12 处，确认非本单引入 |
| Diff hygiene | `git diff --check` | PASS |

Not verified: Swift 编译与 XCTest、iOS 模拟器／真机、桌面 dsh-bot 导出器实跑（容器没有 dsh-bot checkout；调用方用 `bf4075b` 重跑比对）。`swift test --filter PhoneDSHBotTests` 的其它测试也未在本容器运行。`phone-p0-conformance` 的 page-structure 失败是工作树基线已有的 GAP-33 差异，不由本单引入；未把它算作本单通过。

## 7. 多 Bot 名册（bm-profile，P26 additive）

本单元在既有 P26 Bot profile 契约上追加名册 API 和上游规则向量，仍是 additive，未改 P25/P27。实现权威仍是 dsh-bot `bf4075b0a2e8092b04b726c59a7b085d5a37e6f6` 的 `src/main/agents/{store,model}.cjs`；手机端只在「至少保留一个 Bot」上比上游更严。

### 7.1 Public API 与规则

- `BotProfile` 追加 record 字段（JSON 键与上游一致）：`description`（`description`，截断到 2000 个 UTF-16 unit）、`hiddenByUser`（`hidden_by_user`）、`pinned`（`pinned`）、`unreadCount`（`unread_count`，读取与写入都 ≥ 0）、`lastMessageAt`（`last_message_at`，可为 JSON `null`）。
- `BotRoster { bots, mainBotID, visibleBots }`：`bots` 为插入顺序并含隐藏 Bot；`mainBotID` 是修复后的指针；`visibleBots` 只排除 `hiddenByUser`。
- `BotProfileStoreError` 追加 `invalidName(String)`、`lastBot`、`unknownBot(String)`。未知 id 的 `setMainBotID`／`deleteBot`／`setHidden`／`markRead`／`incrementUnread`／`touch` 都抛 `unknownBot`，且不改文件。
- `roster()` 与 `mainBotID()`：指针为空、悬空或指向不存在的 record 时回落到插入顺序的第一个 Bot 并写回；无可回落 Bot 时保留 `nil`。修复同时把主 Bot 置为 `pinned = true`（上游 `setMainAgent` 的自动 pin 语义；读取修复不改变 `updated_at`）。`mainBotID()` 与 `roster()` 共享同一修复路径。
- `createBot(name:fishColor:fishHairstyle:description:)`：id 为 `agent-` + 16 位小写 hex，冲突时重新生成；名字 trim 后非空且 ≤ 60，否则 `invalidName`；`fishColor`／`fishHairstyle` 为 `nil` 时显式写 `blue`／`long`；`name_explicit = true`；空名册的首个 Bot 成为主 Bot 并 pin。
- `deleteBot(id:)`：唯一 Bot 抛 `lastBot`；未知 id 抛 `unknownBot`；删除主 Bot（或指针本来悬空）时指针迁移到剩余第一个（插入顺序），新主 Bot pin；返回被删资料与新主指针。手机端不删除最后一个 Bot 是上游没有的额外限制。
- `setHidden(id:hidden:)`、`markRead(id:)`、`incrementUnread(id:by:)`、`touch(id:at:)`：更新对应字段与 `updated_at`；`incrementUnread` 的 `by` 至少按 1 计；`markRead` 已经是 0 时不写文件也不发事件；`touch(id:at:nil)` 写 JSON `null`。
- `rosterUpdates()`：订阅先同步收到当前名册，之后每次成功写入推一次；无写入的幂等操作（如已读 0 的 `markRead`）不推。流不丢弃中间的写入。
- `upsert`：改名走同一 trim／非空／≤ 60 校验；`BotProfilePatch` 追加 `description: String?`（截断 2000）与 `hiddenByUser: Bool?`。`id`、`primary`、`mainAgentId` 不是可写 patch 字段。
- `bootstrapMainIfNeeded` 不改变既有行为：仍保证 `main` 存在、显式 blue/long，并只在指针缺失时补指针；没有新增 UI 或 data-transfer。

`agents-index.json` 顶层、每条 record、`runtime-settings.json` 顶层与 record 的未知字段继续原样保留；两个文件仍是原子替换和 `completeUntilFirstUserAuthentication`。损坏文件仍先移到 `<name>.corrupt-<ms>`，移动失败则拒绝覆盖。

### 7.2 向量与契约文件

`spec/tools/bot/export-vectors.mjs` 新增 `rosterRules`，由真实 `AgentRecords`／`normalizePatch` 导出：

- `mainPointerRepair`：空指针 → 第一个、悬空指针 → 第一个、合法指针保持、空名册无主指针。
- `deleteMainMigration`：删主 Bot → 剩余第一个、删非主 Bot 指针不变、删最后一个主 Bot → 剩余第一个。
- `normalizePatch`：`id`／`primary`／`mainAgentId` 从 patch 中剔除（合法字段如 name／description／fish_color／hidden_by_user 保留）。

`golden/bot-profile.json` 的既有 colors／colorOrderMain／hairstyles／normalizer／seed 不变；仅 `source.files` 追加 `src/main/agents/store.cjs` 并追加 `rosterRules`。schema 追加 `rosterRules` 的形状和 record 的新可选字段（旧 record 不受影响）。重跑导出器时 `bot-profile.json` 应 byte-identical；其他 golden 的 phoneDSH 增量（如 `held-inbox` 的 `deviceTaskResult`、`tool-effects` 的 `nativeMcp`）不由本单元改变。

### 7.3 相容性与实测记录

| Producer → Consumer | 支援方式 |
| --- | --- |
| old → new | 旧 record 缺新字段时按 `""`／`false`／`0`／`null` 读取；旧 settings 的 `mainAgentId` 原样使用，缺失时由 `mainBotID()` 修复，不迁移版本。 |
| new → old | 文件仍是 record schema 3／settings version 1；旧 dsh-bot 可忽略新增的 `rosterRules` 向量字段和 record 可选字段。 |
| new → new | 名册写入先读后写、原子替换；同一目录的多个 store 实例以文件最新内容为准；每次成功写入发一个 roster 快照。 |
| rollback | 不新增 durable 序号、不删除 record；回滚到没有名册 API 的 App 时两个 JSON 仍是 dsh-bot 可读格式。 |

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| Bot target build | `swift build --target PhoneDSHBot` | FAIL（本 harness 禁止 SwiftPM 的 manifest sandbox：`sandbox-exec: sandbox_apply: Operation not permitted`）；同命令加 `--disable-sandbox` → PASS |
| Bot tests | `swift test --filter PhoneDSHBotTests` | 同上被 sandbox 拒绝；`swift test --disable-sandbox --filter PhoneDSHBotTests` → PASS，306 tests／0 failures（`BotRosterTests` 17、`BotProfileGoldenTests` 8、`BotProfileStoreTests` 10） |
| 导出器语法 | `node --check spec/tools/bot/export-vectors.mjs` | PASS |
| 上游向量重导 | `node spec/tools/bot/export-vectors.mjs --checkout <upstream> --sha bf4075b0… --out /tmp/…` | PASS；`bot-profile.json` 与仓库 golden byte-identical（其余 golden 的 phone 增量不参与比较） |
| Schema | `spec/v1/tools/spec_golden.validate_json(golden, schema)` | PASS |
| Spec／跨树 CI | `CI_PROTOCOL_BASE=dc823973e5bfa9dcb9bab1e0b6c00d35982812e7 bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` | PASS：phone-spec 235 tests；phone-cross-tree 8/8 invariants、87 tests、0 breaking schema finding |
| Diff hygiene | `git diff --check` | PASS |

Not verified: iOS 模拟器／真机、桌面 dsh-bot 与手机之间的实际资料传输、UI 的添加／隐藏／删除流程；本单元只证明 Swift store 与上游导出向量、schema 和 CI 一致。
