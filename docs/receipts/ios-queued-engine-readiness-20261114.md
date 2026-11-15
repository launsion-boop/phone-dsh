<!-- SPDX-License-Identifier: MIT -->
# iOS 本地接单与引擎恢复实现记录

Base: `29a733cb8f8f764e27629b5e126fcf572b042168`。
架构来源：[PR #180](https://github.com/launsion-boop/phone-dsh/pull/180)。
契约：[本次变更单](../protocol-changes/PC-20261114-ios-queued-engine-readiness.md)。

## 要解决的问题和场景

1. 已有 Host 对象不代表引擎可执行。引擎 parked 后收到消息，原队列准备路径只等
   `parked == false`，没有主动走已有 resume；冷 Host 的重放也依赖其他启动事件。
2. 用户离开 App 后回来、恢复进程或同时发送多条消息，持久队列需要统一准备入口，
   不能每条消息各自 boot，也不能在后台启动被禁止时虚假承诺执行。
3. 蓝牙唤醒之后，ASR 和解锁都会耗时。原实现到识别完成才读取“当前会话”，中途
   切换会话会改变投递目标；语音确认也早于持久接收。
4. 原语音按文本包含关系查找用户消息，再取后面的最后一条回复。相同文本、多个
   排队任务或切换会话会导致错误关联；全局 `turnRunning` 也不能证明自己的任务完成。
5. 首次本地发送绕过持久队列；手动重试曾把未知提交结果直接改为 queued。

## 实现

- 复用现有 SendOutbox，不新增第二套执行账本或数据库。所有被接受的本地发送都
  在传输前持久化。首次 UI 发送先在前台建立会话；没有目标/可用受保护存储时不接单。
- 一个 `recoveryFlushTask` 合并队列准备请求；判断 ready/start/resume/wait/deferred/
  needsAttention，再调用已有 ChatModel/Host 方法。保留手动停止、失败退避与恢复提示。
- 进前台即使 Host 为 nil 也重新检查队列。准备期间新来的消息有后续 drain；阻塞的
  附件和其他会话不会形成空转重试。后台只有既有 ready 且有执行资格的 Host 可投递。
- TonoLink 在 wake 时固定本地 DSH 会话和 UUIDv4。识别成功后使用该 ID durable enqueue，
  成功才说“好的，已经记下了”。取消录音不创建任务；接单后新 wake 只停止旧语音等待，
  不偷偷取消/重发已接单任务。
- 播报依据精确 rpcId、权威 user/message、同一 turn 的 settled assistant 和 completed
  终态。turn 通过有序 turn/start/end 事实关联，不假设 user/message 自带 turn 字段。
  切换会话、失败、缺失归属、超时均停止播报等待，不拿其他回复代替。
- 提交结果未知时保留原 ID 并回读；不因用户重试盲目重发。只有当前发送者能确认尚未
  调用传输时，才允许在生命周期变化后把消息退回 queued；崩溃恢复不能复用这个证明。

## 驻留与架构阶段边界

代码中没有“空闲 30 分钟销毁引擎”的统一 TTL。本次保留前台已就绪引擎的现有待命行为，
没有删除运行中回合的 1800 秒无事件 watchdog，也没有延长 BLE 授权窗口。
后台没有需求仍可 park；系统不授予执行时间时等待恢复，不用永久静音音频扩大保活。

| 架构阶段 | 本 PR 的实际交付 |
| --- | --- |
| R0 观测 | 加入准备/等待及 voice admitted/request 诊断；30/60 分钟真机资源基线 NOT_RUN |
| R1 原生准入 | 当前本地 DSH/TonoLink 复用真实 SendOutbox；通用跨来源/账户准入表、TTL/容量/外部源去重未实现，不把这轮称为完整 R1 |
| R2 生命周期 | 实现合并准备、前台恢复、后台约束和停止门禁；全组合真机竞态仍待验证 |
| R3 设备 | 修复现有 TonoLink → DSH 目标和结果关联；指定 Bot 的配置/路由及实体板完整验收尚未实现 |
| R4 服务端/APNs | DEFERRED_BY_USER：用户明确“未来会做”；不加空接口、token 或 entitlement |
| R5 待命调优 | 沿用已有策略；没有测量结果，不宣称零耗电或永久后台在线 |

Bot 现有 nonce/effect 持久账本保持原状。本 PR 不把不可信设备任务伪装成 ownerDirect
Bot action，也没有启用仍为 target 的 BLE secure task session。Android 按用户范围不改。
这是可独立合入的 iOS 可靠性增量，不能作为整个外部任务架构已完成的证据。

## 验证

结果在最终 PR 中绑定实现提交；下表只列实际执行的检查，设备能力不由编译推导。

- Simulator：准备策略、SendOutbox、voice request、真实 transcript projector/输入恢复回归。
- Native build：iOS App + ProbeKit + hostless simulator test target 编译。
- Repository：protocol impact、spec、conformance、cross-tree、插件、image、SDK 与既有必需门禁。
- Host smoke：macOS 真 WKWebView + 重新生成的 Worker，不能替代 iPhone 蓝牙链路。
- NOT_RUN：真机锁屏数据不可读、蓝牙断线/冷唤醒、App 被强退后的恢复、30/60 分钟驻留/耗电、
  真正模型/ASR/TTS 全链路、指定 Bot 投递、APNs。没有在用户手机上安装/替换 App。

兼容与回滚：无 outbox schema/字段变更，无新 BLE 字节，无数据库迁移。旧版本仍能读取
已排队记录；回滚代码不删除任务。服务端实现时仍需单独冻结身份、授权、目标、去重保留期、
到期/容量、账户退出与 erasure，并完成两端验收，不能复用本地语音 ID 冒充服务器去重协议。

### 最终本地结果（2026-11-14）

实现提交：`ec6d189563fd0e302733070e4e65c0c2c415b5f7`。
后续提交只补本记录。最后一次 App/Simulator 构建使用本任务重新打包的 Worker 资源。

| 检查 | 实际结果 |
| --- | --- |
| iOS App + ProbeKit 编译、选定 Simulator XCTest | PASS；35 tests / 0 failures：ChatDeliveryPreparationTests 5、NativeVoiceRequestTests 6、SendOutboxTests 17、ChatInputRecoveryTests 7 |
| protocol impact + `git diff --check` | PASS；P05/P06/P07/P09，P12/P16/P27 有逐项不变理由 |
| `phone-spec` | PASS；265 Python tests；最新 cloud-voice 段落补齐后另跑 `spec_golden.py --full`，105 files / 0 errors |
| `phone-cross-tree` | PASS；8 invariants、129 schemas 无 breaking finding，98 工具回归通过 |
| `phone-plugins` | Gate PASS；typecheck 通过，2648 tests passed / 21 skipped / 0 failed；不把内部 skip 写成已执行 |
| `phone-image` | PASS；从钉版 DSH 重新打包，不修改 DSH 源码 |
| `phone-no-dsh-patch` / `phone-license` / `phone-github-oauth` | PASS |
| `phone-p0-conformance` | FAIL；UI token provenance 和 6 页契约行号过期，已在独立 worktree 的原始 base `29a733c` 原样复现 |
| `phone-hygiene` | FAIL；原始 base 与本分支各 435 条发现，按 path/rule/value 归一化后新增 0、减少 0；没有添加 allowlist |
| `phone-gate-contracts` | FAIL；production-scan selftest 依赖 clean hygiene，报告上述同一批发现；其他已运行子检查不升格成整个 gate PASS |
| `phone-sdk` | FAIL / INCOMPLETE；BLE secure/task 跨运行时测试缺少 pinned cJSON/mbedTLS。已记录失败后，停止其重复的 spec 子阶段（独立 phone-spec 已 PASS）；SDK 进程 rc=143，不能称作完整 SDK 通过 |
| `scripts/ci/smoke.sh` | 最终 PASS；4 tests / 0 failures，真实 macOS WKWebView、scripted model、重启/WAL 恢复。初次 4 项虽通过，包装脚本误匹配编译警告中的 skippedRecordCount 导致 FAIL；保留初次结果，未改 gate，原命令暖构建复跑 PASS |

核心复现命令（从仓库根目录执行，Xcode 工程先用 XcodeGen 生成）：

```sh
xcodebuild -project examples/probe-app/PhoneDSHProbe.xcodeproj -scheme PhoneDSHSimTests \
  -destination 'platform=iOS Simulator,name=<available simulator>' CODE_SIGNING_ALLOWED=NO \
  -only-testing:PhoneDSHSimTests/ChatDeliveryPreparationTests \
  -only-testing:PhoneDSHSimTests/NativeVoiceRequestTests \
  -only-testing:PhoneDSHSimTests/SendOutboxTests \
  -only-testing:PhoneDSHSimTests/ChatInputRecoveryTests test
bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree,phone-gate-contracts,phone-github-oauth,phone-hygiene,phone-license,phone-no-dsh-patch
bash scripts/ci/check.sh --only phone-plugins,phone-image,phone-sdk
bash scripts/ci/smoke.sh
```

本地证据文件名：`ios-ingress-sim-tests-lifecycle-final.log`、`ios-ingress-gates.log`、
`ios-ingress-remaining-gates.log`、`ios-ingress-final-spec-content.log`、
`ios-ingress-host-smoke-verified/smoke-report.json`。PR 保持 Draft，不将本次局部通过
升格为完整架构、真机或发布验收。


### 真机驻留验证（2026-11-15，revision 6/7）

设备：iPhone `00008160-00023D1C2240000A`（iPhone19,4，iOS 27.2），板子 `PhoneAgent-7356`，App
`com.tono.phonedsh.probe`（team Q322S2LD93，本地临时 bundle id，未提交）。Worker 从钉版 DSH
`66491b05` 重新打包，使用 `--without-jq`（本机无 Rust）；其余与标准流程相同。

| 场景 | 结果（来自设备 `chat-status.log` / `tonolink-voice.log` / session WAL） |
| --- | --- |
| XCTest（PhoneDSHDeviceTests 中的 4 个套件，36 项） | 35 PASS；`SendOutboxTests.testGeneratedEntryPassesTheOwningSchema` FAIL：要按 Mac 路径读取 `spec/host/v1/schema/outbox-entry.schema.json`，手机上读不到（环境限制，schema 未改） |
| 冷启动（前台） | PASS：引擎启动，`Session resumed` |
| 板子断开时进后台 → 引擎 park → 板子在后台重连 | PASS：03:42:30 `Host parked`；进程被挂起约 397 s，03:49:41 BLE 重连唤醒（`app=2`） |
| 已 park 引擎上的后台语音（rev 6） | 执行 PASS：03:59:23 `Queued delivery: resuming the parked engine`，03:59:29 turn 141 start，request `1b2c0a4a…` 在 WAL 中只出现一次，03:59:34 completed。回传 FAIL：事件流 resync 卡死，语音 deferred；重启后对账为 durable，未重复执行 |
| 修复（rev 7） | 准备循环在 start/resume 后等到 `.ready` 再 drain；resume 后如果事件流仍在恢复，从 lastSeq 重启 pump。已装到真机 |
| 板子保持连接时的后台语音（rev 7 构建） | PASS：05:04:29 wake → heard「现在几点了？」→ admitted `124fc89c…` → running → 05:04:39 reply「现在是 9:04 PM…」（9.8 s）→ 播报 → 05:04:47 task_done |
| 后台播报「我在」/回复 | 输出路由为 AirPlay 时 FAIL（`'!int'` cannot interrupt others，03:56–03:59）；路由为 Speaker 时 PASS（05:04）。与本 PR 无关，另行跟踪 |

NOT_RUN：rev 7 中 park 之后的 pump 重启（需要再断电一次板子）；强退 / 系统回收后由 BLE
冷启动；30/60 分钟耗电。

### 后台 AirPlay 播报修复（2026-11-15，ios-audio-session revision 3）

原因：只有 playAndRecord 类别才能把 AirPlay 输出强制改到扬声器，而 iOS 拒绝在后台切换到这个类别
（`'!int'`）。板子一断开，前台预先切好的扬声器就被释放，后台重连后的回合只能重新切，因此失败；
另外，即使输出是 Speaker，旧代码也会切换一次类别。

修复：只有输出是 AirPlay 时才切换类别；后台断开时保留前台预先切好的扬声器，回到前台且板子
仍不在时才释放；后台断开后保活再维持 600 s。

| 检查 | 结果 |
| --- | --- |
| 真机 XCTest（SpeakerOutputLease、BackgroundSpeakerOutputLease、ChatDeliveryPreparation、NativeVoiceRequest、ChatInputRecovery） | 26/26 PASS |
| 真机：镜像到板子（AirPlay）→ App 进后台 → 板子关机再开机 → 后台重连 → 语音 | PASS：05:41:53 在后台重连（`app=2`），05:42:27 wake，没有 `output_error`，输出 `after: Speaker`，「我在」和回复均播出，05:42:43 task_done，用时 8.6 s |
| 修复前同一类场景 | FAIL：03:56 / 03:58 / 03:59 每次都有 `output_error … OSStatus 560557684` |

NOT_RUN：超过 600 s 的后台断开（保活释放后 App 被挂起，再由 BLE 唤醒）；耗电。

### 只有延期时才播报确认语（revision 8）

真机（05:47，App 在后台，板子已连接）：wake →「我在」→ heard「今天几？现在几点了？」→ admitted
`011f7f8a…` → running → 05:47:29 回复「今天是 2026 年 11 月 14 日，星期六；现在是 9:47 PM」（9.6 s）
→ 05:47:38 task_done。日志中没有 `ack_ms`，即没有播报确认语。延期时播报一次的路径 NOT_RUN（需要
无法执行的状态）。
