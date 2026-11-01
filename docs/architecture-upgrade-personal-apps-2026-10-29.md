# ADR：Phone DSH 移动办公、个人应用与云端执行架构

- 日期：2026-10-29
- 状态：建议稿，未实施
- 文档角色：架构决策与边界；阶段任务和验收不放在本文重复维护
- 配套文档：[分阶段实施规格](implementation-plan-personal-apps-2026-10-29.md)、[验收矩阵](acceptance-matrix-personal-apps-2026-10-29.md)
- 验证边界：本文不是设备验收报告；真机、后台调度、自定义 scheme、CSP、私有服务与审核结论均需独立证据

## 1. 决策摘要

Phone DSH 不应只做“手机上的 coding agent”，也不应退化为只有办公问答的聊天应用。建议定位为：

> **以 DSH 为生成与推理引擎，以个人应用为长期产品形态，以原生能力完成办公和设备操作，以薄云任务适配器承担编译、转换和可靠调度。**

保留四条业务线：

1. **轻量 coding**：代码浏览、修改、diff、commit、push、PR、Checks。
2. **移动办公**：资料汇总、PDF/图片处理、会议纪要、报表和受控外部动作。
3. **个人应用**：将 vibe coding 产生的标准 HTML/CSS/JS 变成可保存、发布、授权和长期使用的应用。
4. **云端执行**：编译测试、大型仓库、高保真转换、可靠定时刷新和有界批处理。

实施上先做三条互不绑定的竖切，而不是先建设完整平台：

- A1：原生 Daily Brief。
- A2：GitHub 基础闭环。
- A3：Personal App Runtime，无原生桥模式先行。

所有阶段之前增加 Phase 0：修复当前基线并取得首份 source-bound receipt。任何后续 PASS 不得建立在红门禁或未验证前提上。

## 2. 现状与问题定义

### 2.1 可复用资产

- DSH 官方插件树运行于 WKWebView Worker，宿主负责生命周期、模型网关、凭据与持久化，见 `docs/architecture.md:66`。
- Worker 内存 VFS 是运行期权威，WAL/materialized copy 负责恢复和物化，见 `docs/architecture.md:548`。
- 写命令留在 Worker，Rust 原生加速器只读，见 `docs/architecture.md:330`。
- 已有文本/Markdown、网页整理、文件导入、图片附件、Quick Look 和系统分享。
- 已有 Worker Git 和 smart HTTP clone/fetch/push，见 `plugins/wasi-toolbox/git/README.md:30`、`plugins/wasi-toolbox/git/remote.ts:607`。
- 已有本地 HTML PAGE surface，见 `Sources/PhoneDSHEngine/PageSurface.swift:120`。
- 已有 MCP 管理、会话恢复、SideEffectLedger、Handoff 协议和执行抽象。

### 2.2 主要缺口

#### 办公不是缺预览，而是缺“手和眼”

当前 prompt 只接受图片附件，见 `Sources/PhoneDSHAgentCore/DSH/DSHRemoteHarness.swift:171`。Quick Look 能打开文件不代表模型能读取文本、表格和来源位置。需要优先补 PDF 抽文本、页图理解、OOXML 有边界的语义读取、结构化中间表示和确定性渲染。

#### 通用桥不等于领域能力

`phone/ctx` 是通用 JSON 转发，不是日历、联系人、CRM 等领域工具。Probe 当前也未注入相应 MCP bridge，见 `examples/probe-app/PhoneDSHProbe/ChatModel.swift:730`。

#### 会话恢复不等于任务恢复

现有 SideEffectLedger 面向 `exec/mcp`，见 `Sources/PhoneDSHController/SideEffectLedger.swift:17`。业务任务还需要输入版本、产物、审批、成本、外部对象和结果未知状态。

#### 大文件不进 VFS 还缺实现路径

如果 Agent 仍只能经 VFS `read_file` 读取内容，Quick Look 又只映射 materialized workspace，那么“原始字节不进 VFS”只是口号。必须定义 Artifact 到模型工具、旧文件工具和预览器的投影。

#### 平台与审核前提未证明

- 当前没有足够物理 iPhone 证据支撑后续承诺。
- `agent-app://<appID>-<hash>` 的 origin/storage 隔离是假设，不是既定事实。
- 自定义 scheme 下 CSP 的 `'self'`、hash 白名单行为也是假设。
- Personal App 的原生桥可能落入 Apple《App Review Guidelines》4.7.2 的事先许可要求，不能只按技术安全问题处理。

## 3. 目标与非目标

### 3.1 目标

1. 保留 DSH 官方插件树，不重写 Agent 内核。
2. 保留 coding/GitHub，不要求手机承担完整编译工具链。
3. 办公任务交付真实 Artifact、来源和外部动作结果，而非只有聊天气泡。
4. Personal App 可保存、发布、更新、回滚并离线运行。
5. 统一能力、权限、任务、产物和审计，但按需抽象，避免平台先行。
6. 重计算、长任务和高保真转换可按隐私策略路由到云端。
7. 外部副作用默认只读，写入必须经过预览、确认和恢复对账。

### 3.2 非目标

首阶段不做：

- 完整本地桌面 POSIX/编译环境。
- 通用 Word/Excel/PPT 高保真编辑器。
- 自研小程序 DSL、组件框架或开放应用市场。
- 任意读取其他 App、通用第三方 App RPA。
- 生成的 JavaScript 无限后台运行或准点唤醒承诺。
- 任意 URL、任意 SQL、任意 Connector 转发桥。
- 无确认发送、审批、支付、CRM 写回或云端覆盖。
- 在第三种同类需求出现前建设通用 Recipe DSL 或完整 CloudJob 平台。

### 3.3 自用、不分发的产品约束

- Personal App 只由当前用户在本地生成、运行和迭代，不提供 AppPackage 分发、下载、公开索引、排行榜或应用商店式入口。
- 产品表面使用“我的成果 / 文档 / 仪表盘”，不使用“App 商店”叙事。
- 未来可以分享 Skill/模板；其他用户基于 Skill 在自己的设备上生成自己的内容。Skill 不携带平台权限、凭据、用户数据或可执行发布授权。
- 自用、不分发降低了内容治理和索引压力，但不自动豁免动态代码执行、Apple 2.5.2 或 4.7.2 的适用性评估。
- 政策明朗前不承诺分享/分发 AppPackage；必要时砍成交互运行时，只保留 ContentSnapshot + 原生报告渲染。

## 4. 总体架构与依赖边界

```text
┌──────────────────────── Native Experience ────────────────────────┐
│ 任务首页 / Chat / 我的成果 / Share Extension / App Intents       │
└──────────────────────────────┬────────────────────────────────────┘
                               │
                    ┌──────────▼───────────┐
                    │ Native TaskRunner    │
                    │ 初期为线性 Swift 流水线│
                    └───────┬──────────┬───┘
                            │          │
                 ┌──────────▼─┐   ┌────▼─────────────┐
                 │ Capability │   │ AgentStepExecutor│
                 │ Broker     │   │ → AgentHarness   │
                 └──────┬─────┘   └──────────────────┘
                        │                 │
        ┌───────────────┼──────────┐      ▼
        │               │          │   DSH Worker
  Native Executors  Connectors  JobRef  推理/生成/轻加工
        │               │          │
        └───────────────┼──────────┘
                        │
        ┌───────────────▼────────────────────┐
        │ ArtifactStore + Snapshot Index     │
        │ TaskRun / Approval / Receipt / Cost│
        └────────────────────────────────────┘

Personal App 使用独立沙箱与受限投影；
不继承 DSH 的 origin、token、VFS、MCP 或通用执行权限。
```

### 4.1 依赖原则

- `PhoneDSH` 不反向依赖 Office/App 模块。
- App 组合根创建 `PhoneDSHHost`、TaskRunner、ArtifactStore 和 App Runtime。
- DSH 负责推理、生成与文本级轻加工，不拥有办公副作用权威。
- App/Extension 只承担有界输入输出，不运行完整 Agent。
- Remote 只取得明确授权的不可变输入，不直接访问本机文件系统、Keychain 或安全作用域 URL。

## 5. 核心契约

### 5.1 ArtifactRef

```json
{
  "artifactID": "art_01J...",
  "version": 3,
  "sha256": "…",
  "mediaType": "application/pdf",
  "byteCount": 84210331,
  "classification": "confidential"
}
```

约束：

- Artifact 版本不可变，修改产生新版本。
- 原始字节、security-scoped URL、bookmark 和 Keychain 不进入 Worker。
- MCP/Bridge 只传小 JSON、分页文本和引用，不传大 base64。
- 模型需要图片时生成受预算约束的代理图，原图仍留 Store。
- 原始文件与可重建派生物采用不同保留策略；任务引用的原件不能被自动回收。

### 5.2 ContentSnapshot 不是第三套内容系统

ContentSnapshot 定义为“**有序的 ArtifactRef 列表 + 一份索引**”，与 Artifact 共用同一个 Store，只是两种视图：

```json
{
  "snapshotID": "snap_01J...",
  "releaseID": "rel_01J...",
  "createdAt": "2026-10-29T08:00:00Z",
  "items": [
    { "artifactRef": "art_01J...", "ordinal": 0 }
  ],
  "index": {
    "schemaVersion": 1,
    "sourceCursors": [],
    "contentHash": "…"
  }
}
```

- Snapshot 不可变，“当前期”只是指向新 Snapshot 的原子指针。
- 新闻条目、报表数据、原始响应和摘要均可成为 Artifact；索引是 Store 元数据，不另建一套内容权威。
- UI 只读取完整 Snapshot，不能看到半批更新。
- ContentStore 只是该 Store 的查询视图，不是独立数据库或第三种 blob 格式。

### 5.3 Artifact 到 Agent 与预览器的投影

#### 原件权威

原件只存在 ArtifactStore。宿主可用 range 读取，Worker 不持有原件路径。

#### 模型读取

首选结构化工具：

- `artifact.readText(fileId, cursor, limit)`：分页返回文本与 `sourceLocator`。
- `artifact.renderPages(fileId, pageRange, budget)`：返回受约束页图 ArtifactRef。
- `artifact.inspect(fileId)`：返回类型、页数、大小、加密状态和可用操作。

结构化返回默认不超过 256 KiB；更大内容分页，文件通过引用或流式渠道处理。

#### 旧 `read_file` 的兼容投影

如必须兼容现有文件工具，提供**派生只读 projection**：

- 只包含文本、页图、缩略图和 manifest，不包含原始大文件。
- 以 `artifactID + version + derivativeHash` 寻址，内容不可变。
- 每任务有独立配额，可淘汰、可重建，不是权威，不允许写回。
- 首版使用 `/dsh/tmp/artifacts/...` 的易失命名空间或独立只读 mount，避免进入 WAL sink。

禁止简单创建 `/dsh/workspace/.artifacts/...` 普通目录来充当投影，因为当前 workspace 写入会进入 sink/WAL。若未来要呈现该逻辑路径，必须实现不经过 sink 的虚拟只读 mount。

#### Quick Look 与预览

新增 `ArtifactPreviewResolver`，直接解析 `ArtifactRef → 原生只读文件 URL`。Quick Look 不需要把原件映射进 VFS；PAGE surface 与 ArtifactPreview 也不应混为同一个权限入口。

### 5.4 TaskRun 与 DSH session/turn 的归属

关系不是一对一：

- 一个 TaskRun 可包含多个 AgentStepExecution 和多个 turn。
- 一个 DSH session 可承载多个 TaskRun。
- 一个 turn 同时只能有一个 owner：某个 TaskRun 的 `stepAttemptID`，或交互式 Chat。

生命周期规则：

1. **Native TaskRunner 拥有 TaskRun**，DSH 只拥有模型 turn 语义。
2. `SessionScheduler` 串行分配 session 的 turn lease，Chat 与 TaskRun 不能暗中互相覆盖。
3. AgentStepExecution 记录 `{taskID, stepID, attemptID, sessionID, turnID, durableSeq, requestID}`。
4. DSH turn 完成不等于业务步骤完成；TaskRunner 必须验证输出 schema、来源和 Artifact 后再 checkpoint。
5. 重启后先通过 session/events 对账原 turn：已完成则校验并继续，已取消/不存在则按策略重建，结果未知不得盲目重复。
6. 缺引擎、缺权限、缺输入和等待外部系统分别进入 `waitingEngine / needsInput / waitingApproval / waitingRemote`。
7. 外部副作用只能由 Native TaskRunner/Connector 提交，不能由 turn 自行宣告成功。

### 5.5 成本计量与预算

每个 TaskRun 记录实际或明确标注估算的成本：

```text
modelInputTokens / modelOutputTokens
modelProviderCost? / currency?
cloudJobSeconds? / computeUnits?
conversionPages? / remoteBytes?
costSource: actual | estimate | unavailable
```

- UI 在提交前展示可预估成本，在完成后展示实际成本。
- 没有 provider 价格数据时显示 `unavailable` 或估算，不伪造精确账单。
- 长文档摘要、云转换、CloudJob 和定时刷新共用同一成本记录。
- 配额决策同时考虑 token、算力、网络、存储和频率。

视觉能力必须把 `imageBudget` 作为一等参数，而不是只在 prompt 中提醒：

```text
maxPages / maxImages / maxPixelsPerPage
maxBytesPerImage / maxTotalImageBytes
downsamplePolicy / pageSelectionPolicy
```

页图派生物按 `sourceHash + renderPolicy + pageRange` 缓存复用，权限校验后可供后续摘要和修改使用，避免每次再生成重复渲染和重复上传。超预算时先要求选页、降采样或拆任务，不自动扩大上下文。

每用户还应有每日云端成本上限 `dailyCloudCostLimit`。超限策略只能选自：降频、停用可选模型摘要、暂停云转换或等待用户提高额度；不能静默继续计费。首版建议沿用用户自带模型 Key（BYOK），平台云资源采用小额度免费上限；若商业决策改变，必须在云 API 上线前调整价格来源和授权，但 JobRef/TaskRun 成本契约不变。

### 5.6 Capability Registry 与投影方式

每个能力声明：

- `id + version`、输入/输出 schema。
- 执行位置、风险、数据分类和离机策略。
- 系统权限、确认策略、资源预算。
- dry-run、恢复、取消、撤销和幂等语义。

Capability、App manifest、Recipe/TaskRun 和 IR 的 JSON Schema 统一放在 `spec/`，Swift 与 TypeScript 使用同一份 schema 做契约测试和代码生成，避免再次产生文档、Swift、TS 三份定义漂移。

**DSH 投影只选 MCP 一条路径**：复用现有 phone-mcp，不再同时维护一套 DSH 原生工具插件。

- Registry → 单向 codegen → MCP tool schema。
- 原生 UI 直接读取 Registry，不经过另一套模型工具定义。
- 一致性测试比较 Registry 与生成 schema，禁止双向编辑造成漂移。
- `mcp__phone__*` 只是传输名称，稳定能力 ID 与权限仍以 Registry 为准。

### 5.7 Recipe：先线性代码，后 DSL

Recipe/TaskRun 是逻辑契约，不代表第一天就需要 DSL。

- 前 1–2 个 Recipe 使用 Swift 线性 async 流水线和一份 TaskRun 记录。
- 每一步有明确输入、输出、checkpoint、成本和错误分类即可。
- 出现第 3 个具有重复结构的 Recipe 后，才提取共享步骤和有限 DAG/foreach。
- 不提前实现通用 condition/script 执行器。

### 5.8 JobRef：先薄适配器，后 CloudJob 平台

初期只定义：

```text
JobRef {
  jobID, kind, provider,
  requestHash, status,
  resultArtifactRefs[],
  resultUnknown
}
```

先实现两个薄适配器：

- `GitHubActionsJobAdapter`。
- `OfficeConversionJobAdapter`。

Actions 已覆盖已推送代码的 CI，Office 转换初期只需一个有界 endpoint。出现第三种 Job 后，再抽象 image digest、secret refs、runner 隔离、事件续传和统一配额等完整 CloudJob 模型。

### 5.9 外部副作用

所有写/发操作采用：

```text
prepare → commit → reconcile
```

- prepare 固化参数、目标、diff、Artifact 版本、成本和 idempotency key。
- commit 在原生确认后执行，保存 provider 对象 ID 和 receipt。
- 超时或崩溃后先对账，结果未知不得直接重试。

本地 Artifact 可用版本快照回滚；邮件、分享和外部系统没有通用撤销，只能在 provider 支持且版本未变时补偿。

## 6. Personal App Runtime

### 6.1 产品模型

> **Personal App = 标准 HTML/CSS/JS 应用包 + 可选原生能力授权 + 可选自动化。**

不发明小程序 DSL，不要求特定前端框架。静态 HTML/CSS/JS 无需本地编译；需要框架构建时后续走云构建。

核心对象：

```text
AppPackage：appID、draftReleaseID、publishedReleaseID
AppRelease：不可变 bundle、manifestHash、源码/构建溯源、校验报告
AppDataNamespace：appID、draft/production、schemaVersion
AppRuntimeSession：临时运行实例，关闭即销毁
```

规则：

- Draft 与 Published 是两个指针，发布和回滚不复制源码。
- Draft 默认使用测试数据并禁止生产写回。
- refresh 固定到 Published Release，编辑 Draft 不改变线上任务。
- Git 管源码历史，AppRelease 管运行版本。
- 新 Release 扩权必须重新确认。

### 6.2 自定义 scheme 与 CSP 是待验证假设

`agent-app://<appID>-<releaseHash>/` 只是候选方案，不得写为已验证隔离保证。

在开放 Runtime 前必须证明：

1. 不同 host 的 storage、cache、cookie 和 IndexedDB 是否真正隔离。
2. 自定义 scheme 下 CSP `'self'` 对模块、脚本、样式和 fetch 的实际行为。
3. CSP hash 是否按预期允许指定 inline block，并拒绝其他代码。
4. `connect-src 'none'` 是否能阻断直接外部请求。
5. 页面关闭后是否无 JS timer、Worker 或网络残留。

任一前提失败时，使用 per-app loopback origin 或原生数据投影替代；不得以纸面 origin 设计代替安全证据，也不能把“WebKit 必定分配独立进程”当作授权依据。

### 6.3 Dev Loop、schema 与发布正确性

#### Dev Loop

生成 → 使用 → 反馈 → 修改必须成为 Draft 的闭环：

- Draft Runtime 将 console 输出、未捕获异常、资源错误和 bridge 调用错误整理成有界、脱敏的 `DraftDiagnostic` 回传 DSH 会话。
- Agent 可在 draft-only 权限下截取 Draft 页面，诊断首屏、布局和交互问题；截图不包含正式数据。
- Agent 可内省当前 data schema、字段类型和 fixture 形状，避免再生成时盲改数据结构。
- 日志有数量、大小和敏感字段上限；诊断引用 Draft/Release，不复制生产凭据或用户隐私。

#### data schema 与迁移

- manifest 强制声明 `dataSchema + schemaVersion`。
- 发布时 schema diff 与权限 diff 同级阻断；不能只检查代码 hash。
- 默认采用 append-only 事件日志 + 版本化投影，减少再生成对历史数据的破坏。
- 改变 schema 必须附带确定性迁移和回滚方案，在备份副本上 dry-run 成功后才可发布；否则拒绝升级。
- 多设备同步首版明确不支持，AppData 仅本地；未来增加同步前必须定义冲突、迁移和换机恢复。

#### 发布冒烟

发布前必须在隔离 Runtime 中自动加载 Draft：

- 首屏成功渲染，无未捕获 console error。
- fixture 数据下的只读 bridge 调用成功；无桥版本则校验 `content.json` 读取。
- CSP、资源完整性、直接网络和路径逃逸检查通过。
- schema 迁移 dry-run 与回滚检查通过。

冒烟失败不得发布。AppRelease 同时记录 `modelProvenance`：生成模型、模型版本、prompt hash、生成器/依赖版本和校验报告；prompt hash 不代替保存必要的安全审查信息，也不应泄漏私密 prompt 内容。

### 6.4 无原生桥降级模式

首个 Runtime 版本不安装 script message bridge：

- 页面只能读取随 Release 提供的静态资源和由宿主发布的只读 `content.json`。
- `content.json` 来自当前 ContentSnapshot，经只读 scheme route 提供，不允许写入。
- 不提供文件、连接器、分享、通知、日历、CRM 或通用任务调用。
- 功能放在 TestFlight/功能开关后，先验证生成式 HTML 体验和隔离前提。

无桥模式降低风险，但不自动等于审核豁免。

### 6.5 原生桥与 Apple 4.7 审核边界

Apple《App Review Guidelines》4.7.2 明确规定，未经 Apple 事先许可，不得向相关软件扩展或暴露原生平台 API/技术。Personal App 由 Agent 生成 HTML/JS，若再通过 Bridge 获取文件、连接器和系统能力，存在直接适用风险。

因此：

1. 在实现原生桥前完成审核预沟通/法务评估，不自行认定“单入口、固定工具表、fileId”可以获得许可。
2. 无原生桥模式先行；原生桥作为独立发布决策。
3. 将 4.7.1–4.7.5 纳入发布验收，而非只写安全测试，但按“自用、不分发”逐项记录适用性，而不是机械建设不需要的平台功能：
   - 隐私、内容过滤、举报、阻断滥用和联系方式等要求。
   - 原生 API 事先许可。
   - 每次向单个软件共享数据或隐私权限时的明确同意。
   - 软件与 metadata 索引及可访问入口；不分发时记录不适用理由，未来开放时再实现。
   - 年龄分级识别和相应限制。
4. 同时评估 2.5.2 对动态生成/执行代码的要求；“只在本地生成、不分享给其他用户”不能单独作为豁免依据。
5. 若未来改变为分享、公开应用库或用户生成内容分发，重新补齐内容审核、举报处置、索引和年龄策略后再发布。
6. 审核确认前，不把 Bridge 能力包装成可正式分发功能；无桥降级仍是 ContentSnapshot + 原生报告渲染。

### 6.6 若获批准后的 Bridge 安全契约

单入口 `tool.invoke(name,args)` 只是传输简化，不是安全边界。仍需：

- Registry 和能力版本快照不可被模型修改。
- `fileId` 绑定 Artifact 版本、task/app/release、collection 和操作权限。
- 输入输出双向 schema、deadline、限频、payload 和 idempotency 校验。
- 结构化返回默认 ≤256 KiB，大内容分页或引用。
- 文档内容视为不可信输入，不能改变权限、工具表或审批。
- 写/发操作必须走独立 prepare/commit，不得由普通 invoke 直接完成。
- 原生审批在 WKWebView 外展示，页面不能伪造。

## 7. 移动办公能力平面

### 7.1 核心原则

1. **视觉优先**：图片、截图和扫描页优先生成受约束页图，直接交给多模态模型；OCR 不进 P0。
2. **电子版 PDF 用 PDFKit 抽文本**；扫描 PDF 渲页图。
3. **OOXML 做有边界的语义解析**，不宣称任意格式、公式、图表或版式支持。
4. **不新增强型办公运行时依赖**；现有 CPython 可留作 coding/兼容用途，但不是办公前提。
5. **不承诺通用 Office 编辑**，只做读取、提取、整理、生成新文件、转换和导出。
6. **模型不直接写 OOXML**，只输出 DocumentIR/SheetIR/SlidesIR/ChartSpec。
7. **数字用代码算**，模型只叙述；引用定位不到就写“未找到”。
8. **只读默认**，写入需要预览、diff、确认和恢复对账。

### 7.2 三层能力面

| 层 | 责任 | 边界 |
|---|---|---|
| Worker 纯 JS | OOXML 语义读取、受约束新文件写入、CSV/Markdown/ChartSpec | 依赖需审计；纯 JS 不自动等于流式或低内存 |
| 宿主原生 | PDFKit、Quick Look、DocumentPicker、Share、EventKit、Contacts 等 | 系统能力逐项验收；Vision/OCR 仅 P2 |
| 可选云端 | 高保真 Office→PDF、大文件解析、批量转换 | 默认关闭，显式离机同意 |

路由输入：

```text
文件类型 × 操作 × 保真度 × 体积 × 隐私
```

不能默认云优先：

- `local_only`：原生 → Worker 语义 → Quick Look → 纯文本，仍不满足则失败。
- 允许离机且要求交付级：云端高保真 → 失败后可给明确标注的预览/文本降级。

### 7.3 工具优先级

| 优先级 | 工具 | 边界 |
|---|---|---|
| P0 | `files.pick/list` | opaque fileId + grant，分页，不暴露宿主路径 |
| P0 | `doc.preview` | Quick Look，只承诺预览 |
| P0 | `pdf.text` | 电子版文本、页码和 cursor |
| P0 | `pdf.render_pages` | 页图，限制页数、尺寸、字节和模型预算 |
| P0 | `share.export` | 系统分享，由用户确认 |
| P1 | `docx.read` / `xlsx.read` | 分块输入和支持矩阵，不承诺公式重算或样式保真 |
| P1 | `csv.analyze` | 字段映射、校验、确定性聚合 |
| P2 | `doc.write` / `sheet.write` / `slides.write` | IR + 模板生成新文件，不直接编辑原件 |
| P2 | `chart.render` | ChartSpec→SVG/PNG，真机验证渲染路径 |
| P2 | `office.convert` | 云端转换，默认关闭 |
| P2 | `ocr.image` | 仅可搜索 PDF、词级引用、大批量/长文档、离线隐私 |
| P2 | `mail.compose_draft` | 草稿，不等于发送 |
| P2 | `calendar.create_event` | diff + confirm + receipt |
| P2 | `contacts.search` | 最小字段和系统权限 |
| P2 | `text.translate` | 按真实语言与离机能力广告 |

P0 先完成“图片/截图/扫描页 → 多模态理解 → 有出处摘要”。P1 再做发票/报销、合同抽取、会议笔记三个只读闭环。

### 7.4 结构化中间表示

- `DocumentIR`：标题、段落、表格、图片、引用和样式槽位。
- `SheetIR`：sheet、单元格、类型、单位、公式 allowlist、计算值和来源。
- `SlidesIR`：页面、布局、文本、图表、图片和备注。
- `ChartSpec`：数据系列、单位、坐标、标签和精度。

固定流程：

```text
模型输出 IR → schema 校验 → 代码计算与勾稽
→ 模板/资源检查 → 确定性渲染 → 读回校验 → 预览与交付
```

模型不能注入宏、外部关系、任意公式或可执行内容。

IR 校验失败时允许有界自修复：将具体 schema 错误回传给模型重试，最多 N 次；每次 attempt 都记录错误与 token 成本，达到上限后失败，不能把无效 IR 交给渲染器。

## 8. Coding 与 GitHub

### 8.1 复用现有 Worker Git

保留 `status/diff/log/show/add/commit/branch/checkout` 和 smart HTTP clone/fetch/push。当前限制包括非 fast-forward/rebase、shallow/partial/sparse、hooks、签名等，见 `plugins/wasi-toolbox/git/README.md:105`、`plugins/wasi-toolbox/git/README.md:252`。

MVP：

```text
授权 → 小仓库 clone → 主题分支 → 修改 → diff
→ commit → push → PR → Checks
```

- commit/push/PR 分别确认并绑定变更、headOID 和 base/head。
- 超时后先读取 HEAD、remote ref 或唯一 open PR 对账。
- Checks 必须绑定当前 headSHA。
- force push、删除分支和 merge PR 不进入 MVP。
- 大仓库预检失败后明确转云端，不静默降级为不完整 clone。

### 8.2 GitHubConnector

- Smart HTTP 负责 Git 对象和 ref。
- REST 负责仓库、PR、Actions、日志和 Artifact。
- 可选 GraphQL 聚合 PR 首屏 reviews/threads/check rollup。
- 已推送 commit 的编译测试优先 GitHub Actions。

认证分两阶段，避免“第一阶段不自建云”与 token broker 冲突：

- **A2 MVP：fine-grained PAT**。用户只授予所选仓库的最小 contents/pull_requests/checks/actions 权限，token 存 Keychain并由宿主注入；不需要自有服务器。代价是用户需手动创建、续期和撤销，产品必须提供过期处理与最小权限指引。
- **阶段 B 后：GitHub App + token broker**。需要自动续期、安装授权和更完整组织体验时再引入；私钥只在服务端。

两种方式的 token 都不进 Worker、URL、Git config、WAL 或日志。

## 9. 自动化与新闻合规

### 9.1 端上与云端

端上：

- 打开、手动刷新时执行。
- 系统提供后台机会时尽力刷新，不承诺准点。
- 生成 HTML/JS 不在后台运行。

云端：

- 云调度器执行同一版本化 refresh，具备重试、超时和监控。
- 结果写入云 Snapshot Store，手机联网后同步。
- 云端保证的是服务端调度，不保证手机唤醒或通知必达。

### 9.2 新闻源与转载边界

首版只接 RSS/官方 API：

- 保存来源元数据、发布时间、短摘要和外链。
- 默认不全文抓取、全文转载或长期保存全文。
- 保留来源署名、原始链接、抓取时间和 source cursor。
- 遵守来源服务条款、速率限制和版权要求。
- 模型摘要是派生内容，仍需单独评估来源条款，不当然等于可自由分发。

## 10. 性能与资源

1. 原始办公大文件进入 ArtifactStore，不进入 VFS/WAL。
2. 派生 projection 有独立配额且可淘汰，不能重新变成第二份长期原件。
3. MCP/Bridge 传引用、分页文本和小 JSON，不传大 base64。
4. Quick Look/ArtifactPreview 使用只读文件 URL 和 range。
5. Personal App 关闭即销毁 WebView；后台自动化不依赖隐藏页面。
6. 现有 WAL 先保持正确性；在真机基线后再评估 fsync/manifest 批处理和索引优化。
7. 本地与云端都记录 token、CPU、网络、存储和成本预算。

## 11. 安全、隐私与审核

| 风险 | 边界 |
|---|---|
| 同源特权窃取 | 独立 origin；默认无网络；不继承 DSH token/loopback |
| 自定义 scheme 纸面隔离 | 先真机验证 origin/storage/CSP，不验证不发布 |
| Bridge confused deputy | 原生绑定 app/release，逐调用鉴权 |
| 新闻/CRM XSS 与提示注入 | 内容按不可信文本处理，严格 CSP，不能触发能力 |
| 版本升级偷权 | 发布时权限 diff，扩权重新确认 |
| 伪造审批 | 审批只在 WKWebView 外的原生 UI |
| 凭据泄漏 | token 不进 JS、URL、WAL、日志和构建产物 |
| 审核失败 | 无桥先行，4.7 法务/审核评估与发布验收前置 |
| 内容合规 | RSS/官方 API、短摘要与外链、内容过滤/举报/年龄策略按适用范围落地 |

## 12. 决策与替代方案

### 决策 A：先三条竖切，不先建平台

选择：A1 Daily Brief、A2 GitHub、A3 Personal App 独立交付。

替代：一个阶段同时完成 Office、Runtime、GitHub、CloudJob。拒绝，因为依赖会互相阻塞，无法形成可信 receipt。

### 决策 B：Artifact 原件与派生投影分离

选择：原件只在 Store；模型读分页/页图；旧文件工具只读派生 projection；Quick Look 用独立 resolver。

替代：所有文件复制进 VFS。拒绝，因为会产生 base64、内存、WAL 和恢复副本放大。

### 决策 C：Recipe/CloudJob 延迟抽象

选择：线性 Swift 流水线和两个 JobRef 薄适配器先行。

替代：立即实现 DAG DSL 和通用 CloudJob。拒绝，当前需求不足以证明抽象收益。

### 决策 D：无原生桥模式先行

选择：先只读静态资源与 ContentSnapshot，再决定原生桥。

替代：直接给生成式 JS 开放文件、连接器和分享。拒绝，既有安全风险，也有 Apple 4.7 审核风险。

## 13. 未决事项

以下事项必须在对应功能广告前关闭：

1. 首个企业连接器与测试租户。
2. 云端模型、转换和 Snapshot Store 的区域与保留期。
3. Office 交付的预览级、交付级和印刷级定义。
4. 自用、不分发约束下 2.5.2/4.7 的适用性与原生桥评估。
5. 自定义 scheme/CSP 的真机结论及替代路径。
6. 大仓库转云阈值。
7. 未来多设备同步与换机恢复；首版明确不支持。
8. Recipe 级授权和逐次确认的边界。
9. 每日成本上限、免费额度、BYOK 与超限策略的最终产品参数。

## 14. 最终建议

先证明三个小而完整的结果：

- 原生 Daily Brief 可刷新、可离线、可分享。
- 小仓库可完成 commit → push → PR → Checks。
- 生成式 HTML 可在无桥沙箱中读取只读 Snapshot。

然后依次补视觉办公、连接器和云任务。不要先做小程序框架、完整 Office 编辑器、Recipe DSL 或通用 CloudJob 平台。

具体任务见[分阶段实施规格](implementation-plan-personal-apps-2026-10-29.md)，发布门槛见[验收矩阵](acceptance-matrix-personal-apps-2026-10-29.md)。
