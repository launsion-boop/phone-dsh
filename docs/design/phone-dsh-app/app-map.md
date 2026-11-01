# PhoneDSH App 信息架构（App Map）

- 版本：v0.2 · 人工门①评审稿（五 Tab 动态结构）
- 对应需求：[PRD](PRD.md)
- 原型：[wireframes/index.html](wireframes/index.html)

## 1. 顶层结构

```text
PhoneDSH App
├── 首次启动默认：DSH                         #dsh
│   ├── 可新建通用任务、查看会话与产物
│   └── 不被 Personal Agent 或硬件配置阻塞
│
├── Personal Agent 首次配置                  #agent-setup
│   ├── API key / Provider / 数据路径
│   ├── Agent 名                            #agent-name
│   └── 主人称呼                            #owner-name
│
└── 主界面：动态 Dock
    ├── 1 Personal Agent Chat               #chat
    ├── 2 AI日记（配置完成后出现）            #recap
    ├── 3 DSH                               #dsh
    ├── 4 发现                              #discover
    └── 5 个人                              #personal
```

配置 Personal Agent 前，Dock 为 Chat / DSH / 发现 / 个人四格；配置完成后在 Chat 与 DSH 之间插入 AI日记。DSH 始终是独立通用执行入口，不需要 Personal Agent 解锁。

## 2. 全局元素

| 元素 | 位置 | 内容与动作 |
| --- | --- | --- |
| 本地引擎状态 | DSH、个人页顶部 | starting / running / parked / failed；进入恢复，不阻断历史 |
| Personal Agent 配置状态 | Chat 与个人页 | needsApiKey → needsNaming → ready；三处状态一致 |
| 当前对话设备 | Chat | 选择或连接当前语音输入/输出设备 |
| 当前录音来源 | AI日记 | 麦克风产品、导入音频、采集与补传状态 |
| 待确认入口 | Chat、DSH 任务、个人 Memory | 外部动作或记忆候选，不在 Dock 重复制造多个入口 |
| Mock 场景开关 | 原型顶部 | 默认、未配置、无设备、离线、引擎失败、空数据；仅用于评审 |

## 3. Personal Agent Chat（#chat）

### 未配置

```text
Personal Agent 价值说明
→ 显示 needsApiKey，不显示个性化历史
→ 主操作“配置 API key” → #agent-setup
→ 次操作“先去 DSH” → #dsh
→ 可提供当前设备连接入口，但不伪装 Agent 已工作
```

### 已配置

```text
Agent 名 + 本地引擎 + 当前设备
├── 个性化主对话
├── 当前设备与连接器快捷入口
├── Main 轻量回答与工具结果
├── 委派 DSH 的 TaskRun 卡 → #task-hardware-plan
├── 外部动作确认卡 → #approval-feishu
├── 实时 ASR 行（设备 ready 且录音中）
└── Composer：附件 / 文本 / 听写 / 发送或停止
```

规则：

- 委派后跳到 DSH 的 TaskRun，不另建一个“个人任务”权威。
- 设备快捷入口与 AI日记录音源共用设备仓库。
- 没有硬件时仍可使用文字；未配置时不能使用个性化回答。

## 4. Personal Agent 首次配置

### #agent-setup

- 选择 Tono 托管、BYOK 或自建端点。
- 显示数据路径、密钥位置和费用口径。
- BYOK key 只放 Keychain，原型不接收真实 key。
- 通过 Mock 验证后进入 #agent-name；不通过则留在当前页。

### #agent-name 与 #owner-name

- Agent 名：用于 Chat、AI日记、任务来源和通知。
- 主人称呼：用于 Personal Agent 与个人页，不代替账号登录。
- 两步都可返回修改；完成后设置 `agentConfigured=true`，AI日记出现在 Dock。

## 5. AI日记（#recap）

```text
日期导航：‹ 日历 › + 录音来源入口 → #devices
├── 当日大标题：今天 / 昨天 / 具体日期
├── 三环概览：记录时长（小时） / 对话 / 要点
├── 记录状态与录音来源：采集、暂停与补传 → #devices
├── 今日要点（可进入来龙去脉）
├── 今日 AI 日记时间线
│   ├── 对话段与原始原话
│   ├── 会议纪要卡 → #minutes-hardware-review
│   ├── Agent 工作卡 → #task-hardware-plan
│   └── 覆盖缺口说明
├── 当日总结
└── AI 内容核对提示
```

麦克风产品的连接入口放在这里，因为它回答的是“日记从哪里来”；Personal Chat 的设备入口回答的是“我现在和谁说、让谁执行”。两者使用同一设备与授权状态。

### #minutes-hardware-review

- 顶部：返回、居中会议标题、更多（复制）；下方为会议纪要 / 画板 / 逐字稿，沿用桌面客户端 `MinutesDetailView`。
- 摘要、关键决策、待办、覆盖缺口和来源引用。
- 画板按页展示时间 + 只读内容，不是另一套编辑器；点击有条目时间的笔记可定位音频。
- 逐字稿显示说话人、逐句原话和来源状态；方向与发言时长在能力接入前保持待接，不伪造测量值。
- 每条要点可跳转到原话；原话不被 AI 改写。
- 音频区固定在 Dock 上方，支持播放、±5 秒、倍速与空档说明。
- “引用到 Chat”只预填输入，不自动发起任务。

## 6. DSH（#dsh）

```text
当前 PhoneDSH 原生会话主页
├── 会话标题 + 运行状态 + 更多操作
├── 左侧会话抽屉：会话 / 定时任务 / 工作区 / 设置
├── 消息流：用户 / Assistant / 工具与 TaskRun / 确认与产物
├── 工作区与文件产物（从会话抽屉进入）
└── Composer：附件 / 文本 / 听写 / 发送或停止
```

DSH 页以当前 `ChatPage` 和 `NativeShell` 为底座，不另造任务首页：

- 首次启动显示“新会话 / 引擎还没启动”的空态；启动后可继续当前会话或直接发起复杂任务。
- 会话抽屉承载会话切换、定时任务、工作区与设置，保持现有返回路径。
- TaskRun 与 Personal Agent 委派共享，但 session/turn 归属保持 DSH 语义。
- 没有 Personal Agent 配置时也能使用全部已配置的通用能力。

## 7. 发现（#discover）

```text
搜索与分类
├── 硬件：自有 link 设备、通用小智、TonoCard、其他 BLE/LAN
├── 连接器：我的电脑、飞书、Home Assistant、Gmail 等示例
├── 服务应用：录音整理、定时任务、翻译、电话等
└── 接入状态与所需条件
```

- 统一目录，不把每个服务都变成 Dock。
- 硬件从 #devices / #pair-xiaozhi 接入。
- 未接入能力打开条件说明，不伪造 connected。
- 已接入服务可以进入对应工作页，也可以从 Chat 或 AI日记快捷使用。

## 8. 个人（#personal）

```text
不登录也可用的个人中心
├── Agent 名与主人称呼
├── Provider / API key / Credits → #settings
├── Memory → #memory
│   ├── 待确认
│   ├── 关于我
│   ├── 工作进展与待办
│   └── 来源与修订
├── 录音与隐私 → #privacy
├── 本地引擎与恢复
└── 通用设置与关于
```

Memory 不再是独立 Dock，因为它是“关于这个人和本地资料”的内容，与 Agent 配置、隐私和数据导出属于同一层。

### #memory-local-first

- 正文、类型、状态、来源和当前版本。
- 原话可回到 AI日记。
- 操作：确认、修改、驳回、归档、彻底忘记。
- 遗忘结果写实际清理范围，不写“所有副本已消失”。

## 9. 任务、审批与设备二级页

### #task-hardware-plan

- 目标与来源输入、当前状态、步骤、等待与成本。
- 审批、产物、交付回执、取消、恢复与对账。
- `outcome_unknown` 先对账，不提供盲目重试。

### #approval-feishu

- 目标、正文、数据范围、费用与后果。
- 允许一次 / 拒绝；没有默认永久授权。

### #devices 与 #pair-xiaozhi

- 已配对设备、在线状态、能力与授权、状态 revision。
- 配对流程：扫描 → 选择 → 用户确认 → 读取能力 → Ready。
- 简单控制只修改 Mock 设备状态，真实实现按 accepted/applied/outcome_unknown。

### #settings 与 #privacy

- Provider、API key、Credits、用量与本地引擎。
- 本地数据、录音状态、数据路径、导出与遗忘。
- 不展示真实 token、loopback 地址或设备 MAC。

## 10. 导航与返回规则

- 各 Dock 保留页面栈和草稿；AI日记的出现不改变当前所在 Tab。
- 跨页引用先回目标页根，再打开详情。
- 二级页返回固定到来源页；深链只导航，不执行。
- 全局设备面板与 Mock 场景开关为弹层，关闭回到原页。
- 外部动作统一使用整页确认卡，不在弹层里做不可逆操作。

## 11. 与桌面客户端的独立边界

| 借鉴 | 独立重构 |
| --- | --- |
| Dock、日记/记忆数据结构、Clean Glass、服务网格 | DSH 默认首屏、Personal Agent 渐进启用、AI日记条件出现 |
| 任务钉选与 Provider/配对代码能力（实现阶段） | DSH 与 Personal Agent 分层，不强制登录、不沿用云端 DSH |
| 三环日记、原话回跳、候选记忆与隐私 | Memory 收进个人，设备按对话/日记场景入口共用 |
| 黑白结构、灰阶状态、组件契约方法 | 独立 DomainStore、设备 SPI 与硬件开放平台体验 |
