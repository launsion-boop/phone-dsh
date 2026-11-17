# iOS Bot 原计划核心交付

本轮按最早计划收口：只升级 Bot 的对话/文件/现有例程最小闭环。产品源码 `9b68ef81afc08f82b1cc95ae4fd61b55abfcc424`，tree `849c2c3655421250e85f3de30772a5513fdf302d`。后续静默控制值模板修复见 `bf1559cce`；最终候选 `fafee9052` 的产品净增量仅为两处一致的模板字符串，根依赖锁文件已恢复基线。

## 行为与范围

- 用户能在 Bot 工作时持续补充、纠正，消息立即展示并通过官方 steer 接入当前工作；修复收尾和会话重建竞态，普通聊天不隐式拒绝审批。
- 记忆读/召回带真实来源观察时间与当前状态；未知版本不伪造，stored review 是历史断言，不冒充系统事实认证；删除、撤权、恢复沿同一来源路径。
- 有界、可取消的材料检索实际进入模型请求；工具结果提供小型原始记录索引，模型自主决定查询、采用与记忆。检索、注入和采用分别记录。
- 沿既有反馈、held/would/on、maintainer 和例程执行路径，保留对象/范围/undo及停止恢复语义；maintainer 默认关闭。
- 修复恢复旧记忆时错误使用当前请求/版本的来源基线，继承被恢复版本的原始证据、信任和历史 review，并重新判断来源有效性。
- 通用文件导入使用已有持久会话，不因会话未处于 live 状态而丢失已有历史。

新增原生权限、地理围栏、云调度、图片专项、技能治理/编辑审计及新附件选择 UI 已从本轮运行接线移出。完整扩展工作保存在本地 `archive/bot-expanded-20261117-f764` 与各工作分支。原有 DSH 页面、技能编辑、SDK/pin、Android/HarmonyOS 实现保持基线。

少量 parked 设计文件不是当前功能；RoutineCloudSchedule 的保留字段仅用于旧 durable 数据解码，没有调度 caller 或功能承诺。

## 本地验收

| 验证 | 结果与边界 |
| --- | --- |
| 原 8 类 + 连续对话，真实模型 | repeat=1 最小运行 **9/9 场景、81 req**；engine 与独立 scorer 均 PASS。这是 primary minimal run，不是同 SHA 全量三轮。 |
| AHA 组合三轮（历史 + 补跑） | 除 SILENCE 外 8 场景组合 1–3 各 **3/3**；AHA-SILENCE **2/3**（run3 旧 `[安静]` FAIL 保留）。3 轮合计 **248 req**；run1 为 `10b38870b` overlay，**不等同同一最终 SHA 三轮**。 |
| SILENCE bf1559 定向 | **3/3 PASS**（14/13/14 req，quiet=true 断言均过）+ 变化分支 **1 PASS**（6 req，初始 CHANGED_V2，quiet=false，无 `[quiet]`）；旧 SILENCE 2/3 保留，不冒充同 SHA 全量三轮。 |
| 压缩后复用 | 原始 SDK session 日志存在 6 次 compaction/summary 与 6 个 compact-checkpoint；记忆引用实际指向用户要求及读取规范的工具结果，root 已核查。 |
| Bot Swift 回归 | 1,223 executed / 2 skipped / 0 failures。跳过项分别需要独立维护证据环境及 HTTP loopback 环境，未把跳过计为通过。 |
| 记忆恢复/抹除 | 两个原失败方法 2/2；独立相关回归 8/8。 |
| Worker/工具面/导入/身份 | Node 21/21 + 69/69。 |
| 维护质量 | 已有四批真实样例：矛盾修正 2/2、过期修正 2/2；原始引用及独立 judge 已复核。仅代表这些样例，默认 off。 |
| 真实模拟器文本联调 | PASS：新建决策简报，工作中接纳预算/时长变更，随后追问产物与来源。用户纠正 seq396 在 turn15 结束 seq446 前 15.536 秒进入；交付物采用 46 万/60 分钟，保留文件旧值 48 万/45 分钟，报价 v2 继续待确认。 |
| iOS App | build-for-testing 成功；App 内外 Worker image hash 一致，root 核对签名与交付目录中的 xctestrun 路径。构建不代表真机通过。 |

[逐场景原始报告与独立评分](evidence/bot-core-20261117/aha-report.md) · [三轮组合表](evidence/bot-core-20261117/repeat2/table.json) · [SILENCE bf1559 报告](evidence/bot-core-20261117/silence-bf1559/silence-report.json) · [变化分支报告](evidence/bot-core-20261117/silence-bf1559/changed-report.json) · [源码/产物/测试收据](evidence/bot-core-20261117/source-receipt.json) · [XCTest 结果行](evidence/bot-core-20261117/swift-test-results.txt) · [SHA-256 清单](evidence/bot-core-20261117/SHA256SUMS.txt)

真实模型使用 core `10b38870b` 的 host 与 Worker `601a5ef4…`。后续生产变化只有 restore 分支：这批实际捕获的 12 次 UpdateMemory 调用没有 restore；restore 已另行验证。构建源 `c2bf96de1` 与交付 `9b68ef81` 在 Sources/plugins/examples/Package 文件零差异，该阶段后续只是测试/规范记录；静默模板变更另有下述定向证据。

## 诚实边界

- CI 按用户要求延期，未宣称 CI 全绿。
- 真机、电量/后台与两周观察不属于最早计划本轮范围；未将模拟器结果外推为这些结果。
- 历史 repeat=3 的失败保留；当前 core 的三轮证据是“8/9 场景 3/3 + SILENCE 2/3”，另加 bf1559 定向 3/3 + 变化 1 PASS；**不是同一最终 SHA 的全量三轮**，不签 3/3 全 PASS，PR 保留 Draft，不合并、不部署。
- 原计划核心范围已完成本地验收；[模拟器文本验收收据](evidence/bot-core-20261117/simulator-text/receipt.json)、[可见消息和回合证据](evidence/bot-core-20261117/simulator-text/visible-events.json)、[Bot 实际新交付物](evidence/bot-core-20261117/simulator-text/decision-brief.md) 可回查。App 实际模型为 deepseek-flash / high；编排用本机 DSH worker / max，两者不混写。
- 旧入口测试选错页面、全量回显断言失败，以及重启后未尝试新消息，都不能证明 Bot 无法接纳消息。未经真实复现的恢复补丁已撤回；不把旧测试重新标为通过。调试 App 的动态库搜索路径已指向冻结包内 framework，避免加载另一轮构建；只核 App 可执行文件 hash 不足以证明运行源码。
- 简报中部分责任人和影响建议属于模型推断；本次验收证明消息接纳、产物更新和关键来源区分，不将整篇建议提升为事实认证。
- SILENCE bf1559 的模板消歧已验收（3/3 + 变化 1 PASS）；仅代表该定向场景。
- 第二套 FA-D02 未触发压缩的运行保留为未满足测试前提；不以其替代本表已发生真实压缩的 AHA 证据。
- 通过这些场景不代表任意模型输出均无错误。历史初稿出现的无依据推断仍作为质量观察保留；可回查引用不自动证明每句话成立。
- 没有为 OWNER、周报或随机标记增加产品特判；无证明收益的提示增量已撤回。

Protocol impact: P09; P16; P20; P24; P25; P26; P27
