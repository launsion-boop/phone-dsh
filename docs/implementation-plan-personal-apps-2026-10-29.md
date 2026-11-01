# Phone DSH 分阶段实施规格

- 日期：2026-10-29
- 状态：执行中：Phase 0/A1 核心与 B1/B2/B3 模拟器办公核心已验证；A2/A3 未开始；真机、飞行模式、云转换和多模态视觉未完成
- 架构依据：[ADR](architecture-upgrade-personal-apps-2026-10-29.md)
- 验收依据：[验收矩阵](acceptance-matrix-personal-apps-2026-10-29.md)

## 1. 实施原则

1. **Phase 0 先行**：基线不修复，后续不宣称 PASS。
2. **竖切独立验收**：A1、A2、A3 不捆绑为一个平台阶段。
3. **先有用户结果，再抽共享能力**：每个阶段先形成可用闭环。
4. **按需抽象**：前两个 Recipe 用线性 Swift 流水线；前两个云任务用 JobRef 薄适配器。
5. **未验证不广告**：自定义 scheme、CSP、后台调度、原生桥、私有连接器均需证据。
6. **单一事实来源**：架构决策看 ADR，阶段任务看本文，PASS 勾选只看验收矩阵。

## 2. Phase 0：修复基线并取得首份 receipt

建议时间盒：3–5 天。时间盒不是跳过条件；真机签名、设备或依赖缺失时标记 BLOCKED，不得以模拟器替代。

### 2.1 工作项

- [x] 在当前源码和实际构建产物上重跑 `phone-modules`、`phone-hygiene`、`phone-gate-contracts`，逐项修复并记录归因。
- [x] 重跑 iOS Simulator smoke，重点核查“工具结果回填”链路；失败时先修主链路，不扩大新功能范围。
- [x] 保持现有 Worker Git、WAL、channel 和 kill-matrix 回归语义，不用跳测试换绿色。
- [x] 在一台物理 iPhone 上完成最小 smoke：Worker boot、一次真实工具调用、结果回填、WAL 持久化、重启恢复。
- [x] 产出第一份 source-bound receipt，后续阶段引用同一基线或更新基线。

### 2.2 receipt 最小内容

```text
source commit
artifact hashes / bundle provenance
exact commands
macOS / simulator / physical-device environment
pass / fail / blocked by stage
logs and failure classification
date and operator
```

### 2.3 完成条件

- 三项门禁在当前 deliverable 上通过。
- Simulator smoke 通过，工具结果回填无挂起。
- 物理 iPhone 最小 smoke 通过。
- 所有证据可从 receipt 复现；没有“本地应该能过”的口头结论。

## 3. A1：Daily Brief 原生竖切

建议独立时间盒不超过 6 周；超出时砍范围，不用新增抽象延长项目。启动时同时写入 kill/scale 阈值，运行 8 周后评估：refresh 成功率、继续使用率和单位用户成本未达阈值则回退到纯本地报告，不继续加平台功能。

### 3.1 明确不包含

- 不做 HTML Personal App Runtime。
- 不做通用 Office 模块或 P0–P2 工具全家桶。
- 不做 GitHubConnector。
- 不做 Recipe DSL、CloudJob 平台或通用原生桥。

### 3.2 用户结果

用户选择一个或多个 RSS/Atom/官方 API 来源后：

1. 刷新后保留最近一次完整 Snapshot，供后续任务直接读取。
2. 原生刷新流程抓取更新、去重、生成短摘要。
3. 新 Snapshot 原子发布，读取方不会看到半批内容。
4. 离线状态下仍可读取最新一期，并由宿主任务显式调起系统分享。
5. 每条内容记录原始外链、来源与更新时间。

### 3.3 最小实现

- 保留 `DailyBriefModel`、RSS/Atom 解析与系统分享能力，不提供页面或侧边栏入口，不使用生成 HTML。
- 一条线性 `DailyBriefRefreshPipeline`。
- 一份 TaskRun 记录刷新阶段、游标、错误、成本和结果。
- ArtifactStore 保存来源元数据、短摘要和外链；不全文转载。
- ContentSnapshot = 有序 ArtifactRef 列表 + 索引。
- 前台打开和手动刷新；后台刷新不在本阶段承诺。
- 成本记录包含网络字节、模型 token 和 `actual / estimate / unavailable`。
- 来源只走确定性 RSS/Atom/官方 API 解析，不扩展成通用网页抓取器。

### 3.4 建议步骤

1. 实现只读 SourceConfig 和官方来源适配。
2. 实现 Artifact/Snapshot 持久化及当前期指针。
3. 实现线性 refresh：fetch → normalize → dedupe → summarize → publish。
4. 实现离线首页、来源页和系统分享。
5. 增加重复刷新、进程终止、弱网与飞行模式处理。
6. 形成独立 receipt，不与 A2/A3 捆绑。

### 3.5 当前实施状态（2026-10-29）

- 已实现原生页面、RSS/Atom 解析、稳定去重、条件请求游标、原子 Snapshot、线性刷新、来源管理和离线恢复。
- 已实现真实 HTTPS transport、响应上限、重定向与私网校验、失败保留上一期及系统分享。
- 目标测试、真实 RSS 请求、物理 iPhone 最小 smoke、Simulator UI 三阶段进程退出及离线故障阅读/分享均已执行；真实 DeepSeek UI session 已完成文件写入与读回。证据见 `docs/receipts/phase0-a1-2026-10-29.json`。
- 修复手机 mux 投影中嵌套 `llm/retry.delayMs` 的浮点序列化问题；原始 session 日志不变，DSH 上游未改。
- 真正飞行模式和 8 周 kill/scale 评估仍未完成；物理全量 `PhoneDSHDevice` 的 full-Web 与文件桥仍有失败，A1 不宣称全部验收完成。

## 4. A2：GitHub 基础竖切

### 4.1 明确不包含

- 不依赖 Daily Brief 或 Personal App。
- 不做通用 Cloud Sandbox。
- 不做大仓库、自动 rebase、merge PR 或 force push。
- 本阶段不部署 GitHub App token broker。

### 4.2 用户结果

```text
仓库级 fine-grained PAT 授权
→ 选择小仓库与基线
→ clone / branch / edit / diff
→ commit → push → PR → Checks
```

### 4.3 最小实现

- 复用 Worker Git，不重写 object/pack/remote。
- GitHubConnector 使用 REST；可选 GraphQL 只做读取聚合。
- A2 使用 fine-grained PAT，限制到所选仓库和最小权限，存 Keychain并由宿主注入；提供创建、续期、撤销和过期指引，不需要自有服务器。
- GitHub App + token broker 推迟到需要自动续期和组织授权的阶段 B 后。
- commit/push/PR 各自确认并保存请求 hash 和 receipt。
- Checks 绑定精确 headSHA。
- 大仓库在传输前预检并明确拒绝。
- Actions 仅在后续需要时以薄 JobRef 适配，不先建 CloudJob 平台。

### 4.4 故障恢复

- commit 响应丢失：先读 HEAD/status。
- push 超时：先比较 remote ref 与 localHEAD。
- PR 创建超时：先按唯一 head/base/open 反查。
- Actions dispatch 超时：记录结果未知，先反查 run，不盲目重发。

## 5. A3：Personal App Runtime 竖切

A3 分为三个独立门槛。不得把三步合并成“运行时完成”。

### 5.1 A3.0：隔离前提技术验证

在写正式 Runtime 前验证候选 `agent-app://`：

- host A/B 的 localStorage、IndexedDB、cookie、cache 是否隔离。
- CSP `'self'` 对模块、样式和本地 fetch 的行为。
- CSP hash 对指定 inline block 的允许与拒绝行为。
- `connect-src 'none'`、远程脚本、eval 和路径逃逸。
- 页面销毁后的 timer、Worker 和网络残留。

若关键行为不成立，改用 per-app loopback origin 或原生数据投影。不得继续以候选 scheme 宣称安全隔离。

### 5.2 A3.1：无原生桥模式

- AppPackage/AppRelease、Draft/Published 和回滚。
- 页面只读静态 bundle 与宿主发布的 `content.json`。
- `content.json` 来自 ContentSnapshot，不安装 script message bridge。
- 无文件、连接器、通知、分享、日历或 CRM 原生调用。
- 仅本地生成、个人自用，不做 AppPackage 分发或公开索引；产品入口命名为“我的成果/仪表盘”。
- 功能开关/TestFlight 先行。
- 完成 Apple 2.5.2/4.7 适用性与发布评估，不假定无桥或自用自动豁免。

同步实现最小 Dev Loop 和发布门槛：

- Draft console、未捕获异常、资源/bridge 错误以有界脱敏诊断回传 DSH。
- draft-only 截图和 data schema/fixture 内省，不使用正式数据。
- manifest 强制 `dataSchema + schemaVersion`；schema diff 与权限 diff 同级阻断。
- 默认 append-only 事件日志 + 版本化投影；迁移必须确定性、可回滚并在备份副本 dry-run。
- 发布前在隔离 Runtime 做冒烟：首屏渲染、无 console error、fixture 读取成功、CSP/路径/网络检查通过。
- AppRelease 记录生成模型、模型版本、prompt hash、生成器/依赖版本和校验报告。
- 首版不支持多设备同步；换机恢复和未来冲突策略另立决策。

### 5.3 A3.2：受限原生桥，单独发布决策

只有完成审核预沟通/法务评估后才实施：

- 先申请/确认 4.7.2 所需许可或适用范围。
- 按自用、不分发逐项记录 4.7.1–4.7.5 的适用性；公开索引/分发相关功能不在当前范围。
- 首版只开放最小只读方法和 `share.present` 等明确获准能力。
- 写/发操作不进入普通 Bridge，仍走原生 TaskRunner 和审批。
- 扩权 Release 必须重新进行权限 diff 与审核评估。

## 6. B1：视觉办公竖切

可与 A3 独立推进；若 App Runtime 因技术或审核阻塞，先交付 B1，不让办公价值等待新运行时。

### 6.1 用户结果

- 选择 PDF、图片或截图。
- 电子版 PDF 用 PDFKit 抽文本并保留页码。
- 扫描页用 PDFKit 渲页图，直接交给多模态模型。
- 生成有出处的摘要；找不到依据时输出“未找到”。
- 原件不进入 VFS/WAL；Quick Look 和分享可离线使用。

### 6.2 最小实现

- P0：`files.pick/list`、`doc.preview`、`pdf.text`、`pdf.render_pages`、`share.export`。
- ArtifactRef + range read + 分页文本。
- `ArtifactPreviewResolver` 直接预览原件。
- 旧 `read_file` 只读派生 projection：仅文本/页图/缩略图，放在易失命名空间或独立只读 mount。
- 每任务 projection 配额和淘汰策略。
- `imageBudget` 作为 Capability 参数：页数、图片数、分辨率、单图/总字节、降采样和选页策略。
- 页图按 `sourceHash + renderPolicy + pageRange` 缓存复用，避免反复渲染和上传。
- 一条线性摘要 TaskRun，不提前抽 Recipe DSL。
- 成本展示页数、图片预算、token 和估算/实际标记。

### 6.3 不做

- 不把 OCR 作为前置依赖。
- 不把整本长文档无选择地发给模型。
- 不创建普通 `/dsh/workspace/.artifacts` 目录并写入 WAL。
- 不承诺 Office 编辑或高保真转换。

### 6.4 当前实施证据（2026-10-30）

- 已实现固定 19 个 `phone` 工具及原生 ArtifactStore：PDF/OOXML/CSV 读取、结构化 IR 新文件、原生图表、预览与系统分享。
- v45 真实 Agent 矩阵的 Generation、PDF、Read、System 四项通过；v47 的 ShareAndPick 通过。导入 PDF 的字节数与 SHA-256 和原件一致。
- 普通及保留数据模式的模拟器全量基线均为 85 项通过、2 项跳过；其中办公 XCTest 6 项通过、1 项外部扫描 fixture 跳过，真实 Agent 已覆盖该扫描渲染。
- 扫描多模态视觉和云 LibreOffice 转换为 `BLOCKED`，没有使用 OCR 伪造视觉、使用 Quick Look 冒充转换或编辑原 Office 文件。
- 基线脚本曾卸载 App 并清除旧容器；默认 `chat-host` 未恢复。新增 `PDSH_SIM_PRESERVE_DATA=1` 防止后续重置，使用独立测试工作区，并修复日志污染容器路径导致旧终止标记未清理的问题。保留模式全量验收已通过，新哨兵未变；不能据此宣称原数据已保留。
- 分项证据与未验证边界见 [`docs/receipts/office-2026-10-30.json`](receipts/office-2026-10-30.json) 和 [验收矩阵](acceptance-matrix-personal-apps-2026-10-29.md)。

## 7. B2：OOXML 与三个只读场景

### 7.1 范围

- `docx.read`、`xlsx.read`、`csv.analyze`。
- 发票/报销、合同抽取、会议笔记。
- 仍是线性流水线；只有出现第三个重复 Recipe 后才评估共享 DSL。

### 7.2 依赖与支持矩阵

- 新引入的 JS 库必须经许可、包体、内存和真机评估。
- 明确 ZIP 中央目录、shared strings、styles、relationships、公式缓存值、图表与媒体的支持范围。
- 分块/流式输入必须有测试证明，不能以库名推断。
- 不支持的结构明确失败，不能静默返回部分成功。

### 7.3 数字与引用

- 金额、合计、百分比和图表数据由代码计算。
- 保留页码、段落、sheet/单元格等 source locator。
- 找不到来源时写“未找到”。
- 模型输出只负责语义解释，不直接写 OOXML。
- IR schema 校验失败时，将具体错误回传模型进行最多 N 次有界自修复；记录每次 attempt 和成本，达到上限后失败，不进入渲染器。

## 8. C1：连接器与受控写回

### 8.1 前置条件

- 确定首个企业连接器和测试租户。
- 明确数据区域、字段范围、保留期和离机策略。
- 只读链路先验收，写回另开独立验收。

### 8.2 CRM 写回

```text
读取记录与 etag
→ 字段级 diff
→ 原生确认
→ If-Match + idempotency key
→ receipt / audit
→ 冲突重新预览
```

Draft 默认禁止生产写回。邮件、分享和外部 CRM 不承诺通用撤销。

## 9. C2：两个 JobRef 薄适配器

### 9.1 GitHubActionsJobAdapter

- 映射手机 JobRef 与 workflow run。
- 状态、日志轮询、ArtifactRef 和 headSHA。
- 重复 dispatch 先对账，结果未知不直接重试。

### 9.2 OfficeConversionJobAdapter

- 输入为不可变 ArtifactRef、目标格式和转换配置。
- 显式离机确认、页数/大小/成本上限。
- 输出新 Artifact，不覆盖原件。
- 高保真失败只能给明确标注的预览或文本降级。

### 9.3 抽象触发条件

出现第三种 Job 后，才提取统一 CloudJob：

- image digest、secret refs、runner 隔离。
- 事件 seq 续传、统一配额和取消。
- 多 provider 状态模型与成本模型。

## 10. C3：可靠调度与云构建

### 10.1 可靠 refresh

- 云调度器执行同一版本化 refresh。
- 手机同步 Snapshot，普通推送只做提示。
- 云端不承诺手机准点唤醒或通知必达。
- 新闻仍只保存元数据、短摘要与外链，除非来源明确允许更多。

机制按可靠性递增，而不是混用概念：

- `BGAppRefreshTask`：系统决定预算和时机，只做有界 best-effort 刷新。
- 云调度 + 普通推送：服务端先完成 Snapshot，推送提示用户来取；不保证推送必达。
- Silent push：只作为可选同步提示，需单独评估系统限制、频率和隐私，不作为可靠计算保证。
- Notification Service Extension：可做短时、有界的通知内容补全或小数据预取并写 App Group；实际执行时间由系统决定，不承诺固定 30 秒，也不运行完整 Agent。

### 10.2 Personal App 云构建

- 仅用于 React/TypeScript 等确需构建的项目。
- 输入精确 Source Artifact、lockfile、BuildRecipe 和 builder digest。
- 输出静态 bundle、日志和 provenance。
- 构建成功不自动发布，产物仍视为不可信代码。
- 新 Release 扩权必须重新确认。

## 11. 抽象演进规则

| 抽象 | 初始形态 | 何时升级 |
|---|---|---|
| Recipe | 线性 Swift async pipeline + TaskRun | 第三个重复 Recipe 出现后抽有限步骤/DAG |
| ContentStore | ArtifactStore 的 Snapshot 查询视图 | 不另建第三套 blob 权威 |
| CloudJob | JobRef + Actions/Conversion 两个适配器 | 第三种 Job 出现后统一完整模型 |
| Capability | 单一 Registry | 始终唯一权威；schema 放 `spec/` 并做 Swift/TS 契约测试 |
| DSH 工具投影 | Registry → MCP 单向 codegen | 不再增加第二套 DSH 原生工具投影 |
| App 自动化 | 固定到 Published Release 的原生任务 | 不执行任意后台 JS |

## 12. 成本、指标与停止条件

每个 TaskRun 和 JobRef 记录 token、算力、网络、存储、转换页数及成本来源。UI 同时展示预估值与实际值；缺失时显示 `unavailable`，不编造价格。

- 视觉任务必须声明 `imageBudget`；超限先选页、降采样或拆任务，页图派生物按渲染参数缓存复用。
- 每用户设置 `dailyCloudCostLimit`；超限执行降频、停用可选摘要、暂停云转换或等待提额，不能静默继续计费。
- 首版建议模型服务 BYOK，平台云资源使用小额度免费上限；价格来源、免费额度和超限策略在云 API 上线前定稿。
- 每个竖切启动时写入 kill/scale 阈值，8 周评估未达标则回退到更简单的原生报告/只读模式，而不是继续堆平台功能。

出现以下情况必须停止扩大范围并回到基线：

- 当前 deliverable 的既有门禁变红。
- 工具结果回填或 WAL 恢复回归。
- 自定义 scheme/CSP 的关键隔离假设不成立且替代路径未完成。
- 原生桥审核前提未关闭。
- 真实外部动作出现重复、无法对账或凭据进入不该出现的边界。
- 成本无法观测，导致配额和调度无法解释。
