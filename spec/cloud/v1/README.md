<!-- SPDX-License-Identifier: MIT -->

# 端云可靠调度契约包 v1（G-3B，移动端确认）

状态：**FROZEN**（G-3，contract owner G，phone side）。本包是手机确认的**完整版本包**；云仓
`TonoTeam/phone-dsh-cloud` 只整包导入到 `contracts/mobile-scheduler/v1/` 并更新自己的 manifest，
**不得手改**既有 `contracts/` 包内文件或本包文件。云 base `64a3d2098ca282ef16fc287fab96a979858fbd7a`。

## 1. 边界（不可协商）

- 云端只做：可靠定时、lease、去重、离线待交付、回执/对账、授权内公开来源新鲜度（P2，本轮不阻塞）。
- 云端**不**存用户 prompt/消息/抓取正文/音频/凭据；wire 只允许 opaque IDs、时间、版本、枚举、回执。
  任何 `prompt|message|content|body|audio|token|credential|secret` 字段在本包 schema 中不存在；
  校验器按字段名 fail-closed。
- Agent/工具/会话仍在手机；云端不托管 Agent，不执行 routine，不读用户数据。
- 端点 `/v1/bot/wake/**`，Bearer only；新路由 add-only，旧 OpenAPI 路径/错误体不改。
- opaque id 字符集 `[A-Za-z0-9._:-]{1,128}`；`device_id` 由客户端设备注册生成，跨设备一律 404。
- 唯一键 `(account_id, device_id, bot_id, routine_id)`；同一账号多设备不得互领 occurrence。

## 2. wire 形状

全部消息在 `schema/scheduler-wire.schema.json`（按 `schema` 字段 oneOf）。字段冻结：

### 2.1 register/update/delete schedule

```json
{"schema":"bot-cloud-schedule-request/v1","op":"register|update|delete",
 "device_id":"dev-1","bot_id":"bot-a","routine_id":"routine-1","revision":3,"enabled":true,
 "schedule":{"kind":"interval|daily|weekly|cron","timezone":"Asia/Taipei",
   "interval_minutes":60,"local_time":"09:00","weekdays":[1,3,5],
   "cron":"0 9 * * 1-5","phase_minutes":0},
 "catch_up":"latest","authorization_ref":"record://event/7"}
```

- `revision` 单调；旧 revision 409；重复 DELETE 幂等。
- `catch_up` 默认 `latest`（与 v2「错过的只补一次」一致）。
- `next_due_at` 只由**服务端时钟**计算；客户端 `completed_at` 仅审计，不作权威。
- `schedule.kind`：interval（`interval_minutes` 1–10080，`phase_minutes` 0–59；本地 routine 的 phase 若超出 0–59 或不是 interval 对齐偏移，客户端**不得**注册云排程（fail-closed，保留本地 best-effort），不得截断/四舍五入）、daily
  （`local_time`）、weekly（`weekdays` 1=Mon…7=Sun + `local_time`）、cron（五段，无秒/别名；
  `*`, 数字, `a-b`, `a,b`, `*/n`；不支持 L/W/#）。
- `authorization_ref` 是端上用户同意的记录；云端无法验证，只原样存/回显，不据此声称授权。

### 2.2 poll（long-poll + lease）

请求：`{device_id, bot_id?, limit?:16..32, lease_s?:5..900}`；响应
`{events:[{event_id, device_id, bot_id, routine_id, occurrence_key, occurrence_at_ms,
scheduled_for_ms, lease{lease_id,attempt,expires_at_ms}, schedule_revision}]}`。

- `occurrence_key = sha256(routine_id + ":" + occurrence_at_ms 十进制 epoch ms)`，64 位小写 hex；
  **唯一**的 occurrence 表示是 epoch ms，不接受 ISO 变体。
- `lease_s` 缺省 300，clamp 5–900；`limit` 缺省 16、max 32。lease 只决定谁现在能跑，不是执行授权。
- 同一 occurrence 未终结时不再自动 lease；ACK 丢失后由 reconcile 补，不重跑。

### 2.3 ACK receipt

```json
{"schema":"bot-cloud-ack/v1","device_id":"dev-1","event_id":"evt-1",
 "receipt":{"receipt_id":"rcpt-1","occurrence_key":"<64hex>","outcome":"delivered|skipped|failed|cancelled|unknown",
   "reason":"overlap|quiet|disabled|revoked|needs_reconciliation|crash|timeout|unavailable|local_attempt|superseded|user_stopped",
   "completed_at_ms":1760000000000,"local_run_id":"cloud-<64hex>"}}
```

- first-wins；同 `receipt_id`/同 occurrence 幂等；`unknown` 是**终态**（效果未知），服务端必须停止
  自动 lease/重发，交给端上 needs-reconciliation，不得写成 failed。
- `skipped|failed|unknown` 必须带封闭 `reason`；普通运行失败用 `failed`+`run_failed`，不用 `unavailable` 冒充；`delivered|cancelled` 不带自由文本。
- `local_run_id` 必须是 `cloud-<occurrence_key>`（端上确定性 runId），便于对账。

### 2.4 reconcile

请求 `{device_id, since_ms, limit?:16..32}`；响应 `{events:[...], next_cursor_ms}`。用于 ACK 丢失、
乱序、设备重启后恢复；事件按服务端顺序，客户端以 occurrence_key 幂等；不重复交付。

### 2.5 HTTP 映射与响应（SC/S 的最终形状）

- `poll`：`GET /v1/bot/wake/poll?device_id&bot_id&limit&lease_s&wait_s`（wire body 同
  `bot-cloud-poll-request/v1`；`wait_s` 0–60，long-poll）。响应 `bot-cloud-poll-response/v1` 必带
  `server_time_ms`（客户端时钟偏差/lease 剩余以它为准；HTTP Date 只能作 fallback）。
- `reconcile`：`GET /v1/bot/wake/reconcile?device_id&cursor_ms&limit&include_terminal`；响应必带
  `next_cursor_ms` + `server_time_ms`。默认只回未终结/已领 occurrence；`include_terminal=true` 时
  终态事件带 `state:"terminal"` 和 `receipt{receipt_id,outcome,reason?}`。客户端也可按本地 receipt
  重发（first-wins），不依赖响应里的 receipt；服务端不得因重发产生第二终态。
- `ack`：`POST /v1/bot/wake/ack`；响应 `bot-cloud-ack-response/v1`
  `{accepted,duplicate,state:"terminal|unknown",server_time_ms}`。`duplicate=true` 时仍
  `accepted=true`（first-wins）。冲突/错误用 `bot-cloud-error/v1`
  `{code,state?,receipt?,server_time_ms}`；409 `revision-conflict` 可带 `state`。
- `schedule`：`PUT/POST /v1/bot/wake/schedule`；`DELETE` 无独立响应形状，复用
  `bot-cloud-schedule-response/v1`，`next_due_at_ms:null`、`revision` 为删除后的版本。
- **字段名最终版**（G-3 冻结，S/SC 只改一次 codec）：`interval_minutes`、`local_time`、`weekdays`、
  `cron`、`phase_minutes`、`catch_up: latest|none`；不使用 `every_minutes`/`time`/`expr`/`all`。
- `occurrence_at_ms` 是十进制 epoch 毫秒整数，无前导零/正号；`occurrence_key` 的输入是该整数的
  十进制字符串。`routine_id` 原样（不做大小写/归一化）。
- `authorization_ref` 只出现在 schedule request，原样存/回显；**不出现**在 poll/ack/reconcile
  事件或回执里，云端不解释、不据此声称授权。

## 3. 失败语义矩阵（服务端必须本地实测）

| 场景 | 期望 |
| --- | --- |
| 离线到期 | durable pending；重连 poll 拿到；不丢 |
| 服务崩溃/重启 | lease/receipt/pending 从 DB 恢复；无重复 lease |
| lease 过期 | 允许重新 lease 同一 occurrence，但端上 occurrence_key 幂等，不重复执行 |
| 重复 poll/push | 同 occurrence 不产生第二个未终结事件 |
| ACK 丢失 | reconcile 返回已领 occurrence；端上按 receipt 重发；first-wins |
| 乱序/revoke | 旧 revision/已撤销 schedule 不再产生新事件；已领的按端上授权重查，拒绝则 cancelled |
| 设备重启 | 端上以 occurrence_key+本地 routine 状态继续；云端不假定执行成功 |

## 4. 整包导入与 manifest

- `manifest.json`：`package=mobile-scheduler`、`version=v1.0.0`、`immutable=true`、`files[]` 含
  `path/sha256/required`、`import{target:"contracts/mobile-scheduler/v1", whole_package:true,
  must_not_edit_existing:true, manifest_update:"cloud-side only"}`、`boundaries{cloud_stores_user_content:false,
  agent_on_device:true}`。
- SC 导入后：校验每个文件 sha256；不修改包内文件；只更新 cloud 的 `contracts/MANIFEST`（记录包版本
  与本包 sha256）；旧包/旧端点保持可读。
- 回滚：migration 只增表/列；旧客户端不识别新路由，不影响旧路径；删除排程不删历史 receipt。

## 5. 共享向量与验收

- `golden/scheduler-wire.json`：每个消息正例/反例、occurrence_key、lease/limit 边界、outcome/reason、
  跨设备、内容字段拒绝、schedule math（interval/daily/weekly/cron + DST）。
- `tools/validate_cloud_contract.py`：schema + manifest sha256 + 语义重算（occurrence_key、schedule
  next_due）＋ mutation。SC 必须用同一批 `schedule_math_cases` 对拍服务端计算器；Swift
  `RoutineScheduleMath` 与 Python 参考实现必须一致，客户端不加容差。
- 命令：`python3 -B spec/cloud/v1/tools/validate_cloud_contract.py`。
- 真实服务/DB 故障矩阵由 SC 在本地实现并交日志；本包只冻结 wire/边界，不是运行证据。
