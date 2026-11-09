<!-- SPDX-License-Identifier: MIT -->

# Bot 独立工作根目录与旧会话重建（P25／P26／P27）

```yaml
change: PC-20261109-bot-root
contracts: [P25, P26, P27]
status: implemented
base: ff79c6aa13e271cb0f71d12890a40f881699a6ce
contract_revision: PC-20261109-bot-root@1
version_decision: 复用 P25 事件 envelope（`data` 仍是自由 object，新增可选 `cwd` 提示）、P26 Bot 运行时与 P27 附件/行格式；不新增 wire frame、Remote method、事件类型、schema 版本、环境变量或 Worker 参数。旧 `runtime.started` 事件没有 `cwd` 时运行时查询 `session/list` 兼容；旧 `gb-<botID>` 会话由 DSH 现有 archive Remote 隐藏后按新 cwd 重建。
```

Protocol impact: P25; P26; P27; P14: none — 只调用既有 `session/create`、`session/list`、`workspace/archiveSession`、`workspace/unarchiveSession`，未改 mux 帧或 transport；P15: none — 未改 host 控制端点；P16: none — 未改 Worker URL／init／`PDSH_*`／`__PDSH_*`；P09: none — 本单元不改页面、tokens 或 UI 契约，DSH 页过滤与文件夹显示由 `dsh-filter` 的 PC 记录；P01/P02/P03 等: none — 未改 channel、WAL、controller/journal。

## 1. 触发与现状

- Bot 主聊天会话 id 为 `gb-<botID>`（task/routine 为 `gb-<kind>-<uuid>`），但 `createSession` 固定 `cwd: "/dsh/workspace"`。
- 该 cwd 是 DSH 的全局根：Bot 的会话、附件与普通 DSH 文件混在同一目录；用户要求 Bot 会话与文件不出现在 DSH 页。
- 附件 importer 也以 `/dsh/workspace` 为 `targetDirectory`，写入 `/dsh/workspace/imports/attachments-<messageID>/`。
- DSH 只有 `workspace/archiveSession`／`unarchiveSession`，没有 session-delete Remote；旧会话不能物理删除，只能归档并放弃。
- 旧 `runtime.started` 事件没有记录 cwd，重启时无法只靠事件判断旧会话是否已在新根目录。

## 2. 契约 delta

| 项目 | Before → After／依据 |
| --- | --- |
| Bot 会话 cwd | `/dsh/workspace` → `/dsh/workspace/.dshbot/agents/<botID>`（chat/task/routine 全部；`botID` 逐 UTF-8 标量白名单 `[A-Za-z0-9._-]`，非法字符替换为 `_`，`.`/`..`/空值 → `bot`，截 64）。 |
| Bot 根目录常量 | 不存在 → App `BotSessionRegistry.botDataDirectory` / `BotDataRoot.path`；库内 `BotWorkspaceLayout.defaultBotDataDirectory` 必须同值。生产用 App 常量注入 `BotDSHRemoteRuntime`（cwd）与 `BotWorkspaceAttachmentImporter`（targetDirectory）；库 default 只服务测试/未注入调用。`BotWorkspaceLayoutTests` 固定库 default 的路径形状，三个字面值的相等由本 PC 审核（App 文件只依赖 Foundation，不能引用库常量）。 |
| `runtime.started.data` | `{sessionId, botId}` → `{sessionId, botId, cwd}`；`data` 本来就是 `{"type":"object"}`，旧 reader 忽略未知键，新 reader 对旧事件缺 `cwd` 时回退 `session/list`。 |
| 旧主会话检测 | 无 → 读取最新 `runtime.started` 的 cwd；缺失则 `session/list` 查 `sessionId → cwd`；等于新根且 `session/page` 可恢复才复用。 |
| 旧主会话迁移 | 无 → 新会话先按新 cwd 创建成功，再 `workspace/archiveSession` 旧 id，最后写新 `runtime.started`（durable commit）。旧 Bot 域事件／memory／routine 不删。 |
| 迁移 id | `gb-<botID>` 不变 → 新装仍用 `gb-<botID>`；检测到旧 cwd 时用 `gb-<botID>-<uuid>`，避免 DSH 对同名不同 cwd 的 `session/conflict`。所有 id 仍在 `gb-` 保留命名空间。 |
| 失败回退 | 无 → 创建失败时旧会话从未被归档；写入新事件失败时归档新会话并 `workspace/unarchiveSession` 旧会话后抛出。任何路径都不物理删除旧会话，不出现“删掉旧的却没有新的”。 |
| 幂等 | 无 → 成功后最新事件带新 cwd；重启命中新根直接复用，不重复创建/归档。 |
| 附件根 | `/dsh/workspace` → `<botRoot>`；相对布局仍为 `imports/attachments-<messageID>/<safeName>`。实际路径 `<botRoot>/imports/attachments-<messageID>/...`。详见 PC-20261109-bot-attachments revision 3。 |
| App 登记 | 无 → `BotSessionRegistry` 在 create／recover／claim 登记；`gb-` 前缀判定不依赖登记与 I/O，冷启动即可过滤。 |

自检：没有新增第二种 cwd 表达（仍是 `session/create.request.cwd`）；没有新增 wire 字段（只在既有事件 `data` 增加可选键）；没有删除或复用任何协议名称；没有放宽 DSH workspace registry 或附件上限。

## 3. 根目录选择与兼容性

### 3.1 为什么是 `/dsh/workspace/.dshbot/agents/<botID>`

- `/dsh/workspace` 是 Worker VFS 唯一持久、可写的 workspace root；`/dsh/home` 是 `$HOME`，`/dsh/bin` 只读，`/tmp` 不跨重启。Bot 的附件要让 DSH 文件工具读写，必须落在 `/dsh/workspace`。
- DSH `session/create` 对 `cwd` 执行 `mkdir -p`，所以根目录不需要 App 预先建目录，也不会因为目录不存在而失败。
- Worker workspace registry 只列出显式注册的 workspace record；`/dsh/workspace/.dshbot` 不注册，因此不会成为 DSH 抽屉里的文件夹。`dsh-filter` 仍以 `BotSessionRegistry.isBotWorkspacePath` 做防御性过滤，即使未来某条路径被误注册也不显示。
- 不以 `/dsh/workspace` 本身作 Bot root：那会把 Bot 文件与所有 DSH 会话/工作区混在一起，也无法按 Bot 隔离。不只放在 `/dsh/home`：文件工具与 workspace 浏览以 `/dsh/workspace` 为准，且导入服务把 target 限定在 session cwd 下。
- `.dshbot/agents/<botID>` 对齐上游 dsh-bot `<dataRoot>/agents/<botID>/` 命名；即使未来同机多 Bot，每个 Bot 也有独立 cwd，task/routine 共享同一 Bot root。

### 3.2 兼容性

| Producer → Consumer | 支援／拒絕方式及理由；對應測試 |
| --- | --- |
| 旧事件（无 `cwd`）→ 新代码 | 从 `session/list` 读取旧会话 cwd；旧 cwd ≠ 新根时迁移；查询失败按“未知 cwd”处理并迁移，不错误复用。`testLegacyRuntimeStartedWithoutCwdLooksUpTheSessionCwd`。 |
| 旧 `gb-<botID>` 会话 → 新代码 | 创建新会话 → 归档旧 id → 写新事件；旧 id 由 `gb-` 前缀继续被 DSH 页过滤。`testLegacyMainSessionAtOldCwdIsArchivedAndRebuiltUnderTheBotRoot`。 |
| 新代码 → 旧代码回滚 | 新事件多一个 `cwd` 键，旧 reader 只取 `sessionId`/`botId`，忽略 `cwd`；旧代码启动时仍会按 `gb-<botID>` 尝试旧 cwd（不会自动回滚 cwd）。回滚前应接受 Bot 会话可能再次落在 `/dsh/workspace`；Bot 域数据不丢。 |
| 新代码 → 新代码重启 | 最新 `runtime.started.cwd` 命中新根且 `session/page` 可恢复 → 复用，不重复创建；`testLegacyMain...` 的后半段断言 `createCount == 0`。 |
| 创建失败／事件写入失败 | 创建失败不归档旧会话；事件写入失败归档新会话并恢复旧会话，再把错误抛给调用方。`testFailedRebuildKeepsTheOldSessionArchivableAndUsable` 覆盖创建失败。 |
| Bot 域持久化 | events、memory、routines、wake inbox、ledger 均不迁移、不删除；只替换 DSH 会话。 |
| 旧附件文件 | 旧 `/dsh/workspace/imports/...` 文件不删除、不回滚；新附件只写 `<botRoot>`；旧会话归档后其附件仍留在旧路径，不影响新会话。 |

没有 wire version 变化；没有新旧端同时消费同一 Bot cwd 的分歧，因为 cwd 只在 `session/create` 请求内使用，服务端按字符串建目录。

## 4. 分工與證據

- `bot-root` 独占：`Sources/PhoneDSHBot/{MCP,Attachments}`、`Tests/PhoneDSHBotTests/{MCP,Attachments}`、`plugins/bot-runtime`（本轮未改）、`examples/probe-app/PhoneDSHProbe/Bot/BotRuntimeComposition.swift`、`examples/probe-app/PhoneDSHProbe/BotSessionRegistry.swift`、本 PC 与 `PC-20261109-bot-attachments.md`。
- `r3-fixes` 拥有 `examples/probe-app/PhoneDSHProbe/Bot/BotProductionPage.swift`；本单元未改该文件。附件 importer 的构造参数改为 `botDataDirectory`，调用点仍只传 `transport`/`sessionID`，不需要 Page 改签名。
- `dsh-filter` 只读消费冻结的 `BotSessionRegistry`（见 `contract-bot-session-registry.md` revision 1），不复制、不硬编码根路径。

容器内命令与结果：

- `git diff --check` → PASS。
- `python3 spec/bot/v1/tools/validate_vectors.py` → PASS（schemas、positive vectors、negative vectors；本轮未改 bot golden/schema）。
- `bash scripts/ci/check.sh --only phone-spec` → PASS（90 files、0 error；235 tests OK）。
- `CI_PROTOCOL_BASE=ff79c6aa13e271cb0f71d12890a40f881699a6ce bash scripts/ci/check.sh --only phone-cross-tree` → PASS（8/8 invariants、registry byte-identical、89 schemas 0 breaking finding；87 tests OK）。
- `swift test --filter PhoneDSHBotTests` → NOT_RUN（容器无 Swift/Xcode 工具链）。
- `xcodebuild`、`bot-ui` 截图、模拟器/真机手测 → NOT_RUN（容器无 Xcode／iOS SDK；由调用方本机执行）。
- `cd plugins && npm test` 的 bot-runtime 相关测试 → NOT_RUN（本轮未改 `plugins/bot-runtime`；容器 Node 只用于仓库检查，不把它当 Swift 证据）。

剩余风险：

- 容器未编译 Swift；`BotSessionRegistry` 的 `@MainActor` 生命周期、`Task { @MainActor in ... }` 登记 hop 与 `BotWorkspaceLayout` 的 Swift 语法需在调用方本机 `xcodebuild` 验证。
- 未在真实 Worker 上跑 `session/list`／`workspace/archiveSession`／`workspace/unarchiveSession`；本单元用 scripted transport 覆盖调用顺序与失败回退，真实 DSH 行为由调用方模拟器/真机验收。
- 归档是 DSH 唯一的“放弃”方式，旧会话记录仍留在 DSH 持久化中（archived 集合），不会物理删除；`dsh-filter` 必须同时过滤 `gb-` 与归档列表。旧附件文件也不会清理。

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | bot-root | 按 lead 冻结的 plan 目标 2 首次实现：Bot 根目录、旧会话归档重建、附件根迁移、BotSessionRegistry 接线 | lead、`dsh-filter`、`r3-fixes`、`profile` |
