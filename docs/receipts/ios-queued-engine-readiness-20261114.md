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
