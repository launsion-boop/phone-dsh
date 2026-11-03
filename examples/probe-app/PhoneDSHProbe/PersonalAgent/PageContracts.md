<!-- SPDX-License-Identifier: MIT -->

# S3 页面结构描述（交 S1 落盘）

## `personal-agent-chat`

- 顶栏：共享 PhoneDSH Logo 与 Agent 名组成视觉居中的设置入口，右侧保留更多菜单；DSH 仅在更多菜单。
- 跟进入口：有事项时显示“跟进中 N · 需要你处理 M”，无事项不渲染。
- 主时间线：用户/自然语言回答、单行当前状态、简短结果、来源/Artifact 展开、一个问题、失败与恢复。
- 空态：共享 Logo、友好欢迎与最多三条由真实连接器状态生成的建议；模型未配置卡有“配置模型 / 先去 DSH”。
- 候选 Memory：自然停顿处最多两行，每行“记住 / 不用”。
- 来源：自动 / GitHub / Gmail / 文件；一个紧凑来源入口显示当前选择，管理连接器由外层路由处理。
- Composer：草稿属于 `PersonalAgentModel`，保留来源、语音与发送/停止按钮；底部预留外层 Dock inset，页面 accessibility 容器不得合并或覆盖子控件。
- 禁止渲染：thinking/reasoning、bash、命令参数、原始工具输出、JSON、token、内部 ID、子 Agent 和队列技术细节。

## `personal-memory`

- 分组：待确认、关于我、工作进展、归档、遗忘。
- 每条记录：正文、个人上下文字段或类型、revision、scope。
- “为什么知道这个”：来源说明与引用、更新时间、validFrom/expiresAt、supersedes。
- 操作：候选记住/不用；active 修正（新建 revision 并 supersedes）、归档、遗忘。
- 个人字段闭集：称呼、时区、语言、回答长度、职业、关键联系人、关键仓库/邮件标签、作息。

## `personal-agent-follow-up`

- 列表：目标、是否需要处理；空态不显示技术状态。
- 详情：目标、当前结果、等待原因、最近核验时间与最近通知时间（分开）。
- 条件：检查条件、停止条件、通知策略可编辑。
- 操作：暂停到周五、结束跟进；TaskRun 仅保留引用，不复制执行状态。
