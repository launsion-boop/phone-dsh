# 板子从聊天可用：journal key 直达本机工具、受信任设备、Link 回执可回收（P05／P07）

```yaml
change: PC-20261109-link-key-trust-receipts
contracts: [P05, P07, P09, P18]
status: implemented
breaking: false
version_decision: No wire, frame, opcode, status or schema change. One gateway header exception (journal key to loopback targets only) with a new golden vector; P07 device-side receipt retention with tombstones (same receipt record layout, new NVS keys); phone-side trust defaults behind an opt-in store flag the app enables. Older peers interoperate unchanged.
base: 627aed35
contract_revision: spec/v1/gateway-security.md §3 + golden/gateway/hop-004.json; spec/device/v1/ble-link.md "持久化、重连和权限" rules 5–7 @ this PR head
```

Protocol impact: P05; P07; P09; P18. P05 — gateway keeps `x-pdsh-idempotency-key` for loopback upstreams (Swift + Android + vector); `iphone_agent_run` served on the Bot path. P07 — receipt retention with tombstones (reference firmware), refused UPLOAD/COMMIT reported `not_executed`, trusted connected devices, scan of system-connected boards, reconnect of remembered boards. P09 — Bluetooth page copy and the disconnect action; page contracts regenerated. P18 — two new UserDefaults keys (`phone-dsh.ble.revoked-grants.v1`, `phone-dsh.ble.remembered-boards.v1`). P12: none — no module, product or ABI change.

## 1. 识别与角色

- **Trigger → 现况 → 期望.** 老板演示：在聊天里说“开灯／关灯”，TonoLink 板子照做。用普通用户视角在 iPhone 上实测，依次碰到四个问题：(1) 每个原生工具调用都缺 `X-PDSH-Idempotency-Key`，被拒；(2) 每次连接都要逐项点“允许”，扫描还找不到已被系统（HID）连上的板子；(3) 板子掉线后不会回来；(4) 板子用过若干次后所有写操作永远失败。期望：连一次就能一直用，聊天开关灯稳定可用。
- **Roles.** 单一 agent 兼 coordinator／contract owner／implementer／reviewer（AGENTS.md §3）。
- **Ends.** Swift `PhoneDSHGateway`、`PhoneDSHBLE`、app；Android `:net` gateway；参考固件 `firmware/esp32-reference`；TonoLink 固件（另一仓库，同一规则，见 §4）。Worker／插件无改动。

## 2. 根因与 delta

| 问题 | 根因（实测证据） | 修复 |
| --- | --- | --- |
| journal key 缺失 | Worker 的 `llm-bridge` 一直正确附加 key；请求经 host `/v1/http` 时 `ModelGateway.makeURLRequest` 删除所有 `x-pdsh-*`。临时诊断显示 Bot listener 收到的请求没有任何 `x-pdsh-*` 头；只保留 key 给 loopback 后，`has_key=true`（用 `main` 未改动的插件也成立）。 | gateway-security §3 例外：`x-pdsh-idempotency-key` 仅在上游是 loopback 字面量时保留；其他 `x-pdsh-*` 与非 loopback 一律照旧删除。`gw-hop-004`。 |
| 反复授权／扫不到 | P07 旧规则“每次连接逐工具授权、断连清除”；`scan()` 只看广播，且发现列表上限 100，系统已连接（HID）的板子不会被扫描回报。 | ble-link 规则 6：App 打开 `trustConnectedDevices` 后，连接即信任，全部工具／读取／提醒默认允许，只记住撤销；扫描加 `retrieveConnectedPeripherals(Link service)` 与记住的板子并绕过上限。库默认仍是旧行为。 |
| 掉线不回 | 只有 App 启动时会重连。 | 记住的板子在断线回调完全返回后经普通 connect 路径自动重连（不在回调内）；用户点“断开连接”即忘记。 |
| 写操作永久失败 | 参考固件设计：16 个持久回执永不驱逐；而且一条回执 ≈4.2 KB、NVS 24 KB 与绑定共用，空间在 16 槽之前就满 → 保存失败 → 账本永久不健康（INTERNAL），手机误报 outcome_unknown；被拒 COMMIT 还占住上传缓冲导致之后 BUSY。TonoLink 文档 01-requirements H2／06 D-01 已记录。 | ble-link 规则 5：无空槽或 NVS 空间不足时，驱逐最旧的已结束回执（state 2/3，运行中绝不驱逐），先写持久墓碑环（request UUID + key 摘要，16 条）再擦除：重放仍被 5 拒绝，RESULT 回 3。规则 7：被拒 UPLOAD／非 5 的被拒 COMMIT 未执行 → 手机报 `not_executed`；被拒 COMMIT 释放本请求的上传缓冲。receipt_t 布局不变（新增 NVS 键 `s00…s15`、`rseq`、`tombs`、`tomb_n`）。 |

Self-check（spec/README §5.1）：不新增 envelope、字段、错误码或 opcode；状态码沿用；gateway 例外只放宽到本机 loopback；P07 墓碑保持“旧命令不重放”。D-01 方案 A 中“独立 NVS 分区”需要整机烧录，本次未做（见 §4 风险）。

## 3. 相容性

| Producer → Consumer | 行为 |
| --- | --- |
| 新 App → 旧固件 | 旧固件仍会在空间满后 INTERNAL；手机现报 `not_executed`（真实：未执行）。需升级固件才能长期使用。 |
| 旧 App → 新固件 | 线格式不变；旧 App 不区分 not_executed，照旧报 outcome_unknown。 |
| 旧 NVS 数据 → 新固件 | 旧回执无年龄 → 视为最旧先被驱逐；布局不变，不会被判损坏。墓碑键缺失视为空环。回滚到旧固件：新键被忽略，旧固件仍按旧规则（可能再次满）。 |
| gateway 旧／新 | 只多保留一个头给 loopback；外部上游不变。Android 同规则。 |

## 4. 证据

- Swift：`swift test --filter 'ModelGatewayTests|PDSHLinkTests'` → PASS（54 + 12，含 `testJournalKeyReachesOnlyLoopbackToolEndpoints`、`testRefusedCommitOrUploadIsNotExecutedButConflictStaysUnknown`）。
- Android：galic `./gradlew :net:test` → 236 tests, 0 failed（`GatewayVectorConformanceTest` 跑 `gw-hop-004`，catalog 31）。
- spec：`gateway_check.py` → 31 vectors, 0 error。
- 参考固件：galic `IDF_PATH=/opt/esp-idf bash firmware/tests/run.sh` → exit 0（含“bounded ledger with tombstones”）。
- TonoLink 固件（`tonolink-m21-r4-firmware` 分支 `fix/link-receipt-eviction`）：`host_tests/run.sh --no-external --fast` → 35/35（`test_link_core` 17，含满 NVS 与墓碑重放用例）；galic IDF v6.1 构建；经手机 BLE OTA 到板子，`ota_1`、`pending_verify:false`。
- 设备（iPhone19,4 “iPhone”，经本机 USB 安装，Q322S2LD93 签名；板子 PhoneAgent-7356）：普通启动（无 DEBUG autoconnect）→ 板子自动重连、`light.set/light.get` 默认已授权；聊天“关灯／开灯／关灯” → 板子回 `{"on":false|true,"state_source":"ws2812"}`、`status: completed`；OTA 重启后自动重连。
- 未验证：Android／Harmony 的 BLE 受信任设备（无对应 consumer）；长时间运行；独立 NVS 分区（需整机烧录，留给 TonoLink D-01 后续）。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知 |
| --- | --- | --- | --- |
| 1 | Claude | 初版。此前在 Worker 侧的两次修复尝试（ALS 关联、提前包装 fetch）经设备诊断证明根因不在 Worker，已撤回，不在本 PR。 | iOS、Android gateway、参考固件、TonoLink 固件 |
