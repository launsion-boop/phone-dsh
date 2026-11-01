# 会话线 parity 收口状态

> 基线：`deepseek-harness 7be5505b0b`（0.2.1-rc.2），402×874pt。
> 口径：**“第一版”= 有真实代码、编译通过、能覆盖主路径；不等于官方逐像素/全状态验收。**
> 官方 golden：见 [GOLDEN.md](GOLDEN.md)。已拿到 9 张（hero/auth/session chat/long/tool/question/plan/subagent×2）；turn-trigger 在 subagent 图内已覆盖；pending 提问/Plan review/官方深色仍缺。

## 1. 状态矩阵

| 面 | 状态 | 已落地 | 仍缺 |
|---|---|---|---|
| 事件/投影数据 | 第一版 | goal/title 路径修复；tool meta/error；projection 快照；inbox 分类；compaction；imageLimits；agentPreset | 66 事件全覆盖仍有长尾；部分 projection 未消费 |
| 计划/Todo | 第一版 | TodoDock、PlanChip、PlanReview、PlanCard、`exit_plan_mode` 卡 | 完整 plan 审批通道（ASK_CANCELLED）；查看全文交互 |
| 提问 | 第一版 | QuestionComposer 接管、分页/多选/自定义、QuestionReply、AskCard | 计时等待/草稿持久化/迟到回答结构化解析 |
| 子 Agent | 第一版 | 官方 402pt 已验：头部 `1/2 个子智能体` 计数、subagent 行/调用结果/child id/turn-trigger；iOS 按产品要求把入口收进 more 菜单 | 目录树懒加载、侧栏打开、运行态细节；iOS 无头部计数 chip（产品决策） |
| 设置/手机权限 | 第一版 | Settings 改为 4 tab：通用/工具/手机权限/关于；手机权限整页嵌入（无 X/无 intro）；PR11 `PhonePermissionsPage`/Requester/Store/23 能力/Info.plist 已接；`PhoneCapabilityBridge` + `CompositePhoneToolBridge` 已注入 `PDSHShellProvider`，Agent 可消费获授权能力 | 设置页仍以 iOS 版为准；真机逐个系统弹窗未验；folder grant 仍用轻量路径持久化 |
| Device 固定会话 | 第一版 | PR12 `DeviceSessionCoordinator/DeviceSessionMapping/ReadOnlyDeviceSessionTransport` 已接；normal list 过滤 mapping、普通入口拒绝；Device transcript 新增 user/device 来源区分（人工消息右侧、设备消息左侧“设备”气泡） | connector factory 仍 nil；device-origin prompt (`HarnessCommand.prompt.origin`) 未实现，真实设备写入/运行态未验 |
| Turn 时间线 | 第一版 | 控制行、history facts、折叠、turn tail、默认 completion-time 折叠 | `On next message` 已接（页头菜单 + 聊天外观页 + NativeChatPreferences）；最新 exchange 细节；折叠动画 |
| 过程组 | 第一版 | reasoning+工具分组、14 类标题、150ms、400/50vh、条件渐隐；组头 24 行盒 + 8 展开、body 6 flow | 组头 hover/crossfade 细节；与官方滚动锚点 |
| 工具卡 | 第一版 | 54 key 标题表、37 key details 路由、Ask/Subagent 专用行 | bash/read/search/diff 旧卡 chrome 未统一；PTC/subcall/多卡细节 |
| 内容/动作 | 第一版 | 14/24、用户气泡、turn trigger、turn tail；PR11 字体/段落 20/行距按 24 行动态/列表 10/表格自适应已融合 | 图片查看器/脚注/代码复制等长尾 |
| Composer | 第一版 | 338/370/98/28、16pt 输入、独立 pending、键盘发送；本地化命令表/别名/附件拒绝、单一压缩 marker、合并队列 + 单条晋升、UITextView Return/⌘Return/ShiftReturn/Esc/菜单键 | 命令菜单仍是 in-flow 非 anchored overlay；live compaction 无数；queue rpcId 去重缺；⌘Enter 批量 steer 缺 |
| 页头 | 第一版 | 50pt、标题居中、无轨迹 tab、左抽屉、右侧 Device + more（…）；子 Agent/后台任务/定时任务/产物/导出/运行状态/设置/折叠时机/preset 全在菜单；运行中 loading 收进 more | open-in-app = N/A（D-01）；面包屑；D-02 sheet 适配 |
| 深色/Dynamic Type | 第一版设置 | 聊天外观页；深色 session + 设置/文件/搜索/模型/插件/计划页；sessions drawer/SessionsPage 也已切深色；`darkpass-*` + `darkfinal-*` 证据；AX3 设置页验证 | 固定 402pt chrome 未做 AX 缩放；行 title/value 未堆叠 |
| 官方 golden | **9 张：hero/auth/3 chat/tool/question/plan/subagent×2** | 官方 402×874@3；工具会话含 assistant-step + tool-call + bash 卡；question 已作答卡、plan approved PlanCard、subagent 含头部计数 + subagent 行 + turn-trigger（真实 fixture 播种）；`capture-official.sh` 可复现 | pending 提问/Plan review、官方深色、多工具矩阵仍缺 |

## 2. 已完成的可验证证据

- `swift build --target PhoneDSHAgentCore` ✅
- `xcodegen generate` + `xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` ✅
- 官方 402pt：`official-hero-sessionless`、`official-auth-gate`、`official-session-chat`、`official-session-chat-long-user-turn`、`official-session-chat-tool`、`official-session-question`、`official-session-plan`、`official-session-subagent`、`official-session-subagent-parallel`（均 1206×2622）
- iOS 402pt 自检：`screens/current/sample-chat.png`（浅色）、`sample-chat-dark.png`（深色）、`chat.draft-chat.png` / `chat.queued-chat.png`（composer/队列）、`darkpass-*.png` + `darkfinal-*.png`（设置/文件/drawer/Sessions 深色与 AX3）+ `settings.runtime-chat.png`（runtime 深色）+ `settings-chat.png` / `settings.permissions-chat.png`（设置/手机权限）
- 官方 golden 脚本：`scripts/ios-parity/golden/capture-official.sh`
- iOS 自检脚本：`scripts/ios-parity/capture.sh`
- 静态审计：`scripts/ios-parity/audit.py` + `parity/coverage.md`
- 新增 32 个 Swift 文件；修改 18+ 个（详见 `10-wave0-implementation.md`）

## 3. 明确不做的“假 parity”

- `open-in-app`：iOS 无宿主外部打开；不伪造入口。
- `sidebar-right`：iOS 无右侧栏；用 sheet 属适配，不称官方一致。
- 细节行盒/行距验收：[DETAIL_AUDIT.md](DETAIL_AUDIT.md)。
- 无官方 golden 时，不宣称逐像素一致。

## 4. 收口后的下一步（按价值）

1. **官方 402pt golden**：9 张已拿到（含 subagent/turn-trigger）；pending 提问/Plan review/官方深色仍需 live/fixture。
2. **Composer**：命令/压缩/队列/键盘已接；剩余 in-flow menu、live counts、rpcId 去重、批量 steer。
3. **`On next message`**：已接（more + 聊天外观页）。
4. **深色/Dynamic Type**：主要页面 + drawer/Sessions 已接；固定 chrome 未做 AX。

## 5. 变更记录

- 本轮收口计划：[CLOSEOUT_PLAN.md](CLOSEOUT_PLAN.md)
- 平台决策：[DECISIONS.md](DECISIONS.md)
- 实施回执：[10-wave0-implementation.md](10-wave0-implementation.md)
- Golden 状态：[GOLDEN.md](GOLDEN.md)
