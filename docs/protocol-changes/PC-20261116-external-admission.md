<!-- SPDX-License-Identifier: MIT -->
# 外部请求准入记录（R1）

## 0. 摘要

```yaml
change: PC-20261116-external-admission
contracts: [P06, P07, P09, P27]
status: implemented
breaking: false
version_decision: 新增文件与新目录；既有记录、schema、wire 均不变
base: 22cab7b1  # main after #186; first frozen on the pre-merge #186 head d8151ad5, then rebased
contract_revision: ac156bf7b  # external-admission-v1
```

架构来源：[PR #180](https://github.com/launsion-boop/phone-dsh/pull/180) 的 R1。基线为
[PR #186](https://github.com/launsion-boop/phone-dsh/pull/186) 合入后的 main。

Protocol impact: P06; P07; P09; P27; P12: none — 不改 SDK 模块、ABI 或 `Package.swift`; P16: none — Worker
启动与 wire 不变; P25: none — Bot store 的表、迁移与事件不变; P26: none — 工具面、记忆与唤醒不变。

## 1. 识别与角色

- 触发 → 现况 → 期望：
  - 现况：TonoLink 语音在落盘前不带来源和去重键；投给板子 Bot 的语音在引擎起来之前没有任何
    持久记录；`spec/host/v1` §9 J2 把“持久外部入口队列”列为未定。
  - 期望：外部请求先写入原生准入记录（来源、主体、稳定请求 ID、固定目标、内容哈希、期限、
    阶段、下游 ID），再交给既有的发送队列或 Bot 用户动作路径；重复投递不重复执行，
    同 ID 不同内容被拒绝，超量时明确拒收。
- 协调者兼 contract owner：本任务的主 agent。实现者：iOS、Android 各一。
  集成审查：主 agent 在同一 head 上合并审查。
- Owning contract：[external-admission.md](../../spec/host/v1/external-admission.md)、
  [admission-record.schema.json](../../spec/host/v1/schema/admission-record.schema.json)、
  共享用例 [external-admission-v1.json](../../spec/host/v1/fixtures/external-admission-v1.json)、
  五个 golden `spec/host/v1/golden/admission-record-*.json`、
  参考校验器 `spec/host/v1/tools/test_external_admission.py`。
- 受影响端：
  - iOS（生产者 + 消费者）：TonoLink 语音入口、准入记录、向 SendOutbox / Bot 用户动作的交付。
  - Android（生产者 + 消费者）：准入记录与向发送队列的交付；Android 没有 TonoLink 语音消费者
    （GAP-20），本单不新增。
  - Worker / Rust / 固件：不变。BLE 字节不变。

## 2. 契约 delta

| 项目 | Before → After |
| --- | --- |
| fields／limits | 无 → `admission-record` v1：文本 ≤ 16384 UTF-8 字节，TTL 1 秒–7 天，待处理 ≤ 256，目录 ≤ 2048，重试 ≤ 12 次 |
| version／unknown | 无 → `v: 1`，schema 关闭未知成员；解不出的文件原样保留、占容量、不交付、不删除 |
| correlation／terminal | 语音只有 `rpcId` → `admissionId`（主体+来源+来源请求 ID 的 SHA-256）去重；`downstreamId` 在准入时生成且不变，等于 SendOutbox `rpcId` 或 Bot 用户动作 nonce |
| error／retry／deadline／cancel | 无 → 准入结果 `invalid`／`duplicate`／`conflict`／`capacity`／`storage`／`admitted`；退避 3 秒起翻倍至 300 秒；到期只作用于 `admitted` |
| ACK／durability／recovery | “已记下”在 SendOutbox 写入后播报 → 在准入记录写入后才有回执；重启后的 `dispatching` 用同一 `downstreamId` 重做下游写入，由下游去重 |
| auth／backpressure | 无 → 主体只有 `local` 与 `account:<id>`；容量满时拒收且不丢已接收记录 |
| 条款状态 | §9 J2 未定 → `external-admission-v1`，`target` |

自检：没有第二种表达（SendOutbox 仍是 DSH 发送的唯一交付账本，Bot 账本不变）；没有改动两端
都读的既有消息；新 enum（`stage`、`source.kind`、`target.kind`）的未知值规则是“整份记录解不出
即按不可解码文件处理”；没有重用或删除任何名称。

### 2.1 iOS 语音入口的接线（冻结）

- 唤醒时固定 `sourceRequestId` 与 `downstreamId`（同一个 UUIDv4，即现有 `NativeVoiceRequest.rpcID`）。
- 识别出非音量指令的文本后决定目标并准入：板子绑定的 Bot 的 unit 此刻可用时目标为该 Bot，
  否则为唤醒时固定的本地 DSH 会话（沿用 [PC-20261114-device-bot](PC-20261114-device-bot.md)
  的回退条件，只是在准入时决定一次并写入记录，之后不再改）。
- 主体 `local`，来源 `tonolink-voice` + 板名的 SHA-256，TTL 24 小时。
- 准入结果不是 `admitted`／`duplicate` 时不播报“已记下”；`capacity`／`storage` 沿用 #186 的
  “这条没有保存，请在手机上重试”。延期播报、回复归属、音量指令路径不变。
- `dsh-session` 目标交给 SendOutbox（`rpcId = downstreamId`），进入既有的合并准备入口；
  `bot` 目标交给该 Bot 既有的用户动作路径（`nonce = downstreamId`）。

## 3. 相容性与发佈

| Producer → Consumer | 处理方式 |
| --- | --- |
| old → new | 旧版不写准入记录；新版读到空目录，行为与今天相同 |
| new → old | 旧版忽略 `admissions/`；已交给 SendOutbox 的条目照常投递；仍处于 `admitted` 的记录在旧版里不会被交付，升级回来后继续（不丢、不重复） |
| new → new | 共享用例与 golden |
| 旧数据 → 新／回滚 | 没有旧数据需要迁移；回滚不删除目录 |

不改 `outbox-entry` schema、BLE 帧、Bot store。无 image／native 产物变化。

## 4. 分工与证据

| 端 | 独占路径 | 验收命令 |
| --- | --- | --- |
| 契约（owner） | `spec/**`、本单 | `python3 -B spec/host/v1/tools/test_external_admission.py`；`python3 -B spec/host/v1/tools/host_check.py --root .`；`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` |
| iOS | `examples/probe-app/ProbeKit/Admission/**`（新）、`examples/probe-app/PhoneDSHProbe/{ChatModel,TonoLinkVoiceHost}.swift`、`examples/probe-app/PhoneDSHProbe/Bot/{BotChatModel,BotProductionPage}.swift`、`examples/probe-app/PhoneDSHSimTests/ExternalAdmission*Tests.swift`（新）、`examples/probe-app/project.yml` | `xcodebuild … -scheme PhoneDSHSimTests … -only-testing:PhoneDSHSimTests/ExternalAdmissionJournalTests …`（真实 journal 读共享用例）以及既有的 `SendOutboxTests`、`NativeVoiceRequestTests`、`ChatDeliveryPreparationTests` |
| Android | `android/app/src/main/kotlin/com/phonedsh/probe/admission/**`（新）及其测试 | `./gradlew :app:testDebugUnitTest --tests '*ExternalAdmission*'`（真实 journal 读共享用例） |

- 每端的测试必须用真实的 journal 实现跑 `ids`、`records`、`admit`、`transitions`、`retry`、
  `sweep`、`order` 全部分节，并覆盖五个写入／交付边界的崩溃注入（写入前、写入后未交付、
  `dispatching` 未确认、已 `linked` 未结算、终态未清理）。
- 真机（锁屏写入、BLE 冷唤醒后的准入、强退恢复）：NOT_RUN，直到实际执行。
- 剩余风险：`bot` 目标没有契约定义的终态回读，记录最多到 `linked`，14 天后记为 `unknown`
  （待 P27 owner 定义后再改）；容量与期限数值未经 R0 真机测量，按保守值冻结。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| external-admission-v1 | 主 agent | 首次冻结 | iOS、Android |
| external-admission-v1.1 | 主 agent | 裁定 iOS、Android 实现者各自提出的同一条 CONTRACT CHANGE REQUEST：请求自己的 `admissionId` 下已有解不出的文件时结果为 `storage`（§2，新增 3 个 `admit` 用例）；并裁定两端都指出的队头阻塞：只是在等执行条件的记录不占每轮 16 条的额度（§4，新增 1 个 `order` 用例，记录带 `waiting`）。其余条款与既有用例不变 | iOS、Android |
