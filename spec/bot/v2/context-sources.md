<!-- SPDX-License-Identifier: MIT -->

# Bot v2 iOS 情境来源、独立授权与合法入口（G-3A）

状态：`target`（契约冻结，N/S/C 按本 revision 实现；不是真机/模拟器证据）。
本文件拥有 iOS 情境来源的 source/consent/observation/wake 契约；端云 schedule/lease/receipt/reconcile
在 `spec/cloud/v1/`（G-3B）。只消费 G-1 的版本/状态词表与既有 `WakeSignal`/`WakeInbox`，不新增
固定知识分类、不新增第二套队列或事件库。

## 1. iOS capability matrix（运行时也是数据）

| 来源 | iOS 公开能力 | 授权 | 本轮 | 真实边界 |
| --- | --- | --- | --- | --- |
| `calendar` | EventKit 读取 | `NSCalendarsFullAccessUsageDescription`；limited | supported | 只能读已授权日历；`EKEventStoreChanged` 只表示“有变化”，不能点名事件；无网络/账户同步保证 |
| `contacts` | Contacts 最小 keys | `NSContactsUsageDescription`；iOS18 limited | limited | 只按用户发起/已知 ID 读最小字段；不遍历全库；默认脱敏 |
| `selected-media` | PHPicker/NSItemProvider | 用户每次选择 | supported | 只处理用户选中的项；不枚举相册 |
| `location-fence` | CLCircularRegion | Always + background location | supported（simulator 注入；真机未验） | 只注册用户确认的围栏；不持续定位；系统延迟/精度不确定 |
| `power` | UIDevice battery / NSProcessInfoPowerStateDidChange | 无 OS 权限；App 内显式 opt-in | limited | 只有充电/低电量；**没有公开“系统空闲”API**；system-idle unsupported |
| `own-notification` | UNUserNotificationCenter（仅本 App） | 通知权限 | supported | 不能读第三方 App 通知 |
| `external-entry` | onOpenURL / NSUserActivity / share NSItemProvider / 用户点按粘贴 | App 内显式入口 | supported（需 C 接线） | 只接受已声明 URL/activity；粘贴只在用户点按时读一次；不后台扫剪贴板 |
| third-party-notifications | 无公开 API | — | **unsupported** | 不得用 mock/Android 冒充 |
| sms | 无公开 API | — | **unsupported** | 仅用户分享/粘贴文本可作为 external-entry |
| call-history | 无公开 API（CallKit 无历史） | — | **unsupported** | 同上 |
| system-idle | 无公开 API | — | **unsupported** | 只有 App 前台空闲可由宿主定义 |
| Android 通知/短信/通话/前台服务 | Android-only | — | **deferred** | 本轮不实现、不在 iOS 模拟 |

capability matrix 由运行时 Swift 数据（`ContextSourceCapabilityMatrix`）表达并由测试读同一份；UI/授权页
不得维护第二份文案。任何 `unsupported` 项在 UI 显示不可用/原因，绝不能靠 fixture 产生“已支持”。

## 2. 同意与订阅（独立授权、独立撤权）

- 全 App 每来源一份用户同意：`notDetermined|authorized|limited|denied|revoked`；默认
  `notDetermined`，不默认开。OS 授权状态另记 `notDetermined|authorized|limited|denied|restricted`。
  OS `denied/restricted` 与用户主动 `revoked` 分开记录。
- 每 Bot 每来源订阅 `{bot_id, source, subscribed_at_ms, consent_generation}`。只有
  `authorized|limited` + 当前 generation 才能订阅/读取。
- 撤权（revoke）：原子地 (a) 置 `revoked`，(b) `generation + 1`，(c) 停该来源 OS 订阅/delegate/
  observer，(d) 清未消费观测与缓存，(e) 写 `context.consent_changed` 审计，(f) 旧 generation 的
  迟到 callback/read 一律拒绝且不触达 OS。
- 持久化 key：**`phone-dsh.bot.context-source-consent.v1`**（P18 私有设置，P26 语义；本文件冻结）。
  值见 `context-consent.schema.json`。版本不是 1 / JSON 损坏 → 整份忽略并回到 `notDetermined`，
  **不得**把未知数据读成 authorized；回滚旧 App 忽略该 key，不崩。
- 单写者 + generation CAS：同一来源的 grant/revoke 带 generation，旧 generation 写失败。

## 3. 观测（两个 additive durable 事件）

新 durable type（P25 enum add-only）：

- **`context.observed`**：真实证据。写 `ignorable:true`；复用既有
  `origin.kind=local, source=runtime` 与 `principal.kind=proactive`；不新增 origin/principal 枚举值
  （若未来新增，必须在变更单写明旧 App 读新库失败的回滚代价）。
- **`context.consent_changed`**：授权/撤权审计。同样 `ignorable:true` + 既有 origin/principal。

`data` 形状由 `context-observation.schema.json` 的 2 个 oneOf 分支冻结：

- 观测：`{schema:"bot-context-observation/v1", source, kind, observed_at_ms, owner_bot_id,
  consent_generation, source_version, uncertainty{level,reason?,completeness}, delivery:"os"|"injected",
  payload, dedupe_key, wake_requested, record_ref?}`。
  - `source` 封闭七值；`kind` 是开放字符串（已知值见下），未知 kind 保留、不猜语义、不崩。
  - `observed_at_ms` 是 **OS 事件时刻**，不是处理时刻；`owner_bot_id` 由宿主绑定，模型不能自报。
  - `source_version` 用 G-1 的 `{basis,value}|{reason}`；native 版本不可得时显式 unknown（如
    `eventkit-event-has-no-modification-stamp` 归入 `source-unversioned`），不得 null 冒充已知。
  - `uncertainty` 必填：`level` low/medium/high + `completeness` complete/partial；能命名原因就写。
  - `delivery` 只有 `os`（真实 OS 回调）或 `injected`（simulator/test driver/受控 fixture）；
    真实 adapter 只能发 os，测试驱动只能发 injected；两者交叉声明由 N 的 registry 拒绝并审计。
  - payload 只放最小字段，≤32 成员；**禁止** token/key/password/private-key/bearer/credential 等
    凭据形状；命中即拒绝（fail closed，写审计不写观测）。
  - `dedupe_key` 由宿主生成（source+kind+稳定业务键），用于 wake/去重，不含用户正文。
- 已知 kind（非封闭，新增需文档）：`calendar.upcoming/changed`、`contacts.changed`、
  `media.selected`、`location.entered/exited`、`power.charging_started/stopped`、
  `power.low_power_enabled/disabled`、`app.foreground/background`、`own-notification.response/delivered`、
  `external.url/user-activity/share-item/paste`。

## 4. 读视图（`context-observation-view.schema.json`）

- 入参由宿主解析 `bot_id`；只返回当前 consent `authorized|limited` 且
  `consent_generation == 当前 generation` 的观测。已撤权/旧 generation/已抹除/过期 → `inactive` +
  `inactive_reason`，**不返回旧正文/payload**。
- 一次读取一个不可变 snapshot；不与新 event append 混代；上限 50 条；超限截断（`truncated` 由调用方
  另带，不静默）。
- 读取前必须重查授权，不依赖缓存里的 `authorized`；撤权后下一次读取零 OS 调用。

## 5. 唤醒（沿用既有 WakeSignal）

- 复用 `WakeSignal(botId, reason, at)`；`reason` 固定 `context:<source>:<kind>`（如
  `context:location-fence:location.entered`）。不新增 wake/held kind。
- wake 只叫醒，**不携带授权面**：是否相关/是否开口/quiet/fuse/出口由目标、授权、记忆与既有主动
  出口（v2 §3）决定；N 不做产品判断。
- 去重：同一 `dedupe_key` 在宿主侧至多唤醒一次；重复/乱序 event 不产生第二次开口。
- `routine.cloud_schedule`（可选，S）：`{enabled, seq, authorization_ref}`；`authorization_ref` 指向
  用户同意的 record/审批，absent=disabled。wake 不复制 grant、不改 delivery/urgent/quiet；客户端
  每次运行前重查授权，拒绝则取消云排程且零调用。

## 6. 兼容、回滚与未覆盖

- 新事件 type 对旧 reader：仅当 `ignorable:true` 才忽略；origin/principal 复用既有枚举，旧 App 可读
  新库（不能识别 context 数据但不崩、不误用）。
- Android/HarmonyOS：本轮不实现；共享 golden 不放 iOS 新字段，Android 严格解析器只读旧基线。
- 未覆盖：真实真机授权/回调证据（设备 unavailable 时如实 WAITING_DEVICE）、第三方通知/短信/通话
  （永久 unsupported）、system-idle（unsupported）、云侧实现（SC）。

## 7. 共享向量与验收

- `golden/context-sources.json`：capability matrix、consent 生命周期/撤权/迟到回调、observation
  正反例（delivery 交叉、凭据、未知 kind）、read view active/inactive、wake reason/dedupe。
- `tools/validate_context_sources.py`：schema + 语义重算 + mutation。
- 命令：`python3 -B spec/bot/v2/tools/validate_context_sources.py`。
- 实现端：N（OS adapter/consent/registry）、S（wake/schedule 授权重查）、C（composition/Info）、
  E（simulator vs device 分层证据）。
