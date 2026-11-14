# Bot 活动内容：依据、投影与轮换

本次范围：为 iOS 单行活动 UI 提供真实、具体的内容。源码诊断基于 main 203c29bcb；后续 main 合入的 Android #170 未在这轮重新审计，下面 Android 条目仅作为该基线上的研究记录。银灰动效在 PR #171 单独实现；本研究及实验不把更多卡片、日志或额外说明塞回顶部。

## 结论

需要改变活动信息的产生与生命周期，而非给「思考中」增加更多同义句。

1. 以工具调用/结果和真实回合状态作为依据；模型只在语义允许的字段里提供短动作目的。
2. 以 callId 跟踪在途调用，不让最新调用的结束抹掉其他仍在进行的工作。
3. 文案随依据变化更新；一个动作持续执行时维持具体动作，让银灰动效表达“仍活跃”。不要每 2.4 秒凭空换一种工作描述。
4. 没有具体依据时如实说明等待响应；不能把模型请求、工具请求、返回结果、业务成功混成一件事。

## Grok 原版证据与限制

检查的是本机 `grokbot-reverse/extracted/app` 的 Grok Bot 0.78.4 归档；其中 `dsh-go/` 是旧 clone，不作为原版行为依据，也未修改归档。

原版 renderer `dist/renderer/assets/index.eager-app-7tsTMhdH.js` 是压缩文件，以下为字符偏移与函数符号：

| 符号 / 偏移 | 直接观察 |
| --- | --- |
| `dpn` / 3121922 | tool name 去掉 ToolCall 后缀、拆驼峰，生成标签 |
| `fpn` / 3122108 | tool-call 的标题来自 `dpn(t.name)` |
| `ppn` / 紧随 fpn | `status=pending` 用 loading；failed 用 x-circle；否则 wrench |
| `hpn` / 3122931 | tool-call 摘要来自 `summary`；不存在则空 |
| `s4` / 紧随 ppn | 摘要 trim，取第一行并截断 |
| `gpn` / 3123235 | tool-call 的展开详情同样读取 `summary` |
| `vpn` / 3123930 | 活动行消费这些选择器及 pending 状态 |

**可核实的是 name + summary + status 的显示契约。summary 由模型、工具还是服务端模板生成，客户端归档不能证明。** 没有找到能证明其文案质量和更新频率的真实 tool-call JSON 样本。`analysis/agent-harness.md` 的工具执行字段说明了 Shell/ComputerUse 有 description，但不能据此断言它就是 transcript.summary。

## Phone DSH 当前链路与问题

现有链路是 DSH session events / assistant stream → Bot channel → 原生 Driver → ChatModel / RuntimePresentation → BotActivity → ActivityLineState → 单行 UI。UI 已拿到不少真实依据，丢失主要发生在投影和文案选择。

| 位置 | 当前行为 | 影响 |
| --- | --- | --- |
| iOS `BotActivityPhrases.rotationPhrases` | 空 detail 时，thinking/reviewing/replying/generic 每 2.4s 轮换固定句 | “整理思绪”“马上就好”不是新进展；后者还是无依据的时间承诺 |
| `toolActivity` / `modelText` | 所有工具的 description/summary/label 都优先显示 | 文档摘要、队友介绍等业务字段被误当作活动摘要 |
| persona 的 description 指令 | 将 CreateTeammate.description 也要求写成 14 字动作 | 它实际是队友描述，存在语义污染风险；不能把所有 description 都改成状态文案 |
| iOS `BotRuntimePresentationFactory.activity` | lastCall / lastStep / lastStream 判定 | 忽略较早仍未完成的并发调用；新 step 清掉具体动作 |
| iOS `matchingResult` | callId 或 resultId 任一缺失就接受匹配 | 多个在途调用时可能错误关闭另一项 |
| Android `BotChatModel.receive` | tool arguments 直接按对象读取；step/start 设成 REPLYING | 原始 JSON 字符串参数可能丢失/报错；“开始模型步骤”被误说成“正在回复” |
| Android `AppBotChatDriver` | turn/start 设为 REPLYING；tool/call 的 detail 使用原始工具名；缺 tool/result 分支 | 生产 presentation 与 UI live projection 不一致，重新进入页面可能显示内部名或过期动作 |

上述 Android 问题为源码定位，需真实输入回归证明，不能当作已经做过真机复现。

DSH 基线 `plugins/dsh-pin.json` 为 `66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db` / `0.2.2-rc.1`。已检查同版本安装包的 session 类型：

- `step/start` 只有 turn/step，表示一次模型调用及其工具执行的步骤开始，不等于回复开始。
- `tool/call.arguments` 是模型原始 JSON **字符串**；callId 用于配对。
- `tool/result.message` 是模型可见结果；error 与 tool-private meta 可选。收到结果不自动等于用户目标已验证成功。
- 工具请求事件不等于设备执行回执；审批、取消与最终结果的原有边界必须保留。

## 最小改造

### 1. 明确活动文案来源

优先级为：等待授权/错误 → 有依据的当前工具动作 → 实际回复流 → 明确的等待状态。

- bash.description：只作当前命令意图的简短可读说明，不复制 command。
- Task：短任务标题/description 与执行 prompt 分开；不把长指令直接截成状态。
- read/write/edit：动作 + 文件名；web_fetch：动作 + 域名；search：动作 + 有界查询；记忆、例行任务、队友操作按各自真实参数选择安全对象。
- 不把 show_document.summary、CreateTeammate.description 等业务数据当作活动说明。未知工具不显示内部 wire 名称，也不猜测动作。
- 不读取 raw reasoning 来拼活动提示，不新加一次模型请求来替每个 token 生成状态，不给不支持的工具强塞 description 参数。

### 2. 维护真实在途状态

在 turn/session 边界内维护可见 callId 集合，按事件序更新。

- A、B 并发：B 先结束后仍显示 A，不能退回空泛思考。
- 只有匹配结果才结束调用；缺 ID 且存在多个候选时保持未知，不随便匹配。
- FishAction 等隐藏工具不遮掉真正工作。
- step/start 不取消未结调用；turn/end/stop/session 切换清除对应生命周期。
- 返回结果后只表达“收到结果/处理返回结果”，不能仅凭非空输出宣布成功。
- 模型回复流、等待授权和后台任务需有明确优先级，不能靠最后一条事件覆盖全部状态。

### 3. 只在有依据时更新内容

保留最小显示窗口防抖；单个动作不再轮换同义句。若未来要多个并发任务轮播，只在真实仍活跃的候选中轮播，必须有身份、时间和终结条件；本轮先验证“最新仍在途动作”策略，避免为了动感新增 schema/通道。

例子：

| 依据 | 单行内容示例 |
| --- | --- |
| read 的真实路径 | 读取相关资料 |
| bash 的有效动作说明 | 检查卡片布局测试 |
| fetch 的真实 URL | 查看网页内容 |
| B 返回，A 仍在途 | 回到 A 的真实动作 |
| 没有工具且模型请求仍等待 | 等待响应 |
| 真正 text delta 到达 | 正在回复 |
| 审批 pending | 等你确认 |

## 实验与交付边界

最小实现位于独立 `feat/bot-activity-evidence-20261114` 分支。根据用户后续指示，主 agent 接手并完成 iOS 实现；Android 探索补丁单独保存，不进入本次 PR。iOS 专属规范和 53 个事件向量位于 `spec/ui/v1/bot/ios/`，共享旧短语表和 Android 客户端保持原样。

验收至少覆盖：string/object args、串行成功与错误、并发逆序完成、未知/缺失 resultId、新 step 仍有调用、隐藏工具、回复流、等待授权、取消/结束、业务 description 误用、长文与敏感目标。相关协议/生成数据必须同步，不能只改 UI 文案。

实时模型、真实设备和后台异步任务持续状态，未执行前一律 NOT_RUN。Grok 服务端 summary 的生成机制仍为未知；不以仿制应用或 UI 观感充当证据。

## 本轮实际验证

- iOS 35 项逻辑测试 PASS，其中一项逐条驱动真实 factory 验证 53 个事件向量。另测试真实展示入口的审批/停止/回复优先级与稳定文案。
- iOS 采集 App 构建、四类活动场景浅深色 8 张截图 PASS（模拟事件驱动，不是真实 LLM 会话）。
- 中英文 persona 回归 8 项 PASS；生成 Worker profile 与源提示词保持一致。
- 跨树不变量 8/8、protocol-impact、diff whitespace PASS。
- shared Bot UI checker 保留 FAIL：未改动的 `BotChatPage.swift` 与既有 `strings.json[chat.drawer.open]` 的来源行号不符。本轮仅更新自身改动引起的 BotChatModel 来源行号，不删除断言。
- 真机、真实模型/设备执行、部署 Worker 镜像 NOT_RUN。客户端不能凭 UI 文案证明业务完成。

复现逻辑回归：先 `xcodegen generate --spec scripts/ci/bot-activity-evidence/project.yml`，再运行生成项目的 `BotActivityEvidenceTests` scheme（iOS Simulator）。这个逻辑专用 target 直接编译产品 projection/phrase/presence 源文件，避免完整 BotE2E target 对 Worker bundle 和 UI host 的额外依赖。

## 后续语音播报的文案收敛

根据用户补充，活动 detail 优先是 8–14 字的自然短句，不再带文件名、路径、扩展名、网址或内部 ID。短的真实查询主题可以保留，例如 query 为“北京天气”时显示“查询北京天气”；技术查询、过长意图或代码样式文字退回真实操作类型对应的短句，而不是截成省略号。结果提示按真实返回事件显示“已收到读取结果”等，不等同于业务成功。此轮没有接入 TTS；未来应消费稳定 detail 并做语义去重，不消费动画帧或显示层耗时后缀。
