<!-- SPDX-License-Identifier: MIT -->

# Bot 用户消息附件（P27 user-action 契约扩充）

```yaml
change: PC-20261109-bot-attachments
contracts: [P27]
status: frozen
base: b0d246c21621462e804cc087e93d85e0a12267d4
contract_revision: spec/bot/v1/user-action.schema.json@2b82fac119983c5c67c4b54de19f16b3d2f4ae77
version_decision: 复用 P27 `BotUserAction` v1；只新增可选 `attachments`，不新增 wire frame、事件、MCP 方法或持久化格式。旧 producer 不带该字段时行为不变；新 producer 向旧 consumer 发送带附件动作会被旧 schema 拒绝（fail closed），因此同一 App bundle 内先更新消费端。
```

Protocol impact: P27; P25: none — 未改 event envelope、dshbot-pin、export-vectors 或持久化事件；P26: none — 未改工具面、卡片、memory、routine、watchdog 或 `spec/bot/v1/README.md`；P09: none — 本单元不改页面、tokens 或 UI 契约（附件 UI 由 `bot-page` 单元按本契约消费）。

## 1. 触发与现状

- 用户动作 `chat` 只有 `text`；schema 的 chat 分支要求 `text`，空正文不能发送。
- 模型看不到用户选择的本地文件；行投影只产出文本气泡，没有附件元数据。
- 上游 dsh-bot 已冻结附件语义（`src/main/attachments.cjs`、`dshTranscript.cjs` @ `bf4075b`）：每条消息最多 10 个、单个 ≤ 25 MiB，提示块 `[dshbot-attachments] … [/dshbot-attachments]`，解析时从可见气泡剥离。
- 本变更把同一形状接入 P27，并保持手机端文件位于 Bot DSH 工作区而不是 Mac。

## 2. 契约 delta

| 項目 | Before → After／依據 |
| --- | --- |
| `chat.attachments` | 不存在 → 可选 `[ { name, path, size, mimeType, kind } ]`，`maxItems=10`；每项五字段必填，`size` 为非负整数，`name`/`path`/`kind` 非空；`kind` 保留字符串以容纳上游 `image/audio/video/pdf/markdown/table/json/document/archive/file`，消费端不得因未知 kind 拒绝整条消息。 |
| `chat.text` | 必须存在 → 有非空 `attachments` 时可为空串或省略；无附件时仍按原语义要求 `text`。text-only 分支显式 `attachments.maxItems=0`，因此空附件数组不能和“纯文本”混淆。 |
| 其他 kind | schema 的 `cardDismiss`/`approval`/`stopTask` 分支保留原本宽松形状（旧客户端可能带多余字段），但显式把 `attachments` 限制为 `maxItems=0`；`cardAnswer` 分支仍 `additionalProperties=false`。Swift decoder 对所有非 `chat` kind 的 attachments 键直接拒绝。 |
| 提示块 | 正文后追加 `\n\n[dshbot-attachments]\n<sentence>\n- {json}…\n[/dshbot-attachments]`；手机句为 `The user attached these files. They are saved in your workspace; read them with your file tools when the task needs their contents.`。解析只依赖起止标记与 `- {json}` 行；块后的文字丢弃，块前文字 trim。 |
| 行投影 | 用户行正文 → 先剥离提示块；`body.text` 为可见正文，`body.attachments` 为上述对象数组（camelCase 五字段），`body.content` 同步改写为可见文本；附件-only 行 `text=""` 仍为可渲染 bubble。 |
| `kindFor` | 不存在于 Swift → 逐条镜像上游：MIME 前缀（`image/`、`audio/`、`video/`，PDF 精确 `application/pdf`）优先，扩展名回退（`png/jpe?g/gif/webp/heic`、`mp3/wav/m4a/aac/ogg`、`mp4/mov/webm/mkv`、`pdf`、`md/markdown`、`csv/xlsx?/numbers`、`json/jsonl/ya?ml`、`docx?/pages/rtf`、`zip/tar/gz/tgz/rar/7z`），否则 `file`。 |
| `safeName` | 不存在于 Swift → 取 basename，非 `[\w.\- ()一-鿿]` 逐 UTF-16 单元替换 `_`，去前导点，截 120，空则 `file`。 |
| 导入路径 | App 层 importer 通过 Worker directory-import service 写入 Bot session cwd 的 `imports/attachments-<messageID>/<safeName>`：`targetDirectory` 为 session workspace root，`entryName=attachments-<messageID>`，service 固定追加 `imports/`。`BotAttachment.path` 取 commit 返回的绝对 VFS path + `/` + safeName（典型 `/dsh/workspace/imports/attachments-att-xxx/周报.pdf`），不在库里拼路径常量。重名在导入前按 ` (n)` 去重；失败/超限的单个文件跳过并返回原因，不阻止消息发送。 |

冻结的 Swift surface 与 plan.md 一致：`BotAttachment`、`BotAttachmentPolicy`（`maxCount`/`maxBytes`/`kind`/`safeName`）、`BotAttachmentPrompt.block/parse`、`BotAttachmentImportResult`、`BotAttachmentImporting`。库层不提供文件导入实现（本地 `workspaceRoot` 与 Worker VFS 不是同一命名空间）；只新增 `BotDSHRemoteRuntime.ensureMainSessionID() async throws -> String` 作为 session 创建/恢复的单一 seam。`bot-page` 的 app 层 `BotWorkspaceAttachmentImporter` 用 `PhoneDSHWorkspaceImportSink` + `WebEngineDirectoryImportManifest(sessionID:targetDirectory:entryName:)` 写入，`targetDirectory` 取该 session 的 workspace root（本轮 `/dsh/workspace`，下一轮 per-Bot root 只改 session/accessor，不改相对路径）。

## 3. 兼容性與發佈

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| old → new（无 attachments） | 仍解码/校验为 text-only chat；`bot-attachments.json` 的 parse 无标记用例与 `row-protocol.valid.action` 均通过。 |
| new → old（带 attachments） | 旧 schema 的 chat 分支允许未知字段？否：旧 consumer 必须 fail closed 并拒绝该动作；本变更不要求旧 consumer 静默丢弃附件。正式 App 内 producer/consumer 同 bundle 升级，无跨版本投递。 |
| new → new | schema、Swift `BotUserAction`、planner、runtime、行投影、UI 同 bundle；`chatWithAttachments`/`chatAttachmentOnly` 正例、11 个附件反例、非 chat 附件反例。 |
| 持久化旧数据 → 新代码／回滚 | 行由 DSH session log 与既有事件重建；旧 log 无提示块，parse 原样返回。新 log 的提示块由旧代码当作普通文本显示（回滚只影响显示，不丢消息）。导入文件位于 session workspace 的 `imports/attachments-*`；回滚不删除。v1 没有 Bot 删除 API，因此删除清理尚未实现；若以后删除 Bot，应同时删除该 Bot session root 下的 `imports/attachments-*`。下一轮把 session root 改为 `agents/<botID>/` 不需要改相对布局或附件代码。 |

未知字段、null、`mimeType` 空串、`size` 0 与负数：五字段必填；`mimeType` 允许空串（由 `kindFor` 扩展名兜底）；`size` 必须 ≥0；空文件由导入实现记入 errors。10 与 25 MiB 是上限，不因平台放宽。

## 4. 分工與證據

- 契约 owner/implementer：`attachments` 单元，独占本变更的 schema、`bot-attachments.json`、`row-protocol.json`、`row-projection.json`、`Sources/PhoneDSHBot/{Attachments,Rows,MCP}`、对应测试与本文档。
- `profile` 单元代写 `spec/README.md` §3/§4 的 P27 登记与 `spec/bot/v1/export-manifest.json` 的 `bot-attachments.json` 条目；本单元不直接改这两份文件。
- `bot-page` 单元消费 `BotUserAction.attachments` 与行 `body.attachments`，实现「+」选择器、chip、导入调用、用户行附件卡片；P09 页面契约归其维护。其 importer 通过 `BotDSHRemoteRuntime.ensureMainSessionID()` 取得 session id，`targetDirectory` 用该 session 的 workspace root，`entryName=attachments-<messageID>`，最终 path 取 commit 的绝对 `workspacePath` + `/` + safeName。
- `fish-renderer`：none — 不消费附件。

容器内命令与结果：

- `python3 spec/bot/v1/tools/validate_vectors.py` → PASS（schema、正例、反例；新增 11 附件/非 chat 附件反例被真实 schema 拒绝）。
- `python3 -c` 直接以 `spec.v1.tools.spec_golden.validate_json` 跑 `chatWithAttachments`/`chatAttachmentOnly` → PASS（`validate_vectors.py` 当前只登记旧的 `action`/`cardAnswer` 正例，故另跑一次证明新正例合法）。
- `CI_PROTOCOL_BASE=b0d246c21621462e804cc087e93d85e0a12267d4 bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS（phone-spec 90 files/0 errors；phone-cross-tree 8/8 invariants、190/190 golden covered、registry byte-identical、89 schemas 0 breaking）。
- `CI_PROTOCOL_BASE=b0d246c21621462e804cc087e93d85e0a12267d4 bash scripts/ci/check.sh --only phone-p0-conformance` → FAIL（115 tests OK；page-structure 报 12 个 divergence。在 `b0d246c2` 干净 worktree 以同一命令复跑得到完全相同 12 个，故为 baseline 既有，不由本单元引入）。
- `git diff --check` → PASS。
- `swift test --filter PhoneDSHBotTests` → NOT_RUN（容器无 Swift/Xcode 工具链）。
- `xcodebuild`、`spec/tools/bot/export-vectors.mjs --check`、调用方截图/模拟器手测 → NOT_RUN（无 Xcode / dsh-bot checkout；`export-vectors.mjs` 不在本单元路径，golden 按附录原样提交）。

剩余风险：Swift 代码未在容器编译；`BotAttachmentPrompt` 用手写 JSON 字符串转义逐字节对齐 golden（`BotAttachmentGoldenTests`），若上游对控制字符的处理不同会在调用方本机测试暴露。库层没有本地文件 importer，app 层导入与重名/清理行为由 `bot-page` 实现并按本 PC 验收；行投影附件卡片的最终视觉由 `bot-page` 与模拟器验收。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | attachments 单元 | 初次冻结 P27 附件字段、提示块、导入路径与行元数据 | lead、`profile`、`bot-page` |
| 2 | attachments 单元 | 按 lead 最终裁定移除库层 `BotAttachmentFileImporter`，改由 app 层 Worker import service 写入；补 `ensureMainSessionID()`；路径改为 `imports/attachments-<messageID>/<safeName>` | lead、`bot-page`、`profile` |
