# PhoneDSH App 产品需求文档（PRD）

- 版本：v0.2 · 人工门①评审稿（五 Tab 动态结构）
- 日期：2026-10-30
- 产品：独立的 PhoneDSH iPhone App
- 产品基线：[PDSH 手机端 Harness 开放平台规划](../../../../TonoWiki/briefs/2026-10-29-pdsh-open-platform-architecture.md)
- 交互参考：桌面客户端当前工作树的 Dock、AI日记、Memory、任务和 Clean Glass；仅借鉴代码与能力，不继承其产品定位
- 当前阶段：PRD → 交互架构 → DESIGN → 黑白低保真；未进入高保真和生产实现

## 1. 产品定义

PhoneDSH 是运行在用户手机上的**通用 Agent 执行平台、个人 Agent 与硬件接入平台**：

> DSH 提供开箱即用的通用执行能力；Personal Agent 在用户完成模型配置和首次命名后，提供有个性的轻量交互、个人记忆和持续录音整理。硬件作为感知与执行终端接入，任务、证据、日记和记忆统一保存在手机本地。

它不是：

- 桌面客户端的换皮或云端控制台；
- 必须先登录才能使用的模型账号体系；
- 只有 Personal Agent 一个聊天入口的 AI 伴侣；
- 把每次输入都交给 DSH 的重型 coding 终端；
- 要求每台硬件单独部署云 DSH 的配套工具。

首版形态是：**一个独立宿主 App、DSH 通用执行底座、可渐进启用的 Personal Agent、五格动态底部导航，以及可选云端推理与 Credits。**

## 2. 目标用户与核心问题

### 2.1 首批用户

先给团队自己及自有硬件使用，随后开放给：

- 拥有自有 link 设备、通用小智、TonoCard 或兼容 BLE/LAN 设备的用户；
- 希望硬件能完成真实任务，而不只进行 LLM/ASR/TTS 问答的用户；
- 重视本地资料、可替换模型 Provider、无需维护电脑或云账号的个人用户。

### 2.2 核心问题

1. 用户想直接使用通用 Agent，却常被迫先完成账号、硬件和个性化配置。
2. Personal Agent 需要个性、记忆与持续录音，但这些能力不应阻塞通用 DSH。
3. 很多硬件只有语音输入输出，缺少任务执行、恢复和长期记忆。
4. 设备、连接器、服务应用和设置容易分散，形成多套重复入口。
5. Agent 的执行过程、权限和真实结果不透明。

## 3. 产品原则

### 3.1 DSH 先用，Personal Agent 渐进启用

- 首次启动默认进入 DSH，直接展示通用任务、会话、工作区与产物。
- Personal Agent 的独立 Chat 先提示配置 API key，不伪装已经可用。
- key 配置有效后进入首次命名：Agent 名 → 主人称呼 → 完成。
- 完成 Personal Agent 配置后，Dock 才增加 AI日记。
- 无硬件、无账号也能使用；硬件配对可以稍后完成。

### 3.2 Personal Agent 与 DSH 分工明确

- Personal Agent：轻量、连续、个性化的主对话，使用个人记忆、当前设备和连接器，必要时委派 DSH。
- DSH：通用、直接的任务执行工作台，包含新建任务、TaskRun、会话、工作区、文件与执行记录。
- 二者共享本地证据、任务引用和产物，但不把 Personal Agent 的对话历史等同于 DSH session 日志。

### 3.3 设备按场景进入，状态只有一份

- Personal Chat 可连接当前对话的输入/输出设备。
- AI日记可连接麦克风产品、导入录音并管理采集来源。
- 发现统一收纳硬件、连接器和服务应用。
- 以上入口都打开同一设备与授权仓库，不重复配对、不伪造多个 connected 状态。

### 3.4 任务、证据和结果优先

- 任务状态、当前步骤、等待原因和实际产物始终可见。
- 设备命令区分 accepted/applied/failed/outcome_unknown。
- 外部发送必须预览、确认和对账。
- AI 整理内容可回到原话、原文件或执行记录。

### 3.5 本地数据不等于本地推理

长期资料默认保存在本机；使用云模型时明确本次数据去往哪个 Provider。不得把“本地 Harness”写成“所有数据完全不离机”。

## 4. 五 Tab 动态结构

| 顺序 | 名称 | 何时出现 | 首要职责 |
| --- | --- | --- | --- |
| 1 | Personal Agent Chat | 始终显示；未配置时显示配置引导 | 个性化主对话、当前设备、连接器快捷入口、轻量回答与 DSH 委派 |
| 2 | AI日记 | Personal Agent 配置完成后出现 | 录音来源、按天回顾、会议纪要、Agent 工作、原话与覆盖缺口 |
| 3 | DSH | 始终显示，且是首次启动默认页 | 沿用当前 PhoneDSH 原生会话主页：会话抽屉、消息流、TaskRun、工作区、文件和产物 |
| 4 | 发现 | 始终显示 | 硬件、连接器和服务应用的统一目录与接入入口 |
| 5 | 个人 | 始终显示，不登录也可用 | API key、个人命名、Memory、Provider/Credits、隐私与设置 |

未配置 Personal Agent 时，Dock 为 Chat / DSH / 发现 / 个人四格；配置完成后在 Chat 与 DSH 之间插入 AI日记，形成五格。

## 5. 首版核心场景

### P0-A：首次启动先看到 DSH

1. 用户打开 App，直接进入当前 PhoneDSH 原生会话主页，而不是欢迎页、登录页或另建一个任务列表。
2. 首次看到“新会话”与“引擎还没启动”的真实空态，可启动引擎或从会话抽屉进入其他会话、定时任务、工作区和文件。
3. Personal Agent Chat 显示“配置后开启你的个人 Agent”。
4. 用户可先使用 DSH，稍后再配置 Personal Agent。

完成标准：Personal Agent 未配置不阻塞当前 DSH 会话主页与通用任务入口。

### P0-B：API key → 首次命名 → AI日记出现

1. 在 Personal Agent Chat 或个人页选择 Tono 托管、BYOK 或自建端点。
2. 显示模型路径与密钥位置；BYOK key 只放 Keychain，不上传 Tono。
3. Mock 验证通过后，依次输入 Agent 名和主人称呼。
4. 完成后进入 Personal Agent Chat，AI日记同时出现在 Dock。

完成标准：配置前有明确 locked 状态，配置后全局使用同一 Agent 名；AI日记的出现时机一致。

### P0-C：从一句话到任务与产物

1. 用户输入“把今天的硬件接入评审整理成纪要，提取待办并保存到本地”。
2. Personal Agent 判断需要深执行，出现 TaskRun；也可在 DSH 直接发起同类任务。
3. 用户查看步骤、等待、取消、恢复和实际产物。
4. 完成后结果进入 AI日记；原 TaskRun 与 DSH 执行记录仍可查。

完成标准：Personal Chat、DSH 任务详情和 AI日记展示同一个 TaskRun，不形成三套状态。

### P0-D：BLE 硬件获得 Agent 能力

1. 从 Personal Chat、AI日记或发现进入设备接入。
2. 核对设备后在配对窗口内确认授权，读取真实能力。
3. 麦克风设备可作为 AI日记录音源；对话设备可作为 Personal Chat 输入/输出。
4. 反向控制按设备回执更新；断线先对账。

完成标准：不需要云账号或电脑；各入口共用同一设备与授权状态。

### P0-E：录音沉淀为 AI日记和 Memory

1. 实时或导入音频只经过统一 TranscriptionCoordinator 转写一次。
2. 同一份 FINAL 分别供 Main、Recap 和 Memory 使用。
3. AI日记按天呈现要点、会议和 Agent 工作；纪要可回到原话。
4. 自动产生的记忆先进入个人页的待确认，确认后才用于后续回答。

完成标准：一句话只有一份证据、一份转写、一条 Main 输入和一组记忆候选，不重复 ASR、不自触发。

### P0-F：外部动作先确认

1. Agent 准备发送飞书消息或执行其他外部动作。
2. 确认卡显示目标、正文、数据范围、费用和后果。
3. 用户允许一次后才提交；拒绝不产生外部副作用。
4. 结果不明时先对账，不自动重试。

完成标准：没有“允许”就没有发送；结果区明确区分模拟/真实回执。

### P0-G：个人与 Memory 可控

- 不登录也可修改 Agent 名、主人称呼和 Provider。
- 搜索并查看 Memory 内容、来源、状态和修订历史。
- 确认、修改、驳回、归档、彻底忘记。
- 可导出本地数据，可管理录音与隐私策略。

## 6. 关键状态与真实性要求

| 对象 | 界面必须区分 | 禁止 |
| --- | --- | --- |
| Personal Agent | needsApiKey / needsNaming / ready | 未配置就显示个性化回答或 AI日记 |
| 本地引擎 | starting / running / parked / failed / unavailable | 进程存在就写“任务仍在执行” |
| DSH 任务 | queued / running / waitingApproval / completed / failed / cancelled / outcomeUnknown | turn 结束直接写“已完成” |
| 设备 | unpaired / scanning / pairing / ready / offline / denied | 手机发送成功写成设备已执行 |
| 日记 | collecting / processing / partial / complete / failed | 材料缺失时显示“这一天没有内容” |
| Memory | candidate / active / rejected / archived / forgotten / withheld | 候选直接当长期事实；遗忘写成所有副本已删除 |
| 云推理 | Tono 托管 / BYOK / 自建、可用/不可用、用量未知 | 无 usage 时写精确费用；流式等于零留存 |

所有原型中的执行任务、配对、发送、导出均显式标注 Mock，不能冒充真实后端结果。

## 7. 数据与隐私需求

- 原始证据、转写、Main 过程、任务引用和 Memory 均指向同一个本地 DomainStore。
- DSH workspace 只承担执行工作区和恢复，不作为长期记忆库。
- 原始音频/文件与可重建索引分开；索引可以删除重建。
- OAuth 和 BYOK 密钥只进入 Keychain，不进入 Worker、原型、日志或截图。
- 托管推理只显示必要的本次内容路径；Credits 只保存计量元数据。
- 后台只承诺 checkpoint 和可恢复，不承诺无限 CPU 或永久监听。

## 8. 首版不做

- 强制登录、多账号、多用户协作和公开服务市场。
- 全双工 AI 通话、通用电话控制、任意跨 App RPA。
- 通用第三方 MCP server 接入和任意 URL 工具代理。
- 复杂人物关系图、自动冲突合并、空间声场和跨项目权限。
- 全量 Gmail/飞书/Slack/微信/米家连接器；首版只保留目录和少量示例。
- 高保真品牌资产、动态代码生成或生产 SwiftUI 实现（均在后续人工门之后）。

## 9. 原型验收标准

人工门①需要确认：

1. 首次启动是否以 DSH 为主，而不是被 Personal Agent 配置或硬件阻塞。
2. API key → 首次命名 → AI日记出现的流程是否自然、可理解。
3. Personal Agent、DSH、AI日记与 Memory 的数据关系是否一致。
4. 发现、场景设备入口和个人设置是否避免重复与跳转混乱。
5. BLE 配对、能力授权、反向控制和断线回执路径完整。
6. 每屏都有可理解的空、加载、离线/未连接、失败/受阻状态及下一步。
7. 黑白稿能判断结构、密度、术语和导航，不依赖颜色或装饰。
8. 所有 Mock 状态明确可见，没有伪造真实执行结果。

通过后依次进行：高保真 HTML → Playwright 2–4 轮评审 → 人工门② → SwiftUI 实现 → 原型与实现截图 diff。
