# Phone DSH 验收矩阵

- 日期：2026-10-29
- 状态：可勾选验收规格
- 架构依据：[ADR](architecture-upgrade-personal-apps-2026-10-29.md)
- 实施依据：[分阶段实施规格](implementation-plan-personal-apps-2026-10-29.md)

## 1. 证据规则

- 每个 PASS 必须绑定：源码 commit、构建产物 hash、环境、准确命令、日期、结果和日志位置。
- Simulator、macOS、物理 iPhone、真实 GitHub、真实云服务和 in-process simulator 是不同证据等级，不得互相替代。
- 外部 Agent 的失败或成功报告必须由当前交付物复核，不能直接写成当前源码事实。
- 任一阶段只对自己的竖切负责，不用其他功能的 PASS 抵消本阶段失败。
- `NOT_RUN`、`BLOCKED`、`FAIL` 不得写成 `PASS` 或 `INCOMPLETE PASS`。
- 当前 deliverable 出现基线回归时，立即停止后续能力发布。

## 2. Phase 0：基线

| 勾选 | ID | 场景 | 通过条件 | 证据 |
|---|---|---|---|---|
| [x] | P0-01 | 三项基线门禁 | `phone-modules`、`phone-hygiene`、`phone-gate-contracts` 在当前 deliverable 全部通过 | 当前 commit 重跑：[`p0-lite-2026-10-31.json`](receipts/p0-lite-2026-10-31.json) |
| [x] | P0-02 | Simulator smoke | Worker boot、真实工具调用、结果回填、WAL、恢复全部完成，无挂起 | [`p0-lite-2026-10-31.json`](receipts/p0-lite-2026-10-31.json)（probe/smoke/kill 三份报告 gate 全通过） |
| [x] | P0-03 | 既有 Git/WAL 回归 | 现有 Git golden、WAL 和 kill-matrix 语义未削弱 | 同一 receipt 的 `phone-gate-contracts`（18 项回归）与 kill 报告 |
| [ ] | P0-04 | 物理 iPhone 最小 smoke | 真机完成 boot → tool → result → persist → restart/recover | **BLOCKED**：当前 commit 未重跑；历史真机 PASS 绑定 `add2d9c5`，不能充当当前证据 |
| [x] | P0-05 | 基线可追溯 | 首份 receipt 绑定 commit、artifact、命令、环境和结果 | 当前 commit 重跑：[`p0-lite-2026-10-31.json`](receipts/p0-lite-2026-10-31.json) |

2026-10-31 复核：P0-01/P0-02/P0-03/P0-05 在 `b5378575` 上重跑通过，证据见上面的 receipt；P0-04 因真机签名与连接不可用改为 BLOCKED，不再沿用旧 commit 的勾选。同一次 simulator 运行中 `OfficeTests.testOfficeBridgeDoesNotAdvertiseUnsupportedContext` 仍失败，属既有的链接缺失问题（历史日志同样失败），不计入 P0 gate 判据。

## 3. A1：Daily Brief 原生竖切

| 勾选 | ID | 场景 | 通过条件 | 证据 |
|---|---|---|---|---|
| [x] | A1-01 | 首次打开 | 原生页面展示最近完整 Snapshot，不依赖 HTML App Runtime | 截图/运行日志 |
| [x] | A1-02 | 打开时刷新 | fetch → normalize → dedupe → summarize → publish 顺序完成 | TaskRun 与 Snapshot |
| [x] | A1-03 | 原子发布 | 刷新中退出或杀进程，不出现半批内容或当前期指针撕裂 | Simulator UI 三阶段 process-exit 故障注入与 Snapshot ID 对账 |
| [x] | A1-04 | 重复刷新 | 相同 source/itemID 不重复，source cursor 可恢复 | 条目与游标对账 |
| [ ] | A1-05 | 飞行模式阅读 | 飞行模式下可读取最新一期、来源和更新时间 | 真机录屏/日志；当前仅有 DEBUG 网络故障注入，未替代此项 |
| [ ] | A1-06 | 飞行模式分享 | 飞行模式下可调起系统分享并交付本地副本；在线目标不承诺成功 | 真机记录；当前仅验证离线故障下的系统分享面板 |
| [x] | A1-07 | 来源合规 | 仅确定性 RSS/Atom/官方 API；保存元数据、短摘要和外链，不全文转载，不做通用抓取 | 来源配置与 Store 检查 |
| [x] | A1-08 | 成本可见 | 展示网络字节、模型 token 及 actual/estimate/unavailable | UI 与 TaskRun |
| [x] | A1-09 | 进程恢复 | fetch、summary、publish 各阶段杀进程后状态明确，不重复发布 | Simulator UI 三阶段 process-exit receipt |
| [x] | A1-10 | 无范围偷跑 | 无 App Runtime、GitHub、Recipe DSL、CloudJob 依赖 | 依赖审查 |
| [ ] | A1-11 | kill/scale 准则 | 启动时写入阈值，8 周评估未达标则回退到纯本地报告，不继续扩平台 | 评估记录 |

本轮证据：[`docs/receipts/phase0-a1-2026-10-29.json`](receipts/phase0-a1-2026-10-29.json)。物理 iPhone 最小 smoke 已通过；Simulator UI 已完成三阶段进程退出、离线故障阅读/分享及真实 DeepSeek session 文件写入与读回。真正飞行模式和 8 周评估仍未完成；物理全量 `PhoneDSHDevice` 的 full-Web 与文件桥仍有失败，不宣称真机全量通过。

2026-10-30 后续产品决策：原生 UI、侧边栏入口和 DEBUG 页面路由已下线，上述 UI PASS 仅是历史实现证据，不再表示当前产品可以进入每日简报。RSS/Atom、去重、Snapshot 和 Store 能力保留，已有状态不删除，后续由 `DailyBriefTests`、`DailyBriefModelTests` 及入口缺失 UI 用例验收。

## 4. A2：GitHub 基础竖切

| 勾选 | ID | 场景 | 通过条件 | 证据 |
|---|---|---|---|---|
| [ ] | A2-01 | 公开小仓库 | 完成 clone → branch → edit → diff → commit → push → PR | 真实测试仓链接与日志 |
| [ ] | A2-02 | 私有小仓库 | 同上，且只访问明确授权仓库 | 私有测试仓与 PAT 权限 |
| [ ] | A2-03 | 凭据边界 | token 不出现在 Worker、URL、Git config、WAL、模型上下文和日志 | 全边界扫描 |
| [ ] | A2-04 | commit 恢复 | commit 响应丢失后先读 HEAD，不重复提交 | 故障注入与 HEAD |
| [ ] | A2-05 | push 恢复 | push 超时后比较 remote ref，不重复推送 | ref 对账 |
| [ ] | A2-06 | PR 恢复 | 创建超时后按 head/base/open 反查，不重复 PR | PR 对账 |
| [ ] | A2-07 | Checks 正确性 | Checks 只绑定当前 PR headSHA，不展示旧 commit 结果 | Checks 与 SHA |
| [ ] | A2-08 | 大仓库预检 | 超限在传输前明确拒绝并说明路径，不伪装完整 clone | 预检日志 |
| [ ] | A2-09 | 高风险操作边界 | 无自动 merge/rebase/force push；裸 force 不开放 | 调用审查 |
| [ ] | A2-10 | 独立性 | 不依赖 A1/A3 的完成状态 | 独立 receipt |
| [ ] | A2-11 | MVP 无服务器认证 | fine-grained PAT 仅限所选仓库和最小权限，存 Keychain；无需 broker；过期/撤销路径可用 | 授权配置与扫描 |

## 5. A3.0：Personal App 隔离前提

| 勾选 | ID | 场景 | 通过条件 | 证据 |
|---|---|---|---|---|
| [ ] | A3-01 | host A/B storage | localStorage、IndexedDB、cookie、cache 不串读串写 | WebKit probe receipt |
| [ ] | A3-02 | CSP self | 自定义 scheme 下模块、样式、本地 fetch 行为符合预期 | probe 日志 |
| [ ] | A3-03 | CSP hash | 指定 inline block 可运行，其他 inline/eval/远程脚本被拒绝 | 正负样例 |
| [ ] | A3-04 | 网络封锁 | `connect-src 'none'` 阻断直接外联，页面不崩溃 | 网络记录 |
| [ ] | A3-05 | 路径与跨源 | `..`、symlink、跨 appID/release 访问被拒绝 | 攻击样例 |
| [ ] | A3-06 | 销毁生命周期 | 关闭页面后无 JS timer、Worker 或网络残留 | 进程/网络观测 |
| [ ] | A3-07 | 替代路径 | 若上述失败，per-app loopback 或原生投影替代已验证，不保留纸面假设 | 替代 receipt |

## 6. A3.1：无原生桥 Personal App

| 勾选 | ID | 场景 | 通过条件 | 证据 |
|---|---|---|---|---|
| [ ] | A3-10 | 发布与回滚 | Draft/Published 分离；回滚无需重新构建 | Release 记录 |
| [ ] | A3-11 | 只读 Snapshot | 页面仅读静态 bundle 和 `content.json`，无 script message bridge | 配置与调用审查 |
| [ ] | A3-12 | 无设备能力 | 无文件、连接器、通知、日历、CRM 或通用任务调用 | Bridge/网络审查 |
| [ ] | A3-13 | Draft 数据隔离 | Draft 不读取或污染正式数据，不能生产写回 | 数据命名空间检查 |
| [ ] | A3-14 | 源码与模型溯源 | Release 绑定精确 commit/tree 或完整快照，并记录生成模型、版本、prompt hash 和校验报告 | provenance |
| [ ] | A3-15 | 功能开关 | 仅在 TestFlight/功能开关后开放，关闭后无入口 | 构建配置 |
| [ ] | A3-16 | 自用与审核评估 | 无 AppPackage 分发/公开索引；完成 2.5.2/4.7 评估，不宣称自用或无桥自动豁免 | 评估结论与入口审查 |
| [ ] | A3-17 | Dev Loop 诊断 | console、异常、资源/bridge 错误以有界脱敏形式回传 DSH；draft-only 截图和 schema 内省可用 | 诊断样例与隐私检查 |
| [ ] | A3-18 | schema 迁移 | manifest 强制 dataSchema/version；schema diff 阻断；迁移在备份上 dry-run 且可回滚 | 迁移 receipt |
| [ ] | A3-19 | 发布冒烟 | 隔离 Runtime 首屏成功、无 console error、fixture 读取成功、CSP/路径/网络检查通过；失败不能发布 | 冒烟报告 |

## 7. A3.2：原生桥发布门槛

| 勾选 | ID | 场景 | 通过条件 | 证据 |
|---|---|---|---|---|
| [ ] | A3-20 | 4.7.2 原生 API | 事先许可或适用范围结论已关闭，未关闭则不上桥 | 审核/法务记录 |
| [ ] | A3-21 | 4.7.1 内容要求 | 按自用、不分发记录隐私、过滤、举报、阻断和联系方式的适用性；未来分发前重新实现并验收 | 适用性与功能记录 |
| [ ] | A3-22 | 4.7.3 单次同意 | 每次向单个软件共享数据/隐私权限均有明确同意 | 授权记录 |
| [ ] | A3-23 | 4.7.4 索引 | 当前无公开分发/索引，记录不适用理由；未来开放前必须补齐软件、metadata 和可访问入口 | 适用性结论 |
| [ ] | A3-24 | 4.7.5 年龄策略 | 年龄分级识别和限制按适用范围实现 | 配置与流程 |
| [ ] | A3-25 | 调用授权 | fileId 绑定 Artifact 版本、app/release、collection 和操作 | 越权测试 |
| [ ] | A3-26 | 返回预算 | 结构化返回默认 ≤256 KiB；大内容分页或引用 | 大小测试 |
| [ ] | A3-27 | 写发隔离 | 普通 invoke 不能直接写/发，必须 prepare/commit/reconcile | 调用计数与 receipt |
| [ ] | A3-28 | 原生审批 | 审批在 WKWebView 外，绑定参数 hash、目标、成本和版本 | UI 与审批记录 |

## 8. B1：视觉办公

本轮证据限于 macOS/iOS Simulator 的真实 Agent 与原生工具，不能替代物理 iPhone、飞行模式或多模态视觉证据。

| 勾选 | ID | 场景 | 通过条件 | 证据 |
|---|---|---|---|---|
| [x] | B1-01 | 电子版 PDF | PDFKit 抽文本准确，引用可回到正确页码 | v45 两页发票、页码与原文对账 |
| [x] | B1-02 | 扫描 PDF | PDFKit 页图符合页数、尺寸、字节和 token 预算 | 单页 PNG，23,956 B，聚合上限 180,000 B |
| [ ] | B1-03 | 无 OCR 前置 | 图片/截图/扫描页可直接走多模态理解，无需 OCR | BLOCKED：当前 `deepseek-chat` 不支持图像输入；`usedImage=false`，未以 OCR 冒充视觉 |
| [x] | B1-04 | 引用诚实 | 无依据时输出“未找到”，不编造来源 | 发票缺失条款与扫描观察文本均为“未找到” |
| [x] | B1-05 | 原件不进 VFS | WAL 无原始大文件 mutation，无 base64 导入 | ArtifactStore 位于 App Support；VFS 仅有摘要/派生内容 |
| [ ] | B1-06 | 派生 projection | 仅文本/页图/缩略图，配额、只读、可淘汰，不进入持久 sink | 页图为有界 base64 派生物；独立只读 mount 与淘汰策略未单独验收 |
| [x] | B1-07 | 快速预览 | ArtifactPreviewResolver 直接打开原件，无 VFS 副本 | 实际 Quick Look 原件预览，关闭后返回 `dismissed` |
| [ ] | B1-08 | 飞行模式 | PDF 抽文本、预览、已有摘要和本地分享可用 | NOT_RUN：未执行真机飞行模式 |
| [x] | B1-09 | 长文档边界 | 超页数/预算时要求选页或明确失败，不自动塞满上下文 | 分页 cursor、非法页范围、图像预算负样例 |
| [ ] | B1-10 | 图片预算与缓存 | imageBudget 作为 Capability 参数；页图按 sourceHash/renderPolicy/pageRange 复用；重复任务不重复渲染上传 | 参数与 sourceHash 已验证；跨任务缓存/网络复用未验证 |

## 9. B2：OOXML 与只读场景

| 勾选 | ID | 场景 | 通过条件 | 证据 |
|---|---|---|---|---|
| [ ] | B2-01 | 依赖审查 | 新 JS 依赖的许可、包体、内存和真机结果有记录 | 未新增 JS 库；真机包体与内存尚未测量 |
| [ ] | B2-02 | 分块输入 | 大文件测试证明未整文件读入；无隐藏全量拷贝 | 1 MiB 分块导入已实现；大文件真机 IO/内存未测量 |
| [x] | B2-03 | 支持矩阵 | 不支持的结构明确失败，不静默部分成功 | ZIP CRC、Zip64、路径逃逸、非法参数与转换 BLOCKED；不代表完整 Office 保真 |
| [x] | B2-04 | 发票/报销 | 金额由代码计算和勾稽，异常可定位 | `csv.analyze` 合计 116.50、分组与负数第 3 行 |
| [x] | B2-05 | 合同抽取 | 条款候选、风险摘要、未找到项和真实 locator | DOCX `paragraph 1`、`table row 1`；PDF 页码另由 B1-01 验证 |
| [ ] | B2-06 | 会议笔记 | 决议/行动项可回到文本位置，无依据不生成事实 | 已验证新文件生成，尚未完成真实会议材料抽取与引用闭环 |
| [x] | B2-07 | 数字与图表 | 金额、合计、百分比和图表数据均由代码生成 | CSV Decimal 计算与原生 PNG；XLSX 公式缓存值不重算 |
| [x] | B2-08 | 抽象节制 | 第三个重复 Recipe 出现前无通用 DAG/DSL | 当前为固定工具路由与原生实现，未新增 Recipe DSL |
| [ ] | B2-09 | IR 有界自修复 | schema 错误回传后最多重试 N 次；记录 attempt/token；超限失败且不进入渲染器 | 参数错误会失败并可由 Agent 重试；自动次数/token 记录尚未实现 |

## 9A. B3：原生办公集成

| 勾选 | ID | 场景 | 通过条件 | 证据 |
|---|---|---|---|---|
| [x] | B3-01 | 预览、分享、重新选择 | 原生预览关闭后分享，系统保存并导入新 Artifact | v47 `completed`；新 fileId 的 988 B PDF 与原 SHA-256 相同 |
| [x] | B3-02 | 可选 OCR | Vision OCR 返回真实文本与行 locator，不代替视觉 | `Amount 42.00`、`image[0].line[1]` 等真实行 |
| [x] | B3-03 | 邮件草稿 | 只生成草稿，不自动发送 | `.eml` 哈希和正文复核通过，`sent=false` |
| [x] | B3-04 | 通讯录查询 | 权限后查询；空结果合法 | 系统权限后真实返回 `count=0/notFound=true` |
| [x] | B3-05 | 日历创建与幂等 | 原生确认；同 key 不重复创建 | `created` 后 `already_created/idempotent=true`，eventId 相同 |
| [ ] | B3-06 | 系统翻译 | 真实 Apple Translation 结果；不可用明确失败 | BLOCKED：系统能力不可用；未自行生成译文 |
| [ ] | B3-07 | 交付级 Office 转换 | 配置真实云 LibreOffice 后输出新 Artifact | BLOCKED：未配置云服务；Quick Look 不算转换 |
| [x] | B3-08 | 交互与投影恢复 | 有界交互、一次性结算、前台恢复同一会话 | 600 秒上限；预览关闭/分享完成/选择回调及最终 `Turn ended` |

本轮索引：[`docs/receipts/office-2026-10-30.json`](receipts/office-2026-10-30.json)。所有 PASS 均为当前指定 fixtures 的模拟器/主机证据，不扩张为通用 Office 保真、真机或离线承诺。

## 10. C：连接器、云任务与高级场景

| 勾选 | ID | 场景 | 通过条件 | 证据 |
|---|---|---|---|---|
| [ ] | C-01 | 连接器只读 | 只访问授权字段/记录，token 不到 Worker/JS | 测试租户与扫描 |
| [ ] | C-02 | CRM 写回确认 | diff、etag、确认、If-Match、idempotency、receipt 完整 | 写回 receipt |
| [ ] | C-03 | CRM 冲突 | etag 变化后重新预览，不自动覆盖 | 冲突样例 |
| [ ] | C-04 | Actions 适配 | run 绑定 headSHA；重复 dispatch 先对账；日志无重复缺口 | Actions receipt |
| [ ] | C-05 | 转换离机同意 | 上传前展示服务、文件、大小、页数、成本和目的地 | 确认记录 |
| [ ] | C-06 | 转换产物 | 输出新 Artifact，不覆盖原件；高保真失败不冒充预览降级 | 产物与标签 |
| [ ] | C-07 | 云 refresh | 手机离线时云端可完成；回网后 Snapshot 同步；不承诺通知必达 | 云调度 receipt |
| [ ] | C-08 | 云构建 | 精确 source/lockfile/builder digest；构建成功不自动发布 | 构建 provenance |
| [ ] | C-09 | 秘密隔离 | runner 无跨 Job/跨类型文件、网络、secret 泄漏 | 隔离测试 |
| [ ] | C-10 | 成本对账 | TaskRun/JobRef 记录 token、算力、网络和成本来源 | 成本报表 |
| [ ] | C-11 | 每日成本上限 | dailyCloudCostLimit 超限执行降频/停用/等待提额，不静默继续计费；BYOK 与免费额度可解释 | 限额与账单样例 |

## 11. 安全与合规回归

每次发布前至少执行：

- [ ] 跨 App、跨 Release、跨 Task 的 storage/Artifact/Connector 越权样例。
- [ ] DSH loopback、token、MCP 和模型路由访问尝试。
- [ ] eval、CDN、远程脚本、直接网络、路径逃逸和符号链接逃逸。
- [ ] 新闻、CRM、PDF/OOXML 内容中的 XSS 与提示注入。
- [ ] 伪造原生审批、权限 diff 绕过和旧审批重放。
- [ ] token、signed URL、私钥和敏感文档正文的日志扫描。
- [ ] 新闻来源服务条款、署名、短摘要、外链和速率限制检查。
- [ ] Apple 4.7 相关发布项复核；技术安全 PASS 不替代审核结论。

## 12. 指标记录

每个阶段同时记录：

| 维度 | 指标 |
|---|---|
| 交付 | 任务完成率、首次 Artifact 时间、分享率、引用正确率 |
| 恢复 | checkpoint 恢复率、重复外部副作用数、结果未知对账率 |
| Personal App | 发布率、再次打开率、回滚率、数据迁移成功率 |
| 自动化 | refresh 成功率、重复条目率、重复通知数、云/端调度时延 |
| Coding | clone→PR 成功率、Checks/headSHA 一致率、大仓库预检准确率 |
| 资源 | App/WebContent 内存、CPU、网络、存储、WAL/Artifact 放大比例 |
| 成本 | token、云算力、转换页数、实际/估算成本与预算偏差 |
| 安全 | 越权拦截率、秘密泄漏数、内容审核与举报处置时效 |

## 13. receipt 模板

```json
{
  "sourceCommit": "…",
  "artifactHashes": ["…"],
  "stage": "A1-04",
  "environment": "physical-iphone | simulator | macos | real-service",
  "commands": ["…"],
  "result": "PASS | FAIL | BLOCKED | NOT_RUN",
  "evidencePaths": ["…"],
  "failureClassification": null,
  "operator": "…",
  "date": "…"
}
```

任何缺少这些字段的“已通过”都只能视为未验证意见，不能进入发布结论。
