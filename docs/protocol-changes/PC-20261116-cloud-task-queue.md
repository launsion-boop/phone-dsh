<!-- SPDX-License-Identifier: MIT -->
# 云端手机任务队列与 APNs 唤醒（R4）

## 0. 摘要

```yaml
change: PC-20261116-cloud-task-queue
contracts: [P05, P06, P08, P09, P18]
status: implemented
breaking: false
version_decision: 只新增路由、文件与偏好键；既有路由、错误体、记录不变
base: d8151ad58e4b352671a2ff332038c4a9a0a27222
contract_revision: a13a4fe88  # cloud-tasks-v1
```

架构来源：[PR #180](https://github.com/launsion-boop/phone-dsh/pull/180) 的 R4。依赖
[PC-20261116-external-admission](PC-20261116-external-admission.md)（R1）。

用户决定（2026-11-16）：R4 纳入本次范围（此前标为 DEFERRED_BY_USER）；任务正文端到端加密后
存放在云端，云端只存密文；只接受同一账号的用户令牌提交，这次只做接口与命令行测试工具，不做
提交界面。

Protocol impact: P05; P06; P08; P09; P18; P12: none — 不新增模块依赖边，`Package.swift` 不变;
P16: none — Worker 启动与 wire 不变; P24: none — 不新增包依赖，锁文件不变; P27: none — Bot
行与用户动作不变。

## 1. 识别与角色

- 现况：没有任何服务端持久任务、设备注册或推送；`aps-environment` 与 `remote-notification`
  均未配置。
- 期望：同账号的其他端可以给某部手机留任务；云端在手机确认写入准入记录之前一直保留并可重投；
  APNs 只是不含内容的提示；推送全部丢失也不丢任务。
- 协调者兼 contract owner：本任务的主 agent。实现者：云端、iOS、Android 各一。
- Owning contract：[cloud-tasks.md](../../spec/v1/cloud-tasks.md)、
  [cases.json](../../spec/v1/golden/cloud-tasks/cases.json)、参考校验器
  `spec/v1/tools/test_cloud_tasks.py`。云端仓库整包导入到 `contracts/phone-tasks/v1/`，不得手改。
- 受影响端：
  - 云端 `TonoTeam/phone-dsh-cloud`（生产者）：`/v1/phone/**` 路由、表、APNs 发送。
  - iOS（消费者）：注册、密钥、拉取、解密、准入、确认、后台推送入口、设置开关。
  - Android（消费者）：同上但没有推送（`push: null`），只在 App 活跃时拉取。
  - Worker / Rust / 固件：不变。

## 2. 契约 delta

| 项目 | Before → After |
| --- | --- |
| fields／limits | 无 → `phone-device/v1`、`phone-task-submit/v1`、`phone-task-ack/v1` 等封闭对象；正文 ≤ 16384 字节，期限 60 秒–7 天，每设备待处理 ≤ 256，每账号 ≤ 8 台设备 |
| version／unknown | 无 → 每个 body 带 `schema`；未知成员 `400 invalid_request`；未知推送 `kind`／`v` 被手机忽略 |
| correlation | 无 → 提交去重键（账号、`device_id`、`request_id`）；手机侧 `sourceRequestId = task_id` |
| error／retry／deadline／cancel | 无 → 封闭错误码；lease 5–900 秒只控制重投间隔；`pending` 可取消，已准入返回 `409 already_admitted` |
| ACK／durability | 无 → `201` 只表示云端已存；`admitted` 确认只在手机准入记录写入之后发送，云端随即删除密文；`unknown` 是终态 |
| auth／scope | 无 → 仅用户令牌，API key 一律 `403`；跨账号一律 `404`；密文以 HPKE 封到手机公钥，AAD 绑定设备、密钥、请求、目标与期限 |
| 持久化（P18） | 无 → 设备 ID 偏好键 `phone-dsh.bot.cloud.device-id.v1`；私钥在 Keychain／SecureStore；开关偏好键 `phone-dsh.cloud-tasks.enabled.v1`（缺省关闭） |
| 平台（P08） | 无 → iOS 增加 `aps-environment` entitlement 与 `remote-notification` 后台模式；Android 无推送 |

自检：没有第二种表达（设备 ID 与 #187 的调度契约共用同一个键）；新 body 全部封闭且带版本；
没有改动任何既有路由；密封只提供对云端存储的保密性，不提供提交方鉴权，规范 §1 明示。

## 3. 相容性与发佈

| Producer → Consumer | 处理方式 |
| --- | --- |
| 旧云端 → 新手机 | 路由返回 404；手机把功能显示为不可用，不重试风暴，不影响其他功能 |
| 新云端 → 旧手机 | 旧手机从不注册，云端没有设备可投；提交返回 `404 not_found` |
| 新 → 新 | 共享用例 |
| 旧数据 → 新／回滚 | 云端迁移只增表；回滚代码不删表。手机关闭开关即删除注册；已准入的记录按 R1 继续 |

发布顺序：云端先上线（无客户端时无影响）→ 手机带开关发布（缺省关闭）。APNs 凭据未配置时
云端不发推送，其余条款照常成立。

## 4. 分工与证据

| 端 | 独占路径 | 验收命令 |
| --- | --- | --- |
| 契约（owner） | `spec/**`、本单 | `python3 -B spec/v1/tools/test_cloud_tasks.py`；`bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree` |
| 云端 | 云端仓库：`contracts/phone-tasks/v1/**`（整包导入）、`app/routes/phone_tasks.py`、`app/phone_tasks/**`、`app/db/models.py`、`app/db/migrations/versions/0002_*.py`、`app/config.py`、`tests/test_phone_tasks*.py`、`scripts/phone_task_cli.py` | `./scripts/check.sh`（真实路由读共享用例） |
| iOS | `Sources/PhoneDSH/CloudTasks/**`（新）、`Tests/PhoneDSHTests/CloudTask*Tests.swift`（新）、`examples/probe-app/PhoneDSHProbe/**` 中的接线与设置开关、`examples/probe-app/Config/*`、`examples/probe-app/project.yml` | `swift test --filter CloudTask`；模拟器回归；App 构建 |
| Android | `android/net/src/main/kotlin/com/phonedsh/cloudtasks/**`（新）及测试、`android/app/**` 中的接线 | `./gradlew :net:test --tests '*CloudTask*'` |

- 每端的真实编解码与状态机必须跑 `messages`、`aad`、`sealing`、`submit`（云端）、`acks`（云端）、
  `pull`（云端）、`phone`（手机）各分节。
- 密封向量已用两套独立实现对拍：Python 参考实现生成，CryptoKit 打开 3 个正例、拒绝 8 个反例
  （2026-11-16，macOS，PASS）。
- NOT_RUN：真实 APNs 投递、后台推送的延迟／合并／丢失、强退后的行为、真实云端部署、
  真实账号端到端。APNs 需要推送密钥与带推送能力的描述文件，由用户提供。
- 剩余风险：提交方对手机不具备独立鉴权（云端被攻破可伪造任务，手机侧权限确认仍然生效）；
  目标 ID 需要提交方事先知道，本单不提供列举接口；Android 没有推送通道。

## 5. 修订纪录

| revision | 由谁 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| cloud-tasks-v1 | 主 agent | 首次冻结 | 云端、iOS、Android |
| cloud-tasks-v1.1 | 主 agent | 裁定 iOS 库实现者的三条 CONTRACT CHANGE REQUEST：(1) 终态确认的原因映射补全（§7，未列出的 `failed` 原因一律 `run_failed`，新增 `terminal` 用例）；(2) 请求封闭、响应开放，单个解不出的拉取元素不拖垮整次拉取（§1、§5，新增 `pull_elements` 用例）；(3) 另一账号对同一 `device_id` 的 `PUT` 视为接管（§2）。v1 的其余条款与既有用例不变 | 云端、iOS、Android |
| cloud-tasks-v1.2 | 主 agent | iOS 库实现者指出规范“每一层都开放”与参考校验器对 `target`／`sealed` 的封闭判定不一致：以规范为准，修正校验器并新增 2 个 `pull_elements` 用例；语义不变 | 云端、iOS、Android |
| cloud-tasks-v1.2（补充） | 主 agent | 云端实现者的打包请求：校验器可用 `PDSH_CLOUD_TASK_CASES` 指定用例路径，规范写明导入布局为平铺；并写明确认只在设备注册于调用方时接受（§5） | 云端、iOS、Android |
| cloud-tasks-v1.3 | 主 agent | Android 库实现者的澄清请求：密文能打开但不是 1–16384 字节合法 UTF-8 时，确认为 `rejected`／`decrypt_failed`（§7，新增 `sealing.not_text` 2 个用例） | 云端（无行为变化）、iOS、Android |
| cloud-tasks-v1.4 | 主 agent | 云端实现者正确地拒绝实现尚未写进契约的规则并提出请求：同一账号下同一 `key_id` 不得更换公钥（`409 key_mismatch`，不改变任何状态），接管不比较；手机收到后换新 `key_id` 重新注册（§2，新增 `registration` 5 个用例） | 云端、iOS、Android |
| cloud-tasks-v1.5 | 主 agent | Android 库实现者指出 v1.3 的空明文用例与 §5 矛盾（16 字节密文本身就是不可解码元素）：删除该用例，换成截断的 UTF-8 序列；同时把此前只在通知里说过的两点写进 §7：到期判断以拉取响应的 `server_time_ms` 为准；终态确认重发到被接受或记录被清扫为止。线上行为不变 | 云端（无行为变化）、iOS、Android |
