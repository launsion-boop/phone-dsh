<!-- SPDX-License-Identifier: MIT -->
# 外部请求准入记录与云端任务队列：实现记录

架构来源：[PR #180](https://github.com/launsion-boop/phone-dsh/pull/180) 的 R1 与 R4，加 Android 对齐。
基线：[PR #186](https://github.com/launsion-boop/phone-dsh/pull/186) 的分支头 `d8151ad5`。
契约：[外部请求准入记录](../protocol-changes/PC-20261116-external-admission.md)
（`external-admission-v1.1`）、[云端任务队列](../protocol-changes/PC-20261116-cloud-task-queue.md)
（`cloud-tasks-v1.5`）。

## 解决的问题

1. 外部来的请求（板子语音、别的设备留下的任务）在交给执行方之前没有统一的持久记录：重复投递
   靠下游各自去重，投给板子 Bot 的语音在引擎起来之前没有任何落盘。
2. 没有任何办法在手机不在线时给它留任务。
3. Android 的发送在传输之前不落盘，进程一死消息就没了；结果未知时只能靠用户手动重试。

## 交付内容

| 端 | 内容 |
| --- | --- |
| 契约 | 准入记录：记录形状、去重、阶段、限额、存储；云端任务：路由、密封、状态机、推送。两份都带共享正反例和参考校验器 |
| iOS | 准入记录实现；TonoLink 语音先准入再交付；云端任务客户端库与 App 接线；账号页「云端任务」开关（缺省关闭）；推送 entitlement 与后台模式 |
| Android | 持久发送队列、未知结果读回、合并准备入口；准入记录实现；云端任务客户端库与 App 接线；账号页同一开关。没有推送通道，没有 TonoLink 语音（GAP-20） |
| 云端 | `TonoTeam/phone-dsh-cloud` 分支 `feat/phone-task-queue`（头 `0021a57`）：设备注册与接管、提交、拉取与租约、确认、清扫、APNs 发送器、提交端命令行工具。未推送、未部署 |

用户决定（2026-11-16）：任务正文端到端加密，云端只存密文；只接受同账号用户令牌提交；APNs
密钥暂不配置（后台现有两把密钥找不到对应的 `.p8`，团队密钥数已满）。

## 验证（head `adf758e1`，2026-11-16，macOS）

| 检查 | 结果 |
| --- | --- |
| `python3 -B spec/host/v1/tools/test_external_admission.py`、`spec/v1/tools/test_cloud_tasks.py` | PASS |
| 密封向量对拍：Python 参考实现生成，CryptoKit 打开 | PASS（3 个正例打开，8 个反例拒绝；v1 时执行） |
| `check.sh --only phone-spec,phone-cross-tree,phone-no-dsh-patch,phone-license,phone-modules` | PASS（`phone-spec` 在 `dadde725` 上执行，其后只有 `android/**` 变化） |
| `phone-github-oauth`、`phone-xcode-resolve` | PASS |
| iOS 模拟器：7 个套件 | PASS，90 项 / 0 失败（接线 10、准入记录 23、SendOutbox 21、读回 6、语音 6、准备策略 17、输入恢复 7） |
| iOS App 模拟器构建 | PASS |
| `swift test --filter 'CloudTask\|CloudVoice\|TonoAccount'` | PASS，73 项，1 项跳过（需显式开启的 Keychain 用例） |
| Android `:app:testDebugUnitTest` | PASS，746 项 / 0 失败 / 7 跳过 |
| Android `:lib:testDebugUnitTest` | PASS，1664 项 / 0 失败 |
| Android `:net:test --tests '*CloudTask*'` | PASS，47 项 |
| 云端 `./scripts/check.sh`（`0021a57`） | PASS，424 项，契约校验器 14 项无跳过 |
| `phone-p0-conformance` | FAIL：页面对齐 2 处基线外差异（Android 缺固件构建页及其设置入口），main 上既有，#186 已记录。本次新增的账号页差异已由 Android 实现消除 |
| `phone-hygiene` | FAIL：476 条，其中 29 条位于本次新增文件，均为契约冻结的云端域名与键名；未改白名单 |
| `phone-gate-contracts` | FAIL：生产扫描自测依赖 hygiene 干净 |
| `phone-android-structure` | FAIL：工具测试报本机 Android SDK 缺 `platform-35` 等包；`structure_check.py` 本身 PASS（14 项） |
| `phone-sdk` | FAIL：`BLESecureCrossRuntimeTests` 缺 cJSON／mbedTLS（既有环境问题）；`WebEngineTests.testJITProbeStoresBaselineAndReportsRatio` 失败，已在基线 `d8151ad5` 的独立工作树上原样复现 |
| `phone-android-tests`（完整门禁）、`phone-plugins`、`phone-image`、`scripts/ci/smoke.sh` | NOT_RUN |

### 真机（2026-11-16，iPhone19,4，`com.tono.phonedsh.probe`，团队 `Q322S2LD93`）

| 检查 | 结果 |
| --- | --- |
| 带签名的设备构建（Xcode 自动管理的团队描述文件；`project.yml` 的 Bundle ID 与团队只在本地临时替换，未提交） | PASS |
| 已签名产物的 entitlement 含 `aps-environment = development` | PASS（`codesign -d --entitlements`） |
| 安装并启动；进程存活，启动报告与 `tonolink-voice.log` 有新写入 | PASS |
| 板子语音经准入记录 | NOT_RUN：日志为 `board not found or not ready within 20.0 seconds`，板子不在场 |
| 打开「云端任务」开关、推送令牌注册、锁屏下准入、强退恢复 | NOT_RUN：需要在手机上操作 |

## 未验证

- 真机：锁屏写入、BLE 冷唤醒后的准入、强退恢复、文件保护级别、设备 Keychain。
- 真实 APNs 投递与后台推送唤醒（没有密钥）。
- 真实云端：分支未部署；只跑过 SQLite，跨副本防重复领取未被真实 PostgreSQL 检验。
- iOS `ChatModel` 与 Android `ProbeEngineViewModel` 里的真实接线路径只有编译证据；测试覆盖的是
  桥接层、协调器和策略函数。
- Android 任何设备或模拟器运行；真实 Android Keystore。
- 模型端到端。

## 已知限制

- 提交方对手机没有独立鉴权：密封只防云端存储读到正文。取到的任务是普通请求，手机侧权限确认照常。
- `bot` 目标没有契约定义的终态回读，记录最多到 `linked`，14 天后记为 `unknown`。Android 上
  `bot` 目标没有交付方，会一直等到过期。
- Android 只投递到当前打开的对话；附件仍内联进提示文本。
- iOS 的 `dsh-session` 目标只有在引擎运行时才能判定“不存在”，否则任务延后到引擎运行或云端过期。
- 云端的租约到期补推依赖 `phone-tasks-sweep` 定时任务，仓库里没有配置。
- 根目录 `Package.resolved` 在本机被构建工具改写，未提交。

## 兼容与回滚

只新增文件、目录、路由和表；既有记录、schema、BLE 字节与路由不变。旧版忽略 `admissions/`。
云端任务开关缺省关闭，关闭即删除注册。云端迁移只增表。
